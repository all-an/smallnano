/// Vote processor — validate, deduplicate, weight, and route incoming votes.
///
/// This module ties together the pure Vote type, the representative weight
/// cache, the active election set, and the confirmation tracker. It does no
/// networking itself; callers feed already-received votes into `process()`.
const std = @import("std");
const active_elections_mod = @import("active_elections.zig");
const rep_weights_mod = @import("rep_weights.zig");
const vote_mod = @import("../types/vote.zig");

const ActiveElections = active_elections_mod.ActiveElections;
const RepWeights = rep_weights_mod.RepWeights;
const Vote = vote_mod.Vote;
const FINAL_VOTE_TIMESTAMP = vote_mod.FINAL_VOTE_TIMESTAMP;

const Key32 = [32]u8;

fn Key32Context(comptime K: type) type {
    return struct {
        pub fn hash(_: @This(), k: K) u64 {
            return std.hash.Wyhash.hash(0, &k);
        }

        pub fn eql(_: @This(), a: K, b: K) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };
}

pub const ProcessSummary = struct {
    applied_hashes: u8 = 0,
    confirmed_hashes: u8 = 0,
};

pub fn VoteProcessor(comptime ConfirmationType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        rep_weights: *RepWeights,
        elections: *ActiveElections,
        confirmation: *ConfirmationType,
        last_timestamps: std.HashMap(Key32, u64, Key32Context(Key32), 80),

        pub fn init(
            allocator: std.mem.Allocator,
            rep_weights: *RepWeights,
            elections: *ActiveElections,
            confirmation: *ConfirmationType,
        ) Self {
            return .{
                .allocator = allocator,
                .rep_weights = rep_weights,
                .elections = elections,
                .confirmation = confirmation,
                .last_timestamps = std.HashMap(Key32, u64, Key32Context(Key32), 80).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.last_timestamps.deinit();
        }

        /// Process one vote. Invalid signatures return an error; stale or
        /// duplicate timestamps are ignored quietly.
        pub fn process(self: *Self, vote: *const Vote) !ProcessSummary {
            try vote.verify(self.allocator);

            if (!try self.accept_timestamp(&vote.representative, vote.timestamp)) {
                return .{};
            }

            const weight = self.rep_weights.get(&vote.representative);
            if (weight == 0) return .{};

            var summary = ProcessSummary{};
            for (vote.hashes.constSlice()) |hash| {
                const result = try self.elections.apply_vote(vote.representative, weight, hash);
                switch (result) {
                    .ignored => {},
                    .ongoing, .fork => summary.applied_hashes += 1,
                    .confirmed => |winner| {
                        summary.applied_hashes += 1;
                        const confirm_result = try self.confirmation.on_confirmed(winner);
                        if (confirm_result == .advanced) summary.confirmed_hashes += 1;
                    },
                }
            }

            return summary;
        }

        fn accept_timestamp(self: *Self, representative: *const [32]u8, timestamp: u64) !bool {
            const gop = try self.last_timestamps.getOrPut(representative.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = timestamp;
                return true;
            }

            const current = gop.value_ptr.*;
            if (current == FINAL_VOTE_TIMESTAMP) return false;
            if (timestamp == current) return false;
            if (timestamp != FINAL_VOTE_TIMESTAMP and timestamp < current) return false;

            gop.value_ptr.* = timestamp;
            return true;
        }
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const block_mod = @import("../types/block.zig");
const confirmation_mod = @import("confirmation.zig");
const ed25519 = @import("../crypto/ed25519.zig");
const NullStore = @import("../store/null_store.zig").NullStore;

fn test_block(
    account: [32]u8,
    previous: [32]u8,
    representative: [32]u8,
    balance: u128,
    link: [32]u8,
) block_mod.StateBlock {
    return .{
        .account = account,
        .previous = previous,
        .representative = representative,
        .balance = balance,
        .link = link,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
}

test "vote_processor: rejects invalid signature" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    var rep_weights = RepWeights.init(testing.allocator);
    defer rep_weights.deinit();
    var active = ActiveElections.init(testing.allocator, 4);
    defer active.deinit();
    var confirmation = confirmation_mod.ConfirmationTracker(NullStore).init(&store, &rep_weights);
    var processor = VoteProcessor(@TypeOf(confirmation)).init(testing.allocator, &rep_weights, &active, &confirmation);
    defer processor.deinit();

    const kp = ed25519.KeyPair.generate();
    const hash = [_]u8{0xAA} ** 32;
    var vote = try Vote.create(&kp.secret, &kp.public, 1, &.{hash});
    vote.signature[0] ^= 0xFF;

    try testing.expectError(Vote.VerifyError.InvalidSignature, processor.process(&vote));
}

test "vote_processor: ignores duplicate and stale timestamps" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const rep_kp = try ed25519.KeyPair.from_seed(&([_]u8{0x10} ** 32));
    const account = [_]u8{0x20} ** 32;
    const rep = rep_kp.public;
    const blk = test_block(account, block_mod.ZERO_HASH, rep, 12, [_]u8{0x21} ** 32);
    const hash = blk.hash();

    try store.put_block(&hash, .{ .account = account, .block_bytes = blk.to_bytes(), .height = 1 });

    var rep_weights = RepWeights.init(testing.allocator);
    defer rep_weights.deinit();
    try rep_weights.set_confirmed(&([_]u8{0x30} ** 32), &rep, 100);

    var active = ActiveElections.init(testing.allocator, 4);
    defer active.deinit();
    _ = try active.start_election(&blk, rep_weights.total_weight());

    var confirmation = confirmation_mod.ConfirmationTracker(NullStore).init(&store, &rep_weights);
    var processor = VoteProcessor(@TypeOf(confirmation)).init(testing.allocator, &rep_weights, &active, &confirmation);
    defer processor.deinit();

    const vote_first = try Vote.create(&rep_kp.secret, &rep, 5, &.{hash});
    const vote_dup = try Vote.create(&rep_kp.secret, &rep, 5, &.{hash});
    const vote_old = try Vote.create(&rep_kp.secret, &rep, 4, &.{hash});

    try testing.expectEqual(@as(u8, 1), (try processor.process(&vote_first)).applied_hashes);
    try testing.expectEqual(@as(u8, 0), (try processor.process(&vote_dup)).applied_hashes);
    try testing.expectEqual(@as(u8, 0), (try processor.process(&vote_old)).applied_hashes);
}

test "vote_processor: ignores votes from representatives with zero confirmed weight" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    var rep_weights = RepWeights.init(testing.allocator);
    defer rep_weights.deinit();
    var active = ActiveElections.init(testing.allocator, 4);
    defer active.deinit();
    var confirmation = confirmation_mod.ConfirmationTracker(NullStore).init(&store, &rep_weights);
    var processor = VoteProcessor(@TypeOf(confirmation)).init(testing.allocator, &rep_weights, &active, &confirmation);
    defer processor.deinit();

    const kp = ed25519.KeyPair.generate();
    const hash = [_]u8{0x42} ** 32;
    const vote = try Vote.create(&kp.secret, &kp.public, 1, &.{hash});

    const summary = try processor.process(&vote);
    try testing.expectEqual(@as(u8, 0), summary.applied_hashes);
    try testing.expectEqual(@as(u8, 0), summary.confirmed_hashes);
}

test "vote_processor: confirmed vote advances confirmation height" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const rep_kp = try ed25519.KeyPair.from_seed(&([_]u8{0x51} ** 32));
    const account = [_]u8{0x61} ** 32;
    const rep = rep_kp.public;
    const blk = test_block(account, block_mod.ZERO_HASH, rep, 25, [_]u8{0x71} ** 32);
    const hash = blk.hash();

    try store.put_block(&hash, .{ .account = account, .block_bytes = blk.to_bytes(), .height = 1 });

    var rep_weights = RepWeights.init(testing.allocator);
    defer rep_weights.deinit();
    try rep_weights.set_confirmed(&([_]u8{0x81} ** 32), &rep, 90);

    var active = ActiveElections.init(testing.allocator, 4);
    defer active.deinit();
    _ = try active.start_election(&blk, rep_weights.total_weight());

    var confirmation = confirmation_mod.ConfirmationTracker(NullStore).init(&store, &rep_weights);
    var processor = VoteProcessor(@TypeOf(confirmation)).init(testing.allocator, &rep_weights, &active, &confirmation);
    defer processor.deinit();

    const vote = try Vote.create(&rep_kp.secret, &rep, 10, &.{hash});
    const summary = try processor.process(&vote);

    try testing.expectEqual(@as(u8, 1), summary.applied_hashes);
    try testing.expectEqual(@as(u8, 1), summary.confirmed_hashes);

    const ch = store.get_confirmation_height(&account).?;
    try testing.expectEqual(@as(u64, 1), ch.height);
    try testing.expectEqual(hash, ch.frontier);
}

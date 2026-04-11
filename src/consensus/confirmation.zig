/// Confirmation tracker — writes monotonic confirmation height updates.
///
/// Once an election reaches quorum, the winning block becomes the confirmed
/// frontier for that account if and only if its height is above the current
/// confirmation height. The representative weight cache is updated from the
/// winning block's state, not from the live account frontier, so unconfirmed
/// descendants do not leak into the confirmed ledger view.
const std = @import("std");
const block_mod = @import("../types/block.zig");
const rep_weights_mod = @import("rep_weights.zig");
const store_mod = @import("../store/store.zig");

const StateBlock = block_mod.StateBlock;
const ConfirmationHeight = store_mod.ConfirmationHeight;
const RepWeights = rep_weights_mod.RepWeights;

pub const ConfirmationResult = enum {
    no_change,
    advanced,
};

pub fn ConfirmationTracker(comptime StoreType: type) type {
    return struct {
        const Self = @This();

        store: *StoreType,
        rep_weights: *RepWeights,

        pub fn init(store: *StoreType, rep_weights: *RepWeights) Self {
            return .{
                .store = store,
                .rep_weights = rep_weights,
            };
        }

        pub fn on_confirmed(self: *Self, winner_hash: [32]u8) !ConfirmationResult {
            const row = self.store.get_block(&winner_hash) orelse return error.BlockNotFound;
            const blk = StateBlock.from_bytes(&row.block_bytes);
            const current = self.store.get_confirmation_height(&row.account);

            if (current) |ch| {
                if (row.height <= ch.height) return .no_change;
            }

            try self.store.put_confirmation_height(&row.account, ConfirmationHeight{
                .height = row.height,
                .frontier = winner_hash,
            });
            try self.rep_weights.set_confirmed(&row.account, &blk.representative, blk.balance);
            return .advanced;
        }
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const NullStore = @import("../store/null_store.zig").NullStore;

fn test_block(
    account: [32]u8,
    previous: [32]u8,
    representative: [32]u8,
    balance: u128,
    link: [32]u8,
) StateBlock {
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

test "confirmation: advances height and updates representative weights from confirmed block" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const account = [_]u8{0x01} ** 32;
    const rep_a = [_]u8{0x11} ** 32;
    const rep_b = [_]u8{0x12} ** 32;

    const blk_a = test_block(account, block_mod.ZERO_HASH, rep_a, 10, [_]u8{0x21} ** 32);
    const blk_b = test_block(account, blk_a.hash(), rep_b, 20, [_]u8{0x22} ** 32);
    const hash_a = blk_a.hash();
    const hash_b = blk_b.hash();

    try store.put_block(&hash_a, .{ .account = account, .block_bytes = blk_a.to_bytes(), .height = 1 });
    try store.put_block(&hash_b, .{ .account = account, .block_bytes = blk_b.to_bytes(), .height = 2 });
    try store.put_account(&account, .{
        .frontier = hash_b,
        .balance = blk_b.balance,
        .representative = blk_b.representative,
        .height = 2,
        .modified = 0,
    });

    var rep_weights = RepWeights.init(testing.allocator);
    defer rep_weights.deinit();

    var tracker = ConfirmationTracker(NullStore).init(&store, &rep_weights);
    try testing.expectEqual(ConfirmationResult.advanced, try tracker.on_confirmed(hash_a));

    const ch = store.get_confirmation_height(&account).?;
    try testing.expectEqual(@as(u64, 1), ch.height);
    try testing.expectEqual(hash_a, ch.frontier);
    try testing.expectEqual(@as(u128, 10), rep_weights.get(&rep_a));
    try testing.expectEqual(@as(u128, 0), rep_weights.get(&rep_b));
}

test "confirmation: ignores winners at or below current confirmed height" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const account = [_]u8{0x02} ** 32;
    const rep = [_]u8{0x13} ** 32;
    const blk = test_block(account, block_mod.ZERO_HASH, rep, 7, [_]u8{0x23} ** 32);
    const hash = blk.hash();

    try store.put_block(&hash, .{ .account = account, .block_bytes = blk.to_bytes(), .height = 1 });
    try store.put_confirmation_height(&account, .{ .height = 1, .frontier = hash });

    var rep_weights = RepWeights.init(testing.allocator);
    defer rep_weights.deinit();

    var tracker = ConfirmationTracker(NullStore).init(&store, &rep_weights);
    try testing.expectEqual(ConfirmationResult.no_change, try tracker.on_confirmed(hash));
}

/// Active election container with bounded memory usage.
///
/// The container holds at most `max_elections` roots at once. New fork
/// candidates are attached to an existing root; new roots may evict the
/// election with the lowest total tallied weight.
const std = @import("std");
const block_mod = @import("../types/block.zig");
const election_mod = @import("election.zig");

const StateBlock = block_mod.StateBlock;
const Election = election_mod.Election;
const Root = election_mod.Root;

pub const StartResult = enum {
    started,
    fork_registered,
    evicted_and_started,
};

pub const ApplyVoteResult = union(enum) {
    ignored,
    ongoing,
    fork,
    confirmed: [32]u8,
};

pub const ActiveElections = struct {
    allocator: std.mem.Allocator,
    max_elections: usize,
    entries: std.ArrayList(Entry),

    const Entry = struct {
        root: Root,
        election: Election,
    };

    pub fn init(allocator: std.mem.Allocator, max_elections: usize) ActiveElections {
        return .{
            .allocator = allocator,
            .max_elections = max_elections,
            .entries = std.ArrayList(Entry){},
        };
    }

    pub fn deinit(self: *ActiveElections) void {
        for (self.entries.items) |*entry| entry.election.deinit();
        self.entries.deinit(self.allocator);
    }

    pub fn count(self: *const ActiveElections) usize {
        return self.entries.items.len;
    }

    pub fn start_election(self: *ActiveElections, blk: *const StateBlock, online_weight: u128) !StartResult {
        const root = Root.from_block(blk);
        const hash = blk.hash();

        if (self.find_root_index(root)) |idx| {
            _ = try self.entries.items[idx].election.register_candidate(hash);
            return .fork_registered;
        }

        var evicted = false;
        if (self.max_elections > 0 and self.entries.items.len >= self.max_elections) {
            self.evict_lowest_priority();
            evicted = true;
        }

        var election = Election.init(self.allocator, root, online_weight);
        errdefer election.deinit();
        _ = try election.register_candidate(hash);

        try self.entries.append(self.allocator, .{
            .root = root,
            .election = election,
        });

        return if (evicted) .evicted_and_started else .started;
    }

    /// Route one representative vote into the election that owns `hash`.
    pub fn apply_vote(
        self: *ActiveElections,
        representative: [32]u8,
        weight: u128,
        hash: [32]u8,
    ) !ApplyVoteResult {
        const idx = self.find_hash_index(hash) orelse return .ignored;
        const status = try self.entries.items[idx].election.add_vote(representative, weight, hash);
        return switch (status) {
            .ongoing => .ongoing,
            .fork => .fork,
            .confirmed => |winner| .{ .confirmed = winner },
        };
    }

    pub fn get_by_hash(self: *ActiveElections, hash: *const [32]u8) ?*Election {
        const idx = self.find_hash_index(hash.*) orelse return null;
        return &self.entries.items[idx].election;
    }

    fn find_root_index(self: *const ActiveElections, root: Root) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.root.eql(root)) return i;
        }
        return null;
    }

    fn find_hash_index(self: *const ActiveElections, hash: [32]u8) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.election.has_candidate(hash)) return i;
        }
        return null;
    }

    fn evict_lowest_priority(self: *ActiveElections) void {
        if (self.entries.items.len == 0) return;

        var lowest_idx: usize = 0;
        var lowest_weight = self.entries.items[0].election.total_tallied_weight();

        for (self.entries.items[1..], 1..) |entry, i| {
            const weight = entry.election.total_tallied_weight();
            if (weight < lowest_weight) {
                lowest_idx = i;
                lowest_weight = weight;
            }
        }

        self.entries.items[lowest_idx].election.deinit();
        _ = self.entries.orderedRemove(lowest_idx);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

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

test "active_elections: second block on same root becomes fork candidate" {
    var active = ActiveElections.init(testing.allocator, 4);
    defer active.deinit();

    const account = [_]u8{0x01} ** 32;
    const previous = [_]u8{0x02} ** 32;
    const rep = [_]u8{0x03} ** 32;

    const blk_a = test_block(account, previous, rep, 10, [_]u8{0x11} ** 32);
    const blk_b = test_block(account, previous, rep, 11, [_]u8{0x12} ** 32);
    const hash_a = blk_a.hash();
    const hash_b = blk_b.hash();

    try testing.expectEqual(StartResult.started, try active.start_election(&blk_a, 100));
    try testing.expectEqual(StartResult.fork_registered, try active.start_election(&blk_b, 100));
    try testing.expectEqual(@as(usize, 1), active.count());
    try testing.expect(active.get_by_hash(&hash_a) != null);
    try testing.expect(active.get_by_hash(&hash_b) != null);
}

test "active_elections: apply_vote routes to the matching election" {
    var active = ActiveElections.init(testing.allocator, 4);
    defer active.deinit();

    const blk = test_block(
        [_]u8{0x21} ** 32,
        [_]u8{0x22} ** 32,
        [_]u8{0x23} ** 32,
        50,
        [_]u8{0x24} ** 32,
    );
    const hash = blk.hash();

    _ = try active.start_election(&blk, 90);
    const result = try active.apply_vote([_]u8{0x31} ** 32, 60, hash);

    try testing.expectEqualDeep(ApplyVoteResult{ .confirmed = hash }, result);
}

test "active_elections: evicts lowest tally when over capacity" {
    var active = ActiveElections.init(testing.allocator, 2);
    defer active.deinit();

    const blk_a = test_block([_]u8{0x41} ** 32, [_]u8{0x01} ** 32, [_]u8{0x51} ** 32, 10, [_]u8{0x61} ** 32);
    const blk_b = test_block([_]u8{0x42} ** 32, [_]u8{0x02} ** 32, [_]u8{0x52} ** 32, 10, [_]u8{0x62} ** 32);
    const blk_c = test_block([_]u8{0x43} ** 32, [_]u8{0x03} ** 32, [_]u8{0x53} ** 32, 10, [_]u8{0x63} ** 32);
    const hash_a = blk_a.hash();
    const hash_b = blk_b.hash();
    const hash_c = blk_c.hash();

    _ = try active.start_election(&blk_a, 100);
    _ = try active.start_election(&blk_b, 100);
    _ = try active.apply_vote([_]u8{0x71} ** 32, 40, hash_a);

    try testing.expectEqual(StartResult.evicted_and_started, try active.start_election(&blk_c, 100));
    try testing.expect(active.get_by_hash(&hash_a) != null);
    try testing.expect(active.get_by_hash(&hash_b) == null);
    try testing.expect(active.get_by_hash(&hash_c) != null);
}

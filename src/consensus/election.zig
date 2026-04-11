/// Election state machine for one account root.
///
/// Elections are pure in-memory logic: candidate registration, representative
/// vote replacement, tallying, and quorum checks. One election corresponds to
/// one account root `(account, previous)` and may contain multiple candidate
/// blocks if forks are observed for that root.
const std = @import("std");
const block_mod = @import("../types/block.zig");

pub const Root = struct {
    account: [32]u8,
    previous: [32]u8,

    pub fn from_block(blk: *const block_mod.StateBlock) Root {
        return .{
            .account = blk.account,
            .previous = blk.previous,
        };
    }

    pub fn eql(self: Root, other: Root) bool {
        return std.mem.eql(u8, &self.account, &other.account) and
            std.mem.eql(u8, &self.previous, &other.previous);
    }
};

pub const CandidateTally = struct {
    hash: [32]u8,
    weight: u128 = 0,
};

pub const RepBallot = struct {
    representative: [32]u8,
    hash: [32]u8,
    weight: u128,
};

pub const ElectionStatus = union(enum) {
    ongoing,
    confirmed: [32]u8,
    fork,
};

pub const Election = struct {
    allocator: std.mem.Allocator,
    root: Root,
    online_weight: u128,
    candidates: std.ArrayList(CandidateTally),
    ballots: std.ArrayList(RepBallot),

    pub fn init(allocator: std.mem.Allocator, root: Root, online_weight: u128) Election {
        return .{
            .allocator = allocator,
            .root = root,
            .online_weight = online_weight,
            .candidates = std.ArrayList(CandidateTally){},
            .ballots = std.ArrayList(RepBallot){},
        };
    }

    pub fn deinit(self: *Election) void {
        self.candidates.deinit(self.allocator);
        self.ballots.deinit(self.allocator);
    }

    /// Add a new fork candidate to the election.
    /// Returns true only when the candidate was newly inserted.
    pub fn register_candidate(self: *Election, hash: [32]u8) !bool {
        if (self.find_candidate_index(hash) != null) return false;
        try self.candidates.append(self.allocator, .{ .hash = hash });
        return true;
    }

    pub fn candidate_count(self: *const Election) usize {
        return self.candidates.items.len;
    }

    pub fn has_candidate(self: *const Election, hash: [32]u8) bool {
        return self.find_candidate_index(hash) != null;
    }

    pub fn candidate_weight(self: *const Election, hash: [32]u8) ?u128 {
        const idx = self.find_candidate_index(hash) orelse return null;
        return self.candidates.items[idx].weight;
    }

    /// Sum of all candidate tallies. Used by ActiveElections as an eviction
    /// priority metric.
    pub fn total_tallied_weight(self: *const Election) u128 {
        var total: u128 = 0;
        for (self.candidates.items) |candidate| total += candidate.weight;
        return total;
    }

    /// Apply one representative's latest vote to the election.
    ///
    /// Representatives may move their vote between candidates. Their previous
    /// weight is removed from the old candidate before the new tally is applied.
    pub fn add_vote(
        self: *Election,
        representative: [32]u8,
        weight: u128,
        hash: [32]u8,
    ) !ElectionStatus {
        const candidate_idx = self.find_candidate_index(hash) orelse return error.UnknownCandidate;

        if (self.find_ballot_index(representative)) |ballot_idx| {
            var ballot = &self.ballots.items[ballot_idx];
            const old_candidate_idx = self.find_candidate_index(ballot.hash).?;

            if (std.mem.eql(u8, &ballot.hash, &hash)) {
                if (weight > ballot.weight) {
                    self.candidates.items[candidate_idx].weight += weight - ballot.weight;
                } else if (weight < ballot.weight) {
                    self.candidates.items[candidate_idx].weight -= ballot.weight - weight;
                }
                ballot.weight = weight;
            } else {
                self.candidates.items[old_candidate_idx].weight -= ballot.weight;
                self.candidates.items[candidate_idx].weight += weight;
                ballot.hash = hash;
                ballot.weight = weight;
            }
        } else {
            try self.ballots.append(self.allocator, .{
                .representative = representative,
                .hash = hash,
                .weight = weight,
            });
            self.candidates.items[candidate_idx].weight += weight;
        }

        return self.status();
    }

    pub fn status(self: *const Election) ElectionStatus {
        if (self.online_weight == 0 or self.candidates.items.len == 0) {
            return .ongoing;
        }

        const top = self.top_two();
        if (top.first == null) return .ongoing;

        const first = self.candidates.items[top.first.?];
        if (first.weight * 3 >= self.online_weight * 2) {
            return .{ .confirmed = first.hash };
        }

        if (top.second) |second_idx| {
            const second = self.candidates.items[second_idx];
            // Fork alert once two candidates both reach at least one third of
            // online weight. This stays below the two-thirds confirmation rule.
            if (first.weight * 3 >= self.online_weight and second.weight * 3 >= self.online_weight) {
                return .fork;
            }
        }

        return .ongoing;
    }

    fn find_candidate_index(self: *const Election, hash: [32]u8) ?usize {
        for (self.candidates.items, 0..) |candidate, i| {
            if (std.mem.eql(u8, &candidate.hash, &hash)) return i;
        }
        return null;
    }

    fn find_ballot_index(self: *const Election, representative: [32]u8) ?usize {
        for (self.ballots.items, 0..) |ballot, i| {
            if (std.mem.eql(u8, &ballot.representative, &representative)) return i;
        }
        return null;
    }

    fn top_two(self: *const Election) struct { first: ?usize, second: ?usize } {
        var best: ?usize = null;
        var next: ?usize = null;

        for (self.candidates.items, 0..) |candidate, i| {
            if (best == null or candidate.weight > self.candidates.items[best.?].weight) {
                next = best;
                best = i;
                continue;
            }

            if (next == null or candidate.weight > self.candidates.items[next.?].weight) {
                next = i;
            }
        }

        return .{
            .first = best,
            .second = next,
        };
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "election: confirms winner at two-thirds quorum" {
    const root = Root{
        .account = [_]u8{0x01} ** 32,
        .previous = [_]u8{0x02} ** 32,
    };

    var election = Election.init(testing.allocator, root, 90);
    defer election.deinit();

    const hash = [_]u8{0x11} ** 32;
    _ = try election.register_candidate(hash);

    const status = try election.add_vote([_]u8{0xAA} ** 32, 60, hash);
    try testing.expectEqualDeep(ElectionStatus{ .confirmed = hash }, status);
}

test "election: representative switching candidates does not double count" {
    const root = Root{
        .account = [_]u8{0x03} ** 32,
        .previous = [_]u8{0x04} ** 32,
    };

    var election = Election.init(testing.allocator, root, 120);
    defer election.deinit();

    const hash_a = [_]u8{0x21} ** 32;
    const hash_b = [_]u8{0x22} ** 32;
    _ = try election.register_candidate(hash_a);
    _ = try election.register_candidate(hash_b);

    _ = try election.add_vote([_]u8{0xCC} ** 32, 50, hash_a);
    _ = try election.add_vote([_]u8{0xCC} ** 32, 50, hash_b);

    try testing.expectEqual(@as(u128, 0), election.candidate_weight(hash_a).?);
    try testing.expectEqual(@as(u128, 50), election.candidate_weight(hash_b).?);
}

test "election: detects fork once two candidates reach one-third weight" {
    const root = Root{
        .account = [_]u8{0x05} ** 32,
        .previous = [_]u8{0x06} ** 32,
    };

    var election = Election.init(testing.allocator, root, 90);
    defer election.deinit();

    const hash_a = [_]u8{0x31} ** 32;
    const hash_b = [_]u8{0x32} ** 32;
    _ = try election.register_candidate(hash_a);
    _ = try election.register_candidate(hash_b);

    _ = try election.add_vote([_]u8{0xD1} ** 32, 30, hash_a);
    const status = try election.add_vote([_]u8{0xD2} ** 32, 30, hash_b);

    try testing.expectEqualDeep(ElectionStatus.fork, status);
}

test "election: register_candidate ignores duplicates" {
    const root = Root{
        .account = [_]u8{0x07} ** 32,
        .previous = [_]u8{0x08} ** 32,
    };

    var election = Election.init(testing.allocator, root, 10);
    defer election.deinit();

    const hash = [_]u8{0x41} ** 32;
    try testing.expect(try election.register_candidate(hash));
    try testing.expect(!(try election.register_candidate(hash)));
    try testing.expectEqual(@as(usize, 1), election.candidate_count());
}

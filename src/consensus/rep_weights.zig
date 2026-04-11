/// Representative weight cache built from the confirmed ledger.
///
/// Weight is derived from the latest confirmed state of every account chain:
/// each confirmed account contributes its confirmed balance to its confirmed
/// representative. The cache keeps both views:
///   - representative -> total delegated weight
///   - account -> latest confirmed delegation (rep + balance)
///
/// This lets the node rebuild from disk on startup and then update incrementally
/// when confirmation height advances.
const std = @import("std");
const block_mod = @import("../types/block.zig");
const store_mod = @import("../store/store.zig");

const StateBlock = block_mod.StateBlock;
const AccountInfo = store_mod.AccountInfo;

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

pub const ConfirmedDelegation = struct {
    representative: [32]u8,
    balance: u128,
};

pub const RepWeights = struct {
    allocator: std.mem.Allocator,
    rep_totals: std.HashMap(Key32, u128, Key32Context(Key32), 80),
    confirmed_accounts: std.HashMap(Key32, ConfirmedDelegation, Key32Context(Key32), 80),

    pub fn init(allocator: std.mem.Allocator) RepWeights {
        return .{
            .allocator = allocator,
            .rep_totals = std.HashMap(Key32, u128, Key32Context(Key32), 80).init(allocator),
            .confirmed_accounts = std.HashMap(Key32, ConfirmedDelegation, Key32Context(Key32), 80).init(allocator),
        };
    }

    pub fn deinit(self: *RepWeights) void {
        self.rep_totals.deinit();
        self.confirmed_accounts.deinit();
    }

    /// Remove all cached state while keeping allocated capacity.
    pub fn clear(self: *RepWeights) void {
        self.rep_totals.clearRetainingCapacity();
        self.confirmed_accounts.clearRetainingCapacity();
    }

    /// Rebuild the cache by scanning accounts and resolving their confirmed
    /// frontier through `confirmation_height`.
    pub fn rebuild(self: *RepWeights, store: anytype) !void {
        const Ctx = struct {
            weights: *RepWeights,
            store: @TypeOf(store),
            err: ?anyerror = null,

            fn on_account(ctx: *@This(), account: [32]u8, info: AccountInfo) void {
                _ = info;
                if (ctx.err != null) return;

                const ch = ctx.store.get_confirmation_height(&account) orelse return;
                if (ch.height == 0) return;

                const row = ctx.store.get_block(&ch.frontier) orelse {
                    ctx.err = error.MissingConfirmedBlock;
                    return;
                };
                const blk = StateBlock.from_bytes(&row.block_bytes);

                ctx.weights.set_confirmed(&account, &blk.representative, blk.balance) catch |err| {
                    ctx.err = err;
                };
            }
        };

        self.clear();

        var ctx = Ctx{
            .weights = self,
            .store = store,
        };
        try store.for_each_account(&ctx, Ctx.on_account);
        if (ctx.err) |err| return err;
    }

    /// Return the current cached voting weight for `representative`.
    pub fn get(self: *const RepWeights, representative: *const [32]u8) u128 {
        return self.rep_totals.get(representative.*) orelse 0;
    }

    /// Total online weight represented by the cache.
    pub fn total_weight(self: *const RepWeights) u128 {
        var total: u128 = 0;
        var it = self.rep_totals.valueIterator();
        while (it.next()) |weight| total += weight.*;
        return total;
    }

    pub fn confirmed_account_count(self: *const RepWeights) usize {
        return self.confirmed_accounts.count();
    }

    /// Update one account's confirmed delegation.
    ///
    /// If the account already had confirmed state, its old weight is removed
    /// from the previous representative before the new delegation is applied.
    pub fn set_confirmed(
        self: *RepWeights,
        account: *const [32]u8,
        representative: *const [32]u8,
        balance: u128,
    ) !void {
        self.remove_confirmed(account);
        if (balance == 0) return;

        try self.confirmed_accounts.put(account.*, .{
            .representative = representative.*,
            .balance = balance,
        });
        try self.add_weight(representative, balance);
    }

    /// Remove one account from the confirmed set.
    pub fn remove_confirmed(self: *RepWeights, account: *const [32]u8) void {
        const removed = self.confirmed_accounts.fetchRemove(account.*) orelse return;
        self.sub_weight(&removed.value.representative, removed.value.balance);
    }

    fn add_weight(self: *RepWeights, representative: *const [32]u8, weight: u128) !void {
        const gop = try self.rep_totals.getOrPut(representative.*);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += weight;
    }

    fn sub_weight(self: *RepWeights, representative: *const [32]u8, weight: u128) void {
        const current = self.rep_totals.getPtr(representative.*) orelse return;
        if (current.* <= weight) {
            _ = self.rep_totals.remove(representative.*);
            return;
        }
        current.* -= weight;
    }
};

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

test "rep_weights: set_confirmed aggregates and reassigns delegated weight" {
    var weights = RepWeights.init(testing.allocator);
    defer weights.deinit();

    const account_a = [_]u8{0x01} ** 32;
    const account_b = [_]u8{0x02} ** 32;
    const rep_a = [_]u8{0xA1} ** 32;
    const rep_b = [_]u8{0xB2} ** 32;

    try weights.set_confirmed(&account_a, &rep_a, 50);
    try weights.set_confirmed(&account_b, &rep_a, 70);

    try testing.expectEqual(@as(u128, 120), weights.get(&rep_a));
    try testing.expectEqual(@as(usize, 2), weights.confirmed_account_count());

    try weights.set_confirmed(&account_b, &rep_b, 30);

    try testing.expectEqual(@as(u128, 50), weights.get(&rep_a));
    try testing.expectEqual(@as(u128, 30), weights.get(&rep_b));
    try testing.expectEqual(@as(u128, 80), weights.total_weight());
}

test "rep_weights: remove_confirmed drops representative weight" {
    var weights = RepWeights.init(testing.allocator);
    defer weights.deinit();

    const account = [_]u8{0x03} ** 32;
    const rep = [_]u8{0xC3} ** 32;

    try weights.set_confirmed(&account, &rep, 99);
    try testing.expectEqual(@as(u128, 99), weights.get(&rep));

    weights.remove_confirmed(&account);
    try testing.expectEqual(@as(u128, 0), weights.get(&rep));
    try testing.expectEqual(@as(usize, 0), weights.confirmed_account_count());
}

test "rep_weights: rebuild reads confirmed frontier instead of current account frontier" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const account = [_]u8{0x11} ** 32;
    const rep_confirmed = [_]u8{0x21} ** 32;
    const rep_unconfirmed = [_]u8{0x31} ** 32;

    const open_blk = test_block(account, block_mod.ZERO_HASH, rep_confirmed, 10, [_]u8{0x41} ** 32);
    const recv_blk = test_block(account, open_blk.hash(), rep_unconfirmed, 20, [_]u8{0x51} ** 32);
    const open_hash = open_blk.hash();
    const recv_hash = recv_blk.hash();

    try store.put_block(&open_hash, .{ .account = account, .block_bytes = open_blk.to_bytes(), .height = 1 });
    try store.put_block(&recv_hash, .{ .account = account, .block_bytes = recv_blk.to_bytes(), .height = 2 });

    try store.put_account(&account, .{
        .frontier = recv_hash,
        .balance = recv_blk.balance,
        .representative = recv_blk.representative,
        .height = 2,
        .modified = 0,
    });
    try store.put_confirmation_height(&account, .{ .height = 1, .frontier = open_hash });

    var weights = RepWeights.init(testing.allocator);
    defer weights.deinit();

    try weights.rebuild(&store);

    try testing.expectEqual(@as(u128, 10), weights.get(&rep_confirmed));
    try testing.expectEqual(@as(u128, 0), weights.get(&rep_unconfirmed));
    try testing.expectEqual(@as(u128, 10), weights.total_weight());
}

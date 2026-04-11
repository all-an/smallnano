/// LedgerPruner — enforces max_blocks_per_account.
///
/// After each block insertion, the ledger calls prune() to trim old blocks
/// from the given account's chain. The pruner never removes a block at or
/// below the account's confirmation height — those are still needed for
/// bootstrap and proof of cementation.
///
/// The pruning watermark (`pruned_height`) is updated so that peers know
/// which blocks this node can no longer serve during bootstrap.
const std = @import("std");

/// Enforce the `max_blocks` limit for `account`.
///
/// Safe prune boundary:
///   keep_from = current_height - max_blocks + 1
///   safe_from = max(keep_from, confirmed_height + 1)
///
/// Blocks with height < safe_from are deleted.
/// Returns the number of blocks deleted (0 if no pruning was needed).
pub fn prune(store: anytype, account: *const [32]u8, max_blocks: u64) !u64 {
    const info = store.get_account(account) orelse return 0;
    const current_height = info.height;

    if (current_height <= max_blocks) return 0;

    // The confirmed height we must not prune past.
    const confirmed_height: u64 = if (store.get_confirmation_height(account)) |ch| ch.height else 0;

    // We want to keep the top `max_blocks` blocks.
    const keep_from = current_height - max_blocks + 1;
    const safe_from = @max(keep_from, confirmed_height + 1);

    if (safe_from <= 1) return 0;

    const deleted = try store.delete_blocks_below(account, safe_from);
    if (deleted > 0) {
        // Update watermark: the highest pruned height is safe_from - 1.
        try store.put_pruned_height(account, safe_from - 1);
    }
    return deleted;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const NullStore = @import("../store/null_store.zig").NullStore;
const store_mod = @import("../store/store.zig");
const block_mod = @import("../types/block.zig");

fn seed_blocks(s: *NullStore, account: [32]u8, count: u64) !void {
    for (1..count + 1) |i| {
        var hash: [32]u8 = [_]u8{0} ** 32;
        hash[0] = @intCast(i & 0xFF);
        hash[1] = @intCast((i >> 8) & 0xFF);
        try s.put_block(&hash, .{
            .account = account,
            .block_bytes = [_]u8{0} ** 216,
            .height = @intCast(i),
        });
    }
    // Update account with the highest frontier.
    var frontier: [32]u8 = [_]u8{0} ** 32;
    frontier[0] = @intCast(count & 0xFF);
    frontier[1] = @intCast((count >> 8) & 0xFF);
    try s.put_account(&account, .{
        .frontier = frontier,
        .balance = 0,
        .representative = [_]u8{0} ** 32,
        .height = count,
        .modified = 0,
    });
}

test "pruner: no pruning when block count at or below max" {
    var s = NullStore.init(testing.allocator);
    defer s.deinit();

    const account = [_]u8{0x01} ** 32;
    try seed_blocks(&s, account, 10);

    const deleted = try prune(&s, &account, 10);
    try testing.expectEqual(@as(u64, 0), deleted);
    try testing.expectEqual(@as(u64, 10), s.get_account_block_count(&account));
}

test "pruner: prunes oldest blocks beyond max" {
    var s = NullStore.init(testing.allocator);
    defer s.deinit();

    const account = [_]u8{0x02} ** 32;
    try seed_blocks(&s, account, 15);

    const deleted = try prune(&s, &account, 10);
    try testing.expectEqual(@as(u64, 5), deleted);
    try testing.expectEqual(@as(u64, 10), s.get_account_block_count(&account));
}

test "pruner: updates pruned_height watermark after pruning" {
    var s = NullStore.init(testing.allocator);
    defer s.deinit();

    const account = [_]u8{0x03} ** 32;
    try seed_blocks(&s, account, 12);

    _ = try prune(&s, &account, 10);
    // current_height=12, max=10 → keep_from=3, deleted heights 1 and 2 → watermark=2
    try testing.expectEqual(@as(u64, 2), s.get_pruned_height(&account));
}

test "pruner: never prunes below confirmation height" {
    var s = NullStore.init(testing.allocator);
    defer s.deinit();

    const account = [_]u8{0x04} ** 32;
    try seed_blocks(&s, account, 20);

    // Confirm up to height 15 — pruner must keep these.
    try s.put_confirmation_height(&account, .{ .height = 15, .frontier = [_]u8{0} ** 32 });

    // current=20, max=5, keep_from=16, confirmed=15, safe_from=max(16,16)=16
    // delete heights < 16, so heights 1..15 = 15 blocks deleted
    const deleted = try prune(&s, &account, 5);
    try testing.expectEqual(@as(u64, 15), deleted);
    try testing.expectEqual(@as(u64, 5), s.get_account_block_count(&account));
}

test "pruner: confirmation height forces smaller prune window" {
    var s = NullStore.init(testing.allocator);
    defer s.deinit();

    const account = [_]u8{0x05} ** 32;
    try seed_blocks(&s, account, 20);

    // Confirm up to height 18 — very recent, limits pruning heavily.
    try s.put_confirmation_height(&account, .{ .height = 18, .frontier = [_]u8{0} ** 32 });

    // max_blocks=5 would want to keep heights 16..20 (prune below 16).
    // But confirmed=18 → safe_from = max(16, 19) = 19.
    // So we can only delete heights 1..18 = 18 blocks.
    const deleted = try prune(&s, &account, 5);
    try testing.expectEqual(@as(u64, 18), deleted);
    try testing.expectEqual(@as(u64, 2), s.get_account_block_count(&account));
}

test "pruner: no-op for unknown account" {
    var s = NullStore.init(testing.allocator);
    defer s.deinit();

    const account = [_]u8{0xFF} ** 32;
    const deleted = try prune(&s, &account, 10);
    try testing.expectEqual(@as(u64, 0), deleted);
}

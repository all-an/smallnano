/// BlockInserter — applies a validated block to the store.
///
/// Only call this after validate() has returned successfully.
/// The caller (Ledger) is responsible for wrapping this in a transaction
/// (begin_txn / commit_txn / rollback_txn on the store).
///
/// Side-effects by block type:
///   open    — put_account, put_block, delete_pending (consumes receive)
///   send    — put_account, put_block, put_pending    (creates receivable)
///   receive — put_account, put_block, delete_pending (consumes receive)
///   change  — put_account, put_block
const std = @import("std");
const block_mod = @import("../types/block.zig");
const store_mod = @import("../store/store.zig");
const validator = @import("validator.zig");

pub const StateBlock = block_mod.StateBlock;

/// Pre-computed data the inserter needs (derived by the Ledger before calling).
pub const InsertCtx = struct {
    /// Block hash (to avoid re-hashing).
    hash: [32]u8,
    /// Account balance before this block (0 for open blocks).
    prior_balance: u128,
    /// Chain height before this block (0 for open blocks).
    prior_height: u64,
    /// Unix timestamp (seconds) to record as `modified`.
    now: i64,
};

/// Write `blk` and its side-effects to `store`.
/// Must be called within an open transaction.
pub fn insert(store: anytype, blk: *const StateBlock, ctx: InsertCtx) !void {
    const new_height = ctx.prior_height + 1;
    const btype = validator.classify(blk, ctx.prior_balance);

    // Write the block.
    try store.put_block(&ctx.hash, store_mod.BlockRow{
        .account = blk.account,
        .block_bytes = blk.to_bytes(),
        .height = new_height,
    });

    // Update (or create) the account info.
    try store.put_account(&blk.account, store_mod.AccountInfo{
        .frontier = ctx.hash,
        .balance = blk.balance,
        .representative = blk.representative,
        .height = new_height,
        .modified = ctx.now,
    });

    // Pending side-effects.
    switch (btype) {
        .open, .receive => {
            // Consume the pending entry. link = send_hash.
            try store.delete_pending(&blk.account, &blk.link);
        },
        .send => {
            // Create a pending entry for the recipient. link = recipient pubkey.
            const amount = ctx.prior_balance - blk.balance;
            try store.put_pending(&blk.link, &ctx.hash, store_mod.PendingInfo{
                .source = blk.account,
                .amount = amount,
            });
        },
        .change => {}, // no pending changes
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const NullStore = @import("../store/null_store.zig").NullStore;

fn test_store() NullStore {
    return NullStore.init(testing.allocator);
}

const SEND_HASH = [_]u8{0x99} ** 32;
const SENDER_PK = [_]u8{0xAA} ** 32;

fn test_open_block(account: [32]u8) StateBlock {
    return StateBlock{
        .account = account,
        .previous = block_mod.ZERO_HASH,
        .representative = account,
        .balance = 1_000_000,
        .link = SEND_HASH, // link = send_hash for open
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
}

test "inserter: open block creates account and consumes pending" {
    var s = test_store();
    defer s.deinit();

    const account = [_]u8{0x01} ** 32;
    const blk = test_open_block(account);
    const h = blk.hash();

    // Seed a pending entry so delete_pending has something to remove.
    try s.put_pending(&account, &SEND_HASH, .{ .source = SENDER_PK, .amount = 1_000_000 });

    try insert(&s, &blk, .{ .hash = h, .prior_balance = 0, .prior_height = 0, .now = 100 });

    // Account created with correct frontier and balance.
    const info = s.get_account(&account).?;
    try testing.expectEqual(h, info.frontier);
    try testing.expectEqual(@as(u128, 1_000_000), info.balance);
    try testing.expectEqual(@as(u64, 1), info.height);

    // Block stored.
    try testing.expect(s.get_block(&h) != null);

    // Pending entry consumed.
    try testing.expect(s.get_pending(&account, &SEND_HASH) == null);
}

test "inserter: send block decreases balance and creates pending" {
    var s = test_store();
    defer s.deinit();

    const sender = [_]u8{0x02} ** 32;
    const recipient = [_]u8{0x03} ** 32;
    const prev = [_]u8{0x10} ** 32;
    const prior_balance: u128 = 5_000_000;
    const new_balance: u128 = 3_000_000;
    const amount_sent = prior_balance - new_balance; // 2_000_000

    const blk = StateBlock{
        .account = sender,
        .previous = prev,
        .representative = sender,
        .balance = new_balance,
        .link = recipient, // link = recipient pubkey for send
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    const h = blk.hash();

    try insert(&s, &blk, .{ .hash = h, .prior_balance = prior_balance, .prior_height = 1, .now = 200 });

    // Sender account updated.
    const info = s.get_account(&sender).?;
    try testing.expectEqual(new_balance, info.balance);
    try testing.expectEqual(@as(u64, 2), info.height);

    // Pending entry created for recipient.
    const p = s.get_pending(&recipient, &h).?;
    try testing.expectEqual(amount_sent, p.amount);
    try testing.expectEqual(sender, p.source);
}

test "inserter: receive block increases balance and consumes pending" {
    var s = test_store();
    defer s.deinit();

    const account = [_]u8{0x04} ** 32;
    const prev = [_]u8{0x20} ** 32;
    const incoming_send_hash = [_]u8{0x50} ** 32;
    const prior_balance: u128 = 2_000_000;
    const pending_amount: u128 = 1_000_000;

    // Seed the pending entry.
    try s.put_pending(&account, &incoming_send_hash, .{ .source = SENDER_PK, .amount = pending_amount });

    const blk = StateBlock{
        .account = account,
        .previous = prev,
        .representative = account,
        .balance = prior_balance + pending_amount,
        .link = incoming_send_hash, // link = send_hash for receive
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    const h = blk.hash();

    try insert(&s, &blk, .{ .hash = h, .prior_balance = prior_balance, .prior_height = 2, .now = 300 });

    const info = s.get_account(&account).?;
    try testing.expectEqual(prior_balance + pending_amount, info.balance);
    try testing.expectEqual(@as(u64, 3), info.height);

    // Pending consumed.
    try testing.expect(s.get_pending(&account, &incoming_send_hash) == null);
}

test "inserter: change block updates representative only" {
    var s = test_store();
    defer s.deinit();

    const account = [_]u8{0x05} ** 32;
    const prev = [_]u8{0x30} ** 32;
    const new_rep = [_]u8{0x60} ** 32;
    const balance: u128 = 3_000_000;

    const blk = StateBlock{
        .account = account,
        .previous = prev,
        .representative = new_rep,
        .balance = balance, // unchanged
        .link = block_mod.ZERO_HASH,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    const h = blk.hash();

    try insert(&s, &blk, .{ .hash = h, .prior_balance = balance, .prior_height = 3, .now = 400 });

    const info = s.get_account(&account).?;
    try testing.expectEqual(balance, info.balance);
    try testing.expectEqual(new_rep, info.representative);
    try testing.expectEqual(@as(u64, 4), info.height);
}

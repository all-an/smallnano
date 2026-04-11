/// Ledger — coordinates store, validator, inserter, and pruner.
///
/// The Ledger is the single authoritative gateway for all block processing.
/// It is generic over the store type (comptime duck-typing) so that the same
/// code runs with NullStore in tests and SqliteStore in production.
///
/// Usage:
///   var ledger = Ledger(NullStore).init(&my_store, 1000);
///   const result = try ledger.process(&block);
const std = @import("std");
const block_mod = @import("../types/block.zig");
const store_mod = @import("../store/store.zig");
const validator = @import("validator.zig");
const inserter = @import("inserter.zig");
const pruner = @import("pruner.zig");

pub const StateBlock = block_mod.StateBlock;
pub const BlockType = validator.BlockType;
pub const BlockError = validator.BlockError;

/// Result returned by process() on success.
pub const ProcessResult = struct {
    /// Hash of the accepted block.
    hash: [32]u8,
    /// Classified block type.
    block_type: BlockType,
    /// New chain height for this account after the block.
    new_height: u64,
};

/// Return a Ledger type bound to StoreType.
pub fn Ledger(comptime StoreType: type) type {
    return struct {
        const Self = @This();

        store: *StoreType,
        max_blocks_per_account: u64,

        pub fn init(s: *StoreType, max_blocks_per_account: u64) Self {
            return .{ .store = s, .max_blocks_per_account = max_blocks_per_account };
        }

        // ── Core processing ───────────────────────────────────────────────────

        /// Validate, insert, and (if needed) prune a block.
        /// Returns ProcessResult on success or a BlockError (or store error) on failure.
        pub fn process(self: *Self, blk: *const StateBlock) !ProcessResult {
            const h = blk.hash();

            // Pre-fetch context for the validator.
            const account_info = self.store.get_account(&blk.account);
            const already_exists = self.store.get_block(&h) != null;
            const prior_balance: u128 = if (account_info) |a| a.balance else 0;
            const prior_height: u64 = if (account_info) |a| a.height else 0;

            // Only fetch pending for open/receive blocks.
            const btype = validator.classify(blk, prior_balance);
            const pending: ?store_mod.PendingInfo = switch (btype) {
                .open, .receive => self.store.get_pending(&blk.account, &blk.link),
                .send, .change => null,
            };

            // Validate (pure logic, no store writes).
            try validator.validate(blk, .{
                .account = account_info,
                .already_exists = already_exists,
                .pending = pending,
            });

            // Insert atomically.
            const now = std.time.timestamp();
            try self.store.begin_txn();
            errdefer self.store.rollback_txn();
            try inserter.insert(self.store, blk, .{
                .hash = h,
                .prior_balance = prior_balance,
                .prior_height = prior_height,
                .now = now,
            });
            try self.store.commit_txn();

            // Prune if over limit (best-effort; outside the insert transaction).
            _ = try pruner.prune(self.store, &blk.account, self.max_blocks_per_account);

            return ProcessResult{
                .hash = h,
                .block_type = btype,
                .new_height = prior_height + 1,
            };
        }

        // ── Queries ───────────────────────────────────────────────────────────

        pub fn get_account_info(self: *Self, account: *const [32]u8) ?store_mod.AccountInfo {
            return self.store.get_account(account);
        }

        pub fn get_block(self: *Self, hash: *const [32]u8) ?StateBlock {
            const row = self.store.get_block(hash) orelse return null;
            return StateBlock.from_bytes(&row.block_bytes);
        }

        pub fn get_pending(
            self: *Self,
            recipient: *const [32]u8,
            send_hash: *const [32]u8,
        ) ?store_mod.PendingInfo {
            return self.store.get_pending(recipient, send_hash);
        }

        pub fn confirmation_height(self: *Self, account: *const [32]u8) u64 {
            return if (self.store.get_confirmation_height(account)) |ch| ch.height else 0;
        }
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const NullStore = @import("../store/null_store.zig").NullStore;
const ed25519 = @import("../crypto/ed25519.zig");
const work_mod = @import("../crypto/work.zig");

const ZERO_HASH = block_mod.ZERO_HASH;

/// Build a fully valid signed + PoW'd open block for a given keypair.
fn make_valid_open(kp: ed25519.KeyPair, amount: u128, send_hash: [32]u8) !StateBlock {
    var blk = StateBlock{
        .account = kp.public,
        .previous = ZERO_HASH,
        .representative = kp.public,
        .balance = amount,
        .link = send_hash,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    const h = blk.hash();
    blk.signature = try ed25519.sign(&h, &kp.secret);
    blk.work = work_mod.generate(&h, work_mod.THRESHOLD_RECEIVE, 1);
    return blk;
}

/// Build a fully valid signed + PoW'd receive block.
fn make_valid_receive(
    kp: ed25519.KeyPair,
    previous: [32]u8,
    prior_balance: u128,
    pending_amount: u128,
    send_hash: [32]u8,
) !StateBlock {
    var blk = StateBlock{
        .account = kp.public,
        .previous = previous,
        .representative = kp.public,
        .balance = prior_balance + pending_amount,
        .link = send_hash,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    const h = blk.hash();
    blk.signature = try ed25519.sign(&h, &kp.secret);
    blk.work = work_mod.generate(&h, work_mod.THRESHOLD_RECEIVE, 1);
    return blk;
}

// NOTE: change block test omitted — uses THRESHOLD_SEND (~5s).
// Change insertion is covered by inserter.zig; PoW by work.zig.

test "ledger: rejects duplicate block" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x13} ** 32));
    const send_hash = [_]u8{0x23} ** 32;
    const amount: u128 = 1_000_000_000_000_000_000_000_000;

    var s = NullStore.init(testing.allocator);
    defer s.deinit();
    try s.put_pending(&kp.public, &send_hash, .{ .source = [_]u8{0x33} ** 32, .amount = amount });

    var ledger = Ledger(NullStore).init(&s, 1000);
    const blk = try make_valid_open(kp, amount, send_hash);
    _ = try ledger.process(&blk);

    // Re-seed pending so the second attempt reaches the dedup check.
    try s.put_pending(&kp.public, &send_hash, .{ .source = [_]u8{0x33} ** 32, .amount = amount });
    try testing.expectError(BlockError.AlreadyExists, ledger.process(&blk));
}

test "ledger: pruning enforces max_blocks_per_account" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x14} ** 32));
    const send_hash = [_]u8{0x24} ** 32;
    const amount: u128 = 1_000_000_000_000_000_000_000_000;

    var s = NullStore.init(testing.allocator);
    defer s.deinit();
    try s.put_pending(&kp.public, &send_hash, .{ .source = [_]u8{0x34} ** 32, .amount = amount });

    // max_blocks_per_account = 1 — only the latest block is kept.
    var ledger = Ledger(NullStore).init(&s, 1);

    const open_blk = try make_valid_open(kp, amount, send_hash);
    _ = try ledger.process(&open_blk);
    const open_hash = open_blk.hash();

    // Receive a second block — open block should be pruned.
    const recv_send_hash = [_]u8{0x44} ** 32;
    const amount2: u128 = 500_000_000_000_000_000_000_000;
    try s.put_pending(&kp.public, &recv_send_hash, .{ .source = [_]u8{0x54} ** 32, .amount = amount2 });

    const recv_blk = try make_valid_receive(kp, open_hash, amount, amount2, recv_send_hash);
    _ = try ledger.process(&recv_blk);

    // Only 1 block should remain.
    try testing.expectEqual(@as(u64, 1), s.get_account_block_count(&kp.public));
    // Watermark set.
    try testing.expectEqual(@as(u64, 1), s.get_pruned_height(&kp.public));
}

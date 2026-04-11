/// BlockValidator — pure, zero-I/O block validation for smallnano.
///
/// All ledger state needed for validation is pre-fetched by the caller
/// (Ledger) and passed in via ValidateCtx. The validator itself does no
/// store reads or writes — it is pure logic that can be unit-tested
/// without any I/O setup.
///
/// Validation order:
///   1. Burn account guard
///   2. Ed25519 signature
///   3. Deduplication
///   4. Account-existence consistency (open ↔ new account, non-open ↔ existing)
///   5. Frontier match (non-open blocks)
///   6. Proof-of-work threshold
///   7. Balance / pending integrity
const std = @import("std");
const block_mod = @import("../types/block.zig");
const store_mod = @import("../store/store.zig");
const ed25519 = @import("../crypto/ed25519.zig");
const work_mod = @import("../crypto/work.zig");

pub const StateBlock = block_mod.StateBlock;
pub const BlockHash = block_mod.BlockHash;
pub const ZERO_HASH = block_mod.ZERO_HASH;
pub const AccountInfo = store_mod.AccountInfo;
pub const PendingInfo = store_mod.PendingInfo;

// ── Block classification ──────────────────────────────────────────────────────

/// The four block operations encoded as a state block.
pub const BlockType = enum {
    /// First block in an account chain. previous == ZERO_HASH; balance > 0.
    open,
    /// Balance decreases. link = recipient pubkey.
    send,
    /// Balance increases. link = source send_hash.
    receive,
    /// Balance unchanged, representative updated. link unused.
    change,
};

/// Classify a block given the account's prior balance (0 for new accounts).
pub fn classify(blk: *const StateBlock, prior_balance: u128) BlockType {
    if (blk.is_open()) return .open;
    if (blk.balance < prior_balance) return .send;
    if (blk.balance > prior_balance) return .receive;
    return .change;
}

// ── Errors ────────────────────────────────────────────────────────────────────

pub const BlockError = error{
    /// block.account is all-zeros (burn/null address).
    BurnAccount,
    /// Ed25519 signature over block hash failed verification.
    InvalidSignature,
    /// A block with this hash already exists in the ledger.
    AlreadyExists,
    /// Non-open block but the account has not been opened yet.
    AccountNotOpen,
    /// Open block but the account already has a chain (would be a fork).
    Fork,
    /// block.previous does not match the account's current frontier.
    FrontierMismatch,
    /// Proof-of-work is below the required threshold.
    InsufficientWork,
    /// Open/receive block but no pending entry was found.
    PendingNotFound,
    /// Balance delta does not match the pending amount.
    PendingAmountMismatch,
};

// ── Validation context (pre-fetched by Ledger) ────────────────────────────────

/// All store state needed to validate one block.
/// The Ledger fetches this before calling validate().
pub const ValidateCtx = struct {
    /// Current account info, or null if this account has never been opened.
    account: ?AccountInfo,
    /// True if a block with this exact hash already exists in the ledger.
    already_exists: bool,
    /// Pending entry for open/receive blocks (keyed by block.link as send_hash).
    /// Must be non-null when the block is open or receive.
    pending: ?PendingInfo,
};

// ── validate ─────────────────────────────────────────────────────────────────

/// Validate `blk` against `ctx`. Returns void on success or a BlockError.
/// The caller must have filled ctx by querying the store before calling this.
pub fn validate(blk: *const StateBlock, ctx: ValidateCtx) BlockError!void {
    // 1. Burn account.
    if (std.mem.allEqual(u8, &blk.account, 0)) return BlockError.BurnAccount;

    // 2. Ed25519 signature over the canonical block hash.
    const h = blk.hash();
    ed25519.verify(&h, &blk.signature, &blk.account) catch return BlockError.InvalidSignature;

    // 3. Deduplication.
    if (ctx.already_exists) return BlockError.AlreadyExists;

    const prior_balance: u128 = if (ctx.account) |a| a.balance else 0;
    const btype = classify(blk, prior_balance);

    // 4. Account-existence consistency.
    switch (btype) {
        .open => if (ctx.account != null) return BlockError.Fork,
        .send, .receive, .change => if (ctx.account == null) return BlockError.AccountNotOpen,
    }

    // 5. Frontier match (non-open only).
    if (btype != .open) {
        if (!std.mem.eql(u8, &blk.previous, &ctx.account.?.frontier)) {
            return BlockError.FrontierMismatch;
        }
    }

    // 6. Proof-of-work.
    const threshold: u64 = switch (btype) {
        .open, .receive => work_mod.THRESHOLD_RECEIVE,
        .send, .change => work_mod.THRESHOLD_SEND,
    };
    if (!work_mod.is_valid(blk.work, &h, threshold)) return BlockError.InsufficientWork;

    // 7. Balance / pending integrity.
    switch (btype) {
        .open => {
            const p = ctx.pending orelse return BlockError.PendingNotFound;
            if (blk.balance != p.amount) return BlockError.PendingAmountMismatch;
        },
        .receive => {
            const p = ctx.pending orelse return BlockError.PendingNotFound;
            const delta = blk.balance - prior_balance;
            if (delta != p.amount) return BlockError.PendingAmountMismatch;
        },
        .send, .change => {}, // no pending to verify
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

// Helper: build and sign a block (no work yet).
fn make_open_block(kp: ed25519.KeyPair, pending_amount: u128, send_hash: [32]u8) StateBlock {
    var blk = StateBlock{
        .account = kp.public,
        .previous = ZERO_HASH,
        .representative = kp.public,
        .balance = pending_amount,
        .link = send_hash,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    const h = blk.hash();
    blk.signature = ed25519.sign(&h, &kp.secret) catch unreachable;
    return blk;
}

fn make_send_block(
    kp: ed25519.KeyPair,
    previous: [32]u8,
    frontier: [32]u8,
    prior_balance: u128,
    new_balance: u128,
    recipient: [32]u8,
) StateBlock {
    _ = frontier;
    var blk = StateBlock{
        .account = kp.public,
        .previous = previous,
        .representative = kp.public,
        .balance = new_balance,
        .link = recipient,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    _ = prior_balance;
    const h = blk.hash();
    blk.signature = ed25519.sign(&h, &kp.secret) catch unreachable;
    return blk;
}

fn make_receive_block(
    kp: ed25519.KeyPair,
    previous: [32]u8,
    prior_balance: u128,
    new_balance: u128,
    send_hash: [32]u8,
) StateBlock {
    var blk = StateBlock{
        .account = kp.public,
        .previous = previous,
        .representative = kp.public,
        .balance = new_balance,
        .link = send_hash,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    _ = prior_balance;
    const h = blk.hash();
    blk.signature = ed25519.sign(&h, &kp.secret) catch unreachable;
    return blk;
}

fn make_change_block(
    kp: ed25519.KeyPair,
    previous: [32]u8,
    balance: u128,
    new_rep: [32]u8,
) StateBlock {
    var blk = StateBlock{
        .account = kp.public,
        .previous = previous,
        .representative = new_rep,
        .balance = balance,
        .link = ZERO_HASH,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    const h = blk.hash();
    blk.signature = ed25519.sign(&h, &kp.secret) catch unreachable;
    return blk;
}

fn dummy_account_info(frontier: [32]u8, balance: u128, height: u64) AccountInfo {
    return .{
        .frontier = frontier,
        .balance = balance,
        .representative = [_]u8{0x02} ** 32,
        .height = height,
        .modified = 0,
    };
}

test "validator: rejects burn account" {
    const blk = StateBlock{
        .account = [_]u8{0} ** 32, // burn address
        .previous = ZERO_HASH,
        .representative = [_]u8{0x01} ** 32,
        .balance = 1000,
        .link = [_]u8{0x11} ** 32,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    try testing.expectError(BlockError.BurnAccount, validate(&blk, .{
        .account = null,
        .already_exists = false,
        .pending = null,
    }));
}

test "validator: rejects invalid signature" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x01} ** 32));
    var blk = make_open_block(kp, 5000, [_]u8{0x22} ** 32);
    blk.signature = [_]u8{0xFF} ** 64; // corrupt the signature
    try testing.expectError(BlockError.InvalidSignature, validate(&blk, .{
        .account = null,
        .already_exists = false,
        .pending = null,
    }));
}

test "validator: rejects duplicate block" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x02} ** 32));
    const blk = make_open_block(kp, 5000, [_]u8{0x22} ** 32); // work=0, fails at dedup before PoW
    try testing.expectError(BlockError.AlreadyExists, validate(&blk, .{
        .account = null,
        .already_exists = true, // already in ledger
        .pending = .{ .source = [_]u8{0xAA} ** 32, .amount = 5000 },
    }));
}

test "validator: rejects non-open block for unopened account" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x03} ** 32));
    const prev = [_]u8{0x33} ** 32;
    const blk = make_receive_block(kp, prev, 0, 5000, [_]u8{0x44} ** 32); // work=0, fails before PoW
    try testing.expectError(BlockError.AccountNotOpen, validate(&blk, .{
        .account = null, // account does not exist
        .already_exists = false,
        .pending = .{ .source = [_]u8{0xBB} ** 32, .amount = 5000 },
    }));
}

test "validator: rejects open block for already-existing account (fork)" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x04} ** 32));
    const frontier = [_]u8{0x44} ** 32;
    const blk = make_open_block(kp, 5000, [_]u8{0x55} ** 32); // work=0, fails before PoW
    try testing.expectError(BlockError.Fork, validate(&blk, .{
        .account = dummy_account_info(frontier, 5000, 1), // account already open
        .already_exists = false,
        .pending = .{ .source = [_]u8{0xCC} ** 32, .amount = 5000 },
    }));
}

test "validator: rejects frontier mismatch" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x05} ** 32));
    const old_frontier = [_]u8{0x55} ** 32;
    const wrong_previous = [_]u8{0x66} ** 32; // doesn't match frontier
    const blk = make_receive_block(kp, wrong_previous, 5000, 10000, [_]u8{0x77} ** 32); // work=0, fails before PoW
    try testing.expectError(BlockError.FrontierMismatch, validate(&blk, .{
        .account = dummy_account_info(old_frontier, 5000, 1),
        .already_exists = false,
        .pending = .{ .source = [_]u8{0xDD} ** 32, .amount = 5000 },
    }));
}

test "validator: rejects insufficient work" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x06} ** 32));
    var blk = make_open_block(kp, 5000, [_]u8{0x22} ** 32);
    blk.work = 0; // zero is never a valid PoW at any real threshold
    try testing.expectError(BlockError.InsufficientWork, validate(&blk, .{
        .account = null,
        .already_exists = false,
        .pending = .{ .source = [_]u8{0xEE} ** 32, .amount = 5000 },
    }));
}

test "validator: rejects open block with no pending" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x07} ** 32));
    var blk = make_open_block(kp, 5000, [_]u8{0x22} ** 32);
    blk.work = work_mod.generate(&blk.hash(), work_mod.THRESHOLD_RECEIVE, 1);
    try testing.expectError(BlockError.PendingNotFound, validate(&blk, .{
        .account = null,
        .already_exists = false,
        .pending = null, // no pending entry
    }));
}

test "validator: rejects open block with wrong pending amount" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x08} ** 32));
    var blk = make_open_block(kp, 5000, [_]u8{0x22} ** 32);
    blk.work = work_mod.generate(&blk.hash(), work_mod.THRESHOLD_RECEIVE, 1);
    try testing.expectError(BlockError.PendingAmountMismatch, validate(&blk, .{
        .account = null,
        .already_exists = false,
        .pending = .{ .source = [_]u8{0xFF} ** 32, .amount = 9999 }, // wrong amount
    }));
}

test "validator: rejects receive block with wrong pending amount" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x09} ** 32));
    const frontier = [_]u8{0x11} ** 32;
    var blk = make_receive_block(kp, frontier, 1000, 2000, [_]u8{0x33} ** 32);
    blk.work = work_mod.generate(&blk.hash(), work_mod.THRESHOLD_RECEIVE, 1);
    // delta = 1000 but pending says 999
    try testing.expectError(BlockError.PendingAmountMismatch, validate(&blk, .{
        .account = dummy_account_info(frontier, 1000, 1),
        .already_exists = false,
        .pending = .{ .source = [_]u8{0xFF} ** 32, .amount = 999 },
    }));
}

test "validator: accepts valid open block" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x0A} ** 32));
    const send_hash = [_]u8{0x22} ** 32;
    const amount: u128 = 1_000_000_000_000_000_000_000_000; // 1 smn
    var blk = make_open_block(kp, amount, send_hash);
    blk.work = work_mod.generate(&blk.hash(), work_mod.THRESHOLD_RECEIVE, 1);

    try validate(&blk, .{
        .account = null,
        .already_exists = false,
        .pending = .{ .source = [_]u8{0x33} ** 32, .amount = amount },
    });
}

test "validator: accepts valid receive block" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x0B} ** 32));
    const frontier = [_]u8{0x44} ** 32;
    const prior_balance: u128 = 1_000_000_000_000_000_000_000_000;
    const pending_amount: u128 = 500_000_000_000_000_000_000_000;
    var blk = make_receive_block(kp, frontier, prior_balance, prior_balance + pending_amount, [_]u8{0x55} ** 32);
    blk.work = work_mod.generate(&blk.hash(), work_mod.THRESHOLD_RECEIVE, 1);

    try validate(&blk, .{
        .account = dummy_account_info(frontier, prior_balance, 2),
        .already_exists = false,
        .pending = .{ .source = [_]u8{0x66} ** 32, .amount = pending_amount },
    });
}

// NOTE: "accepts valid change block" is intentionally omitted here.
// Change blocks require THRESHOLD_SEND PoW (~5s per test run).
// PoW correctness is already covered by work.zig tests.
// Change block insertion is covered by ledger.zig integration tests.

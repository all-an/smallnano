/// Store interface for smallnano.
///
/// The store is the only layer that touches the disk. All ledger logic above
/// it speaks this interface; swapping the implementation (SQLite vs. in-memory)
/// requires no changes to ledger code.
///
/// Zig does not have runtime interfaces, so we use a comptime "duck-typed"
/// VTable approach: any struct that has the required method signatures is a
/// valid Store. Call `Store.from(impl_ptr)` to obtain a type-erased Store.
///
/// Required methods on the implementation type (all must be present):
///
///   open(path: []const u8) !void
///   close() void
///   migrate() !void
///
///   -- Accounts --
///   get_account(account: *const [32]u8) ?AccountInfo
///   put_account(account: *const [32]u8, info: AccountInfo) !void
///
///   -- Blocks --
///   get_block(hash: *const [32]u8) ?BlockRow
///   get_block_by_height(account: *const [32]u8, height: u64) ?BlockRow
///   put_block(hash: *const [32]u8, row: BlockRow) !void
///   get_account_block_count(account: *const [32]u8) u64
///   delete_blocks_below(account: *const [32]u8, height: u64) !u64
///
///   -- Pending --
///   get_pending(recipient: *const [32]u8, send_hash: *const [32]u8) ?PendingInfo
///   put_pending(recipient: *const [32]u8, send_hash: *const [32]u8, info: PendingInfo) !void
///   delete_pending(recipient: *const [32]u8, send_hash: *const [32]u8) !void
///
///   -- Confirmation height --
///   get_confirmation_height(account: *const [32]u8) ?ConfirmationHeight
///   put_confirmation_height(account: *const [32]u8, ch: ConfirmationHeight) !void
///
///   -- Peers --
///   get_peers(allocator: Allocator, out: *std.ArrayList(PeerRow)) !void
///   put_peer(address: []const u8, last_seen: i64) !void
///   delete_stale_peers(older_than: i64) !void
///
///   -- Pruning watermark --
///   get_pruned_height(account: *const [32]u8) u64
///   put_pruned_height(account: *const [32]u8, height: u64) !void
///
///   -- Meta --
///   get_meta(key: []const u8, buf: []u8) ?[]u8
///   put_meta(key: []const u8, value: []const u8) !void
///
///   -- Iteration (for bootstrap / rep weight scan) --
///   for_each_account(ctx: anytype, cb: fn(@TypeOf(ctx), [32]u8, AccountInfo) void) !void
///   for_each_confirmed_account(ctx: anytype, cb: fn(@TypeOf(ctx), [32]u8, AccountInfo) void) !void
const std = @import("std");

// ── Row types (shared by all Store implementations) ──────────────────────────

pub const AccountInfo = struct {
    /// Hash of the latest block in this account's chain.
    frontier: [32]u8,
    /// Current balance in raw units.
    balance: u128,
    /// Delegated representative public key.
    representative: [32]u8,
    /// Number of blocks in this account's chain (open block = height 1).
    height: u64,
    /// Unix timestamp (seconds) of the most recent block.
    modified: i64,
};

pub const BlockRow = struct {
    /// The account that owns this block.
    account: [32]u8,
    /// Raw serialised 216-byte StateBlock.
    block_bytes: [216]u8,
    /// Block height within the account chain (1 = open block).
    height: u64,
};

pub const PendingInfo = struct {
    /// Account that sent the funds.
    source: [32]u8,
    /// Amount in raw units.
    amount: u128,
};

pub const ConfirmationHeight = struct {
    height: u64,
    /// Hash of the block at this confirmed height.
    frontier: [32]u8,
};

pub const PeerRow = struct {
    address: []u8, // owned by the caller's arena / ArrayList backing store
    last_seen: i64,
};

// ── Tests ─────────────────────────────────────────────────────────────────────
// (No logic to test here — the interface types are tested via implementations.)

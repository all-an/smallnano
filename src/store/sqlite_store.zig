/// SqliteStore — the production store backed by SQLite 3.47.
///
/// Features:
///   - WAL mode: readers never block writers
///   - PRAGMA synchronous = NORMAL: safe for node use, ~2× faster than FULL
///   - 16 MB page cache (configurable via SQLITE_DEFAULT_CACHE_SIZE at compile time)
///   - Sequential migration system: each migration is atomic
///   - All binary keys/values stored as BLOB; amounts as 16-byte big-endian BLOB
///
/// Thread safety: access from a single thread only (SQLITE_THREADSAFE=0 at
/// compile time; the node serialises all store access through one worker).
const std = @import("std");
const store = @import("store.zig");
const c = @cImport(@cInclude("sqlite3.h"));

pub const AccountInfo = store.AccountInfo;
pub const BlockRow = store.BlockRow;
pub const PendingInfo = store.PendingInfo;
pub const ConfirmationHeight = store.ConfirmationHeight;
pub const PeerRow = store.PeerRow;

// ── Errors ────────────────────────────────────────────────────────────────────

pub const SqliteError = error{
    Open,
    Prepare,
    Step,
    Bind,
    Exec,
    Migrate,
};

// ── SqliteStore ───────────────────────────────────────────────────────────────

pub const SqliteStore = struct {
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3,

    pub fn init(allocator: std.mem.Allocator) SqliteStore {
        return .{ .allocator = allocator, .db = null };
    }

    pub fn deinit(self: *SqliteStore) void {
        self.close();
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    /// Open (or create) the database at `path`. Enables WAL mode.
    pub fn open(self: *SqliteStore, path: []const u8) SqliteError!void {
        var path_z: [4096]u8 = undefined;
        if (path.len >= path_z.len) return SqliteError.Open;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const rc = c.sqlite3_open_v2(
            @ptrCast(&path_z),
            &self.db,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX,
            null,
        );
        if (rc != c.SQLITE_OK) {
            if (self.db) |db| _ = c.sqlite3_close(db);
            self.db = null;
            return SqliteError.Open;
        }

        // Configure for WAL mode + performance pragmas.
        try self.exec("PRAGMA journal_mode=WAL");
        try self.exec("PRAGMA synchronous=NORMAL");
        try self.exec("PRAGMA foreign_keys=ON");
        try self.exec("PRAGMA busy_timeout=5000");
    }

    pub fn close(self: *SqliteStore) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    /// Run pending schema migrations. Each migration is idempotent and atomic.
    pub fn migrate(self: *SqliteStore) SqliteError!void {
        // Create the meta table first so we can read schema_version.
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS _meta (
            \\  key   TEXT PRIMARY KEY NOT NULL,
            \\  value TEXT NOT NULL
            \\) STRICT
        );

        const version = self.schema_version();
        if (version < 1) try self.migration_v1();
    }

    // ── Accounts ─────────────────────────────────────────────────────────────

    pub fn get_account(self: *SqliteStore, account: *const [32]u8) ?AccountInfo {
        const sql = "SELECT frontier,balance,representative,height,modified FROM accounts WHERE account=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_blob(stmt, 1, account, 32, c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        return AccountInfo{
            .frontier = blob32(stmt, 0),
            .balance = blob_u128(stmt, 1),
            .representative = blob32(stmt, 2),
            .height = @intCast(c.sqlite3_column_int64(stmt, 3)),
            .modified = c.sqlite3_column_int64(stmt, 4),
        };
    }

    pub fn put_account(self: *SqliteStore, account: *const [32]u8, info: AccountInfo) SqliteError!void {
        const sql =
            \\INSERT INTO accounts (account,frontier,balance,representative,height,modified)
            \\VALUES (?1,?2,?3,?4,?5,?6)
            \\ON CONFLICT(account) DO UPDATE SET
            \\  frontier=excluded.frontier, balance=excluded.balance,
            \\  representative=excluded.representative, height=excluded.height,
            \\  modified=excluded.modified
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK)
            return SqliteError.Prepare;
        defer _ = c.sqlite3_finalize(stmt);

        var bal_be: [16]u8 = undefined;
        std.mem.writeInt(u128, &bal_be, info.balance, .big);

        _ = c.sqlite3_bind_blob(stmt, 1, account, 32, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_blob(stmt, 2, &info.frontier, 32, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_blob(stmt, 3, &bal_be, 16, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_blob(stmt, 4, &info.representative, 32, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 5, @intCast(info.height));
        _ = c.sqlite3_bind_int64(stmt, 6, info.modified);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqliteError.Step;
    }

    // ── Blocks ────────────────────────────────────────────────────────────────

    pub fn get_block(self: *SqliteStore, hash: *const [32]u8) ?BlockRow {
        const sql = "SELECT account,block,height FROM blocks WHERE hash=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_blob(stmt, 1, hash, 32, c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        var row: BlockRow = undefined;
        row.account = blob32(stmt, 0);
        const blob_ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 1));
        @memcpy(&row.block_bytes, blob_ptr[0..216]);
        row.height = @intCast(c.sqlite3_column_int64(stmt, 2));
        return row;
    }

    pub fn put_block(self: *SqliteStore, hash: *const [32]u8, row: BlockRow) SqliteError!void {
        const sql =
            \\INSERT OR IGNORE INTO blocks (hash,account,block,height)
            \\VALUES (?1,?2,?3,?4)
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK)
            return SqliteError.Prepare;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_blob(stmt, 1, hash, 32, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_blob(stmt, 2, &row.account, 32, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_blob(stmt, 3, &row.block_bytes, 216, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 4, @intCast(row.height));

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqliteError.Step;
    }

    pub fn get_account_block_count(self: *SqliteStore, account: *const [32]u8) u64 {
        const sql = "SELECT COUNT(*) FROM blocks WHERE account=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return 0;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, account, 32, c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    pub fn delete_blocks_below(self: *SqliteStore, account: *const [32]u8, height: u64) SqliteError!u64 {
        const sql = "DELETE FROM blocks WHERE account=?1 AND height<?2";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK)
            return SqliteError.Prepare;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_blob(stmt, 1, account, 32, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(height));

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqliteError.Step;
        return @intCast(c.sqlite3_changes(self.db));
    }

    // ── Pending ───────────────────────────────────────────────────────────────

    pub fn get_pending(
        self: *SqliteStore,
        recipient: *const [32]u8,
        send_hash: *const [32]u8,
    ) ?PendingInfo {
        const sql = "SELECT source,amount FROM pending WHERE recipient=?1 AND send_hash=?2";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_blob(stmt, 1, recipient, 32, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_blob(stmt, 2, send_hash, 32, c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        return PendingInfo{
            .source = blob32(stmt, 0),
            .amount = blob_u128(stmt, 1),
        };
    }

    pub fn put_pending(
        self: *SqliteStore,
        recipient: *const [32]u8,
        send_hash: *const [32]u8,
        info: PendingInfo,
    ) SqliteError!void {
        const sql =
            \\INSERT OR IGNORE INTO pending (recipient,send_hash,source,amount)
            \\VALUES (?1,?2,?3,?4)
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK)
            return SqliteError.Prepare;
        defer _ = c.sqlite3_finalize(stmt);

        var amt_be: [16]u8 = undefined;
        std.mem.writeInt(u128, &amt_be, info.amount, .big);

        _ = c.sqlite3_bind_blob(stmt, 1, recipient, 32, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_blob(stmt, 2, send_hash, 32, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_blob(stmt, 3, &info.source, 32, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_blob(stmt, 4, &amt_be, 16, c.SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqliteError.Step;
    }

    pub fn delete_pending(
        self: *SqliteStore,
        recipient: *const [32]u8,
        send_hash: *const [32]u8,
    ) SqliteError!void {
        const sql = "DELETE FROM pending WHERE recipient=?1 AND send_hash=?2";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK)
            return SqliteError.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, recipient, 32, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_blob(stmt, 2, send_hash, 32, c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqliteError.Step;
    }

    // ── Confirmation height ───────────────────────────────────────────────────

    pub fn get_confirmation_height(self: *SqliteStore, account: *const [32]u8) ?ConfirmationHeight {
        const sql = "SELECT height,frontier FROM confirmation_height WHERE account=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, account, 32, c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return ConfirmationHeight{
            .height = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .frontier = blob32(stmt, 1),
        };
    }

    pub fn put_confirmation_height(
        self: *SqliteStore,
        account: *const [32]u8,
        ch: ConfirmationHeight,
    ) SqliteError!void {
        const sql =
            \\INSERT INTO confirmation_height (account,height,frontier) VALUES (?1,?2,?3)
            \\ON CONFLICT(account) DO UPDATE SET height=excluded.height, frontier=excluded.frontier
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK)
            return SqliteError.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, account, 32, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(ch.height));
        _ = c.sqlite3_bind_blob(stmt, 3, &ch.frontier, 32, c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqliteError.Step;
    }

    // ── Pruning watermark ─────────────────────────────────────────────────────

    pub fn get_pruned_height(self: *SqliteStore, account: *const [32]u8) u64 {
        const sql = "SELECT pruned_height FROM pruned WHERE account=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return 0;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, account, 32, c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    pub fn put_pruned_height(self: *SqliteStore, account: *const [32]u8, height: u64) SqliteError!void {
        const sql =
            \\INSERT INTO pruned (account,pruned_height) VALUES (?1,?2)
            \\ON CONFLICT(account) DO UPDATE SET pruned_height=excluded.pruned_height
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK)
            return SqliteError.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, account, 32, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(height));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqliteError.Step;
    }

    // ── Peers ─────────────────────────────────────────────────────────────────

    pub fn put_peer(self: *SqliteStore, address: []const u8, last_seen: i64) SqliteError!void {
        const sql =
            \\INSERT INTO peers (address,last_seen) VALUES (?1,?2)
            \\ON CONFLICT(address) DO UPDATE SET last_seen=excluded.last_seen
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK)
            return SqliteError.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, address.ptr, @intCast(address.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, last_seen);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqliteError.Step;
    }

    pub fn get_peers(
        self: *SqliteStore,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(PeerRow),
    ) (SqliteError || error{OutOfMemory})!void {
        const sql = "SELECT address,last_seen FROM peers";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK)
            return SqliteError.Prepare;
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const addr_ptr: [*]const u8 = @ptrCast(c.sqlite3_column_text(stmt, 0));
            const addr_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const addr = try allocator.dupe(u8, addr_ptr[0..addr_len]);
            const last_seen = c.sqlite3_column_int64(stmt, 1);
            try out.append(allocator, .{ .address = addr, .last_seen = last_seen });
        }
    }

    pub fn delete_stale_peers(self: *SqliteStore, older_than: i64) SqliteError!void {
        const sql = "DELETE FROM peers WHERE last_seen<?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK)
            return SqliteError.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, older_than);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqliteError.Step;
    }

    // ── Meta ──────────────────────────────────────────────────────────────────

    pub fn get_meta(self: *SqliteStore, key: []const u8, buf: []u8) ?[]u8 {
        const sql = "SELECT value FROM _meta WHERE key=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const val_ptr: [*]const u8 = @ptrCast(c.sqlite3_column_text(stmt, 0));
        const val_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        const n = @min(val_len, buf.len);
        @memcpy(buf[0..n], val_ptr[0..n]);
        return buf[0..n];
    }

    pub fn put_meta(self: *SqliteStore, key: []const u8, value: []const u8) SqliteError!void {
        const sql =
            \\INSERT INTO _meta (key,value) VALUES (?1,?2)
            \\ON CONFLICT(key) DO UPDATE SET value=excluded.value
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK)
            return SqliteError.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, value.ptr, @intCast(value.len), c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqliteError.Step;
    }

    // ── Iteration ─────────────────────────────────────────────────────────────

    pub fn for_each_account(
        self: *SqliteStore,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), [32]u8, AccountInfo) void,
    ) SqliteError!void {
        const sql = "SELECT account,frontier,balance,representative,height,modified FROM accounts";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK)
            return SqliteError.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const acct = blob32(stmt, 0);
            const info = AccountInfo{
                .frontier = blob32(stmt, 1),
                .balance = blob_u128(stmt, 2),
                .representative = blob32(stmt, 3),
                .height = @intCast(c.sqlite3_column_int64(stmt, 4)),
                .modified = c.sqlite3_column_int64(stmt, 5),
            };
            cb(ctx, acct, info);
        }
    }

    pub fn for_each_confirmed_account(
        self: *SqliteStore,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), [32]u8, AccountInfo) void,
    ) SqliteError!void {
        const sql =
            \\SELECT a.account,a.frontier,a.balance,a.representative,a.height,a.modified
            \\FROM accounts a
            \\JOIN confirmation_height ch ON ch.account=a.account
            \\WHERE ch.height > 0
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK)
            return SqliteError.Prepare;
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const acct = blob32(stmt, 0);
            const info = AccountInfo{
                .frontier = blob32(stmt, 1),
                .balance = blob_u128(stmt, 2),
                .representative = blob32(stmt, 3),
                .height = @intCast(c.sqlite3_column_int64(stmt, 4)),
                .modified = c.sqlite3_column_int64(stmt, 5),
            };
            cb(ctx, acct, info);
        }
    }

    // ── Checkpoint (flush WAL to main DB file) ────────────────────────────────

    pub fn checkpoint(self: *SqliteStore) void {
        _ = c.sqlite3_wal_checkpoint_v2(self.db, null, c.SQLITE_CHECKPOINT_FULL, null, null);
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    fn exec(self: *SqliteStore, sql: []const u8) SqliteError!void {
        var err_msg: ?[*:0]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql.ptr, null, null, @ptrCast(&err_msg));
        if (err_msg) |msg| _ = c.sqlite3_free(msg);
        if (rc != c.SQLITE_OK) return SqliteError.Exec;
    }

    fn schema_version(self: *SqliteStore) i64 {
        var buf: [4]u8 = undefined;
        const val = self.get_meta("schema_version", &buf) orelse return 0;
        return std.fmt.parseInt(i64, val, 10) catch 0;
    }

    /// Migration 1: create all production tables.
    fn migration_v1(self: *SqliteStore) SqliteError!void {
        try self.exec("BEGIN");
        errdefer _ = c.sqlite3_exec(self.db, "ROLLBACK", null, null, null);

        try self.exec(
            \\CREATE TABLE IF NOT EXISTS accounts (
            \\  account        BLOB PRIMARY KEY NOT NULL,
            \\  frontier       BLOB NOT NULL,
            \\  balance        BLOB NOT NULL,
            \\  representative BLOB NOT NULL,
            \\  height         INTEGER NOT NULL,
            \\  modified       INTEGER NOT NULL
            \\) STRICT
        );
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS blocks (
            \\  hash    BLOB PRIMARY KEY NOT NULL,
            \\  account BLOB NOT NULL,
            \\  block   BLOB NOT NULL,
            \\  height  INTEGER NOT NULL
            \\) STRICT
        );
        try self.exec("CREATE INDEX IF NOT EXISTS idx_blocks_account_height ON blocks(account,height)");
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS pending (
            \\  recipient BLOB NOT NULL,
            \\  send_hash BLOB NOT NULL,
            \\  source    BLOB NOT NULL,
            \\  amount    BLOB NOT NULL,
            \\  PRIMARY KEY (recipient, send_hash)
            \\) STRICT
        );
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS confirmation_height (
            \\  account  BLOB PRIMARY KEY NOT NULL,
            \\  height   INTEGER NOT NULL,
            \\  frontier BLOB NOT NULL
            \\) STRICT
        );
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS pruned (
            \\  account       BLOB PRIMARY KEY NOT NULL,
            \\  pruned_height INTEGER NOT NULL
            \\) STRICT
        );
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS peers (
            \\  address   TEXT PRIMARY KEY NOT NULL,
            \\  last_seen INTEGER NOT NULL
            \\) STRICT
        );

        try self.put_meta("schema_version", "1");
        try self.exec("COMMIT");
    }
};

// ── Column read helpers ───────────────────────────────────────────────────────

fn blob32(stmt: ?*c.sqlite3_stmt, col: c_int) [32]u8 {
    const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, col));
    return ptr[0..32].*;
}

fn blob_u128(stmt: ?*c.sqlite3_stmt, col: c_int) u128 {
    const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, col));
    return std.mem.readInt(u128, ptr[0..16], .big);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn tmp_db_path(buf: *[64]u8) []u8 {
    const ts = std.time.milliTimestamp();
    return std.fmt.bufPrint(buf, "/tmp/smallnano_test_{d}.db", .{ts}) catch buf[0..0];
}

test "sqlite_store: open, migrate, close" {
    var path_buf: [64]u8 = undefined;
    const path = tmp_db_path(&path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};

    var s = SqliteStore.init(std.testing.allocator);
    defer s.deinit();

    try s.open(path);
    try s.migrate();
    // Second migrate is idempotent.
    try s.migrate();
}

test "sqlite_store: account round-trip" {
    var path_buf: [64]u8 = undefined;
    const path = tmp_db_path(&path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};

    var s = SqliteStore.init(std.testing.allocator);
    defer s.deinit();
    try s.open(path);
    try s.migrate();

    const account = [_]u8{0x01} ** 32;
    const info = AccountInfo{
        .frontier = [_]u8{0xAA} ** 32,
        .balance = 1_000_000_000_000_000_000_000_000,
        .representative = [_]u8{0x02} ** 32,
        .height = 7,
        .modified = 1700000000,
    };
    try s.put_account(&account, info);
    const got = s.get_account(&account).?;
    try std.testing.expectEqual(info.height, got.height);
    try std.testing.expectEqual(info.balance, got.balance);
    try std.testing.expectEqual(info.frontier, got.frontier);
    try std.testing.expectEqual(info.representative, got.representative);
}

test "sqlite_store: account get missing returns null" {
    var path_buf: [64]u8 = undefined;
    const path = tmp_db_path(&path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};
    var s = SqliteStore.init(std.testing.allocator);
    defer s.deinit();
    try s.open(path);
    try s.migrate();
    try std.testing.expect(s.get_account(&([_]u8{0xFF} ** 32)) == null);
}

test "sqlite_store: block round-trip and count" {
    var path_buf: [64]u8 = undefined;
    const path = tmp_db_path(&path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};
    var s = SqliteStore.init(std.testing.allocator);
    defer s.deinit();
    try s.open(path);
    try s.migrate();

    const account = [_]u8{0x01} ** 32;
    const hash = [_]u8{0x11} ** 32;
    const row = BlockRow{
        .account = account,
        .block_bytes = [_]u8{0xBB} ** 216,
        .height = 3,
    };
    try s.put_block(&hash, row);

    const got = s.get_block(&hash).?;
    try std.testing.expectEqual(@as(u64, 3), got.height);
    try std.testing.expectEqual(account, got.account);
    try std.testing.expectEqual(@as(u64, 1), s.get_account_block_count(&account));
}

test "sqlite_store: put_block is idempotent (INSERT OR IGNORE)" {
    var path_buf: [64]u8 = undefined;
    const path = tmp_db_path(&path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};
    var s = SqliteStore.init(std.testing.allocator);
    defer s.deinit();
    try s.open(path);
    try s.migrate();

    const account = [_]u8{0x01} ** 32;
    const hash = [_]u8{0x22} ** 32;
    const row = BlockRow{ .account = account, .block_bytes = [_]u8{0} ** 216, .height = 1 };
    try s.put_block(&hash, row);
    try s.put_block(&hash, row); // should not error or duplicate
    try std.testing.expectEqual(@as(u64, 1), s.get_account_block_count(&account));
}

test "sqlite_store: delete_blocks_below" {
    var path_buf: [64]u8 = undefined;
    const path = tmp_db_path(&path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};
    var s = SqliteStore.init(std.testing.allocator);
    defer s.deinit();
    try s.open(path);
    try s.migrate();

    const account = [_]u8{0x01} ** 32;
    for (0..5) |i| {
        var hash: [32]u8 = [_]u8{0} ** 32;
        hash[0] = @intCast(i + 1);
        try s.put_block(&hash, .{ .account = account, .block_bytes = [_]u8{0} ** 216, .height = @intCast(i + 1) });
    }
    const deleted = try s.delete_blocks_below(&account, 3);
    try std.testing.expectEqual(@as(u64, 2), deleted);
    try std.testing.expectEqual(@as(u64, 3), s.get_account_block_count(&account));
}

test "sqlite_store: pending round-trip" {
    var path_buf: [64]u8 = undefined;
    const path = tmp_db_path(&path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};
    var s = SqliteStore.init(std.testing.allocator);
    defer s.deinit();
    try s.open(path);
    try s.migrate();

    const recipient = [_]u8{0x01} ** 32;
    const send_hash = [_]u8{0x02} ** 32;
    const info = PendingInfo{ .source = [_]u8{0x03} ** 32, .amount = 9_999_000_000_000_000_000_000_000 };

    try s.put_pending(&recipient, &send_hash, info);
    const got = s.get_pending(&recipient, &send_hash).?;
    try std.testing.expectEqual(info.amount, got.amount);
    try std.testing.expectEqual(info.source, got.source);

    try s.delete_pending(&recipient, &send_hash);
    try std.testing.expect(s.get_pending(&recipient, &send_hash) == null);
}

test "sqlite_store: confirmation height round-trip" {
    var path_buf: [64]u8 = undefined;
    const path = tmp_db_path(&path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};
    var s = SqliteStore.init(std.testing.allocator);
    defer s.deinit();
    try s.open(path);
    try s.migrate();

    const account = [_]u8{0x01} ** 32;
    try s.put_confirmation_height(&account, .{ .height = 42, .frontier = [_]u8{0xCC} ** 32 });
    const got = s.get_confirmation_height(&account).?;
    try std.testing.expectEqual(@as(u64, 42), got.height);

    // Update.
    try s.put_confirmation_height(&account, .{ .height = 99, .frontier = [_]u8{0xDD} ** 32 });
    const got2 = s.get_confirmation_height(&account).?;
    try std.testing.expectEqual(@as(u64, 99), got2.height);
}

test "sqlite_store: pruning watermark" {
    var path_buf: [64]u8 = undefined;
    const path = tmp_db_path(&path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};
    var s = SqliteStore.init(std.testing.allocator);
    defer s.deinit();
    try s.open(path);
    try s.migrate();

    const account = [_]u8{0x05} ** 32;
    try std.testing.expectEqual(@as(u64, 0), s.get_pruned_height(&account));
    try s.put_pruned_height(&account, 50);
    try std.testing.expectEqual(@as(u64, 50), s.get_pruned_height(&account));
}

test "sqlite_store: peers put and get" {
    var path_buf: [64]u8 = undefined;
    const path = tmp_db_path(&path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};
    var s = SqliteStore.init(std.testing.allocator);
    defer s.deinit();
    try s.open(path);
    try s.migrate();

    try s.put_peer("10.0.0.1:7176", 1000);
    try s.put_peer("10.0.0.2:7176", 2000);

    var list = std.ArrayList(PeerRow){};
    defer {
        for (list.items) |p| std.testing.allocator.free(p.address);
        list.deinit(std.testing.allocator);
    }
    try s.get_peers(std.testing.allocator, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}

test "sqlite_store: meta put and get" {
    var path_buf: [64]u8 = undefined;
    const path = tmp_db_path(&path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};
    var s = SqliteStore.init(std.testing.allocator);
    defer s.deinit();
    try s.open(path);
    try s.migrate();

    try s.put_meta("network", "main");
    var buf: [16]u8 = undefined;
    const val = s.get_meta("network", &buf).?;
    try std.testing.expectEqualStrings("main", val);
}

test "sqlite_store: schema_version set by migration" {
    var path_buf: [64]u8 = undefined;
    const path = tmp_db_path(&path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};
    var s = SqliteStore.init(std.testing.allocator);
    defer s.deinit();
    try s.open(path);
    try s.migrate();
    try std.testing.expectEqual(@as(i64, 1), s.schema_version());
}

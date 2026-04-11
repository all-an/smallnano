/// NullStore — an in-memory Store implementation for tests.
///
/// Zero disk I/O. Uses std.HashMap for all tables. Suitable for unit-testing
/// ledger logic without touching the filesystem.
///
/// All operations are synchronous and deterministic. The store is not
/// thread-safe (matches the single-threaded test context).
const std = @import("std");
const store = @import("store.zig");

pub const AccountInfo = store.AccountInfo;
pub const BlockRow = store.BlockRow;
pub const PendingInfo = store.PendingInfo;
pub const ConfirmationHeight = store.ConfirmationHeight;
pub const PeerRow = store.PeerRow;

// ── Key types for hash maps ────────────────────────────────────────────────────

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

// Pending key = (recipient[32], send_hash[32])
const PendingKey = struct { recipient: Key32, send_hash: Key32 };
const PendingKeyContext = struct {
    pub fn hash(_: @This(), k: PendingKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(&k.recipient);
        h.update(&k.send_hash);
        return h.final();
    }
    pub fn eql(_: @This(), a: PendingKey, b: PendingKey) bool {
        return std.mem.eql(u8, &a.recipient, &b.recipient) and
            std.mem.eql(u8, &a.send_hash, &b.send_hash);
    }
};

// ── NullStore ─────────────────────────────────────────────────────────────────

pub const NullStore = struct {
    allocator: std.mem.Allocator,
    accounts: std.HashMap(Key32, AccountInfo, Key32Context(Key32), 80),
    blocks: std.HashMap(Key32, BlockRow, Key32Context(Key32), 80),
    pending: std.HashMap(PendingKey, PendingInfo, PendingKeyContext, 80),
    conf_heights: std.HashMap(Key32, ConfirmationHeight, Key32Context(Key32), 80),
    pruned: std.HashMap(Key32, u64, Key32Context(Key32), 80),
    meta: std.StringHashMap([]u8),
    peers: std.StringHashMap(i64),

    pub fn init(allocator: std.mem.Allocator) NullStore {
        return .{
            .allocator = allocator,
            .accounts = std.HashMap(Key32, AccountInfo, Key32Context(Key32), 80).init(allocator),
            .blocks = std.HashMap(Key32, BlockRow, Key32Context(Key32), 80).init(allocator),
            .pending = std.HashMap(PendingKey, PendingInfo, PendingKeyContext, 80).init(allocator),
            .conf_heights = std.HashMap(Key32, ConfirmationHeight, Key32Context(Key32), 80).init(allocator),
            .pruned = std.HashMap(Key32, u64, Key32Context(Key32), 80).init(allocator),
            .meta = std.StringHashMap([]u8).init(allocator),
            .peers = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *NullStore) void {
        self.accounts.deinit();
        self.blocks.deinit();
        self.pending.deinit();
        self.conf_heights.deinit();
        self.pruned.deinit();
        // Free owned keys/values in meta and peers.
        var mit = self.meta.iterator();
        while (mit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.meta.deinit();
        var pit = self.peers.iterator();
        while (pit.next()) |e| self.allocator.free(e.key_ptr.*);
        self.peers.deinit();
    }

    // ── Lifecycle (no-ops for the null store) ─────────────────────────────────

    pub fn open(self: *NullStore, path: []const u8) !void {
        _ = self;
        _ = path;
    }

    pub fn close(self: *NullStore) void {
        _ = self;
    }

    pub fn migrate(self: *NullStore) !void {
        _ = self;
    }

    // ── Accounts ─────────────────────────────────────────────────────────────

    pub fn get_account(self: *NullStore, account: *const [32]u8) ?AccountInfo {
        return self.accounts.get(account.*);
    }

    pub fn put_account(self: *NullStore, account: *const [32]u8, info: AccountInfo) !void {
        try self.accounts.put(account.*, info);
    }

    // ── Blocks ────────────────────────────────────────────────────────────────

    pub fn get_block(self: *NullStore, hash: *const [32]u8) ?BlockRow {
        return self.blocks.get(hash.*);
    }

    pub fn put_block(self: *NullStore, hash: *const [32]u8, row: BlockRow) !void {
        try self.blocks.put(hash.*, row);
    }

    pub fn get_account_block_count(self: *NullStore, account: *const [32]u8) u64 {
        // Count blocks whose account field matches.
        var count: u64 = 0;
        var it = self.blocks.valueIterator();
        while (it.next()) |row| {
            if (std.mem.eql(u8, &row.account, account)) count += 1;
        }
        return count;
    }

    pub fn delete_blocks_below(self: *NullStore, account: *const [32]u8, height: u64) !u64 {
        var to_delete = std.ArrayList(Key32){};
        defer to_delete.deinit(self.allocator);

        var it = self.blocks.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, &e.value_ptr.account, account) and e.value_ptr.height < height) {
                try to_delete.append(self.allocator, e.key_ptr.*);
            }
        }
        for (to_delete.items) |k| _ = self.blocks.remove(k);
        return to_delete.items.len;
    }

    // ── Pending ───────────────────────────────────────────────────────────────

    pub fn get_pending(
        self: *NullStore,
        recipient: *const [32]u8,
        send_hash: *const [32]u8,
    ) ?PendingInfo {
        return self.pending.get(.{ .recipient = recipient.*, .send_hash = send_hash.* });
    }

    pub fn put_pending(
        self: *NullStore,
        recipient: *const [32]u8,
        send_hash: *const [32]u8,
        info: PendingInfo,
    ) !void {
        try self.pending.put(.{ .recipient = recipient.*, .send_hash = send_hash.* }, info);
    }

    pub fn delete_pending(
        self: *NullStore,
        recipient: *const [32]u8,
        send_hash: *const [32]u8,
    ) !void {
        _ = self.pending.remove(.{ .recipient = recipient.*, .send_hash = send_hash.* });
    }

    // ── Confirmation height ───────────────────────────────────────────────────

    pub fn get_confirmation_height(self: *NullStore, account: *const [32]u8) ?ConfirmationHeight {
        return self.conf_heights.get(account.*);
    }

    pub fn put_confirmation_height(
        self: *NullStore,
        account: *const [32]u8,
        ch: ConfirmationHeight,
    ) !void {
        try self.conf_heights.put(account.*, ch);
    }

    // ── Pruning watermark ─────────────────────────────────────────────────────

    pub fn get_pruned_height(self: *NullStore, account: *const [32]u8) u64 {
        return self.pruned.get(account.*) orelse 0;
    }

    pub fn put_pruned_height(self: *NullStore, account: *const [32]u8, height: u64) !void {
        try self.pruned.put(account.*, height);
    }

    // ── Peers ─────────────────────────────────────────────────────────────────

    pub fn get_peers(
        self: *NullStore,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(PeerRow),
    ) !void {
        var it = self.peers.iterator();
        while (it.next()) |e| {
            const addr = try allocator.dupe(u8, e.key_ptr.*);
            try out.append(allocator, .{ .address = addr, .last_seen = e.value_ptr.* });
        }
    }

    pub fn put_peer(self: *NullStore, address: []const u8, last_seen: i64) !void {
        const result = try self.peers.getOrPut(address);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, address);
        }
        result.value_ptr.* = last_seen;
    }

    pub fn delete_stale_peers(self: *NullStore, older_than: i64) !void {
        var to_delete = std.ArrayList([]const u8){};
        defer to_delete.deinit(self.allocator);

        var it = self.peers.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* < older_than) try to_delete.append(self.allocator, e.key_ptr.*);
        }
        for (to_delete.items) |k| {
            if (self.peers.fetchRemove(k)) |kv| self.allocator.free(kv.key);
        }
    }

    // ── Meta ──────────────────────────────────────────────────────────────────

    pub fn get_meta(self: *NullStore, key: []const u8, buf: []u8) ?[]u8 {
        const val = self.meta.get(key) orelse return null;
        const n = @min(val.len, buf.len);
        @memcpy(buf[0..n], val[0..n]);
        return buf[0..n];
    }

    pub fn put_meta(self: *NullStore, key: []const u8, value: []const u8) !void {
        const result = try self.meta.getOrPut(key);
        if (result.found_existing) {
            self.allocator.free(result.value_ptr.*);
        } else {
            result.key_ptr.* = try self.allocator.dupe(u8, key);
        }
        result.value_ptr.* = try self.allocator.dupe(u8, value);
    }

    // ── Iteration ─────────────────────────────────────────────────────────────

    pub fn for_each_account(
        self: *NullStore,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), [32]u8, AccountInfo) void,
    ) !void {
        var it = self.accounts.iterator();
        while (it.next()) |e| cb(ctx, e.key_ptr.*, e.value_ptr.*);
    }

    pub fn for_each_confirmed_account(
        self: *NullStore,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), [32]u8, AccountInfo) void,
    ) !void {
        var it = self.accounts.iterator();
        while (it.next()) |e| {
            const ch = self.conf_heights.get(e.key_ptr.*) orelse continue;
            if (ch.height > 0) cb(ctx, e.key_ptr.*, e.value_ptr.*);
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "null_store: account put and get" {
    var s = NullStore.init(std.testing.allocator);
    defer s.deinit();

    const account = [_]u8{0x01} ** 32;
    const info = AccountInfo{
        .frontier = [_]u8{0xAA} ** 32,
        .balance = 1_000_000_000_000_000_000_000_000,
        .representative = [_]u8{0x02} ** 32,
        .height = 5,
        .modified = 1700000000,
    };
    try s.put_account(&account, info);
    const got = s.get_account(&account).?;
    try std.testing.expectEqual(info.height, got.height);
    try std.testing.expectEqual(info.balance, got.balance);
    try std.testing.expectEqual(info.frontier, got.frontier);
}

test "null_store: account get missing returns null" {
    var s = NullStore.init(std.testing.allocator);
    defer s.deinit();
    const account = [_]u8{0xFF} ** 32;
    try std.testing.expect(s.get_account(&account) == null);
}

test "null_store: block put, get, count" {
    var s = NullStore.init(std.testing.allocator);
    defer s.deinit();

    const account = [_]u8{0x01} ** 32;
    const hash1 = [_]u8{0x11} ** 32;
    const hash2 = [_]u8{0x22} ** 32;

    try s.put_block(&hash1, .{ .account = account, .block_bytes = [_]u8{0} ** 216, .height = 1 });
    try s.put_block(&hash2, .{ .account = account, .block_bytes = [_]u8{0} ** 216, .height = 2 });

    try std.testing.expect(s.get_block(&hash1) != null);
    try std.testing.expect(s.get_block(&hash2) != null);
    try std.testing.expectEqual(@as(u64, 2), s.get_account_block_count(&account));
}

test "null_store: delete_blocks_below removes correct blocks" {
    var s = NullStore.init(std.testing.allocator);
    defer s.deinit();

    const account = [_]u8{0x01} ** 32;
    for (0..5) |i| {
        var hash: [32]u8 = [_]u8{0} ** 32;
        hash[0] = @intCast(i);
        try s.put_block(&hash, .{ .account = account, .block_bytes = [_]u8{0} ** 216, .height = @intCast(i + 1) });
    }

    const deleted = try s.delete_blocks_below(&account, 3);
    try std.testing.expectEqual(@as(u64, 2), deleted); // heights 1 and 2 deleted
    try std.testing.expectEqual(@as(u64, 3), s.get_account_block_count(&account));
}

test "null_store: pending put, get, delete" {
    var s = NullStore.init(std.testing.allocator);
    defer s.deinit();

    const recipient = [_]u8{0x01} ** 32;
    const send_hash = [_]u8{0x02} ** 32;
    const info = PendingInfo{ .source = [_]u8{0x03} ** 32, .amount = 5000 };

    try s.put_pending(&recipient, &send_hash, info);
    const got = s.get_pending(&recipient, &send_hash).?;
    try std.testing.expectEqual(info.amount, got.amount);

    try s.delete_pending(&recipient, &send_hash);
    try std.testing.expect(s.get_pending(&recipient, &send_hash) == null);
}

test "null_store: confirmation height put and get" {
    var s = NullStore.init(std.testing.allocator);
    defer s.deinit();

    const account = [_]u8{0x01} ** 32;
    const ch = ConfirmationHeight{ .height = 42, .frontier = [_]u8{0xBB} ** 32 };

    try s.put_confirmation_height(&account, ch);
    const got = s.get_confirmation_height(&account).?;
    try std.testing.expectEqual(@as(u64, 42), got.height);
}

test "null_store: pruned height put and get" {
    var s = NullStore.init(std.testing.allocator);
    defer s.deinit();

    const account = [_]u8{0x01} ** 32;
    try std.testing.expectEqual(@as(u64, 0), s.get_pruned_height(&account)); // default = 0

    try s.put_pruned_height(&account, 10);
    try std.testing.expectEqual(@as(u64, 10), s.get_pruned_height(&account));
}

test "null_store: meta put and get" {
    var s = NullStore.init(std.testing.allocator);
    defer s.deinit();

    try s.put_meta("schema_version", "1");
    var buf: [16]u8 = undefined;
    const val = s.get_meta("schema_version", &buf).?;
    try std.testing.expectEqualStrings("1", val);
}

test "null_store: meta get missing returns null" {
    var s = NullStore.init(std.testing.allocator);
    defer s.deinit();
    var buf: [16]u8 = undefined;
    try std.testing.expect(s.get_meta("nonexistent", &buf) == null);
}

test "null_store: peers put, get, delete stale" {
    var s = NullStore.init(std.testing.allocator);
    defer s.deinit();

    try s.put_peer("192.168.1.1:7176", 1000);
    try s.put_peer("192.168.1.2:7176", 2000);
    try s.put_peer("192.168.1.3:7176", 500);

    // Delete peers older than timestamp 1500.
    try s.delete_stale_peers(1500);

    var peer_list = std.ArrayList(PeerRow){};
    defer {
        for (peer_list.items) |p| std.testing.allocator.free(p.address);
        peer_list.deinit(std.testing.allocator);
    }
    try s.get_peers(std.testing.allocator, &peer_list);
    // Only timestamp 2000 should survive.
    try std.testing.expectEqual(@as(usize, 1), peer_list.items.len);
    try std.testing.expectEqual(@as(i64, 2000), peer_list.items[0].last_seen);
}

test "null_store: for_each_account visits all accounts" {
    var s = NullStore.init(std.testing.allocator);
    defer s.deinit();

    const a1 = [_]u8{0x01} ** 32;
    const a2 = [_]u8{0x02} ** 32;
    const info = AccountInfo{
        .frontier = [_]u8{0} ** 32,
        .balance = 0,
        .representative = [_]u8{0} ** 32,
        .height = 1,
        .modified = 0,
    };
    try s.put_account(&a1, info);
    try s.put_account(&a2, info);

    var count: usize = 0;
    const Ctx = struct {
        count: *usize,
        fn cb(self: @This(), _: [32]u8, _: AccountInfo) void {
            self.count.* += 1;
        }
    };
    try s.for_each_account(Ctx{ .count = &count }, Ctx.cb);
    try std.testing.expectEqual(@as(usize, 2), count);
}

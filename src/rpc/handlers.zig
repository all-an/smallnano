/// RPC handlers — minimal JSON-RPC surface over the wallet and ledger.
///
/// Requests are ordinary JSON objects with an `"action"` field. Responses are
/// always JSON objects: either a success payload or `{"error":"..."}`.
///
/// Implemented commands:
///   - `wallet_unlock`
///   - `wallet_lock`
///   - `account_create`
///   - `account_info`
///   - `pending_info`
///   - `process`
///   - `send`
///   - `receive`
const std = @import("std");
const account_mod = @import("../types/account.zig");
const block_mod = @import("../types/block.zig");

const Account = account_mod.Account;
const StateBlock = block_mod.StateBlock;

pub const RpcRequestError = error{
    InvalidJson,
    InvalidRequest,
    MissingAction,
    UnknownAction,
    MissingField,
    InvalidStringField,
    InvalidBlock,
    InvalidBlockType,
    InvalidHash,
    InvalidAccount,
    InvalidLink,
    InvalidAmount,
    InvalidIndex,
    InvalidWork,
    InvalidSignature,
};

pub fn RpcHandlers(comptime LedgerType: type, comptime WalletType: type) type {
    return struct {
        const Self = @This();

        pub const RequestError = RpcRequestError;

        allocator: std.mem.Allocator,
        ledger: *LedgerType,
        wallet: *WalletType,

        pub fn init(allocator: std.mem.Allocator, ledger: *LedgerType, wallet: *WalletType) Self {
            return .{
                .allocator = allocator,
                .ledger = ledger,
                .wallet = wallet,
            };
        }

        /// Handle one JSON-RPC request body and return an owned JSON response.
        pub fn handle(self: *Self, allocator: std.mem.Allocator, body: []const u8) ![]u8 {
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
                return error_response(allocator, "InvalidJson");
            };
            defer parsed.deinit();

            return self.dispatch_value(allocator, parsed.value) catch |err| {
                return error_response(allocator, @errorName(err));
            };
        }

        fn dispatch_value(self: *Self, allocator: std.mem.Allocator, root: std.json.Value) ![]u8 {
            const obj = expect_object(root) catch return RequestError.InvalidRequest;
            const action = try required_string(obj, "action");

            if (std.mem.eql(u8, action, "wallet_unlock")) return self.handle_wallet_unlock(allocator, obj);
            if (std.mem.eql(u8, action, "wallet_lock")) return self.handle_wallet_lock(allocator);
            if (std.mem.eql(u8, action, "account_create")) return self.handle_account_create(allocator, obj);
            if (std.mem.eql(u8, action, "account_info")) return self.handle_account_info(allocator, obj);
            if (std.mem.eql(u8, action, "pending_info")) return self.handle_pending_info(allocator, obj);
            if (std.mem.eql(u8, action, "process")) return self.handle_process(allocator, obj);
            if (std.mem.eql(u8, action, "send")) return self.handle_send(allocator, obj);
            if (std.mem.eql(u8, action, "receive")) return self.handle_receive(allocator, obj);
            return RequestError.UnknownAction;
        }

        fn handle_wallet_unlock(self: *Self, allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
            const password = try required_string(obj, "password");
            try self.wallet.unlock(password);
            return json_owned(allocator, .{ .unlocked = true });
        }

        fn handle_wallet_lock(self: *Self, allocator: std.mem.Allocator) ![]u8 {
            self.wallet.lock();
            return json_owned(allocator, .{ .locked = true });
        }

        fn handle_account_create(self: *Self, allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
            const index = try parse_u32_string(try required_string(obj, "index"), RequestError.InvalidIndex);
            const derived = try self.wallet.derive_account(index);

            const public_key = std.fmt.bytesToHex(derived.public_key, .lower);
            var index_buf: [16]u8 = undefined;
            return json_owned(allocator, .{
                .index = try decimal_slice(&index_buf, index),
                .account = derived.address[0..],
                .public_key = public_key[0..],
            });
        }

        fn handle_account_info(self: *Self, allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
            const account_key = try parse_account_string(try required_string(obj, "account"));
            const info = self.ledger.get_account_info(&account_key) orelse return error.AccountNotFound;

            var representative: [64]u8 = undefined;
            Account.from_bytes(&info.representative).to_address(&representative);
            const frontier = std.fmt.bytesToHex(info.frontier, .lower);
            var balance_buf: [40]u8 = undefined;
            var height_buf: [24]u8 = undefined;
            var confirmation_height_buf: [24]u8 = undefined;

            return json_owned(allocator, .{
                .frontier = frontier[0..],
                .balance = try decimal_slice(&balance_buf, info.balance),
                .representative = representative[0..],
                .height = try decimal_slice(&height_buf, info.height),
                .confirmation_height = try decimal_slice(&confirmation_height_buf, self.ledger.confirmation_height(&account_key)),
            });
        }

        fn handle_pending_info(self: *Self, allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
            const account_key = try parse_account_string(try required_string(obj, "account"));
            const pending_hash = try parse_hash_string(try required_string(obj, "hash"));
            const pending = self.ledger.get_pending(&account_key, &pending_hash) orelse return error.PendingNotFound;

            var source: [64]u8 = undefined;
            Account.from_bytes(&pending.source).to_address(&source);
            var amount_buf: [40]u8 = undefined;

            return json_owned(allocator, .{
                .source = source[0..],
                .amount = try decimal_slice(&amount_buf, pending.amount),
            });
        }

        fn handle_process(self: *Self, allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
            const block_value = obj.get("block") orelse return RequestError.MissingField;
            const block = try parse_block_json(block_value);
            const result = try self.ledger.process(&block);
            return process_response(allocator, result);
        }

        fn handle_send(self: *Self, allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
            const from = try parse_account_string(try required_string(obj, "source"));
            const to = try parse_account_string(try required_string(obj, "destination"));
            const amount = try parse_u128_string(try required_string(obj, "amount"), RequestError.InvalidAmount);

            const blk = try self.wallet.create_send(from, to, amount);
            const result = try self.ledger.process(&blk);
            return process_response(allocator, result);
        }

        fn handle_receive(self: *Self, allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
            const account_key = try parse_account_string(try required_string(obj, "account"));
            const pending_hash = try parse_hash_string(try required_string(obj, "hash"));

            const blk = try self.wallet.create_receive(account_key, pending_hash);
            const result = try self.ledger.process(&blk);
            return process_response(allocator, result);
        }
    };
}

fn process_response(allocator: std.mem.Allocator, result: anytype) ![]u8 {
    const hash_hex = std.fmt.bytesToHex(result.hash, .lower);
    var height_buf: [24]u8 = undefined;
    return json_owned(allocator, .{
        .hash = hash_hex[0..],
        .block_type = @tagName(result.block_type),
        .height = try decimal_slice(&height_buf, result.new_height),
    });
}

fn json_owned(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn error_response(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return json_owned(allocator, .{ .@"error" = message });
}

fn expect_object(value: std.json.Value) RpcRequestError!std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => RpcRequestError.InvalidRequest,
    };
}

fn required_string(obj: std.json.ObjectMap, key: []const u8) RpcRequestError![]const u8 {
    const value = obj.get(key) orelse return RpcRequestError.MissingField;
    return switch (value) {
        .string => |s| s,
        else => RpcRequestError.InvalidStringField,
    };
}

fn parse_block_json(value: std.json.Value) !StateBlock {
    const obj = expect_object(value) catch return RpcRequestError.InvalidBlock;
    if (obj.get("type")) |block_type| {
        switch (block_type) {
            .string => |s| if (!std.mem.eql(u8, s, "state")) return RpcRequestError.InvalidBlockType,
            else => return RpcRequestError.InvalidBlockType,
        }
    }

    return .{
        .account = try parse_account_string(try required_string(obj, "account")),
        .previous = try parse_hash_string(try required_string(obj, "previous")),
        .representative = try parse_account_string(try required_string(obj, "representative")),
        .balance = try parse_u128_string(try required_string(obj, "balance"), RpcRequestError.InvalidAmount),
        .link = try parse_link_string(try required_string(obj, "link")),
        .work = try parse_work_string(try required_string(obj, "work")),
        .signature = try parse_signature_string(try required_string(obj, "signature")),
    };
}

fn parse_account_string(value: []const u8) ![32]u8 {
    return (Account.from_address(value) catch return RpcRequestError.InvalidAccount).bytes;
}

fn parse_hash_string(value: []const u8) ![32]u8 {
    if (value.len != 64) return RpcRequestError.InvalidHash;
    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, value) catch return RpcRequestError.InvalidHash;
    return hash;
}

fn parse_signature_string(value: []const u8) ![64]u8 {
    if (value.len != 128) return RpcRequestError.InvalidSignature;
    var signature: [64]u8 = undefined;
    _ = std.fmt.hexToBytes(&signature, value) catch return RpcRequestError.InvalidSignature;
    return signature;
}

fn parse_link_string(value: []const u8) ![32]u8 {
    if (std.mem.startsWith(u8, value, "smn_")) return parse_account_string(value);
    return parse_hash_string(value) catch RpcRequestError.InvalidLink;
}

fn parse_work_string(value: []const u8) !u64 {
    var trimmed = value;
    if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) {
        trimmed = trimmed[2..];
    }

    if (trimmed.len == 16 and is_hex_string(trimmed)) {
        return std.fmt.parseInt(u64, trimmed, 16) catch RpcRequestError.InvalidWork;
    }
    return std.fmt.parseInt(u64, trimmed, 10) catch RpcRequestError.InvalidWork;
}

fn is_hex_string(value: []const u8) bool {
    for (value) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return value.len > 0;
}

fn parse_u32_string(value: []const u8, comptime err_tag: RpcRequestError) !u32 {
    return std.fmt.parseInt(u32, value, 10) catch err_tag;
}

fn parse_u128_string(value: []const u8, comptime err_tag: RpcRequestError) !u128 {
    return std.fmt.parseInt(u128, value, 10) catch err_tag;
}

fn decimal_slice(buf: []u8, value: anytype) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value});
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const ledger_mod = @import("../ledger/ledger.zig");
const validator = @import("../ledger/validator.zig");
const store_mod = @import("../store/store.zig");
const wallet_mod = @import("../wallet/wallet.zig");
const DerivedAccount = wallet_mod.DerivedAccount;
const NullStore = @import("../store/null_store.zig").NullStore;

const FakeProcessResult = ledger_mod.ProcessResult;
const TestHandlers = RpcHandlers(FakeLedger, FakeWallet);

const FakeLedger = struct {
    store: *NullStore,
    last_processed: ?StateBlock = null,

    pub fn init(store: *NullStore) FakeLedger {
        return .{ .store = store };
    }

    pub fn get_account_info(self: *FakeLedger, account: *const [32]u8) ?store_mod.AccountInfo {
        return self.store.get_account(account);
    }

    pub fn get_pending(self: *FakeLedger, account: *const [32]u8, send_hash: *const [32]u8) ?store_mod.PendingInfo {
        return self.store.get_pending(account, send_hash);
    }

    pub fn confirmation_height(self: *FakeLedger, account: *const [32]u8) u64 {
        return if (self.store.get_confirmation_height(account)) |ch| ch.height else 0;
    }

    pub fn process(self: *FakeLedger, blk: *const StateBlock) !FakeProcessResult {
        self.last_processed = blk.*;

        const account_info = self.store.get_account(&blk.account);
        const prior_balance: u128 = if (account_info) |info| info.balance else 0;
        const prior_height: u64 = if (account_info) |info| info.height else 0;
        const block_type = validator.classify(blk, prior_balance);

        return .{
            .hash = blk.hash(),
            .block_type = block_type,
            .new_height = prior_height + 1,
        };
    }
};

const FakeWallet = struct {
    unlock_calls: usize = 0,
    locked: bool = true,
    send_block: StateBlock,
    receive_block: StateBlock,
    derived: DerivedAccount,

    pub fn unlock(self: *FakeWallet, password: []const u8) !void {
        if (!std.mem.eql(u8, password, "secret")) return error.AuthenticationFailed;
        self.unlock_calls += 1;
        self.locked = false;
    }

    pub fn lock(self: *FakeWallet) void {
        self.locked = true;
    }

    pub fn derive_account(self: *FakeWallet, index: u32) !DerivedAccount {
        if (self.locked) return error.Locked;
        var out = self.derived;
        out.index = index;
        return out;
    }

    pub fn create_send(self: *FakeWallet, from: [32]u8, to: [32]u8, amount: u128) !StateBlock {
        _ = amount;
        var blk = self.send_block;
        blk.account = from;
        blk.link = to;
        return blk;
    }

    pub fn create_receive(self: *FakeWallet, account: [32]u8, pending_hash: [32]u8) !StateBlock {
        var blk = self.receive_block;
        blk.account = account;
        blk.link = pending_hash;
        return blk;
    }
};

fn make_test_block(account: [32]u8, previous: [32]u8, representative: [32]u8, balance: u128, link: [32]u8) StateBlock {
    return .{
        .account = account,
        .previous = previous,
        .representative = representative,
        .balance = balance,
        .link = link,
        .work = 0x0102030405060708,
        .signature = [_]u8{0xAB} ** 64,
    };
}

fn make_test_handlers(store: *NullStore) TestHandlers {
    const account = [_]u8{0x11} ** 32;
    const representative = [_]u8{0x22} ** 32;
    const send_block = make_test_block(account, [_]u8{0x33} ** 32, representative, 90, [_]u8{0x44} ** 32);
    const receive_block = make_test_block(account, [_]u8{0x55} ** 32, representative, 125, [_]u8{0x66} ** 32);

    var address: [64]u8 = undefined;
    Account.from_bytes(&account).to_address(&address);

    const derived = DerivedAccount{
        .index = 0,
        .public_key = account,
        .address = address,
    };

    const ledger = testing.allocator.create(FakeLedger) catch unreachable;
    ledger.* = FakeLedger.init(store);

    const wallet = testing.allocator.create(FakeWallet) catch unreachable;
    wallet.* = .{
        .send_block = send_block,
        .receive_block = receive_block,
        .derived = derived,
    };

    return TestHandlers.init(testing.allocator, ledger, wallet);
}

fn free_test_handlers(handlers: *TestHandlers) void {
    testing.allocator.destroy(handlers.ledger);
    testing.allocator.destroy(handlers.wallet);
}

test "rpc handlers: account_info returns frontier, balance, and confirmation height" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const account = [_]u8{0x11} ** 32;
    const representative = [_]u8{0x22} ** 32;
    try store.put_account(&account, .{
        .frontier = [_]u8{0xAA} ** 32,
        .balance = 123,
        .representative = representative,
        .height = 7,
        .modified = 0,
    });
    try store.put_confirmation_height(&account, .{
        .height = 5,
        .frontier = [_]u8{0xBB} ** 32,
    });

    var handlers = make_test_handlers(&store);
    defer free_test_handlers(&handlers);

    var account_address: [64]u8 = undefined;
    Account.from_bytes(&account).to_address(&account_address);
    const body = try std.fmt.allocPrint(testing.allocator, "{{\"action\":\"account_info\",\"account\":\"{s}\"}}", .{account_address});
    defer testing.allocator.free(body);

    const response = try handlers.handle(testing.allocator, body);
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"balance\":\"123\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"height\":\"7\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"confirmation_height\":\"5\"") != null);
}

test "rpc handlers: process decodes a state block and returns its hash" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    var handlers = make_test_handlers(&store);
    defer free_test_handlers(&handlers);

    const account = [_]u8{0x31} ** 32;
    const representative = [_]u8{0x41} ** 32;
    const previous = [_]u8{0} ** 32;
    const link = [_]u8{0x51} ** 32;
    const blk = make_test_block(account, previous, representative, 77, link);

    var account_address: [64]u8 = undefined;
    var representative_address: [64]u8 = undefined;
    Account.from_bytes(&blk.account).to_address(&account_address);
    Account.from_bytes(&blk.representative).to_address(&representative_address);
    const link_hex = std.fmt.bytesToHex(blk.link, .lower);
    const previous_hex = std.fmt.bytesToHex(blk.previous, .lower);
    const signature_hex = std.fmt.bytesToHex(blk.signature, .lower);

    const body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"action\":\"process\",\"block\":{{\"type\":\"state\",\"account\":\"{s}\",\"previous\":\"{s}\",\"representative\":\"{s}\",\"balance\":\"{d}\",\"link\":\"{s}\",\"work\":\"0x{x}\",\"signature\":\"{s}\"}}}}",
        .{ account_address, previous_hex, representative_address, blk.balance, link_hex, blk.work, signature_hex },
    );
    defer testing.allocator.free(body);

    const response = try handlers.handle(testing.allocator, body);
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"block_type\":\"open\"") != null);
    try testing.expectEqual(blk.account, handlers.ledger.last_processed.?.account);
    try testing.expectEqual(blk.link, handlers.ledger.last_processed.?.link);
}

test "rpc handlers: send and receive dispatch through wallet builders" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    try store.put_account(&([_]u8{0x11} ** 32), .{
        .frontier = [_]u8{0x33} ** 32,
        .balance = 100,
        .representative = [_]u8{0x22} ** 32,
        .height = 1,
        .modified = 0,
    });

    var handlers = make_test_handlers(&store);
    defer free_test_handlers(&handlers);

    const source = [_]u8{0x11} ** 32;
    const destination = [_]u8{0x99} ** 32;
    var source_address: [64]u8 = undefined;
    var destination_address: [64]u8 = undefined;
    Account.from_bytes(&source).to_address(&source_address);
    Account.from_bytes(&destination).to_address(&destination_address);

    const send_body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"action\":\"send\",\"source\":\"{s}\",\"destination\":\"{s}\",\"amount\":\"25\"}}",
        .{ source_address, destination_address },
    );
    defer testing.allocator.free(send_body);

    const send_response = try handlers.handle(testing.allocator, send_body);
    defer testing.allocator.free(send_response);

    try testing.expect(std.mem.indexOf(u8, send_response, "\"block_type\":\"send\"") != null);
    try testing.expectEqual(destination, handlers.ledger.last_processed.?.link);

    const pending_hash = [_]u8{0x77} ** 32;
    const pending_hex = std.fmt.bytesToHex(pending_hash, .lower);
    const receive_body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"action\":\"receive\",\"account\":\"{s}\",\"hash\":\"{s}\"}}",
        .{ source_address, pending_hex },
    );
    defer testing.allocator.free(receive_body);

    const receive_response = try handlers.handle(testing.allocator, receive_body);
    defer testing.allocator.free(receive_response);

    try testing.expect(std.mem.indexOf(u8, receive_response, "\"block_type\":\"receive\"") != null);
    try testing.expectEqual(pending_hash, handlers.ledger.last_processed.?.link);
}

test "rpc handlers: wallet lock, unlock, and account creation work together" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    var handlers = make_test_handlers(&store);
    defer free_test_handlers(&handlers);

    const unlock_response = try handlers.handle(testing.allocator, "{\"action\":\"wallet_unlock\",\"password\":\"secret\"}");
    defer testing.allocator.free(unlock_response);
    try testing.expect(std.mem.indexOf(u8, unlock_response, "\"unlocked\":true") != null);

    const create_response = try handlers.handle(testing.allocator, "{\"action\":\"account_create\",\"index\":\"9\"}");
    defer testing.allocator.free(create_response);
    try testing.expect(std.mem.indexOf(u8, create_response, "\"index\":\"9\"") != null);
    try testing.expect(std.mem.indexOf(u8, create_response, "\"account\":\"smn_") != null);

    const lock_response = try handlers.handle(testing.allocator, "{\"action\":\"wallet_lock\"}");
    defer testing.allocator.free(lock_response);
    try testing.expect(std.mem.indexOf(u8, lock_response, "\"locked\":true") != null);
}

test "rpc handlers: invalid json and unknown actions return error objects" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    var handlers = make_test_handlers(&store);
    defer free_test_handlers(&handlers);

    const invalid_json = try handlers.handle(testing.allocator, "{");
    defer testing.allocator.free(invalid_json);
    try testing.expect(std.mem.indexOf(u8, invalid_json, "\"error\":\"InvalidJson\"") != null);

    const invalid_action = try handlers.handle(testing.allocator, "{\"action\":\"unknown\"}");
    defer testing.allocator.free(invalid_action);
    try testing.expect(std.mem.indexOf(u8, invalid_action, "\"error\":\"UnknownAction\"") != null);
}

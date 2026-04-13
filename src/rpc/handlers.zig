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
const config_mod = @import("../config.zig");
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
        pub const PublishHook = struct {
            ctx: *anyopaque,
            publish_fn: *const fn (ctx: *anyopaque, blk: *const StateBlock) anyerror!ledger_mod.ProcessResult,
        };

        allocator: std.mem.Allocator,
        ledger: *LedgerType,
        wallet: *WalletType,
        config: *const config_mod.NodeConfig,
        publish_hook: ?PublishHook = null,

        pub fn init(
            allocator: std.mem.Allocator,
            ledger: *LedgerType,
            wallet: *WalletType,
            config: *const config_mod.NodeConfig,
            publish_hook: ?PublishHook,
        ) Self {
            return .{
                .allocator = allocator,
                .ledger = ledger,
                .wallet = wallet,
                .config = config,
                .publish_hook = publish_hook,
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

        pub fn handle_setup_get(self: *Self, allocator: std.mem.Allocator) ![]u8 {
            return render_setup_page(allocator, self.config, null);
        }

        pub fn handle_setup_post(self: *Self, allocator: std.mem.Allocator, body: []const u8) ![]u8 {
            var next = try self.config.clone(allocator);
            defer next.deinit(allocator);

            apply_setup_form(allocator, &next, body) catch |err| {
                return render_setup_page(allocator, &next, @errorName(err));
            };

            next.save(allocator) catch |err| {
                return render_setup_page(allocator, &next, @errorName(err));
            };

            return render_setup_success(allocator, &next);
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
            const result = if (self.publish_hook) |hook|
                try hook.publish_fn(hook.ctx, &blk)
            else
                try self.ledger.process(&blk);
            return process_response(allocator, result);
        }

        fn handle_receive(self: *Self, allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
            const account_key = try parse_account_string(try required_string(obj, "account"));
            const pending_hash = try parse_hash_string(try required_string(obj, "hash"));

            const blk = try self.wallet.create_receive(account_key, pending_hash);
            const result = if (self.publish_hook) |hook|
                try hook.publish_fn(hook.ctx, &blk)
            else
                try self.ledger.process(&blk);
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

const SetupFormError = std.mem.Allocator.Error || config_mod.NodeConfig.ValidationError || error{
    MissingField,
    InvalidInteger,
    InvalidNetwork,
    InvalidLogLevel,
    InvalidFormEncoding,
};

const FormField = struct {
    key: []u8,
    value: []u8,
};

fn render_setup_page(
    allocator: std.mem.Allocator,
    config: *const config_mod.NodeConfig,
    error_message: ?[]const u8,
) ![]u8 {
    const data_dir = try html_escape(allocator, config.data_dir);
    defer allocator.free(data_dir);
    const listen_address = try html_escape(allocator, config.listen_address);
    defer allocator.free(listen_address);
    const external_address = try html_escape(allocator, config.external_address orelse "");
    defer allocator.free(external_address);
    const config_path = try html_escape(allocator, config.config_path);
    defer allocator.free(config_path);
    const peer_seeds = try join_lines(allocator, config.peer_seeds.items);
    defer allocator.free(peer_seeds);
    const peer_seeds_escaped = try html_escape(allocator, peer_seeds);
    defer allocator.free(peer_seeds_escaped);
    const bootstrap_peers = try join_lines(allocator, config.bootstrap_peers.items);
    defer allocator.free(bootstrap_peers);
    const bootstrap_peers_escaped = try html_escape(allocator, bootstrap_peers);
    defer allocator.free(bootstrap_peers_escaped);
    const error_html = if (error_message) |msg| blk: {
        const escaped_error = try html_escape(allocator, msg);
        defer allocator.free(escaped_error);
        break :blk try std.fmt.allocPrint(
            allocator,
            "<p class=\"error\">Save failed: {s}</p>",
            .{escaped_error},
        );
    } else try allocator.dupe(u8, "");
    defer allocator.free(error_html);

    return std.fmt.allocPrint(
        allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>smallnano Setup</title>
        \\  <style>
        \\    :root {{ color-scheme: light; }}
        \\    body {{ font-family: Georgia, "Times New Roman", serif; margin: 0; background: #f4efe1; color: #1f1808; }}
        \\    main {{ max-width: 880px; margin: 0 auto; padding: 32px 20px 56px; }}
        \\    h1 {{ margin: 0 0 8px; font-size: 2.25rem; }}
        \\    p {{ line-height: 1.5; }}
        \\    .note {{ background: #fff8dd; border: 1px solid #d8c376; padding: 14px 16px; border-radius: 10px; }}
        \\    .error {{ background: #fff0ee; border: 1px solid #d48f83; padding: 14px 16px; border-radius: 10px; color: #7a2517; }}
        \\    form {{ background: #fffdf7; border: 1px solid #dbcda3; border-radius: 14px; padding: 24px; margin-top: 20px; }}
        \\    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; }}
        \\    label {{ display: block; font-weight: 700; margin-bottom: 6px; }}
        \\    input, select, textarea {{ width: 100%; box-sizing: border-box; border: 1px solid #b7a770; border-radius: 8px; padding: 10px 12px; background: #fff; font: inherit; }}
        \\    textarea {{ min-height: 108px; resize: vertical; }}
        \\    .field {{ margin-bottom: 16px; }}
        \\    .hint {{ font-size: 0.92rem; color: #5d5130; margin-top: 4px; }}
        \\    .checkbox {{ display: flex; gap: 10px; align-items: center; padding-top: 8px; }}
        \\    .checkbox input {{ width: auto; }}
        \\    button {{ border: 0; border-radius: 999px; padding: 12px 18px; background: #b8860b; color: #fffdf6; font-weight: 700; cursor: pointer; }}
        \\    code {{ background: #f1ead3; padding: 2px 6px; border-radius: 6px; }}
        \\  </style>
        \\</head>
        \\<body>
        \\  <main>
        \\    <h1>smallnano local setup</h1>
        \\    <p>Use this page to edit <code>{s}</code>. Changes are saved to disk for the next restart.</p>
        \\    <div class="note">
        \\      <strong>Important:</strong> after saving, stop the node and start it again so the new config is applied.
        \\    </div>
        \\    {s}
        \\    <form method="post" action="/setup">
        \\      <div class="grid">
        \\        <div class="field"><label for="network">Network</label><select id="network" name="network"><option value="main" {s}>main</option><option value="beta" {s}>beta</option><option value="dev" {s}>dev</option></select></div>
        \\        <div class="field"><label for="log_level">Log level</label><select id="log_level" name="log_level"><option value="err" {s}>err</option><option value="warn" {s}>warn</option><option value="info" {s}>info</option><option value="debug" {s}>debug</option></select></div>
        \\      </div>
        \\      <div class="grid">
        \\        <div class="field"><label for="data_dir">Data directory</label><input id="data_dir" name="data_dir" value="{s}"><div class="hint">Example: <code>./devnet/data</code></div></div>
        \\        <div class="field"><label for="listen_address">Listen address</label><input id="listen_address" name="listen_address" value="{s}"><div class="hint">Use <code>0.0.0.0</code> to listen on all interfaces.</div></div>
        \\      </div>
        \\      <div class="grid">
        \\        <div class="field"><label for="external_address">External address</label><input id="external_address" name="external_address" value="{s}"><div class="hint">Optional. Leave blank if you do not want to advertise one.</div></div>
        \\        <div class="field checkbox"><input id="enable_voting" type="checkbox" name="enable_voting" value="true" {s}><label for="enable_voting">Enable representative voting</label></div>
        \\      </div>
        \\      <div class="grid">
        \\        <div class="field"><label for="rpc_port">RPC port</label><input id="rpc_port" name="rpc_port" value="{d}"></div>
        \\        <div class="field"><label for="peering_port">Peering port</label><input id="peering_port" name="peering_port" value="{d}"></div>
        \\        <div class="field"><label for="max_peers">Max peers</label><input id="max_peers" name="max_peers" value="{d}"></div>
        \\      </div>
        \\      <div class="grid">
        \\        <div class="field"><label for="work_threads">Work threads</label><input id="work_threads" name="work_threads" value="{d}"></div>
        \\        <div class="field"><label for="bandwidth_limit_mbps">Bandwidth limit Mbps</label><input id="bandwidth_limit_mbps" name="bandwidth_limit_mbps" value="{d}"></div>
        \\        <div class="field"><label for="max_pending_elections">Max pending elections</label><input id="max_pending_elections" name="max_pending_elections" value="{d}"></div>
        \\      </div>
        \\      <div class="field"><label for="max_blocks_per_account">Max blocks per account</label><input id="max_blocks_per_account" name="max_blocks_per_account" value="{d}"><div class="hint">Controls pruning depth.</div></div>
        \\      <div class="field"><label for="peer_seeds">Peer seeds</label><textarea id="peer_seeds" name="peer_seeds">{s}</textarea><div class="hint">One <code>host:port</code> per line, such as <code>192.0.2.10:7176</code> or <code>node2:7276</code>.</div></div>
        \\      <div class="field"><label for="bootstrap_peers">Bootstrap peers</label><textarea id="bootstrap_peers" name="bootstrap_peers">{s}</textarea><div class="hint">Optional preferred peers, one <code>host:port</code> per line.</div></div>
        \\      <button type="submit">Save config</button>
        \\    </form>
        \\  </main>
        \\</body>
        \\</html>
    ,
        .{
            config_path,
            error_html,
            selected_attr(config.network == .main),
            selected_attr(config.network == .beta),
            selected_attr(config.network == .dev),
            selected_attr(config.log_level == .err),
            selected_attr(config.log_level == .warn),
            selected_attr(config.log_level == .info),
            selected_attr(config.log_level == .debug),
            data_dir,
            listen_address,
            external_address,
            checked_attr(config.enable_voting),
            config.rpc_port,
            config.peering_port,
            config.max_peers,
            config.work_threads,
            config.bandwidth_limit_mbps,
            config.max_pending_elections,
            config.max_blocks_per_account,
            peer_seeds_escaped,
            bootstrap_peers_escaped,
        },
    );
}

fn render_setup_success(allocator: std.mem.Allocator, config: *const config_mod.NodeConfig) ![]u8 {
    const config_path = try html_escape(allocator, config.config_path);
    defer allocator.free(config_path);
    return std.fmt.allocPrint(
        allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>smallnano Setup Saved</title></head>
        \\<body style="font-family: Georgia, serif; background: #f4efe1; color: #1f1808; margin: 0;">
        \\  <main style="max-width: 760px; margin: 0 auto; padding: 36px 20px;">
        \\    <h1>Config saved</h1>
        \\    <p>The file <code>{s}</code> was updated successfully.</p>
        \\    <p><strong>Next step:</strong> stop the node and start it again so the new config is applied.</p>
        \\    <p><a href="/setup">Back to setup page</a></p>
        \\  </main>
        \\</body>
        \\</html>
    ,
        .{config_path},
    );
}

fn apply_setup_form(
    allocator: std.mem.Allocator,
    config: *config_mod.NodeConfig,
    body: []const u8,
) SetupFormError!void {
    var fields = try parse_form_fields(allocator, body);
    defer {
        for (fields.items) |field| {
            allocator.free(field.key);
            allocator.free(field.value);
        }
        fields.deinit(allocator);
    }

    try replace_owned_string(allocator, &config.data_dir, try required_form_value(fields.items, "data_dir"));
    try replace_owned_string(allocator, &config.listen_address, try required_form_value(fields.items, "listen_address"));
    try replace_optional_string(allocator, &config.external_address, optional_form_value(fields.items, "external_address"));
    try replace_string_list_from_textarea(allocator, &config.peer_seeds, try required_form_value(fields.items, "peer_seeds"));
    try replace_string_list_from_textarea(allocator, &config.bootstrap_peers, try required_form_value(fields.items, "bootstrap_peers"));

    config.max_blocks_per_account = try parse_u32(try required_form_value(fields.items, "max_blocks_per_account"));
    config.max_peers = try parse_u32(try required_form_value(fields.items, "max_peers"));
    config.work_threads = try parse_u32(try required_form_value(fields.items, "work_threads"));
    config.rpc_port = try parse_u16(try required_form_value(fields.items, "rpc_port"));
    config.peering_port = try parse_u16(try required_form_value(fields.items, "peering_port"));
    config.network = try parse_network_field(try required_form_value(fields.items, "network"));
    config.bandwidth_limit_mbps = try parse_u32(try required_form_value(fields.items, "bandwidth_limit_mbps"));
    config.max_pending_elections = try parse_u32(try required_form_value(fields.items, "max_pending_elections"));
    config.enable_voting = optional_form_value(fields.items, "enable_voting") != null;
    config.log_level = try parse_log_level_field(try required_form_value(fields.items, "log_level"));

    try config.validate();
}

fn parse_form_fields(
    allocator: std.mem.Allocator,
    body: []const u8,
) !std.ArrayList(FormField) {
    var fields: std.ArrayList(FormField) = .empty;
    errdefer {
        for (fields.items) |field| {
            allocator.free(field.key);
            allocator.free(field.value);
        }
        fields.deinit(allocator);
    }

    var parts = std.mem.splitScalar(u8, body, '&');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse return error.InvalidFormEncoding;
        try fields.append(allocator, .{
            .key = try percent_decode(allocator, part[0..eq]),
            .value = try percent_decode(allocator, part[eq + 1 ..]),
        });
    }
    return fields;
}

fn required_form_value(fields: []const FormField, key: []const u8) SetupFormError![]const u8 {
    return optional_form_value(fields, key) orelse error.MissingField;
}

fn optional_form_value(fields: []const FormField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key)) return field.value;
    }
    return null;
}

fn percent_decode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (c == '+') {
            try out.append(allocator, ' ');
            continue;
        }
        if (c == '%') {
            if (i + 2 >= value.len) return error.InvalidFormEncoding;
            const hi = std.fmt.charToDigit(value[i + 1], 16) catch return error.InvalidFormEncoding;
            const lo = std.fmt.charToDigit(value[i + 2], 16) catch return error.InvalidFormEncoding;
            try out.append(allocator, @as(u8, @intCast(hi * 16 + lo)));
            i += 2;
            continue;
        }
        try out.append(allocator, c);
    }

    return out.toOwnedSlice(allocator);
}

fn replace_owned_string(allocator: std.mem.Allocator, target: *[]u8, value: []const u8) !void {
    const duped = try allocator.dupe(u8, value);
    allocator.free(target.*);
    target.* = duped;
}

fn replace_optional_string(allocator: std.mem.Allocator, target: *?[]u8, value: ?[]const u8) !void {
    if (target.*) |existing| allocator.free(existing);
    if (value) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) {
            target.* = null;
        } else {
            target.* = try allocator.dupe(u8, trimmed);
        }
    } else {
        target.* = null;
    }
}

fn replace_string_list_from_textarea(
    allocator: std.mem.Allocator,
    target: *std.ArrayList([]u8),
    value: []const u8,
) !void {
    var next: std.ArrayList([]u8) = .empty;
    errdefer {
        for (next.items) |item| allocator.free(item);
        next.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, value, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        try next.append(allocator, try allocator.dupe(u8, line));
    }

    for (target.items) |item| allocator.free(item);
    target.deinit(allocator);
    target.* = next;
}

fn parse_u32(value: []const u8) SetupFormError!u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t\r\n"), 10) catch error.InvalidInteger;
}

fn parse_u16(value: []const u8) SetupFormError!u16 {
    return std.fmt.parseInt(u16, std.mem.trim(u8, value, " \t\r\n"), 10) catch error.InvalidInteger;
}

fn parse_network_field(value: []const u8) SetupFormError!config_mod.Network {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "main")) return .main;
    if (std.mem.eql(u8, trimmed, "beta")) return .beta;
    if (std.mem.eql(u8, trimmed, "dev")) return .dev;
    return error.InvalidNetwork;
}

fn parse_log_level_field(value: []const u8) SetupFormError!config_mod.LogLevel {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "err")) return .err;
    if (std.mem.eql(u8, trimmed, "warn")) return .warn;
    if (std.mem.eql(u8, trimmed, "info")) return .info;
    if (std.mem.eql(u8, trimmed, "debug")) return .debug;
    return error.InvalidLogLevel;
}

fn join_lines(allocator: std.mem.Allocator, values: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (values, 0..) |value, i| {
        if (i != 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, value);
    }
    return out.toOwnedSlice(allocator);
}

fn html_escape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (value) |c| switch (c) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '"' => try out.appendSlice(allocator, "&quot;"),
        '\'' => try out.appendSlice(allocator, "&#39;"),
        else => try out.append(allocator, c),
    };
    return out.toOwnedSlice(allocator);
}

fn selected_attr(selected: bool) []const u8 {
    return if (selected) "selected" else "";
}

fn checked_attr(checked: bool) []const u8 {
    return if (checked) "checked" else "";
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

const FakePublisher = struct {
    calls: usize = 0,
    last_published: ?StateBlock = null,
    result: FakeProcessResult,

    pub fn publish(self: *FakePublisher, blk: *const StateBlock) !FakeProcessResult {
        self.calls += 1;
        self.last_published = blk.*;
        return self.result;
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

fn make_test_config(config_path: []const u8) *config_mod.NodeConfig {
    const config = testing.allocator.create(config_mod.NodeConfig) catch unreachable;
    config.* = config_mod.NodeConfig.init(
        testing.allocator,
        testing.allocator.dupe(u8, config_path) catch unreachable,
    ) catch unreachable;
    config.network = .dev;
    return config;
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

    const config = make_test_config("test-config.toml");
    return TestHandlers.init(testing.allocator, ledger, wallet, config, null);
}

fn make_test_handlers_with_publish(store: *NullStore, publisher: *FakePublisher) TestHandlers {
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

    const config = make_test_config("test-config.toml");
    return TestHandlers.init(testing.allocator, ledger, wallet, config, .{
        .ctx = publisher,
        .publish_fn = struct {
            fn f(ctx: *anyopaque, blk: *const StateBlock) anyerror!FakeProcessResult {
                const publisher_ptr: *FakePublisher = @ptrCast(@alignCast(ctx));
                return publisher_ptr.publish(blk);
            }
        }.f,
    });
}

fn free_test_handlers(handlers: *TestHandlers) void {
    var config = @constCast(handlers.config);
    config.deinit(testing.allocator);
    testing.allocator.destroy(config);
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

test "rpc handlers: send and receive use the publish hook when available" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    try store.put_account(&([_]u8{0x11} ** 32), .{
        .frontier = [_]u8{0x33} ** 32,
        .balance = 100,
        .representative = [_]u8{0x22} ** 32,
        .height = 1,
        .modified = 0,
    });

    var publisher = FakePublisher{
        .result = .{
            .hash = [_]u8{0x88} ** 32,
            .block_type = .send,
            .new_height = 2,
        },
    };

    var handlers = make_test_handlers_with_publish(&store, &publisher);
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
    try testing.expectEqual(@as(usize, 1), publisher.calls);
    try testing.expectEqual(destination, publisher.last_published.?.link);
    try testing.expect(handlers.ledger.last_processed == null);

    const pending_hash = [_]u8{0x77} ** 32;
    const pending_hex = std.fmt.bytesToHex(pending_hash, .lower);
    publisher.result = .{
        .hash = [_]u8{0x99} ** 32,
        .block_type = .receive,
        .new_height = 3,
    };
    const receive_body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"action\":\"receive\",\"account\":\"{s}\",\"hash\":\"{s}\"}}",
        .{ source_address, pending_hex },
    );
    defer testing.allocator.free(receive_body);

    const receive_response = try handlers.handle(testing.allocator, receive_body);
    defer testing.allocator.free(receive_response);

    try testing.expect(std.mem.indexOf(u8, receive_response, "\"block_type\":\"receive\"") != null);
    try testing.expectEqual(@as(usize, 2), publisher.calls);
    try testing.expectEqual(pending_hash, publisher.last_published.?.link);
    try testing.expect(handlers.ledger.last_processed == null);
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

test "rpc handlers: setup page renders current config values" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    var handlers = make_test_handlers(&store);
    defer free_test_handlers(&handlers);

    const page = try handlers.handle_setup_get(testing.allocator);
    defer testing.allocator.free(page);

    try testing.expect(std.mem.indexOf(u8, page, "<form method=\"post\" action=\"/setup\">") != null);
    try testing.expect(std.mem.indexOf(u8, page, "name=\"data_dir\"") != null);
    try testing.expect(std.mem.indexOf(u8, page, "name=\"peer_seeds\"") != null);
    try testing.expect(std.mem.indexOf(u8, page, handlers.config.config_path) != null);
}

test "rpc handlers: setup post saves edited config for next restart" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/config.toml",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(config_path);

    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    var handlers = make_test_handlers(&store);
    defer free_test_handlers(&handlers);

    var config = @constCast(handlers.config);
    config.deinit(testing.allocator);
    config.* = config_mod.NodeConfig.init(
        testing.allocator,
        try testing.allocator.dupe(u8, config_path),
    ) catch unreachable;

    const form =
        "network=dev&log_level=debug&data_dir=.%2Fdevnet%2Fdata&listen_address=0.0.0.0&external_address=192.168.1.50&enable_voting=true&rpc_port=7277&peering_port=7276&max_peers=25&work_threads=1&bandwidth_limit_mbps=15&max_pending_elections=800&max_blocks_per_account=1500&peer_seeds=192.168.1.11%3A7276%0A192.168.1.12%3A7376&bootstrap_peers=192.168.1.11%3A7276";

    const response = try handlers.handle_setup_post(testing.allocator, form);
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "Config saved") != null);

    const contents = try tmp.dir.readFileAlloc(testing.allocator, "config.toml", 16 * 1024);
    defer testing.allocator.free(contents);

    try testing.expect(std.mem.indexOf(u8, contents, "network = \"dev\"") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "external_address = \"192.168.1.50\"") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "peer_seeds = [\"192.168.1.11:7276\", \"192.168.1.12:7376\"]") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "bootstrap_peers = [\"192.168.1.11:7276\"]") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "max_blocks_per_account = 1500") != null);
}

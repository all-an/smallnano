/// Node configuration — defaults, generated TOML, CLI overlays, and validation.
///
/// `load()` resolves a config path, writes a commented default config file if it
/// does not exist yet, parses the TOML-like key/value file, overlays CLI flags,
/// validates all limits, and returns the final `NodeConfig`.
///
/// The parser intentionally supports only the flat scalar fields used by
/// smallnano today. This keeps startup code dependency-free and easy to audit.
const std = @import("std");
const builtin = @import("builtin");
const message = @import("network/message.zig");

pub const Network = message.Network;

pub const LogLevel = enum {
    err,
    warn,
    info,
    debug,
};

pub const NodeConfig = struct {
    config_path: []u8,
    max_blocks_per_account: u32 = 1000,
    max_peers: u32 = 50,
    work_threads: u32 = 1,
    rpc_port: u16 = 7177,
    peering_port: u16 = 7176,
    network: Network = .main,
    bandwidth_limit_mbps: u32 = 10,
    max_pending_elections: u32 = 500,
    enable_voting: bool = false,
    log_level: LogLevel = .info,

    pub const ValidationError = error{
        InvalidMaxBlocksPerAccount,
        InvalidMaxPeers,
        InvalidWorkThreads,
        InvalidRpcPort,
        InvalidPeeringPort,
        DuplicatePort,
        InvalidBandwidthLimitMbps,
        InvalidMaxPendingElections,
    };

    pub fn init(config_path: []u8) NodeConfig {
        return .{ .config_path = config_path };
    }

    pub fn deinit(self: *NodeConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.config_path);
    }

    pub fn validate(self: *const NodeConfig) ValidationError!void {
        if (self.max_blocks_per_account == 0) return ValidationError.InvalidMaxBlocksPerAccount;
        if (self.max_peers == 0) return ValidationError.InvalidMaxPeers;
        if (self.work_threads == 0) return ValidationError.InvalidWorkThreads;
        if (self.rpc_port == 0) return ValidationError.InvalidRpcPort;
        if (self.peering_port == 0) return ValidationError.InvalidPeeringPort;
        if (self.rpc_port == self.peering_port) return ValidationError.DuplicatePort;
        if (self.bandwidth_limit_mbps == 0) return ValidationError.InvalidBandwidthLimitMbps;
        if (self.max_pending_elections == 0) return ValidationError.InvalidMaxPendingElections;
    }
};

pub const LoadError = NodeConfig.ValidationError || ParseError || std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.Dir.MakeError || std.fs.Dir.StatFileError || std.fs.File.ReadError || std.fs.File.WriteError || std.fs.Dir.WriteFileError || error{
    HelpRequested,
    ConfigPathUnavailable,
    MissingFlagValue,
    UnknownFlag,
    InvalidCommand,
};

const CliOverrides = struct {
    config_path: ?[]const u8 = null,
    max_blocks_per_account: ?u32 = null,
    max_peers: ?u32 = null,
    work_threads: ?u32 = null,
    rpc_port: ?u16 = null,
    peering_port: ?u16 = null,
    network: ?Network = null,
    bandwidth_limit_mbps: ?u32 = null,
    max_pending_elections: ?u32 = null,
    enable_voting: ?bool = null,
    log_level: ?LogLevel = null,
    help_requested: bool = false,
};

pub const ParseError = error{
    InvalidLine,
    UnknownField,
    InvalidString,
    InvalidInteger,
    InvalidBoolean,
    InvalidNetwork,
    InvalidLogLevel,
};

pub fn load(allocator: std.mem.Allocator, cli_args: []const []const u8) LoadError!NodeConfig {
    const cli = try parse_cli(cli_args);
    if (cli.help_requested) return error.HelpRequested;

    const config_path = if (cli.config_path) |path|
        try allocator.dupe(u8, path)
    else
        try default_config_path(allocator);
    errdefer allocator.free(config_path);

    try ensure_default_config(config_path);

    var config = NodeConfig.init(config_path);

    const contents = try read_text_file(allocator, config_path, 16 * 1024);
    defer allocator.free(contents);

    try parse_config_text(&config, contents);
    apply_cli_overrides(&config, cli);
    try config.validate();
    return config;
}

pub fn help_text(allocator: std.mem.Allocator, program_name: []const u8) ![]u8 {
    const default_path_owned = default_config_path(allocator) catch null;
    defer if (default_path_owned) |path| allocator.free(path);
    const default_path = default_path_owned orelse "HOME/.smallnano/config.toml";

    return std.fmt.allocPrint(
        allocator,
        \\Usage:
        \\  {s} [node run] [flags]
        \\
        \\Config:
        \\  Default path: {s}
        \\  The file is created automatically on first run.
        \\
        \\Flags:
        \\  --config <path>                    Config file path override
        \\  --max-blocks-per-account <u32>     Default: 1000
        \\  --max-peers <u32>                  Default: 50
        \\  --work-threads <u32>               Default: 1
        \\  --rpc-port <u16>                   Default: 7177
        \\  --peering-port <u16>               Default: 7176
        \\  --network <main|beta|dev>          Default: main
        \\  --bandwidth-limit-mbps <u32>       Default: 10
        \\  --max-pending-elections <u32>      Default: 500
        \\  --enable-voting                    Default: false
        \\  --disable-voting
        \\  --log-level <err|warn|info|debug>  Default: info
        \\  -h, --help                         Show this help
        \\
        \\Examples:
        \\  {s} node run --network dev
        \\  {s} --rpc-port 8080 --enable-voting
        \\
    ,
        .{ program_name, default_path, program_name, program_name },
    );
}

fn parse_cli(cli_args: []const []const u8) LoadError!CliOverrides {
    var args = cli_args;
    if (args.len > 0 and std.mem.eql(u8, args[0], "help")) {
        return .{ .help_requested = true };
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "node")) {
        if (args.len == 1) return error.InvalidCommand;
        if (!std.mem.eql(u8, args[1], "run")) return error.InvalidCommand;
        args = args[2..];
    } else if (args.len > 0 and std.mem.eql(u8, args[0], "run")) {
        args = args[1..];
    }

    var overrides = CliOverrides{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            overrides.help_requested = true;
            continue;
        }
        if (!std.mem.startsWith(u8, arg, "--")) return error.InvalidCommand;

        const split = split_flag(arg);
        const key = split.key;
        const value = if (split.value) |v|
            v
        else blk: {
            if (std.mem.eql(u8, key, "enable-voting")) break :blk "true";
            if (std.mem.eql(u8, key, "disable-voting")) break :blk "false";
            if (i + 1 >= args.len) return error.MissingFlagValue;
            i += 1;
            break :blk args[i];
        };

        if (std.mem.eql(u8, key, "config")) {
            overrides.config_path = value;
        } else if (std.mem.eql(u8, key, "max-blocks-per-account")) {
            overrides.max_blocks_per_account = parse_u32(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "max-peers")) {
            overrides.max_peers = parse_u32(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "work-threads")) {
            overrides.work_threads = parse_u32(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "rpc-port")) {
            overrides.rpc_port = parse_u16(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "peering-port")) {
            overrides.peering_port = parse_u16(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "network")) {
            overrides.network = try parse_network(value);
        } else if (std.mem.eql(u8, key, "bandwidth-limit-mbps")) {
            overrides.bandwidth_limit_mbps = parse_u32(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "max-pending-elections")) {
            overrides.max_pending_elections = parse_u32(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "enable-voting") or std.mem.eql(u8, key, "disable-voting")) {
            overrides.enable_voting = try parse_bool(value);
        } else if (std.mem.eql(u8, key, "log-level")) {
            overrides.log_level = try parse_log_level(value);
        } else {
            return error.UnknownFlag;
        }
    }

    return overrides;
}

fn apply_cli_overrides(config: *NodeConfig, cli: CliOverrides) void {
    if (cli.max_blocks_per_account) |v| config.max_blocks_per_account = v;
    if (cli.max_peers) |v| config.max_peers = v;
    if (cli.work_threads) |v| config.work_threads = v;
    if (cli.rpc_port) |v| config.rpc_port = v;
    if (cli.peering_port) |v| config.peering_port = v;
    if (cli.network) |v| config.network = v;
    if (cli.bandwidth_limit_mbps) |v| config.bandwidth_limit_mbps = v;
    if (cli.max_pending_elections) |v| config.max_pending_elections = v;
    if (cli.enable_voting) |v| config.enable_voting = v;
    if (cli.log_level) |v| config.log_level = v;
}

fn parse_config_text(config: *NodeConfig, contents: []const u8) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, strip_inline_comment(raw_line), " \t\r");
        if (line.len == 0) continue;

        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return ParseError.InvalidLine;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return ParseError.InvalidLine;

        if (std.mem.eql(u8, key, "max_blocks_per_account")) {
            config.max_blocks_per_account = parse_u32(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "max_peers")) {
            config.max_peers = parse_u32(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "work_threads")) {
            config.work_threads = parse_u32(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "rpc_port")) {
            config.rpc_port = parse_u16(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "peering_port")) {
            config.peering_port = parse_u16(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "network")) {
            config.network = try parse_network(value);
        } else if (std.mem.eql(u8, key, "bandwidth_limit_mbps")) {
            config.bandwidth_limit_mbps = parse_u32(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "max_pending_elections")) {
            config.max_pending_elections = parse_u32(value) catch return ParseError.InvalidInteger;
        } else if (std.mem.eql(u8, key, "enable_voting")) {
            config.enable_voting = try parse_bool(value);
        } else if (std.mem.eql(u8, key, "log_level")) {
            config.log_level = try parse_log_level(value);
        } else {
            return ParseError.UnknownField;
        }
    }
}

fn default_config_path(allocator: std.mem.Allocator) LoadError![]u8 {
    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "LOCALAPPDATA")) |base| {
            defer allocator.free(base);
            return std.fs.path.join(allocator, &.{ base, "smallnano", "config.toml" });
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |base| {
            defer allocator.free(base);
            return std.fs.path.join(allocator, &.{ base, ".smallnano", "config.toml" });
        } else |_| {}

        return error.ConfigPathUnavailable;
    }

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.ConfigPathUnavailable;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".smallnano", "config.toml" });
}

fn ensure_default_config(config_path: []const u8) !void {
    if (path_exists(config_path)) return;

    if (std.fs.path.dirname(config_path)) |dir_path| {
        try make_path(dir_path);
    }
    try write_text_file(config_path, default_config_text());
}

fn path_exists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn read_text_file(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return file.readToEndAlloc(allocator, max_bytes);
    }
    return std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}

fn write_text_file(path: []const u8, contents: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(contents);
        return;
    }
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = contents,
        .flags = .{ .truncate = true },
    });
}

fn make_path(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        try std.fs.cwd().makePath(path);
        return;
    }

    switch (builtin.os.tag) {
        .windows => {
            const root_len = absolute_root_len(path);
            var root_dir = try std.fs.openDirAbsolute(path[0..root_len], .{});
            defer root_dir.close();
            const relative = std.mem.trimLeft(u8, path[root_len..], "/\\");
            if (relative.len > 0) try root_dir.makePath(relative);
        },
        else => {
            var root_dir = try std.fs.openDirAbsolute("/", .{});
            defer root_dir.close();
            const relative = std.mem.trimLeft(u8, path[1..], "/");
            if (relative.len > 0) try root_dir.makePath(relative);
        },
    }
}

fn absolute_root_len(path: []const u8) usize {
    if (builtin.os.tag != .windows) return 1;
    const disk = std.fs.path.diskDesignator(path);
    if (disk.len == 0) return 1;
    if (path.len > disk.len and (path[disk.len] == '/' or path[disk.len] == '\\')) {
        return disk.len + 1;
    }
    return disk.len;
}

fn split_flag(arg: []const u8) struct { key: []const u8, value: ?[]const u8 } {
    const body = arg[2..];
    if (std.mem.indexOfScalar(u8, body, '=')) |idx| {
        return .{
            .key = body[0..idx],
            .value = body[idx + 1 ..],
        };
    }
    return .{ .key = body, .value = null };
}

fn strip_inline_comment(line: []const u8) []const u8 {
    var in_string = false;
    var escaped = false;
    for (line, 0..) |c, i| {
        if (c == '"' and !escaped) {
            in_string = !in_string;
        } else if (c == '#' and !in_string) {
            return line[0..i];
        }

        escaped = in_string and c == '\\' and !escaped;
        if (c != '\\') escaped = false;
    }
    return line;
}

fn parse_bool(value: []const u8) ParseError!bool {
    const bare = try parse_string_literal(value);
    if (std.mem.eql(u8, bare, "true")) return true;
    if (std.mem.eql(u8, bare, "false")) return false;
    return ParseError.InvalidBoolean;
}

fn parse_network(value: []const u8) ParseError!Network {
    const bare = try parse_string_literal(value);
    if (std.mem.eql(u8, bare, "main")) return .main;
    if (std.mem.eql(u8, bare, "beta")) return .beta;
    if (std.mem.eql(u8, bare, "dev")) return .dev;
    return ParseError.InvalidNetwork;
}

fn parse_log_level(value: []const u8) ParseError!LogLevel {
    const bare = try parse_string_literal(value);
    if (std.mem.eql(u8, bare, "err")) return .err;
    if (std.mem.eql(u8, bare, "warn")) return .warn;
    if (std.mem.eql(u8, bare, "info")) return .info;
    if (std.mem.eql(u8, bare, "debug")) return .debug;
    return ParseError.InvalidLogLevel;
}

fn parse_string_literal(value: []const u8) ParseError![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn parse_u32(value: []const u8) !u32 {
    return std.fmt.parseInt(u32, try parse_string_literal(value), 10);
}

fn parse_u16(value: []const u8) !u16 {
    return std.fmt.parseInt(u16, try parse_string_literal(value), 10);
}

fn default_config_text() []const u8 {
    return 
    \\# smallnano operator configuration
    \\# Generated automatically on first run.
    \\
    \\# Ledger pruning depth per account.
    \\max_blocks_per_account = 1000
    \\
    \\# Maximum simultaneous peer connections.
    \\max_peers = 50
    \\
    \\# CPU threads used for local proof-of-work generation.
    \\work_threads = 1
    \\
    \\# JSON-RPC HTTP port.
    \\rpc_port = 7177
    \\
    \\# P2P peering port.
    \\peering_port = 7176
    \\
    \\# Network: "main", "beta", or "dev".
    \\network = "main"
    \\
    \\# Combined bandwidth cap in megabits per second.
    \\bandwidth_limit_mbps = 10
    \\
    \\# Maximum active elections kept in memory.
    \\max_pending_elections = 500
    \\
    \\# Opt in to voting as a representative.
    \\enable_voting = false
    \\
    \\# Log level: "err", "warn", "info", or "debug".
    \\log_level = "info"
    \\
    ;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "config: parses generated defaults" {
    var config = NodeConfig.init(try testing.allocator.dupe(u8, "test-config.toml"));
    defer config.deinit(testing.allocator);

    try parse_config_text(&config, default_config_text());
    try config.validate();

    try testing.expectEqual(@as(u32, 1000), config.max_blocks_per_account);
    try testing.expectEqual(@as(u16, 7177), config.rpc_port);
    try testing.expectEqual(Network.main, config.network);
    try testing.expectEqual(LogLevel.info, config.log_level);
}

test "config: load writes default file when missing and applies cli overrides" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/config.toml", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var config = try load(testing.allocator, &.{
        "--config",
        rel_path,
        "--rpc-port=8080",
        "--network",
        "dev",
        "--enable-voting",
    });
    defer config.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 8080), config.rpc_port);
    try testing.expectEqual(Network.dev, config.network);
    try testing.expectEqual(true, config.enable_voting);

    const contents = try tmp.dir.readFileAlloc(testing.allocator, "config.toml", 16 * 1024);
    defer testing.allocator.free(contents);
    try testing.expect(std.mem.indexOf(u8, contents, "max_blocks_per_account = 1000") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "log_level = \"info\"") != null);
}

test "config: parses file values and strips inline comments" {
    var config = NodeConfig.init(try testing.allocator.dupe(u8, "test-config.toml"));
    defer config.deinit(testing.allocator);

    try parse_config_text(&config,
        \\max_blocks_per_account = 2048 # keep more history
        \\rpc_port = 9000
        \\peering_port = 9001
        \\network = "beta"
        \\bandwidth_limit_mbps = 25
        \\max_pending_elections = 750
        \\enable_voting = true
        \\log_level = "debug"
        \\
    );

    try config.validate();
    try testing.expectEqual(@as(u32, 2048), config.max_blocks_per_account);
    try testing.expectEqual(@as(u16, 9000), config.rpc_port);
    try testing.expectEqual(Network.beta, config.network);
    try testing.expectEqual(true, config.enable_voting);
    try testing.expectEqual(LogLevel.debug, config.log_level);
}

test "config: help text lists the operator flags" {
    const text = try help_text(testing.allocator, "smallnano");
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "--max-blocks-per-account <u32>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--network <main|beta|dev>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--enable-voting") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--log-level <err|warn|info|debug>") != null);
}

test "config: validation rejects duplicate ports" {
    var config = NodeConfig.init(try testing.allocator.dupe(u8, "test-config.toml"));
    defer config.deinit(testing.allocator);
    config.rpc_port = 7176;
    config.peering_port = 7176;

    try testing.expectError(NodeConfig.ValidationError.DuplicatePort, config.validate());
}

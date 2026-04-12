/// smallnano — a lightweight block-lattice cryptocurrency
///
/// Entry point. Subsystems are imported here so that `zig build test`
/// discovers every test block transitively.
const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("config.zig");
const node_mod = @import("node/node.zig");

// Pull in all modules so their tests are compiled when running `zig build test`
// from the root. Each module also compiles cleanly on its own.
comptime {
    _ = @import("config.zig");
    _ = @import("crypto/blake2b.zig");
    _ = @import("crypto/ed25519.zig");
    _ = @import("crypto/work.zig");
    _ = @import("types/amount.zig");
    _ = @import("types/account.zig");
    _ = @import("types/block.zig");
    _ = @import("types/vote.zig");
    _ = @import("types/pending.zig");
    _ = @import("types/genesis.zig");
    _ = @import("store/store.zig");
    _ = @import("store/null_store.zig");
    _ = @import("store/sqlite_store.zig");
    _ = @import("ledger/validator.zig");
    _ = @import("ledger/inserter.zig");
    _ = @import("ledger/pruner.zig");
    _ = @import("ledger/ledger.zig");
    _ = @import("ledger/block_processor.zig");
    _ = @import("network/message.zig");
    _ = @import("network/handshake.zig");
    _ = @import("network/channel.zig");
    _ = @import("network/bandwidth.zig");
    _ = @import("network/peer.zig");
    _ = @import("network/network.zig");
    _ = @import("consensus/rep_weights.zig");
    _ = @import("consensus/election.zig");
    _ = @import("consensus/active_elections.zig");
    _ = @import("consensus/confirmation.zig");
    _ = @import("consensus/vote_processor.zig");
    _ = @import("bootstrap/server.zig");
    _ = @import("bootstrap/client.zig");
    _ = @import("wallet/wallet.zig");
    _ = @import("rpc/handlers.zig");
    _ = @import("rpc/server.zig");
    _ = @import("node/node.zig");
}

var shutdown_requested = std.atomic.Value(bool).init(false);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);

    const config = config_mod.load(allocator, args[1..]) catch |err| switch (err) {
        error.HelpRequested => {
            const help = try config_mod.help_text(allocator, args[0]);
            defer allocator.free(help);
            try stdout_writer.interface.writeAll(help);
            try stdout_writer.interface.flush();
            return;
        },
        else => return err,
    };

    const wallet_password = try load_wallet_password(allocator);
    defer {
        std.crypto.secureZero(u8, wallet_password);
        allocator.free(wallet_password);
    }

    try install_shutdown_handlers();

    var node = try node_mod.SqliteNode.init(allocator, config, wallet_password);
    defer node.deinit();

    std.log.info("smallnano configuration loaded from {s}", .{node.config.config_path});
    std.log.info(
        "network={s} peering_port={d} rpc_port={d} max_peers={d}",
        .{
            @tagName(node.config.network),
            node.config.peering_port,
            node.config.rpc_port,
            node.config.max_peers,
        },
    );
    const node_id_hex = std.fmt.bytesToHex(node.node_id(), .lower);
    std.log.info("node runtime initialised: node_id={s} store={s}", .{
        node_id_hex[0..],
        node.store_path,
    });

    try node.start();
    std.log.info("node runtime started; waiting for shutdown signal", .{});

    wait_for_shutdown();

    std.log.info("shutdown requested; stopping node", .{});
    node.stop();
    std.log.info("node stopped cleanly", .{});
}

fn wait_for_shutdown() void {
    while (!shutdown_requested.load(.acquire)) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

fn install_shutdown_handlers() !void {
    shutdown_requested.store(false, .release);

    switch (builtin.os.tag) {
        .windows => try install_windows_shutdown_handler(),
        .linux,
        .macos,
        .ios,
        .watchos,
        .tvos,
        .visionos,
        .freebsd,
        .openbsd,
        .netbsd,
        .dragonfly,
        .solaris,
        .illumos,
        .haiku,
        .serenity,
        => install_posix_shutdown_handlers(),
        else => {},
    }
}

fn install_posix_shutdown_handlers() void {
    const posix = std.posix;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = posix_shutdown_handler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
}

fn posix_shutdown_handler(_: c_int) callconv(.c) void {
    request_shutdown();
}

fn install_windows_shutdown_handler() !void {
    const windows = std.os.windows;
    try windows.SetConsoleCtrlHandler(windows_shutdown_handler, true);
}

fn windows_shutdown_handler(ctrl_type: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    const windows = std.os.windows;
    switch (ctrl_type) {
        windows.CTRL_C_EVENT,
        windows.CTRL_BREAK_EVENT,
        windows.CTRL_CLOSE_EVENT,
        windows.CTRL_SHUTDOWN_EVENT,
        => {
            request_shutdown();
            return windows.TRUE;
        },
        else => return windows.FALSE,
    }
}

fn request_shutdown() void {
    shutdown_requested.store(true, .release);
}

fn load_wallet_password(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "SMALLNANO_WALLET_PASSWORD") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.log.warn(
                "SMALLNANO_WALLET_PASSWORD is not set; new wallets will be created with an empty password",
                .{},
            );
            return allocator.dupe(u8, "");
        },
        else => return err,
    };
}

test "main: request_shutdown flips the shutdown flag" {
    shutdown_requested.store(false, .release);
    request_shutdown();
    try std.testing.expect(shutdown_requested.load(.acquire));
    shutdown_requested.store(false, .release);
}

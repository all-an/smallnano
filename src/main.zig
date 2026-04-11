/// smallnano — a lightweight block-lattice cryptocurrency
///
/// Entry point. Subsystems are imported here so that `zig build test`
/// discovers every test block transitively.
const std = @import("std");

// Pull in all modules so their tests are compiled when running `zig build test`
// from the root. Each module also compiles cleanly on its own.
comptime {
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
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator();

    std.log.err("smallnano v0.1.0 — node not yet implemented", .{});
    std.process.exit(1);
}

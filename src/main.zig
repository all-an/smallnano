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
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    _ = allocator;

    const stderr = std.io.getStdErr().writer();
    try stderr.writeAll("smallnano v0.1.0 — not yet implemented\n");
    std.process.exit(1);
}

/// Benchmark harness for ledger block processing throughput.
///
/// This executable generates valid open blocks for fresh accounts, feeds them
/// through the real `Ledger.process()` path backed by `NullStore`, and prints
/// elapsed time plus blocks/second. It is intended for quick local profiling,
/// not consensus correctness.
const std = @import("std");
const ed25519 = @import("crypto/ed25519.zig");
const work_mod = @import("crypto/work.zig");
const ledger_mod = @import("ledger/ledger.zig");
const block_mod = @import("types/block.zig");
const NullStore = @import("store/null_store.zig").NullStore;

const StateBlock = block_mod.StateBlock;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const count = if (args.len >= 2)
        try std.fmt.parseInt(usize, args[1], 10)
    else
        50;

    var store = NullStore.init(allocator);
    defer store.deinit();
    var ledger = ledger_mod.Ledger(NullStore).init(&store, 1000);

    const pending_amount: u128 = 1_000_000_000_000_000_000_000_000;
    const started = std.time.nanoTimestamp();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const seed = seed_for_index(i);
        const kp = try ed25519.KeyPair.from_seed(&seed);
        const send_hash = hash_for_index(i);

        try store.put_pending(&kp.public, &send_hash, .{
            .source = [_]u8{0xA1} ** 32,
            .amount = pending_amount,
        });

        const block = try make_open_block(kp, pending_amount, send_hash);
        _ = try ledger.process(&block);
    }

    const elapsed_ns = std.time.nanoTimestamp() - started;
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);
    const blocks_per_second = if (seconds == 0.0)
        0.0
    else
        @as(f64, @floatFromInt(count)) / seconds;

    std.debug.print(
        "processed {d} blocks in {d} ns ({d:.2} blocks/sec)\n",
        .{ count, elapsed_ns, blocks_per_second },
    );
    std.debug.print(
        "measure RSS separately with your platform tool, e.g. `/usr/bin/time -v zig build bench-ledger -- {d}`\n",
        .{count},
    );
}

fn make_open_block(kp: ed25519.KeyPair, amount: u128, send_hash: [32]u8) !StateBlock {
    var blk = StateBlock{
        .account = kp.public,
        .previous = block_mod.ZERO_HASH,
        .representative = kp.public,
        .balance = amount,
        .link = send_hash,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    const hash = blk.hash();
    blk.signature = try ed25519.sign(&hash, &kp.secret);
    blk.work = work_mod.generate(&hash, work_mod.THRESHOLD_RECEIVE, 1);
    return blk;
}

fn seed_for_index(index: usize) [32]u8 {
    var seed = [_]u8{0} ** 32;
    std.mem.writeInt(u64, seed[0..8], @intCast(index + 1), .little);
    return seed;
}

fn hash_for_index(index: usize) [32]u8 {
    var hash = [_]u8{0xC4} ** 32;
    std.mem.writeInt(u64, hash[0..8], @intCast(index + 1), .little);
    return hash;
}

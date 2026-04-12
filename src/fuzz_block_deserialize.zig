/// Fuzz harness for `StateBlock.from_bytes`.
///
/// Feed arbitrary bytes on stdin. The harness walks 216-byte windows and forces
/// serialise/deserialise round-trips on each candidate block without asserting
/// any semantic validity.
const std = @import("std");
const block_mod = @import("types/block.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = try std.fs.File.stdin().readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(input);

    if (input.len == 0) return;

    if (input.len < block_mod.BLOCK_SIZE) {
        var padded = [_]u8{0} ** block_mod.BLOCK_SIZE;
        @memcpy(padded[0..input.len], input);
        const blk = block_mod.StateBlock.from_bytes(&padded);
        _ = blk.to_bytes();
        return;
    }

    var offset: usize = 0;
    while (offset + block_mod.BLOCK_SIZE <= input.len) : (offset += 1) {
        const bytes = input[offset .. offset + block_mod.BLOCK_SIZE][0..block_mod.BLOCK_SIZE];
        const blk = block_mod.StateBlock.from_bytes(bytes);
        _ = blk.to_bytes();
    }
}

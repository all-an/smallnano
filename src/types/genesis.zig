/// Genesis — the hard-coded first block of the smallnano network.
///
/// The genesis block opens the genesis account and credits it with the entire
/// fixed supply: 10,000,000 smn (10^31 raw).
///
/// No real funds are attached to these test keys. In a production launch,
/// the genesis account private key would be used once (to distribute initial
/// supply to founders/community) and then either published or burned.
///
/// The genesis block is the only block that is valid with:
///   - a zero `previous` field (open block, no prior state)
///   - a zero `work` field (genesis is exempt from PoW — it is hard-coded)
///   - the genesis account as both account and representative
///
/// Every node verifies the genesis block hash on startup against GENESIS_HASH.
/// A mismatch means the node is on a different network or has a corrupted build.
const std = @import("std");
const block = @import("block.zig");
const amount = @import("amount.zig");

// ── Genesis account ───────────────────────────────────────────────────────────

/// The genesis account public key (32 bytes, Ed25519).
/// This is a fixed test key — replace for mainnet launch.
pub const GENESIS_ACCOUNT: [32]u8 = .{
    0x1C, 0xB0, 0x88, 0x61, 0xF3, 0xAB, 0x25, 0xDE,
    0x71, 0x0B, 0x98, 0xE2, 0x34, 0xF7, 0x2D, 0xA5,
    0xE4, 0xDB, 0x22, 0x9B, 0x6F, 0xA1, 0x80, 0xCC,
    0x57, 0x3D, 0x49, 0x1E, 0x8B, 0xF4, 0x7C, 0x0A,
};

/// Total supply credited in the genesis block (10,000,000 smn).
pub const GENESIS_BALANCE: u128 = amount.TOTAL_SUPPLY_RAW;

// ── Genesis block ─────────────────────────────────────────────────────────────

/// Build and return the genesis StateBlock.
/// This is `comptime`-friendly: the result is a pure struct literal.
pub fn genesis_block() block.StateBlock {
    return block.StateBlock{
        // The genesis account both opens itself and is its own initial representative.
        .account = GENESIS_ACCOUNT,
        .previous = block.ZERO_HASH, // open block — no previous
        .representative = GENESIS_ACCOUNT,
        .balance = GENESIS_BALANCE,
        // link = zero for genesis (no source send block — supply is created here).
        .link = block.ZERO_HASH,
        // Genesis is exempt from PoW — it is validated by hash comparison only.
        .work = 0,
        // Signature is all zeros — genesis is authenticated by its hash alone.
        .signature = [_]u8{0} ** 64,
    };
}

/// The canonical hash of the genesis block. Every node validates against this
/// on startup to confirm they are on the correct network.
///
/// Computed once here at comptime by calling the block hash function.
pub const GENESIS_HASH: [32]u8 = blk: {
    // We cannot call runtime functions at comptime, so we compute the hash
    // inline using the same algorithm as blake2b.block_hash.
    // The preamble bytes and field layout must match blake2b.zig exactly.
    @setEvalBranchQuota(100_000);

    const preamble = [_]u8{0} ** 31 ++ [_]u8{0x01};
    const balance_be: [16]u8 = balance_to_be(GENESIS_BALANCE);

    // Concatenate all hash input fields.
    var input: [32 + 32 + 32 + 32 + 16 + 32]u8 = undefined;
    var off: usize = 0;
    for (preamble) |b| {
        input[off] = b;
        off += 1;
    }
    for (GENESIS_ACCOUNT) |b| {
        input[off] = b;
        off += 1;
    }
    for (block.ZERO_HASH) |b| {
        input[off] = b;
        off += 1;
    } // previous
    for (GENESIS_ACCOUNT) |b| {
        input[off] = b;
        off += 1;
    } // representative
    for (balance_be) |b| {
        input[off] = b;
        off += 1;
    }
    for (block.ZERO_HASH) |b| {
        input[off] = b;
        off += 1;
    } // link

    // Blake2b-256 of `input`. We use std.crypto at comptime.
    var digest: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(&input, &digest, .{});
    break :blk digest;
};

/// Helper: convert u128 to big-endian [16]u8 at comptime.
fn balance_to_be(v: u128) [16]u8 {
    var out: [16]u8 = undefined;
    var remaining = v;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        out[i] = @intCast(remaining & 0xFF);
        remaining >>= 8;
    }
    return out;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "genesis: genesis block hash matches GENESIS_HASH constant" {
    const gb = genesis_block();
    const computed = gb.hash();
    try std.testing.expectEqual(GENESIS_HASH, computed);
}

test "genesis: genesis balance equals total supply" {
    const gb = genesis_block();
    try std.testing.expectEqual(amount.TOTAL_SUPPLY_RAW, gb.balance);
}

test "genesis: genesis previous is zero (open block)" {
    const gb = genesis_block();
    try std.testing.expect(gb.is_open());
}

test "genesis: genesis account is representative" {
    const gb = genesis_block();
    try std.testing.expectEqual(gb.account, gb.representative);
}

test "genesis: genesis link is zero" {
    const gb = genesis_block();
    try std.testing.expectEqual(block.ZERO_HASH, gb.link);
}

test "genesis: GENESIS_HASH is non-zero" {
    // The hash of a non-trivial block should not be all zeros.
    const all_zero = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &GENESIS_HASH, &all_zero));
}

test "genesis: genesis block serialises and deserialises" {
    const gb = genesis_block();
    const bytes = gb.to_bytes();
    const decoded = block.StateBlock.from_bytes(&bytes);
    try std.testing.expectEqual(gb.account, decoded.account);
    try std.testing.expectEqual(gb.balance, decoded.balance);
    try std.testing.expectEqual(gb.previous, decoded.previous);
}

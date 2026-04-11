/// Blake2b wrappers for smallnano.
///
/// We expose three concrete functions:
///   hash256   — 32-byte digest (block hashes, account checksums)
///   hash512   — 64-byte digest (general purpose)
///   hash_work — 8-byte digest (proof-of-work validation)
///
/// All functions accept a slice of byte slices (parts) so callers can hash
/// concatenations without an intermediate allocation.
const std = @import("std");

const B2b256 = std.crypto.hash.blake2.Blake2b256;
const B2b512 = std.crypto.hash.blake2.Blake2b512;

// 8-byte Blake2b output used for proof-of-work.
// Blake2b supports output lengths 1–64 bytes natively.
const B2b64 = std.crypto.hash.blake2.Blake2b(64);

// ── Public API ───────────────────────────────────────────────────────────────

/// Compute a 32-byte Blake2b-256 digest over the concatenation of `parts`.
pub fn hash256(parts: []const []const u8) [32]u8 {
    var h = B2b256.init(.{});
    for (parts) |p| h.update(p);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

/// Compute a 32-byte Blake2b-256 digest over a single contiguous slice.
pub fn hash256_one(data: []const u8) [32]u8 {
    return hash256(&.{data});
}

/// Compute a 64-byte Blake2b-512 digest over the concatenation of `parts`.
pub fn hash512(parts: []const []const u8) [64]u8 {
    var h = B2b512.init(.{});
    for (parts) |p| h.update(p);
    var out: [64]u8 = undefined;
    h.final(&out);
    return out;
}

/// Compute an 8-byte Blake2b-64 digest over the concatenation of `parts`.
/// Used exclusively for proof-of-work.
pub fn hash_work(parts: []const []const u8) [8]u8 {
    var h = B2b64.init(.{});
    for (parts) |p| h.update(p);
    var out: [8]u8 = undefined;
    h.final(&out);
    return out;
}

// ── Block hash ───────────────────────────────────────────────────────────────

/// The preamble for state blocks in smallnano. 32 bytes; last byte is 0x01.
/// (Nano uses 0x06; we use 0x01 to distinguish our protocol.)
const STATE_BLOCK_PREAMBLE: [32]u8 = blk: {
    var p = [_]u8{0} ** 32;
    p[31] = 0x01;
    break :blk p;
};

/// Compute the canonical block hash for a state block.
///
/// Hash input (176 bytes total):
///   preamble(32) | account(32) | previous(32) | representative(32) | balance_be(16) | link(32)
///
/// The work and signature fields are NOT included — the hash is what gets
/// signed and worked on.
pub fn block_hash(
    account: *const [32]u8,
    previous: *const [32]u8,
    representative: *const [32]u8,
    balance: u128,
    link: *const [32]u8,
) [32]u8 {
    var balance_be: [16]u8 = undefined;
    std.mem.writeInt(u128, &balance_be, balance, .big);

    return hash256(&.{
        &STATE_BLOCK_PREAMBLE,
        account,
        previous,
        representative,
        &balance_be,
        link,
    });
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "blake2b: hash256 known-answer — empty input" {
    // Blake2b-256("") from the Blake2 specification.
    const expected: [32]u8 = .{
        0x0e, 0x57, 0x51, 0xc0, 0x26, 0xe5, 0x43, 0xb2,
        0xe8, 0xab, 0x2e, 0xb0, 0x60, 0x99, 0xda, 0xa1,
        0xd1, 0xe5, 0xdf, 0x47, 0x77, 0x8f, 0x77, 0x87,
        0xfa, 0xab, 0x45, 0xcd, 0xf1, 0x2f, 0xe3, 0xa8,
    };
    const got = hash256_one("");
    try std.testing.expectEqual(expected, got);
}

test "blake2b: hash256 single vs parts produce identical output" {
    const a = "hello";
    const b = " world";
    const single = hash256_one("hello world");
    const parts = hash256(&.{ a, b });
    try std.testing.expectEqual(single, parts);
}

test "blake2b: hash512 is 64 bytes" {
    const out = hash512(&.{"test"});
    try std.testing.expectEqual(@as(usize, 64), out.len);
}

test "blake2b: hash_work is 8 bytes and deterministic" {
    const a = hash_work(&.{ "nonce", "hash" });
    const b = hash_work(&.{ "nonce", "hash" });
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(usize, 8), a.len);
}

test "blake2b: block_hash is deterministic and 32 bytes" {
    const account = [_]u8{0x01} ** 32;
    const previous = [_]u8{0x00} ** 32;
    const rep = [_]u8{0x02} ** 32;
    const link = [_]u8{0x03} ** 32;
    const balance: u128 = 1_000_000_000_000_000_000_000_000; // 1 smn

    const h1 = block_hash(&account, &previous, &rep, balance, &link);
    const h2 = block_hash(&account, &previous, &rep, balance, &link);
    try std.testing.expectEqual(h1, h2);
    try std.testing.expectEqual(@as(usize, 32), h1.len);
}

test "blake2b: block_hash differs when any field changes" {
    const account = [_]u8{0x01} ** 32;
    const previous = [_]u8{0x00} ** 32;
    const rep = [_]u8{0x02} ** 32;
    const link = [_]u8{0x03} ** 32;
    const balance: u128 = 1_000_000_000_000_000_000_000_000;

    const h1 = block_hash(&account, &previous, &rep, balance, &link);

    var account2 = account;
    account2[0] ^= 0xFF;
    const h2 = block_hash(&account2, &previous, &rep, balance, &link);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));

    const h3 = block_hash(&account, &previous, &rep, balance + 1, &link);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h3));
}

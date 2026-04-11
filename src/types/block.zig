/// StateBlock — the universal block type for smallnano.
///
/// Every operation in smallnano (open, send, receive, change representative)
/// is represented as a single StateBlock. The `link` field interpretation
/// depends on context:
///   - Send/Change:  link = recipient account's 32-byte public key
///   - Open/Receive: link = source send block hash
///
/// Wire format (216 bytes, little-endian integers):
///   account        [32]u8
///   previous       [32]u8  (all zeros for account open)
///   representative [32]u8
///   balance        [16]u8  (u128, big-endian)
///   link           [32]u8
///   work           [8]u8   (u64, little-endian)
///   signature      [64]u8
///
/// The canonical block hash is computed over:
///   preamble(32) + account(32) + previous(32) + representative(32) + balance_be(16) + link(32)
/// Work and signature are excluded from the hash (they are computed over / about it).
const std = @import("std");
const blake2b = @import("../crypto/blake2b.zig");

pub const BLOCK_SIZE: usize = 216;

// ── StateBlock ────────────────────────────────────────────────────────────────

pub const StateBlock = struct {
    account: [32]u8,
    previous: [32]u8,
    representative: [32]u8,
    balance: u128,
    link: [32]u8,
    work: u64,
    signature: [64]u8,

    // ── Hash ──────────────────────────────────────────────────────────────

    /// Compute the canonical Blake2b-256 hash of this block.
    /// This is the value that gets signed and proof-of-worked.
    pub fn hash(self: *const StateBlock) [32]u8 {
        return blake2b.block_hash(
            &self.account,
            &self.previous,
            &self.representative,
            self.balance,
            &self.link,
        );
    }

    // ── Serialisation ─────────────────────────────────────────────────────

    /// Serialise the block into exactly 216 bytes.
    pub fn to_bytes(self: *const StateBlock) [BLOCK_SIZE]u8 {
        var buf: [BLOCK_SIZE]u8 = undefined;
        var offset: usize = 0;

        @memcpy(buf[offset .. offset + 32], &self.account);
        offset += 32;
        @memcpy(buf[offset .. offset + 32], &self.previous);
        offset += 32;
        @memcpy(buf[offset .. offset + 32], &self.representative);
        offset += 32;

        // Balance: 16 bytes big-endian.
        std.mem.writeInt(u128, buf[offset .. offset + 16][0..16], self.balance, .big);
        offset += 16;

        @memcpy(buf[offset .. offset + 32], &self.link);
        offset += 32;

        // Work: 8 bytes little-endian.
        std.mem.writeInt(u64, buf[offset .. offset + 8][0..8], self.work, .little);
        offset += 8;

        @memcpy(buf[offset .. offset + 64], &self.signature);
        offset += 64;

        std.debug.assert(offset == BLOCK_SIZE);
        return buf;
    }

    /// Deserialise a StateBlock from exactly 216 bytes.
    pub fn from_bytes(buf: *const [BLOCK_SIZE]u8) StateBlock {
        var offset: usize = 0;
        var block: StateBlock = undefined;

        @memcpy(&block.account, buf[offset .. offset + 32]);
        offset += 32;
        @memcpy(&block.previous, buf[offset .. offset + 32]);
        offset += 32;
        @memcpy(&block.representative, buf[offset .. offset + 32]);
        offset += 32;

        block.balance = std.mem.readInt(u128, buf[offset .. offset + 16][0..16], .big);
        offset += 16;

        @memcpy(&block.link, buf[offset .. offset + 32]);
        offset += 32;

        block.work = std.mem.readInt(u64, buf[offset .. offset + 8][0..8], .little);
        offset += 8;

        @memcpy(&block.signature, buf[offset .. offset + 64]);

        return block;
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    /// Returns true if `previous` is all zeros (this is an account open block).
    pub fn is_open(self: *const StateBlock) bool {
        return std.mem.allEqual(u8, &self.previous, 0);
    }

    /// Returns true if the balance decreased compared to `prior_balance`
    /// (this block is a send or change block, not a receive/open).
    pub fn is_send(self: *const StateBlock, prior_balance: u128) bool {
        return self.balance < prior_balance;
    }

    pub fn eql(self: *const StateBlock, other: *const StateBlock) bool {
        return std.mem.eql(u8, &self.hash(), &other.hash());
    }
};

// ── BlockHash convenience alias ───────────────────────────────────────────────

pub const BlockHash = [32]u8;

pub const ZERO_HASH: BlockHash = [_]u8{0} ** 32;

// ── Tests ─────────────────────────────────────────────────────────────────────

fn make_test_block() StateBlock {
    return StateBlock{
        .account = [_]u8{0x01} ** 32,
        .previous = [_]u8{0x00} ** 32,
        .representative = [_]u8{0x02} ** 32,
        .balance = 1_000_000_000_000_000_000_000_000, // 1 smn
        .link = [_]u8{0x03} ** 32,
        .work = 0xDEAD_BEEF_CAFE_1234,
        .signature = [_]u8{0xAA} ** 64,
    };
}

test "block: serialise round-trip" {
    const original = make_test_block();
    const bytes = original.to_bytes();
    const decoded = StateBlock.from_bytes(&bytes);

    try std.testing.expectEqual(original.account, decoded.account);
    try std.testing.expectEqual(original.previous, decoded.previous);
    try std.testing.expectEqual(original.representative, decoded.representative);
    try std.testing.expectEqual(original.balance, decoded.balance);
    try std.testing.expectEqual(original.link, decoded.link);
    try std.testing.expectEqual(original.work, decoded.work);
    try std.testing.expectEqual(original.signature, decoded.signature);
}

test "block: serialised size is exactly 216 bytes" {
    const b = make_test_block();
    try std.testing.expectEqual(@as(usize, 216), b.to_bytes().len);
}

test "block: hash is deterministic" {
    const b = make_test_block();
    try std.testing.expectEqual(b.hash(), b.hash());
}

test "block: hash excludes work and signature" {
    var b1 = make_test_block();
    var b2 = make_test_block();
    b2.work = b1.work ^ 0xFFFF_FFFF_FFFF_FFFF;
    b2.signature = [_]u8{0x55} ** 64;
    // Same account/prev/rep/balance/link → same hash.
    try std.testing.expectEqual(b1.hash(), b2.hash());
}

test "block: hash changes when any hashable field changes" {
    const base = make_test_block();

    var b = base;
    b.account[0] ^= 1;
    try std.testing.expect(!std.mem.eql(u8, &base.hash(), &b.hash()));

    b = base;
    b.previous[0] ^= 1;
    try std.testing.expect(!std.mem.eql(u8, &base.hash(), &b.hash()));

    b = base;
    b.balance += 1;
    try std.testing.expect(!std.mem.eql(u8, &base.hash(), &b.hash()));

    b = base;
    b.link[0] ^= 1;
    try std.testing.expect(!std.mem.eql(u8, &base.hash(), &b.hash()));
}

test "block: is_open true when previous is all zeros" {
    const b = make_test_block(); // previous is 0x00 * 32
    try std.testing.expect(b.is_open());
}

test "block: is_open false when previous is non-zero" {
    var b = make_test_block();
    b.previous[0] = 0x01;
    try std.testing.expect(!b.is_open());
}

test "block: is_send true when balance decreases" {
    const b = make_test_block();
    try std.testing.expect(b.is_send(b.balance + 1));
}

test "block: is_send false when balance same or increases" {
    const b = make_test_block();
    try std.testing.expect(!b.is_send(b.balance));
    try std.testing.expect(!b.is_send(b.balance - 1));
}

test "block: balance serialised as big-endian" {
    var b = make_test_block();
    b.balance = 0x0102030405060708090A0B0C0D0E0F10;
    const bytes = b.to_bytes();
    // Balance starts at offset 96 (32+32+32).
    const balance_bytes = bytes[96..112];
    try std.testing.expectEqual(@as(u8, 0x01), balance_bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x10), balance_bytes[15]);
}

test "block: work serialised as little-endian" {
    var b = make_test_block();
    b.work = 0x0102030405060708;
    const bytes = b.to_bytes();
    // Work starts at offset 144 (32+32+32+16+32).
    const work_bytes = bytes[144..152];
    try std.testing.expectEqual(@as(u8, 0x08), work_bytes[0]); // LSB first
    try std.testing.expectEqual(@as(u8, 0x01), work_bytes[7]); // MSB last
}

/// Account — a 32-byte Ed25519 public key and its smn_ address encoding.
///
/// Address format:
///   smn_<52 base32 chars><8 checksum chars>
///
/// Encoding:
///   1. Take the 32-byte public key (256 bits).
///   2. Prepend 4 zero bits → 260 bits → 52 groups of 5 bits.
///   3. Encode each group using the SMN_ALPHABET (32-char custom alphabet).
///   4. Compute checksum: Blake2b-5bytes(pubkey), reversed.
///   5. Encode the 5 checksum bytes (40 bits → 8 base32 groups).
///   6. Prefix with "smn_".
///
/// Total address length: 4 + 52 + 8 = 64 characters.
const std = @import("std");
const blake2b = @import("../crypto/blake2b.zig");

// ── Base32 alphabet ───────────────────────────────────────────────────────────

/// 32-character alphabet. Omits visually ambiguous characters: 0, 2, l, v.
/// Same set as used by Nano (well-tested, copy-paste safe).
const SMN_ALPHABET = "13456789abcdefghijkmnopqrstuwxyz";

/// Reverse lookup table: ASCII → 5-bit value, 0xFF means invalid.
const DECODE_TABLE: [256]u8 = blk: {
    var t = [_]u8{0xFF} ** 256;
    for (SMN_ALPHABET, 0..) |c, i| t[c] = @intCast(i);
    break :blk t;
};

// ── Account type ─────────────────────────────────────────────────────────────

/// A smallnano account: a 32-byte Ed25519 public key.
pub const Account = struct {
    bytes: [32]u8,

    // ── Constructors ─────────────────────────────────────────────────────────

    pub const ZERO = Account{ .bytes = [_]u8{0} ** 32 };
    pub const BURN = Account{ .bytes = [_]u8{0} ** 32 }; // same as ZERO

    pub fn from_bytes(bytes: *const [32]u8) Account {
        return .{ .bytes = bytes.* };
    }

    // ── Address encoding ─────────────────────────────────────────────────────

    /// Encode this account as a 64-character `smn_...` address string.
    /// `buf` must be at least 64 bytes.
    pub fn to_address(self: *const Account, buf: *[64]u8) void {
        buf[0] = 's';
        buf[1] = 'm';
        buf[2] = 'n';
        buf[3] = '_';

        // Encode key: 4 zero bits prepended to 256 key bits = 260 bits = 52 × 5-bit groups.
        // We process the key MSB-first by treating it as a big number.
        var bit_buf: u64 = 0;
        var bit_count: u6 = 0;
        var out_idx: usize = 4; // start after "smn_"

        // The 4 padding zero bits come first in our bit stream.
        bit_buf = 0;
        bit_count = 4;

        for (self.bytes) |byte| {
            bit_buf = (bit_buf << 8) | @as(u64, byte);
            bit_count += 8;
            while (bit_count >= 5) {
                bit_count -= 5;
                const idx: u5 = @intCast((bit_buf >> bit_count) & 0x1F);
                buf[out_idx] = SMN_ALPHABET[idx];
                out_idx += 1;
            }
        }
        // bit_count should be 0 after processing 4 + 256 = 260 bits in groups of 5.
        std.debug.assert(bit_count == 0);
        std.debug.assert(out_idx == 56); // 4 prefix + 52 key chars

        // Checksum: Blake2b-5bytes(pubkey), reversed, then base32-encode.
        const full_hash = blake2b.hash256_one(&self.bytes);
        var checksum: [5]u8 = undefined;
        @memcpy(&checksum, full_hash[0..5]);
        // Reverse for display (matches Nano convention).
        std.mem.reverse(u8, &checksum);

        bit_buf = 0;
        bit_count = 0;
        for (checksum) |byte| {
            bit_buf = (bit_buf << 8) | @as(u64, byte);
            bit_count += 8;
            while (bit_count >= 5) {
                bit_count -= 5;
                const idx: u5 = @intCast((bit_buf >> bit_count) & 0x1F);
                buf[out_idx] = SMN_ALPHABET[idx];
                out_idx += 1;
            }
        }
        std.debug.assert(out_idx == 64);
    }

    // ── Address decoding ─────────────────────────────────────────────────────

    pub const DecodeError = error{
        InvalidPrefix,
        InvalidLength,
        InvalidCharacter,
        ChecksumMismatch,
    };

    /// Decode a `smn_...` address string into an Account.
    /// Returns `DecodeError` if the address is invalid or the checksum fails.
    pub fn from_address(addr: []const u8) DecodeError!Account {
        if (addr.len != 64) return DecodeError.InvalidLength;
        if (!std.mem.eql(u8, addr[0..4], "smn_")) return DecodeError.InvalidPrefix;

        // Decode the 52 key characters → 260 bits.
        var bit_buf: u64 = 0;
        var bit_count: u6 = 0;
        var key_bytes: [32]u8 = undefined;
        var key_idx: usize = 0;

        for (addr[4..56]) |c| {
            const val = DECODE_TABLE[c];
            if (val == 0xFF) return DecodeError.InvalidCharacter;
            bit_buf = (bit_buf << 5) | @as(u64, val);
            bit_count += 5;
            if (bit_count >= 8) {
                bit_count -= 8;
                if (bit_count == 4) {
                    // First byte: upper 4 bits are padding (must be 0), lower 4 bits are data.
                    // The first emitted byte includes the 4 padding bits and first 4 key bits.
                    // We skip writing the first partial byte — instead we accumulate until
                    // we have a full byte from the key bits only.
                    bit_buf &= 0x0F; // mask off the 4 padding bits
                    // Continue accumulating; do NOT write a byte yet.
                    bit_count = 4;
                    continue;
                }
                key_bytes[key_idx] = @intCast((bit_buf >> bit_count) & 0xFF);
                key_idx += 1;
            }
        }

        // The above loop approach is tricky. Let's use a simpler bit-stream decode.
        // Re-decode from scratch with clearer logic.
        key_bytes = decode_key(addr[4..56]) catch return DecodeError.InvalidCharacter;

        // Decode 8 checksum characters → 5 bytes.
        const checksum_decoded = decode_checksum(addr[56..64]) catch return DecodeError.InvalidCharacter;

        // Verify checksum.
        const full_hash = blake2b.hash256_one(&key_bytes);
        var expected_checksum: [5]u8 = undefined;
        @memcpy(&expected_checksum, full_hash[0..5]);
        std.mem.reverse(u8, &expected_checksum);

        if (!std.mem.eql(u8, &checksum_decoded, &expected_checksum)) {
            return DecodeError.ChecksumMismatch;
        }

        return Account{ .bytes = key_bytes };
    }

    // ── Comparison ───────────────────────────────────────────────────────────

    pub fn eql(self: Account, other: Account) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn is_zero(self: Account) bool {
        return self.eql(ZERO);
    }

    // ── Formatting ───────────────────────────────────────────────────────────

    /// In Zig 0.15 format methods use `*std.io.Writer`; called via `{f}`.
    pub fn format(self: Account, w: *std.io.Writer) std.io.Writer.Error!void {
        var buf: [64]u8 = undefined;
        self.to_address(&buf);
        try w.writeAll(&buf);
    }
};

// ── Private helpers ───────────────────────────────────────────────────────────

/// Decode 52 base32 characters (260 bits = 4 pad + 256 key) into a 32-byte key.
fn decode_key(chars: []const u8) error{InvalidCharacter}![32]u8 {
    std.debug.assert(chars.len == 52);
    // Accumulate 260 bits, then discard the leading 4 padding bits.
    var bits: [260]u1 = undefined;
    for (chars, 0..) |c, ci| {
        const val = DECODE_TABLE[c];
        if (val == 0xFF) return error.InvalidCharacter;
        const base = ci * 5;
        bits[base + 0] = @intCast((val >> 4) & 1);
        bits[base + 1] = @intCast((val >> 3) & 1);
        bits[base + 2] = @intCast((val >> 2) & 1);
        bits[base + 3] = @intCast((val >> 1) & 1);
        bits[base + 4] = @intCast((val >> 0) & 1);
    }
    // Skip the first 4 padding bits; pack remaining 256 bits into 32 bytes.
    var key: [32]u8 = undefined;
    for (&key, 0..) |*byte, i| {
        const b = 4 + i * 8;
        byte.* = (@as(u8, bits[b + 0]) << 7) |
            (@as(u8, bits[b + 1]) << 6) |
            (@as(u8, bits[b + 2]) << 5) |
            (@as(u8, bits[b + 3]) << 4) |
            (@as(u8, bits[b + 4]) << 3) |
            (@as(u8, bits[b + 5]) << 2) |
            (@as(u8, bits[b + 6]) << 1) |
            (@as(u8, bits[b + 7]) << 0);
    }
    return key;
}

/// Decode 8 base32 characters (40 bits) into 5 checksum bytes.
fn decode_checksum(chars: []const u8) error{InvalidCharacter}![5]u8 {
    std.debug.assert(chars.len == 8);
    var bits: [40]u1 = undefined;
    for (chars, 0..) |c, ci| {
        const val = DECODE_TABLE[c];
        if (val == 0xFF) return error.InvalidCharacter;
        const base = ci * 5;
        bits[base + 0] = @intCast((val >> 4) & 1);
        bits[base + 1] = @intCast((val >> 3) & 1);
        bits[base + 2] = @intCast((val >> 2) & 1);
        bits[base + 3] = @intCast((val >> 1) & 1);
        bits[base + 4] = @intCast((val >> 0) & 1);
    }
    var out: [5]u8 = undefined;
    for (&out, 0..) |*byte, i| {
        const b = i * 8;
        byte.* = (@as(u8, bits[b + 0]) << 7) |
            (@as(u8, bits[b + 1]) << 6) |
            (@as(u8, bits[b + 2]) << 5) |
            (@as(u8, bits[b + 3]) << 4) |
            (@as(u8, bits[b + 4]) << 3) |
            (@as(u8, bits[b + 5]) << 2) |
            (@as(u8, bits[b + 6]) << 1) |
            (@as(u8, bits[b + 7]) << 0);
    }
    return out;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "account: encode/decode round-trip (all zeros key)" {
    const acct = Account.ZERO;
    var buf: [64]u8 = undefined;
    acct.to_address(&buf);

    // Must start with smn_
    try std.testing.expectEqualStrings("smn_", buf[0..4]);
    // Total length 64.
    try std.testing.expectEqual(@as(usize, 64), buf.len);

    // Decode must recover the original key.
    const decoded = try Account.from_address(&buf);
    try std.testing.expect(acct.eql(decoded));
}

test "account: encode/decode round-trip (all 0xFF key)" {
    const acct = Account.from_bytes(&([_]u8{0xFF} ** 32));
    var buf: [64]u8 = undefined;
    acct.to_address(&buf);

    const decoded = try Account.from_address(&buf);
    try std.testing.expect(acct.eql(decoded));
}

test "account: encode/decode round-trip (random-looking key)" {
    const key = [32]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
        0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10,
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11,
        0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
    };
    const acct = Account.from_bytes(&key);
    var buf: [64]u8 = undefined;
    acct.to_address(&buf);
    const decoded = try Account.from_address(&buf);
    try std.testing.expect(acct.eql(decoded));
}

test "account: from_address rejects wrong prefix" {
    var buf: [64]u8 = undefined;
    Account.ZERO.to_address(&buf);
    buf[0] = 'x'; // corrupt prefix
    try std.testing.expectError(Account.DecodeError.InvalidPrefix, Account.from_address(&buf));
}

test "account: from_address rejects wrong length" {
    try std.testing.expectError(Account.DecodeError.InvalidLength, Account.from_address("smn_short"));
}

test "account: from_address rejects invalid character" {
    var buf: [64]u8 = undefined;
    Account.ZERO.to_address(&buf);
    buf[10] = '0'; // '0' is not in SMN_ALPHABET
    try std.testing.expectError(Account.DecodeError.InvalidCharacter, Account.from_address(&buf));
}

test "account: from_address rejects corrupted checksum" {
    var buf: [64]u8 = undefined;
    Account.ZERO.to_address(&buf);
    // Flip one checksum character.
    buf[60] = if (buf[60] == '1') '3' else '1';
    try std.testing.expectError(Account.DecodeError.ChecksumMismatch, Account.from_address(&buf));
}

test "account: two distinct keys produce distinct addresses" {
    const a = Account.from_bytes(&([_]u8{0x01} ** 32));
    const b = Account.from_bytes(&([_]u8{0x02} ** 32));
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    a.to_address(&buf_a);
    b.to_address(&buf_b);
    try std.testing.expect(!std.mem.eql(u8, &buf_a, &buf_b));
}

test "account: is_zero" {
    try std.testing.expect(Account.ZERO.is_zero());
    try std.testing.expect(!Account.from_bytes(&([_]u8{0x01} ** 32)).is_zero());
}

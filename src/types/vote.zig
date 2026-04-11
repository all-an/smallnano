/// Vote — a representative's vote on one or more block hashes.
///
/// A vote asserts that the representative believes a set of block hashes
/// should be confirmed. Representatives sign votes with their Ed25519 key.
///
/// Wire format (variable length):
///   representative [32]u8
///   signature      [64]u8
///   timestamp      [8]u8  (u64 little-endian; 0xFFFF...FFFF = final vote)
///   hash_count     [1]u8  (1–12 hashes per vote)
///   hashes         [hash_count * 32]u8
///
/// Minimum size: 32 + 64 + 8 + 1 + 32 = 137 bytes (one hash)
/// Maximum size: 32 + 64 + 8 + 1 + 384 = 489 bytes (twelve hashes)
///
/// The signature covers: Blake2b-256(hashes_concatenated) ++ timestamp_le
const std = @import("std");
const blake2b = @import("../crypto/blake2b.zig");
const ed25519 = @import("../crypto/ed25519.zig");

pub const MAX_HASHES_PER_VOTE: usize = 12;
pub const FINAL_VOTE_TIMESTAMP: u64 = std.math.maxInt(u64);

// ── HashList — fixed-capacity list of 32-byte hashes ─────────────────────────
// (Replaces std.BoundedArray which is not available in Zig 0.15 std root)

pub const HashList = struct {
    buffer: [MAX_HASHES_PER_VOTE][32]u8 = undefined,
    len: usize = 0,

    pub fn append(self: *HashList, hash: [32]u8) error{Overflow}!void {
        if (self.len >= MAX_HASHES_PER_VOTE) return error.Overflow;
        self.buffer[self.len] = hash;
        self.len += 1;
    }

    pub fn appendAssumeCapacity(self: *HashList, hash: [32]u8) void {
        self.buffer[self.len] = hash;
        self.len += 1;
    }

    pub fn constSlice(self: *const HashList) []const [32]u8 {
        return self.buffer[0..self.len];
    }
};

// ── Vote type ─────────────────────────────────────────────────────────────────

pub const Vote = struct {
    representative: [32]u8,
    signature: [64]u8,
    timestamp: u64,
    /// Hashes voted on. Between 1 and MAX_HASHES_PER_VOTE entries.
    hashes: HashList,

    // ── Constructors ─────────────────────────────────────────────────────────

    /// Create and sign a vote. `timestamp` should be milliseconds since Unix
    /// epoch, or FINAL_VOTE_TIMESTAMP for an irreversible final vote.
    pub fn create(
        representative_secret: *const ed25519.SecretKey,
        representative_public: *const [32]u8,
        timestamp: u64,
        hashes: []const [32]u8,
    ) !Vote {
        var v = Vote{
            .representative = representative_public.*,
            .signature = [_]u8{0} ** 64,
            .timestamp = timestamp,
            .hashes = .{},
        };
        for (hashes) |h| try v.hashes.append(h);

        const msg = try signing_message(v.hashes.constSlice(), v.timestamp, std.heap.page_allocator);
        defer std.heap.page_allocator.free(msg);

        v.signature = try ed25519.sign(msg, representative_secret);
        return v;
    }

    // ── Signing message ───────────────────────────────────────────────────────

    /// Build the signed message: Blake2b-256(all_hashes_concatenated) ++ timestamp_le.
    /// Caller owns the returned slice.
    pub fn signing_message(hashes: []const [32]u8, timestamp: u64, allocator: std.mem.Allocator) ![]u8 {
        // Concatenate all hashes, then hash them.
        const hashes_len = hashes.len * 32;
        const hashes_buf = try allocator.alloc(u8, hashes_len);
        defer allocator.free(hashes_buf);
        for (hashes, 0..) |h, i| {
            @memcpy(hashes_buf[i * 32 .. (i + 1) * 32], &h);
        }

        const hash = blake2b.hash256_one(hashes_buf);

        const msg = try allocator.alloc(u8, 40); // 32 hash + 8 timestamp
        @memcpy(msg[0..32], &hash);
        std.mem.writeInt(u64, msg[32..40][0..8], timestamp, .little);
        return msg;
    }

    // ── Signature verification ────────────────────────────────────────────────

    pub const VerifyError = error{ InvalidSignature, InvalidVote };

    pub fn verify(self: *const Vote, allocator: std.mem.Allocator) VerifyError!void {
        if (self.hashes.len == 0) return VerifyError.InvalidVote;

        const msg = signing_message(self.hashes.constSlice(), self.timestamp, allocator) catch
            return VerifyError.InvalidSignature;
        defer allocator.free(msg);

        ed25519.verify(msg, &self.signature, &self.representative) catch
            return VerifyError.InvalidSignature;
    }

    // ── Properties ────────────────────────────────────────────────────────────

    pub fn is_final(self: *const Vote) bool {
        return self.timestamp == FINAL_VOTE_TIMESTAMP;
    }

    // ── Serialisation ─────────────────────────────────────────────────────────

    pub const SerialiseError = error{BufferTooSmall};
    pub const DeserialiseError = error{ BufferTooShort, TooManyHashes, ZeroHashes };

    pub fn to_bytes(self: *const Vote, buf: []u8) SerialiseError!usize {
        const required = 32 + 64 + 8 + 1 + self.hashes.len * 32;
        if (buf.len < required) return SerialiseError.BufferTooSmall;

        var offset: usize = 0;
        @memcpy(buf[offset .. offset + 32], &self.representative);
        offset += 32;
        @memcpy(buf[offset .. offset + 64], &self.signature);
        offset += 64;
        std.mem.writeInt(u64, buf[offset .. offset + 8][0..8], self.timestamp, .little);
        offset += 8;
        buf[offset] = @intCast(self.hashes.len);
        offset += 1;
        for (self.hashes.constSlice()) |h| {
            @memcpy(buf[offset .. offset + 32], &h);
            offset += 32;
        }
        return offset;
    }

    pub fn from_bytes(buf: []const u8, out: *Vote) DeserialiseError!usize {
        if (buf.len < 32 + 64 + 8 + 1) return DeserialiseError.BufferTooShort;

        var offset: usize = 0;
        @memcpy(&out.representative, buf[offset .. offset + 32]);
        offset += 32;
        @memcpy(&out.signature, buf[offset .. offset + 64]);
        offset += 64;
        out.timestamp = std.mem.readInt(u64, buf[offset .. offset + 8][0..8], .little);
        offset += 8;

        const hash_count = buf[offset];
        offset += 1;

        if (hash_count == 0) return DeserialiseError.ZeroHashes;
        if (hash_count > MAX_HASHES_PER_VOTE) return DeserialiseError.TooManyHashes;
        if (buf.len < offset + @as(usize, hash_count) * 32) return DeserialiseError.BufferTooShort;

        out.hashes = HashList{};
        for (0..hash_count) |_| {
            var h: [32]u8 = undefined;
            @memcpy(&h, buf[offset .. offset + 32]);
            out.hashes.appendAssumeCapacity(h);
            offset += 32;
        }
        return offset;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "vote: create and verify signature" {
    const kp = ed25519.KeyPair.generate();
    const hash = [_]u8{0xAB} ** 32;
    const v = try Vote.create(&kp.secret, &kp.public, 1_000_000, &.{hash});
    try v.verify(std.testing.allocator);
}

test "vote: verify detects tampered signature" {
    const kp = ed25519.KeyPair.generate();
    const hash = [_]u8{0xAB} ** 32;
    var v = try Vote.create(&kp.secret, &kp.public, 1_000_000, &.{hash});
    v.signature[0] ^= 0xFF;
    try std.testing.expectError(Vote.VerifyError.InvalidSignature, v.verify(std.testing.allocator));
}

test "vote: verify detects tampered hash" {
    const kp = ed25519.KeyPair.generate();
    const hash = [_]u8{0xAB} ** 32;
    var v = try Vote.create(&kp.secret, &kp.public, 1_000_000, &.{hash});
    v.hashes.buffer[0][0] ^= 0xFF;
    try std.testing.expectError(Vote.VerifyError.InvalidSignature, v.verify(std.testing.allocator));
}

test "vote: is_final true for max timestamp" {
    const kp = ed25519.KeyPair.generate();
    const hash = [_]u8{0x01} ** 32;
    const v = try Vote.create(&kp.secret, &kp.public, FINAL_VOTE_TIMESTAMP, &.{hash});
    try std.testing.expect(v.is_final());
}

test "vote: is_final false for normal timestamp" {
    const kp = ed25519.KeyPair.generate();
    const hash = [_]u8{0x01} ** 32;
    const v = try Vote.create(&kp.secret, &kp.public, 12345, &.{hash});
    try std.testing.expect(!v.is_final());
}

test "vote: serialise/deserialise round-trip (one hash)" {
    const kp = ed25519.KeyPair.generate();
    const hash = [_]u8{0xCD} ** 32;
    const original = try Vote.create(&kp.secret, &kp.public, 999, &.{hash});

    var buf: [512]u8 = undefined;
    const n = try original.to_bytes(&buf);

    var decoded: Vote = undefined;
    const n2 = try Vote.from_bytes(buf[0..n], &decoded);
    try std.testing.expectEqual(n, n2);
    try std.testing.expectEqual(original.representative, decoded.representative);
    try std.testing.expectEqual(original.timestamp, decoded.timestamp);
    try std.testing.expectEqual(original.signature, decoded.signature);
    try std.testing.expectEqual(original.hashes.len, decoded.hashes.len);
    try std.testing.expectEqual(original.hashes.buffer[0], decoded.hashes.buffer[0]);
}

test "vote: serialise/deserialise round-trip (multiple hashes)" {
    const kp = ed25519.KeyPair.generate();
    const hashes = [_][32]u8{
        [_]u8{0x01} ** 32,
        [_]u8{0x02} ** 32,
        [_]u8{0x03} ** 32,
    };
    const original = try Vote.create(&kp.secret, &kp.public, 42, &hashes);

    var buf: [512]u8 = undefined;
    const n = try original.to_bytes(&buf);

    var decoded: Vote = undefined;
    _ = try Vote.from_bytes(buf[0..n], &decoded);
    try std.testing.expectEqual(@as(usize, 3), decoded.hashes.len);
    for (0..3) |i| {
        try std.testing.expectEqual(hashes[i], decoded.hashes.constSlice()[i]);
    }
}

test "vote: deserialise rejects zero hashes" {
    var buf = [_]u8{0} ** 200;
    buf[32 + 64 + 8] = 0; // hash_count = 0
    var v: Vote = undefined;
    try std.testing.expectError(Vote.DeserialiseError.ZeroHashes, Vote.from_bytes(&buf, &v));
}

test "vote: deserialise rejects too many hashes" {
    var buf = [_]u8{0} ** 200;
    buf[32 + 64 + 8] = MAX_HASHES_PER_VOTE + 1;
    var v: Vote = undefined;
    try std.testing.expectError(Vote.DeserialiseError.TooManyHashes, Vote.from_bytes(&buf, &v));
}

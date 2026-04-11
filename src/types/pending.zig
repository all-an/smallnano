/// Pending — a receivable amount waiting to be claimed.
///
/// When account A sends smn to account B, a pending entry is created for B.
/// B must publish a receive block to claim the funds. Until then, the entry
/// sits in the pending table in the store.
///
/// PendingKey uniquely identifies a pending entry:
///   (recipient_account, send_block_hash)
///
/// PendingInfo holds the details needed to construct a receive block:
///   source account (sender), amount
const std = @import("std");

// ── PendingKey ────────────────────────────────────────────────────────────────

/// Uniquely identifies one receivable entry.
pub const PendingKey = struct {
    /// The account that will receive the funds.
    recipient: [32]u8,
    /// The hash of the send block that created this pending entry.
    send_hash: [32]u8,

    pub const SIZE: usize = 64;

    pub fn eql(self: PendingKey, other: PendingKey) bool {
        return std.mem.eql(u8, &self.recipient, &other.recipient) and
            std.mem.eql(u8, &self.send_hash, &other.send_hash);
    }

    // ── Serialisation ─────────────────────────────────────────────────────

    pub fn to_bytes(self: PendingKey) [SIZE]u8 {
        var buf: [SIZE]u8 = undefined;
        @memcpy(buf[0..32], &self.recipient);
        @memcpy(buf[32..64], &self.send_hash);
        return buf;
    }

    pub fn from_bytes(buf: *const [SIZE]u8) PendingKey {
        return .{
            .recipient = buf[0..32].*,
            .send_hash = buf[32..64].*,
        };
    }
};

// ── PendingInfo ───────────────────────────────────────────────────────────────

/// The data needed to construct a receive block for a pending entry.
pub const PendingInfo = struct {
    /// The account that sent the funds.
    source: [32]u8,
    /// Amount of raw units pending.
    amount: u128,

    pub const SIZE: usize = 32 + 16; // 48 bytes

    pub fn eql(self: PendingInfo, other: PendingInfo) bool {
        return std.mem.eql(u8, &self.source, &other.source) and
            self.amount == other.amount;
    }

    // ── Serialisation ─────────────────────────────────────────────────────

    pub fn to_bytes(self: PendingInfo) [SIZE]u8 {
        var buf: [SIZE]u8 = undefined;
        @memcpy(buf[0..32], &self.source);
        std.mem.writeInt(u128, buf[32..48][0..16], self.amount, .big);
        return buf;
    }

    pub fn from_bytes(buf: *const [SIZE]u8) PendingInfo {
        return .{
            .source = buf[0..32].*,
            .amount = std.mem.readInt(u128, buf[32..48][0..16], .big),
        };
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "pending_key: round-trip serialisation" {
    const key = PendingKey{
        .recipient = [_]u8{0xAA} ** 32,
        .send_hash = [_]u8{0xBB} ** 32,
    };
    const bytes = key.to_bytes();
    const decoded = PendingKey.from_bytes(&bytes);
    try std.testing.expect(key.eql(decoded));
}

test "pending_key: size is 64 bytes" {
    const key = PendingKey{
        .recipient = [_]u8{0} ** 32,
        .send_hash = [_]u8{0} ** 32,
    };
    try std.testing.expectEqual(@as(usize, 64), key.to_bytes().len);
}

test "pending_key: eql true for same values" {
    const a = PendingKey{
        .recipient = [_]u8{0x01} ** 32,
        .send_hash = [_]u8{0x02} ** 32,
    };
    const b = a;
    try std.testing.expect(a.eql(b));
}

test "pending_key: eql false for different recipient" {
    const a = PendingKey{
        .recipient = [_]u8{0x01} ** 32,
        .send_hash = [_]u8{0x02} ** 32,
    };
    var b = a;
    b.recipient[0] ^= 0xFF;
    try std.testing.expect(!a.eql(b));
}

test "pending_key: eql false for different send_hash" {
    const a = PendingKey{
        .recipient = [_]u8{0x01} ** 32,
        .send_hash = [_]u8{0x02} ** 32,
    };
    var b = a;
    b.send_hash[0] ^= 0xFF;
    try std.testing.expect(!a.eql(b));
}

test "pending_info: round-trip serialisation" {
    const info = PendingInfo{
        .source = [_]u8{0xCC} ** 32,
        .amount = 999_000_000_000_000_000_000_000_000, // 999 smn
    };
    const bytes = info.to_bytes();
    const decoded = PendingInfo.from_bytes(&bytes);
    try std.testing.expect(info.eql(decoded));
}

test "pending_info: size is 48 bytes" {
    const info = PendingInfo{ .source = [_]u8{0} ** 32, .amount = 0 };
    try std.testing.expectEqual(@as(usize, 48), info.to_bytes().len);
}

test "pending_info: amount serialised big-endian" {
    const info = PendingInfo{
        .source = [_]u8{0} ** 32,
        .amount = 0x0102030405060708090A0B0C0D0E0F10,
    };
    const bytes = info.to_bytes();
    try std.testing.expectEqual(@as(u8, 0x01), bytes[32]); // MSB first
    try std.testing.expectEqual(@as(u8, 0x10), bytes[47]); // LSB last
}

test "pending_info: zero amount round-trips" {
    const info = PendingInfo{ .source = [_]u8{0x01} ** 32, .amount = 0 };
    const decoded = PendingInfo.from_bytes(&info.to_bytes());
    try std.testing.expectEqual(@as(u128, 0), decoded.amount);
}

test "pending_info: max amount round-trips" {
    const info = PendingInfo{
        .source = [_]u8{0x01} ** 32,
        .amount = std.math.maxInt(u128),
    };
    const decoded = PendingInfo.from_bytes(&info.to_bytes());
    try std.testing.expectEqual(std.math.maxInt(u128), decoded.amount);
}

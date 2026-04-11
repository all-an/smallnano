/// Amount — the monetary unit for smallnano.
///
/// All balances are stored as raw integer units (u128) with no floating point.
///
/// Denomination table:
///   1 smn  = 10^24 raw  (one septillion — the main display unit)
///   1 msmn = 10^21 raw  (milli-smn, one thousandth of a coin)
///   1 μsmn = 10^18 raw  (micro-smn, one millionth of a coin)
///   1 raw  = 1          (atomic indivisible unit)
///
/// Fixed supply: 10,000,000 smn = 10^31 raw (fits in u128, max ~3.4×10^38).
const std = @import("std");

// ── Constants ─────────────────────────────────────────────────────────────────

/// 1 smn expressed in raw units.
pub const SMN: u128 = 1_000_000_000_000_000_000_000_000; // 10^24

/// 1 milli-smn in raw units (10^21).
pub const MILLI_SMN: u128 = 1_000_000_000_000_000_000_000;

/// 1 micro-smn in raw units (10^18).
pub const MICRO_SMN: u128 = 1_000_000_000_000_000_000;

/// Total fixed supply of smallnano: 10,000,000 smn.
pub const TOTAL_SUPPLY_RAW: u128 = 10_000_000 * SMN; // 10^31

// ── Amount type ───────────────────────────────────────────────────────────────

pub const Amount = struct {
    raw: u128,

    // ── Constructors ─────────────────────────────────────────────────────────

    pub const ZERO = Amount{ .raw = 0 };
    pub const TOTAL_SUPPLY = Amount{ .raw = TOTAL_SUPPLY_RAW };
    pub const MAX = Amount{ .raw = std.math.maxInt(u128) };

    /// Construct from a raw u128 value.
    pub fn from_raw(raw: u128) Amount {
        return .{ .raw = raw };
    }

    /// Construct from a whole number of smn. Returns null if the value would
    /// overflow (> total supply is allowed — the type makes no supply checks).
    pub fn from_smn(smn: u64) ?Amount {
        const raw = std.math.mul(u128, @as(u128, smn), SMN) catch return null;
        return .{ .raw = raw };
    }

    /// Construct from a whole number of milli-smn.
    pub fn from_msmn(msmn: u64) ?Amount {
        const raw = std.math.mul(u128, @as(u128, msmn), MILLI_SMN) catch return null;
        return .{ .raw = raw };
    }

    // ── Arithmetic ───────────────────────────────────────────────────────────

    /// Checked addition. Returns null on overflow.
    pub fn add(self: Amount, other: Amount) ?Amount {
        const raw = std.math.add(u128, self.raw, other.raw) catch return null;
        return .{ .raw = raw };
    }

    /// Checked subtraction. Returns null on underflow (other > self).
    pub fn sub(self: Amount, other: Amount) ?Amount {
        if (other.raw > self.raw) return null;
        return .{ .raw = self.raw - other.raw };
    }

    // ── Comparison ───────────────────────────────────────────────────────────

    pub fn eql(self: Amount, other: Amount) bool {
        return self.raw == other.raw;
    }

    pub fn lt(self: Amount, other: Amount) bool {
        return self.raw < other.raw;
    }

    pub fn lte(self: Amount, other: Amount) bool {
        return self.raw <= other.raw;
    }

    pub fn gt(self: Amount, other: Amount) bool {
        return self.raw > other.raw;
    }

    // ── Serialisation ────────────────────────────────────────────────────────

    /// Encode the amount as 16 bytes, big-endian (network byte order).
    pub fn to_bytes_be(self: Amount) [16]u8 {
        var out: [16]u8 = undefined;
        std.mem.writeInt(u128, &out, self.raw, .big);
        return out;
    }

    /// Decode from 16 big-endian bytes.
    pub fn from_bytes_be(bytes: *const [16]u8) Amount {
        return .{ .raw = std.mem.readInt(u128, bytes, .big) };
    }

    // ── Display ──────────────────────────────────────────────────────────────

    /// Write a human-readable representation to `w`.
    /// Format: "<integer>.<24-digit-fraction> smn"
    /// Example: Amount{ .raw = SMN } → "1.000000000000000000000000 smn"
    ///
    /// In Zig 0.15 this is called via `{f}` format specifier.
    pub fn format(self: Amount, w: *std.io.Writer) std.io.Writer.Error!void {
        const integer_part = self.raw / SMN;
        const fraction_part = self.raw % SMN;

        try w.print("{d}", .{integer_part});
        try w.writeByte('.');

        // Fraction part: always exactly 24 decimal digits with leading zeros.
        var frac_buf: [24]u8 = undefined;
        _ = std.fmt.bufPrint(&frac_buf, "{d:0>24}", .{fraction_part}) catch unreachable;
        try w.writeAll(&frac_buf);

        try w.writeAll(" smn");
    }

    /// Write a display string into a caller-supplied buffer.
    /// Buffer must be at least 33 bytes. Returns the slice written.
    pub fn to_string(self: Amount, buf: []u8) []u8 {
        const integer_part = self.raw / SMN;
        const fraction_part = self.raw % SMN;
        return std.fmt.bufPrint(buf, "{d}.{d:0>24} smn", .{ integer_part, fraction_part }) catch buf[0..0];
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "amount: ZERO raw is 0" {
    try std.testing.expectEqual(@as(u128, 0), Amount.ZERO.raw);
}

test "amount: TOTAL_SUPPLY is 10 million smn" {
    try std.testing.expectEqual(@as(u128, 10_000_000) * SMN, Amount.TOTAL_SUPPLY.raw);
}

test "amount: from_raw round-trips" {
    const a = Amount.from_raw(12345);
    try std.testing.expectEqual(@as(u128, 12345), a.raw);
}

test "amount: from_smn converts correctly" {
    const a = Amount.from_smn(1).?;
    try std.testing.expectEqual(SMN, a.raw);

    const b = Amount.from_smn(10_000_000).?;
    try std.testing.expectEqual(TOTAL_SUPPLY_RAW, b.raw);
}

test "amount: from_smn overflow returns null" {
    // 2^64 * 10^24 overflows u128.
    const result = Amount.from_smn(std.math.maxInt(u64));
    try std.testing.expect(result == null);
}

test "amount: add two amounts" {
    const a = Amount.from_raw(1000);
    const b = Amount.from_raw(2000);
    const c = a.add(b).?;
    try std.testing.expectEqual(@as(u128, 3000), c.raw);
}

test "amount: add overflow returns null" {
    const a = Amount.MAX;
    const b = Amount.from_raw(1);
    try std.testing.expect(a.add(b) == null);
}

test "amount: sub basic" {
    const a = Amount.from_raw(5000);
    const b = Amount.from_raw(3000);
    const c = a.sub(b).?;
    try std.testing.expectEqual(@as(u128, 2000), c.raw);
}

test "amount: sub exact to zero" {
    const a = Amount.from_raw(100);
    const c = a.sub(a).?;
    try std.testing.expectEqual(@as(u128, 0), c.raw);
}

test "amount: sub underflow returns null" {
    const a = Amount.from_raw(100);
    const b = Amount.from_raw(101);
    try std.testing.expect(a.sub(b) == null);
}

test "amount: comparison operators" {
    const a = Amount.from_raw(100);
    const b = Amount.from_raw(200);
    try std.testing.expect(a.lt(b));
    try std.testing.expect(a.lte(b));
    try std.testing.expect(b.gt(a));
    try std.testing.expect(a.lte(a));
    try std.testing.expect(a.eql(a));
    try std.testing.expect(!a.eql(b));
}

test "amount: serialisation round-trip (big-endian)" {
    const original = Amount.from_raw(0xDEAD_BEEF_CAFE_1234_5678_9ABC_DEF0_1234);
    const bytes = original.to_bytes_be();
    const decoded = Amount.from_bytes_be(&bytes);
    try std.testing.expectEqual(original.raw, decoded.raw);
}

test "amount: to_bytes_be is big-endian" {
    // 1 as a u128 should appear in the last byte.
    const a = Amount.from_raw(1);
    const bytes = a.to_bytes_be();
    try std.testing.expectEqual(@as(u8, 0), bytes[0]);
    try std.testing.expectEqual(@as(u8, 1), bytes[15]);
}

test "amount: format displays smn unit" {
    var buf: [64]u8 = undefined;
    const a = Amount.from_smn(1).?;
    const s = a.to_string(&buf);
    try std.testing.expectEqualStrings("1.000000000000000000000000 smn", s);
}

test "amount: format displays zero" {
    var buf: [64]u8 = undefined;
    const s = Amount.ZERO.to_string(&buf);
    try std.testing.expectEqualStrings("0.000000000000000000000000 smn", s);
}

test "amount: format displays fractional smn" {
    var buf: [64]u8 = undefined;
    // 1 msmn = 10^21 raw = 0.001 smn
    const a = Amount.from_raw(MILLI_SMN);
    const s = a.to_string(&buf);
    try std.testing.expectEqualStrings("0.001000000000000000000000 smn", s);
}

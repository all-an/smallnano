/// Token-bucket bandwidth limiter for smallnano.
///
/// Each direction (inbound / outbound) gets one BandwidthLimiter.
/// The limiter is pure logic: it takes the current time as a parameter,
/// making it fully testable without real clocks or sleeps.
///
/// Algorithm:
///   - Bucket capacity = limit_bytes_per_sec  (one second of headroom)
///   - On each call to consume(n, now_ns):
///       1. Compute elapsed = now_ns - last_refill_ns  (clamped to ≥ 0)
///       2. Add  elapsed_secs * limit_bytes_per_sec  tokens (capped at capacity)
///       3. If tokens >= n: deduct n, return true (allowed)
///       4. Otherwise: return false (over limit; caller should drop or delay)
///
/// `now_ns` is nanoseconds since an arbitrary epoch (e.g. std.time.nanoTimestamp()).
/// The first call after init treats the bucket as full (tokens = capacity).
const std = @import("std");

pub const BandwidthLimiter = struct {
    /// Maximum bytes per second allowed through this limiter.
    limit_bytes_per_sec: u64,
    /// Current token count (bytes available to send/receive).
    tokens: f64,
    /// Nanosecond timestamp of the last refill. 0 = not yet initialised.
    last_refill_ns: i64,

    // ── Constructor ───────────────────────────────────────────────────────────

    pub fn init(limit_bytes_per_sec: u64) BandwidthLimiter {
        return .{
            .limit_bytes_per_sec = limit_bytes_per_sec,
            // Start with a full bucket so the node can bootstrap immediately.
            .tokens = @floatFromInt(limit_bytes_per_sec),
            .last_refill_ns = 0,
        };
    }

    // ── consume ───────────────────────────────────────────────────────────────

    /// Attempt to consume `n` bytes from the bucket at time `now_ns`.
    /// Returns true if the transfer is allowed, false if it should be dropped.
    /// `now_ns` is nanoseconds (e.g. std.time.nanoTimestamp()).
    pub fn consume(self: *BandwidthLimiter, n: u64, now_ns: i64) bool {
        if (self.limit_bytes_per_sec == 0) return false; // zero = disabled

        // Refill on the first call.
        if (self.last_refill_ns == 0) {
            self.last_refill_ns = now_ns;
        }

        const elapsed_ns = now_ns - self.last_refill_ns;
        if (elapsed_ns > 0) {
            const elapsed_secs: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            const added = elapsed_secs * @as(f64, @floatFromInt(self.limit_bytes_per_sec));
            const capacity: f64 = @floatFromInt(self.limit_bytes_per_sec);
            self.tokens = @min(self.tokens + added, capacity);
            self.last_refill_ns = now_ns;
        }

        const cost: f64 = @floatFromInt(n);
        if (self.tokens >= cost) {
            self.tokens -= cost;
            return true;
        }
        return false;
    }

    // ── available ─────────────────────────────────────────────────────────────

    /// Return how many bytes can be consumed right now (floor).
    pub fn available(self: *const BandwidthLimiter) u64 {
        if (self.tokens < 0) return 0;
        return @intFromFloat(self.tokens);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "bandwidth: fresh limiter starts full" {
    var lim = BandwidthLimiter.init(1000);
    // First consume at time 0 — bucket should be full (1000 bytes available).
    try std.testing.expect(lim.consume(1000, 1_000_000_000));
}

test "bandwidth: consume within limit is allowed" {
    var lim = BandwidthLimiter.init(1000);
    try std.testing.expect(lim.consume(500, 1_000_000_000));
    try std.testing.expect(lim.consume(499, 1_000_000_000)); // still within remaining 500
}

test "bandwidth: consume over limit is denied" {
    var lim = BandwidthLimiter.init(1000);
    _ = lim.consume(1000, 1_000_000_000); // drain the bucket
    // No time has passed → no refill → must be denied
    try std.testing.expect(!lim.consume(1, 1_000_000_000));
}

test "bandwidth: refills over time" {
    var lim = BandwidthLimiter.init(1000); // 1000 B/s
    const t0: i64 = 1_000_000_000; // arbitrary start
    _ = lim.consume(1000, t0); // drain completely

    // After 1 second, should have 1000 tokens back.
    const t1 = t0 + 1_000_000_000; // +1 second
    try std.testing.expect(lim.consume(1000, t1));
}

test "bandwidth: partial refill allows partial consumption" {
    var lim = BandwidthLimiter.init(1000);
    // Use a non-zero epoch so the "uninitialised" sentinel (0) is never confused
    // with a real timestamp after the first consume() call.
    const t0: i64 = 1_000_000_000;
    _ = lim.consume(1000, t0); // drain

    // After 0.5 seconds → ~500 tokens refilled.
    const t1 = t0 + 500_000_000; // +500 ms
    try std.testing.expect(lim.consume(490, t1)); // 490 <= ~500 → allowed
    try std.testing.expect(!lim.consume(490, t1)); // ~10 tokens left, 490 denied
}

test "bandwidth: tokens capped at capacity" {
    var lim = BandwidthLimiter.init(1000);
    const t0: i64 = 0;
    // Wait 10 seconds — tokens must not exceed capacity (1000).
    const t1 = t0 + 10_000_000_000;
    try std.testing.expect(lim.consume(1000, t1));
    // After draining, nothing left.
    try std.testing.expect(!lim.consume(1, t1));
}

test "bandwidth: zero limit always denies" {
    var lim = BandwidthLimiter.init(0);
    try std.testing.expect(!lim.consume(1, 1_000_000_000));
    try std.testing.expect(!lim.consume(0, 1_000_000_000));
}

test "bandwidth: available reflects token count" {
    var lim = BandwidthLimiter.init(1000);
    const t0: i64 = 1_000_000_000;
    _ = lim.consume(600, t0); // use 600, 400 left
    try std.testing.expectEqual(@as(u64, 400), lim.available());
}

test "bandwidth: multiple small consumes add up" {
    var lim = BandwidthLimiter.init(100);
    const t: i64 = 1_000_000_000;
    // 100 × 1-byte consumes should exactly drain the bucket.
    for (0..100) |_| {
        try std.testing.expect(lim.consume(1, t));
    }
    try std.testing.expect(!lim.consume(1, t));
}

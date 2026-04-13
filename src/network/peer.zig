/// Peer — address, connection state, and ban management for smallnano.
///
/// A Peer is the node's view of one remote participant. It holds:
///   - The remote's TCP address (`host:port` string + parsed form)
///   - Connection state machine
///   - Authenticated node identity (once handshake completes)
///   - Ban tracking (timestamp-based, no allocations)
///
/// Peer does no I/O — it is pure state that the Network layer updates.
const std = @import("std");

// ── PeerAddress ───────────────────────────────────────────────────────────────

pub const PeerAddress = struct {
    /// Null-terminated `host:port` string stored inline.
    ///
    /// This accepts:
    /// - IPv4 literals: `192.0.2.10:7176`
    /// - bracketed IPv6 literals: `[2001:db8::10]:7176`
    /// - hostname-style peers such as Docker service names: `node2:7276`
    ///
    /// The storage budget keeps room for the longest DNS hostname plus `:65535`.
    buf: [272]u8 = [_]u8{0} ** 272,
    len: u8 = 0,

    pub const ParseError = error{ InvalidFormat, PortOutOfRange };

    /// Parse "host:port" into a PeerAddress. Does NOT resolve DNS.
    pub fn parse(s: []const u8) ParseError!PeerAddress {
        if (s.len == 0 or s.len > std.math.maxInt(u8) or s.len >= 272) {
            return ParseError.InvalidFormat;
        }
        _ = try split_host_port(s);

        var addr = PeerAddress{};
        @memcpy(addr.buf[0..s.len], s);
        addr.len = @intCast(s.len);
        return addr;
    }

    pub fn as_slice(self: *const PeerAddress) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn eql(self: PeerAddress, other: PeerAddress) bool {
        return self.len == other.len and
            std.mem.eql(u8, self.buf[0..self.len], other.buf[0..other.len]);
    }
};

pub const HostPort = struct {
    host: []const u8,
    port: u16,
};

pub fn split_host_port(s: []const u8) PeerAddress.ParseError!HostPort {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.InvalidFormat;
    if (colon == 0 or colon + 1 >= s.len) return error.InvalidFormat;

    const port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return error.PortOutOfRange;
    const host = s[0..colon];
    if (host.len == 0) return error.InvalidFormat;

    if (host[0] == '[') {
        if (host.len < 3 or host[host.len - 1] != ']') return error.InvalidFormat;
        return .{
            .host = host[1 .. host.len - 1],
            .port = port,
        };
    }

    if (std.mem.indexOfScalar(u8, host, ':') != null) return error.InvalidFormat;
    if (!is_valid_hostname(host)) return error.InvalidFormat;

    return .{
        .host = host,
        .port = port,
    };
}

fn is_valid_hostname(host: []const u8) bool {
    for (host) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_') continue;
        return false;
    }
    return true;
}

// ── PeerState ─────────────────────────────────────────────────────────────────

pub const PeerState = enum {
    /// Known address, not currently connected.
    disconnected,
    /// TCP connect in progress.
    connecting,
    /// TCP connected, handshake in progress.
    handshaking,
    /// Handshake complete, fully operational.
    connected,
    /// Banned until ban_until_sec. Will not be dialled until ban expires.
    banned,
};

// ── Peer ──────────────────────────────────────────────────────────────────────

pub const Peer = struct {
    address: PeerAddress,
    state: PeerState = .disconnected,
    /// Unix timestamp (seconds) of last received message. 0 = never.
    last_seen_sec: i64 = 0,
    /// Earliest timestamp when the peer may be dialed again.
    retry_after_sec: i64 = 0,
    /// Unix timestamp (seconds) when the ban expires. 0 = not banned.
    ban_until_sec: i64 = 0,
    /// Authenticated Ed25519 node identity. Populated after handshake.
    node_id: ?[32]u8 = null,
    /// Number of consecutive failed connection attempts.
    fail_count: u32 = 0,

    // ── Constructors ─────────────────────────────────────────────────────────

    pub fn from_address(addr: PeerAddress) Peer {
        return .{ .address = addr };
    }

    // ── State transitions ─────────────────────────────────────────────────────

    pub fn mark_connecting(self: *Peer, now_sec: i64) void {
        self.state = .connecting;
        self.retry_after_sec = now_sec;
    }

    pub fn mark_handshaking(self: *Peer) void {
        self.state = .handshaking;
    }

    pub fn mark_connected(self: *Peer, node_id: [32]u8, now_sec: i64) void {
        self.state = .connected;
        self.node_id = node_id;
        self.last_seen_sec = now_sec;
        self.retry_after_sec = 0;
        self.fail_count = 0;
    }

    pub fn mark_disconnected(self: *Peer) void {
        if (self.state != .banned) self.state = .disconnected;
        self.node_id = null;
    }

    pub fn mark_failed(self: *Peer, now_sec: i64) void {
        self.state = .disconnected;
        self.node_id = null;
        self.fail_count +|= 1; // saturating add
        self.retry_after_sec = now_sec + @as(i64, retry_backoff_sec(self.fail_count));
    }

    pub fn touch(self: *Peer, now_sec: i64) void {
        self.last_seen_sec = now_sec;
    }

    // ── Ban management ────────────────────────────────────────────────────────

    /// Ban this peer for `duration_sec` seconds.
    pub fn ban(self: *Peer, now_sec: i64, duration_sec: u32) void {
        self.state = .banned;
        self.ban_until_sec = now_sec + @as(i64, duration_sec);
        self.node_id = null;
    }

    /// Returns true if the peer is still under a ban at `now_sec`.
    pub fn is_banned(self: *const Peer, now_sec: i64) bool {
        return self.state == .banned and now_sec < self.ban_until_sec;
    }

    /// Lift the ban if it has expired. Returns true if the ban was lifted.
    pub fn try_unban(self: *Peer, now_sec: i64) bool {
        if (self.state == .banned and now_sec >= self.ban_until_sec) {
            self.state = .disconnected;
            self.ban_until_sec = 0;
            return true;
        }
        return false;
    }

    // ── Queries ───────────────────────────────────────────────────────────────

    pub fn is_dialable(self: *const Peer, now_sec: i64) bool {
        return self.state == .disconnected and
            !self.is_banned(now_sec) and
            now_sec >= self.retry_after_sec;
    }

    pub fn is_active(self: *const Peer) bool {
        return self.state == .connected;
    }

    /// How many seconds since we last heard from this peer. null if never seen.
    pub fn idle_secs(self: *const Peer, now_sec: i64) ?i64 {
        if (self.last_seen_sec == 0) return null;
        return now_sec - self.last_seen_sec;
    }

    fn retry_backoff_sec(fail_count: u32) u32 {
        if (fail_count == 0) return 0;
        const shift = @min(fail_count - 1, 30);
        const unbounded = @as(u32, 1) << @intCast(shift);
        return @min(unbounded, 300);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "peer_address: parse valid IPv4" {
    const addr = try PeerAddress.parse("192.168.1.1:7176");
    try std.testing.expectEqualStrings("192.168.1.1:7176", addr.as_slice());
}

test "peer_address: parse valid IPv6-style (bracket)" {
    const addr = try PeerAddress.parse("[::1]:7176");
    try std.testing.expectEqualStrings("[::1]:7176", addr.as_slice());
}

test "peer_address: parse valid hostname peer" {
    const addr = try PeerAddress.parse("node2:7276");
    try std.testing.expectEqualStrings("node2:7276", addr.as_slice());
}

test "peer_address: split hostname and port" {
    const parsed = try split_host_port("smallnano-node-3:7376");
    try std.testing.expectEqualStrings("smallnano-node-3", parsed.host);
    try std.testing.expectEqual(@as(u16, 7376), parsed.port);
}

test "peer_address: rejects missing colon" {
    try std.testing.expectError(PeerAddress.ParseError.InvalidFormat, PeerAddress.parse("192.168.1.1"));
}

test "peer_address: rejects empty string" {
    try std.testing.expectError(PeerAddress.ParseError.InvalidFormat, PeerAddress.parse(""));
}

test "peer_address: rejects hostname with invalid characters" {
    try std.testing.expectError(PeerAddress.ParseError.InvalidFormat, PeerAddress.parse("bad peer:7176"));
}

test "peer_address: rejects port that is not a number" {
    try std.testing.expectError(PeerAddress.ParseError.PortOutOfRange, PeerAddress.parse("host:abc"));
}

test "peer_address: eql true for same address" {
    const a = try PeerAddress.parse("10.0.0.1:7176");
    const b = try PeerAddress.parse("10.0.0.1:7176");
    try std.testing.expect(a.eql(b));
}

test "peer_address: eql false for different address" {
    const a = try PeerAddress.parse("10.0.0.1:7176");
    const b = try PeerAddress.parse("10.0.0.2:7176");
    try std.testing.expect(!a.eql(b));
}

test "peer: initial state is disconnected" {
    const addr = try PeerAddress.parse("1.2.3.4:7176");
    const p = Peer.from_address(addr);
    try std.testing.expectEqual(PeerState.disconnected, p.state);
    try std.testing.expect(p.node_id == null);
}

test "peer: state transitions: disconnected → connecting → handshaking → connected" {
    const addr = try PeerAddress.parse("1.2.3.4:7176");
    var p = Peer.from_address(addr);

    p.mark_connecting(1000);
    try std.testing.expectEqual(PeerState.connecting, p.state);

    p.mark_handshaking();
    try std.testing.expectEqual(PeerState.handshaking, p.state);

    const nid = [_]u8{0xAB} ** 32;
    p.mark_connected(nid, 1000);
    try std.testing.expectEqual(PeerState.connected, p.state);
    try std.testing.expectEqual(nid, p.node_id.?);
    try std.testing.expectEqual(@as(u32, 0), p.fail_count);
}

test "peer: mark_disconnected clears node_id" {
    const addr = try PeerAddress.parse("1.2.3.4:7176");
    var p = Peer.from_address(addr);
    p.mark_connected([_]u8{0x01} ** 32, 1000);
    p.mark_disconnected();
    try std.testing.expectEqual(PeerState.disconnected, p.state);
    try std.testing.expect(p.node_id == null);
}

test "peer: mark_failed increments fail_count" {
    const addr = try PeerAddress.parse("1.2.3.4:7176");
    var p = Peer.from_address(addr);
    p.mark_failed(1000);
    try std.testing.expectEqual(@as(u32, 1), p.fail_count);
    try std.testing.expectEqual(@as(i64, 1001), p.retry_after_sec);
    p.mark_failed(1001);
    try std.testing.expectEqual(@as(u32, 2), p.fail_count);
    try std.testing.expectEqual(@as(i64, 1003), p.retry_after_sec);
}

test "peer: ban / is_banned / try_unban lifecycle" {
    const addr = try PeerAddress.parse("1.2.3.4:7176");
    var p = Peer.from_address(addr);
    const now: i64 = 1000;

    p.ban(now, 60); // ban for 60 seconds
    try std.testing.expect(p.is_banned(now));
    try std.testing.expect(p.is_banned(now + 59));
    try std.testing.expect(!p.is_banned(now + 60)); // exactly at expiry: not banned

    // try_unban before expiry does nothing
    try std.testing.expect(!p.try_unban(now + 30));
    try std.testing.expectEqual(PeerState.banned, p.state);

    // try_unban at/after expiry lifts ban
    try std.testing.expect(p.try_unban(now + 60));
    try std.testing.expectEqual(PeerState.disconnected, p.state);
}

test "peer: is_dialable only when disconnected and not banned" {
    const addr = try PeerAddress.parse("1.2.3.4:7176");
    var p = Peer.from_address(addr);
    const now: i64 = 1000;

    try std.testing.expect(p.is_dialable(now));

    p.mark_connecting(now);
    try std.testing.expect(!p.is_dialable(now));

    p.mark_disconnected();
    p.ban(now, 30);
    try std.testing.expect(!p.is_dialable(now));
    try std.testing.expect(!p.is_dialable(now + 29));
    _ = p.try_unban(now + 30);
    try std.testing.expect(p.is_dialable(now + 30));
}

test "peer: failed peers back off exponentially with an upper bound" {
    const addr = try PeerAddress.parse("1.2.3.4:7176");
    var p = Peer.from_address(addr);
    const now: i64 = 1000;

    p.mark_failed(now);
    try std.testing.expect(!p.is_dialable(now));
    try std.testing.expect(p.is_dialable(now + 1));

    p.mark_failed(now + 1);
    try std.testing.expect(!p.is_dialable(now + 2));
    try std.testing.expect(p.is_dialable(now + 3));

    p.fail_count = 20;
    p.mark_failed(now + 10);
    try std.testing.expectEqual(@as(i64, now + 310), p.retry_after_sec);
}

test "peer: idle_secs returns null when never seen" {
    const addr = try PeerAddress.parse("1.2.3.4:7176");
    const p = Peer.from_address(addr);
    try std.testing.expect(p.idle_secs(1000) == null);
}

test "peer: idle_secs returns elapsed seconds" {
    const addr = try PeerAddress.parse("1.2.3.4:7176");
    var p = Peer.from_address(addr);
    p.touch(1000);
    try std.testing.expectEqual(@as(i64, 42), p.idle_secs(1042).?);
}

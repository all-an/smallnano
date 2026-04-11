/// TCP channel — length-prefixed frame read/write.
///
/// Every frame on the wire is:
///
///   [ 4-byte LE body_len ][ body_len bytes of body ]
///
/// This sits below the message layer: Channel deals only in raw byte frames.
/// message.zig encodes/decodes the structured content inside the body.
///
/// MAX_FRAME_SIZE (1 MiB) is enforced before reading the body, so a malicious
/// peer cannot force us to allocate unbounded memory.
///
/// Tests here cover the pure framing logic (encode/decode header, validation)
/// without any real I/O. Full TCP round-trip behaviour is covered by the
/// integration test in tests/network_integration.zig (runs separately).
const std = @import("std");

pub const MAX_FRAME_SIZE: u32 = 1024 * 1024; // 1 MiB

pub const ChannelError = error{
    /// Peer closed the connection cleanly.
    ConnectionClosed,
    /// Frame body_len exceeds MAX_FRAME_SIZE.
    FrameTooLarge,
    /// The supplied buffer is too small to hold the frame body.
    BufferTooSmall,
};

// ── Frame header helpers (pure, no I/O) ──────────────────────────────────────

/// Encode a 4-byte LE frame length header.
pub fn encode_frame_header(body_len: u32) [4]u8 {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, body_len, .little);
    return buf;
}

/// Decode and validate a 4-byte LE frame length header.
/// Returns FrameTooLarge if body_len > MAX_FRAME_SIZE.
pub fn decode_frame_header(buf: *const [4]u8) ChannelError!u32 {
    const body_len = std.mem.readInt(u32, buf, .little);
    if (body_len > MAX_FRAME_SIZE) return ChannelError.FrameTooLarge;
    return body_len;
}

/// Write a complete frame into a flat buffer: [4-byte header][body].
/// Returns the total number of bytes written, or BufferTooSmall.
pub fn write_frame_to_buf(body: []const u8, out: []u8) ChannelError!usize {
    const total = 4 + body.len;
    if (out.len < total) return ChannelError.BufferTooSmall;
    const hdr = encode_frame_header(@intCast(body.len));
    @memcpy(out[0..4], &hdr);
    if (body.len > 0) @memcpy(out[4 .. 4 + body.len], body);
    return total;
}

/// Read one frame from a flat buffer: validates header, copies body into `out`.
/// Returns the body slice (sub-slice of `out`), or an error.
pub fn read_frame_from_buf(src: []const u8, out: []u8) ChannelError![]u8 {
    if (src.len < 4) return ChannelError.ConnectionClosed;
    const body_len = try decode_frame_header(src[0..4]);
    if (body_len == 0) return out[0..0];
    if (src.len < 4 + body_len) return ChannelError.ConnectionClosed;
    if (out.len < body_len) return ChannelError.BufferTooSmall;
    @memcpy(out[0..body_len], src[4 .. 4 + body_len]);
    return out[0..body_len];
}

// ── Channel (wraps std.net.Stream for real I/O) ───────────────────────────────

pub const Channel = struct {
    stream: std.net.Stream,

    pub fn init(stream: std.net.Stream) Channel {
        return .{ .stream = stream };
    }

    pub fn close(self: Channel) void {
        self.stream.close();
    }

    /// Write a complete frame: 4-byte LE length header + body.
    pub fn write_frame(self: Channel, body: []const u8) !void {
        const hdr = encode_frame_header(@intCast(body.len));
        try write_all(self.stream, &hdr);
        if (body.len > 0) try write_all(self.stream, body);
    }

    /// Read one complete frame into `buf`. Returns a slice of `buf` with the body.
    pub fn read_frame(self: Channel, buf: []u8) ![]u8 {
        var hdr_buf: [4]u8 = undefined;
        try read_exact(self.stream, &hdr_buf);
        const body_len = try decode_frame_header(&hdr_buf);
        if (body_len == 0) return buf[0..0];
        if (buf.len < body_len) return ChannelError.BufferTooSmall;
        try read_exact(self.stream, buf[0..body_len]);
        return buf[0..body_len];
    }
};

// ── I/O helpers ───────────────────────────────────────────────────────────────

fn write_all(stream: std.net.Stream, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = try stream.write(data[written..]);
        if (n == 0) return ChannelError.ConnectionClosed;
        written += n;
    }
}

fn read_exact(stream: std.net.Stream, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return ChannelError.ConnectionClosed;
        total += n;
    }
}

// ── Tests (pure — no sockets, no threads) ─────────────────────────────────────

test "channel: encode_frame_header is little-endian" {
    const hdr = encode_frame_header(0x01020304);
    try std.testing.expectEqual(@as(u8, 0x04), hdr[0]); // LSB first
    try std.testing.expectEqual(@as(u8, 0x01), hdr[3]); // MSB last
}

test "channel: decode_frame_header round-trip" {
    const hdr = encode_frame_header(216);
    const len = try decode_frame_header(&hdr);
    try std.testing.expectEqual(@as(u32, 216), len);
}

test "channel: decode_frame_header accepts MAX_FRAME_SIZE" {
    const hdr = encode_frame_header(MAX_FRAME_SIZE);
    const len = try decode_frame_header(&hdr);
    try std.testing.expectEqual(MAX_FRAME_SIZE, len);
}

test "channel: decode_frame_header rejects > MAX_FRAME_SIZE" {
    const hdr = encode_frame_header(MAX_FRAME_SIZE + 1);
    try std.testing.expectError(ChannelError.FrameTooLarge, decode_frame_header(&hdr));
}

test "channel: write_frame_to_buf / read_frame_from_buf round-trip" {
    const body = [_]u8{ 0xAA, 0xBB, 0xCC };
    var wire: [4 + 3]u8 = undefined;
    const n = try write_frame_to_buf(&body, &wire);
    try std.testing.expectEqual(@as(usize, 7), n);

    var out: [3]u8 = undefined;
    const got = try read_frame_from_buf(&wire, &out);
    try std.testing.expectEqualSlices(u8, &body, got);
}

test "channel: write_frame_to_buf empty body" {
    var wire: [4]u8 = undefined;
    const n = try write_frame_to_buf(&[_]u8{}, &wire);
    try std.testing.expectEqual(@as(usize, 4), n);

    var out: [8]u8 = undefined;
    const got = try read_frame_from_buf(&wire, &out);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "channel: write_frame_to_buf rejects buffer too small" {
    const body = [_]u8{0x01} ** 10;
    var wire: [6]u8 = undefined; // 4 header + 10 body won't fit in 6
    try std.testing.expectError(ChannelError.BufferTooSmall, write_frame_to_buf(&body, &wire));
}

test "channel: read_frame_from_buf rejects truncated wire data" {
    // Only 3 bytes — not even a full header
    const wire = [_]u8{ 0x05, 0x00, 0x00 };
    var out: [8]u8 = undefined;
    try std.testing.expectError(ChannelError.ConnectionClosed, read_frame_from_buf(&wire, &out));
}

test "channel: read_frame_from_buf rejects body truncated mid-stream" {
    // Header says 5 bytes but wire only has 3 body bytes
    var wire: [4 + 3]u8 = undefined;
    std.mem.writeInt(u32, wire[0..4], 5, .little);
    @memset(wire[4..], 0x00);
    var out: [8]u8 = undefined;
    try std.testing.expectError(ChannelError.ConnectionClosed, read_frame_from_buf(&wire, &out));
}

test "channel: read_frame_from_buf rejects output buffer too small" {
    const body = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var wire: [4 + 4]u8 = undefined;
    _ = try write_frame_to_buf(&body, &wire);

    var out: [2]u8 = undefined; // too small for 4-byte body
    try std.testing.expectError(ChannelError.BufferTooSmall, read_frame_from_buf(&wire, &out));
}

test "channel: multiple frames in sequence" {
    const b1 = [_]u8{0x11};
    const b2 = [_]u8{ 0x22, 0x33 };
    const b3 = [_]u8{ 0x44, 0x55, 0x66 };

    // Write all three frames into a flat buffer
    var wire: [3 * 4 + 1 + 2 + 3]u8 = undefined;
    var off: usize = 0;
    off += try write_frame_to_buf(&b1, wire[off..]);
    off += try write_frame_to_buf(&b2, wire[off..]);
    off += try write_frame_to_buf(&b3, wire[off..]);

    // Read them back
    var out: [8]u8 = undefined;
    var pos: usize = 0;

    const f1 = try read_frame_from_buf(wire[pos..], &out);
    try std.testing.expectEqualSlices(u8, &b1, f1);
    pos += 4 + f1.len;

    const f2 = try read_frame_from_buf(wire[pos..], &out);
    try std.testing.expectEqualSlices(u8, &b2, f2);
    pos += 4 + f2.len;

    const f3 = try read_frame_from_buf(wire[pos..], &out);
    try std.testing.expectEqualSlices(u8, &b3, f3);
}

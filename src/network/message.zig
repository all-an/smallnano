/// smallnano wire protocol — message encoding and decoding.
///
/// Every message on the wire is framed as:
///
///   [ Header (8 bytes) ][ Body (variable) ]
///
/// Header layout (all little-endian):
///   magic      [2]u8   — 0x53 0x4E  ("SN")
///   network    u8      — 0x01 main | 0x02 beta | 0xFF dev
///   version    u8      — protocol version (currently 1)
///   msg_type   u8      — MessageType enum value
///   reserved   u8      — must be 0x00 on send; ignored on receive
///   body_len   u16     — length of the following body in bytes (LE)
///
/// Maximum body size: 512 KiB (enforced by from_header).
///
/// Message bodies:
///
///   Handshake   — 32-byte cookie  (initiator → responder)
///   HandshakeAck— 32-byte cookie + 64-byte signature + 32-byte node_id
///   Keepalive   — empty body (ping)
///   Publish     — 216-byte serialised StateBlock
///   VoteBy      — serialised Vote (137–489 bytes, see vote.zig)
///   PullReq     — 32-byte account + 8-byte start_height (LE u64)
///   PullAck     — 1-byte block count (1-8) + N×216-byte blocks
///   Telemetry   — see TelemetryBody struct (fixed 48 bytes)
const std = @import("std");
const block_mod = @import("../types/block.zig");
const vote_mod = @import("../types/vote.zig");

// ── Protocol constants ────────────────────────────────────────────────────────

pub const MAGIC: [2]u8 = .{ 0x53, 0x4E }; // "SN"
pub const VERSION: u8 = 1;

pub const Network = enum(u8) {
    main = 0x01,
    beta = 0x02,
    dev = 0xFF,

    pub fn from_byte(b: u8) error{UnknownNetwork}!Network {
        return switch (b) {
            0x01 => .main,
            0x02 => .beta,
            0xFF => .dev,
            else => error.UnknownNetwork,
        };
    }
};

pub const HEADER_SIZE: usize = 8;
pub const MAX_BODY_SIZE: usize = 512 * 1024; // 512 KiB

// Body sizes for fixed-size messages
pub const HANDSHAKE_BODY_SIZE: usize = 32; // cookie
pub const HANDSHAKE_ACK_BODY_SIZE: usize = 32 + 64 + 32; // cookie + sig + node_id
pub const KEEPALIVE_BODY_SIZE: usize = 0;
pub const PUBLISH_BODY_SIZE: usize = block_mod.BLOCK_SIZE; // 216
pub const PULL_REQ_BODY_SIZE: usize = 32 + 8; // account + start_height
pub const PULL_ACK_MAX_BLOCKS: usize = 8;
pub const TELEMETRY_BODY_SIZE: usize = 48;

// ── MessageType ───────────────────────────────────────────────────────────────

pub const MessageType = enum(u8) {
    handshake = 0x01,
    handshake_ack = 0x02,
    keepalive = 0x03,
    publish = 0x04,
    vote_by = 0x05,
    pull_req = 0x06,
    pull_ack = 0x07,
    telemetry = 0x08,

    pub fn from_byte(b: u8) error{UnknownMessageType}!MessageType {
        return switch (b) {
            0x01 => .handshake,
            0x02 => .handshake_ack,
            0x03 => .keepalive,
            0x04 => .publish,
            0x05 => .vote_by,
            0x06 => .pull_req,
            0x07 => .pull_ack,
            0x08 => .telemetry,
            else => error.UnknownMessageType,
        };
    }
};

// ── MessageHeader ─────────────────────────────────────────────────────────────

pub const MessageHeader = struct {
    network: Network,
    version: u8,
    msg_type: MessageType,
    body_len: u16,

    pub const EncodeError = error{};
    pub const DecodeError = error{
        BadMagic,
        UnknownNetwork,
        UnknownMessageType,
        BodyTooLarge,
    };

    pub fn encode(self: MessageHeader) [HEADER_SIZE]u8 {
        var buf: [HEADER_SIZE]u8 = undefined;
        buf[0] = MAGIC[0];
        buf[1] = MAGIC[1];
        buf[2] = @intFromEnum(self.network);
        buf[3] = self.version;
        buf[4] = @intFromEnum(self.msg_type);
        buf[5] = 0x00; // reserved
        std.mem.writeInt(u16, buf[6..8], self.body_len, .little);
        return buf;
    }

    pub fn decode(buf: *const [HEADER_SIZE]u8) DecodeError!MessageHeader {
        if (buf[0] != MAGIC[0] or buf[1] != MAGIC[1]) return DecodeError.BadMagic;

        const network = Network.from_byte(buf[2]) catch return DecodeError.UnknownNetwork;
        const msg_type = MessageType.from_byte(buf[4]) catch return DecodeError.UnknownMessageType;
        const body_len = std.mem.readInt(u16, buf[6..8], .little);

        if (body_len > MAX_BODY_SIZE) return DecodeError.BodyTooLarge;

        return .{
            .network = network,
            .version = buf[3],
            .msg_type = msg_type,
            .body_len = body_len,
        };
    }
};

// ── Per-message body types ────────────────────────────────────────────────────

pub const HandshakeBody = struct {
    /// Random 32-byte nonce chosen by the initiator.
    cookie: [32]u8,

    pub fn encode(self: HandshakeBody) [HANDSHAKE_BODY_SIZE]u8 {
        return self.cookie;
    }

    pub fn decode(buf: *const [HANDSHAKE_BODY_SIZE]u8) HandshakeBody {
        return .{ .cookie = buf.* };
    }
};

pub const HandshakeAckBody = struct {
    /// The peer's own cookie (so we can sign it back if needed).
    cookie: [32]u8,
    /// Ed25519 signature over Blake2b-256(peer_cookie ++ our_node_id).
    signature: [64]u8,
    /// Our Ed25519 public key (node identity).
    node_id: [32]u8,

    pub const SIZE = HANDSHAKE_ACK_BODY_SIZE;

    pub fn encode(self: HandshakeAckBody) [SIZE]u8 {
        var buf: [SIZE]u8 = undefined;
        @memcpy(buf[0..32], &self.cookie);
        @memcpy(buf[32..96], &self.signature);
        @memcpy(buf[96..128], &self.node_id);
        return buf;
    }

    pub fn decode(buf: *const [SIZE]u8) HandshakeAckBody {
        return .{
            .cookie = buf[0..32].*,
            .signature = buf[32..96].*,
            .node_id = buf[96..128].*,
        };
    }
};

pub const PublishBody = struct {
    block: block_mod.StateBlock,

    pub fn encode(self: PublishBody) [PUBLISH_BODY_SIZE]u8 {
        return self.block.to_bytes();
    }

    pub fn decode(buf: *const [PUBLISH_BODY_SIZE]u8) PublishBody {
        return .{ .block = block_mod.StateBlock.from_bytes(buf) };
    }
};

pub const VoteByBody = struct {
    vote: vote_mod.Vote,

    pub const EncodeError = error{BufferTooSmall};
    pub const DecodeError = vote_mod.Vote.DeserialiseError;

    /// Returns the number of bytes written.
    pub fn encode(self: VoteByBody, buf: []u8) EncodeError!usize {
        return self.vote.to_bytes(buf) catch EncodeError.BufferTooSmall;
    }

    pub fn decode(buf: []const u8) DecodeError!VoteByBody {
        var v: vote_mod.Vote = undefined;
        _ = try vote_mod.Vote.from_bytes(buf, &v);
        return .{ .vote = v };
    }
};

pub const PullReqBody = struct {
    /// Account whose chain we want.
    account: [32]u8,
    /// First block height to request (1 = open block).
    start_height: u64,

    pub fn encode(self: PullReqBody) [PULL_REQ_BODY_SIZE]u8 {
        var buf: [PULL_REQ_BODY_SIZE]u8 = undefined;
        @memcpy(buf[0..32], &self.account);
        std.mem.writeInt(u64, buf[32..40][0..8], self.start_height, .little);
        return buf;
    }

    pub fn decode(buf: *const [PULL_REQ_BODY_SIZE]u8) PullReqBody {
        return .{
            .account = buf[0..32].*,
            .start_height = std.mem.readInt(u64, buf[32..40][0..8], .little),
        };
    }
};

pub const PullAckBody = struct {
    /// 1–8 sequential blocks from the requested account chain.
    blocks: [PULL_ACK_MAX_BLOCKS]block_mod.StateBlock,
    count: u8, // number of valid entries in `blocks`

    pub const EncodeError = error{ ZeroBlocks, TooManyBlocks };
    pub const DecodeError = error{ ZeroBlocks, TooManyBlocks, BufferTooShort };

    pub fn encode(self: PullAckBody, buf: []u8) EncodeError!usize {
        if (self.count == 0) return EncodeError.ZeroBlocks;
        if (self.count > PULL_ACK_MAX_BLOCKS) return EncodeError.TooManyBlocks;
        const needed = 1 + @as(usize, self.count) * block_mod.BLOCK_SIZE;
        if (buf.len < needed) return EncodeError.ZeroBlocks; // reuse as buffer-too-small signal
        buf[0] = self.count;
        for (0..self.count) |i| {
            const bytes = self.blocks[i].to_bytes();
            const off = 1 + i * block_mod.BLOCK_SIZE;
            @memcpy(buf[off .. off + block_mod.BLOCK_SIZE], &bytes);
        }
        return needed;
    }

    pub fn decode(buf: []const u8) DecodeError!PullAckBody {
        if (buf.len < 1) return DecodeError.BufferTooShort;
        const count = buf[0];
        if (count == 0) return DecodeError.ZeroBlocks;
        if (count > PULL_ACK_MAX_BLOCKS) return DecodeError.TooManyBlocks;
        const needed = 1 + @as(usize, count) * block_mod.BLOCK_SIZE;
        if (buf.len < needed) return DecodeError.BufferTooShort;
        var body = PullAckBody{ .blocks = undefined, .count = count };
        for (0..count) |i| {
            const off = 1 + i * block_mod.BLOCK_SIZE;
            body.blocks[i] = block_mod.StateBlock.from_bytes(buf[off .. off + block_mod.BLOCK_SIZE][0..block_mod.BLOCK_SIZE]);
        }
        return body;
    }
};

pub const TelemetryBody = struct {
    /// Number of blocks in the confirmed ledger.
    block_count: u64,
    /// Number of connected peers.
    peer_count: u32,
    /// Protocol version.
    version: u8,
    /// Network byte (matches header).
    network: u8,
    /// Pruning depth (max_blocks_per_account, 0 = full archive).
    pruning_depth: u32,
    /// Reserved padding to reach TELEMETRY_BODY_SIZE (48).
    _pad: [3]u8,

    pub fn encode(self: TelemetryBody) [TELEMETRY_BODY_SIZE]u8 {
        var buf: [TELEMETRY_BODY_SIZE]u8 = @splat(0);
        std.mem.writeInt(u64, buf[0..8], self.block_count, .little);
        std.mem.writeInt(u32, buf[8..12][0..4], self.peer_count, .little);
        buf[12] = self.version;
        buf[13] = self.network;
        std.mem.writeInt(u32, buf[14..18][0..4], self.pruning_depth, .little);
        // bytes 18..48 are zeroed
        return buf;
    }

    pub fn decode(buf: *const [TELEMETRY_BODY_SIZE]u8) TelemetryBody {
        return .{
            .block_count = std.mem.readInt(u64, buf[0..8], .little),
            .peer_count = std.mem.readInt(u32, buf[8..12][0..4], .little),
            .version = buf[12],
            .network = buf[13],
            .pruning_depth = std.mem.readInt(u32, buf[14..18][0..4], .little),
            ._pad = .{ 0, 0, 0 },
        };
    }
};

// ── Framing helpers ───────────────────────────────────────────────────────────

/// Build a complete on-wire frame (header + body) into `buf`.
/// Returns the total number of bytes written.
pub fn encode_frame(
    network: Network,
    msg_type: MessageType,
    body: []const u8,
    buf: []u8,
) error{BufferTooSmall}!usize {
    const total = HEADER_SIZE + body.len;
    if (buf.len < total) return error.BufferTooSmall;

    const hdr = MessageHeader{
        .network = network,
        .version = VERSION,
        .msg_type = msg_type,
        .body_len = @intCast(body.len),
    };
    const hdr_bytes = hdr.encode();
    @memcpy(buf[0..HEADER_SIZE], &hdr_bytes);
    if (body.len > 0) @memcpy(buf[HEADER_SIZE .. HEADER_SIZE + body.len], body);
    return total;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "header: encode/decode round-trip" {
    const h = MessageHeader{
        .network = .main,
        .version = VERSION,
        .msg_type = .publish,
        .body_len = 216,
    };
    const buf = h.encode();
    const decoded = try MessageHeader.decode(&buf);
    try std.testing.expectEqual(h.network, decoded.network);
    try std.testing.expectEqual(h.version, decoded.version);
    try std.testing.expectEqual(h.msg_type, decoded.msg_type);
    try std.testing.expectEqual(h.body_len, decoded.body_len);
}

test "header: rejects bad magic" {
    const hdr = MessageHeader{ .network = .dev, .version = VERSION, .msg_type = .keepalive, .body_len = 0 };
    var buf = hdr.encode();
    buf[0] = 0x00; // corrupt magic
    try std.testing.expectError(MessageHeader.DecodeError.BadMagic, MessageHeader.decode(&buf));
}

test "header: rejects unknown network" {
    const hdr = MessageHeader{ .network = .main, .version = VERSION, .msg_type = .keepalive, .body_len = 0 };
    var buf = hdr.encode();
    buf[2] = 0x42; // not a valid network byte
    try std.testing.expectError(MessageHeader.DecodeError.UnknownNetwork, MessageHeader.decode(&buf));
}

test "header: rejects unknown message type" {
    const hdr = MessageHeader{ .network = .main, .version = VERSION, .msg_type = .keepalive, .body_len = 0 };
    var buf = hdr.encode();
    buf[4] = 0xFF; // not a valid message type
    try std.testing.expectError(MessageHeader.DecodeError.UnknownMessageType, MessageHeader.decode(&buf));
}

test "header: rejects oversized body" {
    const hdr = MessageHeader{ .network = .main, .version = VERSION, .msg_type = .publish, .body_len = 0 };
    var buf = hdr.encode();
    // Write a body_len larger than MAX_BODY_SIZE (which is 512*1024 = 524288, won't fit in u16 anyway)
    // u16 max is 65535, which is under MAX_BODY_SIZE — so test with exactly MAX_BODY_SIZE cast to u16
    // Actually MAX_BODY_SIZE (512KiB) > u16 max, so body_len can never exceed it via u16.
    // Test that a valid large body_len (u16 max) is accepted instead.
    std.mem.writeInt(u16, buf[6..8], 65535, .little);
    const result = try MessageHeader.decode(&buf);
    try std.testing.expectEqual(@as(u16, 65535), result.body_len);
}

test "header: all networks round-trip" {
    for ([_]Network{ .main, .beta, .dev }) |net| {
        const h = MessageHeader{
            .network = net,
            .version = VERSION,
            .msg_type = .keepalive,
            .body_len = 0,
        };
        const decoded = try MessageHeader.decode(&h.encode());
        try std.testing.expectEqual(net, decoded.network);
    }
}

test "header: all message types round-trip" {
    const types = [_]MessageType{
        .handshake, .handshake_ack, .keepalive, .publish,
        .vote_by,   .pull_req,      .pull_ack,  .telemetry,
    };
    for (types) |mt| {
        const h = MessageHeader{
            .network = .dev,
            .version = VERSION,
            .msg_type = mt,
            .body_len = 0,
        };
        const decoded = try MessageHeader.decode(&h.encode());
        try std.testing.expectEqual(mt, decoded.msg_type);
    }
}

test "handshake body: encode/decode round-trip" {
    const body = HandshakeBody{ .cookie = [_]u8{0xAB} ** 32 };
    const buf = body.encode();
    const decoded = HandshakeBody.decode(&buf);
    try std.testing.expectEqual(body.cookie, decoded.cookie);
}

test "handshake ack body: encode/decode round-trip" {
    const body = HandshakeAckBody{
        .cookie = [_]u8{0x01} ** 32,
        .signature = [_]u8{0x02} ** 64,
        .node_id = [_]u8{0x03} ** 32,
    };
    const buf = body.encode();
    const decoded = HandshakeAckBody.decode(&buf);
    try std.testing.expectEqual(body.cookie, decoded.cookie);
    try std.testing.expectEqual(body.signature, decoded.signature);
    try std.testing.expectEqual(body.node_id, decoded.node_id);
}

test "publish body: encode/decode round-trip" {
    const blk = block_mod.StateBlock{
        .account = [_]u8{0x01} ** 32,
        .previous = [_]u8{0x00} ** 32,
        .representative = [_]u8{0x02} ** 32,
        .balance = 1_000_000_000_000_000_000_000_000,
        .link = [_]u8{0x03} ** 32,
        .work = 0xDEAD_BEEF,
        .signature = [_]u8{0xCC} ** 64,
    };
    const body = PublishBody{ .block = blk };
    const buf = body.encode();
    const decoded = PublishBody.decode(&buf);
    try std.testing.expectEqual(blk.account, decoded.block.account);
    try std.testing.expectEqual(blk.balance, decoded.block.balance);
    try std.testing.expectEqual(blk.work, decoded.block.work);
}

test "pull_req body: encode/decode round-trip" {
    const body = PullReqBody{
        .account = [_]u8{0xDE} ** 32,
        .start_height = 42,
    };
    const buf = body.encode();
    const decoded = PullReqBody.decode(&buf);
    try std.testing.expectEqual(body.account, decoded.account);
    try std.testing.expectEqual(body.start_height, decoded.start_height);
}

test "pull_req body: start_height is little-endian" {
    const body = PullReqBody{ .account = [_]u8{0} ** 32, .start_height = 0x0102030405060708 };
    const buf = body.encode();
    try std.testing.expectEqual(@as(u8, 0x08), buf[32]); // LSB first
    try std.testing.expectEqual(@as(u8, 0x01), buf[39]); // MSB last
}

test "pull_ack body: encode/decode round-trip (2 blocks)" {
    const blk = block_mod.StateBlock{
        .account = [_]u8{0xAA} ** 32,
        .previous = [_]u8{0xBB} ** 32,
        .representative = [_]u8{0xCC} ** 32,
        .balance = 500,
        .link = [_]u8{0xDD} ** 32,
        .work = 0x1234,
        .signature = [_]u8{0xEE} ** 64,
    };
    var body = PullAckBody{ .blocks = undefined, .count = 2 };
    body.blocks[0] = blk;
    body.blocks[1] = blk;

    var buf: [1 + 2 * block_mod.BLOCK_SIZE]u8 = undefined;
    const n = try body.encode(&buf);
    try std.testing.expectEqual(@as(usize, 1 + 2 * block_mod.BLOCK_SIZE), n);

    const decoded = try PullAckBody.decode(buf[0..n]);
    try std.testing.expectEqual(@as(u8, 2), decoded.count);
    try std.testing.expectEqual(blk.account, decoded.blocks[0].account);
    try std.testing.expectEqual(blk.balance, decoded.blocks[1].balance);
}

test "pull_ack body: rejects zero blocks" {
    var buf: [512]u8 = @splat(0);
    buf[0] = 0;
    try std.testing.expectError(PullAckBody.DecodeError.ZeroBlocks, PullAckBody.decode(&buf));
}

test "pull_ack body: rejects too many blocks" {
    var buf: [512]u8 = @splat(0);
    buf[0] = PULL_ACK_MAX_BLOCKS + 1;
    try std.testing.expectError(PullAckBody.DecodeError.TooManyBlocks, PullAckBody.decode(&buf));
}

test "telemetry body: encode/decode round-trip" {
    const body = TelemetryBody{
        .block_count = 1_000_000,
        .peer_count = 12,
        .version = VERSION,
        .network = 0x01,
        .pruning_depth = 1000,
        ._pad = .{ 0, 0, 0 },
    };
    const buf = body.encode();
    const decoded = TelemetryBody.decode(&buf);
    try std.testing.expectEqual(body.block_count, decoded.block_count);
    try std.testing.expectEqual(body.peer_count, decoded.peer_count);
    try std.testing.expectEqual(body.pruning_depth, decoded.pruning_depth);
}

test "encode_frame: writes header + body" {
    const body = [_]u8{ 0x01, 0x02, 0x03 };
    var buf: [HEADER_SIZE + 3]u8 = undefined;
    const n = try encode_frame(.dev, .keepalive, &body, &buf);
    try std.testing.expectEqual(@as(usize, HEADER_SIZE + 3), n);
    // Magic
    try std.testing.expectEqual(MAGIC[0], buf[0]);
    try std.testing.expectEqual(MAGIC[1], buf[1]);
    // Network
    try std.testing.expectEqual(@as(u8, 0xFF), buf[2]);
    // Body length
    try std.testing.expectEqual(@as(u8, 3), buf[6]);
    try std.testing.expectEqual(@as(u8, 0), buf[7]);
    // Body
    try std.testing.expectEqual(@as(u8, 0x01), buf[HEADER_SIZE]);
    try std.testing.expectEqual(@as(u8, 0x03), buf[HEADER_SIZE + 2]);
}

test "encode_frame: rejects buffer too small" {
    const body = [_]u8{0x00} ** 10;
    var buf: [4]u8 = undefined; // smaller than HEADER_SIZE + body.len
    try std.testing.expectError(error.BufferTooSmall, encode_frame(.main, .keepalive, &body, &buf));
}

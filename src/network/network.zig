/// Network — peer set, accept loop, and outbound dialer for smallnano.
///
/// Network coordinates all TCP connections. It:
///   - Maintains a bounded map of known Peers (keyed by address string).
///   - Runs an accept loop (listener thread) that handles incoming connections.
///   - Runs a dial loop (dialer thread) that connects to known disconnected peers.
///   - Dispatches fully-framed, decoded messages to a caller-supplied callback.
///
/// Threading model:
///   - One listener thread: accept → handshake → spawn per-peer reader thread.
///   - One dialer thread: scans peer map, dials dialable peers.
///   - One reader thread per connected peer: reads frames, decodes messages,
///     calls on_message.
///   - All peer map mutations are protected by a Mutex.
///   - Shutdown is coordinated with a shared atomic stop flag.
///
/// This module is the application layer of M4; message.zig, handshake.zig,
/// channel.zig, bandwidth.zig, and peer.zig are its building blocks.
const std = @import("std");
const peer_mod = @import("peer.zig");
const message = @import("message.zig");
const channel_mod = @import("channel.zig");
const handshake_mod = @import("handshake.zig");
const bandwidth_mod = @import("bandwidth.zig");
const ed25519 = @import("../crypto/ed25519.zig");

pub const Peer = peer_mod.Peer;
pub const PeerAddress = peer_mod.PeerAddress;
pub const Channel = channel_mod.Channel;

// ── Configuration ─────────────────────────────────────────────────────────────

pub const NetworkConfig = struct {
    /// Maximum number of simultaneous peers (inbound + outbound combined).
    max_peers: usize = 50,
    /// Network identifier byte used in message headers.
    network: message.Network = .main,
    /// Our Ed25519 identity key pair.
    node_keypair: ed25519.KeyPair,
    /// TCP port to listen on.
    listen_port: u16 = 7176,
    /// Inbound bandwidth limit in bytes/sec. 0 = unlimited.
    bandwidth_limit_bytes_per_sec: u64 = 10 * 1024 * 1024, // 10 MiB/s
    /// Seconds between dialer scans.
    dial_interval_sec: u64 = 5,
    /// Seconds of inactivity before sending a keepalive.
    keepalive_interval_sec: i64 = 30,
};

// ── Message callback ──────────────────────────────────────────────────────────

/// Called on the reader thread for every valid decoded message.
/// `peer_addr` is the sender's address string.
/// Implementations must be thread-safe.
pub const OnMessageFn = *const fn (
    ctx: *anyopaque,
    peer_addr: []const u8,
    msg_type: message.MessageType,
    body: []const u8,
) void;

// ── Network ───────────────────────────────────────────────────────────────────

pub const Network = struct {
    allocator: std.mem.Allocator,
    config: NetworkConfig,

    /// Peer map: address string → Peer.  Protected by mutex.
    peers: std.StringHashMap(Peer),
    mutex: std.Thread.Mutex = .{},

    /// Set to true to signal all threads to stop.
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    listener_thread: ?std.Thread = null,
    dialer_thread: ?std.Thread = null,

    on_message_fn: OnMessageFn,
    on_message_ctx: *anyopaque,

    inbound_bw: bandwidth_mod.BandwidthLimiter,

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    pub fn init(
        allocator: std.mem.Allocator,
        config: NetworkConfig,
        on_message_fn: OnMessageFn,
        on_message_ctx: *anyopaque,
    ) Network {
        return .{
            .allocator = allocator,
            .config = config,
            .peers = std.StringHashMap(Peer).init(allocator),
            .on_message_fn = on_message_fn,
            .on_message_ctx = on_message_ctx,
            .inbound_bw = bandwidth_mod.BandwidthLimiter.init(
                config.bandwidth_limit_bytes_per_sec,
            ),
        };
    }

    pub fn deinit(self: *Network) void {
        self.stop.store(true, .release);
        if (self.listener_thread) |t| t.join();
        if (self.dialer_thread) |t| t.join();

        // Free address keys (they were duped on insertion).
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.peers.deinit();
    }

    /// Start the listener and dialer threads.
    pub fn start(self: *Network) !void {
        self.listener_thread = try std.Thread.spawn(.{}, listener_loop, .{self});
        self.dialer_thread = try std.Thread.spawn(.{}, dialer_loop, .{self});
    }

    // ── Peer management ───────────────────────────────────────────────────────

    /// Add a peer address to the known set (if not already present and under limit).
    /// The address string is duped; caller may free its own copy.
    pub fn add_known_peer(self: *Network, addr_str: []const u8) !void {
        const addr = try PeerAddress.parse(addr_str);
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.peers.contains(addr_str)) return; // already known
        if (self.peers.count() >= self.config.max_peers) return; // at capacity

        const key = try self.allocator.dupe(u8, addr_str);
        errdefer self.allocator.free(key);
        try self.peers.put(key, Peer.from_address(addr));
    }

    /// Number of currently connected (post-handshake) peers.
    pub fn connected_count(self: *Network) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        var it = self.peers.valueIterator();
        while (it.next()) |p| {
            if (p.is_active()) n += 1;
        }
        return n;
    }

    /// Total number of known peers (connected + disconnected + banned).
    pub fn peer_count(self: *Network) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.peers.count();
    }

    // ── Private: listener loop ────────────────────────────────────────────────

    fn listener_loop(self: *Network) void {
        const addr = std.net.Address.parseIp("0.0.0.0", self.config.listen_port) catch |e| {
            std.log.err("network: failed to parse listen address: {}", .{e});
            return;
        };
        var server = addr.listen(.{ .reuse_address = true }) catch |e| {
            std.log.err("network: failed to listen: {}", .{e});
            return;
        };
        defer server.deinit();

        std.log.info("network: listening on port {d}", .{self.config.listen_port});

        while (!self.stop.load(.acquire)) {
            // Non-blocking accept with a short timeout.
            const conn = server.accept() catch continue;
            if (self.stop.load(.acquire)) {
                conn.stream.close();
                break;
            }

            // Check peer capacity before spending time on the handshake.
            {
                self.mutex.lock();
                const count = self.peers.count();
                self.mutex.unlock();
                if (count >= self.config.max_peers) {
                    std.log.debug("network: peer limit reached, rejecting inbound", .{});
                    conn.stream.close();
                    continue;
                }
            }

            // Spawn a thread to complete the inbound handshake + read loop.
            const ctx = self.allocator.create(InboundCtx) catch {
                conn.stream.close();
                continue;
            };
            ctx.* = .{ .net = self, .conn = conn };
            std.Thread.spawn(.{}, inbound_peer_thread, .{ctx}) catch {
                conn.stream.close();
                self.allocator.destroy(ctx);
            };
        }
    }

    // ── Private: dialer loop ──────────────────────────────────────────────────

    fn dialer_loop(self: *Network) void {
        while (!self.stop.load(.acquire)) {
            const now_sec = std.time.timestamp();

            // Collect dialable peers under the lock.
            var to_dial = std.ArrayList(PeerAddress).initCapacity(
                self.allocator,
                8,
            ) catch break;
            defer to_dial.deinit();

            {
                self.mutex.lock();
                var it = self.peers.valueIterator();
                while (it.next()) |p| {
                    if (p.is_dialable(now_sec)) {
                        to_dial.append(p.address) catch {};
                        p.mark_connecting();
                    }
                }
                self.mutex.unlock();
            }

            for (to_dial.items) |addr| {
                const ctx = self.allocator.create(OutboundCtx) catch continue;
                ctx.* = .{ .net = self, .address = addr };
                std.Thread.spawn(.{}, outbound_peer_thread, .{ctx}) catch {
                    self.allocator.destroy(ctx);
                    // Mark peer failed so it's retried next scan.
                    self.mutex.lock();
                    if (self.peers.getPtr(addr.as_slice())) |p| p.mark_failed();
                    self.mutex.unlock();
                };
            }

            // Sleep for dial_interval_sec (in 100ms chunks to stay responsive to stop).
            var slept: u64 = 0;
            while (slept < self.config.dial_interval_sec * 1000 and
                !self.stop.load(.acquire))
            {
                std.time.sleep(100 * std.time.ns_per_ms);
                slept += 100;
            }
        }
    }

    // ── Private: per-peer I/O ─────────────────────────────────────────────────

    fn run_peer(
        self: *Network,
        stream: std.net.Stream,
        addr_str: []const u8,
        role: handshake_mod.HandshakeRole,
    ) void {
        const ch = Channel.init(stream);
        defer ch.close();

        // Run the handshake.
        var hs = handshake_mod.new_handshake(role, self.config.node_keypair);
        const random_cookie = blk: {
            var c: [32]u8 = undefined;
            std.crypto.random.bytes(&c);
            break :blk c;
        };

        var frame_buf: [4096]u8 = undefined;

        if (role == .initiator) {
            const frame = hs.initiate(self.config.network, random_cookie, &frame_buf) catch {
                self.on_peer_failed(addr_str);
                return;
            };
            ch.write_frame(frame[message.HEADER_SIZE..]) catch {
                self.on_peer_failed(addr_str);
                return;
            };
        }

        // Exchange handshake frames.
        var recv_buf: [4096]u8 = undefined;
        while (!hs.is_complete() and !self.stop.load(.acquire)) {
            const body = ch.read_frame(&recv_buf) catch {
                self.on_peer_failed(addr_str);
                return;
            };

            if (role == .responder and !hs.is_complete()) {
                // First message from initiator is a Handshake body (cookie only).
                if (body.len != message.HANDSHAKE_BODY_SIZE) {
                    self.on_peer_failed(addr_str);
                    return;
                }
                const hs_body = message.HandshakeBody.decode(body[0..message.HANDSHAKE_BODY_SIZE]);
                var our_cookie: [32]u8 = undefined;
                std.crypto.random.bytes(&our_cookie);
                const result = hs.recv_handshake_responder(
                    self.config.network,
                    hs_body,
                    our_cookie,
                    &frame_buf,
                ) catch {
                    self.on_peer_failed(addr_str);
                    return;
                };
                ch.write_frame(result.send[message.HEADER_SIZE..]) catch {
                    self.on_peer_failed(addr_str);
                    return;
                };
            } else {
                // HandshakeAck body.
                if (body.len != message.HANDSHAKE_ACK_BODY_SIZE) {
                    self.on_peer_failed(addr_str);
                    return;
                }
                const ack_body = message.HandshakeAckBody.decode(
                    body[0..message.HANDSHAKE_ACK_BODY_SIZE],
                );
                if (role == .initiator) {
                    var reply_buf: [4096]u8 = undefined;
                    const result = hs.recv_ack_initiator(
                        self.config.network,
                        ack_body,
                        &reply_buf,
                    ) catch {
                        self.on_peer_failed(addr_str);
                        return;
                    };
                    ch.write_frame(result.send[message.HEADER_SIZE..]) catch {
                        self.on_peer_failed(addr_str);
                        return;
                    };
                } else {
                    _ = hs.recv_ack_responder(ack_body) catch {
                        self.on_peer_failed(addr_str);
                        return;
                    };
                }
            }
        }

        // Handshake complete — update peer state.
        {
            self.mutex.lock();
            if (self.peers.getPtr(addr_str)) |p| {
                p.mark_connected(hs.peer_node_id, std.time.timestamp());
            }
            self.mutex.unlock();
        }
        std.log.info("network: peer connected: {s}", .{addr_str});

        // Read loop.
        var big_buf: [65536]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            const body = ch.read_frame(&big_buf) catch break;

            // Update last_seen.
            {
                self.mutex.lock();
                if (self.peers.getPtr(addr_str)) |p| p.touch(std.time.timestamp());
                self.mutex.unlock();
            }

            // Parse the header to get msg_type (header is prepended by the peer
            // via encode_frame; we re-read it from the body start... but actually
            // Channel strips the 4-byte length prefix; the body here IS the
            // message header + body from message.zig's perspective).
            // We re-parse the message header from the first 8 bytes of `body`.
            if (body.len < message.HEADER_SIZE) continue;
            const hdr = message.MessageHeader.decode(body[0..message.HEADER_SIZE]) catch continue;

            self.on_message_fn(
                self.on_message_ctx,
                addr_str,
                hdr.msg_type,
                body[message.HEADER_SIZE..],
            );
        }

        self.on_peer_disconnected(addr_str);
    }

    fn on_peer_failed(self: *Network, addr_str: []const u8) void {
        self.mutex.lock();
        if (self.peers.getPtr(addr_str)) |p| p.mark_failed();
        self.mutex.unlock();
    }

    fn on_peer_disconnected(self: *Network, addr_str: []const u8) void {
        self.mutex.lock();
        if (self.peers.getPtr(addr_str)) |p| p.mark_disconnected();
        self.mutex.unlock();
        std.log.info("network: peer disconnected: {s}", .{addr_str});
    }
};

// ── Thread context structs ────────────────────────────────────────────────────

const InboundCtx = struct {
    net: *Network,
    conn: std.net.Server.Connection,
};

fn inbound_peer_thread(ctx: *InboundCtx) void {
    defer ctx.net.allocator.destroy(ctx);
    const addr_buf = std.fmt.allocPrint(
        ctx.net.allocator,
        "{}",
        .{ctx.conn.address},
    ) catch {
        ctx.conn.stream.close();
        return;
    };
    defer ctx.net.allocator.free(addr_buf);

    // Register the peer (best-effort; might already be known).
    ctx.net.add_known_peer(addr_buf) catch {};

    ctx.net.run_peer(ctx.conn.stream, addr_buf, .responder);
}

const OutboundCtx = struct {
    net: *Network,
    address: PeerAddress,
};

fn outbound_peer_thread(ctx: *OutboundCtx) void {
    defer ctx.net.allocator.destroy(ctx);
    const addr_str = ctx.address.as_slice();

    const net_addr = std.net.Address.parseIp(addr_str, 0) catch {
        ctx.net.mutex.lock();
        if (ctx.net.peers.getPtr(addr_str)) |p| p.mark_failed();
        ctx.net.mutex.unlock();
        return;
    };

    const stream = std.net.tcpConnectToAddress(net_addr) catch {
        ctx.net.mutex.lock();
        if (ctx.net.peers.getPtr(addr_str)) |p| p.mark_failed();
        ctx.net.mutex.unlock();
        return;
    };

    ctx.net.run_peer(stream, addr_str, .initiator);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "network: add_known_peer and peer_count" {
    const alloc = std.testing.allocator;
    const kp = ed25519.KeyPair.generate();

    // Dummy callback — never called in this test.
    const cb: OnMessageFn = struct {
        fn f(_: *anyopaque, _: []const u8, _: message.MessageType, _: []const u8) void {}
    }.f;
    var dummy_ctx: u8 = 0;

    var net = Network.init(alloc, .{
        .max_peers = 3,
        .network = .dev,
        .node_keypair = kp,
    }, cb, &dummy_ctx);
    defer net.deinit();

    try net.add_known_peer("1.2.3.4:7176");
    try net.add_known_peer("1.2.3.5:7176");
    try std.testing.expectEqual(@as(usize, 2), net.peer_count());
}

test "network: duplicate peers are not double-added" {
    const alloc = std.testing.allocator;
    const kp = ed25519.KeyPair.generate();
    const cb: OnMessageFn = struct {
        fn f(_: *anyopaque, _: []const u8, _: message.MessageType, _: []const u8) void {}
    }.f;
    var dummy_ctx: u8 = 0;

    var net = Network.init(alloc, .{
        .max_peers = 10,
        .network = .dev,
        .node_keypair = kp,
    }, cb, &dummy_ctx);
    defer net.deinit();

    try net.add_known_peer("1.2.3.4:7176");
    try net.add_known_peer("1.2.3.4:7176"); // duplicate
    try std.testing.expectEqual(@as(usize, 1), net.peer_count());
}

test "network: max_peers limit is enforced" {
    const alloc = std.testing.allocator;
    const kp = ed25519.KeyPair.generate();
    const cb: OnMessageFn = struct {
        fn f(_: *anyopaque, _: []const u8, _: message.MessageType, _: []const u8) void {}
    }.f;
    var dummy_ctx: u8 = 0;

    var net = Network.init(alloc, .{
        .max_peers = 2,
        .network = .dev,
        .node_keypair = kp,
    }, cb, &dummy_ctx);
    defer net.deinit();

    try net.add_known_peer("1.2.3.4:7176");
    try net.add_known_peer("1.2.3.5:7176");
    try net.add_known_peer("1.2.3.6:7176"); // over limit — silently ignored
    try std.testing.expectEqual(@as(usize, 2), net.peer_count());
}

test "network: connected_count is 0 when no peers connected" {
    const alloc = std.testing.allocator;
    const kp = ed25519.KeyPair.generate();
    const cb: OnMessageFn = struct {
        fn f(_: *anyopaque, _: []const u8, _: message.MessageType, _: []const u8) void {}
    }.f;
    var dummy_ctx: u8 = 0;

    var net = Network.init(alloc, .{
        .max_peers = 10,
        .network = .dev,
        .node_keypair = kp,
    }, cb, &dummy_ctx);
    defer net.deinit();

    try net.add_known_peer("1.2.3.4:7176");
    try std.testing.expectEqual(@as(usize, 0), net.connected_count());
}

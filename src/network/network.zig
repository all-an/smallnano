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
const block_mod = @import("../types/block.zig");
const vote_mod = @import("../types/vote.zig");
const peer_mod = @import("peer.zig");
const message = @import("message.zig");
const channel_mod = @import("channel.zig");
const handshake_mod = @import("handshake.zig");
const bandwidth_mod = @import("bandwidth.zig");
const ed25519 = @import("../crypto/ed25519.zig");

pub const Peer = peer_mod.Peer;
pub const PeerAddress = peer_mod.PeerAddress;
pub const Channel = channel_mod.Channel;
pub const StateBlock = block_mod.StateBlock;
pub const Vote = vote_mod.Vote;

// ── Configuration ─────────────────────────────────────────────────────────────

pub const NetworkConfig = struct {
    /// Maximum number of simultaneous peers (inbound + outbound combined).
    max_peers: usize = 50,
    /// Network identifier byte used in message headers.
    network: message.Network = .main,
    /// Our Ed25519 identity key pair.
    node_keypair: ed25519.KeyPair,
    /// IP literal to bind the listener to.
    listen_address: []const u8 = "0.0.0.0",
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
    /// All worker-owned streams keyed by peer address. Protected by mutex.
    peer_streams: std.StringHashMap(std.net.Stream),
    /// Active post-handshake channels keyed by peer address. Protected by mutex.
    active_channels: std.StringHashMap(std.net.Stream),
    mutex: std.Thread.Mutex = .{},
    worker_mutex: std.Thread.Mutex = .{},
    worker_cond: std.Thread.Condition = .{},
    active_worker_count: usize = 0,

    /// Set to true to signal all threads to stop.
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
            .peer_streams = std.StringHashMap(std.net.Stream).init(allocator),
            .active_channels = std.StringHashMap(std.net.Stream).init(allocator),
            .on_message_fn = on_message_fn,
            .on_message_ctx = on_message_ctx,
            .inbound_bw = bandwidth_mod.BandwidthLimiter.init(
                config.bandwidth_limit_bytes_per_sec,
            ),
        };
    }

    pub fn stop(self: *Network) void {
        self.stop_requested.store(true, .release);
        self.close_peer_streams();

        if (self.listener_thread) |t| {
            t.join();
            self.listener_thread = null;
        }
        if (self.dialer_thread) |t| {
            t.join();
            self.dialer_thread = null;
        }
        self.wait_for_workers();
    }

    pub fn deinit(self: *Network) void {
        self.stop();

        // Free address keys (they were duped on insertion).
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.peer_streams.deinit();
        self.active_channels.deinit();
        self.peers.deinit();
    }

    /// Start the listener and dialer threads.
    pub fn start(self: *Network) !void {
        if (self.listener_thread != null or self.dialer_thread != null) return;
        self.stop_requested.store(false, .release);
        self.listener_thread = try std.Thread.spawn(.{}, listener_loop, .{self});
        errdefer {
            self.stop_requested.store(true, .release);
            if (self.listener_thread) |t| {
                t.join();
                self.listener_thread = null;
            }
        }
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

    pub fn broadcast_keepalive(self: *Network) !usize {
        var frame: [message.HEADER_SIZE]u8 = undefined;
        const len = try message.encode_frame(self.config.network, .keepalive, "", &frame);
        return self.broadcast_frame(frame[0..len]);
    }

    pub fn broadcast_publish(self: *Network, blk: *const StateBlock) !usize {
        const body = (message.PublishBody{ .block = blk.* }).encode();
        var frame: [message.HEADER_SIZE + message.PUBLISH_BODY_SIZE]u8 = undefined;
        const len = try message.encode_frame(self.config.network, .publish, &body, &frame);
        return self.broadcast_frame(frame[0..len]);
    }

    pub fn broadcast_vote(self: *Network, vote: *const Vote) !usize {
        var body_buf: [512]u8 = undefined;
        const body_len = try (message.VoteByBody{ .vote = vote.* }).encode(&body_buf);

        var frame: [message.HEADER_SIZE + 512]u8 = undefined;
        const len = try message.encode_frame(
            self.config.network,
            .vote_by,
            body_buf[0..body_len],
            &frame,
        );
        return self.broadcast_frame(frame[0..len]);
    }

    pub fn send_pull_req(self: *Network, peer_addr: []const u8, req: message.PullReqBody) !void {
        const body = req.encode();
        var frame: [message.HEADER_SIZE + message.PULL_REQ_BODY_SIZE]u8 = undefined;
        const len = try message.encode_frame(self.config.network, .pull_req, &body, &frame);
        try self.write_frame_to_peer(peer_addr, frame[0..len]);
    }

    // ── Private: listener loop ────────────────────────────────────────────────

    fn listener_loop(self: *Network) void {
        const addr = std.net.Address.parseIp(self.config.listen_address, self.config.listen_port) catch |e| {
            std.log.err("network: failed to parse listen address: {}", .{e});
            return;
        };
        var server = addr.listen(.{
            .reuse_address = true,
            .force_nonblocking = true,
        }) catch |e| {
            std.log.err("network: failed to listen: {}", .{e});
            return;
        };
        defer server.deinit();

        std.log.info("network: listening on {s}:{d}", .{
            self.config.listen_address,
            self.config.listen_port,
        });

        while (!self.stop_requested.load(.acquire)) {
            const conn = server.accept() catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(20 * std.time.ns_per_ms);
                    continue;
                },
                else => continue,
            };
            if (self.stop_requested.load(.acquire)) {
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
            self.track_worker_start();
            const ctx = self.allocator.create(InboundCtx) catch {
                self.track_worker_done();
                conn.stream.close();
                continue;
            };
            ctx.* = .{ .net = self, .conn = conn };
            _ = std.Thread.spawn(.{}, inbound_peer_thread, .{ctx}) catch {
                self.track_worker_done();
                conn.stream.close();
                self.allocator.destroy(ctx);
            };
        }
    }

    // ── Private: dialer loop ──────────────────────────────────────────────────

    fn dialer_loop(self: *Network) void {
        while (!self.stop_requested.load(.acquire)) {
            const now_sec = std.time.timestamp();

            // Collect dialable peers under the lock.
            var to_dial = std.ArrayList(PeerAddress).initCapacity(
                self.allocator,
                8,
            ) catch break;
            defer to_dial.deinit(self.allocator);

            {
                self.mutex.lock();
                var it = self.peers.valueIterator();
                while (it.next()) |p| {
                    if (p.is_dialable(now_sec)) {
                        to_dial.append(self.allocator, p.address) catch {};
                        p.mark_connecting();
                    }
                }
                self.mutex.unlock();
            }

            for (to_dial.items) |addr| {
                self.track_worker_start();
                const ctx = self.allocator.create(OutboundCtx) catch {
                    self.track_worker_done();
                    continue;
                };
                ctx.* = .{ .net = self, .address = addr };
                _ = std.Thread.spawn(.{}, outbound_peer_thread, .{ctx}) catch {
                    self.track_worker_done();
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
                !self.stop_requested.load(.acquire))
            {
                std.Thread.sleep(100 * std.time.ns_per_ms);
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
        defer self.unregister_peer_stream(addr_str);

        self.register_peer_stream(addr_str, stream) catch {
            self.on_peer_failed(addr_str);
            return;
        };

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
        while (!hs.is_complete() and !self.stop_requested.load(.acquire)) {
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
            const key = self.find_peer_key(addr_str) orelse {
                self.mutex.unlock();
                self.on_peer_failed(addr_str);
                return;
            };
            self.active_channels.put(key, stream) catch {
                self.mutex.unlock();
                self.on_peer_failed(addr_str);
                return;
            };
            self.mutex.unlock();
        }
        std.log.info("network: peer connected: {s}", .{addr_str});

        // Read loop.
        var big_buf: [65536]u8 = undefined;
        while (!self.stop_requested.load(.acquire)) {
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
        _ = self.peer_streams.remove(addr_str);
        _ = self.active_channels.remove(addr_str);
        if (self.peers.getPtr(addr_str)) |p| p.mark_disconnected();
        self.mutex.unlock();
        std.log.info("network: peer disconnected: {s}", .{addr_str});
    }

    fn register_peer_stream(self: *Network, addr_str: []const u8, stream: std.net.Stream) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = self.find_peer_key(addr_str) orelse return error.UnknownPeer;
        try self.peer_streams.put(key, stream);
    }

    fn unregister_peer_stream(self: *Network, addr_str: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.peer_streams.remove(addr_str);
        _ = self.active_channels.remove(addr_str);
    }

    fn close_peer_streams(self: *Network) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.peer_streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.close();
        }
    }

    fn track_worker_start(self: *Network) void {
        self.worker_mutex.lock();
        defer self.worker_mutex.unlock();
        self.active_worker_count += 1;
    }

    fn track_worker_done(self: *Network) void {
        self.worker_mutex.lock();
        defer self.worker_mutex.unlock();
        std.debug.assert(self.active_worker_count > 0);
        self.active_worker_count -= 1;
        self.worker_cond.signal();
    }

    fn wait_for_workers(self: *Network) void {
        self.worker_mutex.lock();
        defer self.worker_mutex.unlock();
        while (self.active_worker_count > 0) {
            self.worker_cond.wait(&self.worker_mutex);
        }
    }

    fn broadcast_frame(self: *Network, frame: []const u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var sent: usize = 0;
        var it = self.active_channels.iterator();
        while (it.next()) |entry| {
            const ch = Channel.init(entry.value_ptr.*);
            ch.write_frame(frame) catch {
                if (self.peers.getPtr(entry.key_ptr.*)) |p| p.mark_failed();
                continue;
            };
            sent += 1;
        }
        return sent;
    }

    fn write_frame_to_peer(self: *Network, peer_addr: []const u8, frame: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stream = self.active_channels.get(peer_addr) orelse return error.PeerNotConnected;
        const ch = Channel.init(stream);
        ch.write_frame(frame) catch {
            if (self.peers.getPtr(peer_addr)) |p| p.mark_failed();
            return error.PeerNotConnected;
        };
    }

    fn find_peer_key(self: *Network, addr_str: []const u8) ?[]const u8 {
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, addr_str)) return entry.key_ptr.*;
        }
        return null;
    }
};

// ── Thread context structs ────────────────────────────────────────────────────

const InboundCtx = struct {
    net: *Network,
    conn: std.net.Server.Connection,
};

fn inbound_peer_thread(ctx: *InboundCtx) void {
    defer ctx.net.track_worker_done();
    defer ctx.net.allocator.destroy(ctx);
    const addr_buf = std.fmt.allocPrint(
        ctx.net.allocator,
        "{f}",
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
    defer ctx.net.track_worker_done();
    defer ctx.net.allocator.destroy(ctx);
    const addr_str = ctx.address.as_slice();

    const net_addr = parse_peer_socket_address(addr_str) catch {
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

fn parse_peer_socket_address(addr_str: []const u8) !std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse return error.InvalidAddress;
    const host = addr_str[0..colon];
    const port = try std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10);

    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        return std.net.Address.parseIp(host[1 .. host.len - 1], port);
    }
    return std.net.Address.parseIp(host, port);
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

fn make_stream_pair() ![2]std.net.Stream {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    return .{
        .{ .handle = fds[0] },
        .{ .handle = fds[1] },
    };
}

fn register_test_channel(net: *Network, addr: []const u8, stream: std.net.Stream) !void {
    try net.add_known_peer(addr);
    net.mutex.lock();
    defer net.mutex.unlock();
    const key = net.find_peer_key(addr).?;
    try net.active_channels.put(key, stream);
    if (net.peers.getPtr(addr)) |p| p.mark_connected([_]u8{0xAB} ** 32, std.time.timestamp());
}

test "network: broadcast_keepalive writes a keepalive frame to active peers" {
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

    var pair = try make_stream_pair();
    defer pair[0].close();
    defer pair[1].close();

    try register_test_channel(&net, "127.0.0.1:7176", pair[0]);
    try std.testing.expectEqual(@as(usize, 1), try net.broadcast_keepalive());

    var recv_buf: [128]u8 = undefined;
    const body = try Channel.init(pair[1]).read_frame(&recv_buf);
    try std.testing.expectEqual(@as(usize, message.HEADER_SIZE), body.len);
    const hdr = try message.MessageHeader.decode(body[0..message.HEADER_SIZE]);
    try std.testing.expectEqual(message.MessageType.keepalive, hdr.msg_type);
    try std.testing.expectEqual(@as(u16, 0), hdr.body_len);
}

test "network: broadcast_publish writes encoded publish blocks" {
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

    var pair = try make_stream_pair();
    defer pair[0].close();
    defer pair[1].close();

    try register_test_channel(&net, "127.0.0.1:7176", pair[0]);

    const blk = StateBlock{
        .account = [_]u8{0x01} ** 32,
        .previous = [_]u8{0x02} ** 32,
        .representative = [_]u8{0x03} ** 32,
        .balance = 42,
        .link = [_]u8{0x04} ** 32,
        .work = 0x0102030405060708,
        .signature = [_]u8{0x05} ** 64,
    };

    try std.testing.expectEqual(@as(usize, 1), try net.broadcast_publish(&blk));

    var recv_buf: [512]u8 = undefined;
    const body = try Channel.init(pair[1]).read_frame(&recv_buf);
    const hdr = try message.MessageHeader.decode(body[0..message.HEADER_SIZE]);
    try std.testing.expectEqual(message.MessageType.publish, hdr.msg_type);

    const publish = message.PublishBody.decode(body[message.HEADER_SIZE .. message.HEADER_SIZE + message.PUBLISH_BODY_SIZE][0..message.PUBLISH_BODY_SIZE]);
    try std.testing.expectEqual(blk.account, publish.block.account);
    try std.testing.expectEqual(blk.balance, publish.block.balance);
}

test "network: broadcast_vote writes encoded votes" {
    const alloc = std.testing.allocator;
    const kp = ed25519.KeyPair.generate();
    const voter = try ed25519.KeyPair.from_seed(&([_]u8{0x11} ** 32));
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

    var pair = try make_stream_pair();
    defer pair[0].close();
    defer pair[1].close();

    try register_test_channel(&net, "127.0.0.1:7176", pair[0]);

    const vote = try Vote.create(&voter.secret, &voter.public, 7, &.{[_]u8{0xAA} ** 32});
    try std.testing.expectEqual(@as(usize, 1), try net.broadcast_vote(&vote));

    var recv_buf: [1024]u8 = undefined;
    const body = try Channel.init(pair[1]).read_frame(&recv_buf);
    const hdr = try message.MessageHeader.decode(body[0..message.HEADER_SIZE]);
    try std.testing.expectEqual(message.MessageType.vote_by, hdr.msg_type);

    const decoded = try message.VoteByBody.decode(body[message.HEADER_SIZE..]);
    try std.testing.expectEqual(vote.representative, decoded.vote.representative);
    try std.testing.expectEqual(vote.timestamp, decoded.vote.timestamp);
    try std.testing.expectEqual(vote.hashes.constSlice()[0], decoded.vote.hashes.constSlice()[0]);
}

test "network: send_pull_req targets one active peer" {
    const alloc = std.testing.allocator;
    const kp = ed25519.KeyPair.generate();
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

    var pair_a = try make_stream_pair();
    defer pair_a[0].close();
    defer pair_a[1].close();
    var pair_b = try make_stream_pair();
    defer pair_b[0].close();
    defer pair_b[1].close();

    try register_test_channel(&net, "127.0.0.1:7176", pair_a[0]);
    try register_test_channel(&net, "127.0.0.1:7177", pair_b[0]);

    const req = message.PullReqBody{
        .account = [_]u8{0x77} ** 32,
        .start_height = 9,
    };
    try net.send_pull_req("127.0.0.1:7177", req);

    var recv_buf: [256]u8 = undefined;
    const body = try Channel.init(pair_b[1]).read_frame(&recv_buf);
    const hdr = try message.MessageHeader.decode(body[0..message.HEADER_SIZE]);
    try std.testing.expectEqual(message.MessageType.pull_req, hdr.msg_type);
    const decoded = message.PullReqBody.decode(body[message.HEADER_SIZE .. message.HEADER_SIZE + message.PULL_REQ_BODY_SIZE][0..message.PULL_REQ_BODY_SIZE]);
    try std.testing.expectEqual(req.account, decoded.account);
    try std.testing.expectEqual(req.start_height, decoded.start_height);
}

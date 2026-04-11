/// Node-ID cookie/challenge handshake for smallnano.
///
/// The handshake establishes mutual authentication between two nodes using
/// their Ed25519 node identity keys. It is pure logic — no I/O, no allocations.
///
/// Protocol (initiator → responder):
///
///   1. Initiator picks a random 32-byte cookie and sends a Handshake message.
///
///   2. Responder:
///        a. Signs  Blake2b-256(initiator_cookie ++ responder_node_id)  with its secret key.
///        b. Picks its own 32-byte cookie.
///        c. Sends HandshakeAck{ cookie=responder_cookie, signature=sig, node_id=responder_pub }.
///
///   3. Initiator:
///        a. Verifies the signature against responder's node_id.
///        b. Signs  Blake2b-256(responder_cookie ++ initiator_node_id)  with its own key.
///        c. Sends HandshakeAck{ cookie=initiator_cookie, signature=sig, node_id=initiator_pub }.
///        d. Transitions to Complete and records the responder's node_id.
///
///   4. Responder:
///        a. Verifies the signature.
///        b. Transitions to Complete and records the initiator's node_id.
///
/// Both sides call the appropriate state-machine function with the bytes received;
/// the function returns the bytes to send back (or nothing on completion).
///
/// Signing payload helper (used by both sides):
///   Blake2b-256( peer_cookie(32) ++ own_node_id(32) )   → 32-byte hash, then Ed25519-sign
const std = @import("std");
const blake2b = @import("../crypto/blake2b.zig");
const ed25519 = @import("../crypto/ed25519.zig");
const message = @import("message.zig");

// ── Signing payload ───────────────────────────────────────────────────────────

/// Compute the 32-byte value that gets signed.
/// payload = Blake2b-256(peer_cookie ++ own_node_id)
pub fn signing_payload(peer_cookie: *const [32]u8, own_node_id: *const [32]u8) [32]u8 {
    return blake2b.hash256(&.{ peer_cookie, own_node_id });
}

// ── HandshakeState ────────────────────────────────────────────────────────────

pub const HandshakeError = error{
    /// Received a message while in an unexpected state.
    UnexpectedMessage,
    /// The peer's Ed25519 signature did not verify.
    InvalidSignature,
    /// Handshake already complete.
    AlreadyComplete,
};

pub const HandshakeRole = enum { initiator, responder };

/// Outcome returned by step().
pub const StepResult = union(enum) {
    /// Bytes to send to the peer (slice into caller-supplied buffer).
    send: []u8,
    /// Handshake complete; peer_node_id has been populated.
    complete,
};

/// State machine for one handshake. Embed in a connection struct.
/// All buffers are caller-owned; Handshake holds no heap memory.
pub const Handshake = struct {
    role: HandshakeRole,
    /// Our identity key pair.
    our_secret: ed25519.SecretKey,
    our_node_id: [32]u8,
    /// Cookie we sent to the peer.
    our_cookie: [32]u8,
    /// Authenticated peer identity (valid only after state == .complete).
    peer_node_id: [32]u8,

    state: enum { idle, awaiting_ack, complete } = .idle,

    // ── Initiator API ─────────────────────────────────────────────────────────

    /// (Initiator) Build the initial Handshake frame into `buf`.
    /// Call this once, then send the returned slice.
    pub fn initiate(
        self: *Handshake,
        network: message.Network,
        cookie: [32]u8,
        buf: []u8,
    ) error{BufferTooSmall}![]u8 {
        std.debug.assert(self.role == .initiator);
        std.debug.assert(self.state == .idle);
        self.our_cookie = cookie;
        self.state = .awaiting_ack;

        const body = message.HandshakeBody{ .cookie = cookie };
        const body_bytes = body.encode();
        const n = try message.encode_frame(network, .handshake, &body_bytes, buf);
        return buf[0..n];
    }

    /// (Initiator) Process the responder's HandshakeAck body bytes.
    /// On success, writes the reply HandshakeAck frame into `out_buf` and returns
    /// StepResult.send. Caller must send those bytes, then the handshake is done.
    pub fn recv_ack_initiator(
        self: *Handshake,
        network: message.Network,
        ack_body: message.HandshakeAckBody,
        out_buf: []u8,
    ) (HandshakeError || error{BufferTooSmall})!StepResult {
        if (self.state != .awaiting_ack) return HandshakeError.UnexpectedMessage;

        // Verify the responder's signature over (our_cookie ++ responder_node_id).
        const payload = signing_payload(&self.our_cookie, &ack_body.node_id);
        ed25519.verify(&payload, &ack_body.signature, &ack_body.node_id) catch
            return HandshakeError.InvalidSignature;

        self.peer_node_id = ack_body.node_id;

        // Sign the responder's cookie.
        const reply_payload = signing_payload(&ack_body.cookie, &self.our_node_id);
        const sig = ed25519.sign(&reply_payload, &self.our_secret) catch
            return HandshakeError.InvalidSignature;

        // Build our HandshakeAck.
        const reply_body = message.HandshakeAckBody{
            .cookie = ack_body.cookie,
            .signature = sig,
            .node_id = self.our_node_id,
        };
        const reply_bytes = reply_body.encode();
        const n = try message.encode_frame(network, .handshake_ack, &reply_bytes, out_buf);

        self.state = .complete;
        return .{ .send = out_buf[0..n] };
    }

    // ── Responder API ─────────────────────────────────────────────────────────

    /// (Responder) Process the initiator's Handshake body bytes.
    /// Writes the HandshakeAck frame into `out_buf` and returns StepResult.send.
    pub fn recv_handshake_responder(
        self: *Handshake,
        network: message.Network,
        hs_body: message.HandshakeBody,
        our_cookie: [32]u8,
        out_buf: []u8,
    ) (HandshakeError || error{BufferTooSmall})!StepResult {
        if (self.state != .idle) return HandshakeError.UnexpectedMessage;

        self.our_cookie = our_cookie;
        self.state = .awaiting_ack;

        // Sign the initiator's cookie.
        const payload = signing_payload(&hs_body.cookie, &self.our_node_id);
        const sig = ed25519.sign(&payload, &self.our_secret) catch
            return HandshakeError.InvalidSignature;

        const reply_body = message.HandshakeAckBody{
            .cookie = our_cookie,
            .signature = sig,
            .node_id = self.our_node_id,
        };
        const reply_bytes = reply_body.encode();
        const n = try message.encode_frame(network, .handshake_ack, &reply_bytes, out_buf);

        return .{ .send = out_buf[0..n] };
    }

    /// (Responder) Process the initiator's HandshakeAck body.
    /// Verifies the signature and transitions to complete.
    pub fn recv_ack_responder(
        self: *Handshake,
        ack_body: message.HandshakeAckBody,
    ) HandshakeError!StepResult {
        if (self.state != .awaiting_ack) return HandshakeError.UnexpectedMessage;

        // Verify initiator signed (our_cookie ++ initiator_node_id).
        const payload = signing_payload(&self.our_cookie, &ack_body.node_id);
        ed25519.verify(&payload, &ack_body.signature, &ack_body.node_id) catch
            return HandshakeError.InvalidSignature;

        self.peer_node_id = ack_body.node_id;
        self.state = .complete;
        return .complete;
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    pub fn is_complete(self: *const Handshake) bool {
        return self.state == .complete;
    }
};

/// Convenience constructor.
pub fn new_handshake(role: HandshakeRole, kp: ed25519.KeyPair) Handshake {
    return Handshake{
        .role = role,
        .our_secret = kp.secret,
        .our_node_id = kp.public,
        .our_cookie = [_]u8{0} ** 32,
        .peer_node_id = [_]u8{0} ** 32,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "handshake: full initiator↔responder exchange succeeds" {
    const kp_i = ed25519.KeyPair.generate();
    const kp_r = ed25519.KeyPair.generate();

    var hs_i = new_handshake(.initiator, kp_i);
    var hs_r = new_handshake(.responder, kp_r);

    var buf_i: [512]u8 = undefined;
    var buf_r: [512]u8 = undefined;

    // Step 1: initiator sends Handshake
    const cookie_i = [_]u8{0x11} ** 32;
    const frame1 = try hs_i.initiate(.dev, cookie_i, &buf_i);

    // Parse frame1 at responder — skip header (8 bytes), decode body
    const hs_body = message.HandshakeBody.decode(frame1[message.HEADER_SIZE..][0..message.HANDSHAKE_BODY_SIZE]);

    // Step 2: responder processes Handshake, sends HandshakeAck
    const cookie_r = [_]u8{0x22} ** 32;
    const result_r1 = try hs_r.recv_handshake_responder(.dev, hs_body, cookie_r, &buf_r);
    const frame2 = result_r1.send;

    // Parse frame2 at initiator
    const ack_body_r = message.HandshakeAckBody.decode(frame2[message.HEADER_SIZE..][0..message.HANDSHAKE_ACK_BODY_SIZE]);

    // Step 3: initiator processes HandshakeAck, sends its own HandshakeAck
    var buf_i2: [512]u8 = undefined;
    const result_i = try hs_i.recv_ack_initiator(.dev, ack_body_r, &buf_i2);
    const frame3 = result_i.send;

    // Parse frame3 at responder
    const ack_body_i = message.HandshakeAckBody.decode(frame3[message.HEADER_SIZE..][0..message.HANDSHAKE_ACK_BODY_SIZE]);

    // Step 4: responder finalises
    const result_r2 = try hs_r.recv_ack_responder(ack_body_i);
    try std.testing.expectEqual(StepResult.complete, result_r2);

    // Both sides complete and know each other's node_id
    try std.testing.expect(hs_i.is_complete());
    try std.testing.expect(hs_r.is_complete());
    try std.testing.expectEqual(kp_r.public, hs_i.peer_node_id);
    try std.testing.expectEqual(kp_i.public, hs_r.peer_node_id);
}

test "handshake: responder rejects tampered initiator signature" {
    const kp_i = ed25519.KeyPair.generate();
    const kp_r = ed25519.KeyPair.generate();

    var hs_i = new_handshake(.initiator, kp_i);
    var hs_r = new_handshake(.responder, kp_r);

    var buf: [512]u8 = undefined;

    const frame1 = try hs_i.initiate(.dev, [_]u8{0xAA} ** 32, &buf);
    const hs_body = message.HandshakeBody.decode(frame1[message.HEADER_SIZE..][0..message.HANDSHAKE_BODY_SIZE]);

    var buf_r: [512]u8 = undefined;
    const result = try hs_r.recv_handshake_responder(.dev, hs_body, [_]u8{0xBB} ** 32, &buf_r);
    const frame2 = result.send;

    var ack_body = message.HandshakeAckBody.decode(frame2[message.HEADER_SIZE..][0..message.HANDSHAKE_ACK_BODY_SIZE]);

    // Corrupt the initiator's reply
    var buf_i2: [512]u8 = undefined;
    const result2 = try hs_i.recv_ack_initiator(.dev, ack_body, &buf_i2);
    var frame3 = result2.send;
    // Flip a byte in the signature part of the body
    frame3[message.HEADER_SIZE + 32] ^= 0xFF;

    ack_body = message.HandshakeAckBody.decode(frame3[message.HEADER_SIZE..][0..message.HANDSHAKE_ACK_BODY_SIZE]);
    try std.testing.expectError(
        HandshakeError.InvalidSignature,
        hs_r.recv_ack_responder(ack_body),
    );
}

test "handshake: initiator rejects tampered responder signature" {
    const kp_i = ed25519.KeyPair.generate();
    const kp_r = ed25519.KeyPair.generate();

    var hs_i = new_handshake(.initiator, kp_i);
    var hs_r = new_handshake(.responder, kp_r);

    var buf_i: [512]u8 = undefined;
    var buf_r: [512]u8 = undefined;

    const frame1 = try hs_i.initiate(.dev, [_]u8{0x55} ** 32, &buf_i);
    const hs_body = message.HandshakeBody.decode(frame1[message.HEADER_SIZE..][0..message.HANDSHAKE_BODY_SIZE]);

    const result_r = try hs_r.recv_handshake_responder(.dev, hs_body, [_]u8{0x66} ** 32, &buf_r);
    var frame2 = result_r.send;

    // Corrupt a byte in the responder's signature
    frame2[message.HEADER_SIZE + 32] ^= 0xFF;

    const ack_body = message.HandshakeAckBody.decode(frame2[message.HEADER_SIZE..][0..message.HANDSHAKE_ACK_BODY_SIZE]);

    var buf_i2: [512]u8 = undefined;
    try std.testing.expectError(
        HandshakeError.InvalidSignature,
        hs_i.recv_ack_initiator(.dev, ack_body, &buf_i2),
    );
}

test "handshake: signing_payload is deterministic" {
    const cookie = [_]u8{0x01} ** 32;
    const node_id = [_]u8{0x02} ** 32;
    const p1 = signing_payload(&cookie, &node_id);
    const p2 = signing_payload(&cookie, &node_id);
    try std.testing.expectEqual(p1, p2);
}

test "handshake: signing_payload differs for different inputs" {
    const c1 = [_]u8{0x01} ** 32;
    const c2 = [_]u8{0x02} ** 32;
    const n = [_]u8{0x03} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &signing_payload(&c1, &n), &signing_payload(&c2, &n)));
}

/// Ed25519 wrappers for smallnano — Zig 0.15 API.
///
/// Thin wrappers around std.crypto.sign.Ed25519 with smallnano-specific
/// error types and convenience helpers for block signing/verification.
const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;

// ── Types ────────────────────────────────────────────────────────────────────

pub const PublicKey = [32]u8;
/// 64-byte Ed25519 secret key (seed || public key, as per RFC 8032).
pub const SecretKey = [64]u8;
pub const Signature = [64]u8;

/// A key pair: secret key (64 bytes) and public key (32 bytes).
pub const KeyPair = struct {
    secret: SecretKey,
    public: PublicKey,

    /// Generate a new random key pair using the OS RNG.
    pub fn generate() KeyPair {
        const kp = Ed25519.KeyPair.generate();
        return .{
            .secret = kp.secret_key.toBytes(),
            .public = kp.public_key.toBytes(),
        };
    }

    /// Derive a key pair deterministically from a 32-byte seed.
    pub fn from_seed(seed: *const [32]u8) !KeyPair {
        const kp = try Ed25519.KeyPair.generateDeterministic(seed.*);
        return .{
            .secret = kp.secret_key.toBytes(),
            .public = kp.public_key.toBytes(),
        };
    }
};

// ── Errors ───────────────────────────────────────────────────────────────────

pub const SignError = error{SignFailed};
pub const VerifyError = error{InvalidSignature};

// ── Sign ─────────────────────────────────────────────────────────────────────

/// Sign `message` with `secret_key`. Returns a 64-byte signature.
pub fn sign(message: []const u8, secret_key: *const SecretKey) SignError!Signature {
    const sk = Ed25519.SecretKey.fromBytes(secret_key.*) catch return SignError.SignFailed;
    const kp = Ed25519.KeyPair.fromSecretKey(sk) catch return SignError.SignFailed;
    const sig = kp.sign(message, null) catch return SignError.SignFailed;
    return sig.toBytes();
}

// ── Verify ───────────────────────────────────────────────────────────────────

/// Verify that `signature` is a valid Ed25519 signature of `message`
/// under `public_key`. Returns `error.InvalidSignature` on failure.
pub fn verify(
    message: []const u8,
    signature: *const Signature,
    public_key: *const PublicKey,
) VerifyError!void {
    const pk = Ed25519.PublicKey.fromBytes(public_key.*) catch return VerifyError.InvalidSignature;
    const sig = Ed25519.Signature.fromBytes(signature.*);
    sig.verify(message, pk) catch return VerifyError.InvalidSignature;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "ed25519: generate produces distinct key pairs" {
    const kp1 = KeyPair.generate();
    const kp2 = KeyPair.generate();
    try std.testing.expect(!std.mem.eql(u8, &kp1.public, &kp2.public));
}

test "ed25519: from_seed is deterministic" {
    const seed = [_]u8{0xAB} ** 32;
    const kp1 = try KeyPair.from_seed(&seed);
    const kp2 = try KeyPair.from_seed(&seed);
    try std.testing.expectEqual(kp1.public, kp2.public);
    try std.testing.expectEqual(kp1.secret, kp2.secret);
}

test "ed25519: sign and verify round-trip" {
    const kp = KeyPair.generate();
    const msg = "smallnano test message";
    const sig = try sign(msg, &kp.secret);
    try verify(msg, &sig, &kp.public);
}

test "ed25519: verify rejects wrong message" {
    const kp = KeyPair.generate();
    const sig = try sign("correct message", &kp.secret);
    const result = verify("wrong message", &sig, &kp.public);
    try std.testing.expectError(VerifyError.InvalidSignature, result);
}

test "ed25519: verify rejects tampered signature" {
    const kp = KeyPair.generate();
    const msg = "test";
    var sig = try sign(msg, &kp.secret);
    sig[0] ^= 0xFF;
    const result = verify(msg, &sig, &kp.public);
    try std.testing.expectError(VerifyError.InvalidSignature, result);
}

test "ed25519: verify rejects wrong public key" {
    const kp1 = KeyPair.generate();
    const kp2 = KeyPair.generate();
    const sig = try sign("test", &kp1.secret);
    const result = verify("test", &sig, &kp2.public);
    try std.testing.expectError(VerifyError.InvalidSignature, result);
}

test "ed25519: from_seed different seeds produce different keys" {
    const seed1 = [_]u8{0x01} ** 32;
    const seed2 = [_]u8{0x02} ** 32;
    const kp1 = try KeyPair.from_seed(&seed1);
    const kp2 = try KeyPair.from_seed(&seed2);
    try std.testing.expect(!std.mem.eql(u8, &kp1.public, &kp2.public));
}

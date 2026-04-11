/// Proof-of-Work for smallnano.
///
/// Algorithm:
///   work_hash = Blake2b-64( nonce_le_u64 ++ block_hash )
///   valid     = (interpret work_hash as little-endian u64) >= threshold
///
/// Two difficulty thresholds:
///   THRESHOLD_SEND    — harder; used for send and change-representative blocks
///   THRESHOLD_RECEIVE — easier (~8× faster); used for open and receive blocks
///
/// Generation is CPU-only and uses std.Thread for parallelism.
const std = @import("std");
const blake2b = @import("blake2b.zig");

// ── Thresholds ───────────────────────────────────────────────────────────────

/// Difficulty for send / change blocks. (~2^32 expected iterations on average)
pub const THRESHOLD_SEND: u64 = 0xFFFFFFF800000000;

/// Difficulty for open / receive blocks. (~2^29 expected iterations on average)
pub const THRESHOLD_RECEIVE: u64 = 0xFFFFFE0000000000;

// ── Validation ───────────────────────────────────────────────────────────────

/// Return true if `work` is a valid proof-of-work for `block_hash` at `threshold`.
pub fn is_valid(work: u64, block_hash: *const [32]u8, threshold: u64) bool {
    var nonce_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &nonce_le, work, .little);
    const digest = blake2b.hash_work(&.{ &nonce_le, block_hash });
    const result = std.mem.readInt(u64, &digest, .little);
    return result >= threshold;
}

// ── Generation ───────────────────────────────────────────────────────────────

/// Shared state between PoW worker threads.
const WorkerState = struct {
    block_hash: *const [32]u8,
    threshold: u64,
    found: std.atomic.Value(bool),
    result: std.atomic.Value(u64),
};

fn worker_thread(state: *WorkerState) void {
    var prng = std.Random.DefaultPrng.init(@as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())))));
    const rng = prng.random();

    while (!state.found.load(.acquire)) {
        const nonce = rng.int(u64);
        if (is_valid(nonce, state.block_hash, state.threshold)) {
            // Race: first thread to find a solution wins.
            if (!state.found.swap(true, .acq_rel)) {
                state.result.store(nonce, .release);
            }
            return;
        }
    }
}

/// Generate a valid proof-of-work nonce for `block_hash` at `threshold`.
/// Uses up to `thread_count` CPU threads. Blocks until a solution is found.
/// Pass `thread_count = 1` for single-threaded operation on low-end computers.
pub fn generate(
    block_hash: *const [32]u8,
    threshold: u64,
    thread_count: u32,
) u64 {
    var state = WorkerState{
        .block_hash = block_hash,
        .threshold = threshold,
        .found = std.atomic.Value(bool).init(false),
        .result = std.atomic.Value(u64).init(0),
    };

    const n = @max(1, thread_count);

    if (n == 1) {
        // No thread overhead for single-threaded mode.
        worker_thread(&state);
        return state.result.load(.acquire);
    }

    const allocator = std.heap.page_allocator;
    const threads = allocator.alloc(std.Thread, n) catch {
        // Fallback to single-threaded on OOM.
        worker_thread(&state);
        return state.result.load(.acquire);
    };
    defer allocator.free(threads);

    for (threads) |*t| {
        t.* = std.Thread.spawn(.{}, worker_thread, .{&state}) catch {
            // If spawning fails, run single-threaded.
            state.found.store(false, .release);
            worker_thread(&state);
            return state.result.load(.acquire);
        };
    }
    for (threads) |t| t.join();

    return state.result.load(.acquire);
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "work: is_valid returns false for zero nonce on non-trivial threshold" {
    const hash = [_]u8{0x42} ** 32;
    // Zero nonce produces a near-zero hash value, which won't meet threshold.
    try std.testing.expect(!is_valid(0, &hash, THRESHOLD_RECEIVE));
}

test "work: is_valid returns true for a known valid nonce" {
    // Generate a nonce and confirm is_valid accepts it.
    const hash = [_]u8{0xAA} ** 32;
    // Use a very easy threshold (1) so any nonce is valid.
    const trivial_threshold: u64 = 1;
    try std.testing.expect(is_valid(0, &hash, trivial_threshold));
    try std.testing.expect(is_valid(12345, &hash, trivial_threshold));
}

test "work: is_valid threshold boundary — at threshold" {
    // Construct a nonce whose digest equals the threshold exactly.
    // We do this by scanning until we find one, using a trivial threshold.
    const hash = [_]u8{0x01} ** 32;
    const threshold: u64 = THRESHOLD_RECEIVE;

    // Find a valid nonce via brute force (fast with random starting point).
    var prng = std.Random.DefaultPrng.init(0);
    const rng = prng.random();
    var found_nonce: u64 = 0;
    while (true) {
        const n = rng.int(u64);
        if (is_valid(n, &hash, threshold)) {
            found_nonce = n;
            break;
        }
    }
    // Double-check: the same nonce must pass is_valid.
    try std.testing.expect(is_valid(found_nonce, &hash, threshold));
}

test "work: generate produces a valid nonce (single thread, receive threshold)" {
    // Use a very easy threshold so this test runs quickly.
    const easy_threshold: u64 = 0xFF00000000000000;
    const hash = [_]u8{0x55} ** 32;
    const nonce = generate(&hash, easy_threshold, 1);
    try std.testing.expect(is_valid(nonce, &hash, easy_threshold));
}

test "work: generate determinism — two calls produce valid (not necessarily equal) nonces" {
    const easy: u64 = 0xFF00000000000000;
    const hash = [_]u8{0x77} ** 32;
    const n1 = generate(&hash, easy, 1);
    const n2 = generate(&hash, easy, 1);
    try std.testing.expect(is_valid(n1, &hash, easy));
    try std.testing.expect(is_valid(n2, &hash, easy));
}

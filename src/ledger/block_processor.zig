/// BlockProcessor — MPSC queue that drives ledger block processing.
///
/// Callers submit blocks from any thread via submit(). A single background
/// worker thread pulls blocks in FIFO order and calls ledger.process() on
/// each one. Processing errors are silently dropped (the node will receive
/// the block again from other peers if it matters).
///
/// Lifecycle:
///   var bp = BlockProcessor(MyLedger).init(allocator, &ledger);
///   try bp.start();
///   try bp.submit(some_block);
///   bp.stop();   // drains queue before returning
///   bp.deinit();
const std = @import("std");
const block_mod = @import("../types/block.zig");

pub const StateBlock = block_mod.StateBlock;

pub fn BlockProcessor(comptime LedgerType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        ledger: *LedgerType,
        queue: std.ArrayList(StateBlock),
        mutex: std.Thread.Mutex,
        cond: std.Thread.Condition,
        thread: ?std.Thread,
        running: bool,

        pub fn init(allocator: std.mem.Allocator, ledger: *LedgerType) Self {
            return .{
                .allocator = allocator,
                .ledger = ledger,
                .queue = std.ArrayList(StateBlock){},
                .mutex = std.Thread.Mutex{},
                .cond = std.Thread.Condition{},
                .thread = null,
                .running = false,
            };
        }

        /// Start the background worker thread.
        pub fn start(self: *Self) !void {
            self.running = true;
            self.thread = try std.Thread.spawn(.{}, worker, .{self});
        }

        /// Signal the worker to stop and wait for it to drain the queue and exit.
        pub fn stop(self: *Self) void {
            {
                self.mutex.lock();
                self.running = false;
                self.mutex.unlock();
            }
            self.cond.signal();
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
        }

        pub fn deinit(self: *Self) void {
            if (self.running) self.stop();
            self.queue.deinit(self.allocator);
        }

        /// Submit a block for processing. Thread-safe. May return OutOfMemory.
        pub fn submit(self: *Self, blk: StateBlock) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.queue.append(self.allocator, blk);
            self.cond.signal();
        }

        // ── Worker ────────────────────────────────────────────────────────────

        fn worker(self: *Self) void {
            while (true) {
                // Grab one block under the lock.
                const maybe_blk: ?StateBlock = blk: {
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    // Wait while queue is empty and we haven't been stopped.
                    while (self.queue.items.len == 0 and self.running) {
                        self.cond.wait(&self.mutex);
                    }

                    // If queue is drained and stopped, exit.
                    if (self.queue.items.len == 0) break :blk null;

                    const first = self.queue.items[0];
                    _ = self.queue.orderedRemove(0);
                    break :blk first;
                };

                const blk = maybe_blk orelse return;
                // Silently drop errors; the block will be re-broadcast if needed.
                _ = self.ledger.process(&blk) catch null;
            }
        }
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const NullStore = @import("../store/null_store.zig").NullStore;
const ledger_mod = @import("ledger.zig");
const ed25519 = @import("../crypto/ed25519.zig");
const work_mod = @import("../crypto/work.zig");
const store_mod = @import("../store/store.zig");

const ZERO_HASH = block_mod.ZERO_HASH;

test "block_processor: start and stop with no blocks" {
    var s = NullStore.init(testing.allocator);
    defer s.deinit();
    var ledger = ledger_mod.Ledger(NullStore).init(&s, 1000);

    var bp = BlockProcessor(@TypeOf(ledger)).init(testing.allocator, &ledger);
    defer bp.deinit();

    try bp.start();
    bp.stop();
}

test "block_processor: processes submitted block" {
    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x20} ** 32));
    const send_hash = [_]u8{0x30} ** 32;
    const amount: u128 = 1_000_000_000_000_000_000_000_000;

    var s = NullStore.init(testing.allocator);
    defer s.deinit();
    try s.put_pending(&kp.public, &send_hash, .{ .source = [_]u8{0x40} ** 32, .amount = amount });

    var ledger = ledger_mod.Ledger(NullStore).init(&s, 1000);

    var bp = BlockProcessor(@TypeOf(ledger)).init(testing.allocator, &ledger);
    defer bp.deinit();
    try bp.start();

    // Build a valid open block.
    var blk = StateBlock{
        .account = kp.public,
        .previous = ZERO_HASH,
        .representative = kp.public,
        .balance = amount,
        .link = send_hash,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    const h = blk.hash();
    blk.signature = try ed25519.sign(&h, &kp.secret);
    blk.work = work_mod.generate(&h, work_mod.THRESHOLD_RECEIVE, 1);

    try bp.submit(blk);
    bp.stop(); // drain queue before checking

    const info = s.get_account(&kp.public);
    try testing.expect(info != null);
    try testing.expectEqual(amount, info.?.balance);
}

test "block_processor: invalid block is silently dropped" {
    var s = NullStore.init(testing.allocator);
    defer s.deinit();
    var ledger = ledger_mod.Ledger(NullStore).init(&s, 1000);

    var bp = BlockProcessor(@TypeOf(ledger)).init(testing.allocator, &ledger);
    defer bp.deinit();
    try bp.start();

    // Submit a burn-address block — validator will reject it silently.
    const bad_blk = StateBlock{
        .account = [_]u8{0} ** 32, // burn
        .previous = ZERO_HASH,
        .representative = [_]u8{0} ** 32,
        .balance = 0,
        .link = [_]u8{0} ** 32,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    try bp.submit(bad_blk);
    bp.stop();

    // No account created.
    try testing.expect(s.get_account(&([_]u8{0} ** 32)) == null);
}

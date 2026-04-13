/// Bootstrap client — frontier scan plus iterative `PullReq`/`PullAck` sync.
///
/// The client is generic over the local store and ledger types. It asks a peer
/// for account frontiers, downloads any missing chain suffixes in 8-block
/// windows, and replays the downloaded blocks through `ledger.process()`.
///
/// Resume on restart is implicit: once a downloaded block has been applied to
/// the local ledger, the next bootstrap run starts from `local_height + 1`.
/// If a network error interrupts syncing, already-applied blocks remain on
/// disk and the next run continues from that persisted state.
const std = @import("std");
const block_mod = @import("../types/block.zig");
const message = @import("../network/message.zig");
const server_mod = @import("server.zig");

const StateBlock = block_mod.StateBlock;
const FrontierInfo = server_mod.FrontierInfo;

pub const SyncStats = struct {
    accounts_scanned: usize = 0,
    accounts_completed: usize = 0,
    pruned_accounts_skipped: usize = 0,
    blocks_downloaded: u64 = 0,
    blocks_applied: u64 = 0,
};

pub fn BootstrapClient(comptime StoreType: type, comptime LedgerType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        store: *StoreType,
        ledger: *LedgerType,

        pub fn init(allocator: std.mem.Allocator, store: *StoreType, ledger: *LedgerType) Self {
            return .{
                .allocator = allocator,
                .store = store,
                .ledger = ledger,
            };
        }

        /// Apply one decoded `PullAck` body through the same backlog replay
        /// rules used by full bootstrap sync. This lets the live node runtime
        /// reuse the existing bootstrap semantics for network-delivered block
        /// windows without duplicating ledger replay logic.
        pub fn apply_pull_ack(self: *Self, body: *const message.PullAckBody) !u64 {
            var backlog = std.ArrayList(StateBlock){};
            defer backlog.deinit(self.allocator);

            var i: usize = 0;
            while (i < body.count) : (i += 1) {
                try backlog.append(self.allocator, body.blocks[i]);
            }

            _ = try self.replay_backlog_best_effort(&backlog);
            return self.replay_backlog_strict(&backlog);
        }

        /// Sync from one peer-like source.
        ///
        /// Required peer methods:
        ///   get_frontiers(allocator, out: *std.ArrayList(FrontierInfo)) !void
        ///   serve_pull_req(req: message.PullReqBody) !message.PullAckBody
        pub fn sync_from_peer(self: *Self, peer: anytype) !SyncStats {
            var stats = SyncStats{};
            var frontiers = std.ArrayList(FrontierInfo){};
            defer frontiers.deinit(self.allocator);
            try peer.get_frontiers(self.allocator, &frontiers);

            var backlog = std.ArrayList(StateBlock){};
            defer backlog.deinit(self.allocator);

            for (frontiers.items) |remote| {
                stats.accounts_scanned += 1;

                const local_height = if (self.store.get_account(&remote.account)) |info| info.height else 0;
                var next_height = local_height + 1;

                if (next_height > remote.height) {
                    stats.accounts_completed += 1;
                    continue;
                }

                if (next_height <= remote.pruned_height) {
                    stats.pruned_accounts_skipped += 1;
                    continue;
                }

                while (next_height <= remote.height) {
                    const body = peer.serve_pull_req(.{
                        .account = remote.account,
                        .start_height = next_height,
                    }) catch |err| switch (err) {
                        error.StartHeightPruned => {
                            stats.pruned_accounts_skipped += 1;
                            break;
                        },
                        error.NoBlocksAvailable => break,
                        else => {
                            stats.blocks_applied += try self.replay_backlog_best_effort(&backlog);
                            return err;
                        },
                    };

                    var i: usize = 0;
                    while (i < body.count) : (i += 1) {
                        try backlog.append(self.allocator, body.blocks[i]);
                        stats.blocks_downloaded += 1;
                    }
                    next_height += body.count;
                }

                stats.blocks_applied += try self.replay_backlog_best_effort(&backlog);
            }

            stats.blocks_applied += try self.replay_backlog_strict(&backlog);

            for (frontiers.items) |remote| {
                const local_height = if (self.store.get_account(&remote.account)) |info| info.height else 0;
                if (local_height >= remote.height) stats.accounts_completed += 1;
            }

            return stats;
        }

        fn replay_backlog_best_effort(self: *Self, backlog: *std.ArrayList(StateBlock)) !u64 {
            return self.replay_backlog(backlog, false);
        }

        fn replay_backlog_strict(self: *Self, backlog: *std.ArrayList(StateBlock)) !u64 {
            return self.replay_backlog(backlog, true);
        }

        fn replay_backlog(self: *Self, backlog: *std.ArrayList(StateBlock), strict: bool) !u64 {
            var applied: u64 = 0;
            var progress = true;

            while (backlog.items.len > 0 and progress) {
                progress = false;
                var i: usize = 0;
                while (i < backlog.items.len) {
                    const blk = backlog.items[i];
                    _ = self.ledger.process(&blk) catch |err| switch (err) {
                        error.PendingNotFound,
                        error.AccountNotOpen,
                        error.FrontierMismatch,
                        => {
                            i += 1;
                            continue;
                        },
                        error.AlreadyExists => {
                            _ = backlog.orderedRemove(i);
                            progress = true;
                            continue;
                        },
                        else => return err,
                    };

                    _ = backlog.orderedRemove(i);
                    applied += 1;
                    progress = true;
                }
            }

            if (strict and backlog.items.len > 0) return error.UnresolvedDependencies;
            return applied;
        }
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const inserter = @import("../ledger/inserter.zig");
const NullStore = @import("../store/null_store.zig").NullStore;
const BootstrapServer = server_mod.BootstrapServer;

fn test_block(
    account: [32]u8,
    previous: [32]u8,
    representative: [32]u8,
    balance: u128,
    link: [32]u8,
) StateBlock {
    return .{
        .account = account,
        .previous = previous,
        .representative = representative,
        .balance = balance,
        .link = link,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
}

const FakeLedger = struct {
    store: *NullStore,

    pub fn init(store: *NullStore) FakeLedger {
        return .{ .store = store };
    }

    pub fn process(self: *FakeLedger, blk: *const StateBlock) !void {
        const hash = blk.hash();
        if (self.store.get_block(&hash) != null) return error.AlreadyExists;

        const account_info = self.store.get_account(&blk.account);
        const prior_balance: u128 = if (account_info) |info| info.balance else 0;
        const prior_height: u64 = if (account_info) |info| info.height else 0;

        const block_type: enum { open, send, receive, change } = if (blk.is_open())
            .open
        else if (blk.balance < prior_balance)
            .send
        else if (blk.balance > prior_balance)
            .receive
        else
            .change;

        switch (block_type) {
            .open => {
                if (self.store.get_pending(&blk.account, &blk.link) == null) {
                    return error.PendingNotFound;
                }
            },
            .send, .receive, .change => {
                const info = account_info orelse return error.AccountNotOpen;
                if (!std.mem.eql(u8, &blk.previous, &info.frontier)) {
                    return error.FrontierMismatch;
                }
                if (block_type == .receive and self.store.get_pending(&blk.account, &blk.link) == null) {
                    return error.PendingNotFound;
                }
            },
        }

        try inserter.insert(self.store, blk, .{
            .hash = hash,
            .prior_balance = prior_balance,
            .prior_height = prior_height,
            .now = 0,
        });
    }
};

const OrderedPeer = struct {
    server: *BootstrapServer(NullStore),
    order: []const FrontierInfo,

    pub fn get_frontiers(
        self: *OrderedPeer,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(FrontierInfo),
    ) !void {
        for (self.order) |entry| try out.append(allocator, entry);
    }

    pub fn serve_pull_req(self: *OrderedPeer, req: message.PullReqBody) !message.PullAckBody {
        return self.server.serve_pull_req(req);
    }
};

const FlakyPeer = struct {
    server: *BootstrapServer(NullStore),
    order: []const FrontierInfo,
    fail_after_calls: usize,
    calls: usize = 0,

    pub fn get_frontiers(
        self: *FlakyPeer,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(FrontierInfo),
    ) !void {
        for (self.order) |entry| try out.append(allocator, entry);
    }

    pub fn serve_pull_req(self: *FlakyPeer, req: message.PullReqBody) !message.PullAckBody {
        if (self.calls >= self.fail_after_calls) return error.ConnectionLost;
        self.calls += 1;
        return self.server.serve_pull_req(req);
    }
};

fn seed_applied_block(store: *NullStore, blk: StateBlock, height: u64) !void {
    const hash = blk.hash();
    try store.put_block(&hash, .{
        .account = blk.account,
        .block_bytes = blk.to_bytes(),
        .height = height,
    });
    try store.put_account(&blk.account, .{
        .frontier = hash,
        .balance = blk.balance,
        .representative = blk.representative,
        .height = height,
        .modified = 0,
    });
}

test "bootstrap_client: replays cross-account dependencies until they resolve" {
    var remote = NullStore.init(testing.allocator);
    defer remote.deinit();
    var local = NullStore.init(testing.allocator);
    defer local.deinit();

    const account_a = [_]u8{0x01} ** 32;
    const account_b = [_]u8{0x02} ** 32;
    const rep = [_]u8{0x03} ** 32;

    const a_open = test_block(account_a, block_mod.ZERO_HASH, rep, 100, [_]u8{0x10} ** 32);
    const a_send = test_block(account_a, a_open.hash(), rep, 40, account_b);
    const send_hash = a_send.hash();
    const b_open = test_block(account_b, block_mod.ZERO_HASH, rep, 60, send_hash);

    try seed_applied_block(&remote, a_open, 1);
    try seed_applied_block(&local, a_open, 1);

    try remote.put_block(&send_hash, .{
        .account = account_a,
        .block_bytes = a_send.to_bytes(),
        .height = 2,
    });
    try remote.put_account(&account_a, .{
        .frontier = send_hash,
        .balance = a_send.balance,
        .representative = rep,
        .height = 2,
        .modified = 0,
    });

    const b_open_hash = b_open.hash();
    try remote.put_block(&b_open_hash, .{
        .account = account_b,
        .block_bytes = b_open.to_bytes(),
        .height = 1,
    });
    try remote.put_account(&account_b, .{
        .frontier = b_open_hash,
        .balance = b_open.balance,
        .representative = rep,
        .height = 1,
        .modified = 0,
    });

    var server = BootstrapServer(NullStore).init(&remote);
    const ordered = [_]FrontierInfo{
        .{
            .account = account_b,
            .frontier = b_open_hash,
            .height = 1,
            .pruned_height = 0,
        },
        .{
            .account = account_a,
            .frontier = send_hash,
            .height = 2,
            .pruned_height = 0,
        },
    };
    var peer = OrderedPeer{
        .server = &server,
        .order = &ordered,
    };

    var ledger = FakeLedger.init(&local);
    var client = BootstrapClient(NullStore, FakeLedger).init(testing.allocator, &local, &ledger);
    const stats = try client.sync_from_peer(&peer);

    try testing.expectEqual(@as(u64, 2), stats.blocks_downloaded);
    try testing.expectEqual(@as(u64, 2), stats.blocks_applied);
    try testing.expect(local.get_account(&account_b) != null);
    try testing.expectEqual(@as(u64, 2), local.get_account(&account_a).?.height);
}

test "bootstrap_client: restart resumes from persisted local height after interruption" {
    var remote = NullStore.init(testing.allocator);
    defer remote.deinit();
    var local = NullStore.init(testing.allocator);
    defer local.deinit();

    const account = [_]u8{0x41} ** 32;
    const rep = [_]u8{0x51} ** 32;

    const open_blk = test_block(account, block_mod.ZERO_HASH, rep, 10, [_]u8{0x61} ** 32);
    try seed_applied_block(&remote, open_blk, 1);
    try seed_applied_block(&local, open_blk, 1);

    var previous = open_blk.hash();
    var current_rep = rep;
    for (2..13) |height| {
        var next_rep = current_rep;
        next_rep[0] +%= 1;
        const blk = test_block(account, previous, next_rep, 10, block_mod.ZERO_HASH);
        const hash = blk.hash();
        try remote.put_block(&hash, .{
            .account = account,
            .block_bytes = blk.to_bytes(),
            .height = @intCast(height),
        });
        previous = hash;
        current_rep = next_rep;
    }
    try remote.put_account(&account, .{
        .frontier = previous,
        .balance = 10,
        .representative = current_rep,
        .height = 12,
        .modified = 0,
    });

    var server = BootstrapServer(NullStore).init(&remote);
    const ordered = [_]FrontierInfo{
        .{
            .account = account,
            .frontier = previous,
            .height = 12,
            .pruned_height = 0,
        },
    };

    var flaky = FlakyPeer{
        .server = &server,
        .order = &ordered,
        .fail_after_calls = 1,
    };
    var ledger = FakeLedger.init(&local);
    var client = BootstrapClient(NullStore, FakeLedger).init(testing.allocator, &local, &ledger);

    try testing.expectError(error.ConnectionLost, client.sync_from_peer(&flaky));
    try testing.expectEqual(@as(u64, 9), local.get_account(&account).?.height);

    var healthy = OrderedPeer{
        .server = &server,
        .order = &ordered,
    };
    const stats = try client.sync_from_peer(&healthy);

    try testing.expectEqual(@as(u64, 3), stats.blocks_downloaded);
    try testing.expectEqual(@as(u64, 3), stats.blocks_applied);
    try testing.expectEqual(@as(u64, 12), local.get_account(&account).?.height);
}

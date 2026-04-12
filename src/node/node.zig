/// Node runtime owner — holds the long-lived subsystem graph in one place.
///
/// Milestone 11 starts by introducing a single owner for the existing modules:
/// store, ledger, block processor, consensus caches, bootstrap helpers, wallet,
/// RPC server, and network manager. This file does not yet wire the full live
/// runtime into `main.zig`; that follow-up work belongs to the remaining M11
/// sub-steps. The goal here is ownership, persistence hooks, and clean teardown.
const std = @import("std");
const config_mod = @import("../config.zig");
const block_mod = @import("../types/block.zig");
const vote_mod = @import("../types/vote.zig");
const ed25519 = @import("../crypto/ed25519.zig");
const ledger_mod = @import("../ledger/ledger.zig");
const block_processor_mod = @import("../ledger/block_processor.zig");
const genesis_mod = @import("../types/genesis.zig");
const network_mod = @import("../network/network.zig");
const message_mod = @import("../network/message.zig");
const bootstrap_server_mod = @import("../bootstrap/server.zig");
const bootstrap_client_mod = @import("../bootstrap/client.zig");
const wallet_mod = @import("../wallet/wallet.zig");
const rpc_handlers_mod = @import("../rpc/handlers.zig");
const rpc_server_mod = @import("../rpc/server.zig");
const rep_weights_mod = @import("../consensus/rep_weights.zig");
const active_elections_mod = @import("../consensus/active_elections.zig");
const confirmation_mod = @import("../consensus/confirmation.zig");
const vote_processor_mod = @import("../consensus/vote_processor.zig");
const sqlite_store_mod = @import("../store/sqlite_store.zig");

const RepWeights = rep_weights_mod.RepWeights;
const ActiveElections = active_elections_mod.ActiveElections;

const default_rpc_request_size: usize = 256 * 1024;
const meta_key_network = "network";
const meta_key_genesis_hash = "genesis_hash_hex";
const meta_key_node_seed = "node_seed_hex";
const meta_key_wallet_storage = "wallet_storage_hex";

pub const SqliteNode = Node(sqlite_store_mod.SqliteStore);

pub fn Node(comptime StoreType: type) type {
    return struct {
        const Self = @This();

        pub const LedgerType = ledger_mod.Ledger(StoreType);
        pub const BlockProcessorType = block_processor_mod.BlockProcessor(LedgerType);
        pub const BootstrapServerType = bootstrap_server_mod.BootstrapServer(StoreType);
        pub const BootstrapClientType = bootstrap_client_mod.BootstrapClient(StoreType, LedgerType);
        pub const WalletType = wallet_mod.Wallet(StoreType);
        pub const ConfirmationType = confirmation_mod.ConfirmationTracker(StoreType);
        pub const VoteProcessorType = vote_processor_mod.VoteProcessor(ConfirmationType);
        pub const RpcHandlersType = rpc_handlers_mod.RpcHandlers(LedgerType, WalletType);
        pub const RpcServerType = rpc_server_mod.RpcServer(RpcHandlersType);
        pub const PublishResult = struct {
            process: ledger_mod.ProcessResult,
            election: active_elections_mod.StartResult,
        };

        allocator: std.mem.Allocator,
        config: config_mod.NodeConfig,
        store_path: []u8,
        store: StoreType,
        ledger: LedgerType,
        block_processor: BlockProcessorType,
        rep_weights: RepWeights,
        active_elections: ActiveElections,
        confirmation: ConfirmationType,
        vote_processor: VoteProcessorType,
        bootstrap_server: BootstrapServerType,
        bootstrap_client: BootstrapClientType,
        wallet: WalletType,
        rpc_handlers: RpcHandlersType,
        rpc_server: RpcServerType,
        network: network_mod.Network,
        node_keypair: ed25519.KeyPair,
        network_ctx_token: u8,
        running: bool,

        /// Allocate and fully initialise a node object.
        ///
        /// Ownership of `config` transfers to the returned node. The node opens
        /// the store, restores or creates persistent node identity and wallet
        /// metadata, and wires the subsystem graph around those long-lived
        /// objects. Live socket threads are still started separately.
        pub fn init(
            allocator: std.mem.Allocator,
            config: config_mod.NodeConfig,
            wallet_password: []const u8,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.allocator = allocator;
            self.config = config;
            errdefer self.config.deinit(allocator);

            self.store_path = try derive_store_path(allocator, self.config.data_dir);
            errdefer allocator.free(self.store_path);

            self.store = StoreType.init(allocator);
            errdefer self.store.deinit();

            try self.store.open(self.store_path);
            errdefer self.store.close();

            try self.store.migrate();
            try ensure_network_marker(&self.store, self.config.network);
            try ensure_genesis_initialized(&self.store);

            self.node_keypair = try load_or_create_node_keypair(&self.store);

            self.ledger = LedgerType.init(&self.store, self.config.max_blocks_per_account);
            self.block_processor = BlockProcessorType.init(allocator, &self.ledger);
            errdefer self.block_processor.deinit();

            self.rep_weights = RepWeights.init(allocator);
            errdefer self.rep_weights.deinit();
            try self.rep_weights.rebuild(&self.store);

            self.active_elections = ActiveElections.init(allocator, self.config.max_pending_elections);
            errdefer self.active_elections.deinit();

            self.confirmation = ConfirmationType.init(&self.store, &self.rep_weights);
            self.vote_processor = VoteProcessorType.init(
                allocator,
                &self.rep_weights,
                &self.active_elections,
                &self.confirmation,
            );
            errdefer self.vote_processor.deinit();

            self.bootstrap_server = BootstrapServerType.init(&self.store);
            self.bootstrap_client = BootstrapClientType.init(allocator, &self.store, &self.ledger);

            self.wallet = try load_or_create_wallet(
                allocator,
                &self.store,
                wallet_password,
                self.config.work_threads,
            );
            errdefer self.wallet.deinit();

            self.rpc_handlers = RpcHandlersType.init(allocator, &self.ledger, &self.wallet);
            self.rpc_server = RpcServerType.init(
                allocator,
                &self.rpc_handlers,
                self.config.listen_address,
                self.config.rpc_port,
                default_rpc_request_size,
            );

            self.network_ctx_token = 0;
            self.network = network_mod.Network.init(
                allocator,
                .{
                    .max_peers = self.config.max_peers,
                    .network = self.config.network,
                    .node_keypair = self.node_keypair,
                    .listen_address = self.config.listen_address,
                    .listen_port = self.config.peering_port,
                    .bandwidth_limit_bytes_per_sec = mbps_to_bytes_per_sec(
                        self.config.bandwidth_limit_mbps,
                    ),
                },
                on_network_message,
                &self.network_ctx_token,
            );
            errdefer self.network.deinit();

            self.running = false;
            return self;
        }

        /// Start the owned runtime pieces in one ordered path so the node can
        /// run as a single long-lived process.
        pub fn start(self: *Self) !void {
            if (self.running) return;
            try self.block_processor.start();
            errdefer self.block_processor.stop();
            try self.network.start();
            errdefer self.network.stop();
            try self.rpc_server.start();
            errdefer self.rpc_server.stop_and_join();
            self.running = true;
        }

        pub fn stop(self: *Self) void {
            if (!self.running) return;
            self.rpc_server.stop_and_join();
            self.network.stop();
            self.block_processor.stop();
            self.running = false;
        }

        /// Queue a block for background ledger processing. This keeps the
        /// current single-threaded store discipline intact for future inbound
        /// network plumbing on low-resource machines.
        pub fn submit_block(self: *Self, blk: block_mod.StateBlock) !void {
            try self.block_processor.submit(blk);
        }

        /// Publish a locally-produced block synchronously and immediately start
        /// an election for its root using the current confirmed online weight.
        pub fn publish_block(self: *Self, blk: *const block_mod.StateBlock) !PublishResult {
            const process = try self.ledger.process(blk);
            const election = try self.start_election(blk);
            return .{
                .process = process,
                .election = election,
            };
        }

        pub fn start_election(self: *Self, blk: *const block_mod.StateBlock) !active_elections_mod.StartResult {
            return self.active_elections.start_election(blk, self.rep_weights.total_weight());
        }

        /// Route a vote through the consensus pipeline. Confirmation forwarding
        /// remains centralized in vote_processor -> confirmation tracker so
        /// callers do not need to coordinate those subsystems manually.
        pub fn process_vote(self: *Self, vote: *const vote_mod.Vote) !vote_processor_mod.ProcessSummary {
            return self.vote_processor.process(vote);
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.network.deinit();
            self.wallet.deinit();
            self.vote_processor.deinit();
            self.active_elections.deinit();
            self.rep_weights.deinit();
            self.block_processor.deinit();
            self.store.deinit();
            self.allocator.free(self.store_path);
            self.config.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn node_id(self: *const Self) [32]u8 {
            return self.node_keypair.public;
        }
    };
}

fn derive_store_path(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ data_dir, "ledger.sqlite3" });
}

fn ensure_network_marker(store: anytype, network: config_mod.Network) !void {
    var buf: [16]u8 = undefined;
    if (store.get_meta(meta_key_network, &buf)) |value| {
        if (!std.mem.eql(u8, value, @tagName(network))) return error.NetworkMismatch;
        return;
    }
    try store.put_meta(meta_key_network, @tagName(network));
}

fn ensure_genesis_initialized(store: anytype) !void {
    const genesis_hash_hex = std.fmt.bytesToHex(genesis_mod.GENESIS_HASH, .lower);

    var hash_buf: [64]u8 = undefined;
    if (store.get_meta(meta_key_genesis_hash, &hash_buf)) |value| {
        if (!std.mem.eql(u8, value, &genesis_hash_hex)) return error.GenesisHashMismatch;
    } else {
        try store.put_meta(meta_key_genesis_hash, &genesis_hash_hex);
    }

    const existing_block = store.get_block(&genesis_mod.GENESIS_HASH);
    if (existing_block != null) {
        const info = store.get_account(&genesis_mod.GENESIS_ACCOUNT) orelse return error.InvalidGenesisState;
        const ch = store.get_confirmation_height(&genesis_mod.GENESIS_ACCOUNT) orelse return error.InvalidGenesisState;
        if (info.height != 1 or info.balance != genesis_mod.GENESIS_BALANCE) {
            return error.InvalidGenesisState;
        }
        if (ch.height != 1 or !std.mem.eql(u8, &ch.frontier, &genesis_mod.GENESIS_HASH)) {
            return error.InvalidGenesisState;
        }
        return;
    }

    const genesis_block = genesis_mod.genesis_block();
    const now = std.time.timestamp();

    try store.begin_txn();
    errdefer store.rollback_txn();

    try store.put_block(&genesis_mod.GENESIS_HASH, .{
        .account = genesis_mod.GENESIS_ACCOUNT,
        .block_bytes = genesis_block.to_bytes(),
        .height = 1,
    });
    try store.put_account(&genesis_mod.GENESIS_ACCOUNT, .{
        .frontier = genesis_mod.GENESIS_HASH,
        .balance = genesis_mod.GENESIS_BALANCE,
        .representative = genesis_mod.GENESIS_ACCOUNT,
        .height = 1,
        .modified = now,
    });
    try store.put_confirmation_height(&genesis_mod.GENESIS_ACCOUNT, .{
        .height = 1,
        .frontier = genesis_mod.GENESIS_HASH,
    });

    try store.commit_txn();
}

fn load_or_create_node_keypair(store: anytype) !ed25519.KeyPair {
    const seed = try load_or_create_seed(store, meta_key_node_seed);
    return ed25519.KeyPair.from_seed(&seed);
}

fn load_or_create_seed(store: anytype, key: []const u8) ![32]u8 {
    var buf: [64]u8 = undefined;
    if (store.get_meta(key, &buf)) |value| {
        if (value.len != 64) return error.InvalidStoredSeed;

        var seed: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&seed, value) catch return error.InvalidStoredSeed;
        return seed;
    }

    var seed: [32]u8 = undefined;
    std.crypto.random.bytes(&seed);
    const hex = std.fmt.bytesToHex(seed, .lower);
    try store.put_meta(key, &hex);
    return seed;
}

fn load_or_create_wallet(
    allocator: std.mem.Allocator,
    store: anytype,
    password: []const u8,
    work_threads: u32,
) !wallet_mod.Wallet(@TypeOf(store.*)) {
    const WalletType = wallet_mod.Wallet(@TypeOf(store.*));

    var buf: [wallet_mod.EncryptedSeed.SIZE * 2]u8 = undefined;
    if (store.get_meta(meta_key_wallet_storage, &buf)) |value| {
        if (value.len != wallet_mod.EncryptedSeed.SIZE * 2) {
            return error.InvalidWalletStorage;
        }

        var bytes: [wallet_mod.EncryptedSeed.SIZE]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, value) catch return error.InvalidWalletStorage;
        const storage = try wallet_mod.EncryptedSeed.from_bytes(&bytes);
        return WalletType.from_storage(allocator, store, storage, work_threads);
    }

    var master_seed: [32]u8 = undefined;
    std.crypto.random.bytes(&master_seed);

    var wallet = try WalletType.init(allocator, store, &master_seed, password, work_threads);
    const bytes = wallet.export_storage().to_bytes();
    const hex = std.fmt.bytesToHex(bytes, .lower);
    try store.put_meta(meta_key_wallet_storage, &hex);
    return wallet;
}

fn mbps_to_bytes_per_sec(limit_mbps: u32) u64 {
    return @as(u64, limit_mbps) * 1024 * 1024 / 8;
}

fn on_network_message(
    _: *anyopaque,
    _: []const u8,
    _: message_mod.MessageType,
    _: []const u8,
) void {}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const NullStore = @import("../store/null_store.zig").NullStore;
const work_mod = @import("../crypto/work.zig");

fn make_valid_open_block(kp: ed25519.KeyPair, amount: u128, send_hash: [32]u8) !block_mod.StateBlock {
    var blk = block_mod.StateBlock{
        .account = kp.public,
        .previous = block_mod.ZERO_HASH,
        .representative = kp.public,
        .balance = amount,
        .link = send_hash,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
    const hash = blk.hash();
    blk.signature = try ed25519.sign(&hash, &kp.secret);
    blk.work = work_mod.generate(&hash, work_mod.THRESHOLD_RECEIVE, 1);
    return blk;
}

fn make_test_config(allocator: std.mem.Allocator, path: []const u8, network: config_mod.Network) !config_mod.NodeConfig {
    var config = try config_mod.NodeConfig.init(allocator, try allocator.dupe(u8, path));
    config.network = network;
    config.max_peers = 8;
    config.max_pending_elections = 16;
    config.work_threads = 1;
    allocator.free(config.listen_address);
    config.listen_address = try allocator.dupe(u8, "127.0.0.1");
    config.rpc_port = 7177;
    config.peering_port = 7176;
    return config;
}

fn assign_runtime_ports(config: *config_mod.NodeConfig) !void {
    const rpc_addr = try std.net.Address.parseIp(config.listen_address, 0);
    var rpc_server = try rpc_addr.listen(.{
        .reuse_address = true,
    });
    defer rpc_server.deinit();
    config.rpc_port = rpc_server.listen_address.getPort();

    const peer_addr = try std.net.Address.parseIp(config.listen_address, 0);
    var peer_server = try peer_addr.listen(.{
        .reuse_address = true,
    });
    defer peer_server.deinit();
    config.peering_port = peer_server.listen_address.getPort();
}

test "node: init wires subsystem ownership and persists identity metadata" {
    const config = try make_test_config(testing.allocator, "node-test/config.toml", .dev);
    const node = try Node(NullStore).init(testing.allocator, config, "node-pass");
    defer node.deinit();

    try testing.expectEqualStrings("node-test/ledger.sqlite3", node.store_path);
    try testing.expectEqual(node.node_id(), node.network.config.node_keypair.public);
    try testing.expectEqual(@as(usize, 0), node.network.peer_count());
    try testing.expectEqual(@as(usize, 0), node.active_elections.count());
    try testing.expectEqual(@as(usize, 1), node.rep_weights.confirmed_account_count());

    const genesis_info = node.store.get_account(&genesis_mod.GENESIS_ACCOUNT).?;
    try testing.expectEqual(genesis_mod.GENESIS_BALANCE, genesis_info.balance);
    try testing.expectEqual(genesis_mod.GENESIS_HASH, genesis_info.frontier);
    const genesis_ch = node.store.get_confirmation_height(&genesis_mod.GENESIS_ACCOUNT).?;
    try testing.expectEqual(@as(u64, 1), genesis_ch.height);
    try testing.expectEqual(genesis_mod.GENESIS_HASH, genesis_ch.frontier);
    try testing.expectEqual(genesis_mod.GENESIS_BALANCE, node.rep_weights.get(&genesis_mod.GENESIS_ACCOUNT));

    var meta_buf: [wallet_mod.EncryptedSeed.SIZE * 2]u8 = undefined;
    try testing.expect(node.store.get_meta(meta_key_node_seed, meta_buf[0..64]) != null);
    try testing.expect(node.store.get_meta(meta_key_wallet_storage, &meta_buf) != null);
    try testing.expect(node.store.get_meta(meta_key_genesis_hash, meta_buf[0..64]) != null);

    try node.wallet.unlock("node-pass");
    const derived = try node.wallet.derive_account(0);
    try testing.expect(std.mem.startsWith(u8, derived.address[0..], "smn_"));
}

test "node: start and stop drive the owned block processor" {
    var config = try make_test_config(testing.allocator, "node-runtime/config.toml", .dev);
    try assign_runtime_ports(&config);
    const node = try Node(NullStore).init(testing.allocator, config, "runtime-pass");
    defer node.deinit();

    try node.start();
    try testing.expect(node.running);
    try testing.expect(node.network.listener_thread != null);
    try testing.expect(node.network.dialer_thread != null);
    try testing.expect(node.rpc_server.thread != null);

    node.stop();
    try testing.expect(!node.running);
    try testing.expect(node.network.listener_thread == null);
    try testing.expect(node.network.dialer_thread == null);
    try testing.expect(node.rpc_server.thread == null);
}

test "node: repeated start and stop keep runtime ordering stable" {
    var config = try make_test_config(testing.allocator, "node-repeat/config.toml", .dev);
    try assign_runtime_ports(&config);
    const node = try Node(NullStore).init(testing.allocator, config, "repeat-pass");
    defer node.deinit();

    node.stop();
    try testing.expect(!node.running);

    try node.start();
    try testing.expect(node.running);
    try testing.expect(node.rpc_server.thread != null);

    try node.start();
    try testing.expect(node.running);

    node.stop();
    try testing.expect(!node.running);

    node.stop();
    try testing.expect(!node.running);
}

test "node: stop drains queued blocks before shutdown returns" {
    var config = try make_test_config(testing.allocator, "node-drain/config.toml", .dev);
    try assign_runtime_ports(&config);
    const node = try Node(NullStore).init(testing.allocator, config, "drain-pass");
    defer node.deinit();

    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x64} ** 32));
    const send_hash = [_]u8{0x74} ** 32;
    const amount: u128 = 9_000_000_000_000_000_000_000_000;

    try node.store.put_pending(&kp.public, &send_hash, .{
        .source = genesis_mod.GENESIS_ACCOUNT,
        .amount = amount,
    });

    const blk = try make_valid_open_block(kp, amount, send_hash);

    try node.start();
    try node.submit_block(blk);
    node.stop();

    const info = node.store.get_account(&kp.public).?;
    try testing.expectEqual(blk.hash(), info.frontier);
    try testing.expectEqual(amount, info.balance);
    try testing.expectEqual(@as(u64, 1), info.height);
    try testing.expect(!node.running);
}

test "node: publish_block processes the block and starts an election" {
    const config = try make_test_config(testing.allocator, "node-publish/config.toml", .dev);
    const node = try Node(NullStore).init(testing.allocator, config, "publish-pass");
    defer node.deinit();

    const kp = try ed25519.KeyPair.from_seed(&([_]u8{0x61} ** 32));
    const send_hash = [_]u8{0x71} ** 32;
    const amount: u128 = 5_000_000_000_000_000_000_000_000;

    try node.store.put_pending(&kp.public, &send_hash, .{
        .source = genesis_mod.GENESIS_ACCOUNT,
        .amount = amount,
    });

    const blk = try make_valid_open_block(kp, amount, send_hash);
    const result = try node.publish_block(&blk);

    try testing.expectEqual(ledger_mod.BlockType.open, result.process.block_type);
    try testing.expectEqual(active_elections_mod.StartResult.started, result.election);
    try testing.expectEqual(@as(u64, 1), result.process.new_height);
    try testing.expectEqual(@as(usize, 1), node.active_elections.count());

    const info = node.store.get_account(&kp.public).?;
    try testing.expectEqual(blk.hash(), info.frontier);
    try testing.expectEqual(amount, info.balance);
}

test "node: process_vote forwards confirmed winners into confirmation state" {
    const config = try make_test_config(testing.allocator, "node-vote/config.toml", .dev);
    const node = try Node(NullStore).init(testing.allocator, config, "vote-pass");
    defer node.deinit();

    const account_kp = try ed25519.KeyPair.from_seed(&([_]u8{0x62} ** 32));
    const rep_kp = try ed25519.KeyPair.from_seed(&([_]u8{0x63} ** 32));
    const send_hash = [_]u8{0x72} ** 32;
    const amount: u128 = 7_000_000_000_000_000_000_000_000;

    node.rep_weights.clear();
    try node.rep_weights.set_confirmed(&([_]u8{0x99} ** 32), &rep_kp.public, 100);

    try node.store.put_pending(&account_kp.public, &send_hash, .{
        .source = genesis_mod.GENESIS_ACCOUNT,
        .amount = amount,
    });

    const blk = try make_valid_open_block(account_kp, amount, send_hash);
    const publish = try node.publish_block(&blk);
    try testing.expectEqual(active_elections_mod.StartResult.started, publish.election);

    const vote = try vote_mod.Vote.create(&rep_kp.secret, &rep_kp.public, 1, &.{publish.process.hash});
    const summary = try node.process_vote(&vote);

    try testing.expectEqual(@as(u8, 1), summary.applied_hashes);
    try testing.expectEqual(@as(u8, 1), summary.confirmed_hashes);

    const ch = node.store.get_confirmation_height(&account_kp.public).?;
    try testing.expectEqual(@as(u64, 1), ch.height);
    try testing.expectEqual(publish.process.hash, ch.frontier);
    try testing.expectEqual(amount, node.rep_weights.get(&account_kp.public));
}

test "node: sqlite reopen preserves node identity and wallet storage" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/config.toml",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(config_path);

    const node_a = try SqliteNode.init(
        testing.allocator,
        try make_test_config(testing.allocator, config_path, .dev),
        "persist-pass",
    );
    const node_id = node_a.node_id();
    try node_a.wallet.unlock("persist-pass");
    const derived_a = try node_a.wallet.derive_account(3);
    node_a.deinit();

    const node_b = try SqliteNode.init(
        testing.allocator,
        try make_test_config(testing.allocator, config_path, .dev),
        "persist-pass",
    );
    defer node_b.deinit();

    try testing.expectEqual(node_id, node_b.node_id());
    const genesis_info = node_b.store.get_account(&genesis_mod.GENESIS_ACCOUNT).?;
    try testing.expectEqual(genesis_mod.GENESIS_BALANCE, genesis_info.balance);
    try node_b.wallet.unlock("persist-pass");
    const derived_b = try node_b.wallet.derive_account(3);
    try testing.expectEqual(derived_a.public_key, derived_b.public_key);
    try testing.expectEqualStrings(derived_a.address[0..], derived_b.address[0..]);
}

test "node: sqlite reopen rejects a mismatched network marker" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/config.toml",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(config_path);

    const node = try SqliteNode.init(
        testing.allocator,
        try make_test_config(testing.allocator, config_path, .dev),
        "network-pass",
    );
    node.deinit();

    const reopen = SqliteNode.init(
        testing.allocator,
        try make_test_config(testing.allocator, config_path, .main),
        "network-pass",
    );
    try testing.expectError(error.NetworkMismatch, reopen);
}

test "node: sqlite init rejects invalid wallet storage metadata" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/config.toml",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(config_path);

    const config = try make_test_config(testing.allocator, config_path, .dev);
    const store_path = try derive_store_path(testing.allocator, config.data_dir);
    defer testing.allocator.free(store_path);

    var store = sqlite_store_mod.SqliteStore.init(testing.allocator);
    defer store.deinit();
    try store.open(store_path);
    try store.migrate();
    try store.put_meta(meta_key_network, "dev");
    try store.put_meta(meta_key_wallet_storage, "not-hex-wallet");

    const reopen = SqliteNode.init(
        testing.allocator,
        config,
        "bad-wallet",
    );
    try testing.expectError(error.InvalidWalletStorage, reopen);
}

test "node: sqlite init rejects invalid stored node seed metadata" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/config.toml",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(config_path);

    const config = try make_test_config(testing.allocator, config_path, .dev);
    const store_path = try derive_store_path(testing.allocator, config.data_dir);
    defer testing.allocator.free(store_path);

    var store = sqlite_store_mod.SqliteStore.init(testing.allocator);
    defer store.deinit();
    try store.open(store_path);
    try store.migrate();
    try store.put_meta(meta_key_network, "dev");
    try store.put_meta(meta_key_node_seed, "short-seed");

    const reopen = SqliteNode.init(
        testing.allocator,
        config,
        "bad-seed",
    );
    try testing.expectError(error.InvalidStoredSeed, reopen);
}

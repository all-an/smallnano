/// Wallet — deterministic key derivation, encrypted seed storage, and block builders.
///
/// The wallet keeps one encrypted 32-byte master seed. Accounts are derived
/// deterministically from that seed and registered in a local account→index map:
///
///   child_seed = Blake2b-256("smallnano-account-v1" ++ master_seed ++ index_le)
///   keypair    = Ed25519(child_seed)
///
/// Seed encryption uses XChaCha20-Poly1305 with a key derived from:
///
///   Blake2b-256("smallnano-wallet-v1" ++ salt ++ password)
///
/// The wallet can stay locked in memory until the caller unlocks it with a
/// password. Once unlocked, block builders can derive keys on demand without
/// storing per-account private keys separately.
const std = @import("std");
const account_mod = @import("../types/account.zig");
const block_mod = @import("../types/block.zig");
const blake2b = @import("../crypto/blake2b.zig");
const ed25519 = @import("../crypto/ed25519.zig");
const work_mod = @import("../crypto/work.zig");

const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

const StateBlock = block_mod.StateBlock;
const Account = account_mod.Account;

const Key32 = [32]u8;

fn Key32Context(comptime K: type) type {
    return struct {
        pub fn hash(_: @This(), k: K) u64 {
            return std.hash.Wyhash.hash(0, &k);
        }

        pub fn eql(_: @This(), a: K, b: K) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };
}

pub const DerivedAccount = struct {
    index: u32,
    public_key: [32]u8,
    address: [64]u8,
};

pub const EncryptedSeed = struct {
    version: u8 = 1,
    salt: [32]u8,
    nonce: [XChaCha20Poly1305.nonce_length]u8,
    ciphertext: [32]u8,
    tag: [XChaCha20Poly1305.tag_length]u8,

    pub const SIZE: usize = 1 + 32 + XChaCha20Poly1305.nonce_length + 32 + XChaCha20Poly1305.tag_length;

    pub const DecodeError = error{InvalidVersion};

    pub fn to_bytes(self: EncryptedSeed) [SIZE]u8 {
        var buf: [SIZE]u8 = undefined;
        var offset: usize = 0;

        buf[offset] = self.version;
        offset += 1;
        @memcpy(buf[offset .. offset + 32], &self.salt);
        offset += 32;
        @memcpy(buf[offset .. offset + XChaCha20Poly1305.nonce_length], &self.nonce);
        offset += XChaCha20Poly1305.nonce_length;
        @memcpy(buf[offset .. offset + 32], &self.ciphertext);
        offset += 32;
        @memcpy(buf[offset .. offset + XChaCha20Poly1305.tag_length], &self.tag);

        return buf;
    }

    pub fn from_bytes(buf: *const [SIZE]u8) DecodeError!EncryptedSeed {
        if (buf[0] != 1) return DecodeError.InvalidVersion;

        var offset: usize = 1;
        var storage: EncryptedSeed = undefined;
        storage.version = buf[0];
        storage.salt = buf[offset..][0..32].*;
        offset += 32;
        storage.nonce = buf[offset..][0..XChaCha20Poly1305.nonce_length].*;
        offset += XChaCha20Poly1305.nonce_length;
        storage.ciphertext = buf[offset..][0..32].*;
        offset += 32;
        storage.tag = buf[offset..][0..XChaCha20Poly1305.tag_length].*;
        return storage;
    }
};

pub fn Wallet(comptime StoreType: type) type {
    return struct {
        const Self = @This();

        pub const WalletError = error{
            AuthenticationFailed,
            Locked,
            UnknownAccount,
            AccountNotOpen,
            PendingNotFound,
            InsufficientFunds,
            InvalidAmount,
        };

        allocator: std.mem.Allocator,
        store: *StoreType,
        work_threads: u32,
        send_threshold: u64,
        receive_threshold: u64,
        encrypted_seed: EncryptedSeed,
        unlocked_seed: ?[32]u8,
        account_indexes: std.HashMap(Key32, u32, Key32Context(Key32), 80),

        pub fn init(
            allocator: std.mem.Allocator,
            store: *StoreType,
            master_seed: *const [32]u8,
            password: []const u8,
            work_threads: u32,
        ) !Self {
            return init_with_thresholds(
                allocator,
                store,
                master_seed,
                password,
                work_threads,
                work_mod.THRESHOLD_SEND,
                work_mod.THRESHOLD_RECEIVE,
            );
        }

        pub fn init_with_thresholds(
            allocator: std.mem.Allocator,
            store: *StoreType,
            master_seed: *const [32]u8,
            password: []const u8,
            work_threads: u32,
            send_threshold: u64,
            receive_threshold: u64,
        ) !Self {
            var salt: [32]u8 = undefined;
            var nonce: [XChaCha20Poly1305.nonce_length]u8 = undefined;
            std.crypto.random.bytes(&salt);
            std.crypto.random.bytes(&nonce);

            var key = derive_encryption_key(password, &salt);
            defer std.crypto.secureZero(u8, &key);

            var ciphertext: [32]u8 = undefined;
            var tag: [XChaCha20Poly1305.tag_length]u8 = undefined;
            XChaCha20Poly1305.encrypt(ciphertext[0..], tag[0..], master_seed, "smallnano-wallet-seed", nonce, key);

            return .{
                .allocator = allocator,
                .store = store,
                .work_threads = work_threads,
                .send_threshold = send_threshold,
                .receive_threshold = receive_threshold,
                .encrypted_seed = .{
                    .version = 1,
                    .salt = salt,
                    .nonce = nonce,
                    .ciphertext = ciphertext,
                    .tag = tag,
                },
                .unlocked_seed = null,
                .account_indexes = std.HashMap(Key32, u32, Key32Context(Key32), 80).init(allocator),
            };
        }

        pub fn from_storage(
            allocator: std.mem.Allocator,
            store: *StoreType,
            encrypted_seed: EncryptedSeed,
            work_threads: u32,
        ) Self {
            return .{
                .allocator = allocator,
                .store = store,
                .work_threads = work_threads,
                .send_threshold = work_mod.THRESHOLD_SEND,
                .receive_threshold = work_mod.THRESHOLD_RECEIVE,
                .encrypted_seed = encrypted_seed,
                .unlocked_seed = null,
                .account_indexes = std.HashMap(Key32, u32, Key32Context(Key32), 80).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.lock();
            self.account_indexes.deinit();
        }

        pub fn export_storage(self: *const Self) EncryptedSeed {
            return self.encrypted_seed;
        }

        pub fn unlock(self: *Self, password: []const u8) WalletError!void {
            var key = derive_encryption_key(password, &self.encrypted_seed.salt);
            defer std.crypto.secureZero(u8, &key);

            var seed: [32]u8 = undefined;
            XChaCha20Poly1305.decrypt(
                seed[0..],
                self.encrypted_seed.ciphertext[0..],
                self.encrypted_seed.tag,
                "smallnano-wallet-seed",
                self.encrypted_seed.nonce,
                key,
            ) catch return WalletError.AuthenticationFailed;

            self.lock();
            self.unlocked_seed = seed;
        }

        pub fn lock(self: *Self) void {
            if (self.unlocked_seed) |*seed| {
                std.crypto.secureZero(u8, seed);
                self.unlocked_seed = null;
            }
        }

        /// Derive account `index`, register it in the wallet map, and return
        /// both the raw public key and its `smn_...` address.
        pub fn derive_account(self: *Self, index: u32) !DerivedAccount {
            const kp = try self.key_pair_at(index);

            const gop = try self.account_indexes.getOrPut(kp.public);
            gop.value_ptr.* = index;

            var address: [64]u8 = undefined;
            Account.from_bytes(&kp.public).to_address(&address);

            return .{
                .index = index,
                .public_key = kp.public,
                .address = address,
            };
        }

        pub fn create_send(
            self: *Self,
            from: [32]u8,
            to: [32]u8,
            amount: u128,
        ) WalletError!StateBlock {
            if (amount == 0) return WalletError.InvalidAmount;

            const kp = try self.key_pair_for_account(&from);
            const info = self.store.get_account(&from) orelse return WalletError.AccountNotOpen;
            if (amount > info.balance) return WalletError.InsufficientFunds;
            var blk = StateBlock{
                .account = from,
                .previous = info.frontier,
                .representative = info.representative,
                .balance = info.balance - amount,
                .link = to,
                .work = 0,
                .signature = [_]u8{0} ** 64,
            };

            const h = blk.hash();
            blk.signature = ed25519.sign(&h, &kp.secret) catch unreachable;
            blk.work = work_mod.generate(&h, self.send_threshold, self.work_threads);
            return blk;
        }

        /// Build either an open block or a receive block depending on whether
        /// `account` already has a frontier in the local store.
        pub fn create_receive(
            self: *Self,
            account: [32]u8,
            pending_hash: [32]u8,
        ) WalletError!StateBlock {
            const pending = self.store.get_pending(&account, &pending_hash) orelse
                return WalletError.PendingNotFound;
            const kp = try self.key_pair_for_account(&account);

            const account_info = self.store.get_account(&account);
            const previous = if (account_info) |info| info.frontier else block_mod.ZERO_HASH;
            const representative = if (account_info) |info| info.representative else account;
            const prior_balance: u128 = if (account_info) |info| info.balance else 0;

            var blk = StateBlock{
                .account = account,
                .previous = previous,
                .representative = representative,
                .balance = prior_balance + pending.amount,
                .link = pending_hash,
                .work = 0,
                .signature = [_]u8{0} ** 64,
            };

            const h = blk.hash();
            blk.signature = ed25519.sign(&h, &kp.secret) catch unreachable;
            blk.work = work_mod.generate(&h, self.receive_threshold, self.work_threads);
            return blk;
        }

        fn require_seed(self: *const Self) WalletError![32]u8 {
            return self.unlocked_seed orelse WalletError.Locked;
        }

        fn key_pair_for_account(self: *Self, account: *const [32]u8) WalletError!ed25519.KeyPair {
            const index = self.account_indexes.get(account.*) orelse return WalletError.UnknownAccount;
            return self.key_pair_at(index) catch WalletError.Locked;
        }

        fn key_pair_at(self: *const Self, index: u32) !ed25519.KeyPair {
            const master_seed = try self.require_seed();
            const child_seed = derive_account_seed(&master_seed, index);
            return ed25519.KeyPair.from_seed(&child_seed);
        }
    };
}

fn derive_encryption_key(password: []const u8, salt: *const [32]u8) [32]u8 {
    return blake2b.hash256(&.{
        "smallnano-wallet-v1",
        salt,
        password,
    });
}

fn derive_account_seed(master_seed: *const [32]u8, index: u32) [32]u8 {
    var index_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &index_le, index, .little);
    return blake2b.hash256(&.{
        "smallnano-account-v1",
        master_seed,
        &index_le,
    });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const NullStore = @import("../store/null_store.zig").NullStore;

test "wallet: deterministic account derivation from the same seed" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const master_seed = [_]u8{0x11} ** 32;
    var wallet_a = try Wallet(NullStore).init_with_thresholds(
        testing.allocator,
        &store,
        &master_seed,
        "password",
        1,
        1,
        1,
    );
    defer wallet_a.deinit();
    try wallet_a.unlock("password");

    var wallet_b = try Wallet(NullStore).init_with_thresholds(
        testing.allocator,
        &store,
        &master_seed,
        "password",
        1,
        1,
        1,
    );
    defer wallet_b.deinit();
    try wallet_b.unlock("password");

    const a0 = try wallet_a.derive_account(0);
    const a1 = try wallet_a.derive_account(1);
    const b0 = try wallet_b.derive_account(0);

    try testing.expectEqual(a0.public_key, b0.public_key);
    try testing.expect(!std.mem.eql(u8, &a0.public_key, &a1.public_key));
    try testing.expectEqualStrings(&a0.address, &b0.address);
}

test "wallet: encrypted storage round-trip and wrong password rejection" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const master_seed = [_]u8{0x22} ** 32;
    var wallet = try Wallet(NullStore).init_with_thresholds(
        testing.allocator,
        &store,
        &master_seed,
        "secret",
        1,
        1,
        1,
    );
    defer wallet.deinit();

    const storage = wallet.export_storage();
    try testing.expect(!std.mem.eql(u8, &storage.ciphertext, &master_seed));

    var imported = Wallet(NullStore).from_storage(testing.allocator, &store, storage, 1);
    defer imported.deinit();

    try testing.expectError(Wallet(NullStore).WalletError.AuthenticationFailed, imported.unlock("wrong"));
    try imported.unlock("secret");

    const derived = try imported.derive_account(7);
    const derived_again = try imported.derive_account(7);
    try testing.expectEqual(derived.public_key, derived_again.public_key);
}

test "wallet: encrypted seed serialises and deserialises" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const master_seed = [_]u8{0x33} ** 32;
    var wallet = try Wallet(NullStore).init_with_thresholds(
        testing.allocator,
        &store,
        &master_seed,
        "serialise",
        1,
        1,
        1,
    );
    defer wallet.deinit();

    const bytes = wallet.export_storage().to_bytes();
    const decoded = try EncryptedSeed.from_bytes(&bytes);
    try testing.expectEqual(wallet.export_storage().salt, decoded.salt);
    try testing.expectEqual(wallet.export_storage().ciphertext, decoded.ciphertext);
}

test "wallet: create_send builds signed worked send block" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const master_seed = [_]u8{0x44} ** 32;
    var wallet = try Wallet(NullStore).init_with_thresholds(
        testing.allocator,
        &store,
        &master_seed,
        "send-pass",
        1,
        1,
        1,
    );
    defer wallet.deinit();
    try wallet.unlock("send-pass");

    const derived = try wallet.derive_account(0);
    const recipient = [_]u8{0x88} ** 32;
    const frontier = [_]u8{0x55} ** 32;
    const representative = [_]u8{0x66} ** 32;

    try store.put_account(&derived.public_key, .{
        .frontier = frontier,
        .balance = 100,
        .representative = representative,
        .height = 5,
        .modified = 0,
    });

    const blk = try wallet.create_send(derived.public_key, recipient, 40);
    const h = blk.hash();

    try testing.expectEqual(derived.public_key, blk.account);
    try testing.expectEqual(frontier, blk.previous);
    try testing.expectEqual(representative, blk.representative);
    try testing.expectEqual(recipient, blk.link);
    try testing.expectEqual(@as(u128, 60), blk.balance);
    try ed25519.verify(&h, &blk.signature, &derived.public_key);
    try testing.expect(work_mod.is_valid(blk.work, &h, 1));
}

test "wallet: create_send rejects insufficient funds and unknown account" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const master_seed = [_]u8{0x45} ** 32;
    var wallet = try Wallet(NullStore).init_with_thresholds(
        testing.allocator,
        &store,
        &master_seed,
        "limits",
        1,
        1,
        1,
    );
    defer wallet.deinit();
    try wallet.unlock("limits");

    const derived = try wallet.derive_account(0);
    try store.put_account(&derived.public_key, .{
        .frontier = [_]u8{0x77} ** 32,
        .balance = 10,
        .representative = derived.public_key,
        .height = 1,
        .modified = 0,
    });

    try testing.expectError(
        Wallet(NullStore).WalletError.InsufficientFunds,
        wallet.create_send(derived.public_key, [_]u8{0x99} ** 32, 11),
    );
    try testing.expectError(
        Wallet(NullStore).WalletError.UnknownAccount,
        wallet.create_send([_]u8{0xAB} ** 32, [_]u8{0xCD} ** 32, 1),
    );
}

test "wallet: create_receive builds an open block for unopened account" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const master_seed = [_]u8{0x55} ** 32;
    var wallet = try Wallet(NullStore).init_with_thresholds(
        testing.allocator,
        &store,
        &master_seed,
        "recv-pass",
        1,
        1,
        1,
    );
    defer wallet.deinit();
    try wallet.unlock("recv-pass");

    const derived = try wallet.derive_account(0);
    const pending_hash = [_]u8{0x12} ** 32;
    try store.put_pending(&derived.public_key, &pending_hash, .{
        .source = [_]u8{0x34} ** 32,
        .amount = 75,
    });

    const blk = try wallet.create_receive(derived.public_key, pending_hash);
    const h = blk.hash();

    try testing.expectEqual(block_mod.ZERO_HASH, blk.previous);
    try testing.expectEqual(derived.public_key, blk.representative);
    try testing.expectEqual(@as(u128, 75), blk.balance);
    try testing.expectEqual(pending_hash, blk.link);
    try ed25519.verify(&h, &blk.signature, &derived.public_key);
    try testing.expect(work_mod.is_valid(blk.work, &h, 1));
}

test "wallet: create_receive preserves representative for existing account" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const master_seed = [_]u8{0x66} ** 32;
    var wallet = try Wallet(NullStore).init_with_thresholds(
        testing.allocator,
        &store,
        &master_seed,
        "recv-existing",
        1,
        1,
        1,
    );
    defer wallet.deinit();
    try wallet.unlock("recv-existing");

    const derived = try wallet.derive_account(2);
    const representative = [_]u8{0xE1} ** 32;
    const frontier = [_]u8{0xE2} ** 32;
    const pending_hash = [_]u8{0xE3} ** 32;

    try store.put_account(&derived.public_key, .{
        .frontier = frontier,
        .balance = 200,
        .representative = representative,
        .height = 3,
        .modified = 0,
    });
    try store.put_pending(&derived.public_key, &pending_hash, .{
        .source = [_]u8{0xE4} ** 32,
        .amount = 25,
    });

    const blk = try wallet.create_receive(derived.public_key, pending_hash);
    try testing.expectEqual(frontier, blk.previous);
    try testing.expectEqual(representative, blk.representative);
    try testing.expectEqual(@as(u128, 225), blk.balance);
}

test "wallet: lock prevents further key usage until unlocked again" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const master_seed = [_]u8{0x77} ** 32;
    var wallet = try Wallet(NullStore).init_with_thresholds(
        testing.allocator,
        &store,
        &master_seed,
        "lock-pass",
        1,
        1,
        1,
    );
    defer wallet.deinit();

    try wallet.unlock("lock-pass");
    _ = try wallet.derive_account(0);
    wallet.lock();

    try testing.expectError(Wallet(NullStore).WalletError.Locked, wallet.derive_account(1));
    try wallet.unlock("lock-pass");
    _ = try wallet.derive_account(1);
}

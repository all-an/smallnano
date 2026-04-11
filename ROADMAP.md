# smallnano Roadmap

smallnano is an **independent cryptocurrency** written in **Zig**, inspired by the
ideas of Nano (block-lattice, weighted voting, zero fees) but with a completely new
protocol, network, address format, and coin.

**The problem we solve:** Full nodes for block-lattice cryptocurrencies are too heavy.
Running a Nano node costs ~$40/month on a cloud VPS, requires 8 GB RAM, and hundreds
of GB of disk. That centralises the network to whoever can afford it. smallnano is
designed so that anyone in the world — with a Raspberry Pi, an old laptop, or a $5
VPS — can run a full node and contribute to network security.

---

## Design Goals

| Goal | Target |
|------|--------|
| Idle RAM | ≤ 64 MB |
| Peak RAM (under load) | ≤ 256 MB |
| Disk (pruned ledger, 1000 blocks/account) | ≤ 2 GB |
| Minimum CPU | Single-core ARMv7 @ 1 GHz |
| Binary size | ≤ 10 MB (ReleaseSafe) |
| Dependencies | Zig stdlib + SQLite (vendored) |
| Wire protocol | Own protocol (NOT Nano-compatible) |
| Address format | `smn_...` (own base32 + checksum) |
| Currency | smn, 1 smn = 10^24 raw |
| Genesis supply | 10,000,000 smn (fixed, no inflation) |

---

## What smallnano inherits from Nano's ideas

- **Block-lattice:** Every account has its own chain of blocks. No global chain to sync.
- **Zero fees:** Transfers cost nothing. Spam resistance is achieved via PoW.
- **Instant finality:** Weighted voting reaches irreversible confirmation in seconds.
- **No mining:** Representatives vote with their delegated balance, not hash power.

## What smallnano does differently

| Area | Nano / rsnano-node | smallnano |
|------|-------------------|-----------|
| Language | Rust | Zig |
| Storage | LMDB | SQLite (vendored) |
| Wire protocol | Nano protocol (v25+) | Own lightweight protocol |
| Address format | `nano_...` | `smn_...` |
| Ledger pruning | Optional, complex | First-class, configurable |
| GPU PoW | Yes (OpenCL) | No — CPU only |
| Binary | Many crates, ~50 MB | Single static binary, ≤ 10 MB |
| Minimum VPS | ~$40/month (8 GB RAM) | $5/month (512 MB RAM) |
| Coin | XNO | smn |

---

## Milestones

### ✅ Milestone 1 — Core Types & Cryptography
**Completed.** 80/80 tests pass. Runtime MaxRSS: 1 MB. Zero memory leaks.

- [x] `src/types/amount.zig` — `Amount` (u128 raw), arithmetic (checked), display (24-decimal smn)
- [x] `src/types/block.zig` — `StateBlock` struct: account, previous, representative, balance, link, work, signature. Serialise/deserialise (little-endian binary).
- [x] `src/types/account.zig` — `Account` (32-byte Ed25519 pubkey), own `smn_...` base32 encoding + checksum
- [x] `src/types/vote.zig` — `Vote`, final-vote bit, timestamp, block hash list, signature
- [x] `src/types/pending.zig` — `PendingKey` (recipient + send_hash), `PendingInfo` (source, amount)
- [x] `src/types/genesis.zig` — hard-coded genesis `StateBlock` and genesis account
- [x] `src/crypto/blake2b.zig` — Blake2b-256, Blake2b-512, Blake2b-64 wrappers around `std.crypto`
- [x] `src/crypto/ed25519.zig` — sign / verify thin wrappers around `std.crypto.sign.Ed25519`
- [x] `src/crypto/work.zig` — CPU PoW generation + validation (send threshold > receive threshold)
- [x] Unit tests for all of the above, using `std.testing.allocator`

---

### ✅ Milestone 2 — Storage Layer (SQLite)
**Completed.** All tests pass. WAL mode, migrations, full CRUD for all tables.

- [x] `src/store/store.zig` — comptime-duck-typed `Store` interface
- [x] `src/store/null_store.zig` — in-memory null store for tests (zero disk I/O)
- [x] `src/store/sqlite_store.zig` — SQLite-backed implementation
  - `accounts` — `(account BLOB PK, frontier BLOB, balance BLOB, representative BLOB, height INTEGER, modified INTEGER)`
  - `blocks` — `(hash BLOB PK, account BLOB, block BLOB, height INTEGER)`
  - `pending` — `(hash BLOB, account BLOB, amount BLOB, source BLOB)` — composite PK
  - `confirmation_height` — `(account BLOB PK, height INTEGER, frontier BLOB)`
  - `peers` — `(address TEXT PK, last_seen INTEGER)`
  - `pruned` — `(account BLOB PK, pruned_height INTEGER)` — watermark for pruned blocks
  - `_meta` — `(key TEXT PK, value TEXT)` — schema version, genesis hash, network id
- [x] WAL mode, `PRAGMA synchronous = NORMAL`
- [x] Sequential migration system — version-stamped SQL scripts
- [x] Unit tests: store/retrieve for all table types

---

### Milestone 3 — Ledger & Block Validation
**Goal:** Correct, pure-logic block validator and ledger coordinator.

- [ ] `src/ledger/validator.zig` — `BlockValidator` (pure logic, zero I/O)
  - Ed25519 signature over block hash
  - PoW meets threshold (send/change ≠ receive/open thresholds)
  - Previous block exists (or zero-hash for account open)
  - Block not already in ledger (dedup)
  - Balance ≥ 0 (no negative spend)
  - No fork on previous block
  - Pending entry exists and is unreceived (for receive blocks)
  - Not the burn account
  - Returns typed `BlockError` union — no strings, no I/O
- [ ] `src/ledger/inserter.zig` — applies a validated block to the store in one SQLite transaction
- [ ] `src/ledger/pruner.zig` — enforces `max_blocks_per_account`, never prunes below confirmation height
- [ ] `src/ledger/block_processor.zig` — MPSC queue; worker thread drives `Ledger.process()`
- [ ] `src/ledger/ledger.zig` — `Ledger` coordinates store + validator + inserter + pruner
  - `process(block) !ProcessResult`
  - `get_account_info(account) ?AccountInfo`
  - `get_block(hash) ?StateBlock`
  - `get_pending(account) []PendingInfo`
  - `confirmation_height(account) u64`
- [ ] Unit tests for every validation rule, every error path, pruning correctness

**Exit criteria:** All validation rules correctly accept and reject blocks.
Pruner removes old blocks without corrupting the confirmation watermark.

---

### Milestone 4 — Own Wire Protocol & Networking
**Goal:** Connect to smallnano peers using the project's own message format.

- [ ] `src/network/message.zig` — own message format:
  - Header: magic `0x534E`, network byte, version u8, message type u8, body length u32
  - Message types: `Handshake`, `Keepalive`, `Publish`, `VoteBy`, `PullReq`, `PullAck`, `Telemetry`
  - All integers little-endian
  - Encode/decode for every message type
- [ ] `src/network/handshake.zig` — Node-ID cookie/challenge handshake (Ed25519)
- [ ] `src/network/channel.zig` — non-blocking TCP read/write with frame buffering
- [ ] `src/network/bandwidth.zig` — token-bucket rate limiter (configurable mbps)
- [ ] `src/network/peer.zig` — peer state, last-seen, ban list
- [ ] `src/network/network.zig` — accept loop, outbound dialer, peer set (bounded by `max_peers`)
- [ ] Peer exclusion for malformed messages / protocol violations
- [ ] Unit tests: encode/decode round-trips for every message type, bandwidth limiter

**Exit criteria:** Two dev-network nodes can connect, complete handshake, exchange
keepalives and Publish messages.

---

### Milestone 5 — Consensus (Weighted Voting)
**Goal:** Participate in weighted representative voting for block confirmation.

- [ ] `src/consensus/rep_weights.zig` — in-memory representative weight cache, built from confirmed ledger
- [ ] `src/consensus/election.zig` — `Election` state machine (pure logic)
  - Accumulates votes per candidate block
  - Quorum: `tallied_weight * 3 >= online_weight * 2` (integer, no floats)
  - Detects forks (conflicting blocks for same root)
  - Returns `.ongoing`, `.confirmed { winner }`, or `.fork`
- [ ] `src/consensus/vote_processor.zig` — validates incoming votes, routes to elections
  - Ed25519 signature over `Blake2b(hash_list || timestamp)`
  - Deduplication by `(rep, timestamp)`
  - Weight lookup from cache
- [ ] `src/consensus/active_elections.zig` — bounded container (`max_pending_elections`)
  - Evicts lowest-priority when full
- [ ] `src/consensus/confirmation.zig` — writes `confirmation_height` when quorum reached
- [ ] Unit tests: quorum detection, fork detection, vote deduplication, eviction policy

**Exit criteria:** On a two-node devnet, a published block reaches confirmed state
and cementation height advances monotonically.

---

### Milestone 6 — Bootstrap
**Goal:** Sync a pruned ledger from peers on first start.

- [ ] `src/bootstrap/server.zig` — serves blocks in response to `PullReq`
  - Respects local pruning watermark (won't serve pruned blocks)
- [ ] `src/bootstrap/client.zig` — requests missing blocks via `PullReq` / `PullAck`
  - Frontier scan: discovers which accounts need syncing
  - Only requests down to `max_blocks_per_account` from tip (no deeper)
  - Progress persisted in SQLite; resumes after restart
  - Respects `bandwidth_limit_mbps`
- [ ] Unit tests: mock peer, client correctly inserts received blocks

**Exit criteria:** A fresh node can sync a dev-network ledger from genesis.
Pruned accounts handled without errors.

---

### Milestone 7 — Wallet & Key Management
**Goal:** Generate accounts, sign blocks, send and receive smn.

- [ ] `src/wallet/wallet.zig`
  - Deterministic key derivation: `seed → index → (secret, public)` via Blake2b
  - Encrypted key storage in SQLite (AES-256-GCM, Argon2id key derivation)
  - `create_send(from, to, amount) !StateBlock`
  - `create_receive(account, pending_hash) !StateBlock`
  - `change_representative(account, new_rep) !StateBlock`
  - Work generation integrated (CPU, `work_threads` from config)
- [ ] Unit tests: key derivation vectors, block signing, work validation

**Exit criteria:** Can generate a keypair, receive smn (devnet), and send smn (devnet)
using only the CLI.

---

### Milestone 8 — JSON-RPC API
**Goal:** Minimal HTTP JSON-RPC surface for wallets and integrations.

- [ ] `src/rpc/server.zig` — single-threaded HTTP/1.1 server (no external lib)
- [ ] `src/rpc/handlers.zig` — implemented commands:
  - `account_balance` — returns balance and pending amount
  - `account_info` — frontier, height, representative, confirmation height
  - `account_history` — returns blocks, honours `max_blocks_per_account`
  - `accounts_pending` — list receivable amounts
  - `block_info` — single block lookup by hash
  - `process` — submit a pre-built signed block
  - `send` — wallet convenience (build + sign + submit)
  - `receive` — claim a pending amount
  - `wallet_create`, `wallet_list`, `wallet_add_key`
  - `representatives` — list known representatives and their weights
  - `telemetry` — node stats: peers, block count, pruning depth, version
  - `version` — node version and network name
  - `peers` — connected peer list
- [ ] Unit tests for each handler using `null_store`

**Exit criteria:** An HTTP client can query balances and submit transactions.

---

### Milestone 9 — Configuration & CLI
**Goal:** A friendly, well-documented operator experience.

- [ ] `src/config.zig` — `NodeConfig` parsed from TOML + CLI flags
- [ ] Config file auto-generated with defaults and inline comments on first run
- [ ] All configurable parameters (see CLAUDE.md table)
- [ ] `--help` output with descriptions for every flag
- [ ] Graceful shutdown on SIGINT / SIGTERM
- [ ] Unit tests: config parsing, invalid values, missing fields

**Exit criteria:** A non-technical user edits one TOML file to configure their node.
All limits enforce the memory and disk targets.

---

### Milestone 10 — Hardening, CI & Release
**Goal:** Production-quality binary with automated quality gates.

- [ ] GitHub Actions CI:
  - `zig build test` on every PR (Linux x86_64, Linux aarch64, macOS arm64)
  - `zig fmt --check src/` enforced
  - Memory leak detection via `std.testing.allocator` fails the build
- [ ] Fuzz targets for block deserialisation and message parsing
- [ ] Integration test: 3-node devnet, send a transaction, verify confirmation on all nodes
- [ ] Benchmark: blocks/second insertion rate, peak RSS under load — must meet targets
- [ ] Release binaries:
  - `x86_64-linux-musl` (static, runs on any Linux)
  - `aarch64-linux-musl` (Raspberry Pi, ARM servers)
  - `x86_64-macos`
  - `aarch64-macos` (Apple Silicon)
- [ ] Docker image (scratch-based, < 15 MB compressed)
- [ ] Systemd unit file and one-command install script
- [ ] Project website with single-page explainer and download links

**Exit criteria:** `curl -fsSL install.sh | sh` installs smallnano on a fresh
Ubuntu 22.04 VM. Node runs at ≤ 64 MB RAM idle after sync. Any Raspberry Pi Zero 2
can run a full node continuously.

---

## Resource Budget (per milestone)

| Milestone | Expected peak RSS | Expected disk |
|-----------|------------------|---------------|
| M1–M2 (types + store) | < 8 MB | < 1 MB (tests) |
| M3 (ledger) | < 12 MB | < 1 MB |
| M4 (networking) | < 20 MB | < 1 MB |
| M5 (consensus) | < 40 MB | < 1 MB |
| M6 (bootstrap, 1k blk/acct) | < 128 MB (syncing) | ~500 MB |
| M7–M9 (wallet + RPC + config) | < 64 MB idle | ~500 MB |
| M10 (production) | ≤ 64 MB idle / ≤ 256 MB peak | ≤ 2 GB |

---

## What We Deliberately Omit

| Omitted | Reason |
|---------|--------|
| Nano protocol compatibility | We are our own network with a better protocol |
| GPU / OpenCL PoW | Requires heavy drivers; CPU PoW is sufficient |
| WebSocket server | RPC polling is enough for light clients |
| Full archival mode | Defeats the decentralisation goal; use pruning |
| Legacy block types | smallnano uses state blocks only from genesis |
| Smart contracts | Out of scope; pure payment network |
| Mining | No mining — weighted voting, zero energy waste |

---

## Reference

- [rsnano-node](./rsnano-node/) — Nano-compatible node in Rust, studied for protocol ideas only
- [Nano protocol overview](https://docs.nano.org/protocol-design/overview/) — design inspiration
- [Zig language reference](https://ziglang.org/documentation/master/)
- [SQLite WAL mode](https://www.sqlite.org/wal.html) — storage layer reference

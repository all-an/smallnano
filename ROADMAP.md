# smallnano Roadmap

smallnano is an **independent cryptocurrency** written in **Zig**, inspired by the
ideas of Nano (block-lattice, weighted voting, zero fees) but with a completely new
protocol, network, address format, and coin.

**The problem we solve:** Full nodes for block-lattice cryptocurrencies are too heavy.
Running a Nano node costs ~$40/month on a cloud VPS, requires 8 GB RAM, and hundreds
of GB of disk. That centralises the network to whoever can afford it. smallnano is
designed so that anyone in the world — with a low-end computer, an old laptop, or a $5
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

## Supply Distribution

Total fixed supply: **10,000,000 smn** — minted in the genesis block, no inflation ever.

| Allocation | Amount | Purpose |
|------------|--------|---------|
| Development fund | 50,000 smn | Protocol development, infrastructure, tooling |
| Airdrops & faucet game | 9,950,000 smn | Community distribution — earned, not bought |

**No ICO. No pre-sale. No investors.**
The vast majority of supply reaches users through airdrops and a faucet game, keeping
distribution fair and decentralised from day one.

---

## Milestones

**Reality check:** Milestones 1-3 are fully implemented and locally testable today.
Milestones 4-9 have substantial implementation in the repository, but several of
their original exit criteria assumed a fully wired node runtime and a real
multi-node devnet. That end-to-end proof is still pending and is now captured
explicitly in Milestones 11-13 below.

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

### ✅ Milestone 3 — Ledger & Block Validation
**Completed.** All tests pass. Pure-logic validator, atomic inserter, pruner, ledger coordinator, and MPSC block processor.

Sub-steps:
1. [x] Write `src/ledger/validator.zig` — pure block validation, typed `BlockError`, zero I/O
2. [x] Write `src/ledger/inserter.zig` — apply validated block to store atomically
3. [x] Write `src/ledger/pruner.zig` — enforce `max_blocks_per_account`, never prune below confirmation height
4. [x] Write `src/ledger/ledger.zig` — coordinate validate + insert + prune
5. [x] Write `src/ledger/block_processor.zig` — MPSC queue + worker thread
6. [x] Update `src/main.zig` imports
7. [x] Run `zig build test` — all green
8. [x] `zig fmt src/` + final test run
9. [x] Mark M3 ✅ in ROADMAP.md, commit, push

**Exit criteria:** All validation rules correctly accept and reject blocks.
Pruner removes old blocks without corrupting the confirmation watermark.

---

### Milestone 4 — Own Wire Protocol & Networking
**Module-complete.** All tests pass for the codec, handshake, framing, bandwidth limiter, peer state machine, and threaded listener/dialer scaffolding. End-to-end relay on a real devnet is still pending the runtime work in Milestones 11-13.

Sub-steps:
1. [x] Write `src/network/message.zig` — encode/decode all message types (magic `0x534E`, LE integers)
2. [x] Write `src/network/handshake.zig` — Node-ID cookie/challenge handshake (Ed25519)
3. [x] Write `src/network/channel.zig` — length-prefixed frame helpers (pure buffer, no sockets in tests)
4. [x] Write `src/network/bandwidth.zig` — token-bucket rate limiter (configurable mbps)
5. [x] Write `src/network/peer.zig` — peer state, last-seen, ban list
6. [x] Write `src/network/network.zig` — accept loop, outbound dialer, bounded peer set
7. [x] Update `src/main.zig` imports
8. [x] Run `zig build test` — all green
9. [x] Mark M4 ✅ in ROADMAP.md

**Note:** `zig build test` is slow due to CPU PoW generation in `src/ledger/validator.zig` tests (THRESHOLD_RECEIVE ≈ 2^29 iterations). Network tests themselves are instant — channel and handshake tests use pure in-memory buffers with no sockets or threads.

**Current status:** Message framing, handshake, peer tracking, and threaded
accept/dial loops exist. Live outbound keepalive/publish relay is still pending.

---

### Milestone 5 — Consensus (Weighted Voting)
**Module-complete.** All tests pass for representative weights, elections, vote processing, and confirmation tracking. Real network confirmation flow is still pending the runtime and relay milestones.

Sub-steps:
1. [x] Write `src/consensus/rep_weights.zig` — in-memory weight cache built from confirmed ledger
2. [x] Write `src/consensus/election.zig` — election state machine (pure logic, quorum integer math)
3. [x] Write `src/consensus/vote_processor.zig` — validate + deduplicate + route votes
4. [x] Write `src/consensus/active_elections.zig` — bounded elections container with eviction
5. [x] Write `src/consensus/confirmation.zig` — write `confirmation_height` on quorum
6. [x] Update `src/main.zig` imports
7. [x] Run `zig build test` — fix until green
8. [x] `zig fmt src/` + final test run
9. [x] Mark M5 ✅ in ROADMAP.md, commit, push

**Current status:** Consensus components are implemented and unit-tested. A real
two-node confirmation path is still pending M11-M13 integration.

---

### Milestone 6 — Bootstrap
**Module-complete.** All tests pass for frontier enumeration, `PullReq`/`PullAck`, pruning-watermark enforcement, and replay/resume logic. Live ledger sync between running nodes is still pending the runtime and peer-relay milestones.

Sub-steps:
1. [x] Write `src/bootstrap/server.zig` — serve blocks in response to `PullReq`, respect pruning watermark
2. [x] Write `src/bootstrap/client.zig` — frontier scan, `PullReq`/`PullAck`, resume on restart
3. [x] Update `src/main.zig` imports
4. [x] Run `zig build test` — fix until green
5. [x] `zig fmt src/` + final test run
6. [x] Mark M6 ✅ in ROADMAP.md, commit, push

**Current status:** Bootstrap client/server logic exists and is unit-tested.
Fresh-node sync on a real devnet is still pending M11-M13 integration.

---

### Milestone 7 — Wallet & Key Management
**Module-complete.** All tests pass for deterministic derivation, encrypted seed storage, lock/unlock, and block builders. CLI-driven live wallet usage still depends on the runtime milestones.

Sub-steps:
1. [x] Write `src/wallet/wallet.zig` — deterministic key derivation, encrypted storage, block builders
2. [x] Update `src/main.zig` imports
3. [x] Run `zig build test` — fix until green
4. [x] `zig fmt src/` + final test run
5. [x] Mark M7 ✅ in ROADMAP.md, commit, push

**Current status:** Wallet primitives and block builders are implemented and
tested. Real devnet send/receive through the node CLI is still pending M11-M13.

---

### Milestone 8 — JSON-RPC API
**Module-complete.** All tests pass for the HTTP transport and JSON-RPC handlers. A real operator-facing RPC service still depends on wiring the runtime together.

Sub-steps:
1. [x] Write `src/rpc/server.zig` — single-threaded HTTP/1.1 server, no external lib
2. [x] Write `src/rpc/handlers.zig` — all RPC commands (`account_info`, `process`, `send`, `receive`, etc.)
3. [x] Update `src/main.zig` imports
4. [x] Run `zig build test` — fix until green
5. [x] `zig fmt src/` + final test run
6. [x] Mark M8 ✅ in ROADMAP.md, commit, push

**Current status:** RPC parsing and handlers exist and are unit-tested. A live
RPC server backed by a running node is still pending M11-M13.

---

### Milestone 9 — Configuration & CLI
**Config-complete, runtime-pending.** All tests pass for the config loader, CLI parsing, help output, and shutdown hooks. The entrypoint still stops before starting a real node instance.

Sub-steps:
1. [x] Write `src/config.zig` — `NodeConfig` parsed from TOML + CLI flags, all parameters
2. [x] Auto-generate config file with defaults and inline comments on first run
3. [x] `--help` output for every flag
4. [x] Graceful shutdown on SIGINT / SIGTERM
5. [x] Run `zig build test` — fix until green
6. [x] `zig fmt src/` + final test run
7. [x] Mark M9 ✅ in ROADMAP.md, commit, push

**Current status:** The config file and CLI surface are implemented and tested.
Full operator-facing runtime behavior still depends on M11-M13.

---

### Milestone 10 — Hardening, CI & Release
**Goal:** Production-quality binary with automated quality gates.

Sub-steps:
1. [x] GitHub Actions CI: `zig build test` on Linux x86_64, aarch64, macOS arm64 + `zig fmt --check`
2. [x] Fuzz targets for block deserialisation and message parsing
3. [x] Release binaries: `x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-macos`, `aarch64-macos`
4. [x] Docker image (scratch-based, < 15 MB compressed)
5. [x] Systemd unit file and one-command install script

**Current status:** CI, release packaging, fuzz harnesses, benchmark scaffolding,
Docker packaging, installer assets, and `test-net.md` exist.

**Exit criteria:** `curl -fsSL install.sh | sh` installs smallnano on a fresh
Ubuntu 22.04 VM. Node runs at ≤ 64 MB RAM idle after sync. Any low-end computer
can run a full node continuously.

---

### Milestone 11 — Node Runtime Wiring
**Completed.** The node runtime now owns store open/migrate, genesis bootstrap,
block processing, network bring-up, RPC bring-up, and coordinated shutdown.

**Goal:** Turn the current module set into a real long-running node process.

Sub-steps:
1. [x] Write `src/node/node.zig` — own the store, ledger, block processor, network, bootstrap, wallet, and RPC lifecycles
2. [x] Replace the placeholder wait loop in `src/main.zig` with real startup, shutdown, and error propagation
3. [x] Wire genesis initialization, database open/migrate, and background worker startup in one runtime path
4. [x] Expose a small internal API for publishing blocks, starting elections, and forwarding confirmations between subsystems
5. [x] Add unit tests for clean startup/shutdown ordering and subsystem failure handling
6. [x] Run `zig build test` — fix until green
7. [x] `zig fmt src/` + final test run

**Exit criteria:** `smallnano node run` starts a real node instance, opens its
store, brings up networking/RPC workers, and shuts down cleanly without leaking
threads or state.

---

### Milestone 12 — Peer Relay & Bootstrap Configuration
**Goal:** Make multiple nodes discover each other, exchange live traffic, and sync without manual code changes.

Sub-steps:
1. [x] Extend `src/network/network.zig` with outbound publish, vote, keepalive, and bootstrap request relay paths
2. [x] Track active peer channels so the node can broadcast or target messages after handshake completion
3. [x] Extend `src/config.zig` with peer-seed, bootstrap-peer, listen-address, external-address, and data-dir settings
4. [x] Bring up the RPC worker as part of the real long-running node runtime and coordinate network + RPC + owned subsystem start/stop in one live path
5. [x] Persist peer discovery state safely and bound retry/backoff behavior for low-resource machines
6. [x] Add tests covering outbound relay, peer selection, bootstrap resume, config parsing/validation, and coordinated runtime start/stop
7. [x] Run `zig build test` — fix until green
8. [x] `zig fmt src/` + final test run

**Current status:** Peer discovery persistence, bounded reconnect backoff, and
the node-owned inbound `publish` / `vote` / `pull_req` / `pull_ack` routing are
implemented and unit-tested. The remaining work is proving the same behavior
across a real three-node devnet, which belongs to M13.

**Exit criteria:** Three separately configured nodes can discover peers, relay
blocks and votes outward, and bootstrap ledger state from each other on a
devnet. The real runtime brings up network and RPC workers together and shuts
them down cleanly through the same node-owned lifecycle.

---

### Milestone 13 — Multi-Node Devnet Validation
**Goal:** Prove that smallnano works as a real multi-process cryptocurrency network.

Sub-steps:
1. [ ] Add an end-to-end integration test that launches three node processes and verifies block propagation + confirmation
2. [ ] Verify wallet send/receive flow across three nodes using the JSON-RPC surface
3. [ ] Measure idle RSS, sync RSS, disk usage, and confirmation latency against the design targets
4. [ ] Update `test-net.md` with the final Windows/macOS/Linux manual test procedure and expected results
5. [ ] Run the three-machine manual devnet: one Windows node, one macOS node, one Linux node
6. [ ] Fix the remaining cross-platform defects found during the manual run
7. [ ] Add the three-node integration test to the release gate once it is stable
8. [ ] Publish the project website with a single-page explainer and download links
9. [ ] Mark the project release-ready only after the automated and manual devnet tests both pass

**Exit criteria:** A three-node devnet can process and confirm transactions
between separate machines, and both automated and manual tests prove the network
behaves correctly.

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
| M10 (hardening/release scaffolding) | ≤ 64 MB idle / ≤ 256 MB peak | ≤ 2 GB |
| M11 (runtime wiring) | ≤ 64 MB idle | ~500 MB |
| M12 (peer relay + bootstrap config) | ≤ 96 MB peak | ~500 MB |
| M13 (real multi-node validation) | ≤ 64 MB idle / ≤ 256 MB peak | ≤ 2 GB |

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

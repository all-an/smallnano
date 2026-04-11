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

### ✅ Milestone 4 — Own Wire Protocol & Networking
**Completed.** All tests pass. Pure-logic message codec, Ed25519 handshake, framed channel, token-bucket bandwidth limiter, peer state machine, and threaded network manager with accept/dial loops.

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

**Exit criteria:** Two dev-network nodes can connect, complete handshake, exchange
keepalives and Publish messages.

---

### ✅ Milestone 5 — Consensus (Weighted Voting)
**Completed.** All tests pass. Representative weight cache, election state machine, active election container, vote processor, and confirmation tracker are implemented and covered by unit tests.

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

**Exit criteria:** On a two-node devnet, a published block reaches confirmed state
and cementation height advances monotonically.

---

### ✅ Milestone 6 — Bootstrap
**Completed.** All tests pass. Bootstrap frontier scan, `PullReq` servicing, bounded `PullAck` windows, pruning-watermark enforcement, and client-side replay/resume are implemented and covered by unit tests.

Sub-steps:
1. [x] Write `src/bootstrap/server.zig` — serve blocks in response to `PullReq`, respect pruning watermark
2. [x] Write `src/bootstrap/client.zig` — frontier scan, `PullReq`/`PullAck`, resume on restart
3. [x] Update `src/main.zig` imports
4. [x] Run `zig build test` — fix until green
5. [x] `zig fmt src/` + final test run
6. [x] Mark M6 ✅ in ROADMAP.md, commit, push

**Exit criteria:** A fresh node can sync a dev-network ledger from genesis.
Pruned accounts handled without errors.

---

### ✅ Milestone 7 — Wallet & Key Management
**Completed.** All tests pass. Deterministic account derivation, encrypted seed storage, wallet locking/unlocking, and send/open-receive block builders are implemented and covered by unit tests.

Sub-steps:
1. [x] Write `src/wallet/wallet.zig` — deterministic key derivation, encrypted storage, block builders
2. [x] Update `src/main.zig` imports
3. [x] Run `zig build test` — fix until green
4. [x] `zig fmt src/` + final test run
5. [x] Mark M7 ✅ in ROADMAP.md, commit, push

**Exit criteria:** Can generate a keypair, receive smn (devnet), and send smn (devnet)
using only the CLI.

---

### ✅ Milestone 8 — JSON-RPC API
**Completed.** All tests pass. A minimal HTTP/1.1 JSON-RPC server and handler layer are implemented, including wallet lock/unlock, account creation, account and pending queries, and transaction submission (`process`, `send`, `receive`) with unit tests for both JSON dispatch and raw HTTP request handling.

Sub-steps:
1. [x] Write `src/rpc/server.zig` — single-threaded HTTP/1.1 server, no external lib
2. [x] Write `src/rpc/handlers.zig` — all RPC commands (`account_info`, `process`, `send`, `receive`, etc.)
3. [x] Update `src/main.zig` imports
4. [x] Run `zig build test` — fix until green
5. [x] `zig fmt src/` + final test run
6. [x] Mark M8 ✅ in ROADMAP.md, commit, push

**Exit criteria:** An HTTP client can query balances and submit transactions.

---

### Milestone 9 — Configuration & CLI
**Goal:** A friendly, well-documented operator experience.

Sub-steps:
1. [ ] Write `src/config.zig` — `NodeConfig` parsed from TOML + CLI flags, all parameters
2. [ ] Auto-generate config file with defaults and inline comments on first run
3. [ ] `--help` output for every flag
4. [ ] Graceful shutdown on SIGINT / SIGTERM
5. [ ] Run `zig build test` — fix until green
6. [ ] `zig fmt src/` + final test run
7. [ ] Mark M9 ✅ in ROADMAP.md, commit, push

**Exit criteria:** A non-technical user edits one TOML file to configure their node.
All limits enforce the memory and disk targets.

---

### Milestone 10 — Hardening, CI & Release
**Goal:** Production-quality binary with automated quality gates.

Sub-steps:
1. [ ] GitHub Actions CI: `zig build test` on Linux x86_64, aarch64, macOS arm64 + `zig fmt --check`
2. [ ] Fuzz targets for block deserialisation and message parsing
3. [ ] Integration test: 3-node devnet, send a transaction, verify confirmation on all nodes
4. [ ] Benchmark: blocks/second insertion rate and peak RSS — must meet resource targets
5. [ ] Release binaries: `x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-macos`, `aarch64-macos`
6. [ ] Docker image (scratch-based, < 15 MB compressed)
7. [ ] Systemd unit file and one-command install script
8. [ ] Project website with single-page explainer and download links

**Exit criteria:** `curl -fsSL install.sh | sh` installs smallnano on a fresh
Ubuntu 22.04 VM. Node runs at ≤ 64 MB RAM idle after sync. Any low-end computer
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

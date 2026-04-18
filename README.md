# smallnano

A lightweight block-lattice cryptocurrency written in Zig.

Inspired by Nano's ideas (zero fees, instant finality, no mining) but built as an independent network with its own protocol, address format, and coin. Designed to run on a low-end computer or a $5 VPS.

## Goals

| Target | Value |
|--------|-------|
| Idle RAM | ≤ 64 MB |
| Disk (pruned ledger) | ≤ 2 GB |
| Binary size | ≤ 10 MB |
| Dependencies | Zig stdlib + SQLite (vendored) |

## Key properties

- **Block-lattice** — every account has its own chain, no global chain to sync
- **Zero fees** — spam resistance via CPU proof-of-work
- **Instant finality** — weighted representative voting confirms blocks in seconds
- **No mining** — representatives vote with delegated balance, not hash power
- **Configurable pruning** — operators choose how much history to keep
- **Own wire protocol** — not compatible with Nano or any existing network
- **Address format** — `smn_...`
- **Denomination** — 1 smn = 10²⁴ raw; fixed supply of 10,000,000 smn

## Build

```sh
zig build                          # debug binary
zig build -Doptimize=ReleaseSafe   # production binary
zig build test                     # run all unit tests
zig build fmt-check                # formatting check used in CI
zig build bench-ledger -- 10       # local ledger benchmark
printf 'abc' | zig build fuzz-block
printf 'abcdefgh' | zig build fuzz-message
```

Requires Zig 0.15+. No other dependencies to install — SQLite is vendored.

## Run

```sh
zig build
./zig-out/bin/smallnano
./zig-out/bin/smallnano --network=dev --max-blocks-per-account=500
```

On the first run, `smallnano` creates the default config automatically, starts
the node, and tries to open `http://127.0.0.1:<rpc-port>/setup` in your browser.
After saving the config there, restart the node once to apply the new values.

Current runtime note: the binary now loads config, initializes the node runtime, bootstraps genesis state, starts/stops the owned network and RPC workers cleanly, restores/persists known peers with bounded reconnect backoff, and routes inbound `publish`, `vote`, `pull_req`, and `pull_ack` traffic through the node-owned runtime. Final multi-node devnet proof is still pending, and autonomous representative mode plus public-network readiness work still sit in later roadmap milestones. See [test-net.md](test-net.md) for the exact three-node bring-up status and remaining blockers.

## Status

| Milestone | Status |
|-----------|--------|
| M1 — Core types & cryptography | ✅ Done |
| M2 — Storage layer (SQLite) | ✅ Done |
| M3 — Ledger & block validation | ✅ Done |
| M4 — Wire protocol & networking | module-complete, integration pending |
| M5 — Consensus (weighted voting) | module-complete, integration pending |
| M6 — Bootstrap | module-complete, integration pending |
| M7 — Wallet & key management | module-complete, integration pending |
| M8 — JSON-RPC API | module-complete, integration pending |
| M9 — Configuration & CLI | config complete, multi-node validation pending |
| M10 — Hardening & CI | in progress |
| M11 — Node runtime wiring | ✅ Done |
| M12 — Peer relay & bootstrap config | in progress |
| M13 — Multi-node devnet validation | pending |
| M14 — Representative mode & quorum visibility | pending |
| M15 — Distribution & decentralization readiness | pending |
| M16 — Production UX & integrations | pending |
| M17 — Stress testing, spam resistance & performance tuning | pending |
| M18 — Public network readiness, trust & ecosystem | pending |

See [ROADMAP.md](ROADMAP.md) for full details.

The roadmap now separates technical network completion from broader launch work.
M13 is the devnet proof milestone. M14-M18 cover representative automation,
decentralization, user/integration UX, performance hardening, and public-network
readiness.

## Architecture

```
src/
  config.zig  generated config, CLI flags, help, validation
  node/       runtime owner, genesis bootstrap, publish/vote coordination
  types/      block, account, amount, vote, pending, genesis
  crypto/     blake2b, ed25519, proof-of-work
  store/      SQLite store + in-memory null store for tests
  ledger/     validator, inserter, pruner, block processor
  network/    peer, channel, message framing, handshake
  consensus/  elections, vote processor, confirmation
  bootstrap/  ledger sync client and server
  wallet/     key management, block builders
  rpc/        JSON-RPC HTTP server
```

## Operations

- [test-net.md](test-net.md) — three-Linux-machine bring-up plan and current runtime blockers
- [scripts/install.sh](scripts/install.sh) — release installer for packaged binaries
- [packaging/systemd/smallnano.service](packaging/systemd/smallnano.service) — systemd unit template
- [.github/workflows/ci.yml](.github/workflows/ci.yml) — formatting and unit-test CI
- [.github/workflows/release.yml](.github/workflows/release.yml) — cross-target release artifact workflow

## License

MIT

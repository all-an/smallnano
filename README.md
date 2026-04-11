# smallnano

A lightweight block-lattice cryptocurrency written in Zig.

Inspired by Nano's ideas (zero fees, instant finality, no mining) but built as an independent network with its own protocol, address format, and coin. Designed to run on a Raspberry Pi or a $5 VPS.

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
```

Requires Zig 0.15+. No other dependencies to install — SQLite is vendored.

## Run

```sh
zig build run -- node run --network=main
zig build run -- node run --network=dev --max-blocks-per-account=500
```

## Status

| Milestone | Status |
|-----------|--------|
| M1 — Core types & cryptography | ✅ Done |
| M2 — Storage layer (SQLite) | ✅ Done |
| M3 — Ledger & block validation | ✅ Done |
| M4 — Wire protocol & networking | ✅ Done |
| M5 — Consensus (weighted voting) | pending |
| M6 — Bootstrap | pending |
| M7 — Wallet & key management | pending |
| M8 — JSON-RPC API | pending |
| M9 — Configuration & CLI | pending |
| M10 — Hardening & CI | pending |

See [ROADMAP.md](ROADMAP.md) for full details.

## Architecture

```
src/
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

## License

MIT

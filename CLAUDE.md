# CLAUDE.md

This file provides guidance to Claude Code when working with the smallnano codebase.

## What is smallnano?

smallnano is an **independent cryptocurrency** written in **Zig**, inspired by the
ideas behind Nano (block-lattice, ORV-style voting, zero fees) but with a completely
different protocol, network, and coin. It is NOT compatible with Nano or any existing
network. It has its own genesis block, its own wire protocol, its own denomination,
and its own design priorities.

**Core philosophy:**
- Any person in the world must be able to run a full node on cheap hardware
  (Raspberry Pi, $5 VPS, old laptop)
- Configurable ledger depth per operator — trade storage for history
- Zero fees, instant finality via block-lattice + weighted voting
- One binary, no daemons, no dependencies to install

**Key divergences from Nano's design:**
- Own wire protocol (simpler message format, smaller headers)
- Own address format and account encoding
- Own genesis supply and distribution model
- Own PoW difficulty curve (lighter for receive, heavier for send — CPU only)
- Pruning is a first-class feature, not an afterthought
- SQLite instead of LMDB
- Voting weight based on pruning-aware confirmed ledger only

## Language & Toolchain

- **Zig** — minimum version tracked in `build.zig.zon`
- **SQLite** — vendored amalgamation (`src/vendor/sqlite3.{c,h}`)
- **Blake2b** — via `std.crypto.hash.blake2.Blake2b256` / `Blake2b512`
- **Ed25519** — `std.crypto.sign.Ed25519`
- No external C++ or Rust dependencies; single `zig build` produces a static binary

## Commands

### Build
```bash
zig build                        # build the smallnano binary (Debug)
zig build -Doptimize=ReleaseSafe # release build (recommended for nodes)
zig build -Doptimize=ReleaseSmall # smallest binary for embedded targets
```

### Test
```bash
zig build test                    # run ALL unit tests (required before every commit)
zig build test -- --filter <name> # run a specific test by name
```

### Run
```bash
zig build run -- node run --network=main
zig build run -- node run --network=dev --max-blocks-per-account=500
```

### Format & Lint
```bash
zig fmt src/                     # format all source files
zig fmt --check src/             # check formatting (used in CI)
```

## Workflow

After finishing editing source files:
1. Run `zig fmt src/` to format the code.
2. Run `zig build test` to verify all unit tests pass.
3. Fix any failures before committing.

**Unit tests are mandatory for all code.** No logic file ships without tests.

## Architecture

### Design Philosophy

smallnano follows **A-frame architecture**:

- **Logic** — pure computation, state machines, protocol rules. Zero I/O, zero allocations from infra.
- **Infrastructure** — disk, network, clock, SQLite. No business logic whatsoever.
- **Application** — thin coordination layer that reads from infra → drives logic → writes back.

Logic must be testable with zero I/O setup. Infrastructure must be swappable.

### Memory Discipline

Every allocation must pass through an explicit `std.mem.Allocator`. Never use a global
allocator implicitly. Each subsystem receives its allocator at construction time.

| Scope | Allocator |
|-------|-----------|
| Long-lived node state | `std.heap.GeneralPurposeAllocator` |
| Per-block / per-message | `std.heap.ArenaAllocator` — always `deinit` after |
| Tests | `std.testing.allocator` — auto leak-checks |

### Bounded Ledger

The operator configures `max_blocks_per_account` (default: 1000). When an account
exceeds that depth, the oldest blocks are pruned. Nodes advertise their pruning depth
so peers can skip requests for pruned history. Pruning never goes below the local
confirmation watermark.

### Module layout

```
src/
  main.zig              # Entry point, CLI parsing, signal handling
  node.zig              # Node struct: wires all subsystems, start/stop lifecycle
  config.zig            # NodeConfig — parsed from TOML + CLI flags
  types/
    block.zig           # Block, BlockHash, StateBlock serialise/deserialise
    account.zig         # Account (32-byte pubkey), own base32 encoding (smn_...)
    amount.zig          # Amount (u128 raw), arithmetic, display
    vote.zig            # Vote, VoteHash, final-vote bit
    pending.zig         # PendingKey, PendingInfo
    genesis.zig         # Hard-coded genesis block and initial supply
  crypto/
    blake2b.zig         # Blake2b-256 and Blake2b-512 wrappers
    ed25519.zig         # sign / verify wrappers around std.crypto
    work.zig            # CPU PoW generation and validation
  ledger/
    ledger.zig          # Ledger — coordinates store + validation + insertion + pruning
    validator.zig       # BlockValidator — pure logic, zero I/O
    inserter.zig        # BlockInserter — applies a validated block to the store
    pruner.zig          # LedgerPruner — enforces max_blocks_per_account
    block_processor.zig # MPSC queue; worker drives Ledger.process()
  store/
    store.zig           # Store interface (comptime-duck-typed)
    sqlite_store.zig    # SQLite implementation
    null_store.zig      # In-memory null store for tests
  network/
    peer.zig            # Peer address, connection state
    channel.zig         # TCP channel read/write with length-prefixed frames
    message.zig         # Own message types and framing (NOT Nano protocol)
    handshake.zig       # Node-ID cookie/challenge handshake
    bandwidth.zig       # Token-bucket bandwidth limiter
    network.zig         # Peer set, accept loop, outbound dialer
  consensus/
    vote_processor.zig  # Validate and tally incoming votes
    election.zig        # Election state machine (logic only)
    active_elections.zig# Bounded active elections container
    confirmation.zig    # Cementation — writes confirmation_height
    rep_weights.zig     # In-memory representative weight cache
  bootstrap/
    client.zig          # Request missing blocks from peers
    server.zig          # Serve blocks to bootstrapping peers
  rpc/
    server.zig          # Minimal HTTP/1.1 JSON-RPC server
    handlers.zig        # RPC command handlers
  wallet/
    wallet.zig          # Key management, send/receive block builders
  utils/
    stats.zig           # Lightweight counters / metrics
    ticker.zig          # Periodic background task runner
    cancellation.zig    # CancellationToken for cooperative shutdown
  vendor/
    sqlite3.c           # SQLite amalgamation
    sqlite3.h
build.zig
build.zig.zon
```

### Testing Rules

- **Every public function and every state machine must have unit tests.**
- Use `std.testing.allocator` in tests — it will catch memory leaks automatically.
- Logic tests: instantiate the struct directly, pass inputs, assert outputs. No I/O.
- Infrastructure tests: use `null_store.zig` / in-memory equivalents.
- Never use sleep in tests. Use deterministic inputs and state assertions.
- Test helper functions go at the **bottom** of the test block, after the test cases.
- Name tests descriptively: `test "validator rejects block with bad signature"`.

### Configuration

`NodeConfig` lives in `src/config.zig`. All limits are configurable at startup:

| Field | Default | Description |
|-------|---------|-------------|
| `max_blocks_per_account` | 1000 | Ledger pruning depth per account |
| `max_peers` | 50 | Maximum simultaneous peer connections |
| `work_threads` | 1 | CPU threads for PoW generation |
| `rpc_port` | 7177 | JSON-RPC HTTP port |
| `peering_port` | 7176 | P2P TCP port |
| `network` | `main` | `main`, `beta`, `dev` |
| `bandwidth_limit_mbps` | 10 | Inbound+outbound bandwidth cap |
| `max_pending_elections` | 500 | Active elections before dropping lowest-priority |
| `enable_voting` | false | Opt-in for representatives |
| `log_level` | `info` | `err`, `warn`, `info`, `debug` |

### smallnano Protocol (own wire format)

smallnano does NOT implement the Nano wire protocol. Its own protocol uses:
- Magic bytes: `0x534E` ("SN" for SmallNano)
- Network byte: `0x01` (main), `0x02` (beta), `0xFF` (dev)
- All integers: little-endian
- Message framing: 4-byte header + 4-byte body length + body
- Own message types: `Handshake`, `Keepalive`, `Publish`, `VoteBy`, `PullReq`, `PullAck`, `Telemetry`

### Address Format

Accounts are displayed as `smn_<base32-encoded-pubkey><4-char-checksum>`.
The checksum is the first 4 characters of Blake2b-32(pubkey) in the same base32 alphabet.

### Denomination

All balances are stored as plain integers called **raw** — the smallest indivisible unit.
Human-readable units are just powers of 10 applied on display; the node never does floating-point arithmetic.

| Unit | Raw value | Meaning |
|------|-----------|---------|
| 1 smn | 10^24 raw | One full coin. Like "1 dollar". This is the main unit users see. 10^24 = 1,000,000,000,000,000,000,000,000 (one septillion). |
| 1 msmn (milli-smn) | 10^21 raw | One thousandth of a coin. Like "1 cent" if there were 1000 cents per dollar. 10^21 = 1,000,000,000,000,000,000,000 (one sextillion raw). |
| 1 μsmn (micro-smn) | 10^18 raw | One millionth of a coin. Useful for very small payments. 10^18 = 1,000,000,000,000,000,000 (one quintillion raw). |
| 1 raw | 1 | The atomic unit — cannot be divided further. No fractions, no floating point anywhere in the codebase. |

**Why such large numbers?** Storing balances as large integers avoids all floating-point rounding errors. The same technique is used by Ethereum (wei), Bitcoin (satoshi), and Nano (raw). The number 10^24 was chosen so that 10,000,000 smn fits comfortably in a u128 (max ~3.4 × 10^38).

Genesis supply: 10,000,000 smn (10 million, fixed forever — 10^31 raw), all in the genesis account. No inflation, no mining rewards, no fees.

## Code Style

- Prefer explicit error unions (`!T`) over panics in production code paths.
- Use `comptime` for zero-cost generics, not runtime vtables.
- Struct constructors: `init(allocator, ...)` starts nothing. Separate `start()` method
  launches threads / opens sockets. `deinit()` frees everything.
- No global mutable state outside of `main.zig`.
- All integer arithmetic on `Amount` uses checked math (`std.math.add`, etc.).
- Every file that has logic also has a `test` block at the bottom.

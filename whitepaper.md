# smallnano Whitepaper

## smallnano: A Lightweight, Prunable Block-Lattice Cryptocurrency

Version 0.1  
April 2026

## Abstract

smallnano is an independent digital currency designed for low-cost, low-resource full nodes. It combines a block-lattice ledger, zero-fee user transfers, weighted representative voting, and bounded ledger pruning in order to reduce the hardware and storage costs of participating in the network. The protocol is inspired by the usability goals of Nano, but it is not Nano-compatible and does not reuse Nano's wire protocol, address format, genesis ledger, or coin economics.

The design goal is straightforward: a full node should be practical on low-end PCs, older laptops, and inexpensive virtual private servers, while preserving direct user custody, deterministic validation rules, and rapid transaction finality. smallnano uses a single state-block format from genesis, Ed25519 signatures, Blake2b hashing, asymmetric CPU proof-of-work thresholds for spam resistance, and weighted representative voting for confirmation. The protocol is explicitly designed for pruning from the start, so operators can bound storage without abandoning full verification of current state.

This document describes the target protocol and system model of smallnano. The current reference implementation already includes the core types, cryptography, storage layer, and ledger validation pipeline; networking, full consensus, bootstrap, wallet, and RPC remain under active development.

## 1. Motivation

Cryptocurrency networks often drift toward operational centralization because the cost of running a full node rises faster than ordinary users can justify. High memory consumption, large archival storage requirements, heavyweight dependency stacks, and operational complexity all push node operation toward a small set of professional operators.

smallnano is built around the opposite assumption: a payment network should be operable by ordinary users on modest hardware. This leads to several design constraints:

- The ledger must avoid a single global transaction bottleneck.
- Validation rules must be compact and deterministic.
- The protocol must not require mining.
- User transfers should remain fee-free.
- Storage growth must be bounded through first-class pruning.
- The reference implementation should remain small, auditable, and dependency-light.

smallnano therefore focuses narrowly on one problem: global digital payments and value transfer. It deliberately excludes general-purpose smart contracts, mining, and archival-by-default node behavior.

## 2. Design Goals

smallnano targets the following operating envelope for the reference implementation:

- Idle RAM: at or below 64 MB
- Peak RAM under load: at or below 256 MB
- Pruned ledger disk usage: at or below 2 GB
- Binary size: at or below 10 MB in release mode
- Dependencies: Zig standard library plus vendored SQLite in the current implementation

These targets are not cosmetic. They shape the protocol:

- A block-lattice reduces contention by giving each account its own chain.
- A single state-block format removes legacy complexity.
- Representative voting removes mining overhead.
- Pruning is a normal mode of operation, not an optional afterthought.
- CPU-only work avoids GPU and driver dependencies.

## 3. Design Lineage and Lessons from Prior Whitepapers

The smallnano whitepaper is informed by several earlier cryptocurrency papers and protocol documents:

### Bitcoin

Bitcoin's original whitepaper remains the clearest example of a concise problem-solution-security document. Its strongest lesson is not merely proof-of-work; it is the discipline of explaining the threat model, trust assumptions, and transaction finality mechanism in a compact way. smallnano adopts that discipline, but replaces Nakamoto consensus with account-local chains plus representative voting.

### Ethereum

Ethereum's whitepaper is valuable because it explicitly frames the protocol as a state transition system. smallnano borrows that clarity: each account evolves through signed state transitions, and validation is defined in terms of prior state, not in terms of opaque wallet actions. Unlike Ethereum, smallnano does not aim to be a general-purpose computation layer. It is intentionally specialized for payments.

### Nano

Nano's original whitepaper and subsequent living documentation demonstrate the strengths of a block-lattice ledger for user-facing payments: independent account chains, no fees, and fast confirmation. smallnano inherits that overall direction, but diverges in several important ways:

- It uses its own wire protocol.
- It uses its own `smn_` address format.
- It adopts pruning as a primary design objective.
- It targets CPU-only work generation.
- It defines an independent genesis ledger and supply distribution.

The most important lesson from Nano is that user experience improves when transaction settlement is decoupled from a global serialized chain. The most important lesson from Bitcoin is that security assumptions must remain explicit. The most important lesson from Ethereum is that protocol rules should be described as formal state transitions rather than wallet metaphors. smallnano combines those lessons into a payment-focused protocol optimized for low-cost node operation.

## 4. System Overview

smallnano is a block-lattice cryptocurrency. Every account owns an independent chain of blocks. A transfer of value is not one global transaction appended to one global chain; instead, value is represented by changes in the state of individual accounts.

The protocol uses four logical actions, all encoded as a single state-block format:

- `open`: create an account chain and receive an incoming amount
- `send`: reduce balance and create a receivable pending entry for a destination account
- `receive`: consume a pending send and increase balance
- `change`: update the representative without changing balance

This model allows independent account updates, avoids global mempool auctions for limited block space, and cleanly separates balance ownership from network-wide ordering.

## 5. Accounts, Addresses, and Amounts

An account is a 32-byte Ed25519 public key. Human-readable addresses are encoded as:

`smn_<52 base32 characters><8 checksum characters>`

The address format uses a custom base32 alphabet intended to avoid visually ambiguous characters. The checksum is derived from a Blake2b digest of the public key.

Balances are stored as unsigned 128-bit integers in the smallest indivisible unit, `raw`.

- `1 smn = 10^24 raw`
- Total fixed supply: `10,000,000 smn`
- Total fixed supply in raw units: `10^31 raw`

The use of integer-only accounting avoids rounding risk and keeps validation simple and deterministic.

## 6. State Blocks

smallnano uses a single state-block type from genesis onward. Each block contains:

- account
- previous
- representative
- balance
- link
- work
- signature

In the current reference encoding, a serialized state block is 216 bytes.

The `link` field is interpreted by context:

- for `send` and `change`, it identifies the destination account
- for `open` and `receive`, it identifies the source send block hash

The canonical block hash is computed over the semantic state fields only. Work and signature are not part of the block hash itself; they are attached evidence that the state transition is authorized and meets the network's anti-spam rules.

## 7. Transaction Semantics

smallnano validation is defined as a state transition problem.

For a block to be valid:

- the account must not be the burn account
- the Ed25519 signature must verify against the account key
- the block must not already exist
- open blocks may only appear for unopened accounts
- non-open blocks must reference the current frontier of the account chain
- the proof-of-work must satisfy the required threshold
- for open and receive blocks, the balance delta must match a valid pending entry

This makes validation local, explicit, and deterministic. A node does not need to interpret user intent; it only needs the prior account state, the referenced pending entry when applicable, and the block itself.

## 8. Pending Transfers

When an account performs a `send`, the sender's balance decreases immediately and a pending receivable entry is created for the destination. Funds are claimable only when the recipient publishes an `open` or `receive` block that consumes that pending entry.

This model preserves asynchronous ownership semantics:

- the sender commits the transfer by reducing its own balance
- the recipient finalizes possession by accepting the receivable into its own chain

Pending entries are therefore a core part of ledger state, not an external mempool artifact.

## 9. Spam Resistance via CPU Proof-of-Work

smallnano has zero protocol fees, so it requires an alternative anti-spam mechanism. It uses lightweight CPU proof-of-work per block:

- send and representative-change blocks use a higher threshold
- open and receive blocks use a lower threshold

This asymmetry is deliberate. It is more important to make incoming funds easy to accept than to make outbound spam cheap to create. By making receive-side work lighter, smallnano preserves usability while still imposing computational cost on transaction creation.

Work is defined as a nonce such that:

- `Blake2b-64(nonce_le || block_hash)`, interpreted as a little-endian 64-bit integer, is at least the required threshold

The protocol is designed for CPU generation. The current reference implementation intentionally avoids GPU-specific dependencies.

## 10. Consensus and Finality

smallnano does not use mining. Instead, it uses weighted representative voting.

Each account designates a representative in its state. Voting weight derives from delegated balance on the confirmed ledger. Representatives issue signed votes over block hashes. In the current protocol design, a vote may cover multiple hashes and includes a timestamp; a distinguished maximum timestamp represents a final vote.

The intended confirmation model is:

- blocks are published to the network
- representatives broadcast signed votes
- nodes tally votes by representative weight
- when quorum is reached, the block is confirmed
- confirmation height advances monotonically for the relevant account chain

This design aims to provide rapid economic finality without the energy expenditure or latency of mining-based global chain selection.

## 11. Pruning as a First-Class Protocol Objective

Most cryptocurrencies treat full archival history as the normal operating mode. smallnano does not.

Each node operator selects a maximum block depth per account chain. When an account exceeds that bound, older blocks may be pruned, subject to one safety rule: pruning must not pass below the local confirmation watermark.

This has several benefits:

- storage is bounded
- long-term node operation remains practical on modest disks
- nodes can still validate current state and newly received blocks
- bootstrap protocols can account explicitly for pruned ranges

Pruning is therefore part of the protocol architecture, not merely a database optimization. A node is still a full node if it verifies consensus rules and current state, even if it does not retain all historical account-chain data forever.

## 12. Networking

smallnano uses its own lightweight wire protocol rather than reusing Nano's. In the current design:

- message frames begin with the `"SN"` magic bytes
- network identifiers distinguish main, beta, and development networks
- integers are encoded little-endian
- messages are length-prefixed

The protocol includes compact message types for:

- handshake
- keepalive
- block publication
- representative votes
- bootstrap pull requests and responses
- telemetry

Peer authentication is based on a cookie-challenge handshake using Ed25519 node identity keys. The purpose is not to create trusted identities in the social sense, but to prevent trivial impersonation during live network sessions.

## 13. Storage and the Reference Implementation

The smallnano protocol is conceptually storage-agnostic, but the current reference implementation uses a single embedded SQLite database in WAL mode. This choice is motivated by operational simplicity, compact deployment, and a predictable low-resource footprint.

The reference ledger stores:

- account frontiers and balances
- blocks
- pending entries
- confirmation heights
- peer observations
- pruning watermarks
- metadata such as schema version and network identifiers

This is an implementation choice, not a consensus requirement. The protocol rules are defined by block validity, vote validity, and confirmation semantics, not by any particular storage engine.

## 14. Monetary Policy and Distribution

smallnano has a fixed supply. No inflation, mining rewards, or ongoing issuance are planned.

- Total supply: `10,000,000 smn`
- Development fund: `50,000 smn`
- Community distribution through airdrops and faucet game: `9,950,000 smn`

smallnano does not use an ICO, pre-sale, or investor allocation. The intent is to distribute the overwhelming majority of supply through participation rather than capital purchase.

The genesis block opens the genesis account and credits it with the entire fixed supply. The genesis ledger is an explicit part of the protocol and defines the monetary base of the network.

## 15. Security Model

smallnano assumes:

- Ed25519 remains secure for signatures
- Blake2b remains secure for hashing and work generation
- representative weight is sufficiently decentralized to prevent routine capture
- nodes verify all ledger and vote rules independently

Attack surfaces include:

- spam through cheap block production
- representative concentration
- eclipse and peer-isolation attacks
- dishonest bootstrap sources
- implementation bugs in networking or persistence

The protocol mitigates these through lightweight work, explicit signatures, bounded and auditable state transitions, confirmation-height tracking, and pruning-aware bootstrap design. The reference implementation further isolates logic from infrastructure so validation can be tested independently from disk and network code.

## 16. What smallnano Is Not

smallnano is not:

- a smart contract platform
- a mining network
- a general data availability layer
- an archival-by-default system
- a Nano fork or Nano-compatible node

Its scope is intentionally narrow: secure, fast, low-cost digital payments.

## 17. Implementation Status

At the time of writing, the reference implementation already includes:

- core types and serialization
- account and amount encoding
- genesis definitions
- Blake2b and Ed25519 wrappers
- CPU proof-of-work generation and validation
- SQLite-backed storage and in-memory test storage
- block validation
- atomic block insertion
- pruning logic
- a ledger coordinator and block processor

The following remain under active development:

- full peer-to-peer networking
- vote tallying and consensus finalization
- bootstrap synchronization
- wallet and block-building tools
- JSON-RPC server
- configuration and operational CLI
- hardening, benchmarks, and release automation

## 18. Conclusion

smallnano proposes a payment-focused cryptocurrency whose primary innovation is not a new cryptographic primitive, but a more practical combination of known ideas: block-lattice accounting, representative voting, fee-free transfers, asymmetric CPU work, and mandatory support for bounded storage.

Its central claim is simple: a network becomes more decentralized when ordinary users can run validating nodes cheaply and continuously. smallnano is designed around that claim from genesis.

## References

- Bitcoin whitepaper: https://bitcoin.org/en/bitcoin-paper
- Ethereum whitepaper: https://ethereum.org/whitepaper/
- Nano original whitepaper: https://docs.nano.org/whitepaper/english/
- Nano living whitepaper: https://docs.nano.org/living-whitepaper/

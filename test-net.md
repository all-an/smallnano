# smallnano Test Net

This document is the operator checklist for bringing up a three-machine dev network:

- 1 node on Windows
- 1 node on macOS
- 1 node on Linux in VirtualBox

It also states the current limitation in the repository clearly: as of April 11, 2026, the codebase does **not** yet have a fully wired node runtime that starts storage, networking, RPC, bootstrap, and consensus together, and the current network layer does not retain live outbound peer channels for block/vote relay. Because of that, you can validate build parity, config parity, startup/shutdown behavior, and local module behavior on all three machines, but you cannot yet complete a real multi-node currency transfer over the network from this tree alone.

## What you can test today

- Cross-platform build on all three machines
- Config-file generation and CLI overrides
- Clean startup and shutdown on all three machines
- Unit-test parity across Windows, macOS, and Linux
- RPC/module compatibility at the code level
- Release artifact and packaging flow

## What is still blocked for a real 3-node devnet

- No fully wired `Node` runtime yet
- No outbound publish/vote relay path in the current `network.zig`
- No peer-seed/bootstrap configuration surface in `config.zig`
- No end-to-end integration test proving block propagation and confirmation between three processes

That means you should treat this as a bring-up and readiness document, not a claim that the repository already supports live cross-node transactions.

## Machine layout

Use these example hostnames and ports:

- `win-node`
  - peering port: `7176`
  - rpc port: `7177`
- `mac-node`
  - peering port: `7276`
  - rpc port: `7277`
- `linux-vm-node`
  - peering port: `7376`
  - rpc port: `7377`

For the Linux VM:

- use bridged networking if you want the other two machines to reach it directly
- otherwise set up explicit port forwarding from the host to the guest

## Build and test on each machine

1. Install Zig `0.15.2`.
2. Clone the repo.
3. Run:

```sh
zig build test
```

4. Confirm the suite passes on all three machines before testing runtime behavior.

## Suggested per-node config

Create one config file per machine. The binary will generate a default file on first run if missing. Then edit:

```toml
max_blocks_per_account = 1000
max_peers = 50
work_threads = 1
rpc_port = 7177
peering_port = 7176
network = "dev"
bandwidth_limit_mbps = 10
max_pending_elections = 500
enable_voting = false
log_level = "debug"
```

Change only the two ports per machine.

## Current startup test

On each machine, run:

```sh
zig build run -- node run --network dev --rpc-port 7177 --peering-port 7176
```

Adjust the ports per node.

Expected current behavior:

- config loads successfully
- the binary reports the selected network and ports
- the process stays alive until `Ctrl+C`
- shutdown is clean on all three operating systems

This is the current meaningful runtime validation for the repo as it exists now.

## Packaging checks

You can also validate the release scaffolding:

```sh
zig build -Doptimize=ReleaseSafe
zig build bench-ledger -- 10
printf 'abc' | zig build fuzz-block
printf 'abcdefgh' | zig build fuzz-message
sh -n scripts/install.sh
```

## Bench and fuzz notes

`bench-ledger`

- runs local ledger-processing throughput on valid open blocks
- useful for rough machine-to-machine comparison
- not a proof of live-network performance

`fuzz-block` and `fuzz-message`

- decode arbitrary stdin into block/message parsers
- useful with AFL/libFuzzer-style wrappers later
- currently lightweight harnesses, not a complete fuzzing pipeline

## When the runtime gap is closed

Once the node runtime exists, the three-node live test should look like this:

1. Start all three nodes on `network = "dev"`.
2. Seed each node with the addresses of the other two peers.
3. Confirm all three nodes establish peer connections.
4. Send funds from one wallet through RPC.
5. Confirm the published block reaches the other two nodes.
6. Confirm votes propagate.
7. Confirm confirmation height advances on all three nodes.
8. Create a receive block on the destination node.
9. Confirm the receive block also propagates and cements on all three nodes.

## Data to record during your manual test

For each machine, capture:

- OS version
- CPU model
- RAM size
- Zig version
- exact `config.toml`
- `zig build test` result
- startup log output
- shutdown behavior
- benchmark output from `zig build bench-ledger -- 10`

## Recommendation

Do not announce a public testnet from the current repository state yet.

The right order is:

1. wire a real `Node` runtime
2. add outbound publish/vote peer messaging
3. add peer/bootstrap configuration
4. prove a real 3-node integration test in CI
5. then run the Windows/macOS/Linux manual network test

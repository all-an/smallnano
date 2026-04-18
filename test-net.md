# smallnano Test Net Guide

This is the simplest local way to test `smallnano` with three nodes.

Use Docker Compose.

The idea is:

1. build one image
2. start three containers with one command
3. open three setup pages in the browser
4. save one config per node
5. restart the stack
6. watch the logs and test local RPC

This is much easier than coordinating three separate Linux machines on the first
manual test.

## What This Guide Is For

This guide is for:

- fast local bring-up
- smoke testing three nodes
- checking config, startup, ports, setup page, and RPC
- getting to a usable local devnet with the fewest manual steps

This guide is **not** final proof that the public network is fully validated.
That still belongs to the remaining M13 work.

## What You Need

- Docker
- Docker Compose
- a browser

## Ports Used

The guide uses these ports:

| Node | Peering Port | RPC / Setup Port |
|------|--------------|------------------|
| `node1` | `7176` | `7177` |
| `node2` | `7276` | `7277` |
| `node3` | `7376` | `7377` |

Setup pages:

- `http://127.0.0.1:7177/setup`
- `http://127.0.0.1:7277/setup`
- `http://127.0.0.1:7377/setup`

## Step 1 — Use The Checked-In Compose File

The repo already includes [docker-compose.yml](./docker-compose.yml).

You do not need to create it manually.

It already starts:

- `node1` on `7176` / `7177`
- `node2` on `7276` / `7277`
- `node3` on `7376` / `7377`
- all three nodes in `dev` network mode

## Step 2 — Create The Local Data Folders

Run:

```sh
mkdir -p devnet/node1 devnet/node2 devnet/node3
```

## Step 3 — Start All Three Nodes

Run:

```sh
docker compose up --build
```

What should happen:

- Docker builds the image
- all three containers start
- each node creates `/data/config.toml` automatically if missing
- each node starts the runtime
- each node exposes its own setup page

If you want to keep the stack running in the background later, use:

```sh
docker compose up --build -d
```

## Step 4 — Open The Three Setup Pages

Open these in your browser:

- `http://127.0.0.1:7177/setup`
- `http://127.0.0.1:7277/setup`
- `http://127.0.0.1:7377/setup`

Each page edits that node's own `/data/config.toml`.

## Step 5 — Fill The Setup Pages

Use these values.

### Node 1

- `data_dir`: `/data`
- `listen_address`: `0.0.0.0`
- `external_address`: leave blank
- `peer_seeds`:

```text
node2:7276
node3:7376
```

- `bootstrap_peers`:

```text
node2:7276
```

- `rpc_port`: `7177`
- `peering_port`: `7176`
- `network`: `dev`
- `max_blocks_per_account`: `1000`
- `max_peers`: `50`
- `work_threads`: `1`
- `bandwidth_limit_mbps`: `10`
- `max_pending_elections`: `500`
- `enable_voting`: leave unchecked
- `log_level`: `debug`

### Node 2

- `data_dir`: `/data`
- `listen_address`: `0.0.0.0`
- `external_address`: leave blank
- `peer_seeds`:

```text
node1:7176
node3:7376
```

- `bootstrap_peers`:

```text
node1:7176
```

- `rpc_port`: `7277`
- `peering_port`: `7276`
- `network`: `dev`
- `max_blocks_per_account`: `1000`
- `max_peers`: `50`
- `work_threads`: `1`
- `bandwidth_limit_mbps`: `10`
- `max_pending_elections`: `500`
- `enable_voting`: leave unchecked
- `log_level`: `debug`

### Node 3

- `data_dir`: `/data`
- `listen_address`: `0.0.0.0`
- `external_address`: leave blank
- `peer_seeds`:

```text
node1:7176
node2:7276
```

- `bootstrap_peers`:

```text
node1:7176
```

- `rpc_port`: `7377`
- `peering_port`: `7376`
- `network`: `dev`
- `max_blocks_per_account`: `1000`
- `max_peers`: `50`
- `work_threads`: `1`
- `bandwidth_limit_mbps`: `10`
- `max_pending_elections`: `500`
- `enable_voting`: leave unchecked
- `log_level`: `debug`

Save all three forms.

## Step 6 — Restart The Stack

After saving all three configs, restart the containers:

```sh
docker compose down
docker compose up
```

Or if you use detached mode:

```sh
docker compose down
docker compose up -d
```

This restart matters because the setup page saves config for the **next** run.

## Step 7 — Watch The Logs

If you are not in detached mode, the logs are already on screen.

If you are in detached mode, use:

```sh
docker compose logs -f
```

You should see lines similar to:

```text
smallnano configuration loaded from /data/config.toml
network=dev peering_port=... rpc_port=... max_peers=...
node runtime initialised: node_id=...
rpc: listening on 0.0.0.0:...
network: listening on 0.0.0.0:...
node runtime started; waiting for shutdown signal
```

If peer connections succeed, you may also see:

```text
network: peer connected: ...
```

## Step 8 — Test Local RPC On Each Node

### Unlock node1 wallet

```sh
curl -s http://127.0.0.1:7177 -H 'Content-Type: application/json' -d '{"action":"wallet_unlock","password":"devnet-pass"}'
```

### Unlock node2 wallet

```sh
curl -s http://127.0.0.1:7277 -H 'Content-Type: application/json' -d '{"action":"wallet_unlock","password":"devnet-pass"}'
```

### Unlock node3 wallet

```sh
curl -s http://127.0.0.1:7377 -H 'Content-Type: application/json' -d '{"action":"wallet_unlock","password":"devnet-pass"}'
```

Expected result:

```json
{"unlocked":true}
```

### Create account `0` on each node

```sh
curl -s http://127.0.0.1:7177 -H 'Content-Type: application/json' -d '{"action":"account_create","index":"0"}'
curl -s http://127.0.0.1:7277 -H 'Content-Type: application/json' -d '{"action":"account_create","index":"0"}'
curl -s http://127.0.0.1:7377 -H 'Content-Type: application/json' -d '{"action":"account_create","index":"0"}'
```

Expected result:

- an `smn_...` account
- a public key

## Step 9 — Inspect The Saved Config Files

The configs are stored on your host machine here:

- `./devnet/node1/config.toml`
- `./devnet/node2/config.toml`
- `./devnet/node3/config.toml`

That makes it easy to check what each node is actually using.

## Step 10 — Stop Everything

To stop the stack:

```sh
docker compose down
```

## What You Can Honestly Claim After This

If all of this works:

- three local nodes can be started with one command
- each node creates and saves config cleanly
- each node exposes the setup page
- each node exposes RPC
- each node can be configured for the same `dev` network

That is a good local devnet bring-up result.

## What You Still Should Not Claim Yet

Do not claim yet:

- final three-node transaction proof
- final cross-node confirmation proof
- final public testnet readiness

Those still belong to the remaining M13 validation work.

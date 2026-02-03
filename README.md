# Overview

Docker Compose for a Wemix "End Node" (RPC)

`cp default.env .env`, then `nano .env` and adjust values for the right network, set a snapshot.

Meant to be used with [central-proxy-docker](https://github.com/CryptoManufaktur-io/central-proxy-docker) for traefik
and Prometheus remote write; use `:ext-network.yml` in `COMPOSE_FILE` inside `.env` in that case.

If you want the gwemix RPC ports exposed locally, use `rpc-shared.yml` in `COMPOSE_FILE` inside `.env`.

The `./wemd` script can be used as a quick-start:

`./wemd install` brings in docker-ce, if you don't have Docker installed already.

`cp default.env .env`

`nano .env` and adjust variables as needed, particularly `NETWORK` and `SNAPSHOT`

`./wemd up`

To update the software, run `./wemd update` and then `./wemd up`

## Checking Sync Status

To verify your node is synced with the public Wemix network:

```bash
bash scripts/check_sync.sh
```

This script compares your local node's latest block against the public Wemix RPC endpoint (`https://api.wemix.com`). It will report:
- ✅ Node is in sync (height and hash match)
- ⚠️ Heights differ - still syncing
- ❌ Heights match but hashes differ - possible reorg or divergence

Defaults used by the sync check:
- Public RPC: `https://api.wemix.com`
- Local RPC: `http://127.0.0.1:${RPC_PORT}` (from `.env`, default `8588`)
- Compose service (wrapper): `gwemix` (when using `./ethd check-sync`)

You can also run:

```bash
./ethd check-sync
```

This is Wemix Docker v1.0.0

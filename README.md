# Overview

Docker Compose for a Wemix "End Node" (RPC)

`cp default.env .env`, then `nano .env` and adjust values for the right network, set a snapshot.

Meant to be used with [central-proxy-docker](https://github.com/CryptoManufaktur-io/central-proxy-docker) for traefik
and Prometheus remote write; use `:ext-network.yml` in `COMPOSE_FILE` inside `.env` in that case.

If you want the gwemix RPC ports exposed locally, use `wemix-shared.yml` in `COMPOSE_FILE` inside `.env`.

The `./wemd` script can be used as a quick-start:

`./wemd install` brings in docker-ce, if you don't have Docker installed already.

`cp default.env .env`

`nano .env` and adjust variables as needed, particularly `NETWORK` and `SNAPSHOT`

`./wemd up`

To update the software, run `./wemd update` and then `./wemd up`

This is Wemix Docker v1.0.0

#!/usr/bin/env bash
set -euo pipefail

CONTAINER="wemix-gwemix-1"
LOCAL_RPC="http://127.0.0.1:8588"
PUBLIC_RPC="https://api.wemix.com"

echo "==> Ensuring curl and jq are installed inside container"

docker exec -u root "$CONTAINER" sh -c '
set -e
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y curl jq ca-certificates
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache curl jq ca-certificates
else
  echo "Unsupported base image. No apt-get or apk found."
  exit 1
fi
'

echo "==> Querying local Wemix node"

local_json="$(docker exec "$CONTAINER" sh -c "
curl -sS -X POST '$LOCAL_RPC' \
  -H 'Content-Type: application/json' \
  --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"latest\",false],\"id\":1}'
")"

echo "==> Querying public Wemix RPC"

public_json="$(docker exec "$CONTAINER" sh -c "
curl -sS -X POST '$PUBLIC_RPC' \
  -H 'Content-Type: application/json' \
  --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"latest\",false],\"id\":1}'
")"

local_num="$(echo "$local_json"  | docker exec -i "$CONTAINER" jq -r '.result.number')"
local_hash="$(echo "$local_json" | docker exec -i "$CONTAINER" jq -r '.result.hash')"

public_num="$(echo "$public_json"  | docker exec -i "$CONTAINER" jq -r '.result.number')"
public_hash="$(echo "$public_json" | docker exec -i "$CONTAINER" jq -r '.result.hash')"

hex_to_dec() { printf "%d" "$((16#${1#0x}))"; }

local_dec="$(hex_to_dec "$local_num")"
public_dec="$(hex_to_dec "$public_num")"

echo
echo "Local   block: $local_dec  $local_hash"
echo "Public  block: $public_dec $public_hash"
echo

if [[ "$local_num" == "$public_num" && "$local_hash" == "$public_hash" ]]; then
  echo "✅ Node is in sync (height and hash match)"
elif [[ "$local_num" != "$public_num" ]]; then
  echo "⚠️  Heights differ. Still syncing."
  exit 1
else
  echo "❌ Heights match but hashes differ. Possible reorg or divergence."
  exit 2
fi
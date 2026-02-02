#!/usr/bin/env bash
# Standardized sync check script template
# Supports: ETH Execution, Cosmos/Tendermint, Beacon CL, Sui, L2 Rollups
#
# Exit codes:
#   0 - In sync (within acceptable lag)
#   1 - Still syncing (beyond threshold)
#   2 - Hash/digest mismatch (possible fork/reorg)
#   3 - Local RPC error
#   4 - Public RPC error
#   5 - Missing required tools (curl/jq)
#   6 - Invalid arguments
#   7 - Container/service not found or not running

set -Eeuo pipefail

# ============================================================================
# CONFIGURATION - Modify these for your protocol
# ============================================================================

# Protocol type: evm | cosmos | beacon | sui
PROTOCOL="${PROTOCOL:-evm}"

# Default ports by protocol
declare -A DEFAULT_PORTS=(
  [evm]=8588
  [cosmos]=26657
  [beacon]=5052
  [sui]=9000
)

# Default public RPCs (optional - can require --public-rpc instead)
PUBLIC_RPC_DEFAULT="https://api.wemix.com"

# Protocol-specific env vars to check for port (space-separated)
# Example: "RPC_PORT BOR_RPC_PORT EL_RPC_PORT"
PROTOCOL_PORT_VARS="${PROTOCOL_PORT_VARS:-RPC_PORT}"

# ============================================================================
# DEFAULTS
# ============================================================================

BLOCK_LAG=2
SAMPLE_SECS=10
ENV_FILE=".env"
LOCAL_RPC=""
PUBLIC_RPC=""
CONTAINER=""
COMPOSE_SERVICE=""
NO_INSTALL=false

# ============================================================================
# HELP
# ============================================================================

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Check node sync status against a public reference RPC.

Options:
  --public-rpc URL       Public RPC endpoint (default: $PUBLIC_RPC_DEFAULT)
  --local-rpc URL        Local RPC endpoint (default: auto-detect)
  --block-lag N          Acceptable lag threshold (default: $BLOCK_LAG)
  --sample-secs N        ETA sampling window in seconds (default: $SAMPLE_SECS)
  --container NAME       Docker container to exec into for curl/jq
  --compose-service NAME Docker Compose service name
  --env-file PATH        Environment file to load (default: $ENV_FILE)
  --no-install           Skip auto-install of curl/jq in containers
  -h, --help             Show this help message

Exit codes:
  0  In sync or within acceptable lag
  1  Still syncing (beyond threshold)
  2  Hash mismatch (possible reorg/fork)
  3  Local RPC error
  4  Public RPC error
  5  Missing required tools (curl/jq)
  6  Invalid arguments
  7  Container/service not found or not running

Examples:
  $(basename "$0") --public-rpc https://api.wemix.com
  $(basename "$0") --compose-service gwemix --public-rpc https://api.wemix.com
  $(basename "$0") --container my-node --local-rpc http://localhost:8588 --public-rpc https://api.wemix.com
EOF
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --public-rpc)
        PUBLIC_RPC="$2"
        shift 2
        ;;
      --local-rpc)
        LOCAL_RPC="$2"
        shift 2
        ;;
      --block-lag)
        BLOCK_LAG="$2"
        shift 2
        ;;
      --sample-secs)
        SAMPLE_SECS="$2"
        shift 2
        ;;
      --container)
        CONTAINER="$2"
        shift 2
        ;;
      --compose-service)
        COMPOSE_SERVICE="$2"
        shift 2
        ;;
      --env-file)
        ENV_FILE="$2"
        shift 2
        ;;
      --no-install)
        NO_INSTALL=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "ERROR: Unknown option: $1" >&2
        usage >&2
        exit 6
        ;;
    esac
  done
}

# ============================================================================
# ENVIRONMENT LOADING
# ============================================================================

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "$ENV_FILE"
    set +a
  fi
}

# ============================================================================
# RPC RESOLUTION
# ============================================================================

resolve_local_rpc() {
  # Priority: CLI > env var > protocol-specific vars > default
  if [[ -n "$LOCAL_RPC" ]]; then
    echo "$LOCAL_RPC"
    return
  fi

  # Check protocol-specific env vars
  for var in $PROTOCOL_PORT_VARS; do
    if [[ -n "${!var:-}" ]]; then
      echo "http://127.0.0.1:${!var}"
      return
    fi
  done

  # Default by protocol
  local port="${DEFAULT_PORTS[$PROTOCOL]:-8588}"
  echo "http://127.0.0.1:$port"
}

resolve_public_rpc() {
  if [[ -n "$PUBLIC_RPC" ]]; then
    echo "$PUBLIC_RPC"
    return
  fi

  # Check for default (set in config section)
  if [[ -n "${PUBLIC_RPC_DEFAULT:-}" ]]; then
    echo "$PUBLIC_RPC_DEFAULT"
    return
  fi

  echo ""
}

# ============================================================================
# CONTAINER/SERVICE HELPERS
# ============================================================================

resolve_container() {
  if [[ -n "$CONTAINER" ]]; then
    echo "$CONTAINER"
    return
  fi

  if [[ -n "$COMPOSE_SERVICE" ]]; then
    local container_id
    container_id=$(docker compose ps -q "$COMPOSE_SERVICE" 2>/dev/null || true)
    if [[ -z "$container_id" ]]; then
      echo "ERROR: Compose service '$COMPOSE_SERVICE' not found or not running" >&2
      exit 7
    fi
    echo "$container_id"
    return
  fi

  echo ""
}

# Execute command, optionally in container
exec_cmd() {
  local container="$1"
  shift

  if [[ -n "$container" ]]; then
    docker exec "$container" "$@"
  else
    "$@"
  fi
}

# ============================================================================
# TOOL INSTALLATION (in containers)
# ============================================================================

ensure_tools() {
  local container="$1"

  echo "⏳ Checking tools inside container"

  if [[ -z "$container" ]]; then
    # Local execution - check tools exist
    if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
      echo "❌ curl and jq are required" >&2
      exit 5
    fi
    echo "✅ Tools available"
    return
  fi

  # In container - check and install if needed
  if exec_cmd "$container" sh -c "command -v curl && command -v jq" &>/dev/null; then
    echo "✅ Tools available in container"
    return
  fi

  if [[ "$NO_INSTALL" == "true" ]]; then
    echo "❌ curl/jq not found in container and --no-install specified" >&2
    exit 5
  fi

  echo "⏳ Installing curl and jq in container..."

  # Try apt-get first, then apk
  if exec_cmd "$container" sh -c "command -v apt-get" &>/dev/null; then
    exec_cmd "$container" apt-get update -qq
    exec_cmd "$container" apt-get install -qq -y curl jq ca-certificates
  elif exec_cmd "$container" sh -c "command -v apk" &>/dev/null; then
    exec_cmd "$container" apk add --no-cache curl jq ca-certificates
  else
    echo "❌ Cannot install tools - unknown package manager" >&2
    exit 5
  fi
  echo "✅ Tools installed in container"
}

# ============================================================================
# RPC CALL HELPERS
# ============================================================================

# JSON-RPC POST call (ETH, Sui)
rpc_post() {
  local container="$1"
  local url="$2"
  local method="$3"
  local params="${4:-[]}"

  exec_cmd "$container" curl -sS -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" \
    --connect-timeout 10 --max-time 30
}

# REST GET call (Cosmos, Beacon)
rpc_get() {
  local container="$1"
  local url="$2"

  exec_cmd "$container" curl -sS "$url" \
    --connect-timeout 10 --max-time 30
}

# ============================================================================
# PROTOCOL: ETH EXECUTION LAYER
# ============================================================================

eth_get_block_number() {
  local container="$1"
  local url="$2"

  local response
  response=$(rpc_post "$container" "$url" "eth_blockNumber")
  echo "$response" | jq -r '.result // empty' | xargs printf "%d" 2>/dev/null || echo ""
}

eth_get_block_hash() {
  local container="$1"
  local url="$2"
  local block_num="$3"

  local hex_block
  hex_block=$(printf "0x%x" "$block_num")

  local response
  response=$(rpc_post "$container" "$url" "eth_getBlockByNumber" "[\"$hex_block\",false]")
  echo "$response" | jq -r '.result.hash // empty'
}

eth_check_syncing() {
  local container="$1"
  local url="$2"

  local response
  response=$(rpc_post "$container" "$url" "eth_syncing")
  local result
  result=$(echo "$response" | jq -rc '.result')

  if [[ "$result" == "false" ]]; then
    echo "false"
  else
    echo "true"
  fi
}

check_evm() {
  local container="$1"
  local local_rpc="$2"
  local public_rpc="$3"

  # Check and display sync status
  echo "⏳ Sync status"
  local syncing
  syncing=$(eth_check_syncing "$container" "$local_rpc" 2>/dev/null) || {
    echo "❌ error: RPC unreachable ($local_rpc)"
    echo ""
    echo "❌ Final status: error"
    exit 3
  }
  print_sync_status "$syncing" "eth_syncing"

  # Get local block
  local local_block
  local_block=$(eth_get_block_number "$container" "$local_rpc")
  if [[ -z "$local_block" ]]; then
    echo "❌ error: Failed to get local block number" >&2
    echo ""
    echo "❌ Final status: error"
    exit 3
  fi

  # Get public block
  local public_block
  public_block=$(eth_get_block_number "" "$public_rpc")
  if [[ -z "$public_block" ]]; then
    echo "❌ error: Failed to get public block number" >&2
    echo ""
    echo "❌ Final status: error"
    exit 4
  fi

  local raw_lag=$((public_block - local_block))
  local lag=$raw_lag
  local lag_direction="local behind"
  if (( lag < 0 )); then
    lag=$(( -lag ))
    lag_direction="local ahead"
  fi

  echo ""
  echo "⏳ Head comparison"
  echo "Local head:  $local_block"
  echo "Public head: $public_block"
  echo "Lag:         $lag blocks (threshold: $BLOCK_LAG) ($lag_direction)"

  # Check if syncing (only if local is behind beyond threshold)
  if (( raw_lag > BLOCK_LAG )); then
    # Sample for ETA
    local start_block="$local_block"
    sleep "$SAMPLE_SECS"
    local end_block
    end_block=$(eth_get_block_number "$container" "$local_rpc")
    local blocks_advanced=$((end_block - start_block))

    if (( blocks_advanced > 0 )); then
      local current_lag=$((public_block - end_block))
      local rate
      rate=$(awk "BEGIN {printf \"%.2f\", $blocks_advanced / $SAMPLE_SECS}")
      # Assume chain grows at ~0.08 blocks/sec for ETH mainnet
      local effective_rate
      effective_rate=$(awk "BEGIN {r = $rate - 0.08; print (r > 0) ? r : 0.01}")
      local eta_secs
      eta_secs=$(awk "BEGIN {printf \"%.0f\", $current_lag / $effective_rate}")

      echo "ETA sample:  $rate blocks/sec -> ~$(format_eta "$eta_secs")"
    else
      echo "ETA sample:  n/a"
    fi

    echo ""
    echo "⏳ Final status: syncing"
    exit 1
  fi

  echo "ETA sample:  n/a"

  # In sync - verify hashes match
  echo ""
  echo "⏳ Latest block comparison"
  local local_hash public_hash
  local_hash=$(eth_get_block_hash "$container" "$local_rpc" "$local_block")
  public_hash=$(eth_get_block_hash "" "$public_rpc" "$local_block")

  # Truncate hashes for display
  local local_hash_short="${local_hash:0:10}..."
  local public_hash_short="${public_hash:0:10}..."

  echo "Local latest:  $local_block $local_hash_short"
  echo "Public latest: $public_block $public_hash_short"

  if [[ -n "$local_hash" && -n "$public_hash" && "$local_hash" != "$public_hash" ]]; then
    echo ""
    echo "❌ Hash mismatch at block $local_block" >&2
    echo "   Local:  $local_hash" >&2
    echo "   Public: $public_hash" >&2
    echo ""
    echo "❌ Final status: diverged (possible fork)"
    exit 2
  fi

  echo ""
  echo "✅ Final status: in sync"
  exit 0
}

# ============================================================================
# PROTOCOL: COSMOS/TENDERMINT
# ============================================================================

cosmos_get_status() {
  local container="$1"
  local url="$2"

  rpc_get "$container" "${url}/status"
}

check_cosmos() {
  local container="$1"
  local local_rpc="$2"
  local public_rpc="$3"

  echo "⏳ Sync status"

  # Get local status
  local local_status
  local_status=$(cosmos_get_status "$container" "$local_rpc" 2>/dev/null) || {
    echo "❌ error: RPC unreachable ($local_rpc)"
    echo ""
    echo "❌ Final status: error"
    exit 3
  }
  if [[ -z "$local_status" ]]; then
    echo "❌ error: Failed to get local status" >&2
    echo ""
    echo "❌ Final status: error"
    exit 3
  fi

  local local_height local_hash local_catching_up
  local_height=$(echo "$local_status" | jq -r '.result.sync_info.latest_block_height // .sync_info.latest_block_height')
  local_hash=$(echo "$local_status" | jq -r '.result.sync_info.latest_block_hash // .sync_info.latest_block_hash')
  local_catching_up=$(echo "$local_status" | jq -r '.result.sync_info.catching_up // .sync_info.catching_up')

  print_sync_status "$local_catching_up" "catching_up"

  # Get public status
  local public_status
  public_status=$(cosmos_get_status "" "$public_rpc")
  if [[ -z "$public_status" ]]; then
    echo "❌ error: Failed to get public status" >&2
    echo ""
    echo "❌ Final status: error"
    exit 4
  fi

  local public_height public_hash
  public_height=$(echo "$public_status" | jq -r '.result.sync_info.latest_block_height // .sync_info.latest_block_height')
  public_hash=$(echo "$public_status" | jq -r '.result.sync_info.latest_block_hash // .sync_info.latest_block_hash')

  local raw_lag=$((public_height - local_height))
  local lag=$raw_lag
  local lag_direction="local behind"
  if (( lag < 0 )); then
    lag=$(( -lag ))
    lag_direction="local ahead"
  fi

  echo ""
  echo "⏳ Height comparison"
  echo "Local height:  $local_height"
  echo "Public height: $public_height"
  echo "Lag:           $lag blocks (threshold: $BLOCK_LAG) ($lag_direction)"
  echo "ETA sample:    n/a"

  # Check catching_up flag
  if [[ "$local_catching_up" == "true" ]]; then
    echo ""
    echo "⏳ Final status: syncing"
    exit 1
  fi

  # Check lag (only if local is behind)
  if (( raw_lag > BLOCK_LAG )); then
    echo ""
    echo "⏳ Final status: syncing"
    exit 1
  fi

  # Check hash at same height
  if [[ "$local_height" == "$public_height" && "$local_hash" != "$public_hash" ]]; then
    echo ""
    echo "❌ Hash mismatch at height $local_height" >&2
    echo "   Local:  $local_hash" >&2
    echo "   Public: $public_hash" >&2
    echo ""
    echo "❌ Final status: diverged (possible fork)"
    exit 2
  fi

  echo ""
  echo "✅ Final status: in sync"
  exit 0
}

# ============================================================================
# PROTOCOL: BEACON CHAIN (CL)
# ============================================================================

check_beacon() {
  local container="$1"
  local local_rpc="$2"
  local public_rpc="$3"

  echo "⏳ Sync status"

  # Get local syncing status
  local local_response
  local_response=$(rpc_get "$container" "${local_rpc}/eth/v1/node/syncing" 2>/dev/null) || {
    echo "❌ error: RPC unreachable ($local_rpc)"
    echo ""
    echo "❌ Final status: error"
    exit 3
  }
  if [[ -z "$local_response" ]]; then
    echo "❌ error: Failed to get local sync status" >&2
    echo ""
    echo "❌ Final status: error"
    exit 3
  fi

  local head_slot sync_distance is_syncing is_optimistic
  head_slot=$(echo "$local_response" | jq -r '.data.head_slot')
  sync_distance=$(echo "$local_response" | jq -r '.data.sync_distance')
  is_syncing=$(echo "$local_response" | jq -r '.data.is_syncing')
  is_optimistic=$(echo "$local_response" | jq -r '.data.is_optimistic')

  print_sync_status "$is_syncing" "is_syncing"
  if [[ "$is_optimistic" == "true" ]]; then
    echo "⏳ is_optimistic: true"
  fi

  echo ""
  echo "⏳ Slot comparison"
  echo "Head slot:     $head_slot"
  echo "Sync distance: $sync_distance slots"
  echo "Lag:           $sync_distance slots (threshold: $BLOCK_LAG)"
  echo "ETA sample:    n/a"

  if [[ "$is_syncing" == "true" ]]; then
    echo ""
    echo "⏳ Final status: syncing"
    exit 1
  fi

  echo ""
  echo "✅ Final status: in sync"
  exit 0
}

# ============================================================================
# PROTOCOL: SUI
# ============================================================================

sui_get_checkpoint() {
  local container="$1"
  local url="$2"

  rpc_post "$container" "$url" "sui_getLatestCheckpointSequenceNumber" | jq -r '.result'
}

sui_get_checkpoint_digest() {
  local container="$1"
  local url="$2"
  local checkpoint="$3"

  rpc_post "$container" "$url" "sui_getCheckpoint" "[\"$checkpoint\"]" | jq -r '.result.digest'
}

check_sui() {
  local container="$1"
  local local_rpc="$2"
  local public_rpc="$3"

  echo "⏳ Sync status"

  # Get local checkpoint
  local local_cp
  local_cp=$(sui_get_checkpoint "$container" "$local_rpc" 2>/dev/null) || {
    echo "❌ error: RPC unreachable ($local_rpc)"
    echo ""
    echo "❌ Final status: error"
    exit 3
  }
  if [[ -z "$local_cp" ]]; then
    echo "❌ error: Failed to get local checkpoint" >&2
    echo ""
    echo "❌ Final status: error"
    exit 3
  fi

  # Get public checkpoint
  local public_cp
  public_cp=$(sui_get_checkpoint "" "$public_rpc")
  if [[ -z "$public_cp" ]]; then
    echo "❌ error: Failed to get public checkpoint" >&2
    echo ""
    echo "❌ Final status: error"
    exit 4
  fi

  local raw_lag=$((public_cp - local_cp))
  local lag=$raw_lag
  local lag_direction="local behind"
  local is_syncing="false"
  if (( lag < 0 )); then
    lag=$(( -lag ))
    lag_direction="local ahead"
  elif (( lag > BLOCK_LAG )); then
    is_syncing="true"
  fi

  print_sync_status "$is_syncing" "syncing"

  echo ""
  echo "⏳ Checkpoint comparison"
  echo "Local checkpoint:  $local_cp"
  echo "Public checkpoint: $public_cp"
  echo "Lag:               $lag checkpoints (threshold: $BLOCK_LAG) ($lag_direction)"
  echo "ETA sample:        n/a"

  if (( raw_lag > BLOCK_LAG )); then
    echo ""
    echo "⏳ Final status: syncing"
    exit 1
  fi

  # Verify digest at local checkpoint
  local local_digest public_digest
  local_digest=$(sui_get_checkpoint_digest "$container" "$local_rpc" "$local_cp")
  public_digest=$(sui_get_checkpoint_digest "" "$public_rpc" "$local_cp")

  if [[ -n "$local_digest" && -n "$public_digest" && "$local_digest" != "$public_digest" ]]; then
    echo ""
    echo "❌ Digest mismatch at checkpoint $local_cp" >&2
    echo "   Local:  $local_digest" >&2
    echo "   Public: $public_digest" >&2
    echo ""
    echo "❌ Final status: diverged (possible fork)"
    exit 2
  fi

  echo ""
  echo "✅ Final status: in sync"
  exit 0
}

# ============================================================================
# UTILITIES
# ============================================================================

format_eta() {
  local secs="$1"
  if (( secs < 60 )); then
    echo "${secs}s"
  elif (( secs < 3600 )); then
    echo "$((secs / 60))m $((secs % 60))s"
  elif (( secs < 86400 )); then
    echo "$((secs / 3600))h $((secs % 3600 / 60))m"
  else
    echo "$((secs / 86400))d $((secs % 86400 / 3600))h"
  fi
}

print_sync_status() {
  local is_syncing="$1"
  local label="${2:-Syncing}"  # default to generic "Syncing"
  if [[ "$is_syncing" == "true" ]]; then
    echo "⏳ ${label}: true"
  else
    echo "✅ ${label}: false"
  fi
}

# ============================================================================
# MAIN
# ============================================================================

main() {
  parse_args "$@"
  load_env

  local local_rpc public_rpc container
  local_rpc=$(resolve_local_rpc)
  public_rpc=$(resolve_public_rpc)
  container=$(resolve_container)

  # Validate public RPC
  if [[ -z "$public_rpc" ]]; then
    echo "ERROR: --public-rpc is required" >&2
    exit 6
  fi

  echo "Protocol:     $PROTOCOL"
  echo "Local RPC:    $local_rpc"
  echo "Public RPC:   $public_rpc"
  [[ -n "$container" ]] && echo "Container:    $container"
  echo "---"

  ensure_tools "$container"

  case "$PROTOCOL" in
    evm)
      check_evm "$container" "$local_rpc" "$public_rpc"
      ;;
    cosmos)
      check_cosmos "$container" "$local_rpc" "$public_rpc"
      ;;
    beacon)
      check_beacon "$container" "$local_rpc" "$public_rpc"
      ;;
    sui)
      check_sui "$container" "$local_rpc" "$public_rpc"
      ;;
    *)
      echo "ERROR: Unknown protocol: $PROTOCOL" >&2
      exit 6
      ;;
  esac
}

main "$@"

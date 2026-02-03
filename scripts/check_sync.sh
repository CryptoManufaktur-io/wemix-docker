#!/usr/bin/env bash
# Standardized sync check script template
# Supports: ETH Execution, Cosmos/Tendermint, Beacon CL, Sui, L2 Rollups
#
# Exit codes:
#   0 - In sync (within acceptable lag)
#   1 - Still syncing (beyond threshold)
#   2 - Error (RPC/tools/invalid args/diverged)

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
  2  Error (RPC/tools/invalid args/diverged)

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
        echo "❌ error: Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

# ============================================================================
# ENVIRONMENT LOADING
# ============================================================================

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  echo "$value"
}

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    return
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" == export\ * ]]; then
      line="${line#export }"
      line="$(trim "$line")"
    fi

    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      local key="${line%%=*}"
      local val="${line#*=}"
      key="$(trim "$key")"
      val="$(trim "$val")"

      if [[ "$val" == \"*\" && "$val" == *\" ]]; then
        val="${val:1:-1}"
      elif [[ "$val" == \'*\' && "$val" == *\' ]]; then
        val="${val:1:-1}"
      fi

      export "$key=$val"
    fi
  done <"$ENV_FILE"
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
      fail "Compose service '$COMPOSE_SERVICE' not found or not running"
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
      echo "⏳ Sync status"
      fail "curl and jq are required"
    fi
    echo "✅ Tools available in container"
    return
  fi

  # In container - check and install if needed
  if exec_cmd "$container" sh -c "command -v curl && command -v jq" &>/dev/null; then
    echo "✅ Tools available in container"
    return
  fi

  if [[ "$NO_INSTALL" == "true" ]]; then
    echo "⏳ Sync status"
    fail "curl/jq not found in container and --no-install specified"
  fi

  # Try apt-get first, then apk
  if exec_cmd "$container" sh -c "command -v apt-get" &>/dev/null; then
    exec_cmd "$container" apt-get update -qq
    exec_cmd "$container" apt-get install -qq -y curl jq ca-certificates
  elif exec_cmd "$container" sh -c "command -v apk" &>/dev/null; then
    exec_cmd "$container" apk add --no-cache curl jq ca-certificates
  else
    echo "⏳ Sync status"
    fail "Cannot install tools - unknown package manager"
  fi
  echo "✅ Tools available in container"
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

  local response result
  if ! response=$(rpc_post "$container" "$url" "eth_blockNumber"); then
    return 1
  fi
  result=$(jq_value "$response" '.result' "eth_blockNumber")
  [[ "$result" == "null" || -z "$result" ]] && echo "" && return
  printf "%d" "$result" 2>/dev/null || echo ""
}

eth_get_block_hash() {
  local container="$1"
  local url="$2"
  local block_num="$3"

  local hex_block
  hex_block=$(printf "0x%x" "$block_num")

  local response result
  if ! response=$(rpc_post "$container" "$url" "eth_getBlockByNumber" "[\"$hex_block\",false]"); then
    return 1
  fi
  result=$(jq_value "$response" '.result.hash' "eth_getBlockByNumber")
  [[ "$result" == "null" ]] && result=""
  echo "$result"
}

eth_check_syncing() {
  local container="$1"
  local url="$2"

  local response result
  if ! response=$(rpc_post "$container" "$url" "eth_syncing"); then
    return 1
  fi
  result=$(jq_value "$response" '.result' "eth_syncing")
  if [[ "$result" == "null" || -z "$result" ]]; then
    fail "Failed to parse eth_syncing"
  fi

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

  echo "⏳ Sync status"
  local syncing
  syncing=$(eth_check_syncing "$container" "$local_rpc" 2>/dev/null) || fail "RPC unreachable ($local_rpc)"
  print_eth_syncing "$syncing"

  # Get local block
  local local_block
  local_block=$(eth_get_block_number "$container" "$local_rpc") || fail "RPC unreachable ($local_rpc)"
  [[ -z "$local_block" ]] && fail "Failed to get local block number"

  # Get public block
  local public_block
  public_block=$(eth_get_block_number "" "$public_rpc") || fail "RPC unreachable ($public_rpc)"
  [[ -z "$public_block" ]] && fail "Failed to get public block number"

  local raw_lag=$((public_block - local_block))
  local lag=$raw_lag
  local lag_direction="local behind"
  if (( raw_lag == 0 )); then
    lag=0
    lag_direction="local in sync"
  elif (( raw_lag < 0 )); then
    lag=$(( -raw_lag ))
    lag_direction="local ahead"
  fi

  echo ""
  echo "⏳ Head comparison"
  echo "Local head:  $local_block"
  echo "Public head: $public_block"
  echo "Lag:         $lag blocks (threshold: $BLOCK_LAG) ($lag_direction)"
  local eta_line="n/a"
  if (( raw_lag > 0 )); then
    local start_block="$local_block"
    sleep "$SAMPLE_SECS"
    local end_block
    end_block=$(eth_get_block_number "$container" "$local_rpc" 2>/dev/null || true)
    if [[ -n "$end_block" ]]; then
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
        eta_line="$rate blocks/sec -> ~$(format_eta "$eta_secs")"
      fi
    fi
  fi
  echo "ETA sample:  $eta_line"

  # In sync - verify hashes match
  echo ""
  echo "⏳ Latest block comparison"
  local local_hash public_hash public_hash_at_local
  local_hash=$(eth_get_block_hash "$container" "$local_rpc" "$local_block") || fail "RPC unreachable ($local_rpc)"
  public_hash=$(eth_get_block_hash "" "$public_rpc" "$public_block") || fail "RPC unreachable ($public_rpc)"
  if (( public_block == local_block )); then
    public_hash_at_local="$public_hash"
  else
    public_hash_at_local=$(eth_get_block_hash "" "$public_rpc" "$local_block") || fail "RPC unreachable ($public_rpc)"
  fi

  echo "Local latest:  $local_block $(format_hash "$local_hash")"
  echo "Public latest: $public_block $(format_hash "$public_hash")"

  if [[ -n "$local_hash" && -n "$public_hash_at_local" && "$local_hash" != "$public_hash_at_local" ]]; then
    echo ""
    fail "Hash mismatch at block $local_block"
  fi

  echo ""
  if [[ "$syncing" == "true" ]] || (( raw_lag > BLOCK_LAG )); then
    exit_with_status syncing
  fi
  exit_with_status in_sync
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
  local_status=$(cosmos_get_status "$container" "$local_rpc" 2>/dev/null) || fail "RPC unreachable ($local_rpc)"
  [[ -z "$local_status" ]] && fail "Failed to get local status"

  local local_height local_hash local_catching_up
  local_height=$(jq_value "$local_status" '.result.sync_info.latest_block_height // .sync_info.latest_block_height' "cosmos local height")
  local_hash=$(jq_value "$local_status" '.result.sync_info.latest_block_hash // .sync_info.latest_block_hash' "cosmos local hash")
  local_catching_up=$(jq_value "$local_status" '.result.sync_info.catching_up // .sync_info.catching_up' "cosmos local catching_up")
  [[ -z "$local_height" ]] && fail "Failed to parse local height"

  # Get public status
  local public_status
  public_status=$(cosmos_get_status "" "$public_rpc") || fail "RPC unreachable ($public_rpc)"
  [[ -z "$public_status" ]] && fail "Failed to get public status"

  local public_height public_hash
  public_height=$(jq_value "$public_status" '.result.sync_info.latest_block_height // .sync_info.latest_block_height' "cosmos public height")
  public_hash=$(jq_value "$public_status" '.result.sync_info.latest_block_hash // .sync_info.latest_block_hash' "cosmos public hash")
  [[ -z "$public_height" ]] && fail "Failed to parse public height"

  local raw_lag=$((public_height - local_height))
  local lag=$raw_lag
  local lag_direction="local behind"
  if (( raw_lag == 0 )); then
    lag=0
    lag_direction="local in sync"
  elif (( raw_lag < 0 )); then
    lag=$(( -raw_lag ))
    lag_direction="local ahead"
  fi

  local sync_state="in_sync"
  if [[ "$local_catching_up" == "true" ]] || (( raw_lag > BLOCK_LAG )); then
    sync_state="syncing"
  fi
  print_sync_state "$sync_state"

  echo ""
  echo "⏳ Head comparison"
  echo "Local head:  $local_height"
  echo "Public head: $public_height"
  echo "Lag:         $lag blocks (threshold: $BLOCK_LAG) ($lag_direction)"
  echo "ETA sample:  n/a"

  # Check hash at same height
  echo ""
  echo "⏳ Latest block comparison"
  echo "Local latest:  $local_height $(format_hash "$local_hash")"
  echo "Public latest: $public_height $(format_hash "$public_hash")"

  if [[ "$local_height" == "$public_height" && -n "$local_hash" && -n "$public_hash" && "$local_hash" != "$public_hash" ]]; then
    echo ""
    fail "Hash mismatch at height $local_height"
  fi

  echo ""
  if [[ "$sync_state" == "syncing" ]]; then
    exit_with_status syncing
  fi
  exit_with_status in_sync
}

# ============================================================================
# PROTOCOL: BEACON CHAIN (CL)
# ============================================================================

beacon_get_syncing() {
  local container="$1"
  local url="$2"

  rpc_get "$container" "${url}/eth/v1/node/syncing"
}

beacon_get_head() {
  local container="$1"
  local url="$2"

  rpc_get "$container" "${url}/eth/v1/beacon/headers/head"
}

check_beacon() {
  local container="$1"
  local local_rpc="$2"
  local public_rpc="$3"

  echo "⏳ Sync status"

  # Get local syncing status
  local local_response
  local_response=$(beacon_get_syncing "$container" "$local_rpc" 2>/dev/null) || fail "RPC unreachable ($local_rpc)"
  [[ -z "$local_response" ]] && fail "Failed to get local sync status"

  local head_slot is_syncing is_optimistic
  head_slot=$(jq_value "$local_response" '.data.head_slot' "beacon local head_slot")
  is_syncing=$(jq_value "$local_response" '.data.is_syncing' "beacon local is_syncing")
  is_optimistic=$(jq_value "$local_response" '.data.is_optimistic' "beacon local is_optimistic")
  [[ -z "$head_slot" ]] && fail "Failed to parse local head slot"

  # Get public syncing status (for head slot)
  local public_response
  public_response=$(beacon_get_syncing "" "$public_rpc") || fail "Failed to get public sync status"
  [[ -z "$public_response" ]] && fail "Failed to get public sync status"

  local public_head_slot
  public_head_slot=$(jq_value "$public_response" '.data.head_slot' "beacon public head_slot")
  [[ -z "$public_head_slot" ]] && fail "Failed to parse public head slot"

  local raw_lag=$((public_head_slot - head_slot))
  local lag=$raw_lag
  local lag_direction="local behind"
  if (( raw_lag == 0 )); then
    lag=0
    lag_direction="local in sync"
  elif (( raw_lag < 0 )); then
    lag=$(( -raw_lag ))
    lag_direction="local ahead"
  fi

  local sync_state="in_sync"
  if [[ "$is_syncing" == "true" ]] || (( raw_lag > BLOCK_LAG )); then
    sync_state="syncing"
  fi
  print_sync_state "$sync_state"
  if [[ "$is_optimistic" == "true" ]]; then
    echo "⏳ is_optimistic: true"
  fi

  echo ""
  echo "⏳ Head comparison"
  echo "Local head:  $head_slot"
  echo "Public head: $public_head_slot"
  echo "Lag:         $lag slots (threshold: $BLOCK_LAG) ($lag_direction)"
  echo "ETA sample:  n/a"

  local local_head_response public_head_response
  local_head_response=$(beacon_get_head "$container" "$local_rpc" 2>/dev/null || true)
  public_head_response=$(beacon_get_head "" "$public_rpc" 2>/dev/null || true)

  local local_root public_root
  if [[ -n "$local_head_response" ]]; then
    local_root=$(jq_value "$local_head_response" '.data.root // empty' "beacon local head root")
  else
    local_root=""
  fi
  if [[ -n "$public_head_response" ]]; then
    public_root=$(jq_value "$public_head_response" '.data.root // empty' "beacon public head root")
  else
    public_root=""
  fi

  echo ""
  echo "⏳ Latest block comparison"
  echo "Local latest:  $head_slot $(format_hash "$local_root")"
  echo "Public latest: $public_head_slot $(format_hash "$public_root")"

  if [[ "$head_slot" == "$public_head_slot" && -n "$local_root" && -n "$public_root" && "$local_root" != "$public_root" ]]; then
    echo ""
    fail "Hash mismatch at slot $head_slot"
  fi

  echo ""
  if [[ "$sync_state" == "syncing" ]]; then
    exit_with_status syncing
  fi
  exit_with_status in_sync
}

# ============================================================================
# PROTOCOL: SUI
# ============================================================================

sui_get_checkpoint() {
  local container="$1"
  local url="$2"

  local response result
  if ! response=$(rpc_post "$container" "$url" "sui_getLatestCheckpointSequenceNumber"); then
    return 1
  fi
  result=$(jq_value "$response" '.result' "sui latest checkpoint")
  [[ "$result" == "null" ]] && result=""
  echo "$result"
}

sui_get_checkpoint_digest() {
  local container="$1"
  local url="$2"
  local checkpoint="$3"

  local response result
  if ! response=$(rpc_post "$container" "$url" "sui_getCheckpoint" "[\"$checkpoint\"]"); then
    return 1
  fi
  result=$(jq_value "$response" '.result.digest' "sui checkpoint digest")
  [[ "$result" == "null" ]] && result=""
  echo "$result"
}

check_sui() {
  local container="$1"
  local local_rpc="$2"
  local public_rpc="$3"

  echo "⏳ Sync status"

  # Get local checkpoint
  local local_cp
  local_cp=$(sui_get_checkpoint "$container" "$local_rpc" 2>/dev/null) || fail "RPC unreachable ($local_rpc)"
  [[ -z "$local_cp" ]] && fail "Failed to get local checkpoint"

  # Get public checkpoint
  local public_cp
  public_cp=$(sui_get_checkpoint "" "$public_rpc") || fail "RPC unreachable ($public_rpc)"
  [[ -z "$public_cp" ]] && fail "Failed to get public checkpoint"

  local raw_lag=$((public_cp - local_cp))
  local lag=$raw_lag
  local lag_direction="local behind"
  if (( raw_lag == 0 )); then
    lag=0
    lag_direction="local in sync"
  elif (( raw_lag < 0 )); then
    lag=$(( -raw_lag ))
    lag_direction="local ahead"
  fi

  local sync_state="in_sync"
  if (( raw_lag > BLOCK_LAG )); then
    sync_state="syncing"
  fi
  print_sync_state "$sync_state"

  echo ""
  echo "⏳ Head comparison"
  echo "Local head:  $local_cp"
  echo "Public head: $public_cp"
  echo "Lag:         $lag blocks (threshold: $BLOCK_LAG) ($lag_direction)"
  echo "ETA sample:  n/a"

  # Verify digest at local checkpoint
  local local_digest public_digest
  local_digest=$(sui_get_checkpoint_digest "$container" "$local_rpc" "$local_cp") || fail "RPC unreachable ($local_rpc)"
  public_digest=$(sui_get_checkpoint_digest "" "$public_rpc" "$local_cp") || fail "RPC unreachable ($public_rpc)"

  echo ""
  echo "⏳ Latest block comparison"
  echo "Local latest:  $local_cp $(format_hash "$local_digest")"
  echo "Public latest: $public_cp $(format_hash "$public_digest")"

  if [[ -n "$local_digest" && -n "$public_digest" && "$local_digest" != "$public_digest" ]]; then
    echo ""
    fail "Digest mismatch at checkpoint $local_cp"
  fi

  echo ""
  if [[ "$sync_state" == "syncing" ]]; then
    exit_with_status syncing
  fi
  exit_with_status in_sync
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

format_hash() {
  local hash="$1"
  if [[ -n "$hash" ]]; then
    echo "$hash"
  else
    echo "n/a"
  fi
}

exit_with_status() {
  local state="$1"
  case "$state" in
    in_sync)
      echo "✅ Final status: in sync"
      exit 0
      ;;
    syncing)
      echo "⏳ Final status: syncing"
      exit 1
      ;;
    error)
      echo "❌ Final status: error"
      exit 2
      ;;
    *)
      echo "❌ Final status: error"
      exit 2
      ;;
  esac
}

fail() {
  local message="$1"
  echo "❌ error: ${message}" >&2
  echo ""
  exit_with_status error
}

print_eth_syncing() {
  local is_syncing="$1"
  if [[ "$is_syncing" == "true" ]]; then
    echo "⏳ eth_syncing: true"
  else
    echo "✅ eth_syncing: false"
  fi
}

print_sync_state() {
  local state="$1"
  case "$state" in
    in_sync)
      echo "✅ sync_state: in_sync"
      ;;
    syncing)
      echo "⏳ sync_state: syncing"
      ;;
    *)
      echo "⚠️ sync_state: unknown"
      ;;
  esac
}

jq_value() {
  local response="$1"
  local filter="$2"
  local context="$3"
  local value

  if ! value=$(echo "$response" | jq -r "$filter" 2>/dev/null); then
    fail "JSON parse error ($context)"
  fi

  echo "$value"
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
    fail "--public-rpc is required"
  fi

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
      fail "Unknown protocol: $PROTOCOL"
      ;;
  esac
}

main "$@"

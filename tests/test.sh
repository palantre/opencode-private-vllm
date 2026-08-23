#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export PATH="$ROOT/tests/mock-bin:$PATH"
export MOCK_LOG="$TMP/runpodctl.log"
export MOCK_DELETED="$TMP/deleted"
export OPENCODE_GPU_CONFIG_DIR="$TMP/config"
export OPENCODE_GPU_STATE_DIR="$TMP/state"
export OPENCODE_GPU_MONITOR_INTERVAL_SECONDS=60
export OPENCODE_GPU_HEALTH_TIMEOUT_SECONDS=5
mkdir -p "$HOME" "$OPENCODE_GPU_CONFIG_DIR" "$OPENCODE_GPU_STATE_DIR"
printf '%s\n' test-private-key > "$OPENCODE_GPU_CONFIG_DIR/vllm-api-key"
cat > "$OPENCODE_GPU_CONFIG_DIR/config" <<'CONFIG'
RUNPOD_IMAGE=example.invalid/private-vllm:test
RUNPOD_MAX_PRICE_PER_HOUR=1.20
VLLM_IDLE_MINUTES=30
CONFIG

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_log() {
  grep -F -- "$1" "$MOCK_LOG" >/dev/null || fail "runpodctl arguments do not contain: $1"
}

bash -n "$ROOT/config/opencode-gpu.env.example"
"$ROOT/bin/opencode-gpu" up >/dev/null
[[ -r "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail 'up did not create state'
[[ $(jq -r '.pod_id' "$OPENCODE_GPU_STATE_DIR/state.json") == mock-pod-123 ]] || fail 'wrong Pod id'
[[ $(jq -r '.data_center' "$OPENCODE_GPU_STATE_DIR/state.json") == EUR-IS-2 ]] || fail 'Pod was not pinned to the EEA'
assert_log '--cloud-type SECURE'
assert_log '--data-center-ids EUR-IS-2'
assert_log '--ports 22/tcp'
assert_log 'KV_CACHE_DTYPE'
assert_log 'fp8'
if grep -F -- '8000/http' "$MOCK_LOG" >/dev/null; then
  fail 'vLLM HTTP port was exposed publicly'
fi
if grep -F -- 'test-private-key' "$MOCK_LOG" >/dev/null; then
  fail 'local provider key was sent to Runpod'
fi
"$ROOT/bin/opencode-gpu" status | jq -e '.tunnel == "running" and .idle_monitor == "running"' >/dev/null
"$ROOT/bin/opencode-gpu" down >/dev/null
[[ -e "$MOCK_DELETED" ]] || fail 'down did not terminate the Pod'
[[ ! -e "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail 'down retained state after confirmed deletion'

rm -f "$MOCK_DELETED"
"$ROOT/bin/opencode-gpu" up >/dev/null
export MOCK_DELETE_NOT_FOUND=1
"$ROOT/bin/opencode-gpu" down >/dev/null
unset MOCK_DELETE_NOT_FOUND
[[ ! -e "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail 'down retained state for an already-terminated Pod'

printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm:test' \
  'RUNPOD_MAX_PRICE_PER_HOUR=1.20' \
  'RUNPOD_NETWORK_VOLUME_ID=mock-volume-123' > "$OPENCODE_GPU_CONFIG_DIR/config"
plan=$("$ROOT/bin/opencode-gpu" plan)
jq -e '.data_center == "EUR-IS-2" and .network_volume == {id:"mock-volume-123",data_center:"EUR-IS-2",size_gb:50}' <<< "$plan" >/dev/null || \
  fail 'plan did not validate and report the network volume'
"$ROOT/bin/opencode-gpu" up >/dev/null
assert_log '--network-volume-id mock-volume-123'
assert_log '--volume-mount-path /workspace'
"$ROOT/bin/opencode-gpu" down >/dev/null

rm -f "$MOCK_DELETED"
export MOCK_CREATE_FAIL=1
if "$ROOT/bin/opencode-gpu" up >/dev/null 2>&1; then
  fail 'wait timeout unexpectedly succeeded'
fi
unset MOCK_CREATE_FAIL
[[ -e "$MOCK_DELETED" ]] || fail 'wait timeout orphaned its billable Pod'
[[ ! -e "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail 'wait timeout retained state after deletion'

rm -f "$MOCK_DELETED"
export OPENCODE_GPU_MONITOR_INTERVAL_SECONDS=1
printf '%s\n' 'RUNPOD_IMAGE=example.invalid/private-vllm:test' 'VLLM_IDLE_MINUTES=0' > "$OPENCODE_GPU_CONFIG_DIR/config"
"$ROOT/bin/opencode-gpu" up >/dev/null
for _ in 1 2 3 4 5; do
  [[ -e "$MOCK_DELETED" ]] && break
  sleep 1
done
[[ -e "$MOCK_DELETED" ]] || fail 'idle monitor did not terminate the Pod'
[[ ! -e "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail 'idle monitor retained state'

printf 'All lifecycle tests passed.\n'

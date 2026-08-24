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
RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RUNPOD_LLAMA_CPP_IMAGE=example.invalid/private-llama-cpp@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
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
plan=$(env -u OPENCODE_GPU_HEALTH_TIMEOUT_SECONDS "$ROOT/bin/opencode-gpu" plan)
jq -e '.engine == "vllm" and .startup_timeout_seconds == 1200' <<< "$plan" >/dev/null || \
  fail 'vLLM plan did not report its startup timeout'
"$ROOT/bin/opencode-gpu" up >/dev/null
[[ -r "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail 'up did not create state'
[[ $(jq -r '.pod_id' "$OPENCODE_GPU_STATE_DIR/state.json") == mock-pod-123 ]] || fail 'wrong Pod id'
[[ $(jq -r '.gpu' "$OPENCODE_GPU_STATE_DIR/state.json") == 'NVIDIA L40S' ]] || fail 'GPU priority was not preserved'
[[ $(jq -r '.engine' "$OPENCODE_GPU_STATE_DIR/state.json") == vllm ]] || fail 'L40S did not select vLLM'
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

export MOCK_GPU_SCENARIO=llama
printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_LLAMA_CPP_IMAGE=example.invalid/private-llama-cpp@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'RUNPOD_MAX_PRICE_PER_HOUR=1.20' > "$OPENCODE_GPU_CONFIG_DIR/config"
plan=$(env -u OPENCODE_GPU_HEALTH_TIMEOUT_SECONDS "$ROOT/bin/opencode-gpu" plan)
jq -e '.gpu == "NVIDIA GeForce RTX 5090" and .engine == "llama_cpp" and .max_model_len == 32768 and .startup_timeout_seconds == 3600 and (.image | startswith("example.invalid/private-llama-cpp@sha256:"))' <<< "$plan" >/dev/null || \
  fail 'RTX 5090 profile was not selected'

printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_LLAMA_CPP_IMAGE=example.invalid/private-llama-cpp@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'RUNPOD_GPU_IDS="NVIDIA GeForce RTX 4090"' \
  'RUNPOD_MAX_PRICE_PER_HOUR=1.20' > "$OPENCODE_GPU_CONFIG_DIR/config"
plan=$("$ROOT/bin/opencode-gpu" plan)
jq -e '.gpu == "NVIDIA GeForce RTX 4090" and .engine == "llama_cpp" and .max_model_len == 32768' <<< "$plan" >/dev/null || \
  fail 'RTX 4090 profile was not selected'

printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_LLAMA_CPP_IMAGE=example.invalid/private-llama-cpp@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'RUNPOD_MAX_PRICE_PER_HOUR=1.20' > "$OPENCODE_GPU_CONFIG_DIR/config"
: > "$MOCK_LOG"
"$ROOT/bin/opencode-gpu" up >/dev/null
[[ $(jq -r '.engine' "$OPENCODE_GPU_STATE_DIR/state.json") == llama_cpp ]] || fail 'RTX 5090 lifecycle did not retain its engine'
assert_log 'example.invalid/private-llama-cpp@sha256:'
assert_log 'MODEL_SHA256'
assert_log '115a859329b5f4e876bed5ed49225d8097d055783a81945004a80af2fb2703f8'
assert_log 'CONTEXT_SIZE'
benchmark=$("$ROOT/bin/opencode-gpu" benchmark)
jq -e '.engine == "llama_cpp" and .successful_requests == 20 and .completion_tokens == 200' <<< "$benchmark" >/dev/null || \
  fail 'llama.cpp benchmark did not aggregate successful requests'
export MOCK_COMPLETION_TOKENS=0
benchmark=$("$ROOT/bin/opencode-gpu" benchmark)
unset MOCK_COMPLETION_TOKENS
jq -e '.successful_requests == 20 and .completion_tokens == 0' <<< "$benchmark" >/dev/null || \
  fail 'llama.cpp benchmark rejected zero-token completions'
"$ROOT/bin/opencode-gpu" down >/dev/null

printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_LLAMA_CPP_IMAGE=ghcr.io/CHANGE_ME/opencode-private-llama-cpp:UNPUBLISHED' \
  'RUNPOD_GPU_IDS="NVIDIA GeForce RTX 5090"' \
  'RUNPOD_MAX_PRICE_PER_HOUR=1.20' > "$OPENCODE_GPU_CONFIG_DIR/config"
if output=$("$ROOT/bin/opencode-gpu" plan 2>&1); then
  fail 'plan accepted an unpublished llama.cpp image'
fi
[[ "$output" == *'none has a configured immutable engine image'* ]] || \
  fail 'plan misreported an invalid image as unavailable inventory'

export MOCK_GPU_SCENARIO=llama-a100
printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_LLAMA_CPP_IMAGE=ghcr.io/CHANGE_ME/opencode-private-llama-cpp:UNPUBLISHED' \
  'RUNPOD_MAX_PRICE_PER_HOUR=1.50' > "$OPENCODE_GPU_CONFIG_DIR/config"
plan=$("$ROOT/bin/opencode-gpu" plan)
jq -e '.gpu == "NVIDIA A100 80GB PCIe" and .engine == "vllm"' <<< "$plan" >/dev/null || \
  fail 'selection did not skip an unavailable llama.cpp image'

export MOCK_GPU_SCENARIO=a100
: > "$MOCK_LOG"
printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_LLAMA_CPP_IMAGE=example.invalid/private-llama-cpp@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'RUNPOD_MAX_PRICE_PER_HOUR=1.50' > "$OPENCODE_GPU_CONFIG_DIR/config"
"$ROOT/bin/opencode-gpu" up >/dev/null
[[ $(jq -r '.engine' "$OPENCODE_GPU_STATE_DIR/state.json") == vllm ]] || fail 'A100 did not select vLLM'
assert_log 'KV_CACHE_DTYPE'
assert_log 'auto'
"$ROOT/bin/opencode-gpu" down >/dev/null
unset MOCK_GPU_SCENARIO

rm -f "$MOCK_DELETED"
export MOCK_GPU_SCENARIO=llama
export OPENCODE_GPU_MONITOR_INTERVAL_SECONDS=1
printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_LLAMA_CPP_IMAGE=example.invalid/private-llama-cpp@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'VLLM_IDLE_MINUTES=0' > "$OPENCODE_GPU_CONFIG_DIR/config"
"$ROOT/bin/opencode-gpu" up >/dev/null
for _ in 1 2 3 4 5; do
  [[ -e "$MOCK_DELETED" ]] && break
  sleep 1
done
[[ -e "$MOCK_DELETED" ]] || fail 'llama.cpp idle monitor did not terminate the Pod'
[[ ! -e "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail 'llama.cpp idle monitor retained state'
unset MOCK_GPU_SCENARIO
export OPENCODE_GPU_MONITOR_INTERVAL_SECONDS=60

printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_LLAMA_CPP_IMAGE=example.invalid/private-llama-cpp@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
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
printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_LLAMA_CPP_IMAGE=example.invalid/private-llama-cpp@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'VLLM_IDLE_MINUTES=0' > "$OPENCODE_GPU_CONFIG_DIR/config"
"$ROOT/bin/opencode-gpu" up >/dev/null
for _ in 1 2 3 4 5; do
  [[ -e "$MOCK_DELETED" ]] && break
  sleep 1
done
[[ -e "$MOCK_DELETED" ]] || fail 'idle monitor did not terminate the Pod'
[[ ! -e "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail 'idle monitor retained state'

printf 'All lifecycle tests passed.\n'

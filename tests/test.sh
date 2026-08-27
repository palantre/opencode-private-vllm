#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export PATH="$ROOT/tests/mock-bin:$PATH"
export MOCK_LOG="$TMP/runpodctl.log"
export MOCK_GRAPHQL_LOG="$TMP/graphql.json"
export MOCK_CURL_HEADER_LOG="$TMP/curl-header.log"
export MOCK_SSH_LOG="$TMP/ssh.log"
export MOCK_LIST_COUNT="$TMP/list-count"
export MOCK_PENDING_SEEN="$TMP/pending-seen"
export MOCK_DELETED="$TMP/deleted"
export OPENCODE_GPU_CONFIG_DIR="$TMP/config"
export OPENCODE_GPU_STATE_DIR="$TMP/state"
export OPENCODE_GPU_MONITOR_INTERVAL_SECONDS=60
export OPENCODE_GPU_HEALTH_TIMEOUT_SECONDS=5
export OPENCODE_GPU_RECONCILE_ATTEMPTS=4
export OPENCODE_GPU_RECONCILE_INTERVAL_SECONDS=0
export RUNPOD_CLINICAL_APPROVED_IMAGE_DIGESTS=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mkdir -p "$HOME/.runpod" "$OPENCODE_GPU_CONFIG_DIR" "$OPENCODE_GPU_STATE_DIR"
printf '%s\n' test-private-key > "$OPENCODE_GPU_CONFIG_DIR/vllm-api-key"
printf '%s\n' "apikey = 'mock-api-key'" "apiurl = 'https://api.runpod.io/graphql'" > "$HOME/.runpod/config.toml"
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
plan=$(env -u OPENCODE_GPU_HEALTH_TIMEOUT_SECONDS -u RUNPOD_MIN_DOWNLOAD_MBPS "$ROOT/bin/opencode-gpu" plan)
jq -e '.clinical_mode == true and .engine == "vllm" and .startup_timeout_seconds == 1200 and .min_download_mbps == 100' <<< "$plan" >/dev/null || \
  fail 'vLLM plan did not report its startup timeout'
export RUNPOD_MIN_DOWNLOAD_MBPS=0
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
assert_log 'CLINICAL_MODE'
assert_log '/var/lib/opencode-gpu/huggingface'
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
export RUNPOD_MIN_DOWNLOAD_MBPS=200
"$ROOT/bin/opencode-gpu" up >/dev/null
[[ -e "$MOCK_PENDING_SEEN" ]] || fail 'GraphQL create did not persist pending ownership before the mutation'
jq -e '.variables.input.minDownload == 200 and .variables.input.startSsh == true and .variables.input.ports == "22/tcp" and .variables.input.terminateAfter != null' "$MOCK_GRAPHQL_LOG" >/dev/null || \
  fail 'GraphQL create did not include the bandwidth and lifecycle constraints'
[[ $(<"$MOCK_CURL_HEADER_LOG") == 'Authorization: Bearer mock-api-key' ]] || \
  fail 'GraphQL create did not load the Runpod credential as an authorization header'
if grep -F -- 'mock-api-key' "$MOCK_GRAPHQL_LOG" >/dev/null; then
  fail 'GraphQL create leaked the Runpod credential into its payload'
fi
grep -F -- ' true ' "$MOCK_SSH_LOG" >/dev/null || fail 'GraphQL create did not probe SSH before tunneling'
"$ROOT/bin/opencode-gpu" down >/dev/null
export RUNPOD_MIN_DOWNLOAD_MBPS=0

export RUNPOD_MIN_DOWNLOAD_MBPS=200
export MOCK_GRAPHQL_UNREACHABLE=1
if "$ROOT/bin/opencode-gpu" up >/dev/null 2>&1; then
  fail 'unreachable GraphQL request unexpectedly succeeded'
fi
unset MOCK_GRAPHQL_UNREACHABLE
[[ ! -e "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail 'unsent GraphQL request retained false pending state'
export RUNPOD_MIN_DOWNLOAD_MBPS=0

export RUNPOD_MIN_DOWNLOAD_MBPS=200
export MOCK_GRAPHQL_REJECTED=1
if "$ROOT/bin/opencode-gpu" up >/dev/null 2>&1; then
  fail 'rejected GraphQL request unexpectedly succeeded'
fi
unset MOCK_GRAPHQL_REJECTED
[[ ! -e "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail 'rejected GraphQL request retained false pending state'
export RUNPOD_MIN_DOWNLOAD_MBPS=0

export RUNPOD_MIN_DOWNLOAD_MBPS=200
export MOCK_GRAPHQL_AMBIGUOUS=1
for curl_status in 27 80; do
  rm -f "$MOCK_DELETED"
  export MOCK_GRAPHQL_AMBIGUOUS_STATUS=$curl_status
  if "$ROOT/bin/opencode-gpu" up >/dev/null 2>&1; then
    fail "ambiguous curl status $curl_status unexpectedly succeeded"
  fi
  [[ -e "$MOCK_DELETED" ]] || fail "ambiguous curl status $curl_status orphaned its billable Pod"
  [[ ! -e "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail "ambiguous curl status $curl_status retained state after cleanup"
done
unset MOCK_GRAPHQL_AMBIGUOUS MOCK_GRAPHQL_AMBIGUOUS_STATUS
export RUNPOD_MIN_DOWNLOAD_MBPS=0

rm -f "$MOCK_DELETED"
export RUNPOD_MIN_DOWNLOAD_MBPS=200
export MOCK_GRAPHQL_AMBIGUOUS=1
export MOCK_LIST_HIDDEN_ATTEMPTS=2
rm -f "$MOCK_LIST_COUNT"
if "$ROOT/bin/opencode-gpu" up >/dev/null 2>&1; then
  fail 'ambiguous GraphQL create unexpectedly succeeded'
fi
unset MOCK_GRAPHQL_AMBIGUOUS
unset MOCK_LIST_HIDDEN_ATTEMPTS
if [[ ! -e "$MOCK_DELETED" ]]; then
  printf 'Reconcile calls: %s\n' "$(<"$MOCK_LIST_COUNT")" >&2
  [[ ! -r "$OPENCODE_GPU_STATE_DIR/state.json" ]] || jq . "$OPENCODE_GPU_STATE_DIR/state.json" >&2
  fail 'ambiguous GraphQL create orphaned its billable Pod'
fi
[[ ! -e "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail 'ambiguous GraphQL cleanup retained state'
export MOCK_GRAPHQL_AMBIGUOUS=1
export MOCK_LIST_FAIL=1
if "$ROOT/bin/opencode-gpu" up >/dev/null 2>&1; then
  fail 'unreconciled GraphQL create unexpectedly succeeded'
fi
unset MOCK_GRAPHQL_AMBIGUOUS MOCK_LIST_FAIL
[[ $(jq -r '.pending_pod_name // empty' "$OPENCODE_GPU_STATE_DIR/state.json") == opencode-private-gpu-* ]] ||
  fail 'unreconciled GraphQL create did not retain pending state'
if "$ROOT/bin/opencode-gpu" down >/dev/null 2>&1; then
  fail 'pending GraphQL state was cleared before finding the Pod or reaching hard termination'
fi
[[ -e "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail 'unconfirmed GraphQL cleanup discarded pending state'
export MOCK_GRAPHQL_AMBIGUOUS=1
"$ROOT/bin/opencode-gpu" down >/dev/null
unset MOCK_GRAPHQL_AMBIGUOUS
[[ ! -e "$OPENCODE_GPU_STATE_DIR/state.json" ]] || fail 'pending GraphQL state was not cleared after successful reconciliation'
export MOCK_GRAPHQL_AMBIGUOUS=1
export MOCK_DELETE_FAIL=1
if "$ROOT/bin/opencode-gpu" up >/dev/null 2>&1; then
  fail 'GraphQL create with failed orphan deletion unexpectedly succeeded'
fi
unset MOCK_GRAPHQL_AMBIGUOUS MOCK_DELETE_FAIL
[[ $(jq -r '.pod_id // empty' "$OPENCODE_GPU_STATE_DIR/state.json") == mock-pod-123 ]] ||
  fail 'failed GraphQL orphan deletion discarded the known Pod id'
"$ROOT/bin/opencode-gpu" down >/dev/null
export RUNPOD_MIN_DOWNLOAD_MBPS=08
if "$ROOT/bin/opencode-gpu" plan >/dev/null 2>&1; then
  fail 'plan accepted a download threshold with a leading zero'
fi
export RUNPOD_MIN_DOWNLOAD_MBPS=2147483648
if "$ROOT/bin/opencode-gpu" plan >/dev/null 2>&1; then
  fail 'plan accepted a download threshold above GraphQL Int range'
fi
export RUNPOD_MIN_DOWNLOAD_MBPS=0
export OPENCODE_GPU_RECONCILE_ATTEMPTS=0
if "$ROOT/bin/opencode-gpu" plan >/dev/null 2>&1; then
  fail 'plan accepted zero GraphQL reconciliation attempts'
fi
export OPENCODE_GPU_RECONCILE_ATTEMPTS=4

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

export MOCK_GPU_SCENARIO=pro6000-mig
printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_GPU_IDS="NVIDIA RTX PRO 6000 Blackwell Server Edition MIG 2g.48gb"' \
  'RUNPOD_MAX_PRICE_PER_HOUR=1.20' > "$OPENCODE_GPU_CONFIG_DIR/config"
plan=$("$ROOT/bin/opencode-gpu" plan)
jq -e '.gpu == "NVIDIA RTX PRO 6000 Blackwell Server Edition MIG 2g.48gb" and .engine == "vllm"' <<< "$plan" >/dev/null || \
  fail 'RTX PRO 6000 MIG 48 GB profile was not selected'
unset MOCK_GPU_SCENARIO

export MOCK_GPU_SCENARIO=default
printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_LLAMA_CPP_IMAGE=example.invalid/private-llama-cpp@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'RUNPOD_FORCE_LLAMA_CPP=1' \
  'RUNPOD_MAX_PRICE_PER_HOUR=1.20' > "$OPENCODE_GPU_CONFIG_DIR/config"
plan=$("$ROOT/bin/opencode-gpu" plan)
jq -e '.gpu == "NVIDIA L40S" and .engine == "llama_cpp" and .model == "Chungulus/Qwen3.8-27B-Q4_K_M-GGUF"' <<< "$plan" >/dev/null || \
  fail 'forced llama.cpp profile did not route L40S to Q4_K_M'
unset MOCK_GPU_SCENARIO

export MOCK_GPU_SCENARIO=pro4500
printf '%s\n' \
  'RUNPOD_LLAMA_CPP_IMAGE=example.invalid/private-llama-cpp@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'RUNPOD_FORCE_LLAMA_CPP=1' \
  'RUNPOD_GPU_IDS="NVIDIA RTX PRO 4500 Blackwell"' \
  'RUNPOD_MAX_PRICE_PER_HOUR=1.20' > "$OPENCODE_GPU_CONFIG_DIR/config"
plan=$("$ROOT/bin/opencode-gpu" plan)
jq -e '.gpu == "NVIDIA RTX PRO 4500 Blackwell" and .engine == "llama_cpp" and .max_model_len == 32768' <<< "$plan" >/dev/null || \
  fail 'forced llama.cpp profile did not route RTX PRO 4500 Blackwell to Q4_K_M'
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
if "$ROOT/bin/opencode-gpu" plan >/dev/null 2>&1; then
  fail 'clinical mode accepted a writable vLLM cache on a network volume'
fi
printf '%s\n' 'RUNPOD_CLINICAL_MODE=0' >> "$OPENCODE_GPU_CONFIG_DIR/config"
plan=$("$ROOT/bin/opencode-gpu" plan)
jq -e '.clinical_mode == false and .data_center == "EUR-IS-2" and .network_volume == {id:"mock-volume-123",data_center:"EUR-IS-2",size_gb:50,mount_access:"read-write",purpose:"unrestricted",inference_access:"read-write"}' <<< "$plan" >/dev/null || \
  fail 'plan did not validate and report the network volume'
"$ROOT/bin/opencode-gpu" up >/dev/null
assert_log '--network-volume-id mock-volume-123'
assert_log '--volume-mount-path /workspace'
"$ROOT/bin/opencode-gpu" down >/dev/null

printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_LLAMA_CPP_IMAGE=example.invalid/private-llama-cpp@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'RUNPOD_FORCE_LLAMA_CPP=1' \
  'RUNPOD_NETWORK_VOLUME_ID=mock-volume-123' > "$OPENCODE_GPU_CONFIG_DIR/config"
plan=$("$ROOT/bin/opencode-gpu" plan)
jq -e '.clinical_mode == true and .engine == "llama_cpp" and .network_volume.mount_access == "read-write" and .network_volume.purpose == "model-cache-only" and .network_volume.inference_access == "read-only"' <<< "$plan" >/dev/null || \
  fail 'clinical llama.cpp plan did not restrict the network volume to the model cache'
: > "$MOCK_LOG"
"$ROOT/bin/opencode-gpu" up >/dev/null
assert_log 'CLINICAL_MODE'
assert_log '/workspace/llama.cpp'
"$ROOT/bin/opencode-gpu" down >/dev/null

printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_CLINICAL_MODE=yes' > "$OPENCODE_GPU_CONFIG_DIR/config"
if "$ROOT/bin/opencode-gpu" plan >/dev/null 2>&1; then
  fail 'plan accepted an invalid clinical-mode value'
fi

export RUNPOD_CLINICAL_APPROVED_IMAGE_DIGESTS=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$OPENCODE_GPU_CONFIG_DIR/config"
if "$ROOT/bin/opencode-gpu" plan >/dev/null 2>&1; then
  fail 'clinical mode accepted an image without an approved controls digest'
fi
export RUNPOD_CLINICAL_APPROVED_IMAGE_DIGESTS=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

printf '%s\n' \
  'RUNPOD_IMAGE=example.invalid/private-vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'RUNPOD_LLAMA_CPP_IMAGE=example.invalid/private-llama-cpp@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'RUNPOD_MAX_PRICE_PER_HOUR=1.20' > "$OPENCODE_GPU_CONFIG_DIR/config"
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

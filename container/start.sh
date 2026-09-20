#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_ID:=Qwen/Qwen3.8-27B-FP8}"
: "${MODEL_REVISION:=017b9c7af6b5689d5dd426a76e0bc077eb5ca20a}"
: "${SERVED_MODEL_NAME:=qwen3.8-27b-fp8}"
: "${SERVER_PORT:=8000}"
: "${MAX_MODEL_LEN:=131072}"
: "${MAX_NUM_SEQS:=16}"
: "${MODEL_CACHE_DIR:=/root/.cache/huggingface}"
: "${KV_CACHE_DTYPE:=fp8}"
: "${CLINICAL_MODE:=1}"

[[ "$CLINICAL_MODE" == 0 || "$CLINICAL_MODE" == 1 ]] || {
  printf 'CLINICAL_MODE must be 0 or 1.\n' >&2
  exit 1
}
if [[ "$CLINICAL_MODE" == 1 && "$MODEL_CACHE_DIR" == /workspace/* ]]; then
  printf 'Clinical mode does not permit a writable vLLM cache on a network volume.\n' >&2
  exit 1
fi

mkdir -p "$MODEL_CACHE_DIR" /var/log/opencode-gpu
export HF_HOME="$MODEL_CACHE_DIR"
if [[ "$CLINICAL_MODE" == 1 ]]; then
  chown -R inference:inference "$MODEL_CACHE_DIR"
  export HOME=/var/lib/opencode-gpu
  export TMPDIR=/var/lib/opencode-gpu/tmp
fi

if [[ -n "${PUBLIC_KEY:-}" ]]; then
  printf '%s\n' "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

ssh-keygen -A
/usr/sbin/sshd -t
/usr/sbin/sshd

exec > >(tee -a /var/log/opencode-gpu/vllm.log) 2>&1
server=(vllm serve "$MODEL_ID"
  --revision "$MODEL_REVISION" \
  --served-model-name "$SERVED_MODEL_NAME" \
  --host 127.0.0.1 \
  --port "$SERVER_PORT" \
  --dtype auto \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --kv-cache-dtype "$KV_CACHE_DTYPE" \
  --language-model-only \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder)

if [[ "$CLINICAL_MODE" == 1 ]]; then
  exec gosu inference "${server[@]}"
else
  exec "${server[@]}"
fi

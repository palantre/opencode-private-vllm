#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_ID:=Qwen/Qwen3.8-27B-FP8}"
: "${MODEL_REVISION:=017b9c7af6b5689d5dd426a76e0bc077eb5ca20a}"
: "${SERVED_MODEL_NAME:=qwen3.8-27b-fp8}"
: "${SERVER_PORT:=8000}"
: "${MAX_MODEL_LEN:=32768}"
: "${MODEL_CACHE_DIR:=/root/.cache/huggingface}"
: "${KV_CACHE_DTYPE:=fp8}"

mkdir -p "$MODEL_CACHE_DIR" /var/log/opencode-gpu
export HF_HOME="$MODEL_CACHE_DIR"

if [[ -n "${PUBLIC_KEY:-}" ]]; then
  printf '%s\n' "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

ssh-keygen -A
/usr/sbin/sshd -t
/usr/sbin/sshd

exec > >(tee -a /var/log/opencode-gpu/vllm.log) 2>&1
exec vllm serve "$MODEL_ID" \
  --revision "$MODEL_REVISION" \
  --served-model-name "$SERVED_MODEL_NAME" \
  --host 127.0.0.1 \
  --port "$SERVER_PORT" \
  --dtype auto \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-seqs 16 \
  --kv-cache-dtype "$KV_CACHE_DTYPE" \
  --language-model-only \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder

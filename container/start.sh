#!/usr/bin/env bash
set -euo pipefail

: "${VLLM_API_KEY:?VLLM_API_KEY is required}"
: "${VLLM_MODEL:=Qwen/Qwen3.8-27B-FP8}"
: "${VLLM_REVISION:=017b9c7af6b5689d5dd426a76e0bc077eb5ca20a}"
: "${VLLM_SERVED_MODEL:=qwen3.8-27b-fp8}"
: "${VLLM_PORT:=8000}"
: "${VLLM_MAX_MODEL_LEN:=32768}"
: "${MODEL_CACHE_DIR:=/root/.cache/huggingface}"

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
exec vllm serve "$VLLM_MODEL" \
  --revision "$VLLM_REVISION" \
  --served-model-name "$VLLM_SERVED_MODEL" \
  --host 127.0.0.1 \
  --port "$VLLM_PORT" \
  --api-key "$VLLM_API_KEY" \
  --dtype auto \
  --max-model-len "$VLLM_MAX_MODEL_LEN" \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder

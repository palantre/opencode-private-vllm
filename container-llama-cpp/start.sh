#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_URL:=https://huggingface.co/Chungulus/Qwen3.8-27B-Q4_K_M-GGUF/resolve/5ae8e19376c871fd4fccd956a967f58b1598c8aa/Qwen3.8-27B-Q4_K_M.gguf}"
: "${MODEL_FILE:=Qwen3.8-27B-Q4_K_M.gguf}"
: "${MODEL_SHA256:=115a859329b5f4e876bed5ed49225d8097d055783a81945004a80af2fb2703f8}"
: "${SERVED_MODEL_NAME:=qwen3.8-27b-fp8}"
: "${SERVER_PORT:=8000}"
: "${CONTEXT_SIZE:=32768}"
: "${PARALLEL:=1}"
: "${MODEL_CACHE_DIR:=/root/.cache/llama.cpp}"
: "${CACHE_TYPE:=q8_0}"

mkdir -p "$MODEL_CACHE_DIR" /var/log/opencode-gpu
model_path="$MODEL_CACHE_DIR/$MODEL_FILE"
partial_path="$model_path.partial"

exec > >(tee -a /var/log/opencode-gpu/llama-cpp.log) 2>&1

if [[ -n "${PUBLIC_KEY:-}" ]]; then
  printf '%s\n' "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

ssh-keygen -A
/usr/sbin/sshd -t
/usr/sbin/sshd

if [[ ! -f "$model_path" ]] || ! printf '%s  %s\n' "$MODEL_SHA256" "$model_path" | sha256sum --check --status; then
  rm -f "$model_path"
  if [[ ! -f "$partial_path" ]] || ! printf '%s  %s\n' "$MODEL_SHA256" "$partial_path" | sha256sum --check --status; then
    if ! curl --location --fail --show-error --retry 5 --retry-all-errors \
        --continue-at - --output "$partial_path" "$MODEL_URL"; then
      rm -f "$partial_path"
      curl --location --fail --show-error --retry 5 --retry-all-errors \
        --output "$partial_path" "$MODEL_URL"
    fi
  fi
  printf '%s  %s\n' "$MODEL_SHA256" "$partial_path" | sha256sum --check --status || {
    rm -f "$partial_path"
    printf 'Model checksum verification failed.\n' >&2
    exit 1
  }
  mv "$partial_path" "$model_path"
fi
exec /app/llama-server \
  --model "$model_path" \
  --alias "$SERVED_MODEL_NAME" \
  --host 127.0.0.1 \
  --port "$SERVER_PORT" \
  --ctx-size "$CONTEXT_SIZE" \
  --parallel "$PARALLEL" \
  --n-gpu-layers all \
  --fit off \
  --flash-attn on \
  --cache-type-k "$CACHE_TYPE" \
  --cache-type-v "$CACHE_TYPE" \
  --no-mmproj \
  --jinja \
  --metrics \
  --no-webui

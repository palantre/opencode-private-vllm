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
: "${CLINICAL_MODE:=1}"

[[ "$CLINICAL_MODE" == 0 || "$CLINICAL_MODE" == 1 ]] || {
  printf 'CLINICAL_MODE must be 0 or 1.\n' >&2
  exit 1
}
[[ "$MODEL_FILE" != */* && "$MODEL_FILE" != . && "$MODEL_FILE" != .. ]] || {
  printf 'MODEL_FILE must be a basename.\n' >&2
  exit 1
}

mkdir -p "$MODEL_CACHE_DIR" /var/log/opencode-gpu
model_path="$MODEL_CACHE_DIR/$MODEL_FILE"
partial_path="$model_path.partial"

clinical_validate_volume() {
  [[ "$CLINICAL_MODE" == 1 && "$MODEL_CACHE_DIR" == /workspace/* ]] || return 0
  if find /workspace -mindepth 1 -maxdepth 1 ! -path "$MODEL_CACHE_DIR" -print -quit | grep -q .; then
    printf 'Clinical mode requires a dedicated model-only volume; unexpected top-level content was not deleted.\n' >&2
    exit 1
  fi
  if find "$MODEL_CACHE_DIR" -mindepth 1 -maxdepth 1 \
      ! -name "$MODEL_FILE" ! -name "$MODEL_FILE.partial" -print -quit | grep -q .; then
    printf 'Clinical mode found unexpected model-cache content and did not delete it.\n' >&2
    exit 1
  fi
}

clinical_cleanup() {
  [[ "$CLINICAL_MODE" == 1 && "$MODEL_CACHE_DIR" == /workspace/* ]] || return 0
  find /workspace -mindepth 1 -maxdepth 1 ! -path "$MODEL_CACHE_DIR" -exec rm -rf -- {} +
  find "$MODEL_CACHE_DIR" -mindepth 1 -maxdepth 1 ! -name "$MODEL_FILE" -exec rm -rf -- {} +
}

clinical_validate_volume

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
rm -f "$partial_path"

server=(/app/llama-server
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
  --no-webui)

if [[ "$CLINICAL_MODE" == 0 ]]; then
  exec "${server[@]}"
fi

server+=(--no-cache-prompt --cache-ram 0 --no-slots --log-disable)
clinical_cleanup
chown root:root "$MODEL_CACHE_DIR" "$model_path"
chmod 0555 "$MODEL_CACHE_DIR"
chmod 0444 "$model_path"
if [[ "$MODEL_CACHE_DIR" == /workspace/* ]]; then
  chown root:root /workspace
  chmod 0555 /workspace
fi
if gosu inference test -w "$MODEL_CACHE_DIR" || gosu inference test -w "$model_path"; then
  printf 'Clinical mode could not make the model cache read-only for the inference user.\n' >&2
  exit 1
fi

export HOME=/var/lib/opencode-gpu
export TMPDIR=/var/lib/opencode-gpu/tmp
gosu inference "${server[@]}" &
server_pid=$!
terminate_server() {
  kill -TERM "$server_pid" 2>/dev/null || true
  terminate_requested=1
}
terminate_requested=0
trap terminate_server TERM INT
while :; do
  if wait "$server_pid"; then
    server_status=0
    break
  else
    server_status=$?
  fi
  [[ "$terminate_requested" == 1 ]] && kill -0 "$server_pid" 2>/dev/null && continue
  break
done
trap - TERM INT
clinical_cleanup
exit "$server_status"

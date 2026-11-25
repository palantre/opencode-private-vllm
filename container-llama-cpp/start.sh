#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_URL:=https://huggingface.co/Chungulus/Qwen3.8-27B-Q4_K_M-GGUF/resolve/5ae8e19376c871fd4fccd956a967f58b1598c8aa/Qwen3.8-27B-Q4_K_M.gguf}"
: "${MODEL_FILE:=Qwen3.8-27B-Q4_K_M.gguf}"
: "${MODEL_SHA256:=115a859329b5f4e876bed5ed49225d8097d055783a81945004a80af2fb2703f8}"
: "${MMPROJ_URL:=https://huggingface.co/Chungulus/Qwen3.8-27B-Q4_K_M-GGUF/resolve/5ae8e19376c871fd4fccd956a967f58b1598c8aa/mmproj-Qwen3.8-27B-F16.gguf}"
: "${MMPROJ_FILE:=mmproj-Qwen3.8-27B-F16.gguf}"
: "${MMPROJ_SHA256:=1d5398ec531eb7652d661af5548cd3b699794bf0d3fdc72c49ac696e8eda9bd7}"
: "${SERVED_MODEL_NAME:=qwen3.8-27b-fp8}"
: "${SERVER_PORT:=8000}"
: "${CONTEXT_SIZE:=131072}"
: "${PARALLEL:=1}"
: "${MODEL_CACHE_DIR:=/root/.cache/llama.cpp}"
: "${CACHE_TYPE:=q8_0}"
: "${CLINICAL_MODE:=1}"

[[ "$CLINICAL_MODE" == 0 || "$CLINICAL_MODE" == 1 ]] || {
  printf 'CLINICAL_MODE must be 0 or 1.\n' >&2
  exit 1
}
for artifact in MODEL MMPROJ; do
  file_var="${artifact}_FILE"
  sha_var="${artifact}_SHA256"
  [[ "${!file_var}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || {
    printf '%s must be a safe basename.\n' "$file_var" >&2
    exit 1
  }
  [[ "${!sha_var}" =~ ^[a-fA-F0-9]{64}$ ]] || {
    printf '%s must be a SHA-256 digest.\n' "$sha_var" >&2
    exit 1
  }
done
[[ "$MODEL_FILE" != "$MMPROJ_FILE" && "$MODEL_FILE.partial" != "$MMPROJ_FILE" && "$MMPROJ_FILE.partial" != "$MODEL_FILE" ]] || {
  printf 'Model and projector filenames must not overlap.\n' >&2
  exit 1
}

mkdir -p "$MODEL_CACHE_DIR" /var/log/opencode-gpu
model_path="$MODEL_CACHE_DIR/$MODEL_FILE"
partial_path="$model_path.partial"
mmproj_path="$MODEL_CACHE_DIR/$MMPROJ_FILE"
mmproj_partial_path="$mmproj_path.partial"

clinical_validate_volume() {
  local unexpected candidate
  [[ "$CLINICAL_MODE" == 1 && "$MODEL_CACHE_DIR" == /workspace/* ]] || return 0
  [[ "$MODEL_CACHE_DIR" == /workspace/llama.cpp ]] || {
    printf 'Clinical mode requires MODEL_CACHE_DIR=/workspace/llama.cpp on a network volume.\n' >&2
    exit 1
  }
  [[ -d /workspace && ! -L /workspace && -d "$MODEL_CACHE_DIR" && ! -L "$MODEL_CACHE_DIR" ]] || {
    printf 'Clinical mode requires real, non-symlink workspace and model-cache directories.\n' >&2
    exit 1
  }
  if ! unexpected=$(find /workspace -mindepth 1 -maxdepth 1 ! -path "$MODEL_CACHE_DIR" -print -quit); then
    printf 'Clinical mode could not audit the network-volume root.\n' >&2
    exit 1
  fi
  if [[ -n "$unexpected" ]]; then
    printf 'Clinical mode requires a dedicated model-only volume; unexpected top-level content was not deleted.\n' >&2
    exit 1
  fi
  if ! unexpected=$(find "$MODEL_CACHE_DIR" -mindepth 1 -maxdepth 1 \
      ! -name "$MODEL_FILE" ! -name "$MODEL_FILE.partial" \
      ! -name "$MMPROJ_FILE" ! -name "$MMPROJ_FILE.partial" -print -quit); then
    printf 'Clinical mode could not audit the model cache.\n' >&2
    exit 1
  fi
  if [[ -n "$unexpected" ]]; then
    printf 'Clinical mode found unexpected model-cache content and did not delete it.\n' >&2
    exit 1
  fi
  for candidate in "$model_path" "$partial_path" "$mmproj_path" "$mmproj_partial_path"; do
    [[ ! -L "$candidate" && ( ! -e "$candidate" || -f "$candidate" ) ]] || {
      printf 'Clinical mode permits only regular model and partial files.\n' >&2
      exit 1
    }
  done
}

clinical_cleanup() {
  [[ "$CLINICAL_MODE" == 1 && "$MODEL_CACHE_DIR" == /workspace/* ]] || return 0
  find /workspace -mindepth 1 -maxdepth 1 ! -path "$MODEL_CACHE_DIR" -exec rm -rf -- {} +
  find "$MODEL_CACHE_DIR" -mindepth 1 -maxdepth 1 \
    ! -name "$MODEL_FILE" ! -name "$MMPROJ_FILE" -exec rm -rf -- {} +
}

download_artifact() {
  local path=$1 sha=$2 url=$3 partial="$1.partial"
  if [[ ! -f "$path" ]] || ! printf '%s  %s\n' "$sha" "$path" | sha256sum --check --status; then
    rm -f "$path"
    if [[ ! -f "$partial" ]] || ! printf '%s  %s\n' "$sha" "$partial" | sha256sum --check --status; then
      if ! curl --location --fail --show-error --retry 5 --retry-all-errors \
          --continue-at - --output "$partial" "$url"; then
        rm -f "$partial"
        curl --location --fail --show-error --retry 5 --retry-all-errors \
          --output "$partial" "$url"
      fi
    fi
    printf '%s  %s\n' "$sha" "$partial" | sha256sum --check --status || {
      rm -f "$partial"
      printf 'Artifact checksum verification failed.\n' >&2
      exit 1
    }
    mv "$partial" "$path"
  fi
  rm -f "$partial"
}

prepare_cache_for_download() {
  [[ "$CLINICAL_MODE" == 1 ]] || return 0
  # A reused network cache was sealed 0555 by the previous session. Network
  # filesystems can enforce that mode even for container root. Only root gets
  # temporary write access; inference has not started and remains unprivileged.
  chown root:root "$MODEL_CACHE_DIR"
  chmod 0755 "$MODEL_CACHE_DIR"
}

clinical_validate_volume
prepare_cache_for_download

exec > >(tee -a /var/log/opencode-gpu/llama-cpp.log) 2>&1

if [[ -n "${PUBLIC_KEY:-}" ]]; then
  printf '%s\n' "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

ssh-keygen -A
/usr/sbin/sshd -t
/usr/sbin/sshd

download_artifact "$model_path" "$MODEL_SHA256" "$MODEL_URL"
download_artifact "$mmproj_path" "$MMPROJ_SHA256" "$MMPROJ_URL"

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
  --mmproj "$mmproj_path" \
  --jinja \
  --metrics \
  --no-webui)

if [[ "$CLINICAL_MODE" == 0 ]]; then
  exec "${server[@]}"
fi

server+=(--no-cache-prompt --cache-ram 0 --no-slots --log-disable)
clinical_cleanup
chown root:root "$MODEL_CACHE_DIR" "$model_path" "$mmproj_path"
chmod 0555 "$MODEL_CACHE_DIR"
chmod 0444 "$model_path" "$mmproj_path"
if [[ "$MODEL_CACHE_DIR" == /workspace/* ]]; then
  chown root:root /workspace
  chmod 0555 /workspace
fi
if gosu inference test -w "$MODEL_CACHE_DIR" || gosu inference test -w "$model_path" || gosu inference test -w "$mmproj_path"; then
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

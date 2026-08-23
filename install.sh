#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode-gpu"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/opencode-gpu"
OPENCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
OPENCODE_CONFIG="$OPENCODE_DIR/opencode.jsonc"
AGENT_DIR="$OPENCODE_DIR/agents"
APPLICATION_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

for command in jq openssl; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  }
done

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$STATE_DIR" "$AGENT_DIR" "$APPLICATION_DIR"
install -m 0755 "$ROOT/bin/opencode-gpu" "$BIN_DIR/opencode-gpu"
install -m 0755 "$ROOT/bin/opencode-gpu-desktop" "$BIN_DIR/opencode-gpu-desktop"
install -m 0644 "$ROOT/config/private-gpu-agent.md" "$AGENT_DIR/private-gpu.md"
install -m 0644 "$ROOT/desktop/opencode-gpu-start.desktop" "$APPLICATION_DIR/opencode-gpu-start.desktop"
install -m 0644 "$ROOT/desktop/opencode-gpu-stop.desktop" "$APPLICATION_DIR/opencode-gpu-stop.desktop"

if [[ ! -e "$CONFIG_DIR/config" ]]; then
  install -m 0600 "$ROOT/config/opencode-gpu.env.example" "$CONFIG_DIR/config"
fi
if [[ ! -e "$CONFIG_DIR/vllm-api-key" ]]; then
  umask 077
  openssl rand -hex 32 > "$CONFIG_DIR/vllm-api-key"
fi
chmod 600 "$CONFIG_DIR/config" "$CONFIG_DIR/vllm-api-key"

if [[ ! -e "$OPENCODE_CONFIG" ]]; then
  printf '%s\n' '{"$schema":"https://opencode.ai/config.json"}' > "$OPENCODE_CONFIG"
fi
if ! jq empty "$OPENCODE_CONFIG" >/dev/null 2>&1; then
  printf 'Refusing to edit %s: comments or trailing commas require a manual merge.\n' "$OPENCODE_CONFIG" >&2
  printf 'Provider and agent files were otherwise installed.\n' >&2
  exit 1
fi

tmp=$(mktemp "$OPENCODE_DIR/opencode.jsonc.XXXXXX")
jq --arg key_file "$CONFIG_DIR/vllm-api-key" '
  .share = "disabled"
  | .provider."runpod-private" = {
      name: "Runpod private Qwen",
      npm: "@ai-sdk/openai-compatible",
      options: {
        baseURL: "http://127.0.0.1:18000/v1",
        apiKey: ("{file:" + $key_file + "}"),
        timeout: false
      },
      models: {
        "qwen3.8-27b-fp8": {
          name: "Qwen3.8 27B (private Runpod)",
          reasoning: true,
          tool_call: true,
          temperature: true,
          limit: {context: 32768, output: 8192}
        }
      }
    }
' "$OPENCODE_CONFIG" > "$tmp"
chmod --reference="$OPENCODE_CONFIG" "$tmp"
mv "$tmp" "$OPENCODE_CONFIG"

command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database "$APPLICATION_DIR" >/dev/null 2>&1 || true

printf 'Installed opencode-gpu.\n'
printf 'Lifecycle configuration: %s\n' "$CONFIG_DIR/config"
printf 'Restart OpenCode to load the provider and private-gpu agent.\n'

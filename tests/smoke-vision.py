"""Opt-in real vision check using only an in-memory synthetic red PNG."""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import urllib.error
import urllib.request
import zlib


def red_png():
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\0\0" * 64) * 64))
            + chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:18000/v1")
    parser.add_argument("--key-file", type=Path)
    parser.add_argument("--model", default="qwen3.8-27b-fp8")
    args = parser.parse_args()
    key_file = args.key_file
    if key_file is None:
        controller = shutil.which("opencode-gpu")
        if controller:
            resolved = subprocess.run(
                [controller, "provider-key-path"], capture_output=True,
                text=True, timeout=10,
            )
            if resolved.returncode == 0 and resolved.stdout.strip():
                key_file = Path(resolved.stdout.strip())
        if key_file is None:
            key_file = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "opencode-gpu/vllm-api-key"
    try:
        key = key_file.read_text().strip()
    except OSError:
        raise SystemExit("Local provider key unavailable; pass --key-file explicitly. No image sent.")
    if not key:
        raise SystemExit("Local provider key is empty. No image sent.")
    payload = {
        "model": args.model,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": "What is the dominant color? Answer with one English color word."},
            {"type": "image_url", "image_url": {
                "url": "data:image/png;base64," + base64.b64encode(red_png()).decode(),
            }},
        ]}],
        "max_tokens": 256, "temperature": 0,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    request = urllib.request.Request(
        args.base_url.rstrip("/") + "/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + key},
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Vision check failed: HTTP {error.code}; response body not logged.")
    except (urllib.error.URLError, TimeoutError):
        raise SystemExit("Vision check failed: connection unavailable or timed out.")
    except (ValueError, OSError):
        raise SystemExit("Vision check failed: unreadable response; response body not logged.")
    choices = result.get("choices") if isinstance(result, dict) else None
    message = choices[0].get("message") if isinstance(choices, list) and choices and isinstance(choices[0], dict) else None
    content = message.get("content", "") if isinstance(message, dict) else ""
    if not isinstance(content, str) or content.strip().lower().strip(" .!\"'") != "red":
        raise SystemExit("Vision check failed: expected red; response content not logged.")
    print("PASS: synthetic red image recognized; no image or response content saved.")


if __name__ == "__main__":
    main()

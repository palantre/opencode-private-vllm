"""Opt-in real vision check using only an in-memory synthetic red PNG."""
import argparse
import base64
import json
from pathlib import Path
import struct
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
    parser.add_argument("--key-file", type=Path,
                        default=Path.home() / ".config/opencode-gpu/vllm-api-key")
    parser.add_argument("--model", default="qwen3.8-27b-fp8")
    args = parser.parse_args()
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
                 "Authorization": "Bearer " + args.key_file.read_text().strip()},
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Vision check failed: HTTP {error.code}; response body not logged.")
    except (urllib.error.URLError, TimeoutError):
        raise SystemExit("Vision check failed: connection unavailable or timed out.")
    content = result.get("choices", [{}])[0].get("message", {}).get("content", "")
    if not isinstance(content, str) or content.strip().lower().strip(" .!\"'") != "red":
        raise SystemExit("Vision check failed: expected red; response content not logged.")
    print("PASS: synthetic red image recognized; no image or response content saved.")


if __name__ == "__main__":
    main()

"""Loopback-only check of the vision verifier, not real model inference."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]


class VisionVerifier(unittest.TestCase):
    def test_configured_key_path_and_synthetic_request(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key = root / "custom provider key"
            key.write_text("synthetic-secret")
            controller = root / "opencode-gpu"
            controller.write_text('#!/bin/sh\n[ "$1" = provider-key-path ] || exit 1\nprintf "%s\\n" "$SYNTHETIC_KEY_PATH"\n')
            controller.chmod(0o755)
            requests = []

            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass

                def do_POST(self):
                    payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    requests.append((self.path, self.headers.get("Authorization"), payload))
                    data = json.dumps({"choices": [{"message": {"content": "red"}}]}).encode()
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)

            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                result = subprocess.run(
                    ["python3", str(ROOT / "tests/smoke-vision.py"),
                     "--base-url", f"http://127.0.0.1:{server.server_port}/v1"],
                    env=dict(os.environ, PATH=str(root) + ":" + os.environ["PATH"],
                             SYNTHETIC_KEY_PATH=str(key)),
                    capture_output=True, text=True, timeout=10,
                )
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("synthetic-secret", result.stdout + result.stderr)
            self.assertEqual(len(requests), 1)
            path, auth, payload = requests[0]
            self.assertEqual(path, "/v1/chat/completions")
            self.assertEqual(auth, "Bearer synthetic-secret")
            image = payload["messages"][0]["content"][1]["image_url"]["url"]
            self.assertTrue(image.startswith("data:image/png;base64,"))
            self.assertNotIn(image, result.stdout + result.stderr)
            self.assertIn("PASS", result.stdout)

    def test_missing_key_fails_without_traceback_or_request(self):
        result = subprocess.run(
            ["python3", str(ROOT / "tests/smoke-vision.py"),
             "--key-file", "/nonexistent/synthetic-key"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No image sent", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()

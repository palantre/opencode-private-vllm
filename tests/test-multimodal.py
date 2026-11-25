"""Offline artifact/cache checks; these do not prove real vision inference."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "container-llama-cpp/start.sh").read_text()


def function(name):
    start = SOURCE.index(f"\n{name}() {{") + 1
    return SOURCE[start:SOURCE.index("\n}\n", start) + 3]


class Multimodal(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.workspace = self.root / "workspace"
        self.cache = self.workspace / "llama.cpp"
        self.cache.mkdir(parents=True)
        self.model = self.cache / "model.gguf"
        self.projector = self.cache / "mmproj.gguf"
        self.model.write_bytes(b"synthetic language weights")
        self.projector.write_bytes(b"synthetic visual weights")

    def shell(self, body, success=True):
        # Only replace the hardcoded volume root in the isolated functions;
        # never operate on the real /workspace or invoke sshd/the real server.
        funcs = "\n".join(function(name) for name in [
            "clinical_validate_volume", "clinical_cleanup", "download_artifact",
        ]).replace("/workspace", str(self.workspace))
        env = dict(os.environ, CLINICAL_MODE="1", MODEL_CACHE_DIR=str(self.cache),
                   MODEL_FILE=self.model.name, MMPROJ_FILE=self.projector.name,
                   model_path=str(self.model), partial_path=str(self.model) + ".partial",
                   mmproj_path=str(self.projector),
                   mmproj_partial_path=str(self.projector) + ".partial")
        result = subprocess.run(
            ["bash", "-c", "set -euo pipefail\n" + funcs + "\n" + body],
            env=env, capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result

    def test_cache_accepts_both_artifacts_and_partials(self):
        Path(str(self.model) + ".partial").write_bytes(b"partial")
        Path(str(self.projector) + ".partial").write_bytes(b"partial")
        self.shell("clinical_validate_volume")

    def test_cache_rejects_unexpected_files_without_deleting_them(self):
        unexpected = self.cache / "private-image.png"
        unexpected.write_bytes(b"synthetic canary")
        self.shell("clinical_validate_volume", success=False)
        self.assertTrue(unexpected.exists())

    def test_cache_rejects_projector_symlinks(self):
        self.projector.unlink()
        self.projector.symlink_to(self.model)
        self.shell("clinical_validate_volume", success=False)
        self.assertTrue(self.projector.is_symlink())

    def test_cleanup_preserves_model_and_projector(self):
        partial = Path(str(self.projector) + ".partial")
        partial.write_bytes(b"partial")
        canary = self.workspace / "synthetic-runtime-canary"
        canary.write_bytes(b"ephemeral")
        self.shell("clinical_cleanup")
        self.assertTrue(self.model.exists())
        self.assertTrue(self.projector.exists())
        self.assertFalse(partial.exists())
        self.assertFalse(canary.exists())

    def test_valid_cached_projector_needs_no_download(self):
        sha = hashlib.sha256(self.projector.read_bytes()).hexdigest()
        self.shell(f"""
curl() {{ exit 99; }}
download_artifact "$mmproj_path" "{sha}" https://example.invalid/pinned
""")

    def test_completed_partial_is_verified_and_promoted(self):
        data = self.projector.read_bytes()
        self.projector.unlink()
        Path(str(self.projector) + ".partial").write_bytes(data)
        sha = hashlib.sha256(data).hexdigest()
        self.shell(f"""
curl() {{ exit 99; }}
download_artifact "$mmproj_path" "{sha}" https://example.invalid/pinned
""")
        self.assertEqual(self.projector.read_bytes(), data)
        self.assertFalse(Path(str(self.projector) + ".partial").exists())

    def test_bad_projector_download_never_becomes_final(self):
        self.projector.unlink()
        self.shell("""
curl() {
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --output ]]; then
      printf 'corrupt fixture' > "$2"
      return 0
    fi
    shift
  done
  return 1
}
download_artifact "$mmproj_path" \
  0000000000000000000000000000000000000000000000000000000000000000 \
  https://example.invalid/pinned
""", success=False)
        self.assertFalse(self.projector.exists())
        self.assertFalse(Path(str(self.projector) + ".partial").exists())
        self.assertEqual(self.model.read_bytes(), b"synthetic language weights")

    def test_server_loads_projector_and_keeps_clinical_restrictions(self):
        self.assertIn('--mmproj "$mmproj_path"', SOURCE)
        self.assertNotIn("--no-mmproj", SOURCE)
        for flag in ["--log-disable", "--no-cache-prompt", "--no-slots",
                     "--cache-ram 0", 'chmod 0444 "$model_path" "$mmproj_path"']:
            self.assertIn(flag, SOURCE)


if __name__ == "__main__":
    unittest.main()

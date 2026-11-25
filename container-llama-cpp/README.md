# llama.cpp with vision

This image starts the existing loopback-only llama-server and SSH service.
It loads both the GGUF language model and its vision projector with `--mmproj`.
The controller exposes only SSH (`22/tcp`), forwards inference through the local
tunnel, and retains the existing idle/absolute local watchdogs.

## Pinned artifacts

Both files are from `Chungulus/Qwen3.8-27B-Q4_K_M-GGUF`, revision
`5ae8e19376c871fd4fccd956a967f58b1598c8aa`:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `Qwen3.8-27B-Q4_K_M.gguf` | 16810714496 | `115a859329b5f4e876bed5ed49225d8097d055783a81945004a80af2fb2703f8` |
| `mmproj-Qwen3.8-27B-F16.gguf` | 927607040 | `1d5398ec531eb7652d661af5548cd3b699794bf0d3fdc72c49ac696e8eda9bd7` |

Source: the [pinned model card](https://huggingface.co/Chungulus/Qwen3.8-27B-Q4_K_M-GGUF/blob/5ae8e19376c871fd4fccd956a967f58b1598c8aa/README.md)
and the repository's LFS metadata. The publisher reports vision validation with
these files; this does not prove inference with our pinned CUDA image or GPU.
Do not substitute a projector from another model.

Artifacts download at first startup to `MODEL_CACHE_DIR`, using resumable partial
files and SHA-256 checks before atomic rename. Verified cached artifacts are reused.
The existing 30 GB cache can hold both (17.74 GB total); budget additional space
for temporary downloads. Storage size is not a VRAM requirement: vision adds
memory use, and the configured 131072 context is not a tested vision-fit guarantee.

Container variables: `MODEL_URL`, `MODEL_FILE`, `MODEL_SHA256`,
`MMPROJ_URL`, `MMPROJ_FILE`, `MMPROJ_SHA256`, `MODEL_CACHE_DIR`,
`SERVED_MODEL_NAME`, `SERVER_PORT`, `CONTEXT_SIZE`, `PARALLEL`, `CACHE_TYPE`,
`CLINICAL_MODE`. Defaults are pinned in `start.sh`. The controller generates both
URLs from the same model repository/revision, and passes `LLAMA_CPP_MMPROJ_FILE`
and `LLAMA_CPP_MMPROJ_SHA256` through to the container.

## Clinical controls

With `CLINICAL_MODE=1`, a mounted model cache must be `/workspace/llama.cpp`.
Only the model, projector and their partial files are accepted at startup;
unexpected content or symlinks are rejected without deleting them.
The inference process runs unprivileged with a read-only cache containing both
verified artifacts. Prompt caching, slot persistence and server logging remain
disabled. Cleanup preserves both artifacts and removes transient volume content
only after the child server has stopped. Do not store input images on this volume.
Use only synthetic images for verification.

## Build and rollout

The existing `.github/workflows/container.yml` builds **linux/amd64** on GitHub,
publishes a new image, checks flags, and tests clinical isolation with fake weights
and a fake server. Those tests do not prove actual vision inference.
No model weights or input images are copied into the image.

The previously approved image digest is text-only and **does not gain vision by
changing environment variables**. After building and reviewing the new image:

1. Record its immutable manifest digest and verify its platform/CUDA compatibility
   (the project's minimum for llama.cpp remains CUDA 12.8).
2. Review the clinical controls and add only that new digest to the approved list.
   Do not remove the digest allowlist or other policies.
3. Pin `RUNPOD_LLAMA_CPP_IMAGE` to the new `ghcr.io/...@sha256:...` in the
   persistent config. Update the installed controller from the reviewed source,
   preserving the provider, private agent, credentials and configuration.
4. Stop any old managed session with `gpu-stop` and confirm cleanup. Run `gpu-start`
   for a fresh plan, approve its current cost, then `gpu-start --confirm`.
   There is no remote auto-termination guarantee if the Pi loses power/network.
5. Once `gpu-status` is `ready`, run from the project root:

   ```bash
   python3 tests/smoke-vision.py
   ```

The check sends an in-memory synthetic red PNG to the loopback endpoint and
requires the answer `red`; it saves neither the image nor response content.
Use `--key-file` if the local provider key lives elsewhere. After testing, stop
the managed session with `gpu-stop`; retained model storage keeps billing.

## Checks without GPU or Docker

```bash
bash -n container-llama-cpp/start.sh
python3 tests/test-multimodal.py
bash tests/test.sh
```

Offline tests cover cache reuse, checksum rejection, partial-file promotion,
projector preservation, symlink/unexpected-file rejection and server flag wiring.
Build, real projector loading, target-GPU fit and end-to-end vision remain
unverified until the rebuilt image passes the live synthetic check.

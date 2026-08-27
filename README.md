# Private OpenCode GPU on Runpod

This project creates an occasional EU/EEA Runpod Secure Cloud GPU, selects the
inference engine and pinned Qwen artifact for that GPU, and connects OpenCode
through a local SSH tunnel. Large-memory GPUs use vLLM with official FP8 weights;
RTX 5090/4090 use llama.cpp with a verified Q4_K_M GGUF. The inference HTTP port
is never published by Runpod.

## Safety Status

The mocked lifecycle and both real synthetic-data paths have been validated.
The vLLM/FP8 route passed on a Secure Cloud L40S in `EUR-IS-2` on 2026-08-23.
The llama.cpp/Q4_K_M route passed on a Secure Cloud RTX 4090 in `EU-RO-1` on
2026-08-24. Startup, SSH-only forwarding, OpenAI chat completions, structured
tool calls, the OpenCode agent, benchmarking, and explicit termination completed
successfully. Mocked tests cover idle termination for both engines. No Pod or
network volume was left running.

Do not process clinical or identifiable data until your organization has
approved Runpod for that purpose and reviewed or signed the applicable DPA.
Use synthetic data for initial tests. OneDrive authorization does not by itself
authorize sending file contents or prompts to Runpod.

## Architecture

```text
OpenCode -> http://127.0.0.1:18000/v1
         -> SSH local forwarding
         -> 127.0.0.1:8000 inside the Pod
         -> vLLM/FP8 or llama.cpp/Q4_K_M
```

Only `22/tcp` is requested from Runpod. Both servers bind to remote `127.0.0.1`; the
local provider key satisfies the OpenAI client but is not sent to Runpod as a
server secret. The CLI selects a preferred GPU only when it has
reported stock in an allowed `EU-*` or `EUR-*` datacenter, pins creation there, and
uses `--cloud-type SECURE`.

Two independent cost guards are used:

- A local monitor terminates the Pod after 30 minutes without completed or
  active inference requests.
- Runpod receives a hard `--terminate-after` timestamp, four hours by default,
  in case the laptop disconnects or the local monitor fails.

`down` always terminates rather than stops the Pod. A network volume, when
configured, remains separately billable after Pod termination.

## Prerequisites

- `runpodctl` 2.11 or newer, `jq`, `curl`, OpenSSH, OpenSSL, and OpenCode.
- A Runpod account with billing configured.
- A Runpod API key configured with `runpodctl doctor` or exported as
  `RUNPOD_API_KEY`.
- An SSH public key recognized by Runpod.
- The published vLLM image; the llama.cpp image built from
  `container-llama-cpp/Dockerfile` is additionally required for RTX 5090/4090.

The current machine already has the required local CLI tools except Docker.
The included GitHub Actions workflow can build both images without local Docker.

## Build The Image

Create a GitHub repository from this directory and run the **Build private
inference images** workflow. It publishes two SHA tags such as:

```text
ghcr.io/OWNER/opencode-private-vllm:0123456
ghcr.io/OWNER/opencode-private-llama-cpp:0123456
```

Make both GHCR packages public, or create Runpod registry credentials and put
their ID in `RUNPOD_REGISTRY_AUTH_ID`. Both base images are pinned by digest.
Resolve each published SHA tag to its manifest digest and set
`RUNPOD_LLAMA_CPP_IMAGE` before enabling RTX 5090/4090 placement. For local
builds on a machine with Docker:

```bash
docker build -t ghcr.io/OWNER/opencode-private-vllm:0.1.0 container
docker build -t ghcr.io/OWNER/opencode-private-llama-cpp:0.1.0 container-llama-cpp
docker push ghcr.io/OWNER/opencode-private-vllm:0.1.0
docker push ghcr.io/OWNER/opencode-private-llama-cpp:0.1.0
```

## Install

```bash
./install.sh
```

This installs:

- `~/.local/bin/opencode-gpu`
- `~/.local/bin/opencode-gpu-desktop`
- `~/.config/opencode-gpu/config`
- A generated `0600` local provider key
- The global `runpod-private` OpenCode provider
- The global `private-gpu` primary agent
- Start and stop desktop launchers

The installer sets OpenCode sharing globally to `disabled`. The private agent
defaults every tool category to deny and allows only local file/search/edit,
questions, and task-list operations. This blocks shell, web, delegated agents,
skills, and project-added MCP tools. Review `opencode debug agent private-gpu`
before any approved clinical use.

Quit and restart OpenCode after installation because configuration is loaded
only at startup.

## Configure

Both published images are pinned to immutable manifest digests. The CLI rejects
mutable image tags for every engine. Defaults are:

- GPUs, in order: L40S, RTX 6000 Ada, L40, RTX 5090, RTX 4090, A100 80 GB PCIe,
  A100 SXM4 80 GB
- Secure Cloud EU/EEA placement only
- Maximum GPU price: `$1.50/hour`
- Minimum advertised host download speed: 100 Mbps
- L40S/RTX 6000 Ada/L40: `Qwen/Qwen3.8-27B-FP8` at revision
  `017b9c7af6b5689d5dd426a76e0bc077eb5ca20a`, vLLM, 32,768-token context,
  16 sequences, and FP8 KV cache
- A100 80 GB: the same official FP8 artifact and vLLM profile, but KV cache
  `auto` because the validated A100 run failed with FP8 KV
- RTX 5090/4090: `Chungulus/Qwen3.8-27B-Q4_K_M-GGUF` at revision
  `5ae8e19376c871fd4fccd956a967f58b1598c8aa`, llama.cpp, 32,768-token context,
  one slot, and Q8 KV cache
- GGUF file SHA-256:
  `115a859329b5f4e876bed5ed49225d8097d055783a81945004a80af2fb2703f8`;
  startup refuses bytes that do not match
- Idle termination: 30 minutes
- Startup readiness timeout: 20 minutes for vLLM and 60 minutes for llama.cpp
- Hard session termination: 240 minutes

Set `RUNPOD_FORCE_LLAMA_CPP=1` to serve the same Q4_K_M artifact on every
configured 5090, 4090, RTX PRO 4500 Blackwell, RTX 6000 Ada, L40, L40S, RTX
A6000, or A100 fallback.
This is useful when those GPU types share one persistent GGUF cache; the default
remains `0`, preserving the vLLM/FP8 profiles on 48 GB and 80 GB GPUs.

The stable OpenAI model ID remains `qwen3.8-27b-fp8` for compatibility with the
installed OpenCode provider, even when the selected backend serves Q4_K_M. It is
an API routing alias in this project, not a claim about the active quantization.
The installer preserves an existing lifecycle config; existing installations
must update `RUNPOD_GPU_IDS` explicitly to opt into the expanded GPU list.
The default `$1.50/hour` ceiling currently allows the A100 80 GB PCIe list price
but excludes A100 SXM4 80 GB at `$1.59/hour`; current Runpod inventory and prices
remain authoritative.

Runpod's current `runpodctl pod create` command does not expose the scheduler's
download-speed constraint. When `RUNPOD_MIN_DOWNLOAD_MBPS` is greater than zero,
the lifecycle CLI creates the Pod through Runpod GraphQL and sends that value as
`minDownload`; all later reads, SSH handling, and deletion still use
`runpodctl`. Set it to `0` to use `runpodctl` for creation as well. The threshold
filters on host network capability reported to the scheduler; it does not
guarantee real-time end-to-end throughput to Hugging Face or eliminate CDN and
network-volume bottlenecks.

Check actual stock and prices before the first session:

```bash
runpodctl gpu list --include-unavailable
runpodctl datacenter list
```

The CLI refuses stock outside configured EU/EEA prefixes and prices above the
configured ceiling. Runpod availability and pricing remain the final source of
truth.

## Use

```bash
opencode-gpu plan
opencode-gpu up
opencode-gpu status
opencode-gpu logs
opencode-gpu benchmark
opencode-gpu down
```

`plan` queries current inventory and prints the exact allowed GPU, datacenter,
engine, model revision, context, image, price, and hard session duration without
creating a billable resource. GPUs whose engine lacks an immutable published
image are skipped, so a usable lower-priority profile can still be selected.

After `up`, choose the `private-gpu` agent in an already-open OpenCode Desktop
window for synthetic work. The application menu also contains **Start OpenCode
private GPU** and **Stop OpenCode private GPU**. Plugins in an existing Desktop
process can observe sessions, so do not use that route for approved clinical
work unless its complete configuration and loaded plugins have been reviewed.

For a TUI session whose exit always terminates the Pod:

```bash
opencode-gpu session
```

This TUI route disables project configuration and external plugins. `Ctrl-C`,
normal TUI exit, and common termination signals invoke `down`. The Runpod hard
termination time remains the fallback for power or network loss.

## Storage Trial

Start with ephemeral model storage (`RUNPOD_NETWORK_VOLUME_ID` empty). Record
`startup_seconds` from `opencode-gpu status`, terminate, then repeat. Each new
Pod should need to download either the roughly 31 GB FP8 model or the 16.811 GB
GGUF again.

To test persistent caching:

1. Create a standard Runpod network volume of at least 50 GB in an EU/EEA
   datacenter with compatible GPU stock. At current list pricing, 50 GB is
   approximately `$3.50/month` while the volume exists.
2. Set `RUNPOD_NETWORK_VOLUME_ID`. The CLI reads and pins its actual
   datacenter; an optional `RUNPOD_DATA_CENTER_IDS` must match exactly.
3. Run `up`, record `startup_seconds`, and run `down`.
4. Run the same pair again and compare second-start readiness and volume cost.

The CLI derives the volume datacenter from Runpod and verifies EU placement,
preventing an accidental cross-datacenter placement. Delete the volume after
the trial if cache reuse does not justify its continuous storage charge.

Runpod network volumes cannot be encrypted. Use one only for the public model
cache; never store prompts, clinical data, credentials, or other sensitive
artifacts there. The vLLM cache path is `/workspace/huggingface`; the llama.cpp
cache path is `/workspace/llama.cpp`; runtime logs remain on ephemeral container
storage.

The validated ephemeral baseline was 359 seconds to readiness. A 20-request
synthetic burst completed without failures at 174.76 output tokens/second, with
55.32 ms mean time per output token. These figures are a deployment check, not
a workload-specific capacity guarantee.

The RTX 4090 Q4_K_M cold start took 3,013 seconds, dominated by downloading the
16.811 GB GGUF. It used 17,044 MiB of 24,564 MiB VRAM after serving requests. A
20-request synthetic burst completed without failures at 39.66 output
tokens/second. The temporary 25 GB network volume used for resumable validation
was deleted.

A second RTX 4090 cache trial on 2026-08-24 showed substantial cold-download
variance. Filling a new 25 GB volume in `EU-RO-1` required two 3,600-second
startup attempts plus a 1,241-second resumed attempt, at least 8,441 seconds of
GPU time. With the completed GGUF, two subsequent Pods became ready in 4 and 14
seconds. First-response latency was 1.345 seconds after filling the cache and
1.343/1.599 seconds on the warm starts. The corresponding 20-request benchmarks
were 39.22, 38.50, and 39.05 output tokens/second, showing no material serving
penalty from the network volume. The full trial cost $1.8832 and all resources
were deleted.

The inventory snapshot at `2026-08-24T16:11:22Z` reported low RTX 4090 stock in
`EU-RO-1`, `EUR-IS-1`, and `EUR-IS-2`. RTX 5090 stock was low in `EU-CZ-1` and
`EUR-IS-1`; it was unavailable in `EU-RO-1`. L40S, L40, and A100 80 GB PCIe had
no allowed EU/EEA stock. A volume therefore improves startup dramatically but
also restricts fallback to GPUs available in its fixed datacenter. `EUR-IS-1`
was the only volume-capable location in this snapshot reporting both RTX 5090
and RTX 4090 stock.

A later no-volume trial on 2026-08-24 tested three independent RTX 4090 Pods
with `minDownload: 200` and a 30-minute hard limit. The `EUR-IS-2` Pod never
reached SSH during 1,200 seconds and had only started pulling the container
image when it was removed. Two `EU-RO-1` Pods reached SSH but did not finish the
GGUF within the 1,500-second model timeout. On the instrumented repetition, SSH
was ready in 61 seconds, but after 25 minutes 58 seconds curl had downloaded
only 4,641 MiB of 15.6 GiB at an average 3,050 KiB/s, approximately 25 Mbps,
with a projected total download time of 1 hour 29 minutes. RTX 5090 requests in
`EU-CZ-1` and `EUR-NO-1` were rejected before allocation because no instance
matched the requested specifications. The trial cost $0.8937, created no
volumes, and left no resources running. This confirms that `minDownload`
filters advertised host capacity but does not guarantee throughput to the
Hugging Face CDN; ephemeral cold-start time remains highly variable.

A no-volume vLLM trial later that day used `minDownload: 100` and the same
30-minute hard limit. An L40S in `EUR-IS-2` reached SSH in 49 seconds and served
the FP8 model in 1,471 seconds; its first API request returned HTTP 200 in 1.586
seconds. An RTX PRO 6000 Blackwell Server Edition MIG 2g.48gb in the same
datacenter reached SSH in 60 seconds and became ready in 875 seconds, 596 seconds
faster in this sample; a non-reasoning `READY` response completed in 0.418
seconds. A100 80 GB PCIe and RTX 6000 Ada had no EU/EEA stock at test time. The
two billable Pods cost $0.6206 as observed immediately after deletion, created
no volumes, and left no resources running. The MIG profile is supported by the
CLI but remains outside the default priority list until repeated measurements
justify changing selection policy.

An initial `EUR-IS-1` volume configuration was exercised on 2026-08-26. Capacity
disappeared twice between inventory reads and creation, then a Secure Cloud RTX
4090 was allocated and reached SSH in 115 seconds. The volume retained
903,389,184 partial GGUF bytes before the deliberately stopped Pod was
terminated; this partial fill cost $0.1710 and no inference server became ready.

A subsequent 25-sample inventory study favored `EU-RO-1`, so the active 30 GB
volume was moved there with priority RTX 5090, RTX 4090, RTX PRO 4500 Blackwell,
then A100 80 GB PCIe. Two short RTX 5090 Pods validated the replacement: the
second Pod recovered a marker written by the first and resumed the GGUF partial
from 1,269,760 to 1,982,464 bytes in 15 seconds. Both Pods and the old
`EUR-IS-1` volume were deleted after validation; only the `EU-RO-1` volume
remains billable.

The GGUF was then filled directly from Pods as requested. A one-hour RTX PRO
4500 attempt made limited progress, after which an RTX 5090 resumed the partial
and reached readiness in 2,345 seconds, including 103 seconds to SSH. The final
16,810,714,496-byte file matched the pinned SHA-256. The RTX 5090 used 17,156
MiB VRAM, returned the first `READY` response in 0.736 seconds, and completed the
20-request benchmark without failures at 60.10 output tokens/second. A fresh
RTX 5090 then validated the warm path: SSH was ready in 54 seconds, the API in
57 seconds, and the first response took 0.639 seconds. Both Pods were deleted;
the completed model remains on the `EU-RO-1` volume.

The RTX PRO 4500 fallback was subsequently validated against the same warm
volume. After one transient pre-allocation GraphQL error, a retry reached SSH in
38 seconds and API readiness in 62 seconds. It used 16,882 MiB VRAM, returned a
valid first response in 1.279 seconds, and completed all 20 benchmark requests
at 34.68 output tokens/second. It is therefore a functional lower-cost fallback,
although its measured throughput was about 42% below the RTX 5090 result.

A 50 GB network-volume trial in `EUR-IS-1` used 29 GB for the model cache. Two
successful A100 starts took 256 and 267 seconds, so a warm cache produced no
measurable startup improvement. The unencrypted trial volume was deleted and
the default remains ephemeral storage.

For vLLM, `benchmark` uses `vllm bench serve` with 20 random requests. For
llama.cpp it sends 20 deterministic OpenAI-compatible requests through the same
local tunnel and reports completed tokens and wall-clock throughput. These two
results are deployment checks and are not directly comparable benchmarks.

## Recovery

If startup fails after Runpod created a Pod, the CLI attempts immediate
termination and retains state when deletion cannot be confirmed. Check:

```bash
opencode-gpu status
runpodctl pod list --all
opencode-gpu down
```

Never delete `~/.local/state/opencode-gpu/state.json` merely to clear an error;
doing so can orphan a billable Pod. Confirm termination in Runpod first.

Logs are always in `~/.local/state/opencode-gpu/`. Failed startup diagnostics
also preserve the last lifecycle state and up to 200 KB of the remote engine
log before termination. The generated API key and lifecycle configuration are
in `~/.config/opencode-gpu/` with user-only permissions.

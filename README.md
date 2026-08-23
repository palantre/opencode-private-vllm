# Private OpenCode GPU on Runpod

This project creates an occasional EU/EEA Runpod Secure Cloud GPU, serves a pinned
Qwen FP8 model with vLLM, and connects OpenCode through a local SSH tunnel. The
inference HTTP port is never published by Runpod.

## Safety Status

The mocked lifecycle and real synthetic-data path were validated on 2026-08-23
using a Secure Cloud L40S in `EUR-IS-2`. Startup, SSH-only forwarding, OpenAI
chat completions, structured tool calls, the OpenCode agent, idle monitoring,
benchmarking, and termination all completed successfully. No Pod or network
volume is left running by the validation.

Do not process clinical or identifiable data until your organization has
approved Runpod for that purpose and reviewed or signed the applicable DPA.
Use synthetic data for initial tests. OneDrive authorization does not by itself
authorize sending file contents or prompts to Runpod.

## Architecture

```text
OpenCode -> http://127.0.0.1:18000/v1
         -> SSH local forwarding
         -> 127.0.0.1:8000 inside the Pod
         -> vLLM / Qwen
```

Only `22/tcp` is requested from Runpod. vLLM binds to remote `127.0.0.1`; the
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
- A published image built from `container/Dockerfile`.

The current machine already has the required local CLI tools except Docker.
The included GitHub Actions workflow can build the image without local Docker.

## Build The Image

Create a GitHub repository from this directory and run the **Build private
vLLM image** workflow. It publishes an immutable SHA tag such as:

```text
ghcr.io/OWNER/opencode-private-vllm:0123456
```

Make the GHCR package public, or create Runpod registry credentials and put
their ID in `RUNPOD_REGISTRY_AUTH_ID`. The base vLLM image is pinned by digest.
For a local build on a machine with Docker:

```bash
docker build -t ghcr.io/OWNER/opencode-private-vllm:0.1.0 container
docker push ghcr.io/OWNER/opencode-private-vllm:0.1.0
```

## Install

```bash
./install.sh
```

This installs:

- `~/.local/bin/opencode-gpu`
- `~/.local/bin/opencode-gpu-desktop`
- `~/.config/opencode-gpu/config`
- A generated `0600` vLLM API key
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

The published default image is pinned to its immutable multi-platform manifest
digest. Edit `~/.config/opencode-gpu/config` only when publishing a replacement.
Defaults are:

- Model: `Qwen/Qwen3.8-27B-FP8`
- Revision: `017b9c7af6b5689d5dd426a76e0bc077eb5ca20a`
- GPUs, in order: L40S, L40, RTX 6000 Ada
- Secure Cloud EU/EEA placement only
- Maximum GPU price: `$1.50/hour`
- Model context: 32,768 tokens; 16 concurrent sequences; FP8 KV cache
- Idle termination: 30 minutes
- Hard session termination: 240 minutes

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
price, image, and hard session duration without creating a billable resource.

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
Pod should need to download the roughly 31 GB model again.

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
artifacts there. The model cache path is `/workspace/huggingface`; runtime logs
remain on ephemeral container storage.

The validated ephemeral baseline was 359 seconds to readiness. A 20-request
synthetic burst completed without failures at 174.76 output tokens/second, with
55.32 ms mean time per output token. These figures are a deployment check, not
a workload-specific capacity guarantee.

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

Logs are always in `~/.local/state/opencode-gpu/`. The generated API key and lifecycle
configuration are in `~/.config/opencode-gpu/` with user-only permissions.

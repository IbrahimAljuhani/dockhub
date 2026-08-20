# 🧩 LocalAI

A **provider** — see the [AI category](../README.md) — and the broadest one here.

[Ollama](../ollama/) and [llama.cpp](../llama-cpp/) serve text. LocalAI serves **text, speech-to-text, text-to-speech and image generation** from a single OpenAI-compatible API. That breadth is its reason to exist in this catalogue; being OpenAI-compatible isn't, because llama.cpp is too.

---

## 📗 When to pick LocalAI

| You want | Use |
|---|---|
| Chat, simply, with model switching | [Ollama](../ollama/) |
| One model, tuned precisely to your hardware | [llama.cpp](../llama-cpp/) |
| **Transcription, speech, or image generation alongside chat** | **LocalAI** |

If all you need is chat, Ollama does it with less setup. Come here when you want more than text out of one endpoint.

> ⚠️ **You cannot run two providers.** They share the same GPU memory, so `deploy.sh` detects another one running and offers to stop it. Afterwards, rerun any consumer's `deploy.sh` (like [Open WebUI](../open-webui/)) and it will offer to re-point itself.

---

## 📥 Installation

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/AI/localai/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/AI/localai/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

### The one real question: All-In-One, or empty?

**All-In-One (recommended)** arrives pre-configured with a model for each capability, named the way OpenAI names them:

| Model name | Does |
|---|---|
| `gpt-4` | Chat |
| `gpt-4-vision-preview` | Image understanding |
| `text-embedding-ada-002` | Embeddings |
| `whisper-1` | Speech → text |
| `tts-1` | Text → speech |
| `stablediffusion` | Image generation |

Because the names match OpenAI's, code written against the OpenAI API works against your server with only the base URL changed.

**Empty** gives you a bare server and you configure each model yourself. A reasonable choice — but it leaves LocalAI doing roughly what Ollama does, with more effort, and it answers nothing at all until you install something.

> 💡 **LocalAI serves its own web interface on the same port.** If you published a host port, open `http://<server-ip>:<port>` and use **Install Models** in the left sidebar to browse the gallery and install with a click — no CLI needed. This is the easy path out of an empty deployment.
>
> **Two harmless things you will see, verified live on a full AIO GPU deployment:**
>
> - `ERROR guessDefaultsFromFile: panic while parsing gguf file` appears on **every** startup and is recovered from. LocalAI probes each file in `/models` to guess its defaults, and the multimodal projector (`*-mmproj-*.gguf`) is not a model file, so the probe fails on it. All models still import and `core/startup process completed!` still follows.
> - `deploy.sh` reports ready while files are still `.partial`. LocalAI serves and finishes downloading behind you. A run that reported ready with a file at 62% had it complete and loading normally after a reboot a minute later. **Don't delete `.partial` files** — that discards an in-progress download.
>
> The bare root URL may answer **404 — Page Not Found** while the sidebar still renders around it. That is a routing quirk, not a broken deployment: the interface is being served, and the sidebar links (or the page's own "Return Home" button) work. Judge the deployment by `curl http://<server-ip>:<port>/readyz`, not by what `/` returns.

> ⚠️ **AIO downloads its model set on first start, not at image pull.** The container is "running" long before it's usable, and on the GPU profile that's tens of gigabytes. `deploy.sh` waits on LocalAI's own `/readyz` and prints progress, so you can tell downloading from stuck.

---

## 🖥️ The image tag is two decisions

LocalAI's tags combine **hardware** and **content**:

| | Empty | All-In-One |
|---|---|---|
| **CPU** | `latest-cpu` | `latest-aio-cpu` |
| **NVIDIA** | `latest-gpu-nvidia-cuda-12` | `latest-aio-gpu-nvidia-cuda-12` |

`deploy.sh` builds the tag from both halves: the hardware from what [`lib/gpu.sh`](../../../lib/gpu.sh) detected, the content from your answer. Nothing is guessed.

> 💡 **A modest GPU is not a reason to avoid the GPU build.** AIO detects how much VRAM the card actually has and starts with a matching profile, with models sized for it. It adapts to your hardware rather than assuming a large card.
>
> **Verified on a 6 GB consumer GPU:** `latest-aio-gpu-nvidia-cuda-12` deployed and reached `/readyz` in about 25 minutes. AIO picked `Q4_K_M` (4-bit) quantisations for both large models — a 4.4 GB chat model and a 4.7 GB vision model — rather than the `Q8`/`F16` builds it would use on a bigger card. That sizing is the profile mechanism working, not a coincidence.
>
> The CPU build is a *fallback* for when GPU loading genuinely fails, not a requirement for smaller cards. If that happens — or if you simply want the card left free for something else — set **`AI_ACCELERATION=cpu`** in `.env` and rerun. `deploy.sh` swaps the hardware half of the tag for you and leaves the All-In-One half alone, so you don't have to work out which of the four tags you need. See the [category README](../README.md#-gpu-or-cpu--you-decide-not-the-detector).
>
> ⚠️ Switching direction means a different set of backends: LocalAI builds them per hardware target, so what's already downloaded doesn't carry over. `deploy.sh` says so before it starts.
>
> Don't confuse the two limits: **disk** decides whether the model set can be downloaded (tens of GB for the GPU profile), **VRAM** decides how large a single model can be once loaded. They're unrelated, and only the second is about your card.

---

## 🔌 How other services reach it

```
http://localai:8080/v1
```

OpenAI-compatible, so [Open WebUI](../open-webui/) and the agents find it with no LocalAI-specific code — `detect_ai_provider()` in `lib/common.sh` handles the mapping.

> ⚠️ **No authentication on the API.** `ai-net` and `models-net` — never `main-net`, never a public domain. A host port is offered and defaults to no (`8082` → the container's `8080` if you want one).
>
> Two networks because this container is the **hub** that lets the agent services and the [Multi-Agent](../../Multi-Agent/) builders share it without sharing each other — see [the AI category README](../README.md#two-networks-and-why-a-provider-joins-both). It gains no reach from either: a network gives it callers, and it calls nobody.

---

## 🛠️ Management Commands

```bash
cd ~/docker/localai
```

| Command | Purpose |
|---|---|
| Open `http://<server-ip>:8082` | LocalAI's own UI — "Install Models" in the sidebar browses the gallery |
| `curl http://<server-ip>:8082/readyz` | The real health answer, unaffected by UI routing |
| `docker exec localai sh -c 'ls /models/*.partial'` | What is still downloading in the background (normal — don't delete these) |
| `sudo du -sh ~/docker/ai-models/localai/*` | Space used by models and backends — **`sudo` is required**, see below |
| `docker compose logs -f localai` | Follow downloads and inference |
| `curl http://localhost:8082/v1/models` | What's actually loaded (if you published a host port) |
| `docker exec localai local-ai models list` | Everything available in the gallery |
| `docker exec localai local-ai models install <name>` | Add one |
| `docker compose pull && docker compose up -d` | Update |

---

## 📦 Where the space goes

Four paths are persisted, because upstream requires all four — `/models`, `/backends`, `/configuration` and `/data`. DockHub splits them by what the data *is*:

| Path | Lives in | Why |
|---|---|---|
| `/models` · `/backends` | `~/docker/ai-models/localai/` | Large, re-downloadable. Skipped by backup. |
| `/configuration` · `/data` | `~/docker/localai/` | Small, yours. Captured by backup. |

**Mounting only `/models` was a real bug, caught by a live test.** After removing and redeploying, LocalAI re-downloaded gigabytes of CUDA backends while 13 GB of models sat untouched on disk — the models had survived, the backends had not. With all four mounted, the same remove-and-redeploy reaches ready in **seconds** with no downloads at all.

> ⚠️ **`du` needs `sudo` here.** LocalAI runs as root inside the container and creates the backend directories unreadable by your host user. Plain `du` fails per-directory *and* silently under-reports the total. Use `sudo du -sh ~/docker/ai-models/localai/*`.

---

## 💾 Backups

**Backup saves the configuration and skips the models — on purpose.**

This is the starkest case in DockHub. A full All-In-One GPU deployment is **25+ GB** of backends, GGUF and safetensors. The generic volume backup would gzip all of it into a staging directory and then gzip *that* — a long single-threaded pass needing about double the space free, to preserve files LocalAI re-fetches on its own at first start.

The archive keeps `.env` and the compose files: the AIO-or-empty choice, the GPU/CPU decision, the image tag, the port. Restore, start, and it rebuilds its model set — the same 25 minutes it took the first time, from a 1 KB archive.

---

## 📌 Notes & Deviations

- **AIO is the default choice offered**, where upstream's quickstart leaves it to you. Without it LocalAI is a harder Ollama, and the multimodality that justifies its place here never arrives.
- **The tag is composed, not fixed** — hardware from detection, content from your answer.
- **`MODELS_PATH=/models` on a named volume**, so the AIO download survives a recreate instead of repeating.
- **`DEBUG` is set explicitly to `false`** rather than left unset. Empty environment variables are not the same as absent ones, and this project has already been bitten by that: an empty `LLAMA_ARG_N_GPU_LAYERS` put llama.cpp into a restart loop, because it parses the value rather than checking whether it exists.
- **No `main-net`, no NPM, no domain** — same posture as the other providers.

---

## 📜 License

LocalAI is licensed separately (MIT — see the [official repository](https://github.com/mudler/LocalAI)). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of DockHub.

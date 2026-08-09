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

**Empty** gives you a bare server and you configure each model yourself. A reasonable choice — but it leaves LocalAI doing roughly what Ollama does, with more effort.

> ⚠️ **AIO downloads its model set on first start, not at image pull.** The container is "running" long before it's usable, and on the GPU profile that's tens of gigabytes. `deploy.sh` waits on LocalAI's own `/readyz` and prints progress, so you can tell downloading from stuck.

---

## 🖥️ The image tag is two decisions

LocalAI's tags combine **hardware** and **content**:

| | Empty | All-In-One |
|---|---|---|
| **CPU** | `latest-cpu` | `latest-aio-cpu` |
| **NVIDIA** | `latest-gpu-nvidia-cuda-12` | `latest-aio-gpu-nvidia-cuda-12` |

`deploy.sh` builds the tag from both halves: the hardware from what [`lib/gpu.sh`](../../../lib/gpu.sh) detected, the content from your answer. Nothing is guessed.

> 💡 A small GPU is a real reason to choose the CPU build. If the GPU profile fails to load its models, set `LOCALAI_TAG=latest-aio-cpu` in `.env` and rerun — the failure message says so too.

---

## 🔌 How other services reach it

```
http://localai:8080/v1
```

OpenAI-compatible, so [Open WebUI](../open-webui/) and the agents find it with no LocalAI-specific code — `detect_ai_provider()` in `lib/common.sh` handles the mapping.

> ⚠️ **No authentication on the API.** `ai-net` only, never `main-net`, never a public domain. A host port is offered but defaults to no.

---

## 🛠️ Management Commands

```bash
cd ~/docker/localai
```

| Command | Purpose |
|---|---|
| `docker compose logs -f localai` | Follow downloads and inference |
| `curl http://localhost:8082/v1/models` | What's actually loaded (if you published a host port) |
| `docker exec localai local-ai models list` | Everything available in the gallery |
| `docker exec localai local-ai models install <name>` | Add one |
| `docker compose pull && docker compose up -d` | Update |

---

## 💾 Backups

**Not wired up, deliberately.** The one volume holds downloaded models — large, and re-downloadable. Nothing here is yours.

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

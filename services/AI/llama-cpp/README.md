# ⚙️ llama.cpp

The inference engine, served directly. A **provider** — see the [AI category](../README.md).

[llama.cpp](https://github.com/ggml-org/llama.cpp) is the engine underneath much of this space, including Ollama. Running it directly trades convenience for control.

---

## 📗 llama.cpp or Ollama?

They are not layers of the same thing — pick one:

| | [Ollama](../ollama/) | **llama.cpp** |
|---|---|---|
| Models served | **Many**, switched on demand | **One** |
| Getting a model | `ollama pull llama3.1:8b` | A Hugging Face repo + quantization |
| Tuning | Little exposed | Every flag llama-server has |
| Best for | Most people, most of the time | Squeezing a specific model onto specific hardware |

**Ollama is the better default.** Come here when you want a model that isn't in Ollama's library, or you want to control exactly how it's loaded.

> ⚠️ **You cannot run both.** They share the same GPU memory, so `deploy.sh` detects the other one running and offers to stop it first. Same reasoning as Pi-hole and AdGuard both wanting port 53.

---

## ⚠️ One model, not a list

This is the difference that surprises people, so it's worth stating plainly:

**`llama-server` loads one model and serves that one.** Point [Open WebUI](../open-webui/) at it and you'll see a single entry in the model dropdown rather than a list. **That is correct behaviour, not a broken connection.**

To serve a different model:

```bash
nano ~/docker/llama-cpp/.env      # change LLAMA_ARG_HF_REPO
bash deploy.sh
```

---

## 📥 Installation

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/AI/llama-cpp/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/AI/llama-cpp/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

You'll be asked for a **model** — mandatory here, unlike Ollama. `llama-server` loads one at startup; with nothing to load there's no service. Three curated options are offered, or enter any Hugging Face GGUF repo:

```
ggml-org/gemma-3-1b-it-GGUF               ~1 GB
ggml-org/gemma-3-4b-it-GGUF               ~3 GB
bartowski/Qwen2.5-Coder-7B-Instruct-GGUF  ~5 GB
```

Format is `user/repo` or `user/repo:QUANT` — the quantization defaults to `Q4_K_M`. Browse more at [huggingface.co/models?library=gguf](https://huggingface.co/models?library=gguf).

**First start downloads the model inside the container**, so "container running" arrives long before "ready to answer". `deploy.sh` waits on the image's own `/health` endpoint, which reports unhealthy while loading and healthy once serving.

---

## 🖥️ GPU

The **image tag is the entire GPU decision**:

| Tag | |
|---|---|
| `server` | CPU build. No CUDA inside — a GPU on the host changes nothing, because the binary can't use it. |
| `server-cuda` | CUDA build. Required for any acceleration at all. |

`deploy.sh` picks between them from what [`lib/gpu.sh`](../../../lib/gpu.sh) actually detected, and adds the device reservation to the compose override when it chooses the CUDA build.

> 📌 **Two things guides tell you to fix that are already fine.** Both were checked against upstream's own Dockerfile and server docs rather than assumed:
>
> - **`--host`**: llama-server defaults to `127.0.0.1`, which in a container would mean nothing can reach it. The server image **already sets `LLAMA_ARG_HOST=0.0.0.0`**, so there's nothing to do.
> - **`-ngl` / GPU layers**: defaults to **`auto`** in current llama.cpp, so the CUDA build offloads on its own. Older guides insist you must pass `-ngl 99` or it silently runs on CPU — no longer true.
>
> `LLAMA_ARG_N_GPU_LAYERS` sits in `.env` empty, and `deploy.sh` passes it to the container **only when you give it a number**. That distinction is load-bearing: llama.cpp parses this variable with `stoi`, so an *empty* value is a parse error rather than a fallback to `auto`, and the container restart-loops with `error while handling environment variable "LLAMA_ARG_N_GPU_LAYERS": stoi`. The default applies only when the variable is absent entirely.

---

## 🔌 How other services reach it

```
http://llama-cpp:8080/v1
```

An OpenAI-compatible endpoint, so [Open WebUI](../open-webui/) and the agents find it without any llama.cpp-specific code — `detect_ai_provider()` in `lib/common.sh` handles the mapping.

> ⚠️ **The API has no authentication**, exactly like Ollama's. It joins `ai-net` only, never `main-net`, and never goes behind NGINX Proxy Manager. A host port is offered but defaults to no — anything that can reach it can use your models and read your prompts.

---

## 🛠️ Management Commands

```bash
cd ~/docker/llama-cpp
```

| Command | Purpose |
|---|---|
| `docker compose logs -f llama-cpp` | Follow loading and inference |
| `docker compose ps` | Health status — unhealthy means still loading |
| `curl http://llama-cpp:8080/v1/models` | What it's serving (from another container on `ai-net`) |
| `docker compose pull && docker compose up -d` | Update |

### Tuning worth knowing about

| `.env` variable | |
|---|---|
| `LLAMA_ARG_N_GPU_LAYERS` | Leave **empty** for `auto` — `deploy.sh` then omits it entirely, which is what makes `auto` apply. Set a number to force partial offload when a model doesn't quite fit VRAM. Rerun `deploy.sh` after changing it. |
| `LLAMA_ARG_N_PARALLEL` | Concurrent requests, default `1`. Raising it **multiplies** VRAM use — each slot needs its own KV cache. |

---

## 💾 Backups

**Not wired up, deliberately.** The only volume holds downloaded model files: large, and re-downloadable from Hugging Face at any time. Nothing here is yours. The whole configuration is `.env`, which is two lines.

---

## 📌 Notes & Deviations

- **The tag follows the hardware**, chosen at deploy time rather than fixed in the compose file — the same detection that serves Ollama.
- **`LLAMA_CACHE=/models` on a named volume.** Without it the model downloads to the container filesystem and is lost on every recreate — several gigabytes, re-fetched each time.
- **`LLAMA_ARG_N_PARALLEL=1`** rather than upstream's higher default: on a single consumer GPU, parallel slots multiply VRAM rather than sharing it.
- **A model is required at deploy**, unlike Ollama where you can skip and pull later.
- **No `main-net`, no NPM, no domain** — same posture as Ollama.

---

## 📜 License

llama.cpp is licensed separately (MIT — see the [official repository](https://github.com/ggml-org/llama.cpp)). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of DockHub.

# 🦙 Ollama

Runs language models on your own hardware and serves them over an API.

Ollama is a **provider** — see the [AI category](../README.md) for how providers and consumers fit together. It has **no web interface and no login**, because it isn't an app you open; it's the engine other things talk to. Pair it with [Open WebUI](../open-webui/) for a chat interface, or point any agent in DockHub at it.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```

### 2. Deploy Ollama

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/AI/ollama/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/AI/ollama/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

`deploy.sh` will:

1. **Check the GPU** — in three layers (see below) and offer to fix the one it can.
2. Ask about a **memory limit** and an optional **host port**.
3. Start Ollama on the shared `ai-net` network.
4. **Offer to pull a first model**, with sizes and a disk check.

---

## 🖥️ GPU support

Three separate things have to be true before a *container* can use your GPU, and most guides blur them together:

| Layer | Question | Checked with |
|---|---|---|
| 1. Hardware | Is a GPU present? | `lspci` |
| 2. Host driver | Can the OS talk to it? | `nvidia-smi` |
| 3. **Docker bridge** | Can **containers** see it? | `docker run --gpus all …` |

A machine can pass 1 and 2 and still fail 3 — that's the normal state of a fresh install, and it's why *"I have an NVIDIA card, why is Ollama using the CPU?"* is so common.

**What `deploy.sh` does about each:**

- **Layers 1–2 are detected and reported, never installed silently.** The driver builds a kernel module and needs a reboot, and with **Secure Boot** enabled it also needs you to enroll a key interactively on a blue screen during boot — no script can finish that. If the driver is missing, you get the recommended package name from `ubuntu-drivers devices` and the command to install it yourself.
- **Layer 3 — the NVIDIA Container Toolkit — is offered and installed**, because it's an ordinary userspace package with no kernel module and no reboot. It is then **verified with a real test container**, not assumed.

> ⚠️ **Docker installed from snap can never use the GPU.** Snap's confinement blocks `/dev/nvidia*`, and nothing reports this clearly — you just get a GPU that never appears. `deploy.sh` detects it and says so. `install_dockhub.sh` uses the official APT repository, so this only affects Docker you installed yourself.

**No GPU is fine.** Small models (3B, quantized) are perfectly usable on a modern CPU. Larger ones will be slow rather than broken.

**Installed the driver later?** Just rerun `deploy.sh` — the GPU check runs every time, and it rewrites the compose override to add acceleration.

---

## 📦 Models

Ollama ships with none. The deploy offers a starting point:

| Model | Size | Notes |
|---|---|---|
| `llama3.2:3b` | ~2 GB | Fast, modest quality. The sensible choice without a GPU. |
| `llama3.1:8b` | ~5 GB | The common default. Wants a GPU, or patience. |
| `qwen2.5-coder:7b` | ~5 GB | Tuned for code. |

Afterwards:

```bash
docker exec -it ollama ollama list           # what's installed
docker exec -it ollama ollama pull <model>   # add one
docker exec -it ollama ollama rm <model>     # remove one
```

Browse everything available at [ollama.com/library](https://ollama.com/library).

> 💡 **A rough rule for fit:** a quantized model needs a bit more RAM (or VRAM) than its download size. A 5 GB model on a 4 GB card will run, but partly on the CPU and much slower.

---

## 🖥️ GPU or CPU

`deploy.sh` asks once, on the first run, and stores the answer as **`AI_ACCELERATION`** in `~/docker/ollama/.env`:

```bash
AI_ACCELERATION=cpu    # or: gpu
```

Every rerun honours it. Detection still runs each time — so installing an NVIDIA driver later and rerunning does enable the GPU — but detecting that the GPU *works* is no longer taken as consent to *use* it.

> ⚠️ **Don't hand-edit `docker-compose.override.yml`.** `deploy.sh` regenerates it from scratch on every run, so deleting the `deploy:` block there lasts exactly until the next rerun. `.env` is the file that persists. This was the only supported way to get CPU on a GPU host before `AI_ACCELERATION` existed — and it didn't work.

Reasons to choose CPU on a machine that has a working GPU are covered in the [category README](../README.md#-gpu-or-cpu--you-decide-not-the-detector); the common one is leaving the card free for [Jellyfin](../../Media/jellyfin/) or [Plex](../../Media/plex/) transcoding.

---

## 🔌 How other services reach it

```
http://ollama:11434
```

Over the shared `ai-net` network, by container name. Every AI consumer in DockHub uses that address, and none of them needs a published port.

**Ollama also speaks the OpenAI-compatible API** at `http://ollama:11434/v1`, which is what most third-party tools expect.

---

## ⚠️ There is no authentication

None. Not a default password — no authentication at all. Anything that can reach port `11434` can list your models, run inference on your hardware, and read the prompts you send.

That's why **no host port is published by default**, and why this service stays off `main-net`. The deploy offers a host port for pointing tools outside Docker at it, but treat that as opening the API to your whole LAN, because that's what it is.

Never put Ollama behind NGINX Proxy Manager on a public domain.

---

## 🛠️ Management Commands

```bash
cd ~/docker/ollama
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Is it running? |
| `docker compose logs -f ollama` | Follow the logs |
| `docker compose pull && docker compose up -d` | Update Ollama itself (models are kept) |
| `docker exec -it ollama ollama ps` | Which models are loaded in memory right now |

> 💡 **`OLLAMA_KEEP_ALIVE`** in `.env` controls how long a model stays resident after its last request. The default here is `5m` — shorter than Ollama's own default, because on a shared server holding several GB idle isn't free. Raise it if you use it constantly and dislike the reload pause.

---

## 💾 Backups

**Backup saves the configuration and skips the models — on purpose.**

`ollama_ollama-models` holds every model you've pulled, often tens of gigabytes of already-compressed weights. Archiving it would need roughly double that in free space and a long compression pass, to preserve a set of files that `ollama pull` re-fetches for free. None of it is yours.

What the archive *does* contain is the part that can't be re-downloaded: `.env` (model choice, GPU/CPU decision, port, memory limit) and the compose files. Restoring it gives you the same deployment back; the models arrive on the next pull.

```bash
docker exec -it ollama ollama list      # what you'd need to re-pull
```

---

## 📌 Notes & Deviations

- **`OLLAMA_HOST=0.0.0.0:11434` is set explicitly.** Without it Ollama binds `127.0.0.1` inside the container and no other container can reach it — which looks exactly like a broken network. The same class of trap as Mosquitto's local-only default.
- **The GPU block isn't in `docker-compose.yml`.** It's written into `docker-compose.override.yml` only after a test container proves the GPU is reachable. Baking it in unconditionally would make the service fail to start on every CPU-only machine.
- **`ai-net`, not `main-net`.** There's no web UI for NPM to serve, and an unauthenticated API doesn't belong on the network with everything else.
- **No secrets file**, unlike most services here — Ollama generates no credentials, because it has none.
- **Models can't be shared with llama.cpp or LocalAI.** Ollama repacks weights into its own content-addressed store (blobs + manifests) rather than keeping plain `.gguf` files, so a shared model volume across providers isn't possible even though they can run the same weights.

---

## 📜 License

Ollama is licensed separately (MIT — see the [official repository](https://github.com/ollama/ollama)). Models carry their own licences. This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of DockHub.

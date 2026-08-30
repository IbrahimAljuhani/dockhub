# 🧠 AI

The **model layer** — the servers that run language models, and the interface you talk to them through.

This is one of three categories that split what people loosely call "AI", along a single line: **do you use a model, use an agent, or build agent systems?**

| Category | Question it answers |
|---|---|
| **AI** (here) | *Run a model, and chat with it.* |
| [AI-Agents](../AI-Agents/) | *An agent does work for me.* |
| [Multi-Agent](../Multi-Agent/) | *I build what the agents do.* |

---

## 📋 What's here

**Providers** — servers that run models and serve them over an API. Each one is complete on its own:

| | Notes | Reached as |
|---|---|---|
| ✅ [**Ollama**](ollama/) | The easiest. Pull a model by name and it's ready. The default choice, and every consumer supports it natively. | `http://ollama:11434` |
| ✅ [**llama.cpp**](llama-cpp/) | The engine underneath much of this space, served directly. Leanest and most tunable; you name a HuggingFace repo and a quantization rather than a friendly model name. | `http://llama-cpp:8080` |
| ✅ [**LocalAI**](localai/) | Broadest: 35+ backends covering not just text but **speech-to-text, text-to-speech and image generation** in one server. That breadth is its real value. | `http://localai:8080` |

**Interface:**

| | Notes |
|---|---|
| ✅ [**Open WebUI**](open-webui/) | A polished chat interface — the one service here that **produces nothing by itself**. It needs a model source: any provider above, or a cloud API key. |

---

## 🔗 How the pieces fit

This is the one thing worth understanding before deploying anything:

```
           ┌── Ollama ────┐
           │  llama.cpp   │   a provider RUNS the model. Complete on its own.
           │  LocalAI     │   Nothing else is required for it to work.
           └───┬─────┬────┘
               │     │       the providers join BOTH networks, so the two
    models-net │     │ ai-net groups of consumers share them without
               │     │       ever sharing each other
      ┌────────┘     └────────┐
      │                       │
 Open WebUI              OpenHands / Hermes / OpenClaw / Paperclip
 Dify / Flowise          they act on text they did not write
 Langflow

 these RUN CODE          ai-net carries OpenHands: no authentication
 you did not write       of its own, and it mounts the Docker socket
```

**A provider is useful alone.** Deploy Ollama and you have a working model API immediately — DockHub's own agents talk to it, and so can your scripts.

**Open WebUI is not.** It is a face, not an engine. On first deploy it looks for a running provider, and if it finds none it asks whether you want to point it at a cloud endpoint instead or add a connection later in the web interface. Either way, **an interface with no model source has an empty dropdown** and nothing to say.

> It is **not** tied to Ollama. `deploy.sh` wires whichever provider it finds: Ollama through its native API (`OLLAMA_BASE_URL`), llama.cpp and LocalAI through their OpenAI-compatible `/v1` path (`OPENAI_API_BASE_URL`, plus a placeholder key the protocol demands and local servers ignore). Swap providers later and rerunning `deploy.sh` offers to re-point it for you.

---

## 🤔 Which provider

| Choose | When |
|---|---|
| **Ollama** | You want it to work in one command. `ollama pull llama3.2:3b` and you're done. Holds several models and switches between them on demand. |
| **llama.cpp** | You want control — exact quantization, exact flags, minimum overhead. Serves **one model at a time**: point a chat UI at it and you will see a single entry, which looks broken if you expected a list. |
| **LocalAI** | You want more than text. Speech-to-text, text-to-speech and image generation from the same server, with per-hardware backends. |

**They all speak the OpenAI-compatible `/v1` API**, so any interface or agent in DockHub can talk to any of them — with one exception documented below.

---

## ⚠️ The context window is set by the SERVER, not the model

The most expensive lesson in this category, and it is invisible until something behaves oddly.

A model advertises the window it was **trained** with. The server decides what it **allocates**. Ollama picks automatically "based on VRAM" and on a modest card that is **4096**, whatever the model claims:

| | |
|---|---|
| `gemma4:e4b` advertises | **131,072** |
| Ollama served it | **4,096** |
| OpenHands' opening prompt alone | **17,742** |

Nothing reports this. There is no error, no warning, no log line — the model simply forgets, because everything older fell out of a window four times too small to hold the agent's own prompt.

For **chat**, 4096 is survivable. For **agents**, it is not: the system prompt and tool schemas consume the entire window before you type a word.

```bash
docker exec ollama ollama ps        # the CONTEXT column is the truth
```

[Ollama](ollama/)'s `deploy.sh` now asks for this and writes `OLLAMA_CONTEXT_LENGTH`. **Raising it costs GPU memory in proportion**, and the cost is steeper than most people expect. Measured on a 6 GB consumer GPU with one 8B model, changing only this value:

| Context | Size | Processor |
|---|---|---|
| 32,768 | 3.3 GB | **100% GPU** |
| 65,536 | 10.0 GB | 70%/30% CPU/GPU ❌ |

Doubling the window added 6.7 GB of KV cache and pushed most of the model onto the CPU. That trade is always bad — you gain context you cannot afford to process. If `ollama ps` shows any CPU in `PROCESSOR`, come back down.

---

## 🔒 One provider at a time — and it is enforced

All three load models into the same GPU memory, and the model files are many gigabytes each. So `deploy.sh` does not merely advise:

```
[!] Another model provider is already running: ollama
    Stop ollama and continue? (Y/n):
```

Decline and **nothing is deployed** — the script stops rather than leave you with two servers fighting over one card. Accept and it stops the other for you.

This is different from the [agents](../AI-Agents/) category, where only one runs at a time for a *human* reason (they are alternatives, not companions) rather than a hardware one.

---

## 🖥️ GPU or CPU — you decide, not the detector

Every provider writes **`AI_ACCELERATION`** into its `~/docker/<service>/.env`, holding `gpu` or `cpu`. It is asked once, on the first run, and honoured on every run after.

The distinction it draws is the one most setup scripts miss:

| Question | Answered by | Where |
|---|---|---|
| **Can** containers use a GPU on this host? | Detection — a real test container | `GPU_DOCKER_OK` |
| **Should** this deployment use it? | You | `AI_ACCELERATION` in `.env` |

A working GPU used to imply the second answer automatically, with no supported way to decline. There are good reasons to decline:

- **The GPU is already spoken for.** DockHub ships [Jellyfin](../Media/jellyfin/) and [Plex](../Media/plex/), and both use it for hardware transcoding. A model that seizes the card breaks the media server the household actually notices.
- **The model is larger than the VRAM.** 6 GB cannot hold a 14B model; 32 GB of system RAM can, slowly. Here the CPU *works* and the GPU *fails*.
- **Isolating a fault.** "Is this CUDA's doing?" is answered fastest by one CPU run.
- **Heat, fan noise and power draw** on a machine that runs overnight.

To change your mind later, edit that one line and rerun `deploy.sh`:

```bash
AI_ACCELERATION=cpu
```

Each provider then adjusts whatever it needs to. llama.cpp and LocalAI also swap their image — `server` has no CUDA compiled in at all, so for them the tag *is* the hardware decision, and `deploy.sh` keeps it in step so you never have to edit two things.

> ⚠️ Switching LocalAI between GPU and CPU means a different set of backends. They're built per hardware target, so the ones already downloaded don't carry over — expect it to fetch again. `deploy.sh` warns before it happens.

---

## 🔓 None of these have a login

Worth stating plainly, because it decides how you expose them.

A provider's API has **no authentication of any kind**. Anyone who can reach the port can use your models, read the prompts sent to them, and burn your GPU. That is upstream's design in all three, not an oversight.

| | Default |
|---|---|
| Inside Docker | Reached by container name on `ai-net` **and `models-net`**. **No port published, nothing exposed.** |
| Host port | **Offered, never assumed** — and `deploy.sh` names the missing authentication in the prompt |

Consumers inside DockHub never need the host port. Publish it only when something outside Docker must reach the API, and treat that as putting an open endpoint on your LAN — because it is.

### Two networks, and why a provider joins both

A Docker network is **flat**: every member can reach every other. So "join the network to use a local model" also means "join the network and be reachable by everything else on it" — and `ai-net` carries [OpenHands](../AI-Agents/openhands/), which has **no authentication of its own** and mounts the Docker socket.

That was acceptable while `ai-net` held only the agent services. It stopped being acceptable on **2026-08-19**, when the [Multi-Agent](../Multi-Agent/) builders — whose whole purpose is running code a user or a model wrote — were put on it to reach a local model. Code arriving inside an imported flow could then reach an unauthenticated endpoint holding root on the host.

The providers are now the **hub** that keeps the two consumer groups apart:

```
  agents ──────► ai-net ──────► [ ollama · llama-cpp · localai ] ◄────── models-net ◄────── builders
  (OpenHands, Hermes,                    joins BOTH                       (Dify, Flowise,
   OpenClaw, Open WebUI,                                                   Langflow)
   Paperclip)
```

Each group reaches the models; neither reaches the other. A provider gains nothing from this — a network gives it members that can call *it*, and it calls nobody.

`deploy.sh` creates both networks and joins both, so this needs no thought from you. If a builder cannot see your provider, the usual cause is a provider deployed before this change whose kept `docker-compose.yml` is still on `ai-net` alone — rerun its `deploy.sh` and accept the compose update it offers.

Open WebUI is different: it **does** have accounts, and **the first account registered becomes admin**. Create yours immediately after deploying, before anyone else finds the page.

---

## 📁 Where the weights live

Models are the largest thing DockHub downloads — tens of gigabytes is normal. They go to a **host directory** shared by every AI service, asked once and remembered:

```
~/docker/ai-models/<provider>/
```

A bind mount rather than a named volume, deliberately: named volumes bury the files in `/var/lib/docker/volumes` where you can neither see the space nor move it to a bigger disk. Here you can do both.

This also decides the backup policy, which is the **opposite** of the agents':

| | What it holds | Backup |
|---|---|---|
| **Providers** (here) | Downloaded weights | Config only — weights are skipped |
| [Agents](../AI-Agents/) | Memories, skills, conversations | Everything |

A provider *downloads*. Anything it holds can be fetched again. Backing up 40 GB of re-downloadable weights every night is not caution, it is waste.

### One parent, three private rooms

That `<provider>` in the path is not decoration. The providers share the **parent**, not the files:

```
~/docker/ai-models/
├── ollama/       blobs + manifests, content-addressed
├── llama-cpp/    the Hugging Face cache layout
└── localai/      models/ — plain .gguf
```

Each container mounts only its own directory. **Ollama cannot see llama.cpp's weights and llama.cpp cannot see Ollama's** — they are siblings, never nested. Sharing one folder would not work anyway, because they do not store the same way:

| | On disk | Reads a plain `.gguf`? |
|---|---|---|
| **Ollama** | `blobs/sha256-…` + `manifests/`, no file extensions | Only by importing a copy |
| **llama.cpp** | `models--{org}--{repo}/blobs/{sha256}` with `.gguf` **symlinks** under `snapshots/` | Yes, in place |
| **LocalAI** | plain files in `models/` | Yes, in place |

Two consequences that surprise people, both found on a live machine:

- **`ls ~/docker/ai-models/llama-cpp/*.gguf` finds nothing**, even with models downloaded. The weights are hash-named blobs with no extension; the only things called `.gguf` are symlinks two directories down.
- **Importing into Ollama costs a second copy.** `ollama create` pulls the weights into its own store rather than referencing them, so the same model then exists twice. llama.cpp and LocalAI read their file where it lies. `deploy.sh` says so before you choose.

**Removing a service does not remove its weights.** They live outside `~/docker/<service>/`, so redeploying reuses them and downloads nothing — which is the point. `services.sh` now tells you how much stayed behind and where, because "removed completely" was true of everything except the largest thing on disk.

### Getting a model in

Both providers can pull from **Ollama's library and from Hugging Face**; neither is limited to one source.

| | Ollama | llama.cpp |
|---|---|---|
| Its own library | `gemma3:4b` | — |
| Hugging Face | `hf.co/{user}/{repo}[:QUANT]` | `{user}/{repo}[:QUANT]` |

`deploy.sh` asks which source and adds the prefix itself, so a repo pasted straight from the browser works.

⚠️ **GGUF only.** Raw `safetensors` weights cannot be pulled by either — filter Hugging Face by `library=gguf`.

⚠️ **An `mmproj-*.gguf` is not a model.** It is the vision half of a multimodal pair, and llama.cpp loads both. **Ollama cannot** — its Modelfile has no instruction for a projector (`ADAPTER` is for LoRA). Import such a model into Ollama and you get a working text model with its vision silently gone; `deploy.sh` says so in the list. The naming is not fixed either — `mmproj-Ornith-…gguf` and `gemma-4-E4B-it-mmproj.gguf` are both real.

### One model or many

The deepest difference, and the one that makes two similar-looking menus mean opposite things:

- **llama.cpp serves ONE model.** Choosing another **replaces** it. Open WebUI will show a list of one, and that is correct.
- **Ollama serves ALL of them.** Choosing another **adds** it; the client picks per request.

So llama.cpp's menu asks *which model*, and Ollama's asks *what to add*.

### Context length: the same setting, opposite dangers

Covered above for Ollama; the reason the two prompts read differently:

| | Default | So the prompt exists to |
|---|---|---|
| **Ollama** | VRAM-based, often **4096** | **raise** it — agents need far more |
| **llama.cpp** | `-c 0` — the model's own trained context | **cap** it — a 128k-context model sizes its cache for 128k and may not load |

> ⚠️ For llama.cpp, leaving the setting **blank deletes the key**; it is never written empty. `LLAMA_ARG_CTX_SIZE=` is parsed with `stoi`, and an empty string is a parse error that puts the container in a restart loop. Absent means the default; empty means a crash. The same is true of `LLAMA_ARG_N_GPU_LAYERS`.

---

## 🔌 How consumers reach a provider

Every DockHub consumer finds a running provider automatically — `deploy.sh` detects it on `ai-net` and writes the right URL in. Two things are worth knowing anyway.

**The address is the container name**, not `localhost` and not the server's IP:

```
http://ollama:11434        http://llama-cpp:8080        http://localai:8080
```

Upstream documentation frequently says `http://host.docker.internal:11434`, which assumes the provider runs on the host. In DockHub it is a container on `ai-net`.

> ⚠️ **OpenHands is the exception, and it is the opposite.** Its agent runs inside a *session container* on the default bridge, where no DockHub name resolves at all — so it needs `http://host.docker.internal:<published port>/v1` and therefore needs the host port published. Verified live; see [AI-Agents](../AI-Agents/). This is the one case where the rule above is inverted.

**A local provider is optional.** Every interface and agent in DockHub also accepts a cloud API key, so you can use this category, skip it entirely, or mix both.

---

← Back to [all services](../README.md)

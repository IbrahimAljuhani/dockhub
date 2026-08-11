# 🦞 OpenClaw

A personal AI assistant you reach over messaging, with a web gateway of its own.

**The first agent in DockHub** — and an agent is a different kind of thing from anything in [AI](../AI/). [Open WebUI](../AI/open-webui/) shows you a conversation. OpenClaw *acts* on one: it reads pages, runs tools, and takes instructions from text you didn't write.

Read [the category threat model](../README.md) before deploying. Everything below follows from it.

---

## 📗 What you get

| | |
|---|---|
| **Reach it from** | Messaging channels, or its own web gateway on `18789` |
| **Model** | Any provider from [AI](../AI/) on this server, or a cloud API key |
| **Authentication** | A gateway token, generated during onboarding |
| **Docker socket** | **Not mounted** by default — optional, for sandbox mode |
| **Networks** | `ai-net` only by default |

---

## 📥 Installation

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/AI-Agents/openclaw/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/AI-Agents/openclaw/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

**Deploy a model provider first.** [Ollama](../AI/ollama/) is the simplest. Without one, OpenClaw starts fine but has nothing to think with, and you'll be pasting a cloud API key instead.

---

## ⚠️ The image, and a trap worth naming

The official image lives on **GitHub Container Registry**:

```
ghcr.io/openclaw/openclaw
```

Docker Hub carries an official mirror at `openclaw/openclaw` — **and a crowd of unofficial forks under similar names**. For a container that will hold your messaging tokens and run tools on your behalf, pulling a lookalike is not a small mistake. The compose file here pins the GHCR path so there is nothing to get wrong.

**DockHub does not use upstream's `scripts/docker/setup.sh`.** That script builds the image locally by default — a multi-gigabyte Node build on your server, needing heap tuning on small hosts. Official pre-built images exist, so this deploys one.

---

## 🔌 The Docker socket is optional here

Checked against upstream's own Docker documentation, not assumed: the socket powers **sandbox mode**, where agent tools run in their own containers. The gateway itself does not need it.

`deploy.sh` asks, defaults to **no**, and states the trade rather than implying it:

| | |
|---|---|
| **Gained** | Tools run isolated from the gateway itself |
| **Given** | Anything reaching that socket can start a privileged container — root-equivalent on the host |

OpenClaw works fully without it. Start there.

---

## 🕸️ Networks

`ai-net` is all it needs — the model provider. `deploy.sh` offers `main-net` separately, because that is what lets NGINX Proxy Manager serve it on a domain **and** what lets OpenClaw reach every other DockHub service by container name, Portainer included.

Without `main-net` there is no public domain, only a host port on your LAN. That is the trade, stated plainly at deploy time.

Note that OpenClaw reaches *you* **outbound** over messaging — so in normal use it needs no inbound proxy at all.

---

## 🧩 Giving it a model — the one step that isn't scripted

OpenClaw configures its model in an **onboarding wizard**, not from environment variables. DockHub doesn't fake that; `deploy.sh` prints the exact endpoint to paste, discovered from whichever provider is running.

> ⚠️ **Upstream's docs say `http://host.docker.internal:11434`. That is wrong here.** It assumes Ollama runs on the host. In DockHub it's a container on `ai-net`, so the address is:
>
> ```
> http://ollama:11434
> ```
>
> `deploy.sh` prints the right one for whichever provider it finds — llama.cpp and LocalAI use their OpenAI-compatible paths instead.

---

## 🖥️ Browser automation

`deploy.sh` offers a **browser variant** of the image, with Chromium and Xvfb baked in, for page automation. It's considerably larger, and most people never need it — so it's a question rather than a default.

---

## 🛠️ Management Commands

```bash
cd ~/docker/openclaw
```

| Command | Purpose |
|---|---|
| `curl http://<server-ip>:18789/readyz` | The real health answer — unauthenticated by design |
| `docker compose logs -f openclaw` | Follow what the agent is doing |
| `ls workspace/` | Files the agent has created |
| `docker compose pull && docker compose up -d` | Update |

---

## 💾 Backups

**The full volume backup, and that is the opposite of the [providers](../AI/).**

A provider's volume holds downloaded weights — re-fetchable, skipped on purpose. OpenClaw's holds **memories, learned behaviour, conversations and workspace files**. It *produced* those; nothing re-downloads them. So there is no `backup.sh` here: the generic backup in `services.sh` is already correct.

---

## 📌 Notes & Deviations

- **Pre-built image, not upstream's build script** — same reason every other DockHub service pulls rather than builds.
- **No `lib/gpu.sh` call.** An agent never loads a model; the provider does. Same reasoning as Open WebUI.
- **`config/` and `auth/` are created mode `700`** by `deploy.sh` rather than left to Docker. They hold messaging tokens and model keys; root-owned and world-readable is the wrong default for an agent's credential store.
- **`workspace/` is a separate mount** from the config tree, so "where the agent works" and "where its credentials live" can be reasoned about separately.
- **Bonjour/mDNS disabled.** This is a server, not a laptop looking for peers — one less thing listening.
- **`/readyz` drives the self-test.** Unauthenticated and purpose-built, so unlike the providers this service had a real readiness answer from its first deploy.

---

## 🔑 One habit worth keeping

Give it its **own** credentials — a bot token and an API key created for this agent alone. An agent with your primary key can spend it, and an agent acting on text it didn't write is exactly the thing you want scoped.

---

## 📜 License

OpenClaw is licensed separately (see the [official repository](https://github.com/openclaw/openclaw)). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of DockHub.

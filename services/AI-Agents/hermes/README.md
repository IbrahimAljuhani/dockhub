# 🪽 Hermes Agent

<sub>Part of [AI-Agents](../README.md) — read the category's threat model before deploying any agent.</sub>

Nous Research's self-improving agent: persistent memory, skills it writes for itself from experience, cron jobs, and messaging channels. MIT licensed, from [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent).

**The second agent in DockHub, and the first that deploys in one pass.** [OpenClaw](../openclaw/) needs five manual steps after its deploy because its onboarding cannot be scripted. Hermes keeps its configuration in a file, so `deploy.sh` writes the model in and the agent is usable when the script finishes.

---

## 📗 What you get

| | |
|---|---|
| **Interface** | **Outbound messaging** — Telegram, Discord, Slack, WhatsApp, Signal, email |
| **API** | OpenAI-compatible on `8642`, key-protected |
| **Dashboard** | Optional, on `9119` — for inspecting memory, skills and cron |
| **Authentication** | Mandatory and fail-closed. See below |
| **Docker socket** | **Optional**, off by default |
| **Model** | Configured at deploy time from whichever provider is running |
| **State** | `~/docker/hermes/data` — memory, skills, sessions, `SOUL.md` |

The interface point matters: Hermes reaches *you*, so in normal use there is no page to open and no inbound proxy to set up.

---

## 📥 Installation

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/AI-Agents/hermes/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/AI-Agents/hermes/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group — and here that matters more than usual, because your uid is written into `.env`.

**Deploy a provider first.** [Ollama](../../AI/ollama/) is the simplest; `deploy.sh` will query whatever is running for its model list and offer you the choice.

---

## 🔴 The container runs as uid 10000

Upstream runs its processes as a non-root `hermes` user, **uid 10000 by default**, and the data directory is a bind mount owned by you. Without intervention the agent cannot write its own memory.

`deploy.sh` sets `PUID` and `PGID` from `id -u` / `id -g`, which is upstream's supported answer.

> This is worth spelling out because the other agent in this category *appears* not to need it. OpenClaw's image runs as `node` — uid 1000 — and the first login account on a normal Ubuntu box is also 1000. The two coincide by luck. Here they cannot, so the fix is explicit.

Upstream also suggests `chmod -R 755 ~/.hermes` when ownership goes wrong. **This repo deliberately does not**, because that directory contains `.env` with your model and messaging API keys. Matching the uid fixes the problem without widening permissions on a credential store.

---

## 🔐 Authentication is mandatory, and it fails closed

Two independent gates, both documented by upstream rather than discovered by crashing into them:

| Surface | Rule |
|---|---|
| **API server (8642)** | `API_SERVER_KEY` is required whenever the API server is enabled — upstream is explicit that there is **no exception for loopback** |
| **Dashboard (9119)** | The auth gate engages whenever the bind host is not loopback, which inside a container it never is. *"A misconfigured gated dashboard never starts."* |

There is no escape hatch: `HERMES_DASHBOARD_INSECURE=1` is a deprecated no-op.

`deploy.sh` generates a random API key, and — if you enable the dashboard — a username, password and session-signing secret, into a `600` secrets file.

### Why plaintext for the dashboard password

Upstream offers `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` (plaintext) and `..._PASSWORD_HASH` (scrypt). The hash looks more careful, but the plaintext value is **hashed in memory at load and takes precedence over the hash**, so using the hash form would mean running a Python one-liner inside the image to end up in the same place. Either way the value sits in a `600` `.env` on the same host.

### No secure-context requirement

Worth stating because this category taught us to check: OpenClaw's control UI derives a device identity with Web Crypto, so browsers refuse it over plain `http://` from another machine and an **SSH tunnel is mandatory** there. Hermes has no such requirement — plain HTTP works, and the constraint is authentication instead.

`deploy.sh` still binds the dashboard to `127.0.0.1` on the host and points you at a tunnel, but here that is a **privacy choice, not a workaround**:

```bash
ssh -L 9119:localhost:9119 you@your-server
```

---

## 🕸️ Networks and the Docker socket

`ai-net` always — the model provider is the only thing it needs. `main-net` is offered separately, with the category's standard warning: it lets the agent reach every other DockHub service by name, Portainer included.

The Docker socket is **optional**. Upstream ships `docker-cli` in the image and suggests the mount so the agent can use Docker as a tool. Convenience, not a requirement — the same ruling this repo made for OpenClaw.

---

## 🧩 The model, configured at deploy time

`data/config.yaml` is a plain file:

```yaml
model:
  provider: custom
  model: llama3.1:8b
  base_url: http://ollama:11434/v1
  api_key: "none"
```

`provider: custom` is upstream's shape for any OpenAI-compatible endpoint, which all three DockHub providers are. `deploy.sh` asks the running provider what it serves — one query to `/v1/models`, made from a container **on `ai-net`**, because that is the vantage point whose answer means anything — and writes the file.

> 💡 **Upstream's docs get the address right**, which is worth noting: they say to use the container name for an inference server on the same Docker network. OpenClaw's docs say `host.docker.internal` and its wizard offers `127.0.0.1`, both wrong inside a container, and that cost a full debugging round.

**`deploy.sh` writes `config.yaml` only when it is absent.** After the first run the file belongs to the agent — the wizard, the dashboard and Hermes itself all write to it — so a rerun leaves your channels, skills and any model change intact.

To change the model later:

```bash
nano ~/docker/hermes/data/config.yaml
docker compose restart hermes
```

---

## 🛠️ Management Commands

```bash
cd ~/docker/hermes
```

| Command | Purpose |
|---|---|
| `docker compose run --rm -it hermes channels add` | **Add a messaging channel** — the main way you talk to it |
| `docker compose run --rm -it hermes setup` | Upstream's interactive wizard, if you want it |
| `docker compose logs -f hermes` | Follow the agent |
| `nano data/config.yaml` | Model, then `restart` |
| `nano data/SOUL.md` | The agent's personality |
| `docker compose pull && docker compose up -d` | Update — your data is a bind mount and survives |

Check the API by hand:

```bash
curl -H "Authorization: Bearer <key>" http://localhost:8642/v1/models
```

---

## 💾 Backups

**Use them, and unlike the AI providers these capture something irreplaceable.** `data/` holds conversation history, the memories the agent has accumulated, the skills it has written for itself, and `SOUL.md`. None of that is re-downloadable.

There are no named volumes — everything is a bind mount inside the install directory, so the generic backup captures it as part of the directory tree. Take one before you experiment.

---

## 📌 Notes & Deviations

- **`PUID`/`PGID` are set, not left to chance.** The one thing that would otherwise break on every host.
- **`command: gateway run`** — without it the image lands in its interactive CLI, which is not what a service with a restart policy wants.
- **The dashboard binds to `127.0.0.1` on the host**, not the LAN. A single-user management surface whose bundled auth is a password does not belong on a LAN interface by default.
- **`config.yaml` is written once, then owned by the agent.** Same rule this repo applies to OpenClaw's origin allow-list, for the same reason: rewriting user-owned configuration on a rerun is how a working setup quietly breaks.
- **The self-test probes `/v1/models` *with* the key** — one request that proves the server is up, the key works, and the config parsed. It also detects whether the image ships `curl`, `wget` or only `python3` first, because a probe that fails for want of a tool looks exactly like a service that never started.
- **No `lib/gpu.sh`** — an agent never loads a model; the provider does.

---

## 📜 License

Hermes Agent is MIT licensed — see the [official repository](https://github.com/NousResearch/hermes-agent). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of DockHub.

<img src="../../../assets/services/paperclip.svg" alt="" width="64" align="right">

# Paperclip

> *"The open-source app everyone uses to manage agents at work."* — [paperclipai/paperclip](https://github.com/paperclipai/paperclip)

> ℹ️ **The icon above is ours, not theirs.** Paperclip publishes no logo or brand asset (checked 2026-08-18), so this one was drawn for DockHub's catalogue. It carries no endorsement and is not the project's official mark — see [the policy](../../../assets/services/README.md). If upstream ever publishes one, this file gets deleted rather than kept beside it.

Paperclip is where you **run a company of agents**: organisational hierarchy, goals, budgets, tickets and governance. It manages agents — it is not one, and it ships none. You bring the model provider.

|  |  |
|---|---|
| **Image** | `ghcr.io/paperclipai/paperclip` (official, `linux/amd64` + `linux/arm64`) |
| **Licence** | MIT — no account, no licence key, no paid tier to unlock self-hosting |
| **Port** | `3100` (container) |
| **Containers** | 2 — `paperclip-app`, `paperclip-db` (`postgres:17-alpine`) |
| **Docker socket** | **Not required** |
| **Runtime dir** | `~/docker/paperclip/` |

---

## 🚀 Install

From the menu:

```bash
bash services/services.sh
```

Or directly:

```bash
bash deploy.sh
```

You will be asked two things: whether to publish a host port for direct access, and — if not — the public domain you will point NGINX Proxy Manager at. Everything else, including both secrets, is generated.

**First run:** open the URL and create the first account. Paperclip runs in `authenticated` mode, so there is no anonymous access and no default password for anyone to find.

---

## 🔌 The agents, and where they run

**Four agent harnesses ship inside the image** — you do not install them:

| Harness | Installed as | Wants |
|---|---|---|
| **Claude Code** | `@anthropic-ai/claude-code` | `ANTHROPIC_API_KEY` |
| **Codex** | `@openai/codex` | `OPENAI_API_KEY` |
| **Gemini CLI** | `@google/gemini-cli` | `GEMINI_API_KEY` |
| **opencode** | `opencode-ai` | configured in the UI |

Add whichever keys you have to `~/docker/paperclip/.env` and rerun `deploy.sh`. All are optional and passed straight through by `env_file`.

**Where they execute matters.** Paperclip runs these harnesses as **processes inside the app container** — not in containers of their own, and not through the Docker socket. That is why this deployment needs no socket at all.

It also means an agent has whatever the app container has: the database credentials in its environment, and the networks the container is on. Read [the category threat model](../README.md) before pointing an agent at anything you did not write.

### Keeping the work on your own hardware

Paperclip joins **`ai-net`**, so if you run Ollama, llama.cpp or LocalAI from [the AI category](../../AI/), the harnesses can reach them by container name. `deploy.sh` detects whichever provider is running and prints the exact lines to add:

```
ANTHROPIC_BASE_URL=http://ollama:11434      # Claude Code
OPENAI_BASE_URL=http://ollama:11434         # Codex
```

It prints them rather than writing them, because which variable a given harness honours differs — a wrong guess would look like a working local setup while every request still went to the cloud.

---

## 🧭 Why this deployment differs from upstream's

**We pull; upstream's own compose files build.** Both `docker/docker-compose.yml` and `docker/docker-compose.quickstart.yml` in the source tree use `build:`, which turns a deploy into a pnpm monorepo build on your server. Since the authors *also* publish the built image, this pulls it — the same rule as the rest of the catalogue.

**A real database, not the embedded one.** Paperclip can run as a single container with an embedded Postgres; upstream calls that the *local* mode and points production at a real Postgres. A server behind a reverse proxy is production.

**`./state` is a bind mount, not a named volume.** `PAPERCLIP_HOME` holds instance config, agent teams, goals and tickets — produced by you, not re-downloadable. A bind mount inside the install directory puts it where the menu's Backup option can see it. Upstream's named volume would be missed.

**Telemetry is off** (`PAPERCLIP_TELEMETRY_DISABLED=1`). Delete that line from `docker-compose.yml` to restore upstream's default.

**`main-net` only when the proxy needs it.** The agents run inside this container, so its network reach is theirs. Pick a direct host port and NPM is not in the path — so the app never joins `main-net`, and the agents cannot see the other services on it, Portainer included. Pick a domain and it joins, because the proxy has to reach it; `deploy.sh` says so plainly when it does. The database never joins either way.

---

## 💾 Backup

The menu's Backup option runs a `pg_dump` **and** archives the install tree, because Paperclip's state is split between Postgres and `./state`. A raw file copy of a running database is a coin toss; a dump is a consistent snapshot. Restore replays both.

---

## ✅ Verified

Deployed on a real Ubuntu server on **2026-08-18**, first attempt, no fixes needed: 22 layers / 1633 MB pulled, `paperclip-db` reached `healthy`, `paperclip-app` started and answered on 3100.

## ⚠️ Known unknowns

Stated plainly rather than discovered later:

- **Agent runtimes.** Upstream publishes `agent-runtime-*` images alongside the app. Its own compose files mount no Docker socket, so this deployment grants none — and the service starts and serves fine without one. What has **not** been exercised is running an actual agent end to end. If that turns out to need the daemon, it is a security decision to make deliberately (see [AI-Agents](../../AI-Agents/README.md), where OpenHands required exactly that and said so).
- **Resource appetite.** `deploy.sh` suggests a 2 GB limit for the app container as a starting point, not a measured figure.

---

## 📄 Upstream

- Repository — <https://github.com/paperclipai/paperclip>
- Site — <https://paperclip.ing/>

Licensed by its own authors (MIT). This deployment wrapper follows the same [MIT licence](../../../LICENSE) as the rest of DockHub.

---

← Back to [Multi-Agent](../README.md) · [all services](../../README.md)

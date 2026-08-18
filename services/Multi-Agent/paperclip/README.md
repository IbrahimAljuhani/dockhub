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

## 🔌 Adapters: what "Connect a model" is really offering

The **Connect a model** screen lists nine adapter types. Read this before picking one — the list is what Paperclip *supports*, not what this image *contains*.

### "Local" does not mean a local model

`claude_local`, `codex_local`, `gemini_local` — the `local` means **the CLI runs as a process on this host** instead of Paperclip calling a remote service. It says nothing about where the model lives. `claude_local` still talks to Anthropic.

### What is actually usable — three tiers, not one list

Two independent gates decide this, and the source tree tells you neither of them. **A package existing in the repo does not mean the adapter is selectable**, and a selectable adapter does not mean its CLI is in this image.

**✅ Works here**

| Adapter | Why | Wants |
|---|---|---|
| **Claude Code** | `@anthropic-ai/claude-code` is installed | `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` |
| **Codex** | `@openai/codex` is installed | `OPENAI_API_KEY` |
| **Gemini CLI** | `@google/gemini-cli` is installed | `GEMINI_API_KEY` |
| **OpenCode** | `opencode-ai` is installed | a config file — see below |
| **Hermes Gateway** | needs no CLI; drives a running agent | URL + key — see below |

**⚠️ Selectable, but no CLI in this image** — Cursor · Cursor Cloud · Grok Build · Pi · **Hermes** (the *local* one, as opposed to Hermes **Gateway**). Choosing one fails at the first run.

**🚧 Marked "Coming soon" in the UI and not selectable at all** — **OpenClaw Gateway** · **Process** · **HTTP**.

> That last row matters more than it looks. `docs/adapters/process.md` documents the `process` adapter in full — arbitrary `command`, `env`, `cwd` — and an earlier version of this page recommended it as the general escape hatch for wiring up any framework. **It is greyed out in the interface.** Documented is not the same as shipped; the dropdown is the authority.

Add whichever keys you have to `~/docker/paperclip/.env` and rerun `deploy.sh`. All are optional and passed straight through by `env_file`.

### The gateway — driving DockHub's own Hermes

A gateway adapter does not spawn a CLI; it talks to an **already-running agent**. DockHub deploys [Hermes](../../AI-Agents/hermes/), and both containers sit on `ai-net`, so the route is direct by container name.

| Adapter | Status | URL | Credential |
|---|---|---|---|
| **Hermes Gateway** | ✅ working, proven end to end | `http://hermes:8642` | `API_SERVER_KEY` from `~/docker/hermes/data/.env` |
| **OpenClaw Gateway** | 🚧 **"Coming soon" — not selectable yet** | `http://openclaw:18789` | `OPENCLAW_GATEWAY_TOKEN` from `~/docker/openclaw/.env` |

`deploy.sh` detects whichever agent is running and **proves Paperclip can actually reach it** from inside the container — useful for OpenClaw too, so that the day the adapter ships, the route is already known to work.

**The port is not a guess.** Paperclip's own smoke test (`docker/hermes-gateway-smoke/entrypoint.sh`) defaults `API_SERVER_PORT` to `8642` — exactly what our Hermes sets. The two were built to the same number independently.

> ⚠️ **Do not confuse "Hermes" with "Hermes Gateway" in the dropdown.** They are two different adapters and both are listed. Plain **Hermes** is the local CLI harness, which is *not* in this image. **Hermes Gateway** is the one that works.

> 🔑 **Read Hermes' key from `data/.env`, not from its compose `.env`.** Hermes *generates its own* key in its own secrets file, and that file wins. The compose one returns 401. This project already made that mistake once inside Hermes' own deploy.sh; `deploy.sh` here reads the right file and tells you which one it used.

**Two separate checks, on purpose.** `deploy.sh` first proves the port answers from inside `paperclip-app`, then — separately — proves the key is *accepted* (`GET /v1/models` → 200). A single request that proves "running and routable and authenticated" cannot tell you which of the three failed; this project learned that inside Hermes' own deploy script.

### Connecting it, step by step

Agent → **Configuration** → **Adapter** → adapter type **Hermes Gateway**. Paperclip publishes no schema for this adapter anywhere, so these field names come from the running UI:

| Field | Value |
|---|---|
| **API base URL** | `http://hermes:8642` |
| **API key** | from `~/docker/hermes/data/.env` |
| **Paperclip API URL** | `http://paperclip-app:3100` — see below |
| Session key strategy | `Issue scoped` is a sensible default |
| Timeout seconds | `0` (no limit) |
| Event reconnect ms | `2000` |
| **Dangerously allow remote HTTP** | must be **on** — see below |

Then press **Test**, and run one trivial task before trusting it with anything real.

**Verified end to end on 2026-08-19:** `POST /v1/runs` to `http://hermes:8642/v1/runs`, run created, streamed `message.delta` events back, `run.completed`. The handshake works.

### The callback field — use the container name

**Paperclip API URL** is how Hermes calls *back*. The obvious value is your server's IP and published port, and it works — but it makes the integration depend on a host port being published, and sends container-to-container traffic out through the host's network stack and back.

Both containers are on `ai-net`, so prefer:

```
http://paperclip-app:3100
```

That keeps the round trip inside the Docker network and works even when no host port is published at all. Confirm the route before switching:

```bash
docker exec hermes node -e "fetch('http://paperclip-app:3100').then(r=>console.log(r.status)).catch(e=>console.log('FAIL',e.message))"
```

### The HTTP escape hatch — what the warning actually means

Paperclip refuses plain HTTP to a non-loopback gateway unless you enable **Dangerously allow remote HTTP**, and warns:

> *Unsafe dev escape hatch enabled for non-loopback HTTP Hermes traffic. Use HTTPS before using this gateway for real credentials.*

That warning is correct in general and **overstated for this topology** — but not empty. The honest reading:

- The traffic is `paperclip-app → hermes:8642` across `ai-net`, a private Docker bridge. It never touches your LAN or the internet, so there is no network path for an outside listener.
- What it *is* exposed to: **another container on `ai-net`**. A container holding `NET_RAW` can attempt to intercept traffic on a shared bridge, and the Hermes API key travels in that request. Paperclip's own container drops `NET_RAW` — the other members of `ai-net` are not all so restricted.

So: acceptable on a host where you control everything on `ai-net`, which is the normal DockHub case. **Not** acceptable if you ever put a container you do not trust on that network. There is no HTTPS option here without putting a TLS terminator in front of Hermes, which DockHub does not currently do.

**Where they execute matters.** Paperclip runs these harnesses as **processes inside the app container** — not in containers of their own, and not through the Docker socket. That is why this deployment needs no socket at all.

It also means an agent has whatever the app container has: the database credentials in its environment, and the networks the container is on. Read [the category threat model](../README.md) before pointing an agent at anything you did not write.

## 🏠 Running on your own model

Paperclip joins **`ai-net`**, so an Ollama, llama.cpp or LocalAI deployed from [the AI category](../../AI/) is reachable by container name. There are two routes, and they are not equally solid.

### The supported route: OpenCode

OpenCode is the multi-provider harness, and this image ships with **`OPENCODE_ALLOW_ALL_MODELS=true`** already set — upstream expects custom models here. Its config lives at `$HOME/.config/opencode/opencode.json`, and since the image sets `HOME=/paperclip`, that is:

```
~/docker/paperclip/state/.config/opencode/opencode.json
```

Inside the bind mount, so it survives container replacement and is captured by backups. Point it at your provider by **container name** — `localhost` is the container itself, not your Ollama:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama",
      "options": { "baseURL": "http://ollama:11434/v1" },
      "models": { "qwen3.5": { "name": "qwen3.5" } }
    }
  }
}
```

No API key is needed for a local provider.

> ⚠️ **OpenCode needs a context length of 64k or more.** Ollama's default is far below that, and the failure does not announce itself — the agent simply truncates and behaves badly. Raise it on the model you serve before blaming the setup. DockHub has been caught by Ollama's *allocated* context differing from a model's advertised maximum before; check what is actually allocated, not what the model card claims.

### The unsupported route: base-URL variables

Every adapter has a generic `env` object, so you *can* hand `ANTHROPIC_BASE_URL` to Claude Code or `OPENAI_BASE_URL` to Codex, and those CLIs do honour them.

**But Paperclip's documentation never mentions this.** It works because the adapter passes arbitrary environment through and the CLI happens to read it — not because anyone promised it would. An earlier version of this page presented it as a supported path; that was overstated. Treat it as a mechanism that may break in an update, and prefer OpenCode.

---

## 🧭 Why this deployment differs from upstream's

**We pull; upstream's own compose files build.** Both `docker/docker-compose.yml` and `docker/docker-compose.quickstart.yml` in the source tree use `build:`, which turns a deploy into a pnpm monorepo build on your server. Since the authors *also* publish the built image, this pulls it — the same rule as the rest of the catalogue.

**A real database, not the embedded one.** Paperclip can run as a single container with an embedded Postgres; upstream calls that the *local* mode and points production at a real Postgres. A server behind a reverse proxy is production.

**`./state` is a bind mount, not a named volume.** `PAPERCLIP_HOME` holds instance config, agent teams, goals and tickets — produced by you, not re-downloadable. A bind mount inside the install directory puts it where the menu's Backup option can see it. Upstream's named volume would be missed.

> 🔑 **`./state` is a credentials directory, not just data.** The image sets `HOME=/paperclip`, so every agent CLI keeps its own configuration *and logins* in there — `.claude/`, `.config/opencode/`, `.codex/`. That is a deliberate and good choice by upstream: it means your agent setup survives container replacement and is captured by backups. It also means the directory holds OAuth tokens and API keys, so `deploy.sh` sets it `0700`, and **your backup archives contain those credentials** — store them accordingly.

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

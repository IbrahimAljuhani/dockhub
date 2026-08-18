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

### Only four of the nine will actually run

The image installs four harnesses. The others are offered by the interface but have no CLI behind them here, and picking one fails at the first run.

| Adapter | In this image? | Wants |
|---|---|---|
| **Claude Code** | ✅ `@anthropic-ai/claude-code` | `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` |
| **Codex** | ✅ `@openai/codex` | `OPENAI_API_KEY` |
| **Gemini CLI** | ✅ `@google/gemini-cli` | `GEMINI_API_KEY` |
| **OpenCode** | ✅ `opencode-ai` | configured in a file — see below |
| Cursor · Cursor Cloud · Grok Build · Pi | ❌ | not installed |
| **Hermes** · **OpenClaw** | ❌ *as CLIs* | but see the gateways below |

Add whichever keys you have to `~/docker/paperclip/.env` and rerun `deploy.sh`. All are optional and passed straight through by `env_file`.

### Two adapters that are not harnesses at all

- **`process`** — runs *any* shell command with your own `command`, `env` and `cwd`. This is the real escape hatch for wiring up a framework Paperclip has never heard of.
- **`http`** — **not** an inference bridge. It POSTs a webhook to an agent service you host elsewhere, which then calls Paperclip's API back. Useful, but not a way to plug in a model.

### The gateways — and why they matter *here*

`hermes_gateway` and `openclaw_gateway` do not spawn a CLI; they talk to an **already-running agent**. DockHub deploys both [Hermes](../../AI-Agents/hermes/) and [OpenClaw](../../AI-Agents/openclaw/). So Paperclip can drive the agents you already run rather than its own built-in ones. Not wired up yet — noted because nothing else in this catalogue can do it.

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

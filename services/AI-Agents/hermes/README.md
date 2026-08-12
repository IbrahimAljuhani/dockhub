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

### The uid is re-checked on every deploy, not frozen

Writing `id -u` into `.env` once is correct until the deployment moves — and **restore is exactly that case**. A backup taken here and unpacked on a host whose account is `1001` would carry `PUID=1000`, so the container would run as a user that does not own its own data directory. The symptom is an opaque permission error that names no uid at all.

So `deploy.sh` compares them every run and corrects the drift. It also tells you the half it cannot do itself:

```
[!] This deployment was created by uid 1000, but you are 1001.
[!] Updating PUID/PGID so the container runs as you.
[!] Some files under data/ are still owned by the old user, and only
[!] root can hand them over. Hermes will fail to write until you run:
[!]   sudo chown -R 1001:1001 ~/docker/hermes/data
```

Changing `PUID` alone is not enough — the *files* still belong to the old uid, and chowning another user's files needs root, which this script deliberately does not have.

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

### Saying yes to the socket gets a second question

Mounting it creates a chain that is easy to miss, and Hermes names it at every startup:

> *API server is network-accessible (0.0.0.0) AND the terminal backend is `local` (unsandboxed). Agent work dispatched through this endpoint runs as the host user with full terminal/file access. Strongly consider a sandboxed backend (`terminal.backend: docker`).*

```
agent runs a command
  └─ inside the hermes container        ← terminal.backend: local (the default)
       └─ which now holds docker.sock
            └─ so it can:  docker run --privileged -v /:/host …
                 └─ root on the whole host
```

Three possible setups, and the default is the weakest of them:

| | Socket | Backend | The agent can reach |
|---|---|---|---|
| **A** | ❌ | `local` | its own container only |
| **B** | ✅ | `docker` | a hardened per-session container |
| **C** | ✅ | `local` | **the entire host** |

`deploy.sh` therefore asks a **second** question when you mount the socket, defaulting to the sandbox. Answering the first `y` should not silently buy you **C**.

What **B** actually applies, per upstream's security page: **all Linux capabilities dropped**, then only `DAC_OVERRIDE`, `CHOWN` and `FOWNER` added back; `no-new-privileges`; a 256-process limit; `/tmp` and `/var/tmp` as `nosuid` tmpfs. Upstream notes that its usual dangerous-command checks are *skipped* under this backend, "because the container itself is the security boundary".

The setting is written with Hermes' own CLI rather than hand-edited YAML — the tool knows its schema, a guessed nesting does not:

```bash
docker exec -it hermes hermes config set terminal.backend docker
docker compose restart hermes
```

> ⚠️ **One thing this repo did not verify:** whether the sandbox container itself is denied the Docker socket. Reasoning says it must be — moving the agent's shell off the container that holds the socket is the entire point — but upstream's security page does not say so, and reasoning is not evidence. If you depend on that boundary, check it: `docker exec -it hermes hermes config get terminal`.

**If the agent does not actually need Docker as a tool, option A is stronger than any sandbox and costs nothing.** What is never granted cannot be misused.

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

### 🔴 The model needs a 64K context window

**Hermes refuses to run below 64,000 tokens**, and the failure is late and confusing: the container starts, the API answers, the self-test passes — and then every message comes back as

```
agent init failed: Model qwen2.5-coder:7b has a context window of 32,768 tokens,
which is below the minimum 64,000 required by Hermes Agent.
```

Found live. A 7B coding model is a perfectly reasonable pick and is simply ineligible; `llama3.1:8b` reports 131,072 and works.

`deploy.sh` now checks before you commit. Ollama publishes `context_length` per model on `/api/tags` — the OpenAI-compatible `/v1/models` does not — so the menu is annotated where the number is knowable and says nothing where it isn't:

```
   1) qwen2.5-coder:7b   — 32768 ctx  ❌ too small for Hermes
   2) llama3.1:8b        — 131072 ctx  ✅
```

The check also runs when a provider serves **exactly one** model and there is no menu at all — which is precisely the case that got through the first time.

If your server under-reports a window the model really has, Hermes' own error suggests the override, and `deploy.sh` will write it for you:

```yaml
model:
  context_length: 131072
```

Only do that when you know the true window is 64K+. Declaring a number larger than the truth simply moves the failure to a context overflow later.

---

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
| `docker exec -it hermes hermes channels add` | **Add a messaging channel** — the main way you talk to it |
| `docker exec -it hermes hermes whatsapp` | Per-platform shortcuts also exist: `telegram`, `discord`, `slack` … |
| `docker exec -it hermes hermes status` | Model, provider, which channels are configured, gateway PID |
| `docker exec -it hermes hermes setup` | Upstream's interactive wizard, if you want it |
| `docker compose logs -f hermes` | Follow the agent |
| `nano data/config.yaml` | Model, then `restart` |
| `nano data/SOUL.md` | The agent's personality |
| `docker compose pull && docker compose up -d` | Update — your data is a bind mount and survives |

> 🔴 **`docker exec`, never `docker compose run`.** This image is supervised by **s6**: its entrypoint starts the gateway *and* the dashboard whatever command you pass it. So `compose run` silently brings up a **second, competing Hermes** next to the one already running, floods your interactive prompt with its own startup banner —
>
> ```
> Choose [1/2]: → Using web dist from HERMES_WEB_DIST: ...
> ⚕ Hermes Gateway Starting...
> HERMES_DASHBOARD_READY port=9119
> ```
>
> — and leaves `Previous gateway life … exited UNCLEANLY` in the lifecycle ledger once the extra one is torn down. Found live while adding a WhatsApp channel. `docker exec` runs inside the container that is already up, which is what every command in this table actually wants.
>
> Note this differs from [OpenClaw](../openclaw/), where `compose run` is correct — that image has no supervisor, so a throwaway container really is throwaway.

> ⚠️ **When a wizard finishes and says "start the gateway: `hermes gateway`" — don't.** It is already running as the container's main process. That instruction is written for a host install, and following it inside the container starts a second gateway beside the first. Restart the container instead, which is what "pick up the new configuration" means here:
>
> ```bash
> docker compose restart hermes
> ```
>
> This is the **third** upstream instruction in this category that assumes a laptop: OpenClaw's dashboard offers an `openclaw update` that cannot work in a container, its wizard defaults Ollama to `127.0.0.1`, and Hermes' channel setup ends by telling you to start something that is already started. None of them are bugs — they are simply written for the install shape their authors expect. Read every "next step" from upstream with that in mind.

Check the API by hand:

```bash
curl -H "Authorization: Bearer <key>" http://localhost:8642/v1/models
```

---

## 📱 Adding a channel — one decision depends on hardware you may not have

```bash
docker exec -it hermes hermes channels add     # or: hermes whatsapp
```

WhatsApp's wizard opens with a choice that decides whether anything will ever work, and the answer depends on how many phone numbers you own:

| Mode | Needs | How you talk to it |
|---|---|---|
| **1. Separate bot number** | **TWO numbers** — the wizard says so: *"Requires a second phone number"* | Others message the bot's number |
| **2. Personal number (self-chat)** | One number | You message yourself |

> 🔴 **Picking mode 1 with a single number produces total silence.** Verified live. The QR gets scanned by your phone, so *your* number becomes the bot; the allow-list then holds that same number; and reaching "the bot" would mean messaging yourself — which is mode 2's job. Mode `bot` does not pick up self-chat, so the message never reaches Hermes at all.
>
> The tell is that **the log stays completely empty** — no rejection, no error, nothing. Combined with the startup warning that messaging platforms *"deny unknown senders"* by default, silence is the designed outcome for anything unrecognised. Re-run the wizard and choose **2**, then `docker compose restart hermes`.
>
### Changing the mode afterwards

**The wizard asks this once in the life of a deployment.** Re-running it prints `✓ Mode: separate bot number` as a statement and moves on — it only re-offers the allow-list and re-pairing. And `hermes whatsapp --help` carries **no options at all**, so there is no reset flag to reach for. Both verified.

The way back is to remove what it reads, so the question returns:

```bash
sed -i '/^WHATSAPP_MODE=/d' ~/docker/hermes/data/.env
docker exec -it hermes hermes whatsapp          # now asks again — choose 2
docker compose restart hermes
```

Answer **N** to "Re-pair?" — the session is fine, only the mode was wrong. Then WhatsApp → **Message Yourself**.

> Don't guess the value and write it into `.env` by hand. `bot` is mode 1's; mode 2's could be `self`, `personal`, or something else, and a plausible-looking wrong value fails **exactly as silently** as the problem you are trying to fix. Let the wizard write it.

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

# 🤖 AI-Agents

Agents that **do work for you**. You give one a task and it acts, using tools — it is not a chat box, and you are not designing a workflow.

| Category | Question it answers |
|---|---|
| [AI](../AI/) | *Run a model, and chat with it.* |
| **AI-Agents** (here) | *An agent does work for me.* |
| [Multi-Agent](../Multi-Agent/) | *I build what the agents do.* |

---

## 📋 What's here

| | What it's for | Image | Port |
|---|---|---|---|
| ✅ [**OpenClaw**](openclaw/) | A personal assistant reachable over messaging, with a web gateway of its own. The broadest control plane of the three. | `ghcr.io/openclaw/openclaw` | `18789` |
| ✅ [**Hermes**](hermes/) | A leaner, more personal assistant with a **learning loop** — built for repeated and scheduled work that should improve over time. Reachable over WhatsApp, Slack and other channels, and exposes its own OpenAI-compatible gateway. | `nousresearch/hermes-agent` | `8642` · `9119` |
| ✅ [**OpenHands**](openhands/) | A **software engineering** agent. It writes code, runs it, and browses — a different job from the two above. You give it a coding task in a browser; it is not something you message. | `docker.openhands.dev/openhands/openhands` | `3001` |

> OpenHands publishes on `3000` upstream. DockHub defaults it to **`3001`**, because `3000` is [Open WebUI](../AI/open-webui/)'s default — and Open WebUI is exactly what someone deploying an agent is likely to already be running.

---

## 🧠 What makes an agent different from everything else in DockHub

Every other service here does what *you* tell it. An agent does what **text tells it** — a web page it reads, a repository it clones, an issue someone filed, a message from a stranger. And unlike a chat model, it has **tools**: a shell, a network, sometimes a container runtime.

That combination is the whole story, and it is worth stating without drama:

> **The attack is one step: something the agent reads tells it to run a command.**

No exploit, no vulnerability, no CVE. The agent is working exactly as designed. This is called *prompt injection*, and there is no known complete defence against it at the model level — which is precisely why the answer here is not "trust the model" but **"limit what the tools can reach."**

The rule this category is built on:

> **The agent needs tools. It does not need your host.**

---

## 🛡️ How DockHub contains them

Containment here is **layered and verifiable**. Every claim below is something you can check yourself with one command — that matters more than any adjective, so the commands are printed beside the claims.

### Layer 1 — Network: the agent sees the model, and nothing else

| | Default | Effect |
|---|---|---|
| `ai-net` | ✅ always | Reaches the model provider. That is all it needs to work. |
| `main-net` | ❌ opt-in, warned | Would let it reach **every other DockHub service by name**, including Portainer and its Docker socket |

An agent on `ai-net` alone cannot resolve `nextcloud`, `portainer`, or your database. `deploy.sh` names Portainer explicitly in the warning before you opt in.

```bash
docker inspect hermes --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
```

### Layer 2 — Binding: no unauthenticated surface on your LAN

Where an agent's web interface has **no login of its own**, DockHub binds it to `127.0.0.1` on the server rather than `0.0.0.0`. It is reached over SSH, not over the network.

| Interface | Bind | Why |
|---|---|---|
| OpenHands UI | `127.0.0.1:3001` | **It has no authentication at all** |
| Hermes dashboard | `127.0.0.1:9119` | Credentials are generated, but it is an inspection surface |
| Hermes API | host port, optional | Protected by a generated bearer key |

```bash
docker port openhands        # expect 127.0.0.1, never 0.0.0.0
```

### Layer 3 — The Docker socket: off unless the design requires it

Checked against each project's own documentation, and the answer is **not the same for all three**:

| | `/var/run/docker.sock` | DockHub's default |
|---|---|---|
| **OpenClaw** | Optional — only for its sandbox mode | **Off.** Offered explicitly. |
| **Hermes** | Optional — the image ships `docker-cli` | **Off.** Offered explicitly. |
| **OpenHands** | **Required by architecture** — it starts a fresh container per session | On, behind a **typed** acknowledgement |

Two of the three run with no socket at all unless you ask for it. For the third it is not optional, so the gate is not a `y/n` — you type `i-accept` after reading what it costs, and the answer is recorded in `.env` so a rerun cannot inherit consent you never gave.

### Layer 4 — The sandbox: where the agent's commands actually run

This is the strongest layer, and the one most people do not know exists.

**Hermes** can run every tool call in a **separate hardened container** instead of its own (`terminal.backend=docker`, which DockHub sets for you when you accept the socket):

- **all** Linux capabilities dropped, then only `DAC_OVERRIDE`, `CHOWN`, `FOWNER` added back
- `no-new-privileges` — a setuid binary cannot escalate
- a **256-process** limit — fork bombs die instead of taking the host down
- `nosuid` tmpfs for `/tmp` and `/var/tmp`
- no volumes mounted by default

**And what it costs, because a layer described only by its strengths is a sales pitch.** With no volumes mounted, files the agent writes to container-local paths — `/output/…`, `/workspace/…` — do not exist anywhere you can reach. Hermes says so on every start:

> *Docker backend is enabled for the messaging gateway but no explicit host-visible output mount … MEDIA file delivery can fail for container-local paths.*

Text answers are unaffected; **sending you a file it generated can fail.** That is the same property that makes the layer worth having, seen from the other side. If you need file delivery, add a mount to Hermes' own terminal volume list (`hermes config get terminal`) and accept that the sandbox now has one door into your filesystem — deliberately, and only that one.

**OpenHands** goes further by architecture: **every session gets its own fresh container**, and the code the agent writes never executes in the app container at all. Isolation is the entire reason it wants the Docker socket. That is a security-*positive* design, and it is why DockHub grants it rather than refusing.

```bash
docker exec -it hermes hermes config get terminal
```

### Layer 5 — Who may talk to it

Messaging agents **deny unknown senders by default**. A stranger who finds your bot's number gets nothing; you add yourself to an allowlist explicitly. This is upstream behaviour, and DockHub documents it rather than switching it off — because the failure mode (silence) looks exactly like a broken deploy, and people "fix" it by disabling the protection.

### Layer 6 — Kernel capabilities: a smaller toolkit inside the container

Docker grants every container 14 Linux capabilities by default. All three agents here drop three of them and refuse privilege escalation:

```yaml
security_opt: [ "no-new-privileges:true" ]
cap_drop:     [ MKNOD, NET_RAW, AUDIT_WRITE ]
pids_limit:   4096
```

| | What it removes | Why an agent does not need it |
|---|---|---|
| `MKNOD` | Creating device nodes | Nothing here creates devices |
| `NET_RAW` | Raw sockets | Removes ARP and DNS spoofing against other containers on `ai-net` |
| `AUDIT_WRITE` | Writing kernel audit records | Removes a way to pollute the host's audit trail |
| `no-new-privileges` | — | A setuid binary inside cannot regain what was dropped |
| `pids_limit` | — | A fork bomb becomes one dead container, not a dead host |

**Where these numbers come from.** They are not copied from a hardening blog. In August 2026 we deployed [OpenSandbox](https://github.com/opensandbox-group/OpenSandbox) — Alibaba's sandbox runtime for AI agents — on a real server and inspected the container it produced. Its configuration drops *nine* capabilities, which reads impressively until you decode the `CapEff` mask it actually yields: `0x800405fb`, which is **11 capabilities where Docker's default is 14**. Six of its nine were never granted in the first place. These three are the entire real difference, so these three are what we adopted.

**Check it on your own host** rather than believing this table:

```bash
docker exec openclaw grep -E '^(CapEff|NoNewPrivs)' /proc/self/status
docker inspect openclaw --format '{{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{.HostConfig.PidsLimit}}'
```

### Layer 7 — Identity and blast radius

- Give the agent **its own** API keys and bot tokens, never your primary ones. An agent holding your main key can spend it.
- Containers run as a non-root user where the image allows it (Hermes: `PUID`/`PGID`, uid 1000 by default here).
- `.env` and generated secrets files are `chmod 600`; agent data directories are the agent's own.

---

## 🚧 What this does **not** cover

A threat model that only lists its strengths is marketing. These are the real edges, stated plainly — and knowing them is what makes the layers above worth trusting.

**1. The Docker socket is root-equivalent, and Layer 6 does not change that.** When you enable it, anything that reaches it can ask the daemon to start a *new* container that is privileged and mounts the host filesystem — and that new container inherits none of the capabilities dropped above. Dropping capabilities from the process that holds the key does not lock the door. Layer 6 buys something real and smaller: a flaw that yields code execution *inside* the agent container without reaching the socket now has a shorter list of things to try. DockHub does not refuse the socket — [core infrastructure can install Portainer with the same one](../../README.md) — but the difference is who holds the trigger: Portainer is driven by you, an agent by a language model reading untrusted text.

> The same applies to the session runtimes OpenHands starts. They are created **through the socket**, not by its compose file, so none of Layer 6 reaches them.

**2. OpenHands has no authentication of its own.** Not a weak login — none. Anyone who reaches its port gets a fully privileged agent. This is why the port is loopback-only and why it must never be published to `0.0.0.0`, whatever a tutorial suggests.

**3. OpenHands does not ask before acting.** Observed on a live first session:

```
Confirmation policy set to: kind='NeverConfirm'
```

Upstream's default is to run the commands it decides on **without confirming**. Nothing in DockHub sets that; it is changeable in the UI's settings, and worth changing.

**4. OpenHands session containers publish ports on `0.0.0.0`.** Measured on a live run:

```
8000/tcp -> 0.0.0.0:36137        8011/tcp -> 0.0.0.0:57493
8001/tcp -> 0.0.0.0:57443        8012/tcp -> 0.0.0.0:34577
```

Those are created by the app through the Docker socket — **not by DockHub's compose file** — so our careful `127.0.0.1` binding on the app does not extend to them. The session's workspace and API are reachable from your LAN on random high ports for as long as the session lives. Keep the host behind a firewall; this one is not ours to close.

**5. Prompt injection is unsolved.** Every layer above assumes the model *will* eventually be talked into something. That is the design premise, not a pessimistic aside.

---

## 🔌 Reaching each agent

| Agent | How you reach it | Why |
|---|---|---|
| **OpenClaw** | SSH tunnel, then `http://localhost:18789` | Its UI needs a browser **secure context** (Web Crypto for a device identity) — plain `http://` to a server IP cannot work, however correct your token |
| **Hermes** | Messaging (WhatsApp, Slack…). Dashboard via SSH tunnel | Outbound by design; in normal use you never open a page |
| **OpenHands** | **SSH SOCKS proxy** — see below | A plain port-forward is not enough, and this surprises everyone |

### OpenHands: use a SOCKS proxy, not `ssh -L`

The obvious approach fails in a way that looks like a broken agent:

```bash
ssh -L 3001:localhost:3001 you@server     # ⚠️ loads the page, then "Disconnected"
```

The page appears, and the UI reports **Disconnected** with `Network Error` in its side panel. Nothing is broken. Your browser also needs to reach the **session container**, which publishes its ports on **random numbers that change every conversation** (`36137`, `57443`, …). You cannot forward a port you cannot predict.

A dynamic proxy solves it, because every address the page asks for is opened from the server's side:

```bash
ssh -D 1080 you@server
```

Then point the browser at SOCKS5 `127.0.0.1:1080`:

- **Firefox** — Settings → Network Settings → Manual proxy → **SOCKS Host** `127.0.0.1`, Port `1080`, SOCKS v5, and tick **Proxy DNS when using SOCKS v5**.
  Then in `about:config` set **`network.proxy.allow_hijacking_localhost = true`**.
  ⚠️ Without it nothing will work: that same dialog states *"Connections to localhost, 127.0.0.1/8, and ::1 are never proxied"* — so the one address you need is the one Firefox refuses to send. Put the value in **SOCKS Host**, not the HTTP Proxy field above it.
- **Chrome** — launch with `--proxy-server="socks5://127.0.0.1:1080"`

Now open **`http://127.0.0.1:3001`**. Conversations work end to end.

> This is also why OpenHands is marked ✅ here rather than 🚧: it works completely, but reaching it is genuinely different from every other service in DockHub, and that difference is documentation — not a defect.

---

## 🧩 Giving an agent its model

Every agent needs one — a provider from [AI](../AI/) on this server, or a cloud API key. Neither is assumed.

**They disagree completely on how**, which decided how far each `deploy.sh` could go:

| | Where the model is configured | Scriptable? |
|---|---|---|
| **Hermes** | `data/config.yaml`, a plain file | ✅ **Yes** — `deploy.sh` writes it, and the agent works when the script ends |
| OpenClaw | An onboarding wizard, no environment variable | ❌ No — manual steps follow the deploy |
| OpenHands | **The web UI only** | ❌ No |

Where it can be scripted, DockHub does it: Hermes' `deploy.sh` asks the running provider what it serves — from a container **on `ai-net`**, the only vantage point whose answer means anything — and writes the choice in. Where it cannot, DockHub **does not fake it**: it prints the exact endpoint to paste and leaves the wizard alone.

### ⚠️ The provider address is not the same for all three

| Agent | Base URL | Why |
|---|---|---|
| OpenClaw, Hermes | `http://ollama:11434/v1` | The agent runs **in its own container**, on `ai-net`, where the name resolves |
| **OpenHands** | `http://host.docker.internal:11434/v1` | The agent runs in the **session container**, on the default bridge, where **no DockHub name resolves at all** |

Verified from inside a live session runtime:

```
getent hosts ollama                       →  (nothing)
wget host.docker.internal:11434/api/tags  →  your model list
```

> An earlier version of this page said the opposite — *"use the container name, never `host.docker.internal`"* — which was correct for the app container and wrong for the one that actually calls the model. `deploy.sh` now derives the right URL from the provider's published port and prints it.

### ⚠️ The context window your provider *advertises* is not what it *serves*

A model reports the window it was trained with; the server decides what it allocates. Measured live: `gemma4:e4b` advertising **131,072** while Ollama served **4,096** — because `OLLAMA_CONTEXT_LENGTH` was unset and Ollama sizes it from available VRAM.

That matters more for agents than for chat, because an agent spends most of its window before you type:

> **OpenHands' opening prompt measured 17,742 tokens** — system prompt, tool schemas, skills — on an empty conversation. Four times the entire 4,096 default.

The symptom is memory loss with no error anywhere. See [Ollama](../AI/ollama/) for the setting and its VRAM cost.

---

## ⚠️ A green self-test does not mean a working agent

Every agent here shipped a self-test that passed while the agent could not answer a single message. This is a property of the category, not a flaw in the scripts.

| What a deploy self-test can prove | What it cannot |
|---|---|
| The container is running | The model is eligible |
| The web/API surface answers | The model provider is reachable **from where the agent runs** |
| The auth token works | The messaging channel is wired to a reachable person |
| The config file parsed | The agent will actually reply |

Three lived examples, all of which looked identical from outside — silence:

- **Hermes** passed every check, then answered `agent init failed` to everything: the model's advertised context was 32,768 against a required 64,000.
- **OpenHands** created conversations and queued every message forever. Its session container was posting results back to a port nothing was listening on. No error surfaced in the UI.
- **Hermes on WhatsApp** paired successfully and then replied *"I don't recognize you yet"* — the allowlist had been set from a phone number typed one digit short. The wizard confirmed `Allowed users set` for a number that could never message it.

The habit that follows: **a deploy is not finished until a message has gone in and a reply has come out.** For an agent, that round trip is the only real test, and no `deploy.sh` can run it for you.

---

## 🧭 Questions to ask an agent image before writing a line

Every one of these cost at least a round when it was discovered by running into it. They share a root: **these programs assume a human at a terminal on `localhost`**, and a container with a scripted deploy is neither.

| Ask | Because, in practice |
|---|---|
| **Does it refuse to start unconfigured?** | OpenClaw crash-looped on `Missing config`, and **no environment variable existed** for the setting — only its own CLI could write it |
| **Does it demand auth on a non-loopback bind?** | Both messaging agents do, and both **fail closed** — so credentials must exist *before* first start |
| **Does its UI need a browser secure context?** | OpenClaw's does. Hermes' and OpenHands' do not. **Three agents, one requirement between them**: assume nothing |
| **Where does its work actually run?** | OpenHands' answer is "a different container, on a different network, that you did not create" — which changed its model URL, its callback, and how you browse to it |
| **Is its config seeded in memory or written to disk?** | OpenClaw seeds its origin allow-list *without writing it*. The dashboard worked for two and a half minutes, then broke with no restart in between |
| **Is the image supervised?** | Hermes runs under **s6**, so `docker compose run` starts a *second* gateway beside the first. Prefer `docker exec` |
| **What does it run as?** | Hermes: uid 10000 upstream, so `PUID`/`PGID` are mandatory with a bind mount. OpenClaw: `node`, uid 1000. **OpenHands: root**, so its `state/` is root-owned and needs `sudo` to remove |

---

## 💾 Backups: the opposite of the providers

| | What its data holds | Backup |
|---|---|---|
| [Providers](../AI/) | Downloaded model weights | Config only — weights are skipped |
| **Agents** | Memories, learned skills, conversations, workspace files | **Everything** |

A provider *downloads*. An agent *produces*. What an agent accumulates is yours and exists nowhere else.

---

## ✅ The habit

1. Give the agent the **narrowest** access that does your job — start without the Docker socket and without `main-net`.
2. Turn the sandbox on. It is one prompt, and it is the layer that matters most.
3. Treat everything it reads as untrusted input, because it is.
4. Give it **its own** credentials, never your primary ones.
5. Change OpenHands' confirmation policy if you value being asked.
6. Back it up — unlike a provider, what it holds cannot be re-downloaded.

---

← Back to [all services](../README.md)

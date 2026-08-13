# 🤖 AI-Agents

Agents that **do work for you**. You talk to one and it acts, using tools — it isn't a chat box, and you don't design anything.

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
| ✅ [**Hermes**](hermes/) | A leaner, more personal assistant with a **learning loop** — built for repeated and scheduled work that should improve over time. Reachable over Telegram, Discord, Slack, WhatsApp, Signal or email, and exposes its own OpenAI-compatible gateway. | `nousresearch/hermes-agent` | `8642` · `9119` |
| ✅ [**OpenHands**](openhands/) | A **software engineering** agent. It writes code, runs it, and browses — a different job from the two above. Give it a coding task in a browser; it is not something you message. | `docker.openhands.dev/openhands/openhands` | `3001` |

> OpenHands publishes on `3000` upstream. DockHub defaults it to **`3001`**, because `3000` is [Open WebUI](../AI/open-webui/)'s default — and Open WebUI is exactly what someone deploying an agent is likely to already be running.

---

## 🧠 The principle behind every design choice here

An agent takes instructions from text you don't control — a web page it reads, a repository it clones, a message someone sends it — and it has **tools**. That combination exists nowhere else in DockHub.

The rule, carried over from [Security-Lab](../Security-Lab/) and adapted:

> **The agent needs tools. It does not need your host.**

The attack isn't exotic. It's one step: *something the agent reads tells it to run a command.* Everything below follows from taking that seriously.

---

## 🕸️ Why agents sit on `ai-net` by default

[Open WebUI](../AI/open-webui/) is on `main-net` and that's fine — it displays a conversation and executes nothing. An agent executes. **The ability to run commands is what changes the network posture**, and that's the line this category draws.

On `main-net` an agent can reach every other DockHub service by container name — including **Portainer, which mounts the Docker socket**. So the chain from "a web page said so" to "root on the host" is short.

> ⚠️ **For OpenHands, read that claim narrowly.** It applies to the *app* container. The shell the agent actually types into lives in a separate session runtime, and `docker inspect` on a live one shows it attached to the **default bridge**, not to `ai-net` and not to `main-net`. So the network answer you gave does not describe where its commands run.
>
> That cuts both ways. The runtime cannot resolve `ollama` or any other DockHub service by name — but it *is* given `host.docker.internal`, pointing at the docker0 gateway, which reaches **every port published on this host**. Network isolation for that container is therefore weaker than the category table below implies, and the honest boundary around it remains the Docker socket, not the network.

| | Default | Why |
|---|---|---|
| `ai-net` | ✅ always | It's all the agent actually needs: the model provider |
| `main-net` | ❌ opt-in, warned | Only if you want NGINX Proxy Manager to serve a public domain |

**The honest trade-off:** without `main-net`, NPM cannot proxy the agent, so there is **no public domain** — only a host port on your LAN. `deploy.sh` offers `main-net` explicitly and names Portainer in the warning, the same way the providers' host-port prompt names the missing authentication.

Worth knowing: OpenClaw and Hermes reach *you* **outbound** over Telegram or Slack. In normal use they need no inbound proxy at all.

---

## 🔌 The Docker socket

Checked against each project's own documentation rather than assumed — and the answer is not the same for all three:

| | `/var/run/docker.sock` | DockHub's default |
|---|---|---|
| **OpenClaw** | **Optional** — only for its sandbox mode. Upstream is explicit that the gateway itself doesn't need it. | Off. Offered explicitly. |
| **Hermes** | **Optional** — the image ships `docker-cli` so agent tools *can* drive the host daemon. | Off. Offered explicitly. |
| **OpenHands** | **Required by architecture** — it starts a fresh runtime container per session to sandbox the code it runs. | On, behind a written acknowledgement. |

**OpenHands is the exception, and it gets its own gate.** Its intent is security-*positive*: it isolates execution away from itself. But the effect on the host is the one that makes Portainer sensitive — anything reaching that socket can start a privileged container.

DockHub does not refuse it, and refusing would be inconsistent: **core infrastructure already installs Portainer with that same socket**, and prints a warning. What differs is who holds the trigger — Portainer is driven by *you*, OpenHands by a language model. So it takes a typed acknowledgement rather than a `y/n`, and `main-net` stays **opt-in and warned**, exactly as for the other two — the socket is the reason the gate exists, and no network choice makes it safer.

> **And the trigger is not held back.** The first live session logged `Confirmation policy set to: kind='NeverConfirm'` — OpenHands' default is to run the commands it decides on **without asking you first**. Nothing in the deploy sets that; it is upstream's default and it is changeable in the UI's settings. Read together with the two facts above — no login, and the Docker socket — that is the whole threat model in one line, and it is why the port stays on `127.0.0.1`.

---

## 🔒 One agent at a time

Like the [providers](../AI/), only one runs at once — but **for a different reason**, and the scripts say so differently.

| | Why only one |
|---|---|
| Providers | A hard technical limit: they load models into the same GPU memory |
| **Agents** | They're **alternatives, not companions** — you pick one assistant. Several means several memories acting on the same workspace, all queueing against the one provider |

Agents never load a model, so there is no VRAM contention to cite. `deploy.sh` offers to stop whichever other agent is running.

---

## 🧩 Giving an agent its model

Every agent here needs one — a provider from [AI](../AI/) on this server, or a cloud API key. Neither is assumed.

**And they disagree completely on how** — which decided how far each `deploy.sh` could go:

| | Where the model is configured | Scriptable? |
|---|---|---|
| **Hermes** | `data/config.yaml`, a plain file | ✅ **Yes** — `deploy.sh` writes it, and the agent works when the script ends |
| OpenClaw | An onboarding wizard, no environment variable | ❌ No — five manual steps follow the deploy |
| OpenHands | **The web UI only** | ❌ No |

This was the single biggest difference between building the first agent and the second. OpenClaw took ten rounds and five discovered gates; Hermes worked on the first live deploy, and a config file rather than a wizard is most of why.

Where it *can* be scripted, DockHub does it: Hermes' `deploy.sh` asks the running provider what models it serves — one query to `/v1/models`, made from a container **on `ai-net`**, because that is the only vantage point whose answer means anything — and writes the choice in.

Where it cannot, DockHub **does not fake it**. `deploy.sh` prints the exact endpoint to paste and leaves the wizard alone, the same choice made for the NGINX Proxy Manager steps in [ERPNext](../ERP/erpnext/).

> ⚠️ **Upstream docs will tell you `http://host.docker.internal:11434` for Ollama. That is wrong here.** It assumes Ollama runs on the host. In DockHub it's a container on `ai-net`, so the address is **`http://ollama:11434`** — and `deploy.sh` prints the right one for you.

---

## ⚠️ A green self-test does not mean a working agent

Both agents here shipped a self-test that passed while the agent could not answer a single message. This is not a flaw in either script — it is a property of the category, and worth naming before you build a third.

| What a deploy self-test can prove | What it cannot |
|---|---|
| The container is running | The model is eligible |
| The web/API surface answers | Credentials for the model provider resolve |
| The auth token works | The messaging channel is wired to a reachable person |
| The config file parsed | The agent will actually reply |

Two lived examples:

- **Hermes** passed every check, then returned `agent init failed` to every message — the model's context window was 32,768 against a required 64,000. The gateway was healthy the whole time; the *agent* was not.
- **Hermes again**, with WhatsApp: paired successfully, bridge connected, gateway running — and messages produced **no log line at all**, because the wizard's mode had been set for a two-number setup on a one-number phone. "Deny unknown senders" is the documented default, so silence was the correct behaviour and looked exactly like a fault.

The habit that follows: **a deploy is not finished until a message has gone in and a reply has come out.** For an agent, that round trip is the only real test, and it is the one no `deploy.sh` can run for you.

---

## 🧭 Five questions to ask an agent image before writing a line

Every one of these cost at least a round when it was discovered by running into it instead. They share a root: **these programs assume a human sitting at a terminal on `localhost`**, and a container with a scripted deploy is neither.

| Ask | Because, in practice |
|---|---|
| **Does it refuse to start unconfigured?** | OpenClaw crash-looped on `Missing config`, and **no environment variable existed** for the setting it wanted — only its own CLI could write it |
| **Does it demand auth on a non-loopback bind?** | Both do, and both **fail closed**. That is good behaviour, but it means credentials must exist *before* first start, not after |
| **Does its web UI need a browser secure context?** | OpenClaw's does — Web Crypto for a device identity — so plain `http://` to a server IP **cannot work**, however correct the token. An SSH tunnel is mandatory there. Hermes and OpenHands have no such rule — verified live, OpenHands' UI is fully usable over plain `http://localhost:3001` through a tunnel. **Three agents, one requirement between them**: assume nothing, test it |
| **Is its config seeded in memory or written to disk?** | OpenClaw seeds its origin allow-list *without writing it*. The dashboard worked for two and a half minutes, then broke with no restart in between |
| **Is the image supervised?** | Hermes runs under **s6**, so `docker compose run` starts a *second* gateway beside the first. OpenClaw has no supervisor and `run` is fine. **Same command, opposite outcomes** — use `docker exec` for Hermes |

And one that only shows up later: **what does the container run as?** Hermes uses **uid 10000**, so `PUID`/`PGID` are mandatory with a bind mount. OpenClaw uses `node` — uid 1000 — which happens to match a first Ubuntu account, so it works by coincidence rather than design. **OpenHands runs as root**, so its `state/` ends up root-owned on the host: nothing breaks, but `ls` and any manual edit need `sudo`, and backups must be taken as root to read it.

> All three answers were different, and none was documented where a deploy script could read it. OpenHands' surfaced by accident — `wait_for_container_ready()` echoes the newest container log line every third round so a long pull doesn't look like a hang, and one of those lines was `Running OpenHands as root`. A progress indicator answered a design question. That is an argument for keeping it noisy.

---

## 💾 Backups: the opposite of the providers

Worth stating plainly, because the two categories look similar and are treated in exactly opposite ways.

| | What its volume holds | Backup |
|---|---|---|
| [Providers](../AI/) | Downloaded model weights | Config only — the weights are skipped |
| **Agents** | Memories, learned skills, conversations, workspace files | **Everything** — the standard volume backup |

A provider *downloads*. An agent *produces*. What an agent accumulates is yours and exists nowhere else, so none of these ship a `backup.sh` — the generic backup is already right for them.

---

## ✅ The habit

1. Give the agent the **narrowest** access that lets it do your job — start without the Docker socket and without `main-net`.
2. Treat anything it reads as untrusted input, because it is.
3. Give it its own credentials, never your primary ones. An agent with your main API key can spend it.
4. Back it up: unlike a provider, what it holds cannot be re-downloaded.

---

← Back to [all services](../README.md)

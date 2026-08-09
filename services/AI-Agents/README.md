# 🤖 AI-Agents

Agents that **do work for you**. You talk to one and it acts, using tools — it isn't a chat box, and you don't design anything.

| Category | Question it answers |
|---|---|
| [AI](../AI/) | *Run a model, and chat with it.* |
| **AI-Agents** (here) | *An agent does work for me.* |
| [Multi-Agent](../Multi-Agent/) | *I build what the agents do.* |

---

## 📋 What's here

| | What it's for |
|---|---|
| 🚧 [**OpenClaw**](openclaw/) | A personal assistant you reach over **Telegram, Slack, Discord or WhatsApp**. The strongest as a control plane: multiple channels, persistent agent teams, broad model support. |
| 🚧 [**Hermes**](hermes/) | A leaner, more personal assistant with a **learning loop** — built for repeated tasks and scheduled work that should improve over time. Also exposes its own OpenAI-compatible gateway. |
| 🚧 [**OpenHands**](openhands/) | A **software engineering** agent. It writes code, runs it, and browses — a different job from the two above. |

---

## ⚠️ These are not ordinary services

An agent takes instructions from text you don't control — a web page it reads, a message someone sends it — and it has **tools**. That combination doesn't exist anywhere else in DockHub, and it deserves thought before you deploy one next to your real services.

The principle carried over from [Security-Lab](../Security-Lab/), adapted:

> **The agent needs tools. It does not need your host.**

**OpenHands is the exception that needs its own decision:** its architecture *requires* the Docker socket, because it starts a fresh runtime container for every session to sandbox the code it runs. The intent is security-positive — it isolates execution *away* from itself. But the effect on the host is the one that makes Portainer sensitive: anything reaching that socket can start a privileged container.

---

## 📌 Also worth knowing

**Every agent here needs a model** — either a provider from [AI](../AI/) running on this server, or a cloud API key. Neither is assumed; you're asked at deploy time.

**They reach you outbound.** OpenClaw and Hermes connect *out* to Telegram or Slack rather than waiting for inbound requests, so in normal use they need no public domain and no reverse proxy at all.

---

← Back to [all services](../README.md)

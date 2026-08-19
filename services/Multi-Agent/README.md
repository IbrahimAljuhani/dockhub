# 🕸️ Multi-Agent

Platforms where you **build and orchestrate systems of agents** — visual flow builders, RAG pipelines, and agent management.

The line separating this category from [AI-Agents](../AI-Agents/) is simple:

> **AI-Agents** — a running agent that does work *for* you. You talk to it; it acts.
> **Multi-Agent** — a platform where *you* design what the agents do.

And both differ from [AI](../AI/), which is the model layer underneath: the providers that serve models and the chat interface you talk to them through. Everything here needs one of those — or a cloud API key.

---

## 📋 What's here

| | What it is | Weight |
|---|---|---|
| [**Dify**](dify/) | Full-stack LLM app platform — workflow orchestration, production RAG with hybrid search, agent management, team accounts | Heaviest: ~15 containers, 4 GB minimum |
| [**Langflow**](langflow/) | The most powerful builder — LangGraph multi-agent support, custom **Python** nodes inside the visual surface, MIT licensed | Medium: 2 containers |
| [**Flowise**](flowise/) | The fastest to get moving — drag-and-drop builder on LangChain | Lightest: 2 containers |
| [**Paperclip**](paperclip/) | "The open-source app everyone uses to manage agents at work" — org hierarchy, goals, budgets, tickets | Light: 2 containers |

> 📌 **All four join `ai-net`** (Dify's `api`, `worker` and `plugin_daemon`; the single app container in the other three). That is how a flow reaches an [Ollama](../AI/ollama/), [llama.cpp](../AI/llama-cpp/) or [LocalAI](../AI/localai/) deployed from the AI category — **by container name**, `http://ollama:11434`, with no port published on either side. Three of them did not join it until **2026-08-19**, while `deploy.sh` had been printing *"will run on 'ai-net', where it can reach the model provider"* the whole time. The statement was false and the capability was missing; the only route left was publishing an API that has **no authentication at all** onto your LAN, to obtain a connection Docker was willing to make privately. Verified live the same day: `docker exec langflow curl http://ollama:11434/api/tags` returns the model list, and `dify-api`, `dify-worker-1` and `dify-plugin_daemon-1` all report `ai-net`.

> 🚫 **Dify's `agent_backend` is deliberately left off `ai-net`**, and that absence is a decision, not an oversight. It runs the agent *sandbox* — a Linux environment where an agent installs packages and writes files — and upstream routes its egress through a dedicated Squid proxy whose ACL permits only `/files/` on `api` and `/agent-stub/` on itself. Attaching it to `ai-net` would put a code-executing sandbox straight onto the shared network carrying Ollama, Hermes, OpenClaw, OpenHands and Paperclip, punching through an isolation boundary upstream built on purpose. It reaches models the way everything else does: by calling back into `api`, which *is* on `ai-net`.

> ⚠️ **`ai-net` is a shared network, and joining it is not free.** These four can now see each other and the AI-Agents services by name. That is the existing design — the agents have always shared it, and it is why `prompt_agent_network`'s warning is about `main-net`, where Portainer and the Docker socket live — but it is a real widening of reach, stated here rather than left implicit.

> 🔐 **Registration differs between them, and the difference is not obvious.** **Flowise** is invite-only: after the first admin account nobody can self-register. **Langflow** ships `LANGFLOW_ENABLE_SIGNUP=True` by default, leaving `POST /api/v1/users/` open to anyone who can reach the port — accounts created that way are inactive (`LANGFLOW_NEW_USER_IS_ACTIVE=False`) and cannot sign in, but the endpoint is an unauthenticated write. DockHub sets both to `False`.

> 📌 **Dify was moved here from `AI`.** It describes itself as an LLM *application development platform* with agent management, which puts it alongside Langflow and Flowise rather than alongside Ollama. Filing it under AI sent people looking in the wrong place.

> 📌 **Paperclip was 🚧 for one reason, and that reason expired.** This page used to say it was deferred because upstream published no official image, and that *"the moment that changes, it's a normal build."* It changed. Checked against the registry itself on **2026-08-18**: `ghcr.io/paperclipai/paperclip:latest` is published by the authors' own organisation, carries `org.opencontainers.image.source = github.com/paperclipai/paperclip`, was built hours earlier (`2026.817.0`), and covers `linux/amd64` and `linux/arm64`. The third-party image this note used to mention is no longer relevant and is not used.

---

## 🛡️ Threat model — read this before deploying any of them

[AI-Agents](../AI-Agents/) has had one of these since it was created. This category needed one too, and the reason is sharper than it looks.

### The one fact everything follows from

**These platforms execute code you did not write, on behalf of a model reading text you did not write.**

That is not a flaw — it is the product. Paperclip ships four agent harnesses *inside its own image* (`claude-code`, `codex`, `opencode`, `gemini-cli`) and runs them as **processes in the application container**. There is no sandbox in a plain Docker deployment; the sandbox providers upstream ships are for Kubernetes.

So the blast radius of an agent is exactly **the container's own reach**. Not less.

### What that container can touch

| | Reachable from inside the app container |
|---|---|
| Its own state | `/paperclip` — instance config, agent definitions, and anything the agents write |
| Its database | `paperclip-db`, with `DATABASE_URL` sitting in the environment |
| Its API keys | every `*_API_KEY` you added, readable by any process |
| **`main-net`, if joined** | **every proxied service on the host** |

That last row is the one that matters, and it is why DockHub does not join `main-net` unless it must:

- **`portainer:9000`** — Portainer mounts `/var/run/docker.sock`. Anything that reaches its API and authenticates can start a privileged container. That is root on the host.
- **NGINX Proxy Manager's admin interface** — whose first-login credentials *this project's own README prints*: `admin@example.com` / `changeme`.

An agent does not have to be malicious for this to matter. It has to be *persuaded* — by a web page it fetched, a repository it cloned, an issue it was asked to read.

### What DockHub does about it

| | |
|---|---|
| **No Docker socket** | Never mounted for these services. Paperclip does not need it, so it does not get it. |
| **`main-net` only when the proxy needs it** | Choose a direct host port and the app never joins it — NPM is not in the path, so the network buys nothing and costs reach. `deploy.sh` decides this from the answer you already gave. |
| **Database off the shared network** | `paperclip-db` sits on a private network only the app can see. |
| **Capabilities dropped** | `no-new-privileges`, `cap_drop: [MKNOD, NET_RAW, AUDIT_WRITE]`, `pids_limit`. Real containment here, because there is no socket to make it decorative. |

### What is left to you

**Change the default passwords on NPM and Portainer.** Not because of these services — you should do it anyway — but an agent on `main-net` turns "I'll get to it" into an exposure with a documented password.

**Prefer a direct host port plus a firewall or VPN**, and reach it over that, if the deployment does not need a public domain. It is the shape with the least reach.

**Give agents the narrowest credentials that work.** A key scoped to one project beats an organisation-wide one, and revoking it is a single action.

---

## 🧩 Why LangGraph and CrewAI are not listed

They come up constantly in this space, and they are genuinely excellent — but **neither is a deployable service**, so neither gets a menu entry.

**LangGraph** does publish a server image, which makes it look deployable. It isn't: `langgraph build` packages **your own graph code** from a `langgraph.json` into an image. Deploy it empty and you get a server with no graphs to run.

**CrewAI** publishes no image at all. It's a Python library you `pip install` and write code against.

Listing either would put an entry in `services.sh` with nothing behind it — the same reason [Strapi was removed](../../README.md) from this project entirely.

**The capability is still here, as a service:**

| You wanted | Deploy this instead |
|---|---|
| LangGraph's multi-agent graphs | **Langflow** — built on LangGraph, with the graph as a visual surface and custom Python nodes where you need code |
| CrewAI's crews of role-playing agents | **Flowise** or **Dify** — both model multi-step agent workflows; Dify adds RAG and team management |

If you specifically want to write agents in Python rather than build them visually, install those libraries in your own project. They aren't infrastructure, and DockHub deploys infrastructure.

---

## 📜 License

Each project is licensed by its own authors — see their repositories. These deployment wrappers follow the same [MIT license](../../LICENSE) as the rest of DockHub.

---

← Back to [all services](../README.md)

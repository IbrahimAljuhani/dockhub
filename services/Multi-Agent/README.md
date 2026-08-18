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
| [**Dify**](dify/) | Full-stack LLM app platform — workflow orchestration, production RAG with hybrid search, agent management, team accounts | Heaviest: ~10 containers, 4 GB minimum |
| [**Langflow**](langflow/) | The most powerful builder — LangGraph multi-agent support, custom Python nodes inside the visual surface, MIT licensed | Medium |
| [**Flowise**](flowise/) | The fastest to get moving — drag-and-drop builder on LangChain | Lightest: runs in ~1 GB |
| [**Paperclip**](paperclip/) | "The open-source app everyone uses to manage agents at work" — org hierarchy, goals, budgets, tickets | Light: 2 containers |

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

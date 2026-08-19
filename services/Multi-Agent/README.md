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
| [**Dify**](dify/) | Full-stack LLM app platform — workflow orchestration, production RAG with hybrid search, agent management, team accounts | Heaviest: **15 containers**, 4 GB minimum |
| [**Langflow**](langflow/) | The most powerful builder — LangGraph multi-agent support, custom **Python** nodes inside the visual surface, MIT licensed | Medium: 2 containers |
| [**Flowise**](flowise/) | The fastest to get moving — drag-and-drop builder on LangChain | Lightest: 2 containers |
| [**Paperclip**](paperclip/) | "The open-source app everyone uses to manage agents at work" — org hierarchy, goals, budgets, tickets | Light: 2 containers |

> 📌 **Dify, Flowise and Langflow reach your local models over `models-net`** (Dify via `api`, `worker` and `plugin_daemon`; the single app container in the other two). That is how a flow reaches an [Ollama](../AI/ollama/), [llama.cpp](../AI/llama-cpp/) or [LocalAI](../AI/localai/) — **by container name**, `http://ollama:11434`, with no port published on either side. None of the three reached a model provider at all until **2026-08-19**, while `deploy.sh` had been printing *"will run on 'ai-net', where it can reach the model provider"* the whole time. Verified live: `docker exec langflow curl http://ollama:11434/api/tags` returns the model list.

> 🔴 **Why `models-net` exists, and not just `ai-net`.** The first fix put those three on `ai-net`, and it lasted one day. A Docker network is **flat** — every member can reach every other — and `ai-net` also carries [OpenHands](../AI-Agents/openhands/), whose container has **no authentication of its own** and mounts `/var/run/docker.sock`. Binding its host port to `127.0.0.1` protects it from your LAN; it does nothing about a container sitting on the same Docker network. So joining `ai-net` gave a Custom Tool node — JavaScript or Python that arrives inside a flow you imported — a route to `http://openhands:3000`, and from there to root on the host. That is the same chain this page warns about for `main-net` and Portainer, reproduced by a fix for something else.
>
> The providers now act as a **hub**: `ollama`, `llama-cpp` and `localai` join **both** networks, the builders join `models-net` only, and the agent services stay on `ai-net` only. Everything keeps the access it had a reason for, and the two consumer groups cannot see each other.
>
> | | `ai-net` | `models-net` |
> |---|---|---|
> | Ollama · llama.cpp · LocalAI | ✅ | ✅ |
> | OpenHands · Hermes · OpenClaw · Open WebUI | ✅ | — |
> | **Paperclip** | ✅ | — |
> | **Dify · Flowise · Langflow** | — | ✅ |
>
> **Paperclip is the deliberate exception.** It runs agent CLIs — code execution — *and* stays on `ai-net`, because its proven integration is calling Hermes at `hermes:8642`. So it remains the one service in this category that can still reach OpenHands. That is a trade this project accepts and states, not a case it missed. If you run both, understand that Paperclip is as trusted as the agents you let it drive.

> 🚫 **Dify's `agent_backend` is deliberately on neither network**, and that absence is a decision. It runs the agent *sandbox* — a Linux environment where an agent installs packages and writes files — and upstream routes its egress through a dedicated Squid proxy whose ACL permits only `/files/` on `api` and `/agent-stub/` on itself. Attaching it to a shared network would punch through an isolation boundary upstream built on purpose. It reaches models the way everything else does: by calling back into `api`.

> 🔐 **Registration differs between them, and the difference is not obvious.** **Flowise** is invite-only: after the first admin account nobody can self-register. **Langflow** ships `LANGFLOW_ENABLE_SIGNUP=True` by default, leaving `POST /api/v1/users/` open to anyone who can reach the port — accounts created that way are inactive (`LANGFLOW_NEW_USER_IS_ACTIVE=False`) and cannot sign in, but the endpoint is an unauthenticated write. DockHub sets both to `False`.

> 📌 **Dify was moved here from `AI`.** It describes itself as an LLM *application development platform* with agent management, which puts it alongside Langflow and Flowise rather than alongside Ollama. Filing it under AI sent people looking in the wrong place.

> 📌 **Paperclip was 🚧 for one reason, and that reason expired.** This page used to say it was deferred because upstream published no official image, and that *"the moment that changes, it's a normal build."* It changed. Checked against the registry itself on **2026-08-18**: `ghcr.io/paperclipai/paperclip:latest` is published by the authors' own organisation, carries `org.opencontainers.image.source = github.com/paperclipai/paperclip`, was built hours earlier (`2026.817.0`), and covers `linux/amd64` and `linux/arm64`. The third-party image this note used to mention is no longer relevant and is not used.

---

## 🧮 Running more than one of them

They coexist. Nothing here is one-of-a-group the way the [model providers](../AI/) are — those compete for the same GPU memory, these do not.

| | containers | suggested host port | app memory prompt |
|---|---|---|---|
| Paperclip | 2 | `3100` | 2 GB |
| Dify | **15** (16 created) | `8088` | not prompted — see below |
| Flowise | 2 | `3200` | 1 GB |
| Langflow | 2 | `7860` | 2 GB |
| **all four** | **21 running** | no collisions | — |

**The ports do not collide**, deliberately: each was checked against the whole catalogue before it was chosen, which is why Flowise is on 3200 rather than its native 3000 (taken by Open WebUI, Redmine and Juice Shop) and Langflow keeps 7860 (used by nothing else here).

**Dify is the whole memory question.** Its own requirement is 4 GB minimum, and it is fifteen containers against everyone else's two. The other three together weigh less than it does alone. `deploy.sh` does not prompt for a memory limit on Dify at all — tuning fifteen containers is an exercise, not a deploy question, and on a dedicated host no limits is the right answer.

> The per-app numbers above are what the prompts *suggest*, not measurements. Treat them as starting points; the only figure here that comes from its authors is Dify's 4 GB.

**If you are choosing rather than collecting**, the [table at the top](#-whats-here) is the honest answer: Flowise to move fastest, Langflow when you want Python inside the canvas, Dify when you need RAG and team accounts, Paperclip when you are managing agents rather than building flows.

---

## 🏷️ One naming inconsistency, kept on purpose

The app containers are `flowise`, `langflow`, `dify-api` — and **`paperclip-app`**, not `paperclip`. So `docker logs flowise` works and `docker logs paperclip` does not.

It is inconsistent and it stays. Renaming it would break something no migration could repair: `http://paperclip-app:3100` is the **callback URL you type into Paperclip's own Hermes Gateway adapter**, and it is stored in Paperclip's database, not in any file this project controls. A rename would leave a working integration silently pointing at a host that no longer resolves, with nothing in DockHub able to notice or fix it.

A small wart is cheaper than a silent breakage in somebody's running setup.

---

## 🛡️ Threat model — read this before deploying any of them

[AI-Agents](../AI-Agents/) has had one of these since it was created. This category needed one too, and the reason is sharper than it looks.

### The one fact everything follows from

**These platforms execute code you did not write, on behalf of a model reading text you did not write.**

That is not a flaw — it is the product. What differs between the four is only *what* runs and *where*:

| | what executes | where |
|---|---|---|
| **Paperclip** | four agent harnesses shipped inside its own image (`claude-code`, `codex`, `opencode`, `gemini-cli`) | **processes in the app container.** No sandbox in a plain Docker deployment — upstream's sandbox providers are for Kubernetes |
| **Langflow** | Custom Component nodes — **Python** | in the app container |
| **Flowise** | Custom Tool nodes — **JavaScript**, with `require('fs')` permitted by upstream's own default | in the app container |
| **Dify** | generated code, and agent skills | in `sandbox` / `agent_backend`, **isolated by upstream on purpose** — the one of the four with a real boundary |

So for three of them the blast radius of an agent is exactly **the container's own reach**. Not less. Dify is the exception, and its exposure is its web front end rather than its sandbox.

And "a flow you imported" is the same category of thing as "a repository an agent cloned". **A shared flow is a program.** It arrives as JSON, it looks like configuration, and it runs.

### What that container can touch

| | Reachable from inside the app container |
|---|---|
| Its own state | the mounted data directory — instance config, flows, agent definitions, and anything they write |
| Its database | its own Postgres, with the credentials sitting in the environment |
| Its API keys | every provider key you added, readable by any process in that container |
| **`models-net`** *(Dify · Flowise · Langflow)* | the model providers — Ollama, llama.cpp, LocalAI. Each has **no authentication**, so this is "use my models, read my prompts". Nothing else is on this network. |
| **`ai-net`** *(Paperclip)* | the model providers **and the agent services** — including **`openhands:3000`**, which has no authentication and mounts `/var/run/docker.sock` |
| **`main-net`, if joined** | **every proxied service on the host** |

**A Docker network is flat.** Every member reaches every other, so joining one to reach a model is also joining it to reach everything else on it. That is the whole reason `models-net` exists, and why the three code-running builders are on it rather than on `ai-net` — see the network table near the top of this page.

The last two rows are the ones that matter:

- **`openhands:3000`** — OpenHands mounts `/var/run/docker.sock` and, in its own README's words, *"has no authentication. This is the decisive fact."* Its host port is bound to `127.0.0.1`, which protects it from your LAN and does nothing about a container on the same Docker network. **Paperclip can reach it; the other three deliberately cannot.**
- **`portainer:9000`** — Portainer mounts the socket too. Anything that reaches its API and authenticates can start a privileged container. That is root on the host.
- **NGINX Proxy Manager's admin interface** — whose first-login credentials *this project's own README prints*: `admin@example.com` / `changeme`.

An agent does not have to be malicious for this to matter. It has to be *persuaded* — by a web page it fetched, a repository it cloned, an issue it was asked to read, a flow somebody shared.

### What DockHub does about it

| | |
|---|---|
| **No Docker socket** | Never mounted for any of these four. None of them needs it, so none of them gets it. |
| **Code-runners are off `ai-net`** | Dify, Flowise and Langflow reach the model providers over **`models-net`**, which carries nothing else. The providers join both networks and act as a hub, so nobody loses model access and the builders never share a network with OpenHands. |
| **`main-net` only when the proxy needs it** | Choose a direct host port and the app never joins it — NPM is not in the path, so the network buys nothing and costs reach. `deploy.sh` decides this from the answer you already gave. |
| **Databases off every shared network** | Each service's Postgres sits on a private network only its own app can see, with no host port. |
| **Capabilities dropped** | `no-new-privileges`, `cap_drop: [MKNOD, NET_RAW, AUDIT_WRITE]`, `pids_limit` — on the apps *and* their databases. Real containment here, because there is no socket to make it decorative. |

### What is left to you

**Change the default passwords on NPM and Portainer.** Not because of these services — you should do it anyway — but an agent on `main-net` turns "I'll get to it" into an exposure with a documented password.

**Prefer a direct host port plus a firewall or VPN**, and reach it over that, if the deployment does not need a public domain. It is the shape with the least reach.

**Give agents the narrowest credentials that work.** A key scoped to one project beats an organisation-wide one, and revoking it is a single action.

**Read a flow before you run it**, the way you would read a script before running it. Every one of these four can import somebody else's work in a single click, and in three of them that work executes with the container's full reach.

**If you run Paperclip and OpenHands together, understand what that means.** Paperclip runs agent CLIs *and* stays on `ai-net`, because its proven integration is calling Hermes at `hermes:8642`. It is therefore the one service here that can still reach an unauthenticated OpenHands. That is a deliberate trade, stated rather than hidden — but it is yours to accept.

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

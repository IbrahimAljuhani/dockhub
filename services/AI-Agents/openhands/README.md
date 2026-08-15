# 🙌 OpenHands

<sub>Part of [AI-Agents](../README.md) — read the category's threat model before deploying any agent.</sub>

**A software-engineering assistant.** It writes code, runs it, and browses the web to get a task done.

That is a different job from its neighbours here, and worth saying plainly so nobody arrives expecting the wrong thing: [OpenClaw](../openclaw/) and [Hermes](../hermes/) are **personal assistants** you message on Telegram or WhatsApp. OpenHands is a **developer tool** you open in a browser and give a coding task to. Same category — an agent that does work for you — different work.

---

## 📗 What you get

| | |
|---|---|
| **Interface** | A web UI, reached over an SSH tunnel |
| **Docker socket** | **Required** — not optional, unlike the other two |
| **Authentication** | **None.** See below; it shapes every other decision |
| **Port** | `3001` on `127.0.0.1` — deliberately not your LAN |
| **Model** | Set in the UI only. No environment variable exists |
| **Containers** | Two: the app, plus a runtime it starts per session |
| **Runs as** | **root** — so `state/` is root-owned on the host |
| **State** | `~/docker/openhands/state` — settings, conversations, working copies |

---

## 🔴 The Docker socket is required, and DockHub asks you to type

Every other service in this repo either does not want the socket or treats it as an extra. OpenHands cannot run without it: it starts a **fresh runtime container per session**, which is how the code it writes stays out of OpenHands itself.

So the intent is security-*positive*. The effect on the host is not:

```
agent runs code
  └─ OpenHands starts a runtime container for it
       └─ using /var/run/docker.sock
            └─ which can also start:  docker run --privileged -v /:/host …
                 └─ root on the whole host
```

`deploy.sh` will not proceed on a keypress. It prints the full chain and asks you to type **`i-accept`**.

> The typing is not security theatre disguised as friction — it plainly is not harder than pressing `y`. Its actual job is that **it cannot be answered by habit**: every other prompt in this repo takes `y` or Enter, so a reflex answer lands nowhere and you have to look up. What earns the gate is the warning, not the keystroke.

**DockHub does not refuse this**, and refusing would be inconsistent: core infrastructure already runs **Portainer** on the same socket. The difference is who holds the trigger — you, or a language model acting on text it did not write.

If you only want an assistant, [OpenClaw](../openclaw/) and [Hermes](../hermes/) do that job with the socket **off**.

---

## 🔴 It has no authentication. This is the decisive fact.

The other two agents here **refuse to start** unless you give them credentials — OpenClaw wants a gateway token, Hermes an API key. Checked against upstream, OpenHands has no such gate: it boots straight to a usable settings screen, and **anyone who reaches the port has a fully privileged agent with the Docker socket behind it**.

Upstream says the same in its own words: bind `127.0.0.1`, reach it through a reverse proxy with TLS, and expose it only behind an API key plus a firewall or VPN. The third-party "hardened" build of OpenHands adds HTTP basic auth **in nginx, in front** — precisely because OpenHands has none.

So `deploy.sh` publishes the port to **`127.0.0.1` on the server**, never the LAN. Reaching it needs a **SOCKS proxy, not a port tunnel** — `ssh -L` loads the page but leaves the UI stuck on *Disconnected*, because each session's runtime publishes random ports the browser must also reach (see the next section):

```bash
ssh -D 1080 you@your-server
```

Then point the browser at it — Firefox: *Network Settings → Manual proxy → **SOCKS Host** `127.0.0.1`, Port `1080`, SOCKS v5*, and in `about:config` set `network.proxy.allow_hijacking_localhost = true` (Firefox refuses to proxy `localhost` without it). Chrome: `--proxy-server="socks5://127.0.0.1:1080"`.

Then browse `http://localhost:3001`.

> This is the same treatment Hermes' dashboard gets, for a stronger reason. There it is a privacy preference; here it is the only thing standing between your LAN and a root-equivalent agent.

### That binding covers the app — not the session runtime

Worth stating precisely, because the loopback claim is easy to over-read. `docker ps` during a live session shows the runtime container publishing **on `0.0.0.0`**, on random high ports that change every session:

```
0.0.0.0:54805->8000/tcp   0.0.0.0:45457->8001/tcp   …
```

So the runtime *is* reachable from your LAN, and no firewall rule can pin ports that are chosen at random. **It defends itself with a token**, though — verified from the server's own LAN address:

| Endpoint | Result |
|---|---|
| `GET /alive` | `200` — an unauthenticated liveness probe, reveals only that a container is there |
| `POST /api/bash/start_bash_command` | **`401`** — the endpoint that actually runs commands requires authentication |

Which leaves an inversion worth remembering: **the machine-to-machine API authenticates; the human-facing UI does not.** OpenHands guards the channel between its two containers and leaves the front door on `3001` open — which is exactly why that door stays on `127.0.0.1`.

### And the runtime has to answer back — which loopback alone forbids

The two containers talk in both directions, and the return leg is where a loopback-only binding quietly breaks the product:

| Direction | How |
|---|---|
| app → runtime | Docker socket, then a published session port |
| **runtime → app** | **HTTP POST to `OH_WEBHOOKS_0_BASE_URL`** |

Every agent event — its reply, its tool calls, its output — reaches you only over that second arrow. Its default value, confirmed by `docker inspect` on a live runtime, is:

```
OH_WEBHOOKS_0_BASE_URL=http://host.docker.internal:3000/api/v1/webhooks
```

The runtime is started on the **default bridge**, so `openhands` does not resolve there; `host.docker.internal` is its only route home, and it points at the docker0 gateway. Bind the app to `127.0.0.1` alone and that gateway has nothing listening on it. The result is the worst failure shape available:

```
Failed to post events to webhook … All connection attempts failed   ← runtime log
Queued pending message … (position: 2)                              ← app log
```

**No error in the UI.** The message is filed in a queue and never answered, which reads exactly like a broken model — and sends you off to check the one thing that is fine.

So `deploy.sh` publishes the port twice: `127.0.0.1:<port>` for you, and `<docker0 gateway>:<port>` for the runtime, with `OH_WEBHOOKS_0_BASE_URL` pointed at the second. The gateway address is read from Docker rather than assumed to be `172.17.0.1`.

> ⚠️ **The cost, stated plainly.** The gateway is not reachable from your LAN, so the tunnel-only rule for humans is intact. It *is* reachable from every other container on the default bridge — so an unauthenticated agent holding the Docker socket is exposed to anything else running on this host. That is accepted here because it does not exceed the trust already granted by mounting that socket, and because without it the service does not work at all. It is not accepted quietly, which is why it is written down.

### It also does not ask before acting

The first live session logged this on startup:

```
Confirmation policy set to: kind='NeverConfirm'
```

That is upstream's **default**: the agent runs the commands it decides on without pausing for your approval. Nothing in this deployment sets it, and you can change it in the UI's settings once you are in. Stated plainly because the three facts compound — no login, the Docker socket, and no confirmation step — and together they are the entire reason the port never leaves `127.0.0.1`.

### If you put it behind NGINX Proxy Manager

Possible — answer **yes** to the `main-net` question — but **add an Access List on the proxy host**. NPM's basic auth is then the only login OpenHands will ever have. Without it you have published a privileged agent to whoever finds the domain.

---

## 🔌 Port 3001, not 3000

Upstream publishes on `3000`. In this catalogue that is [Open WebUI](../../AI/open-webui/)'s default — and Open WebUI is exactly what someone deploying an agent already runs — as well as Redmine's and Juice Shop's. DockHub defaults to **3001**, and warns if you type 3000 anyway.

---

## 📦 Two images, both pinned

| | |
|---|---|
| App | `docker.openhands.dev/openhands/openhands:1.8` |
| Session runtime | `ghcr.io/openhands/agent-server:1.26.0-python` |

Both are pinned in `.env` rather than floating on `latest`, and that is not caution for its own sake: **`ghcr.io/openhands/agent-server:latest` does not exist** — verified, it returns 404 — while `1.26.0-python` does. Upstream's own documented command names explicit versions too.

`deploy.sh` pulls **both** up front. Otherwise the runtime is fetched when you start your first session, inside a web UI with no progress bar, which is indistinguishable from a hang.

Watch the runtime appear when a session starts:

```bash
docker ps --filter ancestor=ghcr.io/openhands/agent-server:1.26.0-python
```

---

## 🧩 The model — UI only

No environment variable configures it. This is the sharpest contrast with [Hermes](../hermes/), whose model lives in a config file that `deploy.sh` writes, so its agent works the moment the script ends. Here nothing can be scripted; `deploy.sh` prints the endpoint and stops.

Open **Settings → LLM → Advanced**. Three fields, and all three must be right — a wrong one fails at the first message, not at save time:

| Field | Value |
|---|---|
| **Custom Model** | `openai/<model>` — e.g. `openai/qwen3.5:9b` |
| **Base URL** | `http://ollama:11434/v1` |
| **API Key** | anything, e.g. `ollama` — **must not be empty** |

**There is no dropdown of your models.** `Custom Model` is free text and OpenHands never asks your provider what it serves; the list on the **Basic** tab is OpenHands' own *cloud* catalogue, so your local models will never appear there. Get the exact names yourself:

```bash
docker exec -it ollama ollama list
```

> ⚠️ The `openai/` prefix does **not** name OpenAI the company. It tells LiteLLM — the client library inside OpenHands — to speak the OpenAI protocol to the Base URL below it. Leave the Basic tab's `openhands/…` value in place and it **silently ignores your Base URL** and calls the cloud instead. That is the single most likely reason a correct-looking setup does nothing.
>
> ⚠️ The **API Key field must not be left empty**, even for a local provider. The protocol requires the field; Ollama ignores its value.

> ⚠️ **Use `host.docker.internal` here — not the container name.** This is the one place OpenHands differs from every other DockHub service, and an earlier version of this page said the exact opposite.
>
> `http://ollama:11434/v1` resolves from the *app* container. But the model is not called from there: the agent runs inside the **session container**, on the default bridge, where no DockHub name resolves at all. Verified from inside a live one:
>
> ```
> getent hosts ollama                       →  (nothing)
> wget host.docker.internal:11434/api/tags  →  your model list
> ```
>
> So the session reaches your provider the same way it reaches OpenHands itself — through `host.docker.internal` and a **published host port**. A container name here fails silently: the message is accepted, no reply ever arrives, and nothing in the UI says why. `deploy.sh` works the correct URL out from the provider's published port and prints it.

Any API key value will do for a local provider — the protocol requires the field, the server ignores it.

---

## 🛠️ Management Commands

```bash
cd ~/docker/openhands
```

| Command | Purpose |
|---|---|
| `ssh -D 1080 you@server` | The way in — run it from your machine, then set the browser's SOCKS proxy. `-L` is not enough |
| `docker compose logs -f openhands` | Follow the app |
| `docker logs <runtime> 2>&1 \| grep -oP '^[^\|]+' \| uniq` | Read the **session runtime**'s log without the duplication — see below |
| `docker ps --filter ancestor=ghcr.io/openhands/agent-server:1.26.0-python` | Is a session runtime alive? |
| `docker compose pull && docker compose up -d` | Update — your state is a bind mount and survives |

---

> ### ⚠️ The runtime container's log repeats itself
>
> Every line in `oh-agent-server-…` is emitted **8–16 times**, each copy with a little more of `asctime=` / `levelname=` / `name=` / `filename=` appended, and occasionally a JSON copy too. This is the **runtime image's own logging configuration**, not something this deployment sets — the `openhands` app container's log is clean, and it is the only one DockHub passes environment to.
>
> It is cosmetic and nothing is lost, but `docker logs` on the runtime is close to unreadable without the `grep`/`uniq` line above. When you just want to know what the agent did, the UI's event view is the better place to look.

---

## 💾 Backups

`state/` holds settings, credentials you entered in the UI, conversations and the agent's working copies. **Real user data**, like the other two agents — so the standard volume backup is right, and worth taking before you let it loose on anything you care about.

⚠️ **It is root-owned**, because OpenHands runs as root in the container. `ls` and any hand-edit need `sudo`, and a backup taken as your own user will read nothing. The menu's Backup option runs with the privileges it needs; a manual `tar` does not.

---

## ⚠️ What a successful deploy does *not* prove

The self-test checks that the web server answers. It cannot check the model, the credentials, or whether the agent can run a single command — **none of that exists until you configure it in the UI**.

This service is the clearest case in the repo of the rule in the [category README](../README.md): *a green self-test does not mean a working agent*. The only real test is giving it a task and watching it act.

That test has been run. On a live server the second container appeared as `oh-agent-server-…`, and its log carried what no self-test could: `POST /api/bash/start_bash_command → 200` repeatedly with the output polled back, three model profiles saved, the extensions repository cloned, 57 skills loaded, and a conversation created. **The agent works. The deploy still cannot tell you that** — which is the whole point of saying so out loud.

---

## 📌 Notes & Deviations

- **Typed acknowledgement**, not `y/n` — the only prompt in DockHub that works this way.
- **The gate is re-checked on rerun.** `.env` records that it was accepted; a file that was hand-made, copied from another host, or predates the key makes `deploy.sh` refuse rather than mount the socket on an unacknowledged deployment.
- **`127.0.0.1` binding is not offered as a choice.** `prompt_host_port` — used everywhere else — offers a LAN binding, and a LAN binding on an unauthenticated privileged agent is not something this repo should present as routine.
- **`main-net` is offered with the category's standard warning**, consistent with the other two agents rather than a special case. The loopback binding stands either way: no network choice fixes missing authentication.
- **The port is published twice** — `127.0.0.1` for you, the docker0 gateway for the session runtime's callback. The second binding is not a convenience; without it the agent's answers never reach the app and every message queues in silence. The gateway address is read from Docker, not assumed.
- **`OH_WEBHOOKS_0_BASE_URL` is set explicitly** rather than left at its default, so the callback follows the port you chose instead of hard-coded `3000` — which would collide with Open WebUI.
- **A rerun warns if the installed `docker-compose.yml` predates that fix.** Deployments made earlier look healthy and are not, so the script says so instead of leaving you to find it the hard way.
- **Both images pre-pulled**, because the second one is invisible from the UI.
- **No `lib/gpu.sh`** — an agent never loads a model; the provider does.

---

## 📜 License

OpenHands is licensed separately — see the [official repository](https://github.com/All-Hands-AI/OpenHands). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of DockHub.

# 💬 Open WebUI

A ChatGPT-style interface for your own models.

Open WebUI is a **consumer** — see the [AI category](../README.md). It runs no models itself; it talks to whatever is serving them: [Ollama](../ollama/), llama.cpp or LocalAI on this host, or a cloud API key.

---

## 📥 Installation

### 1. Deploy a provider first (recommended)

```bash
bash services/AI/ollama/deploy.sh
```

Not mandatory — Open WebUI runs without one and you can add connections from its own interface later. But with Ollama already running, this deploy wires itself up automatically and you'll find your models waiting.

### 2. Deploy Open WebUI

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/AI/open-webui/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/AI/open-webui/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

`deploy.sh` looks for a running provider and configures itself accordingly:

| What it finds | What it does |
|---|---|
| **Ollama** | Sets `OLLAMA_BASE_URL` and **lists the models it has**, so you know before opening the page whether the dropdown will be empty. |
| **llama.cpp** or **LocalAI** | Sets `OPENAI_API_BASE_URL` to their OpenAI-compatible `/v1` path. |
| **Nothing** | Offers a cloud API key, or lets you skip and configure it in the UI later. |

---

## 👤 First Login

There is **no default account**. Open the site and register — **the first person to sign up becomes the admin**.

> 🔐 Do this promptly. Until you do, anyone who reaches the page can claim ownership. Afterwards, turn signups off under **Admin → Settings**.

The secrets file holds the session signing key, not a login:

```bash
cat ~/docker/open-webui/.open-webui-docker-secrets.txt
```

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

> ☁️ **Using Cloudflare Tunnel?** Two steps below are different: where you open NPM, and the SSL certificate (`None`, not Let's Encrypt). See [docs/cloudflare-tunnel.md](../../../docs/cloudflare-tunnel.md#deploying-a-service-behind-the-tunnel).

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Forward Hostname/IP**: `open-webui`
   - **Forward Port**: `8080`
   - Enable **Websockets Support** — chat responses stream over a websocket, and without this replies appear to hang.
3. Enable **SSL** with Let's Encrypt.

Scheme stays `http`; NPM terminates TLS.

---

## ⚠️ The image tag is a real trap here

Open WebUI publishes three tags, and copying the wrong one from a guide causes a confusing mess:

| Tag | What it is |
|---|---|
| **`main`** | What this deployment uses. The interface, and nothing else. |
| `cuda` | A GPU build — but only for **local embeddings** (document search) and speech-to-text. It does **not** accelerate the language model; that runs in the provider. Most people never need it. |
| `ollama` | ⚠️ **Bundles Ollama inside this container.** |

That last one is the trap. On a host where DockHub already deployed Ollama, using `:ollama` leaves you with **two Ollamas holding two separate model stores** — you download the same model twice, and neither interface explains why the other one's models are missing.

---

## 🩺 The model list is empty

Three different causes, in the order worth checking:

**1. The provider has no models.** Most likely, and the deploy warns about it:

```bash
docker exec -it ollama ollama list
docker exec -it ollama ollama pull llama3.2:3b
```

**2. Open WebUI can't reach the provider.** The deploy tests this from *inside* the container and says so — the host reaching Ollama proves nothing if the container can't. Both must be on `models-net`:

```bash
docker inspect open-webui --format '{{json .NetworkSettings.Networks}}'
docker inspect ollama     --format '{{json .NetworkSettings.Networks}}'
```

**3. No connection is configured.** If you deployed before any provider existed, add one in **Admin → Settings → Connections** — `http://ollama:11434` for Ollama, or `http://llama-cpp:8080/v1` for an OpenAI-compatible server.

### 🔄 Switched providers? Just rerun this deploy

Providers are mutually exclusive, so deploying llama.cpp **stops** Ollama — and Open WebUI keeps pointing at the container that is no longer running. The symptom is an empty model list with nothing explaining it.

Rerunning `deploy.sh` detects exactly that and offers to fix it:

```
[!] This deployment is configured to use 'ollama', which is not running.
[!] 'llama-cpp' is running instead — you likely switched providers.
Point Open WebUI at llama-cpp? (Y/n):
```

Saying yes rewrites `.env` for you, picking the right variable for the new provider — `OLLAMA_BASE_URL` for Ollama, `OPENAI_API_BASE_URL` for llama.cpp and LocalAI. Declining changes nothing. A cloud endpoint is never treated as "stopped".

---

## 🛠️ Management Commands

```bash
cd ~/docker/open-webui
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Is it running? |
| `docker compose logs -f open-webui` | Follow the logs |
| `docker compose pull && docker compose up -d` | Update |

---

## 💾 Backups

The generic **Backup** in `services.sh` covers this properly: accounts, chat history, settings, prompts and uploaded documents all live in the `open-webui_open-webui-data` volume, and `.env` sits alongside it.

⚠️ `WEBUI_SECRET_KEY` in `.env` signs session cookies. Restoring the data without it doesn't lose anything permanently, but everyone is signed out.

---

## 📌 Notes & Deviations

- **`:main`, never `:ollama`** — see above.
- **No GPU check.** `lib/gpu.sh` isn't called: GPU handling belongs to providers, and this container never loads a model. The `cuda` tag exists for local embeddings only, which this deployment doesn't enable.
- **Two shared networks** — `main-net` for NPM, `models-net` to reach the provider. **Not `ai-net`**, and that is deliberate: this container runs arbitrary Python from its own Workspace Tools — upstream calls importing a Tool *"equivalent to giving them shell access to the server"* — while `ai-net` carries [OpenHands](../../AI-Agents/openhands/), which has no authentication and mounts the Docker socket. The provider stays off `main-net`: no web interface, and an unauthenticated API.
- **Provider detection is generic**, not Ollama-specific. The same code finds llama.cpp or LocalAI later and picks the right environment variable for each.
- **The self-test has two parts** — the interface answering, and the provider being reachable *from inside the container*. They fail independently, and the second is what decides whether the model dropdown has anything in it.

---

## 📜 License

Open WebUI is licensed separately — see the [official repository](https://github.com/open-webui/open-webui). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of DockHub.

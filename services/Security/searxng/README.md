# 🔎 SearXNG

Deploys [SearXNG](https://github.com/searxng/searxng) — a **metasearch engine you run yourself**. It forwards your query to other engines, merges what comes back, and hands you the results. No account, no profile, no history: the engines it queries see a request from your server, not a person they can follow.

Two containers, behind the shared `main-net` network so [NGINX Proxy Manager](../../../README.md) can front it.

See the top of [`docker-compose.yml`](docker-compose.yml) for every deliberate deviation, each one traced to upstream's current files.

---

## 🧭 Two reasons to run this, and they need different answers

**As your own search page.** Set it as your browser's search engine and the queries you type stop feeding a profile.

**As the search tool for an agent.** This is the reason SearXNG is in DockHub. Hermes, OpenClaw and OpenHands can all search the web — and by default Hermes does it through a **rotating ring of five third-party endpoints**, choosing per request, with no log of which one served you. Point it here instead and the query never leaves your server. See [AI-Agents → Can it browse?](../../AI-Agents/README.md#-can-it-browse-can-you-ask-it-to-search).

`deploy.sh` asks which of the two you want, because the second needs a setting the first does not.

---

## ⚠️ The JSON API is off until you ask for it

Upstream's default is:

```yaml
search:
  formats:
    - html
```

**An API query against an instance in that state is refused** — HTTP 403, with nothing in the message about formats. The instance works perfectly in a browser the whole time, so the natural conclusion is that the agent is broken.

Ten `SEARXNG_*` environment variables are honoured — `BASE_URL`, `BIND_ADDRESS`, `DEBUG`, `IMAGE_PROXY`, `LIMITER`, `METHOD`, `PORT`, `PUBLIC_INSTANCE`, `SECRET`, `VALKEY_URL`. **`formats` is not one of them.** It exists only in `settings.yml`, which is why `deploy.sh` writes that file and why `config/` is a bind mount you can open.

Answer **yes** to the JSON question and `deploy.sh` writes it for you, then proves it worked by asking the running instance for JSON and reading the status code.

---

## ⛔️ The repository most guides point at is dead

`searxng/searxng-docker` is **superseded**. Its README says so, and its compose file has been deleted — the templates now live in the main repo under `container/`. Anything telling you to clone `searxng-docker` describes a layout that no longer exists.

This matters beyond tidiness. The old repo shipped `limiter: true`, which blocks API requests. Follow a stale guide and you get an instance that serves a browser and refuses every agent query — the exact failure above, arrived at by a second route.

---

## 🏷️ The one service here that is *not* pinned

Every other service in DockHub pins its image tag. This one runs `latest`, and that is a decision rather than an omission.

SearXNG has **no semantic version**. Its tags are `YYYY.M.D-<commit>`, and some days carry two builds:

```
latest                 = 2026.8.29-d226b78bc   (identical digest — checked)
2026.8.29-451c46aa3
2026.8.28-a30b2d474
```

Pinning would freeze a particular day and commit — and for a metasearch engine that is the *harmful* choice. Engines break whenever Google or Bing change their markup, and the repair ships as a new build. **A pinned SearXNG decays into an instance whose results quietly thin out**, with nothing to tell you why.

`latest` is also well-behaved here, which is not something to assume: it is byte-identical to the newest dated tag. (Flowise's `latest` in this same catalogue turned out to be an *earlier* build than its tagged release.)

Set `SEARXNG_VERSION` in `.env` if you want a fixed tag anyway.

**Architectures: `amd64`, `arm64`, `arm/v7`** — a Raspberry Pi is in scope. Image is ~90 MB.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows, it installs the full bundle automatically (skipping anything already installed).

### 2. Deploy SearXNG

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Security/searxng/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Security/searxng/docker-compose.yml
bash deploy.sh
```

### You'll be guided through:

| Question | What it decides |
|---|---|
| **Enable the JSON API?** | Whether anything but a browser can use it. Default **yes** |
| **Join `ai-net`?** | Whether agents can reach it at `http://searxng-app:8080`. Asked only if JSON is on |
| **Domain via NPM?** | Sets `SEARXNG_BASE_URL`. Optional |
| **Memory limit** | Applied to the app container only |
| **Host port** | Optional direct access. Default **no** — NPM is the only path in |

No password is asked for, and none is generated: **SearXNG has no accounts.** The secret it generates signs preference cookies, nothing more.

---

## 🕸️ What ends up where

```
~/docker/searxng/
├── .env                    # your answers + the generated secret   (chmod 600)
├── docker-compose.yml      # copied from this repo on every run
├── docker-compose.override.yml   # generated — memory, port, ai-net
└── config/
    └── settings.yml        # written ONCE, then never touched again
```

| Network | Who is on it | Why |
|---|---|---|
| `searxng-net` | app ↔ valkey | Private. Valkey has no authentication and nothing else needs it |
| `main-net` | app | So NPM can reach it by container name |
| `ai-net` | app, *if you said yes* | So agents can query it. Not hardcoded — a SearXNG for your own browsing has no business on the agent network |

---

## ✍️ settings.yml is yours

`deploy.sh` writes it on first run and **never rewrites it**. The image's entrypoint follows the same rule (`if [ ! -f "$target_settings" ]`), so between the two nothing overwrites your edits — image updates included.

It is short on purpose:

```yaml
use_default_settings: true
```

That line loads upstream's entire configuration — every engine, every category — and treats the rest of the file as overrides. **Remove it and the file becomes the whole configuration**, engines included, which is to say none.

Useful things to change:

| | |
|---|---|
| Turn engines off | `engines: [{name: google, disabled: true}]` |
| Keep only a few | `use_default_settings: {engines: {keep_only: [duckduckgo, wikipedia]}}` |
| Default language | `search.default_lang: "ar"` |
| Rate-limit a public instance | `server.limiter: true` — needs valkey, which is already running |

Apply changes with `docker compose restart` from `~/docker/searxng/`.

> The container runs with `FORCE_OWNERSHIP=true`, so it takes ownership of `config/` on start. If editing needs `sudo`, that is why — not a permissions bug.

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

> ☁️ **Using Cloudflare Tunnel?** Two steps below are different: where you open NPM, and the SSL certificate (`None`, not Let's Encrypt). See [docs/cloudflare-tunnel.md](../../../docs/cloudflare-tunnel.md#deploying-a-service-behind-the-tunnel).

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: the domain you gave `deploy.sh`
   - **Forward Hostname/IP**: `searxng-app`
   - **Forward Port**: `8080`
   - **Forward Scheme**: **HTTP**
3. Enable **SSL** with Let's Encrypt from the UI.

✅ No host port is published by default — NPM reaches it by container name over `main-net`.

> 🔓 **SearXNG has no login.** If your instance is reachable from the internet, anyone who finds it can search through it — and to the engines those searches look like yours. Put an **Access List** on the Proxy Host, or keep it off the public internet entirely.

---

## 🤖 Pointing an agent at it

For **Hermes**, once SearXNG is on `ai-net`:

```bash
docker exec -it hermes hermes config set web.search_backend searxng
docker exec -it hermes sh -c 'echo SEARXNG_URL=http://searxng-app:8080 >> /opt/data/.env'
docker restart hermes
```

Verify it took effect by asking the instance directly — a 200 means the format is permitted:

```bash
curl -s -o /dev/null -w '%{http_code}\n' "http://<server-ip>:<port>/search?q=test&format=json"
```

To prove the route from *inside* the agent, use the interpreter the image is built on rather than a tool you hope is there — Hermes ships **no `wget`**:

```bash
docker exec hermes python3 -c "import urllib.request;print(urllib.request.urlopen('http://searxng-app:8080/search?q=test&format=json',timeout=10).status)"
```

> Check per image, never per habit. In this catalogue Flowise has wget, Langflow has curl, Paperclip has neither, and Hermes' own deploy probes for all three before choosing. A probe that fails for want of a tool looks exactly like a service that is down.

Other agents take a URL the same way. The address is always `http://searxng-app:8080` from inside `ai-net`.

### ⚠️ Setting the backend is not the same as closing the door

After `web.search_backend = searxng`, `hermes config get web` still reports:

```yaml
search_backend: searxng
extract_backend: ''
keyless_fallback: true
keyless_rescue: true
```

**Two ways a query still reaches a stranger**, and neither announces itself:

**1. SearXNG is search-only.** Upstream's provider says so outright — *"does not fetch/extract arbitrary URLs. `supports_extract()` returns False."* So `web_search` is yours; **`web_extract` has no provider and falls through to the keyless ring.**

**2. A failure is a fallback.** `keyless_rescue` exists precisely to catch a configured backend that errored. SearXNG being briefly down does not produce an error you see — it produces a search served by one of five third parties.

Closing both is one setting, because the rescue is implicitly off whenever the tier is:

```bash
docker exec -it hermes hermes config set web.keyless_fallback false
docker restart hermes
```

**The cost, stated plainly:** `web_extract` stops working rather than silently going elsewhere, and a SearXNG outage becomes a visible failure instead of an invisible leak. Hermes can still fetch a page through its own browser and terminal — what it loses is the one-call convenience. **That is the trade: a tool that fails loudly, or one that quietly succeeds by another route.**

---

## 💾 Backups

Handled by the generic volume backup in `lib/common.sh` — no `backup.sh` is needed. What it captures is `config/settings.yml` and your `.env`; the favicon cache and valkey's counters are regenerable and losing them costs nothing.

```bash
bash services/services.sh
```

---

## 🛠️ Management Commands

```bash
cd ~/docker/searxng

docker compose ps                      # both containers
docker compose logs -f searxng         # the app
docker compose restart                 # after editing settings.yml
docker compose pull && docker compose up -d    # update
docker compose down                    # stop
```

Check which networks it actually joined:

```bash
docker inspect searxng-app --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
```

---

## 📌 Notes & Deviations

- **Container port is 8080, and the reason is Granian.** The image runs Granian as its WSGI server, and the socket is Granian's (`GRANIAN_HOST="::"`, `GRANIAN_PORT="8080"`). `server.bind_address` / `server.port` in `settings.yml` are inert here — their defaults are `127.0.0.1:8888`, which inside a container would mean unreachable. The entrypoint bridges `SEARXNG_PORT` across to `GRANIAN_PORT`, which is why the documented variable still behaves as documented.
- **Container names follow DockHub, not upstream.** Upstream calls them `searxng-core` / `searxng-valkey`; here the app is `searxng-app`, matching the `<service>-app` convention every other service uses and every NPM instruction assumes.
- **`image_proxy: true`**, matching upstream's own container template rather than the bare default — result images are fetched through your instance, so the originating site never sees your address.
- **`limiter` is left off.** Correct for a private instance, and required for agent use. Turn it on only if the instance is public.
- **The deploy self-test runs from the host, not `docker exec`.** The image is built on `searxng/base`, whose contents are not a documented interface — assuming `curl`, `wget` or `python3` is on its PATH would produce a probe that fails for want of a tool and looks exactly like a service that never started. If the *host* has no curl, the script says "not tested" rather than reporting a failure it did not observe.

---

## 📜 License

SearXNG is AGPL-3.0 licensed — see the [official repository](https://github.com/searxng/searxng). This deployment configuration is part of DockHub.

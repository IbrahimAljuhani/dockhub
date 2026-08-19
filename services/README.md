# 🧩 Services

Optional services that run on top of the core infrastructure ([`install_dockhub.sh`](../install_dockhub.sh) — Docker CE, Compose, NGINX Proxy Manager, Portainer, and the shared `main-net` network). Each one lives in its own folder here, is deployed independently, and you only run the ones you actually need.

---

## 📋 Services Roadmap

![Progress](https://img.shields.io/badge/built-39%20%2F%2041%20services-46a049?style=for-the-badge)

[`services.sh`](services.sh) presents these grouped by category. ✅ = deployable now, 🚧 = listed in the menu already (shows "coming soon" if picked) but not built yet.

> 💡 A few services have no badge available — those show a plain icon instead. **Hover it to see its name**, or click through to its README.

| Category | Services |
|---|---|
| **[AI](AI/)** | ✅ [![Ollama](https://img.shields.io/badge/Ollama-000000?style=flat-square&logo=ollama&logoColor=white)](AI/ollama/) · ✅ <a href="AI/open-webui/"><img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/open-webui.svg" width="20" height="20" alt="Open WebUI" title="Open WebUI"></a> · ✅ <a href="AI/llama-cpp/"><img src="https://llama-cpp.com/wp-content/uploads/2025/10/Llama-cpp-300x108.jpg" height="20" alt="llama.cpp" title="llama.cpp"></a> · ✅ <a href="AI/localai/"><img src="https://localai.io/img/logo-mark.png" height="20" alt="LocalAI" title="LocalAI"></a> |
| **[AI-Agents](AI-Agents/)** | ✅ <a href="AI-Agents/openclaw/"><img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/openclaw.svg" width="20" height="20" alt="OpenClaw" title="OpenClaw — personal assistant, multi-channel"></a> · ✅ <a href="AI-Agents/hermes/"><img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/hermes-icon.svg" width="20" height="20" alt="Hermes" title="Hermes Agent — self-improving runtime"></a> · ✅ [![OpenHands](https://img.shields.io/badge/OpenHands-000000?style=flat-square&logo=github&logoColor=white)](AI-Agents/openhands/) |
| **[Multi-Agent](Multi-Agent/)** | 🚧 [![Dify](https://img.shields.io/badge/Dify-0033FF?style=flat-square&logo=dify&logoColor=white)](Multi-Agent/dify/) · 🚧 [![Langflow](https://img.shields.io/badge/Langflow-FF3366?style=flat-square)](Multi-Agent/langflow/) · 🚧 <a href="Multi-Agent/flowise/"><img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/flowise.svg" width="20" height="20" alt="Flowise" title="Flowise — lightest visual builder"></a> · 🚧 <a href="Multi-Agent/paperclip/"><img src="https://paperclip.ing/favicon.svg" width="20" height="20" alt="Paperclip" title="Paperclip — deferred, no official image upstream"></a> |
| **[Automation](Automation/)** | ✅ [![n8n](https://img.shields.io/badge/n8n-EA4B71?style=flat-square&logo=n8n&logoColor=white)](Automation/n8n/) |
| **[DNS](DNS/)** | ✅ [![Pi-hole](https://img.shields.io/badge/Pi--hole-96060C?style=flat-square&logo=pihole&logoColor=white)](DNS/pi-hole/) · ✅ [![AdGuard](https://img.shields.io/badge/AdGuard-68BC71?style=flat-square&logo=adguard&logoColor=white)](DNS/adguard/) |
| **[ERP](ERP/)** | ✅ [![ERPNext](https://img.shields.io/badge/ERPNext-0089FF?style=flat-square&logo=erpnext&logoColor=white)](ERP/erpnext/) · ✅ [![Dolibarr](https://img.shields.io/badge/Dolibarr-263C5C?style=flat-square&logo=dolibarr&logoColor=white)](ERP/dolibarr/) · ✅ [![Odoo](https://img.shields.io/badge/Odoo-714B67?style=flat-square&logo=odoo&logoColor=white)](ERP/odoo/) (multi-instance) |
| **[Home-Automation](Home-Automation/)** | ✅ [![Home Assistant](https://img.shields.io/badge/Home_Assistant-18BCF2?style=flat-square&logo=homeassistant&logoColor=white)](Home-Automation/home-assistant/) · ✅ [![Eclipse Mosquitto](https://img.shields.io/badge/Eclipse_Mosquitto-3C5280?style=flat-square&logo=eclipsemosquitto&logoColor=white)](Home-Automation/mosquitto/) |
| **[Media](Media/)** | ✅ [![Jellyfin](https://img.shields.io/badge/Jellyfin-00A4DC?style=flat-square&logo=jellyfin&logoColor=white)](Media/jellyfin/) · ✅ [![Plex](https://img.shields.io/badge/Plex-EBAF00?style=flat-square&logo=plex&logoColor=white)](Media/plex/) (proprietary — needs a Plex account) |
| **[Photos](Photos/)** | ✅ [![Immich](https://img.shields.io/badge/Immich-4250AF?style=flat-square&logo=immich&logoColor=white)](Photos/immich/) · ✅ <a href="Photos/photoprism/"><img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/photoprism.svg" width="20" height="20" alt="PhotoPrism" title="PhotoPrism"></a> |
| **[Projects](Projects/)** | ✅ [![OpenProject](https://img.shields.io/badge/OpenProject-0770B8?style=flat-square&logo=openproject&logoColor=white)](Projects/openproject/) · ✅ [![Plane](https://img.shields.io/badge/Plane-121212?style=flat-square&logo=plane&logoColor=white)](Projects/plane/) · ✅ [![Vikunja](https://img.shields.io/badge/Vikunja-196AFF?style=flat-square&logo=vikunja&logoColor=white)](Projects/vikunja/) · ✅ [![Redmine](https://img.shields.io/badge/Redmine-B32024?style=flat-square&logo=redmine&logoColor=white)](Projects/redmine/) · ✅ <a href="Projects/taiga/"><img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/taiga.svg" width="20" height="20" alt="Taiga" title="Taiga"></a> |
| **[Security](Security/)** | ✅ [![Vaultwarden](https://img.shields.io/badge/Vaultwarden-000000?style=flat-square&logo=vaultwarden&logoColor=white)](Security/vaultwarden/) |
| **[Security-Lab](Security-Lab/)** ⚠️ | ✅ [![OWASP Juice Shop](https://img.shields.io/badge/OWASP_Juice_Shop-000000?style=flat-square&logo=owasp&logoColor=white)](Security-Lab/juice-shop/) · ✅ [![WebGoat](https://img.shields.io/badge/WebGoat-000000?style=flat-square&logo=owasp&logoColor=white)](Security-Lab/webgoat/) · ✅ [![Vulhub](https://img.shields.io/badge/Vulhub-C1272D?style=flat-square&logo=docker&logoColor=white)](Security-Lab/vulhub/) |
| **[Storage](Storage/)** | ✅ [![Nextcloud](https://img.shields.io/badge/Nextcloud-0082C9?style=flat-square&logo=nextcloud&logoColor=white)](Storage/nextcloud/) · ✅ [![Seafile](https://img.shields.io/badge/Seafile-FF9800?style=flat-square&logo=seafile&logoColor=white)](Storage/seafile/) · ✅ [![ownCloud](https://img.shields.io/badge/ownCloud-041E42?style=flat-square&logo=owncloud&logoColor=white)](Storage/owncloud/) (Infinite Scale — one container, no database) |
| **[VPN](VPN/)** | ✅ [![WireGuard](https://img.shields.io/badge/WireGuard-88171A?style=flat-square&logo=wireguard&logoColor=white)](VPN/wireguard/) · ✅ <a href="VPN/netbird/"><img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/netbird.svg" width="20" height="20" alt="NetBird" title="NetBird"></a> · ✅ [![OpenVPN](https://img.shields.io/badge/OpenVPN-EA7E20?style=flat-square&logo=openvpn&logoColor=white)](VPN/openvpn/) (Access Server — 2 free concurrent connections) |
| **[Web](Web/)** | ✅ [![WordPress](https://img.shields.io/badge/WordPress-21759B?style=flat-square&logo=wordpress&logoColor=white)](Web/wordpress/) · ✅ [![Ghost](https://img.shields.io/badge/Ghost-15171A?style=flat-square&logo=ghost&logoColor=white)](Web/ghost/) · ✅ <a href="Web/linkstack/"><img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/linkstack.svg" width="20" height="20" alt="LinkStack" title="LinkStack (multi-instance)"></a> |

This is the project roadmap, not a promise of order — services get built one at a time. The category/service list itself lives in [`services.sh`](services.sh)'s `CATALOG` array; a service becomes ✅ automatically the moment its `services/<Category>/<slug>/deploy.sh` exists, no separate flag to flip. **The count badge above is hand-maintained — bump it when you add a service.**

---

## 🔌 Suggested Default Ports

Only relevant if you opt into a service's **direct host port** prompt (default is no host port at all — NPM reaches every service by container name). Listed so you can mentally track what's in use before deploying several services at once; each `deploy.sh` still lets you type any port you want at the prompt.

> ⚠️ **Pi-hole and AdGuard Home cannot run on the same host.** Both are DNS servers that bind port `53` unconditionally (not an opt-in prompt), so the second one to start will fail. Pick one — they do the same job.

| Service | Suggested port |
|---|---|
| Odoo | `8069` (+ `8072` for WebSocket/longpolling) |
| Dolibarr | `8086` (optional) → the container's `80`. Note `DOLI_URL_ROOT` in `.env` must match how you reach it — see its README. |
| ERPNext | `8085` (optional) → the frontend container's `8080`. Note the site is named after your domain, so a direct IP:port only works because `FRAPPE_SITE_NAME_HEADER` is pinned to that name — see its README. |
| OpenProject | `8080` |
| Nextcloud | `8080` ⚠️ same suggested default as OpenProject — pick a different one if running both |
| n8n | `5678` |
| LocalAI | `8082` (optional) → the container's `8080`. ⚠️ No authentication, like the other providers. Reached as `localai:8080` with no host port. |
| llama.cpp | `8081` (optional) → the container's `8080`. ⚠️ No authentication, same as Ollama. Other services reach it as `llama-cpp:8080` with no host port. |
| Open WebUI | `3000` (optional) ⚠️ same as Redmine and Juice Shop — pick another if running them together. NPM reaches it as `open-webui:8080`. |
| Ollama | `11434` (optional, **default no**) ⚠️ Ollama's API has NO authentication — a published port exposes your models to the whole LAN. Other services reach it as `ollama:11434` over `ai-net` without one. |
| OpenClaw | `18789` (optional). Has real authentication, unlike the providers — a gateway token generated by `deploy.sh`. ⚠️ But its dashboard needs a **browser secure context**, so the published port alone will not open it: use an SSH tunnel and browse `localhost`. See its [README](AI-Agents/openclaw/README.md). |
| Hermes | `8642` API (optional) and `9119` dashboard. The API key is **mandatory** — upstream allows no loopback exception. The dashboard is bound to `127.0.0.1` **on the server**, not your LAN, and reached over an SSH tunnel; it also refuses to start on a container bind without credentials. |
| OpenHands | `3001` — bound to `127.0.0.1` **on the server**, and that is not offered as a choice. ⚠️ OpenHands has **no authentication of its own**, and it holds the Docker socket, so a LAN binding would publish a root-equivalent agent to everyone on your network. Reached over an SSH tunnel, like Hermes' dashboard. Not `3000` because that is Open WebUI's, Redmine's and Juice Shop's default. **The same port is also published on the docker0 gateway** — not for you, but because each session runtime posts the agent's answers back there; without it every message queues in silence. That address is unreachable from your LAN, but *is* reachable from other containers on this host. See its [README](AI-Agents/openhands/README.md). |
| Redmine | `3000` |
| OWASP WebGoat | `8080` ⚠️ same as OpenProject/Nextcloud, **plus `9090` for WebWolf**. Both are required — WebWolf is the attacker-side half and several lessons silently never complete without it. LAN-bound, not optional. See [Security-Lab](Security-Lab/README.md). |
| OWASP Juice Shop | `3000` ⚠️ same as Redmine — pick another if running both. Unlike every other row here the port is **not optional** (there is no NPM path) and it binds to your **LAN address only**, never `0.0.0.0`. See [Security-Lab](Security-Lab/README.md). |
| Taiga | `9000` |
| Vikunja | `3456` |
| Plane | `8090` |
| LinkStack | `8095` (suggested for each instance — multi-instance, pick a different port per instance if publishing more than one) |
| Jellyfin | `8096` |
| Eclipse Mosquitto | MQTT `1883` — **always** bound to the host, not an opt-in prompt: MQTT isn't HTTP, so NPM can't front it (same as Pi-hole's `53` and WireGuard's `51820`). WebSockets `9001` optional. No web interface at all. |
| Home Assistant | `8123` — **always** bound to the host (host networking, not an opt-in prompt like the others above) |
| Immich | `2283` |
| Pi-hole | Web UI `8081` (optional, deliberately not `80` — NPM owns that already). DNS itself (`53`) is **always** bound to the host, not an opt-in prompt — see its README for the systemd-resolved conflict almost every Ubuntu server has out of the box. |
| WireGuard (wg-easy) | Web UI `51821` (optional). The VPN data port (`51820/udp`) is **always** bound to the host, not an opt-in prompt — same reasoning as Pi-hole's DNS port. |
| WordPress | `8082` ⚠️ deliberately not `8080` (upstream's own default) — already taken by OpenProject/Nextcloud's suggested defaults above |
| AdGuard Home | Setup wizard `3000` ⚠️ same as Redmine's default, admin UI `8080` ⚠️ same as OpenProject/Nextcloud (both optional, asked together). DNS itself (`53`) is **always** bound to the host, not an opt-in prompt — same reasoning as Pi-hole's DNS port. |
| Plex | `32400` |
| PhotoPrism | `2342` |
| Seafile | `8087` (optional) → the container's `80`. ⚠️ `SEAFILE_SERVER_HOSTNAME` in `.env` must carry the port for a direct-port deployment (`192.168.1.50:8087`), and `SEAFILE_SERVER_PROTOCOL` must match — a mismatch surfaces as "CSRF verification failed" at login, not as a config error. |
| ownCloud (Infinite Scale) | `9200` (optional, oCIS's own port). ⚠️ Even this direct port is **https** with a self-signed cert — oCIS's web UI is an OIDC client and needs a browser secure context, so plain http can't work. See its README. |
| Ghost | `2368` (optional, Ghost's own port). `GHOST_URL` in `.env` must match how you reach it — see its README. |
| Vaultwarden | **none** — no host-port option. Its web vault needs a browser "secure context" (HTTPS or localhost), so a direct port can't work; NPM + SSL is the only route. |
| OpenVPN (Access Server) | Web UI `9443` (optional) → the container's own `943`; deliberately not `943` itself, which the shared port prompt rejects as below `1024`. The VPN data port (`1194/udp`) is **always** bound to the host, not an opt-in prompt — same reasoning as WireGuard's. An OpenVPN-over-TCP fallback is optional on `8443` ⚠️ deliberately not `443` (upstream's own default) — NPM owns that. |
| NetBird | **none** for HTTP — the domain is load-bearing for OAuth/gRPC, so NPM + SSL only. STUN (`3478/udp`) is **always** bound to the host and must reach the internet; it can't go through NPM or Cloudflare Tunnel. |

---

## 🚀 Quick Start

### 1. Clone the repo and install the core infrastructure (if you haven't)

```bash
git clone https://github.com/IbrahimAljuhani/dockhub.git
cd dockhub
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows.

### 2. Pick and deploy a service

Pick **`2) Install a service`** from that same menu — it launches [`services.sh`](services.sh) right there. It's a two-level menu: pick a **category** (AI, Automation, ERP, Projects, ...), then a **service** within it. Services not built yet are shown too, marked `(coming soon)` — picking one just prints a notice and drops you back in that category's list instead of failing.

Pick an available (✅) service and you get:

```
1) Deploy / manage (runs deploy.sh — safe for new or existing deployments)
2) Remove
3) Reinstall (remove, then deploy fresh)
4) Backup
5) Restore from backup
0) Back
```

- **Deploy / manage** just runs that service's `deploy.sh` — safe to pick whether it's a fresh install or an existing one (reuses `.env`, won't overwrite `docker-compose.yml`).
- **Remove** stops its containers and asks separately whether to also permanently delete its data (database, uploaded files, secrets). Say no and only the containers/cached compose file go — `.env` and volumes are kept so a later deploy picks up right where you left off.
- **Reinstall** does Remove, then immediately deploys fresh. For multi-instance services (odoo), picking Remove or Reinstall with more than one instance deployed asks which instance first.
- **Backup** saves the entire `~/docker/<service>/` directory (`.env`, compose files, and any bind-mounted data like Vikunja's `files/` or Redmine's `plugins/`/`themes/`) plus every named Docker volume, to `~/docker/backups/<service>/[<instance>/]<timestamp>.tar.gz` — you can create as many as you want, nothing is ever auto-deleted. Services with a separate database container (Postgres/MySQL) additionally use a proper `pg_dump`/`mysqldump` for the database itself instead of copying its live data files, if that service ships a `backup.sh` (see [`services/_template/`](_template/)) — otherwise the database volume just gets tarred as-is (fine for config-only/SQLite-embedded services like Jellyfin/LinkStack, which have no separate database at all).
- **Restore from backup** lists your saved backups (newest first), confirms before overwriting current data, restores, and restarts the service.

Or run `bash services/services.sh` (or `bash deploy.sh` inside any service's own folder, see that service's own README) yourself at any time.

> 💡 **Didn't clone the repo** (just curled `install_dockhub.sh` alone)? "Install a service" still works — `services.sh` detects there's no local checkout and downloads the service you pick fresh from GitHub instead. See [`services.sh`](services.sh) usage in that case: `curl -fsSL -o services.sh https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/services.sh && bash services.sh`.
>
> Everywhere in this repo, run scripts as `bash <file>` rather than `chmod +x <file> && ./<file>` — a fresh `git clone`/`git pull` doesn't reliably preserve the executable bit, and `bash <file>` works regardless of it.

> ⚠️ **Do not run `services.sh` or any `deploy.sh` as root.** Your user must be in the `docker` group (set up by `install_dockhub.sh`).

---

## 📐 Convention Every Service Follows

- **Its own `.env`** — generated automatically by `deploy.sh` with random secrets (never committed; covered by the root [`.gitignore`](../.gitignore)), `chmod 600`.
- **Networking**: a private `<service>-net` for the service's own containers (app ↔ db, etc.), and only the app/entrypoint container also joins the shared external `main-net` so NPM can reach it by container name. Databases and internal-only containers never touch `main-net` and never publish a host port.
  - *Two documented exceptions.* **Single-container services with no database** (Jellyfin, Plex, LinkStack, Pi-hole, AdGuard Home) skip the private network entirely and join `main-net` directly — there's nothing to isolate them from. **[Home Assistant](Home-Automation/home-assistant/) joins no Docker network at all**: it needs `network_mode: host` for local-device discovery (mDNS/SSDP), which is exclusive of Compose networking, so NPM forwards to the server's own LAN IP instead of a container name. Each exception is explained in that service's own README.
- **Naming**: containers are `<service>-app` / `<service>-db` (or descriptive names for additional containers in multi-container stacks, e.g. `openproject-worker`).
- **Runtime state**: lives under `~/docker/<service>/` on the host (not inside this repo checkout) — logs, generated `.env`, and secrets files all land there, so the whole host's state stays backupable as one `~/docker/` tree.
- **Reruns are safe**: `deploy.sh` never overwrites an existing `docker-compose.yml` at `~/docker/<service>/` (so manual edits survive) and reuses an existing `.env` without re-prompting.
- **Optional memory cap**: most services ask once (on first deploy) whether to cap the main container's memory, applied via a generated `docker-compose.override.yml`. Say no and it runs uncapped.
- **Optional direct host port**: most services also ask once whether to publish a host port for quick direct access without NPM (default: no). Choosing one also flips any HTTPS-only-assuming settings (secure cookies, forced redirects) to their plain-HTTP-safe equivalents automatically — otherwise the direct port would be inaccessible. See the relevant "Reverse Proxy" section in each service's README for exactly what changes.
- **Shared logic lives in [`lib/common.sh`](../lib/common.sh)**, not copy-pasted per service — `prompt_mem_limit`, `prompt_host_port`, `prompt_domain`, `read_env_value`, `generate_secret`, `ensure_main_net`, backup/restore, and the environment-detection reader all come from there. Two of those exist because of specific bugs and should always be preferred over the obvious inline alternative: **`read_env_value`** instead of `grep KEY= .env | cut` (plain `grep` prints `Binary file … matches` and hands that back as the value), and **`prompt_domain`** instead of `read` + `validate_domain` (the latter *exits*, so one stray pasted character or an accidental Enter aborts the entire deploy instead of re-asking). Every `deploy.sh` sources it (self-fetching a copy via `curl` first if run standalone, so a bare `curl deploy.sh && bash deploy.sh` still works with no extra steps). Never redefine these functions locally in a new service's `deploy.sh`.

> ⚠️ **Using Cloudflare Tunnel instead of a normal DNS A/AAAA record?** This applies to every service here, not just one — full guide: [docs/cloudflare-tunnel.md](../docs/cloudflare-tunnel.md). Short version: `cloudflared` delivers traffic to NPM over plain HTTP by design (Cloudflare's edge already terminates HTTPS for the visitor); leaving **Force SSL off** on the Proxy Host avoids a redirect loop that otherwise surfaces as `400 Bad Request — Request Header Or Cookie Too Large`. Not a security downgrade — Cloudflare's edge still enforces HTTPS to every visitor regardless. Other network/reverse-proxy issues: [docs/troubleshooting.md](../docs/troubleshooting.md).

---

## ➕ Adding a New Service

1. Pick the category it belongs to (see the roadmap table above, or `services.sh`'s `CATALOG` array), then copy [`_template/`](_template/) to `services/<Category>/<slug>/` and adapt `deploy.sh.template` and `docker-compose.template.yml` to the new service, following the conventions above. See [`services/ERP/odoo/deploy.sh`](ERP/odoo/deploy.sh) for a full-featured example (multi-instance, interactive secret generation) or [`services/Storage/nextcloud/deploy.sh`](Storage/nextcloud/deploy.sh) for a simpler single-instance one.
2. Add `[<slug>]="docker-compose.yml ..."` to `services.sh`'s `SERVICE_FILES` table, listing every file besides `deploy.sh` the service needs (keep in sync with that service's own README "Installation" curl commands).
3. If `<slug>` isn't already in `services.sh`'s `CATALOG` array as a `🚧` placeholder, add it there too (`Category|slug|Display Name`) — otherwise it's already there and just flips to ✅ automatically. `Category` here must exactly match the folder name from step 1.
4. If the service has a separate database container (Postgres/MySQL), copy [`_template/backup.sh.template`](_template/backup.sh.template) to `services/<Category>/<slug>/backup.sh` and adapt its `backup_<slug>()`/`restore_<slug>()` to that database (`pg_dump`/`psql` for Postgres, `mariadb-dump`/`mysqldump` for MySQL/MariaDB) — see [`Projects/vikunja/backup.sh`](Projects/vikunja/backup.sh) or [`Web/wordpress/backup.sh`](Web/wordpress/backup.sh) for worked examples. Add `backup.sh` to the service's `SERVICE_FILES` entry from step 2 as well.
   > ⚠️ These functions must go in **`backup.sh`, not `deploy.sh`**. `services.sh` only ever `exec`s `deploy.sh` as its own process (never sources it, since it's full of top-level side-effecting code), so a backup function defined there would be **silently invisible** — backups would appear to work and quietly fall back to the generic volume copy.

   Services with no separate database (SQLite-embedded, like Jellyfin or LinkStack) don't need a `backup.sh` at all — the generic volume-based backup in `lib/common.sh` already covers them correctly.

Don't guess at a new service's official Docker image, required environment variables, or ports — check that project's own official Docker/Compose documentation first.

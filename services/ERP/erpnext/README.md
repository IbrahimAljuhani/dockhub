# 📊 ERPNext

Deploys [ERPNext](https://erpnext.com/) (a full open-source ERP — accounting, inventory, HR, manufacturing, CRM) on the [Frappe framework](https://frappeframework.com/), behind the shared `main-net` network so [NGINX Proxy Manager](../../../README.md) can front it.

Adapted from Frappe's own [`frappe_docker`](https://github.com/frappe/frappe_docker) — its `compose.yaml` plus the single-file `pwd.yml`. See the top of [`docker-compose.yml`](docker-compose.yml) for the exact, deliberate deviations from upstream.

---

## ⚠️ Read This Before Deploying

**1. This is the heaviest service in this repo — 11 containers.**

| Container | Role |
|---|---|
| `erpnext-configurator` | One-shot: writes the db/redis connection config |
| `erpnext-create-site` | One-shot: runs `bench new-site`, installs the erpnext app |
| `erpnext-backend` | The Python app server (gunicorn) |
| `erpnext-frontend` | nginx — static assets, routes to backend/websocket |
| `erpnext-websocket` | Node.js socket.io, real-time UI updates |
| `erpnext-queue-short` | Background worker (short + default queues) |
| `erpnext-queue-long` | Background worker (long + default + short) |
| `erpnext-scheduler` | Scheduled/cron jobs |
| `erpnext-db` | MariaDB |
| `erpnext-redis-cache` | Cache |
| `erpnext-redis-queue` | Job queue + socket.io pub/sub |

None are optional — Frappe genuinely splits the work this way. Budget **4 GB RAM minimum**, 8 GB to be comfortable. First-run site creation compiles assets and takes **5–15 minutes**; `deploy.sh` waits for it and reports progress rather than claiming success early.

**2. Every ERPNext site has a name, and you're asked for it up front.**

Frappe is multi-tenant. By default it decides *which site to serve* from the HTTP `Host` header, which is why upstream deployments must name a site after its domain — serve a site named `erp.example.com` at `erp.other.com` and you'd get **"Site not found"**.

**This deployment removes that constraint.** `FRAPPE_SITE_NAME_HEADER` is pinned to the site name instead of upstream's `$host` default, and Frappe's nginx template substitutes it into `proxy_set_header X-Frappe-Site-Name` when the config is built — so *every* request resolves to this one site, whatever `Host` arrives. A domain, a different domain, a raw IP:port: all reach it.

So the site name is effectively a **label**, and the question is unconditional simply because a site must be called something at creation time.

It still matters for one thing: `host_name`, which Frappe uses to build absolute URLs in password-reset links, notification emails, and PDF assets. `deploy.sh` sets it from the name you give. That's the real reason to use your actual domain if you have one — not reachability.

> 📌 The trade for pinning is that this is **single-site** by design. It is anyway.

### Just trying it out, with no domain?

Answer the domain question with your **server's LAN IP** — `192.168.1.50` throughout this section is a placeholder, substitute your own — and say yes to the host port. Frappe accepts an IP as a site name — upstream's own docs use `127.0.0.1` for local debugging — and `deploy.sh` adjusts accordingly: `host_name` becomes `http://192.168.1.50:8085` instead of an `https://` URL the site doesn't serve, and it skips the NPM instructions rather than printing a route that wouldn't work.

**Adding a domain later works without renaming anything.** Because the site name is pinned rather than matched against `Host` (see above), you can put NPM in front of an IP-named site whenever you like and it will serve normally. The one thing to update is the link-building config:

```bash
docker exec erpnext-backend bench --site 192.168.1.50 set-config host_name https://erp.example.com
```

> 💡 Still, if you already know the domain you'll use, enter it now — it saves that step and keeps the site name meaningful. Nothing about site creation requires the domain to resolve yet, so you can enter it before DNS points anywhere.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows.

### 2. Deploy ERPNext

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/ERP/erpnext/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/ERP/erpnext/docker-compose.yml
curl -fsSL -o backup.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/ERP/erpnext/backup.sh
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

This is a **single-instance** service (unlike [Odoo](../odoo/), which supports multiple named instances) — one ERPNext deployment per host, under `~/docker/erpnext/`.

You'll be asked for:

| Question | Notes |
|---|---|
| **Site domain** | Required, and becomes the site's name. See above. |
| Memory limit | Optional, suggested `2g`, applied to `erpnext-backend` only. |
| Host port | Optional, default `8085` → the frontend's `8080`. |

`deploy.sh` generates the MariaDB root password and the ERPNext Administrator password, saving them to `.env` (`600`) and a readable copy at `~/docker/erpnext/.erpnext-docker-secrets.txt` (`600`).

Rerunning `deploy.sh` is safe: it reuses `.env`, and the `create-site` container sees the site already exists and exits without touching it.

---

## 👤 First Login

Username **`Administrator`**, password from the secrets file:

```bash
cat ~/docker/erpnext/.erpnext-docker-secrets.txt
```

ERPNext then runs its own setup wizard on first login — company name, currency, fiscal year, chart of accounts.

> 📌 The login is `Administrator` with a capital A. It is not an email address, and it is not `admin`.

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: your domain. It does *not* have to equal the site name — the site name is pinned, see above — but using the same one keeps `host_name` and generated links correct with no extra step.
   - **Forward Hostname/IP**: `erpnext-frontend`
   - **Forward Port**: `8080`
   - Enable **Websockets Support** ← required; real-time updates use socket.io
3. Enable **SSL** with Let's Encrypt from the UI.

Scheme stays `http` — the frontend container serves plain HTTP, and NPM terminates TLS.

No custom nginx block is needed. Upload size (`50m`) and proxy timeout (`120s`) are already set on the frontend container itself; raise them in `docker-compose.yml` if you attach large files.

✅ No host port is published by default — NPM reaches `erpnext-frontend` by container name over `main-net`. Everything else stays on the private `erpnext-net`.

---

## 🩺 "Site not found" / blank page

This shouldn't happen here — the site name is pinned rather than matched against `Host` — so if you see it, the two halves have drifted apart. Check what site actually exists:

```bash
docker exec erpnext-backend ls sites
```

Then what the frontend was told to ask for:

```bash
docker exec erpnext-frontend env | grep FRAPPE_SITE_NAME_HEADER
```

**Those two must be identical.** They can drift if `SITE_NAME` in `.env` was edited after the site was created — the frontend picks up the new value on restart, but the site directory keeps its original name. Set `SITE_NAME` back to the name that actually exists under `sites/` and rerun `deploy.sh`.

> ⚠️ **Editing `SITE_NAME` does not rename an existing site.** The site directory and its database keep the name they were created with; only the frontend's pinned header follows `.env`. To genuinely change a site's name, either use Frappe's own `bench` rename procedure, or — on a deployment with nothing in it yet — remove and redeploy (services.sh → **Reinstall**), which is much faster.
>
> If all you want is a domain in front of an IP-named site, you don't need any of this: proxy it and update `host_name` (see [Just trying it out](#just-trying-it-out-with-no-domain)).

If the site directory doesn't exist at all, site creation failed or is still running:

```bash
cd ~/docker/erpnext && docker compose logs create-site
```

---

## 🛠️ Management Commands

```bash
cd ~/docker/erpnext
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Status of all 11 containers |
| `docker compose logs -f backend` | Follow the app server's logs |
| `docker compose logs -f create-site` | First-run site creation progress |
| `docker compose logs -f queue-long` | Background job failures show up here |
| `docker compose pull && docker compose up -d` | Update to the image tag in `.env` |

Frappe's own CLI, `bench`, runs inside the backend container:

```bash
docker exec erpnext-backend bench --site <your-domain> list-apps
```

```bash
docker exec erpnext-backend bench --site <your-domain> set-admin-password <new-password>
```

> 💡 **Upgrading ERPNext** is not just a `docker compose pull` — a new image usually ships schema changes that need `bench migrate` afterwards. Bump `ERPNEXT_VERSION` in `.env`, `docker compose up -d`, then run `docker exec erpnext-backend bench --site <your-domain> migrate`. Take a backup first.

---

## 💾 Backups

This service ships a DB-aware [`backup.sh`](backup.sh), so the **Backup** option in `services.sh` dumps MariaDB properly instead of raw-copying live database files. Two ERPNext-specific details it handles:

- **`--all-databases`**, because Frappe names a site's database after a generated hash, and creates a per-site DB user that lives in the `mysql` system database. Dumping only the site database would restore the data but not the account allowed to read it.
- **MariaDB 11 renamed the client binaries** (`mysqldump` → `mariadb-dump`); it tries the new name first and falls back.

The `sites` volume — site config, uploaded files, and the site's **encryption key** — is captured by the same run.

⚠️ That encryption key protects stored passwords and API secrets. A database restored **without** the matching `sites` volume leaves those fields unreadable, so always keep the two halves of a backup together.

> 💡 Frappe also has its own `bench --site <domain> backup --with-files`, which writes into `sites/<domain>/private/backups/`. It's the right tool if you want a Frappe-native archive to hand to another Frappe host; the repo's backup covers the whole deployment instead.

---

## 📌 Notes & Deviations

- **Generated passwords.** Upstream's `pwd.yml` hardcodes `admin` for both the MariaDB root password and the Administrator password. Both are generated here.
- **`FRAPPE_SITE_NAME_HEADER` pinned to the site name**, not upstream's `$host` default — see above. Costs multi-site, buys one less way to fail.
- **`UPSTREAM_REAL_IP_ADDRESS` is discovered, not hardcoded.** `deploy.sh` reads `main-net`'s actual subnet so nginx trusts NPM's `X-Forwarded-For`. Left at upstream's `127.0.0.1` default, every login record and audit-log entry in the ERP would show NPM's container IP instead of the real user's — bad in any system with an audit trail. Same class of setting as Jellyfin's "Known proxies" and NetBird's `trustedHTTPProxies`.
- **`pull_policy: missing`, not upstream's `always`.** Upstream defaults to a floating tag where re-pulling makes sense; this file pins an exact version, so `always` would mean nine pointless registry round-trips on every rerun.
- **The site-creation wait loop was simplified.** Upstream's `create-site` opens with a ~15-line `jq` polling loop re-reading `common_site_config.json`. It's redundant here — `depends_on: configurator: service_completed_successfully` already guarantees the configurator exited 0, and writing that file is all it does. Upstream's version also uses backslash continuations inside a YAML folded scalar, a construct subtle enough not to transcribe untested.
- **Only `frontend` joins `main-net`**; the other ten containers stay on the private `erpnext-net`. Upstream puts everything on one network with no external network at all.
- **No Traefik.** Upstream's production overrides bundle Traefik with its own Let's Encrypt, which would collide with NGINX Proxy Manager on ports 80/443.

---

## 📜 License

ERPNext and Frappe are licensed separately (GPL-3.0 — see the [official repository](https://github.com/frappe/erpnext)). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of this repo.

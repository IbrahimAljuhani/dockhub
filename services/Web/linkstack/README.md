# 🔗 LinkStack

Deploys [LinkStack](https://linkstack.org/) (a self-hosted Linktree/many.link alternative — one page with all your links) behind the shared `main-net` network so [NGINX Proxy Manager](../../../README.md) can front it.

Adapted from the official [`linkstack-docker`](https://github.com/LinkStackOrg/linkstack-docker) image and its documented `docker-compose.yml` example. See the top of [`docker-compose.yml`](docker-compose.yml) for the exact, deliberate deviations from upstream.

LinkStack is otherwise the simplest service in this repo: **one container**, SQLite embedded (no separate database container at all) — but it's **multi-instance** (like this repo's Odoo), so you can run more than one LinkStack site (e.g. a personal one and a client's) on the same host.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows, it installs the full bundle automatically (skipping anything already installed).

### 2. Deploy LinkStack

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Web/linkstack/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Web/linkstack/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

Every run of `deploy.sh` creates a **new** instance under `~/docker/linkstack/<instance-name>/` — same convention as this repo's Odoo. Unlike this repo's other (single-instance) services, there's no "rerun to manage an existing deployment" flow; rerunning `deploy.sh` just lets you add another instance. There's also no password or secret to generate — LinkStack has no database credentials (SQLite, embedded in its own Docker volume) and creates its own app secret internally during its first-run setup wizard.

### You'll be guided through:

| # | Prompt | Notes |
|---|---|---|
| 1 | **Instance name** (e.g. `linkstack-prod`) | Validated: lowercase letters, digits, `-`, `_` only. Must not already exist. |
| 2 | **Memory limit for the `linkstack-<instance>` container?** (default: **no** → unbounded) | Suggested default `512m` if you say yes |
| 3 | **Publish a host port for direct access without NPM?** (default: **no**) | e.g. `http://<server-ip>:8095` — useful for a quick first check before wiring up NPM. Maps to the container's plain-HTTP port 80 (not 443) specifically so a quick test doesn't hit LinkStack's self-signed HTTPS certificate. |
| 4 | **Public domain** (only asked if you said no to a host port) | e.g. `links.example.com` — sets `SERVER_NAME` (Apache's `ServerName` for both the HTTP and HTTPS vhosts) |

If you published a host port, the domain question is skipped — `SERVER_NAME` is set to your server's bare IP automatically. Unlike Vikunja/Plane, LinkStack has no CORS or host-header check, so a mismatched `SERVER_NAME` won't break access — it's just used for Apache's own canonical-URL generation.

> 💡 **To change the host port or memory limit later**: like Odoo, `deploy.sh` only ever runs once per instance and never regenerates `docker-compose.override.yml` on its own. Hand-edit `~/docker/linkstack/<instance>/docker-compose.override.yml` directly, then `cd ~/docker/linkstack/<instance> && docker compose up -d`.

### 📁 Directory structure (multiple instances)

```
~/docker/linkstack/
├── linkstack-personal/
│   ├── .env
│   └── docker-compose.yml
└── linkstack-client/
    ├── .env
    └── docker-compose.yml
```

---

## 👤 First Login

LinkStack has **no default admin account**. Visiting the site for the first time runs its own setup wizard, which will:

1. Check server dependencies
2. Set up the database (SQLite, automatic — no input needed)
3. Create your admin account
4. Configure the app

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

> ☁️ **Using Cloudflare Tunnel?** Two steps below are different: where you open NPM, and the SSL certificate (`None`, not Let's Encrypt). See [docs/cloudflare-tunnel.md](../../../docs/cloudflare-tunnel.md#deploying-a-service-behind-the-tunnel).

> ⚠️ **This service is different from every other one in this repo.** LinkStack's container serves HTTPS internally on port 443 with its own self-signed certificate, and upstream's own docs are explicit: *"Make sure to use HTTPS to access your container to avoid mixed content errors."* Proxying plain HTTP to port 80 (like every other service here) will cause broken/mixed-content pages.

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: the same domain you entered during `deploy.sh` (should match `SERVER_NAME` in `.env`)
   - **Forward Hostname/IP**: `linkstack-<instance>` (e.g. `linkstack-prod`)
   - **Forward Port**: `443`
   - **Forward Scheme**: **HTTPS** — not the default HTTP. NPM does not validate the container's self-signed certificate, so this works without extra configuration; you just need to actually pick HTTPS in the dropdown.
3. Enable **SSL** with Let's Encrypt from the UI (this is the outward-facing cert visitors see; it's separate from the container's internal self-signed one).

✅ No host port is published for `linkstack-<instance>` by default — NPM reaches it by container name over `main-net`.

---

## 🛠️ Management Commands

```bash
cd ~/docker/linkstack/<instance-name>
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Check container status |
| `docker compose logs -f linkstack` | Follow the app's logs |
| `docker compose stop` / `start` | Stop/start without removing containers |
| `docker compose pull && docker compose up -d` | Update to the latest image |

LinkStack also has its own **in-app one-click updater** — after logging in as admin, an update notification appears in the Admin Panel if a new version is available.

---

## 🏷️ Removing the "Powered by LinkStack" Badge

Profile pages show a "Powered by LinkStack" footer by default. This is controlled by `DISPLAY_CREDIT` and `DISPLAY_CREDIT_FOOTER` in **LinkStack's own app-level `.env`** — confirmed directly in the [official `.env` template](https://github.com/LinkStackOrg/LinkStack/blob/main/.env), both default to `true`. It's not a license requirement (LinkStack is GPL-3.0) — the project itself ships the off-switch.

> ⚠️ This is a **different `.env`** than the one `deploy.sh` manages. LinkStack's app config lives inside the container at `/htdocs/.env` (part of that instance's `linkstack_data` volume); `~/docker/linkstack/<instance>/.env` only holds Apache/PHP-level settings (`TZ`, `SERVER_NAME`, etc.) — `deploy.sh` never touches the app-level one.

Check the Admin Panel settings first in case it's exposed there. If not, edit it directly (replace `linkstack-<instance>` with the actual container name, e.g. `linkstack-prod`):

```bash
docker exec linkstack-<instance> sed -i -e "s/^DISPLAY_CREDIT_FOOTER=.*/DISPLAY_CREDIT_FOOTER=false/" -e "s/^DISPLAY_CREDIT=.*/DISPLAY_CREDIT=false/" /htdocs/.env
docker restart linkstack-<instance>
```

This survives updates and restarts since `/htdocs` is the persistent volume.

---

## 📌 Known Simplifications vs. Upstream

- Upstream's own example publishes a host port unconditionally (e.g. `8190:443`); here that's optional (default: no), matching this repo's "NPM-only unless you opt in" convention.
- No private `<service>-net` — every other service here isolates its database on a private network and only joins the app container to `main-net`. LinkStack has nothing to isolate (one container, no database container), so the app container joins `main-net` directly.
- `PHP_MEMORY_LIMIT` (LinkStack's own PHP-level memory setting) and `UPLOAD_MAX_FILESIZE` are left at upstream's defaults (`256M` / `8M`) rather than exposed as prompts — this repo's own `MEM_LIMIT` prompt controls the container's overall memory instead, which is a different thing.
- `linkstack_data` has no instance suffix in the compose file's YAML key — Docker Compose automatically prefixes it with the per-instance directory's project name, which is what actually keeps multiple instances' data from colliding (same mechanism this repo's Odoo uses). `container_name`/`hostname` are explicitly suffixed with `${INSTANCE_NAME}` instead, since Compose does not auto-suffix those the way it does un-named volumes.

---

## 📜 License

LinkStack itself is licensed separately (GPL-3.0 — see the [official repository](https://github.com/LinkStackOrg/LinkStack) for terms). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of this repo.

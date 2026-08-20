# ☁️ Nextcloud

Deploys [Nextcloud](https://nextcloud.com/) (file sync & sharing) behind the shared `main-net` network so [NGINX Proxy Manager](../../README.md) can front it.

Adapted from the official [nextcloud/docker](https://github.com/nextcloud/docker/tree/master/.examples/docker-compose/insecure/postgres/apache) reference compose (Postgres + Redis + Apache). See the top of [`docker-compose.yml`](docker-compose.yml) for the exact, deliberate deviations from upstream.

> 📝 **Resources**: Nextcloud's official docs only give per-process minimums (128–512 MB RAM). In practice, budget at least **1–2 GB RAM** for a small personal/team instance — usage grows with file count, active users, and installed apps. ([source](https://docs.nextcloud.com/server/stable/admin_manual/installation/system_requirements.html))

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows, it installs the full bundle automatically (skipping anything already installed).

### 2. Deploy Nextcloud

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Storage/nextcloud/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Storage/nextcloud/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

You'll be prompted for the admin username. `POSTGRES_PASSWORD` and the admin password are generated automatically and saved to `.env` (`600`) and a one-time readable copy at `~/docker/nextcloud/.nextcloud-docker-secrets.txt` (`600`).

Nextcloud auto-installs on first `docker compose up` using `NEXTCLOUD_ADMIN_USER`/`NEXTCLOUD_ADMIN_PASSWORD` — no manual setup wizard needed. Give it a minute or two on first start.

You'll also be asked whether to cap memory on the `app` container (default suggestion: `1g`; `db`/`redis`/`cron` stay unbounded either way). Say no and it runs uncapped.

> 💡 **To change the memory limit later**: edit `MEM_LIMIT=` in `~/docker/nextcloud/.env` (change the value, or delete the line entirely to remove the cap), then rerun `deploy.sh` — it regenerates `docker-compose.override.yml` from whatever `.env` currently has and reapplies it with `docker compose up -d`.

You'll also be asked whether to publish a host port for direct access without NPM (e.g. `http://<server-ip>:8080`) — useful for a quick first check that the container actually works before wiring up NPM. Default is no (main-net/NPM only, matching the rest of this repo's services). Say yes and the port is checked for conflicts, then printed as a URL once Nextcloud starts.

- **If you said no** to a host port, you're then prompted for the public domain you plan to point NPM at (e.g. `cloud.example.com`) — this becomes `NEXTCLOUD_TRUSTED_DOMAINS`, and `OVERWRITEPROTOCOL=https`.
- **If you said yes** to a host port, the domain question is skipped — `NEXTCLOUD_TRUSTED_DOMAINS` is set to `<server-ip>:<port>` automatically, and `OVERWRITEPROTOCOL=http`. This matters because **Nextcloud rejects every request with "Access through untrusted domain" unless the domain is in `NEXTCLOUD_TRUSTED_DOMAINS` exactly** — a placeholder domain wouldn't match `<server-ip>:<port>`. `OVERWRITEPROTOCOL=https` would also force a redirect to `https://`, making a bare `http://` direct port inaccessible.

Either way, this choice (like memory and secrets) is only asked once — rerunning `deploy.sh` reuses `.env` and **never overwrites an existing `docker-compose.yml`** at `~/docker/nextcloud/` (so any manual edits you make there survive reruns; delete it yourself first if you want the latest version from this repo).

Once you switch to NPM+SSL, edit `NEXTCLOUD_TRUSTED_DOMAINS` to your real domain and `OVERWRITEPROTOCOL=https` (and remove `HOST_PORT=` if you no longer want the direct port) in `.env` and rerun `deploy.sh`.

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: the same domain you entered during `deploy.sh` (must be in `NEXTCLOUD_TRUSTED_DOMAINS`)
   - **Forward Hostname/IP**: `nextcloud-app`
   - **Forward Port**: `80`
   - Enable **Websockets Support** (needed for the desktop/mobile clients' notification push)
3. Enable **SSL** with Let's Encrypt from the UI.

✅ No host port is published for `app` — NPM reaches it by container name over `main-net`.

> ⚠️ **`docker-compose.yml` sets `TRUSTED_PROXIES: 172.16.0.0/12`** — this covers Docker's default bridge-network address range (so NPM's container IP on `main-net` is trusted), but it's intentionally broad rather than the exact subnet, since `main-net` gets an auto-assigned subnet at creation time. Narrow it yourself with `docker network inspect main-net` (look for `IPAM.Config.Subnet`) if you want it pinned exactly.

---

## 🛠️ Management Commands

```bash
cd ~/docker/nextcloud
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Check container status |
| `docker compose logs -f app` | Follow the main app's logs |
| `docker compose exec -u www-data app php occ status` | Check install/upgrade status via Nextcloud's CLI tool |
| `docker compose stop` / `start` | Stop/start without removing containers |
| `docker compose pull && docker compose up -d` | Update to the latest `nextcloud:apache` image |

> 💡 After updating the image, Nextcloud may need `docker compose exec -u www-data app php occ upgrade` to finish a version upgrade — check `docker compose logs app` first.

---

## 📌 Known Simplifications vs. Upstream

- Postgres pinned to `18-alpine` (Nextcloud's current recommended version) instead of upstream's unpinned `postgres:alpine`, for reproducibility.
- Redis has no password set, matching upstream's own reference — it's not reachable outside the private `nextcloud-net` anyway. Add `REDIS_HOST_PASSWORD` yourself if you want defense-in-depth.
- `TRUSTED_PROXIES` uses the broad default-Docker-range approach described above rather than a pinned subnet — see the warning in the Reverse Proxy section.

---

## 💾 Backup and restore

Run from the menu: `bash services/services.sh` → this service → **4) Backup** / **5) Restore**.

This service ships a `backup.sh` because its state is split in two: **Postgres** holds the data, and the install tree holds the rest. The generic archive captures the second and would take a raw, mid-write copy of the first — a `pg_dump` is a consistent snapshot; a file copy of a running database is a coin toss.

**What restore actually does, because it is not obvious.** `restore_service_generic` puts the *volumes* back first, so by the time the dump replays, the database is already a complete copy of itself. Replaying into that gives "relation already exists" on every statement — and `psql < file` **exits 0 even when every statement failed**, so it would report success. So the restore instead: stops the app, `dropdb --force`, `createdb`, then replays with `ON_ERROR_STOP=1 --single-transaction`. If the drop or create fails, the replay is **skipped** rather than half-applied, and the restored volume is left coherent.

> ⚠️ **Restore replaces the current data.** It is not a merge. Take a fresh backup first if the running deployment holds anything you have not archived.

---

## 📜 License

Nextcloud itself is licensed separately (AGPLv3) — see the [official repository](https://github.com/nextcloud/server) for terms. This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of this repo.

# 📝 WordPress

Deploys [WordPress](https://wordpress.org/) (the world's most popular CMS/blogging platform) behind the shared `main-net` network so [NGINX Proxy Manager](../../../README.md) can front it.

Adapted from the official [Docker Hub `wordpress` image](https://hub.docker.com/_/wordpress)'s own `docker-compose.yml` example (WordPress + MySQL). See the top of [`docker-compose.yml`](docker-compose.yml) for the exact, deliberate deviations from upstream.

Unlike OpenProject/Nextcloud, WordPress's official image already handles reverse-proxy HTTPS detection out of the box — its own `wp-config-docker.php` checks the `X-Forwarded-Proto` header and sets `$_SERVER['HTTPS']` accordingly automatically, verified directly in the [official image's source](https://github.com/docker-library/wordpress/blob/master/wp-config-docker.php). No manual "flip HTTPS settings for direct host-port access" step is needed here.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows, it installs the full bundle automatically (skipping anything already installed).

### 2. Deploy WordPress

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Web/wordpress/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Web/wordpress/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

This is a **single-instance** service: one WordPress deployment per host, under `~/docker/wordpress/`.

`deploy.sh` generates and saves a random `WORDPRESS_DB_PASSWORD` (to `.env`, `600`, and a one-time readable copy at `~/docker/wordpress/.wordpress-docker-secrets.txt`, `600`). The MySQL root password is randomized by the database image itself and never surfaced anywhere — this deployment never needs it, only the app-level database user.

You'll also be asked whether to cap memory on the `wordpress-app` container (default suggestion: `512m`) — `db` stays unbounded, same "main container only" convention every other service here follows.

> 💡 **To change the memory limit later**: edit `MEM_LIMIT=` in `~/docker/wordpress/.env`, then rerun `deploy.sh` — it regenerates `docker-compose.override.yml` from whatever `.env` currently has and reapplies it with `docker compose up -d`.

You'll also be asked whether to publish a host port for direct access without NPM (e.g. `http://<server-ip>:8082`) — useful for a quick first check before wiring up NPM. Default is no. (Suggested default is `8082`, not upstream's own `8080` — that port is already suggested by both OpenProject and Nextcloud in this repo; picking a third default at 8080 would just guarantee a collision if you run more than one.)

Either way, this choice (like memory and the DB password) is only asked once — rerunning `deploy.sh` reuses `.env` and **never overwrites an existing `docker-compose.yml`** at `~/docker/wordpress/` (so any manual edits you make there survive reruns; delete it yourself first if you want the latest version from this repo).

---

## 👤 First Login

WordPress has **no default admin account**. Visiting the site for the first time runs WordPress's own famous setup wizard — pick a site title, and create your own admin username/password/email.

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

> ☁️ **Using Cloudflare Tunnel?** Two steps below are different: where you open NPM, and the SSL certificate (`None`, not Let's Encrypt). See [docs/cloudflare-tunnel.md](../../../docs/cloudflare-tunnel.md#deploying-a-service-behind-the-tunnel).

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: your chosen domain, e.g. `blog.example.com`
   - **Forward Hostname/IP**: `wordpress-app`
   - **Forward Port**: `80`
3. Enable **SSL** with Let's Encrypt from the UI.

✅ No host port is published for `wordpress-app` by default — NPM reaches it by container name over `main-net`. `db` stays on the private `wordpress-net` only.

---

## 🛠️ Management Commands

```bash
cd ~/docker/wordpress
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Check container status |
| `docker compose logs -f wordpress` | Follow the app's logs |
| `docker compose stop` / `start` | Stop/start without removing containers |
| `docker compose pull && docker compose up -d` | Update to the latest image |

WordPress also has its own **in-app one-click updater** (Dashboard → Updates) for WordPress core, themes, and plugins — separate from the Docker image itself, and the more common way to stay current day-to-day.

---

## 📌 Known Simplifications vs. Upstream

- Upstream's own example publishes a host port unconditionally (`8080:80`); here that's optional (default: no), matching this repo's "NPM-only unless you opt in" convention.
- `db` gets an added `mysqladmin ping` healthcheck, and `wordpress-app` waits on it via `condition: service_healthy` instead of upstream's bare `depends_on`.
- `db` stays off `main-net` entirely; only `wordpress-app` joins it — upstream's own compose doesn't define any custom networks at all (everything shares Compose's single default network, with nothing external to join).

---

## 💾 Backup and restore

Run from the menu: `bash services/services.sh` → this service → **4) Backup** / **5) Restore**.

This service ships a `backup.sh` because its state is split in two: **MySQL** holds the data, and the install tree holds the rest. The generic archive captures the second and would take a raw, mid-write copy of the first.

**Why the restore looks simpler here than in the Postgres services, and correctly so.** `mysqldump` enables `--opt` by default, which includes `--add-drop-table`, so the dump already drops each table before recreating it — replaying onto restored data is idempotent without a drop-and-recreate step. And `mysql` stops at the first error and returns non-zero by default, so its exit status can be trusted, unlike `psql`. **Do not "fix" this to match the Postgres services**: this deployment has no root credentials at all (`MYSQL_RANDOM_ROOT_PASSWORD`), so dropping the database with the application user and then failing to recreate it would destroy the data with no way back.

> ⚠️ **Restore replaces the current data.** It is not a merge. Take a fresh backup first if the running deployment holds anything you have not archived.

---

## 📜 License

WordPress itself is licensed separately (GPLv2+ — see the [official repository](https://github.com/WordPress/WordPress) for terms). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of this repo.

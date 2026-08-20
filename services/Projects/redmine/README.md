# 📌 Redmine

Deploys [Redmine](https://www.redmine.org/) (project management / issue tracking) behind the shared `main-net` network so [NGINX Proxy Manager](../../README.md) can front it.

Adapted from the official [redmine](https://hub.docker.com/_/redmine) Docker Hub image. See the top of [`docker-compose.yml`](docker-compose.yml) for the exact, deliberate deviations from upstream's own example (which uses MySQL — this uses Postgres, matching every other service here).

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows, it installs the full bundle automatically (skipping anything already installed).

### 2. Deploy Redmine

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Projects/redmine/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Projects/redmine/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

`POSTGRES_PASSWORD` and `SECRET_KEY_BASE` are generated automatically and saved to `.env` (`600`) and a one-time readable copy at `~/docker/redmine/.redmine-docker-secrets.txt` (`600`).

This is a **single-instance** service: one Redmine deployment per host, under `~/docker/redmine/`.

You'll also be asked whether to cap memory on the `redmine` container (default suggestion: `512m`). Say no and it runs uncapped — `db` is never capped, same "main container only" convention used by every other service here.

> 💡 **To change the memory limit later**: edit `MEM_LIMIT=` in `~/docker/redmine/.env` (change the value, or delete the line entirely to remove the cap), then rerun `deploy.sh` — it regenerates `docker-compose.override.yml` from whatever `.env` currently has and reapplies it with `docker compose up -d`.

You'll also be asked whether to publish a host port for direct access without NPM (e.g. `http://<server-ip>:3000`) — useful for a quick first check that the container actually works before wiring up NPM. Default is no.

**Unlike this repo's other services** (OpenProject, Nextcloud, n8n, Taiga), choosing a host port here needs **no extra configuration** — Redmine has no Host-header validation and doesn't force HTTPS by default (verified directly against Redmine's own `production.rb`: no `config.hosts`, `config.force_ssl` commented out), so a direct `http://ip:port` visit just works either way.

Either way, this choice (like the memory limit and secrets) is only asked once — rerunning `deploy.sh` reuses `.env` and **never overwrites an existing `docker-compose.yml`** at `~/docker/redmine/` (so any manual edits you make there survive reruns; delete it yourself first if you want the latest version from this repo).

---

## 👤 First Login

- **Username**: `admin`
- **Password**: `admin`

Change this immediately (**My account → Change password**) — recent Redmine versions prompt for this on first login, but don't rely on it.

---

## 🌐 Setting Your Real URL

Unlike this repo's other services, Redmine has **no deploy-time domain setting** — there's nothing to configure in `.env` for it. Once you've logged in, set it from Redmine's own admin UI instead:

**Administration → Settings → General → "Host name and path"**

This is what Redmine uses to build links in notification emails, RSS feeds, etc. Set it to your real domain once NGINX Proxy Manager is wired up.

---

## 🧩 Plugins and Themes

Unlike `files` (uploaded attachments, a Docker-managed named volume), `plugins/` and `themes/` under `~/docker/redmine/` are **bind mounts** — drop a plugin's files into `plugins/<plugin-name>/`, then run its migration and restart:

```bash
cd ~/docker/redmine
docker compose exec redmine bin/rails redmine:plugins:migrate RAILS_ENV=production
docker compose restart redmine
```

Same idea for `themes/<theme-name>/` (select it afterwards in Administration → Settings → Display).

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: your real domain (set the same one in Redmine's own "Host name and path" setting — see above)
   - **Forward Hostname/IP**: `redmine-app`
   - **Forward Port**: `3000`
3. Enable **SSL** with Let's Encrypt from the UI.

✅ No host port is published for `redmine-app` by default — NPM reaches it by container name over `main-net`.

---

## 🛠️ Management Commands

```bash
cd ~/docker/redmine
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Check container status |
| `docker compose logs -f redmine` | Follow the app's logs |
| `docker compose stop` / `start` | Stop/start without removing containers |
| `docker compose pull && docker compose up -d` | Update to the latest image |

---

## 📌 Known Simplifications vs. Upstream

- Upstream's official docker-compose example uses **MySQL**; this uses **Postgres**, matching every other service in this repo (`REDMINE_DB_POSTGRES` instead of `REDMINE_DB_MYSQL` — both are officially supported by the image, just documented via a plain `docker run` example rather than a compose one upstream).
- Image pinned to `redmine:6-alpine` by default rather than `:latest` — Redmine 7 was released very recently at the time this was written; edit `REDMINE_VERSION=` in `.env` to move to `7-alpine` (or `latest`) once you're ready, then `docker compose pull && docker compose up -d`.

---

## 💾 Backup and restore

Run from the menu: `bash services/services.sh` → this service → **4) Backup** / **5) Restore**.

This service ships a `backup.sh` because its state is split in two: **Postgres** holds the data, and the install tree holds the rest. The generic archive captures the second and would take a raw, mid-write copy of the first — a `pg_dump` is a consistent snapshot; a file copy of a running database is a coin toss.

**What restore actually does, because it is not obvious.** `restore_service_generic` puts the *volumes* back first, so by the time the dump replays, the database is already a complete copy of itself. Replaying into that gives "relation already exists" on every statement — and `psql < file` **exits 0 even when every statement failed**, so it would report success. So the restore instead: stops the app, `dropdb --force`, `createdb`, then replays with `ON_ERROR_STOP=1 --single-transaction`. If the drop or create fails, the replay is **skipped** rather than half-applied, and the restored volume is left coherent.

> ⚠️ **Restore replaces the current data.** It is not a merge. Take a fresh backup first if the running deployment holds anything you have not archived.

---

## 📜 License

Redmine itself is licensed separately (GPLv2 — see the [official repository](https://github.com/redmine/redmine) for terms). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of this repo.

# 📐 Plane

Deploys [Plane](https://plane.so/) (project management — issues, cycles, modules, pages) behind the shared `main-net` network so [NGINX Proxy Manager](../../../README.md) can front it.

Adapted from the official release-attached [`docker-compose.yml`](https://github.com/makeplane/plane/releases/download/v1.4.0/docker-compose.yml) — the actual self-host distribution artifact (the root of Plane's GitHub repo builds from source and is for local development, not this). See the top of [`docker-compose.yml`](docker-compose.yml) for the exact, deliberate deviations from upstream.

Plane is the most complex service in this repo so far: **13 containers** — `web`, `space`, `admin`, `live` (realtime collaboration), `api`, `worker`, `beat-worker`, `migrator` (all built from `makeplane/plane-backend`), Postgres, Redis (Valkey), RabbitMQ, MinIO (S3-compatible object storage for uploads), and a Caddy-based `proxy` that's the single entrypoint.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows, it installs the full bundle automatically (skipping anything already installed).

### 2. Deploy Plane

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Projects/plane/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Projects/plane/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

This is a **single-instance** service: one Plane deployment per host, under `~/docker/plane/`.

> ⚠️ **Resources**: Plane's own docs recommend at least 4 GB RAM (8 GB comfortable) — it's noticeably heavier than this repo's other project-management services (OpenProject, Redmine, Taiga, Vikunja). First boot also pulls 8 separate images and runs database migrations, so it can take several minutes before the site responds.

`deploy.sh` generates and saves (to `.env`, `600`, and a one-time readable copy at `~/docker/plane/.plane-docker-secrets.txt`, `600`) six secrets:

| Secret | Used for |
|---|---|
| `POSTGRES_PASSWORD` | Postgres |
| `RABBITMQ_PASSWORD` | RabbitMQ |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | MinIO (S3-compatible upload storage) credentials |
| `SECRET_KEY` | Django session/token signing |
| `LIVE_SERVER_SECRET_KEY` | The realtime `live` (collaborative editing) service |

You'll also be asked whether to cap memory on the `plane-app` (proxy) container (default suggestion: `256m`). Say no and it runs uncapped — the other 12 containers are never capped, same "main container only" convention used by every other service here, stretched further given how many containers Plane has.

> 💡 **To change the memory limit later**: edit `MEM_LIMIT=` in `~/docker/plane/.env`, then rerun `deploy.sh` — it regenerates `docker-compose.override.yml` from whatever `.env` currently has and reapplies it with `docker compose up -d`.

You'll also be asked whether to publish a host port for direct access without NPM (e.g. `http://<server-ip>:8090`) — useful for a quick first check before wiring up NPM. Default is no.

- **If you said no** to a host port, you're then prompted for the public domain you plan to point NPM at (e.g. `plane.example.com`) — this sets `APP_DOMAIN=plane.example.com` and `WEB_URL`/`CORS_ALLOWED_ORIGINS=https://plane.example.com`.
- **If you said yes** to a host port, the domain question is skipped — `APP_DOMAIN`/`WEB_URL`/`CORS_ALLOWED_ORIGINS` are set to `<server-ip>:<port>` / `http://<server-ip>:<port>` automatically. Plane's CORS check rejects requests whose Origin doesn't match `CORS_ALLOWED_ORIGINS` exactly, so a placeholder domain wouldn't work with a bare `IP:port` visit — verified directly against the release-attached `variables.env`, where `CORS_ALLOWED_ORIGINS` is derived from `APP_DOMAIN`.

Either way, this choice (like memory and secrets) is only asked once — rerunning `deploy.sh` reuses `.env` and **never overwrites an existing `docker-compose.yml`** at `~/docker/plane/` (so any manual edits you make there survive reruns; delete it yourself first if you want the latest version from this repo).

Once you switch to NPM+SSL, edit `APP_DOMAIN`, `WEB_URL`, and `CORS_ALLOWED_ORIGINS` in `.env` to your real `https://` domain (and remove `HOST_PORT=` if you no longer want the direct port), then rerun `deploy.sh`.

---

## 👤 First Login

Like Vikunja, Plane ships with **no default account**. Visit the app and **register your own account** — the first person to register becomes the workspace owner.

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: the same domain you entered during `deploy.sh` (must match `APP_DOMAIN` in `.env`)
   - **Forward Hostname/IP**: `plane-app`
   - **Forward Port**: `80`
3. On the **Details** tab, enable **Websockets Support** — required by the `live` realtime-collaboration service.
4. Enable **SSL** with Let's Encrypt from the UI.

✅ No host port is published for `plane-app` by default — NPM reaches it by container name over `main-net`. Every other container (`plane-db`, `plane-redis`, `plane-mq`, `plane-minio`, and all backend/frontend containers) stays on the private `plane-net` only.

---

## 🛠️ Management Commands

```bash
cd ~/docker/plane
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Check status of all 13 containers |
| `docker compose logs -f api` | Follow the API's logs (most app errors surface here) |
| `docker compose logs -f migrator` | Check migration status on first boot |
| `docker compose stop` / `start` | Stop/start without removing containers |
| `docker compose pull && docker compose up -d` | Update to the latest images |

---

## 📌 Known Simplifications vs. Upstream

- Upstream's own release compose file publishes `80:80`/`443:443` unconditionally and runs Caddy's own ACME/Let's Encrypt automation; here the host port is optional (default: no) and NPM handles TLS instead, matching this repo's "NPM-only unless you opt in" convention — same reasoning as every other service.
- Every service's swarm-only `deploy: {replicas, restart_policy}` block is dropped in favor of plain `restart: unless-stopped` — `deploy:` doesn't apply outside Swarm mode under plain `docker compose up`. Same fix already made for this repo's Odoo service.
- `plane-db` gets an added `pg_isready` healthcheck, and `api`/`worker`/`beat-worker`/`migrator` wait on it via `condition: service_healthy` — upstream relied on the (now-dropped) swarm restart policy to paper over startup-ordering races.
- MinIO's bucket (`uploads`) is not auto-created by a one-shot `mc` container the way some MinIO deployments do — Plane's own `api` container creates it on first boot if missing (verified against upstream's own entrypoint behavior).

---

## 💾 Backup and restore

Run from the menu: `bash services/services.sh` → this service → **4) Backup** / **5) Restore**.

This service ships a `backup.sh` because its state is split in two: **Postgres** holds the data, and the install tree holds the rest. The generic archive captures the second and would take a raw, mid-write copy of the first — a `pg_dump` is a consistent snapshot; a file copy of a running database is a coin toss.

**What restore actually does, because it is not obvious.** `restore_service_generic` puts the *volumes* back first, so by the time the dump replays, the database is already a complete copy of itself. Replaying into that gives "relation already exists" on every statement — and `psql < file` **exits 0 even when every statement failed**, so it would report success. So the restore instead: stops the app, `dropdb --force`, `createdb`, then replays with `ON_ERROR_STOP=1 --single-transaction`. If the drop or create fails, the replay is **skipped** rather than half-applied, and the restored volume is left coherent.

> ⚠️ **Restore replaces the current data.** It is not a merge. Take a fresh backup first if the running deployment holds anything you have not archived.

---

## 📜 License

Plane itself is licensed separately (AGPLv3 — see the [official repository](https://github.com/makeplane/plane) for terms). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of this repo.

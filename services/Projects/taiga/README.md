# 📌 Taiga

Deploys [Taiga](https://www.taiga.io/) (agile/kanban project management) behind the shared `main-net` network so [NGINX Proxy Manager](../../README.md) can front it.

Adapted from the official [taigaio/taiga-docker](https://github.com/taigaio/taiga-docker) repo. See the top of [`docker-compose.yml`](docker-compose.yml) for the exact, deliberate deviations from upstream.

> ⚠️ **Resource requirements**: Taiga needs roughly **4 GB RAM** for a small team — Postgres, two RabbitMQ brokers, and the backend/async workers add up. Significantly heavier than Nextcloud or n8n. ([source](https://community.taiga.io/t/setting-up-taiga-self-hosted-from-scratch/893))

This is a 9-container stack: `taiga-db` (Postgres), `taiga-back` + `taiga-async` (Django, same image, different entrypoints), two `rabbitmq` brokers (one for realtime events, one for async jobs), `taiga-front`, `taiga-events` (websocket), `taiga-protected` (signed attachment downloads), and `taiga-gateway` (nginx — routes one port to all of the above). Unlike OpenProject's dropped Caddy proxy, `taiga-gateway` is **kept** — it isn't a redundant external proxy, it's the internal glue that makes the other containers work as one app. NPM only ever needs to know about `taiga-gateway`.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows, it installs the full bundle automatically (skipping anything already installed).

### 2. Deploy Taiga

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Projects/taiga/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Projects/taiga/docker-compose.yml
curl -fsSL -o docker-compose-inits.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Projects/taiga/docker-compose-inits.yml
mkdir -p taiga-gateway i18n-overrides
curl -fsSL -o taiga-gateway/taiga.conf \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Projects/taiga/taiga-gateway/taiga.conf
curl -fsSL -o i18n-overrides/django-ar.po \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Projects/taiga/i18n-overrides/django-ar.po
curl -fsSL -o i18n-overrides/locale-ar.json \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Projects/taiga/i18n-overrides/locale-ar.json
curl -fsSL -o i18n-overrides/apply-front-locale.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Projects/taiga/i18n-overrides/apply-front-locale.sh
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

`SECRET_KEY`, `POSTGRES_PASSWORD`, `RABBITMQ_PASS`, and `RABBITMQ_ERLANG_COOKIE` are generated automatically and saved to `.env` (`600`) and a one-time readable copy at `~/docker/taiga/.taiga-docker-secrets.txt` (`600`). Outbound email defaults to `EMAIL_BACKEND=console` (logged, not actually sent) — edit `.env` yourself if you want real SMTP.

This is a **single-instance** service: one Taiga deployment per host, under `~/docker/taiga/`. First startup can take a few minutes — 9 images to pull, plus Postgres/RabbitMQ initialization.

You'll also be asked whether to cap memory on the `taiga-gateway` container (default suggestion: `512m`). Say no and it runs uncapped. **Note**: `taiga-gateway` is just nginx (lightweight) — the actual heavy memory users (`taiga-back`, `taiga-async`, both RabbitMQ brokers, Postgres) are **not** covered by this cap, same "main container only" convention used by every other service here.

> 💡 **To change the memory limit later**: edit `MEM_LIMIT=` in `~/docker/taiga/.env` (change the value, or delete the line entirely to remove the cap), then rerun `deploy.sh` — it regenerates `docker-compose.override.yml` from whatever `.env` currently has and reapplies it with `docker compose up -d`.

You'll also be asked whether to publish a host port for direct access without NPM (e.g. `http://<server-ip>:9000`) — useful for a quick first check that the container actually works before wiring up NPM. Default is no.

- **If you said no** to a host port, you're then prompted for the public domain you plan to point NPM at (e.g. `taiga.example.com`) — this becomes `TAIGA_DOMAIN`, with `TAIGA_SCHEME=https` and `WEBSOCKETS_SCHEME=wss`.
- **If you said yes** to a host port, the domain question is skipped — `TAIGA_DOMAIN` is set to `<server-ip>:<port>` automatically, with `TAIGA_SCHEME=http` and `WEBSOCKETS_SCHEME=ws`. Taiga's backend validates the domain it's accessed through, so a placeholder domain wouldn't match `<server-ip>:<port>`, and `https://` URLs would be unreachable without NPM/TLS anyway.

Either way, this choice (like memory and secrets) is only asked once — rerunning `deploy.sh` reuses `.env` and **never overwrites an existing `docker-compose.yml`** at `~/docker/taiga/` (so any manual edits you make there survive reruns; delete it yourself first if you want the latest version from this repo).

Once you switch to NPM+SSL, edit `TAIGA_DOMAIN` to your real domain, `TAIGA_SCHEME=https`, and `WEBSOCKETS_SCHEME=wss` (and remove `HOST_PORT=` if you no longer want the direct port) in `.env` and rerun `deploy.sh`.

---

## 🌍 Community Arabic Translation Overlay

On first deploy you'll also be asked whether to apply a **community-completed Arabic translation** for both `taiga-back` and `taiga-front` — upstream Taiga's own official Arabic translation is largely incomplete (most UI strings silently fall back to English). Say yes and `deploy.sh` layers the completed translation on top of the stock images via volume mounts — no image rebuild, no fork.

See [`i18n-overrides/README.md`](i18n-overrides/README.md) for exactly what gets mounted where, how to refresh it once upstream's own translation catches up, and how to turn it off later (`AR_I18N_OVERLAY=false` in `.env`, then rerun `deploy.sh`).

---

## 👤 First Login

Unlike this repo's other services, Taiga doesn't ship a seeded admin account — `deploy.sh` creates one for you automatically, right after the containers come up (it needs `taiga-back`'s database migrations to finish first, so it retries for up to a minute). This check/create step runs on **every** `deploy.sh` run, not just the first — so even a deployment made before this step existed will get its admin account created the next time you rerun `deploy.sh`.

- **Username**: `admin`
- **Password**: a random secret, generated on the run that actually creates the account and printed in that run's output, saved to `~/docker/taiga/.taiga-docker-secrets.txt` (`600`) alongside the other secrets.

If you ever see `admin account setup failed` in the `deploy.sh` output (e.g. migrations took longer than the retry window), run it yourself:

```bash
cd ~/docker/taiga
docker compose -f docker-compose.yml -f docker-compose-inits.yml run --rm taiga-manage createsuperuser
```

Change the password immediately after logging in — Taiga doesn't force a change on first login the way OpenProject does.

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: the same domain you entered during `deploy.sh` (must match `TAIGA_DOMAIN` in `.env`)
   - **Forward Hostname/IP**: `taiga-app`
   - **Forward Port**: `80`
   - Enable **Websockets Support** (needed for the `/events` real-time path — task updates, notifications)
3. Enable **SSL** with Let's Encrypt from the UI.

✅ No host port is published for `taiga-gateway` — NPM reaches it by container name (`taiga-app`) over `main-net`. `taiga-gateway` itself already does all the internal routing (frontend, `/api/`, `/admin/`, `/media/`, `/events`) to the other 7 containers — you only need the one NPM proxy host.

---

## 🛠️ Management Commands

```bash
cd ~/docker/taiga
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Check container status (9 containers) |
| `docker compose logs -f taiga-back` | Follow the main backend's logs |
| `docker compose logs -f taiga-gateway` | Check nginx routing issues |
| `docker compose stop` / `start` | Stop/start without removing containers |
| `docker compose pull && docker compose up -d` | Update to the latest images |

---

## 📌 Known Simplifications vs. Upstream

- Service **keys** (`taiga-db`, `taiga-back`, `taiga-async`, `taiga-async-rabbitmq`, `taiga-front`, `taiga-events`, `taiga-events-rabbitmq`, `taiga-protected`, `taiga-gateway`) are **unchanged from upstream on purpose** — `taiga-gateway/taiga.conf` and the backend images' own defaults hardcode several of these as internal DNS hostnames (no `RABBITMQ_HOST` override exists upstream either). Renaming any of them would silently break internal routing.
- Outbound email defaults to `EMAIL_BACKEND=console` (upstream's own default) — no interactive SMTP setup, matching this repo's other services (none of them prompt for SMTP either). Edit `.env` directly if you need real email delivery.
- The optional memory cap only targets `taiga-gateway` (nginx) for consistency with every other service here — it's the least memory-hungry container in the stack, so treat it as a placeholder cap rather than real resource control until you decide to extend `docker-compose.override.yml` yourself.

---

## 💾 Backup and restore

Run from the menu: `bash services/services.sh` → this service → **4) Backup** / **5) Restore**.

This service ships a `backup.sh` because its state is split in two: **Postgres** holds the data, and the install tree holds the rest. The generic archive captures the second and would take a raw, mid-write copy of the first — a `pg_dump` is a consistent snapshot; a file copy of a running database is a coin toss.

**What restore actually does, because it is not obvious.** `restore_service_generic` puts the *volumes* back first, so by the time the dump replays, the database is already a complete copy of itself. Replaying into that gives "relation already exists" on every statement — and `psql < file` **exits 0 even when every statement failed**, so it would report success. So the restore instead: stops the app, `dropdb --force`, `createdb`, then replays with `ON_ERROR_STOP=1 --single-transaction`. If the drop or create fails, the replay is **skipped** rather than half-applied, and the restored volume is left coherent.

> ⚠️ **Restore replaces the current data.** It is not a merge. Take a fresh backup first if the running deployment holds anything you have not archived.

---

## 📜 License

Taiga itself is licensed separately (AGPLv3 backend, other components under their own licenses — see the [official repository](https://github.com/taigaio/taiga-back) for terms). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of this repo.

# 📌 Vikunja

Deploys [Vikunja](https://vikunja.io/) (to-do / project management) behind the shared `main-net` network so [NGINX Proxy Manager](../../../README.md) can front it.

Adapted from the official [full Docker example](https://vikunja.io/docs/full-docker-example/). See the top of [`docker-compose.yml`](docker-compose.yml) for the exact, deliberate deviations from upstream.

Vikunja ships as a single combined image (API + frontend served from one container) — simpler than most of this repo's other multi-container project-management services.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows, it installs the full bundle automatically (skipping anything already installed).

### 2. Deploy Vikunja

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Projects/vikunja/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Projects/vikunja/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

`POSTGRES_PASSWORD` and `SECRET_KEY` (used to sign session tokens) are generated automatically and saved to `.env` (`600`) and a one-time readable copy at `~/docker/vikunja/.vikunja-docker-secrets.txt` (`600`).

This is a **single-instance** service: one Vikunja deployment per host, under `~/docker/vikunja/`.

You'll also be asked whether to cap memory on the `vikunja` container (default suggestion: `512m`). Say no and it runs uncapped — `db` is never capped, same "main container only" convention used by every other service here.

> 💡 **To change the memory limit later**: edit `MEM_LIMIT=` in `~/docker/vikunja/.env` (change the value, or delete the line entirely to remove the cap), then rerun `deploy.sh` — it regenerates `docker-compose.override.yml` from whatever `.env` currently has and reapplies it with `docker compose up -d`.

You'll also be asked whether to publish a host port for direct access without NPM (e.g. `http://<server-ip>:3456`) — useful for a quick first check that the container actually works before wiring up NPM. Default is no.

- **If you said no** to a host port, you're then prompted for the public domain you plan to point NPM at (e.g. `vikunja.example.com`) — this becomes `PUBLIC_URL=https://vikunja.example.com/`.
- **If you said yes** to a host port, the domain question is skipped — `PUBLIC_URL` is set to `http://<server-ip>:<port>/` automatically. Vikunja's CORS check rejects requests whose Origin doesn't match `VIKUNJA_SERVICE_PUBLICURL` exactly (scheme, host, and trailing slash all matter), so a placeholder domain wouldn't work with a bare `IP:port` visit — verified directly against [Vikunja's own installation docs](https://vikunja.io/docs/installing/): *"The default configuration has CORS enabled, which requires a public URL to be set."*

Either way, this choice (like memory and secrets) is only asked once — rerunning `deploy.sh` reuses `.env` and **never overwrites an existing `docker-compose.yml`** at `~/docker/vikunja/` (so any manual edits you make there survive reruns; delete it yourself first if you want the latest version from this repo).

Once you switch to NPM+SSL, edit `PUBLIC_URL=https://your-real-domain.com/` (and remove `HOST_PORT=` if you no longer want the direct port) in `.env` and rerun `deploy.sh`.

---

## 👤 First Login

Unlike most of this repo's other services, Vikunja ships with **no default account at all** — not even a seeded admin. Just visit the app and **register your own account** directly; whoever registers first becomes the first user (there's no separate "admin" role distinction at signup).

### Disabling Registration

Once you (and anyone else you want) have an account, Vikunja's own docs recommend disabling public sign-ups for security. Add to `~/docker/vikunja/.env`:

```
VIKUNJA_SERVICE_ENABLEREGISTRATION=false
```

then `cd ~/docker/vikunja && docker compose up -d`.

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: the same domain you entered during `deploy.sh` (must match `PUBLIC_URL` in `.env`)
   - **Forward Hostname/IP**: `vikunja-app`
   - **Forward Port**: `3456`
3. Enable **SSL** with Let's Encrypt from the UI.

✅ No host port is published for `vikunja-app` by default — NPM reaches it by container name over `main-net`.

---

## 🛠️ Management Commands

```bash
cd ~/docker/vikunja
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Check container status |
| `docker compose logs -f vikunja` | Follow the app's logs |
| `docker compose stop` / `start` | Stop/start without removing containers |
| `docker compose pull && docker compose up -d` | Update to the latest image |

---

## 📌 Known Simplifications vs. Upstream

- Upstream's own example publishes `3456:3456` on the host unconditionally; here that's optional (default: no), matching this repo's "NPM-only unless you opt in" convention.
- `POSTGRES_DB` is set explicitly (`vikunja`) — upstream's own example leaves it unset and relies on the `postgres` image defaulting it to `POSTGRES_USER`'s value.
- The `db` volume mounts at `/var/lib/postgresql` (not `.../postgresql/data`) — this matches upstream's own example exactly, not a typo.
- Vikunja runs as uid `1000` with no group; `deploy.sh` `chown`s the `files/` bind mount (uploaded attachments) accordingly, same pattern as this repo's Odoo service uses for its `config`/`addons` folders.

---

## 💾 Backup and restore

Run from the menu: `bash services/services.sh` → this service → **4) Backup** / **5) Restore**.

This service ships a `backup.sh` because its state is split in two: **Postgres** holds the data, and the install tree holds the rest. The generic archive captures the second and would take a raw, mid-write copy of the first — a `pg_dump` is a consistent snapshot; a file copy of a running database is a coin toss.

**What restore actually does, because it is not obvious.** `restore_service_generic` puts the *volumes* back first, so by the time the dump replays, the database is already a complete copy of itself. Replaying into that gives "relation already exists" on every statement — and `psql < file` **exits 0 even when every statement failed**, so it would report success. So the restore instead: stops the app, `dropdb --force`, `createdb`, then replays with `ON_ERROR_STOP=1 --single-transaction`. If the drop or create fails, the replay is **skipped** rather than half-applied, and the restored volume is left coherent.

> ⚠️ **Restore replaces the current data.** It is not a merge. Take a fresh backup first if the running deployment holds anything you have not archived.

---

## 📜 License

Vikunja itself is licensed separately (AGPLv3 — see the [official repository](https://github.com/go-vikunja/vikunja) for terms). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of this repo.

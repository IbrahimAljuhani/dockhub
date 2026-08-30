# 🔧 n8n

Deploys [n8n](https://n8n.io/) (workflow automation) behind the shared `main-net` network so [NGINX Proxy Manager](../../README.md) can front it.

Adapted from the official [n8n-io/n8n-hosting](https://github.com/n8n-io/n8n-hosting/tree/main/docker-compose/withPostgres) reference compose (Postgres + n8n + external task runner). See the top of [`docker-compose.yml`](docker-compose.yml) for the exact, deliberate deviations from upstream.

> 📝 **Resources**: official docs give **320 MB – 2 GB RAM** and 512 MB – 4 GB disk for the database, scaling with workflow complexity (large files / Code nodes use more). ([source](https://docs.n8n.io/deploy/host-n8n/deploy-as-an-oem-integration/prerequisites))

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows, it installs the full bundle automatically (skipping anything already installed).

### 2. Deploy n8n

```bash
mkdir n8n-deploy && cd n8n-deploy
curl -fsSL -o deploy.sh https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Automation/n8n/deploy.sh
curl -fsSL -o docker-compose.yml https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Automation/n8n/docker-compose.yml
curl -fsSL -o init-data.sh https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Automation/n8n/init-data.sh
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

The Postgres root password, the app-user password, and the runner auth token are all generated automatically and saved to `.env` (`600`) and a one-time readable copy at `~/docker/n8n/.n8n-docker-secrets.txt` (`600`).

n8n has **no default admin account** — the first person to open the URL creates the owner account through n8n's own setup screen.

You'll also be asked whether to cap memory on the `app` container (default suggestion: `512m`; `db`/`runner` stay unbounded either way — note the `runner` is what actually executes workflow code, so heavy Code-node usage isn't covered by this cap). Say no and it runs uncapped.

> 💡 **To change the memory limit later**: edit `MEM_LIMIT=` in `~/docker/n8n/.env` (change the value, or delete the line entirely to remove the cap), then rerun `deploy.sh` — it regenerates `docker-compose.override.yml` from whatever `.env` currently has and reapplies it with `docker compose up -d`.

You'll also be asked whether to publish a host port for direct access without NPM (e.g. `http://<server-ip>:5678`) — useful for a quick first check that the container actually works before wiring up NPM. Default is no. Say yes and the port is checked for conflicts, then printed as a URL once n8n starts.

- **If you said no** to a host port, you're then prompted for the public domain you plan to point NPM at (e.g. `n8n.example.com`) — this becomes `N8N_HOST`, with `N8N_PROTOCOL=https` and `N8N_SECURE_COOKIE=true`.
- **If you said yes** to a host port, the domain question is skipped — `N8N_HOST` is set to `<server-ip>:<port>` automatically, with `N8N_PROTOCOL=http` and `N8N_SECURE_COOKIE=false`. Without this, **n8n's login fails outright** over a bare `http://` direct port, since browsers refuse to send a secure-flagged cookie back over plain HTTP.

Either way, this choice (like memory and secrets) is only asked once — rerunning `deploy.sh` reuses `.env` and **never overwrites an existing `docker-compose.yml`** at `~/docker/n8n/` (so any manual edits you make there survive reruns; delete it yourself first if you want the latest version from this repo).

Once you switch to NPM+SSL, edit `N8N_HOST` to your real domain, `N8N_PROTOCOL=https`, `N8N_SECURE_COOKIE=true`, and `N8N_WEBHOOK_URL=https://<domain>/` (and remove `HOST_PORT=` if you no longer want the direct port) in `.env` and rerun `deploy.sh`.

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

> ☁️ **Using Cloudflare Tunnel?** Two steps below are different: where you open NPM, and the SSL certificate (`None`, not Let's Encrypt). See [docs/cloudflare-tunnel.md](../../../docs/cloudflare-tunnel.md#deploying-a-service-behind-the-tunnel).

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: the same domain you entered during `deploy.sh` (must match `N8N_HOST` in `.env`)
   - **Forward Hostname/IP**: `n8n-app`
   - **Forward Port**: `5678`
   - Enable **Websockets Support** (the workflow editor uses it for live updates)
3. Enable **SSL** with Let's Encrypt from the UI.

✅ No host port is published for `app` — NPM reaches it by container name over `main-net`. `docker-compose.yml` already sets `N8N_PROXY_HOPS=1` and `N8N_WEBHOOK_URL`/`N8N_HOST`/`N8N_PROTOCOL` so webhooks register with your real `https://` domain instead of an internal address.

---

## 🛠️ Management Commands

```bash
cd ~/docker/n8n
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Check container status (db, app, runner) |
| `docker compose logs -f app` | Follow the main app's logs |
| `docker compose logs -f runner` | Check the task-runner (executes workflow code) |
| `docker compose stop` / `start` | Stop/start without removing containers |
| `docker compose pull && docker compose up -d` | Update to the latest `stable` tag |

---

## 📌 Known Simplifications vs. Upstream

- Upstream's example publishes `5678:5678` directly on the host and has no reverse-proxy env vars set (meant for local/direct access). This version drops the host port and adds `N8N_HOST`/`N8N_PROTOCOL`/`N8N_PROXY_HOPS`/`N8N_WEBHOOK_URL` for correct operation behind NPM, per the [official reverse-proxy guide](https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/configuration-examples/configure-webhook-urls-with-reverse-proxy.md).
- Uses n8n's current **external task-runner** architecture (a separate `runner` container executes workflow code, communicating with `app` over the private `n8n-net` only) — this is upstream's own current default, not a deviation.

---

## 💾 Backup and restore

Run from the menu: `bash services/services.sh` → this service → **4) Backup** / **5) Restore**.

This service ships a `backup.sh` because its state is split in two: **Postgres** holds the data, and the install tree holds the rest. The generic archive captures the second and would take a raw, mid-write copy of the first — a `pg_dump` is a consistent snapshot; a file copy of a running database is a coin toss.

**What restore actually does, because it is not obvious.** `restore_service_generic` puts the *volumes* back first, so by the time the dump replays, the database is already a complete copy of itself. Replaying into that gives "relation already exists" on every statement — and `psql < file` **exits 0 even when every statement failed**, so it would report success. So the restore instead: stops the app, `dropdb --force`, `createdb`, then replays with `ON_ERROR_STOP=1 --single-transaction`. If the drop or create fails, the replay is **skipped** rather than half-applied, and the restored volume is left coherent.

> ⚠️ **Restore replaces the current data.** It is not a merge. Take a fresh backup first if the running deployment holds anything you have not archived.

---

## 📜 License

n8n itself is licensed separately (Sustainable Use License / n8n Enterprise) — see the [official repository](https://github.com/n8n-io/n8n) for terms. This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of this repo.

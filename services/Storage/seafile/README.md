# 📁 Seafile

Deploys [Seafile](https://www.seafile.com/) Community Edition (file sync and share, built around encrypted *libraries* with block-level deduplication — its sync client is the fastest of the three storage options here) behind the shared `main-net` network so [NGINX Proxy Manager](../../../README.md) can front it.

Verified against Seafile's own 13.0 Docker templates ([`.env`](https://manual.seafile.com/13.0/repo/docker/ce/env), [`seafile-server.yml`](https://manual.seafile.com/13.0/repo/docker/ce/seafile-server.yml)). See the top of [`docker-compose.yml`](docker-compose.yml) for the exact, deliberate deviations.

Three containers: `seafile-app`, `seafile-db` (MariaDB) and `seafile-redis`.

---

## ⚠️ Most Seafile guides you'll find are out of date

Seafile 12 and 13 changed deployment substantially, and a large share of the tutorials and forum answers online predate that. If something you read elsewhere contradicts this page, check which version it was written for.

What changed:

| | Old (≤ 11) | Now (12–13) |
|---|---|---|
| Configuration | `environment:` blocks, hand-edited `ccnet.conf` / `seahub_settings.py` | a `.env` file |
| Admin variables | `SEAFILE_ADMIN_EMAIL` | **`INIT_`**`SEAFILE_ADMIN_EMAIL` (first start only) |
| Cache | memcached | **Redis** (default since 13) |
| Stack layout | one compose file | several, selected by `COMPOSE_FILE` |
| Reverse proxy | your own | a bundled **Caddy** on ports 80/443 |

That last one matters here: upstream's default stack claims host ports 80 and 443, which NGINX Proxy Manager already owns. This deployment drops Caddy — see below.

---

## 📗 Which storage service should I pick?

The catalogue now has three, and they're genuinely different:

| | Containers | Best for |
|---|---|---|
| **Seafile** | 3 | Fast, reliable sync of large numbers of files. Library-based, with client-side encryption available per library. Fewer collaboration features. |
| [**Nextcloud**](../nextcloud/) | 3 | The everything-suite — files plus calendar, contacts, office, and a large app store. |
| [**ownCloud** (Infinite Scale)](../owncloud/) | 1 | Lightest by far, modern architecture, no database at all. Newest, smallest feature set. |

Pick Seafile if sync performance is what you care about most.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows.

### 2. Deploy Seafile

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Storage/seafile/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Storage/seafile/docker-compose.yml
curl -fsSL -o backup.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Storage/seafile/backup.sh
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

This is a **single-instance** service, under `~/docker/seafile/`.

| Question | Notes |
|---|---|
| Memory limit | Optional, suggested `2g`, applied to `seafile-app` only. |
| Host port | Optional, default `8087` → the container's `80`. |
| **Domain** | Asked only if you said **no** to a host port. |
| **Admin email** | Required — Seafile uses it as the login identity, so it's re-asked until it looks like an address. |

All passwords, plus `JWT_PRIVATE_KEY`, are generated into `.env` (`600`) and a readable copy at `~/docker/seafile/.seafile-docker-secrets.txt` (`600`).

> ⏳ **First start takes a few minutes.** Seafile creates three databases (`ccnet_db`, `seafile_db`, `seahub_db`) and runs migrations before serving anything. **A 502 in the first couple of minutes is normal** — watch it finish with `docker compose logs -f seafile-app` rather than assuming it failed.

---

## 👤 First Login

The email you gave `deploy.sh`, with the generated password:

```bash
cat ~/docker/seafile/.seafile-docker-secrets.txt
```

> 📌 The `INIT_` prefix on those variables means **first startup only**. Editing `INIT_SEAFILE_ADMIN_PASSWORD` in `.env` later does nothing — change the password from inside Seafile's own profile page.

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: the domain you gave `deploy.sh` — must match `SEAFILE_SERVER_HOSTNAME`
   - **Forward Hostname/IP**: `seafile-app`
   - **Forward Port**: `80`
   - Enable **Websockets Support**
3. In NPM's **Custom Nginx Configuration** box (the **⚙️ gear icon** in the *Edit Proxy Host* dialog — not "Custom Locations"), paste the upload block.

   `deploy.sh` already wrote it to a file for you:

   ```bash
   cat ~/docker/seafile/npm-custom-nginx.conf
   ```

   <details>
   <summary>The block itself, if you'd rather copy it from here</summary>

   ```nginx
   client_max_body_size 0;
   proxy_request_buffering off;
   proxy_read_timeout 1200s;
   proxy_send_timeout 1200s;
   send_timeout 1200s;
   ```

   </details>

   This one earns its place more than on most services: Seafile *is* a file-sync product, so the proxy's request limit is what actually caps your uploads. `0` removes the limit and lets Seafile's own settings govern; the timeouts stop a long upload over a slow link from being cut mid-transfer and restarting from zero. Without them the desktop client just reports a sync failure with no useful detail.
4. Enable **SSL** with Let's Encrypt from the UI.

Scheme stays `http` — the container serves plain HTTP and NPM terminates TLS.

### ⚠️ `SEAFILE_SERVER_HOSTNAME` and `SEAFILE_SERVER_PROTOCOL` must agree with reality

Seafile uses these two both to build absolute links **and** as its CSRF trusted origins. That second use is why a mismatch is so confusing: nothing fails at deploy time, the site loads, and then login fails with **"CSRF verification failed. Request aborted."**

Note the hostname carries **no scheme**, and **does** carry the port when it isn't standard:

| Access path | `SEAFILE_SERVER_HOSTNAME` | `SEAFILE_SERVER_PROTOCOL` |
|---|---|---|
| Behind NPM | `files.example.com` | `https` |
| Direct host port | `192.168.1.50:8087` (your server's IP) | `http` |

Moving from a host port to NPM means editing **both**, then rerunning `deploy.sh`.

---

## 📄 SeaDoc (collaborative editing) is off

Upstream defaults `ENABLE_SEADOC` to true and ships an `sdoc-server` container alongside it. This deployment sets it to **false**, because enabling the flag without deploying that container leaves Seafile advertising a document-editor endpoint that doesn't exist — which fails when a user opens a document, not when you deploy.

To turn it on you need three things: the `seafileltd/sdoc-server` container, `ENABLE_SEADOC=true`, and a `/sdoc-server` path route in NPM pointing at it. Upstream's [`seadoc.yml`](https://manual.seafile.com/13.0/setup/setup_ce_by_docker/) is the reference.

---

## 🛠️ Management Commands

```bash
cd ~/docker/seafile
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Check all three containers |
| `docker compose logs -f seafile-app` | Follow Seafile's logs |
| `docker compose logs -f seafile-db` | Database logs |
| `docker compose pull && docker compose up -d` | Update within the pinned release line |

Logs go to **stdout** here (`SEAFILE_LOG_TO_STDOUT=true`), unlike upstream's default of writing them to files inside the data volume where `docker compose logs` shows nothing.

> ⚠️ **Upgrading across major versions is not a plain `pull`.** Seafile requires stepping through major versions in order and has version-specific upgrade notes; skipping one can leave the database half-migrated. Read [Seafile's upgrade documentation](https://manual.seafile.com/latest/upgrade/upgrade_notes_for_13.0.x/) and **back up first**.

---

## 💾 Backups

This service ships a DB-aware [`backup.sh`](backup.sh) so the **Backup** option in `services.sh` dumps MariaDB properly instead of raw-copying live files. It uses `--all-databases` for two Seafile-specific reasons:

- Seafile uses **three** databases that must be restored as a consistent set.
- Its dedicated `seafile` MySQL user is created during first-run init and lives in the `mysql` system database — dumping only the three would restore the data but not the account allowed to read it.

The `seafile-data` volume (every uploaded file, stored as deduplicated blocks) and `.env` are captured in the same run.

🔐 **`JWT_PRIVATE_KEY` must travel with the backup.** It signs the tokens Seafile's internal services use to talk to each other. Restore the data with a different key and you get the confusing half-broken state where the web UI loads but file operations fail.

---

## 📌 Notes & Deviations

- **No Caddy.** Upstream's default `COMPOSE_FILE` includes `caddy.yml`, which claims host ports 80 and 443 — a direct collision with NGINX Proxy Manager. What Caddy does there is minimal (`caddy.reverse_proxy: "{{upstreams 80}}"`, i.e. proxy everything to port 80), so NPM replaces it with no path routing needed. Upstream's own compose already has the seafile `ports:` block commented out.
- **SeaDoc disabled** — see above.
- **Named volumes**, not upstream's bind mounts under `/opt`.
- **`SEAFILE_LOG_TO_STDOUT=true`** (upstream: false), so `docker compose logs` is useful.
- **A generated Redis password.** Upstream ships `REDIS_PASSWORD` empty, which starts Redis with `--requirepass ""` — no authentication at all.
- **Redis pinned to a major version**; upstream uses the bare `redis` tag, which is whatever `latest` is on the day you pull.
- **MariaDB left at upstream's `10.11`** even though this repo uses 11.8 elsewhere. Seafile is specific about its database and 10.11 is what upstream tests against — not the place to be clever.
- **Notification server not deployed** (`ENABLE_NOTIFICATION_SERVER=false`, upstream's default too). It powers real-time in-browser notifications and is a separate container plus another proxy path.

---

## 📜 License

Seafile Community Edition is licensed separately (AGPL-3.0 — see the [official repository](https://github.com/haiwen/seafile)). The Professional Edition is commercial and is not what this deploys. This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of this repo.

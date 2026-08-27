# 👻 Ghost

Deploys [Ghost](https://ghost.org/) (a publishing platform — blog, newsletter, and paid memberships in one) behind the shared `main-net` network so [NGINX Proxy Manager](../../../README.md) can front it.

Uses the [`ghost` Docker Official Image](https://hub.docker.com/_/ghost). See the top of [`docker-compose.yml`](docker-compose.yml) for the exact, deliberate deviations from the official example.

Two containers: `ghost-app` (Node.js) and `ghost-db` (MySQL).

---

## ⚠️ Read This Before Deploying

**Ghost requires MySQL. Not MariaDB.**

This is the one thing that sets Ghost apart from every other database-backed service here. Ghost 5+ supports **MySQL 8 only** in production — not MariaDB, not PostgreSQL, not SQLite. This repo's [Dolibarr](../../ERP/dolibarr/) and [ERPNext](../../ERP/erpnext/) both use MariaDB; **don't copy their `db` service into this one.**

It matters beyond "will it boot": MariaDB and MySQL have drifted far enough apart that their dumps are no longer directly interchangeable, so *"start it on MariaDB and migrate later"* is not a recovery plan.

> 📌 **On the MySQL version:** the official example pins `mysql:8.0`, which reached **end of life in April 2026**. This deployment uses **`mysql:8.4`**, the current LTS. Ghost's own docs say "MySQL 8" without pinning a minor, and Ghost's `mysql2` driver speaks `caching_sha2_password` (8.4's default) natively.
>
> The setups people report as "Ghost doesn't work with 8.4" are all passing `--default-authentication-plugin=mysql_native_password` — an option **removed** in 8.4. This compose file deliberately sets **no** MySQL command flags, and Ghost 6 connects to a stock `mysql:8.4` without them. If you ever do need to fall back, changing that one tag to `8.0` is the entire change.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows.

### 2. Deploy Ghost

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Web/ghost/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Web/ghost/docker-compose.yml
curl -fsSL -o backup.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Web/ghost/backup.sh
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

This is a **single-instance** service: one Ghost deployment per host, under `~/docker/ghost/`.

You'll be asked for:

| Question | Notes |
|---|---|
| Memory limit | Optional, suggested `1g`, applied to `ghost-app` only. |
| Host port | Optional, default `2368` (Ghost's own port). |
| **Domain** | Asked only if you said **no** to a host port — it becomes Ghost's `url`. |

---

## 👤 First Login

Ghost has **no default account**. Open `<your-url>/ghost` and the setup screen asks you to create the owner account — the first person to reach it becomes the owner.

> 🔐 Do this promptly after deploying. Until you do, anyone who reaches the admin URL can claim ownership of the site.

The secrets file holds the database passwords, not login credentials:

```bash
cat ~/docker/ghost/.ghost-docker-secrets.txt
```

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

> ☁️ **Using Cloudflare Tunnel?** Two steps below are different: where you open NPM, and the SSL certificate (`None`, not Let's Encrypt). See [docs/cloudflare-tunnel.md](../../../docs/cloudflare-tunnel.md#deploying-a-service-behind-the-tunnel).

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: the domain you gave `deploy.sh`
   - **Forward Hostname/IP**: `ghost-app`
   - **Forward Port**: `2368`
3. In NPM's **Custom Nginx Configuration** box (the **⚙️ gear icon** in the *Edit Proxy Host* dialog — not "Custom Locations"), paste the upload-size block.

   `deploy.sh` already wrote it to a file for you, so you don't have to copy it out of this page:

   ```bash
   cat ~/docker/ghost/npm-custom-nginx.conf
   ```

   <details>
   <summary>The block itself, if you'd rather copy it from here</summary>

   ```nginx
   client_max_body_size 50M;
   ```

   </details>

   Without it, dragging an image into the editor fails with **413 Request Entity Too Large** — and nothing appears in Ghost's logs, because the request never reaches Ghost.
4. Enable **SSL** with Let's Encrypt from the UI.

Scheme stays `http` — the container serves plain HTTP and NPM terminates TLS.

✅ No host port is published by default — NPM reaches `ghost-app` by container name over `main-net`. The database stays on the private `ghost-net`.

### ⚠️ `url` must match how the site is actually reached

Ghost builds **every absolute link** from `url` — canonical URLs, RSS, newsletter links, and the redirect after admin login. A mismatch is the classic Ghost self-hosting symptom: the site renders, but logging into `/ghost` bounces you to the wrong host and appears to fail.

To change it: edit `GHOST_URL` in `~/docker/ghost/.env` and rerun `deploy.sh`. Never hand-edit config inside the container.

Same class of setting as [Dolibarr](../../ERP/dolibarr/)'s `DOLI_URL_ROOT` and [OpenProject](../../Projects/openproject/)'s `OPENPROJECT_HOST__NAME`.

---

## 📧 Email

Not configured by this deployment, and Ghost **works fine without it** for writing and publishing. But three things silently don't work until you add SMTP:

- staff invitations
- password resets
- member signups and newsletters

To add it, put your SMTP details in `~/docker/ghost/.env` and add the matching `mail__*` variables to `ghost-app`'s `environment:` block in `docker-compose.yml`:

```yaml
mail__transport: SMTP
mail__options__service: Mailgun
mail__options__host: smtp.example.com
mail__options__port: "587"
mail__options__auth__user: ${MAIL_USER}
mail__options__auth__pass: ${MAIL_PASSWORD}
mail__from: "'Your Site' <noreply@example.com>"
```

Then `docker compose up -d`. Ghost's own [email configuration docs](https://ghost.org/docs/config/#mail) list every supported provider and option.

> 💡 Ghost distinguishes **transactional** email (invites, resets — plain SMTP) from **bulk** email (newsletters to members), which upstream expects to go through Mailgun specifically. A plain SMTP server covers the first group only.

---

## 🛠️ Management Commands

```bash
cd ~/docker/ghost
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Check both containers |
| `docker compose logs -f ghost-app` | Follow Ghost's logs |
| `docker compose logs -f ghost-db` | Database logs |
| `docker compose pull && docker compose up -d` | Update to the latest patch of the pinned major |

> 💡 **Upgrading across major versions** (e.g. 6 → 7): bump `GHOST_VERSION` in `.env`, then `docker compose up -d`. Ghost runs its own database migration on first start. **Back up first**, and check Ghost's upgrade notes — major versions occasionally drop themes or API versions.

---

## 💾 Backups

This service ships a DB-aware [`backup.sh`](backup.sh), so the **Backup** option in `services.sh` uses `mysqldump` instead of raw-copying live database files. The `ghost-content` volume — themes, uploaded images and media, `routes.yaml` — is captured in the same run, along with `.env`.

⚠️ Ghost stores **absolute URLs** in its database. Restoring to a different domain without updating `GHOST_URL` in `.env` produces broken links and an admin panel that redirects away; the restore step warns about this.

---

## 📌 Notes & Deviations

- **MySQL 8.4 instead of the official example's 8.0** — see the box at the top. No MySQL command flags are set, deliberately.
- **A dedicated database user.** The official example connects Ghost to MySQL as `root`.
- **No host port by default**, where the official example publishes `8080` unconditionally.
- **A private `ghost-net`** for app↔db, where the example puts everything on the default network. Only `ghost-app` joins `main-net`.
- **A healthcheck on the database**, so `ghost-app` waits for MySQL to actually accept connections rather than just for the container to exist. MySQL's first-run initialisation takes noticeably longer than MariaDB's, and without this Ghost starts, fails to connect, and restarts a few times before settling.

---

## 📜 License

Ghost is licensed separately (MIT — see the [official repository](https://github.com/TryGhost/Ghost)). Note the **Ghost trademark and logo are not covered by that licence**, and Ghost(Pro) branding rules apply if you redistribute. This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of this repo.

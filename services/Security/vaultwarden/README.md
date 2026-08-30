# 🔑 Vaultwarden

Deploys [Vaultwarden](https://github.com/dani-garcia/vaultwarden) — a lightweight, Bitwarden-compatible password manager server — behind the shared `main-net` network so [NGINX Proxy Manager](../../../README.md) can front it.

It speaks the official Bitwarden API, so the official Bitwarden apps and browser extensions work against it unchanged. Single container, SQLite embedded — one of the lightest services in this repo.

See the top of [`docker-compose.yml`](docker-compose.yml) for the exact, deliberate deviations from upstream's own example.

---

## 🔐 This One Holds Your Passwords — Read This

Everything in this repo is worth securing, but this service *is* the security. Three things are not optional:

1. **HTTPS is genuinely required — not just recommended.** See [the section below](#️-https-only--there-is-no-direct-port-option): the web vault refuses to load at all over plain `http://` on a normal address. This is a browser rule, not a Vaultwarden setting, and nothing in `.env` can turn it off — which is why this service has no direct-port option at all.
2. **Close registration immediately after creating your account** — see [below](#-required-close-registration-after-your-first-account). Open signups on a reachable instance means strangers can register on your password manager.
3. **`DOMAIN` must be correct.** It's not cosmetic: attachments, WebAuthn/2FA, and emailed links are all built from it.

---

## ⛔️ HTTPS Only — There Is No Direct-Port Option

**This is the one service in this repo with no "publish a host port for quick direct access" prompt.** It was removed on purpose, because that path is a dead end here, twice over:

**1. The browser blocks it.** Open Vaultwarden on a plain `http://<server-ip>:<port>` address and you get this instead of the login page:

> You are not using a secure context which is required for the Subtle Crypto API to work. You need to enable HTTPS!

The web vault encrypts in the browser via the Web Crypto API (`crypto.subtle`), and browsers expose that API only in a **secure context** — an HTTPS page, or a `localhost`/`127.0.0.1` address. A LAN IP over plain HTTP is neither. No server-side setting can override this; it isn't a Vaultwarden option.

**2. It would quietly break the NPM path too.** Choosing a host port would set `DOMAIN` to `http://<ip>:<port>`, and `DOMAIN` must match the real access URL. Setting up NPM afterwards would then misbehave until someone noticed and hand-edited `DOMAIN` — a confusing failure with no obvious cause.

So `deploy.sh` always asks for your public domain and sets `DOMAIN=https://<domain>`. NPM + SSL is the only supported route.

> 💡 **Need a look before DNS/SSL is ready?** An SSH tunnel makes the address `localhost`, which *is* a secure context. Add a temporary port mapping to `~/docker/vaultwarden/docker-compose.override.yml`, then:
> ```bash
> ssh -L 8222:localhost:8222 you@your-server
> ```
> and open `http://localhost:8222`. Remove the mapping afterwards — this is a debugging aid, not a deployment mode.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows, it installs the full bundle automatically (skipping anything already installed).

### 2. Deploy Vaultwarden

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Security/vaultwarden/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Security/vaultwarden/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

This is a **single-instance** service: one Vaultwarden deployment per host, under `~/docker/vaultwarden/`.

`deploy.sh` generates a random admin-page password and saves it to `~/docker/vaultwarden/.vaultwarden-docker-secrets.txt` (`600`).

> 💡 **The token is stored in `.env` as plaintext, not an Argon2 hash — expect this.** `deploy.sh` tries to hash it with Vaultwarden's own `hash --preset owasp` command, but that command reads the password straight from the terminal device (`/dev/tty`) rather than standard input, so it can't be scripted at all. Vaultwarden accepts both forms; hashing just protects the token if someone reads `.env` without otherwise owning the host. Upgrading takes one command — see [Re-hashing the admin token](#-re-hashing-the-admin-token) — and `deploy.sh` tells you which form it used.

You'll also be asked for the **public domain** you'll point NPM at (required — see [above](#️-https-only--there-is-no-direct-port-option) for why there's no host-port alternative) and whether to cap memory on the `vaultwarden` container (default suggestion: `512m`).

---

## 🚨 REQUIRED: Close Registration After Your First Account

`deploy.sh` sets `SIGNUPS_ALLOWED=true` so you can create your own account. **Close it the moment you have:**

```bash
sed -i 's/^SIGNUPS_ALLOWED=true/SIGNUPS_ALLOWED=false/' ~/docker/vaultwarden/.env
cd ~/docker/vaultwarden && docker compose up -d
```

To invite others afterward, use the admin page (`/admin`) or an organization invite — neither requires reopening public signups.

---

## 👤 First Login & the Admin Page

Vaultwarden has **no default account**. Visit the site and register your own — the first account is just a normal user account.

The **admin page** at `/admin` is separate: it manages users, invites, and server settings, and is protected by the admin token (not by any user account). Log in with the plaintext password from the secrets file.

> 📌 Don't need it? Deleting the `ADMIN_TOKEN` line from `.env` and restarting **disables the admin page entirely** — a legitimate and safer choice if you're the only user.

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

> ☁️ **Using Cloudflare Tunnel?** Two steps below are different: where you open NPM, and the SSL certificate (`None`, not Let's Encrypt). See [docs/cloudflare-tunnel.md](../../../docs/cloudflare-tunnel.md#deploying-a-service-behind-the-tunnel).

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: your chosen domain, e.g. `vault.example.com` (must match `DOMAIN` in `.env`)
   - **Forward Hostname/IP**: `vaultwarden-app`
   - **Forward Port**: `80`
   - Enable **Websockets Support** (used for live sync between your devices)
3. Enable **SSL** with Let's Encrypt from the UI — see the warning at the top of this README; this is effectively required, not optional.

✅ No host port is published for `vaultwarden-app` at all — NPM reaches it by container name over `main-net`.

> 📌 **Older guides mention a second port `3012` for websockets.** That's obsolete — current Vaultwarden serves websockets on the main port, enabled by default. One Proxy Host to port `80` is all you need.

---

## 💾 Backups

This repo's **Backup** option (in `services.sh`) fully covers Vaultwarden: everything — vault data, attachments, config — lives in the single `/data` volume with an embedded SQLite database, which the generic volume backup captures completely. No special `backup.sh` is needed here, unlike the Postgres/MySQL-backed services.

Given what this service stores, take backups **before** upgrades, and keep at least one copy off this host.

---

## 🛠️ Management Commands

```bash
cd ~/docker/vaultwarden
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Check container status |
| `docker compose logs -f vaultwarden` | Follow the app's logs |
| `docker compose stop` / `start` | Stop/start without removing containers |
| `docker compose pull && docker compose up -d` | Update to the latest image |

### 🔁 Re-hashing the admin token

`deploy.sh` stores the token as plaintext (see [above](#2-deploy-vaultwarden) for why it can't be automated). To replace it with an Argon2 hash — worth doing, and it takes about ten seconds:

```bash
docker run --rm -it vaultwarden/server /vaultwarden hash --preset owasp
```

Copy the `$argon2id$...` string it prints into `~/docker/vaultwarden/.env` as:

```
ADMIN_TOKEN='$argon2id$...'
```

Keep the **single quotes** and the **single `$`** characters exactly as printed — this file is passed to the container via `env_file`, so no `$`-doubling is needed (and doubling them would break it). Then `docker compose up -d`.

---

## 📌 Notes & Deviations

- **Container port is `80`**, despite upstream's `.env.template` showing `ROCKET_PORT=8000` — that value is the bare binary's default, and the official Docker image overrides it (`ROCKET_PORT=80` + `EXPOSE 80` in its own Dockerfile).
- **`env_file` instead of `${VAR}` substitution**, deliberately: the Argon2 admin token is full of `$` characters that Compose would otherwise try to expand as variables. This is the same class of problem as this repo's [WireGuard](../../VPN/wireguard/) service, solved the opposite way there (`$$`-doubling) because that one genuinely needs substitution.
- **No private `<service>-net`** — single container, no database to isolate, so it joins `main-net` directly (same as Jellyfin/LinkStack).
- **No host-port option at all** — the only service here without one. Every other service offers it as an optional quick-look path; for Vaultwarden it can't work (browser secure-context rule) *and* it would corrupt `DOMAIN` for the NPM path, so it's omitted rather than offered-and-caveated. See [above](#️-https-only--there-is-no-direct-port-option).

---

## 📜 License

Vaultwarden itself is licensed separately (AGPL-3.0 — see the [official repository](https://github.com/dani-garcia/vaultwarden) for terms). It is an independent, unofficial implementation and is **not** affiliated with or endorsed by Bitwarden, Inc. This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of this repo.

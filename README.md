# 🐳 DockHub

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](#)
[![Docker](https://img.shields.io/badge/Docker-CE-2496ED?logo=docker&logoColor=white)](#)
[![NPM](https://img.shields.io/badge/NGINX%20Proxy%20Manager-latest-00A98F)](#-environment-variable-overrides)
[![Portainer](https://img.shields.io/badge/Portainer--CE-latest-13BEF9)](#-environment-variable-overrides)
[![Platforms](https://img.shields.io/badge/Platforms-Debian%20%7C%20Ubuntu%20%7C%20RHEL%20%7C%20Arch%20%7C%20openSUSE-lightgrey)](#-supported-operating-systems)

A hardened, interactive Bash installer for **Docker CE, Docker Compose, NGINX Proxy Manager (NPM), and Portainer‑CE** on Linux — including ARM64 devices like Raspberry Pi — plus a growing, categorized catalog of self-hosted services ([AI, Automation, ERP, Projects, Storage, and more](#-services)) that deploy behind that same reverse proxy with one command each.

One command → a reproducible Docker host with a reverse proxy and a container management UI, ready to sit behind a domain and SSL.

---

## 📑 Table of Contents

- [Supported Operating Systems](#-supported-operating-systems)
- [Features](#-features)
- [Architecture](#-architecture)
- [Services](#-services)
- [Installation](#-installation)
- [Environment Variable Overrides](#-environment-variable-overrides)
- [Default Credentials](#-default-credentials)
- [Directory Layout After Install](#-directory-layout-after-install)
- [Management Commands](#️-management-commands)
- [Security Notes](#-security-notes)
- [Troubleshooting](#-troubleshooting)
- [System Requirements](#-system-requirements)
- [Changelog](#-changelog)
- [License](#-license)

---

## 🖥️ Supported Operating Systems

| OS Family | Versions |
|---|---|
| **Debian** | 10 / 11 / 12 |
| **Ubuntu** | 20.04 / 22.04 / 24.04 (x86_64 & ARM64) |
| **Raspberry Pi OS / Raspbian** | ARM64 |
| **CentOS / RHEL / Rocky / AlmaLinux / Fedora** | via `dnf` or `yum` |
| **Arch Linux** | — |
| **openSUSE** | Leap & Tumbleweed |

Auto-detected via `/etc/os-release` (falls back to `ID_LIKE` for derivatives). If detection fails, you get an interactive manual picker — the install never silently guesses wrong.

---

## ✅ Features

| Category | Details |
|---|---|
| 🚀 **One-command setup** | Docker CE + Compose + NPM + Portainer, all interactive, all in one script |
| 🧩 **Compose-based, not bare `docker run`** | Both NPM **and Portainer** are deployed as `docker-compose.yml` stacks — consistent, reproducible, easy to inspect/edit |
| 🏷️ **Configurable images** | NPM defaults to `:latest`; Portainer pinned to `2.40.0` for stability. Both overridable via env vars |
| 🌐 **Shared `main-net` network** | NPM (and Portainer) attach to it, so other containers can be proxied by hostname |
| ❤️ **Working health checks** | Exec-form checks that don't depend on a shell existing inside minimal images (see [Changelog](#-changelog) — this used to silently misreport "unhealthy") |
| 🔎 **Port-conflict detection** | Checks `ss`/`netstat` before binding, warns and asks before proceeding |
| ♻️ **Idempotent reruns** | Existing containers, compose files, the network, and the Portainer data volume are all preserved |
| ⚙️ **Configurable ports** | Every published port is an environment variable override |
| 👤 **`sudo` vs pure-root aware** | Installs into the *invoking* user's home (not `/root`), fixes ownership, adds them to the `docker` group correctly |
| 🛡️ **Proper error propagation** | `set -Eeuo pipefail` + a global `ERR` trap reporting file, line, and function |
| 🗒️ **Log rotation** | Each run archives the previous `~/docker/install_dockhub.log` to `.old` |
| 🔥 **Firewalld hint** | Prints ready-to-paste `firewall-cmd` commands on RHEL-family systems |
| 🎨 **Color-coded, EOF-safe prompts** | Won't crash if piped or run non-interactively |

---

## 🧠 Architecture

```
                         ┌───────────────────────────────────────────┐
                         │              main-net  (bridge)             │
                         │                                             │
   Host                  │   ┌────────────┐        ┌────────────────┐│
   ─────                 │   │  NPM (app) │        │   Portainer     ││
   :80   → HTTP    ───────┼──►│  :80/:443  │        │   :9000 HTTP    ││
   :443  → HTTPS   ───────┼──►│  :81 admin │        │   :9443 HTTPS   ││
   :81   → Admin UI ──────┼──►│            │        │   :8000 Edge    ││
                         │   └─────┬──────┘        └────────┬────────┘│
   :9000 → HTTP    ───────┼─────────┼────────────────────────┤        │
   :9443 → HTTPS   ───────┼─────────┼────────────────────────┤        │
   :8000 → Edge     ──────┼─────────┼────────────────────────┘        │
                         └─────────┼─────────────────────────────────┘
                                   │
                    ┌──────────────▼──────────────┐        ┌─────────────────────┐
                    │  ~/docker/npm/                │        │ /var/run/docker.sock │
                    │    ├── data/        (bind)     │        │  (Portainer mgmt)     │
                    │    └── letsencrypt/ (bind)     │        └─────────────────────┘
                    └────────────────────────────────┘
                                                         ┌──────────────────────────┐
                                                         │ named volume:              │
                                                         │ portainer_data (external)  │
                                                         └──────────────────────────┘
```

Both services are plain `docker-compose.yml` stacks under `~/docker/<service>/`, attached to a single shared external network (`main-net`) so you can add more services later and proxy them by container hostname through NPM.

---

## 🧱 Services

This repo installs the **core infrastructure** (`install_dockhub.sh` → Docker CE, Compose, NPM, Portainer, and the shared `main-net` network). Everything else lives under [`services/`](services/README.md) as its own self-contained, independently-deployed folder — run only the ones you actually need. See [`services/README.md`](services/README.md) for the full up-to-date roadmap (41 catalog entries across 15 categories, ✅ = built), quick-start, and conventions — the table there is the source of truth; this section just shows the shape of the repo.

```
dockhub/
├── install_dockhub.sh
├── lib/
│   └── common.sh                 # shared helpers every service's deploy.sh sources
├── docs/
│   ├── troubleshooting.md        # reverse-proxy / network issues
│   ├── cloudflare-tunnel.md      # home-server-behind-NAT setup guide
│   └── updating.md
└── services/
    ├── services.sh                # category → service → deploy/remove/reinstall/backup/restore menu
    ├── ERP/odoo/                  # multi-instance; also has backup.sh (DB-aware)
    ├── Projects/{openproject,plane,vikunja,redmine,taiga}/
    ├── Storage/nextcloud/
    ├── Automation/n8n/
    ├── Media/jellyfin/
    ├── Web/linkstack/
    ├── _template/                 # copy this to scaffold a new service
    │   ├── deploy.sh.template
    │   ├── backup.sh.template      # only needed for services with their own db container
    │   ├── docker-compose.template.yml
    │   └── .env.example
    └── <other categories>/        # still 🚧 roadmap placeholders — see services/README.md
```

Convention for every service: its own `.env` (never committed, `chmod 600`), a private `<service>-net` for its own containers (e.g. app ↔ db) when it has more than one, and only its app/entrypoint container also joined to `main-net` so NPM can reach it by container name. Containers are named `<service>-app` / `<service>-db`. Every service also offers an **optional memory cap** and **optional direct host port**, and a **Backup/Restore** menu option in `services.sh` (generic volume-based by default, `pg_dump`/`mysqldump`-based for services with their own database container). See [`services/_template/`](services/_template/) to scaffold a new one, or [`services/README.md`](services/README.md) for the full convention list.

---

## 📥 Installation

**Recommended: clone the full repo.** This is what the "Install a service" menu option below needs anyway — with a clone, every service's files are already on disk, so picking one from the menu launches it immediately instead of downloading it on the spot.

```bash
git clone https://github.com/IbrahimAljuhani/dockhub.git
cd dockhub
sudo bash install_dockhub.sh
```

<details>
<summary>Alternative: just <code>install_dockhub.sh</code> alone (no git, no services)</summary>

If you only want the core infrastructure (Docker CE, Compose, NPM, Portainer) and don't care about `services/` at all:

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```

Picking **"Install a service"** from the menu without a local clone still works — it falls back to downloading the service you pick from GitHub on the spot (see [`services/README.md`](services/README.md)).

</details>

> ⚠️ Must be run with `sudo` (or as root). Use `sudo -E bash install_dockhub.sh` if you're setting env-var overrides (`-E` preserves them across the `sudo` boundary). Note it's `bash install_dockhub.sh`, not `./install_dockhub.sh` — a fresh `git clone`/`git pull` doesn't reliably preserve the executable bit, and `bash <file>` works regardless of it.

You'll get a menu:

```
What would you like to do?
1) Install / manage core infrastructure (Docker CE, Compose, NPM, Portainer)
2) Install a service
3) Exit
```

- **Option 1**: if Docker, Compose, NPM, and Portainer are all already installed, you're offered **Reset NPM & Portainer** (recreates just those two — never touches Docker Engine, `main-net`, or any other running service/container — and asks separately whether to also wipe their data) or going back. Otherwise, choosing this option is itself the confirmation — it installs the full bundle (Docker CE, Compose, NPM, Portainer) straight away, silently skipping whichever pieces are already installed/active:

  | Component | Skipped automatically if... |
  |---|---|
  | Docker-CE | Docker is already installed and active |
  | Docker Compose | The `compose` plugin is already present |
  | NGINX Proxy Manager | Always installed |
  | Portainer-CE | Always installed |

- **Option 2**: hands off to [`services/services.sh`](services/services.sh) (if you have the full repo checked out next to this script) to list and launch any service under `services/`; otherwise it prints the `curl` command to fetch `services.sh` standalone.

---

## 🔧 Environment Variable Overrides

Export before running to customize images or host ports:

| Variable | Default | Purpose |
|---|---|---|
| `NPM_IMAGE` | `jc21/nginx-proxy-manager:latest` | NPM image tag — see note below |
| `NPM_HTTP_PORT` | `80` | Host port for public HTTP |
| `NPM_HTTPS_PORT` | `443` | Host port for public HTTPS |
| `NPM_ADMIN_PORT` | `81` | Host port for NPM admin UI |
| `PORTAINER_IMAGE` | `portainer/portainer-ce:latest` | Portainer image tag |
| `PORTAINER_HTTP_PORT` | `9000` | Host port for Portainer HTTP |
| `PORTAINER_HTTPS_PORT` | `9443` | Host port for Portainer HTTPS |
| `PORTAINER_EDGE_PORT` | `8000` | Host port for Portainer Edge agent |

> 💡 **`NPM_IMAGE` defaults to `:latest`** — you always get the newest NPM release, at the cost of reproducibility (a re-run next month may pull a different image than today). If you need a **pinned, repeatable** version instead (e.g. for production), override it explicitly:
> ```bash
> NPM_IMAGE=jc21/nginx-proxy-manager:2.14.0 sudo -E bash install_dockhub.sh
> ```

Example (move NPM's HTTP/HTTPS off the standard ports):

```bash
NPM_HTTP_PORT=8080 NPM_HTTPS_PORT=8443 sudo -E bash install_dockhub.sh
```

---

## 🔑 Default Credentials

### NGINX Proxy Manager
- URL: `http://YOUR_SERVER_IP:81` (or `$NPM_ADMIN_PORT`)
- Email: `admin@example.com`
- Password: `changeme`

> ⚠️ Change these immediately after first login.

### Portainer-CE
- URL: `http://YOUR_SERVER_IP:9000` or `https://YOUR_SERVER_IP:9443`
- First login: create your own admin account (no default credentials — first visitor wins, so don't leave it exposed before you've set this up).

---

## 📁 Directory Layout After Install

This script only creates `npm/` and `portainer/`, plus its own log file — but every service under [`services/`](services/) (see [Services](#-services)) follows the same convention and adds its own `~/docker/<name>/` folder alongside them, so the entire host's state (core infra *and* every optional service) stays backupable as one `~/docker/` tree:

```
~/docker/
├── install_dockhub.log      # this script's own log (rotated to .old on rerun)
├── .dockhub-env              # one-time home/VPS + access-method choice (see install_dockhub.sh)
├── npm/
│   ├── docker-compose.yml
│   ├── data/            # NPM SQLite DB + config      (owned by you)
│   └── letsencrypt/      # TLS certs                   (owned by you)
├── portainer/
│   └── docker-compose.yml
├── backups/                  # created on demand by services.sh's Backup option
│   └── <service>/[<instance>/]<timestamp>.tar.gz
└── odoo/                 # example: added by services/ERP/odoo/deploy.sh — runtime state stays flat under ~/docker/ regardless of the repo's category folders
    ├── deploy.log
    ├── .odoo-docker-secrets.txt
    └── <instance-name>/
        ├── .env
        └── docker-compose.yml
```

> 📝 Portainer's own data (users, stack definitions, settings) lives in the **named Docker volume** `portainer_data` — not a folder under `~/docker/portainer/`. It's created as `external: true` in the compose file specifically so that re-running the installer, or upgrading from an older version of this script, never touches or recreates existing Portainer data.

---

## 🛠️ Management Commands

```bash
cd ~/docker/npm         # or: cd ~/docker/portainer
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Check container status |
| `docker compose logs -f` | Follow live logs |
| `docker compose stop` / `start` | Stop/start without removing containers |
| `docker compose restart` | Restart |
| `docker compose down` | Stop & remove containers (bind-mounted data preserved; Portainer's named volume also preserved since it's `external`) |
| `docker compose pull && docker compose up -d` | Update to the latest image (relevant for `NPM_IMAGE=...:latest`) |

Quick health check from anywhere:
```bash
docker inspect --format='{{.State.Health.Status}}' npm-app-1
docker inspect --format='{{.State.Health.Status}}' portainer
```

---

## 🔐 Security Notes

- **Portainer mounts `/var/run/docker.sock`.** Anyone who can reach Portainer effectively has root on the host. Keep the admin UI behind a firewall, VPN, or a reverse-proxied auth layer.
- **NPM default credentials must be changed immediately** — the panel is reachable on `:81` the moment the container starts.
- **`docker` group membership = root-equivalent.** Be deliberate about who you add.
- The script pins Portainer's tag but, by default, tracks NPM's `:latest` — pin it (see above) if unattended reproducibility matters more to you than always having the newest NPM.
- Docker is installed via `curl -fsSL https://get.docker.com | sh` with no checksum verification of that upstream script. If that's a concern in your environment, install Docker from your distro's own repository instead.

---

## 🩺 Troubleshooting

This table is for **core-infrastructure install issues** (Docker/Compose/NPM/Portainer). For "a service deployed fine but the site won't open" — reverse proxy misconfiguration, Cloudflare Tunnel, direct-port reachability — see [docs/troubleshooting.md](docs/troubleshooting.md) instead.

| Symptom | Cause | Fix |
|---|---|---|
| Portainer shows `unhealthy` in `docker ps` / Portainer's own UI, even though it works fine | *(Historical — fixed)* Older revisions used `docker run --health-cmd`, which always requires a shell inside the image; the default portainer-ce image has none | Already fixed — Portainer now runs via `docker-compose.yml` with a shell-free healthcheck. If you're still seeing this, you're on an old copy of the script; re-download it |
| `~/docker/npm/data` or `.../letsencrypt` need `sudo` to edit | *(Historical — fixed)* Those folders used to be auto-created by the root Docker daemon *after* the script's ownership fix ran, so they stayed root-owned | Already fixed — ownership is re-applied after `docker compose up`. For an existing install: `sudo chown -R $USER:$USER ~/docker/npm` |
| `docker` command requires `sudo` after install | Group membership only applies to new login sessions | Log out and back in (or reboot) |
| Services unreachable on RHEL/Fedora | `firewalld` blocks ports even though Docker bypasses `ufw` | The script prints the exact `firewall-cmd` lines it needs at the end of the run |
| Port already in use | Another service is bound to it | The script pre-checks with `ss`/`netstat` and offers to continue or abort. Re-run with the relevant `_PORT` env var to pick a different one |
| Containers not running after install | Varies | `cd ~/docker/npm && docker compose logs` / `cd ~/docker/portainer && docker compose logs` |
| Installation failed mid-way | Varies — check the log | `~/docker/install_dockhub.log` (previous run preserved as `.old`) |
| Site deployed fine but domain won't open (Cloudflare Tunnel) | Wrong routing target, or Force SSL fighting Cloudflare's own HTTPS enforcement | See [docs/cloudflare-tunnel.md](docs/cloudflare-tunnel.md) |
| Not sure how to update DockHub itself, or a single service's image | — | See [docs/updating.md](docs/updating.md) |

---

## 💻 System Requirements

- 1 GB RAM minimum (2 GB recommended)
- ~10 GB free disk
- Internet access during install

---

## 🗒️ Changelog

- **Fixed:** Portainer's healthcheck permanently reported `unhealthy` despite the container working correctly. Root cause: `docker run --health-cmd` always wraps the test in `CMD-SHELL` (`/bin/sh -c ...`), but the default portainer-ce image ships no shell at all. Portainer is now deployed via `docker-compose.yml` (same pattern as NPM) with an exec-form (`["CMD", "wget", ...]`) healthcheck that never invokes a shell.
- **Fixed:** `~/docker/npm/data` and `~/docker/npm/letsencrypt` could end up owned by `root` instead of the invoking user, because the Docker daemon (running as root) creates those bind-mount folders the first time `docker compose up` runs them into existence — *after* the script's one-time `chown` had already completed. Ownership is now re-applied after `up` as well.
- **Changed:** `NPM_IMAGE` now defaults to `jc21/nginx-proxy-manager:latest` instead of a pinned version. See the [override note](#-environment-variable-overrides) if you need reproducibility instead.
- **Fixed:** NPM's healthcheck path corrected to the documented `/usr/bin/check-health` (the previous `/bin/check-health` likely worked too on this Debian-based image thanks to the usr-merge symlink, but this removes any ambiguity).
- **Documented:** `docker_compose_NPM.yml` (the standalone reference template) now states its `main-net` external-network prerequisite explicitly, and is kept in sync with the installer's generated compose file.
- **Renamed:** project renamed from `docker_installs` to **DockHub**, and `install_docker_core.sh` to `install_dockhub.sh`, ahead of the project growing into a categorized multi-service catalog (see [Services](#-services)). The GitHub repo itself was renamed too — old `raw.githubusercontent.com/.../docker_installs/...` links will redirect for a while, but update any bookmarked install commands to the `dockhub` URLs shown throughout this README.

---

## 📜 License

MIT — see [LICENSE](LICENSE).

---

## 🙌 Author

**Ibrahim Aljuhani** — [@IbrahimAljuhani](https://github.com/IbrahimAljuhani)

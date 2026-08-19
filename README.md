<!-- The blank lines inside this div are load-bearing. An HTML block in
     GitHub-flavoured markdown swallows everything until a blank line, so
     without them every badge below would render as literal `[![...]](...)`
     text. With them, the div opens, markdown resumes, and the badges are
     still badges — centred, because they inherit the div's alignment. -->
<div align="center">

<img src="assets/dockhub-lockup.svg" alt="DockHub — your self-hosted server, simplified" width="420">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![ShellCheck](https://github.com/IbrahimAljuhani/dockhub/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/IbrahimAljuhani/dockhub/actions/workflows/shellcheck.yml)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](#)
[![Docker](https://img.shields.io/badge/Docker-CE%20%2B%20Compose-2496ED?logo=docker&logoColor=white)](#-the-core-what-install_dockhubsh-gives-you)
[![Platforms](https://img.shields.io/badge/Platforms-Debian%20%7C%20Ubuntu%20%7C%20RHEL%20%7C%20Arch%20%7C%20openSUSE-lightgrey)](#-supported-systems)
[![ARM64](https://img.shields.io/badge/arch-x86__64%20%7C%20ARM64-lightgrey)](#-supported-systems)

[![Services](https://img.shields.io/badge/Services-39%20built%20%2F%2041-brightgreen)](#-the-catalogue)
[![Categories](https://img.shields.io/badge/Categories-15-blue)](#-the-catalogue)
[![NPM](https://img.shields.io/badge/NGINX%20Proxy%20Manager-latest-00A98F)](#-environment-variable-overrides)
[![Portainer](https://img.shields.io/badge/Portainer--CE-latest-13BEF9)](#-environment-variable-overrides)
[![TLS](https://img.shields.io/badge/TLS-Let's%20Encrypt-003A70)](#-two-networks-and-why)
[![Backups](https://img.shields.io/badge/Backup%20%26%20Restore-built--in-6E4AFF)](#-backups)
[![GPU](https://img.shields.io/badge/GPU-optional-76B900?logo=nvidia&logoColor=white)](services/AI/)

</div>

**Self-hosted services, deployed properly.** One script installs the Docker foundation; a menu deploys any of **39 services** on top of it — each with a reverse proxy route, a backup path, and documentation written from actually running it.

```bash
git clone https://github.com/IbrahimAljuhani/dockhub.git
cd dockhub
sudo bash install_dockhub.sh
```

---

## 📑 Contents

- [What DockHub is](#-what-dockhub-is)
- [Getting started](#-getting-started)
- [The core](#-the-core-what-install_dockhubsh-gives-you)
- [The catalogue](#-the-catalogue)
- [How every service behaves](#-how-every-service-behaves)
- [Networks](#-two-networks-and-why)
- [Where everything lives](#-where-everything-lives)
- [Backups](#-backups)
- [Environment variable overrides](#-environment-variable-overrides)
- [Supported systems](#-supported-systems)
- [Managing and updating](#-managing-and-updating)
- [Documentation](#-documentation)
- [How this project is built](#-how-this-project-is-built)
- [Status](#-status)

---

## 🎯 What DockHub is

A catalogue of **self-hostable services** with a consistent deployment script for each, plus the infrastructure they all share: a reverse proxy, a container manager, and one predictable place on disk for everything.

It is **not** a control panel and not a PaaS. Nothing runs in the background, nothing phones home, and nothing hides what it did — every deployment is a plain `docker-compose.yml` you can read, edit, or take somewhere else.

**Who it is for:** anyone standing up services on their own hardware — a home server, a VPS, a spare machine under a desk — who wants them proxied, backed up and reachable without assembling each one by hand.

---

## 🚀 Getting started

**1 — Install the foundation.** Docker CE, Docker Compose, NGINX Proxy Manager and Portainer, with every port and image overridable:

```bash
sudo bash install_dockhub.sh
```

**2 — Deploy services.** The installer hands off to the picker when it finishes, or run it yourself at any time:

```bash
bash services/services.sh
```

You get a category menu, then a service menu, then a short interview — domain or host port, memory limit, and whatever that particular service genuinely needs. Nothing is assumed.

> **Run the installer with `sudo`, the picker as yourself.** `install_dockhub.sh` drops privileges before handing off, so services deploy under your own user with your own file ownership.

---

## 🧱 The core: what `install_dockhub.sh` gives you

| | Purpose | Reached at |
|---|---|---|
| **Docker CE + Compose** | Installed for your distribution, or skipped if already present | — |
| **NGINX Proxy Manager** | Routes domains to containers, issues Let's Encrypt certificates | `:81` admin |
| **Portainer CE** | A web view of every container, volume and network | **no host port by default** — see below |
| **`main-net`** | The shared bridge network the proxy and your services meet on | — |

**First-login credentials** — change both immediately:

| | |
|---|---|
| NGINX Proxy Manager | `admin@example.com` / `changeme` |
| Portainer | No default — **the first visitor creates the admin account.** Do not leave it reachable before you have |

**Docker is not optional; NPM and Portainer are.** The installer asks about the last two, because a host that only ever uses LAN ports needs neither. It does not ask about Docker — a choice you cannot decline is not a choice.

**Portainer gets no host port unless you ask for it.** It mounts `/var/run/docker.sock`, so reaching its web interface is equivalent to root on the machine — it is not a dashboard, it is a key. By default it joins `main-net` only, reachable as `portainer:9000`, and you publish it deliberately through NGINX Proxy Manager with HTTPS in front. Answer yes to the port question and it binds every interface, which on a VPS means the internet.

> The same rule already removed the host-port option from [Vaultwarden](services/Security/vaultwarden/) outright. Portainer is the more dangerous of the two and kept its ports open for longer than it should have.

The installer also asks, once, whether this is a **home server or a VPS**, and how you intend to reach it from outside — port forwarding or Cloudflare Tunnel. The answer is remembered in `~/docker/.dockhub-env` and shapes the advice every later script gives you.

---

## 📚 The catalogue

Each category has its own README explaining what the services are for, how they differ, and the traps found while building them.

| Category | Services | Built |
|---|---|---|
| 🧠 [**AI**](services/AI/) | Ollama · llama.cpp · LocalAI · Open WebUI | 4/4 |
| 🤖 [**AI-Agents**](services/AI-Agents/) | OpenClaw · Hermes · OpenHands | 3/3 |
| 🧩 [**Multi-Agent**](services/Multi-Agent/) | **Paperclip** · **Dify** · Flowise · Langflow | 2/4 |
| ⚙️ [**Automation**](services/Automation/) | n8n | 1/1 |
| 🌐 [**DNS**](services/DNS/) | Pi-hole · AdGuard Home | 2/2 |
| 🏢 [**ERP**](services/ERP/) | Odoo · ERPNext · Dolibarr | 3/3 |
| 🏠 [**Home-Automation**](services/Home-Automation/) | Home Assistant · Mosquitto | 2/2 |
| 🎬 [**Media**](services/Media/) | Jellyfin · Plex | 2/2 |
| 📷 [**Photos**](services/Photos/) | Immich · PhotoPrism | 2/2 |
| 📋 [**Projects**](services/Projects/) | OpenProject · Plane · Redmine · Taiga · Vikunja | 5/5 |
| 🔐 [**Security**](services/Security/) | Vaultwarden | 1/1 |
| 🧪 [**Security-Lab**](services/Security-Lab/) | Juice Shop · WebGoat · Vulhub | 3/3 |
| 💾 [**Storage**](services/Storage/) | Nextcloud · ownCloud · Seafile | 3/3 |
| 🔒 [**VPN**](services/VPN/) | WireGuard · NetBird · OpenVPN | 3/3 |
| 🕸️ [**Web**](services/Web/) | WordPress · Ghost · LinkStack | 3/3 |

> ⚠️ **[Security-Lab](services/Security-Lab/) is deliberately vulnerable software** — training targets, not services. It sits behind its own gate and must never touch a network you care about. Read that category's README before deploying anything in it.

---

## 🔧 How every service behaves

The value of a catalogue is that the second service works like the first. Every `deploy.sh` here follows the same contract:

| | |
|---|---|
| **One command** | `bash deploy.sh`, or pick it from the menu |
| **Asks, never assumes** | Domain *or* host port, memory limit, and any service-specific decision — each with the trade-off stated |
| **Generates its own secrets** | Written to `~/docker/<service>/.<service>-docker-secrets.txt`, `chmod 600` |
| **Never overwrites your edits** | An existing `.env` or `docker-compose.yml` is reused, not replaced. Delete it yourself to take the newer version |
| **Safe to rerun** | Reruns reconfigure; they do not reinstall or wipe |
| **Self-tests at the end** | And says plainly what the test did **not** prove |
| **Writes `NEXT-STEPS.txt`** | The manual steps that remain, with the reasoning behind them |

Deployment is always a real Compose stack. Nothing is generated behind your back and nothing depends on DockHub staying installed.

---

## 🌐 Two networks, and why

| Network | Who is on it | Purpose |
|---|---|---|
| **`main-net`** | NGINX Proxy Manager, Portainer, and any service you want proxied | Lets the proxy reach a container **by name** — no IPs, no published ports |
| **`ai-net`** | Model providers and the services that use them | Keeps model traffic on its own bridge |

A service on `main-net` can be given a domain and a certificate. A service **not** on it is reachable only through an optional host port on your LAN — which is exactly right for anything without a login of its own, and is why several services here default to no proxy at all.

> In NGINX Proxy Manager, always point a Proxy Host at the **container name** (`jellyfin-app`), never at the server's own IP — the container and the proxy share a network, and an IP would loop back through the proxy itself.

---

## 📁 Where everything lives

One tree, so the whole host is one backup target:

```
~/docker/
├── install_dockhub.log        # the installer's log, rotated on rerun
├── .dockhub-env               # your one-time home/VPS + access answers
├── npm/                       # NGINX Proxy Manager: compose, data, certs
├── portainer/                 # compose (its data is a named volume, kept on rerun)
├── backups/
│   └── <service>/<timestamp>.tar.gz
└── <service>/                 # one folder per deployed service
    ├── docker-compose.yml
    ├── .env                   # chmod 600
    ├── deploy.log
    ├── NEXT-STEPS.txt
    └── data/                  # the service's own state
```

Runtime state stays **flat** under `~/docker/` regardless of the repo's category folders — `services/ERP/odoo/` in git deploys to `~/docker/odoo/`.

---

## 💾 Backups

The picker's **Backup** option archives a service's whole directory to `~/docker/backups/`, and **Restore** puts it back. Services with a database ship their own `backup.sh` so the dump is consistent rather than a copy of files being written to.

Two deliberate exceptions:

- **Model weights are skipped.** They are tens of gigabytes and can be downloaded again.
- **Agent data is not.** Memories, learned skills and conversations exist nowhere else. See [AI-Agents](services/AI-Agents/).

---

## 🔧 Environment variable overrides

The core installer takes no arguments — everything it publishes or pulls is an environment variable, so you can pin an image or move a port without editing the script:

| Variable | Default | |
|---|---|---|
| `NPM_IMAGE` | `jc21/nginx-proxy-manager:latest` | Pin a version: `NPM_IMAGE=jc21/nginx-proxy-manager:2.11.3` |
| `NPM_HTTP_PORT` | `80` | |
| `NPM_HTTPS_PORT` | `443` | |
| `NPM_ADMIN_PORT` | `81` | The admin interface |
| `PORTAINER_IMAGE` | `portainer/portainer-ce:latest` | |
| `PORTAINER_HTTP_PORT` | `9000` | |
| `PORTAINER_HTTPS_PORT` | `9443` | |
| `PORTAINER_EDGE_PORT` | `8000` | Edge agent |

```bash
sudo NPM_ADMIN_PORT=8081 PORTAINER_HTTP_PORT=9001 bash install_dockhub.sh
```

Values are validated before use — an image reference must look like `name:tag` and a port must be 1–65535, so a typo stops the run instead of being written into a Compose file.

Per-service settings are not env vars: each service asks its questions during deployment and records the answers in its own `~/docker/<service>/.env`.

---

## 🖥️ Supported systems

| OS family | Versions |
|---|---|
| **Debian** | 10 · 11 · 12 |
| **Ubuntu** | 20.04 · 22.04 · 24.04 (x86_64 & ARM64) |
| **Raspberry Pi OS** | ARM64 |
| **RHEL family** | CentOS · Rocky · AlmaLinux · Fedora |
| **Arch Linux** | — |
| **openSUSE** | Leap · Tumbleweed |

Detected from `/etc/os-release`, falling back to `ID_LIKE` for derivatives. If detection fails you get a manual picker — **the install never silently guesses wrong.**

**Minimum:** 2 GB RAM and 20 GB disk for the core. Individual services ask for more; the heavy ones say so before they start. A GPU is optional and only relevant to [AI](services/AI/).

---

## 🛠️ Managing and updating

Every service is a normal Compose project:

```bash
cd ~/docker/<service>
docker compose ps          # status
docker compose logs -f     # follow logs
docker compose restart
docker compose pull && docker compose up -d    # update
```

To reconfigure, rerun its `deploy.sh` — it reuses what exists. To remove one, use the picker's **Remove**, which offers to keep or wipe the data and tells you the truth about what it could not delete.

See [docs/updating.md](docs/updating.md) before updating anything that holds a database.

---

## 📖 Documentation

| | |
|---|---|
| [docs/troubleshooting.md](docs/troubleshooting.md) | The failures that actually happen — 502s, certificate errors, proxy misconfiguration |
| [docs/cloudflare-tunnel.md](docs/cloudflare-tunnel.md) | Reaching services with no public IP and no port forwarding |
| [docs/updating.md](docs/updating.md) | Updating images without losing data |
| `services/<category>/README.md` | What each category is for, and how its services differ |
| `services/<category>/<service>/README.md` | Per-service detail, gotchas, and manual steps |

---

## 🔬 How this project is built

Worth stating, because it explains why the documentation reads the way it does.

**Every service here was deployed on a real server before it was committed.** Not built from upstream's README and assumed to work — actually run, actually broken, actually fixed. The gap between the two is large and it is where most of this repository's content comes from.

That produced a few habits worth knowing about as a reader:

**The documentation records what failed.** When a script printed a command that did not exist, or a warning that pointed the wrong way, the fix includes a note saying so. You will find sentences like *"an earlier version of this file said the opposite"* — those are deliberate. A correction with its reason attached does not get re-broken later.

**Self-tests state their own limits.** A deploy that ends with "self-test passed" also tells you what the test could not check. A green tick over an unverified claim is worse than no tick.

**Numbers come from measurements.** Where the documentation gives a figure — a memory cost, a context window, a timing — it was observed on a running system, and it says so.

**Trade-offs are printed, not hidden.** Where a choice has a real cost — mounting the Docker socket, publishing a port on an API with no authentication, joining a network that widens reach — the prompt names the cost before you answer.

---

## 📌 Status

**39 of 41 services are built.** The remaining three are all in [Multi-Agent](services/Multi-Agent/) — Dify, Flowise and Langflow.

Categories, conventions and the shared library (`lib/`) are stable. Service scripts are added one at a time, each verified on real hardware before it lands.

---

## 📜 License

[MIT](LICENSE) — use it, fork it, change it.

## 🙌 Author

**Ibrahim Aljuhani** — [@IbrahimAljuhani](https://github.com/IbrahimAljuhani)

Issues and pull requests welcome. If you hit something this documentation got wrong, that is the most useful report there is.

# 🧃 OWASP Juice Shop

> ⚠️ **Deliberately vulnerable software.** Read [`services/Security-Lab/README.md`](../README.md) first — it carries the threat model this deployment is built around. This page assumes it.

[OWASP Juice Shop](https://owasp.org/www-project-juice-shop/) is OWASP's flagship insecure web application: a fully working online shop containing roughly a hundred planted vulnerabilities, from trivial to genuinely hard, with a built-in scoreboard that tracks what you've found.

One container. No database to run, no credentials to generate.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```

### 2. Deploy Juice Shop

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Security-Lab/juice-shop/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Security-Lab/juice-shop/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

You'll be asked to type **`I-UNDERSTAND`** before anything is created. Refusing leaves no directory, no container, nothing.

Then:

| Question | Notes |
|---|---|
| Port | Default `3000`. Bound to your LAN address only, never `0.0.0.0`. |
| **Enable all challenges?** | Default no. See below — this one is a real choice. |
| Memory limit | Optional, suggested `512m`. |

`deploy.sh` waits for the app to answer an actual HTTP request before reporting success, so "started" means "usable".

### The one question worth thinking about

Juice Shop ships a handful of challenges **disabled by default** — the ones that reach the filesystem rather than staying inside the application. Answering yes sets `NODE_ENV=unsafe` and enables them.

- **No (default)** — the great majority of challenges, all of them application-layer. The right choice for learning web app security.
- **Yes** — the complete set, including challenges that write outside the app. More to learn, and a wider blast radius if something goes further than you intended.

The container hardening (dropped capabilities, no new privileges, PID and memory limits) applies either way. To change your mind later: edit `JUICE_SHOP_MODE` in `~/docker/juice-shop/.env` and rerun `deploy.sh`.

---

## 🏆 Where to start

Open the scoreboard — it is itself the first challenge, but the deploy prints the direct link:

```
http://<your-server>:3000/#/score-board
```

It lists every challenge by category and difficulty (⭐ to ⭐⭐⭐⭐⭐⭐), and marks them solved as you go.

**There is no login handed to you.** Discovering accounts is part of the exercise. If you get stuck, the official companion guide [*Pwning OWASP Juice Shop*](https://pwning.owasp-juice.shop/) has hints graded from a nudge to a full walkthrough — use the nudge first.

> 💡 **Your progress resets when the container restarts.** Juice Shop keeps its database in memory and wipes it on every start as part of its self-healing design. That's usually what you want for repeat practice, but don't expect a scoreboard to survive a `docker compose restart`.

---

## 🛑 When you're done

```bash
cd ~/docker/juice-shop && docker compose stop
```

Nothing in this category restarts on boot, so stopped stays stopped. To check you haven't left a lab running:

```bash
docker ps --filter "label=dockhub.security-lab=true"
```

---

## 🛠️ Management Commands

```bash
cd ~/docker/juice-shop
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Is it running? |
| `docker compose stop` / `start` | The two you'll use most |
| `docker compose logs -f juice-shop` | Follow the app's logs |
| `docker compose pull && docker compose up -d` | Update to a newer pinned version |

To move to a newer release, bump `JUICE_SHOP_VERSION` in `.env` and rerun `deploy.sh`.

---

## 💾 Backups

**Deliberately none.** There is nothing to back up: Juice Shop wipes its own database on every start, and it holds no data of yours. The Backup option in `services.sh` is not wired up for this service, and that's intentional rather than an omission.

---

## 📌 Notes & Deviations

- **`restart: "no"`**, where every other DockHub service uses `unless-stopped`. A forgotten lab must not come back after a reboot.
- **Never joins `main-net`**, never gets a domain, never goes behind NGINX Proxy Manager. It sits on the shared `seclab-net` with the other lab targets, and publishes one LAN-bound port.
- **Hardened beyond the rest of the repo** — `cap_drop: ALL`, `no-new-privileges`, `pids_limit: 200`. The app is meant to be exploitable; the container is not meant to be escapable.
- **`read_only` is deliberately not set.** Juice Shop writes to its own working directories during file-upload and FTP challenges and rewrites its database on every restart. A read-only rootfs would need tmpfs mounts over exactly the paths the challenges target, and getting that subtly wrong breaks lessons in ways that look like bugs.
- **The image already runs as uid 65532 (nonroot)** — unusually good hygiene for a deliberately vulnerable app, and left intact.
- **No secrets file**, unlike every other service here. Juice Shop generates no admin credentials, because finding accounts is the exercise.

---

## 📜 License

OWASP Juice Shop is licensed separately (MIT — see the [official repository](https://github.com/juice-shop/juice-shop)). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of DockHub.

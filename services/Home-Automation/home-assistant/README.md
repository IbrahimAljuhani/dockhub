# 🏠 Home Assistant

Deploys [Home Assistant Container](https://www.home-assistant.io/installation/linux/#install-home-assistant-container) — the official "Container" installation type (not "Supervised" or "Home Assistant OS", which need a dedicated machine/VM, not just a container — see [Known Simplifications](#-known-simplifications-vs-supervisedos) below).

This is the only service in this repo that doesn't join the shared `main-net` network or follow the "optional host port" convention — see [Why Host Networking](#-why-host-networking--privileged) below before deploying.

---

## ⚠️ Why Host Networking + Privileged

Every other service in this repo runs on the isolated `main-net` bridge network with no elevated privileges. Home Assistant is the deliberate exception, because its own official docs require:

```yaml
network_mode: host
privileged: true
```

This is Home Assistant's own recommendation, not a shortcut taken here — without it, you lose:
- **Local-network device auto-discovery** (mDNS/SSDP/Zeroconf) — Sonos, Chromecast, many smart-home devices announce themselves this way and won't show up for auto-configuration otherwise
- **HomeKit Bridge** — needs to appear as a real device on your LAN
- **Bluetooth** (via the `/run/dbus` mount)

What this actually means for this deployment:
- **No `main-net`** — host networking replaces Compose's own network stack entirely, so this container isn't reachable by container name at all, unlike every other service here.
- **Port 8123 is always bound directly to the host** — there's no "optional host port" prompt, because there's nothing to make optional; host networking exposes it unconditionally.
- **NGINX Proxy Manager must forward to this server's own LAN IP**, not a container name — see [Reverse Proxy](#-reverse-proxy-nginx-proxy-manager) below.
- **`privileged: true` grants far broader host access** than any other service in this repo (effectively disables most of Docker's container isolation). If that's a concern for your setup, weigh it against the discovery/Bluetooth/HomeKit features above.

If you don't need auto-discovery, HomeKit, or Bluetooth, you can hand-edit `~/docker/home-assistant/docker-compose.yml` after deploying to remove `network_mode: host`/`privileged: true` and add `main-net` back — but that's an unsupported deviation from Home Assistant's own docs, not something this deploy.sh does for you.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```
Pick **`1) Install / manage core infrastructure`** from the menu it shows, it installs the full bundle automatically (skipping anything already installed).

### 2. Deploy Home Assistant

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Home-Automation/home-assistant/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Home-Automation/home-assistant/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

This is a **single-instance** service: one Home Assistant deployment per host, under `~/docker/home-assistant/`. You'll be asked whether to cap memory on the `homeassistant` container (default suggestion: `1g`). Say no and it runs uncapped.

> 💡 **To change the memory limit later**: edit `MEM_LIMIT=` in `~/docker/home-assistant/.env`, then rerun `deploy.sh` — it regenerates `docker-compose.override.yml` from whatever `.env` currently has and reapplies it with `docker compose up -d`.

There's no domain/host-port question — see [Why Host Networking](#-why-host-networking--privileged) above.

---

## 👤 First Login

Home Assistant has **no default admin account**. Visiting `http://<server-ip>:8123` for the first time runs its own setup wizard where you create your own account, name your home, and set your location (used for sun-based automations, weather, etc.).

---

## 🌐 Reverse Proxy (NGINX Proxy Manager)

> ⚠️ Unlike every other service in this repo, forward to this **server's own LAN IP**, not a container name — this container isn't on `main-net` (see [Why Host Networking](#-why-host-networking--privileged) above).

1. Open `http://<server-ip>:81`
2. Create a **Proxy Host**:
   - **Domain**: your chosen domain, e.g. `ha.example.com`
   - **Forward Hostname/IP**: this server's own LAN IP (`192.168.1.50` is a placeholder — use yours) — **not** `homeassistant`
   - **Forward Port**: `8123`
   - Enable **Websockets Support** (Home Assistant's frontend uses them for live state updates)
3. Enable **SSL** with Let's Encrypt from the UI.

### Required: tell Home Assistant to trust NPM

Home Assistant rejects requests that arrive via an unlisted reverse proxy by default. Find `main-net`'s subnet:

```bash
docker network inspect main-net --format '{{ (index .IPAM.Config 0).Subnet }}'
```

Add it to `~/docker/home-assistant/config/configuration.yaml`:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.20.0.0/16   # replace with the subnet printed above
```

Then restart: `cd ~/docker/home-assistant && docker compose restart`.

---

## 🛠️ Management Commands

```bash
cd ~/docker/home-assistant
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Check container status |
| `docker compose logs -f homeassistant` | Follow the app's logs |
| `docker compose stop` / `start` | Stop/start without removing containers |
| `docker compose pull && docker compose up -d` | Update to the latest image |

Home Assistant also has its own **in-app update mechanism** for the Core app and any integrations/add-ons you install (Settings → System → Updates), separate from the Docker image itself.

---

## 📌 Known Simplifications vs. Supervised/OS

This deploys the **Container** installation type only — the simplest of Home Assistant's four official installation methods, and the only one that fits a plain Docker Compose setup. It does **not** include:

- **Supervisor / Add-on Store** — no one-click add-ons (Node-RED, ESPHome, etc. as managed add-ons); install those as their own separate Docker containers instead, or use Home Assistant's own integrations where available.
- **Automatic OS-level updates/backups** that Home Assistant OS provides — this repo's [Backup/Restore](../../README.md) menu covers the config directory instead (see below).

If you specifically need the Supervisor/Add-on Store, Home Assistant's own docs recommend Home Assistant OS on dedicated hardware (e.g. a Raspberry Pi or a VM with no other Docker workloads) — that's a different installation model than this repo's shared-host, multi-service Docker setup.

---

## 📜 License

Home Assistant itself is licensed separately (Apache 2.0 — see the [official repository](https://github.com/home-assistant/core) for terms). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of this repo.

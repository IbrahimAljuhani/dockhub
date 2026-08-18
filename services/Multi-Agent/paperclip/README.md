# 📎 Paperclip

> *"The open-source app everyone uses to manage agents at work."* — [paperclipai/paperclip](https://github.com/paperclipai/paperclip)

Paperclip is where you **run a company of agents**: organisational hierarchy, goals, budgets, tickets and governance. It manages agents — it is not one, and it ships none. You bring the model provider.

|  |  |
|---|---|
| **Image** | `ghcr.io/paperclipai/paperclip` (official, `linux/amd64` + `linux/arm64`) |
| **Licence** | MIT — no account, no licence key, no paid tier to unlock self-hosting |
| **Port** | `3100` (container) |
| **Containers** | 2 — `paperclip-app`, `paperclip-db` (`postgres:17-alpine`) |
| **Docker socket** | **Not required** |
| **Runtime dir** | `~/docker/paperclip/` |

---

## 🚀 Install

From the menu:

```bash
bash services/services.sh
```

Or directly:

```bash
bash deploy.sh
```

You will be asked two things: whether to publish a host port for direct access, and — if not — the public domain you will point NGINX Proxy Manager at. Everything else, including both secrets, is generated.

**First run:** open the URL and create the first account. Paperclip runs in `authenticated` mode, so there is no anonymous access and no default password for anyone to find.

---

## 🔌 Giving it a model provider

Paperclip orchestrates agents; the agents need a model. Add a key to `~/docker/paperclip/.env` and rerun `deploy.sh`:

```
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
```

Both are optional and are passed straight through.

---

## 🧭 Why this deployment differs from upstream's

**We pull; upstream's own compose files build.** Both `docker/docker-compose.yml` and `docker/docker-compose.quickstart.yml` in the source tree use `build:`, which turns a deploy into a pnpm monorepo build on your server. Since the authors *also* publish the built image, this pulls it — the same rule as the rest of the catalogue.

**A real database, not the embedded one.** Paperclip can run as a single container with an embedded Postgres; upstream calls that the *local* mode and points production at a real Postgres. A server behind a reverse proxy is production.

**`./state` is a bind mount, not a named volume.** `PAPERCLIP_HOME` holds instance config, agent teams, goals and tickets — produced by you, not re-downloadable. A bind mount inside the install directory puts it where the menu's Backup option can see it. Upstream's named volume would be missed.

**Telemetry is off** (`PAPERCLIP_TELEMETRY_DISABLED=1`). Delete that line from `docker-compose.yml` to restore upstream's default.

**No host port by default.** NGINX Proxy Manager reaches `paperclip-app:3100` over `main-net`. The database never joins `main-net` — the proxy has no business seeing it.

---

## 💾 Backup

The menu's Backup option runs a `pg_dump` **and** archives the install tree, because Paperclip's state is split between Postgres and `./state`. A raw file copy of a running database is a coin toss; a dump is a consistent snapshot. Restore replays both.

---

## ⚠️ Known unknowns

Stated plainly rather than discovered later:

- **Agent runtimes.** Upstream publishes `agent-runtime-*` images alongside the app. Its own compose files mount no Docker socket, so this deployment grants none — but if running agents in practice turns out to need the daemon, that is a security decision to make deliberately (see [AI-Agents](../../AI-Agents/README.md), where OpenHands required exactly that and said so). Not yet exercised on a live server.
- **Resource appetite.** `deploy.sh` suggests a 2 GB limit for the app container as a starting point, not a measured figure.

---

## 📄 Upstream

- Repository — <https://github.com/paperclipai/paperclip>
- Site — <https://paperclip.ing/>

Licensed by its own authors (MIT). This deployment wrapper follows the same [MIT licence](../../../LICENSE) as the rest of DockHub.

---

← Back to [Multi-Agent](../README.md) · [all services](../../README.md)

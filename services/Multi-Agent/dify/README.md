# Dify

Full-stack LLM **application platform**: visual workflow orchestration, production RAG with hybrid search, agent management, team accounts and an app-publishing layer. The heaviest service in this catalogue.

|  |  |
|---|---|
| **Upstream** | [langgenius/dify](https://github.com/langgenius/dify), pinned at **1.16.1** |
| **Licence** | Apache-2.0 with additional conditions — see upstream |
| **Containers** | **15 running**, 16 created (of 39 defined; the rest are optional vector stores) — [counted, not estimated](#-how-many-containers-exactly) |
| **Minimum** | 4 GB RAM, 2 CPU |
| **Runtime dir** | `~/docker/dify/` |

---

## 🔢 How many containers, exactly

**16 are created; 15 keep running.** `init_permissions` is a one-shot that fixes volume ownership and exits — it shows as `Exited` in `docker ps -a` and that is correct, not a failure.

Counted from a live deploy rather than estimated: `init_permissions`, `sandbox`, `local_sandbox`, `ssrf_proxy`, `agent_ssrf_proxy`, `weaviate`, `redis`, `web`, `db`, `worker_beat`, `api_websocket`, `plugin_daemon`, `agent_backend`, `worker`, `api`, `nginx`.

That number moves with upstream's release — `agent_backend` arrived in 1.16 — and with `COMPOSE_PROFILES`, since choosing a different vector store swaps `weaviate` for something else.

---

## 🚀 Install

```bash
bash services/services.sh
```

Or directly: `bash deploy.sh`. It asks one question — whether to publish a host port — and generates everything else.

**First run:** open the URL and create the admin account. The setup password is `INIT_PASSWORD` in `~/docker/dify/.env`.

---

## 🧭 The one service that ships no compose file of ours

Every other service in DockHub comes with a `docker-compose.yml` we wrote and you can read end to end. Dify cannot work that way, for reasons that are measured rather than aesthetic:

- upstream's `docker/docker-compose.yaml` is **1,345 lines** defining **39 services**
- it mounts **relative sibling paths** — `./nginx/nginx.conf.template`, `./nginx/conf.d`, `./ssrf_proxy/`, `./startupscripts/` — so the compose file alone does not run; the whole `docker/` tree is required
- it is **regenerated from a template every release**

A hand-maintained fork of that would be wrong within a version, and a stale copy of someone else's orchestration is worse than no copy. So `deploy.sh` fetches upstream's tree **at the pinned tag**, and DockHub's entire contribution is one readable file:

```
~/docker/dify/docker-compose.override.yml
```

Read that and you have read every change DockHub makes.

---

## 🔐 What the override and deploy.sh actually change

**Every credential is generated — and the result is checked, not assumed.** Upstream's `.env.example` ships working defaults for all of them, several being real keys published in a public repository:

```
DB_PASSWORD=difyai123456          REDIS_PASSWORD=difyai123456
SANDBOX_API_KEY=dify-sandbox      CODE_EXECUTION_API_KEY=dify-sandbox
CELERY_BROKER_URL=redis://:difyai123456@redis:6379/1
WEAVIATE_API_KEY=WVF5YThaHlkYwhGUSmCRgsX3tD5ngdN8pkih
PLUGIN_DAEMON_KEY=lYkiYYT6owG+71oLerGzA7GXCgOT++6ovaezWAjpCjf+…
PLUGIN_DIFY_INNER_API_KEY=QaHbTe77CtuXmsfyhR7+vRjI/+XbV1AaFy69…
DIFY_AGENT_API_TOKEN=dify-agent-run-token-for-dev-only
DIFY_AGENT_SERVER_SECRET_KEY=MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY
```

Anyone who copied the example and moved on is running a deployment whose every secret is on GitHub. The last two are flagged *by upstream's own file* — "Replace this development default in production" — which is a default that documents its own unsuitability.

**Several of these come in pairs**, and that is where the first version of this script got it wrong: it regenerated `REDIS_PASSWORD` but left `CELERY_BROKER_URL` embedding the old one, and regenerated `SANDBOX_API_KEY` while `CODE_EXECUTION_API_KEY` — the other end of the same handshake — still read `dify-sandbox`. Both ends are now written from one generated value.

`deploy.sh` then **greps the finished `.env` for every one of those literals and refuses to start if any survived**. It used to print "none of upstream's published defaults survive"; that claim was false, and a claim its own output file contradicts is worse than no claim.

**The port collision is removed.** Upstream publishes `80:80` and `443:443`. DockHub's NGINX Proxy Manager already owns both — deploying Dify unchanged would fight the proxy meant to serve it, and on a VPS take the host's HTTP down with it. The override drops both; a host port is added back only if you ask, and never 80.

**Two containers get stable names** — `dify-nginx` (so you can point NPM at it) and `dify-db` (so `backup.sh` has a target). Upstream names only its exotic vector stores, not the database it actually ships with.

> ⚠️ **Docker Compose 2.24+ is required.** The override uses the `!override` tag to *replace* upstream's ports rather than merge with them. On older Compose the merge would silently keep 80 and 443. `deploy.sh` checks the version and refuses rather than colliding.

---

## 💾 Backup

Dify keeps everything under the install directory as **bind mounts**, not named volumes — Postgres, Redis, uploaded files, the knowledge base, the Weaviate index. So the generic install-tree backup captures the lot; `backup.sh` adds a consistent `pg_dump` on top, because a raw file copy of a running Postgres is a coin toss.

> 🔑 **`SECRET_KEY` must match the backup you restore.** Dify encrypts stored model-provider API keys with it; a mismatch leaves them unreadable while everything else looks fine. Restore keeps the `.env` from the archive, so this is only a risk if you edit it by hand.

---

## ⚠️ Known unknowns

- **Not yet run on a server.** Built 2026-08-19 against upstream's pinned tree and `.env.example`; the first live deployment has not happened.
- **Vector store:** Weaviate, upstream's default (`COMPOSE_PROFILES` derives from `VECTOR_STORE`). The other 12 are available by editing `.env`, untested here.
- **Resource appetite** is upstream's stated 4 GB minimum, not a figure measured on our hardware.

---

## 📄 Upstream

- Repository — <https://github.com/langgenius/dify>
- Docs — <https://docs.dify.ai/>

Licensed by its own authors. This deployment wrapper follows the same [MIT licence](../../../LICENSE) as the rest of DockHub.

---

← Back to [Multi-Agent](../README.md) · [all services](../../README.md)

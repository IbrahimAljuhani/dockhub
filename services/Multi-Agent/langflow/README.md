# Langflow

Visual builder for agents and flows, on LangChain/LangGraph — with **custom Python components** inside the visual surface, which is what separates it from the drag-and-drop builders. MIT licensed.

|  |  |
|---|---|
| **Image** | `langflowai/langflow:1.11.4` (official, pinned) |
| **Containers** | 2 — `langflow`, `langflow-db` |
| **Database** | Postgres — upstream's own reference deployment |
| **Port** | `7860` in the container |
| **Runtime dir** | `~/docker/langflow/` |
| **Status** | ✅ deployed, backed up and restored on a real server, 2026-08-19 |

---

## 🚀 Install

```bash
bash services/services.sh
```

Or directly: `bash deploy.sh`.

**First run is slow** — Langflow imports its whole component library at startup, so expect minutes rather than seconds on a small server. `deploy.sh` waits up to four minutes before warning.

Your login is generated and printed at the end of the deploy. It is also in `~/docker/langflow/.env` as `LANGFLOW_SUPERUSER` / `LANGFLOW_SUPERUSER_PASSWORD`.

> The password in `.env` is what the superuser account was **created with**. Whether Langflow re-applies `LANGFLOW_SUPERUSER_PASSWORD` on every restart, or only on the first one, is **not stated anywhere in upstream's documentation** — so if you change the password in the UI, do not assume the change survives a redeploy until you have tested it on your own instance. (An earlier version of this README asserted it does survive. That was an assumption, not a finding, and it has been withdrawn.)

---

## 🧭 How this differs from upstream's own compose

Upstream ships a two-service `docker_example/docker-compose.yml`, and this deployment follows its shape. The differences are these:

**The database password is not `langflow`.** Upstream hardcodes the entire connection string — `postgresql://langflow:langflow@postgres:5432/langflow` — with `POSTGRES_PASSWORD: langflow` beside it. Not a placeholder, not a `${VAR}`: a literal published credential. `deploy.sh` generates one and builds the URL from it, then refuses to start if the published value survived.

**Postgres is not published on the host.** Upstream maps `5432:5432`. On a machine running this catalogue that is both a collision — several services here bring their own Postgres — and an exposure, since the database would answer on every interface using the password above. Here it has no host port and sits on a private network whose only other member is the app.

**No host port unless you ask, and the app's is `7860`** (nothing else in this catalogue uses it). Upstream maps it unconditionally.

**A real healthcheck, and `depends_on: condition: service_healthy`.** Upstream's compose has no healthcheck at all and a bare `depends_on: postgres`, which waits for the container to be *created*, not for Postgres to accept connections — so the app can lose its first connection attempt on a cold start.

**`postgres:17-alpine`, where upstream pins `postgres:16-trixie`.** Their comment explains that pin: a moving Debian base can update the OS under an existing data volume, and glibc collation changes can corrupt indexes. The concern is real, but it argues for *pinning*, not for Debian — and this catalogue standardises on `postgres:17-alpine`, equally pinned, alongside [Paperclip](../paperclip/) and [Flowise](../flowise/). What matters is not switching libc under an **existing** volume, so don't move a live `langflow-db` between alpine and Debian-based tags in either direction.

**Telemetry off** via `DO_NOT_TRACK`, which upstream leaves on.

**It joins `models-net`**, so a flow can point at an [Ollama](../../AI/ollama/), [llama.cpp](../../AI/llama-cpp/) or [LocalAI](../../AI/localai/) deployed from the AI category **by container name** — `http://ollama:11434`, with no published port on either side. Upstream's compose has no equivalent, because upstream does not assume a model provider next door. It is `models-net` and **not** `ai-net` on purpose: `ai-net` also carries [OpenHands](../../AI-Agents/openhands/), which has no authentication and holds the Docker socket — and this service exists to run code that arrived inside a flow. See [the category README](../README.md).

> Verified live 2026-08-19: from inside the container, `curl http://ollama:11434/api/tags` returns the model list — no port published on either side.

**Capabilities dropped — on *both* containers.** `no-new-privileges`, `cap_drop: [MKNOD, NET_RAW, AUDIT_WRITE]`, `pids_limit`. Added to `langflow-db` too, because a hardened app beside a database running with Docker's full default grant was an asymmetry with no reason behind it. Safe for Postgres specifically: the official image drops privileges with `gosu`, which calls `setuid()` while still root rather than exec'ing a setuid binary, so `no-new-privileges` cannot interfere — and everything the entrypoint needs (`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`) is left in place.

---

## 🧰 Two things you can set by hand in `.env`

Neither is prompted — the deploy interview is long enough, and both are better decided after you have run the service than before.

| key | effect |
|---|---|
| `LANGFLOW_VERSION` | the image tag. Changing it and rerunning is an **upgrade**, and `deploy.sh` now notices: it prints the old and new tags, warns that startup migrations are one-way, and refuses to continue without a `y`. |
| `DOCKHUB_DB_MEM_LIMIT` | a memory ceiling for `langflow-db` (e.g. `512m`). Left unset by default on purpose: Postgres that hits a hard ceiling is not slowed down, it is **OOM-killed mid-write**, and how much it needs depends on the largest restore you will ever run — which nobody knows at deploy time. |

---

## 🩺 `/health_check`, not `/health` — a trap upstream documents

Langflow serves both. `/health` is answered by **uvicorn, before Langflow finishes initialising**, so a probe on it reports ready while the application is still starting. That is worse than having no probe, because it converts a wait into a false pass. `/health_check` reports the database and chat services.

The probe uses `curl`, not `wget`: this image is RHEL UBI-based and ships curl. (The opposite of [Flowise](../flowise/), which is Alpine and ships wget — an image detail that has to be checked per service, not assumed.)

---

## 🔐 Secrets — and one that has to be the right *shape*

Three are generated on first deploy: the Postgres password, the superuser password, and `LANGFLOW_SECRET_KEY`.

The last one is not like the others. It encrypts every credential you store in Langflow — global variables of type *Secret*, which is where your model-provider API keys live — using **Fernet**, and Fernet requires a key that decodes to **exactly 32 bytes**. DockHub's two standard secret generators both fail that test:

| generator | length | decodes to | |
|---|---|---|---|
| `generate_secret_hex 32` | 64 chars | 48 bytes | ❌ rejected |
| `generate_secret 32` | 32 chars | 24 bytes | ❌ rejected |
| `generate_secret_urlsafe 32` | 43 chars | 32 bytes | ✅ valid |

So this service prompted a third generator in `lib/common.sh`. It produces exactly what Langflow's own documentation tells you to generate with `python -c "from secrets import token_urlsafe; print(token_urlsafe(32))"`, and `deploy.sh` asserts the shape of what it wrote rather than trusting it.

Why it matters that the key is set at all: leave `LANGFLOW_SECRET_KEY` unset and Langflow **generates one for you** and keeps it in the config directory. That works until the day you rebuild `.env` or the config directory by hand, at which point every stored credential becomes ciphertext nobody can read. Set explicitly, the key lives in `.env`, inside the install tree, and therefore inside every backup.

---

## 🔓 Three auth settings, all set explicitly

`LANGFLOW_AUTO_LOGIN=True` does not mean "log in automatically". It means **there is no login**: anyone who reaches the port is the superuser. Current versions default it to `False`, older ones to `True`.

`LANGFLOW_ENABLE_SIGNUP` **defaults to `True`**, which leaves `POST /api/v1/users/` open — an unauthenticated endpoint that creates rows in your database for anyone who can reach the port. It is less alarming than it sounds, because `LANGFLOW_NEW_USER_IS_ACTIVE` defaults to `False`, so a self-registered account exists but is **inactive** and cannot sign in until a superuser activates it. The default is therefore "anyone can create a dormant account", not "anyone gets in".

| | set to | upstream default |
|---|---|---|
| `LANGFLOW_AUTO_LOGIN` | `False` | `False` now, `True` in older versions |
| `LANGFLOW_ENABLE_SIGNUP` | `False` | **`True`** |
| `LANGFLOW_NEW_USER_IS_ACTIVE` | `False` | `False` |

All three are pinned here rather than inherited. A DockHub deployment has one operator who already holds the superuser account, so an open registration endpoint buys nothing and costs an unauthenticated write — and a security-relevant default is not a value to take from whichever image tag you happen to land on. `AUTO_LOGIN` has already moved once.

**To add a second user:** sign in as the superuser and create the account, then activate it. Signup does not need to be turned back on.

---

## ⚠️ Custom Components execute Python

Langflow's **Custom Component** node runs Python inside the app container — that is the feature, and it is why Langflow is the most capable builder in this category. It also means **a shared flow is a program**, and importing one you did not read is the same act as running a script you did not read.

Read [the category threat model](../README.md) before pointing this at anything you care about.

---

## 💾 Backup

`backup.sh` dumps Postgres with `pg_dump` before archiving, then on restore drops the database, recreates it, and replays the dump in a single transaction with `ON_ERROR_STOP`. The encryption key rides along in `.env` inside the same archive, so restored credentials still decrypt.

---

## 📌 Version

Pinned to `1.11.4`. Checked against the registry rather than assumed: **`latest` and `1.11.4` carry the same digest**, and the newer `1.12.0.devNN` builds are excluded from `latest` — so here `latest` behaves exactly as it should. (That is worth stating because [Flowise](../flowise/) in the same category does the opposite: its `latest` is an *older* build than its newest release.) The pin is for reproducibility, not a workaround.

To move version: edit `LANGFLOW_VERSION` in `~/docker/langflow/.env` and rerun.

---

## ⚠️ Known unknowns

- **Memory** — `deploy.sh` suggests a 2 GB limit, higher than the rest of the category, because Langflow loads its full component library at startup. Not a measured figure.
- **`LANGFLOW_SSRF_PROTECTION_ENABLED` and `LANGFLOW_STORE_ENVIRONMENT_VARIABLES`** exist in upstream's `.env.example` and are left at their defaults here. Worth revisiting once the service has been exercised.

---

## 📄 Upstream

- Repository — <https://github.com/langflow-ai/langflow>
- Docs — <https://docs.langflow.org/>
- Environment variables — <https://docs.langflow.org/environment-variables>

Licensed by its own authors (MIT). This deployment wrapper follows the same [MIT licence](../../../LICENSE) as the rest of DockHub.

---

← Back to [Multi-Agent](../README.md) · [all services](../../README.md)

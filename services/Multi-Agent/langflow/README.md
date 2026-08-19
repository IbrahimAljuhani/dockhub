# Langflow

Visual builder for agents and flows, on LangChain/LangGraph — with **custom Python components** inside the visual surface, which is what separates it from the drag-and-drop builders. MIT licensed.

|  |  |
|---|---|
| **Image** | `langflowai/langflow:1.11.4` (official, pinned) |
| **Containers** | 2 — `langflow`, `langflow-db` |
| **Database** | Postgres — upstream's own reference deployment |
| **Port** | `7860` in the container |
| **Runtime dir** | `~/docker/langflow/` |

---

## 🚀 Install

```bash
bash services/services.sh
```

Or directly: `bash deploy.sh`.

**First run is slow** — Langflow imports its whole component library at startup, so expect minutes rather than seconds on a small server. `deploy.sh` waits up to four minutes before warning.

Your login is generated and printed at the end of the deploy. It is also in `~/docker/langflow/.env` as `LANGFLOW_SUPERUSER` / `LANGFLOW_SUPERUSER_PASSWORD`.

> Langflow creates the superuser **once**, at first start. If you change the password in the UI, the value in `.env` goes stale — it is what the account was created with, not what it currently is.

---

## 🧭 How this differs from upstream's own compose

Upstream ships a two-service `docker_example/docker-compose.yml`, and this deployment follows its shape. The differences are these:

**The database password is not `langflow`.** Upstream hardcodes the entire connection string — `postgresql://langflow:langflow@postgres:5432/langflow` — with `POSTGRES_PASSWORD: langflow` beside it. Not a placeholder, not a `${VAR}`: a literal published credential. `deploy.sh` generates one and builds the URL from it, then refuses to start if the published value survived.

**Postgres is not published on the host.** Upstream maps `5432:5432`. On a machine running this catalogue that is both a collision — several services here bring their own Postgres — and an exposure, since the database would answer on every interface using the password above. Here it has no host port and sits on a private network whose only other member is the app.

**No host port unless you ask, and the app's is `7860`** (nothing else in this catalogue uses it). Upstream maps it unconditionally.

**A real healthcheck, and `depends_on: condition: service_healthy`.** Upstream's compose has no healthcheck at all and a bare `depends_on: postgres`, which waits for the container to be *created*, not for Postgres to accept connections — so the app can lose its first connection attempt on a cold start.

**`postgres:17-alpine`, where upstream pins `postgres:16-trixie`.** Their comment explains that pin: a moving Debian base can update the OS under an existing data volume, and glibc collation changes can corrupt indexes. The concern is real, but it argues for *pinning*, not for Debian — and this catalogue standardises on `postgres:17-alpine`, equally pinned, alongside [Paperclip](../paperclip/) and [Flowise](../flowise/). What matters is not switching libc under an **existing** volume, so don't move a live `langflow-db` between alpine and Debian-based tags in either direction.

**Telemetry off** via `DO_NOT_TRACK`, which upstream leaves on.

**Capabilities dropped** — `no-new-privileges`, `cap_drop: [MKNOD, NET_RAW, AUDIT_WRITE]`, `pids_limit`.

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

## 🔓 `LANGFLOW_AUTO_LOGIN` — set to `False`, explicitly

`LANGFLOW_AUTO_LOGIN=True` does not mean "log in automatically". It means **there is no login**: anyone who reaches the port is the superuser.

Current versions default it to `False`. Older ones defaulted to `True`. This deployment sets it explicitly, because the difference between "authenticated" and "wide open" is not a value to inherit from whichever image tag you happen to land on.

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

- **Not yet live-tested.** This note comes down after a real deploy on a real server. Everything above is derived from upstream's own compose file, Dockerfile and documentation, read literally — not from a running instance.
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

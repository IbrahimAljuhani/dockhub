# Flowise

Drag-and-drop builder for LLM apps and agent flows, on LangChain. The fastest thing in this category to get moving with, and still the lightest — **two containers**, against Dify's nine.

|  |  |
|---|---|
| **Image** | `flowiseai/flowise:3.1.4` (official, pinned) |
| **Containers** | 2 — `flowise`, `flowise-db` |
| **Database** | Postgres — **not by preference**, see [below](#-postgres-because-sqlite-does-not-start) |
| **Port** | `3000` in the container |
| **Runtime dir** | `~/docker/flowise/` |

---

## 🚀 Install

```bash
bash services/services.sh
```

Or directly: `bash deploy.sh`.

**First run:** open the URL and create your own account. Flowise has no default login — current versions use a full account system (registration, JWT sessions, password reset), not the `FLOWISE_USERNAME`/`FLOWISE_PASSWORD` basic auth older guides describe.

---

## 🧭 How this differs from upstream's own compose

**Your data lives inside the install directory.** Upstream mounts `~/.flowise` — the invoking user's *home*, outside anything DockHub manages. Since every backup here archives `~/docker/<service>/`, that layout would produce archives containing none of your flows, credentials or uploads while reporting success. Here it is `./data`.

**No host port unless you ask, and never 3000.** Upstream publishes `${PORT}:${PORT}` with `PORT=3000` — which in this catalogue already belongs to [Open WebUI](../../AI/open-webui/), and is why [OpenHands](../../AI-Agents/openhands/) sits on 3001. `deploy.sh` suggests 3200.

**Postgres, with a generated password.** Upstream's `.env.example` sets `DATABASE_TYPE=postgres` with the literal `DATABASE_PASSWORD=mypassword` and *no database container to talk to* — so following it gives you a published password and a service that cannot connect. Here there is a real `flowise-db`, on a private network of its own, with a password generated on first deploy.

**It joins `ai-net`**, so a flow can point at an [Ollama](../../AI/ollama/), [llama.cpp](../../AI/llama-cpp/) or [LocalAI](../../AI/localai/) deployed from the AI category **by container name** — `http://ollama:11434` in the node's Base URL, with no published port on either side. Upstream's compose has no equivalent, because upstream does not assume a model provider next door.

> Verified live 2026-08-19: from inside the container, `curl http://ollama:11434/api/tags` returns the model list — no port published on either side.

**Every file path points inside the volume.** Upstream's example leaves `LOG_PATH`, `BLOB_STORAGE_PATH` and the rest as `/your_*_path` placeholders. Unset, logs and uploads land in the image's ephemeral layer, where replacing the container destroys them.

**Capabilities dropped — on *both* containers.** `no-new-privileges`, `cap_drop: [MKNOD, NET_RAW, AUDIT_WRITE]`, `pids_limit`. Warranted for the app more than in most of the catalogue (see below); added to `flowise-db` too, because a hardened app beside a database running with Docker's full default grant was an asymmetry with no reason behind it. Safe for Postgres specifically: the official image drops privileges with `gosu`, which calls `setuid()` while still root rather than exec'ing a setuid binary, so `no-new-privileges` cannot interfere — and everything the entrypoint needs (`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`) is left in place.

---

## 🧰 Two things you can set by hand in `.env`

Neither is prompted — the deploy interview is long enough, and both are better decided after you have run the service than before.

| key | effect |
|---|---|
| `FLOWISE_VERSION` | the image tag. Changing it and rerunning is an **upgrade**, and `deploy.sh` now notices: it prints the old and new tags, warns that startup migrations are one-way, and refuses to continue without a `y`. |
| `DOCKHUB_DB_MEM_LIMIT` | a memory ceiling for `flowise-db` (e.g. `512m`). Left unset by default on purpose: Postgres that hits a hard ceiling is not slowed down, it is **OOM-killed mid-write**, and how much it needs depends on the largest restore you will ever run — which nobody knows at deploy time. |

---

## 🔐 Secrets

Six are generated on first deploy, and the deployment refuses to start if a published upstream default survived:

| | |
|---|---|
| `FLOWISE_SECRETKEY_OVERWRITE` | **encrypts the credential store** — every model-provider API key you paste into a flow. Upstream's example ships it as the literal `myencryptionkey`. |
| `JWT_AUTH_TOKEN_SECRET` · `JWT_REFRESH_TOKEN_SECRET` | session signing |
| `EXPRESS_SESSION_SECRET` · `TOKEN_HASH_SECRET` | session and token hashing |
| `POSTGRES_PASSWORD` | the database. Upstream's example ships the literal `mypassword`. |

The four auth secrets are **absent from upstream's example entirely**. An unset signing secret is not "no auth" — it is auth signed with whatever the application falls back to, identically on every install that also left it unset.

> 🔑 **Keep `FLOWISE_SECRETKEY_OVERWRITE` with your backups.** Restore the data without it and every stored credential is unreadable ciphertext. It lives in `~/docker/flowise/.env`, which the backup archives — so this only bites if you rebuild `.env` by hand.

---

## ⚠️ Custom Tools execute JavaScript

This is the thing to understand before running a flow you did not write.

Flowise's **Custom Tool** node runs JavaScript, and upstream's own configuration allows those tools to `require('fs')` — see `TOOL_FUNCTION_BUILTIN_DEP=crypto,fs`. The external dependency allow-list includes database drivers (`pg`, `mysql2`, `mongodb`, `ioredis`). So a tool can read and write the container filesystem and open database connections.

That is the product, not a defect — it is what makes Flowise useful. But it means **a shared flow is a script**, and importing one you did not read is the same act as running a script you did not read.

**Upstream's defaults are good here, and worth naming:** `HTTP_SECURITY_CHECK`, `PATH_TRAVERSAL_SAFETY`, `CUSTOM_MCP_SECURITY_CHECK` and `OAUTH2_SECURITY_CHECK` all default to *on*, and `ALLOW_BUILTIN_DEP` defaults to *off* so only the named modules are reachable. DockHub changes none of them.

Read [the category threat model](../README.md) before pointing this at anything you care about.

---

## 🐘 Postgres, because SQLite does not start

This service was designed as one container on SQLite. It does not work, and the reason is worth writing down because nothing in configuration can route around it.

On **both** `3.1.4` and `latest`, startup ends here:

```
TypeError: this.db.exec is not a function
  at new SQLiteStore (connect-sqlite3/lib/connect-sqlite3.js:56)
  at initializeDBClientAndStore (enterprise/.../SessionPersistance.js:96)
```

Reading the failing function settles it. Flowise picks its **session store** from `DATABASE_TYPE`, which defaults to `sqlite`, and the sqlite branch requires `connect-sqlite3`. The image ships that package without a working `sqlite3` under it, so `this.db` is not a database handle.

The decisive detail is what the log says *immediately before* the crash:

```
📦 [server]: Data Source initialized successfully
🔄 [server]: Database migrations completed successfully
```

Flowise's **main** SQLite database works fine. Only the session store is broken, and only because it reaches for a different sqlite library than TypeORM does. There is no `.env` value that repairs that.

The `postgres` branch of the same function uses `connect-pg-simple`, which the image *does* carry. So this deployment costs a second container. The "one container" claim was corrected rather than the deployment being left broken to protect it.

**Confirmed on a live server (2026-08-19).** The line that used to be the crash is now just a log entry:

```
🔑 [server]: Encryption key initialized successfully
🔐 [server]: Auth initialized successfully
⚡️ [server]: Flowise Server is listening at :3000
```

---

## 💾 Backup

`backup.sh` dumps Postgres with `pg_dump` before archiving, then on restore drops the database, recreates it, and replays the dump in a single transaction with `ON_ERROR_STOP`. (Without the drop, the replay lands on the volume `restore_service_generic` has *already* restored — and `psql < file` exits 0 even when every statement failed.)

**Logs are excluded from the archive.** `LOG_PATH` points at `./data/logs` so logs survive a container replacement — which also meant every log line rode inside every archive, so ten backups held ten copies of a file that only grows. `backup.sh` sets `BACKUP_EXCLUDE_PATHS="data/logs"`, which drops it from the staging *copy*; the live directory is untouched and `docker logs flowise` is unaffected. ([Langflow](../langflow/) never needed this — it sets no `LOG_PATH`, so its logs go to stdout and were never in the archive.)

> 🔑 **The credentials and the key travel together.** Your model-provider API keys are stored encrypted *in Postgres*, and the key that decrypts them is a file under `./data`. One archive holds both, which is the point — restoring a database dump against a different install's data directory leaves credentials that decrypt to nothing.

---

## 📌 Pinned to 3.1.4, and `latest` is not a synonym for it

The first live deploy used `:latest` and crash-looped:

```
TypeError: this.db.exec is not a function
  at new SQLiteStore (connect-sqlite3/lib/connect-sqlite3.js:56)
  at initializeDBClientAndStore (enterprise/.../SessionPersistance.js:96)
```

**Pinning did not fix that**, and this section used to imply it would. 3.1.4 crashed identically, and the module-resolution errors that came with it are in *both* images. The crash was the SQLite session store, and only Postgres fixed it. Recorded rather than quietly rewritten, because "pin it and see" was a reasonable move that turned out not to be the answer.

The pin is kept anyway, for a reason that survives independently. Checked against the registry rather than assumed: **`3.1.4` and `latest` have different digests, and `3.1.4` was pushed fifteen minutes after `latest`.** So on this image `latest` is an *earlier* build than the newest tagged release — not a pointer to it. Deploying `latest` here means deploying something older than the release you think you asked for, and a redeploy months from now silently lands on a different image than the one this catalogue was tested against.

`deploy.sh` also migrates an existing `.env` that still says `latest` — a value *it* wrote, not one you chose. A version you pinned yourself is left alone.

To move version: edit `FLOWISE_VERSION` in `~/docker/flowise/.env` and rerun.

---

## ⚠️ Known unknowns

- **The AWS Bedrock node does not load, on this image, in both database modes.** Startup logs a `Cannot find module '@smithy/eventstream-codec'` stack trace from `@langchain/community/dist/llms/bedrock`. It is **not** fatal — `Nodes pool initialized successfully` follows it, and the server starts normally — but that one node is unavailable. It is a packaging fault inside the published image, not something this deployment configures; every other provider node loads. Left as-is rather than papered over, so the stack trace in your logs has an explanation.
- **Memory** — `deploy.sh` suggests a 1 GB limit for the app, matching the category README's figure. Postgres adds its own footprint on top, and neither number is measured.
- **Upgrading from the SQLite layout** is handled: `deploy.sh` detects a compose file with no `flowise-db`, keeps it as `docker-compose.yml.pre-postgres`, replaces it, and generates the database credentials into your existing `.env`. Nothing is lost, because the SQLite deployment never reached the point of storing anything.

---

## 📄 Upstream

- Repository — <https://github.com/FlowiseAI/Flowise>
- Docs — <https://docs.flowiseai.com/>

Licensed by its own authors. This deployment wrapper follows the same [MIT licence](../../../LICENSE) as the rest of DockHub.

---

← Back to [Multi-Agent](../README.md) · [all services](../../README.md)

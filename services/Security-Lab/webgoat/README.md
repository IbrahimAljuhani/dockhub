# 🐐 OWASP WebGoat

> ⚠️ **Deliberately vulnerable software.** Read [`services/Security-Lab/README.md`](../README.md) first — it carries the threat model this deployment is built around.

[WebGoat](https://owasp.org/www-project-webgoat/) is OWASP's guided trainer. Unlike [Juice Shop](../juice-shop/), which drops you into a broken app and lets you hunt, WebGoat teaches lesson by lesson: each one explains the vulnerability class, shows the relevant code, then asks you to exploit it.

**Pick WebGoat if you're learning a topic. Pick Juice Shop if you're practising the hunt.** They complement each other; most people use both.

---

## 🐺 WebWolf is not optional

WebGoat ships with a second application called **WebWolf**, and this is the thing most guides get wrong — they publish port 8080, never mention 9090, and several lessons then quietly never complete.

WebWolf is the **attacker-side** half. Lessons where you have to receive a request, catch exfiltrated data, host a malicious file, or read an email land there. Without it those lessons have nowhere to send anything.

Both run inside **one container** (`webgoat/webgoat`) and need **a port each**. This deployment publishes both and, more importantly, **checks both answered** before reporting success.

> 📌 The old two-image `webgoat/goatandwolf` split you'll find in older tutorials was last built in **2021**. Don't use it.

---

## 📥 Installation

### 1. Install prerequisites (if not already done)

```bash
curl -fsSL -o install_dockhub.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/install_dockhub.sh
sudo bash install_dockhub.sh
```

### 2. Deploy WebGoat

```bash
curl -fsSL -o deploy.sh \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Security-Lab/webgoat/deploy.sh
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/Security-Lab/webgoat/docker-compose.yml
bash deploy.sh
```

> ⚠️ **Do not run as root.** Your user must be in the `docker` group.

You'll type **`I-UNDERSTAND`** before anything is created, then:

| Question | Notes |
|---|---|
| WebGoat port | Default `8080` |
| WebWolf port | Default `9090` |
| **Timezone** | Defaults to this host's. See below — it isn't cosmetic. |
| Memory limit | Optional, suggested `1g` — this is a JDK image |

### Why it asks about the timezone

Several lessons compare timestamps. The image's own default is `Europe/Amsterdam`, and if the container's clock sits in a different zone than yours, those lessons fail in ways that look like bugs rather than misconfiguration. `deploy.sh` reads your host's timezone and offers it as the default.

---

## 👤 First visit

```
http://<your-server>:8080/WebGoat/
```

**Mind the `/WebGoat/` path** — neither app serves the root URL, and a bare `http://server:8080/` gives you nothing useful.

There's no default login. Register an account on first visit; it's local to this deployment and throwaway.

> 🔑 **Sign in to WebWolf with the *same username*** you registered in WebGoat. That's how the two halves associate your traffic — a different username means the lesson never sees what you sent.

---

## 🛑 When you're done

```bash
cd ~/docker/webgoat && docker compose stop
```

Nothing here restarts on boot. To check you haven't left a lab running:

```bash
docker ps --filter "label=dockhub.security-lab=true"
```

---

## 🩺 A lesson won't complete

Work through these in order:

| Check | Rules out |
|---|---|
| Does `http://<server>:9090/WebWolf/` load? | The missing-WebWolf problem — by far the commonest |
| Are you logged into WebWolf as the **same user** as WebGoat? | The two halves not associating your traffic |
| Does the timezone in `.env` match yours? | Timestamp-comparing lessons |
| `docker compose logs -f webgoat` | The app actually erroring |

`deploy.sh` checks the first of these automatically and names WebGoat or WebWolf specifically when one doesn't answer.

---

## 🛠️ Management Commands

```bash
cd ~/docker/webgoat
```

| Command | Purpose |
|---|---|
| `docker compose ps` | Is it running? |
| `docker compose stop` / `start` | The two you'll use most |
| `docker compose logs -f webgoat` | Both apps log here — it's one container |

To move to a newer release, bump `WEBGOAT_VERSION` in `.env` and rerun `deploy.sh`.

> 📌 `v2025.3` (March 2025) is genuinely the **latest release**. Development continues on `master`, but upstream hasn't cut a release since — so the pinned image is current, not neglected.

---

## 💾 Backups

**Your lesson progress now persists**, in a named volume — and it did not until 2026-08-20.

That earlier behaviour was a bug this README described as a decision. It used to say *"there is nothing of yours to lose"*, and that was wrong: WebGoat writes its HSQLDB **to disk**, at `/home/webgoat/.webgoat-<version>/`, and the compose file mounted nothing there. Every `docker compose down` — and every container recreate, including the ones `deploy.sh` performs when it updates the compose file — silently took your completed lessons with it.

The distinction matters because [Juice Shop](../juice-shop/) really *does* reset by design: its database is in memory and it wipes it on every start as part of its self-healing. WebGoat never chose that. It simply had nowhere to write.

| | |
|---|---|
| **Volume** | `webgoat-data-<version>`, mounted at `/home/webgoat/.webgoat-<version>` |
| **Backed up by** | the menu's ordinary **4) Backup** — the generic path archives named volumes |
| **On a version bump** | a **clean** database. The mount path contains the version, so the new volume is new. Your old progress stays in the old volume and comes back if you return to that tag. |

> ⚠️ **Do not "simplify" this to `/home/webgoat`.** `webgoat.jar` lives in that directory, and a volume over it hides the application from its own `ENTRYPOINT` — the container would stop starting at all.

---

## 📌 Notes & Deviations

- **Both ports published, and both verified.** Publishing 8080 and forgetting 9090 is the defining mistake with WebGoat, and its symptom — a few lessons that silently never finish — is very hard to trace back.
- **`WEBGOAT_HOST` / `WEBWOLF_HOST` are set to this host's LAN address.** They are **advertised hostnames**, not bind addresses: WebGoat builds the links that move you between the two apps from them. Left unset they resolve to `localhost`, which only works if your browser is on the server itself.
- **This image does *not* bind to localhost internally**, contrary to widely repeated advice. Its Dockerfile ends `--server.address 0.0.0.0`. The `server.address` gotcha applies to running the JAR **standalone**, outside Docker.
- **`pids_limit: 512`**, far above Juice Shop's 200. Every Java thread counts against that limit, and some lessons compile Java at runtime — a low cap produces errors that look like broken lessons.
- **The image already runs as a non-root user** (`USER webgoat` in its Dockerfile), left intact.
- **`restart: "no"`**, the shared `seclab-net`, never `main-net`, never proxied — the Security-Lab convention.

---

## 🩺 The image's healthcheck is broken upstream, and this deployment replaces it

If you have run WebGoat in Docker before and wondered why the container always shows **unhealthy** while the application works perfectly — this is why. The image ships:

```
HEALTHCHECK --interval=5s --timeout=3s
  CMD curl --fail http://localhost:8080/WebGoat/actuator/health
```

**and the image does not contain `curl`.** Measured on a running container:

```
"FailingStreak": 203
"Output": "/bin/sh: 1: curl: not found\n"
```

Meanwhile the very same endpoint answers `200` with `{"status":"UP"}`. The probe was never testing the application; it was failing to start.

This deployment overrides it with `wget`, which *is* in the image, against the same endpoint — plus a 90-second `start_period`, because the JVM needs about eighteen seconds to boot and upstream sets no start period either.

> This is an upstream packaging bug, not something DockHub causes. It affects every `webgoat/webgoat` container, however it is run.

---

## 📜 License

WebGoat is licensed separately (GPL-2.0 — see the [official repository](https://github.com/WebGoat/WebGoat)). This deployment wrapper follows the same [MIT license](../../../LICENSE) as the rest of DockHub.

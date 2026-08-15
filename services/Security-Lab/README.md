# ⚠️ Security-Lab

Deliberately vulnerable software, for learning application security on targets you are allowed to attack.

**This category is different from every other one in DockHub.** Everything else here is meant to hold your data and stay running. These are meant to be broken, and then stopped.

Read this page once. The three service READMEs assume it.

---

## 🎯 What these are for

Practising web application security — finding and exploiting SQL injection, XSS, broken access control, insecure deserialisation — against systems whose owners have explicitly published them for that purpose.

**They are not for practising against anything else.** Attacking systems you don't own or lack written authorisation to test is a crime in most jurisdictions, including Saudi Arabia under the Anti-Cyber Crime Law. The skills transfer; the permission does not.

---

## 🧠 The principle behind every design choice here

> **The application must be vulnerable. The container must not be escapable.**

These are orthogonal, and conflating them is the classic mistake in home labs.

We *want* the SQL injection to work — that's the lesson. We do *not* want a successful injection to become a foothold on your server. So the containers in this category are hardened **more** than the rest of DockHub, not less:

| Measure | What it takes away from an attacker |
|---|---|
| `cap_drop: ALL` | Linux capabilities used to escalate inside the container |
| `security_opt: no-new-privileges:true` | setuid binaries as an escalation path |
| `pids_limit` | Fork bombs — a genuine risk when you run payloads you found online |
| `mem_limit`, `cpus` | Taking the host down by exhaustion; crypto-miner payloads |
| No `privileged`, no `docker.sock` | The direct, well-known routes to host root |
| `restart: "no"` | A lab you forgot about coming back after a reboot |

None of this blunts the lessons, because the lessons live in the application layer.

---

## 🕸️ What "isolated network" actually buys you

This is the part most guides get wrong, so it's worth being precise.

Each lab service runs on its **own** Docker network and never joins `main-net`. That is real: Docker installs isolation rules that stop containers on one bridge network reaching containers on another. Your Vaultwarden and Seafile containers are not reachable from a lab container by name or by IP.

**But network isolation does not stop a lab container reaching the host itself, and through it, your LAN.**

```
   ┌─ seclab-net ──────────┐
   │  juice-shop           │
   └───────────┬───────────┘
               │  ✗ blocked by Docker isolation
               │     (main-net containers)
               │
               ✓  NOT blocked: the host's own address
               │
   ┌───────────▼──────────────────────────────────┐
   │  Docker host                                  │
   │   :81   NGINX Proxy Manager admin             │
   │   :9000 Portainer  ← mounts docker.sock       │
   │   :8085 :8086 :8087 :9200 … published ports   │
   │   → and onward to your router and laptop      │
   └───────────────────────────────────────────────┘
```

That path — container to host to LAN — is the real risk, not container-to-container. **Portainer is the sharpest edge**: it mounts `/var/run/docker.sock`, so anything that can talk to it can start a privileged container and own the host.

This is why the answer for Vulhub is a separate machine, and why the habit below matters more than any single setting.

---

## ✅ The habit

```bash
cd ~/docker/<lab-service> && docker compose stop
```

**Stop the lab when you finish practising.** Nothing in this category restarts on boot (`restart: "no"`), precisely so that stopping it stays stopped. A vulnerable app that runs for six months because you forgot about it is the actual failure mode — not any exotic exploit.

To see whether you left something running:

```bash
docker ps --filter "label=dockhub.security-lab=true"
```

Every container in this category carries that label. To stop all of them at once:

```bash
docker ps -q --filter "label=dockhub.security-lab=true" | xargs -r docker stop
```

---

## 🔌 How they're reached

Bound to your server's **LAN address**, not `0.0.0.0` and not a public domain:

```yaml
ports:
  - "<this-server's-lan-ip>:3000:3000"
```

That's a deliberate choice. You'll be pointing tools like Burp Suite and sqlmap at these from a laptop, and forcing everything through an SSH tunnel makes proxy tooling painful enough that people stop using the lab. The trade is that anything on your LAN can reach them — which is what the stop-when-done habit above covers.

**Never** put a Security-Lab service behind NGINX Proxy Manager, never give it a public domain, and never forward a port to it on your router.

> 💡 Want the stricter posture instead? Change the bind address to `127.0.0.1` in `~/docker/<service>/.env` and rerun `deploy.sh`, then reach it with `ssh -L 3000:localhost:3000 user@your-server`.

---

## 🛑 The confirmation gate

Every deploy in this category asks you to type `I-UNDERSTAND` before it does anything.

It isn't theatre. `services.sh` lists Security-Lab in the same menu as Nextcloud and Jellyfin, and a `y/N` prompt is exactly what muscle memory defeats. Typing a phrase is not.

---

## 📚 The three services

| | What it is | Shape |
|---|---|---|
| [**OWASP Juice Shop**](juice-shop/) | The modern OWASP flagship — a deliberately broken shop with a built-in scoreboard and ~100 challenges | One container |
| [**WebGoat**](webgoat/) | OWASP's guided lesson-based trainer, each lesson explaining the flaw before you exploit it | **Two** containers — WebGoat + WebWolf |
| [**Vulhub**](vulhub/) | Reproductions of real infrastructure CVEs (Log4Shell, Struts RCE, …) | **Not a service** — a launcher, and it wants its own machine |

**Juice Shop and WebGoat are application-layer targets.** You attack them through a browser; the flaws are in the app's logic. Combined with the hardening above, running them on your server is a defensible risk.

**Vulhub is a different class entirely.** It reproduces unauthenticated remote code execution against real services — the exploit lands you *inside the container* immediately, not inside a web session. Its environments are hundreds of compose files owned by upstream, some running `privileged` or on host networking, so none of this category's hardening can be applied to them. Its `deploy.sh` therefore treats a separate throwaway machine as a **requirement**, and refuses to run on a host where `main-net` exists.

---

## 📜 License

Each project is licensed by its own authors — see their repositories. These deployment wrappers follow the same [MIT license](../../LICENSE) as the rest of DockHub.

---

← Back to [all services](../README.md)

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
| `mem_limit`, `cpus` | Taking the host down by exhaustion; crypto-miner payloads. **Both always apply** — 512 MB / 1.5 CPU for Juice Shop, 1 GB / 2 CPU for WebGoat, which the deploy prompt can raise but not remove |
| No `privileged`, no `docker.sock` | The direct, well-known routes to host root |
| `restart: "no"` | A lab you forgot about coming back after a reboot |

None of this blunts the lessons, because the lessons live in the application layer.

---

## 🕸️ What "isolated network" actually buys you

This is the part most guides get wrong, so it's worth being precise.

The lab services share **one** Docker network — `seclab-net` — and none of them ever joins `main-net`. That separation is real: Docker installs isolation rules that stop containers on one bridge network reaching containers on another. Your Vaultwarden and Seafile containers are not reachable from a lab container by name or by IP.

**They share it with each other on purpose.** Each service used to get a private network of its own, which is stricter on paper and buys close to nothing here: both are targets you are deliberately breaking, and neither holds anything the other would want. What sharing does buy is that **pivoting from one target to another is itself an exercise** — lateral movement is a real skill and this is a place to practise it — and that `docker network inspect seclab-net` answers "what is in my lab" in one command.

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

### `internal: true` would close that path — and it cannot be used here. Measured.

Docker networks take `internal: true`, which the Compose reference describes only as letting you *"create an externally isolated network"*. It never says what happens to published ports. That question was open in this project for twelve days; it is now answered, on a real host:

| | result |
|---|---|
| Container reaching the internet | **blocked** — the isolation is real |
| nginx answering *inside* the container | up, so no startup race |
| The published port, from the host | **HTTP 000** — unreachable |
| DNAT rules installed for that port | **zero** |

That last row is the mechanism, and it is what makes this final rather than circumstantial: Docker does not install the forwarding rule at all for a container on an internal network. The port is not slow, or racing, or firewalled — **it was never wired up.**

So `internal: true` and `ports:` are mutually exclusive. A lab you cannot reach from your laptop is not a lab, and `seclab-net` is therefore an ordinary bridge network.

**What remains, if you want the container → host path closed anyway:** host firewall rules, not a Docker setting. Done properly that needs *two* chains — `DOCKER-USER` for traffic the host forwards on to your LAN, and `INPUT` for traffic aimed at the host's own address, which never reaches `DOCKER-USER` at all. It also does not survive a reboot without `iptables-persistent`. **No recipe is given here because none has been tested on this project's hardware**, and a firewall rule that looks right and silently does not match is worse than knowing you have none. The habit below — stop the lab when you finish — remains the control that actually works.

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
| [**WebGoat**](webgoat/) | OWASP's guided lesson-based trainer, each lesson explaining the flaw before you exploit it | **One** container, **two apps** — WebGoat + WebWolf, a port each |
| [**Vulhub**](vulhub/) | Reproductions of real infrastructure CVEs (Log4Shell, Struts RCE, …) | **Not a service** — a launcher, and it wants its own machine |

**Juice Shop and WebGoat are application-layer targets.** You attack them through a browser; the flaws are in the app's logic. Combined with the hardening above, running them on your server is a defensible risk.

**Vulhub is a different class entirely.** It reproduces unauthenticated remote code execution against real services — the exploit lands you *inside the container* immediately, not inside a web session. Its environments are hundreds of compose files owned by upstream, some running `privileged` or on host networking, so none of this category's hardening can be applied to them. Its `deploy.sh` therefore treats a separate throwaway machine as a **requirement**, and refuses to run on a host where `main-net` exists.

---

## 📜 License

Each project is licensed by its own authors — see their repositories. These deployment wrappers follow the same [MIT license](../../LICENSE) as the rest of DockHub.

---

← Back to [all services](../README.md)

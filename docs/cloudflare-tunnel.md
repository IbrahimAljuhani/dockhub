# ☁️ Using Cloudflare Tunnel with DockHub

Cloudflare Tunnel opens **no inbound ports at all** — `cloudflared` dials out from your server and Cloudflare delivers traffic back down that connection. This guide covers the setup pattern specific to how DockHub is structured; you install and create the tunnel yourself (`install_dockhub.sh` does not automate it), then follow the routing convention below for every service.

If you chose "Cloudflare Tunnel" when `install_dockhub.sh` asked how you plan to reach your services, this is the guide it pointed you to. It asks that on **both** a home server and a VPS.

**It is not only a workaround for lacking a public IP.** That was how this page used to read, and it undersold the case. Two different reasons to want it:

| | Why |
|---|---|
| **Home server** | No public IP, CGNAT, or a router you would rather not forward ports on |
| **VPS** | You have a public IP and want **nothing listening on it**. Origin unreachable, no firewall allow-list to keep current, and no Let's Encrypt certificate needed at the origin at all |

The VPS case is the stronger one, for a reason that is specific to Docker: **`ufw` does not filter published container ports** (see [troubleshooting.md](troubleshooting.md#i-denied-a-port-in-ufw-and-it-is-still-open)). Every other approach leaves you maintaining a firewall outside the host and remembering that the one inside it does not apply. A tunnel removes the question — there is no published port to filter.

---

## The core idea

```
Visitor → Cloudflare edge (HTTPS) → cloudflared (on your server) → NPM (port 80) → the service's own container (by name, over main-net)
```

**`cloudflared` always routes to NPM — never directly to a service's container.** NPM is what decides, based on the domain in the request, which service to forward to. This is exactly the same role NPM already plays for a normal DNS setup; Cloudflare Tunnel just replaces "point your domain's A record at your public IP" with "route the domain through the tunnel to this server instead."

---

## One-time setup

> ⚠️ **There are two ways to run a tunnel and they are not interchangeable.** This page used to give the first two steps of one and then the routing instructions of the other, which cannot work.
>
> | | Tunnel created | Routes live in |
> |---|---|---|
> | **Dashboard-managed** *(this guide)* | Zero Trust dashboard | the **Public Hostname** tab |
> | Locally managed | `cloudflared tunnel login` + `create` | `~/.cloudflared/config.yml` + `cloudflared tunnel route dns` |
>
> A tunnel created locally **cannot be routed from the dashboard UI**. Pick one and stay in it. The dashboard path is documented here because it is fewer moving parts and the routing table below matches it.

1. **Create the tunnel in the dashboard.** Cloudflare Zero Trust → **Networks → Tunnels → Create a tunnel → Cloudflared**, give it a name.
2. **Install the connector.** The dashboard shows an install command for your OS ending in a long token. Prefer your distribution's package (the apt/yum repo it offers) over a manually downloaded binary — a packaged `cloudflared` is patched by your normal update mechanism, a hand-placed one never is. If `cloudflared` is already installed, skip that half and run only:

   ```bash
   sudo cloudflared service install <TOKEN>
   ```

   That registers a systemd unit that starts at boot and reads the token from a file rather than the command line, so it does not show up in `ps`.

   > 🔒 The token is a credential for the tunnel. Treat it like a password — do not paste it into issues, chats, or screenshots.

3. **Confirm it connected.** `systemctl status cloudflared` should be `active (running)` **and** the dashboard should show the tunnel HEALTHY. Running is not the same as connected:

   ```bash
   sudo journalctl -u cloudflared -n 15 --no-pager | grep -iE 'registered|error'
   ```

   You want `Registered tunnel connection`, usually four of them.

---

## Per-service routing (do this for every service you deploy)

In the Cloudflare Zero Trust dashboard → **Networks → Tunnels → your tunnel → Public Hostname**, add a route:

| Field | Value |
|---|---|
| Subdomain / Domain | whatever domain you want this service on (e.g. `jellyfin.example.com`) |
| Path | leave empty |
| **Service URL** | **`http://localhost:80`** — NPM's port, always, whichever service this domain is for |

Three things about that one field:

- **`http`, not `https`**, even though the field's own placeholder suggests otherwise. Cloudflare terminates TLS at its edge; this last hop never leaves your server. NPM serves plain HTTP on 80 and an `https://` here simply fails to connect.
- **`localhost`, not the server's IP.** This page used to say `<server-ip>:80`. Both work today, but `cloudflared` runs on the same host, so `localhost` keeps the hop off the network entirely and survives the server's address changing.
- **Always port 80.** Not the service's port. NPM reads the hostname and decides where the request goes — that is the whole reason it is in front.

Recent Cloudflare UI versions combine scheme, host and port into this single **Service URL** box; older ones had a separate **Service Type** dropdown plus a URL field. Same three values either way.

Then set up the matching Proxy Host in NPM as normal, following that service's own README "Reverse Proxy" section (forward to `<service>-app`, the actual container port, etc.) — the only thing Cloudflare Tunnel changes is how traffic *reaches* NPM, not anything about how NPM itself is configured internally.

### Critical: leave Force SSL OFF in NPM for tunnel-routed domains

`cloudflared` delivers traffic to NPM over **plain HTTP** by design — Cloudflare's edge already terminates HTTPS for the visitor, so that hop doesn't need to be encrypted again. If you enable **Force SSL** on the NPM Proxy Host, NPM tries to redirect that already-plain-HTTP request to HTTPS, which fights with Cloudflare's own HTTPS enforcement and creates a redirect loop.

**Symptom**: `400 Bad Request — Request Header Or Cookie Too Large`. This looks like a cookie/header-size problem but is actually the redirect loop — each iteration stacks another round of headers until nginx rejects the request.

**Leaving Force SSL off is not a security downgrade** — Cloudflare's edge still enforces HTTPS to every visitor regardless of what NPM does internally.

---

---

## On a VPS: finish the job by binding NPM to loopback

The tunnel means nothing on your server needs to listen on a public interface. Once a hostname works end to end, make that true — otherwise the ports are still open and the tunnel is only the route you happen to be using.

Edit `~/docker/npm/docker-compose.yml`:

```yaml
    ports:
      - '127.0.0.1:80:80'
      - '127.0.0.1:81:81'
```

Drop the `443` line entirely: Cloudflare terminates TLS, so nothing ever connects to your origin on 443.

```bash
cd ~/docker/npm && docker compose up -d --force-recreate && docker port npm-app-1
```

`docker port` must show **only** `127.0.0.1` bindings — no `0.0.0.0`, no `[::]`. Changing a port mapping needs a new container, so `--force-recreate` is not optional; `up -d` alone will report "Started" and change nothing.

**Why this beats a firewall rule.** `DOCKER-USER` rules do not survive a reboot, and a provider firewall is a setting you have to keep correct. A port bound to loopback is not blocked — it is not there. Make the protection structural rather than remembered.

Leave a comment in the file saying why, or the next person to touch it will restore `80:80` and wonder why nothing works.

### Reaching the admin panel afterwards

Two routes, and you want both:

```bash
ssh -L 8181:127.0.0.1:81 <user>@<server>   # then http://localhost:8181
```

The SSH tunnel is the recovery path — it works when DNS, certificates or Cloudflare itself do not. **Test it while you do not need it.**

The other route is NPM proxying its own admin panel: add a Proxy Host for `npm.example.com` forwarding to **`npm-app-1` port `81`**, scheme `http`, Websockets on, SSL Certificate **None**. That is just this project's own "point at the container name" rule applied to NPM itself.

> **Order matters.** Create the Proxy Host and confirm the hostname works **before** moving the binding to loopback. Reversed, you remove the way in before the way in exists.

### Optional: put Cloudflare Access in front

Zero Trust → **Access → Applications → Self-hosted → Public DNS**, one application per hostname, all sharing one policy. Cloudflare then authenticates the visitor before the request ever reaches your server, so an admin panel's login form is not exposed to scanners at all.

⚠️ **One policy trap, and it is easy to walk into.** An `Include` rule answers *who*. Setting `Include → Authentication Method → Pin` looks restrictive and is the opposite: One-time PIN mails a code to whatever address the visitor types, so "anyone who used a PIN" means everyone. Use `Include → Emails → <your address>`; a method constraint belongs in **`Require (AND)`**, never `Include`.

The built-in **Policy tester** does not catch this — it evaluates identities that have already signed in, not who could. With one user it reports "1 user is approved" for both the safe rule and the wide-open one.

---

## Verifying it's working

```bash
# Confirm the tunnel is actually connected — "running" is not "connected"
sudo journalctl -u cloudflared -n 20 --no-pager

# If you run cloudflared as a container instead of a systemd service:
docker logs <cloudflared-container-name> --tail 20

# Confirm NPM is listening where the tunnel expects
docker port npm-app-1
```

If a specific domain isn't reachable, check `cloudflared`'s logs for the exact address it tried to reach — `dial tcp <ip>:<port>: connect: connection refused` tells you immediately whether the route is pointed at the wrong place (see the per-service routing table above).

If you have bound NPM to loopback, that same error means the route is pointed at the server's IP rather than `localhost` — which worked before the change and stops working after it.

For anything else, see [troubleshooting.md](troubleshooting.md)'s Cloudflare Tunnel checklist.

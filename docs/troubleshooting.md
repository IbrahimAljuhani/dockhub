# 🩺 Troubleshooting: Network & Reverse Proxy

This covers the category of issues that come up **after** a service deploys successfully (containers healthy, `docker ps` looks fine) but the site still doesn't open — reverse proxy misconfiguration, network reachability, and related gotchas. For core-infrastructure install issues (Docker/Portainer/NPM install itself), see the [root README's Troubleshooting section](../README.md#-troubleshooting) instead.

Every example below was a real issue hit while building/testing this repo, not a hypothetical.

---

## "The site just doesn't open" — where to start

Work through these in order; each one rules out an entire layer.

1. **Is the container actually healthy?**
   ```bash
   docker ps --filter name=<service>-app
   docker logs <service>-app --tail 50
   ```
   If the container is restarting or unhealthy, the problem is in the app itself, not networking — check that service's own README first.

2. **Does it work from the server itself?**
   ```bash
   curl -I http://localhost:<port>
   ```
   If this fails too, the container/port mapping is the problem (see [Direct host port doesn't work](#direct-host-port-doesnt-work-from-another-device) below). If this **succeeds**, everything past this point is a network/reverse-proxy problem, not the service.

3. **Is NPM's Proxy Host actually configured correctly for this service?**
   See [NPM Proxy Host misconfigured](#npm-proxy-host-misconfigured) below — this is the single most common cause once step 2 passes.

4. **Are you reaching NPM through Cloudflare Tunnel?**
   See [Cloudflare Tunnel checklist](#cloudflare-tunnel-checklist) below — a whole separate category of gotchas lives here. Also see the dedicated [cloudflare-tunnel.md](cloudflare-tunnel.md) guide.

---

## NPM Proxy Host misconfigured

Open the Proxy Host in NPM (**Hosts → Proxy Hosts → edit**) and check the **Details** tab against that service's own README "Reverse Proxy" section. The three fields that actually matter:

| Field | Common mistake |
|---|---|
| **Forward Hostname / IP** | Typing the server's own IP (e.g. `192.168.1.50`) instead of the container name (e.g. `jellyfin-app`). NPM and the container are on the same Docker network (`main-net`) — always use the container name, never an IP, and never the server's own address (that would loop back through NPM itself). |
| **Forward Port** | Watch for **non-Latin digits** if your OS input language isn't English (e.g. Arabic-indic `٤٤٣` instead of `443`) — some fields don't validate this and silently store the wrong value. Retype using a Latin-digit keyboard layout if a port field looks visually odd. |
| **Scheme** | Most services here are plain `http`, and NPM defaults to `http` — so the exceptions are the ones that bite. **LinkStack** terminates its own self-signed HTTPS internally and needs `https` to port `443`; **OpenVPN Access Server** does the same on port `943`. Leaving either on `http` produces a `502 Bad Gateway` (see the next section). |

If Forward Hostname/IP is accidentally set to the server's own address (or to NPM's own port), NPM ends up proxying a request back to itself, which typically surfaces as `400 Bad Request — Request Header Or Cookie Too Large` (headers stack with every loop iteration) rather than an obvious "wrong config" error — check this first if you see that specific error.

---

## `502 Bad Gateway` from openresty

`openresty` is NPM's own nginx, so this error is NPM talking, not the service. It means NPM *reached* something but couldn't make sense of the reply. The overwhelmingly common cause is a **scheme mismatch**: the upstream speaks HTTPS, NPM was told `http`, and nginx gets a TLS handshake where it expected a plain HTTP response.

Work outwards — each step rules out one layer:

```bash
# 1. Is the service itself healthy, from inside its own container?
docker exec <container> curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:<port>/
```

```bash
# 2. Can NPM reach it by container name over main-net?
docker exec npm-app-1 curl -sk -o /dev/null -w '%{http_code}\n' https://<container>:<port>/
```

Both returning `200` means the deployment is fine and the problem is entirely in what NPM saved. Read that back:

```bash
conf=$(docker exec npm-app-1 sh -c 'grep -l "your-domain" /data/nginx/proxy_host/*.conf'); docker exec npm-app-1 grep -E '^\s*set ' "$conf"
```

You'll get exactly the three fields that matter:

```
set $forward_scheme http;      ← the culprit, if the upstream is HTTPS
set $server         "openvpn-as";
set $port           943;
```

Fix it in **Details → Scheme**, save, and re-run the `grep` to confirm it now reads `https`.

> ⚠️ **Don't grep for `proxy_pass` in that file — it isn't there.** NPM's proxy-host template writes `set $forward_scheme` / `$server` / `$port` and then pulls in `include conf.d/include/proxy.conf;`, and the actual `proxy_pass $forward_scheme://$server:$port;` lives inside that shared include. Grepping for `proxy_pass` returns nothing and looks like a broken or empty config when the config is perfectly fine. Always grep for `set `.

Other causes worth checking if the scheme is already right: the container is not on `main-net` (`docker inspect <container> --format '{{json .NetworkSettings.Networks}}'`), or the app is still starting up.

---

## Cloudflare Tunnel checklist

If you're using Cloudflare Tunnel instead of a normal DNS A/AAAA record (common for home servers with no public IP), see the full [cloudflare-tunnel.md](cloudflare-tunnel.md) guide. Quick checklist if something's already set up and broken:

- [ ] The Tunnel's Public Hostname route points at **NPM** (`http://<server-ip>:80`), not directly at the service's own port.
- [ ] **Force SSL is OFF** on the NPM Proxy Host for this domain. `cloudflared` delivers traffic to NPM over plain HTTP by design (Cloudflare's edge already handles HTTPS to the visitor); if NPM also tries to force a redirect to HTTPS, it fights with Cloudflare's own enforcement and creates a redirect loop — symptom: `400 Bad Request — Request Header Or Cookie Too Large`, headers/cookies stacking with every loop iteration.
- [ ] The DNS record for this hostname is **Proxied** (🟠 orange cloud) in Cloudflare's dashboard, not "DNS only" (⚪ grey) — a `cfargotunnel.com` CNAME target only resolves through Cloudflare's own proxy layer.
- [ ] Check `cloudflared`'s own logs for the real error instead of guessing: `docker logs <cloudflared-container-name> --tail 50` (look for `dial tcp ... connect: connection refused` — that tells you exactly which address/port the tunnel tried and failed to reach).

---

## Direct host port doesn't work from another device

You deployed with an optional host port (e.g. `http://192.168.1.50:6464` — every address in this file is a placeholder, use your own), it works via `curl` from the server itself, but not from your phone/laptop on the same network.

1. **Check `ufw`/firewall on the server**: `sudo ufw status verbose`. If active, make sure the port is allowed.
2. **Try a different port number.** Some routers and ISPs silently block or deprioritize specific ports by default as a security measure — port `6666` in particular has a bad reputation from historical IRC-botnet malware and gets blocked by some consumer routers/ISPs even on a private LAN. If a port mysteriously doesn't work despite everything else being correct, retry with an unrelated port (e.g. `6464` instead of `6666`) before assuming a deeper networking problem.
3. **Router client/AP isolation.** Some routers (especially with a guest network, or some mesh systems) block devices on the same Wi-Fi from reaching each other by default. Test with `ping <server-ip>` from the other device — if even ping fails, this is almost certainly the cause; check your router's admin settings for "AP isolation" / "client isolation".
4. If none of the above explains it and you have a stable domain set up already, it's simpler to just use NPM + your domain instead of chasing direct-port LAN issues — the direct host port is only meant for quick testing, not as the primary access method.

---

## "Known Proxies" / X-Forwarded-For issues (Jellyfin and similar)

Some services (Jellyfin is the current example) discard `X-Forwarded-For` unless the proxy's address is explicitly trusted, so every visitor shows up in logs as NPM's own container IP. Find `main-net`'s subnet and add it in that service's own admin settings:

```bash
docker network inspect main-net --format '{{ (index .IPAM.Config 0).Subnet }}'
```

See the specific service's own README for exactly where this setting lives.

---

## Deploy "succeeded" but the app rejects logins / builds broken URLs

Symptoms: containers start fine, the site loads, and then authentication fails
with something like `Unauthenticated`, or generated links point somewhere wrong.
This usually means a value in `~/docker/<service>/.env` is not what you typed.

Check the domain first:

```bash
grep -a '^DOMAIN=\|^NETBIRD_DOMAIN=\|^PHOTOPRISM_SITE_URL=\|^WEB_URL=' ~/docker/<service>/.env | cat -A
```

`cat -A` matters: it makes invisible characters visible. A domain that looks
right but shows something like `vn.ia.sa M-bM-^@M-^F$` picked up a stray
character — most often a directional mark that travels along invisibly when a
Latin domain is pasted from an Arabic (or other RTL) context. NetBird was the
first service where this surfaced: the corrupted domain went into OAuth
redirect URIs, producing a deployment that started cleanly and then failed
every login.

**Fix:** correct the value in `.env` (retype it by hand rather than pasting),
then rerun that service's `deploy.sh` so any files derived from it get
rewritten too.

Current `deploy.sh` scripts validate the domain at the prompt and reject
anything that isn't a plain hostname, so this shouldn't recur — but an `.env`
written by an older version can still carry a bad value.

---

## "I pasted the custom nginx config but nothing changed"

Some services need extra nginx routing beyond a plain Proxy Host — NetBird
(gRPC + OAuth paths), Odoo (`/websocket`), OpenProject (`/hocuspocus`), Immich
(upload limits). If it seems to have no effect, the usual cause is that it was
never saved where nginx reads it.

**Where the box actually is:** in current NGINX Proxy Manager versions there is
**no tab called "Advanced"**. Open *Edit Proxy Host* and look for the **⚙️ gear
icon** at the top-right, beside the `Details / Custom Locations / SSL` tabs — it
opens a box titled **"Custom Nginx Configuration"**. That is the right place.
The **"Custom Locations" tab is a different feature** and will not work for
these blocks.

**Verify it landed, rather than trusting the UI.** NPM writes a real nginx file
per Proxy Host; read it back:

```bash
conf=$(docker exec npm-app-1 sh -c 'grep -l "your-domain" /data/nginx/proxy_host/*.conf')
echo "$conf"
docker exec npm-app-1 cat "$conf"
```

Your pasted directives should appear verbatim in that output. If they don't,
they weren't saved — reopen the ⚙️ box, paste again, and hit **Save**.

A quick targeted check for one expected string:

```bash
docker exec npm-app-1 grep -c "netbird-server" "$conf"   # 0 = not applied
```

---

## The fix worked, but the page still shows the old error

A trap worth knowing before it costs you an hour: **a browser can keep showing a
failure long after the server side is fixed.**

Single-page apps (NetBird's dashboard, Vaultwarden's vault, and most
login-driven UIs here) cache tokens and auth state in `localStorage` /
`sessionStorage`. Every failed attempt made while something *was* genuinely
broken leaves that state behind, and it survives an ordinary reload — including
Ctrl-R. So a repair that actually succeeded can look like it changed nothing,
and the natural reaction is to "fix" something that was never wrong.

**Rule: trust `curl`, not the page.** A command-line request carries no cached
state, so it reflects the server's real behaviour:

```bash
curl -sk -o /dev/null -w '%{http_code} %{content_type}\n' https://your-domain/some/endpoint
```

If `curl` looks right and the browser doesn't, the remaining problem is in the
browser. Confirm in a **private/incognito window** — it starts with empty
storage. If it works there, clear that site's data in your normal window
(usually: padlock icon → site settings → clear data) and reload.

### Diagnose outwards, one layer at a time

When something is broken, resist changing several things at once. Work from the
container outwards, so each step eliminates exactly one layer:

1. **Container logs** — `docker compose logs -f <service>`. Is the app healthy,
   and do the values it printed at startup (domain, issuer, URLs) match what you
   configured?
2. **NPM's generated config** — read the actual file, don't trust the UI:
   ```bash
   conf=$(docker exec npm-app-1 sh -c 'grep -l "your-domain" /data/nginx/proxy_host/*.conf')
   docker exec npm-app-1 cat "$conf"
   ```
3. **`curl` through the domain** — tests DNS, tunnel/port-forward, TLS and
   routing together, with no browser involved.
4. **A private browser window** — the only step left once 1–3 all pass.

Most of the confusing failures in this repo's history came from skipping
straight to step 4's symptom while the real cause sat in step 2.

# 🛡️ DNS

Network-wide ad and tracker blocking, by filtering DNS for every device on your network.

| | Notes |
|---|---|
| ✅ [**Pi-hole**](pi-hole/) | The best known, with the largest community and the most block-list guides written for it. |
| ✅ [**AdGuard Home**](adguard/) | Same job, more built in: DNS-over-HTTPS/TLS upstreams, parental controls and per-client rules without add-ons. |

---

## ⚠️ You can only run one of them

**Both bind port 53 unconditionally** — it isn't an opt-in prompt, because a DNS server that isn't on 53 isn't answering anyone. Whichever starts second will fail to bind.

They do the same job. Pick one.

## ⚠️ Ubuntu takes port 53 by default

`systemd-resolved` listens on 53 on a stock Ubuntu server, so the first deploy of either service usually fails with *address already in use*. Both READMEs cover the fix; it's a normal part of the setup, not a sign anything is broken.

---

## 📌 After deploying

Point your **router's** DNS at this server so every device is covered, rather than configuring each device. Both services then show you what's being blocked, per client.

Neither needs NGINX Proxy Manager for DNS itself — only their admin web UI is worth proxying.

---

← Back to [all services](../README.md)

# 🔐 Security

Software that protects your credentials.

> ⚠️ Not to be confused with [**Security-Lab**](../Security-Lab/), which is the opposite: software that is deliberately *vulnerable*, for practising on. Two different categories on purpose.

| | What it is |
|---|---|
| ✅ [**Vaultwarden**](vaultwarden/) | A password manager — a lightweight server that works with the official **Bitwarden** apps and browser extensions on every platform. |

---

## 📌 Things worth knowing

**Vaultwarden is the one service in DockHub with no host-port option at all**, and that isn't an oversight. Its web vault needs a browser [secure context](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts) — HTTPS or localhost — because it uses the browser's cryptography APIs to encrypt your vault before anything leaves your machine. Reached over plain `http://<ip>:<port>` those APIs simply don't exist, and you get *"You are not using a secure context"* rather than a login screen.

So: a real domain through NGINX Proxy Manager with SSL is the only route. That constraint is the encryption working as intended.

**It's genuinely light.** One container, small memory footprint — it runs comfortably on a Raspberry Pi alongside everything else.

---

← Back to [all services](../README.md)

# 🔐 VPN

Private access to your network, or between your devices.

| | Model | Best for |
|---|---|---|
| ✅ [**WireGuard**](wireguard/) | Classic hub-and-spoke VPN | The simplest and fastest. Your devices dial one server. Deployed here as **wg-easy**, which adds the web UI and QR codes that plain WireGuard lacks. |
| ✅ [**NetBird**](netbird/) | Peer-to-peer overlay | Devices connect **directly to each other**, with NAT traversal handled for you. Best when you have machines in several locations rather than one central server. |
| ✅ [**OpenVPN**](openvpn/) | Classic VPN, enterprise flavour | Compatibility. Pick it when something else already speaks OpenVPN — existing `.ovpn` profiles, a corporate client, hardware that supports nothing else. |

---

## ⚠️ Two things that apply to all three

**A VPN tunnel cannot go through NGINX Proxy Manager.** These are raw UDP protocols, not HTTP. NPM can front a *web UI*, but the tunnel itself needs a **port forwarded at your router** — and **Cloudflare Tunnel cannot carry it either**:

| Service | Port that must reach the internet |
|---|---|
| WireGuard | `51820/udp` |
| NetBird | `3478/udp` (STUN — NAT traversal is the whole point) |
| OpenVPN | `1194/udp` |

**OpenVPN has a licensing limit you should know before deploying it:** this is OpenVPN Access Server, which allows **2 concurrent connections** without a licence. Two simultaneous tunnels, not two accounts — phone plus laptop and you're full. It never expires. WireGuard and NetBird are unlimited, which is why OpenVPN is here for compatibility rather than as a default.

---

## 📌 Also worth knowing

**NetBird needs more than a normal Proxy Host.** It speaks gRPC and WebSocket alongside plain HTTP, so a default proxy makes the dashboard load and then peers silently fail to register. Its `deploy.sh` writes the required nginx block to a file and ships a `verify-npm.sh` that tells you whether the routing actually took.

---

← Back to [all services](../README.md)

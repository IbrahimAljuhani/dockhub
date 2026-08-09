# 🎬 Media

Your own streaming server for films, series and music.

| | Licence | Notes |
|---|---|---|
| ✅ [**Jellyfin**](jellyfin/) | Fully open source | No account, no subscription, nothing phones home. Every feature is available to everyone. |
| ✅ [**Plex**](plex/) | **Proprietary** | More polished apps on more devices, but it **requires a Plex account** to claim the server, and some features sit behind Plex Pass. |

---

## 📌 Things worth knowing before you pick

**Plex needs a claim token**, and it expires about four minutes after you generate it. This repo's `deploy.sh` therefore asks for it **last**, after every other question is out of the way, so the clock starts as late as possible.

**Both offer optional hardware transcoding.** Answering "no" is completely fine — direct play needs almost no CPU. Transcoding only kicks in when a client can't play the original format.

**Point them at media you already have.** Both ask for a media path during deploy rather than assuming one, and will offer to create it if it doesn't exist yet.

---

← Back to [all services](../README.md)

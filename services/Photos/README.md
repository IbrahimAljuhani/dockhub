# 📷 Photos

Your own Google Photos — backup, browse and search your library.

| | Emphasis |
|---|---|
| ✅ [**Immich**](immich/) | **Phone backup.** Excellent mobile apps that back up automatically, plus face recognition and smart search. Pick this if the job is "get photos off my phone safely". |
| ✅ [**PhotoPrism**](photoprism/) | **Organising an existing library.** Strong browsing, tagging and search over folders of photos you already have. Pick this if the job is "make sense of 20 years of files". |

---

## 📌 Things worth knowing before you pick

**Immich is a 4-container stack** and needs a specific PostgreSQL image with vector extensions built in — a plain `postgres` image will not work, because its smart search depends on them.

**Both want a custom nginx block** in NPM raising the upload limit. Without it, large videos fail to upload with a `413` and **nothing appears in the app's own logs to explain why**, because the request never reaches the app. Immich's `deploy.sh` writes the block to a file for you.

**Neither has a default login.** The first person to open the site creates the admin account — so do it promptly after deploying.

---

← Back to [all services](../README.md)

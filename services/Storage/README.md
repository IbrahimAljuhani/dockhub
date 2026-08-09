# ☁️ Storage

File sync and share — your own Dropbox.

| | Architecture | Best for |
|---|---|---|
| ✅ [**Nextcloud**](nextcloud/) | PHP + MariaDB + Redis | The broadest feature set and by far the largest **app ecosystem** — calendar, contacts, office, chat. Pick this if you want a platform, not just files. |
| ✅ [**ownCloud**](owncloud/) | **One container. No database at all.** | The lightest by a wide margin — Infinite Scale is a single Go binary with its storage engine, metadata store and identity provider embedded. Pick this if you want files, fast, with the least to maintain. |
| ✅ [**Seafile**](seafile/) | App + MariaDB + Redis | Fast, reliable **sync** specifically. Its storage model is block-based rather than file-based, which makes syncing large or frequently-changed files noticeably quicker. |

---

## 📌 Things worth knowing before you pick

**ownCloud here means Infinite Scale (oCIS), not ownCloud Server (Classic).** ownCloud ships two products; upstream describes Classic as a migration path rather than a destination, and Classic's architecture would have duplicated Nextcloud almost exactly. The trade: no PHP app store, and a different sharing model built on "Spaces". Its README explains this in full.

**oCIS has one deployment quirk worth reading about before you deploy it:** it verifies logins by fetching its *own public URL* from inside the container. On a home server behind a router that request can't loop back, and the symptom is nasty — the site loads perfectly and login fails. `deploy.sh` handles it, but its README explains what it did and why.

**Nextcloud and Seafile both want a custom nginx block** in NPM for large uploads. Their `deploy.sh` writes it to a file so you can `cat` it rather than copy it out of a browser.

---

← Back to [all services](../README.md)

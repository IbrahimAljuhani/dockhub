# 🌐 Web

Websites and publishing.

| | What it is | Best for |
|---|---|---|
| ✅ [**WordPress**](wordpress/) | The classic CMS | Anything. Themes and plugins for every purpose, and the largest community of any web software. |
| ✅ [**Ghost**](ghost/) | Publishing platform | Writing. Blog, newsletter and paid memberships in one, with a far better editor than WordPress and far less to configure. |
| ✅ [**LinkStack**](linkstack/) | Link-in-bio page | A single page of links — your own Linktree. **Multi-instance**: run several independent pages on one host. |

---

## 📌 Things worth knowing before you pick

**Ghost requires MySQL — not MariaDB.** It's the only service in DockHub with that constraint, and it matters beyond "will it start": MariaDB and MySQL dumps are no longer interchangeable, so "start on MariaDB and migrate later" is not a recovery plan. Don't copy a `db` service from another category into it.

**Ghost's `url` is load-bearing.** It builds every absolute link from it — canonical URLs, RSS, newsletter links, and the redirect after admin login. The classic symptom of getting it wrong: the site renders fine, but logging into `/ghost` bounces you elsewhere and looks like a broken password.

**LinkStack is multi-instance**, like Odoo — each instance gets its own name, database and port.

**Ghost sends no email until you configure SMTP.** Writing and publishing work fine without it, but staff invites, password resets and newsletters silently don't.

---

← Back to [all services](../README.md)

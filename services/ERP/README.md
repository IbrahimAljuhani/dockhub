# 📗 ERP

Business management — invoicing, orders, stock, contacts, accounting.

All three are complete, mature ERP systems. They differ mostly in **weight** and in **who they're built for**, so the honest answer to "which one" is usually "the lightest one that covers what you need".

| | Containers | Realistic RAM | Best for |
|---|---|---|---|
| ✅ [**Dolibarr**](dolibarr/) | 3 | 1 GB | Small businesses. Easiest to run and to learn; modular, so you enable only invoicing or only stock if that's all you need. **Try this first if you're unsure.** |
| ✅ [**Odoo**](odoo/) | 2 (+ per instance) | 2 GB | Multi-company or multi-instance setups, and a huge app ecosystem. This repo supports **several named instances** on one host. |
| ✅ [**ERPNext**](erpnext/) | 11 | 4 GB min, 8 GB comfortable | Manufacturing, deeper accounting, heavy customisation through the Frappe framework. |

---

## 📌 Things worth knowing before you pick

**Dolibarr** starts with almost every module switched off — that's by design, not a broken install. You turn on what you need under *Home → Setup → Modules*.

**Odoo** is the only **multi-instance** service in this category: you can run `odoo-prod` and `odoo-test` side by side, each with its own database and port.

**ERPNext** names its site after the address you serve it on, and is by far the slowest first start — it creates three databases and runs migrations before serving anything. A 502 for the first few minutes is normal.

All three want a real domain through NGINX Proxy Manager. Dolibarr and Odoo also need a **custom nginx block** pasted into NPM (their `deploy.sh` writes it to a file for you) — without it, Dolibarr rejects large attachments and Odoo's live chat and POS sync silently don't work.

---

← Back to [all services](../README.md)

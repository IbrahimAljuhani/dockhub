# 📋 Projects

Project management and issue tracking. Five services, and the differences between them are real — this is the category where picking the wrong one costs the most time.

| | Style | Best for |
|---|---|---|
| ✅ [**Vikunja**](vikunja/) | Lightweight tasks | Personal or small-team to-do lists with list, Gantt, table and Kanban views. The lightest here. |
| ✅ [**Taiga**](taiga/) | Agile | Teams running actual Scrum or Kanban — sprints, backlogs, story points. |
| ✅ [**Plane**](plane/) | Modern issue tracking | A Linear-like experience: cycles, modules, issue-first workflow. |
| ✅ [**Redmine**](redmine/) | Classic, plugin-driven | Long-established and extremely stable, with a large plugin ecosystem. Looks dated; still excellent at what it does. |
| ✅ [**OpenProject**](openproject/) | Full project management | Gantt charts, budgets, time and cost tracking, meetings. The heaviest and the most complete. |

---

## 📌 Things worth knowing before you pick

**Taiga has no admin account after install.** You create the superuser yourself with an explicit command — its README covers it. This surprises people who expect generated credentials like every other service here.

**OpenProject needs a custom nginx block** in NPM to route `/hocuspocus`. Without it OpenProject works fine, but two people editing the same work package silently won't see each other's changes. Its `deploy.sh` writes the block to a file.

**Vikunja is the fastest to try** if you're not sure what you want — one container, quick start, and easy to remove if it isn't a fit.

---

← Back to [all services](../README.md)

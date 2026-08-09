# 🚧 Paperclip

**Status:** Not built yet — coming soon, deliberately deferred.

[Paperclip](https://paperclip.ing/) ([GitHub](https://github.com/paperclipai/paperclip), MIT license) is an open-source platform for running/orchestrating AI agents at work. It's genuinely popular (75,000+ stars within 5 months of its first commit) and its licensing checks out clean — but as of this writing it ships **no pre-built Docker image**. Its own official `docker-compose.yml` builds the app container from source (`build: context: .. dockerfile: Dockerfile`), and that Dockerfile is a full multi-stage pnpm monorepo build (dozens of sub-packages, four separate AI-CLI toolchains installed globally, several build stages) — not something `deploy.sh` can just `curl` and `docker compose up -d` the way every other service in this repo does.

Building this properly would mean this repo's first "clone the full upstream source and build locally" deploy pattern — a meaningfully different (and heavier: longer build time, more disk/bandwidth) approach than every other service here. That's a deliberate architectural decision, not a small addition, so it's parked here as a roadmap placeholder until there's a reason to take it on (e.g. an official pre-built image appears upstream).

Part of the **Multi-Agent** category in [DockHub](../../../README.md)'s services roadmap. It's already listed in [`services.sh`](../../services.sh)'s menu (shows "coming soon" if picked) and in [`services/README.md`](../../README.md)'s roadmap table — this folder is just a placeholder until it's actually built.

Want to help build this one, or need it sooner? Open an issue on the [DockHub repo](https://github.com/IbrahimAljuhani/dockhub).

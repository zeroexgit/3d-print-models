---
title: MkDocs Setup
summary: Durable notes for MkDocs config, generated files, and publish flow in this repo.
status: active
updated: 2026-05-19
---

# MkDocs Setup

- `mkdocs/mkdocs.yml` - Full MkDocs config. Tracked. Edit directly.
- `mkdocs/hooks.py` - Generates `models/index.md` (main gallery) and `models/<category>/index.md`
  (per-category gallery) at build time via `on_pre_build`. Also injects full nav dynamically via
  `on_config` so categories appear as collapsible left-panel sections by default.
- `mkdocs/serve.sh` - Wraps `uv run --with mkdocs-material mkdocs ...`.
- `.github/workflows/deploy-pages.yml` - CI installs `mkdocs-material`, then runs `gh-deploy` on
  pushes to `main`.
- GitHub Pages must be set once to branch `gh-pages` / root.
- `docs_dir: ..` means MkDocs resolves paths from repo root.
- Hook paths in `mkdocs/mkdocs.yml` are relative to `mkdocs/`, so use `hooks.py`, not
  `mkdocs/hooks.py`.
- Category `index.md` files are auto-generated and gitignored via `models/.gitignore`.
- Empty categories are skipped: no `index.md` generated, not shown in nav.

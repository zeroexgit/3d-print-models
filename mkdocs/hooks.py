"""
hooks.py — MkDocs hook: generates models/index.md as a visual gallery.

Runs automatically on every `mkdocs serve` / `mkdocs build`.
No plugins needed — registered via hooks: in mkdocs.yml.

Gallery layout: one card per model showing preview image, name, and
the first description paragraph from its README.md.
"""

import re
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
MODELS_DIR = REPO_ROOT / "models"
OUT = MODELS_DIR / "index.md"

PREVIEW_EXTS = (".jpg", ".jpeg", ".png", ".webp")
_BRIEF = re.compile(r"^-\s+\*\*Brief\*\*:\s*(.+)$", re.MULTILINE)
_EXTRA_PREVIEW = re.compile(r"^preview_.+", re.IGNORECASE)


def _brief(readme: Path) -> str:
    """Extract the value of the '- **Brief**: ...' field from a README."""
    text = readme.read_text(encoding="utf-8")
    m = _BRIEF.search(text)
    return m.group(1).strip() if m else ""


def _find_preview(model_dir: Path) -> str | None:
    for ext in PREVIEW_EXTS:
        p = model_dir / f"preview{ext}"
        if p.exists():
            return p.name
    return None


def _find_extra_previews(model_dir: Path) -> list[str]:
    extras = []
    for item in sorted(model_dir.iterdir()):
        if not item.is_file():
            continue
        if item.suffix.lower() not in PREVIEW_EXTS:
            continue
        if _EXTRA_PREVIEW.match(item.stem):
            extras.append(item.name)
    return extras


def _build_gallery() -> str:
    lines = [
        "# Models",
        "",
        '<div class="grid cards" markdown>',
        "",
    ]

    categories = sorted(
        d for d in MODELS_DIR.iterdir()
        if d.is_dir() and not d.name.startswith(".")
    )

    for cat in categories:
        models = sorted(
            m for m in cat.iterdir()
            if m.is_dir() and not m.name.startswith(".")
        )
        for model_dir in models:
            readme = model_dir / "README.md"
            if not readme.exists():
                continue

            preview = _find_preview(model_dir)
            extra_previews = _find_extra_previews(model_dir)
            rel_page = f"{cat.name}/{model_dir.name}/README.md"
            desc = _brief(readme)

            lines.append("-   " + (f"[![]({cat.name}/{model_dir.name}/{preview}){{ loading=lazy }}]({rel_page})" if preview else ""))
            lines.append("")
            lines.append(f"    **[{model_dir.name}]({rel_page})**")
            if desc:
                # Truncate long descriptions
                short = desc if len(desc) <= 120 else desc[:117] + "…"
                lines.append("")
                lines.append(f"    {short}")
            if extra_previews:
                extra_images = " ".join(
                    f"![]({cat.name}/{model_dir.name}/{name}){{ width=96 loading=lazy }}"
                    for name in extra_previews
                )
                lines.append("")
                lines.append(f"    {extra_images}")
            lines.append("")

    lines += ["</div>", ""]
    return "\n".join(lines)


def on_pre_build(config):
    OUT.write_text(_build_gallery(), encoding="utf-8")

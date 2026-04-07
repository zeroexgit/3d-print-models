"""
hooks.py — MkDocs hook: generates index pages and injects nav.

Runs automatically on every `mkdocs serve` / `mkdocs build`.
No plugins needed — registered via hooks: in mkdocs.yml.

Generates:
  - models/index.md          — top-level gallery of all models
  - models/<category>/index.md — per-category gallery

Also injects the full nav into MkDocs config so that categories appear
as collapsible sections in the left panel (collapsed by default, because
navigation.expand is NOT set).
"""

import re
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
MODELS_DIR = REPO_ROOT / "models"
MAIN_INDEX = MODELS_DIR / "index.md"

PREVIEW_EXTS = (".jpg", ".jpeg", ".png", ".webp")
_BRIEF = re.compile(r"^-\s+\*\*Brief\*\*:\s*(.+)$", re.MULTILINE)
_EXTRA_PREVIEW = re.compile(r"^preview_.+", re.IGNORECASE)

# Category folders to skip (not real model categories)
_SKIP_DIRS = {"model-template"}


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


def _model_card_lines(cat_name: str, model_dir: Path, prefix: str = "") -> list[str]:
    """Return card lines for one model. prefix is prepended to image/link paths."""
    readme = model_dir / "README.md"
    if not readme.exists():
        return []

    preview = _find_preview(model_dir)
    extra_previews = _find_extra_previews(model_dir)
    rel_page = f"{prefix}{cat_name}/{model_dir.name}/README.md"
    img_base = f"{prefix}{cat_name}/{model_dir.name}/"
    desc = _brief(readme)

    out = []
    out.append("-   " + (
        f"[![]({img_base}{preview}){{ loading=lazy }}]({rel_page})"
        if preview else ""
    ))
    out.append("")
    out.append(f"    **[{model_dir.name}]({rel_page})**")
    if desc:
        short = desc if len(desc) <= 120 else desc[:117] + "…"
        out.append("")
        out.append(f"    {short}")
    if extra_previews:
        extra_images = " ".join(
            f"![]({img_base}{name}){{ width=96 loading=lazy }}"
            for name in extra_previews
        )
        out.append("")
        out.append(f"    {extra_images}")
    out.append("")
    return out


def _categories() -> list[Path]:
    return sorted(
        d for d in MODELS_DIR.iterdir()
        if d.is_dir() and not d.name.startswith(".") and d.name not in _SKIP_DIRS
    )


def _models_in(cat: Path) -> list[Path]:
    return sorted(
        m for m in cat.iterdir()
        if m.is_dir() and not m.name.startswith(".")
        and (m / "README.md").exists()
    )


# ---------------------------------------------------------------------------
# Page generators
# ---------------------------------------------------------------------------

def _build_main_index() -> str:
    """Top-level gallery: all models across all categories."""
    lines = ["# Models", "", '<div class="grid cards" markdown>', ""]
    for cat in _categories():
        for model_dir in _models_in(cat):
            lines.extend(_model_card_lines(cat.name, model_dir, prefix=""))
    lines += ["</div>", ""]
    return "\n".join(lines)


def _build_category_index(cat: Path) -> str:
    """Per-category gallery: all models within this category."""
    title = cat.name.title()
    lines = [f"# {title}", "", '<div class="grid cards" markdown>', ""]
    for model_dir in _models_in(cat):
        # paths are relative to the category index, so no category prefix needed
        lines.extend(_model_card_lines(cat.name, model_dir, prefix="../"))
    lines += ["</div>", ""]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Nav builder
# ---------------------------------------------------------------------------

def _build_nav() -> list:
    """
    Build the full MkDocs nav structure.

    Top-level items become tabs (navigation.tabs).  Layout:
      - Models:                        ← tab 1
          - models/index.md            ← landing page / section header
          - Board Games:               ← left-panel section (collapsed)
              - models/board games/index.md
              - Model: models/.../README.md
          - ...
      - Contact: doc/contact.md        ← tab 2
      - Donate:  doc/donate.md         ← tab 3
    """
    models_section: list = ["models/index.md"]
    for cat in _categories():
        cat_models = _models_in(cat)
        if not cat_models:
            continue
        cat_index = f"models/{cat.name}/index.md"
        section_entries: list = [cat_index]
        for model_dir in cat_models:
            section_entries.append(
                {model_dir.name: f"models/{cat.name}/{model_dir.name}/README.md"}
            )
        models_section.append({cat.name.title(): section_entries})
    nav = [
        {"Models": models_section},
        {"Contact": "doc/contact.md"},
        {"Donate": "doc/donate.md"},
    ]
    return nav


# ---------------------------------------------------------------------------
# MkDocs hooks
# ---------------------------------------------------------------------------

def on_pre_build(config):
    # Generate main index
    MAIN_INDEX.write_text(_build_main_index(), encoding="utf-8")

    # Generate per-category index pages (only for non-empty categories)
    for cat in _categories():
        models = _models_in(cat)
        if not models:
            continue
        cat_index = cat / "index.md"
        cat_index.write_text(_build_category_index(cat), encoding="utf-8")


def on_config(config):
    config["nav"] = _build_nav()
    return config

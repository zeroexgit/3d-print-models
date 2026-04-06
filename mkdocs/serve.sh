#!/usr/bin/env bash
# serve.sh — Install mkdocs-material (if needed) and serve the site locally.
#
# Usage:
#   ./mkdocs/serve.sh          # serve with live-reload at http://localhost:8000
#   ./mkdocs/serve.sh build    # one-off build to /tmp/mkdocs_site
#
# Requirements: uv (https://docs.astral.sh/uv)
# Config:       mkdocs/mkdocs.yml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/mkdocs.yml"

case "${1:-serve}" in
  serve)
    uv run --with mkdocs-material mkdocs serve --config-file "$CONFIG"
    ;;
  build)
    uv run --with mkdocs-material mkdocs build --config-file "$CONFIG"
    ;;
  *)
    echo "Usage: $0 [serve|build]" >&2
    exit 1
    ;;
esac

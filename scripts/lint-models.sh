#!/usr/bin/env bash
# lint-models.sh
# Checks that every model's README.md title matches its folder name exactly,
# and that the frontmatter `type` field is consistent with any (remix/reupload/proxy) suffix.
#
# Exit codes:
#   0  — all checks passed
#   1  — one or more issues found

set -euo pipefail

MODELS_DIR="$(cd "$(dirname "$0")/../models" && pwd)"
errors=0

check_model() {
  local readme="$1"
  local folder
  folder=$(basename "$(dirname "$readme")")

  # Skip template folder
  [[ "$folder" == "model-template" ]] && return

  local title
  title=$(grep "^#" "$readme" 2>/dev/null | head -1 | sed 's/^# //')

  local type
  type=$(grep "^type:" "$readme" 2>/dev/null | head -1 | sed 's/type: //')

  # 1. Title must exist
  if [[ -z "$title" ]]; then
    echo "MISSING TITLE: $folder"
    ((errors++))
    return
  fi

  # 2. Folder name must equal title
  if [[ "$folder" != "$title" ]]; then
    echo "TITLE MISMATCH:"
    echo "  Folder: $folder"
    echo "  Title:  $title"
    ((errors++))
  fi

  # 3. type field must match suffix
  if [[ "$title" == *"(remix)"* && "$type" != "remix" ]]; then
    echo "TYPE MISMATCH: '$title' has (remix) but type='$type'"
    ((errors++))
  elif [[ "$title" == *"(reupload)"* && "$type" != "reupload" ]]; then
    echo "TYPE MISMATCH: '$title' has (reupload) but type='$type'"
    ((errors++))
  elif [[ "$title" == *"(proxy)"* && "$type" != "proxy" ]]; then
    echo "TYPE MISMATCH: '$title' has (proxy) but type='$type'"
    ((errors++))
  elif [[ "$title" != *"("* && "$type" != "original" ]]; then
    echo "TYPE MISMATCH: '$title' has no suffix but type='$type'"
    ((errors++))
  fi
}

while IFS= read -r -d '' readme; do
  check_model "$readme"
done < <(find "$MODELS_DIR" -maxdepth 3 -name "README.md" -type f -print0)

if [[ "$errors" -eq 0 ]]; then
  echo "All models OK."
  exit 0
else
  echo ""
  echo "$errors issue(s) found."
  exit 1
fi

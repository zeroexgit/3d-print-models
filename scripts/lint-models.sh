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
DECORATOR='<!------------------------------------------------------------------------------------------------->'
errors=0

require_pattern() {
  local readme="$1"
  local pattern="$2"
  local label="$3"

  if ! grep -Eq "$pattern" "$readme"; then
    echo "MISSING $label: $readme"
    ((errors += 1))
  fi
}

check_decorated_heading() {
  local readme="$1"
  local heading="$2"

  if ! awk -v heading="$heading" -v decorator="$DECORATOR" '
    {
      if (check_next && $0 == decorator) {
        valid = 1
      }
      check_next = ($0 == heading)
    }
    END { exit !(valid) }
  ' "$readme"; then
    echo "MISSING DECORATORS around $heading: $readme"
    ((errors += 1))
  fi
}

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

  require_pattern "$readme" '^!\[Preview\]\(preview\.jpg\)(\{[^}]+\})?$' "CANONICAL PREVIEW"
  require_pattern "$readme" '^- \*\*Brief\*\*:' "BRIEF"
  require_pattern "$readme" '^- \*\*Tags\*\*:' "TAGS"
  require_pattern "$readme" '^## Attribution$' "ATTRIBUTION HEADING"
  require_pattern "$readme" '^## License$' "LICENSE HEADING"
  check_decorated_heading "$readme" "## Attribution"
  check_decorated_heading "$readme" "## License"

  if [[ ! -f "$(dirname "$readme")/preview.jpg" ]]; then
    echo "MISSING PREVIEW FILE: $readme"
    ((errors += 1))
  fi

  if awk '
    {
      if (!in_comment && $0 ~ /link-goes-here/) {
        found = 1
      }
      if ($0 ~ /<!--/) {
        in_comment = 1
      }
      if ($0 ~ /-->/) {
        in_comment = 0
      }
    }
    END { exit !(found) }
  ' "$readme"; then
    echo "PLACEHOLDER LINK OUTSIDE COMMENT: $readme"
    ((errors += 1))
  fi

  if grep -q 'TODO:' "$readme"; then
    echo "INCOMPLETE README: $readme"
    ((errors += 1))
  fi

  case "$type" in
    original)
      require_pattern "$readme" '^This is an original 3D print model\.$' "ORIGINAL ATTRIBUTION"
      require_pattern "$readme" '^Explore my \[3D print model collection\]' "COLLECTION LINK"
      ;;
    remix)
      require_pattern "$readme" '^This model is a remix of ' "REMIX ATTRIBUTION"
      require_pattern "$readme" '^### Differences of the remix compared to the original$' "REMIX DIFFERENCES"
      require_pattern "$readme" '^### Original Description$' "ORIGINAL DESCRIPTION"
      require_pattern "$readme" '^Explore my \[3D print model collection\]' "COLLECTION LINK"
      ;;
    reupload)
      require_pattern "$readme" '^This model is a reupload of ' "REUPLOAD ATTRIBUTION"
      require_pattern "$readme" "^I've reuploaded this model only to " "REUPLOAD NOTICE"
      require_pattern "$readme" '^### Original Description$' "ORIGINAL DESCRIPTION"
      ;;
    proxy)
      require_pattern "$readme" '^This entry references a 3D print model by ' "PROXY ATTRIBUTION"
      require_pattern "$readme" '^### Original Description$' "ORIGINAL DESCRIPTION"
      ;;
  esac

  if [[ "$type" != "original" ]] && ! grep -Eq 'https?://[^ >)]+' "$readme"; then
    echo "MISSING SOURCE URL: $readme"
    ((errors += 1))
  fi

  if ! grep -Eq '^(This model is licensed under |This model is marked as |Single User License)' "$readme"; then
    echo "MISSING LICENSE STATEMENT: $readme"
    ((errors += 1))
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

#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

##==================================================================================================
##	DEPENDENCY CHECKS
##==================================================================================================

requireCommand() {
    command -v "$1" >/dev/null 2>&1 || {
        printf "Abort: '%s' not found\n" "$1" >&2
        exit 1
    }
}

requireCommand awk
requireCommand basename
requireCommand dirname
requireCommand find
requireCommand grep
requireCommand git

##==================================================================================================
##	GLOBALS
##==================================================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
declare -r SCRIPT_DIR
REPOSITORY_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
declare -r REPOSITORY_DIR
MODELS_DIR="$(cd -- "$SCRIPT_DIR/../models" && pwd -P)"
declare -r MODELS_DIR
declare -r CATEGORIES_FILE="$MODELS_DIR/_model-templates/categories.md"
declare -r DECORATOR='<!------------------------------------------------------------------------------------------------->'
declare -A VALID_CATEGORIES=()
ERRORS=0

##==================================================================================================
##	UTILITIES
##==================================================================================================

reportIssue() {
    local label="$1"
    local readme="$2"
    printf '%s: %s\n' "$label" "$readme"
}

readmeHasPattern() {
    local readme="$1"
    local pattern="$2"
    grep -Eq "$pattern" "$readme"
}

getMarkdownTitle() {
    local readme="$1"
    awk '/^# / { sub(/^# /, ""); print; exit }' "$readme"
}

getFrontmatterField() {
    local readme="$1"
    local key="$2"
    awk -v key="$key" '
    /^---$/ { delimiter += 1; if (delimiter == 2) exit; next }
    delimiter == 1 && index($0, key ":") == 1 {
      sub("^" key ":[[:space:]]*", "")
      print
      exit
    }
  ' "$readme"
}

readmeHasDecoratedHeading() {
    local readme="$1"
    local heading="$2"
    awk -v heading="$heading" -v decorator="$DECORATOR" '
    {
      if (check_next && $0 == decorator) valid = 1
      check_next = ($0 == heading)
    }
    END { exit !(valid) }
  ' "$readme"
}

##==================================================================================================
##	CORE FUNCTIONS
##==================================================================================================

## Load valid "family/category" pairs from categories.md.
loadCategories() {
    if [[ ! -f "$CATEGORIES_FILE" ]]; then
        printf 'MISSING categories.md: %s\n' "$CATEGORIES_FILE"
        return 1
    fi

    local current_family=""
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^-\ ([a-z0-9-]+) ]]; then
            current_family="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+-\ ([a-z0-9-]+) ]]; then
            VALID_CATEGORIES["$current_family/${BASH_REMATCH[1]}"]=1
        fi
    done <"$CATEGORIES_FILE"
}

checkInstructions() {
    local readme="$1"

    awk '
    function fail() {
      invalid = 1
    }
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function finish_item(kind, value, key) {
      value = trim(kind == "materials" ? current_material : current_assembly)
      if (value == "") {
        fail()
      } else {
        key = kind SUBSEP value
        if (seen_items[key]) fail()
        seen_items[key] = 1
      }
    }
    /^## / {
      if (active) {
        active = 0
      }
      if ($0 == "## Instructions") {
        active = 1
        instructions += 1
        subsection = ""
      }
      next
    }
    !active { next }
    /^### / {
      if ($0 == "### Bill of materials") {
        subsection = "materials"
        materials += 1
      } else if ($0 == "### Printing") {
        subsection = "printing"
        printing += 1
      } else if ($0 == "### Assembly") {
        subsection = "assembly"
        assembly += 1
      } else {
        subsection = "ignored"
      }
      next
    }
    /^[[:space:]]*$/ { next }
    subsection == "materials" {
      if ($0 ~ /^[[:space:]]*[-*+][[:space:]]+/) {
        if (material_items > 0) finish_item("materials")
        material_items += 1
        current_material = $0
        sub(/^[[:space:]]*[-*+][[:space:]]+/, "", current_material)
        current_material = trim(current_material)
      } else if (material_items > 0) {
        current_material = current_material " " trim($0)
      } else {
        fail()
      }
      next
    }
    subsection == "printing" {
      printing_content = 1
      next
    }
    subsection == "assembly" {
      if ($0 ~ /^[[:space:]]*[0-9]+[.)][[:space:]]+/) {
        if (assembly_items > 0) finish_item("assembly")
        assembly_items += 1
        current_assembly = $0
        sub(/^[[:space:]]*[0-9]+[.)][[:space:]]+/, "", current_assembly)
        current_assembly = trim(current_assembly)
      } else if (assembly_items > 0) {
        current_assembly = current_assembly " " trim($0)
      } else {
        fail()
      }
      next
    }
    END {
      if (material_items > 0) finish_item("materials")
      if (assembly_items > 0) finish_item("assembly")
      if (instructions > 1) fail()
      if (instructions == 1 && (materials != 1 || printing != 1 || assembly != 1 ||
          material_items == 0 || !printing_content || assembly_items == 0)) fail()
      exit invalid
    }
  ' "$readme"
}

checkTitleExists() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    if [[ -z "$(getMarkdownTitle "$readme")" ]]; then
        reportIssue "MISSING TITLE in $(basename "$model_dir")" "$readme"
        return 1
    fi
}

checkFolderTitleMatchesReadme() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local folder_title
    local readme_title
    folder_title="$(basename "$model_dir")"
    readme_title="$(getMarkdownTitle "$readme")"
    if [[ -n "$readme_title" && "$folder_title" != "$readme_title" ]]; then
        printf 'TITLE MISMATCH: %s\n  Folder: %s\n  Title:  %s\n' \
            "$readme" "$folder_title" "$readme_title"
        return 1
    fi
}

checkTypeMatchesTitle() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local title
    local type
    title="$(getMarkdownTitle "$readme")"
    type="$(getFrontmatterField "$readme" "type")"
    [[ -n "$title" ]] || return 0

    local expected_type="original"
    if [[ "$title" == *"(remix)"* ]]; then
        expected_type="remix"
    elif [[ "$title" == *"(reupload)"* ]]; then
        expected_type="reupload"
    elif [[ "$title" == *"(proxy)"* ]]; then
        expected_type="proxy"
    elif [[ "$title" == *"("* ]]; then
        return 0
    fi

    if [[ "$type" != "$expected_type" ]]; then
        reportIssue "TYPE MISMATCH: '$title' expects type='$expected_type', got '$type'" "$readme"
        return 1
    fi
}

checkCategoryIsValid() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local category
    category="$(getFrontmatterField "$readme" "category")"
    if [[ -z "$category" ]]; then
        reportIssue "MISSING CATEGORY" "$readme"
        return 1
    elif [[ -z "${VALID_CATEGORIES[$category]+x}" ]]; then
        reportIssue "INVALID CATEGORY '$category'" "$readme"
        return 1
    fi
}

checkCanonicalPreviewReference() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    if ! readmeHasPattern "$readme" '^!\[Preview\]\(preview\.jpg\)(\{[^}]+\})?$'; then
        reportIssue "MISSING CANONICAL PREVIEW REFERENCE" "$readme"
        return 1
    fi
}

checkBriefExists() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    if ! readmeHasPattern "$readme" '^- \*\*Brief\*\*:'; then
        reportIssue "MISSING BRIEF" "$readme"
        return 1
    fi
}

checkTagsExist() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    if ! readmeHasPattern "$readme" '^- \*\*Tags\*\*:'; then
        reportIssue "MISSING TAGS" "$readme"
        return 1
    fi
}

checkAttributionHeadingExists() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    if ! readmeHasPattern "$readme" '^## Attribution$'; then
        reportIssue "MISSING ATTRIBUTION HEADING" "$readme"
        return 1
    elif ! readmeHasDecoratedHeading "$readme" "## Attribution"; then
        reportIssue "MISSING ATTRIBUTION DECORATORS" "$readme"
        return 1
    fi
}

checkLicenseHeadingExists() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    if ! readmeHasPattern "$readme" '^## License$'; then
        reportIssue "MISSING LICENSE HEADING" "$readme"
        return 1
    elif ! readmeHasDecoratedHeading "$readme" "## License"; then
        reportIssue "MISSING LICENSE DECORATORS" "$readme"
        return 1
    fi
}

checkInstructionsFormat() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    if ! checkInstructions "$readme"; then
        reportIssue "INVALID INSTRUCTIONS SECTION FORMAT" "$readme"
        return 1
    fi
}

checkPreviewFileExists() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    if [[ ! -f "$model_dir/preview.jpg" ]]; then
        reportIssue "MISSING PREVIEW FILE" "$readme"
        return 1
    fi
}

checkAssetsDirectoryIsIgnored() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local assets_dir="$model_dir/assets"
    local assets_gitignore="$assets_dir/.gitignore"
    local asset_path
    local relative_asset_path

    [[ -d "$assets_dir" ]] || return 0

    if [[ ! -f "$assets_gitignore" ]]; then
        if ! printf '*\n' >"$assets_gitignore"; then
            reportIssue "COULD NOT CREATE $assets_gitignore" "$readme"
            return 1
        fi
        printf 'CREATED %s\n' "$assets_gitignore"
    fi

    while IFS= read -r -d '' asset_path; do
        relative_asset_path="${asset_path#"$REPOSITORY_DIR"/}"
        if ! git -C "$REPOSITORY_DIR" check-ignore --quiet --no-index -- \
            "$relative_asset_path"; then
            reportIssue "ASSETS CONTENT IS NOT GIT-IGNORED: $relative_asset_path" "$readme"
            return 1
        fi
    done < <(find "$assets_dir" -mindepth 1 -print0)
}

checkNoPlaceholderLinks() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    if awk '
    {
      if (!in_comment && $0 ~ /link-goes-here/) found = 1
      if ($0 ~ /<!--/) in_comment = 1
      if ($0 ~ /-->/) in_comment = 0
    }
    END { exit !(found) }
  ' "$readme"; then
        reportIssue "PLACEHOLDER LINK OUTSIDE COMMENT" "$readme"
        return 1
    fi
}

checkNoTodoMarkers() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    if grep -q 'TODO:' "$readme"; then
        reportIssue "INCOMPLETE README (TODO)" "$readme"
        return 1
    fi
}

checkAttributionMatchesType() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local type
    type="$(getFrontmatterField "$readme" "type")"

    case "$type" in
        original)
            if ! readmeHasPattern "$readme" '^This is an original 3D print model\.$' ||
                ! readmeHasPattern "$readme" '^Explore my \[3D print model collection\]'; then
                reportIssue "INVALID ORIGINAL ATTRIBUTION" "$readme"
                return 1
            fi
            ;;
        remix)
            if ! readmeHasPattern "$readme" '^This model is a remix of ' ||
                ! readmeHasPattern "$readme" '^### Differences of the remix compared to the original$' ||
                ! readmeHasPattern "$readme" '^### Original Description$' ||
                ! readmeHasPattern "$readme" '^Explore my \[3D print model collection\]'; then
                reportIssue "INVALID REMIX ATTRIBUTION" "$readme"
                return 1
            fi
            ;;
        reupload)
            if ! readmeHasPattern "$readme" '^This model is a reupload of ' ||
                ! readmeHasPattern "$readme" "^I've reuploaded this model only to " ||
                ! readmeHasPattern "$readme" '^### Original Description$'; then
                reportIssue "INVALID REUPLOAD ATTRIBUTION" "$readme"
                return 1
            fi
            ;;
        proxy)
            if ! readmeHasPattern "$readme" '^This entry references a 3D print model by ' ||
                ! readmeHasPattern "$readme" '^### Original Description$'; then
                reportIssue "INVALID PROXY ATTRIBUTION" "$readme"
                return 1
            fi
            ;;
    esac
}

checkSourceUrlExists() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local type
    type="$(getFrontmatterField "$readme" "type")"
    if [[ "$type" != "original" ]] && ! readmeHasPattern "$readme" 'https?://[^ >)]+'; then
        reportIssue "MISSING SOURCE URL" "$readme"
        return 1
    fi
}

checkLicenseStatementExists() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    if ! readmeHasPattern "$readme" '^(This model is licensed under |This model is marked as |Single User License)'; then
        reportIssue "MISSING LICENSE STATEMENT" "$readme"
        return 1
    fi
}

runModelChecks() {
    local model_dir="$1"
    local check_function
    local -a checks=(
        checkTitleExists
        checkFolderTitleMatchesReadme
        checkTypeMatchesTitle
        checkCategoryIsValid
        checkCanonicalPreviewReference
        checkBriefExists
        checkTagsExist
        checkAttributionHeadingExists
        checkLicenseHeadingExists
        checkInstructionsFormat
        checkPreviewFileExists
        checkAssetsDirectoryIsIgnored
        checkNoPlaceholderLinks
        checkNoTodoMarkers
        checkAttributionMatchesType
        checkSourceUrlExists
        checkLicenseStatementExists
    )

    for check_function in "${checks[@]}"; do
        if ! "$check_function" "$model_dir"; then
            ((ERRORS += 1))
        fi
    done
}

lintModelFolder() {
    local readme="$1"
    local model_dir
    model_dir="$(dirname "$readme")"
    [[ "$model_dir" == "$MODELS_DIR"/_model-templates/* ]] && return 0
    runModelChecks "$model_dir"
}

##==================================================================================================
##	MAIN
##==================================================================================================

main() {
    local readme
    if ! loadCategories; then
        ((ERRORS += 1))
    fi

    while IFS= read -r -d '' readme; do
        lintModelFolder "$readme"
    done < <(find "$MODELS_DIR" -maxdepth 3 -name "README.md" -type f -print0)

    if [[ "$ERRORS" -eq 0 ]]; then
        printf '%s\n' "All models OK."
        return 0
    fi
    printf '\n%d issue(s) found.\n' "$ERRORS"
    return 1
}

##==================================================================================================
##	SCRIPT ENTRY POINT
##==================================================================================================

main

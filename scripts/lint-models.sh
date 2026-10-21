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
requireCommand chmod
requireCommand mktemp
requireCommand mv
requireCommand trash

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
declare -r LICENSES_FILE="$MODELS_DIR/_model-templates/licenses.md"
declare -r REMIX_NOTICE_TEMPLATE="$MODELS_DIR/_model-templates/remix-notice.md"
declare -r MORE_TEMPLATE="$MODELS_DIR/_model-templates/more-url.md"
declare -r DECORATOR='<!------------------------------------------------------------------------------------------------->'
declare -A VALID_CATEGORIES=()
declare -A VALID_LICENSE_STATEMENTS=()
declare -A VALID_LICENSE_TYPES=()
CATEGORIES_AVAILABLE=true
LICENSES_AVAILABLE=true
REMIX_NOTICE_AVAILABLE=true
MORE_TEMPLATE_AVAILABLE=true
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
        printf 'WARNING: category validation skipped; file not found: %s\n' "$CATEGORIES_FILE"
        CATEGORIES_AVAILABLE=false
        return 0
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

## Load valid license statements from licenses.md.
loadLicenseStatements() {
    if [[ ! -f "$LICENSES_FILE" ]]; then
        printf 'WARNING: license validation skipped; file not found: %s\n' "$LICENSES_FILE"
        LICENSES_AVAILABLE=false
        return 0
    fi

    local line
    local current_license_statement=""
    local license_type
    while IFS= read -r line; do
        if [[ "$line" =~ ^-[[:space:]](.+)$ ]]; then
            current_license_statement="${BASH_REMATCH[1]}"
            current_license_statement="${current_license_statement%"${current_license_statement##*[![:space:]]}"}"
            VALID_LICENSE_STATEMENTS["$current_license_statement"]=1
            if [[ "$current_license_statement" == 'This model is licensed under [**CC '* ]]; then
                VALID_LICENSE_TYPES["$current_license_statement|proxy"]=1
            fi
        elif [[ -n "$current_license_statement" && "$line" =~ ^[[:space:]]+-[[:space:]](.+)$ ]]; then
            license_type="${BASH_REMATCH[1]}"
            license_type="${license_type%"${license_type##*[![:space:]]}"}"
            VALID_LICENSE_TYPES["$current_license_statement|$license_type"]=1
        else
            current_license_statement=""
        fi
    done < <(stripMarkdownComments "$LICENSES_FILE")
}

checkSupportingTemplateFiles() {
    if [[ ! -f "$REMIX_NOTICE_TEMPLATE" ]]; then
        printf 'WARNING: remix notice validation skipped; file not found: %s\n' \
            "$REMIX_NOTICE_TEMPLATE"
        REMIX_NOTICE_AVAILABLE=false
    fi
    if [[ ! -f "$MORE_TEMPLATE" ]]; then
        printf 'WARNING: required more-text validation skipped; file not found: %s\n' \
            "$MORE_TEMPLATE"
        MORE_TEMPLATE_AVAILABLE=false
    fi
}

## Remove HTML comments while preserving text outside comment blocks.
stripMarkdownComments() {
    local markdown_file="$1"
    awk '
    {
      line = ""
      position = 1
      while (position <= length($0)) {
        if (in_comment) {
          if (substr($0, position, 3) == "-->") {
            in_comment = 0
            position += 3
          } else {
            position += 1
          }
        } else if (substr($0, position, 4) == "<!--") {
          in_comment = 1
          position += 4
        } else {
          line = line substr($0, position, 1)
          position += 1
        }
      }
      print line
    }
  ' "$markdown_file"
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

checkFolderNameHasNoTrailingSpaces() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local folder_name
    folder_name="$(basename "$model_dir")"
    if [[ "$folder_name" == *' ' ]]; then
        reportIssue "TRAILING SPACE IN MODEL FOLDER NAME" "$readme"
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
    [[ "$CATEGORIES_AVAILABLE" == true ]] || return 0
    category="$(getFrontmatterField "$readme" "category")"
    if [[ -z "$category" ]]; then
        reportIssue "MISSING CATEGORY; add an accepted family/category from $CATEGORIES_FILE" \
            "$readme"
        return 1
    elif [[ -z "${VALID_CATEGORIES[$category]+x}" ]]; then
        reportIssue "INVALID CATEGORY '$category'; accepted values are listed in $CATEGORIES_FILE" \
            "$readme"
        return 1
    fi
}

checkPreviewReferenceCountMatchesFiles() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local preview_file
    local preview_file_name
    local reference_path
    local reference_alt_text
    local expected_alt_text
    local issue_message
    local preview_file_count=0
    local preview_reference_count=0
    local reference_index
    local expected_support_number
    local invalid=0
    local -a preview_file_names=()
    local -a preview_reference_paths=()
    local -A seen_preview_files=()
    local -A seen_preview_references=()

    for preview_file in "$model_dir"/preview*.jpg "$model_dir"/preview*.jpeg \
        "$model_dir"/preview*.png "$model_dir"/preview*.webp; do
        [[ -f "$preview_file" ]] || continue
        preview_file_name="${preview_file##*/}"
        preview_file_names+=("$preview_file_name")
        seen_preview_files["$preview_file_name"]=1
        ((preview_file_count += 1))
    done

    while IFS=$'\t' read -r reference_alt_text reference_path; do
        preview_reference_paths+=("$reference_path")
        ((preview_reference_count += 1))
        expected_alt_text='Preview'
        if [[ "$reference_path" =~ ^preview_([1-9][0-9]*)\. ]]; then
            expected_alt_text="Preview ${BASH_REMATCH[1]}"
        fi
        if [[ "$reference_alt_text" != "$expected_alt_text" ]]; then
            reportIssue \
                "PREVIEW LABEL MISMATCH ($reference_path requires alt text '$expected_alt_text')" \
                "$readme"
            invalid=1
        fi
        if [[ -n "${seen_preview_references["$reference_path"]+x}" ]]; then
            reportIssue "DUPLICATE PREVIEW REFERENCE ($reference_path)" "$readme"
            invalid=1
        fi
        seen_preview_references["$reference_path"]=1
    done < <(awk '
        {
            line = $0
            while (match(line, /!\[Preview[^]]*\]\(preview[^)]*\)/)) {
                image_reference_start = RSTART
                image_reference = substr(line, RSTART, RLENGTH)
                image_reference_length = RLENGTH
                alt_text = image_reference
                sub(/^!\[/, "", alt_text)
                sub(/\].*$/, "", alt_text)
                preview_path = image_reference
                sub(/^.*\]\(/, "", preview_path)
                sub(/\)$/, "", preview_path)
                print alt_text "\t" preview_path
                line = substr(line, image_reference_start + image_reference_length)
            }
        }
    ' "$readme")

    if ((preview_reference_count != preview_file_count)); then
        printf -v issue_message \
            'PREVIEW COUNT MISMATCH (README: %s refs; folder: %s preview images)' \
            "$preview_reference_count" "$preview_file_count"
        reportIssue "$issue_message" "$readme"
        invalid=1
    fi

    for preview_file_name in "${preview_file_names[@]}"; do
        if [[ -z "${seen_preview_references["$preview_file_name"]+x}" ]]; then
            reportIssue "PREVIEW FILE NOT REFERENCED BY README ($preview_file_name)" \
                "$model_dir/$preview_file_name"
            invalid=1
        fi
    done

    for reference_path in "${!seen_preview_references[@]}"; do
        if [[ -z "${seen_preview_files["$reference_path"]+x}" ]]; then
            reportIssue "PREVIEW REFERENCE HAS NO MATCHING FILE ($reference_path)" "$readme"
            invalid=1
        fi
    done

    for ((reference_index = 1; reference_index < preview_reference_count; reference_index += 1)); do
        expected_support_number="$reference_index"
        reference_path="${preview_reference_paths[$reference_index]}"
        if [[ "$reference_path" != "preview_${expected_support_number}."* ]]; then
            printf -v issue_message \
                'PREVIEW REFERENCES OUT OF ORDER (expected preview_%s.<extension>; found %s)' \
                "$expected_support_number" "$reference_path"
            reportIssue "$issue_message" "$readme"
            invalid=1
        fi
    done

    ((invalid == 0))
}

checkPreviewReferencesAreContiguous() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    if ! awk '
        {
            preview_reference_count = gsub(/!\[Preview[^]]*\]\(preview[^)]*\)/, "&")
            if (preview_reference_count > 1) invalid = 1
        }
        {
            if (!match($0, /!\[Preview[^]]*\]\(preview[^)]*\)/)) next
            if (previous_preview_line && NR != previous_preview_line + 1) invalid = 1
            previous_preview_line = NR
        }
        END { exit invalid }
    ' "$readme"; then
        reportIssue "PREVIEW REFERENCES MUST BE ONE PER LINE AND CONTIGUOUS" "$readme"
        return 1
    fi
}

removeBlankLinesBetweenPreviewReferences() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local temporary_file

    if ! awk '
        /^!\[Preview[^]]*\]\(preview[^)]*\)/ {
            if (previous_preview && blank_between) needs_fix = 1
            previous_preview = 1
            blank_between = 0
            next
        }
        /^[[:space:]]*$/ {
            if (previous_preview) blank_between = 1
            next
        }
        { previous_preview = 0; blank_between = 0 }
        END { exit !needs_fix }
    ' "$readme"; then
        return 0
    fi

    temporary_file="$(mktemp --tmpdir="${readme%/*}" ".${readme##*/}.XXXXXX")"
    if ! awk '
        /^!\[Preview[^]]*\]\(preview[^)]*\)/ {
            if (!(previous_preview && pending_blanks)) printf "%s", pending
            pending = ""
            pending_blanks = 0
            print
            previous_preview = 1
            next
        }
        /^[[:space:]]*$/ {
            pending = pending $0 "\n"
            pending_blanks = 1
            next
        }
        {
            printf "%s", pending
            pending = ""
            pending_blanks = 0
            print
            previous_preview = 0
        }
        END { printf "%s", pending }
    ' "$readme" >"$temporary_file"; then
        trash "$temporary_file"
        reportIssue "COULD NOT NORMALIZE PREVIEW SPACING" "$readme"
        return 1
    fi

    if ! chmod --reference="$readme" "$temporary_file" ||
        ! mv -- "$temporary_file" "$readme"; then
        if [[ -e "$temporary_file" ]]; then
            trash "$temporary_file"
        fi
        reportIssue "COULD NOT NORMALIZE PREVIEW SPACING" "$readme"
        return 1
    fi
    printf 'REMOVED BLANK LINES BETWEEN PREVIEW REFERENCES: %s\n' "$readme"
}

checkCanonicalPreviewReference() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local first_preview_reference

    first_preview_reference="$(awk '
        {
            if (!match($0, /!\[Preview[^]]*\]\(preview[^)]*\)/)) next
            print substr($0, RSTART, RLENGTH)
            exit
        }
    ' "$readme")"
    if [[ ! "$first_preview_reference" =~ ^!\[Preview\]\(preview\.(jpg|jpeg|png|webp)\)(\{[^}]+\})?$ ]]; then
        reportIssue \
            "INVALID FIRST PREVIEW REFERENCE (expected ![Preview](preview.<extension>))" \
            "$readme"
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

checkPreviewFileNames() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local preview_file
    local file_name
    local preview_number
    local support_preview_count=0
    local canonical_preview_count=0
    local invalid=0
    local issue_message
    local -A seen_support_preview_numbers=()

    for preview_file in "$model_dir"/preview*; do
        [[ -f "$preview_file" ]] || continue
        file_name="${preview_file##*/}"

        if [[ "$file_name" =~ ^preview\.(jpg|jpeg|png|webp)$ ]]; then
            ((canonical_preview_count += 1))
        elif [[ "$file_name" =~ ^preview_([1-9][0-9]*)\.(jpg|jpeg|png|webp)$ ]]; then
            preview_number="${BASH_REMATCH[1]}"
            if [[ -n "${seen_support_preview_numbers["$preview_number"]+x}" ]]; then
                printf -v issue_message \
                    'DUPLICATE SUPPORT PREVIEW NUMBER (%s; already used by %s)' \
                    "$preview_number" "${seen_support_preview_numbers["$preview_number"]}"
                reportIssue "$issue_message" "$preview_file"
                invalid=1
            else
                seen_support_preview_numbers["$preview_number"]="$file_name"
                ((support_preview_count += 1))
            fi
        else
            printf -v issue_message \
                'INVALID PREVIEW FILE NAME (%s; use preview.<ext> or preview_<n>.<ext>; ext: jpg/jpeg/png/webp)' \
                "$file_name"
            reportIssue "$issue_message" "$preview_file"
            invalid=1
        fi
    done

    if ((canonical_preview_count == 0)); then
        reportIssue \
            "MISSING CANONICAL PREVIEW FILE (expected preview.jpg, preview.jpeg, preview.png, or preview.webp)" \
            "$readme"
        invalid=1
    elif ((canonical_preview_count > 1)); then
        reportIssue \
            "MULTIPLE CANONICAL PREVIEW FILES (found $canonical_preview_count; keep one preview.<extension>)" \
            "$readme"
        invalid=1
    fi

    for ((preview_number = 1; preview_number <= support_preview_count; preview_number += 1)); do
        if [[ -z "${seen_support_preview_numbers["$preview_number"]+x}" ]]; then
            reportIssue "PREVIEW NUMBERING GAP (missing preview_${preview_number}.<extension>)" \
                "$readme"
            invalid=1
        fi
    done

    ((invalid == 0))
}

checkStlNames() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local stl_path
    local file_name
    local part_path
    local part_number
    local part_name
    local version
    local max_part_number=0
    local invalid=0
    local has_root_alternatives=0
    local has_numbered_parts=0
    local part
    local segment
    local prefix
    local segment_index
    local -a stl_files=()
    local -a part_segments=()
    local -A seen_part_paths=()
    local -A seen_option_slots=()
    local -A seen_top_level_parts=()

    while IFS= read -r -d '' stl_path; do
        stl_files+=("${stl_path##*/}")
    done < <(find "$model_dir" -maxdepth 1 -type f -name '*.stl' -print0)

    ## NOP: single-file model naming is unrestricted for now.
    ((${#stl_files[@]} > 1)) || return 0

    for file_name in "${stl_files[@]}"; do
        if [[ ! "$file_name" =~ ^((0|[1-9][0-9]*|[A-Z])(\.[1-9][0-9]*|\.[A-Z]|\.x)*)\.\ (.+)\.stl$ ]]; then
            reportIssue "INVALID STL NAME (expected '<part path>. Name.stl')" \
                "$model_dir/$file_name"
            invalid=1
            continue
        fi

        part_path="${BASH_REMATCH[1]}"
        part_name="${BASH_REMATCH[4]}"
        IFS='.' read -r -a part_segments <<<"$part_path"
        part_number="${part_segments[0]}"
        if [[ "$part_number" =~ ^[0-9]+$ ]]; then
            has_numbered_parts=1
            if ((part_number > max_part_number)); then
                max_part_number="$part_number"
            fi
            seen_top_level_parts["$part_number"]=1
        else
            has_root_alternatives=1
        fi

        if [[ -n "${seen_part_paths[$part_path]+x}" ]]; then
            reportIssue "DUPLICATE STL PART PATH ($part_path)" "$model_dir/$file_name"
            invalid=1
        fi
        seen_part_paths["$part_path"]=1

        prefix="${part_segments[0]}"
        for ((segment_index = 1; segment_index < ${#part_segments[@]}; segment_index += 1)); do
            segment="${part_segments[$segment_index]}"
            if [[ "$segment" =~ ^[A-Z]$ ]]; then
                seen_option_slots["$prefix"]=1
            fi
            prefix+=".$segment"
        done

        if [[ "$part_name" =~ ^(.+)\ \(v(.+)\)$ ]]; then
            version="${BASH_REMATCH[2]}"
            if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
                reportIssue "INVALID STL VERSION (expected vMAJOR.MINOR.PATCH)" \
                    "$model_dir/$file_name"
                invalid=1
            fi
        elif [[ "$part_name" == *" (v"* ]]; then
            reportIssue "INVALID STL VERSION (expected vMAJOR.MINOR.PATCH)" \
                "$model_dir/$file_name"
            invalid=1
        fi
    done

    if ((has_root_alternatives && has_numbered_parts)); then
        reportIssue "STL ROOT ALTERNATIVES CANNOT MIX WITH NUMBERED PARTS" "$readme"
        invalid=1
    fi

    for ((part = 1; part <= max_part_number; part += 1)); do
        if [[ -z "${seen_top_level_parts[$part]+x}" ]]; then
            reportIssue "MISSING STL PART NUMBER ($part)" "$readme"
            invalid=1
        fi
    done

    for prefix in "${!seen_option_slots[@]}"; do
        if [[ -n "${seen_part_paths[$prefix]+x}" ]]; then
            reportIssue "STL PART HAS BOTH BASE AND OPTIONS ($prefix)" "$readme"
            invalid=1
        fi
    done

    ((invalid == 0))
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

##--------------------------------------------------------------------------------------------------

checkOriginalDescriptionIsQuoted() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local type
    type="$(getFrontmatterField "$readme" "type")"
    [[ "$type" == "original" ]] && return 0
    if [[ "$type" == "remix" ]] && ! readmeHasPattern "$readme" '^### Original Description$'; then
        return 0
    fi

    if ! awk '
        /^### Original Description$/ { in_description = 1; found = 1; next }
        in_description && /^<!-+>$/ { in_description = 0; next }
        in_description && /^#+[[:space:]]/ { in_description = 0 }
        in_description && /^>/ {
            if (quote_block_ended) invalid = 1
            quote_started = 1
            next
        }
        in_description && /^[[:space:]]*$/ {
            if (quote_started) quote_block_ended = 1
            next
        }
        in_description { invalid = 1 }
        END { exit !(found && quote_started && !invalid) }
    ' "$readme"; then
        reportIssue "ORIGINAL DESCRIPTION MUST BE QUOTED WITH >" "$readme"
        return 1
    fi
}

##--------------------------------------------------------------------------------------------------

##--------------------------------------------------------------------------------------------------

checkRemixAttributionPhrase() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local type
    type="$(getFrontmatterField "$readme" "type")"
    [[ "$type" == "remix" ]] || return 0
    [[ "$REMIX_NOTICE_AVAILABLE" == true ]] || return 0

    if ! awk -v template_file="$REMIX_NOTICE_TEMPLATE" '
        function paragraphMatchesNotice(paragraph, remaining, author_end, url_length) {
            gsub(/[[:space:]]+/, " ", paragraph)
            sub(/^ /, "", paragraph)
            sub(/ $/, "", paragraph)
            if (!template_valid || substr(paragraph, 1, length(prefix)) != prefix) return 0
            remaining = substr(paragraph, length(prefix) + 1)
            author_end = index(remaining, middle)
            if (author_end < 2 || substr(remaining, 1, author_end - 1) ~ /[<>*]/) return 0
            remaining = substr(remaining, author_end + length(middle))
            if (!match(remaining, /^<https?:\/\/[^ >]+>/)) return 0
            url_length = RLENGTH
            remaining = substr(remaining, url_length + 1)
            return remaining == suffix
        }
        BEGIN {
            while ((getline line < template_file) > 0) {
                template = template (template == "" ? "" : " ") line
            }
            close(template_file)
            gsub(/[[:space:]]+/, " ", template)
            author_position = index(template, "<author>")
            url_position = index(template, "<<url-goes-here.com>>")
            if (author_position && url_position > author_position) {
                prefix = substr(template, 1, author_position - 1)
                middle_start = author_position + length("<author>")
                middle = substr(template, middle_start, url_position - middle_start)
                suffix = substr(template, url_position + length("<<url-goes-here.com>>"))
                template_valid = 1
            }
        }
        /^[[:space:]]*$/ {
            if (paragraphMatchesNotice(paragraph)) found = 1
            paragraph = ""
            next
        }
        {
            paragraph = paragraph (paragraph == "" ? "" : " ") $0
        }
        END {
            if (paragraphMatchesNotice(paragraph)) found = 1
            exit !found
        }
    ' "$readme"; then
        reportIssue "REMIX NOTICE DOES NOT MATCH TEMPLATE; use the format in $REMIX_NOTICE_TEMPLATE" \
            "$readme"
        return 1
    fi
}

##--------------------------------------------------------------------------------------------------

checkMoreTextExists() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local model_type
    [[ "$MORE_TEMPLATE_AVAILABLE" == true ]] || return 0
    model_type="$(getFrontmatterField "$readme" "type")"

    if ! awk -v template_file="$MORE_TEMPLATE" -v model_type="$model_type" '
        function checkParagraph() {
            gsub(/[[:space:]]+/, " ", paragraph)
            sub(/^ /, "", paragraph)
            sub(/ $/, "", paragraph)
            if (index(paragraph, required_text)) {
                found = 1
                if (!differences_started) found_before_differences = 1
            }
            paragraph = ""
        }
        BEGIN {
            while ((getline line < template_file) > 0) {
                required_text = required_text (required_text == "" ? "" : " ") line
            }
            close(template_file)
            gsub(/[[:space:]]+/, " ", required_text)
        }
        /^### Differences of the remix compared to the original$/ {
            checkParagraph()
            differences_started = 1
            found_differences = 1
            next
        }
        /^[[:space:]]*$/ {
            checkParagraph()
            next
        }
        {
            paragraph = paragraph (paragraph == "" ? "" : " ") $0
        }
        END {
            checkParagraph()
            if (model_type == "remix") {
                exit !(required_text != "" && found && found_differences &&
                    found_before_differences)
            }
            exit !(required_text != "" && found)
        }
    ' "$readme"; then
        if [[ "$model_type" == "remix" ]]; then
            reportIssue "REQUIRED MORE TEXT MISSING OR OUT OF ORDER; use $MORE_TEMPLATE and place it before the remix differences heading" \
                "$readme"
        else
            reportIssue "REQUIRED MORE TEXT MISSING; include the text in $MORE_TEMPLATE" "$readme"
        fi
        return 1
    fi
}

##--------------------------------------------------------------------------------------------------

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

checkLicenseStatementIsApproved() {
    local model_dir="$1"
    local readme="$model_dir/README.md"
    local readme_line
    local model_type
    local license_found=false
    local invalid_license_type=false
    [[ "$LICENSES_AVAILABLE" == true ]] || return 0
    model_type="$(getFrontmatterField "$readme" "type")"

    while IFS= read -r readme_line; do
        if [[ -n "$readme_line" && -n "${VALID_LICENSE_STATEMENTS[$readme_line]+x}" ]]; then
            license_found=true
            if [[ -z "${VALID_LICENSE_TYPES["$readme_line|$model_type"]+x}" ]]; then
                invalid_license_type=true
            fi
        fi
    done <"$readme"

    if [[ "$invalid_license_type" == true ]]; then
        reportIssue "LICENSE NOT ALLOWED FOR MODEL TYPE '$model_type'; see accepted statements and types in $LICENSES_FILE" \
            "$readme"
        return 1
    fi
    [[ "$license_found" == true ]] && return 0
    reportIssue "LICENSE STATEMENT IS NOT AN APPROVED EXACT MATCH; copy an accepted statement for '$model_type' from $LICENSES_FILE" \
        "$readme"
    return 1
}

runModelChecks() {
    local model_dir="$1"
    local check_function
    local -a checks=(
        checkTitleExists
        checkFolderTitleMatchesReadme
        checkFolderNameHasNoTrailingSpaces
        checkTypeMatchesTitle
        checkCategoryIsValid
        checkCanonicalPreviewReference
        checkPreviewReferenceCountMatchesFiles
        removeBlankLinesBetweenPreviewReferences
        checkPreviewReferencesAreContiguous
        checkBriefExists
        checkTagsExist
        checkAttributionHeadingExists
        checkLicenseHeadingExists
        checkInstructionsFormat
        checkPreviewFileNames
        checkStlNames
        checkAssetsDirectoryIsIgnored
        checkNoPlaceholderLinks
        checkNoTodoMarkers
        checkAttributionMatchesType
        checkOriginalDescriptionIsQuoted
        checkRemixAttributionPhrase
        checkMoreTextExists
        checkSourceUrlExists
        checkLicenseStatementExists
        checkLicenseStatementIsApproved
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
    if git -C "$REPOSITORY_DIR" check-ignore --quiet -- "$readme"; then
        return 0
    fi
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
    if ! loadLicenseStatements; then
        ((ERRORS += 1))
    fi
    checkSupportingTemplateFiles

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

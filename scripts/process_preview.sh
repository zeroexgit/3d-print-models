#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

##==================================================================================================
##	DEPENDENCY CHECKS
##==================================================================================================

requireCommand() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    fi
}

requireCommand magick
requireCommand exiftool
requireCommand stat
requireCommand mktemp
requireCommand mv
requireCommand chmod
requireCommand trash

##==================================================================================================
##	GLOBALS
##==================================================================================================

declare -r MAX_DIMENSION=2048
declare -r MAX_FILE_SIZE=$((1024 * 1024))
declare INPUT_FILE=''
declare OUTPUT_FILE=''
declare TEMPORARY_FILE=''
declare CROPPED_FILE=''

##==================================================================================================
##	UTILITIES
##==================================================================================================

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

cleanupTemporaryFile() {
    if [[ -n "$TEMPORARY_FILE" && -e "$TEMPORARY_FILE" ]]; then
        trash "$TEMPORARY_FILE"
    fi
    if [[ -n "$CROPPED_FILE" && -e "$CROPPED_FILE" ]]; then
        trash "$CROPPED_FILE"
    fi
}

##==================================================================================================
##	CORE FUNCTIONS
##==================================================================================================

getImageDimensions() {
    local image_file="$1"
    local dimensions
    local image_width
    local image_height

    dimensions=$(magick identify -format '%w %h\n' "$image_file") ||
        die "Cannot read image: $image_file"
    IFS=' ' read -r image_width image_height <<<"$dimensions"
    printf '%s %s\n' "$image_width" "$image_height"
}

cropToSquare() {
    local input_file="$1"
    local image_format="$2"
    local output_file="$3"
    local input_dimensions
    local image_width
    local image_height
    local crop_dimension

    input_dimensions=$(getImageDimensions "$input_file") || die "Cannot inspect image: $input_file"
    IFS=' ' read -r image_width image_height <<<"$input_dimensions"
    if [[ "$image_width" != "$image_height" ]]; then
        printf 'Warning: input is not square (%sx%s); cropping around its center.\n' \
            "$image_width" "$image_height" >&2
    fi

    crop_dimension=$image_width
    if [[ "$image_height" -lt "$crop_dimension" ]]; then
        crop_dimension=$image_height
    fi

    magick "$input_file" -auto-orient -gravity center \
        -crop "${crop_dimension}x${crop_dimension}+0+0" +repage \
        -resize "${MAX_DIMENSION}x${MAX_DIMENSION}>" \
        "${image_format}:${output_file}" || die "Image processing failed: $input_file"
}

stripMetadata() {
    local image_file="$1"

    exiftool -all= -overwrite_original "$image_file" >/dev/null ||
        die "Could not remove image metadata: $image_file"
}

reduceImageSize() {
    local max_value="$1"
    local input_file="$2"
    local output_file="$3"
    local quality=90
    local output_size

    while [[ "$quality" -ge 5 ]]; do
        magick "$input_file" -quality "$quality" "JPEG:${output_file}" ||
            die "JPEG compression failed: $input_file"
        output_size=$(stat -c '%s' "$output_file") || die "Cannot read JPEG size: $output_file"
        [[ "$output_size" -le "$max_value" ]] && return 0
        quality=$((quality - 5))
    done

    return 0
}

processImage() {
    local input_file="$1"
    local output_file="$2"
    local processed_dimensions
    local processed_width
    local processed_height
    local image_format
    local output_directory
    local output_basename
    local output_reference
    local output_size

    [[ -f "$input_file" ]] || die "Input file does not exist: $input_file"
    image_format=$(magick identify -format '%m\n' "$input_file") ||
        die "Cannot identify image format: $input_file"
    image_format=${image_format%%$'\n'*}

    output_directory=${output_file%/*}
    output_basename=${output_file##*/}
    [[ -n "$output_directory" ]] || output_directory=$PWD
    [[ -d "$output_directory" ]] || die "Output directory does not exist: $output_directory"

    if [[ -e "$output_file" ]]; then
        output_reference=$output_file
    else
        output_reference=$input_file
    fi

    CROPPED_FILE=$(mktemp --tmpdir="$output_directory" ".~${output_basename}.crop.XXXXXX") ||
        die "Cannot create cropped image temporary file in: $output_directory"
    cropToSquare "$input_file" "$image_format" "$CROPPED_FILE"
    if [[ "$image_format" == 'JPEG' ]]; then
        TEMPORARY_FILE=$(mktemp --tmpdir="$output_directory" ".~${output_basename}.XXXXXX") ||
            die "Cannot create output temporary file in: $output_directory"
        reduceImageSize "$MAX_FILE_SIZE" "$CROPPED_FILE" "$TEMPORARY_FILE"
    else
        TEMPORARY_FILE=$CROPPED_FILE
        CROPPED_FILE=''
    fi
    stripMetadata "$TEMPORARY_FILE"
    chmod --reference="$output_reference" "$TEMPORARY_FILE" ||
        die "Could not preserve output file permissions"

    processed_dimensions=$(getImageDimensions "$TEMPORARY_FILE") ||
        die "Cannot inspect processed image: $input_file"
    IFS=' ' read -r processed_width processed_height <<<"$processed_dimensions"
    output_size=$(stat -c '%s' "$TEMPORARY_FILE") || die "Cannot read processed image size"
    mv -- "$TEMPORARY_FILE" "$output_file" || die "Could not write output image: $output_file"
    TEMPORARY_FILE=''

    if [[ "$output_size" -gt "$MAX_FILE_SIZE" ]]; then
        printf 'Warning: output remains over 1 MB (%s bytes).\n' "$output_size" >&2
    fi

    printf 'Processed %s → %s (%sx%s, %s bytes)\n' \
        "$input_file" "$output_file" "$processed_width" "$processed_height" "$output_size"
}

##==================================================================================================
##	ARGUMENT PARSING
##==================================================================================================

printUsage() {
    printf 'Usage: %s IMAGE [OUTPUT]\n' "${0##*/}"
    printf '   or: %s --input IMAGE [--output OUTPUT]\n' "${0##*/}"
    printf '  -i, --input   Image to resize and strip metadata from\n'
    printf '  -o, --output  Output path (defaults to the input path)\n'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --input)
            [[ $# -ge 2 ]] || die "Missing value for $1"
            [[ -z "$INPUT_FILE" ]] || die 'Specify --input only once'
            INPUT_FILE=$2
            shift 2
            ;;
        -o | --output)
            [[ $# -ge 2 ]] || die "Missing value for $1"
            [[ -z "$OUTPUT_FILE" ]] || die 'Specify --output only once'
            OUTPUT_FILE=$2
            shift 2
            ;;
        -h | --help)
            printUsage
            exit 0
            ;;
        *)
            [[ "$1" != -* ]] || die "Unknown option: $1"
            if [[ -z "$INPUT_FILE" ]]; then
                INPUT_FILE=$1
            elif [[ -z "$OUTPUT_FILE" ]]; then
                OUTPUT_FILE=$1
            else
                die 'Specify only one input and one output image'
            fi
            shift
            ;;
    esac
done

##==================================================================================================
##	MAIN
##==================================================================================================

main() {
    [[ -n "$INPUT_FILE" ]] || die 'An input image is required'
    [[ -n "$OUTPUT_FILE" ]] || OUTPUT_FILE=$INPUT_FILE

    if [[ "$INPUT_FILE" != /* ]]; then
        INPUT_FILE="$PWD/$INPUT_FILE"
    fi
    if [[ "$OUTPUT_FILE" != /* ]]; then
        OUTPUT_FILE="$PWD/$OUTPUT_FILE"
    fi

    trap cleanupTemporaryFile EXIT
    processImage "$INPUT_FILE" "$OUTPUT_FILE"
}

main

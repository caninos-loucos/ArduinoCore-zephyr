#!/bin/bash

set -euo pipefail

#
# ArduinoCore-zephyr package generator
#
# Usage:
#   extra/package_core.sh ARTIFACT VERSION [OUTPUT_FILE]
#
# Example:
#   extra/package_core.sh zephyr_puppy 0.0.3 \
#       distrib/zephyr_puppy_0.0.3.tar.gz
#
# The script must be executed from the ArduinoCore-zephyr root directory.
#

if [ $# -lt 2 ]; then
    echo "Usage: $0 ARTIFACT VERSION [OUTPUT_FILE]"
    exit 1
fi

if [ ! -f platform.txt ]; then
    echo "ERROR: launch this script from the root core folder."
    exit 2
fi

ARTIFACT="$1"
VERSION="$2"
OUTPUT_FILE="${3:-distrib/${ARTIFACT}-${VERSION}.tar.gz}"

TEMP_BOARDS=""
TEMP_PLATFORM=""
TEMP_INC=""
TEMP_EXC=""
TEMP_LIST=""
TEMP_VERBOSE=""

cleanup() {
    [ -z "$TEMP_BOARDS" ]   || rm -f "$TEMP_BOARDS"
    [ -z "$TEMP_PLATFORM" ] || rm -f "$TEMP_PLATFORM"
    [ -z "$TEMP_INC" ]      || rm -f "$TEMP_INC"
    [ -z "$TEMP_EXC" ]      || rm -f "$TEMP_EXC"
    [ -z "$TEMP_LIST" ]     || rm -f "$TEMP_LIST"
    [ -z "$TEMP_VERBOSE" ]  || rm -f "$TEMP_VERBOSE"
}

trap cleanup EXIT

log_msg() {
    local type="${1:-}"
    local msg="${2:-}"

    if [ -n "${GITHUB_WORKSPACE:-}" ]; then
        echo "::${type}::${msg}"
    elif [ -n "$msg" ]; then
        echo "$msg"
    fi
}

error() {
    echo "ERROR: $*" >&2
}

#
# Check that a directory exists and contains actual files.
#
check_nonempty_directory() {
    local dir="$1"
    local description="$2"

    if [ ! -d "$dir" ]; then
        error "$description directory not found:"
        error "  $dir"
        return 1
    fi

    if [ -z "$(find "$dir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        error "$description directory is empty:"
        error "  $dir"
        return 1
    fi

    return 0
}

#
# Check required submodules.
#
# A previous package could be generated with these directories empty when
# the Git submodules had not been initialized. Never generate a release in
# that state.
#
check_submodule() {
    local dir="$1"

    if ! check_nonempty_directory "$dir" "Submodule"; then
        echo
        echo "Initialize the repository submodules with:"
        echo
        echo "  git submodule update --init --recursive"
        echo
        return 1
    fi

    #
    # A populated Git submodule normally has a .git file containing a
    # reference to the parent repository's .git/modules directory.
    #
    # It is allowed in the source tree, but it will not be included in
    # the generated package.
    #
    return 0
}

echo "Checking package dependencies..."

check_submodule "libraries/Arduino_RouterBridge"
check_submodule "libraries/Arduino_RPClite"

#
# ArduinoCore-API may be a symbolic link in the development checkout.
# The tar command below uses --dereference, so the actual API files will
# be stored in the package rather than the symbolic link.
#
if [ ! -e "cores/arduino/api" ]; then
    error "cores/arduino/api does not exist."
    exit 4
fi

if [ -z "$(find -L cores/arduino/api -mindepth 1 -print -quit 2>/dev/null)" ]; then
    error "cores/arduino/api is empty or its symbolic link cannot be resolved."
    exit 4
fi

echo "  OK: ArduinoCore-API available"
echo "  OK: Arduino_RouterBridge available"
echo "  OK: Arduino_RPClite available"
echo

#
# We use variants for include because we filter on file paths,
# and boards for exclude because we remove matching lines from boards.txt.
#
BOARD_DETAILS="$(extra/get_board_details.sh)"

if [ "$ARTIFACT" = "zephyr" ]; then
    INCLUDED_VARIANTS="$(echo "$BOARD_DETAILS" | jq -cr '.[].variant')"
    EXCLUDED_BOARDS=""
elif [ ! -f "extra/artifacts/${ARTIFACT}.json" ]; then
    error "Unknown artifact '$ARTIFACT'."
    exit 3
else
    ARTIFACT_NAME="$(
        grep '"name"' "extra/artifacts/${ARTIFACT}.json" |
            head -n 1 |
            cut -d '"' -f 4
    ) (${VERSION})"

    INCLUDED_VARIANTS="$(
        echo "$BOARD_DETAILS" |
            jq -cr "map(select(.artifact == \"$ARTIFACT\")) | .[].variant"
    )"

    EXCLUDED_BOARDS="$(
        echo "$BOARD_DETAILS" |
            jq -cr "map(select(.artifact != \"$ARTIFACT\")) | .[].board"
    )"
fi

log_msg group \
    "Packaging ${ARTIFACT_NAME:-all variants} ($(basename "$OUTPUT_FILE"))"

#
# Temporary boards.txt containing only the boards belonging to this
# artifact.
#
TEMP_BOARDS="$(mktemp -p . | sed 's,\./,,')"
cp boards.txt "$TEMP_BOARDS"

for board in $EXCLUDED_BOARDS; do
    #
    # Remove normal and commented definitions for excluded boards.
    #
    sed -i "/^\([[:space:]]*#[[:space:]]*\)\?${board}\./d" "$TEMP_BOARDS"
done

#
# Remove consecutive empty lines.
#
sed -i '/^$/N;/^\n$/D' "$TEMP_BOARDS"

#
# Temporary platform.txt containing the correct package name and version.
#
TEMP_PLATFORM="$(mktemp -p . | sed 's,\./,,')"
cp platform.txt "$TEMP_PLATFORM"

if [ -n "${ARTIFACT_NAME:-}" ]; then
    sed -i "s/^name=.*/name=${ARTIFACT_NAME}/" "$TEMP_PLATFORM"
fi

sed -i \
    "s/^version=.*/version=$(extra/get_core_version.sh)/" \
    "$TEMP_PLATFORM"

#
# Read an include/exclude file while ignoring comments and empty lines.
#
declutter_file() {
    [ -f "$1" ] || return 0

    sed \
        -e 's/[[:space:]]*#.*//' \
        -e '/^[[:space:]]*$/d' \
        "$1"
}

#
# Build the list of files and directories to include.
#
TEMP_INC="$(mktemp -p . | sed 's,\./,,')"

echo "$TEMP_BOARDS" >> "$TEMP_INC"
echo "$TEMP_PLATFORM" >> "$TEMP_INC"

declutter_file "extra/artifacts/_common.inc" >> "$TEMP_INC"
declutter_file "extra/artifacts/${ARTIFACT}.inc" >> "$TEMP_INC"

MISSING_FIRMWARE=0

for variant in $INCLUDED_VARIANTS; do
    echo "- $variant"

    if [ ! -d "variants/${variant}" ]; then
        error "Variant directory not found: variants/${variant}"
        MISSING_FIRMWARE=1
        continue
    fi

    echo "variants/${variant}/" >> "$TEMP_INC"

    #
    # Add all firmware files associated with this variant.
    #
    # Do not silently create a package if the firmware is missing.
    #
    shopt -s nullglob
    FIRMWARE_FILES=(firmwares/zephyr-"${variant}".*)
    shopt -u nullglob

    if [ ${#FIRMWARE_FILES[@]} -eq 0 ]; then
        error "No firmware for '${variant}' found."
        MISSING_FIRMWARE=1
        continue
    fi

    printf '%s\n' "${FIRMWARE_FILES[@]}" >> "$TEMP_INC"
done

if [ "$MISSING_FIRMWARE" -ne 0 ]; then
    error "Package generation aborted because required files are missing."
    exit 4
fi

#
# Build the list of files and directories to exclude.
#
TEMP_EXC="$(mktemp -p . | sed 's,\./,,')"

declutter_file "extra/artifacts/_common.exc" >> "$TEMP_EXC"
declutter_file "extra/artifacts/${ARTIFACT}.exc" >> "$TEMP_EXC"

mkdir -p "$(dirname "$OUTPUT_FILE")"
rm -f "$OUTPUT_FILE"

echo
echo "Creating package..."

#
# --dereference
#     Follow symbolic links and store the actual files. This is important
#     for cores/arduino/api, which may be a symlink in the development
#     checkout.
#
# --exclude-vcs
#     Exclude Git/CVS/SVN/etc. metadata.
#
# Additional exclusions make sure GitHub and Git-specific development
# metadata cannot accidentally enter the distribution archive.
#
tar \
    --dereference \
    --create \
    --gzip \
    --file="$OUTPUT_FILE" \
    --exclude-vcs \
    --exclude='.github' \
    --exclude='.github/*' \
    --exclude='.gitignore' \
    --exclude='.gitattributes' \
    --exclude='.gitmodules' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='*.pyo' \
    --exclude='*.swp' \
    --exclude='*.swo' \
    --exclude='*~' \
    -X "$TEMP_EXC" \
    -T "$TEMP_INC" \
    --transform "s,${TEMP_BOARDS},boards.txt," \
    --transform "s,${TEMP_PLATFORM},platform.txt," \
    --transform 's,^,ArduinoCore-zephyr/,'

if [ ! -s "$OUTPUT_FILE" ]; then
    error "Package was not created or is empty."
    rm -f "$OUTPUT_FILE"
    exit 5
fi

echo
echo "Validating package..."

#
# Extract archive listings once. Besides being faster, this avoids
# pipefail/SIGPIPE problems caused by repeatedly piping tar into grep -q.
#
TEMP_LIST="$(mktemp)"
TEMP_VERBOSE="$(mktemp)"

tar -tzf "$OUTPUT_FILE" > "$TEMP_LIST"
tar -tvzf "$OUTPUT_FILE" > "$TEMP_VERBOSE"

#
# No Git metadata may be present.
#
if grep -E \
    '(^|/)\.git($|/)|(^|/)\.github($|/)|(^|/)\.gitignore$|(^|/)\.gitattributes$|(^|/)\.gitmodules$' \
    "$TEMP_LIST" >/dev/null
then
    error "Git-related metadata found inside the package:"
    grep -E \
        '(^|/)\.git($|/)|(^|/)\.github($|/)|(^|/)\.gitignore$|(^|/)\.gitattributes$|(^|/)\.gitmodules$' \
        "$TEMP_LIST" >&2

    rm -f "$OUTPUT_FILE"
    exit 5
fi

echo "  OK: no Git metadata"

#
# No symbolic links may remain in the final archive.
#
# In tar -v output:
#   - = regular file
#   d = directory
#   l = symbolic link
#
if awk '$1 ~ /^l/ { found=1 } END { exit !found }' "$TEMP_VERBOSE"; then
    error "Symbolic links found inside the package:"
    awk '$1 ~ /^l/ { print }' "$TEMP_VERBOSE" >&2

    rm -f "$OUTPUT_FILE"
    exit 5
fi

echo "  OK: no symbolic links"

#
# Verify that ArduinoCore-API was materialized into the archive.
#
if ! grep -Fx \
    'ArduinoCore-zephyr/cores/arduino/api/ArduinoAPI.h' \
    "$TEMP_LIST" >/dev/null
then
    error "ArduinoCore-API was not packaged correctly."
    rm -f "$OUTPUT_FILE"
    exit 5
fi

echo "  OK: ArduinoCore-API present"

#
# Verify that Arduino_RouterBridge contains its actual source files.
# This specifically prevents the empty-submodule problem that occurred
# in previous packages.
#
if ! grep -E \
    '^ArduinoCore-zephyr/libraries/Arduino_RouterBridge/src/[^/]+$' \
    "$TEMP_LIST" >/dev/null
then
    error "Arduino_RouterBridge is empty or incomplete in the package."
    rm -f "$OUTPUT_FILE"
    exit 5
fi

echo "  OK: Arduino_RouterBridge present"

#
# Verify Arduino_RPClite for the same reason.
#
if ! grep -E \
    '^ArduinoCore-zephyr/libraries/Arduino_RPClite/src/[^/]+$' \
    "$TEMP_LIST" >/dev/null
then
    error "Arduino_RPClite is empty or incomplete in the package."
    rm -f "$OUTPUT_FILE"
    exit 5
fi

echo "  OK: Arduino_RPClite present"

#
# Sanity check: boards.txt and platform.txt must have been renamed from
# their temporary filenames to their final archive names.
#
if ! grep -Fx \
    'ArduinoCore-zephyr/boards.txt' \
    "$TEMP_LIST" >/dev/null
then
    error "boards.txt not found in the package."
    rm -f "$OUTPUT_FILE"
    exit 5
fi

if ! grep -Fx \
    'ArduinoCore-zephyr/platform.txt' \
    "$TEMP_LIST" >/dev/null
then
    error "platform.txt not found in the package."
    rm -f "$OUTPUT_FILE"
    exit 5
fi

echo "  OK: boards.txt present"
echo "  OK: platform.txt present"

#
# Final integrity test.
#
if ! gzip -t "$OUTPUT_FILE"; then
    error "gzip integrity test failed."
    rm -f "$OUTPUT_FILE"
    exit 5
fi

echo "  OK: gzip integrity check passed"

if ! tar -tzf "$OUTPUT_FILE" >/dev/null; then
    error "tar integrity test failed."
    rm -f "$OUTPUT_FILE"
    exit 5
fi

echo "  OK: tar integrity check passed"

#
# Information required by Arduino package_index.json.
#
ARCHIVE_NAME="$(basename "$OUTPUT_FILE")"
ARCHIVE_SIZE="$(stat -c %s "$OUTPUT_FILE")"
ARCHIVE_SHA256="$(sha256sum "$OUTPUT_FILE" | awk '{print $1}')"

echo
echo "Package successfully created:"
echo "  $OUTPUT_FILE"

echo
echo "Size:"
du -h "$OUTPUT_FILE"

echo
echo "Files:"
wc -l < "$TEMP_LIST"

echo
echo "Arduino package_index.json values:"
echo
cat <<EOF
{
  "version": "${VERSION}",
  "archiveFileName": "${ARCHIVE_NAME}",
  "checksum": "SHA-256:${ARCHIVE_SHA256}",
  "size": "${ARCHIVE_SIZE}"
}
EOF

echo
echo "Download URL must be added after the archive is uploaded."

log_msg endgroup


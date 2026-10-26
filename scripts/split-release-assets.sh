#!/usr/bin/env bash
# Wrap oversized .tar.xz files in ZIP volumes: <name>.tar.xz.zip.001, .002, ...
# Extract the first volume with 7-Zip to recover the original .tar.xz file.
# .parts lists the ordered ZIP volumes; .sha256 and .size describe the .tar.xz.
# Usage: split-release-assets.sh [--assets DIR] [--limit BYTES] [--dry-run]
set -euo pipefail

ASSETS_DIR=release_assets
# Keep each uploaded volume below GitHub's 2 GiB asset limit.
LIMIT_BYTES=$((1900 * 1024 * 1024))
DRY_RUN=false

usage() {
    echo "usage: $0 [--assets DIR] [--limit BYTES] [--dry-run]" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --assets) ASSETS_DIR="${2:?}"; shift 2 ;;
        --limit) LIMIT_BYTES="${2:?}"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) usage ;;
    esac
done

[[ -d "$ASSETS_DIR" ]] || { echo "no such directory: $ASSETS_DIR" >&2; exit 1; }
[[ "$LIMIT_BYTES" =~ ^[1-9][0-9]*$ ]] || { echo "invalid limit: $LIMIT_BYTES" >&2; exit 2; }
ASSETS_DIR="$(cd "$ASSETS_DIR" && pwd)"
work=''
trap 'if [[ -n "$work" ]]; then rm -rf -- "$work"; fi' EXIT
split_count=0
kept_count=0
shopt -s nullglob

for archive in "$ASSETS_DIR"/*.tar.xz; do
    name="${archive##*/}"
    size="$(stat -c %s "$archive")"
    if (( size <= LIMIT_BYTES )); then
        kept_count=$((kept_count + 1))
        continue
    fi

    echo "packing $name ($size bytes) into ZIP volumes of at most $LIMIT_BYTES bytes"
    digest="$(sha256sum "$archive" | awk '{print $1}')"
    if [[ "$DRY_RUN" == true ]]; then
        echo "  would create ${name}.zip.001, .002, ...; original sha256 $digest"
        split_count=$((split_count + 1))
        continue
    fi

    if command -v 7zz >/dev/null 2>&1; then
        SEVEN_ZIP="$(command -v 7zz)"
    elif command -v 7z >/dev/null 2>&1; then
        SEVEN_ZIP="$(command -v 7z)"
    else
        echo '7-Zip is required for ZIP volumes (Ubuntu: apt-get install 7zip)' >&2
        exit 1
    fi
    stale=("${archive}.zip."[0-9]* "${archive}.part-"*)
    if (( ${#stale[@]} )) || [[ -e "${archive}.parts" || -e "${archive}.sha256" || -e "${archive}.size" ]]; then
        echo "refusing to mix existing volumes or sidecars with $name" >&2
        exit 1
    fi

    for tool in zip split; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "$tool is required for ZIP volumes (Ubuntu: apt-get install zip coreutils)" >&2
            exit 1
        }
    done
    work="$(mktemp -d "${archive}.split.XXXXXX")"
    # 7-Zip 23.01's direct ZIP64 volume writer can fail with EEXIST once the
    # input exceeds 4 GiB. Stream an Info-ZIP ZIP64 archive through GNU split
    # instead; 7-Zip still opens .zip.001 and extracts the original .tar.xz.
    # -0 stores the already-compressed XZ; -j keeps only its filename in the ZIP.
    # pipefail keeps the original intact if either producer or splitter fails.
    echo "creating ZIP64 stream with Info-ZIP; verifying with $SEVEN_ZIP"
    (
        cd "$ASSETS_DIR"
        zip -0 -q -j - -- "$name" |
            split --bytes="$LIMIT_BYTES" --numeric-suffixes=1 --suffix-length=3 \
                - "$work/${name}.zip."
    )
    "$SEVEN_ZIP" t -bd -bso0 "$work/${name}.zip.001"
    volumes=("$work/${name}.zip."[0-9]*)
    (( ${#volumes[@]} )) || { echo "no ZIP volumes produced for $name" >&2; exit 1; }
    mapfile -t volumes < <(printf '%s\n' "${volumes[@]}" | sort -V)
    for volume in "${volumes[@]}"; do
        (( $(stat -c %s "$volume") <= LIMIT_BYTES )) || {
            echo "ZIP volume exceeds the upload limit: $volume" >&2
            exit 1
        }
        printf '%s\n' "${volume##*/}"
    done > "$work/${name}.parts"
    printf '%s  %s\n' "$digest" "$name" > "$work/${name}.sha256"
    printf '%s\n' "$size" > "$work/${name}.size"
    mv -- "${volumes[@]}" "$work/${name}.parts" "$work/${name}.sha256" \
        "$work/${name}.size" "$ASSETS_DIR/"
    rm -rf -- "$work"
    work=''
    # Keep the original until ZIP creation and validation have both succeeded.
    rm -f -- "$archive"
    split_count=$((split_count + 1))
done

echo "ZIP-split archives: $split_count, kept whole: $kept_count (limit $LIMIT_BYTES bytes)"

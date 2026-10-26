#!/usr/bin/env bash
# Split RootFS archives into GitHub Release sized volumes.
#
# GitHub rejects any single release asset larger than 2 GiB. Some templates
# (ArmadaOS ships Steam plus a full gamescope toolchain) exceed that, so each
# oversized archive is cut into fixed size parts that are uploaded instead.
#
# The parts are plain byte ranges of the original archive, so restoring one is
# just `cat`. Every split asset records what it belongs to:
#   <name>.part-aa   the parts, in order
#   <name>.parts     one line per part, so a downloader knows the order
#   <name>.sha256    the SHA-256 of the ORIGINAL archive
#
# The subscription manifests keep describing the original archive name, size and
# hash: splitting is a transport detail, not a different image. A downloader
# concatenates the parts and verifies against <name>.sha256.
#
# Usage: split-release-assets.sh [--assets DIR] [--limit BYTES] [--dry-run]
set -euo pipefail

ASSETS_DIR=release_assets
# Leave headroom below the hard 2 GiB limit: the upload action may add metadata
# and GitHub counts the whole asset, not just the payload.
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

split_count=0
kept_count=0
shopt -s nullglob

for archive in "$ASSETS_DIR"/*.tar.xz; do
    name="$(basename "$archive")"
    size="$(wc -c < "$archive")"

    if (( size <= LIMIT_BYTES )); then
        kept_count=$((kept_count + 1))
        continue
    fi

    echo "splitting $name ($size bytes) into $LIMIT_BYTES byte parts"

    # Hash the whole archive before splitting so the manifest value and the
    # published .sha256 always describe the same bytes.
    digest="$(sha256sum "$archive" | awk '{print $1}')"

    if [[ "$DRY_RUN" == true ]]; then
        parts=$(( (size + LIMIT_BYTES - 1) / LIMIT_BYTES ))
        echo "  would produce $parts parts, sha256 $digest"
        split_count=$((split_count + 1))
        continue
    fi

    work="$(mktemp -d "${archive}.split.XXXXXX")"
    split --bytes="$LIMIT_BYTES" --numeric-suffixes=0 --suffix-length=2 \
        --additional-suffix=.part "$archive" "$work/${name}."
    # split names files <prefix><NN><suffix>; normalise to <name>.part-NN.
    for part in "$work"/*.part; do
        base="$(basename "$part")"
        index="${base#"${name}".}"; index="${index%.part}"
        mv "$part" "$ASSETS_DIR/${name}.part-${index}"
    done
    rm -rf "$work"

    # Publish the part list in upload order and the hash of the whole archive.
    ( cd "$ASSETS_DIR" && ls -1 "${name}".part-* | sort ) > "$ASSETS_DIR/${name}.parts"
    printf '%s  %s\n' "$digest" "$name" > "$ASSETS_DIR/${name}.sha256"

    # The original archive is replaced by its parts; keeping it would upload a
    # file GitHub refuses and double the artifact size.
    rm -f "$archive"
    split_count=$((split_count + 1))
done

echo "split archives: $split_count, kept whole: $kept_count (limit $LIMIT_BYTES bytes)"
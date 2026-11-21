#!/usr/bin/bash
# Fetch the TUI scripts straight from the upstream git tree instead of the rolling
# Gold-bug-tui release.
#
# Why this exists: the rolling release is cut by hand and lags the git tree by days,
# so an image could be assembled from a TUI whose own system detection predates fixes
# already merged upstream -- that is exactly what happened with d4e41c3
# ("fix(tui): treat armada* as fedora in system detection"), which was four days ahead
# of the release revision and made `install-mesa` abort the build with
# "Unsupported system: ArmadaOS-Freedom ...".
#
# This script pins one commit, downloads the GitHub archive for exactly that commit,
# checks the tree and the script syntax, writes the two provenance manifests with real
# per-file digests, and produces the same directory layout install-rootfs-tools.sh
# --tui-dir expects. No copy of the TUI needs to live in this repository.
#
# Usage: scripts/fetch-tui-git.sh --output .build/tui [--ref <branch|tag|commit>]
#                                    [--dry-run]
# Output: <output>/ with droidspaces-*.sh, install-*.sh, lib/*.sh plus
#         Gold-bug-tui-manifest and Gold-bug-tui-files.
#
# Environment:
#   DROIDSPACES_TUI_REF            default ref (main)
#   DROIDSPACES_TUI_REPOSITORY     default Goldzxcbug/droidspaces-package
#   DROIDSPACES_TUI_ARCHIVE_BASE   default https://github.com; set it to a mirror, e.g.
#                                  https://gh.monlor.com/https://github.com, when
#                                  github.com is blocked
set -euo pipefail

readonly MANIFEST_NAME='Gold-bug-tui-manifest'
readonly FILES_NAME='Gold-bug-tui-files'
readonly REPOSITORY="${DROIDSPACES_TUI_REPOSITORY:-Goldzxcbug/droidspaces-package}"
readonly ARCHIVE_BASE="${DROIDSPACES_TUI_ARCHIVE_BASE:-https://github.com}"
readonly DEFAULT_REF="${DROIDSPACES_TUI_REF:-main}"

# install-rootfs-tools.sh refuses to start when any of these is missing, so the fetch
# fails here instead of three Docker layers later.
readonly REQUIRED=(
    droidspaces-tui.sh
    droidspaces-gpu.sh
    droidspaces-video.sh
    install-anland-kde.sh
    install-anland-gnome.sh
    install-anland-next.sh
    install-anland-niri.sh
    install-anland-hyprland.sh
    install-anland-mango.sh
    install-anland-denial.sh
    install-mesa.sh
    install-hangover-wine.sh
    install-winefonts.sh
    lib/anland-common.sh
    lib/anland-archive-common.sh
    lib/anland-compositor-common.sh
)

log() { printf 'fetch-tui-git: %s\n' "$*" >&2; }
die() { printf 'fetch-tui-git: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed -e '${/^set -euo/d;}' -e 's/^# \{0,1\}//'
}

OUTPUT=''
REF=$DEFAULT_REF
DRY_RUN=false

while (($#)); do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            OUTPUT=$2
            shift 2
            ;;
        --output=*)
            OUTPUT=${1#*=}
            shift
            ;;
        --ref)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            REF=$2
            shift 2
            ;;
        --ref=*)
            REF=${1#*=}
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'fetch-tui-git: unsupported argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n $OUTPUT ]] || { printf 'fetch-tui-git: --output is required\n' >&2; usage >&2; exit 2; }
[[ -n $REF ]] || die 'ref must not be empty'

for tool in tar gzip sha256sum bash mktemp find realpath sort cut; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required command: $tool"
done

# --- resolve the ref to a commit ----------------------------------------------------
# A 40-hex ref is already a commit. Anything else is looked up with git ls-remote when
# git is available, so the manifest records the commit actually fetched rather than a
# branch name that may move later. Downloading is always done by commit.
resolve_commit() {
    local ref=$1
    if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
        printf '%s' "$ref"
        return 0
    fi
    if command -v git >/dev/null 2>&1; then
        local line
        line=$(git ls-remote "https://github.com/$REPOSITORY" "refs/heads/$ref" "refs/tags/$ref^{}" "refs/tags/$ref" 2>/dev/null | head -1 || true)
        if [[ -n $line ]]; then
            printf '%s' "${line%%[[:space:]]*}"
            return 0
        fi
    fi
    printf '%s' ''
}

COMMIT=$(resolve_commit "$REF")
if [[ -n $COMMIT ]]; then
    TARGET=$COMMIT
    REVISION=$COMMIT
    RELEASE_LABEL=${REF}
else
    # No way to turn the ref into a commit here. Fetch the ref itself; the manifest then
    # records the ref and says so, instead of pretending to be a pinned revision.
    TARGET=$REF
    REVISION="refs/heads/$REF"
    RELEASE_LABEL=${REF}
    log "warning: could not resolve $REF to a commit; fetching the ref directly"
fi
log "repository $REPOSITORY, ref $REF -> $REVISION"

URL="${ARCHIVE_BASE%/}/$REPOSITORY/archive/$TARGET.tar.gz"
log "downloading $URL"
[[ $DRY_RUN == true ]] && { log 'dry run: no download, no output'; exit 0; }

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

archive=$work/archive.tar.gz
if ! curl -fL --retry 3 --retry-delay 1 --connect-timeout 30 -o "$archive.part" "$URL"; then
    die "cannot download $URL (set DROIDSPACES_TUI_ARCHIVE_BASE to a mirror when github.com is blocked)"
fi
mv -f "$archive.part" "$archive"

# --- check the tree ----------------------------------------------------------------
# GitHub archives wrap everything in one top directory named after the repo and the ref,
# so it cannot be guessed; take it from the archive itself and refuse anything else.
mapfile -t entries < <(tar -tzf "$archive" | cut -d/ -f1 | sort -u)
[[ ${#entries[@]} -eq 1 && -n ${entries[0]} ]] ||
    die 'archive does not have the single top directory GitHub uses'
top=${entries[0]}
tar -xzf "$archive" -C "$work" --no-same-owner --no-same-permissions
tuidir=$work/$top/scripts/tui
[[ -d $tuidir ]] || die "archive has no scripts/tui directory (top dir: $top)"
[[ -f $tuidir/install-mesa.sh ]] || die 'archive lacks install-mesa.sh'

# Reject anything that could escape the staging directory when copied.
if find "$tuidir" -name '.git*' -o -type l | grep -q .; then
    die 'scripts/tui contains symlinks or git metadata; refusing to stage it'
fi

stage=$work/stage
mkdir -p "$stage"
cp -a "$tuidir/." "$stage/"

for name in "${REQUIRED[@]}"; do
    [[ -f $stage/$name ]] || die "missing TUI file: $name"
done

# The build installs every .sh from lib/, so a syntax error there would only surface
# inside the image.
while IFS= read -r -d '' script; do
    bash -n "$script" || die "syntax error in ${script#"$stage"/}"
done < <(find "$stage" -type f -name '*.sh' -print0)

# --- provenance manifests ----------------------------------------------------------
# Same tab layout as the release manifests, but every digest is computed from the tree
# that is about to be staged, and revision names the commit actually downloaded.
manifest=$stage/$MANIFEST_NAME
files=$stage/$FILES_NAME
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
    printf 'format=1\n'
    printf 'release_tag=git-%s\n' "${REVISION:0:12}"
    printf 'revision=%s\n' "$REVISION"
    printf 'generated_at=%s\n' "$stamp"
    printf 'sha256\tsize\trole\ttarget\tasset\n'
} >"$manifest"
{
    printf 'format=1\n'
    printf 'release_tag=git-%s\n' "${REVISION:0:12}"
    printf 'revision=%s\n' "$REVISION"
    printf 'generated_at=%s\n' "$stamp"
    printf 'sha256\tsize\trole\ttarget\tasset\n'
} >"$files"

while IFS= read -r -d '' path; do
    name=${path#"$stage"/}
    [[ $name == "$MANIFEST_NAME" || $name == "$FILES_NAME" ]] && continue
    digest=$(sha256sum "$path" | cut -d' ' -f1)
    size=$(stat -c %s "$path")
    printf '%s\t%s\tgit\t-\t%s\n' "$digest" "$size" "$name" >>"$files"
done < <(find "$stage" -type f -print0 | sort -z)
printf '%s\t%s\tgit\t-\t%s\n' "$(sha256sum "$files" | cut -d' ' -f1)" "$(stat -c %s "$files")" "$FILES_NAME" >>"$manifest"

# --- stage atomically --------------------------------------------------------------
OUTPUT=${OUTPUT%/}
[[ -n $OUTPUT && $OUTPUT != / ]] || die '--output cannot be the filesystem root'
OUTPUT="$(realpath -m -- "$OUTPUT")"
[[ $OUTPUT != / ]] || die '--output cannot be the filesystem root'
mkdir -p -- "${OUTPUT%/*}"
replace=$(mktemp -d "${OUTPUT%/*}/.${OUTPUT##*/}.fetch.XXXXXXXX")
chmod 0755 "$replace"
cp -a "$stage/." "$replace/"
if [[ -e $OUTPUT || -L $OUTPUT ]]; then
    [[ -d $OUTPUT && ! -L $OUTPUT ]] || die "output exists and is not a plain directory: $OUTPUT"
    mv -T -- "$OUTPUT" "$replace.old"
    mv -T -- "$replace" "$OUTPUT"
    rm -rf -- "$replace.old"
else
    mv -T -- "$replace" "$OUTPUT"
fi

log "staged $(find "$OUTPUT" -type f | wc -l) files at $OUTPUT"
log "revision $(printf '%s' "$REVISION")"
log "install-mesa armada mapping: $(grep -c 'armada' "$OUTPUT/install-mesa.sh" || true) line(s)"
printf '%s\n' "$OUTPUT"
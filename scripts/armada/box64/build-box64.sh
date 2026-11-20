#!/usr/bin/bash
# Build box64 from a pinned upstream commit and register it as /usr/bin/box64.
#
# Why not the distribution package: Fedora ships box64 0.3.6, whose dynarec does
# not implement `MOVQ xmm, FS:[abs32]`. Godot's .NET runtime emits that form for
# TLS access all the time, so every .NET game dies with SIGILL on an
# unimplemented opcode. Upstream 0.4.4 implements it and the same game runs.
#
# The binary is deliberately not placed directly at /usr/bin/box64: alternatives
# owns that path, so a later package transaction cannot silently replace the
# emulator with an older build. Priority 200 keeps this build ahead of the
# distribution one (priority 0 by default).
set -eu

REPOSITORY=${BOX64_REPOSITORY:-https://github.com/ptitSeb/box64.git}
# Pinned: this is the revision the image was built and tested against. Bump it
# only together with a rebuild and a run of an actual .NET game, because the
# dynarec opcode coverage is what decides whether games start at all.
COMMIT=${BOX64_COMMIT:-2f130fab1d6e1a4ee8a71dc60cfdfcc839ad192a}
CACHE=${CACHE:-/var/tmp/box64-build}
JOBS=${JOBS:-$(nproc)}
INSTALL=0

usage() {
    cat <<'EOF'
usage: build-box64 [--jobs N] [--install] [--cache DIR] [--help]

  --jobs N     parallel build jobs (default: nproc)
  --install    install the built binary and register it through alternatives
  --cache DIR  keep the source checkout and build tree here
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jobs) JOBS=${2:?--jobs needs a value}; shift 2 ;;
        --install) INSTALL=1; shift ;;
        --cache) CACHE=${2:?--cache needs a value}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

SRC="$CACHE/box64"
BUILD="$CACHE/build"
DEST=/usr/local/libexec/box64

# Only install what is missing, and remember it so the build-only packages can be
# dropped again in the same layer (a compiler left in the image is pure weight).
DEPS=(git cmake make gcc gcc-c++ binutils)
ADDED=()
for dep in "${DEPS[@]}"; do
    rpm -q "$dep" >/dev/null 2>&1 || ADDED+=("$dep")
done
if [[ ${#ADDED[@]} -gt 0 ]]; then
    dnf -y install --setopt=install_weak_deps=False "${ADDED[@]}"
fi
cleanup_deps() {
    if [[ ${#ADDED[@]} -gt 0 && ${KEEP_BUILD_DEPS:-0} != 1 ]]; then
        dnf -y remove "${ADDED[@]}" || true
    fi
}
trap cleanup_deps EXIT

mkdir -p "$CACHE"

# Sources come from git when the transport works, from a codeload tarball when it
# does not (github's git endpoint times out on some networks while the HTTPS
# archive download still works), and are reused when the checkout is already
# there. All three paths end at the same pinned COMMIT.
prepare_source() {
    if [[ -d "$SRC/.git" ]] && git -C "$SRC" cat-file -e "${COMMIT}^{commit}" 2>/dev/null; then
        echo "reusing checkout at $SRC"
        git -C "$SRC" checkout --quiet --detach "$COMMIT"
        return 0
    fi
    rm -rf "$SRC"
    if git clone --quiet "$REPOSITORY" "$SRC" 2>/dev/null &&
       git -C "$SRC" checkout --quiet --detach "$COMMIT"; then
        return 0
    fi
    # codeload wants "<owner>/<repo>"; strip the host prefix and any .git suffix
    # (bash ERE has no non-greedy repeat, so this cannot be one expression).
    slug=$(printf '%s' "$REPOSITORY" |
        sed -E 's#^.*github\.com[:/]+##; s#/+$##; s#\.git$##')
    case "$slug" in
        */*) ;;
        *) slug="" ;;
    esac
    if [[ -z "$slug" ]]; then
        echo "cannot derive a codeload path from $REPOSITORY" >&2
        return 1
    fi
    url="https://codeload.github.com/$slug/tar.gz/$COMMIT"
    echo "git transport failed, falling back to $url"
    rm -rf "$SRC"
    mkdir -p "$SRC"
    curl -fL --retry 3 --connect-timeout 30 -o "$CACHE/box64-$COMMIT.tar.gz" "$url"
    tar -xzf "$CACHE/box64-$COMMIT.tar.gz" -C "$SRC" --strip-components=1
}
prepare_source

# NOGIT keeps the runtime banner free of a `git describe` that would fail here.
rm -rf "$BUILD"
cmake -S "$SRC" -B "$BUILD" \
    -DARM_DYNAREC=ON \
    -DNOGIT=ON \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build "$BUILD" --parallel "$JOBS"

if [[ "$INSTALL" != 1 ]]; then
    echo "build ready: $BUILD/box64"
    exit 0
fi

# Take the version from the binary itself, so it is identical whether the source
# came from a git checkout or from a tarball (which has no tags to describe).
# box64 writes --version to stderr, hence 2>&1.
VERSION=$("$BUILD/box64" --version 2>&1 | sed -nE 's/.*[vV]([0-9][0-9.]*).*/\1/p' | head -1)
NAME="box64-${VERSION:-${COMMIT:0:12}}"
install -d -m 0755 "$DEST"
# strip -o keeps the build tree untouched and writes the stripped copy directly.
strip -o "$DEST/$NAME" "$BUILD/box64"
chmod 0755 "$DEST/$NAME"
if command -v update-alternatives >/dev/null 2>&1; then
    update-alternatives --install /usr/bin/box64 box64 "$DEST/$NAME" 200
    update-alternatives --set box64 "$DEST/$NAME"
else
    # No chkconfig in this image: a plain copy keeps /usr/bin/box64 working, at
    # the cost of losing the priority guarantee against a later package update.
    install -m 0755 "$DEST/$NAME" /usr/bin/box64
fi
/usr/bin/box64 --version
echo "installed: $DEST/$NAME"
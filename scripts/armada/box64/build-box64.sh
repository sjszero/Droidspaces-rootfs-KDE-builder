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
BUILD=${BOX64_BUILD_DIR:-"$CACHE/box64-build"}
# Patches come from one directory, not from a per-patch variable: the image build
# once applied only the patch it knew by name and silently skipped the other.
PATCH_DIR=${BOX64_PATCH_DIR:-"$(dirname -- "$(realpath -- "$0")")/patches"}
if [[ ! -d $PATCH_DIR ]]; then
    PATCH_DIR=/usr/local/share/armada/box64
fi
if [[ ! -d $PATCH_DIR ]]; then
    printf 'box64: patch directory not found (script directory and /usr/local/share/armada/box64)\n' >&2
    exit 1
fi
DEST=/usr/local/libexec/box64

# Only install what is missing, and remember it so the build-only packages can be
# dropped again in the same layer (a compiler left in the image is pure weight).
DEPS=(git cmake make gcc gcc-c++ binutils patch)
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

# Every patch in patches/ applies the same way: a reverse dry-run that succeeds
# means the hunk is already in the tree (a cached checkout), otherwise all hunks
# are verified before anything is written.
for patch_file in "$PATCH_DIR"/*.patch; do
    [[ -f "$patch_file" ]] || continue
    patch_name=${patch_file##*/}
    if patch --force --reverse --dry-run --fuzz=0 -d "$SRC" -p1 -i "$patch_file" >/dev/null 2>&1; then
        echo "already applied: $patch_name"
        continue
    fi
    patch --force --dry-run --fuzz=0 -d "$SRC" -p1 -i "$patch_file"
    patch --force --fuzz=0 -d "$SRC" -p1 -i "$patch_file"
    echo "applied: $patch_name"
done

# NOGIT keeps the runtime banner free of a `git describe` that would fail here.
# BOX32 adds the i386 front end: without it box64 can only load x86_64 guests,
# and the Steam client people actually run here is a 32-bit binary
# (ubuntu12_32/steam, e_machine 3). Upstream labels the option experimental, but
# measured on this image it starts the client and survives its copy relocations;
# patches/box32-sched-cpualloc.patch covers the two glibc symbols box64 leaves
# unexported, which otherwise abort the guest's PLT resolver with
#   [BOX32] Error: PltResolver32: Symbol __sched_cpualloc ... not found
rm -rf "$BUILD"
cmake -S "$SRC" -B "$BUILD" \
    -DARM_DYNAREC=ON \
    -DNOGIT=ON \
    -DBOX32=ON \
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
# /usr/bin/box64 is a real file, not an alternatives link, and that is on
# purpose -- same reasoning as /usr/bin/FEX in build-fex.sh.
#
# Originally this script registered itself through alternatives with priority
# 200. Fedora's own box64 package registers with 300, so a later `dnf install
# box64` would silently take the path over and every wrapper here would start
# running a different emulator. A plain file turns that race into an ordinary
# rpm file conflict: the transaction reports it instead of quietly winning.
if command -v update-alternatives >/dev/null 2>&1; then
    update-alternatives --remove box64 "$DEST/$NAME" >/dev/null 2>&1 || true
fi
install -d -m 0755 /usr/local/bin
install -m 0755 "$DEST/$NAME" /usr/bin/box64
# Historical location kept as a symlink so anything that recorded
# /usr/local/bin/box64 keeps resolving to the same real binary.
ln -sfn /usr/bin/box64 /usr/local/bin/box64

# box64 is the default binfmt_misc interpreter for x86 / x86-64 ELF binaries.
#
# No "P" flag here, and that is deliberate: with P the kernel passes the original
# argv[0] ahead of the binary path, box64 takes that as the program name, and
# every guest then sees its own path as an extra argument (measured: `echo one
# two` printed the path, `uname -m` reported "extra operand <path>"). FEX
# reorders argv itself and does keep the flag -- the two are not interchangeable
# on this point.
#
# FEX can claim the same ELF magic, and binfmt_misc prefers the handler registered
# *last* (measured), so registration order decides the winner. `/usr/bin/fex-binfmt
# on|off` (installed by build-fex.sh) registers one side and drops the other for
# the duration of a Steam session; this file only decides the boot default.

# The binfmt_misc entry list lives in box64-binfmt.conf: next to this script in a
# checkout, in /usr/local/share/armada/box64 in the image. It is the file the boot
# unit reads and the RPM packages, so adding a machine never needs a second edit
# here -- the image used to carry its own copy of this list instead.
BINFMT_SRC=${BOX64_BINFMT_CONF:-"$(dirname -- "$(realpath -- "$0")")/box64-binfmt.conf"}
if [[ ! -r $BINFMT_SRC ]]; then
    BINFMT_SRC=/usr/local/share/armada/box64/box64-binfmt.conf
fi
if [[ ! -r $BINFMT_SRC ]]; then
    printf 'box64: binfmt config not readable (script directory and /usr/local/share/armada/box64)\n' >&2
    exit 1
fi
install -d -m 0755 /usr/lib/binfmt.d
install -m 0644 "$BINFMT_SRC" /usr/lib/binfmt.d/box64.conf
# Registering here too keeps a running container in step with a fresh boot.
if [[ -x /usr/libexec/armada/box64-binfmt ]] && grep -q '^binfmt_misc' /proc/mounts 2>/dev/null; then
    /usr/libexec/armada/box64-binfmt || echo 'box64: binfmt registration failed; see box64-binfmt.service' >&2
fi
/usr/bin/box64 --version
echo "installed: $DEST/$NAME"
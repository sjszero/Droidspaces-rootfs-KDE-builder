#!/usr/bin/bash
# Build the box64-armada RPM.
#
# The package is meant to be handed to people who already run an ArmadaOS
# container: installing it upgrades box64 in place (emulator, tuned rcfile,
# x86-64 libraries, binfmt registration, Steam compatibility tool) instead of
# asking them to rebuild the image.
#
# Usage:  scripts/armada/box64/rpm/build-rpm.sh
# Output: <repo>/artifacts/box64-armada-<version>-<release>.<dist>.aarch64.rpm
#
# Sources:
#   * box64 tarball   - codeload archive of the pinned commit, cached under
#                       ~/.cache/box64-rpm/cache so rebuilds stay offline;
#   * x86-64 libs     - tarball of /usr/lib/box64-x86_64-linux-gnu as deployed by
#                       install-x86-64-libs.sh (override with BOX64_X86_LIBS_DIR);
#   * everything else - this repo, copied as-is, so the RPM can never drift from
#                       what the container actually runs.
set -euo pipefail

RPMDIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ARMDIR=$(cd -- "$RPMDIR/.." && pwd)
REPO=$(cd -- "$ARMDIR/../../.." && pwd)
SPEC=$RPMDIR/box64-armada.spec

TOPDIR=${BOX64_RPM_TOPDIR:-$HOME/.cache/box64-rpm}
CACHE=$TOPDIR/cache
SOURCES=$TOPDIR/SOURCES
ARTIFACTS=$REPO/artifacts
LIBS_DIR=${BOX64_X86_LIBS_DIR:-/usr/lib/box64-x86_64-linux-gnu}

log() { printf 'build-rpm: %s\n' "$*" >&2; }
die() { printf 'build-rpm: %s\n' "$*" >&2; exit 1; }

# The spec is the single source of truth for version and commit.
VERSION=$(sed -n -E 's/^Version:[[:space:]]+//p' "$SPEC" | head -1)
RELEASE=$(sed -n -E 's/^Release:[[:space:]]+([0-9]+).*/\1/p' "$SPEC" | head -1)
COMMIT=$(sed -n -E 's/^%global[[:space:]]+commit[[:space:]]+//p' "$SPEC" | head -1)
[[ -n $VERSION && -n $COMMIT ]] || die "cannot read Version/commit from $SPEC"
DIST=$(rpm --eval '%{?dist}')
log "packaging box64 $VERSION (commit ${COMMIT:0:12}) release $RELEASE$DIST"

for tool in rpmbuild cmake gcc g++ make tar; do
    command -v "$tool" >/dev/null || die "missing build tool: $tool"
done

rm -rf "$TOPDIR/BUILD" "$TOPDIR/BUILDROOT" "$SOURCES"
mkdir -p "$CACHE" "$SOURCES" "$TOPDIR/RPMS" "$TOPDIR/SPECS" "$TOPDIR/SRPMS"

# --- box64 source tarball ---------------------------------------------------
# A local checkout of the same commit can stand in for the download (Handy when
# the network is slow): BOX64_SOURCE_TREE=/path/to/box64 build-rpm.sh
TARBALL=$CACHE/box64-$COMMIT.tar.gz
if [[ ! -s $TARBALL ]]; then
    if [[ -n ${BOX64_SOURCE_TREE:-} ]]; then
        [[ -f $BOX64_SOURCE_TREE/CMakeLists.txt ]] ||
            die "$BOX64_SOURCE_TREE does not look like a box64 source tree"
        log "packing local source tree $BOX64_SOURCE_TREE"
        # %setup -n box64-<commit> wants that exact top directory, and a leftover
        # build directory would only bloat the archive.
        tar -czf "$TARBALL.part" -C "$BOX64_SOURCE_TREE" \
            --exclude=./build --transform "s,^\.,box64-$COMMIT," .
        mv "$TARBALL.part" "$TARBALL"
    else
        URL=https://codeload.github.com/ptitSeb/box64/tar.gz/$COMMIT
        log "downloading $URL (or set BOX64_SOURCE_TREE to reuse a local checkout)"
        curl -fL --retry 3 --connect-timeout 30 -o "$TARBALL.part" "$URL" ||
            die "cannot download the box64 source tarball (network needed once)"
        mv "$TARBALL.part" "$TARBALL"
    fi
fi
# %setup -n box64-<commit> needs exactly this layout. `head` closes the pipe on
# the first entry, so tar exits on SIGPIPE; pipefail would turn that into a
# silent abort of the whole script.
first=$(tar -tzf "$TARBALL" | head -1 | cut -d/ -f1 || true)
[[ $first == box64-$COMMIT ]] ||
    die "unexpected tarball layout: top directory is '$first', expected box64-$COMMIT"
install -m 0644 "$TARBALL" "$SOURCES/box64-$VERSION.tar.gz"
log "source: $(du -h "$TARBALL" | cut -f1) $(basename "$TARBALL")"

# --- x86-64 libraries box64 cannot wrap -------------------------------------
[[ -d $LIBS_DIR ]] || die "$LIBS_DIR is missing; run install-x86-64-libs.sh first"
count=$(find "$LIBS_DIR" -maxdepth 1 -name '*.so*' | wc -l)
(( count >= 18 )) || die "$LIBS_DIR holds only $count libraries, expected 18"
# Packed as "./*" so %install can simply extract into the hardcoded directory;
# tar keeps the symlinked sonames and --owner/--group keep the archive reproducible.
tar -czf "$SOURCES/box64-x86_64-libs.tar.gz" -C "$LIBS_DIR" --owner=0 --group=0 .
log "libs: $count files, $(du -h "$SOURCES/box64-x86_64-libs.tar.gz" | cut -f1)"

# --- files that come straight out of the repo -------------------------------
install -m 0644 "$ARMDIR/box64.box64rc" "$SOURCES/box64.box64rc"
install -m 0755 "$ARMDIR/box64-binfmt" "$SOURCES/box64-binfmt"
install -m 0644 "$ARMDIR/box64-binfmt.service" "$SOURCES/box64-binfmt.service"
install -m 0755 "$ARMDIR/box64-run" "$SOURCES/box64-run"
install -m 0644 "$ARMDIR/compatibilitytool.vdf" "$SOURCES/compatibilitytool.vdf"
install -m 0644 "$ARMDIR/toolmanifest.vdf" "$SOURCES/toolmanifest.vdf"
install -m 0644 "$RPMDIR/README.md" "$SOURCES/README.md"
log "config: box64rc, binfmt script+unit, Steam tool, README"

# --- build ------------------------------------------------------------------
# rpmbuild's output goes to a log file: this takes minutes, and on failure the
# tail is what matters. Piping it would also swallow the exit status.
LOG=$TOPDIR/rpmbuild.log
# Clear previous results first: a package left over from an earlier run must never
# be picked up and shipped as if it were the one just built.
rm -f "$TOPDIR"/RPMS/*/box64-armada-*.rpm
log "rpmbuild starting (topdir $TOPDIR, log $LOG)"
if ! rpmbuild -bb "$SPEC" \
        --define "_topdir $TOPDIR" \
        --define "_smp_build_ncpus $(nproc)" >"$LOG" 2>&1; then
    tail -n 30 "$LOG" >&2
    die "rpmbuild failed; full log: $LOG"
fi
tail -n 3 "$LOG" >&2

RPM=$(find "$TOPDIR/RPMS" -name 'box64-armada-*.rpm' | head -1)
[[ -n $RPM ]] || die "rpmbuild reported success but wrote no rpm"

# --- verify -----------------------------------------------------------------
# The two things this package can silently get wrong are dependency metadata
# (x86-64 libraries leaking into an aarch64 package) and an unstripped binary,
# so both are checked here instead of by eye.
provides=$(rpm -qp --provides "$RPM" 2>/dev/null)
requires=$(rpm -qp --requires "$RPM" 2>/dev/null)
if grep -qE '^lib(stdc\+\+|icu|curl|gcc_s|nghttp)' <<<"$provides"; then
    die "package advertises x86-64 sonames as provides: $(grep -cE '^lib(stdc\+\+|icu|curl|gcc_s|nghttp)' <<<"$provides") lines"
fi
if grep -qE '^lib(ssl|crypto|ssh|ldap|ngtcp2|brotli|psl|idn2)' <<<"$requires"; then
    die "package requires libraries only the emulated libcurl uses"
fi
grep -q '^glibc' <<<"$requires" || die "package does not declare its glibc requirement"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && rpm2cpio "$RPM" | cpio -idm --quiet ./usr/bin/box64 2>/dev/null)
version=$("$tmp/usr/bin/box64" --version 2>&1 | head -1)
[[ $version == *v0.4* ]] || die "packaged binary does not run: ${version:-no output}"
# box64 builds with LTO and is ~21 MB even stripped, so size says nothing; what
# matters is that no debug sections were carried over. Unstripped it was 29 MB.
[[ $(readelf -S "$tmp/usr/bin/box64" | grep -c '\.debug_') -eq 0 ]] ||
    die "packaged binary still carries debug sections (strip did not run)"
log "binary check: $version, $(( $(stat -c %s "$tmp/usr/bin/box64") / 1024 / 1024 )) MiB stripped, 0 debug sections"

mkdir -p "$ARTIFACTS"
cp -f "$RPM" "$ARTIFACTS/"
OUT=$ARTIFACTS/$(basename "$RPM")

log "built $(basename "$OUT") ($(du -h "$OUT" | cut -f1))"
log "sha256 $(sha256sum "$OUT" | cut -d' ' -f1)"
printf '%s\n' "$OUT"
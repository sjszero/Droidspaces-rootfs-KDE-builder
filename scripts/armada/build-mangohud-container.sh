#!/usr/bin/bash
# Build the ArmadaOS MangoHud package with the Droidspaces container metric patch.
#
# Why this exists
# ---------------
# ArmadaOS ships mangohud-0.8.4-1.fc44.armada, built from ~/armada/packages/mangohud.
# That build is tuned for bare-metal Qualcomm hardware and reads sysfs paths a
# container does not mount:
#
#   * it reads only devfreq `cur_freq` (Hz) for the GPU clock, but a Droidspaces
#     container exposes the older kgsl-3d0 layout where the clock is
#     `clock_mhz` (MHz), so GPU clock/load/temperature all read 0;
#   * /sys/class/hwmon does not exist, so the msm GPU hwmon node is unreachable
#     and every scan logs an error.
#
# scripts/armada/mangohud-container-metrics.patch fixes both. This script
# applies it on top of the armada patch set and produces a drop-in RPM.
#
# What it needs
# -------------
#   ~/armada/packages/mangohud   spec, BASE.env and the 9 armada patches
#   network (first run)          upstream tarball + 5 meson subprojects
#
# Everything is cached under $CACHE so later runs work offline.
#
# Two host quirks this script works around, both documented so they are not
# rediscovered the hard way:
#
#  1. glfw-devel cannot be installed. It requires pkgconfig(dri), which comes
#     from mesa-libGL-devel, and this image excludes `mesa*` in /etc/dnf/dnf.conf
#     to keep the pinned Mesa/Turnip stack. Bypassing the exclude with
#     `--setopt=exclude=` upgrades Mesa and breaks KGSL, so instead the package
#     is downloaded and only the headers, glfw3.pc and the .so symlink are
#     extracted. Nothing from mesa is touched.
#
#  2. rpmbuild's BuildRequires check cannot be satisfied for pkgconfig(dri) and
#     pkgconfig(glfw3): dri.pc exists on disk but no RPM owns it after (1).
#     `--nodeps` skips that gate only; the real compilation still links against
#     the extracted glfw.
#
# Usage:
#   build-mangohud-container.sh [--version X.Y.Z] [--jobs N] [--keep]
#                               [--dry-run] [--install]
#
#   --version   upstream MangoHud version; default comes from armada's BASE.env
#   --jobs      parallel compile jobs; default $(nproc)
#   --keep      keep the build tree
#   --dry-run   resolve inputs and print the plan, build nothing
#   --install   dnf-install the resulting RPM (replacing the installed one)
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$HERE/../.." 2>/dev/null && pwd -P || printf '%s' "$HERE")
ARMADA_ROOT=${ARMADA_ROOT:-$HOME/armada}
ARMADA_PKG=$ARMADA_ROOT/packages/mangohud
# PATCH may be overridden because the image build copies the script to
# /usr/local/sbin while the patch lands in /tmp.
PATCH=${PATCH:-$HERE/mangohud-container-metrics.patch}
CACHE=${CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mangohud-container-build}
JOBS=${JOBS:-$(nproc)}
VERSION=${VERSION:-}
KEEP=0
DRY_RUN=0
DO_INSTALL=0

log() { printf '[mangohud] %s\n' "$*"; }
die() { printf '[mangohud] error: %s\n' "$*" >&2; exit 1; }

while (( $# )); do
    case $1 in
        --version) VERSION=${2:?--version needs a value}; shift 2 ;;
        --jobs)    JOBS=${2:?--jobs needs a value}; shift 2 ;;
        --keep)    KEEP=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --install) DO_INSTALL=1; shift ;;
        -h|--help) sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die "invalid --jobs: $JOBS"

# ---- inputs ----------------------------------------------------------------
[[ -d $ARMADA_PKG ]] || die "armada mangohud recipe not found: $ARMADA_PKG"
[[ -f $ARMADA_PKG/mangohud.spec ]] || die "missing spec: $ARMADA_PKG/mangohud.spec"
[[ -f $PATCH ]] || die "missing container patch: $PATCH"

if [[ -z $VERSION ]]; then
    # shellcheck disable=SC1091
    VERSION=$( . "$ARMADA_PKG/BASE.env" && printf '%s' "${VERSION:-}" )
    [[ -n $VERSION ]] || die "cannot determine version from $ARMADA_PKG/BASE.env"
fi

mapfile -t ARMADA_PATCHES < <(find "$ARMADA_PKG/patches" -maxdepth 1 -type f -name '*.patch' | sort)
(( ${#ARMADA_PATCHES[@]} )) || die "no armada patches found in $ARMADA_PKG/patches"

# ARMADA_MARCH is what makes the armada package Armada-specific. Read it from
# the recipe's toolchain.env instead of hardcoding, so a flag change upstream
# is picked up here too.
MARCH=""
if [[ -f $ARMADA_ROOT/packages/toolchain.env ]]; then
    MARCH=$(sed -n 's/^ARMADA_MARCH="\(.*\)"$/\1/p' "$ARMADA_ROOT/packages/toolchain.env")
fi

log "version       : $VERSION"
log "armada recipe : $ARMADA_PKG (${#ARMADA_PATCHES[@]} patches)"
log "container     : $(basename "$PATCH")"
log "march         : ${MARCH:-<none>}"
log "cache         : $CACHE"

if (( DRY_RUN )); then
    log "dry run: nothing built"
    exit 0
fi

# ---- host preparation ------------------------------------------------------
# Everything here is idempotent and reversible; the script records what it
# installed so --help's description stays honest about side effects.
need_root() {
    [[ $(id -u) == 0 ]] || die "this step needs root; re-run with sudo or install the deps manually"
}

prepare_glfw() {
    # See header note 1. Only headers, the .pc file and the linker symlink are
    # taken; mesa is never upgraded.
    if pkg-config --exists glfw3 2>/dev/null &&
       [[ -e /usr/lib64/libglfw.so ]] &&
       [[ -e /usr/include/GLFW/glfw3.h ]]; then
        log "glfw3 development files already present"
        return 0
    fi

    local dl=$CACHE/glfw-devel
    mkdir -p "$dl"
    if ! ls "$dl"/*.rpm >/dev/null 2>&1; then
        log "downloading glfw-devel (not installing it: it would pull mesa)"
        dnf download --destdir "$dl" glfw-devel >/dev/null 2>&1 ||
            die "cannot download glfw-devel"
    fi
    local rpm
    rpm=$(find "$dl" -name 'glfw-devel-*.rpm' | head -1)
    [[ -n $rpm ]] || die "glfw-devel rpm missing from $dl"

    local x=$CACHE/glfw-devel-extract
    rm -rf "$x"; mkdir -p "$x"
    ( cd "$x" && rpm2cpio "$rpm" | cpio -idm --quiet ) || die "cannot extract $rpm"

    need_root
    install -d /usr/include/GLFW
    install -m644 "$x"/usr/include/GLFW/*.h /usr/include/GLFW/
    install -m644 "$x"/usr/lib64/pkgconfig/glfw3.pc /usr/lib64/pkgconfig/
    # glfw-devel normally provides this unversioned symlink; the runtime package
    # only ships libglfw.so.3.
    local so
    so=$(find /usr/lib64 -maxdepth 1 -name 'libglfw.so.3.*' | head -1)
    [[ -n $so ]] || die "glfw runtime library not found; install the 'glfw' package"
    ln -sf "$(basename "$so")" /usr/lib64/libglfw.so
    log "installed glfw3 development files (mesa untouched)"
}

prepare_deps() {
    local missing=()
    for tool in rpmbuild git meson ninja gcc g++ pkg-config python3 glslangValidator rpm2cpio cpio; do
        command -v "$tool" >/dev/null || missing+=("tool:$tool")
    done
    for pc in vulkan appstream dbus-1 yaml-cpp nlohmann_json spdlog glslang; do
        pkg-config --exists "$pc" 2>/dev/null || missing+=("pkgconfig:$pc")
    done
    if ! find "$(gcc -print-file-name=libstdc++.a 2>/dev/null)" -maxdepth 0 -type f >/dev/null 2>&1; then
        missing+=("libstdc++-static")
    fi

    if (( ${#missing[@]} )); then
        log "installing missing build dependencies: ${missing[*]}"
        need_root
        dnf install -y --skip-broken \
            rpm-build rpmdevtools 'dnf5-command(builddep)' git meson ninja-build \
            gcc gcc-c++ pkgconf-pkg-config python3 glslang \
            vulkan-headers appstream dbus-devel yaml-cpp-devel json-devel \
            spdlog-devel glslang-devel libstdc++-static \
            libdrm-devel wayland-devel wayland-protocols-devel python3-mako \
            libX11-devel libXrandr-devel libXcursor-devel libcurl-devel \
            vulkan-loader-devel libappstream-glib >/dev/null 2>&1 ||
            die "dependency installation failed"
    fi

    prepare_glfw
}

prepare_deps

# ---- fetch sources ---------------------------------------------------------
mkdir -p "$CACHE"
TARBALL=$CACHE/mangohud-$VERSION.tar.gz
if [[ ! -s $TARBALL ]]; then
    log "downloading MangoHud v$VERSION"
    url="https://github.com/flightlessmango/MangoHud/archive/v$VERSION/mangohud-$VERSION.tar.gz"
    ok=0
    for attempt in 1 2 3 4 5; do
        if timeout 200 curl -sSL -o "$TARBALL" "$url" && [[ -s $TARBALL ]]; then ok=1; break; fi
        log "download attempt $attempt failed, retrying"
        sleep $(( attempt * 3 ))
    done
    (( ok )) || { rm -f "$TARBALL"; die "cannot download $url"; }
else
    log "using cached tarball $TARBALL"
fi

# The meson subprojects are fetched at build time and GitHub is flaky from a
# container, so keep them cached and seed meson's packagecache before building.
declare -A SUBPROJECTS=(
    [imgui-1.91.6.tar.gz]=https://github.com/ocornut/imgui/archive/refs/tags/v1.91.6.tar.gz
    [implot-0.16.zip]=https://github.com/epezent/implot/archive/refs/tags/v0.16.zip
    [spdlog-1.14.1.tar.gz]=https://github.com/gabime/spdlog/archive/refs/tags/v1.14.1.tar.gz
    [vulkan-headers-1.4.346.tar.gz]=https://github.com/KhronosGroup/Vulkan-Headers/archive/v1.4.346.tar.gz
    [vulkan-utility-libraries-1.4.346.tar.gz]=https://github.com/KhronosGroup/Vulkan-Utility-Libraries/archive/v1.4.346.tar.gz
)
SUBDIR=$CACHE/subprojects
mkdir -p "$SUBDIR"
for name in "${!SUBPROJECTS[@]}"; do
    dest=$SUBDIR/$name
    [[ -s $dest ]] && continue
    log "downloading subproject $name"
    ok=0
    for attempt in 1 2 3 4 5; do
        if timeout 200 curl -sSL -o "$dest" "${SUBPROJECTS[$name]}" && [[ -s $dest ]]; then ok=1; break; fi
        sleep $(( attempt * 3 ))
    done
    (( ok )) || { rm -f "$dest"; die "cannot download subproject $name"; }
done

# ---- assemble the build tree ----------------------------------------------
TOP=$CACHE/rpmbuild
rm -rf "$TOP"
mkdir -p "$TOP"/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS}

cp "$ARMADA_PKG/mangohud.spec" "$TOP/SPECS/"
cp "${ARMADA_PATCHES[@]}" "$TOP/SOURCES/"
cp "$TARBALL" "$TOP/SOURCES/"
cp "$PATCH" "$TOP/SOURCES/0010-container-metrics.patch"

SPEC=$TOP/SPECS/mangohud.spec

# The armada build.sh does these two edits; replicate them so the result is the
# same package plus our patch, not a subtly different build.
sed -i "s/^Version:.*/Version:        $VERSION/" "$SPEC"
if [[ -n $MARCH ]]; then
    sed -i "/^%build$/i %global build_cflags %{build_cflags} $MARCH" "$SPEC"
    sed -i "/^%build$/i %global build_cxxflags %{build_cxxflags} $MARCH" "$SPEC"
fi

# Declare the container patch after the last armada PatchN line so %autosetup
# applies it in order.
last_patch=$(grep -n '^Patch[0-9]*:' "$SPEC" | tail -1 | cut -d: -f1)
[[ -n $last_patch ]] || die "spec has no Patch lines to anchor the container patch"
sed -i "${last_patch}a Patch10:        0010-container-metrics.patch" "$SPEC"

# Verify the patch still applies to the patched source before spending minutes
# on a compile. --fuzz=0 makes drift a hard failure instead of a silent offset.
log "verifying the container patch applies cleanly"
VERIFY=$CACHE/verify
rm -rf "$VERIFY"; mkdir -p "$VERIFY"
tar xf "$TARBALL" -C "$VERIFY"
( cd "$VERIFY/MangoHud-$VERSION" || exit 1
  for p in "${ARMADA_PATCHES[@]}"; do
      patch -s -p1 --batch --forward --fuzz=0 <"$p" || exit 1
  done
  patch -p1 --batch --forward --fuzz=0 <"$PATCH" >/dev/null || exit 1
) || die "patch series does not apply cleanly (armada patches or container patch drifted)"

# Seed meson's packagecache from the verified tree so the build never needs the
# network. The directory only exists after the first configure, so create it.
PKGCACHE=$VERIFY/MangoHud-$VERSION/subprojects/packagecache
mkdir -p "$PKGCACHE"
cp "$SUBDIR"/* "$PKGCACHE"/
rm -rf "$VERIFY"

# ---- build -----------------------------------------------------------------
# --nodeps: see header note 2. debug_package is disabled because the generated
# debugsource file list is empty for this spec, which aborts the build.
log "building (jobs=$JOBS)"
BUILDLOG=$CACHE/build.log
( cd "$TOP" && rpmbuild -bb --nodeps \
      --define "_topdir $TOP" \
      --define "debug_package %{nil}" \
      --define "_smp_mflags -j$JOBS" \
      "$SPEC" ) >"$BUILDLOG" 2>&1 || {
    tail -40 "$BUILDLOG" >&2
    die "rpmbuild failed (full log: $BUILDLOG)"
}

RPM=$(find "$TOP/RPMS" -name "mangohud-$VERSION-*.aarch64.rpm" | head -1)
[[ -n $RPM ]] || die "no RPM produced; see $BUILDLOG"

log "built $RPM"
rpm -qip "$RPM" 2>/dev/null | sed -n '1,4p' | sed 's/^/[mangohud]   /'

if (( DO_INSTALL )); then
    need_root
    log "installing $RPM"
    dnf install -y --allowerasing "$RPM" >/dev/null 2>&1 ||
        dnf reinstall -y "$RPM" >/dev/null 2>&1 ||
        die "installation failed"
    rpm -q mangohud
fi

if (( KEEP )); then
    log "build tree kept at $TOP"
fi

printf '%s\n' "$RPM"
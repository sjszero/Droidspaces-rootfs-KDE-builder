#!/usr/bin/bash
# Build MangoHud from upstream with the Droidspaces container metric patch.
#
# Why this exists
# ---------------
# MangoHud is built from upstream rather than from the armada package because the
# armada build reads sysfs paths a container does not mount:
#
#   * it reads only devfreq `cur_freq` (Hz) for the GPU clock, but a Droidspaces
#     container exposes the older kgsl-3d0 layout where the clock is
#     `clock_mhz` (MHz), so GPU clock/load/temperature all read 0;
#   * /sys/class/hwmon does not exist, so the msm GPU hwmon node is unreachable;
#   * the kernel energy model is the only CPU power source on Qualcomm hardware,
#     and MangoHud has no EAS backend at all.
#
# scripts/armada/mangohud/mangohud-container-metrics.patch fixes all three. This
# script applies it to a pinned upstream commit and produces a drop-in RPM.
#
# What it needs
# -------------
#   network (first run)          upstream tarball + meson subprojects
#
# Everything is cached under $CACHE so later runs work offline.
#
# Two host quirks this script works around, both documented so they are not
# rediscovered the hard way:
#
#  1. glfw-devel needs pkgconfig(dri), which comes from mesa-libGL-devel. Once
#     install-mesa has run it pins `exclude=mesa*` in /etc/dnf/dnf.conf to keep
#     the container's KGSL/Turnip stack, so installing glfw-devel there would
#     upgrade Mesa and break KGSL. This script runs *before* that point in the
#     image build, where mesa is still unlocked, so it installs glfw-devel
#     normally. If it ever runs on a host that already excludes mesa*, it falls
#     back to downloading glfw-devel and extracting only the headers, glfw3.pc
#     and the .so symlink, leaving mesa untouched.
#
#  2. rpmbuild's BuildRequires check cannot be satisfied for pkgconfig(dri) and
#     pkgconfig(glfw3) in the fallback path: dri.pc exists on disk but no RPM
#     owns it. `--nodeps` skips that gate only; the real compilation still links
#     against glfw.
#
# Usage:
#   build-mangohud-container.sh [--version X.Y.Z] [--jobs N] [--keep]
#                               [--dry-run] [--install]
#
#   --version   version string baked into the RPM name; default comes from
#               upstream's meson.build
#   --jobs      parallel compile jobs; default $(nproc)
#   --keep      keep the build tree
#   --dry-run   resolve inputs and print the plan, build nothing
#   --install   dnf-install the resulting RPM (replacing the installed one)
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# PATCH may be overridden because the image build copies the script to
# /usr/local/sbin while the patch lands in /tmp.
PATCH=${PATCH:-$HERE/mangohud-container-metrics.patch}
CACHE=${CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mangohud-container-build}
# Pinned upstream commit. Bump it deliberately: the container patch is written
# against this exact tree, and the build below refuses to start if the patch does
# not apply cleanly.
MANGOHUD_COMMIT=${MANGOHUD_COMMIT:-791f92016625c866323b35d01da3844531b6c237}
MANGOHUD_REPOSITORY=${MANGOHUD_REPOSITORY:-https://github.com/flightlessmango/MangoHud.git}
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
[[ -f $PATCH ]] || die "missing container patch: $PATCH"

log "repository    : $MANGOHUD_REPOSITORY"
log "commit        : $MANGOHUD_COMMIT"
log "version       : ${VERSION:-<from meson.build>}"
log "container     : $(basename "$PATCH")"
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

# True when /etc/dnf/dnf.conf (or any repo file) excludes mesa*, which is what
# install-mesa sets up after it puts the container-specific drivers in place.
mesa_is_locked() {
    local conf
    for conf in /etc/dnf/dnf.conf /etc/dnf/dnf.conf.d/*.conf; do
        [[ -f $conf ]] || continue
        grep -qE '^[[:space:]]*(exclude|excludepkgs)[[:space:]]*=.*mesa\*' "$conf" && return 0
    done
    return 1
}

prepare_glfw() {
    if pkg-config --exists glfw3 2>/dev/null &&
       [[ -e /usr/lib64/libglfw.so ]] &&
       [[ -e /usr/include/GLFW/glfw3.h ]]; then
        log "glfw3 development files already present"
        return 0
    fi

    # MangoHud is built before install-mesa locks the drivers, so on a stock
    # armada image mesa is not excluded yet and glfw-devel can simply be
    # installed. That is the normal path and it keeps the build simple.
    if ! mesa_is_locked; then
        need_root
        if dnf install -y --setopt=install_weak_deps=False glfw-devel >/dev/null 2>&1 &&
           pkg-config --exists glfw3 2>/dev/null; then
            log "installed glfw-devel"
            return 0
        fi
        log "glfw-devel install failed; falling back to extracting it"
    fi

    # See header note 1. Only headers, the .pc file and the linker symlink are
    # taken; mesa is never upgraded.
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
    for tool in rpmbuild git meson ninja gcc g++ pkg-config python3 glslangValidator rpm2cpio cpio cmake; do
        command -v "$tool" >/dev/null || missing+=("tool:$tool")
    done
    # gl belongs here: -Dmangoapp=true switches imgui's opengl feature on, so
    # imgui's meson.build asks for dependency('gl') and needs gl.pc plus
    # /usr/include/GL/gl.h. Both come from libglvnd-devel.
    for pc in vulkan appstream dbus-1 yaml-cpp nlohmann_json spdlog glslang \
              wayland-client x11 xkbcommon gl egl; do
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
            vulkan-headers appstream appstream-devel dbus-devel yaml-cpp-devel json-devel \
            spdlog-devel glslang-devel libstdc++-static \
            libdrm-devel wayland-devel wayland-protocols-devel python3-mako \
            libX11-devel libXrandr-devel libXcursor-devel libcurl-devel \
            libxkbcommon-devel libxkbcommon-x11-devel \
            vulkan-loader-devel libappstream-glib libglvnd-devel mesa-libEGL-devel >/dev/null 2>&1 ||
            die "dependency installation failed"
    fi

    prepare_glfw
}

prepare_deps

# ---- fetch sources ---------------------------------------------------------
mkdir -p "$CACHE"
SRC=$CACHE/src

# A shallow clone at the pinned commit. Upstream tarballs are named after the
# release tag, but the pin is a commit past v0.8.4, so the repository is the only
# source that matches MANGOHUD_COMMIT exactly.
if [[ ! -d $SRC/.git ]]; then
    rm -rf "$SRC"
    log "cloning MangoHud"
    git clone --quiet --filter=blob:none --no-checkout \
        "$MANGOHUD_REPOSITORY" "$SRC" || die "cannot clone $MANGOHUD_REPOSITORY"
fi
if ! git -C "$SRC" cat-file -e "$MANGOHUD_COMMIT^{commit}" 2>/dev/null; then
    log "fetching pinned commit"
    git -C "$SRC" fetch --quiet origin "$MANGOHUD_COMMIT" ||
        git -C "$SRC" fetch --quiet origin || die "cannot fetch from $MANGOHUD_REPOSITORY"
fi
git -C "$SRC" checkout --quiet --force "$MANGOHUD_COMMIT" || die "cannot check out $MANGOHUD_COMMIT"
git -C "$SRC" clean -xdfq
log "checkout $(git -C "$SRC" rev-parse --short HEAD)"

# Only read the version out of the source when the caller did not pin one.
if [[ -z $VERSION ]]; then
    VERSION=$(sed -n "s/^  version : 'v\{0,1\}\([^']*\)',/\1/p" "$SRC/meson.build" | head -1)
    [[ -n $VERSION ]] || die "cannot determine version from $SRC/meson.build"
fi

# The spec sets %global __meson_wrap_mode default, so meson fetches the wraps
# itself during %build. Do that download here instead: a fresh container has no
# warm cache, and a failure inside meson names no URL. Every file is also
# hash-checked against the wrap file, so a truncated download stops the build now
# instead of as "Incorrect hash for source" minutes later.
#
# The files are then handed to meson through MESON_PACKAGE_CACHE_DIR. That is
# the variable meson 1.x actually reads
# (mesonbuild/wrap/wrap.py: os.environ.get('MESON_PACKAGE_CACHE_DIR')), and it
# is exported into rpmbuild below.
SUBDIR=$CACHE/subprojects
mkdir -p "$SUBDIR"

fetch() {   # fetch <filename> <expected-sha256> <url> [fallback-url...]
    local name=$1 hash=$2
    shift 2
    local dest=$SUBDIR/$name
    if [[ -s $dest ]] && printf '%s  %s\n' "$hash" "$dest" | sha256sum -c --status -; then
        log "subproject $name already downloaded"
        return 0
    fi
    rm -f "$dest"
    local url attempt
    for url in "$@"; do
        for attempt in 1 2 3; do
            log "downloading $name (attempt $attempt)"
            if timeout 300 curl -fsSL -o "$dest.part" "$url"; then
                if printf '%s  %s\n' "$hash" "$dest.part" | sha256sum -c --status -; then
                    mv -f "$dest.part" "$dest"
                    return 0
                fi
                log "checksum mismatch for $name from $url, retrying"
            fi
            sleep $(( attempt * 3 ))
        done
    done
    rm -f "$dest" "$dest.part"
    die "cannot download subproject $name (tried: $*)"
}

# hashes are copied from the pinned commit's subprojects/*.wrap
fetch imgui-1.91.6.tar.gz \
    c5fbc5dcab1d46064001c3b84d7a88812985cde7e0e9ced03f5677bec1ba502a \
    https://github.com/ocornut/imgui/archive/refs/tags/v1.91.6.tar.gz
fetch implot-0.16.zip \
    24f772c688f6b8a6e19d7efc10e4923a04a915f13d487b08b83553aa62ae1708 \
    https://github.com/epezent/implot/archive/refs/tags/v0.16.zip \
    https://github.com/mesonbuild/wrapdb/releases/download/implot_0.16-1/implot-0.16.zip
fetch implot_0.16-1_patch.zip \
    1c6b1462066a5452fa50c1da1dd47fed841f28232972c82d778f2962936568c7 \
    https://wrapdb.mesonbuild.com/v2/implot_0.16-1/get_patch
fetch spdlog-1.14.1.tar.gz \
    1586508029a7d0670dfcb2d97575dcdc242d3868a259742b69f100801ab4e16b \
    https://github.com/gabime/spdlog/archive/refs/tags/v1.14.1.tar.gz \
    https://github.com/mesonbuild/wrapdb/releases/download/spdlog_1.14.1-1/spdlog-1.14.1.tar.gz
fetch spdlog_1.14.1-1_patch.zip \
    ae878e732330ea1048f90d7e117c40c0cd2a6fb8ae5492c7955818ce3aaade6c \
    https://wrapdb.mesonbuild.com/v2/spdlog_1.14.1-1/get_patch
fetch vulkan-headers-1.4.346.tar.gz \
    5bb77f5d7b460e255a9e51affc00d64354986b55cf577d8eab28529cad01fc80 \
    https://github.com/KhronosGroup/Vulkan-Headers/archive/v1.4.346.tar.gz
fetch vulkan-utility-libraries-1.4.346.tar.gz \
    372eb525103ecb4e3a04d030b2a9778ebc67853bbdc82ce6747de3757d432ad9 \
    https://github.com/KhronosGroup/Vulkan-Utility-Libraries/archive/v1.4.346.tar.gz

# ---- assemble the build tree ----------------------------------------------
TOP=$CACHE/rpmbuild
rm -rf "$TOP"
mkdir -p "$TOP"/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS}

# The source is shipped as a git archive so %autosetup has a stable top-level
# directory to strip. `git archive` also drops .git, which keeps rpmbuild from
# picking up a stale vcs tag.
TARBALL=$CACHE/mangohud-$VERSION.tar.gz
( cd "$SRC" && git archive --format=tar.gz --prefix="MangoHud-$VERSION/" \
    -o "$TARBALL" "$MANGOHUD_COMMIT" ) || die "cannot create source tarball"
cp "$TARBALL" "$TOP/SOURCES/"
cp "$PATCH" "$TOP/SOURCES/0001-container-metrics.patch"

# A minimal spec. The armada spec is not reused because it carries nine patches
# written against the armada fork; this package is plain upstream plus the
# container patch.
SPEC=$TOP/SPECS/mangohud.spec
cat >"$SPEC" <<SPEC_EOF
%global appname MangoHud
%global forgeurl https://github.com/flightlessmango/MangoHud
# Let meson fetch subprojects from the wraps at build time; the files themselves
# are pre-seeded through MESON_PACKAGE_CACHE_DIR.
%global __meson_wrap_mode default
%global source_date_epoch_from_changelog 0
%bcond_with tests
Name:           mangohud
Version:        $VERSION
Release:        1%{?dist}.container
Summary:        Vulkan and OpenGL overlay for monitoring FPS, temperatures, CPU/GPU load
License:        MIT
URL:            %{forgeurl}
Source0:        %{name}-%{version}.tar.gz
Patch1:         0001-container-metrics.patch
BuildRequires:  vulkan-headers
BuildRequires:  appstream
BuildRequires:  dbus-devel
BuildRequires:  gcc-c++
BuildRequires:  git-core
BuildRequires:  libappstream-glib
BuildRequires:  libstdc++-static
BuildRequires:  meson >= 1.7.0
BuildRequires:  python3-mako
BuildRequires:  pkgconfig(dri)
BuildRequires:  pkgconfig(glfw3)
BuildRequires:  pkgconfig(glslang)
BuildRequires:  pkgconfig(nlohmann_json)
BuildRequires:  pkgconfig(spdlog)
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(x11)
BuildRequires:  pkgconfig(xkbcommon)
Requires:       hicolor-icon-theme
Requires:       vulkan-loader%{?_isa}

%description
A Vulkan and OpenGL overlay for monitoring FPS, temperatures, CPU/GPU load and
more. Built from upstream with the Droidspaces container metric patch.

%prep
%autosetup -n %{appname}-%{version} -p1

%build
%meson \\
    -Dmangoapp=true \\
    -Dmangohudctl=true \\
    -Dinclude_doc=true \\
    -Duse_system_spdlog=enabled \\
    -Dwith_wayland=enabled \\
    -Dwith_xnvctrl=disabled \\
    -Dtests=disabled \\
    -Dwith_fex=false \\
    -Dwith_mangohud_next=false \\
    %{nil}
%meson_build

%install
%meson_install
# mangoplot ships a `#!/usr/bin/env python` shebang, which rpm rejects as
# ambiguous. Upstream's own spec does the same rewrite.
sed -i "s@#!/usr/bin/env python@#!/usr/bin/python3@" \
    %{buildroot}%{_bindir}/mangoplot
rm -f %{buildroot}%{_libdir}/libimgui.a

%files
%license LICENSE
%doc README.md
%{_bindir}/mangoapp
%{_bindir}/mangohud
%{_bindir}/mangohudctl
%{_bindir}/mangoplot
%{_datadir}/icons/hicolor/scalable/*/*.svg
%{_datadir}/vulkan/implicit_layer.d/*Mango*.json
%{_docdir}/%{name}/%{appname}.conf.example
%{_docdir}/%{name}/presets.conf.example
%{_libdir}/%{name}/
%{_mandir}/man1/%{name}.1*
%{_mandir}/man1/mangoapp.1*
%{_metainfodir}/*.metainfo.xml

%changelog
SPEC_EOF

# Verify the patch still applies to the pinned source before spending minutes on
# a compile. --fuzz=0 makes drift a hard failure instead of a silent offset.
log "verifying the container patch applies cleanly"
VERIFY=$CACHE/verify
rm -rf "$VERIFY"; mkdir -p "$VERIFY"
tar xf "$TARBALL" -C "$VERIFY"
( cd "$VERIFY/MangoHud-$VERSION" || exit 1
  patch -p1 --batch --forward --fuzz=0 <"$PATCH" >/dev/null || exit 1
) || die "container patch does not apply to $MANGOHUD_COMMIT"
rm -rf "$VERIFY"

# Hand the downloads to meson. rpmbuild passes the environment through to %build,
# so export it for the invocation below.
export MESON_PACKAGE_CACHE_DIR=$SUBDIR

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
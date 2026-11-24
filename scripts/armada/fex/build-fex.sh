#!/usr/bin/bash
# Build FEX from a pinned upstream commit, with the patches an Android kernel
# needs, and register it as /usr/bin/FEX.
#
# Why not the distribution package: Fedora ships fex-emu built for a mainline
# kernel. On this Android kernel `openat2` is rejected outright (measured:
# rc=-1 errno=EACCES, not ENOSYS), and FEX routes all of its path resolution
# through it, so the distribution build cannot even start a guest. The patches
# in patches/ are what make it work here; they come from DroidDeck, which hit
# the same kernel limits on the same kind of container.
#
# The binary owns /usr/bin/FEX as a real file. A distribution `fex-emu` package
# then cannot take the path over silently: it either conflicts on the file (we
# want that -- the package build is mainline-only and cannot start a guest on
# this kernel) or it does not ship the path at all. An alternatives entry would
# have made the same takeover a matter of priority numbers, i.e. silent.
#
# Thunks (host GL/Vulkan/X11 bridges for a guest Linux game) are opt-in.
# Turning them on needs two sets of -devel packages (see DEPS below) and an
# x86-64 sysroot for the guest-side libraries, which prepare_x86_sysroot()
# builds from x86_64 rpms. Verified: guest glxinfo reports the host Adreno GPU
# with direct rendering, i.e. the guest never loads an x86 graphics driver.
set -eu

REPOSITORY=${FEX_REPOSITORY:-https://github.com/FEX-Emu/FEX.git}
# Pinned: the revision the Android patches apply to cleanly and the revision
# this build was smoke-tested against. Bump it only together with a rebuild of
# patches/ and a run of an actual x86-64 binary.
COMMIT=${FEX_COMMIT:-95d69be58b697a72dadd7fe6c11faeba4eb402a0}
CACHE=${CACHE:-/var/tmp/fex-build}
JOBS=${JOBS:-$(nproc)}
INSTALL=0
THUNKS=0
# Git transport for github can time out on some networks while the HTTPS
# archive still works; submodules, however, only ever come from git.
MIRROR=${FEX_MIRROR:-https://gh.monlor.com/https://github.com}

usage() {
    cat <<'EOF'
usage: build-fex [--jobs N] [--install] [--thunks] [--cache DIR] [--help]
  --jobs N     parallel build jobs (default: nproc)
  --install    strip and install the binaries, and take over /usr/bin/FEX as a real file
  --thunks     also build the GL/EGL/Vulkan/asound/Wayland thunks, both the host
               (aarch64) and guest (x86-64) halves, and enable them in Config.json.
               Assembles an x86-64 sysroot in \$X86_SYSROOT (default
               /opt/x86-dev-rootfs) and installs the extra -devel packages.
  --cache DIR  keep the source checkout and build tree here
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jobs) JOBS=${2:?--jobs needs a value}; shift 2 ;;
        --install) INSTALL=1; shift ;;
        --thunks) THUNKS=1; shift ;;
        --cache) CACHE=${2:?--cache needs a value}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

HERE=$(dirname -- "$(realpath -- "$0")")
PATCH_DIR=${FEX_PATCH_DIR:-"$HERE/patches"}
DEST=/usr/local/libexec/fex
SRC="$CACHE/FEX"
BUILD=${FEX_BUILD_DIR:-"$CACHE/fex-build"}
# x86-64 sysroot used only to cross-build the *guest* thunk libraries. FEX's
# own toolchain file assumes the host's crt/libgcc can emit x86-64, which is
# false on aarch64, so the sysroot is mandatory (crtbegin.o, -lgcc, -lstdc++).
X86_SYSROOT=${X86_SYSROOT:-/opt/x86-dev-rootfs}

if [[ ! -d "$PATCH_DIR" ]]; then
    printf 'fex: patch directory not readable: %s\n' "$PATCH_DIR" >&2
    exit 1
fi

# Only install what is missing, and drop it again in the same layer: a compiler
# left behind in the image is pure weight. FEX needs clang (not gcc) for its
# JIT targets, plus ninja for the build and nasm for its assembly unit tests.
DEPS=(git cmake ninja-build clang clang-tools-extra lld llvm nasm patch python3)
if [[ $THUNKS == 1 ]]; then
    # Two groups. Arm64 side: headers + pkg-config for the *host* thunk libraries
    # (they link the running system's libGL/libvulkan/libasound), plus clang-devel
    # and llvm-devel because ThunkLibs/Generator drives libclang to parse the
    # interface definitions. Guest side needs no host packages: it is cross-built
    # against X86_SYSROOT.
    DEPS+=(clang-devel llvm-devel openssl-devel pkgconf-pkg-config
           libX11-devel libxcb-devel libXext-devel libXrandr-devel libXrender-devel
           libxshmfence-devel mesa-libGL-devel mesa-libEGL-devel vulkan-loader-devel
           alsa-lib-devel wayland-devel libdrm-devel)
    # Assembling the x86-64 sysroot needs rpm2cpio/cpio, curl for the fallback path,
    # and dnf's download command (a plugin in older dnf5 builds).
    DEPS+=(cpio curl)
    dnf download --help >/dev/null 2>&1 || DEPS+=(dnf5-plugins)
fi
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

# Cross-building the *guest* thunk libraries (x86-64 .so files that FEX loads
# inside the guest) needs x86-64 crt objects, libc and libstdc++. None of those
# exist on an aarch64 host and clang cannot synthesise them, which is exactly how
# the naive build dies:
#   ld.lld: error: cannot open crtbegin.o
#   ld.lld: error: unable to find library -lgcc
#   ld.lld: error: unable to find library -lstdc++
# So the sysroot is assembled from x86_64 rpms. It is a build-only artefact and
# can be deleted after the build; the guest libraries it produces are a few
# hundred KB each.
prepare_x86_sysroot() {
    if [[ -f "${X86_SYSROOT}/.fex-thunk-sysroot-ready" ]]; then
        echo "x86-64 sysroot ready: ${X86_SYSROOT}"
        return 0
    fi
    local rpms="${CACHE}/x86-sysroot-rpms"
    rm -rf "$rpms"
    mkdir -p "$rpms" "$X86_SYSROOT"
    # glibc-devel carries the headers and the crt objects, gcc carries
    # crtbegin/crtend plus libgcc.a, libgcc carries libgcc_s.so.1 and gcc's
    # libgcc_s.so linker script, libstdc++(-devel) the C++ runtime and headers.
    ( cd "$rpms" && dnf download --forcearch=x86_64 --destdir="$rpms" \
        glibc glibc-headers glibc-devel kernel-headers \
        libstdc++ libstdc++-devel libgcc gcc ) \
        || echo "fex: dnf download reported errors, verifying the sysroot anyway" >&2
    # i686 members arrive through multilib resolution; unpacking them would put
    # 32-bit libraries into the sysroot's /usr/lib and confuse the link.
    local rpm
    for rpm in "$rpms"/*.x86_64.rpm; do
        [[ -f "$rpm" ]] || continue
        rpm2cpio "$rpm" | cpio -idm --quiet --directory="$X86_SYSROOT" 2>/dev/null || true
    done
    rm -rf "$rpms"

    # Fedora's linker scripts name absolute paths (/lib64/libc.so.6 and friends).
    # lld does not apply --sysroot to those, so the link fails even though the
    # file is right there. Rewrite them relative and let -L resolve them.
    local script
    for script in "${X86_SYSROOT}/usr/lib64/libc.so" "${X86_SYSROOT}/usr/lib64/libm.so"; do
        [[ -f "$script" ]] || continue
        sed -i -E 's#(^|[ (])/(usr/)?lib64/#\1#g' "$script"
    done
    # libstdc++-devel only creates this symlink when the runtime package was
    # already unpacked, which is not the case on a fresh dnf download.
    if [[ -e "${X86_SYSROOT}/usr/lib64/libstdc++.so.6" ]]; then
        ln -sfn libstdc++.so.6 "${X86_SYSROOT}/usr/lib64/libstdc++.so"
    fi
    # Graphics/audio headers are architecture-independent and already on the
    # host; link the missing ones in instead of duplicating ~200 MB of -devel.
    # Without this, --sysroot redirects -I/usr/include/libdrm etc. into the
    # sysroot and libdrm/alsa/GL interface files stop compiling.
    local entry name
    for entry in /usr/include/*; do
        name=${entry##*/}
        [[ -e "${X86_SYSROOT}/usr/include/${name}" ]] && continue
        ln -sfn "$entry" "${X86_SYSROOT}/usr/include/${name}"
    done
    # Only mark the sysroot ready when it can actually link. dnf's download failure
    # used to be swallowed and the marker written anyway, so the build died half an
    # hour later on "cannot open crtbegin.o" with the real cause long gone.
    local crt
    crt=$(find "$X86_SYSROOT" -name 'crtbegin*.o' -print -quit)
    if [[ -z $crt ]]; then
        printf 'fex: x86-64 sysroot is incomplete (no crtbegin*.o); dnf download did not deliver\n' >&2
        return 1
    fi
    : > "${X86_SYSROOT}/.fex-thunk-sysroot-ready"
    echo "x86-64 sysroot built: ${X86_SYSROOT} (${crt#"$X86_SYSROOT"/})"
}

# FEX's own Data/CMake/toolchain_x86_64.cmake passes -target but no sysroot, so
# clang links against the host (aarch64) crt/libgcc and the compiler check fails.
# This variant pins the sysroot, keeps -fuse-ld=lld in the *final* linker flags
# (assigning those clobbers what the _INIT variables would have provided, and
# without lld the host's ld.bfd rejects elf_x86_64), and adds the two lib dirs
# clang does not search for a *-linux-gnu triple on Fedora.
write_thunk_toolchain() {
    local out="${CACHE}/toolchain_x86_64.cmake"
    cat > "$out" <<EOF
option(ENABLE_CLANG_THUNKS "Enable building thunks with clang" FALSE)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_SYSROOT ${X86_SYSROOT})
if (ENABLE_CLANG_THUNKS)
  set(CMAKE_C_COMPILER clang)
  set(CMAKE_CXX_COMPILER clang++)
  set(CLANG_FLAGS "-target x86_64-linux-gnu --sysroot=\${CMAKE_SYSROOT} --gcc-toolchain=\${CMAKE_SYSROOT}/usr")
  set(CMAKE_C_FLAGS "\${CLANG_FLAGS}")
  set(CMAKE_CXX_FLAGS "\${CLANG_FLAGS}")
  set(THUNK_LIB_DIRS "-L\${CMAKE_SYSROOT}/usr/lib64 -L\${CMAKE_SYSROOT}/lib64")
  set(CMAKE_EXE_LINKER_FLAGS "-fuse-ld=lld --sysroot=\${CMAKE_SYSROOT} \${THUNK_LIB_DIRS}")
  set(CMAKE_SHARED_LINKER_FLAGS "-fuse-ld=lld --sysroot=\${CMAKE_SYSROOT} \${THUNK_LIB_DIRS}")
  set(CMAKE_MODULE_LINKER_FLAGS "-fuse-ld=lld --sysroot=\${CMAKE_SYSROOT} \${THUNK_LIB_DIRS}")
else()
  set(CMAKE_C_COMPILER x86_64-linux-gnu-gcc)
  set(CMAKE_CXX_COMPILER x86_64-linux-gnu-g++)
endif()
EOF
    echo "thunk toolchain: $out"
}

# Sources come from git when the transport works, from a codeload tarball when
# it does not (a tarball carries no submodules, which FEX needs, so that path
# only works when the tree already has them), and are reused when the checkout
# is already there. All paths end at the same pinned COMMIT.
prepare_source() {
    if [[ -d "$SRC/.git" ]] && git -C "$SRC" cat-file -e "${COMMIT}^{commit}" 2>/dev/null; then
        echo "reusing checkout at $SRC"
        git -C "$SRC" checkout --quiet --detach "$COMMIT"
        return 0
    fi
    rm -rf "$SRC"
    if git -c "url.$MIRROR.insteadOf=https://github.com" clone --quiet "$REPOSITORY" "$SRC" 2>/dev/null &&
       git -C "$SRC" checkout --quiet --detach "$COMMIT"; then
        return 0
    fi
    echo "mirrored git transport failed, retrying directly" >&2
    if git clone --quiet "$REPOSITORY" "$SRC" 2>/dev/null &&
       git -C "$SRC" checkout --quiet --detach "$COMMIT"; then
        return 0
    fi
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
    echo "git transport failed, falling back to $url (no submodules included)" >&2
    rm -rf "$SRC"
    mkdir -p "$SRC"
    curl -fL --retry 3 --connect-timeout 30 -o "$CACHE/FEX-$COMMIT.tar.gz" "$url"
    tar -xzf "$CACHE/FEX-$COMMIT.tar.gz" -C "$SRC" --strip-components=1
}
prepare_source

# Submodules carry vixl, fmt, range-v3, jemalloc, rpmalloc, zydis, fmt and the
# JIT test bins. Without them the build fails late and confusingly, so do it
# up front; the test-bin repositories are skipped, they are hundreds of MB of
# guest binaries that only the retired test suite reads.
git -C "$SRC" -c "url.$MIRROR.insteadOf=https://github.com" \
    submodule update --init --recursive --depth 1 \
    External/Catch2 External/Vulkan-Headers External/drm-headers External/fmt \
    External/jemalloc_glibc External/range-v3 External/rpmalloc External/tracy \
    External/unordered_dense External/vixl External/xxhash External/zydis \
    Source/Common/cpp-optparse

# Patches are applied idempotently: a reverse dry-run that succeeds means the
# hunk is already in the tree (a cached checkout), otherwise every hunk is
# verified before anything is written.
applied=0
for patch_file in "$PATCH_DIR"/*.patch; do
    [[ -f "$patch_file" ]] || continue
    if patch --force --reverse --dry-run --fuzz=0 -d "$SRC" -p1 -i "$patch_file" >/dev/null 2>&1; then
        echo "already applied: ${patch_file##*/}"
        continue
    fi
    patch --force --dry-run --fuzz=0 -d "$SRC" -p1 -i "$patch_file" >/dev/null
    patch --force --fuzz=0 -d "$SRC" -p1 -i "$patch_file"
    echo "applied: ${patch_file##*/}"
    applied=$((applied + 1))
done
echo "patches applied this run: $applied"

if [[ $THUNKS == 1 ]]; then
    prepare_x86_sysroot
    write_thunk_toolchain
    THUNK_TOOLCHAIN="$CACHE/toolchain_x86_64.cmake"
fi

# A rebuild starts from an empty build directory by default. FEX_REUSE_BUILD=1
# keeps the existing one, which matters when this script is re-run after a
# failure: the expensive half (the ~8000 targets of the interpreter itself) is
# not thrown away just because the thunk step is the thing being fixed.
if [[ ${FEX_REUSE_BUILD:-0} != 1 ]]; then
    rm -rf "$BUILD"
elif [[ -f "$BUILD/CMakeCache.txt" ]]; then
    # Reusing a build directory is only safe when it was configured for *this*
    # source tree and *this* --thunks setting. A cache inherited from somewhere
    # else makes the configure step die deep inside find_package because the
    # recorded paths point at another checkout -- which reads like a missing
    # dependency and is not one, so it gets diagnosed from scratch every time.
    cached_src=$(sed -nE 's/^CMAKE_HOME_DIRECTORY:INTERNAL=(.*)$/\1/p' "$BUILD/CMakeCache.txt" | head -1)
    cached_thunks=$(sed -nE 's/^BUILD_THUNKS:BOOL=(.*)$/\1/p' "$BUILD/CMakeCache.txt" | head -1)
    want_thunks=$([[ $THUNKS == 1 ]] && echo ON || echo OFF)
    if [[ -n $cached_src && $cached_src != "$SRC" ]] ||
       [[ -n $cached_thunks && ${cached_thunks^^} != "$want_thunks" ]]; then
        echo "fex: $BUILD belongs to ${cached_src:-unknown} (thunks=${cached_thunks:-unknown}); starting over" >&2
        rm -rf "$BUILD"
    fi
fi
cmake_args=(
    -S "$SRC" -B "$BUILD" -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER=clang
    -DCMAKE_CXX_COMPILER=clang++
    -DENABLE_LTO=OFF
    -DENABLE_ASSERTIONS=OFF
    -DENABLE_CCACHE=OFF
    -DBUILD_FEXCONFIG=OFF
    -DBUILD_THUNKS="$([[ $THUNKS == 1 ]] && echo ON || echo OFF)"
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)
if [[ $THUNKS == 1 ]]; then
    cmake_args+=(
        -DENABLE_CLANG_THUNKS=ON
        -DX86_DEV_ROOTFS="$X86_SYSROOT"
        -DX86_64_TOOLCHAIN_FILE="$THUNK_TOOLCHAIN"
    )
fi
# Skipped when a compatible cache already exists, so re-running this script on an
# existing build tree does not re-run the configure (and cannot fail there).
if [[ -f "$BUILD/CMakeCache.txt" ]]; then
    echo "fex: reusing existing configure in $BUILD"
else
    cmake "${cmake_args[@]}"
fi
if [[ $THUNKS == 1 ]]; then
    # The interpreter itself first: `--install` needs libFEXCore.so and the
    # frontends, which the thunk targets alone never build. Then the 64-bit guest
    # thunk libraries (the top-level CMakeLists adds guest-libs-32
    # unconditionally, but 32-bit guest thunks need a full i686 sysroot that no
    # 64-bit game uses, so targets are named explicitly instead of building all),
    # then the host thunk libraries.
    # "all" cannot be used: it includes guest-libs-32, which needs a full i686
    # sysroot that no 64-bit game uses. Naming targets one by one does not scale
    # either -- install() references libFEXCore.so, libFEXGDBReader.so and the
    # host thunk libraries, and missing any single one aborts the install. So
    # build the interpreter plus every shared library target, skipping the 32-bit
    # ones by name, then the 64-bit guest thunks through their own project.
    # Only path-qualified targets. The bare names in the target list are phony
    # aggregates (libGL-host.so, libPlaceholderX11.so) that also depend on the
    # 32-bit generator, which needs a full i686 sysroot and aborts here.
    mapfile -t so_targets < <(ninja -C "$BUILD" -t targets all 2>/dev/null |
        grep -oE '^[^:]+/[^:]+\.so' |
        grep -vE 'HostLibs_32|Guest_32|ThunkLibs/GuestLibs' | sort -u)
    # Every frontend, not just the interpreter: FEXServer and friends are looked
    # up next to the FEX binary at runtime, and `--install` copies whatever exists.
    mapfile -t bin_targets < <(ninja -C "$BUILD" -t targets all 2>/dev/null |
        grep -oE '^Bin/[^:]+' | sort -u)
    cmake --build "$BUILD" --parallel "$JOBS" --target "${bin_targets[@]}" "${so_targets[@]}"
    cmake --build "$BUILD" --parallel "$JOBS" --target guest-libs
    mapfile -t host_targets < <(ninja -C "$BUILD" -t targets all 2>/dev/null |
        grep -oE '^HostLibs_64/[^:]+' | sort -u)
    if [[ ${#host_targets[@]} -eq 0 ]]; then
        echo "fex: no HostLibs_64 targets came out of the configure step" >&2
        exit 1
    fi
    cmake --build "$BUILD" --parallel "$JOBS" --target "${host_targets[@]}"
else
    cmake --build "$BUILD" --parallel "$JOBS"
fi

if [[ "$INSTALL" != 1 ]]; then
    echo "build ready: $BUILD"
    exit 0
fi

# Install by laying the artefacts out ourselves instead of `cmake --install`.
# FEX's install rules reference every Bin/* program, every .so, and the 32-bit
# guest thunk directory (GuestThunks_32) which needs an i686 sysroot this build
# deliberately does not create. `cmake --install` therefore aborts on the first
# missing 32-bit artefact even when every 64-bit piece is present -- measured,
# it stopped on libFEXCore.so, then libFEXGDBReader.so, then FEXRootFSFetcher.
install -d -m 0755 "$DEST/bin" "$DEST/lib" \
    /usr/local/lib64/fex-emu/HostThunks /usr/local/share/fex-emu/GuestThunks
for program in "$BUILD"/Bin/*; do
    [[ -f "$program" ]] || continue
    install -m 0755 "$program" "$DEST/bin/"
done
for library in "$BUILD"/FEXCore/Source/libFEXCore.so \
               "$BUILD"/Source/Tools/FEXGDBReader/libFEXGDBReader.so; do
    [[ -f "$library" ]] || continue
    install -m 0755 "$library" "$DEST/lib/"
done
# The thunk database is what maps guest sonames to thunk libraries; the 32-bit
# builds of this image still ship it from the source tree.
install -m 0644 "$SRC/Data/ThunksDB.json" /usr/local/share/fex-emu/ThunksDB.json
if [[ $THUNKS == 1 ]]; then
    for library in "$BUILD"/HostLibs_64/*.so; do
        [[ -f "$library" ]] || continue
        install -m 0755 "$library" /usr/local/lib64/fex-emu/HostThunks/
    done
    for library in "$BUILD"/Guest/*-guest.so; do
        [[ -f "$library" ]] || continue
        install -m 0644 "$library" /usr/local/share/fex-emu/GuestThunks/
    done
fi

BIN="$DEST/bin/FEX"
if [[ ! -x "$BIN" ]]; then
    printf 'fex: %s is missing after install\n' "$BIN" >&2
    exit 1
fi
# Strip in place: the build tree is discarded by the image build anyway.
strip --strip-unneeded "$BIN" || true
# No `--version` probe: this frontend takes its first argument as the guest
# program, so `FEX --version` really tries to exec something called `--version`
# and exits 248. The pinned commit is the identity of the build.
NAME="FEX-${COMMIT:0:12}"
mv -- "$BIN" "$DEST/bin/$NAME"

# /usr/bin/FEX is a real file, not an alternatives link.
#
# An alternatives entry is a priority race: a later `dnf install fex-emu` (or
# anything else registering the same name with a higher priority) can silently
# take the path over, and the next `FEX` invocation is then a mainline-only build
# that cannot start a guest on this kernel at all. A plain file makes that
# transaction fail loudly on a file conflict instead, which is what we want.
#
# The versioned copy stays in $DEST/bin for reference; any registration left
# behind by an older build of this script is removed first so the two do not
# fight over the same path.
if command -v alternatives >/dev/null 2>&1; then
    alternatives --remove FEX "$DEST/bin/$NAME" >/dev/null 2>&1 || true
    alternatives --remove FEX /usr/bin/FEX >/dev/null 2>&1 || true
fi
if [[ -L /usr/bin/FEX ]]; then
    rm -f /usr/bin/FEX
fi
install -m 0755 "$DEST/bin/$NAME" /usr/bin/FEX
# FEX resolves FEXServer as "<dir of the interpreter>/FEXServer" first and only
# then falls back to PATH. With the real file at /usr/bin/FEX, a session whose
# PATH does not include the install prefix otherwise starts every guest with
#   E FEXServerClient: Failure to setup client
#   E Couldn't execute: FEXServer
#   E Expect errors!            (and exit status 255)
# so the helper programs have to sit beside it.
for helper in FEXServer FEXBash FEXGetConfig FEXpidof FEXRootFSFetcher FEXOfflineCompiler; do
    [[ -f "$DEST/bin/$helper" ]] || continue
    ln -sfn "$DEST/bin/$helper" "/usr/bin/$helper"
done
# Also reachable without anyone having to know the layout: `FEX <binary>` has to
# work out of the box, and every DroidDeck-era script spells the interpreter
# FEXInterpreter. All three aliases resolve to the single real file above.
ln -sfn FEX /usr/bin/FEXInterpreter
ln -sfn /usr/bin/FEX /usr/local/bin/FEX
ln -sfn /usr/bin/FEX /usr/local/bin/FEXInterpreter

# x86 / x86-64 ELF -> FEX, but **opt-in**: box64 stays the machine default.
#
# binfmt_misc prefers the handler registered *last* (measured), so the two can be
# kept apart by registration order alone. `fex-binfmt` still drops the other side
# while switching, which keeps the table clean and the result obvious:
#
#   /usr/lib/fex-emu/binfmt/FEX.conf    the two FEX entries (FEX keeps the P flag)
#   /usr/bin/fex-binfmt on|off|status   registers one side and drops the other
#
# The Steam launcher calls `fex-binfmt on` for the lifetime of a session and `off`
# again on exit. It has to: the i386 client and the x86-64 helpers it spawns
# (pressure-vessel-wrap, steamwebhelper) were measured to fail silently under
# box64, while ordinary games and CLI tools want box64.
BINFMT_CONF=/usr/lib/fex-emu/binfmt/FEX.conf
mkdir -p /usr/lib/fex-emu/binfmt
cat > "$BINFMT_CONF" <<'CONF'
# opt-in: only active while `fex-binfmt on` is in effect (Steam's 32-bit client).
# FEX reorders argv itself, so it keeps the P flag; box64 must not, see build-box64.sh.
:FEX-x86_64:M:0:\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/FEX:P
:FEX-i386:M:0:\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/FEX:P
CONF
install -m 0755 "$HERE/fex-binfmt" /usr/bin/fex-binfmt
# Earlier iterations registered FEX through systemd-binfmt from /usr/local/lib/binfmt.d.
# Those files are no longer shipped; left behind they come back on the next
# systemd-binfmt run and undo the switch (they sort after /usr/lib/binfmt.d and are
# therefore registered later, i.e. they win).
for stale in /usr/local/lib/binfmt.d/FEX-*.conf; do
    [[ -e $stale ]] || continue
    rm -f "$stale" && echo "removed stale $stale"
done
# Never leave the machine with FEX as the boot default: if box64 did not install
# its own registration, restore the default here rather than silently winning.
if [[ ! -e /usr/lib/binfmt.d/box64.conf ]]; then
    echo "fex: /usr/lib/binfmt.d/box64.conf missing -- run build-box64.sh --install first;" >&2
    echo "fex: leaving binfmt_misc untouched so the default interpreter stays box64" >&2
fi

# Default config beside the binaries. EnableCodeCachingWIP is written as 0 here on
# purpose: measured on this build, turning the WIP code cache on makes a plain
# `FEX <x86-64 binary>` die with SIGILL (rc 132) as soon as the cache is
# generated. The knob is only useful for Proton's own arm64ec/wow64 FEX, which
# armada-game-launch feeds through the environment instead.
#
# The path is FEX's baked-in data directory, not $DEST: install() rules use an
# absolute destination, and the binary reads /usr/local/share/fex-emu/Config.json
# (verified with `strings`). ThunkDB and the thunk libraries land in the same
# baked locations, so a `--prefix` never has to be mirrored by hand.
FEX_DATA=/usr/local/share/fex-emu
mkdir -p "$FEX_DATA"
CFG="$FEX_DATA/Config.json"
THUNKDB="$FEX_DATA/ThunksDB.json"
THUNKS_ON="$([[ $THUNKS == 1 ]] && echo 1 || echo 0)"
python3 - "$CFG" "$THUNKDB" "$THUNKS_ON" <<'PY'
import json, pathlib, sys

cfg_path = pathlib.Path(sys.argv[1])
db_path = pathlib.Path(sys.argv[2])
thunks_on = sys.argv[3] == '1'

# Defaults: no WIP code cache (it SIGILLs this build), RootFS set by
# install-x86-64-libs.sh once the x86-64 loader is installed.
cfg = {}
if cfg_path.exists():
    cfg = json.loads(cfg_path.read_text() or '{}')
cfg.setdefault('Config', {}).setdefault('EnableCodeCachingWIP', '0')

if thunks_on:
    # Without this block FEX leaves every thunk disabled, and a guest
    # dlopen("libGL.so.1") just reports "cannot open shared object file" even
    # though the host libraries are installed -- measured.
    cfg['ThunksDB'] = {'GL': 1, 'EGL': 1, 'Vulkan': 1, 'drm': 1,
                       'asound': 1, 'WaylandClient': 1}
    # Upstream's ThunksDB.json has no EGL entry even though the generator emits
    # libEGL-guest.so; without it EGL cannot be routed to the host driver.
    #
    # GL also lists libGL.so* only, but glvnd-based guests reach for
    # libOpenGL.so.0 first (glvnd >= 1.3 resolves the GL entry points through
    # it). The RootFS deliberately ships no libOpenGL of its own -- a real one
    # would shadow the thunk -- so the name has to be overlaid as well, or
    # dlopen("libOpenGL.so.0") simply fails. Same fix DroidDeck carries as
    # 0015-gl-thunk-overlays-libopengl.
    if db_path.exists():
        db = json.loads(db_path.read_text())
        entries = db.setdefault('DB', {})
        changed = []
        if 'EGL' not in entries:
            entries['EGL'] = {
                'Library': 'libEGL-guest.so',
                'Overlay': ['@PREFIX_LIB@/libEGL.so',
                            '@PREFIX_LIB@/libEGL.so.1',
                            '@PREFIX_LIB@/libEGL.so.1.5.0'],
            }
            changed.append('EGL')
        gl_overlay = entries.get('GL', {}).get('Overlay')
        if gl_overlay is not None:
            for extra in ('@PREFIX_LIB@/libOpenGL.so.0',
                          '@PREFIX_LIB@/libOpenGL.so.0.0.0'):
                if extra not in gl_overlay:
                    gl_overlay.append(extra)
                    changed.append(extra.replace('@PREFIX_LIB@/', ''))
        if changed:
            db_path.write_text(json.dumps(db, indent=2) + '\n')
            print('thunksdb: added ' + ', '.join(changed))
    print('config: ThunksDB enabled (GL, EGL, Vulkan, drm, asound, WaylandClient)')

cfg_path.write_text(json.dumps(cfg, indent=2) + '\n')
print(f'config written: {cfg_path}')
PY

# The thunk libraries are only useful when the loader can find them at the
# baked paths, so report where they landed instead of assuming success.
if [[ $THUNKS == 1 ]]; then
    for dir in /usr/local/lib64/fex-emu/HostThunks /usr/local/share/fex-emu/GuestThunks; do
        count=$(find "$dir" -maxdepth 1 -name '*.so' 2>/dev/null | wc -l)
        printf 'thunks: %s -> %s libraries\n' "$dir" "$count"
        [[ $count -gt 0 ]] || { echo "fex: no thunk libraries in $dir" >&2; exit 1; }
    done
fi

# Structural check instead of `--version` (see above): the pieces FEX resolves at
# runtime have to sit beside the interpreter.
for path in /usr/bin/FEX /usr/bin/FEXServer /usr/bin/FEXBash "$DEST/bin/$NAME"; do
    [[ -x $path ]] || { printf 'fex: missing %s after install\n' "$path" >&2; exit 1; }
done
echo "installed: $DEST/bin/$NAME"
echo "on PATH: /usr/bin/FEX, /usr/bin/FEXInterpreter, /usr/local/bin/FEX"
echo "rootfs: remember to run install-x86-64-libs.sh, FEX needs an x86-64 loader in its RootFS"
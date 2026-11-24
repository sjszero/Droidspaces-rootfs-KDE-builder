#!/usr/bin/bash
# Install an x86-64 Mesa stack into the FEX RootFS at <rootfs>/opt/zink, so a guest
# that brings its own GL client still gets a real driver backed by the host GPU.
#
# Why this exists next to the thunks: the GL/EGL/Vulkan thunks are the default and
# they answer any guest that dlopens libGL.so.1. Some binaries ship their own GL
# client (CEF, a vendored Mesa, Debian multiarch builds) and need something
# guest-side to answer GL. zink does that by running Mesa's OpenGL *on Vulkan*, and
# Vulkan stays thunked: the guest libvulkan.so.1 is the FEX stub, so every Vulkan
# call lands on the host Turnip driver.
#
# Measured (GLX path, Adreno 750): zink Vulkan 1.4 on Turnip, GL 4.6, pixel readback
# 64,128,191,255 exact, 59 fps. The EGL path still reports "ZINK: failed to choose
# pdev"; that is *not* the Vulkan WSI set (the thunk exposes all of it) and the real
# cause is undiagnosed -- use GLX.
#
# Nothing here becomes the default: the thunk stub keeps answering libGL.so.1, and
# /opt/zink only wins when LD_LIBRARY_PATH points at it (see env.sh below).
set -eu

MIRROR=${FEX_X86_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/fedora/releases/44/Everything/x86_64/os/Packages}
ROOTFS=${FEX_ROOTFS:-/usr/lib/fex-emu/rootfs}
DEST=$ROOTFS/opt/zink
WORK=${CACHE:-/var/tmp/fex-zink}

# mesa itself, the glvnd front-ends that load it, the demo binaries used as
# smoke tests, and every x86-64 soname the closure below actually needs --
# each one of these was added because `readelf -d` said a library was missing,
# not because it looked tidy.
PACKAGES=(
    mesa-dri-drivers mesa-libGL mesa-libEGL mesa-libgbm mesa-demos
    libglvnd libglvnd-glx libglvnd-egl
    llvm-libs spirv-tools-libs lm_sensors-libs elfutils-libelf expat
    libwayland-client
    libX11-xcb libXxf86vm libdrm libedit libffi libxml2 libzstd libpciaccess
    # vkgears/vulkaninfo: the Vulkan-side acceptance tests. vkgears needs a
    # windowing stack of its own: libdecor for the window, libxkbcommon-x11 for
    # input. (libdecor's own cairo plugin stays unloadable here -- it wants cairo
    # and pango -- and that is fine: vkgears falls back to "no decorations" and
    # still opens a window and renders at ~56 fps, measured.)
    vulkan-tools libdecor libxkbcommon libxkbcommon-x11
)

# Libraries that go into the RootFS's own /usr/lib64 rather than /opt/zink:
# the RootFS previously carried only their 32-bit builds, and mesa resolves them
# through the normal search path.
ROOTFS_LIBS=(
    libX11-xcb.so.1 libXxf86vm.so.1 libdrm.so.2 libdrm_amdgpu.so.1
    libdrm_intel.so.1 libedit.so.0 libffi.so.8 libxml2.so.2 libzstd.so.1
    libpciaccess.so.0
)

fetch() {
    local pkg=$1 dir attempt name
    dir=$(printf '%s' "$pkg" | cut -c1 | tr 'A-Z' 'a-z')
    for attempt in 1 2 3; do
        name=$(curl -sf --max-time 60 "$MIRROR/$dir/" |
            grep -oE "${pkg}-[0-9][^\"]*x86_64\\.rpm" | sort -u | tail -1) || true
        [[ -n ${name:-} ]] && break
    done
    [[ -n ${name:-} ]] || { echo "zink: no x86_64 rpm named $pkg at $MIRROR/$dir/" >&2; return 1; }
    ( cd "$WORK" && curl -sf --max-time 300 -O "$MIRROR/$dir/$name" ) ||
        { echo "zink: download failed: $name" >&2; return 1; }
    printf '%s\n' "$name"
}

rm -rf "$WORK"
mkdir -p "$WORK/rpm" "$WORK/x86root"
for pkg in "${PACKAGES[@]}"; do
    fetch "$pkg" >/dev/null
done
printf 'zink: fetched %d packages\n' "$(find "$WORK" -maxdepth 1 -name '*.rpm' | wc -l)"

( cd "$WORK/x86root" && for rpm in "$WORK"/*.rpm; do
    rpm2cpio "$rpm" | cpio -idm --quiet 2>/dev/null
done )
X=$WORK/x86root

install -d -m 0755 "$DEST/lib/dri" "$DEST/bin"

# Version-carrying sonames are resolved by glob: fetch() takes whatever version the
# mirror currently carries, so a hardcoded libgallium-<ver>.so stops the script dead
# on the next mesa bump. The glob takes real files only, so the installed name is the
# one the loader actually asks for.
take() {
    local name=$1 src
    src=$(find "$X/usr/lib64" -maxdepth 1 -name "$name" | head -1)
    [[ -n $src ]] || { echo "zink: $name not found in the fetched packages" >&2; return 1; }
    install -m 0755 "$src" "$DEST/lib/$name"
}
take_glob() {
    local pattern=$1 src
    src=$(find "$X/usr/lib64" -maxdepth 1 -name "$pattern" ! -type l | sort | head -1)
    [[ -n $src ]] || { echo "zink: $pattern not found in the fetched packages" >&2; return 1; }
    install -m 0755 "$src" "$DEST/lib/${src##*/}"
}
# glvnd front-ends plus mesa's vendor libraries: libEGL_mesa/libGLX_mesa talk to the
# DRI driver, libGL/libEGL are the dispatch layer a client links against.
for lib in libGL.so.1 libGLX.so.0 libGLdispatch.so.0 \
           libEGL.so.1 libGLX_mesa.so.0 libEGL_mesa.so.0 libgbm.so.1; do
    take "$lib"
done
take_glob 'libgallium-*.so'
# Everything the above resolve through NEEDED, kept beside them so the tree is
# self-contained; the RootFS only gets the X11/drm half (ROOTFS_LIBS) because other
# guests may want those too.
for lib in libSPIRV-Tools.so libsensors.so.4 libelf.so.1 \
           libexpat.so.1 libwayland-client.so.0; do
    take "$lib"
done
take_glob 'libLLVM.so.*'

# Fedora 26 exposes the DRI drivers as symlinks to one libdril loader; keeping
# that shape means only libdril plus the two real driver names have to travel.
install -m 0755 "$X/usr/lib64/dri/libdril_dri.so" "$DEST/lib/dri/libdril_dri.so"
for drv in zink_dri.so swrast_dri.so; do
    ln -sfn libdril_dri.so "$DEST/lib/dri/$drv"
done

for prog in glxinfo glxgears eglinfo es2_info es2gears_x11; do
    [[ -f $X/usr/lib64/mesa/$prog ]] && install -m 0755 "$X/usr/lib64/mesa/$prog" "$DEST/bin/$prog"
done

# Vulkan-side acceptance tests: vkgears renders through the Vulkan thunk (no zink
# involved), vulkaninfo is the query-only counterpart.
[[ -f $X/usr/lib64/mesa/vkgears ]] && install -m 0755 "$X/usr/lib64/mesa/vkgears" "$DEST/bin/vkgears"
[[ -f $X/usr/bin/vulkaninfo ]] && install -m 0755 "$X/usr/bin/vulkaninfo" "$DEST/bin/vulkaninfo"

# libdecor looks its plugins up at a compiled-in absolute path, so they have to
# land in the RootFS's own /usr/lib64 rather than next to the library. Without
# them vkgears falls back to "no decorations" and -- measured -- never creates a
# window at all.
if [[ -d $X/usr/lib64/libdecor/plugins-1 ]]; then
    install -d -m 0755 "$ROOTFS/usr/lib64/libdecor/plugins-1"
    for plugin in "$X/usr/lib64/libdecor/plugins-1/"*.so; do
        [[ -f $plugin ]] && install -m 0755 "$plugin" "$ROOTFS/usr/lib64/libdecor/plugins-1/"
    done
fi

for lib in "${ROOTFS_LIBS[@]}"; do
    src=$(find "$X/usr/lib64" -maxdepth 1 -name "$lib" | head -1)
    if [[ -n $src ]]; then
        install -m 0755 "$src" "$ROOTFS/usr/lib64/$lib"
    else
        echo "zink: warning: $lib not found in the fetched packages" >&2
    fi
done
install -d -m 0755 "$ROOTFS/etc/glvnd/egl_vendor.d"
install -m 0644 "$X/usr/share/glvnd/egl_vendor.d/50_mesa.json" \
    "$ROOTFS/etc/glvnd/egl_vendor.d/50_mesa.json" 2>/dev/null || true

# One file to source instead of remembering three variables.
cat > "$DEST/env.sh" <<'ENV'
# Point a guest at the zink stack. Source this (or copy the exports) before
# running an x86-64 GL program under FEX; it does not affect the thunk default.
export LD_LIBRARY_PATH=/opt/zink/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export LIBGL_DRIVERS_PATH=/opt/zink/lib/dri
# Guest programs that can pick a Wayland backend will try to, and a guest cannot
# reach the host's compositor -- only X11 is proxied. Without this, vkgears opens
# no window at all (measured) while working fine on X11.
unset WAYLAND_DISPLAY
# vkgears uses libdecor for its window; the plugin lives in the RootFS's
# /usr/lib64 and needs to be pointed at explicitly when it moves.
export LIBDECOR_PLUGIN_DIR=/usr/lib64/libdecor/plugins-1
ENV
chmod 0644 "$DEST/env.sh"

# The closure must be complete before this is worth anything: report, do not
# silently ship a tree that cannot load.
missing=0
for lib in "$DEST"/lib/*.so*; do
    while IFS= read -r need; do
        [[ -e $DEST/lib/$need || -e $ROOTFS/usr/lib64/$need ]] || {
            printf 'zink: unresolved soname: %s (needed by %s)\n' "$need" "${lib##*/}" >&2
            missing=$((missing + 1))
        }
    done < <(readelf -d "$lib" 2>/dev/null | sed -nE 's/.*\(NEEDED\).*\[(.*)\]/\1/p')
done
[[ $missing -eq 0 ]] || { echo "zink: $missing unresolved sonames" >&2; exit 1; }

# The fetch/extract tree is a scratch copy of a few hundred MB and must not survive
# into an image layer.
rm -rf "$WORK"
du -sh "$DEST"
echo "zink ready: $DEST (source $DEST/env.sh; GLX path only, the EGL path is undiagnosed)"

#!/usr/bin/bash
# Populate /usr/lib/fex-emu/rootfs with the x86-64 pieces FEX cannot get from
# the host.
#
# This is the one place where FEX differs from box64 in a way that costs image
# size, and it is worth being explicit about it:
#
#   box64 wraps libc/libm/libpthread/libdl onto the host's aarch64 libraries, so
#   it needs no guest libc at all. FEX emulates the guest from the ELF entry
#   point, which means the guest's own x86-64 ld.so and libc have to exist
#   somewhere -- that is the RootFS.
#
# What goes in: glibc (ld-linux-x86-64.so.2, libc, libm, libpthread, libdl,
# librt, libnss_*), plus the C++ runtime the engines link against. Roughly 30 MB.
#
# What must NOT go in, and why it is not an omission:
#
#   libGL / libEGL / libvulkan / libwayland
#       FEX's thunks forward these to the host's aarch64 Mesa/Vulkan instead of
#       emulating them. An x86-64 copy in the RootFS would shadow the thunk and
#       the guest would end up on llvmpipe (or fail to load a driver at all).
#       This is also why the distribution's fex-emu-rootfs-fedora is not used
#       here: it ships a full x86 userspace, graphics included, 1.8 GiB of it.
#
#   libssl / libcrypto / libasound / libpulse / libudev / libdbus
#       same reasoning as box64's install-x86-64-libs.sh: they carry the host
#       integration, and an emulated copy breaks it.
#       openssl-libs is the measured exception for command-line tools: Fedora's
#       coreutils sha256sum links libcrypto.so.3, and without it the binary fails
#       to start at all. Nothing in the Steam/Proton path picks the guest copy up
#       (Proton runs its own x86-64 userspace), so the trade-off is one-sided.
#
#   libX11 / libXext / libxcb
#       NOT a driver and NOT thunked: X11 is a guest-native client library, and
#       the GL thunk links against it (libGL-guest.so -> libX11.so.6). Leaving it
#       out makes `dlopen("libGL.so.1")` fail on libX11.so.6 -- measured.
#
# Everything comes from Fedora's own x86_64 repositories through dnf, so the
# glibc version tracks the one the image already ships. No x86-64 root filesystem
# image, no Arch squashfs, no Steam runtime.
set -eu
# Default set is the smallest one that runs both CLI tools and a guest GL program
# through the thunks. Each group was added because a binary actually failed
# without it:
#   coreutils ls        -> libselinux.so.1, libcap.so.2
#   coreutils sha256sum -> libcrypto.so.3 (openssl-libs), libz.so.1 (zlib-ng-compat)
#   bash                -> libtinfo.so.6 (ncurses-libs)
#   libGL-guest.so      -> libX11.so.6 and its xcb chain
# glibc/libstdc++-devel are needed by the guest thunk libraries themselves.
PKGS=(glibc libstdc++ libgcc libselinux pcre2 libacl libattr libcap
      ncurses-libs openssl-libs zlib-ng-compat
      libX11 libXext libxcb libXau libXdmcp libxshmfence)
# Set FEX_ROOTFS_MINIMAL=1 for just enough to start a dynamically linked x86-64
# binary (glibc + C++ runtime + the selinux/cap chain). Useful when the RootFS
# has to stay as small as possible and no GUI program is expected to run.
if [[ ${FEX_ROOTFS_MINIMAL:-0} == 1 ]]; then
    PKGS=(glibc libstdc++ libgcc libselinux pcre2 libacl libattr libcap)
fi
# Extra packages can be pulled in without editing this file: the guest loader
# names what it is missing, and that name usually maps straight to a Fedora
# package (libicu -> libicu, for .NET/CoreCLR guests like Stardew Valley).
EXTRA_PKGS=("${FEX_ROOTFS_EXTRA_PKGS:-}")
for extra in ${EXTRA_PKGS[@]}; do
    [[ -n "$extra" ]] && PKGS+=("$extra")
done
DEST=/usr/lib/fex-emu/rootfs
WORK=${CACHE:-/var/tmp/fex-x86-64-rootfs}

# The image is not guaranteed to carry the extraction tooling nor dnf's download
# command, so make sure both exist before using them.
NEEDED=()
command -v cpio >/dev/null 2>&1 || NEEDED+=(cpio)
command -v rpm2cpio >/dev/null 2>&1 || NEEDED+=(rpm)
dnf download --help >/dev/null 2>&1 || NEEDED+=(dnf5-plugins)
if [[ ${#NEEDED[@]} -gt 0 ]]; then
    dnf -y install --setopt=install_weak_deps=False "${NEEDED[@]}"
fi

rm -rf "$WORK"
mkdir -p "$WORK/pkgs" "$WORK/root"
if ! ( cd "$WORK/pkgs" && dnf download --forcearch=x86_64 --skip-unavailable --destdir=. "${PKGS[@]}" ); then
    echo "dnf download failed: is the download plugin installed (dnf install dnf-plugins-core)?" >&2
    exit 1
fi

shopt -s nullglob
rpms=("$WORK"/pkgs/*.x86_64.rpm)
if [[ ${#rpms[@]} -eq 0 ]]; then
    echo "no x86_64 packages were downloaded" >&2
    exit 1
fi
for rpm in "${rpms[@]}"; do
    printf '%s\n' "$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$rpm")"
    ( cd "$WORK/root" && rpm2cpio "$rpm" | cpio -idm --quiet )
done

install -d -m 0755 "$DEST"
# Keep the FHS layout: FEX resolves guest libraries through the normal Fedora
# paths (usr/lib64, lib64). Packages place 64-bit libraries in either, so both
# are collected and the top-level lib64 is linked to usr/lib64 the way Fedora's
# filesystem package does it.
for dir in lib64 usr/lib64; do
    [[ -d "$WORK/root/$dir" ]] || continue
    install -d -m 0755 "$DEST/$dir"
    while IFS= read -r -d '' lib; do
        case "${lib##*/}" in
            # gconv converters are a glibc module tree, not a library to flatten
            *gconv/*) continue ;;
        esac
        cp -a --no-dereference "$lib" "$DEST/$dir/"
    done < <(find "$WORK/root/$dir" -maxdepth 1 -name '*.so*' -print0)
done
if [[ -d "$WORK/root/usr/lib64/gconv" ]]; then
    cp -a "$WORK/root/usr/lib64/gconv" "$DEST/usr/lib64/"
fi
# /lib64 has to be the loader's real location. Fedora's glibc puts everything in
# usr/lib64 and leaves /lib64 as a symlink, which rpm2cpio extraction does not
# recreate -- so lib64 ends up an empty directory and FEX's lookup of
# <rootfs>/lib64/ld-linux-x86-64.so.2 fails with ENOENT (strace-verified). Fold
# whatever landed in lib64 into usr/lib64, then make it the symlink FEX expects.
if [[ -d "$DEST/lib64" && ! -L "$DEST/lib64" ]]; then
    if [[ -n "$(ls -A "$DEST/lib64" 2>/dev/null)" ]]; then
        cp -a "$DEST/lib64/." "$DEST/usr/lib64/"
    fi
    rm -rf "$DEST/lib64"
fi
ln -sfn usr/lib64 "$DEST/lib64"

# The loader is the whole point: without it nothing dynamic starts.
for f in usr/lib64/ld-linux-x86-64.so.2 usr/lib64/libc.so.6; do
    [[ -e "$DEST/$f" ]] || { echo "missing $DEST/$f" >&2; exit 1; }
done
# And the graphics *drivers* must be absent, otherwise the thunks are defeated.
# libX11 is deliberately not in this list: it is a guest-native client library
# the GL thunk links against, not a driver.
for pattern in libGL.so* libEGL.so* libvulkan.so* libgallium* swrast_dri.so; do
    compgen -G "$DEST/usr/lib64/$pattern" >/dev/null && {
        echo "refusing to ship $pattern: it would shadow the host thunk" >&2
        exit 1
    }
done

# ---------------------------------------------------------------------------
# Debian-spelled view of the same libraries: /usr/lib/x86_64-linux-gnu.
#
# This is not a cosmetic detail, it is a global mode switch inside the emulator.
# FEXCore's FileManagement::RootFSIsMultiarch() tests for the existence of
# <rootfs>/usr/lib/x86_64-linux-gnu and, from that one bit, decides which set of
# paths every guest library lookup uses:
#
#   Fedora layout  : /usr/lib64, /lib64, /usr/lib, /lib
#   Debian layout  : the above *plus* /usr/lib/<triplet>, /lib/<triplet>
#
# Steam's pressure-vessel container and the CEF/steamwebhelper process that runs
# inside it are Debian binaries: they dlopen /usr/lib/x86_64-linux-gnu/libGL.so.1
# by absolute-ish name. Without the triplet directories the emulator answers every
# one of those lookups with ENOENT and the client dies with
# "MESA-LOADER: failed to open ... libGL.so.1" -- measured, and this is exactly
# what blocked the Steam UI before the directories existed.
#
# Symlinks, never copies: the real libraries stay in the Fedora locations so the
# host thunks keep shadowing anything graphics-shaped, and image size does not
# grow. Both layouts stay populated at once because the flag flips globally --
# turning multiarch on makes the emulator stop matching the lib64 spellings, so
# the guest thunk stubs have to exist under both sets of names as well (that is
# build-fex.sh --thunks' job, see install_guest_thunks there).
install -d -m 0755 "$DEST/usr/lib/x86_64-linux-gnu" "$DEST/usr/lib/i386-linux-gnu"
for lib in "$DEST"/usr/lib64/*.so*; do
    [[ -e "$lib" ]] || continue
    ln -sfn "../../lib64/${lib##*/}" "$DEST/usr/lib/x86_64-linux-gnu/${lib##*/}"
done
# The 32-bit guest libraries only exist when fex-rootfs32 has been merged into
# the tree (lib/ld-linux.so.2 and friends); the loop is a no-op otherwise.
for lib in "$DEST"/usr/lib/*.so*; do
    [[ -e "$lib" ]] || continue
    ln -sfn "../${lib##*/}" "$DEST/usr/lib/i386-linux-gnu/${lib##*/}"
done
install -d -m 0755 "$DEST/lib"
ln -sfn ../usr/lib/x86_64-linux-gnu "$DEST/lib/x86_64-linux-gnu"
ln -sfn ../usr/lib/i386-linux-gnu "$DEST/lib/i386-linux-gnu"
# The guest's own ldconfig has to know about the triplet directories too, or the
# cache it builds on first run leaves them out and ld.so falls back to a linear
# search. ldconfig -r works on any tree without chroot.
install -d -m 0755 "$DEST/etc/ld.so.conf.d"
cat > "$DEST/etc/ld.so.conf.d/multiarch.conf" <<'CONF'
/usr/lib64
/usr/lib
/usr/lib/x86_64-linux-gnu
/usr/lib/i386-linux-gnu
CONF
if command -v ldconfig >/dev/null 2>&1; then
    ldconfig -r "$DEST" >/dev/null 2>&1 || true
fi

du -sh "$DEST"
echo "rootfs ready: $DEST (steam-fex.sh exports FEX_ROOTFS=$(printf '%s' "$DEST"))"
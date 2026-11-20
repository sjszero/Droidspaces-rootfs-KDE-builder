#!/usr/bin/bash
# Populate /usr/lib/box64-x86_64-linux-gnu, the directory box64 always searches
# for the x86-64 libraries it has to emulate (src/core.c).
#
# box64 wraps a long list of libraries onto the host's aarch64 ones -- libc,
# libm, libpthread, libdl, ld-linux, libvulkan, libGL, libX11, libssl,
# libcrypto, libasound, libpulse, libudev, libdbus, libfontconfig, libz ... --
# so those must NOT be bundled: a bundled x86 copy would shadow the host wrapper
# and break both graphics and the loader. Measured from a full run of a Godot
# .NET game, only three groups actually have to exist as x86-64:
#
#   libstdc++ / libgcc_s   the C++ runtime the engine and its plugins link
#   libicu*                CoreCLR globalization
#   libcurl + its chain    CoreCLR HTTP (libnghttp2, libnghttp3, libssh2)
#
# Everything comes from Fedora's own x86_64 repositories through dnf, so the set
# tracks the distribution the image already ships. No x86-64 root filesystem and
# no Arch Linux squashfs is involved.
set -eu

PKGS=(libstdc++ libgcc libicu libcurl libnghttp2 libnghttp3 libssh2)
DEST=/usr/lib/box64-x86_64-linux-gnu
WORK=${CACHE:-/var/tmp/box64-x86-64-libs}

# The image is not guaranteed to carry the extraction tooling (nothing else pulls
# cpio in) nor dnf's download command, so make sure both exist before using them.
NEEDED=()
command -v cpio >/dev/null 2>&1 || NEEDED+=(cpio)
command -v rpm2cpio >/dev/null 2>&1 || NEEDED+=(rpm)
dnf download --help >/dev/null 2>&1 || NEEDED+=(dnf5-plugins)
if [[ ${#NEEDED[@]} -gt 0 ]]; then
    dnf -y install --setopt=install_weak_deps=False "${NEEDED[@]}"
fi

rm -rf "$WORK"
mkdir -p "$WORK/pkgs" "$WORK/root"

# --forcearch asks the aarch64 host for x86_64 packages; it also pulls i686
# dependencies along (libgcc for 32-bit), which are filtered out below.
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
# Packages put 64-bit libraries in either /lib64 or /usr/lib64; collect both into
# one flat directory, keeping the soname symlinks (cp --no-dereference). ICU's
# tooling libraries (icuio, icutu, icutest) are dropped: only libicuuc,
# libicui18n and libicudata are part of the runtime CoreCLR loads.
for dir in lib64 usr/lib64; do
    [[ -d "$WORK/root/$dir" ]] || continue
    while IFS= read -r -d '' lib; do
        case "${lib##*/}" in
            libicuio.so*|libicutu.so*|libicutest.so*) continue ;;
        esac
        cp -a --no-dereference "$lib" "$DEST/"
    done < <(find "$WORK/root/$dir" -maxdepth 1 -name '*.so*' -print0)
done

# `compgen -G` handles the ICU soname, which moves with every major upgrade.
for pattern in libstdc++.so.6 libgcc_s.so.1 libcurl.so.4 libicuuc.so.* libicui18n.so.* libicudata.so.*; do
    compgen -G "$DEST/$pattern" >/dev/null || { echo "missing $DEST/$pattern" >&2; exit 1; }
done

du -sh "$DEST"
[Documentation index](README.md) · [Project home](../../README_english.md)

# Quick Start

## Subscribe to the rolling desktop feed

In Droidspaces repository management, add [Chinese RootFS (GitHub)](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder/releases/download/droidspaces-rootfs-all-wayland/rootfs_zh.json), [Chinese RootFS (CNB)](https://cnb.cool/goldzxcbug/droidspaces-package/-/releases/download/droidspaces-rootfs-all-wayland/rootfs_zh.json), or [English RootFS (GitHub)](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder/releases/download/droidspaces-rootfs-all-wayland/rootfs_en.json). Each Chinese index uses download URLs from its own source. The rolling release updates weekly and includes every Anland Wayland desktop for Debian 13, Ubuntu 26, Fedora 43/44, and Arch.

## 1. Build with GitHub Actions

1. Fork this repository and open its `Actions` page.
2. Select “Build and Release Droidspaces RootFS” and click `Run workflow`.
3. Choose a distribution, desktop, display backend, and optional features, then start the workflow.
4. When it completes, download the `.tar.xz` from `Releases`. Archives larger than 1900 MiB are published as `.tar.xz.zip.001`, `.002`, etc.

A common Wayland setup uses Debian 13, Ubuntu 26, Fedora 43/44, or Arch, with desktop `KDE` and backend `anland-wayland`. You can keep the defaults for a first build. Some defaults differ between the English and Chinese workflows; see [build options](build-options.md).

Wayland builds use patched desktop packages published in `Goldzxcbug/droidspaces-package`. To use your package-repository fork, set `wayland_package_repository` to its public `owner/repository` and publish the matching Anland package Release there.

### Extract ZIP volumes

Download every `.zip.001`, `.zip.002`, etc. for the same archive into one directory without renaming them. Open or extract the first volume with 7-Zip, for example:

```bash
7z x ArmadaOS-kde-Wayland-Droidspaces-rootfs-aarch64-VERSION.tar.xz.zip.001
```

Extraction produces the original **`.tar.xz` archive** to import into Droidspaces. The ZIP contains only that archive; it does not directly unpack the root filesystem. The `.parts` file lists volume names; `.sha256` and `.size` describe the original `.tar.xz` hash and byte count. Do not concatenate the ZIP volumes and rename the result to `.tar.xz`. Archives at or below 1900 MiB remain plain `.tar.xz` files.

## 2. Import into Droidspaces

Create or import a container and select the downloaded `.tar.xz` as its RootFS. Enable hardware access for desktop images.

- For Debian/Ubuntu, enable `noseccomp` in privileged mode and make sure the host kernel has `USER_NS`; otherwise desktop operations may lag.
- Fedora may need hardware access enabled to avoid flicker or crashes.
- X11 desktops require Termux:X11 on Android.
- Anland Wayland also requires the [host setup](desktop-and-anland.md#anland-wayland-host-setup).

## 3. First login

If `desktop_autostart` was enabled, `desktop-session.service` starts the selected desktop when the container starts. Otherwise, log in as the normal user and run the desktop command shown in the [desktop startup guide](desktop-and-anland.md).

The default username is `Gold` and the default password is `1234` (use your custom username if you changed it during the build). Change the password after the first login:

```bash
passwd
```

`all` and `all-wayland` build multiple compatible targets. GNOME, Niri, Hyprland, Mango, and Denial are available on Debian 13, Ubuntu 26, Fedora 43/44, and Arch Linux ARM. See the [compatibility matrix](build-options.md).

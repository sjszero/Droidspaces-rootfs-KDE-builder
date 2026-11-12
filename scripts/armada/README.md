# scripts/armada

ArmadaOS-specific adaptations applied on top of the upstream armada package set.
Every file here is consumed by `ArmadaOS.Dockerfile`.

The layout groups files by the subsystem they fix. Keep new files in the
matching directory rather than at the root, and update the `COPY` lines in
`ArmadaOS.Dockerfile` to the grouped path.

## `mangohud/` — overlay metrics

| File | Purpose |
|---|---|
| `mangohud-container-metrics.patch` | Apply on top of upstream: read the kgsl-3d0 temperature reading and add an EAS energy-model CPU power source. |
| `build-mangohud-container.sh` | Fetch a pinned upstream commit, apply that patch, produce a drop-in RPM. |
| `mangohud-energy-model.service` | Bring up the energy-model sysfs entries MangoHud reads at game start. |

## `anland/` — display backend and session

| File | Purpose |
|---|---|
| `armada-gamescope-startup.sh` | Read the startup FIFO without a deadline when the Anland consumer is absent. |
| `patch-armada-gamescope-startup.py` | Patch the vendor session for Anland startup and optional fullscreen mode. |
| `armada-steam-anland.sh` | Force Zink/Turnip and the XRandR preload for the Steam client under Anland. |
| `patch-armada-plasma-session.py` | Give the standalone Plasma session an Anland producer environment. |
| `patch-armada-container-desktop-mode.py` | Point Armada Control's desktop-mode read at the container session state. |
| `verify-anland-kwin.py` | Fail the build when KWin lacks the Anland backend. |

## `configure/` — first-boot and desktop configuration

| File | Purpose |
|---|---|
| `configure-armada-decky.py` | Configure Decky Loader for the container account. |
| `configure-armada-splash.py` | Let the selected container account own the Steam startup splash state. |
| `patch-armada-remove-bazaar-pin.py` | Remove Bazaar from the Plasma taskbar pins. |

## Root — cross-cutting helpers

| File | Purpose |
|---|---|
| `armada-container-session-control` | Container replacement for the base image's `session-control`. |
| `as-user.sh` | Run a command as an unprivileged account, with or without PAM. |
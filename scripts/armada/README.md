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

## `box64/` — x86-64 games on the arm64 container

| File | Purpose |
|---|---|
| `build-box64.sh` | Build a pinned upstream box64 and register it through alternatives. The distribution package lacks the dynarec opcode that Godot's .NET runtime emits. |
| `install-x86-64-libs.sh` | Extract the few x86-64 libraries box64 cannot wrap (C++ runtime, ICU, curl chain) from Fedora RPMs into `/usr/lib/box64-x86_64-linux-gnu`. |
| `box64-binfmt` | Mount `binfmt_misc` and register box64 as the x86-64 interpreter, after FEX, so the winner is deterministic. |
| `box64-binfmt.service` | Run that registration at boot; `systemd-binfmt` never starts in a container. |
| `box64-run` | Steam compatibility tool launcher: drops the arm64 library paths Steam injects and sets the .NET knobs the games need. |
| `box64.box64rc` | Installed as `/etc/box64.box64rc`. Global dynarec tuning for this hardware, with the measurement that justifies each value. |
| `bench/bench_fs.c` | Freestanding single-thread x86-64 workload (ALU, memory, SSE, call/return), built `-nostdlib` so only dynarec code is timed. |
| `bench/bench_fs_mt.c` | Freestanding multi-process LOCK-op workload: fork plus a `MAP_SHARED` page, which is the shape of cost strong-memory emulation pays. |
| `bench/run-matrix.sh` | Rebuilds both workloads with the x86-64 cross compiler and prints one setting per row. |
| `compatibilitytool.vdf` | Registers `box64 (Armada)` in Steam's compatibility list for Linux games. |
| `toolmanifest.vdf` | Steam entry point (`/box64-run %verb% --`), deliberately without `require_tool_appid` so the tool runs on the host, not inside the aarch64 Steam Linux Runtime. |

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
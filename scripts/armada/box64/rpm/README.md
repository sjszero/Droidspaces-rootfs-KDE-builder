# box64-armada

The complete x86-64 runtime for an ArmadaOS container: box64 0.4.4 built with the
arm64 dynarec, the tuned `box64.box64rc` measured on this hardware, the x86-64
libraries box64 cannot wrap onto the host, the `binfmt_misc` registration, and the
"box64 (Armada)" Steam compatibility tool.

## Install

```sh
sudo dnf install --nogpgcheck ./box64-armada-0.4.4-1.fc44.aarch64.rpm
```

The package replaces Fedora's `box64` 0.3.6 and `box64-data` (same paths, older
build), so `dnf` will remove those two as part of the transaction. The FEX
packages are left alone; this package only makes sure box64 wins the x86-64
`binfmt_misc` handler.

Verify:

```sh
box64 --version                     # Box64 arm64 v0.4.4 ... with Dynarec
systemctl status box64-binfmt       # active (exited)
cat /proc/sys/fs/binfmt_misc/box64  # enabled, interpreter /usr/bin/box64
```

## Use it for a Steam game

1. Restart Steam once (it scans `compatibilitytools.d` only at startup).
2. Game → Properties → Compatibility → force **box64 (Armada)**.
3. Launch.

Only x86-64 **Linux** builds go through box64. Windows-only titles still need
Proton (`proton-cachyos-…-arm64` here), and native aarch64 game containers
(Steam Linux Runtime) do not need it at all.

## What is in the package

| Path | What |
|---|---|
| `/usr/bin/box64` | the emulator (upstream commit `2f130fa`, `RelWithDebInfo`, stripped) |
| `/etc/box64.box64rc` | tuned dynarec settings; every value has its measurement in the comments |
| `/usr/lib/box64-x86_64-linux-gnu/` | libstdc++, libgcc, ICU, libcurl/libnghttp2/libnghttp3/libssh2 — the path box64 hardcodes |
| `/usr/libexec/armada/box64-binfmt` | mounts `binfmt_misc` and registers box64 last, so it beats FEX's handler whatever the boot order |
| `/usr/lib/systemd/system/box64-binfmt.service` | runs the above, enabled by the package |
| `/usr/share/steam/compatibilitytools.d/box64-armada/` | the Steam compatibility tool (`compatibilitytool.vdf`, `toolmanifest.vdf`, `box64-run`) |

`box64-run` is what makes games work without extra setup: it drops the aarch64
entries Steam injects into `LD_LIBRARY_PATH`/`LD_PRELOAD`, exports the CoreCLR GC
knobs (`DOTNET_GCHeapHardLimit`, `gcServer=0`, `gcConcurrent=0`), sets
`BOX64_DYNAREC_STRONGMEM=1`, and disables the native Vulkan layer chain
(`VK_LOADER_LAYERS_DISABLE=~all~`) — with any aarch64 Vulkan layer in the chain,
box64's `vkGetInstanceProcAddr` thunk calls a NULL pointer and the game dies with
SIGSEGV inside SDL2's `X11_GL_GetVisual`.

## Overrides

* `VK_LOADER_LAYERS_DISABLE=…` in the environment wins over the package default,
  so you can re-enable layers for one game to test.
* `~/.box64rc` wins over `/etc/box64.box64rc`; copy the installed file there and
  edit it if you want different settings for one user.
* `installer` guard: `[*setup*]`/`[*install*]` sections keep `DYNAREC_SAFEFLAGS=2`
  and `BIGBLOCK=0` for installers, which break under the tuned global defaults.

## Known limits

* First launch of a .NET game is slow: Stardew Valley needs ~75 s of CoreCLR
  startup under box64 before its window appears (a Godot Mono title needs ~3.5 s).
  Do not give up during Steam's "launching" splash.
* MangoHud's Vulkan overlay does not work inside x86-64 games while the layer
  chain is disabled; it still works for native aarch64 games.
* 32-bit x86 games are not covered (this is the x86-64 tool only).

## Remove

```sh
sudo dnf remove box64-armada
```

This unregisters the `binfmt_misc` handler; Fedora's `box64` is **not** restored
automatically — `sudo dnf install box64 box64-data` puts 0.3.6 back.

---

## 中文速览

装完即用，不用重建容器：

```sh
sudo dnf install --nogpgcheck ./box64-armada-0.4.4-1.fc44.aarch64.rpm
```

包含：box64 0.4.4（arm64 dynarec）、实测调优的 `/etc/box64.box64rc`、x86-64
库集、`binfmt_misc` 注册、Steam 兼容层 **box64 (Armada)**。

用游戏时：重启一次 Steam → 游戏属性 → 兼容性 → 选 **box64 (Armada)** → 启动。
只适用于 **x86-64 Linux** 游戏；Windows 游戏仍需 Proton，原生 aarch64 容器游戏不需要它。

注意：.NET 游戏首次启动很慢（星露谷约 75 秒才出窗口），Steam 显示"启动中"时别中断；
MangoHud 覆盖层在 x86-64 游戏里不生效（原生游戏不受影响）。
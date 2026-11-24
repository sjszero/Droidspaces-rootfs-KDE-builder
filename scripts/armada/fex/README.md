# FEX on ArmadaOS

Fedora's `fex-emu` is a mainline-kernel build: this Android kernel rejects `openat2`
outright, and FEX routes all path resolution through it, so the packaged build
cannot start a guest. This directory builds FEX from a pinned upstream commit with
the patches that make it work here, and installs it next to box64.

Split of duties: **box64 runs games**, **FEX runs Steam's own 32-bit client** and
x86-64 graphics tests. No FEX Steam compatibility tool is shipped.

## Files

| File | What it does |
|---|---|
| `build-fex.sh` | Build/install FEX from the pinned commit; `--thunks` adds the GL/EGL/Vulkan/asound/Wayland bridges and the x86-64 sysroot they need |
| `install-x86-64-libs.sh` | Populate `/usr/lib/fex-emu/rootfs` with the x86-64 glibc/C++ runtime the guest loader needs |
| `install-zink.sh` | Opt-in x86-64 Mesa (zink) under `<rootfs>/opt/zink`; `env.sh` there switches to it |
| `fex-binfmt` | `on` / `off` / `status`: move x86/x86-64 ELF between FEX and box64 |
| `steam-fex.sh` | Run the i386 Steam client under FEX: right identity, `LANG=C`, interpreter switched for the session |
| `patches/0000-armada-android-kernel.patch` | The whole patch series as one file; `patches/sources/` holds the originals for reference |
| `fex-deps.py` | Walk an i386 guest's ELF graph and list what the RootFS is missing, in one shot |
| `zink-test.c` | GLX + pixel-readback + 60-frame timing acceptance test |

## Patches

One merged file, applied at `fuzz=0`. It comes from DroidDeck's FEX series (which
meets the same kernel limits) plus this container's measurements:

- **kernel/base** — `openat2` fallback to `ENOSYS`, 32-bit allocator exhaustion,
  `auxv` AT_PLATFORM, path syscalls through libc, guest preload drops host libs.
- **signals/JIT** — host stack freed on handler escape, syscall state and guest
  registers restored on return, code created after translation aliased for SMC,
  thunk calls mark spilled state.
- **build/thunks** — `cmake --install` without the 32-bit depends, thunk generator
  with newer clang, GL thunk forwards X errors, GL thunk overlays `libOpenGL.so.0`.

## Build

```bash
build-fex.sh --install --thunks      # interpreter + host/guest thunks
install-x86-64-libs.sh               # x86-64 glibc into the RootFS
```

`--thunks` is required for graphics: without the thunk DB entries a guest
`dlopen("libGL.so.1")` fails even though the host libraries are installed.

## Verified on this container (Adreno 750)

| Check | Result |
|---|---|
| `FEX uname -m` | `x86_64` |
| guest `dlopen` of GL/EGL/Vulkan/drm | all four load through the thunks |
| `glxinfo` through the GL thunk | host `freedreno FD750`, GL 4.6, direct rendering |
| `vkgears` (native Vulkan) | window 300x300, 283 frames / 5.0 s = **56 fps**, stable 20 s |
| Steam client (i386) | main window mapped, 6 h unattended |
| `zink-test.c` (GLX) | pixel `64,128,191,255` exact, **59 fps** |

## Steam client: three rules

1. **Run as the owner of `~/.local/share/Steam`**, never via `sudo`. tier0 creates a
   SysV semaphore with mode 0600 and the creator's uid; `ipcperms()` then rejects
   any other euid and the client dies on `threadtools.cpp (2526) Assertion Failed`
   with SIGTRAP. Stop it with SIGTERM — `kill -9` leaves that semaphore behind.
2. **`LANG=C LC_ALL=C XMODIFIERS=@im=none`.** The RootFS has no `zh_CN` locale, and
   with the host locale leaking through Xlib reports `XOpenIM() failed` and takes
   the client down before the window appears.
3. **Interpreter.** `steam-fex.sh` runs `fex-binfmt on` for the session and restores
   box64 on exit. The i386 client and its x86-64 helpers exit silently under box64.

The window itself is `xwininfo -root -tree` work, not log parsing: the client logs
nothing about mapping, and an unmapped steamwebhelper window looks like a failure.

## Vulkan through the thunk

`vkGetInstanceProcAddr` is a generated table; a function belonging to an extension
that was not enabled returns NULL — that is the loader, not a missing thunk. With
`VK_KHR_surface` + `VK_KHR_xlib_surface` enabled all 14 probed entry points resolve,
WSI included. `vulkaninfo --summary` still dies with SIGILL (`ILL_ILLOPC`) inside the
JIT — an unimplemented instruction, not a Vulkan fault; `vkgears` uses the same path
and renders fine.

`WAYLAND_DISPLAY` must be unset for guest windowing programs: only X11 is proxied,
so a guest that picks a Wayland backend silently renders into nothing.

## x86 Mesa (zink): GLX works, EGL does not

`install-zink.sh` drops a complete x86-64 Mesa tree into `<rootfs>/opt/zink`; it is
opt-in through `env.sh`, so the thunk default is untouched. Mesa then runs OpenGL on
Vulkan, and Vulkan is the one API that stays thunked.

Three things had to be fixed before even the GLX path loaded: the RootFS carried
only 32-bit `libX11-xcb`/`libdrm`/`libffi`/`libxml2`/`libzstd`/`libedit`/
`libpciaccess`; `libwayland-client` had to be a real library instead of the thunk
stub; and the GL thunk now also overlays `libOpenGL.so.0`.

The **EGL** path still reports `MESA: error: ZINK: failed to choose pdev`. That is
not the Vulkan WSI set (the thunk exposes all of it) and the real cause is
undiagnosed. Use GLX.

## EnableCodeCachingWIP: on for Proton, off for this FEX

The knob starts FEX's shared code buffer at its maximal size. This build dies with
SIGILL (rc 132) as soon as the cache is generated, so it stays `0` in
`Config.json`, `fex-profiles.json` and everywhere else that feeds *this* FEX. The
box64 profiles still export it as `FEX_ENABLECODECACHINGWIP=1` because that value
reaches Proton's own arm64ec/wow64 FEX, a different build.

## Wiring

`ArmadaOS.Dockerfile` section 8f copies this directory to `/usr/local/libexec/fex`
and runs `build-fex.sh --install --thunks`, `install-x86-64-libs.sh`, then installs
`steam-fex.sh` as `/usr/local/bin/steam-fex`. `install-zink.sh` is deliberately not
run at image build time (it fetches ~200 MB and is opt-in).

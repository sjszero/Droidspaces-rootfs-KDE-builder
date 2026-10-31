[文档目录](README.md) · [项目主页](../../README.md)

# ArmadaOS 容器维护

ArmadaOS 的日常维护在云端构建产物导入后的 Droidspaces 容器内进行，构建入口为 `~/Droidspaces-rootfs-KDE-builder/ArmadaOS.Dockerfile`。修改运行环境后，应把需要保留的依赖和配置同步到这份仓库，避免下次重建丢失。

## 工作方式

- 使用现有的容器终端会话；执行前核对用户名、主机名与仓库状态。
- 修改前检查 `git status` 和相关脚本。迁移仓库后先修复所有权，再正常使用 Git。
- 查看用户目录时使用 `getent passwd USER`。Armada 的 `/var/home` 和 `/home` 可能指向同一目录，不能仅根据路径字符串判断数据是否搬迁。
- 普通环境检查只读取状态和日志；会话切换、图形测试及服务重启应单独执行。
- 修改构建脚本后记录验证范围。现有镜像的测试结果不能代替修改后完整镜像的构建结果。

## 2026-10-27 环境基线

以下为该日导入镜像的实测状态，后续维护时应重新检查：

| 项目 | 状态 |
| --- | --- |
| 系统与架构 | Armada `20261026.3446cca`，Fedora 44 系，`aarch64` |
| 维护账号 | `Gold`，UID/GID `1001:1001`，passwd 家目录 `/var/home/Gold` |
| 上游游戏账号 | `armada`，UID/GID `1000:1000` |
| 仓库 | `main`，基线提交 `7468e90`；origin 为 `sjszero/Droidspaces-rootfs-KDE-builder` |
| 仓库归属 | 迁移后的工作副本已改为 Gold 所有，Git 可正常访问 |
| 系统状态 | 系统和 Gold 用户实例均无 failed unit |
| 运行中服务 | SDDM、`plugin_loader.service`、SSH、Gold 的 `armada-container-session-manager.service` |
| gamescope | `terra-gamescope-3.16.31^1-1.fc44.armada.anland.aarch64`，`--help` 包含 `anland` 后端 |
| Anland 源码 | 镜像内 `/usr/local/src/anland` 提交 `22e063c` |
| 游戏会话后端配置 | `BACKEND=anland`，`ANLAND_SOCKET=/run/display.sock` |
| 当前 SDDM 登录目标 | `armada-plasma.desktop`；检查时 gamescope 用户服务未运行，未验证图形显示 |

`/etc/droidspaces-desktop.conf` 在该镜像中不存在。ArmadaOS 使用自己的 SDDM、gamescope 与会话管理路径；通用 TUI 对此镜像的组件识别仍需单独核对，不能直接套用其他 Fedora 模板的桌面启动服务。

## 开发与测试依赖

本次在运行容器中补装了 `ripgrep`、`ShellCheck` 和 `zip`。对应的构建配置为：

- `ENABLE_kfgj_ARG=true`：在原有编译器、CMake、Python 开发工具之外，安装 `ripgrep` 和 `ShellCheck`。
- `ENABLE_zip_ARG=true`：安装压缩工具，其中已经包含 `zip`。

运行回归测试需要 Python 3、Bash、`zip`、`split` 和 7-Zip。权限切换测试需要 root；普通用户没有免密 sudo 时会跳过相关用例。可在仓库根目录运行：

```bash
sudo env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
shellcheck scripts/armada/as-user.sh
bash -n scripts/armada/as-user.sh
```

实测结果：23 项测试中 22 项通过；唯一跳过项为需要显式设置 `RUN_LARGE_ZIP_TESTS=1` 的 4,936,509,568 字节 ZIP64 回归用例。

另外，使用 `capsh --drop=cap_sys_resource` 在子进程中复现了 PAM 会话失败。相同条件下，仓库的 `as-user` 包装器成功以 Gold 身份执行命令、传递环境变量，并得到 soft/hard `nofile=524288/524288`。该检查不改变容器主会话的 capability。

## Steam 大屏幕自启动修复（同日）

开机日志确认 `container-boot-mode` 已选择 `gamescope-session-steam.desktop`，SDDM 也确实启动了 gamescope。失败发生在图形初始化：镜像只设置了 KGSL 环境变量，没有实际调用共享 Mesa 安装器；Fedora 自带 Vulkan 驱动仅枚举出 llvmpipe，gamescope 随后在 `vkAllocateMemory` 失败处断言退出。短会话重试触发了上游恢复逻辑，最终切换到 Plasma。

修复采用其他容器共用的 `mesa-for-android-container` 驱动：

- `scripts/tui/install-mesa.sh` 将 `ID=armada` 按 `VERSION_ID` 映射到相应 Fedora 目标，不修改系统的 `/etc/os-release`。
- `ArmadaOS.Dockerfile` 在最后的软件包事务之后、删除安装器之前，按 `ENABLE_mesa_ARG` 调用共享安装器；驱动随后使用相同的 DNF 锁定机制。
- 运行容器从同一分发 Release 的 CNB 镜像安装了 `mesa-for-android-container_26.3.0-devel-20260824_fedora_44_arm64.tar.gz` 与媒体解码驱动，下载校验沿用共享安装器。
- Gold 的 Steam 路径指向 armada 的预装数据，原目录仍归 UID 1000 所有。构建脚本现在将共享的 `.local/share/Steam` 和 `.steam` 实体目录归给所选图形用户，使 Steam 能写入和更新；此共享客户端由该用户维护。运行容器已应用相同修复，并将旧归属快照保存到 `~/.cache/armada-driver-maintenance/steam-ownership.jsonl`。

运行验证中，`vulkaninfo --summary` 识别到 Turnip Adreno 750，gamescope 日志确认选择了该 GPU。Steam 已完成首次客户端更新。更新期间还发现两个独立问题：

- 启动画面进度文件由上游硬编码的 `armada` 用户维护，Gold 无法写入。`scripts/armada/configure-armada-splash.py` 现在将状态写入脚本和 `/etc/tmpfiles.d/armada-run.conf` 的 splash 目录归属设为所选用户，同时保留 root 所有的 `/run/armada` 和其他规则。运行容器已应用相同修复。
- 更新后的 ARM Steam 在原生 KGSL GL 路径中出现 DRI3/GBM dma-buf 导出失败，`steamwebhelper` 的 `SIGTRAP` 和 Steam 主进程退出码 1 已由进程跟踪确认。单独关闭 CEF GPU 加速以及禁用共享纹理均未解决。对照镜像内 Anland 参考启动脚本，游戏会话改用同一 Mesa 驱动包中的 Zink/Turnip，并只为 Steam 客户端命令预加载 `libXrandr.so.2`，解决 `XRRGetOutputInfo` 符号查找问题；无需关闭 GPU 加速。`scripts/armada/armada-steam-anland.sh` 只对 Anland 后端生效，并保留显式指定的 Vulkan ICD 和现有预加载库。

正式脚本已安装到运行容器，清除临时跟踪覆盖及无效测试参数后重新启动了游戏会话。Steam 使用 `-gamepadui -steamos3 -steampal -steamdeck`，大屏幕登录页已完成加载，读取到二维码登录与账号密码表单；gamescope 焦点为 Steam AppID `769`，实际 X11 窗口截图包含渲染内容。诊断证据和截图保存在 `~/.cache/armada-driver-maintenance/`。该验证未重启容器，冷启动和重建镜像仍需单独验证。

本轮完整回归共 37 项：36 项通过，1 项大于 4 GiB 的 ZIP64 测试按默认条件跳过。新增覆盖包括 ArmadaOS/Fedora 43、44 驱动目标一致性、媒体解码目录、未知版本拒绝、Debian 独立目标、splash 配置幂等性及失败保护、Anland Steam 环境与其他后端隔离。ShellCheck、Shell 语法和 `git diff --check` 通过。

## Steam 画面定格修复（同日续）

上一轮的 Zink 修复让 Steam 大屏幕登录页成功渲染，但闲置约 8 分钟后画面再次定格：CEF 的 DevTools 目标仍可读取，DOM 文本完整，而 X11 焦点窗口与 CEF 截图同时退化为纯黑（`getextrema` 全 0）。

`cef_log.txt` 给出链路：CEF 的 GPU 进程反复 `exit_code=5`（SIGTRAP）后不再重生，`pgrep -f 'steamwebhelper.*--type=gpu'` 为 0，两个渲染进程各自占用约 90% CPU 空转（`eu-stack` 显示 `__lll_lock_wake` / Mesa `util_queue_thread_func`），页面日志随之静默。

根因与 Zink 无关：`/proc/<renderer>/maps` 显示 `steamwebhelper` 加载的是 Steam 自带的 `steamrtarm64/libEGL.so`、`libGLESv2.so`（ANGLE），CEF 不会使用系统 Mesa，因此 `MESA_LOADER_DRIVER_OVERRIDE=zink` 从未作用到 UI 的 GPU 进程，ANGLE 仍在原生 KGSL 上触发崩溃。镜像内 `producers/gamescope/ArmadaOS_v5/startup.sh` 中已标注为已验证的 KGSL/ANGLE 变通方案此前没有生效。

修复在 `scripts/armada/armada-steam-anland.sh` 中追加 ANGLE 覆盖，并与 XRandR 预加载一样只作用于 Steam 客户端命令，不改动 gamescope：

```bash
angle_features=${ANGLE_FEATURE_OVERRIDES_ENABLED:-}
case :${angle_features}: in
*:disableTimestampQueries:*) ;;
*) angle_features="${angle_features:+${angle_features}:}disableTimestampQueries" ;;
esac
CLIENTCMD="env LD_PRELOAD=libXrandr.so.2${LD_PRELOAD:+:${LD_PRELOAD}} ANGLE_FEATURE_OVERRIDES_ENABLED=${angle_features} ${CLIENTCMD}"
```

保留用户已设置的其他 ANGLE 特性，并保证重复 source 时不产生重复项。运行容器按同一路径 `/usr/libexec/armada/steam-anland-env` 部署后重启会话验证：全部 `steamwebhelper` 进程均带 `ANGLE_FEATURE_OVERRIDES_ENABLED=disableTimestampQueries`，GPU 进程崩溃计数在重启前为 12、约 3 分钟内无新增，大屏幕截图由纯黑恢复为 18,257 种颜色、随后持续刷新到 26,413 种颜色并显示 `MENU`/`SELECT`/`BACK` 底栏。

本轮回归共 40 项：37 项通过，3 项按条件跳过。新增覆盖为 ANGLE 覆盖存在性、既有特性保留和幂等性。仍未执行冷启动验证与完整镜像重建。

## Steam 大屏幕居中偏移修复（同日续）

截图确认右侧多选弹窗的偏移来自 gamescope 输出几何错误，而不是 Steam 面板布局：Android 当前横屏逻辑画布为 `2480x1116`，但 Anland gamescope 未收到 `SCREEN_WIDTH`/`SCREEN_HEIGHT`，Xwayland 因此使用默认 `1280x720` 的 16:9 画布。Steam 的居中计算基于这个错误画布，显示到实际面板后就表现为向右偏移。

`scripts/armada/armada-steam-anland.sh` 现在在 Anland 后端默认导出 `SCREEN_WIDTH=2480`、`SCREEN_HEIGHT=1116`，同时允许外部环境变量覆盖，非 Anland 后端保持不变。运行容器已同步部署；重启 `gamescope-session-plus@steam.service` 后实测命令行包含 `-W 2480 -H 1116`，Xwayland 报告 `current 2480 x 1116`，输出为 `gamescope connected 2480x1116+0+0`，Steam 与 `steamwebhelper` 进程均保持运行。这确认 Steam 现在使用完整面板几何。

本轮新增 2 项自动化测试；针对性测试 10 项通过，完整回归 71 项通过、1 项按条件跳过，Shell 语法和 `git diff --check` 通过。Android 截图工具未能从当前帧提取文字，因此弹窗的最终视觉位置仍需用户在设备上重新打开同一多选弹窗确认。

## 登录横幅中的 bluetooth.service 失败（同日续）

每次打开交互式 shell 都会打印：

```
[systemd]
Failed Units: 1
  bluetooth.service
```

横幅由上游 Armada 的 `/etc/profile.d/console-login-helper-messages-profile.sh` 提供，它对 `systemctl list-units --state=failed` 的每一项直接列名，因此只有清掉失败 unit 才会消失。

根因是容器没有蓝牙硬件：

- bluetooth.service 的 ConditionPathIsDirectory=/sys/class/bluetooth 通过（目录存在但为空），unit 因此照常启动。
- 容器内 /sys/class/bluetooth 无任何适配器，/dev/rfkill 也不存在。
- bluetoothd 于是报 src/adapter.c:adapter_init() Failed to access management interface，Adapter handling initialization failed，以 status=1/FAILURE 退出。

蓝牙在这种环境下不可能工作，属于第 3 节「假设真实硬件的服务」同一类，因此把 bluetooth.service 加入 ArmadaOS.Dockerfile 的 mask 列表，沿用既有的 ln -sf /dev/null 机制，而不是新增单独处理。

运行容器已就地创建同一 mask 链接，systemctl is-enabled bluetooth.service 返回 masked，重启后不会再启动。当次会话中的历史失败记录需要 polkit 认证的 reset-failed 才能清除，因此下次开机后横幅才彻底消失；这属于运行时残留，不影响镜像行为。

本轮回归共 43 项：40 项通过，3 项按条件跳过。新增覆盖为 mask 列表包含 bluetooth.service、沿用同一 mask 机制，以及 sddm/seatd/armada-control 等会话与电源 unit 不被误 mask。

## 桌面模式缺 Anland KWin（同日续）

切换到桌面模式后，SDDM 反复以 `Session crashed (exit code 1)` 重试并回退到游戏模式。直接运行 KWin 得到真实原因：

```
$ kwin_wayland --xwayland --socket test
kwin_core: Failed to open drm node : 没有那个文件或目录
kwin_vulkan: Device Turnip Adreno (TM) 750 misses required Vulkan extensions
kwin_vulkan: VK_EXT_physical_device_drm
kwin_wayland_drm: No suitable DRM devices have been found
```

KWin 本体装了（`kwin-6.7.5-1.fc44.armada`），但它是普通 Fedora 构建，只有 DRM 后端。容器只暴露了渲染节点 `/dev/dri/renderD128`，没有 KMS 主节点 `card0`，DRM 后端因此找不到可用输出设备。缺失的是 Anland 后端：`kwin_wayland --help` 中原本没有 `--anland`。

有两个构建缺口使桌面模式无法自行修好：

1. `ArmadaOS.Dockerfile` 从未 `COPY scripts/tui/install-anland-kde.sh`，而 `install-anland-desktop` 的 `kde` 分支正需要它，因此 `ENABLE_ANLAND_OVERLAY=true` 也无法装出 Anland KWin。
2. `install-anland-kde.sh` 的 `detect_target()` 只匹配 `fedora:44*`，ArmadaOS 的 `ID=armada` 会被直接判为不支持。

修复沿用共享安装器的既有模式：

- `detect_target()` 按 `install-mesa.sh` 的做法把 `ID=armada` 归一化为 `fedora`，仍用 `VERSION_ID` 选择版本化归档；同时把 os-release 路径改为可用 `ANLAND_KDE_OS_RELEASE` 覆盖，便于测试。
- Dockerfile 补上 `install-anland-kde.sh` 的 COPY 与 `chmod +x`。
- 第 10 节补充说明：`terra-gamescope` 不覆盖 KWin，桌面模式必须 `ENABLE_ANLAND_OVERLAY=true` 且 `DESKTOP=kde`。

运行容器已用官方归档 `anland-kde-fedora44-kwin-6.7.5-aarch64.tar.gz`（Goldzxcbug/droidspaces-package 的 `anland-kde-packages`）完成安装，`kwin`/`kwin-libs`/`kwin-common`/`xorg-x11-server-Xwayland` 均为 `6.7.5-1.anland.fc44`，`--anland` 选项已出现，`kwin_backend_anland` 能加载。安装器同时把四个包写入 DNF exclude，避免后续更新覆盖。

实测时 `/run/display.sock` 是失效的残留 socket（连接报「没有那个设备或地址」），显示 daemon 与 consumer 都未运行，因此 Anland 后端报 `consumer disconnected, entering fallback`。这属于运行环境的显示链路状态，不改变 KWin 自身能力结论；桌面模式的完整显示验证仍待显示 daemon/consumer 在线时进行。

本轮回归共 46 项：43 项通过，3 项按条件跳过。新增覆盖为 Armada→Fedora 44 KWin 归档映射、原生 Fedora 映射不变，以及不支持的 Armada 版本被拒绝。

## 桌面模式最终打通：会话脚本缺 producer 环境与会话总线

装好 Anland KWin 后桌面仍然打不开，最终定位在 armada 自己的会话脚本上。`/usr/libexec/armada/armada-plasma-session` 在 `standalone` 分支的结尾是：

```bash
export DESKTOP_SESSION=plasma
exec "${ARMADA_STARTPLASMA:-/usr/bin/startplasma-wayland}"
```

这是真机上的写法：桌面由正在运行的 Game Mode 交接而来，显示栈已经就绪。容器里走 Anland 时缺两样东西，缺任一样 KWin 都会在毫秒级退出（`status=0`，日志里只有 `startplasma-wayland: Shutting down...`）：

1. **producer 环境**。`kwin_wayland` 是顶层合成器，通过内建 `anland` 后端直连显示 daemon，靠 `ANLAND`/`ANLAND_SOCKET`/`ANLAND_DRM_DEVICE`/`ANLAND_SKIP_IMPLICIT_SYNC_WAIT` 加 KGSL Mesa 选择来决定后端和 GPU。没有这些变量它会退回 DRM 后端，在容器里找不到 KMS 设备后退出。
2. **会话总线**。SDDM 启动 Wayland 会话时不会建 session bus，`startplasma-wayland` 在 dbus-daemon 缺席时直接关停。

一个关键陷阱：这些变量**不能**从 `sddm.service` 的 drop-in 注入。`sddm-helper` 会用 PAM 加自己的白名单重建会话环境，实测 `systemctl show sddm -p Environment` 明明列着 `ANLAND=1`，会话进程里却是空值（`set -x` trace 显示走了 `[[ 0 == 1 ]]` 的未命中分支）。所以修复必须落在会话脚本自身。

修复方式（`scripts/armada/patch-armada-plasma-session.py` + Dockerfile 第 7i 节）：

- 脚本自己检测 `/run/display.sock`，命中就导出全套 Anland 环境，并改用 `exec dbus-run-session startplasma-wayland`；没命中则保持上游原样的裸 `exec`，非 Anland 容器行为不变。
- 补丁是精确匹配的：上游改了这段就构建失败，而不是静默跳过产出一个没有 Anland 后端的桌面。重复执行会识别为已打过补丁，保持幂等。

同轮还修了两个直接影响桌面可用性的问题：

- **进桌面要密码**：自动登录没有密码，`pam_kwallet5` 拿不到 wallet key（日志 `pam_kwallet5: open_session called without kwallet5_key`），KWallet 于是在每次登录弹出「首次使用」设置向导。容器内没有需要保护的密钥库，因此在 `/etc/xdg/kwalletrc` 与构建用户的 `~/.config/kwalletrc` 里写入 `Enabled=false` / `First Time=false`。
- **桌面没有「切换到大屏幕模式」图标**：`/usr/share/applications/armada-return-to-gamemode.desktop` 存在，但只有 armada 自己的 `~/Desktop` 有一份，而 `~`（构建用户）的桌面是空的；Plasma 桌面 applet 渲染的是 `~/Desktop` 目录内容，所以看不到入口。现在构建时把 `armada-return-to-gamemode` 与 `armada-anland-game-mode` 两个启动器装进 `~/.config` 同级的主目录桌面。

实测（运行容器）：`systemctl start sddm` 后 `dbus-run-session` → `startplasma-wayland` → `kwin_wayland` → `kded6` → `plasmashell` 全部起来，`wayland-0` 建立，`NRestarts=0`；经 `container-request desktop` 重启会话后依然能完整拉起。本轮新增回归 10 项（补丁正常路径、幂等、上游变更失败、缺参用法错误、非 Anland 回落、shell 语法，以及 Dockerfile 的会话补丁、钱包禁用、桌面启动器三处断言），全套 56 项测试通过、1 项按条件跳过。

仍待确认：显示端 `com.anland.consumer` 当前处于断开状态，`kwin_backend_anland` 报 `consumer disconnected, entering fallback`，因此画面输出尚未验证；这属于 Android 侧显示链路，不是容器内脚本问题。

## 桌面图标、关机授权与模式切换耗时

### 桌面图标

armada 只在自己的账号桌面上放了游戏模式入口，构建用户的 `~/Desktop` 是空的，而 Plasma 桌面 applet 渲染的正是该目录，于是面板里能看到、桌面上却点不到。现在构建时把 `切换到大屏幕模式`（`armada-return-to-gamemode`）和 `关闭容器`（`armada-container-poweroff`）两个启动器装进桌面。

`armada-anland-game-mode.desktop` 不再放到桌面并主动删除：它的 `Exec` 是 `/usr/bin/armada-anland-game-mode`，直接 `exec /usr/libexec/gamescope-anland/startup.sh`，在有会话时启动一个嵌套 gamescope，实际什么都不会发生。真正做完整会话交接的是走 `container-request` 的 `切换到大屏幕模式`。

### KDE 和 Steam 的关机不关容器

两边的电源按钮都经系统总线调 `org.freedesktop.login1.power-off`，默认策略是 `auth_admin_keep`。容器会话里没有 polkit 认证代理，所以请求要么被拒、要么一直等密码。实测以普通用户调用 `CanPowerOff` 返回 `challenge`。

新增 `scripts/etc/polkit/49-armada-container-power.rules` 放行 `power-off`/`reboot`/`suspend`/`hibernate` 及其 `-multiple-sessions`、`-ignore-inhibit` 变体。规则**不能**用 `subject.active` 作为条件：容器里 `pam_systemd` 注册会话就失败（`io.systemd.Login.CreateSession` 返回 `InvalidParameter`，因为没有 VT），`loginctl list-sessions` 看不到桌面用户的会话，任何 subject 都会被判为 inactive。改用 `wheel` 组成员作为条件，范围不超过容器本身。生效后 `CanPowerOff`/`CanReboot` 均返回 `yes`。

`hibernate` 保留在允许列表里但没有实际意义：容器内 `CanSuspend` 返回 `EROFS`（只读文件系统），系统本身也不支持挂起。

### 顺带修掉的条件判断错误

`armada-container-poweroff.service`、`armada-container-reboot.service`、`armada-container-session@.service` 原本用 `ConditionVirtualization=container`。systemd 把 Droidspaces 容器识别为 `container-other`（`/run/systemd/container` 里的 `droidspaces` 不是它认识的已知容器管理器），于是 `systemctl show <unit> -p ConditionResult` 一直显示 `no`，单元看起来像是被跳过。改用 `ConditionPathExists=/run/systemd/container`，与脚本里既有的判断保持一致。

需要注意 `ConditionResult` 会保留上一次执行的结果，oneshot 单元跑完后也不会刷新，所以判断是否被跳过要看 `journalctl` 里有没有实际执行记录，不能只看这个字段。

### 模式切换慢

根因是 SDDM 停止超时。`98-armada-container-ux.conf` 里 `TimeoutStopSec=15`，而 SDDM 收到 SIGTERM 后并不退出：它把信号转给会话，然后等会话消失，容器里没有 VT 可以完成注销，于是每次都要等满整个超时。实测 `container-action` 日志里 `Selected` 到下一步 `RUN ... stop` 之间正好卡 15.1 秒（`21:29:21.007` → `21:29:36.123`）。

会话拆除本来就由 `container-action` 自己做（它随后会 stop `graphical-session.target` 和 plasma/gamescope 的单元），SDDM 不需要再等。改为 `TimeoutStopSec=3` + `KillMode=control-group` + `SendSIGKILL=yes`：

| 路径 | 改动前 | 改动后 |
|---|---|---|
| `systemctl stop sddm` | 15.1 s | 3.4 s |
| 切到桌面 | ~15 s | **0.6–0.7 s** |
| 切到大屏幕 | ~24 s | ~10 s |

切到大屏幕剩余的约 10 秒是 gamescope 自身的启动开销（headless backend + 两个 Xwayland 实例），不属于会话切换逻辑。

本轮回归 65 项通过、1 项按条件跳过。新增覆盖桌面图标安置与游戏模式图标移除、SDDM 停止超时、unit 条件写法、polkit 规则内容（动作覆盖、变体覆盖、不使用 `subject.active`、只处理会话动作）。

## Protontricks 与残留启动器

### 游戏模式启动器没删干净

只从 `~/Desktop` 删掉是不够的：`/usr/share/applications/armada-anland-game-mode.desktop` 仍然存在，它属于 `terra-gamescope-anland-session` 包。直接 `rm` 会被下一次包更新还原，而且会留下「rpm 数据库记录的文件不存在」的不一致状态。

改用 freedesktop 的隐藏机制：在 `/usr/local/share/applications/` 放一个**同名**文件并写 `Hidden=true`。按文件名做覆盖，`/usr/local/share` 在默认 `XDG_DATA_DIRS` 中排在 `/usr/share` 之前，因此菜单读到的是隐藏版本，原文件原样保留。实测 `Hidden=true` 生效，`Hidden=false` 的原件不再被采用。

### Protontricks 找不到 Proton：这是 Steam 侧的兼容性设置

装了游戏之后 `protontricks -l` 能列出（`Stardew Valley (413150)`），但真正执行命令失败：

```
protontricks (ERROR): Active compatibility tool was found, but it's not a Proton
installation supported by Protontricks.
Proton installation could not be found!
```

`--verbose` 揭示了原因：

```
User has configured app Proton version (CompatToolMapping): steamlinuxruntime_steamrt4-arm64
User has configured default Proton version (CompatToolMapping): proton-cachyos-11.0-arm64
Found active compatibility tool: Steam Linux Runtime 4.0 - Arm64
```

Armada 是 ARM64，Steam 给这个游戏的按应用配置写的是 **arm64 Steam Linux Runtime**（Proton 运行在它里面），而 Protontricks 的 `find_proton_app()` 只接受 `is_proton` 为真的工具（判定条件是安装目录里存在名为 `proton` 的文件）。Runtime 目录没有这个文件，于是判为「不是受支持的 Proton 安装」。

这是 **Steam 自己的兼容性设置写错了**，不属于容器缺陷。修法是在 Steam 里给该游戏强制指定 Proton（游戏属性 → 兼容性 → 强制使用特定 Steam Play 兼容工具），`config.vdf` 里对应条目的 `name` 就会从 `steamlinuxruntime_steamrt4-arm64` 变成 Proton 的名字，Protontricks 随即能正常解析。

镜像**不**为此加 `PROTON_VERSION` 包装。那样做有两个问题：一是把 Proton 版本固定死，用户换不了别的 Proton；二是掩盖了真正的原因（Steam 侧的映射），使问题在别的游戏上重复出现。`protontricks` / `protontricks-launch` 保持 RPM 原样，`/usr/local/bin` 下没有同名文件。
本轮回归 69 项通过、1 项按条件跳过。新增覆盖启动器隐藏覆盖层（同名前缀、落点目录、不删包内文件），以及「镜像不携带 Protontricks 包装」这一约束。

## 2026-10-29 重新导入镜像后：桌面模式再次黑屏

本轮镜像是重新导入的（Armada `20261027.ebe101d`），容器于 16:17 重启。切换桌面模式后黑屏，`/var/lib/anland-kde/` 不存在，说明 **Anland KWin 从未在本次镜像里安装过**。

与上文「桌面模式缺 Anland KWin」一节的关系需要说明：那一节记录的修复（`detect_target()` 归一化、Dockerfile 补 COPY）确实在仓库里生效了 —— `install-anland-kde.sh` 现在能识别 `ID=armada` → `fedora:44` 并选到 `anland-kde-fedora44-kwin-6.7.5-aarch64.tar.gz`。但**Dockerfile 只 COPY 脚本、从未执行它**，且 COPY 上方的注释明确写着桌面安装器「meaningless here because the desktop already comes from the armada image」。对其它安装器成立，对这一个不成立：armada 基础镜像自带的 KWin 没有 Anland 后端。因此新镜像里依旧是发行版 KWin。

真实症状比上文记录的更隐蔽：SDDM 没有报 `Session crashed`，而是**静默崩溃循环**。

```
kwin_wayland[19918]: No backend specified, automatically choosing drm
kwin_wayland[19918]: Failed to open drm device /dev/dri/card0
kwin_wayland[19918]: No suitable DRM devices have been found

16:39:07 armada-plasma-session: starting surface=standalone shell=desktop pid=18493
16:39:12 armada-plasma-session: starting surface=standalone shell=desktop pid=18673
16:39:17 armada-plasma-session: starting surface=standalone shell=desktop pid=18870
```

每 5 秒一轮，用户看到的就是「切过去什么都没有」。环境变量 `ANLAND=1`/`ANLAND_SOCKET` 都已正确传给 KWin（`/proc/<pid>/environ` 实测），但那版 KWin 没有可用的 Anland 后端。`org.kde.kwin.waylandbackends` 插件目录在全盘都不存在 —— 后端是编进二进制里的，找插件文件会得出错误结论。

安装时还撞到一个此前未记录的 dnf 冲突：`xorg-x11-server-Xwayland-devel` 按精确版本要求发行版 Xwayland，而归档要把它降级为 `24.1.14-1.anland.fc44`，事务直接失败。该包没有任何包依赖（`rpm -q --whatrequires` 为空），只带头文件，移除后 Xwayland 本体保留。

本轮修复：

- 运行容器：`systemctl stop sddm` → `dnf remove xorg-x11-server-Xwayland-devel --setopt=clean_requirements_on_remove=False` → `install-anland-kde -1` → 校验 → `systemctl start sddm`。
- 仓库：`ArmadaOS.Dockerfile` 在 `DISPLAY_BACKEND=anland-wayland` 分支里实际执行安装（含上述 devel 冲突处理），并修正了那段过时注释。
- 仓库：新增 `scripts/armada/verify-anland-kwin.py`，构建期断言所有 KWin 包为 `anland` 构建且二进制导出 `AnlandBackend`，不满足就让构建失败。

实测（运行容器）：`kwin`/`kwin-common`/`kwin-libs` 均为 `6.7.5-1.anland.fc44`，`xorg-x11-server-Xwayland` 为 `24.1.14-1.anland.fc44`，`strings /usr/bin/kwin_wayland | grep AnlandBackend` 命中。`systemctl start sddm` 后 KWin PID 稳定在 27892（连续 9 秒不变），`plasmashell`、`kioworker` 均在运行，画面恢复。日志出现 `consumer disconnected, entering fallback`，说明 Anland 后端已接管。

期间还观察到一段 `Rendering a layer failed!` / `Failed to find a working output layer configuration!` 的密集重试，随后自行消失、画面正常。**该现象的确切成因未定位**，只能确认它发生在「后端已选对、consumer 未连上」阶段，不是后端选择问题。

仍未验证：

- 镜像未重建。上述 Dockerfile 改动只经过 `bash -n`、`shellcheck`、`git diff --check` 和抽取块语法校验，没有跑过真实构建。
- 未提交 git。`ArmadaOS.Dockerfile` 为 modified，`scripts/armada/verify-anland-kwin.py` 等脚本为新增。
- 冷启动桌面模式未验证。
- `Rendering a layer failed!` 未复现定位。

同时确认了另外两件与本文档既有记录不符的事实，后续复核请注意：

1. `/run/display.sock` 不是「失效的残留 socket」，而是 Android 侧的 bind mount（`/dev/block/dm-51[/local/Droidspaces/Net/anland-a4b95...sock]`），宿主侧应用为 `com.anland.consumer`，本轮它在运行。容器内 `ss -xl` 看不到监听者属正常现象。
2. 会话切换链路双向可用：D-Bus `SwitchToGameMode` → `mode=gamemode` → gamescope 起来；`SwitchToDesktopMode` → `mode=desktop` → kwin 起来。切换逻辑本身没有问题，黑屏在于桌面会话自身起不来。

## 后续核对项

- 完整镜像重建后验证可选工具是否保留；本次已在运行容器安装共享 GPU 驱动并验证 gamescope/Steam 进程，尚未完整重建镜像。
- 核对通用 TUI 对 ArmadaOS 的发行版、桌面和组件识别，确认其更新入口适配 Armada 自带会话栈。
- 单独安排 Steam、Plasma 和 Anland consumer 的图形验证，并记录实际会话与日志。

## ArmadaOS 构建：从 KDE 任务栏移除 Bazaar（2026-10-30）

Armada 基础镜像会从两个配置入口把 Bazaar 固定到 Plasma 任务栏：首次初始化脚本 `armada-pins.js` 的 `icontasks.launchers` 默认列表，以及 `kicker-extra-favoritesrc` 的 `Prepend` 收藏列表。只删桌面文件或 Flatpak 包不够，因为 pin 配置仍会保留失效图标。

仓库新增 `scripts/armada/patch-armada-remove-bazaar-pin.py`，在 Dockerfile 构建期只移除精确 ID `io.github.kolunmi.Bazaar.desktop`，其余启动器顺序与配置不变。脚本会先同时校验两个文件的锚点，再写入；重复执行通过 marker 幂等；上游结构变化或目标项数量不符时构建失败，避免半改或静默漏改。Dockerfile 随后对两处文件做 `grep` 断言，并在成功后移除临时脚本。

验证：独立副本首次运行和第二次运行均通过；目标 ID 在两个配置副本中都不存在；人为移除预期锚点的反例返回非零，且另一文件未被部分改写。Python 编译、Dockerfile 该 RUN 块 `bash -n`、`git diff --check` 通过。

运行容器已同步处理：从 Gold 的 `plasma-org.kde.plasma.desktop-appletsrc`、`kactivitymanagerd-statsrc`，以及系统默认的 `armada-pins.js`、`kicker-extra-favoritesrc` 中删除精确的 `io.github.kolunmi.Bazaar.desktop`。Firefox、Steam、Konsole、Dolphin 启动器保留；修改后 `plasmashell` PID 仍为 `278379`，没有重启图形会话。

未验证：未重建镜像（用户要求不要本地编译容器）；当前运行中的 Plasma 是否立即刷新已加载的任务栏内存状态尚未通过重启验证，但配置文件和默认 pin 均已无 Bazaar。下一份镜像构建后仍需在新用户会话确认任务栏无 Bazaar 图标。未提交或推送 Git。

## ArmadaOS 容器：强制移除并阻止 xdg-desktop-portal（2026-10-30）

用户报告其特殊 Droidspaces/ArmadaOS 环境可能在安装 `xdg-desktop-portal` 后被 Android 杀死 `plasmashell`。这是外部反馈，本容器此前未复现；按风险规避处理，不宣称已证实因果。

当前容器原先安装了 `xdg-desktop-portal`、`xdg-desktop-portal-gtk`、`xdg-desktop-portal-kde`。其中 `rpm -q --whatrequires` 显示 portal 被 GTK/KDE portal、Firefox、`plasma-workspace` 依赖。为严格遵守“只删除 portal 包”的要求，容器内使用 `rpm -e --nodeps` 逐个移除所有名称前缀为 `xdg-desktop-portal` 的 RPM，不运行 DNF erase，也不移除 Firefox、Plasma 或其他依赖方。移除后 RPM 查询确认该前缀无残留；systemd/图形会话没有重启。

容器内 `/etc/dnf/dnf.conf` 的 `excludepkgs` 与 `exclude` 均加入 `xdg-desktop-portal*`。仓库 `ArmadaOS.Dockerfile` 在早期构建阶段写入相同排除规则并清除基础镜像可能已有的匹配 RPM；末尾软件包事务之后再执行一次 `rpm -e --nodeps`，并断言无残留及两条 DNF 排除规则存在。这样既阻止后续 DNF 事务安装，又覆盖绕过 DNF 的基础镜像初始状态。

验证边界：当前容器已实测三个 portal RPM 被移除、DNF 两条排除规则存在；未安装/卸载其他软件包，未重启 plasmashell 或游戏会话。仓库只做静态检查，未重建镜像（用户明确禁止本地容器编译），未提交或推送 Git。尚未验证应用 portal API 的程序行为；移除 portal 可能使依赖文件/选择器 portal 的应用回退到非 portal 路径，这是此规避措施的已知功能代价。

## ArmadaOS 镜像构建：Gamescope 固定版本不一致（2026-10-30）

新编译的 ArmadaOS 容器首次执行 `ArmadaOS.Dockerfile` 时，在 Gamescope 编译入口之前退出：

```text
git clone --branch 3.16.31-ogc1 ...
HEAD = afd6eac6e1b5045119831b63854bad68ec4fd92c
build.sh: Unexpected Gamescope revision
```

这是输入版本配置错误，不是 C++ 编译失败。Dockerfile pin 的 `3.16.31-ogc1` 与 `/usr/local/src/anland/producers/gamescope/ArmadaOS_v5/build.sh` 硬校验要求不一致。Anland 的 `gamescope.patch` 头和构建脚本都要求 `3.17.0-ogc1`，commit 为 `4246b87f49d6116d5f863131dcc401fc52840644`。

检查时还发现同一 Dockerfile 另一处版本契约也不一致：它固定 Armada commit `ec7eda6b0318d22a6021a5ca0016616f21323cfb`，只包含 27 个 Gamescope 补丁；Anland `build.sh` 要求 32 个。当前 Armada checkout `f0a50c0a178d71c0ea3d1a67e385dce0ef6c2158` 的补丁数实测为 32，与 Anland 脚本及 `gamescope.patch` 的当前基线一致。

仓库修复已落在 `ArmadaOS.Dockerfile`：统一为 Gamescope `3.17.0-ogc1` / `4246b87f...`、Armada `f0a50c0a...`；Dockerfile 的补丁数断言改为 32；镜像内 `anland-rebuild-gamescope` 默认 Gamescope tag 和 Armada commit 同步更新。没有放宽 Anland 构建脚本的版本/补丁断言，也没有修改旧容器运行中的图形服务。

静态验证：仓库初始工作区干净；配置修复后 `git diff --check` 通过。曾误启动一次本地 rootful Podman 构建验证，30 分钟后仍停在拉取 `ghcr.io/armada-os/armada:testing` 基础镜像，未进入 Dockerfile 步骤；随后按用户要求立即中止，不再本地编译容器。rootless Podman 的 `newuidmap` 受限，默认 rootful 存储位于 F2FS 且不支持 overlay；没有形成可用的本地镜像。后续只在用户指定的新编译环境中验证。

未验证：Dockerfile 实际构建、Gamescope RPM 产出、导出 RootFS、导入后的桌面/游戏会话；未提交或推送 Git。
## ArmadaOS 镜像构建失败：portal 排除断言（2026-10-31）
新镜像构建到 `[customizer 90/92]` 时失败，退出码 1。失败指令就是 Dockerfile 末尾的 portal 断言块：
```text
#120 1.105 + test -z ''
#120 1.106 + grep -q '^excludepkgs='      -> 通过
#120 1.107 + grep -q '^exclude='          -> 失败，exit code 1
```

### 取证
`test -z` 通过说明 RPM 侧无 portal 残留；`^excludepkgs=` 通过说明 dnf.conf 里有一行以 `excludepkgs=` 开头；紧随其后的 `^exclude=` 失败。两条断言同时成立只有一种解释：`excludepkgs` 与 `exclude` 被写进了**同一行**，该行只能以其中一个键开头。

把 HEAD 版本的两段 portal 相关 `RUN` 块按 Docker 的续行规则拼回 shell 脚本，在真实 `libdnf5` RPM payload 提取的初始 `/etc/dnf/dnf.conf`（63 字节，仅注释 + `[main]`）上执行，得到：
```text
[main]
excludepkgs=xdg-desktop-portal*\nexclude=xdg-desktop-portal*\n,kwin*,xorg-x11-server-Xwayland*
```
即字面 `\n` 未转义，两行被拼接；随后 `install-anland-kde` 的 hold 逻辑又把 `,kwin*,xorg-x11-server-Xwayland*` 追加到这条坏行上。对该结果执行 CI 的两条断言：`excludepkgs_rc=0`、`exclude_rc=1`，与构建日志完全一致。

### 根因
`ArmadaOS.Dockerfile` 中两处用了 4 个反斜杠的 `\\n`，而 Docker 不处理行内反斜杠，shell 收到的是 `\n`：

1. `printf '%s=xdg-desktop-portal*\\n'` 输出字面 `\n`，`excludepkgs=` 和 `exclude=` 挤在同一行；
2. `rpm -qa --qf '%{NAME}\\n'` 让 rpm 收到 `\\n`，输出字面 `\n`，所有包名连成一行，`grep '^xdg-desktop-portal'` 的 `^` 锚定失效 —— 实测 `rpm -qa --qf '%{NAME}\\n' | grep -c '^libdnf5'` 返回 0，正确写法返回 4。这意味着 portal 的 `rpm -e` 循环**从未真正匹配到任何包**，即使断言偶然通过也不代表包被移除。

### 修复（仅 `ArmadaOS.Dockerfile`）
- 第 65 行 `printf` 的 `\\n` → `\n`（shell 层正确转义，输出真实换行）。
- 第 68、71、2093、2096 行 `rpm -qa --qf '%{NAME}\\n'` → `rpm -qa`（一行一个包名，彻底绕开 `--qf` 转义问题）。
- 未改断言、未放宽条件、未动 `install-mesa.sh` / `install-anland-kde.sh` / `systemd257.sh` 的 hold 逻辑。

### 验证
以 `libdnf5` RPM payload 提取的真实初始配置为起点，按构建顺序串行执行四个阶段：早期 Dockerfile 块 → `install-anland-kde.sh:write_dnf_config_with_managed_block` → `install-mesa.sh:write_dnf_config_with_managed_block` → `systemd257.sh:write_dnf_config_with_systemd_hold`。

修复后结果：
```text
[main]
excludepkgs=xdg-desktop-portal*,kwin*,xorg-x11-server-Xwayland*
exclude=xdg-desktop-portal*,mesa*,systemd*
```
四阶段 rc 均为 0；`excludepkgs_rc=0`、`exclude_rc=0`；配置中字面 `\n` 计数为 0。

补充校验：两段 RUN 块拼回后 `sh -n` 均通过；同一块连续执行两次结果不变（幂等）；已存在 `excludepkgs`、已存在 `exclude`、两者都已含 portal 三种初始状态下断言均通过；全仓库 8 个 Dockerfile 与 `*.sh`/`*.py` 扫描无残留双重转义；`git diff --check` 通过。

### 仍未验证
未重建镜像（本容器 rootless Podman 因 `newuidmap` 无 setuid/filecaps 无法启动，rootful 存储亦不可用），因此 `#120` 之后剩余 2 层与最终导出 RootFS 未实测。上述验证是等价的 shell 级复现，不是容器内真跑。未提交或推送 Git。

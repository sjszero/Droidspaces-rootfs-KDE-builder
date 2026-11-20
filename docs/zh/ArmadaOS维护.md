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

- 启动画面进度文件由上游硬编码的 `armada` 用户维护，Gold 无法写入。`scripts/armada/configure/configure-armada-splash.py` 现在将状态写入脚本和 `/etc/tmpfiles.d/armada-run.conf` 的 splash 目录归属设为所选用户，同时保留 root 所有的 `/run/armada` 和其他规则。运行容器已应用相同修复。
- 更新后的 ARM Steam 在原生 KGSL GL 路径中出现 DRI3/GBM dma-buf 导出失败，`steamwebhelper` 的 `SIGTRAP` 和 Steam 主进程退出码 1 已由进程跟踪确认。单独关闭 CEF GPU 加速以及禁用共享纹理均未解决。对照镜像内 Anland 参考启动脚本，游戏会话改用同一 Mesa 驱动包中的 Zink/Turnip，并只为 Steam 客户端命令预加载 `libXrandr.so.2`，解决 `XRRGetOutputInfo` 符号查找问题；无需关闭 GPU 加速。`scripts/armada/anland/armada-steam-anland.sh` 只对 Anland 后端生效，并保留显式指定的 Vulkan ICD 和现有预加载库。

正式脚本已安装到运行容器，清除临时跟踪覆盖及无效测试参数后重新启动了游戏会话。Steam 使用 `-gamepadui -steamos3 -steampal -steamdeck`，大屏幕登录页已完成加载，读取到二维码登录与账号密码表单；gamescope 焦点为 Steam AppID `769`，实际 X11 窗口截图包含渲染内容。诊断证据和截图保存在 `~/.cache/armada-driver-maintenance/`。该验证未重启容器，冷启动和重建镜像仍需单独验证。

本轮完整回归共 37 项：36 项通过，1 项大于 4 GiB 的 ZIP64 测试按默认条件跳过。新增覆盖包括 ArmadaOS/Fedora 43、44 驱动目标一致性、媒体解码目录、未知版本拒绝、Debian 独立目标、splash 配置幂等性及失败保护、Anland Steam 环境与其他后端隔离。ShellCheck、Shell 语法和 `git diff --check` 通过。

## Steam 画面定格修复（同日续）

上一轮的 Zink 修复让 Steam 大屏幕登录页成功渲染，但闲置约 8 分钟后画面再次定格：CEF 的 DevTools 目标仍可读取，DOM 文本完整，而 X11 焦点窗口与 CEF 截图同时退化为纯黑（`getextrema` 全 0）。

`cef_log.txt` 给出链路：CEF 的 GPU 进程反复 `exit_code=5`（SIGTRAP）后不再重生，`pgrep -f 'steamwebhelper.*--type=gpu'` 为 0，两个渲染进程各自占用约 90% CPU 空转（`eu-stack` 显示 `__lll_lock_wake` / Mesa `util_queue_thread_func`），页面日志随之静默。

根因与 Zink 无关：`/proc/<renderer>/maps` 显示 `steamwebhelper` 加载的是 Steam 自带的 `steamrtarm64/libEGL.so`、`libGLESv2.so`（ANGLE），CEF 不会使用系统 Mesa，因此 `MESA_LOADER_DRIVER_OVERRIDE=zink` 从未作用到 UI 的 GPU 进程，ANGLE 仍在原生 KGSL 上触发崩溃。镜像内 `producers/gamescope/ArmadaOS_v5/startup.sh` 中已标注为已验证的 KGSL/ANGLE 变通方案此前没有生效。

修复在 `scripts/armada/anland/armada-steam-anland.sh` 中追加 ANGLE 覆盖，并与 XRandR 预加载一样只作用于 Steam 客户端命令，不改动 gamescope：

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

`scripts/armada/anland/armada-steam-anland.sh` 现在在 Anland 后端默认导出 `SCREEN_WIDTH=2480`、`SCREEN_HEIGHT=1116`，同时允许外部环境变量覆盖，非 Anland 后端保持不变。运行容器已同步部署；重启 `gamescope-session-plus@steam.service` 后实测命令行包含 `-W 2480 -H 1116`，Xwayland 报告 `current 2480 x 1116`，输出为 `gamescope connected 2480x1116+0+0`，Steam 与 `steamwebhelper` 进程均保持运行。这确认 Steam 现在使用完整面板几何。

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

修复方式（`scripts/armada/anland/patch-armada-plasma-session.py` + Dockerfile 第 7i 节）：

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
- 仓库：新增 `scripts/armada/anland/verify-anland-kwin.py`，构建期断言所有 KWin 包为 `anland` 构建且二进制导出 `AnlandBackend`，不满足就让构建失败。

实测（运行容器）：`kwin`/`kwin-common`/`kwin-libs` 均为 `6.7.5-1.anland.fc44`，`xorg-x11-server-Xwayland` 为 `24.1.14-1.anland.fc44`，`strings /usr/bin/kwin_wayland | grep AnlandBackend` 命中。`systemctl start sddm` 后 KWin PID 稳定在 27892（连续 9 秒不变），`plasmashell`、`kioworker` 均在运行，画面恢复。日志出现 `consumer disconnected, entering fallback`，说明 Anland 后端已接管。

期间还观察到一段 `Rendering a layer failed!` / `Failed to find a working output layer configuration!` 的密集重试，随后自行消失、画面正常。**该现象的确切成因未定位**，只能确认它发生在「后端已选对、consumer 未连上」阶段，不是后端选择问题。

仍未验证：

- 镜像未重建。上述 Dockerfile 改动只经过 `bash -n`、`shellcheck`、`git diff --check` 和抽取块语法校验，没有跑过真实构建。
- 未提交 git。`ArmadaOS.Dockerfile` 为 modified，`scripts/armada/anland/verify-anland-kwin.py` 等脚本为新增。
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

仓库新增 `scripts/armada/configure/patch-armada-remove-bazaar-pin.py`，在 Dockerfile 构建期只移除精确 ID `io.github.kolunmi.Bazaar.desktop`，其余启动器顺序与配置不变。脚本会先同时校验两个文件的锚点，再写入；重复执行通过 marker 幂等；上游结构变化或目标项数量不符时构建失败，避免半改或静默漏改。Dockerfile 随后对两处文件做 `grep` 断言，并在成功后移除临时脚本。

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

静态验证：仓库初始工作区干净；配置修复后 `git diff --check` 通过。曾误启动一次本地 rootful Podman 构建验证，30 分钟后仍停在拉取 `ghcr.io/armada-os/armada:testing` 基础镜像（当时的上游；2026-11-20 起已改为 `armadaos-freedom`），未进入 Dockerfile 步骤；随后按用户要求立即中止，不再本地编译容器。rootless Podman 的 `newuidmap` 受限，默认 rootful 存储位于 F2FS 且不支持 overlay；没有形成可用的本地镜像。后续只在用户指定的新编译环境中验证。

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

## 2026-11-07 game-tweaks 环境默认值
新增脚本 `scripts/armada/configure/configure-armada-game-tweaks-env.py`，接入 `ArmadaOS.Dockerfile` 的 `8c` 段。
Armada 读取两份配置：`/usr/share/armada/game-tweaks.json` 是工厂默认值（**没有 `env` 块**），`/etc/armada/game-tweaks.json` 是覆盖层，`armada_game_tweaks.py` 用 `data["global"].update(overrides)` 做浅合并。脚本只往覆盖层写入 `global.env.MESA_LOADER_DRIVER_OVERRIDE=kgsl`，不动工厂文件。
行为约束：
- 已有覆盖文件保留全部既有键，包括手工添加的 `env` 条目；
- 该键已存在但值不同（例如用户选了 `zink`）时**保留用户值并打印提示**，不覆盖；
- JSON 损坏时以非零退出，绝不静默重写；
- `ARMADA_GAME_TWEAKS_OVERRIDES` 可指向暂存副本，供镜像构建与测试使用。
实测 5 个场景全部通过：新建、幂等重跑、保留其它键、保留用户自定义值、损坏文件拒绝覆盖。
### MangoHud 改用上游源码（2026-11-12）
镜像现在从上游 MangoHud 源码构建，不再使用 armada 打过九个补丁的分支。原先的 `8c` 降级段（把 `0.8.4-1.fc44.armada` 降为 `0.8.3~rc1-2.fc44`）早已删除，`8d` 段也从「克隆 armada 树 + 套 armada 补丁集」改为「克隆上游 pinned commit + 套本仓库容器补丁」。

切换理由：armada 分支只在裸机上成立，容器里 GPU 占用/温度恒为 0；而 Fedora 仓库只有 `0.8.3~rc1`，比 armada 的 0.8.4 更旧，不能作为替代。上游 master 自带 `MSM_KGSL`/`MSM_DPU` 后端，正好对应容器暴露的 sysfs 布局。

失败的旧方案记录，避免重复踩坑：
- **`mangoapp` 与 `glfw` 存在硬冲突**：上游 `meson.build` 在 `mangoapp=true` 时追加 `imgui_options += ['glfw=enabled']`，而 `glfw-devel` 依赖 `pkgconfig(dri)`（来自 `mesa-libGL-devel`），本镜像 `dnf.conf` 有 `exclude=...mesa*`。**不要用 `--setopt=exclude=` 绕过该排除**：实测会把 Mesa 从 26.2.5 升级到 26.2.6 并删除多个 mesa 子包，破坏 KGSL/Turnip 栈。回滚需同样绕过 exclude 执行 `dnf history undo`。构建脚本在 mesa 尚未被锁定前运行，直接装 `glfw-devel`，失败时回退为「只提取头文件 + `glfw3.pc` + `libglfw.so` 符号链接」。
- **降级发行版包**：不可行，Fedora 只有 `0.8.3~rc1`，比 armada 的 0.8.4 旧。
### 仍未验证
未重建镜像；本次验证是在当前容器内直接执行脚本，等价于 Dockerfile 中对应 RUN 块的命令序列，但不是完整镜像构建。
### 2026-11-08 该脚本已删除
`configure-armada-game-tweaks-env.py` 与 Dockerfile 的 `8c` 段整体移除。
当初的理由是"容器内 render node 通过 Android 显示栈暴露，Mesa 会去找不存在的 DRM 设备"。这个判断不成立，而该覆盖层写入的是 `global.env`，对**所有**游戏生效，包括原生 ARM64 Proton：
- 原生路径上强制 `kgsl` 正常（`glxinfo` 出 FD750），不强制时走 zink 也正常，两者都可用，所以覆盖值本身不是必需的；
- 强制 `kgsl` 反而有害：容器里的 `/usr/lib/dri` 指向 guestos 的 x86 Mesa，Mesa 会去加载跑不起来的 x86 DRI 驱动，日志报 `failed to load driver: kgsl`，回退 zink 又撞上 Vulkan 串连失败，最终 GL 完全起不来。
`/etc/environment` 里那份 `MESA_LOADER_DRIVER_OVERRIDE=kgsl`（Dockerfile 第 8a 段）保留不动：它只用于原生 aarch64 会话，实测正常。

## 2026-11-07 MangoHud 容器指标补丁
容器里的 MangoHud 指标全为 0，实测日志给出三处失效：
```text
[warning] kgsl: /sys/class/kgsl/kgsl-3d0/cur_freq is not found
[debug]   hwmon: failed to find hwmon directory
[error]   Error opening directory '/sys/class/hwmon/'
[debug]   load = 0, proc_vram = 0, power = 0, core = 0, temp = 0
```
根因是 armada 补丁集只读 devfreq `cur_freq`（Hz），而容器内核暴露的是老式 `kgsl-3d0` 布局，频率在 `clock_mhz`（MHz），`cur_freq` 不存在；同时 `/sys/class/hwmon` 整个未挂载。
### 补丁：`scripts/armada/mangohud/mangohud-container-metrics.patch`

补丁基于上游 `MANGOHUD_COMMIT=791f920` 重写，共 3 个文件、304 行。上游 master 自带 `MSM_KGSL` 后端（`mangohud-next/server/metrics/gpu/msm/kgsl.*`），已经把 kgsl-3d0 当作 hwmon 目录来读，所以旧版针对 `init_kgsl()`/`get_kgsl_clock()` 的改动不再需要。

| 位置 | 改动 |
| --- | --- |
| `mangohud-next/server/metrics/hwmon.cpp` `find_sensors()` | 去掉「文件名必须含 `_`」的前置过滤，改为仅在需要读 `*_label` 时才检查。kgsl-3d0 的 `temp` 没有下划线也没有 label，旧逻辑直接丢弃它，导致温度恒为 0 |
| `src/cpu.h` | 新增 `CPU_POWER_ENERGY_MODEL`、`CPUPowerData_energy_model(_domain)` |
| `src/cpu.cpp` `read_time_in_state()` / `get_cpu_power_energy_model()` | 读 EAS 功耗表 × 频率驻留增量，做加权平均 |
| `src/cpu.cpp` `init_cpu_power_data_energy_model()` | 解析 `/sys/kernel/debug/energy_model/<域>/cpus` 与 `ps:<freq>/{frequency,power}` |
| `src/cpu.cpp` `InitCpuPowerData()` | 在 hwmon/APU/deckard/powercap 全部失败后回退到 energy model |

实测（安装新 RPM 后，`MANGOHUD_LOG_LEVEL=debug` 跑 `vkcube`）：`hwmon: temp reading found at /sys/class/kgsl/kgsl-3d0/temp`、`load 0→3`、`CoreClock 231`、`temp 0→33`，`energy_model` 识别出 4 个域（cpu0/2/5/7，18/32/29/37 个 OPP）。

仍然为 0 的是 `power`/`proc_vram`/`fan`/`voltage`：msm 驱动只通过 hwmon 暴露这些，容器无 hwmon 即无数据源；统一内存架构也没有独立 VRAM。这些不做假值填充。
### CPU 功耗：走内核 EAS energy model
`cpu_power` 原先恒为 0，因为 MangoHud 只会从 `hwmon`（k10temp/zenpower/zenergy/apm_xgene）、`powercap`（RAPL）或 AMD APU 取功耗，这台设备三者都没有。实测确认：

| 检查项 | 结果 |
| --- | --- |
| `/sys/class/hwmon` | 整机不存在（`CONFIG_HWMON` 未启用） |
| `/sys/class/powercap` | 目录存在但**零条目**（`CONFIG_POWERCAP=y` 但无驱动注册） |
| `walt` / `qcom_llcc` 等能量计数器 | 均不存在 |

但内核发布了厂商标定的 EAS 功耗表，补丁据此新增数据源：

| 数据源 | 路径 | 内容 |
| --- | --- | --- |
| 静态功耗表 | `/sys/kernel/debug/energy_model/<域>/ps:<freq>/power` | 每个 OPP 的功耗 |
| 频率驻留计数 | `/sys/devices/system/cpu/cpuN/cpufreq/stats/time_in_state` | 各 OPP 累计驻留时间 |

`get_cpu_power_energy_model()` 对驻留增量做功耗加权平均，再按域求和——与 Android Power HAL 同一套模型。注册为 `CPU_POWER_ENERGY_MODEL`，排在 hwmon / APU / powercap 全部失败之后，裸机行为不变。

**单位坑（务必注意）**：debugfs 的 `power` 属性由内核 `em_debug_power_show()` 输出为 `ps->power * 1000`，即 **µW**；而内核内部 `em_perf_state.power` 字段是 mW。第一版按 mW 换算算出 243 W（整机仅 0.6 W），已改为 `/1000000`。变量名同步用 `uw` 以免再误读。

实测（本机 4 簇）：

| 域 | CPU | OPP 数 | 当前功耗 |
| --- | --- | --- | --- |
| cpu0 | 0-1 | 18 | 0.017 W |
| cpu2 | 2-4 | 32 | 0.052 W |
| cpu5 | 5-6 | 29 | 0.048 W |
| cpu7 | 7 | 37 | 0.129 W |
| 合计 | | | **0.246 W** |

同期整机电池 `power_now` 为 0.606 W，CPU 占 41%，量级合理。

GPU 功耗**无法获取**：`energy_model` 只含 cpu0/2/5/7，GPU OPP 的 `u_watt`/`u_volt_target`/`u_amp` 全为 0（厂商未填充），kgsl debugfs 无任何功耗节点。要真实读数只能改内核让 kgsl 注册 hwmon/powercap，超出容器范围。

### 开机自动放行：`scripts/armada/mangohud/mangohud-energy-model.service`
`energy_model` 在 debugfs 下，挂载点权限是 `drwx------ root:root`，普通用户读不到。装成 systemd oneshot：

- `ExecStart`：debugfs 未挂载则先挂，再把挂载点 `chmod 0755`（只放开目录，内部文件仍由内核控制）
- `ExecStartPost`：`test -r /sys/kernel/debug/energy_model`，失败则单元可见地报错，避免 `cpu_power` 静默消失
- `WantedBy=multi-user.target`，镜像构建时 `systemctl enable`

冷启动场景已实测：手动 `chmod 700` 模拟重启后权限状态 → 用户读不到 → `systemctl restart` → 恢复可读 → MangoHud 重新识别出 4 个域。
### 构建脚本：`scripts/armada/mangohud/build-mangohud-container.sh`
从上游 `MANGOHUD_COMMIT` 取源码，套本仓库容器补丁后产出 RPM。脚本不再依赖上游源码树（`~/armada`，现为 `~/armadaos-freedom`）：`MANGOHUD_COMMIT` 在 Dockerfile 与本脚本中各有一份默认值，两者必须一致。
```bash
scripts/armada/mangohud/build-mangohud-container.sh              # 只构建
scripts/armada/mangohud/build-mangohud-container.sh --install    # 构建并安装
scripts/armada/mangohud/build-mangohud-container.sh --dry-run    # 只打印解析结果
```
接入 `ArmadaOS.Dockerfile` 的 `8d` 段：`git clone` 上游 → checkout pinned commit → 构建 → 安装 → 清理。
脚本处理了三个宿主限制：
1. **glfw-devel 装不上**（`pkgconfig(dri)` ← `mesa-libGL-devel`，被 `exclude=...mesa*` 挡住）。改为 `dnf download` 后只提取头文件、`glfw3.pc` 和 `libglfw.so` 符号链接，不碰 mesa。
2. **BuildRequires 无法满足** `pkgconfig(dri)`/`pkgconfig(glfw3)`。用 `--nodeps` 只跳过这道门禁，实际编译仍链接已提取的 glfw。
3. **`mangoplot` 的 `#!/usr/bin/env python` shebang 被 rpm 判为 ambiguous**（`%install` 阶段直接失败）。在 spec 里改写成 `#!/usr/bin/python3` 并联同其它文件一起打包。
构建前会先用 `--fuzz=0` 验证补丁可干净应用，漂移即硬失败，不会静默偏移。
meson subproject 全部预下载并做 SHA256 校验，通过 `MESON_PACKAGE_CACHE_DIR` 交给 meson，避免 `%build` 阶段才去联网。
### 仍未验证
脚本已在容器内端到端实跑（含 `--install`，产出 1.9M RPM 并生效）；未重建完整镜像。

## 2026-11-18 x86-64 游戏：box64 与 Steam 兼容层

### 现象与根因

Steam 库里唯一的 Linux 游戏 `Slay the Spire 2`（AppID 2868840）启动后进程在 1 秒内 added→removed。`file` 确认游戏本体与全部 `.so` 都是 **x86-64**，数据目录叫 `data_sts2_linuxbsd_x86_64`，depot 里没有 aarch64 构建；但 `config.vdf` 的 `CompatToolMapping` 把它映射到 `steamlinuxruntime_steamrt4-arm64`（runtime AppID 4185400），而那套运行时里只有 aarch64 库。

`compat_log.txt` 显示这是映射优先级的结果，不是用户随手选的：

```text
Requesting mapping AppID 2868840 from appinfo to tool "SteamLinuxRuntime_sniper"   (priority 90)
Mapping AppID 2868840 to tool "steamlinuxruntime_steamrt4-arm64" with priority 250  (用户映射)
```

arm64 客户端把游戏声明的 "Steam Linux Runtime 4" 解析成 arm64 变体。arm64 运行时本身**不是无用**——它是给原生 aarch64 游戏的容器，不负责翻译 x86-64；对当前库（只有 x86-64 内容）确实没有用途。FEX 路线按用户决定不再维护，`fex-emu-*` 与 `ArchLinux.sqsh` 原样保留不动。

复现：在 arm64 运行时里执行游戏 → `Syntax error`（shell 解析）；直接执行 → `无法执行二进制文件`（ENOEXEC）。

### 方案：`scripts/armada/box64/`，Dockerfile `8e` 段

| 组件 | 作用 |
| --- | --- |
| `build-box64.sh` | 从上游 pinned commit 编译 box64，strip 后放 `/usr/local/libexec/box64/`，用 alternatives 以优先级 200 接管 `/usr/bin/box64` |
| `install-x86-64-libs.sh` | 用 `dnf download --forcearch=x86_64` 取 Fedora 的 x86_64 RPM，提取 `.so*` 到 `/usr/lib/box64-x86_64-linux-gnu`（box64 在 `src/core.c` 里固定搜索的目录） |
| `box64-binfmt` + `.service` | 挂载 `binfmt_misc` 并注册 box64 作为 x86-64 解释器，开机生效 |
| `compatibilitytool.vdf` / `toolmanifest.vdf` / `box64-run` | Steam 自定义兼容层，游戏属性里可选 `box64 (Armada)` |

透明运行的证据：不显式调用 box64，直接 `./SlayTheSpire2`，内核 binfmt 接管，GPU 14–15%、窗口 1280×720、locale 与存档加载完成。

`systemd-binfmt` 在本容器里永远不会启动：它是 `static` 且带 `ConditionPathIsMountPoint=/proc/sys/fs/binfmt_misc`，而没有任何东西在开机时挂载那个目录，因此 `binfmt.d` 的条目全部静默失效。自建 oneshot 单元先挂载再注册。FEX 也用 `binfmt.d` 声明 x86-64，`binfmt_misc` 对同一 ELF 的多个 handler 按**注册顺序逆序**择优，所以脚本先 `echo -1 > binfmt_misc/box64` 再重新注册，让结果与启动顺序无关。

### 三个必须踩过的坑

1. **发行版 box64 0.3.6 跑不了 .NET 游戏**。Godot Mono 高频使用 `MOVQ xmm, FS:[abs32]`（`64 F3 0F 7E 04 25`）做 TLS 访问，0.3.6 的 dynarec 未实现该形式，SIGILL 在 `0x13703d5`。`BOX64_DYNAREC=0` 走解释器不崩但慢到不可用。上游 0.4.4（`2f130fab`）实现后同一二进制直接过。
2. **CoreCLR 的 GC 预留 box64 满足不了**。默认配置在 `GC heap initialization failed with error 0x8007000E`（E_OUTOFMEMORY）处中止，`Failed to create CoreCLR`。加 `DOTNET_GCHeapHardLimit=0x20000000`（512MB）+ `DOTNET_gcServer=0` 后可启动。反直觉的是**调大上限更糟**：改成 1GB 时窗口都没创建就 5 秒退出，512MB 是必要值而不是保守值。
3. **禁用并发 GC 不够，真正的竞态在内存序**。Steamworks 初始化成功后游戏会走云存档/Finalizer 路径，然后在 `System.GC.RunFinalizers()` 抛 `System.ArgumentException: Disposable not registered`（Godot 的 disposables tracker 竞态）并中止。它**非确定性**，所以单次通过不算证据：

| 配置 | 运行次数 | 结果 |
| --- | --- | --- |
| 512MB + `gcServer=0`（基线） | 1 | 12 s 崩 |
| 同上，另一轮 | 1 | 24 s 崩 |
| `+gcConcurrent=0` | 3 | 30 s 通过 / 3 s 崩 / 24 s 活（不稳定） |
| `GCHeapHardLimit=0x40000000` + `gcConcurrent=0` | 1 | 5 s 崩，无窗口 |
| `+BOX64_DYNAREC_STRONGMEM=1` | 6 | 全部 28–30 s 跑满，0 崩溃 |
| `+BOX64_DYNAREC_STRONGMEM=2` | 4 | 全部 28–30 s 跑满，0 崩溃 |

box64 的 dynarec 默认弱内存模型，.NET GC 的无锁算法需要真实内存序；`STRONGMEM=1` 足够且比 `2` 便宜得多，因此 `box64-run` 里默认设 1（可被外部覆盖）。`gcConcurrent=0` 一并保留。

### x86-64 库只需要 41 MB，不需要 rootfs

box64 把 libc/libm/libpthread/libdl/ld-linux、libvulkan/libGL/libX11、libssl/libcrypto、libasound/libpulse/libudev/libdbus/libfontconfig/libz 等**全部 native wrap** 到宿主的 aarch64 库，所以这些库一个都不能打包（打包会遮蔽宿主 wrapper）。`BOX64_LOG=1` 统计一次完整运行里实际被 emulated 的库只有 8 个：`libstdc++`、`libgcc_s`、`libcurl` 及其 `libnghttp2`/`libnghttp3`/`libngtcp2`/`libssh2` 链，加上 CoreCLR 需要的 ICU。

| 库集 | 大小 | 来源 | 实测 |
| --- | --- | --- | --- |
| 早期方案：解包 FEX 的 `ArchLinux.sqsh` | 4.4 GB | Arch Linux rootfs | 可运行，但体积荒谬 |
| 只放 libstdc++/libgcc_s | 3 MB | Arch rootfs | 在 ICU 处失败 |
| 补 ICU + curl 链（ICU 78） | 43 MB | Arch rootfs | 通过 |
| 现方案（ICU 77，Fedora 44） | 41 MB | `dnf download --forcearch=x86_64` | 2/2 运行 30 s 通过，无 ICU/libstdc++ 报错 |

ICU 大版本随 Fedora 走（fc44 是 77），CoreCLR 的 dlopen 版本列表能接受，所以不需要跟 Arch 的 78 对齐。

### Steam 兼容层

`/usr/share/steam/compatibilitytools.d/box64-armada/`，模板取自同目录已有的 `lepton-armada`：

```text
compatibilitytool.vdf   box64_armada / "box64 (Armada)" / from_oslist linux, to_oslist linux
toolmanifest.vdf        "commandline" "/box64-run %verb% --"，无 require_tool_appid
box64-run               过滤 arm64 库路径 + 设置 .NET/STRONGMEM 变量 + 判定 ELF 架构
```

关键点：

- **不设 `require_tool_appid`**。同目录的 `proton-cachyos-11.0-arm64` 设了 `4185400`，因此 Steam 先把命令塞进 aarch64 的 pressure-vessel 容器，容器里没有宿主 `/usr/bin/box64`。box64 要用的正是宿主的 aarch64 glibc/Mesa/Vulkan，必须留在宿主执行。
- **必须自己导出环境变量**。`/etc/environment` 由 pam_env 加载，但实测 Steam 客户端进程环境里 `BOX64_LD_LIBRARY_PATH`/`DOTNET_*` 一个都没有（只有 `LD_LIBRARY_PATH=<steamrtarm64>`、`LD_PRELOAD=libXrandr.so.2`、`SYSTEM_PATH`）。兼容层脚本因此无法依赖全局配置。
- **必须过滤 Steam 注入的 arm64 路径**。x86-64 进程继承 `LD_LIBRARY_PATH=/…/steamrtarm64:/…/lib/aarch64-linux-gnu` 与 arm64 的 `LD_PRELOAD` 会让加载器解出错误架构，脚本按 `*steamrtarm64*|*linuxarm64*|*aarch64*|*gameoverlayrenderer*` 丢弃。
- 目标可执行文件若是 ELF 且 `e_machine=62` 才交给 `box64`；若是 shell 启动脚本（`launch_vulkan.sh` 之类）就原样 `exec`，脚本内部的 x86-64 子进程由 binfmt 接管并继承同一套环境。
- Steam 对 2868840 的启动链是 `/bin/sh -c /usr/libexec/armada/armada-game-launch <steam-launch-wrapper> … reaper SteamLaunch AppId=2868840 -- <runtime>/_v2-entry-point --verb=waitforexitandrun -- <game>/SlayTheSpire2`，选定本工具后 `_v2-entry-point` 那一段被替换为 `/usr/share/steam/compatibilitytools.d/box64-armada/box64-run`，`armada-game-launch`（FEX 的 per-game 配置器）仍在最外层，不冲突。

### 仍未验证 / 待办

- 兼容层要在 Steam **启动时**扫描才会注册（`compat_log.txt` 里自定义工具以 `Posting tool registration callback 0 <name>` 出现，AppID 0）。因此 `box64 (Armada)` 进入游戏属性的下拉列表需要重启 Steam；映射改成 `box64_armada` 也必须写 `config.vdf`，而 Steam 运行中不读该文件。
- Dockerfile `8e` 段未在完整镜像构建中跑过；本次是在现有容器内逐条执行等价命令验证的。

## 2026-11-19 `/etc/box64.box64rc` 针对本机调优

发行版自带的那份 `box64.box64rc`（19 KB，2025-06 生成）是 0.3.6 时代的**按程序名堆叠的节**，没有全局 `[*]` 节，对我们这个"大量 .NET 游戏 + 异构 8 核 + Android 内核"的组合等于没配置。改为本仓库维护的配置，原文件保留为 `/etc/box64.box64rc.distro`。

### 必须先记住的三条机制

| 机制 | 事实 | 影响 |
| --- | --- | --- |
| 优先级 | `~/.box64rc` > `/etc/box64.box64rc` > **环境变量** | rcfile 会覆盖启动器 export 的值，所以 `.NET` 的稳定参数必须同时写在 rcfile 里 |
| 全局节 | `[*]` 是唯一的"对所有程序生效"节，`[*setup*]`/`[*install*]` 是名字通配节 | 具体节只覆盖自己定义的键 |
| 预设 | 0.4.x 内置 `BOX64_PROFILE=safest/safe/default/fast/fastest`，用 `SET_IF_EMPTY` 语义 | 显式写的键不会被预设覆盖，但 `fast` 会带 `STRONGMEM=1 DIRTY=1 BIGBLOCK=3 SAFEFLAGS=0 FORWARD=1024` |

### 本机环境实测的事实

| 项 | 值 | 对调优的意义 |
| --- | --- | --- |
| CPU | 8 核，`cpu_capacity` = 369 369 897 897 897 842 842 1024 | **确有小核且排在前**，`BOX64_SKIPCPU` 理论可用 |
| `vm.max_map_count` | 2147483642 | 不是瓶颈，不需要为映射数让步 |
| `vm.overcommit_memory` | 1 | CoreCLR 的大块预留能过 |
| `vm.swappiness` | **180** | 高换出倾向，长会话下 DynaBlock 膨胀会被压到 swap |
| 页大小 | 4096 | 无常规坑 |
| DynaCache | `~/.cache/box64` 已有 237 MiB | 缓存确实在工作，值得设上限 |

### 测法与两个负载

发行版 box64 是 arm64 二进制，要给别人量化"更快"，只能用 x86-64 负载。`dnf install gcc-x86_64-linux-gnu` 提供交叉编译器（Fedora **没有**交叉 glibc 开发包，所以负载写成 `-ffreestanding -nostdlib -static` + 裸 `syscall`，连带省掉了「库调用是否 native wrapped」这个混淆因素）：

| 负载 | 内容 | 针对的参数 |
| --- | --- | --- |
| `bench/bench_fs.c` | ALU 依赖链、数组读写、SSE 双精度、call/return 密集混合，跑 ~0.5 s | `FORWARD` `SAFEFLAGS` `BIGBLOCK` `CALLRET` `SEP` |
| `bench/bench_fs_mt.c` | 4 个 fork 进程用 `MAP_SHARED` 页抢同一 cache line 做 `LOCK` 原子操作 | `STRONGMEM` `WEAKBARRIER` `PAUSE` `ALIGNED_ATOMICS` |

两点经验：`sha256sum` 这类"看起来是计算"的 coreutils 负载**无效**——x86 版本会走到被 wrap 的宿主加速路径，128 MB 只要 134 ms（≈1 GB/s）；交叉编译又缺 glibc 头文件时不要试图拼 sysroot，直接写 freestanding 更省事。

### 单变量结果（中位数，5 次；**未锁频，事后证明不可靠**）

| 设置 | 单线程 ms | 原子 ms |
| --- | --- | --- |
| base（仅 `STRONGMEM=1`） | 503.9 | 792.9 |
| `STRONGMEM=0` | 500.3 | **602.5** |
| `STRONGMEM=2` | 493.0 | 813.0 |
| **`FORWARD=1024`** | **457.1** | 806.1 |
| **`SAFEFLAGS=0`** | **443.6** | 818.9 |
| `BIGBLOCK=3` | 480.2 | 764.1 |
| `SEP=1` | 646.0 | 801.7 |
| `SEP=2` | 646.3 | 797.3 |
| `CALLRET=1` | 504.9 | 814.2 |
| `PAUSE=1` / `PAUSE=3` | 506.4 / 505.6 | 766.8 / 762.5 |
| `ALIGNED_ATOMICS=1` | 514.9 | 819.3 |
| `WEAKBARRIER=2` | 509.2 | 796.9 |
| `DIRTY=1` | 506.5 | 813.3 |

组合（`FORWARD=1024 + SAFEFLAGS=0 + BIGBLOCK=3`）：单线程 **448.5**（−11%），原子 819.0（不变）；去掉 `BIGBLOCK=3` 是 453.4，说明 `BIGBLOCK` 的贡献在噪声内。

**反直觉但明确的三点**：

1. **`SEP` 是陷阱**：文档说它是 `CALLRET` 的进一步优化，实测单线程 **+28%**，两档一样；锁频复测里依然 +27.8%，是唯一跨两种条件都成立的结论。
2. **`STRONGMEM=0` 快 18–24%（原子场景）**，但它是游戏崩溃的根因，绝不能为了这个数字动它；`STRONGMEM=2` 只慢 2.5%，同样不需要。
3. **`BIGBLOCK=3` 在锁频下没有任何收益**，而它不再检查代码页是否被写过就直接复用块，.NET JIT 一直在写代码页——拦下它的从来是安全性，不是性能。留在默认的 2。

### 游戏级 A/B（未锁频窗口，绝对值不可比；锁频结论见下一节）

用兼容层跑 `Slay the Spire 2`，测到首个窗口的时间（日志里的 `Window changed!` 是游戏自己打的），每种配置 3 次：

| 配置 | 到窗口时间 | RSS |
| --- | --- | --- |
| 仅环境变量（今日状态） | 5.2 / 5.2 / 5.8 s；复测 4.7 / 5.2 s | 1.54–1.59 GB |
| 调优 rcfile（初版，含 `PURGE=1`） | 8.4 / 9.0 / 9.0 s | 1.24 GB |
| 调优 rcfile（**去掉 `PURGE`**） | **4.5 / 4.5 / 4.5 s**（三次几乎无抖动） | 1.27–1.29 GB |
| 同上，在**被限频到 1.0–1.08 GHz** 的窗口内复测 | base 13.8 / 14.3 s vs 调优 **12.8 / 12.9 s**（仍快 8.6%） | — |

最后一行是审查时意外得到的额外证据：设备中途被限到约 1/3 频率（`scaling_max_freq` 1.02–1.08 GHz，硬件上限 2.26–3.4 GHz，温度仅 29–30℃ 所以不是热降频；`/run/armada/perf-state.json` 里也没有相关设置，来源在 Android 侧），所有绝对耗时翻了 2.6 倍，但**相对收益不变**。教训：这类对比必须在同一会话内交替进行，跨时间的绝对数字不可比。

- 初版慢 3 秒的元凶是 `BOX64_DYNAREC_PURGE=1`：启动期生成的块在还没被二次命中时就被回收，于是反复重编译。**已关闭**，并在配置注释里写明这条数据。
- 最终版本比现状**快约 9–10%**，同时 RSS 少 250–300 MB（三次一致，不是单次抖动）。RSS 下降来自 `FORWARD`/`SAFEFLAGS` 改变代码形状，未再细分归因。
- `BOX64_DYNAREC_PURGE` 对**长会话**的内存价值仍未验证（需要数分钟级别的 RSS 曲线），所以只关不删注释。

### 锁频复测：把 CPU 钉在硬件满档

上面那些绝对值不可比，因为测量期间设备先被限到约 1/3 频率、之后又被拉满。把 `scaling_max_freq` 钉到硬件上限后重测（policy0/2/5/7 = 2265600 / 3148800 / 2956800 / 3398400，三次采样稳定；温度 35–43℃，不是热降频），每个格子 5 次和 7 次中位数各一组：

| 设置 | 单线程 ms | 原子 ms | 相对 base |
| --- | --- | --- | --- |
| base（仅 `STRONGMEM=1`） | 413.7 / 412.1 | 657.2 / 677.9 | — |
| **`SAFEFLAGS=0`** | **372.0 / 367.9** | 677.9 / 670.3 | **单线程 −10%，原子 −1%** |
| `FORWARD=1024` | 411.2 / 412.7 | 688.4 / 695.6 | 单线程持平，**原子 +2.6…4.8%** |
| `PAUSE=1` | 411.3 / 411.8 | 703.6 / 701.2 | 单线程持平，**原子 +3.4…7.1%** |
| `BIGBLOCK=3` | 413.8 | 665.3 | 单线程持平，原子 +1% |
| `ALIGNED_ATOMICS=1` | 411.8 | 694.5 | 原子 **+5.7%** |
| `SEP=2` | 528.8 | 682.9 | 单线程 **+27.8%** |
| `STRONGMEM=0` | 410.3 | **537.1** | 原子 −18%（游戏会崩，不可用） |
| `shipped`（`FWD+SF0+PAUSE`） | 371.6 / 369.8 | 681.7 / 681.8 | 与单独的 `SF0` 相同 → 另两项是负担 |

**结论修正**（配置与注释已按此更新）：

1. **`SAFEFLAGS=0` 是唯一真实的收益项**：单线程 −10%，原子场景还不吃亏。
2. **`FORWARD=1024` 没有收益**（那条 −9% 是限频窗口里的伪差异），原子场景反而慢 2–5% → **已从配置移除**。
3. **`PAUSE=1` 在原子场景反而慢 3–7%** → **已移除**。
4. `BIGBLOCK=3`、`ALIGNED_ATOMICS=1` 在锁频下同样没有收益，继续按安全性否决。
5. 最终只剩两个键：`STRONGMEM=1`（稳定性）+ `SAFEFLAGS=0`（性能）。

### 游戏级 A/B，锁频窗口内

预热一次（让各配置的 DynaCache 都命中）后交替跑 3 轮：

| 配置 | 到首个窗口 | RSS |
| --- | --- | --- |
| base（仅环境变量） | 4040 / 4048 / 4035 ms | 1.43–1.45 GB |
| tuned（`/etc/box64.box64rc`） | **3529 / 3528 / 3536 ms** | **1.13–1.17 GB** |

**−12.6% 到窗口、−306 MB RSS、6/6 次无崩溃**，抖动只有 ±10 ms。这是全套改动最干净的一组证据。

### 最终配置（`scripts/armada/box64/box64.box64rc` → `/etc/box64.box64rc`）

| 键 | 值 | 依据 |
| --- | --- | --- |
| `DYNAREC_STRONGMEM` | 1 | .NET GC 必须；相对 0 在原子场景慢 31%（barrier 的真实代价），2 只再慢 2.5% |
| `DYNAREC_SAFEFLAGS` | 0 | 锁频复测里唯一真实的收益：单线程 −10%、原子 −1%；安装器用 `[*install*]` 覆盖回 2 |
| `DYNACACHE` / `LIMIT` / `COMPRESS` | 1 / 1024 / 1 | 冷启动最贵的一环；上游默认 2 GiB 对手持设备偏大 |
| `DYNAREC_PURGE` | 不设（默认 0） | 实测让启动慢 60% |
| `BOX64_NOBANNER` | 1 | 去掉 banner，`BOX64_LOG` 保持默认以便排障 |

显式否决的项（以锁频数据为准）：`SEP`（+28%）、`FORWARD=1024`（无收益，原子 2–5% 更差）、`PAUSE=1`（无收益，原子 3–7% 更差）、`ALIGNED_ATOMICS=1`（原子 −6% 且非对齐 `LOCK` 变 SIGBUS）、`NOHOTPAGE=1`（未在锁频下复测；它不再捕获自修改代码，对 JIT 不安全）、`BIGBLOCK=3`（锁频下无收益且有 JIT 风险）、`SKIPCPU=2`（收益在噪声内，却少用两个核）。

### 仍未验证

未重建镜像；Dockerfile `8e` 段新增的 rcfile COPY 未在完整构建中执行过。基准与 A/B 都是在当前容器内直接跑的。
## 2026-11-19 星露谷崩溃根因与 box64 的 RPM 化

### 现象

星露谷（413150，box64 链路装好后第一个 x86-64 Linux 游戏）从 Steam 界面启动必定失败：进程树在 11 s / 31 s / 47 s / 72 s / 74 s / 138 s 的随机时刻消失，无窗口，`~/.config/StardewValley` 下没有任何日志，Steam 的 console_log 只有 `Game process added` → `removed`。

两个“看不见”的原因：游戏本身不写日志（除非装 SMAPI），Steam 又会把游戏 stderr 丢掉。

### 根因

用 `strace -e trace=none -e signal=all` 挂在游戏进程上抓到 SIGSEGV，再用 `BOX64_SHOWSEGV=1 BOX64_SHOWBT=1 BOX64_ROLLING_LOG=32`（临时写进 `box64-run`、事后已撤）拿到现场：

```
x64pc=0x30000e73 "box64/vulkan_layer_getinstanceprocaddr + 0x13"
EmulatedBT: libSDL2-2.0.so.0(X11_GL_GetVisual+105)
SIGSEGV for accessing (nil)
```

崩溃前是一整墙 `Calling vulkan_layer_getinstanceprocaddr(...) => return 0x0`。容器的 GL 是 Mesa zink（`MESA_LOADER_DRIVER_OVERRIDE=zink`，Steam 只对游戏设置，且游戏拿到的是 `DISPLAY=:1`），zink 建 GL 上下文时批量查 instance proc 全得 NULL，SDL2 随后把其中一个当函数指针调用 → 调 NULL → 崩。

二分（每次都以真 Steam 启动 + 观察 90~220 s 为准）：单独禁 gamescope WSI（`VK_LAYER_FROG_gamescope_wsi_aarch64`）、MangoHud、`VK_LAYER_MESA_device_select`、Steam 注入的 `VK_INSTANCE_LAYERS`（VALVE_rpo / fdm_injection） —— 全都在同一地址崩；只有 `VK_LOADER_LAYERS_DISABLE=~all~` 不崩。结论：box64 0.4.4 对 native(aarch64) Vulkan **层链**的 `vkGetInstanceProcAddr` 桥接只要有任何层就崩，与具体哪个层无关。

修法（提交 `c45a178`）：`box64-run` 里 `export VK_LOADER_LAYERS_DISABLE="${VK_LOADER_LAYERS_DISABLE:-~all~}"`。代价是 x86-64 游戏里 MangoHud 覆盖层与 gamescope WSI 失效，原生游戏不受影响。

### 顺带量到的启动成本

手动/复现链（`DISPLAY=:0`、无 Vulkan 层）能把游戏跑到窗口：t≈71–75 s 出现 2480×1116 的 `Stardew Valley` 窗口，33–36 线程，RSS 1.17–1.23 GB，GPU busy 28–65%（确实在渲染）。同一个 box64 下 SS2（Godot Mono）到窗口只要 ~3.5 s —— 星露谷的时间全花在 CoreCLR 冷启动 + JIT 上。所以 Steam 的“启动中”要等一分多钟，别中途停止。

### RPM 化：`scripts/armada/box64/rpm/`

已装容器的人不该为升级 box64 去重建镜像，所以把整套东西打成一个 aarch64 包：

```
scripts/armada/box64/rpm/build-rpm.sh      # 组 SOURCES + rpmbuild，产物落到仓库 artifacts/
scripts/armada/box64/rpm/box64-armada.spec
scripts/armada/box64/rpm/README.md         # 装到 /usr/share/doc/box64-armada/ 给最终用户
```

包内容：`/usr/bin/box64`（按 pin 的 commit 现编，strip 后）、`/etc/box64.box64rc`、`/usr/lib/box64-x86_64-linux-gnu/` 的 18 个库、`/usr/libexec/armada/box64-binfmt` 与 `/usr/lib/systemd/system/box64-binfmt.service`、`/usr/share/steam/compatibilitytools.d/box64-armada/` 三件套、doc 与 license。

用户侧只需：`sudo dnf install --nogpgcheck ./box64-armada-0.4.4-1.fc44.aarch64.rpm`，装完重启一次 Steam，在游戏属性里选 **box64 (Armada)**。

两个打包坑：

1. **路径归属**。Fedora 的 `box64` 包拥有 `/usr/bin/box64`（alternatives 符号链接），`box64-data` 拥有 `/etc/box64.box64rc` —— 我们要装的恰好是这两个路径。所以包用 `Obsoletes: box64 / box64-data < 0.4.4` + `Provides:` 同名同版本，让 dnf 直接把 0.3.6 换掉，而不是用 alternatives 去抢。`box64-binfmts`（binfmt.d 条目）保持不动，我们的 unit 负责 mount + 确定性重注册。
2. **x86-64 库不能进依赖生成**。rpm 6.0.2 里 `__provides_exclude_from` 对 ELF 生成器无效；正确的开关是 `__elf_exclude_path`（且要保留 `^/lib/modules/.*` 那条默认值）。不排除的话，这个 aarch64 包会宣告 `Provides: libstdc++.so.6()(64bit)`（可能被拿去满足别的包的依赖，塞进去的却是 x86-64 文件）并凭空 `Requires: libssl.so.3`（那是包内 x86-64 libcurl 的依赖）。已用一个一次性小包验证开关有效（控制组有 `libcurl.so.4()(64bit)`，加排除后为空）。

构建注意：本机 `nproc` 够，但 **CPU 频率会被系统收回**（实测从满档掉到 1.02 GHz），box64 的 LTO 链接在低频下单步就要十几分钟；一次干净构建满频约 6 分钟、1 GHz 下 20 分钟以上。构建脚本支持 `BOX64_SOURCE_TREE=…` 用本地源码树跳过 codeload 下载（本机到 GitHub 只有 ~18 KB/s）。

## 2026-11-20 容器构建上游从 armada 改为 armadaos-freedom

`armada-os/armada` 已改名为 `ArmadaOS-Freedom/armadaos-freedom`，容器构建随之切换。
之后 `~/armadaos-freedom` 就是上游参照，`~/armada` 只作为历史仓库保留。

改动（`ArmadaOS.Dockerfile`）：

| 位置 | 旧 | 新 |
| --- | --- | --- |
| 基础镜像 | `ghcr.io/armada-os/armada:testing` | `ghcr.io/armadaos-freedom/armadaos-freedom:testing` |
| gamescope 补丁源 | `github.com/armada-os/armada.git` @ `d5c23cd` | `github.com/ArmadaOS-Freedom/armadaos-freedom.git` @ `be6fc783` |
| 补丁数量断言（gamescope 步骤） | `= 31` | `= 40` |
| `anland-rebuild-gamescope` | 硬编码旧 URL 与 `d5c23cd` | 统一走 `ARMADA_REPOSITORY` / `ARMADA_COMMIT` 变量 |

关键点：`anland` 的 `producers/gamescope/ArmadaOS_v5/build.sh` 里有一条写死的
`assert len(patches)==31`（对应 armada d5c23cd 的旧序列），而它同时决定生成 RPM spec 的
补丁清单。新上游序列是 40 个（`[0-9][0-9][0-9][0-9]-*.patch` 实测计数），直接换会在这一步
assert 失败。现在的做法是在 anland 克隆后用一段 python 把那个字面量改成“按钉住的
ARMADA_ROOT 实际文件数”，断言本身保留：它能抓住上游悄悄改变序列长度，anland 脚本形状
变化时会明确报错而不是静默通过。gamescope 构建步骤与镜像内
`/usr/local/bin/anland-rebuild-gamescope` 两处都做了同样处理。

验证：重定向片段在本机对真实 anland `build.sh` 跑过（31 → 40，`bash -n` 通过）；
`ArmadaOS.Dockerfile` 里已无 `armada-os/armada` 的功能性引用；新基础镜像 tag 已核实存在
（`ghcr.io/armadaos-freedom/armadaos-freedom:testing` 的 OCI index 可匿名拉取，HTTP 200；
旧 `armada-os/armada:testing` 同样可用，切换不会因镜像不存在而在 `FROM` 就失败）。

仍未验证：**没有重建镜像**。gamescope 仍钉在 `3.17.0-ogc1`（`4246b87f`，anland 侧同样断言
该 revision），armadaos-freedom 的 40 个补丁是否仍基于该 tag 未实测——首次重建若补丁打不上，
会停在 gamescope 步骤，届时需要同步升 `GAMESCOPE_TAG`/`GAMESCOPE_COMMIT` 或挑一组与
`3.17.0-ogc1` 兼容的补丁。`anland` 的 `ArmadaOS_v5` 目录名与预设路径未变，但若上游改了
`build.sh` 的断言写法，重定向片段会显式报错（期望恰好一条 `assert len(patches)==N`）。

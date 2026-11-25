# 容器自检 / 补齐

运行中的 ArmadaOS 容器缺什么补什么：先从 GitHub 同步本仓库脚本（多加速节点，全部失败时
用上次同步的副本，离线可用），再把能在运行中修复的条目逐项检查/修复；镜像内置项只报告，
不擅自动手。

| 文件 | 用途 |
|---|---|
| `armada-container-setup.sh` | 主脚本：`--check-only` / `--no-sync` / `--only <id>` / `--json` / `--list` |
| `armada-container-setup-gui.sh` | 桌面入口的图形前端：先选「只检查 / 检查并修复」，修复前再确认一次 |
| `armada-container-setup.desktop` | 应用菜单与 `~/Desktop` 的入口，`Exec=/usr/local/bin/armada-container-setup-gui` |

镜像里装到 `/usr/local/bin/armada-container-setup{,-gui}`，并把 `.desktop` 同时放进
`/usr/share/applications` 和用户的 `~/Desktop`（见 `ArmadaOS.Dockerfile` 桌面条目那段），
新容器开箱就带这个图标。

## 提权

镜像**默认没有免密 sudo**（要不要免密由使用者自己决定），所以：

- 图形前端在动手前会问一次密码（zenity 密码框；没有 zenity 时退 kdialog），密码写进
  `$XDG_RUNTIME_DIR/armada-sudo.$$/`（目录 700、密码文件 600、askpass 脚本 700），
  交给主脚本当 `SUDO_ASKPASS`，退出时整目录删除，密码不经过命令行。
- 主脚本自己按 `sudo -n` → `sudo -A`（有 askpass 时）→ tty 上的普通 `sudo` 三级降级；
  都拿不到就只报告、不尝试，日志第一行会写明用的是哪种。
- 发过的密码在 sudo 时间戳有效期内会被复用，此时不再弹框。

## 排障

`armada-container-setup-gui --choice=check|fix|offline|sync` 跳过菜单直接进入对应分支
（同时跳过确认框），便于脚本化验证和远程排障。

提权出问题先看 `~/.local/share/armada-container-setup/gui.log`：里面记了密码框用的哪个
后端、返回码、拿到的密码长度，以及 `sudo -A` 的报错原文。

退出码：0 全部满足/已修复；1 有失败（`--only` 没匹配到条目也是 1）；2 有需要人工处理的项；3 已有实例在跑；4 只检查模式发现待修复项。
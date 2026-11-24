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

退出码：0 全部满足/已修复；1 有失败；2 有需要人工处理的项；3 已有实例在跑。
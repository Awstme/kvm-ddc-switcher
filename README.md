# kvm-ddc-switcher

让显示器输入源跟着 KVM 自动切换的小工具。

按下 KVM 把键鼠切到另一台电脑时，显示器往往还停在原来那台。这个工具检测到 KVM 切换后，通过 **DDC/CI** 自动把显示器输入源切到对应的电脑，省去每次手动按显示器 OSD。

> **当前状态**：两端自动切换均已实测可用（KVM 离开哪台主机，哪台就趁自己还亮着把显示器切给对方）；图形界面待开发。

---

## 背景与硬件

作者的实测环境（所有数值都可在配置里改）：

- **显示器**：Mi Monitor（小米），同时接两台电脑
  - Mac → DP1（DDC 输入源值 `15`）
  - Windows → DP2（DDC 输入源值 `16`）
- **KVM**：只切 USB（键鼠），在系统里表现为一个 USB Hub
  - `USB 2.0 Hub [Safe]`，VID `0x1A40` / PID `0x0801`
  - 键盘 `MCHOSE X75 V2`、鼠标 `MCHOSE A7 Pro` 挂在它下面
- **Mac**：MacBook Air（Apple Silicon），macOS 27

KVM 切走时，这个 Hub 连同键鼠会整体从本机 USB 树里消失；切回来时出现——这就是检测信号。

---

## 核心原理（重要）

**DDC/CI 只有“当前被选中的输入源”那台主机能发有效命令。** 一旦显示器切到别的输入，原主机就失去可靠的 DDC 通道：读数会变成垃圾值，写入也常被忽略。

所以正确的逻辑不是“新接管的主机把画面切过来”，而是 **“即将失去 KVM 的主机，趁自己还亮着，把显示器切给对方”**：

- KVM 离开 Mac → Mac 发 DDC 把显示器切到 DP2（Windows）
- KVM 离开 Windows → Windows 发 DDC 把显示器切到 DP1（Mac）

每台主机只负责“切出”，不依赖对方是否已经枚举到显示器。这也是为什么**完整的双向自动切换需要两台机器各跑一个代理**——单端只能覆盖一个方向。

---

## 目录结构

```
kvm-ddc-switcher/
├─ macos/                  macOS 端（已实现）
│  ├─ kvm-watch.sh         检测 KVM + 发 DDC 的常驻脚本
│  ├─ config.env           配置
│  ├─ local.kvm.mac-autoswitch.plist   登录自启（LaunchAgent）
│  └─ m1ddc-src/           vendored DDC 后端（m1ddc，Apple Silicon）
├─ windows/                Windows 端（已实现）
│  ├─ kvm-watch.ps1        检测 KVM + 发 DDC 的常驻脚本（PowerShell 5.1+）
│  └─ config.ps1           配置
└─ gui/                    图形界面（占位，待实现）
```

---

## macOS 用法

### 1. 构建 DDC 后端

需要 Xcode Command Line Tools（`clang`）。仅支持 Apple Silicon。

```sh
cd macos/m1ddc-src
make            # 生成 ./m1ddc
```

### 2. 配置 `macos/config.env`

先查你的 KVM Hub 名字和显示器信息：

```sh
ioreg -p IOUSB -w0 -d 3                    # 找 KVM 的 USB Hub 产品名
./macos/m1ddc-src/m1ddc display list       # 找显示器名字和 UUID
./macos/m1ddc-src/m1ddc display <UUID> get input   # 读当前输入源
```

主要配置项：

| 键 | 说明 | 默认 |
|---|---|---|
| `KVM_HUB_NAME` | KVM USB Hub 的产品名 | `USB 2.0 Hub [Safe]` |
| `MONITOR_NAME` | 显示器名（用于运行时解析 UUID） | `Mi Monitor` |
| `WINDOWS_INPUT` | 对方（Windows）输入的 DDC 值 | `16`（DP2） |
| `MAC_INPUT` | 本机输入值（仅参考） | `15`（DP1） |
| `DRY_RUN` | `1`=只记录不切换，`0`=实际切换 | `0` |
| `POLL_INTERVAL` | 轮询间隔（秒） | `0.5` |
| `STABLE_SAMPLES` | 连续多少次同状态才动作（去抖） | `2` |
| `DISPLAY_SELECTOR` | 指定显示器 UUID（兜底，运行时优先按名字解析） | 见文件 |
| `M1DDC` / `LOG` | 工具与日志路径（`$DIR` 相对） | 见文件 |

### 3. 运行

```sh
# 前台（直接看日志）
./macos/kvm-watch.sh

# 后台
nohup ./macos/kvm-watch.sh >/dev/null 2>&1 &

# 日志
tail -f macos/logs/kvm-auto-switch.log

# 停止
pkill -f kvm-watch.sh
```

切到 Windows 后要回到 Mac 时：Windows 端代理在运行会自动切回；否则用显示器 OSD 切回 DP1。

### 4. 开机自启（可选）

plist 里是绝对路径，移动仓库后需相应修改。

```sh
cp macos/local.kvm.mac-autoswitch.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.kvm.mac-autoswitch.plist

# 卸载
launchctl bootout gui/$(id -u)/local.kvm.mac-autoswitch
rm ~/Library/LaunchAgents/local.kvm.mac-autoswitch.plist
```

---

## Windows 用法

无需编译，Windows PowerShell 5.1 即可，不需要管理员。注意：**DDC 只能在交互桌面会话里发送**——sshd/服务会话（session 0）枚举不到显示器，所以脚本要跑在登录用户的桌面上（下面的计划任务方式天然满足）。

### 1. 配置 `windows/config.ps1`

| 键 | 说明 | 默认 |
|---|---|---|
| `$KVM_HWID_PREFIX` | KVM USB Hub 的硬件 ID 前缀 | `USB\VID_1A40&PID_0801` |
| `$MONITOR_NAME` | 物理监视器描述包含串；留空=所有显示器 | 留空（Windows 常只报 `Generic PnP Monitor`） |
| `$MAC_INPUT` | 对方（Mac）输入的 DDC 值 | `15`（DP1） |
| `$DRY_RUN` | `1`=只记录不切换，`0`=实际切换 | `0` |
| `$POLL_INTERVAL` / `$STABLE_SAMPLES` | 轮询与去抖 | `0.5` / `2` |
| `$LOG` | 日志路径（`$DIR` 相对） | 见文件 |

先跑诊断，确认 Hub 与显示器都能识别：

```powershell
powershell -ExecutionPolicy Bypass -File .\kvm-watch.ps1 -Probe
```

`-Probe` 输出：当前会话、Hub 是否在场、每个物理监视器的描述与当前输入源读数。若提示 `no physical monitors visible`，说明当前不是交互桌面会话；Hub 没匹配到时会列出全部 USB 设备供核对前缀。

### 2. 运行

```powershell
# 前台
powershell -ExecutionPolicy Bypass -File .\kvm-watch.ps1

# 只记录不切换
powershell -ExecutionPolicy Bypass -File .\kvm-watch.ps1 -DryRun

# 后台（隐藏窗口）
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File .\kvm-watch.ps1
```

日志：`windows\logs\kvm-auto-switch.log`（去抖/日志语义与 macOS 端一致）。

### 3. 后台常驻（计划任务）

用 `/IT` 把脚本放进交互会话跑；注销/重启后需重建（登录自启在 Phase 2 标准化）：

```cmd
schtasks /Create /F /TN kvm-watch /TR "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\path\to\kvm-ddc-switcher\kvm-watch.ps1" /SC ONCE /ST 00:00 /IT
schtasks /Run /TN kvm-watch

:: 停止
schtasks /End /TN kvm-watch
```

---

## DDC 输入源对照（VCP `0x60`）

| 输入 | 值 |
|---|---|
| DisplayPort 1 | 15 |
| DisplayPort 2 | 16 |
| HDMI 1 | 17 |
| HDMI 2 | 18 |
| USB-C | 27 |

部分显示器（如某些 LG）用另一套 VCP 码，m1ddc 提供 `input-alt`（`0xF4`）。具体以你的显示器实测为准。

---

## 已知限制

- **只有当前输入源的主机能发有效 DDC**：所以每台主机只负责「切出」，双向自动切换需要两端各跑一个代理——macOS 与 Windows 端均已实现。
- **Windows 的 DDC 必须跑在交互桌面会话**：sshd/服务会话（session 0）枚举不到显示器（`-Probe` 会报 `no physical monitors visible`），常驻请用计划任务（`/IT`）放到登录用户会话里。
- **macOS 外接屏重识别**：在这套硬件上，显示器切走再切回后，macOS 有时不会自动重新识别外接屏，可能需要重插显示线或重启。这是反向自动化之后仍需长期观察的可靠性问题。
- **m1ddc 仅支持 Apple Silicon**，不支持 Intel Mac。
- 显示器需支持并开启 **DDC/CI**。
- 检测依赖“KVM 表现为一个会随切换消失的 USB Hub”。若你的 KVM 行为不同，macOS 端调 `KVM_HUB_NAME`（产品名）、Windows 端调 `$KVM_HWID_PREFIX`（硬件 ID 前缀）。

---

## 路线图

- [x] macOS：USB Hub 检测 KVM + m1ddc 发 DDC 自动切出
- [x] Windows 端代理：PnP 检测 KVM + `dxva2` `SetVCPFeature`（VCP `0x60`）切出；Mac→Win→Mac 双向链路已实测（2026-10-24）
- [ ] 图形界面：Tauri 托盘应用，做配置/状态/手动切换，包装各平台的常驻守护进程
- [ ] 安装打包：macOS LaunchAgent（已有 plist）、Windows 计划任务；公证/签名与安装器
- [ ] 排查 macOS 外接屏切回后的重识别可靠性（一次实测未复现，继续观察）

---

## 许可

`macos/m1ddc-src/` 是 vendored 的 [m1ddc](https://github.com/waydabber/m1ddc)（MIT，© waydabber），用于在 Apple Silicon 上收发 DDC/CI。其余为本项目代码。

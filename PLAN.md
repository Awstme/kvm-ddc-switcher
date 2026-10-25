# 项目规划

目标：基于 KVM（USB Hub 1A40:0801）事件，在 Mac / Windows 两台主机间自动切换显示器输入源（DP1=Mac, DP2=Win），最终交付跨平台托盘 GUI。

## 现状

- `macos/`：已实测（KVM 离开 Mac 1–2 秒后 DDC 切到 DP2）
- `windows/`：`kvm-watch.ps1` 已实测（KVM 离开 Windows 后 DDC 切回 DP1）；2026-10-24 Mac→Win→Mac 双向全链路验证通过
- `gui/`：Tauri 托盘 GUI 骨架已可运行（Phase 3 进行中）
- 硬件约束：只有当前输入源的主机能发有效 DDC，因此「切出」由即将失去 KVM 的那台负责，双向切换需要两端各跑一个代理

## Phase 1 — Windows 端代理（✅ 已完成）

- ✅ dxva2 发 DDC（VCP 0x60，设 DP1/15）+ PnP（SetupAPI）监听 KVM Hub（1A40:0801）在否
- ✅ 验证了「仅当前输入源可发 DDC」在 Windows 侧同样成立：显示器不在 Windows 输入时读 VCP 0x60 为 n/a，切出瞬间写入生效
- ✅ 产出 `windows/kvm-watch.ps1` + `windows/config.ps1`（含 `-Probe` / `-DryRun`，去抖/日志与 macOS 端同构）
- 实测注意点：DDC 只能在交互桌面会话发（ssh/服务会话 session 0 枚举不到显示器）；Windows 只报 "Generic PnP Monitor"，`$MONITOR_NAME` 默认留空

## Phase 2 — 双向联动与稳定化

- ✅ Mac→Win→Mac 全链路实测（2026-10-24），无丢屏/错序，切换延迟约 1–2 秒
- ✅ 自启标准化（2026-10-25）：macOS LaunchAgent（TCC 规避部署 + KeepAlive）、Windows 登录触发计划任务（允许电池、失败重启、不限时长）；日志 1MB 启动时轮转
- 待办：脚本级失败重试、两端统一配置格式、缓解 macOS 外接屏重识别问题

## Phase 3 — GUI 壳（Tauri 托盘应用，进行中）

- ✅ 骨架与后端（2026-10-25）：Tauri 2 + 原生 HTML/JS（零前端构建），托盘常驻（打开窗口/手动切换/退出），关窗即隐藏
- ✅ 已实现：守护进程状态与预计输入源（由日志推断）、日志查看（自动刷新）、`config.env` 编辑（保存后重启守护进程）、自启开关（装/卸 LaunchAgent）、手动切到 Windows
- ✅ 守护进程新增命令文件通道 `switch-to-windows`（KVM 不在本机时忽略），实测通道正常且不误切屏；GUI 不直接碰 DDC
- 待做：手动切换与保存配置的实机点验、托盘/窗口细节打磨；Windows 版需在 Windows 上构建（依赖 MSVC 工具链）

## Phase 4 — 分发（远期）

- macOS 公证 + Windows 签名；安装器打包
- 首次运行配置向导（探测显示器与 USB Hub）

## 优先级判断

Phase 1（已完成）解决了双向里缺失的那一半；Phase 2 的稳定性与自启是 GUI 之前必须过的坎；Phase 4 可暂缓。

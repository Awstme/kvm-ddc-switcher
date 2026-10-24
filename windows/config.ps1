# kvm-watch.ps1 配置（被脚本 dot-source 加载；删掉本文件即用脚本内默认值）

# KVM USB Hub 的硬件 ID 前缀，形如 USB\VID_xxxx&PID_xxxx&REV_yyyy。
# Windows 上查法：设备管理器 → 该 Hub → 属性 → 详细信息 → 硬件 ID；
# 或直接跑 kvm-watch.ps1 -Probe，若没匹配到会列出所有 USB 设备供辨认。
$KVM_HWID_PREFIX = "USB\VID_1A40&PID_0801"

# 显示器匹配串：dxva2 物理监视器描述里包含它即可；留空 = 匹配所有物理显示器
# （这台 Windows 实测只报 "Generic PnP Monitor"，按名字匹配行不通，故默认留空）
$MONITOR_NAME = ""

# 轮询间隔（秒）；连续 STABLE_SAMPLES 次读到同一状态才动作（去抖）
$POLL_INTERVAL = 0.5
$STABLE_SAMPLES = 2

# 1 = 只记录，不发 DDC；0 = 真正切换（命令行 -DryRun 可临时覆盖）
$DRY_RUN = 0

# 对方（Mac）的输入源 DDC 值（VCP 0x60）：DP1=15, DP2=16, HDMI1=17, HDMI2=18, USB-C=27
$MAC_INPUT = 15

# 日志路径（$DIR = 脚本所在目录）
$LOG = Join-Path $DIR "logs\kvm-auto-switch.log"
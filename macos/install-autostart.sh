#!/bin/zsh
# 安装/卸载 macOS 开机自启（LaunchAgent）
#
# launchd 拉起的进程受 macOS TCC 限制，读不了 ~/Documents 下的文件，
# 所以这里把脚本/配置/m1ddc 复制到 ~/Library/Application Support 再装载服务。
# 修改仓库里的脚本或 config.env 后，需要重新运行本脚本部署。
#
# 用法：
#   ./macos/install-autostart.sh              # 安装并启动（会重启已在跑的实例）
#   ./macos/install-autostart.sh --uninstall  # 停止并卸载（保留 Application Support 里的日志）

set -eu

SRC="${0:A:h}"
LABEL="local.kvm.mac-autoswitch"
DST="$HOME/Library/Application Support/kvm-ddc-switcher"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
  rm -f "$PLIST_DST"
  echo "uninstalled: $LABEL (logs kept in $DST/logs)"
  exit 0
fi

if [[ ! -x "$SRC/m1ddc-src/m1ddc" ]]; then
  echo "m1ddc not built; run: make -C $SRC/m1ddc-src" >&2
  exit 1
fi

mkdir -p "$DST/m1ddc-src" "$DST/logs"
cp -f "$SRC/kvm-watch.sh" "$DST/kvm-watch.sh"
cp -f "$SRC/config.env" "$DST/config.env"
cp -f "$SRC/m1ddc-src/m1ddc" "$DST/m1ddc-src/m1ddc"
chmod +x "$DST/kvm-watch.sh" "$DST/m1ddc-src/m1ddc"

cp -f "$SRC/local.kvm.mac-autoswitch.plist" "$PLIST_DST"

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST_DST"
echo "installed & started: $LABEL"
echo "  deploy dir: $DST"
echo "  log:        $DST/logs/kvm-auto-switch.log"

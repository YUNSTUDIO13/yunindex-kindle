#!/bin/sh

# 主路径与 v12.0（实证可安装版）逐字节一致：硬编码 USB 根绝对路径。
# 原因：早前版本用 $(dirname "$0") 自定位，但 ;log runme 的 launcher 调用方式下
#       $0 不一定等于脚本真实绝对路径（可能被 pipe 给 shell），导致 PKG 解析到错误目录
#       → 全部 payload 检查失败 → 静默退出「完全没反应」。故改回硬编码为主。
# 仅当该目录确实不存在时，才 fallback 到 $0 自定位（非标准摆盘兜底）。
PKG="/mnt/us/native-reading-time-package"
[ -d "$PKG" ] || PKG=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
BASE="/mnt/us/reading-time"
INSTALL_LOG="$BASE/install.log"
JOB="native-reading-time"
CONF="/etc/upstart/${JOB}.conf"
DAEMON="$BASE/bin/native-reading-time-daemon.sh"
VIEWER="/mnt/us/documents/Yunindex阅读统计.sh"
# v13.1 R28：恢复右上角「退出按钮」——touch.lua 热区 (1130,35)-(1222,127) → exit。
# 配合 timeout 60 秒空闲自动退出（不再无限常驻，避免下拉状态栏永久卡死）。
TOUCH_READER="$BASE/bin/reading-insights-touch.lua"
FONT_DIR="$BASE/fonts"
UI_DIR="$BASE/ui"

toast() { lipc-set-prop com.lab126.system toasterMessage "$1" >/dev/null 2>&1 || true; }
# v13.0：任何失败/结束时都把 install.log 复制到 USB 根目录
export_install_log() { [ -f "$INSTALL_LOG" ] && cp "$INSTALL_LOG" "/mnt/us/LOG-install.log" 2>/dev/null; sync; }
fail() { echo "$(date): ERROR: $1" | tee -a "$INSTALL_LOG"; export_install_log; toast "Installation failed: $1"; exit 1; }

mkdir -p "$BASE"
echo "$(date): installer v2.0 (single-page / no-touch / SerifSC-only) entered, uid=$(id -u), PKG=$PKG, args=$*" >> "$INSTALL_LOG"

# ;log runme 必须以 root 调用
[ "$(id -u)" -eq 0 ] || fail "not running as root; use ;log runme"
echo "$(date): root invocation confirmed" >> "$INSTALL_LOG"

# 修复旧版残留的输入屏蔽 / 常亮
lipc-set-prop com.lab126.winmgr eatTapMode 0 >/dev/null 2>&1 || true
lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1 || true

[ -x /sbin/initctl ] || fail "Upstart not found (/sbin/initctl missing)"
[ -f /lib/ld-linux-armhf.so.3 ] || fail "not a kindlehf device"
[ -f "$PKG/native-reading-time-daemon.sh" ] || fail "missing daemon payload"
[ -f "$PKG/native-reading-time.conf" ] || fail "missing Upstart payload"
[ -f "$PKG/Yunindex阅读统计.sh" ] || fail "missing dashboard launcher"
[ -f "$PKG/reading-insights-touch.lua" ] || fail "missing touch reader (exit button)"
# v13.1 R19：v13.0 改用 Noto Serif SC 后，NotoSansCJKsc 已无人引用，故包内不再带（瘦身 ~33MB）
[ -f "$PKG/NotoSerifSC-Regular.otf" ] || fail "missing Noto Serif SC Regular"
[ -f "$PKG/NotoSerifSC-Bold.otf" ] || fail "missing Noto Serif SC Bold"
[ -f "$PKG/FONT-LICENSE.txt" ] || fail "missing bundled font license"
[ -f "$PKG/ui/dashboard_bg.png" ] || fail "missing single-page dashboard background PNG (expect at ui/)"
[ -f "$PKG/ui/compose.py" ] || fail "missing compose.py (expect at ui/)"
[ -f "$PKG/ui/quotes.tsv" ] || fail "missing quotes.tsv (expect at ui/)"

# 检测 KPM 系统级 FBInk：兼容多路径（KPM / Véra / 旧版 KUAL）
FBINK_CAND="/var/local/kmc/bin/fbink"
[ -x "$FBINK_CAND" ] || FBINK_CAND="/usr/bin/fbink"
[ -x "$FBINK_CAND" ] || FBINK_CAND="/mnt/us/kpm/bin/fbink"
[ -x "$FBINK_CAND" ] || fail "FBInk not found at expected locations (KPM not installed?)"
echo "$(date): fbink resolved to $FBINK_CAND" >> "$INSTALL_LOG"

# 备份既有阅读数据
[ -f "$BASE/reading-time.tsv" ] && cp "$BASE/reading-time.tsv" "$BASE/reading-time.tsv.bak-$(date +%s)" 2>/dev/null

mkdir -p "$BASE/bin" || fail "cannot create data directory"
cp "$PKG/native-reading-time-daemon.sh" "$DAEMON.new" || fail "cannot stage daemon"
chmod 755 "$DAEMON.new" || fail "cannot chmod daemon"
mv "$DAEMON.new" "$DAEMON" || fail "cannot install daemon"
rm -f "$BASE/bin/reading-insights-server.sh"
killall reading-insights-server.sh >/dev/null 2>&1 || true
cp "$PKG/Yunindex阅读统计.sh" "$VIEWER" || fail "cannot install dashboard launcher"
chmod 755 "$VIEWER" || fail "cannot chmod dashboard launcher"
rm -f "/mnt/us/documents/书籍进度探测.sh"
rm -f "/mnt/us/documents/阅读页数探测.sh"
rm -f "$BASE/bin/page-turn-probe-worker.sh" "$BASE/bin/page-turn-probe.lua" "$BASE/page-turn-probe.pid"
rm -f "/mnt/us/documents/阅读洞察.sh"
cp "$PKG/reading-insights-touch.lua" "$TOUCH_READER" || fail "cannot install touch reader"
chmod 644 "$TOUCH_READER" || fail "cannot chmod touch reader"
mkdir -p "$FONT_DIR" || fail "cannot create font directory"
# v13.1 R19：仅安装 Noto Serif SC（v13.0 改用衬线体后，NotoSansCJKsc 已无人引用，包内不再带）
cp "$PKG/NotoSerifSC-Regular.otf" "$FONT_DIR/NotoSerifSC-Regular.otf" || fail "cannot install Noto Serif SC Regular"
cp "$PKG/NotoSerifSC-Bold.otf" "$FONT_DIR/NotoSerifSC-Bold.otf" || fail "cannot install Noto Serif SC Bold"
rm -f "$FONT_DIR/DroidSansFallback.ttf"
cp "$PKG/FONT-LICENSE.txt" "$FONT_DIR/FONT-LICENSE.txt" || fail "cannot install font license"
chmod 644 "$FONT_DIR"/* || fail "cannot chmod font files"

# v13.0：安装单页 dashboard 资源（背景 PNG + compose.py + 金句 tsv）
mkdir -p "$UI_DIR" || fail "cannot create UI directory"
cp "$PKG/ui/dashboard_bg.png" "$UI_DIR/dashboard_bg.png" || fail "cannot install dashboard_bg.png"
cp "$PKG/ui/compose.py" "$UI_DIR/compose.py" || fail "cannot install compose.py"
cp "$PKG/ui/quotes.tsv" "$UI_DIR/quotes.tsv" || fail "cannot install quotes.tsv"
chmod 644 "$UI_DIR"/*.png "$UI_DIR/compose.py" "$UI_DIR/quotes.tsv" || fail "cannot chmod UI assets"

# v13.0：探测设备是否具备 python3 + Pillow（快通道）。缺失仅降级为纯 fbink 慢路径，不致命但给出提示。
PIL_OK=0
for _c in python3 python; do
    _p=$(command -v "$_c" 2>/dev/null)
    [ -n "$_p" ] && "$_p" -c "import PIL" >/dev/null 2>&1 && { PIL_OK=1; break; }
done
if [ "$PIL_OK" -eq 1 ]; then
    echo "$(date): PIL available -> fast path enabled" >> "$INSTALL_LOG"
else
    echo "$(date): WARNING PIL not found -> will use slow fbink path" >> "$INSTALL_LOG"
    toast "Installed: 未检测到 Pillow，已切换慢速渲染"
fi

# 修复：data 文件自建（保证 dashboard 即便 daemon 没起来也能开）
[ -f "$BASE/reading-time.tsv" ] || printf 'date\tbook_id\tseconds\ttitle\tstatus\tprogress\n' > "$BASE/reading-time.tsv" || fail "cannot seed reading-time.tsv"

# 关键修复：把 FBInk 真实路径通过 sed 注入到 dashboard launcher（默认写的是 /var/local/kmc/bin/fbink）
if [ "$FBINK_CAND" != "/var/local/kmc/bin/fbink" ]; then
    sed -i "s|^FBINK=\"/var/local/kmc/bin/fbink\"|FBINK=\"$FBINK_CAND\"|" "$VIEWER" 2>/dev/null || true
    echo "$(date): patched dashboard FBINK path -> $FBINK_CAND" >> "$INSTALL_LOG"
fi

lipc-set-prop com.lab126.scanner doFullScan 1 >/dev/null 2>&1 || lipc-set-prop com.lab126.scanner triggerUpdate 1 >/dev/null 2>&1 || true

/sbin/initctl stop "$JOB" >/dev/null 2>&1 || true

ROOT_RW=0
root_ro() {
    if [ "$ROOT_RW" -eq 1 ]; then
        mntroot ro >/dev/null 2>&1 || /usr/sbin/mntroot ro >/dev/null 2>&1 || /sbin/mntroot ro >/dev/null 2>&1 || true
        ROOT_RW=0
    fi
}
trap root_ro EXIT INT TERM HUP

if mntroot rw >/dev/null 2>&1 || /usr/sbin/mntroot rw >/dev/null 2>&1 || /sbin/mntroot rw >/dev/null 2>&1; then
    ROOT_RW=1
else
    fail "cannot remount rootfs"
fi

cp "$PKG/native-reading-time.conf" "$CONF.new" || fail "cannot stage Upstart job"
chmod 644 "$CONF.new" || fail "cannot chmod Upstart job"
mv "$CONF.new" "$CONF" || fail "cannot install Upstart job"
/sbin/initctl reload-configuration >/dev/null 2>&1 || true
root_ro
trap - EXIT INT TERM HUP

/sbin/initctl start "$JOB" >/dev/null 2>&1 || true
sleep 2
if /sbin/initctl status "$JOB" 2>/dev/null | grep -q 'start/running'; then
    echo "$(date): installed and running" | tee -a "$INSTALL_LOG"
    toast "Yunindex阅读统计 v2.0 installed"
    export_install_log
    exit 0
fi

# daemon 没起来不致命：dashboard 仍能打开看历史/手动开
echo "$(date): installation completed, but service did not start" | tee -a "$INSTALL_LOG"
echo "See /mnt/us/reading-time/upstart.log" | tee -a "$INSTALL_LOG"
toast "Tracker installed but did not start; check install.log"
export_install_log
exit 1
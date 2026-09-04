#!/bin/sh
#
# Kindle 原生阅读时长统计 · 卸载脚本 v2.1
# ============================================================
# 触发方式（在 Kindle 搜索栏输入，不带引号）：
#       ;log uninstall
# 该命令会以 root 身份执行 /mnt/us/UNINSTALL.sh
#
# 高级用法（已通过 SSH/USBNet 登录后）：
#   DRY_RUN=1 sh /mnt/us/UNINSTALL.sh     # 仅打印将要执行的操作，不改动任何文件
#
# 说明：
#   - 会自动停止 Upstart 守护进程并删除其配置
#   - 会删除：守护脚本、字体、背景图、touch lua、文档启动器、安装包目录、旧版残留
#   - 会【保留】你的阅读数据（reading-time.tsv / state / 阅读时长统计.txt 原位不删，重装自动续用）
#   - 会复位 eatTapMode / preventScreenSaver 为安全默认值（0）
#   - 删除前若 rootfs 为只读会自动 remount rw，失败则跳过 Upstart 清理并提示
# ============================================================

# ---- 路径定义（与安装脚本对应）----
JOB="native-reading-time"
CONF="/etc/upstart/${JOB}.conf"
BASE="/mnt/us/reading-time"
PKG="/mnt/us/native-reading-time-package"
VIEWER="/mnt/us/documents/Yunindex阅读统计.sh"
UNINSTALL_LOG="/mnt/us/UNINSTALL.log"

# ---- 干跑模式：DRY_RUN=1 时只打印不执行 ----
DRY_RUN="${DRY_RUN:-0}"
run() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

toast() { lipc-set-prop com.lab126.system toasterMessage "$1" >/dev/null 2>&1 || true; }
log() { echo "$(date): $1" >> "$UNINSTALL_LOG" 2>/dev/null || echo "$(date): $1"; }

ROOT_RW=0
root_ro() {
    if [ "$ROOT_RW" -eq 1 ]; then
        run mntroot ro >/dev/null 2>&1 || run /usr/sbin/mntroot ro >/dev/null 2>&1 || run /sbin/mntroot ro >/dev/null 2>&1 || true
        ROOT_RW=0
    fi
}
root_remount_rw() {
    if run mntroot rw >/dev/null 2>&1 || run /usr/sbin/mntroot rw >/dev/null 2>&1 || run /sbin/mntroot rw >/dev/null 2>&1; then
        ROOT_RW=1
        return 0
    fi
    return 1
}

: > "$UNINSTALL_LOG" 2>/dev/null || true
log "uninstall started, uid=$(id -u), DRY_RUN=$DRY_RUN"

# 必须以 root 调用（;log uninstall 自带 root）
if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: not running as root; use ;log uninstall"
    toast "Uninstall failed: run via ;log uninstall"
    exit 1
fi

# ---- 1. 停止守护进程（Upstart 会 respawn，先停 job 再杀残留）----
log "stopping upstart job: $JOB"
run /sbin/initctl stop "$JOB" >/dev/null 2>&1 || true
run sleep 1
run pkill -f "native-reading-time-daemon.sh" >/dev/null 2>&1 || true
run pkill -f "Yunindex阅读统计.sh" >/dev/null 2>&1 || true
run pkill -f "reading-insights-touch.lua" >/dev/null 2>&1 || true
log "daemon stop signals sent"

# ---- 2. 保留用户阅读数据（原位不动，重装自动续用）----
# 数据文件 reading-time.tsv / reading-time.tsv.bak-* / state / 阅读时长统计.txt / .quote_idx 全部保留，
# 只删程序文件（bin/fonts/ui）与日志（见下方第 4 步）。
log "keeping user data in place (reading-time.tsv, state, 阅读时长统计.txt)"

# ---- 3. 删除 Upstart 配置（需要 rootfs 可写）----
if [ -f "$CONF" ]; then
    if root_remount_rw; then
        run rm -f "$CONF"
        run /sbin/initctl reload-configuration >/dev/null 2>&1 || true
        root_ro
        log "removed upstart conf: $CONF"
    else
        log "WARN: cannot remount rootfs rw; upstart conf left at $CONF"
        toast "Could not remove Upstart job (rootfs ro)"
    fi
else
    log "upstart conf not present, skip"
fi

# ---- 4. 删除已安装的程序文件（数据文件保留）----
log "removing installed files (keeping user data)"
run rm -f  "$VIEWER"
run rm -rf "$BASE/bin"
run rm -rf "$BASE/fonts"
run rm -rf "$BASE/ui"
run rm -f  "$BASE/service.log" "$BASE/install.log" "$BASE/upstart.log" \
           "$BASE/dashboard-launch.log" "$BASE/dashboard-touch.log" "$BASE/fbink.log"
run rm -rf "$PKG"
run rm -f  "/mnt/us/LOG-install.log"

# 旧版残留清理（保险）
run rm -f "/mnt/us/documents/书籍进度探测.sh"
run rm -f "/mnt/us/documents/阅读页数探测.sh"
run rm -f "/mnt/us/documents/阅读洞察.sh"
run rm -f "$BASE/bin/page-turn-probe-worker.sh" "$BASE/bin/page-turn-probe.lua" "$BASE/page-turn-probe.pid" 2>/dev/null || true
run rm -f "$BASE/bin/reading-insights-server.sh" 2>/dev/null || true

# ---- 5. 复位 lipc 属性到安全默认 ----
run lipc-set-prop com.lab126.winmgr eatTapMode 0 >/dev/null 2>&1 || true
run lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1 || true
log "reset lipc props to safe defaults"

# ---- 6. 收尾：同步、删掉本脚本自身（保持设备干净）----
run sync
log "uninstall completed"
toast "Reading time tracker uninstalled"

# 最后删除 UNINSTALL.sh 自身（脚本已在内存中执行，删除无碍）
run rm -f /mnt/us/UNINSTALL.sh

exit 0

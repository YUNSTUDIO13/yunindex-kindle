#!/bin/sh

# Executed as root by typing ;log runme in the Kindle search bar.
#
# 主路径与 v12.0（实证可安装版）逐字节一致：硬编码 USB 根绝对路径。
# 说明：早前版本曾用 $(dirname "$0") 自定位，但 ;log runme 的 launcher 调用方式下
#       $0 不一定等于 /mnt/us/runme.sh（可能被 pipe 给 shell 或以其他方式唤起），
#       导致 SCRIPT_DIR 解析到错误目录 → 找不到 installer → 静默退出「完全没反应」。
#       故改回硬编码为主、自定位仅作兜底。
#
# v2.2 · 智能入口（同时承载安装与卸载）：
#   Vera 越狱的 ;log 只接受 mrpi/runme，不支持 ;log uninstall。
#   因此 RUNME.sh 改造为「标记文件分发」：
#     · 正常安装  → 直接调 Install-Native-Reading-Time.sh
#     · 想卸载   → 在 USB 根（/mnt/us/）放一个名为 uninstall.flag 的空文件，
#                  再 ;log runme，RUNME.sh 检测到标记自动 exec /mnt/us/UNINSTALL.sh
#   UNINSTALL.sh 必须在 /mnt/us/（由 Install 末尾同步并 chmod +x），否则报 toaster 失败。

INSTALLER="/mnt/us/native-reading-time-package/Install-Native-Reading-Time.sh"
LOG="/mnt/us/reading-time/install.log"

# === 卸载模式：根目录存在 uninstall.flag*（任意扩展名）则走卸载 ===
# 兼容 macOS 上文本编辑器创建标记文件时自动加 .rtf/.txt 扩展名的场景，
# 用通配匹配 uninstall.flag.rtf、uninstall.flag.txt、uninstall.flag 等任何变体。
UNINSTALL_FLAG=""
for f in /mnt/us/uninstall.flag*; do
    if [ -e "$f" ]; then
        UNINSTALL_FLAG="$f"
        break
    fi
done

if [ -n "$UNINSTALL_FLAG" ]; then
    echo "$(date): RUNME entry (uninstall mode), uid=$(id -u), flag=$UNINSTALL_FLAG, self=$0" >> "$LOG"
    UNINSTALL="/mnt/us/UNINSTALL.sh"
    if [ ! -f "$UNINSTALL" ]; then
        echo "$(date): ERROR UNINSTALL.sh missing at $UNINSTALL" >> "$LOG"
        lipc-set-prop com.lab126.system toasterMessage "UNINSTALL.sh not found; please reinstall first" >/dev/null 2>&1 || true
        rm -f /mnt/us/uninstall.flag*
        exit 1
    fi
    chmod +x "$UNINSTALL" 2>/dev/null || true
    # 先清掉所有标记（含 .rtf/.txt 等变体），再 exec UNINSTALL
    rm -f /mnt/us/uninstall.flag*
    exec /bin/sh "$UNINSTALL"
fi

mkdir -p /mnt/us/reading-time
echo "$(date): RUNME entry (install mode), uid=$(id -u), self=$0" >> "$LOG"

# 主路径缺失时才尝试自定位（非标准摆盘兜底）
if [ ! -f "$INSTALLER" ]; then
    echo "$(date): primary path missing, trying self-locate" >> "$LOG"
    SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/native-reading-time-package/Install-Native-Reading-Time.sh" ]; then
        INSTALLER="$SCRIPT_DIR/native-reading-time-package/Install-Native-Reading-Time.sh"
    else
        for d in "$SCRIPT_DIR"/*/; do
            if [ -f "${d}native-reading-time-package/Install-Native-Reading-Time.sh" ]; then
                INSTALLER="${d}native-reading-time-package/Install-Native-Reading-Time.sh"
                break
            fi
        done
    fi
fi

if [ ! -f "$INSTALLER" ]; then
    echo "$(date): ERROR: installer not found (primary=/mnt/us/native-reading-time-package, self=$0)" >> "$LOG"
    lipc-set-prop com.lab126.system toasterMessage "Installer payload not found" >/dev/null 2>&1 || true
    exit 1
fi

echo "$(date): installer resolved -> $INSTALLER" >> "$LOG"

exec /bin/sh "$INSTALLER"

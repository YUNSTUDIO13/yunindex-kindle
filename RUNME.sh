#!/bin/sh

# Executed as root by typing ;log runme in the Kindle search bar.
#
# 主路径与 v12.0（实证可安装版）逐字节一致：硬编码 USB 根绝对路径。
# 说明：早前版本曾用 $(dirname "$0") 自定位，但 ;log runme 的 launcher 调用方式下
#       $0 不一定等于 /mnt/us/runme.sh（可能被 pipe 给 shell 或以其他方式唤起），
#       导致 SCRIPT_DIR 解析到错误目录 → 找不到 installer → 静默退出「完全没反应」。
#       故改回硬编码为主、自定位仅作兜底。

INSTALLER="/mnt/us/native-reading-time-package/Install-Native-Reading-Time.sh"
LOG="/mnt/us/reading-time/install.log"

mkdir -p /mnt/us/reading-time
echo "$(date): RUNME entry, uid=$(id -u), self=$0" >> "$LOG"

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

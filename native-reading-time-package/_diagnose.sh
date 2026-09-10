#!/bin/sh
# Yunindex 阅读统计 v2.3.9 诊断脚本
# 用途：检查 kindle 上 render_ranking 数据链路是否正常（封面/作者/日期/进度/日均 字段来源）
# 跑法 A（推荐，无需 SSH）：
#   1. 把本文件拷到 Kindle USB 根 /mnt/us/_diagnose.sh
#   2. 在 USB 根放一个名为 diagnose.flag 的空文件
#   3. Kindle 搜索栏输入 ;log runme  回车
#   4. 等约 10 秒，USB 连接电脑，取回 /mnt/us/LOG-diagnose.log
# 跑法 B（有终端/SSH）：sh /mnt/us/_diagnose.sh
# 输出：自动写到 /mnt/us/LOG-diagnose.log（USB 根，方便拷回）

BASE="/mnt/us/reading-time"
OUT="/mnt/us/LOG-diagnose.log"
LAUNCHER="/mnt/us/documents/Yunindex阅读统计.sh"

{
echo "=========================================="
echo "Yunindex v2.3.9 诊断报告"
echo "时间: $(date)"
echo "=========================================="

echo ""
echo "【1. 必备工具探测】"
echo "  python3     : $(command -v python3 2>/dev/null || echo NOT_FOUND)"
echo "  python2     : $(command -v python2 2>/dev/null || echo NOT_FOUND)"
echo "  python      : $(command -v python 2>/dev/null || echo NOT_FOUND)"
echo "  awk (路径)  : $(command -v awk 2>/dev/null || echo NOT_FOUND)"
echo "  fbink       : $(command -v fbink 2>/dev/null || echo NOT_FOUND)"
echo "  lipc-set-prop: $(command -v lipc-set-prop 2>/dev/null || echo NOT_FOUND)"

echo ""
echo "【2. awk 版本探测（检查是否支持 asorti）】"
AWK_BIN="$(command -v awk 2>/dev/null)"
if [ -n "$AWK_BIN" ]; then
    ls -la "$AWK_BIN"
    echo "  awk --version:"
    "$AWK_BIN" --version 2>&1 | head -3 || echo "  (no --version support)"
    echo "  测试 asorti:"
    echo "" | "$AWK_BIN" 'BEGIN{n=asorti(arr, idx, "@ind_num_desc"); print "asorti OK"}' 2>&1 | head -3
fi

echo ""
echo "【3. python3 sqlite3 测试】"
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import sqlite3, os; print('  sqlite3 OK')" 2>&1
    python3 -c "import sys, os; print('  python:', sys.version.split()[0]); print('  cc.db exists:', os.path.exists('/var/local/cc.db'))" 2>&1
fi

echo ""
echo "【4. 数据文件状态】"
echo "  reading-time.tsv 行数: $(wc -l < "$BASE/reading-time.tsv" 2>/dev/null || echo NOT_FOUND)"
echo "  book-meta.tsv 行数:    $(wc -l < "$BASE/book-meta.tsv" 2>/dev/null || echo NOT_FOUND)"
echo "  /var/local/cc.db 大小: $(ls -la /var/local/cc.db 2>/dev/null | awk '{print $5}')"
echo "  前 5 行 tsv:"
head -5 "$BASE/reading-time.tsv" 2>/dev/null | awk '{printf "    | %s\n", $0}'

echo ""
echo "【5. fbink 探测】"
if [ -x /var/local/kmc/bin/fbink ]; then
    /var/local/kmc/bin/fbink -h 2>&1 | head -3
fi

echo ""
echo "【6. launcher 版本号（安装位置 /mnt/us/documents/）】"
if [ -f "$LAUNCHER" ]; then
    grep -E "^# Yunindex阅读统计 v|VERSION=|v2\.3\.[0-9]" "$LAUNCHER" 2>/dev/null | head -3
    echo "  launcher 修改时间: $(ls -la "$LAUNCHER" | awk '{print $6,$7,$8}')"
else
    echo "  ✗ launcher 不存在: $LAUNCHER"
fi
grep "model=" "$BASE/bin/native-reading-time-daemon.sh" 2>/dev/null | head -1

echo ""
echo "【7. daemon 进程状态】"
ps -ef | grep -E "native-reading-time-daemon|reading-time" | grep -v grep | head -3

echo ""
echo "【8. 最近 launcher 日志（最后 30 行）】"
tail -30 "$BASE/dashboard-launch.log" 2>/dev/null || echo "  (log 不存在)"

echo ""
echo "【9. fbink.log 错误（最后 30 行）】"
tail -30 "$BASE/fbink.log" 2>/dev/null || echo "  (log 不存在)"

echo ""
echo "【10. 封面缩略图检查（定位「封面拿不到」）】"
echo "  sqlite3: $(command -v sqlite3 2>/dev/null || echo NOT_FOUND)"
echo "  cc.db 可读: $([ -r /var/local/cc.db ] && echo YES || echo NO)"
if command -v sqlite3 >/dev/null 2>&1 && [ -r /var/local/cc.db ]; then
    echo "  cc.db Entries 有 cdeKey 的书（前 5 本）:"
    sqlite3 -readonly -noheader "/var/local/cc.db" \
        "SELECT cdeKey, substr(coalesce(p_titles_0_nominal,''),1,20) FROM Entries WHERE cdeKey IS NOT NULL LIMIT 5" 2>/dev/null | awk '{printf "    | %s\n", $0}'
fi
echo "  缩略图目录 /mnt/us/system/thumbnails/ 是否存在: $([ -d /mnt/us/system/thumbnails ] && echo YES || echo NO)"
if [ -d /mnt/us/system/thumbnails ]; then
    echo "  缩略图文件总数: $(ls /mnt/us/system/thumbnails/ 2>/dev/null | wc -l | tr -d ' ')"
    echo "  前 10 个缩略图文件名:"
    ls /mnt/us/system/thumbnails/ 2>/dev/null | head -10 | awk '{printf "    | %s\n", $0}'
fi
echo "  reading-time.tsv 里的 book_id（前 5 个，用于比对缩略图命名）:"
awk -F'\t' 'NR>1 && NF>=2 {print $2}' "$BASE/reading-time.tsv" 2>/dev/null | sort -u | head -5 | awk '{printf "    | %s\n", $0}'

echo ""
echo "【11. 排行页运行时日志 rank-debug.log（v2.3.10 新增 · 最有用的一节）】"
echo "  说明：只要打开过一次「排行」页，该文件就会自动生成，含 cc.db 查询结果与 RANK_LINES 原始输出。"
if [ -f "$BASE/rank-debug.log" ]; then
    echo "  文件大小: $(ls -la "$BASE/rank-debug.log" | awk '{print $5}') 字节"
    echo "  内容："
    sed 's/^/    | /' "$BASE/rank-debug.log" 2>/dev/null
else
    echo "  ✗ 尚未生成 —— 请先打开一次「排行」页，再跑本诊断"
fi

echo ""
echo "【12. reading-time.tsv 原始前 8 行（看 progress 第 6 列是否有值）】"
sed 's/^/    | /' "$BASE/reading-time.tsv" 2>/dev/null | head -8

echo ""
echo "【13. 退出回图书馆链路（v2.4.4 定位用）】"
echo "  sqlite3 可用: $(command -v sqlite3 2>/dev/null || echo NONE)"
echo "  appreg.db 可读: $([ -r /var/local/appreg.db ] && echo YES || echo NO)"
echo "  launcher 版本标记:"
grep -o "v2\.4\.[0-9]" "$LAUNCHER" 2>/dev/null | sort -u | awk '{printf "    | %s\n", $0}'
grep -c "booklet%library" "$LAUNCHER" 2>/dev/null | awk '{printf "    | 动态探测代码存在: %s 处\n", $1}'
if command -v sqlite3 >/dev/null 2>&1 && [ -r /var/local/appreg.db ]; then
    echo "  appreg.db 全部 booklet handlerId:"
    sqlite3 -readonly -noheader /var/local/appreg.db \
        "SELECT handlerId FROM handlerIds WHERE handlerId LIKE '%booklet%' ORDER BY handlerId" 2>&1 | awk '{printf "    | %s\n", $0}'
    echo "  LIKE %booklet%library% 命中:"
    sqlite3 -readonly -noheader /var/local/appreg.db \
        "SELECT handlerId FROM handlerIds WHERE handlerId LIKE '%booklet%library%' ORDER BY handlerId LIMIT 1" 2>&1 | awk '{printf "    | %s\n", $0}'
    echo "  （无输出行 = 该固件无独立图书馆 booklet）"
fi
echo "  最近退出日志（lib_id 行）:"
grep "exit →" "$BASE/dashboard-launch.log" 2>/dev/null | tail -5 | awk '{printf "    | %s\n", $0}'

echo ""
echo "=========================================="
echo "诊断完成。请把整段输出发给维护者排查。"
echo "=========================================="
} | tee "$OUT"
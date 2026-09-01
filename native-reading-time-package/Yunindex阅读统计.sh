#!/bin/sh
#
# Yunindex阅读统计 v2.0 · 单页 dashboard launcher
# 架构：
#   FAST（设备有 python3 + Pillow）：compose.py 整页合成 → fbink -g 推 1 次
#   慢路径（无 PIL，纯 fbink）：推背景 PNG → fbink 多次 -t/-k 叠加数字与柱体
# 坐标体系：logical 1272x1696（与 background PNG 同源），由 fbink -g 自动缩放。
# 字体：Noto Serif SC 衬线体（与效果图一致）
#

BASE="/mnt/us/reading-time"
DATA="$BASE/reading-time.tsv"
LOG="$BASE/dashboard-launch.log"
FBINK="/var/local/kmc/bin/fbink"
LOGICAL_W=1272
LOGICAL_H=1696
TAB=$(printf '\t')

# 关键修复：先确保数据目录存在
mkdir -p "$BASE" 2>/dev/null
exec >> "$LOG" 2>&1
echo "$(date): v2.0 single-page dashboard launch, uid=$(id -u)"

FBINK_LOG="$BASE/fbink.log"
UI_DIR="$BASE/ui"
BASE_BG="$UI_DIR/dashboard_bg.png"
BASE_QUOTES="$UI_DIR/quotes.tsv"
FONT_DIR="$BASE/fonts"
RFONT="$FONT_DIR/NotoSerifSC-Regular.otf"
BFONT="$FONT_DIR/NotoSerifSC-Bold.otf"
PNG_TMP="$BASE/.tmp_dashboard.png"

# 坐标缩放 (logical → KPW6 viewport；fbink 实测 1272x1696，与 logical 一致 → 1:1)
scale_y() { awk -v y="$1" -v h="$LOGICAL_H" 'BEGIN{y+=0;h+=0;print int(y*1696/h+0.5)}'; }
scale_x() { awk -v x="$1" -v w="$LOGICAL_W" 'BEGIN{x+=0;w+=0;print int(x*1272/w+0.5)}'; }

# 单次 fbink -t（绝对定位，避免多 -t 文本流 bug）
fb_text_at() {
    px="$1"; top="$2"; left="$3"; right="$4"; style="$5"; fg="$6"; bg="$7"; msg="$8"
    bg_arg=""
    # R38：bg="-" 时用 -O（bgless，不画背景像素），否则 fbink 默认 -B WHITE 会给文字加白底
    if [ -n "$bg" ] && [ "$bg" != "-" ]; then
        bg_arg="-B $bg"
    else
        bg_arg="-O"
    fi
    "$FBINK" -q -b -C "$fg" $bg_arg \
        -t "regular=$RFONT,bold=$BFONT,px=$px,top=$(scale_y "$top"),left=$(scale_x "$left"),right=$(scale_x "$right"),style=$style" \
        "$msg" 2>>"$FBINK_LOG"
}
fb_rect_at() {
    "$FBINK" -q -b -B "$5" \
        -k "top=$(scale_y "$1"),left=$(scale_x "$2"),width=$(scale_x "$3"),height=$(scale_y "$4")" \
        2>>"$FBINK_LOG"
}

# 居中（left=0, right=LOGICAL_W）
fb_center() {
    fb_text_at "$1" "$2" 0 "$LOGICAL_W" BOLD BLACK - "$3"
}

fail() {
    echo "$(date): ERROR: $1"
    if [ -x "$FBINK" ]; then
        "$FBINK" -q -b -B WHITE -k "top=0,left=0,width=1264,height=1680" 2>/dev/null || true
        fb_text_at 24 600 0 "$LOGICAL_W" BOLD BLACK - "$1" 2>/dev/null || true
        "$FBINK" -q -f -W GC16 -s 2>/dev/null || true
    fi
    exit 1
}

# v13.1 防卡死加固：刷屏前收回系统状态栏/系统 UI 覆盖层，避免与下拉状态栏等系统 UI
# 并发争抢 framebuffer 导致 e-ink 驱动死锁（表现为"下拉状态栏后卡屏"）。
# 该 lipc 属性若固件不支持则静默 no-op，绝不报错；trap 兜底保证任何退出路径都恢复。
collapse_system_ui() {
    lipc-set-prop com.lab126.winmgr hideStatusBar 1 >/dev/null 2>&1 || true
}
restore_system_ui() {
    lipc-set-prop com.lab126.winmgr hideStatusBar 0 >/dev/null 2>&1 || true
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1 || true
}
trap restore_system_ui EXIT INT TERM HUP

# 必备资源检查
[ -x "$FBINK" ] || { echo "FBInk not found at $FBINK"; exit 1; }
[ -f "$BASE_BG" ] || fail "dashboard_bg.png missing"
[ -f "$RFONT" ] || fail "NotoSerifSC-Regular.otf missing"
[ -f "$BFONT" ] || fail "NotoSerifSC-Bold.otf missing"
[ -f "$DATA" ] || printf 'date\tbook_id\tseconds\ttitle\tstatus\tprogress\n' > "$DATA" 2>/dev/null

TS=$(date +%Y-%m-%d)
HYEAR=$(date +%Y)
hyear="$HYEAR"   # 当前展示年份（可被 < > 切换）

# === 年份切换（v13.1 R34 从 v12.0 移植）===
# 有阅读数据的所有年份 + 当前年份，排序去重（升序）
years_sorted() {
    {
        awk -F"$TAB" 'NR>1 && NF>=4 { y=substr($1,1,4); if(y ~ /^[0-9][0-9][0-9][0-9]$/) print y }' "$DATA"
        echo "$HYEAR"
    } | sort -un
}
# 切到上一个有数据的年份（比 hyear 小的最大年份）。返回 0 表示已切换，1 表示没数据。
year_prev() {
    best=""
    for y in $YEARS; do
        if [ "$y" -lt "$hyear" ]; then
            if [ -z "$best" ] || [ "$y" -gt "$best" ]; then best="$y"; fi
        fi
    done
    if [ -n "$best" ]; then hyear="$best"; return 0
    else return 1
    fi
}
# 切到下一个有数据的年份（比 hyear 大的最小年份）。返回 0 表示已切换，1 表示没数据。
year_next() {
    best=""
    for y in $YEARS; do
        if [ "$y" -gt "$hyear" ]; then
            if [ -z "$best" ] || [ "$y" -lt "$best" ]; then best="$y"; fi
        fi
    done
    if [ -n "$best" ]; then hyear="$best"; return 0
    else return 1
    fi
}
YEARS="$(years_sorted)"

# ============================================================
# FAST 探测：找一个能 import PIL 的 python3（含缓存）
# ============================================================
FAST_PY=""
FAST_SP=""
_fast_cache="$BASE/.fast_python"

read_cached_python() {
    _cached=$(cat "$_fast_cache" 2>/dev/null)
    [ -z "$_cached" ] && return 1
    _cp="${_cached%%|*}"
    _csp="${_cached#*|}"
    [ "$_csp" = "$_cached" ] && _csp=""
    [ -x "$_cp" ] || return 1
    if [ -z "$_csp" ]; then
        "$_cp" -c "import PIL" >/dev/null 2>&1 || return 1
    else
        PYTHONPATH="$_csp" "$_cp" -c "import PIL" >/dev/null 2>&1 || return 1
    fi
    FAST_PY="$_cp"
    FAST_SP="$_csp"
    [ -n "$FAST_SP" ] && export PYTHONPATH="$FAST_SP"
    return 0
}

if [ -f "$_fast_cache" ] && read_cached_python; then
    :
else
    for _c in python3 python; do
        _p=$(command -v "$_c" 2>/dev/null)
        [ -n "$_p" ] && "$_p" -c "import PIL" >/dev/null 2>&1 && { FAST_PY="$_p"; break; }
    done
    if [ -z "$FAST_PY" ]; then
        _pil=""
        for _base in /mnt/us/Vera /mnt/us/extensions /mnt/us/python /mnt/us/kpm /mnt/us/entware /opt /usr/local; do
            [ -d "$_base" ] || continue
            _pil=$(find "$_base" -maxdepth 6 -type d -name PIL 2>/dev/null | head -n1)
            [ -n "$_pil" ] && break
        done
        if [ -n "$_pil" ]; then
            _sp=$(dirname "$_pil")
            for _c in python3 python; do
                _p=$(command -v "$_c" 2>/dev/null)
                [ -n "$_p" ] && PYTHONPATH="$_sp" "$_p" -c "import PIL" >/dev/null 2>&1 && {
                    FAST_PY="$_p"; FAST_SP="$_sp"
                    export PYTHONPATH="$_sp"
                    break
                }
            done
        fi
    fi
    if [ -n "$FAST_PY" ]; then
        printf '%s\n' "${FAST_PY}|${FAST_SP}" > "$_fast_cache" 2>/dev/null || true
    fi
fi

# 数据计算只需 python3（无需 PIL）；整页合成渲染才需要 PIL。
# Kindle 有 python3 但可能无 PIL：此时数据仍用 python3 heredoc 算，渲染退回 fbink 慢路径。
PY3=""
# v13.1 R28：补上旧版的具体路径候选（Vera 的 python3 常不在 PATH，而在 /mnt/us/Vera/bin 等）
for _c in python3 python /opt/bin/python3 /usr/bin/python3 \
         /mnt/us/Vera/bin/python3 /mnt/us/Vera/python/bin/python3 \
         /mnt/us/extensions/python/bin/python3; do
    PY3=$(command -v "$_c" 2>/dev/null)
    [ -n "$PY3" ] && break
done

# ============================================================
# 计算 8 字段 + 周 7 天秒数 + 抽一句金句
# ============================================================
extract_random_quote() {
    QFILE="$BASE_QUOTES"
    QUOTE_LINE=""
    if [ -f "$QFILE" ]; then
        NLINES=$(grep -cE '^[^\t]+\t' "$QFILE" 2>/dev/null)
        if [ -n "$NLINES" ] && [ "$NLINES" -gt 0 ] 2>/dev/null; then
            IDX=$(( $(date -d "$TS" +%s 2>/dev/null || echo 0) % NLINES + 1 ))
            QUOTE_LINE=$(awk -F '\t' -v i="$IDX" 'NR==i{print;exit}' "$QFILE")
        fi
    fi
    [ -z "$QUOTE_LINE" ] && QUOTE_LINE="我们都是孤独的，直到遇见另一个孤独的灵魂	当尼采哭泣	欧文·亚隆"
    echo "$QUOTE_LINE"
}

# v13.1 R34：从 Kindle 系统「My Clippings.txt」读取真实高亮句（标注类），
# 随机抽一条，输出「句子\t书名\t作者」。无文件/无标注时输出空串。
# My Clippings.txt 结构：
#   ==========
#   书名 (作者)
#   - 您在位置 #xx 的标注 | 添加于 ...
#   <空行>
#   高亮正文（可能多行）
#   ==========
CLIP_PATH="/mnt/us/documents/My Clippings.txt"
extract_clipping() {
    [ -f "$CLIP_PATH" ] || { echo "$(date): DIAG clip: NOT FOUND at $CLIP_PATH" >&2; return 0; }
    CLIP_SIZE=$(wc -c < "$CLIP_PATH" 2>/dev/null | tr -d ' ')
    echo "$(date): DIAG clip: found $CLIP_SIZE bytes" >&2
    # R38：BOM/CRLF 全部在 awk 内处理
    # ★ 关键：用 awk 字符串字面量 substr($0,1,3) == "\357\273\277"（八进制转义 POSIX 标准）
    #   每行都去 BOM（不只在 NR==1，因为 Kindle 每条书名行都可能带 BOM）
    # ✗ 不要用 shell 层 $'\xef\xbb\xbf' 或 sed $'s/^\xef\xbb\xbf//' —— 那是 bash 专有语法，
    #   Kindle 的 /bin/sh 是 busybox ash，不认 $'...' ANSI-C 转义，会直接失效
    # ✗ 不要用 awk 正则 /^\357\273\277/ —— 正则里的 \NNN 八进制转义在 gawk/BSD/busybox 行为不一致
    CLIP_OUT=$(awk '
function flush() {
    if (is_hl && content != "") {
        gsub(/[\t\r]/, " ", content)
        gsub(/[ \t]+$/, "", content)
        print ts "\t" content "\t" title "\t" author
    }
    is_hl=0; title=""; author=""; content=""; meta=""; ts="00000000"
}
BEGIN { ts = "00000000" }
{
    if (substr($0,1,3) == "\357\273\277") { $0 = substr($0,4) }   # 每行去 UTF-8 BOM
    gsub(/\r$/, "")                                                # 去 CRLF 行尾 \r
    if ($0 ~ /^[[:space:]]*$/) next
    if ($0 ~ /^===+$/) { flush(); next }
    if (title == "") {
        if ($0 ~ /\([^()]*\)[[:space:]]*$/) {
            author = $0; sub(/^.*\(/, "", author); sub(/\)[[:space:]]*$/, "", author)
            title = $0; sub(/\([^()]*\)[[:space:]]*$/, "", title); gsub(/[[:space:]]+$/, "", title)
        } else { title = $0; author = "" }
    } else if (meta == "") {
        if ($0 ~ /标注|Highlight/) is_hl=1
        meta = $0
        # R43：提取添加时间 YYYYMMDD（中文"添加于 2026年3月16日"），用于按时间排序轮播
        if (meta ~ /添加于/) {
            m = meta; sub(/^.*添加于[[:space:]]*/, "", m)
            if (m ~ /^[0-9]+年[0-9]+月[0-9]+日/) {
                y = m; sub(/年.*/, "", y)
                mo = m; sub(/^[0-9]+年/, "", mo); sub(/月.*/, "", mo)
                d = m; sub(/^[0-9]+年[0-9]+月/, "", d); sub(/日.*/, "", d)
                if (length(mo) == 1) mo = "0" mo
                if (length(d) == 1) d = "0" d
                ts = y mo d
            }
        }
    } else {
        if (content == "") content = $0
        else content = content " " $0
    }
}
END { flush() }
' "$CLIP_PATH" 2>/dev/null)
    [ -z "$CLIP_OUT" ] && { echo "$(date): DIAG clip: parsed 0 highlights (empty)" >&2; return 0; }
    # R43：按添加时间升序排序（YYYYMMDD 定长字符串，字典序=时间序，最早在前）
    SORTED=$(printf '%s\n' "$CLIP_OUT" | sort 2>/dev/null)
    NL=$(printf '%s\n' "$SORTED" | wc -l | tr -d ' ')
    [ "$NL" -gt 0 ] 2>/dev/null || { echo "$(date): DIAG clip: 0 after sort" >&2; return 0; }
    echo "$(date): DIAG clip: parsed $NL highlight(s)" >&2
    # R43：索引轮询——每次打开展示下一条（时间顺序），遍历完重新循环
    IDX_FILE="$BASE/.quote_idx"
    idx=0
    [ -f "$IDX_FILE" ] && idx=$(cat "$IDX_FILE" 2>/dev/null | tr -dc '0-9')
    [ -z "$idx" ] && idx=0
    CLIP=$(printf '%s\n' "$SORTED" | awk -F '\t' -v i=$((idx % NL + 1)) 'NR==i{print $2 "\t" $3 "\t" $4; exit}')
    echo $(( (idx + 1) % NL )) > "$IDX_FILE" 2>/dev/null
    echo "$(date): DIAG clip: idx=$idx next=$(( (idx+1) % NL )) selected=[$CLIP]" >&2
    printf '%s\n' "$CLIP"
    return 0
}

# R41/R43：截断句子到一行（48pt 约 21 个中文字符），超出加省略号"…"。
# 金句 48pt（与累计时长值字号一致），版心 [100,1172] 宽 1072px ≈ 22 全角字，fbink OT 路径会自动换行，
# 若句子超长会换行压到下方书名作者行，故在数据层截断。
# busybox awk 是字节模式：中文字符 3 字节，截断到 63 字节(21字) + 省略号 3 字节 = 22 字显示宽。
truncate_sent() {
    printf '%s\n' "$1" | awk '
    function trunc_utf8(s, maxbytes,   out, i, b, len) {
        if (length(s) <= maxbytes) return s
        out = substr(s, 1, maxbytes)
        i = length(out)
        # 从末尾跳过续字节 0x80-0xBF（[\200-\277] 可靠；[\000-\177] 判断 ASCII 不可靠，故用排除法）
        while (i > 0 && substr(out, i, 1) ~ /[\200-\277]/) i--
        if (i == 0) return ""
        b = substr(out, i, 1)
        if (b ~ /[\300-\337]/) len = 2        # 前导 0xC0-0xDF → 2 字节字符
        else if (b ~ /[\340-\357]/) len = 3   # 前导 0xE0-0xEF → 3 字节（中文）
        else if (b ~ /[\360-\367]/) len = 4   # 前导 0xF0-0xF7 → 4 字节
        else len = 1                            # ASCII
        if (length(out) - i + 1 < len) return substr(out, 1, i - 1)
        return out
    }
    {
        s = $0
        if (length(s) <= 63) { print s; exit }
        print trunc_utf8(s, 63) "…"
    }'
}

# 进度回填（v13.1 R27 补回旧版机制）：从 Kindle 系统库 cc.db 读每本书真实进度，
# 回填 tsv 的 status/progress 字段（旧 4 列 tsv 或 progress 缺失时兜底）。
CC_DB="/var/local/cc.db"
PROGRESS_CACHE="$BASE/.progress_cache"
backfill_progress() {
    [ -r "$CC_DB" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
    rm -f "$PROGRESS_CACHE"
    sqlite3 -readonly -separator "$TAB" "$CC_DB" \
        "SELECT replace(replace(p_titles_0_nominal,char(9),' '),char(10),' '), CAST(p_percentFinished+0.5 AS INTEGER) FROM Entries WHERE p_titles_0_nominal IS NOT NULL AND p_percentFinished>=0 AND p_percentFinished<=100;" \
        > "$PROGRESS_CACHE" 2>/dev/null || return 0
    [ -s "$PROGRESS_CACHE" ] || return 0
    awk -F"$TAB" -v map="$PROGRESS_CACHE" '
    BEGIN{ while((getline line < map)>0){ n=split(line,a,"\t"); if(a[2]!="") pct[a[1]]=a[2] } close(map) }
    NR==1 && $1=="date" { print; next }
    {
        if(NF>=6){ t=$4; prog=$6; st=$5 }
        else if(NF>=4){ t=$4; prog=""; st="" }
        else { print; next }
        np=pct[t]; if(np!=""){ prog=np }
        if(prog=="") prog=0; if(prog!~/^[0-9]+$/) prog=0
        st=(prog+0>=100)?"finished":"reading"
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,t,st,prog
    }' "$DATA" > "$DATA.tmp" && mv "$DATA.tmp" "$DATA"
    rm -f "$PROGRESS_CACHE"
}
backfill_progress

# DIAG（写 launch.log）：定位"数据全0"根因——daemon 是否在跑 + lipc 属性真实值 + tsv 行数
echo "$(date): DIAG daemon_pid=[$(pgrep -f native-reading-time-daemon 2>/dev/null | tr '\n' ' ')]"
echo "$(date): DIAG activeApp=[$(lipc-get-prop com.lab126.appmgrd activeApp 2>/dev/null)]"
echo "$(date): DIAG powerd_state=[$(lipc-get-prop com.lab126.powerd state 2>/dev/null)]"
echo "$(date): DIAG tsv_lines=[$(wc -l < "$DATA" 2>/dev/null)]"

# v13.1 R34：把「计算 + 渲染」函数化，支持年份切换后按新 hyear 重算四卡并重绘整页。
# 注意：函数体顶格书写（不缩进），保证 heredoc 结束标记 PY 与 awk 脚本保持在行首。
render_dashboard() {
if [ -n "$PY3" ]; then
    calc=$("$PY3" - "$DATA" "$TS" "$hyear" <<'PY'
import sys
data_path, today_str, yr_str = sys.argv[1], sys.argv[2], sys.argv[3]
from datetime import date, timedelta

y, m, d = [int(x) for x in today_str.split('-')]
def days_in_month(y, m):
    if m in (1,3,5,7,8,10,12): return 31
    if m in (4,6,9,11): return 30
    return 29 if (y%400==0 or (y%4==0 and y%100!=0)) else 28
def wkd_mon(y, m, d):
    if m<3: m+=12; y-=1
    q=d; k=y%100; j=y//100
    h=(q+(13*(m+1))//5+k+k//4+j//4+5*j)%7
    return (h+5)%7

dow = wkd_mon(y, m, d)
ws = date(y,m,d)
for _ in range(dow): ws -= timedelta(days=1)
we = date(y,m,d)
for _ in range(6-dow): we += timedelta(days=1)
ws_str, we_str = ws.isoformat(), we.isoformat()

sec_today=0; sec_week=0
days_set=set(); fin_set=set(); rb_set=set(); fb_set=set()
sec7=[0]*7
yr_str_eq = yr_str
msec = 0; ysec = 0   # msec=本月累计(供本月日均); ysec=本年累计(供四卡"累计时长"，与 FAST/compose.py 口径一致)
read_set=set()
today_d = date(y,m,d)
try:
    with open(data_path,'r',encoding='utf-8',errors='replace') as f:
        nxt = f.readline()
        for line in f:
            p = line.rstrip().split('\t')
            if len(p)<3: continue
            dt = p[0]
            bid = p[1] if len(p)>1 else ''
            try: sec = int(float(p[2]))
            except: continue
            prog = 0; st='reading'
            if len(p)>=6:
                try: prog = int(float(p[5]))
                except: prog=0
                st = p[4] if p[4] else 'reading'
            if sec<=0: continue
            read_set.add(dt)
            if dt == today_str: sec_today += sec
            if ws_str <= dt <= we_str:
                try:
                    rd = date.fromisoformat(dt)
                except:
                    rd = None
                if rd is not None and rd > today_d:
                    pass
                else:
                    sec_week += sec
                    if rd is not None:
                        idx = (rd - ws).days
                        if 0<=idx<=6: sec7[idx] += sec
            if dt[:7] == today_str[:7]: msec += sec
            if dt[:4] == yr_str_eq:
                ysec += sec
                isfin = prog >= 100 or st == 'finished'
                if isfin: fin_set.add(bid)
                else: rb_set.add(bid)
                days_set.add(dt)
except Exception:
    pass

cur = date(y,m,d)
if today_str not in read_set: cur -= timedelta(days=1)
streak=0
while cur.isoformat() in read_set:
    streak += 1
    cur -= timedelta(days=1)

days_elapsed = d
avg_sec = int(round(msec / days_elapsed)) if days_elapsed else 0
total_week = sum(sec7)
# R39: 末尾新增 msec（本月累计秒数 = 本月时长），供第一排"本月时长"字段
print(f"{sec_today}\t{sec_week}\t{avg_sec}\t{streak}\t{ysec}\t{len(days_set)}\t{len(rb_set)}\t{len(fin_set)}\t{total_week}\t{','.join(str(x) for x in sec7)}\t{dow}\t{msec}")
PY
    )
else
    # v13.1 R31：慢路径用 awk 算数据（旧版方案，不依赖 python3）。
    # Vera 5.19.03 无 python3 → 之前 heredoc 不跑、calc 写死全 0。现改为纯 awk。
    calc=$(awk -F "$TAB" -v today="$TS" -v year="$hyear" '
function jd(y,m,d,   a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
BEGIN {
    split(today, td, "-"); ty=td[1]+0; tm=td[2]+0; tdd=td[3]+0
    _y=ty; _m=tm; if(_m<3){_m+=12;_y--}
    q=tdd; k=_y%100; j=int(_y/100)
    h=(q+int(13*(_m+1)/5)+k+int(k/4)+int(j/4)+5*j)%7
    dow=(h+5)%7
    today_jd=jd(ty,tm,tdd); ws_jd=today_jd-dow; we_jd=ws_jd+6
    month_ym=sprintf("%04d-%02d", ty, tm)
    sec_today=0; sec_week=0; sec_month=0; sec_year=0
    days_year=0; rb=0; fb=0
    for(i=0;i<7;i++) sec7[i]=0
    read_cnt=0
}
{
    if(NR==1 && $1=="date") next
    if(NF<4) next
    dstr=$1; sec=$3+0
    if(sec<=0) next
    bid=$2; prog=0; st="reading"
    if(NF>=6){ prog=$6+0; st=$5 }
    isfin=(prog>=100 || st=="finished")
    n2=split(dstr, dd, "-"); d_jd=jd(dd[1]+0, dd[2]+0, dd[3]+0)
    if(dstr==today) sec_today+=sec
    if(d_jd>=ws_jd && d_jd<=we_jd && d_jd<=today_jd){
        sec_week+=sec
        idx=d_jd-ws_jd
        if(idx>=0 && idx<=6) sec7[idx]+=sec
    }
    if(substr(dstr,1,7)==month_ym) sec_month+=sec
    if(substr(dstr,1,4)==year){
        sec_year+=sec
        if(!(dstr in seen_day)){ seen_day[dstr]=1; days_year++ }
        if(isfin){ if(!(bid in fin_seen)){ fin_seen[bid]=1; fb++ } }
        else { if(!(bid in rb_seen)){ rb_seen[bid]=1; rb++ } }
    }
    if(!(dstr in read_seen)){ read_seen[dstr]=1; read_jd[read_cnt++]=d_jd }
}
END {
    streak=0; cur=today_jd
    has=0; for(i=0;i<read_cnt;i++) if(read_jd[i]==cur){has=1;break}
    if(!has) cur=today_jd-1
    while(1){
        has=0; for(i=0;i<read_cnt;i++) if(read_jd[i]==cur){has=1;break}
        if(!has) break
        streak++; cur--
    }
    avg=(tdd>0) ? int(sec_month/tdd) : 0
    sec7str=""
    for(i=0;i<7;i++){ if(i>0) sec7str=sec7str ","; sec7str=sec7str sec7[i] }
    # R39: 末尾新增 sec_month（本月累计秒数 = 本月时长）
    printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\n", sec_today, sec_week, avg, streak, sec_year, days_year, rb, fb, sec_week, sec7str, dow, sec_month
}
' "$DATA")
fi

TODAY_S=$(echo "$calc" | awk -F '\t' '{print $1}')
WEEK_S=$(echo "$calc" | awk -F '\t' '{print $2}')
AVG_S=$(echo "$calc" | awk -F '\t' '{print $3}')
STREAK_N=$(echo "$calc" | awk -F '\t' '{print $4}')
MSEC=$(echo "$calc" | awk -F '\t' '{print $5}')
YEAR_DAYS=$(echo "$calc" | awk -F '\t' '{print $6}')
YEAR_RB=$(echo "$calc" | awk -F '\t' '{print $7}')
YEAR_FB=$(echo "$calc" | awk -F '\t' '{print $8}')
TOTAL_WEEK=$(echo "$calc" | awk -F '\t' '{print $9}')
SEC7=$(echo "$calc" | awk -F '\t' '{print $10}')
DOW=$(echo "$calc" | awk -F '\t' '{print $11}')
MONTH_TOTAL=$(echo "$calc" | awk -F '\t' '{print $12}')   # R39: 本月累计秒数（本月时长）

# 格式化（无单位）：时间用 HH:MM，数字直接
fmt_hm() {
    awk -v s="$1" 'BEGIN{t=s+0;h=int(t/3600);m=int((t%3600)/60);printf("%dh%dm",h,m)}'
}

TODAY_STR=$(fmt_hm "$TODAY_S")
WEEK_STR=$(fmt_hm "$WEEK_S")
AVG_STR=$(fmt_hm "$AVG_S")
STREAK_STR="${STREAK_N}天"   # R46: 连续阅读→连续天，值加"天"后缀
MSEC_STR=$(fmt_hm "$MSEC")
TW_STR=$(fmt_hm "$TOTAL_WEEK")
MONTH_TOTAL_STR=$(fmt_hm "$MONTH_TOTAL")   # R39: 本月时长

# v13.1 R34：优先用 Kindle 真实高亮句（My Clippings.txt），无则回退到预设金句
CLIP=$(extract_clipping)
if [ -n "$CLIP" ]; then
    QSENT=$(echo "$CLIP" | awk -F '\t' '{print $1}')
    QBOOK=$(echo "$CLIP" | awk -F '\t' '{print $2}')
    QAUTHOR=$(echo "$CLIP" | awk -F '\t' '{print $3}')
else
    QLINE=$(extract_random_quote)
    QSENT=$(echo "$QLINE" | awk -F '\t' '{print $1}')
    QBOOK=$(echo "$QLINE" | awk -F '\t' '{print $2}')
    QAUTHOR=$(echo "$QLINE" | awk -F '\t' '{print $3}')
fi

# R41：截断到一行（约 40 字），超出加省略号，避免超长句自动换行压到书名作者/年份
QSENT=$(truncate_sent "$QSENT")

echo "$(date): calc today=$TODAY_STR week=$WEEK_STR avg=$AVG_STR streak=$STREAK_N sec7=$SEC7 dow=$DOW quote=\"$QSENT\""

# ============================================================
# 派发渲染
# ============================================================
if [ -n "$FAST_PY" ]; then
    rm -f "$PNG_TMP"
    "$FAST_PY" "$UI_DIR/compose.py" \
        --bg "$BASE_BG" --quotes "$BASE_QUOTES" --data "$DATA" \
        --reg-font "$RFONT" --bold-font "$BFONT" \
        --today "$TS" --year "$hyear" --out "$PNG_TMP" 2>>"$FBINK_LOG"
    if [ $? -eq 0 ] && [ -r "$PNG_TMP" ]; then
        echo "$(date): fast path ON python=$FAST_PY -> $PNG_TMP"
        collapse_system_ui
        "$FBINK" -q -g "file=$PNG_TMP" 2>>"$FBINK_LOG" || { restore_system_ui; rm -f "$PNG_TMP"; fail "fbink push failed"; }
        "$FBINK" -q -f -W GC16 -s 2>>"$FBINK_LOG" || true
        restore_system_ui
        rm -f "$PNG_TMP"
        return 0
    fi
    rm -f "$PNG_TMP"
    echo "$(date): fast path compose failed; falling back"
fi

# === SLOW path ===
echo "$(date): fast path OFF python=$FAST_PY"

# 1. 推背景
collapse_system_ui
"$FBINK" -q -g "file=$BASE_BG" 2>>"$FBINK_LOG" || { restore_system_ui; fail "bg push failed"; }

# 2. 今日阅读大数字（左对齐 x=100 y=352）
fb_text_at 130 352 100 800 BOLD BLACK - "$TODAY_STR"

# 3. 第一排四卡 44pt y=615（R39：改为 4 字段，起点/列宽与下方四卡完全一致 [100,378,656,934]）
fb_text_at 44 615 100 100 BOLD BLACK - "$WEEK_STR"
fb_text_at 44 615 378 378 BOLD BLACK - "$AVG_STR"
fb_text_at 44 615 656 338 BOLD BLACK - "$MONTH_TOTAL_STR"
fb_text_at 44 615 934 60 BOLD BLACK - "$STREAK_STR"

# 4. 7 柱（R33：gap 46→76 柱体变窄，与底图 generate_bg.py 一致）
bar_x0=60
bar_x1=$((LOGICAL_W - 60))
inner_w=$((bar_x1 - bar_x0))
n=7
gap=76
sq=$(( (inner_w - gap * (n - 1)) / n ))
bar_y_top=830
bar_y_bot=1010
bar_full_h=$((bar_y_bot - bar_y_top))
col_w=$((sq + gap))
LOW_H=$((bar_full_h * 33 / 100))   # < 30min 低柱
MID_H=$((bar_full_h * 66 / 100))   # 30min-1h59min 中柱
FULL_H=$bar_full_h                  # >= 2h 满柱

TW_S=$(echo "$SEC7" | tr ',' '\n' | awk 'BEGIN{s=0}{s+=$1+0}END{print s}')
# 条件渲染：周总时长 > 0 才画柱 + 合计
if [ "$TW_S" -gt 0 ] 2>/dev/null; then
    i=0
    for s in $(echo "$SEC7" | tr ',' ' '); do
        if [ "$i" -gt "$DOW" ] 2>/dev/null; then
            i=$((i+1)); continue
        fi
        if [ "$s" -le 0 ] 2>/dev/null; then
            i=$((i+1)); continue
        fi
        x=$((bar_x0 + i * col_w))
        # 4 档离散（与 compose.py 一致）
        if [ "$s" -lt $((30 * 60)) ]; then
            h=$LOW_H
        elif [ "$s" -lt $((120 * 60)) ]; then
            h=$MID_H
        else
            h=$FULL_H
        fi
        bar_top=$((bar_y_bot - h))
        fb_rect_at "$bar_top" "$x" "$sq" "$h" BLACK
        # R35：柱顶数字 24pt 完全画在柱顶之外（top=bar_top-30，bottom=bar_top-6，离开柱体）
        # 不再画白底矩形（皇上要求"不需要背景图底色"，水印(218,218,218)很浅不影响阅读）
        lbl=$(fmt_hm "$s")
        lbl_cx=$((x + sq / 2))
        lbl_w=$((${#lbl} * 14))
        half=$((lbl_w / 2))
        # 24pt 文字居中于 lbl_cx（top=bar_top-30，bottom=bar_top-6 留 6px padding）
        fb_text_at 24 $((bar_top - 30)) $((lbl_cx - half)) $((LOGICAL_W - lbl_cx - half)) BOLD BLACK - "$lbl"
        i=$((i+1))
    done
fi
# R45：已移除"合计"（皇上确认不需要展示；原 right=$((W-60))=1212 致绘制区反向本就不显示）

# 6. 本年统计 4 卡 48pt y=1233（R14: 列宽 278pt 严格 4 等分；起点 [100, 378, 656, 934]，终点 [378, 656, 934, 1212]；起点对齐"本年统计"段标题 XL=100）
fb_text_at 48 1233 100 100 BOLD BLACK - "$MSEC_STR"
fb_text_at 48 1233 378 378 BOLD BLACK - "${YEAR_DAYS}天"
fb_text_at 48 1233 656 338 BOLD BLACK - "${YEAR_RB}本"
fb_text_at 48 1233 934 60 BOLD BLACK - "${YEAR_FB}本"

# 7. 金句（R43：句子 48pt（与累计时长值字号一致）+ 书名/作者 28pt（比句子小一点））
# R41：left/right 是 fbink -t 的边距，right=1272(=W) 会让绘制区 [0, W-1272]=[0,0] 宽 0 → 金句静默不画！
# 这是"高亮一直不显示"的真凶（数据层早已正确，卡在渲染层）。改成 left=100 right=100（版心 [100,1172]）。
# 金句区 [1320,1450] 130px：句子 48pt top=1332(底≈1380)，书名作者 28pt top=1392(底≈1420)，距下分割线 30px。
fb_text_at 48 1332 100 100 BOLD BLACK - "$QSENT"
if [ -n "$QBOOK" ]; then
    meta="《$QBOOK》"
    [ -n "$QAUTHOR" ] && meta="$meta · $QAUTHOR"
    fb_text_at 28 1392 100 100 REGULAR BLACK - "$meta"
fi

# 8. 年份（R34：36pt 垂直居中于按钮中心 1557，top=1539；右对齐边距 W-60 保持）
ar_w=90; ar_h=65; ar_gap=16
ar_total=$((ar_w * 3 + ar_gap * 2))
ar_x1=$((LOGICAL_W - 60 - ar_total))
ar_y0=1525
year_cx=$((ar_x1 + (ar_w + ar_gap) + ar_w / 2))
# 白底（高 50px 覆盖 36pt 数字，居中于 year_cx）
fb_rect_at $((ar_y0 + 6)) $((year_cx - 45)) 90 50 WHITE
# R35：年份 36pt 居中。4 位数字宽 ~80px，绘制区宽 88（left=year_cx-44, right=W-year_cx-44）让文字视觉中心=year_cx（之前 96 偏左 8px）
fb_text_at 36 1539 $((year_cx - 44)) $((LOGICAL_W - year_cx - 44)) BOLD BLACK - "$hyear"

# 9. commit
"$FBINK" -q -f -W GC16 -s 2>>"$FBINK_LOG" || true
restore_system_ui
}

# ============================================================
# v13.1 R34：主循环 —— 渲染 → 监听触摸 → 切年份重渲染 / 退出
# 年份切换只影响「本年统计」四卡（累计时长/累计阅读/在读书籍/完成阅读），
# 但为简单可靠，切年份时整页重渲染（v12.0 也是 while 循环整页 draw 的成熟模式）。
# ============================================================
find_touch_device() {
    for pat in pt_mt touch zforce cyttsp fts goodix capmulti elan _ts; do
        for event_path in /sys/class/input/event*; do
            [ -r "$event_path/device/name" ] || continue
            event_name="$(cat "$event_path/device/name" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
            case "$event_name" in
                *pwrkey*|*power*|*-key*|*keypad*|*button*) continue;;
                *"$pat"*)
                    candidate="/dev/input/${event_path##*/}"
                    [ -r "$candidate" ] && { TOUCH="$candidate"; return; }
                    ;;
            esac
        done
    done
    [ -r /dev/input/event1 ] && { TOUCH="/dev/input/event1"; return; }
    TOUCH="/dev/input/event0"
}
TOUCH=""
find_touch_device
TOUCH_READER="$BASE/bin/reading-insights-touch.lua"

lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1 || true

# 首次渲染
render_dashboard

# 循环：每次 touch 返回 action 后，切换年份则重渲染，exit/超时则退出回主页
while :; do
    action=""
    if [ -r "$TOUCH_READER" ] && command -v lua >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        action="$(timeout 120 lua "$TOUCH_READER" "$TOUCH" "$BASE/dashboard-touch.log" "single" "$hyear" 0 0 1272 1696 2>/dev/null)" || action="exit"
    else
        sleep 120
        action="exit"
    fi
    echo "$(date): action=$action hyear=$hyear"
    case "$action" in
        exit) break;;
        period_prev) year_prev;;   # 切换 hyear，返回 0=成功 / 1=无更早年份
        period_next) year_next;;   # 返回 0=成功 / 1=无更晚年份
        *) break;;
    esac
    # R45：切换成功（返回 0）才重渲染；失败（无数据）不渲染，避免空闪屏
    # （修复此前 case 之后无条件 render_dashboard 导致的"点一下闪一下"）
    if [ $? -eq 0 ]; then
        lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1 || true
        render_dashboard
    fi
done

# 自动回主页（右上角退出 / 2 分钟超时 / 主页键 trap 恢复）
# 导出日志到 USB 根（补回旧版 export_logs，方便排障）
for _lf in dashboard-launch.log fbink.log dashboard-touch.log install.log; do
    [ -f "$BASE/$_lf" ] && cp "$BASE/$_lf" "/mnt/us/LOG-$_lf" 2>/dev/null
done
restore_system_ui
lipc-set-prop com.lab126.appmgrd start 'app://com.lab126.booklet.home' >/dev/null 2>&1 || \
lipc-set-prop com.lab126.appmgrd start 'app://com.lab126.KPPMainApp?view=KPP_LIBRARY' >/dev/null 2>&1 || true
exit 0

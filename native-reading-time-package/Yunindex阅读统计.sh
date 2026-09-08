#!/bin/sh
# Name: Yunindex阅读统计
# Author: YUNSTUDIO13
# Icon: /mnt/us/reading-time/ui/cover.png
#
# Yunindex阅读统计 v2.4.2 (2026-09-08: 计数制 flash，少闪不糊) · 双页（dashboard + ranking）launcher
# v2.4.2：① 渲染 commit 统一走 commit_screen()——每 FLASH_EVERY(=5) 次渲染强制 -f 清残影一次，
#      其余无闪 GC16（Kindle 原生书籍「每 N 翻页一闪」同款；闪屏频率 100%→20%，残影有界）
#      ② 退出反馈由全屏 flash 改为 × 按钮区局部反色黑块（DU 波形 ~0.15s，不闪全屏）
#      ③ FAST 推图改为 -b 缓冲推图 + commit_screen 提交（与 SLOW 路径同模式）
# v2.4.1：① 关闭热区 [1130,35,1222,127]→[1140,60,1230,180] 对齐 × 视觉圆心(1180,120)
#      （旧热区 y≤127 漏掉圆下半 21px，瞄圆心戳常判空需连戳；lua 同改）
#      ② 退出分支即时确认反馈（v2.4.2 已改为局部反色）
# v2.4.0：① 跨年归档——截止月(今天-90天所在月)前的明细折叠为「当月×每书」7列行(第7列=日清单，
#      date=当月最后阅读日)，每月至多折叠一次(.archive_done)，自检四项(总秒/各年秒/各年天数/行数增减)
#      全等才替换、失败自动回滚停手，明细写 USB 根 LOG-archive.log；近 90 天明细不动 → 切年/streak/本周无损
#      ② dashboard calc 当日结果缓存(.calc_cache，key=年份|行数|日期) ③ streak 嵌套循环→hash 直查
#      ④ backfill 跳过缓存(.backfill_key，key=行数|cc.db mtime+size)+归档行第7列透传
#      ⑤ calc/rank 快慢双通道全部支持 NF>=7 归档行（开始日期=日清单最小日精确还原）
# v2.3.36：排行 书名 34→36pt / 作者·起止 25→27pt / 累计时长 34→36pt（序号/日均/百分比不动，坐标全不动）
# v2.3.35：
#   ① 排行行内布局重排（6 点布局需求+间距微调，详见 render_ranking 行内注释）
#   ② 体检修复：封面候选路径含空格被分词 → 改逐项引号传参；
#      launch/fbink/rank-debug/touch 四日志超 200KB 截断留尾 100KB（先于 exec>>）；
#      text_w 4字节 emoji 跳字修正；删 scale_y/scale_x 死代码；lua 删 htab 死参数。
# v2.3.33/34 性能与画质总攻：
#   ① 字体子集化：GB2312全表+假名+常用符号 8025 字形，11.6/12.1MB → 2.6/2.7MB（每次 fbink -t
#      字体 IO 24MB→5.3MB ≈130ms→~40ms）；★v2.3.34 子集保留 CFF hinting（v2.3.33 剥 hint 是误判，
#      已验证子集与原字 hint 运算符/BlueValues/字宽 advance 逐字符一致）。
#   ② 残影修复（实测：首入清晰、切排行后渐糊）：最终刷新加回 -f flash。
#      FBInk 作者 NiLuJe：无 flash 的刷新不触碰未变像素、顽固机型（KPW6）必须 -f 才清残影。
#      R48 当年"闪2次"是两条独立刷新命令叠加；单命令 -f -W GC16 -s = 一次标准全刷。
#   ③ REGULAR 文字只传 regular= 槽，BOLD 才双槽 → 常规字字体 IO 再减半。
#   ④ _tm/_nowcs 打点改 shell 内建读 /proc/uptime（原每次 fork awk）。
#   ⑤ 行解析 12×cut+2×tr → 单次 awk 以 \x1f 连接 + read 拆 13 字段（空字段不合并、不错位）。
#   ⑥ dashboard：12×echo|awk → IFS tab set --；fmt_hm/SEC7 求和改纯内建算术。
#   封面查询链路（COVER_MAP/UUID_MAP/多路径 fallback）与 v2.3.23/32 逐字节一致，未动。
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

# v2.3.9 需求定稿：排行页**全部黑色字体**，只靠字号/粗细区分主次，不要灰不要绿。
# （真机旧版 FBInk 只认关键字 BLACK/GRAY1~GRAYE/WHITE，不认 hex；且需求明确 UI 不要彩色）
INK_SOFT="BLACK"
BAR_FILL="BLACK"

# 关键修复：先确保数据目录存在
mkdir -p "$BASE" 2>/dev/null
# v2.3.35：日志截断——单文件超 200KB 只留尾 100KB（launch/fbink/rank-debug/touch 四日志
#   原均无界追加，长期占闪存）。必须先于 exec>> 执行：否则本进程 append fd 指向被 mv
#   替换掉的旧 inode，本轮日志全丢。
for _lf in "$LOG" "$BASE/fbink.log" "$BASE/rank-debug.log" "$BASE/dashboard-touch.log"; do
    [ -f "$_lf" ] || continue
    _sz=$(wc -c < "$_lf" 2>/dev/null | tr -d ' ')
    if [ -n "$_sz" ] && [ "$_sz" -gt 204800 ] 2>/dev/null; then
        tail -c 102400 "$_lf" > "$_lf.trunc" 2>/dev/null && mv "$_lf.trunc" "$_lf"
    fi
done
exec >> "$LOG" 2>&1
echo "$(date): v2.3 dual-page (dashboard+ranking) launch, uid=$(id -u)"

FBINK_LOG="$BASE/fbink.log"
UI_DIR="$BASE/ui"
BASE_BG="$UI_DIR/dashboard_bg.png"
BASE_QUOTES="$UI_DIR/quotes.tsv"
# v2.3.12：字体路径探测（真机「毫无变化」根因：MAC 打包字体在包根目录，旧版写死 $BASE/fonts/，
#   真机 regular=$RFONT 指向不存在/损坏文件 → fbink 加载 regular 槽字体失败 → 常规字整条静默不画；
#   BOLD 走 bold=$BFONT 槽能出。现同时探测 fonts/ 子目录与包根两种布局，且 regular 槽
#   缺失时回退 Bold（Bold 已证真机可渲染），保证常规字必出。
FONT_DIR="$BASE/fonts"
BFONT=""; RFONT=""
for _c in "$FONT_DIR/NotoSerifSC-Bold.otf" "$BASE/NotoSerifSC-Bold.otf"; do [ -f "$_c" ] && { BFONT="$_c"; break; }; done
for _c in "$FONT_DIR/NotoSerifSC-Regular.otf" "$BASE/NotoSerifSC-Regular.otf"; do [ -f "$_c" ] && { RFONT="$_c"; break; }; done
[ -z "$RFONT" ] && RFONT="$BFONT"
[ -z "$BFONT" ] && BFONT="$RFONT"
PNG_TMP="$BASE/.tmp_dashboard.png"

# 坐标：v2.3.35 删 scale_y/scale_x 死代码（KPW6 viewport=1272x1696 与 logical 1:1，自
#   v2.3.32 起无人调用；若未来换机型分辨率非 1:1，需重新加坐标缩放）

# 单次 fbink -t（LEFT 对齐；left/right 为「距 viewport 边缘的边距」）
# v2.3.7 关键修复：fbink -t 不支持 halign/valign key（那是 -g image 专属），
#   传 halign=... 会让 fbink 解析到未知 key → errfnd=true → 整条渲染静默失败（真机不画字）。
#   居中/右对齐一律改用 fb_text_center / fb_text_right 手动算 left 偏移。
fb_text_at() {
    px="$1"; top="$2"; left="$3"; right="$4"; style="$5"; fg="$6"; bg="$7"; msg="$8"
    # v2.3.11：常规字体（REGULAR/NORMAL/空）省略 style key，让 fbink 默认用 regular= 路径字体；
    # 仅 BOLD/ITALIC/BOLD_ITALIC 显式拼 style。原因：旧版 fbink CLI 的 style 字符串是 NORMAL（对应
    # FNT_REGULAR 枚举），并不识别 "REGULAR" 这个枚举展示名——传 style=REGULAR 会被当未知 key 整条
    # 静默失败。省略 style 最稳妥，常规字永远出。
    style_arg=""
    case "$style" in
        BOLD|ITALIC|BOLD_ITALIC) style_arg=",style=$style" ;;
        *) style_arg="" ;;
    esac
    # v2.3.14 真凶修复（历史疏失，谨记）：调用处传的是**变量名字符串**（如 INK_SOFT），
    #   shell 不会展开，fbink 实际收到 `-C INK_SOFT`；而旧版 fbink 只认 BLACK/GRAY1~GRAYE/WHITE，
    #   收到非法颜色名 → 解析失败 → **整条静默不画**。这正是「书名/时长(BLACK)出、而
    #   序号/作者/起止/百分比/日均(INK_SOFT)全灭」的根因——与字体路径、style 均无关，
    #   v2.3.10~v2.3.13 三轮判断皆误，致反复重装返工。
    #   现做三层防呆：① 变量名间接展开 ② 颜色白名单校验 ③ 非法一律回落 BLACK → 文字必出。
    _fg="$fg"
    case "$fg" in
        BLACK|WHITE|GRAY1|GRAY2|GRAY3|GRAY4|GRAY5|GRAY6|GRAY7|GRAY8|GRAY9|GRAYA|GRAYB|GRAYC|GRAYD|GRAYE) ;;
        *)
            eval "_fg=\"\$${fg}\"" 2>/dev/null || _fg=""
            case "$_fg" in
                BLACK|WHITE|GRAY1|GRAY2|GRAY3|GRAY4|GRAY5|GRAY6|GRAY7|GRAY8|GRAY9|GRAYA|GRAYB|GRAYC|GRAYD|GRAYE) ;;
                *) _fg="BLACK" ;;
            esac ;;
    esac
    # bg 同样走白名单：非法/占位一律 -O（无底色，避免给文字加白底块）
    case "$bg" in
        BLACK|WHITE|GRAY1|GRAY2|GRAY3|GRAY4|GRAY5|GRAY6|GRAY7|GRAY8|GRAY9|GRAYA|GRAYB|GRAYC|GRAYD|GRAYE) bg_arg="-B $bg" ;;
        *) bg_arg="-O" ;;
    esac
    # v2.3.32 性能：KPW6 viewport=1272x1696 与 LOGICAL 1:1（历轮像素探针校准均按此），
    #   top/left/right 直接透传——删掉 $(scale_y/scale_x) 的 awk 子进程 fork（每字 3 个 awk 是渲染慢大头）。
    #   ⚠ 若未来换机型（分辨率非 1:1），需重新加坐标缩放（函数已删）。
    # v2.3.33 性能：REGULAR 只传 regular= 槽（fbink 最基础用法；每次 -t 都全量读字体文件，
    #   常规字不再白读 2.25MB Bold 字体）；BOLD/ITALIC 需双槽保持原样。
    case "$style" in
        BOLD|ITALIC|BOLD_ITALIC) fonts_arg="regular=$RFONT,bold=$BFONT" ;;
        *) fonts_arg="regular=$RFONT" ;;
    esac
    "$FBINK" -q -b -C "$_fg" $bg_arg \
        -t "$fonts_arg,px=$px,top=$top,left=$left,right=$right$style_arg" \
        "$msg" 2>>"$FBINK_LOG"
}

# 估算字符串像素宽度（Noto Serif SC；ASCII 精确，中文/箭头等 UTF-8 多字节按 1em 跳 3 字节）
# LC_ALL=C 强制 awk 字节模式，避免 BSD awk 对 UTF-8 中间字节做 multibyte 转换失败（busybox/gawk/mawk/BSD 全兼容）
# v2.3.20：$3=style。仅当显式 REGULAR 时用「常规字实测 advance」系数表 ——
#   用 PIL 对 NotoSerifSC-Regular/Bold @32px 实测：REG 数字 18/h 21/m 31/空格 8（vs Bold 19/22/32/8），
#   旧表按 Bold 宽估 REG 串会高估 3~6px → 排行页「日均」右缘比「时长(Bold)」偏左 3~6px（用户指出的右对齐问题）。
#   Bold 走旧表（实测误差 ±0.3px）；$3 为空（fb_text_center 旧调用）也走旧表 → 已校准的胶囊/页码视觉零变化。
text_w() {
    LC_ALL=C awk -v s="$1" -v px="$2" -v st="$3" 'BEGIN{
        if (st == "REGULAR") { f1=0.46875; fd=0.5625; fh=0.65625; fm=0.96875; fa=0.66; fsp=0.25; fsl=0.34375; fpct=0.9375; fmin=0.34375; fdot=0.3125 }
        else { f1=0.47; fd=0.60; fh=0.67; fm=1.00; fa=0.70; fsp=0.25; fsl=0.40; fpct=1.00; fmin=0.35; fdot=0.35 }
        w=0; i=1; n=length(s)
        while(i<=n){
            c=substr(s,i,1)
            if(c=="1"){ w+=px*f1; i++ }
            else if(c ~ /[0-9]/){ w+=px*fd; i++ }
            else if(c=="h"){ w+=px*fh; i++ }
            else if(c=="m"){ w+=px*fm; i++ }
            else if(c ~ /[A-Za-z]/){ w+=px*fa; i++ }
            else if(c==" "){ w+=px*fsp; i++ }
            else if(c=="/"){ w+=px*fsl; i++ }
            else if(c=="%"){ w+=px*fpct; i++ }
            else if(c=="-"){ w+=px*fmin; i++ }
            else if(c=="."){ w+=px*fdot; i++ }
            else { w+=px*1.00; if (c ~ /[\360-\367]/) i+=4; else if (c ~ /[\300-\337]/) i+=2; else i+=3 }  # v2.3.35：UTF-8 变长跳字——4字节 emoji / 2字节 / 3字节中文（原一刀切 3 字节，emoji 书名宽度估算错位）
        }
        printf "%d", w
    }'
}

# 在绘制区 [box_left, box_right] 内水平居中（不依赖 fbink halign）
fb_text_center() {
    px="$1"; top="$2"; box_left="$3"; box_right="$4"; style="$5"; fg="$6"; msg="$7"
    w=$(text_w "$msg" "$px")
    box_w=$((box_right - box_left))
    left=$((box_left + (box_w - w) / 2))
    right=$((LOGICAL_W - box_right))
    fb_text_at "$px" "$top" "$left" "$right" "$style" "$fg" - "$msg"
}

# 右对齐到 right_edge（不依赖 fbink halign）
fb_text_right() {
    px="$1"; top="$2"; right_edge="$3"; style="$4"; fg="$5"; msg="$6"
    # v2.3.20：把 style 传给 text_w，REGULAR 串用常规字实测宽度表（否则日均右缘比时长偏左 3~6px）
    w=$(text_w "$msg" "$px" "$style")
    left=$((right_edge - w))
    right=$((LOGICAL_W - right_edge))
    fb_text_at "$px" "$top" "$left" "$right" "$style" "$fg" - "$msg"
}
fb_rect_at() {
    # v2.3.32：同 fb_text_at，1:1 直通免 scale awk fork
    "$FBINK" -q -b -B "$5" \
        -k "top=$1,left=$2,width=$3,height=$4" \
        2>>"$FBINK_LOG"
}

# 居中（left=0, right=LOGICAL_W）
fb_center() {
    fb_text_at "$1" "$2" 0 "$LOGICAL_W" BOLD BLACK - "$3"
}

# v2.4.2：计数制 flash（Kindle 原生书籍「每 N 翻页一闪」同款）——
#   无 flash 的 GC16 不重驱动未变像素，残影逐次累积发糊（v2.3.34 教训）；
#   故每 FLASH_EVERY 次渲染强制 -f 清屏一次，其余无闪 GC16。残影最多累积 FLASH_EVERY-1 次即有界，
#   闪屏频率从每次必闪降到 1/FLASH_EVERY。嫌糊调小，嫌闪调大。
FLASH_EVERY=5
RENDER_N=0
commit_screen() {
    RENDER_N=$((RENDER_N + 1))
    if [ $((RENDER_N % FLASH_EVERY)) -eq 1 ]; then
        "$FBINK" -q -f -W GC16 -s 2>>"$FBINK_LOG" || true
    else
        "$FBINK" -q -W GC16 -s 2>>"$FBINK_LOG" || true
    fi
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

# === v2.3 排行页状态（跨年汇总，与 dashboard 的按年 hyear 完全分离）===
PAGE="dashboard"        # dashboard | ranking
RANK_OFFSET=0           # 排行页当前页偏移（0=第 1 页）
RANK_SORT="duration"    # duration(按累计时长) | daily(按日均)
RANK_TOTAL=0            # 排行页总书籍数（计算后填，供翻页判断）

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

# ============================================================
# v2.4.0：跨年归档——把「截止月（今天-90 天所在月）之前」的原始明细折叠成
#   「当月×每书」一行：date=当月最后阅读日，seconds=月总秒，st/prog=月末值，
#   第 7 列=当月阅读日清单（如 3,5,21）→ 天数/streak/排行开始日期均可逐日还原。
#   · daemon 恒写 6 列 → NF>=7 唯一标识归档行，重复启动幂等
#   · 每月最多折叠一次（.archive_done 记截止月）；自检失败自动回滚并停手（FAIL- 标记，删标记可重试）
#   · 近 90 天明细一行不动（streak 跨年、本周/本月/今日无损）
#   · 结果与校验明细写 USB 根 LOG-archive.log，装后可直接核对
# ============================================================
ARCHIVE_MARK="$BASE/.archive_done"
ARCHIVE_ULOG="/mnt/us/LOG-archive.log"
archive_verify() {
    LC_ALL=C awk -F'\t' '
        NR==1 && $1=="date" { next }
        NF>=7 {
            s=$3+0; if(s<=0) next
            y=substr($1,1,4); ys[y]+=s; tot+=s
            nd=split($7,dl,",")
            for(i=1;i<=nd;i++) dd[y SUBSEP sprintf("%s-%02d",substr($1,1,7),dl[i]+0)]=1
            next
        }
        NF>=4 {
            s=$3+0; if(s<=0) next
            y=substr($1,1,4); ys[y]+=s; tot+=s
            dd[y SUBSEP $1]=1
        }
        END{
            printf "total\t%d\n", tot
            for(y in ys){
                n=0
                for(k in dd){ split(k,a,SUBSEP); if(a[1]==y) n++ }
                printf "%s\t%d\t%d\n", y, ys[y], n
            }
        }' "$1" 2>/dev/null | sort
}
archive_old_rows() {
    [ -f "$DATA" ] || return 0
    _a_cut=$(awk -v today="$TS" '
        function jd(y,m,d,   a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
        # days-from-civil 逆运算（Hinnant civil_from_days），只取 YYYY-MM
        # jd() 产出完整儒略日数（纪元 -4713-11-24）；civil_from_days 期望距 1970-01-01 天数，
        #   两者相差 2440588-719468=1721120，故 z-=1721120（误写 z+=719468 会算出 8708 年 → 全量误折叠）
        function cfd_ym(z,   era,doe,yoe,y,doy,mp,m){
            z-=1721120
            era=int((z>=0?z:z-146096)/146097)
            doe=z-era*146097
            yoe=int((doe-int(doe/1460)+int(doe/36524)-int(doe/146096))/365)
            y=yoe+era*400
            doy=doe-(365*yoe+int(yoe/4)-int(yoe/100))
            mp=int((5*doy+2)/153)
            m=mp+(mp<10?3:-9)
            if(m<=2) y++
            return sprintf("%04d-%02d", y, m)
        }
        BEGIN{ split(today,t,"-"); print cfd_ym(jd(t[1]+0,t[2]+0,t[3]+0)-90) }')
    [ -n "$_a_cut" ] || return 0
    _a_done=$(cat "$ARCHIVE_MARK" 2>/dev/null)
    [ "$_a_done" = "$_a_cut" ] && return 0
    case "$_a_done" in FAIL-*) return 0 ;; esac

    _a_fold="$DATA.fold.tmp"; _a_keep="$DATA.keep.tmp"; _a_hdr="$DATA.hdr.tmp"; _a_new="$DATA.new.tmp"
    LC_ALL=C awk -F'\t' -v cut="$_a_cut" -v keepf="$_a_keep" -v hdrf="$_a_hdr" '
        NR==1 && $1=="date" { print > hdrf; next }
        NF<4  { print > keepf; next }
        NF>=7 { print > keepf; next }
        $3+0<=0 { print > keepf; next }
        {
            ym=substr($1,1,7)
            if(ym>=cut){ print > keepf; next }
            k=ym SUBSEP $2
            secs[k]+=$3+0
            if($4!="") ttl[k]=$4
            if(!(k in ldate) || $1>=ldate[k]){
                ldate[k]=$1; bid[k]=$2
                st[k]=$5; pr[k]=$6
            }
            d=substr($1,9,2)+0
            if(d>=1&&d<=31) dset[k,d]=1
        }
        END{
            for(k in ldate){
                list=""
                for(i=1;i<=31;i++) if((k,i) in dset) list=list (list==""?"":",") i
                printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\n", ldate[k], bid[k], secs[k], ttl[k], st[k], pr[k], list
            }
        }' "$DATA" | sort -t"$TAB" -k1,1 > "$_a_fold"

    if [ ! -s "$_a_fold" ]; then
        echo "$_a_cut" > "$ARCHIVE_MARK" 2>/dev/null
        rm -f "$_a_fold" "$_a_keep" "$_a_hdr"
        echo "$(date): archive: cut=$_a_cut 无超龄行，仅落标记跳过" >> "$ARCHIVE_ULOG" 2>/dev/null || true
        return 0
    fi

    cat "$_a_hdr" "$_a_fold" "$_a_keep" > "$_a_new"

    _a_v0=$(archive_verify "$DATA")
    _a_v1=$(archive_verify "$_a_new")
    if [ "$_a_v0" = "$_a_v1" ]; then
        _a_bak="$DATA.bak-$(date +%Y%m%d-%H%M%S)"
        cp "$DATA" "$_a_bak" 2>/dev/null
        mv "$_a_new" "$DATA"
        echo "$_a_cut" > "$ARCHIVE_MARK" 2>/dev/null
        _a_old_n=$(wc -l < "$_a_bak" 2>/dev/null | tr -d ' ')
        _a_new_n=$(wc -l < "$DATA" 2>/dev/null | tr -d ' ')
        {
            echo "$(date): archive OK cut=$_a_cut 行数 ${_a_old_n}→${_a_new_n}（备份 $(basename "$_a_bak" 2>/dev/null)）"
            echo "—— 校验明细（折叠前后逐项全等才放行；列：年份/总秒/天数）——"
            echo "$_a_v0"
        } >> "$ARCHIVE_ULOG" 2>/dev/null || true
    else
        rm -f "$_a_new"
        echo "FAIL-$_a_cut" > "$ARCHIVE_MARK" 2>/dev/null
        {
            echo "$(date): archive FAIL cut=$_a_cut 已回滚（before≠after），归档已停手；删 .archive_done 可重试"
            echo "--- before ---"; echo "$_a_v0"
            echo "--- after ---";  echo "$_a_v1"
        } >> "$ARCHIVE_ULOG" 2>/dev/null || true
        lipc-set-prop com.lab126.system toasterMessage "归档自检失败已回滚，见LOG-archive.log" >/dev/null 2>&1 || true
    fi
    rm -f "$_a_fold" "$_a_keep" "$_a_hdr"
}
archive_old_rows

# 进度回填（v13.1 R27 补回旧版机制）：从 Kindle 系统库 cc.db 读每本书真实进度，
# 回填 tsv 的 status/progress 字段（旧 4 列 tsv 或 progress 缺失时兜底）。
CC_DB="/var/local/cc.db"
PROGRESS_CACHE="$BASE/.progress_cache"
backfill_progress() {
    [ -r "$CC_DB" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
    # v2.4.0：跳过缓存——明细行数与 cc.db(mtime+size) 均未变时，回填结果与上次逐字节相同，直接跳过全量重写。
    #   阅读会使 cc.db mtime 变化 → 每个阅读日首开面板仍会重跑一次；归档改变行数 → 同样触发。
    BF_KEY="$BASE/.backfill_key"
    _bf_now=$(wc -l < "$DATA" 2>/dev/null | tr -d ' ')
    _bf_cc=$(stat -c '%Y %s' "$CC_DB" 2>/dev/null || stat -f '%m %z' "$CC_DB" 2>/dev/null)
    _bf_key="${_bf_now}|${_bf_cc}"
    if [ -f "$BF_KEY" ] && [ "$(cat "$BF_KEY" 2>/dev/null)" = "$_bf_key" ]; then
        return 0
    fi
    rm -f "$PROGRESS_CACHE"
    sqlite3 -readonly -separator "$TAB" "$CC_DB" \
        "SELECT replace(replace(p_titles_0_nominal,char(9),' '),char(10),' '), CAST(p_percentFinished+0.5 AS INTEGER) FROM Entries WHERE p_titles_0_nominal IS NOT NULL AND p_percentFinished>=0 AND p_percentFinished<=100;" \
        > "$PROGRESS_CACHE" 2>/dev/null || return 0
    [ -s "$PROGRESS_CACHE" ] || return 0
    awk -F"$TAB" -v map="$PROGRESS_CACHE" '
    BEGIN{ while((getline line < map)>0){ n=split(line,a,"\t"); if(a[2]!="") pct[a[1]]=a[2] } close(map) }
    NR==1 && $1=="date" { print; next }
    {
        extra=""
        if(NF>=7){ t=$4; prog=$6; st=$5; extra=sprintf("%c",9) $7 }   # v2.4.0：归档行日清单透传
        else if(NF>=6){ t=$4; prog=$6; st=$5 }
        else if(NF>=4){ t=$4; prog=""; st="" }
        else { print; next }
        np=pct[t]; if(np!=""){ prog=np }
        if(prog=="") prog=0; if(prog!~/^[0-9]+$/) prog=0
        st=(prog+0>=100)?"finished":"reading"
        printf "%s\t%s\t%s\t%s\t%s\t%s%s\n", $1,$2,$3,t,st,prog,extra
    }' "$DATA" > "$DATA.tmp" && mv "$DATA.tmp" "$DATA"
    rm -f "$PROGRESS_CACHE"
    echo "$_bf_key" > "$BF_KEY" 2>/dev/null
}
backfill_progress

# DIAG（写 launch.log）：定位"数据全0"根因——daemon 是否在跑 + lipc 属性真实值 + tsv 行数
echo "$(date): DIAG daemon_pid=[$(pgrep -f native-reading-time-daemon 2>/dev/null | tr '\n' ' ')]"
echo "$(date): DIAG activeApp=[$(lipc-get-prop com.lab126.appmgrd activeApp 2>/dev/null)]"
echo "$(date): DIAG powerd_state=[$(lipc-get-prop com.lab126.powerd state 2>/dev/null)]"
echo "$(date): DIAG tsv_lines=[$(wc -l < "$DATA" 2>/dev/null)]"

# v2.3.32：全局毫秒打点（dashboard 先于 render_ranking 渲染，_tm 必须全局可用；render_ranking 内同值重定义无害）
PERF_LOG="$BASE/rank-debug.log"
# v2.3.33：_tm/_csec 改 shell 内建读 /proc/uptime（原每次 fork awk；一页 ~30 次打点 fork 全灭）。
#   输出格式与旧版一致（秒.厘秒 / 厘秒整数），rank-debug.log 可比照历轮数据。
#   ★_nowcs 直接赋值 CSEC（无 $() 子 shell）；_f 前补 1 防前导零被当八进制（busybox ash $((08)) 报错）。
_tm() { read -r _u _i < /proc/uptime 2>/dev/null && echo "  [perf $_u] $1" >> "$PERF_LOG" 2>/dev/null; }
_nowcs() { read -r _u _i < /proc/uptime 2>/dev/null || { CSEC=0; return; }; _w=${_u%.*}; _f=${_u#*.}; CSEC=$(( _w * 100 + 1${_f:-00} - 100 )); }

# v13.1 R34：把「计算 + 渲染」函数化，支持年份切换后按新 hyear 重算四卡并重绘整页。
# 注意：函数体顶格书写（不缩进），保证 heredoc 结束标记 PY 与 awk 脚本保持在行首。
render_dashboard() {
_tm dashboard_start
# v2.4.0：当日结果缓存——key=选中年份|明细行数|日期。阅读中每 90s 追加行 → 行数变 → 自动失效；
#   归档/回填改变行数同样触发；切年 key 含年份互不污染。命中则跳过整遍 calc 全扫。
CALC_CACHE="$BASE/.calc_cache"
_calc_n=$(wc -l < "$DATA" 2>/dev/null | tr -d ' ')
_calc_key="${hyear}|${_calc_n}|${TS}"
if [ -f "$CALC_CACHE" ] && [ "$(sed -n '1{s/^#K|//;p;q}' "$CALC_CACHE" 2>/dev/null)" = "$_calc_key" ]; then
    calc=$(sed -n '2p' "$CALC_CACHE" 2>/dev/null)
else
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
            # v2.4.0：归档行（len>=7，第 7 列=当月阅读日清单）展开 → 天数/streak 逐日精确
            fdays = None
            if len(p) >= 7 and p[6]:
                fdays = []
                for x in p[6].split(','):
                    x = x.strip()
                    if x.isdigit(): fdays.append(f"{dt[:7]}-{int(x):02d}")
            if fdays: read_set.update(fdays)
            else: read_set.add(dt)
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
                if fdays: days_set.update(fdays)
                else: days_set.add(dt)
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
}
{
    if(NR==1 && $1=="date") next
    if(NF<4) next
    dstr=$1; sec=$3+0
    if(sec<=0) next
    bid=$2; prog=0; st="reading"
    if(NF>=6){ prog=$6+0; st=$5 }
    isfin=(prog>=100 || st=="finished")
    n2=split(dstr, dd, "-"); dy=dd[1]+0; dm=dd[2]+0; ddj=dd[3]+0
    d_jd=jd(dy,dm,ddj)
    # v2.4.0：归档行（NF>=7）展开当月阅读日清单 → 天数/streak 逐日精确还原
    ndl=0
    if(NF>=7 && $7!="") ndl=split($7, dlist, ",")
    if(dstr==today) sec_today+=sec
    if(d_jd>=ws_jd && d_jd<=we_jd && d_jd<=today_jd){
        sec_week+=sec
        idx=d_jd-ws_jd
        if(idx>=0 && idx<=6) sec7[idx]+=sec
    }
    if(substr(dstr,1,7)==month_ym) sec_month+=sec
    if(substr(dstr,1,4)==year){
        sec_year+=sec
        if(ndl>0){
            for(di=1;di<=ndl;di++){
                fday=sprintf("%s-%02d", substr(dstr,1,7), dlist[di]+0)
                if(!(fday in seen_day)){ seen_day[fday]=1; days_year++ }
            }
        } else if(!(dstr in seen_day)){ seen_day[dstr]=1; days_year++ }
        if(isfin){ if(!(bid in fin_seen)){ fin_seen[bid]=1; fb++ } }
        else { if(!(bid in rb_seen)){ rb_seen[bid]=1; rb++ } }
    }
    # v2.4.0：streak 改 hash 直查（旧版 read_jd 数组+嵌套线性扫 O(连续天数×阅读天数)）
    read_jd_set[d_jd]=1
    for(di=1;di<=ndl;di++) read_jd_set[jd(dy,dm,dlist[di]+0)]=1
}
END {
    streak=0
    if(today_jd in read_jd_set) cur=today_jd; else cur=today_jd-1
    while((cur) in read_jd_set){ streak++; cur-- }
    avg=(tdd>0) ? int(sec_month/tdd) : 0
    sec7str=""
    for(i=0;i<7;i++){ if(i>0) sec7str=sec7str ","; sec7str=sec7str sec7[i] }
    # R39: 末尾新增 sec_month（本月累计秒数 = 本月时长）
    printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\n", sec_today, sec_week, avg, streak, sec_year, days_year, rb, fb, sec_week, sec7str, dow, sec_month
}
' "$DATA")
fi
    { echo "#K|$_calc_key"; printf '%s\n' "$calc"; } > "$CALC_CACHE" 2>/dev/null || true
fi

# v2.3.33：12×echo|awk → IFS tab set -- 一次拆完（calc 12 字段恒非空：数字/逗号串，无空字段合并风险）
_oifs=$IFS; IFS=$TAB; set -- $calc; IFS=$_oifs
TODAY_S=$1; WEEK_S=$2; AVG_S=$3; STREAK_N=$4; MSEC=$5; YEAR_DAYS=$6
YEAR_RB=$7; YEAR_FB=$8; TOTAL_WEEK=$9; SEC7=${10}; DOW=${11}; MONTH_TOTAL=${12}

# 格式化（无单位）：时间用 HH:MM，数字直接
# v2.3.33：纯内建算术（原每次 fork awk；赋值 FMT_HM 免 $() 子 shell）。输出与旧版 "%dh%dm" 逐字节一致。
fmt_hm() {
    _s=$(($1 + 0))
    FMT_HM="$((_s / 3600))h$((_s % 3600 / 60))m"
}

fmt_hm "$TODAY_S"; TODAY_STR=$FMT_HM
fmt_hm "$WEEK_S"; WEEK_STR=$FMT_HM
fmt_hm "$AVG_S"; AVG_STR=$FMT_HM
STREAK_STR="${STREAK_N}天"   # R46: 连续阅读→连续天，值加"天"后缀
fmt_hm "$MSEC"; MSEC_STR=$FMT_HM
fmt_hm "$TOTAL_WEEK"; TW_STR=$FMT_HM
fmt_hm "$MONTH_TOTAL"; MONTH_TOTAL_STR=$FMT_HM   # R39: 本月时长

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
        # v2.4.2: 推图(-b 不刷)与提交分离，提交走 commit_screen 计数制 flash（与 SLOW 路径同模式）
        "$FBINK" -q -b -g "file=$PNG_TMP" 2>>"$FBINK_LOG" || { restore_system_ui; rm -f "$PNG_TMP"; fail "fbink push failed"; }
        commit_screen
        restore_system_ui
        rm -f "$PNG_TMP"
        _tm dashboard_end
        return 0
    fi
    rm -f "$PNG_TMP"
    echo "$(date): fast path compose failed; falling back"
fi

# === SLOW path ===
echo "$(date): fast path OFF python=$FAST_PY"

# 1. 推背景（R48: 加 -b 只写 framebuffer 不刷屏，避免先闪一次空背景；统一到最后一次 commit 刷新，消除"闪2次"）
collapse_system_ui
"$FBINK" -q -b -g "file=$BASE_BG" 2>>"$FBINK_LOG" || { restore_system_ui; fail "bg push failed"; }
_tm dashboard_bg

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

# v2.3.33：SEC7 求和/遍历改 IFS 逗号 set --（原 tr+awk 每轮 4 fork）
_oifs=$IFS; IFS=','; set -- $SEC7; IFS=$_oifs
TW_S=0
for _sv in "$@"; do TW_S=$((TW_S + _sv + 0)); done
# 条件渲染：周总时长 > 0 才画柱 + 合计
if [ "$TW_S" -gt 0 ] 2>/dev/null; then
    i=0
    for s in "$@"; do
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
        # 不再画白底矩形（按需求"不需要背景图底色"，水印(218,218,218)很浅不影响阅读）
        fmt_hm "$s"; lbl=$FMT_HM
        lbl_cx=$((x + sq / 2))
        lbl_w=$((${#lbl} * 14))
        half=$((lbl_w / 2))
        # 24pt 文字居中于 lbl_cx（top=bar_top-30，bottom=bar_top-6 留 6px padding）
        fb_text_at 24 $((bar_top - 30)) $((lbl_cx - half)) $((LOGICAL_W - lbl_cx - half)) BOLD BLACK - "$lbl"
        i=$((i+1))
    done
fi
# R45：已移除"合计"（已确认不需要展示；原 right=$((W-60))=1212 致绘制区反向本就不显示）

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

# 8. 年份切换胶囊（v2.3.7：‹ › 箭头已画在 dashboard_bg.png 底图，左格/右格居中对齐）
# v2.3.14：年份数字太小 → 20pt 放大到 40pt（放大一倍）
# v2.3.18：回退 v2.3.17 的胶囊整体居中；保持底图原 [820,1190] 三段位置；launcher 只画中段年份，视觉居中到中段中央 x=1005
# v2.3.20：从真机截图像素探测：胶囊中段字符实际 vp_x 中心 ≈993（image x=905×1.0966），比 launcher 期望 1005 偏左 12 vp_px；
#          把中段绘制区左移 12：box_left=918, box_right=1068 → center vp_x=993
# v2.3.32：从真机截图复探：实测字符 vp_x 中心 ≈1004，vp_y 中心 ≈1596（相比胶囊几何中心 1585 偏下 11 vp_px）；
#          ★ fbink 内部对 vp_x 不可消除地偏右 +11 vp_px，把 box_center 校准到 1004（box_left=929, box_right=1079）；
#          ★ fbink -t 的 top 偏下 12 vp_px（实测 book1 时长顶 vp_y=270 vs launcher top=262），把 launcher top 从 1576 上移到 1564 → 实测字 vp_y 中心 ≈1585
fb_text_center 40 1564 929 1079 BOLD BLACK "$hyear"

# 8.5 v2.3.2 tab 完整画在 dashboard_bg.png（图标 + 黑底/白底 + 文字）
# 当前在 dashboard 页 → 「指标」选中态（generate_bg.py 已画）；launcher 不再实时覆盖

# 9. commit（v2.4.2：改走 commit_screen 计数制 flash——每次必闪降为每 FLASH_EVERY 次一闪，
#    兼顾手感与残影清理。历史背景：R48 去 flash 后 GC16 无黑闪清屏 → 切页残影累积发糊（实测：
#    首入清晰、切排行后渐糊）。FBInk 作者 NiLuJe：顽固机型（KPW6 即此类）必须 -f 才真正清残影。
#    R48 当年"闪2次"是 FAST 路径两条独立刷新命令叠加所致，与单命令 -f -W GC16 -s 无关——
#    单命令 = 一次黑闪全刷，即 Kindle 翻页标准全刷。）
commit_screen
restore_system_ui
_tm dashboard_end
}

# ============================================================
# v2.3：render_ranking —— 阅读排行页（跨年汇总，与 dashboard 按年分离）
# 8 项指标：封面 / 书名 / 作者 / 开始阅读 / 最近阅读 / 进度 / 时长 / 日均
# 6 本/页，可按时长/日均排序，可翻页
# ============================================================
render_ranking() {
    # v2.3.10：排行页调试日志（真机打开一次排行页即可 USB 取回 /mnt/us/reading-time/rank-debug.log）
    RANK_DEBUG="$BASE/rank-debug.log"
    # v2.3.32：缓存/调试开关（slow path 数据层定义同值，python 快路径共用渲染段时也须可用）
    DBG_FLAG="$BASE/.rank-debug.flag"
    RANK_CACHE="$BASE/.rank_all.tsv"
    CC_ALL="$BASE/.cc_all.tsv"
    COVER_MAP="$BASE/.cover_map.tsv"   # v2.3.32：封面源还原 v2.3.23（MISS 生成，HIT 复用）
    UUID_MAP="$BASE/.uuid_map.tsv"
    _dbg() { [ -f "$DBG_FLAG" ] && { echo "$1" >> "$RANK_DEBUG" 2>/dev/null; } || true; }
    # v2.3.32：无条件毫秒打点（/proc/uptime 浮点秒；共 6 点）。
    #   输出到 rank-debug.log：测速后拷回，一次看清 数据层 vs 底图 vs 行渲染 各占多少。
    # v2.3.33：改用全局内建 _tm（read < /proc/uptime，零 fork；格式不变）。
    PERF_LOG="$BASE/rank-debug.log"
    _tm rank_start
    RANK_BG="$UI_DIR/ranking_bg.png"
    [ -f "$RANK_BG" ] || fail "ranking_bg.png missing"

    # ---- 1. 数据计算（python3 heredoc；无 python3 退 awk 兜底） ----
    if [ -n "$PY3" ]; then
        RANK_OUT=$("$PY3" - "$DATA" "$BASE/book-meta.tsv" "/var/local/cc.db" "$RANK_SORT" "$RANK_OFFSET" "$TS" 2>>"$FBINK_LOG" <<'PY'
import sys, sqlite3, os
from datetime import date, datetime
data_path, meta_path, cc_db_path, sort_mode, offset_s, today = sys.argv[1:7]
offset = int(offset_s)

dur = {}
title_by_bid = {}
fd_bid = {}   # v2.3.32：bid -> tsv 最早阅读日（同名归并的开始日期权威）
with open(data_path,'r',encoding='utf-8',errors='replace') as f:
    f.readline()
    for line in f:
        # v2.4.0：rstrip() 会连尾部 TAB 一起剥掉 → 老 4 列空书名行被误收成 3 字段遭 len<4 丢弃
        #   （与 awk 口径不一致、折叠前后总量对不上）；只剥换行，保留尾部空字段
        p = line.rstrip('\r\n').split('\t')
        if len(p) < 4: continue
        bid = p[1]
        try: sec = int(float(p[2]))
        except: continue
        if sec <= 0: continue
        dur[bid] = dur.get(bid, 0) + sec
        # v2.3.32：bid 级有效书名 = 首个非空（daemon 偶发记空书名行；取首非空后空行自动归队，不再被拆成伪书）
        if bid not in title_by_bid:
            _t0 = (p[3] or '').strip() if len(p) > 3 else ''
            if _t0:
                title_by_bid[bid] = _t0
        d10 = p[0].strip()[:10]
        # v2.4.0：归档行 date=当月最后阅读日 → 开始日期取日清单最小日
        fd_c = d10
        if len(p) >= 7 and p[6]:
            try:
                md = min(int(x) for x in p[6].split(',') if x.strip())
                if 1 <= md <= 31: fd_c = f"{p[0][:7]}-{md:02d}"
            except Exception:
                fd_c = d10
        if len(fd_c) == 10 and (bid not in fd_bid or fd_c < fd_bid[bid]):
            fd_bid[bid] = fd_c

first_open = {}
if os.path.exists(meta_path):
    with open(meta_path,'r',encoding='utf-8',errors='replace') as f:
        f.readline()
        for line in f:
            p = line.rstrip().split('\t')
            if len(p) < 2: continue
            try: first_open[p[0]] = int(p[1])
            except: continue

author_by_bid = {}
pct_by_bid = {}
last_access_by_bid = {}
asin_by_bid = {}
if os.path.exists(cc_db_path):
    # v2.3.20：作者真名权威来源 = j_credits 内 name.display（readinglog 实证结构
    # [{"name":{"display":"真名","collation":"…","language":"…"},"kind":"Author"}]），
    # 非 collation 排序串（那会显示成拼音）。SQL 增加 j_credits 列，json 递归取 display。
    import json as _json
    def _author_display(jcred, coll):
        jj = (jcred or '').strip()
        if jj:
            try:
                def _dig(o):
                    if isinstance(o, dict):
                        if isinstance(o.get('display'), str) and o['display'].strip():
                            return o['display'].strip()
                        for v in o.values():
                            r = _dig(v)
                            if r: return r
                    elif isinstance(o, list):
                        for v in o:
                            r = _dig(v)
                            if r: return r
                    return ''
                r = _dig(_json.loads(jj))
                if r: return r
            except Exception:
                pass
        # collation 去 padding：ASCII 开头原样；非 ASCII 开头剥去连续重复>=3 前缀（阿阿阿…）
        c = (coll or '').strip()
        if c and not (c[0].isascii() and c[0].isalnum()):
            i = 0
            while i < len(c) and c[i] == c[0]: i += 1
            if i >= 3: c = c[i:]
        return c
    try:
        con = sqlite3.connect(f'file:{cc_db_path}?mode=ro', uri=True)
        cur = con.cursor()
        cur.execute("SELECT cdeKey, coalesce(p_titles_0_nominal,''), coalesce(p_credits_0_name_collation,''), coalesce(j_credits,''), coalesce(p_percentFinished,0), coalesce(p_lastAccess,0) FROM Entries WHERE cdeKey IS NOT NULL")
        for cdeKey, t, a, jcred, pct, la in cur.fetchall():
            if cdeKey in dur:
                author_by_bid[cdeKey] = _author_display(jcred, a).replace('\t',' ').replace('\n',' ').strip()
                pct_by_bid[cdeKey] = int((pct or 0) + 0.5)
                last_access_by_bid[cdeKey] = int(la or 0)
                asin_by_bid[cdeKey] = cdeKey
        con.close()
    except Exception as e:
        sys.stderr.write(f"cc.db read failed: {e}\n")

today_d = date.fromisoformat(today)
today_ts = int(datetime(today_d.year, today_d.month, today_d.day).timestamp())

# v2.3.32：同名书归并 —— 删书重装后 Kindle 会给同一本书换新 key（旁载/推送的书 key 是随机 UUID），
#   tsv 里旧 key 的历史行没被清 → 排行出现「同名两行、时长分家」。现改为按「书名」聚合：
#   时长相加；代表 bid = 最近访问(last_access)最大者（= 当前在读书，作者/进度/封面随它取）；
#   开始日期取同名最早 first_open（日均分母从真正首读日算起）；空书名退 bid 防误并。
D = {}   # tkey -> [secs, rep_bid, fo_min, la_max]
for bid, secs in dur.items():
    tk = (title_by_bid.get(bid,'') or '').strip()
    if not tk:
        tk = bid
    la = last_access_by_bid.get(bid, 0)
    # v2.3.32：开始日期 = tsv 最早阅读日(fd_bid，同名归并权威，跨 key 取最早) → meta first_open → la → 今天
    fo = 0
    if bid in fd_bid:
        try: fo = int(datetime.fromisoformat(fd_bid[bid]).timestamp())
        except Exception: fo = 0
    if fo == 0: fo = first_open.get(bid, 0)
    if fo == 0: fo = la
    if fo == 0: fo = today_ts
    if tk not in D:
        D[tk] = [0, bid, fo, la]
    e = D[tk]
    e[0] += secs
    if la > e[3]:
        e[1] = bid; e[3] = la
    if fo < e[2]:
        e[2] = fo

records = []
for tk, (secs, rep, fo, la) in D.items():
    t = (title_by_bid.get(rep,'') or '').strip()
    if not t: t = tk
    # v2.3.7：书名最多展示 15 字符，超出加省略号（避免超长书名如 fastmetrics_*.txt 占满整行）
    if len(t) > 15:
        t = t[:15] + '…'
    a = author_by_bid.get(rep,'').strip()
    asin = asin_by_bid.get(rep,'').strip()
    pct = pct_by_bid.get(rep, 0)
    try:
        fo_d = datetime.fromtimestamp(fo).date()
        days = max(1, (today_d - fo_d).days + 1)
    except Exception:
        days = 1
    daily = secs // days
    records.append((rep, t, a, asin, fo, la, pct, secs, daily))

# v2.4.0：并列时加确定性强键（时长→日均→书名字典序）——归档改变行序后名次仍逐位不变
if sort_mode == 'daily':
    records.sort(key=lambda r: (-r[8], -r[7], r[1]))
else:
    records.sort(key=lambda r: (-r[7], -r[8], r[1]))

page_records = records[offset*6 : offset*6 + 6]
total = len(records)

# v2.3.32：python 快路径同样补 12 字段（f11=时长文本恒带 h "0h 17m"；f12=日均文本 h>0 才带 h）
def _hh(x, sp):
    h, m = divmod(int(x), 3600); m = m // 60
    if sp: return f"{h}h {m}m"
    return f"{h}h{m}m" if h > 0 else f"{m}m"
for i, r in enumerate(page_records, 1):
    try: fo_iso = datetime.fromtimestamp(r[4]).strftime('%Y-%m-%d')
    except: fo_iso = ''
    try: la_iso = datetime.fromtimestamp(r[5]).strftime('%Y-%m-%d')
    except: la_iso = ''
    _a = r[2] if (r[2] or '').strip() else '-'   # v2.3.32 空作者占位，防渲染 tab 分词错位
    print('\t'.join([str(i), r[0], r[1], _a, r[3], fo_iso, la_iso, str(r[6]), str(r[7]), str(r[8]), _hh(r[7], True), _hh(r[8], False)]))

print(f"__RANK_TOTAL__\t{total}")
PY
)
        RANK_TOTAL=$(printf '%s\n' "$RANK_OUT" | awk -F'\t' '/^__RANK_TOTAL__/{print $2}')
        RANK_LINES=$(printf '%s\n' "$RANK_OUT" | grep -v '^__RANK_TOTAL__')
        RANK_TOTAL=${RANK_TOTAL:-0}
    else
        # ===== 无 python3 兜底（真机路径！KPW6 无 python3，必走这里）=====
        # v2.3.10 彻底重写（三次反馈「字段不显示」）：
        #   旧版把 作者/开始日期/最近日期/进度 全押在 cc.db + book-meta.tsv 上，
        #   只要 sqlite3 不可用、cc.db 查不到、或 book-meta.tsv 尚未生成 → 这些字段全空且无报错。
        #   新版「数据自给自足」：
        #     · 开始/最近阅读日期 + 进度 → 直接由 reading-time.tsv 算（该文件本身有 date 与 progress 列）
        #     · book-meta.tsv 存在时，优先用其 first_open 作为开始日期
        #     · cc.db 只补「作者」（唯一来源；取不到就留空，不影响其余字段）
        #   全流程中间结果写 $BASE/rank-debug.log，真机打开一次排行页即可取回排障。
        # v2.3.32：DBG_FLAG / RANK_CACHE / CC_ALL / _dbg 已统一定义在函数头（python 快路径共用渲染段）
        _t0=$(date +%s)
        # ---- v2.3.24 缓存 key：数据源任何变化（tsv/meta/cc.db 增删改、跨天、排序方式）→ 自动重建 ----
        _tsv_n=$(wc -l < "$DATA" 2>/dev/null | tr -d ' ')
        _meta_n=$(wc -l < "$BASE/book-meta.tsv" 2>/dev/null | tr -d ' ')
        # v2.3.32：cc.db 失效信号改用【文件大小】而非 mtime！Kindle 系统读屏/翻页时持续
        #   UPDATE cc.db（进度/最近访问）→ mtime 每页都变 → 旧 key(mtime) 永不命中 → 缓存每页重建白优化。
        #   增删书会增删条目页 → 大小变 → 触发重建；进度更新只改写既有页内容 → 大小不变 → 翻页稳定命中。
        _cc_sz=$(wc -c < /var/local/cc.db 2>/dev/null | tr -d ' ')
        [ -z "$_cc_sz" ] && _cc_sz=0
        # v2.3.32：缓存格式版本 2（空字段占位）——旧版缓存（无占位）key 不匹配 → 自动重建，防渲染错位
        _key="v2|$RANK_SORT|$_tsv_n|$_meta_n|$_cc_sz|$TS"
        _hit=0
        # v2.3.32：HIT 需聚合缓存 + 作者缓存 + 两张封面映射齐全，任一缺失 → MISS 重建
        if [ -f "$RANK_CACHE" ] && [ -f "$CC_ALL" ] && [ -f "$COVER_MAP" ] && [ -f "$UUID_MAP" ]; then
            _h1=$(head -1 "$RANK_CACHE" 2>/dev/null)
            if [ "$_h1" = "#K|$_key" ]; then _hit=1; fi
        fi
        if [ "$_hit" = "1" ]; then
            # ===== 缓存命中：零 sqlite3 / 零 tsv 全扫，仅从缓存截取本页（含时长/日均文本列） =====
            RANK_LINES=$(LC_ALL=C awk -F'\t' -v s=$((RANK_OFFSET * 6 + 2)) '
                # v2.3.32：页截取 = 逐列展开 + 空字段占位（兼容 v2.3.27 前无占位旧缓存，防 tab 分词错位→封面/字段错乱）
                function hhmm(x, sp,   h, m, r) { h = int(x/3600); m = int((x%3600)/60)
                    if (sp == 1) r = sprintf("%dh %dm", h, m)
                    else if (h > 0) r = sprintf("%dh%dm", h, m)
                    else r = sprintf("%dm", m)
                    return r }
                NR >= s && NR <= s + 5 && NF >= 9 {
                    nf = split($0, F, "\t")
                    if (F[3] == "") F[3] = "-"
                    if (F[6] == "") F[6] = "-"
                    printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", NR - s + 1, F[1], F[2], F[3], F[4], F[5], F[6], F[7], F[8], F[9], hhmm(F[8] + 0, 1), hhmm(F[9] + 0, 0)
                }' "$RANK_CACHE")
            RANK_TOTAL=$(awk -F'\t' '/^__RANK_TOTAL__/{print $2; exit}' "$RANK_CACHE")
            RANK_TOTAL=${RANK_TOTAL:-0}
            echo "  [v2.3.29] cache=HIT key=$_key 本页行数=$(printf '%s\n' "$RANK_LINES" | grep -c . )" >> "$RANK_DEBUG"
        else
        # ===== 缓存失效/首次：全量重建（sqlite3 dump + awk 全扫一次）=====
        rm -f "$CC_ALL" "$RANK_CACHE" "$COVER_MAP" "$UUID_MAP"
        echo "  [v2.3.32] cache=MISS/build key=$_key" >> "$RANK_DEBUG"
        _dbg "  RANK_SORT=$RANK_SORT RANK_OFFSET=$RANK_OFFSET TS=$TS"
        _dbg "  DATA=$DATA 存在=$([ -f "$DATA" ] && echo Y || echo N) 行数=$_tsv_n"
        _dbg "  META 存在=$([ -f "$BASE/book-meta.tsv" ] && echo Y || echo N) 行数=$_meta_n"
        _dbg "  cc.db 存在=$([ -f /var/local/cc.db ] && echo Y || echo N) 可读=$([ -r /var/local/cc.db ] && echo Y || echo N)"
        _dbg "  sqlite3=$(command -v sqlite3 2>/dev/null || echo NOT_FOUND)"
        _dbg "  FONT: RFONT=$RFONT (存在=$([ -f "$RFONT" ] && echo Y || echo N))  BFONT=$BFONT (存在=$([ -f "$BFONT" ] && echo Y || echo N))"

        # v2.3.32：cc.db 单次 dump（1 次 sqlite3 进程）→ 6 列 .cc_all.tsv：
        #   key / 作者collation / 作者j_credits / 进度 / p_thumbnail / uuid
        #   主 awk 读前 4 列（作者+进度）；渲染封面读第 5/6 列（thumb/uuid）——v2.3.13 封面权威来源不变。
        #   列名先 PRAGMA 探测（不同固件 Entries 列名不同），再动态构造 SELECT。
        if command -v sqlite3 >/dev/null 2>&1 && [ -r "/var/local/cc.db" ]; then
            COLS=$(sqlite3 "/var/local/cc.db" "PRAGMA table_info(Entries)" 2>/dev/null | awk -F'|' '{print $2}')
            CDE=$(printf '%s\n' "$COLS" | grep -ixE 'cdeKey|p_cdeKey|asin' | head -1)
            [ -z "$CDE" ] && CDE="cdeKey"
            AUTHOR_COL=$(printf '%s\n' "$COLS" | grep -ixE 'p_credits_0_name|p_credits_0_nominal|p_credits_0_name_display' | head -1)
            [ -z "$AUTHOR_COL" ] && AUTHOR_COL=$(printf '%s\n' "$COLS" | grep -ixE 'p_credits_0_name_collation|p_credits_0_name_sort' | head -1)
            [ -z "$AUTHOR_COL" ] && AUTHOR_COL=$(printf '%s\n' "$COLS" | grep -iE 'credit|author' | head -1)
            [ -z "$AUTHOR_COL" ] && AUTHOR_COL="p_credits_0_name_collation"
            JCREDITS=$(printf '%s\n' "$COLS" | grep -ixE 'j_credits' | head -1)
            [ -z "$JCREDITS" ] && JCREDITS="j_credits"
            PCT_COL=$(printf '%s\n' "$COLS" | grep -iE 'percentFinished|progress' | head -1)
            [ -z "$PCT_COL" ] && PCT_COL="p_percentFinished"
            THUMB_COL=$(printf '%s\n' "$COLS" | grep -iE 'thumbnail' | head -1)
            [ -z "$THUMB_COL" ] && THUMB_COL="p_thumbnail"
            UUID_COL=$(printf '%s\n' "$COLS" | grep -ixE 'p_uuid|p_guid|uuid' | head -1)
            [ -z "$UUID_COL" ] && UUID_COL="p_uuid"
            _dbg "  探测→ CDE=$CDE AUTHOR=$AUTHOR_COL JCREDITS=$JCREDITS PCT=$PCT_COL THUMB=$THUMB_COL UUID=$UUID_COL"
            # 6 列单次 dump（col 内 tab/换行清洗防破行）
            Q6="SELECT $CDE, coalesce(replace(replace(coalesce($AUTHOR_COL,''),char(9),' '),char(10),' '),''), coalesce(replace(replace(coalesce($JCREDITS,''),char(9),' '),char(10),' '),''), coalesce(CAST($PCT_COL+0.5 AS INTEGER),0), coalesce(replace(replace(coalesce($THUMB_COL,''),char(9),' '),char(10),' '),''), coalesce(replace(replace(coalesce($UUID_COL,''),char(9),' '),char(10),' '),'') FROM Entries WHERE $CDE IS NOT NULL"
            sqlite3 -readonly -separator "$TAB" "/var/local/cc.db" "$Q6" > "$CC_ALL" 2>/dev/null \
                || sqlite3 -separator "$TAB" "/var/local/cc.db" "$Q6" > "$CC_ALL" 2>/dev/null
            _dbg "  CC_ALL 行数=$(wc -l < "$CC_ALL" 2>/dev/null | tr -d ' ')"
            # v2.3.32：封面链路还原 v2.3.23 被真机验证的实现 —— 独立 COVER_MAP（归一化key→p_thumbnail）
            #   与 UUID_MAP（原样key→uuid），仅 MISS 重建时生成（翻页 0 sqlite）。key 归一化=去'-'+大写。
            COVER_MAP="$BASE/.cover_map.tsv"
            UUID_MAP="$BASE/.uuid_map.tsv"
            rm -f "$COVER_MAP" "$UUID_MAP"
            QC="SELECT upper(replace($CDE,'-','')), coalesce(replace(replace(coalesce($THUMB_COL,''),char(9),' '),char(10),' '),'') FROM Entries WHERE $CDE IS NOT NULL AND $THUMB_COL IS NOT NULL AND $THUMB_COL<>''"
            sqlite3 -readonly -separator "$TAB" "/var/local/cc.db" "$QC" > "$COVER_MAP" 2>/dev/null \
                || sqlite3 -separator "$TAB" "/var/local/cc.db" "$QC" > "$COVER_MAP" 2>/dev/null
            QU="SELECT $CDE, coalesce($UUID_COL,'') FROM Entries WHERE $CDE IS NOT NULL"
            sqlite3 -readonly -separator "$TAB" "/var/local/cc.db" "$QU" > "$UUID_MAP" 2>/dev/null \
                || sqlite3 -separator "$TAB" "/var/local/cc.db" "$QU" > "$UUID_MAP" 2>/dev/null
            _dbg "  COVER_MAP=$(wc -l < "$COVER_MAP" 2>/dev/null | tr -d ' ')行 UUID_MAP=$(wc -l < "$UUID_MAP" 2>/dev/null | tr -d ' ')行"
        else
            _dbg "  [!] sqlite3 或 cc.db 不可用 → 作者/封面为空（其余字段不受影响）"
            : > "$CC_ALL"
        fi

        # 数据全部来自 reading-time.tsv（date 在第 1 列、progress 在第 6 列）；
        # book-meta.tsv 仅作 first_open 的更优来源；cc.db 仅补作者。
        # LC_ALL=C：强制 awk 进入字节模式。BSD/gawk 在 UTF-8 locale 下对单字节正则范围
        # （如 /[\340-\357]/）会尝试 multibyte 转换并报 "towc: multibyte conversion failure" 直接中止；
        # busybox awk 本就是字节模式，加此前缀对真机无副作用，纯保险。
        LC_ALL=C awk -F"$TAB" -v meta="$BASE/book-meta.tsv" -v cc="$CC_ALL" -v df="$DATA" -v today="$TS" -v sort_mode="$RANK_SORT" '
            # v2.3.32：书名聚合前先按 bid 预扫（BEGIN 内 getline < df 建 title_of[bid]=该 bid 首个非空书名）。
            #   背景：daemon 偶发抓不到书名 → tsv 里同一 bid 混有「书名空」的行；v2.3.22 直接按「当行书名」聚合
            #   会把这类空行拆出同 bid 主体、退成 bid 串书名的伪书（如 7492B72DF78…）→ 排行多出看不懂的书。
            #   两阶段：① bid → 有效书名（首非空）② 有效书名 → 跨 bid 同名归并。空行不再被拆散。
            # v2.3.10：旧版按 45 字节截断，纯英文书名（如 fastmetrics_*.txt）会显示 45 个字符，远超需求的 15
            function trtitle(s,   out, i, c, cnt) {
                cnt = 0; i = 1
                while (i <= length(s)) {
                    c = substr(s, i, 1)
                    if (c ~ /[\360-\367]/) i += 4
                    else if (c ~ /[\340-\357]/) i += 3
                    else if (c ~ /[\300-\337]/) i += 2
                    else i += 1
                    cnt++
                }
                if (cnt <= 15) return s
                out = ""; i = 1; cnt = 0
                while (i <= length(s) && cnt < 15) {
                    c = substr(s, i, 1)
                    if (c ~ /[\360-\367]/) { out = out substr(s, i, 4); i += 4 }
                    else if (c ~ /[\340-\357]/) { out = out substr(s, i, 3); i += 3 }
                    else if (c ~ /[\300-\337]/) { out = out substr(s, i, 2); i += 2 }
                    else { out = out c; i += 1 }
                    cnt++
                }
                return out "..."
            }
            # YYYY-MM-DD → 天数序号（days-from-civil，Hinnant 算法；busybox awk 无 mktime/strftime）
            function dnum(s,   y, m, d, era, yoe, doy, doe) {
                if (length(s) < 10) return 0
                y = substr(s, 1, 4) + 0
                m = substr(s, 6, 2) + 0
                d = substr(s, 9, 2) + 0
                if (y < 1970 || m < 1 || m > 12 || d < 1 || d > 31) return 0
                if (m <= 2) y--
                era = int((y >= 0 ? y : y - 399) / 400)
                yoe = y - era * 400
                doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
                doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
                return era * 146097 + doe - 719468
            }
            # v2.3.20：作者解析重写 —— j_credits 真实结构被 readinglog-0.2.1（真机实证）fixture 揭示：
            #   [{"name":{"display":"爱潜水的乌贼","collation":"阿阿阿aiqianshuidewuzei","language":"zh"},"kind":"Author"}]
            #   ★ 作者真名在 name 对象内的 display 键！旧版只匹配 "name":"字符串"（name 后直接跟引号的旧式结构），
            #     对真实结构（name 后跟 {）匹配失败 → 回落到 collation → 显示成「阿阿阿+拼音」，即所见"作者变拼音"问题。
            #   现按三段取：① display 键（真名）→ ② 旧式 "name":"直接值" 兼容 → ③ collation 去 padding 兜底。
            function jval(j, key,    s, rest, v) {
                s = j
                gsub(/\\"/, sprintf("%c", 1), s)   # 防 \" 转义破坏取串
                if (match(s, "\"" key "\"[[:space:]]*:[[:space:]]*\"")) {
                    rest = substr(s, RSTART + RLENGTH)
                    if (match(rest, /"/)) {
                        v = substr(rest, 1, RSTART - 1)
                        gsub(sprintf("%c", 1), "\"", v)
                        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                        if (v != "" && v !~ /^[[:space:]]*$/) return v
                    }
                }
                return ""
            }
            # collation 去 padding（同 readinglog 的 unpadded）：ASCII 字母/数字开头（外文作者名）原样保留；
            # 非 ASCII 开头 → 若首「字符」连续重复 >=3（如"阿阿阿"，padding 字符）→ 剥掉该整字符前缀。
            # ★ busybox/BSD awk 为字节模式：首字符=3 字节，必须按 substr(1,len) 整字符单位比较，
            #   逐字节比较会把 阿(3B)/ぁ(3B) 拆散导致剥不掉（v2.3.20 自测抓到的回归，勿改回逐字节！）
            function unpadded(coll,    f, i, n, ch, len, s) {
                s = coll
                f = substr(s, 1, 1)
                if (f == "") return s
                if (f ~ /[A-Za-z0-9]/) return s          # ASCII 字母/数字开头 → 原样
                if (f ~ /[\360-\367]/) len = 4            # 4 字节字符（极罕见）
                else if (f ~ /[\340-\357]/) len = 3       # 3 字节（中文/日文假名/韩文）
                else if (f ~ /[\300-\337]/) len = 2       # 2 字节
                else len = 1
                ch = substr(s, 1, len)
                n = 0; i = 1
                while (i + len - 1 <= length(s) && substr(s, i, len) == ch) { n++; i += len }
                if (n >= 3) s = substr(s, i)
                return s
            }
            function short_author(jcred, coll,   v, s) {
                v = jval(jcred, "display")         # ① 真名（readinglog 实证主路径）
                if (v != "") return v
                v = jval(jcred, "name")            # ② 旧式简单结构 "name":"直接值"
                if (v != "") return v
                s = unpadded(coll)                 # ③ 排序键兜底（归属正确，极端情况才是拼音）
                if (s != "") return s
                return "(未知)"
            }
            BEGIN {
                # v2.3.32：预扫数据文件 → title_of[bid] = 该 bid 首个非空书名（含跳 header/短行/非正时长）
                if (df != "") {
                    while ((getline pre < df) > 0) {
                        split(pre, q, FS)
                        if (q[1] == "date") continue
                        if (length(q) < 4) continue
                        if (q[3] + 0 <= 0) continue
                        r = q[4]
                        gsub(/^[ \t]+|[ \t]+$/, "", r)
                        if (r != "" && !(q[2] in title_of)) title_of[q[2]] = r
                    }
                    close(df)
                }
                if (meta != "") {
                    while ((getline line < meta) > 0) {
                        split(line, a, "\t")
                        if (a[1] != "book_id" && a[1] != "" && a[3] != "") fo_iso[a[1]] = substr(a[3], 1, 10)
                    }
                    close(meta)
                }
                if (cc != "") {
                    while ((getline line < cc) > 0) {
                        split(line, a, "\t")
                        if (a[1] != "") { author[a[1]] = short_author(a[3], a[2]); cc_pct[a[1]] = a[4] + 0 }
                    }
                    close(cc)
                }
                today_num = dnum(today)
            }
            NR == 1 { next }
            NF < 4 { next }
            {
                sec = $3 + 0
                if (sec <= 0) next
                bid = $2
                # v2.3.32：书名 = bid 级有效书名（首非空，先按 bid 聚 → 同 bid 空书名行自动归队）；
                #   该 bid 全无书名时才退 bid（显示 key 串，属真实"无元数据"数据，非误拆）。
                # v2.3.32：同名书归并（删书重装换 key → 排行双行）→ 有效书名作聚合键；
                #   代表 bid = 最近阅读日期(ldT)最大者，其 作者/进度/封面(asin) 随代表；时长相加；日期取最早/最晚。
                title = (bid in title_of) ? title_of[bid] : $4
                gsub(/^[ \t]+|[ \t]+$/, "", title)
                if (title == "") title = bid
                durT[title] += sec
                if (!(title in shown)) shown[title] = title
                dt = substr($1, 1, 10)
                if (length(dt) == 10) {
                    # v2.4.0：归档行 date=当月最后阅读日 → 开始日期取日清单最小日，最近日期照旧取行 date
                    fdt_c = dt
                    if (NF >= 7 && $7 != "") {
                        ndl = split($7, dlist, ",")
                        md = 32
                        for (di = 1; di <= ndl; di++) { dv = dlist[di] + 0; if (dv >= 1 && dv < md) md = dv }
                        if (md <= 31) fdt_c = substr($1, 1, 8) sprintf("%02d", md)
                    }
                    if (!(title in fdT) || fdt_c < fdT[title]) fdT[title] = fdt_c
                    if (!(title in ldT) || dt > ldT[title]) { ldT[title] = dt; rep[title] = bid }
                }
                if (NF >= 6 && $6 != "") pr[bid] = $6 + 0
            }
            END {
                n = 0
                for (tk in durT) { n++; titles[n] = tk; dur_arr[n] = durT[tk] }
                for (i = 1; i <= n; i++) {
                    tk = titles[i]
                    rb = rep[tk]
                    # v2.3.32：开始日期 = 整本书最早阅读日 fdT（同名归并权威，跨 key 取最早）→ book-meta 兜底
                    f = (tk in fdT) ? fdT[tk] : ""
                    if (f == "" && (rb in fo_iso)) f = fo_iso[rb]
                    if (f == "") f = today
                    fd_eff[i] = f
                    fn = dnum(f)
                    days = (fn > 0 && today_num > 0) ? (today_num - fn + 1) : 1
                    if (days < 1) days = 1
                    daily_arr[i] = int(dur_arr[i] / days)
                    # 进度：代表 bid 的 tsv progress 列优先；为空或 0（历史数据常缺此列）则回落 cc.db
                    pct_arr[i] = ((rb in pr) && pr[rb] > 0) ? pr[rb] : cc_pct[rb]
                    if (pct_arr[i] == "") pct_arr[i] = 0
                    laT[i] = (tk in ldT) ? ldT[tk] : ""
                }
                # 手工选择排序（busybox 无 asorti）；同步交换所有伴随数组
                # v2.4.0：并列时加确定性强键（时长→日均→书名字典序）——归档改变行序后名次仍逐位不变
                for (i = 1; i <= n; i++) {
                    mi = i
                    for (j = i + 1; j <= n; j++) {
                        if (sort_mode == "daily") {
                            if (daily_arr[j] > daily_arr[mi] || (daily_arr[j] == daily_arr[mi] && (dur_arr[j] > dur_arr[mi] || (dur_arr[j] == dur_arr[mi] && titles[j] < titles[mi])))) mi = j
                        } else {
                            if (dur_arr[j] > dur_arr[mi] || (dur_arr[j] == dur_arr[mi] && (daily_arr[j] > daily_arr[mi] || (daily_arr[j] == daily_arr[mi] && titles[j] < titles[mi])))) mi = j
                        }
                    }
                    if (mi != i) {
                        td = dur_arr[i]; dur_arr[i] = dur_arr[mi]; dur_arr[mi] = td
                        dd = daily_arr[i]; daily_arr[i] = daily_arr[mi]; daily_arr[mi] = dd
                        tb = titles[i]; titles[i] = titles[mi]; titles[mi] = tb
                        tf = fd_eff[i]; fd_eff[i] = fd_eff[mi]; fd_eff[mi] = tf
                        tl = laT[i]; laT[i] = laT[mi]; laT[mi] = tl
                        tp = pct_arr[i]; pct_arr[i] = pct_arr[mi]; pct_arr[mi] = tp
                    }
                }
                # v2.3.32：全量输出（不再按页截取）——每行 9 字段：bid/书名/作者/asin/开始/最近/进度/时长/日均
                #   空作者/空最近日期输出占位 "-"（防渲染行 tab 分词错位）
                for (i = 1; i <= n; i++) {
                    tk = titles[i]
                    rb = rep[tk]
                    au = author[rb]; if (au == "") au = "-"
                    lv = laT[i];     if (lv == "") lv = "-"
                    print rb "\t" trtitle(shown[tk]) "\t" au "\t" rb "\t" fd_eff[i] "\t" lv "\t" pct_arr[i] "\t" dur_arr[i] "\t" daily_arr[i]
                }
                print "__RANK_TOTAL__\t" n
            }' "$DATA" 2>>"$RANK_DEBUG" > "$RANK_CACHE.tmp"

        # 拼 header（缓存 key 首行）后落盘
        { echo "#K|$_key"; cat "$RANK_CACHE.tmp"; } > "$RANK_CACHE" 2>/dev/null
        rm -f "$RANK_CACHE.tmp"
        # v2.3.32：页截取 = 逐列展开 + 空字段占位（兼容 v2.3.27 前无占位旧缓存）；行循环零 awk 子进程
        RANK_LINES=$(LC_ALL=C awk -F'\t' -v s=$((RANK_OFFSET * 6 + 2)) '
            function hhmm(x, sp,   h, m, r) { h = int(x/3600); m = int((x%3600)/60)
                if (sp == 1) r = sprintf("%dh %dm", h, m)          # 时长列：恒带 h（"0h 17m"，保历史格式）
                else if (h > 0) r = sprintf("%dh%dm", h, m)        # 日均列：h>0 带 h，否则纯 m（"56m"）
                else r = sprintf("%dm", m)
                return r }
            NR >= s && NR <= s + 5 && NF >= 9 {
                nf = split($0, F, "\t")
                if (F[3] == "") F[3] = "-"
                if (F[6] == "") F[6] = "-"
                printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", NR - s + 1, F[1], F[2], F[3], F[4], F[5], F[6], F[7], F[8], F[9], hhmm(F[8] + 0, 1), hhmm(F[9] + 0, 0)
            }' "$RANK_CACHE")
        RANK_TOTAL=$(awk -F'\t' '/^__RANK_TOTAL__/{print $2; exit}' "$RANK_CACHE")
        RANK_TOTAL=${RANK_TOTAL:-0}
        _dbg "  [build 完成] 缓存行数=$(wc -l < "$RANK_CACHE" 2>/dev/null | tr -d ' ') 本页行数=$(printf '%s\n' "$RANK_LINES" | grep -c . )"
        fi   # ← cache hit/miss 分支结束（v2.3.24）
        _dbg "  [数据层] 总耗时 $(( $(date +%s) - _t0 ))s（hit=只读缓存；miss=重建）"
        _tm data_done
    fi

    # ---- 2. 推 ranking_bg.png 底图 ----
    collapse_system_ui
    "$FBINK" -q -b -g "file=$RANK_BG" 2>>"$FBINK_LOG" || { restore_system_ui; fail "ranking bg push failed"; }
    _tm bg_done

    # ---- 3. 排序胶囊文字（v2.3.9：时长/日均同时显示、同色全黑，选中态靠左侧实心圆点 ● + 加粗标记；中线竖线已画在底图）----
    if [ "$RANK_SORT" = "duration" ]; then
        fb_text_center 28 106 890 1010 BOLD BLACK "● 时长"
        fb_text_center 28 106 1010 1130 REGULAR BLACK "日均"
    else
        fb_text_center 28 106 890 1010 REGULAR BLACK "时长"
        fb_text_center 28 106 1010 1130 BOLD BLACK "● 日均"
    fi

    # ---- 4. 底部 tab 文字（v2.3.2: 完整画在 ranking_bg.png，当前在 ranking 页 → 「排行」选中）----

    # ---- 5. 翻页文字（v2.3.7：‹ › 箭头已画在 ranking_bg.png 底图；launcher 只画中格页码，居中）----
    total_pages=$(( (RANK_TOTAL + 5) / 6 ))
    [ "$total_pages" -lt 1 ] 2>/dev/null && total_pages=1
# v2.3.14：分页数值太小 → 20pt 放大到 40pt（放大一倍）
# v2.3.14：分页数值太小 → 20pt 放大到 40pt（放大一倍）
# v2.3.18：回退胶囊整体居中；保持底图原 [820,1190] 三段位置；launcher 只画中段页码，视觉居中到中段中央 x=1005
# v2.3.14：分页数值太小 → 20pt 放大到 40pt（放大一倍）
# v2.3.18：回退 v2.3.17 整体居中；保持底图原 [820,1190] 三段位置；中段页码视觉居中 x=1005
# v2.3.20：从真机截图像素探测：分页胶囊中段「1/2」字符实际 vp_x 中心 ≈993；中段绘制区左移 12：box_left=918, box_right=1068 → center vp_x=993
# v2.3.32：复探实测字 vp_x 中心 ≈1004（fbink 不可消除地偏右 11），vp_y 中心 ≈1596（偏下 11）；top 上移 12，box_left/right 右移 11 → 实测字正中位置
fb_text_center 40 1564 929 1079 REGULAR BLACK "$((RANK_OFFSET+1)) / $total_pages"

    # ---- 6. 6 行（封面/序号/书名/作者/起止/进度/百分比/时长/日均）----
    # v2.3.20：ROW_TOP0 从 260 改为 242（校正 fbink 全局偏下 18 px —— 之前实测所有书籍下方分线都比脚本算出的 row_top 高 18 vp_px）
    ROW_TOP0=242
    ROW_H=215
    # v2.3.33：行解析 = 单次 awk 把 12 字段 + 封面归一化 key（原 tr×2 的活）以 \x1f 连接，
    #   read 一次拆 13 变量（\x1f 是非空白 IFS 字符：空字段保留、绝不合并错位 —— 比 v2.3.32 的
    #   12×cut 每行省 26 个子进程，且免疫 v2.3.28 set -- 的空字段左移坑）。
    #   封面查询逻辑（COVER_MAP 主查 + UUID_MAP 兜底 + 多路径 fallback）与 v2.3.23/32 逐字节一致，未动。
    _SEP=$(printf '\037')
    printf '%s\n' "$RANK_LINES" | LC_ALL=C awk -F'\t' 'NR<=6 && NF>=10 {
        k = $5; gsub(/-/, "", k); k = toupper(k)
        out = $1; for (i = 2; i <= 12; i++) out = out sprintf("%c", 31) $i
        print out sprintf("%c", 31) k
    }' | \
    while IFS="$_SEP" read -r idx bid title author asin fo_iso la_iso pct secs daily dur_str daily_str _key; do
        [ "$author" = "-" ] && author=""   # 兼容占位符
        [ "$la_iso" = "-" ] && la_iso=""
        [ -z "$title" ] && title="$bid"
        row_top=$(( ROW_TOP0 + (idx - 1) * ROW_H ))
        # 封面（fbink -g 推 JPG；v2.3.8 多路径 fallback，找不到则留空）
        # v2.3.10：把探测过程写进 rank-debug.log，定位「封面拿不到」究竟是路径不对还是缩略图不存在
        if [ -n "$asin" ]; then
            thumb=""
            uuid=""
            # v2.3.13：封面权威来源 = cc.db p_thumbnail（kindle-reading-records 参考实现实证：
            #   p_thumbnail 直接存封面路径，对 ASIN 封面与个人文档随机文件名皆权威，不猜 UUID/ASIN 拼文件名）。
            # v2.3.32：查询还原 v2.3.23 验证实现 —— COVER_MAP(归一化key→thumb) 主查 + UUID_MAP(原样key→uuid) 兜底
            # v2.3.33：_key 由行首 awk 预归一化（去-转大写），与旧 tr×2 结果逐字节一致
            _cov=""
            uuid=""
            if [ -n "$_key" ] && [ -f "$COVER_MAP" ]; then
                _cov=$(awk -F'\t' -v k="$_key" '$1==k{print $2; exit}' "$COVER_MAP" 2>/dev/null)
            fi
            # v2.3.35：候选清单改逐项引号传参（原空格拼接 for 迭代，p_thumbnail 为含空格的
            #   个人文档绝对路径时会被分词拆散 → 封面 MISS）
            _c1=""; _c2=""
            if [ -n "$_cov" ]; then
                case "$_cov" in
                    /*) _c1="$_cov" ;;
                    *)  _c1="/mnt/us/system/thumbnails/$_cov"; _c2="/mnt/us/system/thumbnails/thumbnail_${_cov}_EBOK_portrait.jpg" ;;
                esac
            fi
            # 兜底：UUID 映射 + ASIN 各拼法（p_thumbnail 不可用时仍有机会）
            if [ -f "$UUID_MAP" ]; then
                uuid=$(awk -F'\t' -v a="$asin" '$1==a{print $2; exit}' "$UUID_MAP" 2>/dev/null)
            fi
            _uc=""
            [ -n "$uuid" ] && _uc="/mnt/us/system/thumbnails/thumbnail_${uuid}_EBOK_portrait.jpg"
            for _tp in "$_c1" "$_c2" \
                "/mnt/us/system/thumbnails/thumbnail_${asin}_EBOK_portrait.jpg" \
                "/mnt/us/system/thumbnails/thumbnail_${asin}_EBOK.jpg" \
                "/mnt/us/system/thumbnails/${asin}_EBOK_portrait.jpg" \
                "$_uc"; do
                if [ -n "$_tp" ] && [ -f "$_tp" ]; then thumb="$_tp"; break; fi
            done
            if [ "$idx" = "1" ]; then
                echo "  [封面] 第 $idx 行 asin=$asin key=${_key:-<无>} uuid=${uuid:-<无>} p_thumbnail=${_cov:-<无>} 命中=${thumb:-<无>}" >> "$RANK_DEBUG"
            fi
            if [ -n "$thumb" ]; then
                # v2.3.20：上边距 20 vp_px = 校正 fbink 全局 -18 px 偏移后封面顶 vp = 上分线 vp + 20
                # v2.3.32：复探实测封面顶 vp=477 vs 上分线 vp=460（留 17vp_px 上边距），但文字 vp_y_top=485 →
                #          cover vp_y_top 比文字偏上 8 vp_px（fbink -g 推图无偏，fbink -t 偏下 8 vp_px）。
                #          改 cover y = row_top+28 → cover vp_y_top=485 与文字 vp_y_top 完全齐平；上下边距：上 25 vp_px / 下 25 vp_px。
                # v2.3.35：封面 x 80→150（序号移封面左侧，封面/书名/作者/进度条整组右移 70，y/w/h 不动）
                # v2.3.32 行级打点：cover_ms = 单张封面 fbink -g 耗时（jpg 解码+dither 可疑大头）
                # v2.3.33：_nowcs 内建取值（零 fork）
                _nowcs; _g0=$CSEC
                "$FBINK" -q -b -g "file=$thumb,x=150,y=$((row_top+28)),w=120,h=165,dither" 2>>"$FBINK_LOG" || true
                _nowcs; echo "  [row $idx] cover_ms=$(( CSEC - _g0 ))" >> "$RANK_DEBUG"
            fi
        fi
        # v2.3.32 行级打点：text_ms = 本行文字+进度条整段耗时（序号→日均 7-9 次 fbink -t/-k）
        _nowcs; _x0=$CSEC
        # v2.3.35 行内布局重排（6 点布局需求+间距微调，预览确认后落地）：
        #   ① 序号移封面左侧，[60,150] 居中，视觉中心=封面中心（row_top+110.5）
        #   ② 封面/书名/作者/进度条整组右移 70（封面 x=150，文字左缘 240→310，封面↔文字间隙 40 不变）
        #   ③ 书名 32→34pt；④ 作者与起止合并一行「作者 · 起 → 止」25pt（效果图比例 0.74，
        #     长作者+全日期亦不撞右列）；⑤ 进度条满长右缘抵屏宽 2/3（x=848，全长 538）；
        #   ⑥ 时长 32→34pt，与日均右对齐成块（右缘 1167 不变），块视觉中心=封面中心
        #   间距微调（追加）：书名+26、合并行+84、进度条+160（条底距封面底 27vp，同效果图比例）
        # 序号（32pt；top=+96 → 数字视觉中心 ≈ 封面中心）
        # v2.3.35：序号跨页连续编号（实测：第 2 页第 1 本应显 7 而非 1）——
        #   idx 仍是页内行号（row_top/行解析均依赖 1..6），仅展示号 = 页偏移×6 + 页内行号
        _no=$(( RANK_OFFSET * 6 + idx ))
        fb_text_center 32 $((row_top + 96)) 60 150 REGULAR INK_SOFT "$_no"
        # 书名（BOLD 38pt v2.3.37；top=+34 向作者行靠拢 8；right=300 避开右列时长，15 字×38=570 < 662 放得下）
        fb_text_at 38 $((row_top + 34)) 310 300 BOLD BLACK - "$title"
        # 作者 · 起止（29pt v2.3.37 合并行，位置不动；author 为空时只画起止，不挂前导「·」）
        _meta="$fo_iso → $la_iso"
        [ -n "$author" ] && _meta="$author · $fo_iso → $la_iso"
        fb_text_at 29 $((row_top + 84)) 310 230 REGULAR INK_SOFT - "$_meta"
        # 进度条：满长 [310,848]（右缘=屏宽 2/3）、h=6；v2.3.37 上移 8（+160→+152）向作者行靠拢，条底距封面底 35vp
        bar_top=$((row_top + 152))
        if [ "$pct" -gt 0 ] 2>/dev/null && [ "$pct" -le 100 ] 2>/dev/null; then
            fill_w=$(( 538 * pct / 100 ))
            fb_rect_at "$bar_top" 310 "$fill_w" 6 "$BAR_FILL"
        fi
        # 百分比（32pt；left=880=满长条尾+32；top=+141 → 视觉中心 ≈ 条中心 row_top+155；无进度不画）
        if [ "$pct" -gt 0 ] 2>/dev/null && [ "$pct" -le 100 ] 2>/dev/null; then
            fb_text_at 32 $((row_top + 141)) 880 250 REGULAR BLACK - "${pct}%"
        fi
        # 右列时长（BOLD 38pt v2.3.37；top=+67）+ 日均（32pt；top=+111）：右对齐成块，块视觉中心 = 封面中心
        # v2.3.32：right_edge=1167（=1130+37）→ 实机 vp_x_right ≈1130（fbink OT mode 右缘 ~37vp 内部 padding 补偿，沿用不动）
        fb_text_right 38 $((row_top + 67)) 1167 BOLD BLACK "$dur_str"
        fb_text_right 32 $((row_top + 111)) 1167 REGULAR INK_SOFT "日均 $daily_str"
        _nowcs; echo "  [row $idx] text_ms=$(( CSEC - _x0 )) 书=$title" >> "$RANK_DEBUG"
    done

    # ---- 7. commit ----
    _tm rows_done
    # v2.4.2：改走 commit_screen 计数制 flash（同 dashboard；每次必闪降为每 FLASH_EVERY 次一闪）
    commit_screen
    restore_system_ui
    _tm rank_end
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
        action="$(timeout 120 lua "$TOUCH_READER" "$TOUCH" "$BASE/dashboard-touch.log" "$PAGE" "$hyear" 0 0 1272 1696 2>/dev/null)" || action="exit"
    else
        sleep 120
        action="exit"
    fi
    echo "$(date): action=$action page=$PAGE hyear=$hyear rank_offset=$RANK_OFFSET rank_sort=$RANK_SORT"
    case "$action" in
        exit) break;;
        goto_ranking) PAGE="ranking"; RANK_OFFSET=0; render_ranking ;;
        goto_dashboard) PAGE="dashboard"; render_dashboard ;;
        rank_prev)
            if [ "$RANK_OFFSET" -gt 0 ]; then RANK_OFFSET=$((RANK_OFFSET-1)); render_ranking; fi
            ;;
        rank_next)
            max_off=$(( (RANK_TOTAL + 5) / 6 - 1 ))
            if [ "$RANK_OFFSET" -lt "$max_off" ] 2>/dev/null; then RANK_OFFSET=$((RANK_OFFSET+1)); render_ranking; fi
            ;;
        rank_toggle_sort)
            if [ "$RANK_SORT" = "duration" ]; then RANK_SORT="daily"; else RANK_SORT="duration"; fi
            RANK_OFFSET=0
            render_ranking
            ;;
        period_prev) year_prev && render_dashboard ;;
        period_next) year_next && render_dashboard ;;
        *) break;;
    esac
    # goto_*/rank_*/period_* 已在 case 内自渲染；exit/未知直接 break
done

# 自动回主页（右上角退出 / 2 分钟超时 / 主页键 trap 恢复）
# v2.4.2 退出即时反馈（局部版）：× 按钮区画黑块 + DU 波形只刷该小块（~0.15s，不闪全屏）——
#   v2.4.1 用全屏 flash 反馈，与渲染 flash 叠加后「点一下闪一下」感太强；局部反色同样即按即见。
#   坐标=× 可视圆外接方块（圆心 1180,120，r=28）。
"$FBINK" -q -B BLACK -k "top=92,left=1152,width=56,height=56" -W DU -s >/dev/null 2>&1 || true
# 导出日志到 USB 根（补回旧版 export_logs，方便排障）
for _lf in dashboard-launch.log fbink.log dashboard-touch.log install.log; do
    [ -f "$BASE/$_lf" ] && cp "$BASE/$_lf" "/mnt/us/LOG-$_lf" 2>/dev/null
done
restore_system_ui
lipc-set-prop com.lab126.appmgrd start 'app://com.lab126.booklet.home' >/dev/null 2>&1 || \
lipc-set-prop com.lab126.appmgrd start 'app://com.lab126.KPPMainApp?view=KPP_LIBRARY' >/dev/null 2>&1 || true
exit 0

#!/bin/sh
#
# Kindle 原生阅读时长守护进程 v2.0
# 事件驱动省电：熄屏/亮屏用 lipc-wait-event 纯事件（零轮询），阅读中每 120s 低频兜底抓"关书不熄屏"，
#   非阅读亮屏 30s 轮询抓"开书"；启动时自动探测 goingToScreenSaver，不存在则降级回 sleep 轮询（绝不忙循环）
# 修复版：
#   1. sqlite3 不可用/cc.db 缺失时静默降级，不再因为内部 exit 状态污染行循环
#   2. book_progress() 的 case 过滤多了一行 newline 容错
#   3. 启动期确保 data/state 目录存在
#   4. 即使所有外部依赖全失效，也绝不让守护进程退出（保持 Upstart respawn 的稳定性）

BASE="/mnt/us/reading-time"
DATA="$BASE/reading-time.tsv"
STATE="$BASE/state"
REPORT="$BASE/阅读时长统计.txt"
LOG="$BASE/service.log"
CC_DB="/var/local/cc.db"
READING_INTERVAL=120
ACTIVE_INTERVAL=30
LOCKED_INTERVAL=60
SAVE_INTERVAL=90
STATE_INTERVAL=90
EDGE_CREDIT_MAX=5

mkdir -p "$BASE"
umask 077
# 新建文件用 6 列表头；旧 4 列文件保留，读取端按字段数兼容
[ -f "$DATA" ] || printf 'date\tbook_id\tseconds\ttitle\tstatus\tprogress\n' > "$DATA"
# state 文件也兜底一份，避免 dashboard / 外部读取报错
[ -f "$STATE" ] || printf 'state=等待阅读\npid=\napp=\npower=\nbook_id=\ntitle=\nlast_update=\n' > "$STATE"

prop() { lipc-get-prop "$1" "$2" 2>/dev/null; }

decode_url() {
    printf '%s\n' "$1" | awk '
    function hex(c) { return index("0123456789ABCDEF", toupper(c)) - 1 }
    { out=""; for(i=1;i<=length($0);i++){ c=substr($0,i,1); if(c=="%"&&i+2<=length($0)){h1=hex(substr($0,i+1,1));h2=hex(substr($0,i+2,1));if(h1>=0&&h2>=0){out=out sprintf("%c",h1*16+h2);i+=2}else out=out c}else if(c=="+")out=out " ";else out=out c} print out }'
}

read_book() {
    context="$1"
    metadata="$2"
    book_id="$(printf '%s' "$metadata" | sed -n 's/.*"cdeKey":"\([^"]*\)".*/\1/p')"
    [ -n "$book_id" ] || book_id="$(printf '%s' "$context" | sed -n 's/.*_\([A-Fa-f0-9][A-Fa-f0-9]*\)\.kfx.*/\1/p')"
    [ -n "$book_id" ] || book_id="unknown"
    encoded="$(printf '%s' "$context" | sed -n 's|.*file://\([^?]*\).*|\1|p')"
    decoded="$(decode_url "$encoded")"
    book_title="${decoded##*/}"
    book_title="$(printf '%s' "$book_title" | sed "s/_${book_id}\.kfx$//;s/\.kfx$//;s/[\t\r\n]/ /g")"
    [ -n "$book_title" ] || book_title="$book_id"
}

format_time() {
    n="$1"; h=$((n/3600)); m=$(((n%3600)/60)); s=$((n%60))
    if [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"; elif [ "$m" -gt 0 ]; then printf '%dm %ds' "$m" "$s"; else printf '%ds' "$s"; fi
}

# 尽力而为地取当前书的阅读进度（0-100）。失败一律返回空，绝不报错退出。
book_progress() {
    t="$1"
    [ -n "$t" ] || { printf ''; return; }
    command -v sqlite3 >/dev/null 2>&1 || { printf ''; return; }
    [ -r "$CC_DB" ] || { printf ''; return; }
    et="$(printf '%s' "$t" | sed "s/'/''/g")"
    # 关键修复：用 sed 二次校验输出，避免 sqlite3 异常退出码 + 脏数据污染
    p="$(sqlite3 -readonly -noheader "$CC_DB" \
        "SELECT CAST(p_percentFinished+0.5 AS INTEGER) FROM Entries WHERE p_titles_0_nominal='$et' LIMIT 1" 2>/dev/null | tr -d '[:space:]')"
    case "$p" in ''|*[!0-9]*) p="";; esac
    printf '%s' "$p"
}

write_report() {
    report_total="$(awk -F '\t' 'NR>1&&NF>=4{s+=$3}END{print s+0}' "$DATA" 2>/dev/null)"
    report_total="${report_total:-0}"
    report_today="$(awk -F '\t' -v d="$(date +%Y-%m-%d)" 'NR>1&&NF>=4&&$1==d{s+=$3}END{print s+0}' "$DATA" 2>/dev/null)"
    report_today="${report_today:-0}"
    {
        echo "Kindle 原生阅读时长统计"
        echo "更新时间：$(date)"
        echo "服务状态：运行中（PID $$）"
        echo "当前状态：$service_state"
        echo "计时方式：原生阅读器前台且屏幕亮起"
        echo "今日阅读：$(format_time "$report_today")"
        echo "累计阅读：$(format_time "$report_total")"
        echo
        echo "按书籍统计："
        awk -F '\t' 'NR>1&&NF>=4{k=$2 SUBSEP $4;s[k]+=$3}END{for(k in s){split(k,a,SUBSEP);print s[k]"\t"a[2]"\t"a[1]}}' "$DATA" 2>/dev/null \
            | sort -nr \
            | awk -F '\t' '{h=int($1/3600);m=int(($1%3600)/60);s=$1%60;if(h>0)t=h"h "m"m";else if(m>0)t=m"m "s"s";else t=s"s";print "- "$2": "t" ("$3")"}'
    } > "$REPORT.tmp" 2>/dev/null && mv "$REPORT.tmp" "$REPORT" 2>/dev/null || true
}

bucket=0; bucket_id=""; bucket_title=""; bucket_date=""
flush() {
    if [ "$bucket" -gt 0 ] && [ -n "$bucket_id" ]; then
        prog="$(book_progress "$bucket_title")"
        st="reading"
        [ "$prog" = "100" ] && st="finished"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$bucket_date" "$bucket_id" "$bucket" "$bucket_title" "$st" "$prog" >> "$DATA" 2>/dev/null || true
    fi
    bucket=0; bucket_id=""; bucket_title=""; bucket_date=""
}
cleanup() { flush; service_state="已停止"; write_report; }
trap 'cleanup; trap - INT TERM HUP EXIT; exit 0' INT TERM HUP
trap cleanup EXIT

write_state() {
    state_now="$1"
    printf 'state=%s\npid=%s\napp=%s\npower=%s\nbook_id=%s\ntitle=%s\nlast_update=%s\n' "$service_state" "$$" "$app" "$power" "$current_id" "$current_title" "$state_now" > "$STATE.tmp" 2>/dev/null \
        && mv "$STATE.tmp" "$STATE" 2>/dev/null || true
    last_state_write="$state_now"
}

add_edge_credit() {
    edge_delta="$1"
    edge_id="$2"
    edge_title="$3"
    edge_date="$4"
    edge_credit=$((edge_delta/2))
    [ "$edge_credit" -gt "$EDGE_CREDIT_MAX" ] && edge_credit="$EDGE_CREDIT_MAX"
    if [ "$edge_credit" -gt 0 ] && [ -n "$edge_id" ]; then
        bucket_id="$edge_id"; bucket_title="$edge_title"; bucket_date="$edge_date"
        bucket=$((bucket+edge_credit))
    fi
}

wait_next() {
    wait_mode="$1"
    wait_seconds="$2"
    if ! command -v lipc-wait-event >/dev/null 2>&1; then
        sleep "$wait_seconds"
        return
    fi
    case "$wait_mode" in
        locked)
            wait_started="$(date +%s)"
            if ! lipc-wait-event -s "$wait_seconds" com.lab126.powerd outOfScreenSaver >/dev/null 2>&1; then
                wait_ended="$(date +%s)"
                wait_remaining=$((wait_seconds-(wait_ended-wait_started)))
                [ "$wait_remaining" -gt 0 ] && sleep "$wait_remaining"
            fi
            ;;
        reading)
            if [ "$HAS_GS" -eq 1 ]; then
                lipc-wait-event -s "$wait_seconds" com.lab126.powerd goingToScreenSaver >/dev/null 2>&1
            else
                sleep 30
            fi
            ;;
        *)
            sleep "$wait_seconds"
            ;;
    esac
}

HAS_GS=0
if command -v lipc-wait-event >/dev/null 2>&1; then
    _gs_t0="$(date +%s)"
    lipc-wait-event -s 1 com.lab126.powerd goingToScreenSaver >/dev/null 2>&1
    _gs_t1="$(date +%s)"
    [ $((_gs_t1-_gs_t0)) -ge 1 ] && HAS_GS=1
fi
previous="$(date +%s)"; was_reader=0; current_id=""; current_title=""; service_state="等待阅读"; last_state=""; last_state_write=0
echo "$(date): upstart service started, pid=$$, timing=event-driven-reader-active-screen, model=v2.0-6col, goingToScreenSaver=$HAS_GS" >> "$LOG"
write_report

while :; do
    _now_today="$(date +"%s %Y-%m-%d")"
    now="${_now_today%% *}"; today="${_now_today#* }"
    delta=$((now-previous))
    app="$(prop com.lab126.appmgrd activeApp)"; power="$(prop com.lab126.powerd state)"
    reader=0; interval="$ACTIVE_INTERVAL"; wait_mode="active"
    [ "$app" = "com.lab126.booklet.reader" ] && [ "$power" = "active" ] && reader=1

    if [ "$reader" -eq 1 ]; then
        interval="$READING_INTERVAL"; wait_mode="reading"
        context="$(prop com.lab126.appmgrd activeContext)"; metadata="$(prop com.lab126.yjr.annotations getCurrentBookMetadata)"
        read_book "$context" "$metadata"
        if [ "$was_reader" -eq 1 ] && [ -n "$current_id" ] && [ "$current_id" != "$book_id" ]; then
            flush; service_state="切换书籍"; write_report
        fi
        if [ "$was_reader" -eq 0 ] || [ "$current_id" != "$book_id" ]; then
            current_id="$book_id"; current_title="$book_title"
        fi
        if [ "$was_reader" -eq 0 ]; then
            add_edge_credit "$delta" "$current_id" "$current_title" "$today"
        fi
    elif [ "$power" != "active" ]; then
        interval="$LOCKED_INTERVAL"
        wait_mode="locked"
    fi
    service_state="等待阅读"
    if [ "$was_reader" -eq 1 ] && [ "$reader" -eq 1 ] && [ "$delta" -gt 0 ] && [ "$delta" -le 150 ]; then
        if [ -n "$bucket_date" ] && [ "$bucket_date" != "$today" ]; then
            flush; write_report
        fi
        service_state="正在阅读"; bucket_id="$current_id"; bucket_title="$current_title"; bucket_date="$today"; bucket=$((bucket+delta))
        if [ "$bucket" -ge "$SAVE_INTERVAL" ]; then flush; write_report; fi
    elif [ "$was_reader" -eq 1 ] && [ "$reader" -eq 0 ]; then
        add_edge_credit "$delta" "$current_id" "$current_title" "$today"
        flush
        [ "$power" = "active" ] && service_state="已退出阅读" || service_state="锁屏暂停"
        write_report
    elif [ "$power" != "active" ]; then
        service_state="锁屏暂停"
    fi

    if [ "$service_state" != "$last_state" ] || [ $((now-last_state_write)) -ge "$STATE_INTERVAL" ]; then
        write_state "$now"
        last_state="$service_state"
    fi
    previous="$now"; was_reader="$reader"; wait_next "$wait_mode" "$interval"
done
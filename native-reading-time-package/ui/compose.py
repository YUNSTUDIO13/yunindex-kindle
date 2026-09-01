#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Yunindex阅读统计 v2.0 · 整页 dashboard 合成器（快通道）。

设计：v13.0 单页 dashboard + 完全照效果图重做（衬线体 / 无单位字段 / 累计时长在下方首位）。
  - 顶部：剪影 logo + "Yunindex阅读统计" + 副标 + 关闭按钮
  - 今日阅读：大号 HH:MM 衬线数字
  - 三卡：本周阅读 / 本月日均 / 连续阅读（无单位）
  - 本周节奏：7 根柱（柱顶时间数字 + 右侧"合计 HH:MM"）
  - 本年统计四卡：累计时长 / 累计阅读 / 在读书籍 / 完成阅读（无单位）
  - 底部金句（句子 + 《书名》·作者）
  - 右下角 < 年份 > 切换器（背景已烤按钮框，compose 覆盖年份数字）
  - 背景水印 "Kindle"（极淡米色，衬线 Bold）

坐标：logical 1272x1696，fbink -g 自动缩放到 KPW6 viewport。
"""

import os
import sys
import argparse
import hashlib
from datetime import date
from PIL import Image, ImageDraw, ImageFont

W, H = 1272, 1696
XL = 100  # 全局左缘基线（所有标题/标签/值的左缘统一基线）

# === 配色（与 generate_bg.py 一致）===
WHITE = (255, 255, 255)
INK = (22, 22, 22)            # #161616
INK_SOFT = (189, 184, 171)    # #BDB8AB


# ---------------- 字体（带缓存） ----------------
_font_cache = {}


def fr(size, bold=False):
    key = (size, bold)
    if key in _font_cache:
        return _font_cache[key]
    path = BOLD_FONT if bold else REG_FONT
    try:
        f = ImageFont.truetype(path, size)
    except Exception:
        f = ImageFont.load_default()
    _font_cache[key] = f
    return f


# ---------------- 文本绘制（top 为文字上沿 y） ----------------
def tcenter(d, text, cx, top_y, fnt, fill):
    bbox = d.textbbox((0, 0), text, font=fnt)
    tw = bbox[2] - bbox[0]
    d.text((cx - tw / 2, top_y), text, font=fnt, fill=fill)


def tright(d, text, right_x, top_y, fnt, fill):
    bbox = d.textbbox((0, 0), text, font=fnt)
    tw = bbox[2] - bbox[0]
    d.text((right_x - tw, top_y), text, font=fnt, fill=fill)


# ---------------- 时间格式 ----------------
def fmt_hm(tt):
    """秒 -> 'H:MM'（如 1:23、326:40），无 24h 上限。"""
    h = tt // 3600
    m = (tt % 3600) // 60
    return f"{h:02d}:{m:02d}"


def fmt_hm_compact(tt):
    """秒 -> 'HhMMm'（合计用，节省宽度）。"""
    h = tt // 3600
    m = (tt % 3600) // 60
    if h == 0:
        return f"{m}分"
    if m == 0:
        return f"{h}时"
    return f"{h}时{m:02d}分"


# ---------------- 日期工具 ----------------
def days_in_month(y, m):
    m = m % 12
    if m in (1, 3, 5, 7, 8, 10, 12):
        return 31
    if m in (4, 6, 9, 11):
        return 30
    if (y % 400) == 0 or ((y % 4) == 0 and (y % 100) != 0):
        return 29
    return 28


def weekday_monday(y, m, d):
    if m < 3:
        m += 12
        y -= 1
    q = d
    k = y % 100
    j = y // 100
    h = (q + (13 * (m + 1)) // 5 + k + k // 4 + j // 4 + 5 * j) % 7
    return (h + 5) % 7


def _dec(y, m, d):
    d -= 1
    if d < 1:
        m -= 1
        if m < 1:
            m = 12
            y -= 1
        d = days_in_month(y, m)
    return y, m, d


def _inc(y, m, d):
    d += 1
    if d > days_in_month(y, m):
        d = 1
        m += 1
        if m > 12:
            m = 1
            y += 1
    return y, m, d


def week_range(y, m, d):
    dow = weekday_monday(y, m, d)
    cy, cm, cd = y, m, d
    for _ in range(dow):
        cy, cm, cd = _dec(cy, cm, cd)
    ws = f"{cy:04d}-{cm:02d}-{cd:02d}"
    ey, em, ed = y, m, d
    for _ in range(6 - dow):
        ey, em, ed = _inc(ey, em, ed)
    we = f"{ey:04d}-{em:02d}-{ed:02d}"
    return ws, we


# ---------------- 数据读取 ----------------
def load_rows(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        first = True
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if first:
                first = False
                if parts and parts[0] == "date":
                    continue
            if len(parts) < 3:
                continue
            d = parts[0].strip()
            bid = parts[1].strip() if len(parts) > 1 else ""
            try:
                sec = int(float(parts[2]))
            except Exception:
                continue
            prog = 0
            st = "reading"
            if len(parts) >= 6:
                try:
                    prog = int(float(parts[5]))
                except Exception:
                    prog = 0
                st = parts[4].strip() if parts[4] else "reading"
            rows.append({"date": d, "bid": bid, "sec": sec, "prog": prog, "st": st})
    return rows


# ---------------- 指标聚合 ----------------
def metric_today(rows, today):
    s = 0
    for r in rows:
        if r["date"] == today:
            s += r["sec"]
    return s


def metric_week(rows, today, ws, we):
    """本周总秒数（不含未来日期，与柱状图合计口径一致）。"""
    try:
        ty, tm, td = int(today[:4]), int(today[5:7]), int(today[8:10])
        today_d = date(ty, tm, td)
    except Exception:
        today_d = None
    s = 0
    for r in rows:
        if ws <= r["date"] <= we:
            if today_d is not None:
                try:
                    if date.fromisoformat(r["date"]) > today_d:
                        continue
                except Exception:
                    pass
            s += r["sec"]
    return s


def metric_streak(rows, today):
    read = set(r["date"] for r in rows if r["sec"] > 0)
    try:
        y, m, d = int(today[:4]), int(today[5:7]), int(today[8:10])
    except Exception:
        return 0
    cur = date(y, m, d)
    if cur.strftime("%Y-%m-%d") not in read:
        cur = date.fromordinal(cur.toordinal() - 1)
    s = 0
    while cur.strftime("%Y-%m-%d") in read:
        s += 1
        cur = date.fromordinal(cur.toordinal() - 1)
    return s


def metric_year(rows, hyear):
    """年度：累计时长（秒）、累计阅读（天数）、在读书籍、完成阅读。"""
    fin = set()
    for r in rows:
        if r["prog"] >= 100 or r["st"] == "finished":
            fin.add(r["bid"])
    S = 0
    DAYS = set()
    RB = set()
    FB = set()
    for r in rows:
        if r["date"][:4] != hyear:
            continue
        if r["sec"] > 0:
            S += r["sec"]
            DAYS.add(r["date"])
            if r["bid"] in fin:
                FB.add(r["bid"])
            else:
                RB.add(r["bid"])
    return S, len(DAYS), len(RB), len(FB)


def week_seconds(rows, today, ws, we):
    """周一到周日各日秒数（不含未来）。"""
    ws_d = date.fromisoformat(ws)
    we_d = date.fromisoformat(we)
    today_d = date.fromisoformat(today)
    sec7 = [0] * 7
    for r in rows:
        try:
            rd = date.fromisoformat(r["date"])
        except Exception:
            continue
        if rd < ws_d or rd > we_d:
            continue
        if rd > today_d:
            continue
        idx = rd.toordinal() - ws_d.toordinal()
        if 0 <= idx <= 6:
            sec7[idx] += r["sec"]
    return sec7


# ---------------- 金句 ----------------
FALLBACK_QUOTES = [
    ("我们都是孤独的，直到遇见另一个孤独的灵魂", "当尼采哭泣", "欧文·亚隆"),
    ("走过的路成为背后的风景", "平凡的世界", "路遥"),
    ("所谓万丈深渊，下去，也是前程万里", "挪威的森林", "村上春树"),
    ("懂得太多反而是一种负担", "局外人", "阿尔贝·加缪"),
    ("生活总是让我们遍体鳞伤，但后来那些受伤的地方一定会变成最强壮的地方", "永别了，武器", "海明威"),
    ("人生如逆旅，我亦是行人", "苏东坡传", "林语堂"),
]


def load_quotes(quotes_path):
    items = []
    if os.path.exists(quotes_path):
        try:
            with open(quotes_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.rstrip("\n")
                    if not line or line.startswith("#"):
                        continue
                    parts = line.split("\t")
                    if len(parts) >= 3:
                        items.append((parts[0].strip(), parts[1].strip(),
                                      "·".join(p.strip() for p in parts[2:])))
                    elif len(parts) == 2:
                        items.append((parts[0].strip(), parts[1].strip(), ""))
        except Exception as e:
            sys.stderr.write(f"[compose] quotes read fail: {e}\n")
    if not items:
        items = FALLBACK_QUOTES
    return items


def pick_quote(items, today):
    h = hashlib.md5(today.encode("utf-8")).hexdigest()
    idx = int(h, 16) % len(items)
    return items[idx]


# ===============================================================
# 主绘制：单页 dashboard
# ===============================================================
def draw_dashboard(img, rows, today, ws, we, hyear, quote):
    d = ImageDraw.Draw(img)

    # === 1) 今日阅读（大号衬线 HH:MM，左对齐于 x=100）===
    s_today = metric_today(rows, today)
    d.text((100, 352), fmt_hm(s_today), font=fr(130, bold=True), fill=INK)

    # === 2) 第一排四卡：本周阅读 / 本月日均 / 本月时长 / 连续阅读（左对齐）===
    s_week = metric_week(rows, today, ws, we)
    streak = metric_streak(rows, today)
    ty, tm = int(today[:4]), int(today[5:7])
    mon_total = sum(r["sec"] for r in rows if r["date"][:7] == today[:7])
    days_elapsed = int(today[8:10])
    avg_sec = round(mon_total / days_elapsed) if days_elapsed > 0 else 0

    # R39: 第一排改为 4 字段，起点/列宽与下方四卡完全一致 [100, 378, 656, 934]
    cw4_top = (W - 60 - XL) // 4  # = 278
    col4_top_left = [XL + i * cw4_top for i in range(4)]  # [100, 378, 656, 934]
    values_top = [fmt_hm(s_week), fmt_hm(avg_sec), fmt_hm(mon_total), str(streak) + "天"]  # R46: 连续阅读→连续天
    for i, v in enumerate(values_top):
        d.text((col4_top_left[i], 615), v, font=fr(44, bold=True), fill=INK)

    # === 3) 本周节奏：7 柱 + 柱顶时间 + 右侧合计（条件渲染：sum(sec7) > 0 才画）===")
    sec7 = week_seconds(rows, today, ws, we)
    today_dow = weekday_monday(int(today[:4]), int(today[5:7]), int(today[8:10]))

    bar_x0, bar_x1 = 60, W - 60
    inner_w = bar_x1 - bar_x0
    n = 7
    gap = 46                  # 与底图对齐（瘦柱）
    sq = (inner_w - gap * (n - 1)) // n
    bar_y_top, bar_y_bot = 830, 1010  # R35: 整体下移 20 与 generate_bg.py + Yunindex阅读统计.sh 对齐
    bar_full_h = bar_y_bot - bar_y_top
    col_w = sq + gap
    total_week = sum(sec7)

    # —— 4 档离散高度（按用户 v13.1 第三轮：空/低/中/满，0=空不画）——
    LOW_H = int(bar_full_h * 0.33)   # 30 分以下 低柱（约 1/3 高）
    MID_H = int(bar_full_h * 0.66)   # 30 分-1小时59分 中柱（约 2/3 高）
    FULL_H = bar_full_h              # 2 小时及以上 满柱

    if total_week > 0:
        # 任何一天 sec > 0：7 柱开始绘制
        for i in range(n):
            x = bar_x0 + i * col_w
            sec = sec7[i]
            is_future = (i > today_dow)

            if is_future or sec <= 0:
                # 未来/0 分：完全不绘制（按用户"去掉空就三个高度差"）
                continue

            # 第一档：sec < 30 分钟 = 低柱（第二档高度）
            # 注意：用户原话"位读书=空，第二高度小于30分"——位读书=0 已 continue
            # 再细分：0 < sec < 1800 → 低柱；1800 <= sec < 7200 → 中柱；>= 7200 → 满柱
            if sec < 30 * 60:
                h = LOW_H
            elif sec < 120 * 60:
                h = MID_H
            else:
                h = FULL_H

            bar_top = bar_y_bot - h
            # 黑色实柱（衬线风统一墨色，避免多色干扰）
            d.rectangle([x, bar_top, x + sq, bar_y_bot], fill=INK)
            # R35：柱顶数字 18pt 完全画在柱顶之外（lbl_cy = bar_top - 28，bottom = bar_top - 16，远离柱体）
            # 皇上要求"不需要背景图底色"：不再画白底矩形，水印(218,218,218)很浅不影响阅读
            lbl = fmt_hm(sec)
            f_lbl = fr(18, bold=True)
            lbl_cx = x + sq // 2
            lbl_cy = bar_top - 28  # 上移确保 18pt 文字完全在柱顶之外
            d.text((lbl_cx, lbl_cy), lbl, font=f_lbl, fill=INK, anchor="mm")

    # R45：已移除"合计"（皇上确认不需要展示）
    # else: sum(sec7) <= 0 则不画柱（按设计稿 19.45.37"无数据态"）

    # === 4) 本年统计四卡：累计时长 / 累计阅读 / 在读书籍 / 完成阅读（左对齐）===
    s_year, days_year, rb_year, fb_year = metric_year(rows, hyear)
    n4 = 4
    # R14: 四卡列严格 4 等分 — 列宽 = (W - 60 - XL) // 4 = (1212 - 100) // 4 = 278pt
    # 起点 = XL + i*278 = [100, 378, 656, 934]，终点 = [378, 656, 934, 1212]
    # 第 1 字段"累计时长"起点 = 段标题"本年统计"起点 XL=100（字间距对齐）
    # "完成阅读" 起点 934 + 文本 ~156pt = 终点 ~1090 < 1212（再无超界）
    cw4_align = (W - 60 - XL) // n4  # = 278
    col4_left_c = [XL + i * cw4_align for i in range(n4)]  # [100, 378, 656, 934]
    values4 = [fmt_hm(s_year), str(days_year) + "天", str(rb_year) + "本", str(fb_year) + "本"]  # R46: 累计阅读→累计天, 在读→读过, 完成→读完
    for i, v in enumerate(values4):
        d.text((col4_left_c[i], 1233), v, font=fr(48, bold=True), fill=INK)  # R12: y 1238→1233

    # === 5) 底部金句（R43：句子 48pt 与累计时长值一致 + 书名/作者 28pt；y 1332/1392）===
    if quote:
        sentence, book, author = quote
        tcenter(d, sentence, W // 2, 1332, fr(48, bold=True), INK)  # R43: 26→48, 1360→1332
        if book:
            meta = f"《{book}》" + (f" · {author}" if author else "")
            tcenter(d, meta, W // 2, 1392, fr(28), INK)  # R43: 16→28, 1408→1392；R44 同高亮色

    # === 6) 右下年份覆盖（R34：按钮参数与 generate_bg.py 对齐 90/65/16；年份 36pt 居中）===
    ar_w, ar_h, ar_gap = 90, 65, 16
    ar_total = ar_w * 3 + ar_gap * 2
    ar_x1 = W - 60 - ar_total
    ar_y0 = 1525
    year_cx = ar_x1 + (ar_w + ar_gap) + ar_w // 2
    btn_cy = ar_y0 + ar_h // 2  # 按钮中心 y = 1557
    # 覆盖背景可能残留的年份：先涂白底再写
    d.rectangle([ar_x1 + ar_w + 4, ar_y0 + 6,
                 ar_x1 + (ar_w + ar_gap) * 2 - 4, ar_y0 + ar_h - 6],
                fill=WHITE)
    d.text((year_cx, btn_cy), str(hyear), font=fr(36, bold=True), fill=INK, anchor="mm")

    return img


# ---------------- 入口 ----------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bg", required=True, help="dashboard_bg.png 路径")
    ap.add_argument("--quotes", required=True, help="ui/quotes.tsv 路径")
    ap.add_argument("--data", required=True, help="reading-time.tsv 路径")
    ap.add_argument("--reg-font", required=True)
    ap.add_argument("--bold-font", required=True)
    ap.add_argument("--today", default="")
    ap.add_argument("--year", default="", help="当前展示年份（默认按 today 取）")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    global REG_FONT, BOLD_FONT
    REG_FONT = args.reg_font
    BOLD_FONT = args.bold_font
    if not os.path.exists(REG_FONT) or not os.path.exists(BOLD_FONT):
        sys.stderr.write(f"[compose] font missing: reg={REG_FONT} bold={BOLD_FONT}\n")
        sys.exit(2)

    rows = load_rows(args.data)
    if args.today:
        today = args.today
    else:
        today = date.today().strftime("%Y-%m-%d")
    ty, tm, td = int(today[:4]), int(today[5:7]), int(today[8:10])
    ws, we = week_range(ty, tm, td)
    hyear = args.year if args.year else str(ty)

    items = load_quotes(args.quotes)
    quote = pick_quote(items, today)

    img = Image.open(args.bg).convert("RGB")
    img = draw_dashboard(img, rows, today, ws, we, hyear, quote)
    img.save(args.out, "PNG", optimize=True)

    s_today = metric_today(rows, today)
    s_week = metric_week(rows, today, ws, we)
    streak = metric_streak(rows, today)
    s_year, days_y, rb_y, fb_y = metric_year(rows, hyear)
    sys.stderr.write(
        f"[DIAG dashboard] today={today} ws={ws} we={we} hyear={hyear} "
        f"today_sec={s_today} week_sec={s_week} streak={streak} "
        f"year_sec={s_year} year_days={days_y} year_rb={rb_y} year_fb={fb_y} "
        f"quote=\"{quote[0][:20]}...\" from=\"{quote[1]}\"\n"
    )
    print(f"composed dashboard -> {args.out}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        import traceback
        traceback.print_exc()
        sys.exit(1)

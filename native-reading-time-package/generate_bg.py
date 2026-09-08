#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v2.3.4 dashboard_bg.png · 单页 dashboard 背景生成器（回滚 2x 超采样）
- Noto Serif SC 衬线体（按效果图）
- 配色 #FFFFFF / #161616 / #BDB8AB（按设计说明）
- v2.3.4：去掉 v2.3.3 monkey-patch，回到 1x 直接画，圆角严格按设计稿 radius=40
         tab 文字 28→32（按需求放大），文字 cx 严格 tab 中点（居中）
"""

import os
from PIL import Image, ImageDraw, ImageFont

W, H = 1272, 1696
XL = 100  # 全局左缘基线

# === 配色 ===
WHITE = (255, 255, 255)
INK = (22, 22, 22)            # #161616 主文字
INK_SOFT = (189, 184, 171)    # #BDB8AB 分割线/次级文字
WATER = (218, 218, 218)       # 淡灰水印

# === 字体 ===
BASE = os.path.dirname(os.path.abspath(__file__))
F_BOLD = os.path.join(BASE, "NotoSerifSC-Bold.otf")
F_REG = os.path.join(BASE, "NotoSerifSC-Regular.otf")
LOGO_PATH = os.path.join(BASE, "kindle_logo_full.png")


def font(size, bold=False):
    return ImageFont.truetype(F_BOLD if bold else F_REG, size)


def tcenter(d, text, cx, top_y, fnt, fill):
    bbox = d.textbbox((0, 0), text, font=fnt)
    tw = bbox[2] - bbox[0]
    d.text((cx - tw / 2, top_y), text, font=fnt, fill=fill)


def tleft(d, text, x, top_y, fnt, fill):
    d.text((x, top_y), text, font=fnt, fill=fill)


def tright(d, text, right_x, top_y, fnt, fill):
    bbox = d.textbbox((0, 0), text, font=fnt)
    tw = bbox[2] - bbox[0]
    d.text((right_x - tw, top_y), text, font=fnt, fill=fill)


def ccenter(d, text, cx, cy, fnt, fill):
    """文字以 (cx, cy) 为视觉中心严格居中（用 PIL anchor='mm'，与 icon 视觉中心 = cy 严格对齐）"""
    d.text((cx, cy), text, font=fnt, fill=fill, anchor="mm")


# v2.3.6：icon 加权视觉中心严格 = cy
# draw_bar_icon：3 根竖条 heights [16, 24, 20] 总和 60，base_y - 10 = cy → base_y = cy + 10
def draw_bar_icon(d, cx, cy, color, size=30):
    """cx, cy 为图标加权视觉中心；3 根高低竖条，宽 6 间距 4，base_y = cy + 10"""
    base_y = cy + 10
    widths = [6, 6, 6]
    heights = [16, 24, 20]
    total_w = widths[0] * 3 + 4 * 2  # 26
    cur_x = cx - total_w // 2
    for w, h in zip(widths, heights):
        d.rectangle([cur_x, base_y - h, cur_x + w, base_y], fill=color)
        cur_x += w + 4


# v2.3.6：上下两本等大无缝衔接（加权中心 = cy）
def draw_book_icon(d, cx, cy, color, size=28):
    """cx, cy 为图标加权视觉中心；上下两本等大 22×11 堆叠，整体视觉中心 = cy"""
    bw, bh = 22, 11
    # 上书 y [cy-11, cy]
    bx1 = cx - bw // 2
    by2 = cy - 11
    d.rectangle([bx1, by2, bx1 + bw, by2 + bh], outline=color, width=2)
    d.line([(bx1 + 4, by2 + 2), (bx1 + 4, by2 + bh - 2)], fill=color, width=1)
    # 下书 y [cy, cy+11]（与上书共享边 cy，无缝堆叠）
    by1 = cy
    d.rectangle([bx1, by1, bx1 + bw, by1 + bh], outline=color, width=2)
    d.line([(bx1 + 4, by1 + 2), (bx1 + 4, by1 + bh - 2)], fill=color, width=1)


def main():
    img = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(img)

    # 外框
    pad = 36
    d.rounded_rectangle([pad, pad, W - pad, H - pad], radius=20, outline=INK_SOFT, width=2)

    # header logo
    logo = Image.open(LOGO_PATH).convert("RGBA")
    lh = 64
    lw = int(logo.size[0] * lh / logo.size[1])
    logo_r = logo.resize((lw, lh), Image.LANCZOS)
    logo_rgb = Image.new("RGB", (lw, lh), WHITE)
    for y in range(lh):
        for x in range(lw):
            r, g, b, a = logo_r.getpixel((x, y))
            if a > 128 and r < 128:
                logo_rgb.putpixel((x, y), INK)
    img.paste(logo_rgb, (86, 88))
    title_x = 86 + lw + 32
    tleft(d, "Yunindex阅读统计", title_x, 92, font(36, bold=True), INK)
    tleft(d, "READING LEDGER · 阅读数据面板", title_x, 142, font(13), INK_SOFT)

    # X 关闭按钮
    cx_b, cy_b, r_b = 1180, 120, 28
    d.ellipse([cx_b - r_b, cy_b - r_b, cx_b + r_b, cy_b + r_b], outline=INK_SOFT, width=2)
    d.text((cx_b, cy_b), "×", font=font(28, bold=True), fill=INK, anchor="mm")
    d.line([(60, 200), (W - 60, 200)], fill=INK_SOFT, width=2)

    # 今日时长
    tleft(d, "今日时长", XL, 252, font(28, bold=True), INK)
    tleft(d, "TODAY", XL, 296, font(13), INK_SOFT)

    # 第一排四栏
    cw4_top = (W - 60 - XL) // 4
    col4_top_left = [XL + i * cw4_top for i in range(4)]
    for i in range(1, 4):
        x_line = col4_top_left[i] - 40
        d.line([(x_line, 555), (x_line, 670)], fill=INK_SOFT, width=2)
    labels_top = ["本周时长", "本月日均", "本月时长", "连续天"]
    for i, (xL, lb) in enumerate(zip(col4_top_left, labels_top)):
        tleft(d, lb, xL, 555, font(28, bold=True), INK)
    d.line([(60, 690), (W - 60, 690)], fill=INK_SOFT, width=2)

    # 本周节奏
    tleft(d, "本周节奏 · WEEKLY RHYTHM", XL, 750, font(28, bold=True), INK)
    bar_x0, bar_x1 = 60, W - 60
    inner_w = bar_x1 - bar_x0
    n = 7
    gap = 76
    sq = (inner_w - gap * (n - 1)) // n
    bar_y_top, bar_y_bot = 830, 1010
    wm_text = "Kindle"
    wm_color = WATER
    wm_max_h = (bar_y_bot - bar_y_top) * 0.72
    for wm_size in range(180, 50, -10):
        f_wm = font(wm_size, bold=True)
        bbox = d.textbbox((0, 0), wm_text, font=f_wm)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        if tw <= inner_w * 0.85 and th <= wm_max_h:
            break
    wm_cx = W // 2
    wm_cy = (bar_y_top + bar_y_bot) // 2
    d.text((wm_cx, wm_cy), wm_text, font=f_wm, fill=wm_color, anchor="mm")
    days = ["一", "二", "三", "四", "五", "六", "日"]
    for i, dn in enumerate(days):
        x = bar_x0 + i * (sq + gap) + sq // 2
        tcenter(d, dn, x, bar_y_bot + 18, font(18), INK)

    # 本年统计
    tleft(d, "本年统计 · THIS YEAR", XL, 1108, font(28, bold=True), INK)
    n4 = 4
    cw4_align = (W - 60 - XL) // n4
    col4_left = [XL + i * cw4_align for i in range(n4)]
    col4_x = [xL + cw4_align // 2 for xL in col4_left]
    labels4 = ["累计时长", "累计天", "读过", "读完"]
    for i in range(1, n4):
        x_line = col4_left[i] - 40
        d.line([(x_line, 1173), (x_line, 1289)], fill=INK_SOFT, width=2)
    for i, (cx, xL, lb) in enumerate(zip(col4_x, col4_left, labels4)):
        tleft(d, lb, xL, 1173, font(28, bold=True), INK)
    d.line([(60, 1320), (W - 60, 1320)], fill=INK_SOFT, width=2)

    # 金句下分割线
    d.line([(60, 1450), (W - 60, 1450)], fill=INK_SOFT, width=2)

    # ===== 底部 tab 完整画（圆角 radius=40） + tab 图标 + tab 文字（32pt 严格居中）=====
    TAB_Y0, TAB_Y1 = 1545, 1625          # 高 80px
    TAB1_X0, TAB1_X1 = 80, 300           # 宽 220px；中点 cx1 = 190
    TAB2_X0, TAB2_X1 = 320, 540          # 宽 220px；中点 cx2 = 430
    TAB_CY = 1585                         # vertical center

    # 左 tab：指标（黑底白字，柱状图白 icon，**当前页选中**）
    d.rounded_rectangle([TAB1_X0, TAB_Y0, TAB1_X1, TAB_Y1], radius=40, fill=INK, outline=INK, width=2)
    draw_bar_icon(d, 130, TAB_CY, WHITE)
    ccenter(d, "指标", 210, TAB_CY, font(32, bold=True), WHITE)

    # 右 tab：排行（白底黑字，书本黑 icon）
    d.rounded_rectangle([TAB2_X0, TAB_Y0, TAB2_X1, TAB_Y1], radius=40, outline=INK, width=2)
    draw_book_icon(d, 370, TAB_CY, INK)
    ccenter(d, "排行", 450, TAB_CY, font(32, bold=True), INK)

    # 年份胶囊（与 tab 同款）
    d.rounded_rectangle([820, 1545, 1190, 1625], radius=40, outline=INK, width=2)
    d.line([(930, 1545), (930, 1625)], fill=INK_SOFT, width=1)
    d.line([(1080, 1545), (1080, 1625)], fill=INK_SOFT, width=1)
    # v2.3.7：‹ › 箭头直接画在底图，左格/右格严格居中对齐（anchor="mm"）
    # 左格 [820,930] 中心 x=875；右格 [1080,1190] 中心 x=1135；垂直中心 y=1585
    # launcher 只画中格 [930,1080] 的年份数字
    d.text((875, 1585), "‹", font=font(28, bold=True), fill=INK, anchor="mm")
    d.text((1135, 1585), "›", font=font(28, bold=True), fill=INK, anchor="mm")

    out = os.path.join(BASE, "ui", "dashboard_bg.png")
    img.save(out, "PNG", optimize=True)
    print(f"saved: {out}  size={img.size}")


if __name__ == "__main__":
    main()
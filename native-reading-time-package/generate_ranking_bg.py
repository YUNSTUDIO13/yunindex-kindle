#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v2.3.4 ranking_bg.png · 阅读排行页背景生成器（回滚 2x 超采样，恢复 v2.3.2 简洁版）
- 沿用 dashboard_bg.png 同风格（Noto Serif SC 衬线体 / 圆角外框 / 淡灰线）
- 仅画静态框：外框、header、排序胶囊框、6 行分隔线、底部 tab 框 + 翻页框
- 动态内容（书名/作者/起止/时长/日均/排序字重/封面 JPG/翻页文字）由 launcher 用 fbink 叠加
- v2.3.4：去掉 v2.3.3 monkey-patch（radius=40 在 2x 画布上缩小后只剩 20，圆角太小）；
         回到 1x 直接画，圆角严格按设计稿 radius=40；
         tab 文字 28→32（按需求放大），文字 cx 严格 tab 中点（居中）
"""

import os
from PIL import Image, ImageDraw, ImageFont

W, H = 1272, 1696

WHITE = (255, 255, 255)
INK = (22, 22, 22)            # #161616 主文字
INK_SOFT = (189, 184, 171)    # #BDB8AB 分割线/次级

BASE = os.path.dirname(os.path.abspath(__file__))
F_BOLD = os.path.join(BASE, "NotoSerifSC-Bold.otf")
F_REG = os.path.join(BASE, "NotoSerifSC-Regular.otf")
LOGO_PATH = os.path.join(BASE, "kindle_logo_full.png")


def font(size, bold=False):
    return ImageFont.truetype(F_BOLD if bold else F_REG, size)


def tleft(d, text, x, top_y, fnt, fill):
    d.text((x, top_y), text, font=fnt, fill=fill)


def ccenter(d, text, cx, cy, fnt, fill):
    """文字以 (cx, cy) 为视觉中心严格居中（用 PIL anchor='mm'，与 icon 视觉中心 = cy 严格对齐）"""
    d.text((cx, cy), text, font=fnt, fill=fill, anchor="mm")


# v2.3.6：icon 加权视觉中心严格 = cy
# draw_bar_icon：3 根竖条 heights [16, 24, 20] 总和 60，base_y - 平均高 = base_y - 10
#   设 base_y - 10 = cy → base_y = cy + 10（v2.3.5 算错成 cy+12，整体偏文字下 2px）
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


# v2.3.6：上下两本等大无缝衔接（视觉中心 = cy）
#   上书 y [cy-11, cy] 中心 cy-5.5；下书 y [cy, cy+11] 中心 cy+5.5
#   加权中心 = (cy-5.5 + cy+5.5)/2 = cy ✓
def draw_book_icon(d, cx, cy, color, size=28):
    """cx, cy 为图标加权视觉中心；上下两本等大 22×11 堆叠"""
    bw, bh = 22, 11
    # 上书
    bx1 = cx - bw // 2
    by2 = cy - 11
    d.rectangle([bx1, by2, bx1 + bw, by2 + bh], outline=color, width=2)
    d.line([(bx1 + 4, by2 + 2), (bx1 + 4, by2 + bh - 2)], fill=color, width=1)
    # 下书（与上书共享边 cy，无缝堆叠）
    by1 = cy
    d.rectangle([bx1, by1, bx1 + bw, by1 + bh], outline=color, width=2)
    d.line([(bx1 + 4, by1 + 2), (bx1 + 4, by1 + bh - 2)], fill=color, width=1)


def main():
    img = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(img)

    # 外框
    d.rounded_rectangle([36, 36, W - 36, H - 36], radius=20, outline=INK_SOFT, width=2)

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
    tleft(d, "阅读排行", title_x, 92, font(36, bold=True), INK)
    tleft(d, "READING RANKING · 阅读排行", title_x, 142, font(13), INK_SOFT)

    # X 关闭按钮（右上角）
    cx_b, cy_b, r_b = 1180, 120, 28
    d.ellipse([cx_b - r_b, cy_b - r_b, cx_b + r_b, cy_b + r_b], outline=INK_SOFT, width=2)
    d.text((cx_b, cy_b), "×", font=font(28, bold=True), fill=INK, anchor="mm")

    # 顶部分隔线
    d.line([(60, 200), (W - 60, 200)], fill=INK_SOFT, width=2)

    # 排序胶囊框（右上）
    d.rounded_rectangle([890, 90, 1130, 150], radius=30, outline=INK, width=2)
    # v2.3.8：中线竖线 x=1010 分割「时长」「日均」两半（按需求「· 时长 丨 日均」）
    d.line([(1010, 100), (1010, 140)], fill=INK_SOFT, width=2)

    # 6 行分隔线
    ROW_TOP0 = 260
    ROW_H = 215
    for i in range(6):
        top = ROW_TOP0 + i * ROW_H
        if i < 5:
            d.line([(60, top + 200), (W - 60, top + 200)], fill=INK_SOFT, width=1)

    # ===== 底部 tab 框（圆角 radius=40 严格按设计稿） + tab 图标 + tab 文字（32pt 居中）=====
    TAB_Y0, TAB_Y1 = 1545, 1625          # 高 80px
    TAB1_X0, TAB1_X1 = 80, 300           # 宽 220px；中点 cx1 = 190
    TAB2_X0, TAB2_X1 = 320, 540          # 宽 220px；中点 cx2 = 430
    TAB_CY = 1585                         # vertical center

    # 左 tab：指标（白底黑字，柱状图黑 icon）
    d.rounded_rectangle([TAB1_X0, TAB_Y0, TAB1_X1, TAB_Y1], radius=40, outline=INK, width=2)
    draw_bar_icon(d, 130, TAB_CY, INK)
    ccenter(d, "指标", 210, TAB_CY, font(32, bold=True), INK)

    # 右 tab：排行（黑底白字，书本白 icon，当前页选中）
    d.rounded_rectangle([TAB2_X0, TAB_Y0, TAB2_X1, TAB_Y1], radius=40, fill=INK, outline=INK, width=2)
    draw_book_icon(d, 370, TAB_CY, WHITE)
    ccenter(d, "排行", 450, TAB_CY, font(32, bold=True), WHITE)

    # 右下翻页框（与 tab 同款）
    d.rounded_rectangle([820, 1545, 1190, 1625], radius=40, outline=INK, width=2)
    d.line([(930, 1545), (930, 1625)], fill=INK_SOFT, width=1)
    d.line([(1080, 1545), (1080, 1625)], fill=INK_SOFT, width=1)
    # v2.3.7：‹ › 箭头直接画在底图，左格/右格严格居中对齐（anchor="mm"）
    # 左格 [820,930] 中心 x=875；右格 [1080,1190] 中心 x=1135；垂直中心 y=1585
    # launcher 只画中格 [930,1080] 的页码数字
    d.text((875, 1585), "‹", font=font(28, bold=True), fill=INK, anchor="mm")
    d.text((1135, 1585), "›", font=font(28, bold=True), fill=INK, anchor="mm")

    out = os.path.join(BASE, "ui", "ranking_bg.png")
    img.save(out, "PNG", optimize=True)
    print(f"saved: {out}  size={img.size}")


if __name__ == "__main__":
    main()
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v2.1 dashboard_bg.png · 单页 dashboard 背景生成器
- Noto Serif SC 衬线体（按效果图）
- 配色 #FFFFFF / #161616 / #BDB8AB（按设计说明）
- 字段无单位（按效果图）
- 累计时长在下方四栏首位（按设计说明对调）
- 标题 "Yunindex阅读统计"（按用户要求替换 阅痕）
- 水印 "Kindle"（按用户要求替换 阅）
- Logo 剪影小男孩（按用户要求 P 干净后使用）
- 年份切换在 footer 右下（按用户要求）
- 柱状图时间/合计/金句 留给 compose.py 动态绘制
"""

import os
from PIL import Image, ImageDraw, ImageFont

W, H = 1272, 1696
XL = 100  # 全局左缘基线（所有标题/标签/值的左缘统一基线）

# === 配色（设计说明）===
WHITE = (255, 255, 255)
INK = (22, 22, 22)            # #161616 主文字
INK_SOFT = (189, 184, 171)    # #BDB8AB 分割线/次级文字
WATER = (218, 218, 218)       # 淡灰水印（按用户 v13.1 第三轮指正：与白底同层级，不挡字线）

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
    bbox = d.textbbox((0, 0), text, font=fnt)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    d.text((cx - tw / 2, cy - th / 2), text, font=fnt, fill=fill)


def main():
    img = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(img)

    # === 全局左缘基线（统一所有字段竖向左对齐，与外框内边距一致）===
    # XL 由模块顶部全局常量定义，所有标题/标签/值的左缘统一基线 XL=100

    # === 外框（细线圆角矩形，浅灰非纯黑，按设计稿）===
    pad = 36
    d.rounded_rectangle(
        [pad, pad, W - pad, H - pad],
        radius=20, outline=INK_SOFT, width=2  # R36: 外框线加粗 1→2，颜色不变（灰 INK_SOFT）
    )

    # === 顶部 header（y=36..200）===
    # 剪影 logo
    logo = Image.open(LOGO_PATH).convert("RGBA")
    lh = 64
    lw = int(logo.size[0] * lh / logo.size[1])
    logo_r = logo.resize((lw, lh), Image.LANCZOS)
    # 黑色像素：直接当墨色；白色透明
    logo_rgb = Image.new("RGB", (lw, lh), WHITE)
    for y in range(lh):
        for x in range(lw):
            r, g, b, a = logo_r.getpixel((x, y))
            if a > 128 and r < 128:
                logo_rgb.putpixel((x, y), INK)
    img.paste(logo_rgb, (86, 88))

    # 标题 "Yunindex阅读统计"（左对齐，距 logo 24px）
    title_x = 86 + lw + 32
    tleft(d, "Yunindex阅读统计", title_x, 92, font(36, bold=True), INK)
    # 副标 "READING LEDGER · 阅读数据面板"
    tleft(d, "READING LEDGER · 阅读数据面板", title_x, 142, font(13), INK_SOFT)

    # 右上角关闭按钮：细线圆 + ×（用 PIL anchor='mm' 直接居中，最稳）
    cx_b, cy_b, r_b = 1180, 120, 28
    d.ellipse([cx_b - r_b, cy_b - r_b, cx_b + r_b, cy_b + r_b],
              outline=INK_SOFT, width=2)
    d.text((cx_b, cy_b), "×", font=font(28, bold=True), fill=INK, anchor="mm")

    # header 与今日阅读区分隔线 y=200（R11: 恢复，皇上明确要求保留）
    d.line([(60, 200), (W - 60, 200)], fill=INK_SOFT, width=2)

    # === 今日阅读（y=240..490）===
    tleft(d, "今日时长", XL, 252, font(28, bold=True), INK)  # R46: 今日阅读→今日时长
    tleft(d, "TODAY", XL, 296, font(13), INK_SOFT)

    # === 第一排四栏（y=555..690）：本周阅读 / 本月日均 / 本月时长 / 连续阅读 ===
    # R39: 改为 4 字段，列宽/起点/竖线 与下方"本年统计"四卡【完全一致】
    # 列宽 = (W - 60 - XL) // 4 = 278；起点 [100, 378, 656, 934]
    cw4_top = (W - 60 - XL) // 4  # = 278，与四卡 cw4_align 完全一致
    col4_top_left = [XL + i * cw4_top for i in range(4)]  # [100, 378, 656, 934]
    # 3 条竖线（与四卡一致：x = 右字段起点 - 40 = [338, 616, 894]）
    for i in range(1, 4):
        x_line = col4_top_left[i] - 40
        d.line([(x_line, 555), (x_line, 670)], fill=INK_SOFT, width=2)
    labels_top = ["本周时长", "本月日均", "本月时长", "连续天"]  # R46: 本周阅读→本周时长, 连续阅读→连续天
    for i, (xL, lb) in enumerate(zip(col4_top_left, labels_top)):
        tleft(d, lb, xL, 555, font(28, bold=True), INK)
    # 数值留给 compose 画（左对齐 @ y=615）
    # 第一排底分割线 y=690
    d.line([(60, 690), (W - 60, 690)], fill=INK_SOFT, width=2)

    # === 本周节奏（y=830..1010；R38 标题上移回 y=750，柱体保持 830..1010）===
    tleft(d, "本周节奏 · WEEKLY RHYTHM", XL, 750, font(28, bold=True), INK)  # R38: 770→750 标题上移 20

    bar_x0, bar_x1 = 60, W - 60
    inner_w = bar_x1 - bar_x0
    n = 7
    gap = 76                  # R33：间距 46→76，柱体进一步变窄
    sq = (inner_w - gap * (n - 1)) // n   # ≈ 99px 柱宽
    bar_y_top, bar_y_bot = 830, 1010  # R35: 整体下移 20（与三卡块底 y=690 留 140px 呼吸；与本年段 y=1108 留 78px）
    # 不画空柱占位框（按用户 v13.1 第三轮：无数据时不展示）

    # === "Kindle" 水印（淡灰大字，限制高度避免压柱顶数字+柱底日期）==="
    wm_text = "Kindle"
    wm_color = WATER  # 淡灰 #DADADA 同层级
    wm_max_h = (bar_y_bot - bar_y_top) * 0.72  # 限制高度 ≤ 柱区高的 72%
    for wm_size in range(180, 50, -10):     # 水印 ×0.5 缩小（用户"0.5 倍即完美"）
        f_wm = font(wm_size, bold=True)
        bbox = d.textbbox((0, 0), wm_text, font=f_wm)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        if tw <= inner_w * 0.85 and th <= wm_max_h:
            break
    wm_cx = W // 2
    wm_cy = (bar_y_top + bar_y_bot) // 2
    # 用 PIL anchor='mm' 精确居中
    d.text((wm_cx, wm_cy), wm_text, font=f_wm, fill=wm_color, anchor="mm")

    # 柱底日期标签 一/二/三/四/五/六/日（在水印之后画，盖住水印底缘）
    days = ["一", "二", "三", "四", "五", "六", "日"]
    for i, dn in enumerate(days):
        x = bar_x0 + i * (sq + gap) + sq // 2
        tcenter(d, dn, x, bar_y_bot + 18, font(18), INK)
    # 合计不写在背景，交给 compose 条件渲染（无数据时不展示）

    # === "Kindle" 水印（淡灰大字，限制高度避免压柱顶数字+柱底日期；柱区上方无段顶分割线）===

    # === 本年统计（y=1108..1370，R16 段标题上移 20: 1128→1108）===
    tleft(d, "本年统计 · THIS YEAR", XL, 1108, font(28, bold=True), INK)  # R9: 1108→1128；R16: 1128→1108（上移一点，与"累计时长"标签行 1173 间距 65pt，与三卡段→标签 68pt 节奏统一）
    n4 = 4
    # R14: 四卡严格 4 等分 — 列宽 = (W - 60 - XL) // 4 = (1212 - 100) // 4 = 278pt
    # 起点 = XL + i*278 = [100, 378, 656, 934]，终点 = [378, 656, 934, 1212]
    # 第 1 字段"累计时长"起点 100 = 段标题"本年统计 · THIS YEAR"起点 XL=100（字间距对齐）
    # "完成阅读" 起点 934 + 文本 ~156pt = 终点 ~1090 < 1212（再无超界）
    cw4_align = (W - 60 - XL) // n4  # = 278
    col4_left = [XL + i * cw4_align for i in range(n4)]  # [100, 378, 656, 934]
    col4_x = [xL + cw4_align // 2 for xL in col4_left]  # 列中心
    labels4 = ["累计时长", "累计天", "读过", "读完"]  # R46: 累计阅读→累计天, 在读书籍→读过, 完成阅读→读完
    # R15: 恢复 3 条竖分隔线（全部恢复 + 节奏统一）
    # 竖线 x = "右字段起点 - 40pt"（与三卡"本周阅读|本月日均"竖线距"本月日均"起点 40pt 严格一致）
    # R15 又 "向下一点移动"：y 起点从 R14 的 1163 → 1173（对齐字段基线 1173），终点 1289 保持
    # 竖线高度 1173-1289 = 116pt（三卡竖线 555-670 = 115pt 严格一致）
    # 计算每条竖线 x = col4_left[i+1] - 40，y = 1173-1289
    for i in range(1, n4):  # i=1,2,3 → 3 条竖线
        x_line = col4_left[i] - 40  # 右字段起点偏左 40pt
        d.line([(x_line, 1173), (x_line, 1289)], fill=INK_SOFT, width=2)
    # 四字段标签起点 = col4_left[i]（与段标题起点 XL=100 严格对齐）
    # R14: 起点 100/378/656/934；y=1173（R12 字段上移 5）
    # R12/R13 28pt bold（与三卡字段字号粗细严格一致）
    for i, (cx, xL, lb) in enumerate(zip(col4_x, col4_left, labels4)):
        tleft(d, lb, xL, 1173, font(28, bold=True), INK)
    # 数值留给 compose（左对齐 @ y=1233，R12: 字段→值间距 60 与三卡一致，1173+60=1233）
    # 本年统计下分割线 y=1320（R11: R10 误删，恢复）
    d.line([(60, 1320), (W - 60, 1320)], fill=INK_SOFT, width=2)

    # === 金句区（y=1360..1450，R9 下移 20）===
    # 金句由 compose 条件渲染，居中 @ y=1360/1408
    # 金句下分割线 y=1450（R11: R10 误删，恢复）
    d.line([(60, 1450), (W - 60, 1450)], fill=INK_SOFT, width=2)

    # === footer（R10: footer 距底部外框 80-100px padding；同时把数据每日自动同步字基线下移，与金句 meta 上行间距合理）===
    # 统一基线：左"数据每日自动同步 · AUTO SYNC" 与 右年份按钮中心 y=1545
    tleft(d, "数据每日自动同步 · AUTO SYNC", XL, 1534, font(18), INK_SOFT)  # R33: 14→18pt 放大，top_y 1538→1534
    # 右：年份切换按钮 < 2026 >（R33：等比放大 1.3 倍，保持右对齐边距 W-60）
    ar_w, ar_h, ar_gap = 90, 65, 16
    ar_total = ar_w * 3 + ar_gap * 2
    ar_x1 = W - 60 - ar_total
    ar_y0 = 1525
    d.rounded_rectangle(
        [ar_x1, ar_y0, ar_x1 + ar_total, ar_y0 + ar_h],
        radius=ar_h // 2, outline=INK, width=2
    )
    # < 和 > 符号 34pt，用 anchor='mm' 精确垂直+水平居中于各自格子中心（R34 修正：tcenter 只水平居中、top_y 定位会偏下）
    btn_cy = ar_y0 + ar_h // 2  # 按钮垂直中心 = 1557
    d.text((ar_x1 + ar_w // 2, btn_cy), "<", font=font(34, bold=True), fill=INK, anchor="mm")
    # 年份留白（年份由 Yunindex阅读统计.sh 动态渲染）
    d.text((ar_x1 + (ar_w + ar_gap) * 2 + ar_w // 2, btn_cy), ">", font=font(34, bold=True), fill=INK, anchor="mm")

    # === "Kindle" 水印（已在柱状图区先画，避开本年统计）===

    # 写入 ui/ 目录，与 compose.py --bg 路径一致（之前写到 BASE/ 导致漂移）
    out = os.path.join(BASE, "ui", "dashboard_bg.png")
    img.save(out, "PNG", optimize=True)
    print(f"saved: {out}  size={img.size}")


if __name__ == "__main__":
    main()

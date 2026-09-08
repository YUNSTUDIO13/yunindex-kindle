#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Yunindex v2.3.33: NotoSerifSC 子集化（Kindle fbink 提速核心）
# 覆盖：GB2312 全表(汉字6763+符号) + ASCII + Latin-1/Ext-A + 常用标点/箭头/几何/假名/全角
# 用法: python3 subset_fonts.py <in.otf> <out.otf>
import sys
from fontTools import subset

def build_charset():
    chars = set()
    # GB2312 全表（含 6763 汉字 + 全角符号/假名/注音等；webnovel 书名作者几乎全覆盖）
    for hi in range(0xA1, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                chars.add(bytes([hi, lo]).decode('gb2312'))
            except Exception:
                pass
    # 显式 Unicode 区间（GB2312 之外的保险）
    ranges = [
        (0x0020, 0x007E),   # ASCII
        (0x00A0, 0x00FF),   # Latin-1（é/· 等外文作者名）
        (0x0100, 0x017F),   # Latin Extended-A
        (0x2000, 0x206F),   # 通用标点 … — “ ” ‘ ’
        (0x2190, 0x21FF),   # 箭头 →（起止时间用）
        (0x2460, 0x24FF),   # 圈数字（以防万一）
        (0x25A0, 0x25FF),   # 几何符号 ●（排序胶囊用）
        (0x3000, 0x303F),   # CJK 标点 。、《》「」
        (0x3040, 0x30FF),   # 日文假名（日系书名）
        (0x31F0, 0x31FF),   # 片假名扩展
        (0xFF00, 0xFFEF),   # 全角英数
    ]
    for a, b in ranges:
        for cp in range(a, b + 1):
            chars.add(chr(cp))
    return chars

def main():
    src, dst = sys.argv[1], sys.argv[2]
    chars = build_charset()
    text = ''.join(sorted(chars))
    opts = subset.Options()
    opts.name_IDs = ['*']           # 保留字体名（OFL 要求）
    opts.name_legacy = True
    opts.name_languages = ['*']
    opts.notdef_outline = True      # .notdef 保留字形轮廓
    opts.recalc_bounds = True
    opts.drop_tables += ['DSIG', 'BASE', 'GDEF', 'GSUB', 'GPOS']  # stb_truetype 不做 shaping，全扔
    # v2.3.33-hotfix：必须保留 CFF hinting！真机 fbink 走 FreeType 时会应用 hint，
    #   剥掉后 24-36px 小字号边缘发虚（实测"字体很模糊"即此因）。保留 hint 体积仅略增。
    opts.hinting = True
    opts.desubroutinize = False     # 保留 subr（CFF 体积更小）
    font = subset.load_font(src, opts)
    ss = subset.Subsetter(opts)
    ss.populate(text=text)
    ss.subset(font)
    font.save(dst)

if __name__ == '__main__':
    main()

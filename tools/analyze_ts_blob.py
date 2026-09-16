# -*- coding: utf-8 -*-
"""反推 Tiny Swords Tilemap_colorN.png 的 4x4 blob 编码。

思路：blob 图集里"某一侧没有同类邻居"的那一格，会在该侧画出**崖壁描边**
（明显更暗的一条带）。于是逐格比较四条边带的平均亮度与格子内部平均亮度，
边带显著偏暗 = 该侧封闭（不连通）。

输出 4x4 表：每格标出 上/下/左/右 哪些是 Open（连通）。
"""
import os
from PIL import Image

SRC = r"D:\SteamPunkExtraction\images\Tiny Swords (Free Pack)\Terrain\Tileset"
TILE = 64
BAND = 10

OUT = r"C:\Users\Administrator\WorkBuddy\2026-09-15-23-06-42\_blob_probe.txt"


def band_mean(img, box):
    reg = img.crop(box).convert("L")
    px = list(reg.getdata())
    return sum(px) / max(1, len(px))


def analyze(path):
    img = Image.open(path).convert("RGBA")
    lines = [os.path.basename(path), ""]
    table = []
    for row in range(4):
        rowtxt = []
        rowdata = []
        for col in range(4):
            x0, y0 = col * TILE, row * TILE
            interior = (x0 + BAND, y0 + BAND, x0 + TILE - BAND, y0 + TILE - BAND)
            mi = band_mean(img, interior)
            mt = band_mean(img, (x0, y0, x0 + TILE, y0 + BAND))
            mb = band_mean(img, (x0, y0 + TILE - BAND, x0 + TILE, y0 + TILE))
            ml = band_mean(img, (x0, y0, x0 + BAND, y0 + TILE))
            mr = band_mean(img, (x0 + TILE - BAND, y0, x0 + TILE, y0 + TILE))
            # 边带比内部暗 18% 以上 → 认为是崖壁（封闭）
            th = mi * 0.82
            closed = {"U": mt < th, "D": mb < th, "L": ml < th, "R": mr < th}
            open_ = {k: (not v) for k, v in closed.items()}
            letters = "".join(k for k in "UDLR" if closed[k]) or "-"
            rowtxt.append("%s" % letters.ljust(4))
            rowdata.append({"row": row, "col": col, "closed": closed,
                            "mi": round(mi, 1), "U": round(mt, 1), "D": round(mb, 1),
                            "L": round(ml, 1), "R": round(mr, 1)})
        table.append(rowdata)
        lines.append("row%d: %s" % (row, "  ".join(rowtxt)))
    lines.append("")
    lines.append("明细（closed=该侧画了崖壁；O=连通）：")
    for rowdata in table:
        for d in rowdata:
            o = "".join(k for k in "UDLR" if not d["closed"][k]) or "-"
            lines.append("  (%d,%d) idx=%2d  open=%-4s  内部=%5.1f U=%5.1f D=%5.1f L=%5.1f R=%5.1f"
                         % (d["row"], d["col"], d["row"] * 4 + d["col"], o,
                            d["mi"], d["U"], d["D"], d["L"], d["R"]))
    return "\n".join(lines)


def main():
    out = []
    for i in range(1, 6):
        p = os.path.join(SRC, "Tilemap_color%d.png" % i)
        out.append("=" * 70)
        out.append(analyze(p))
    open(OUT, "w", encoding="utf-8").write("\n".join(out))
    print("written", OUT)


main()

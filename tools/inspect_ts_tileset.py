#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
inspect_ts_tileset.py — 读 Tiny Swords 官方地形图集，逐格拆 9x6 并输出特征报告。

用途：Tilemap_color1..5.png 都是 576x384 = 64px 网格 x 9 列 x 6 行。
用 Godot TileSet 之前必须弄清每格到底是什么（地形内部块 / 边缘块 / 角块 /
悬崖块 / 特殊块），否则拼出来的地图会跟素材包里看到的完全不同。

只对 Tilemap_colorN.png 做只读分析，不写任何游戏资源。
"""
import os
import sys

from PIL import Image

ROOT = r"D:\SteamPunkExtraction\images\Tiny Swords (Free Pack)\Terrain\Tileset"
TILE = 64
COLS, ROWS = 9, 6


def classify_pixel(r, g, b):
    """把像素粗略归类：草绿 / 岩石棕 / 水蓝 / 雪白 / 暗描边 / 其他。"""
    mx, mn = max(r, g, b), min(r, g, b)
    if mx < 60:
        return "D"                      # 暗线（描边）
    if g > r + 22 and g > b + 22:
        return "G"                      # 草绿
    if b > r + 25 and b > g + 8:
        return "B"                      # 水蓝
    if mx - mn < 26:
        return "S" if mx > 170 else "K" # 雪白 / 灰石
    if r >= g >= b:
        return "R"                      # 岩棕/土
    return "?"


def block_stats(img, cx, cy):
    """返回一块 64x64 的统计特征。"""
    x0, y0 = cx * TILE, cy * TILE
    blk = img.crop((x0, y0, x0 + TILE, y0 + TILE)).convert("RGBA")
    px = blk.load()
    opaque = 0
    total = TILE * TILE
    acc = [0, 0, 0]
    cls_count = {}
    for y in range(TILE):
        for x in range(TILE):
            r, g, b, a = px[x, y]
            key = classify_pixel(r, g, b)
            cls_count[key] = cls_count.get(key, 0) + 1
            if a > 32:
                opaque += 1
                acc[0] += r
                acc[1] += g
                acc[2] += b
    n = max(opaque, 1)
    avg = (acc[0] // n, acc[1] // n, acc[2] // n)

    # 四条边缘带的「不透明像素占比」—— 低于 ~0.9 说明这块在这一侧是切开的
    def band_alpha(band):
        hit = cnt = 0
        for coord in band:
            r, g, b, a = px[coord[0], coord[1]]
            cnt += 1
            if a > 32:
                hit += 1
        return hit / max(cnt, 1)

    top = band_alpha([(x, 0) for x in range(TILE)])
    bottom = band_alpha([(x, TILE - 1) for x in range(TILE)])
    left = band_alpha([(0, y) for y in range(TILE)])
    right = band_alpha([(TILE - 1, y) for y in range(TILE)])

    # 纵向落差：把块上下两半的主类分开记，悬崖块上=草绿 下=岩石
    def dominant(y0f, y1f):
        c = {}
        for y in range(int(TILE * y0f), int(TILE * y1f)):
            for x in range(TILE):
                r, g, b, a = px[x, y]
                if a <= 32:
                    continue
                k = classify_pixel(r, g, b)
                c[k] = c.get(k, 0) + 1
        if not c:
            return "-"
        return max(c.items(), key=lambda kv: kv[1])[0]

    top_cls = dominant(0.0, 0.34)
    bot_cls = dominant(0.66, 1.0)
    return {
        "alpha": opaque / total,
        "avg": avg,
        "edges": (top, bottom, left, right),
        "top_cls": top_cls,
        "bot_cls": bot_cls,
        "cls": sorted(cls_count.items(), key=lambda kv: -kv[1])[:3],
    }


def main():
    names = sys.argv[1:] or ["Tilemap_color1.png"]
    for name in names:
        path = os.path.join(ROOT, name)
        if not os.path.exists(path):
            print("missing:", path)
            continue
        img = Image.open(path)
        print("=" * 78)
        print("%s  (%dx%d)" % (name, img.width, img.height))
        print("=" * 78)
        # 先看整体主色
        for cy in range(ROWS):
            row_desc = []
            for cx in range(COLS):
                s = block_stats(img, cx, cy)
                row_desc.append("%s%s" % (s["top_cls"], s["bot_cls"]))
            print("row %d  %s" % (cy, "  ".join(row_desc)))
        print("-" * 78)
        print("col,row  alpha%  avgRGB           edges(T,B,L,R)          T/B类")
        for cy in range(ROWS):
            for cx in range(COLS):
                s = block_stats(img, cx, cy)
                e = s["edges"]
                print("%d,%d   %5.1f  (%3d,%3d,%3d)  (%.2f,%.2f,%.2f,%.2f)  %s/%s  cls=%s" % (
                    cx, cy, s["alpha"] * 100, s["avg"][0], s["avg"][1], s["avg"][2],
                    e[0], e[1], e[2], e[3], s["top_cls"], s["bot_cls"],
                    "".join("%s%d" % (k, v) for k, v in s["cls"])))


if __name__ == "__main__":
    main()

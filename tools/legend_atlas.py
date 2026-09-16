# -*- coding: utf-8 -*-
"""tools/legend_atlas.py — 把地图用到的每张官方地形图集拼成一张对照表。

为什么需要它：全图预览出来是一片绿+一片青，光看分不清哪块是"哪个群系的普通地面"、
哪块是"不可通行的深水"、哪块是"可涉水浅滩"。靠猜很容易把沼泽地面当成水去调参数。

输出：每行一个来源（群系名 / 水），左边是该图的完整 atlas，右边是 16 个 blob 变体放大图。

用法：python tools/legend_atlas.py <输出png>
"""
import json
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = os.path.join(ROOT, "Data", "config.json")
TILES = os.path.join(ROOT, "Assets", "Art", "Tiles", "TS")
SRC_TILE = 64
BLOB_N = 16
ZOOM = 2


def load_rows():
    with open(CFG, encoding="utf-8") as f:
        d = json.load(f)
    rows = []
    for b in d["map"]["biomes"]:
        rows.append(("biome%d %s" % (b["id"], b["name"]), b["tileset"]))
    rows.append(("WALL/impassable", "water_bg.png"))
    return rows


def main() -> int:
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "generated_images", "atlas", "_atlas_legend.png")
    rows = load_rows()

    blob_w = 4 * SRC_TILE * ZOOM          # 右侧 4x4 blob 区块放大
    atlas_w = 9 * SRC_TILE                # 原始图集宽（576）
    pad_ = 12
    label_h = 28
    row_h = max(atlas_w * 0, SRC_TILE * 6) # 图集高 384
    total_h = sum(max(blob_w // 4 * 4, 0) and 0 or 0 for _ in rows)  # 占位，真实高度下面算
    row_h = 4 * SRC_TILE * ZOOM           # 每行统一 512 高
    W = pad_ + atlas_w + pad_ + blob_w + pad_
    H = pad_ + len(rows) * (label_h + row_h + pad_)

    canvas = Image.new("RGB", (W, H), (24, 24, 28))
    draw = ImageDraw.Draw(canvas)

    y = pad_
    for name, fname in rows:
        path = os.path.join(TILES, fname)
        draw.text((pad_, y + 6), "%s   <-  %s" % (name, fname), fill=(235, 235, 240))
        y += label_h
        if not os.path.exists(path):
            draw.text((pad_, y + 20), "(缺失)", fill=(255, 90, 90))
            y += row_h + pad_
            continue
        im = Image.open(path).convert("RGBA")
        # 左：原图集（补一层棋盘底，方便看透明区）
        bg = Image.new("RGB", im.size, (60, 60, 66))
        bg.paste(im, (0, 0), im)
        canvas.paste(bg, (pad_, y))
        # 右：4x4 blob 区块放大
        blob = im.crop((0, 0, 4 * SRC_TILE, 4 * SRC_TILE))
        bb = Image.new("RGB", blob.size, (60, 60, 66))
        bb.paste(blob, (0, 0), blob)
        bb = bb.resize((4 * SRC_TILE * ZOOM, 4 * SRC_TILE * ZOOM), Image.NEAREST)
        canvas.paste(bb, (pad_ + atlas_w + pad_, y))
        y += row_h + pad_

    canvas.save(out)
    print("OK %s  %dx%d" % (out, canvas.width, canvas.height))
    return 0


if __name__ == "__main__":
    sys.exit(main())

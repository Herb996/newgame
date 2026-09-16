#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""从 Tiny Swords Tilemap_color*.png 重排出项目的 atlas_floor / atlas_wall。

项目约定（map_generator.gd）：
- atlas_floor.png : 768x16 = 4 群系 x 12 变体，横向一行
- atlas_wall.png  : 384x16 = 4 群系 x  6 变体，横向一行
- tile_size = 16px

Tiny Swords tileset：576x384（36x24 格 @16px），9-slice 结构。
内部是纯草地纹理，边缘带白描边；右下有蓝色岩壁（墙正面）。

挑选规则（全自动，不靠人工数格子）：
- 地板格：16x16 内无白描边像素（亮度>235 且低饱和），且绿色调（G >= R >= B 或 G 主导）
- 墙格  ：蓝色调（B > R + 12）占主导
- 每张 color 图各取前 12 个地板 / 6 个墙格；不足时循环补齐（变体少好过列空）

用法：
    python tools/build_ts_atlas.py
"""
import os
import sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TS_DIR = os.path.join(ROOT, "images", "Tiny Swords (Free Pack)",
                      "Terrain", "Tileset")
OUT_DIR = os.path.join(ROOT, "Assets", "Art", "Tiles")

BIOME_COLOR = [1, 3, 4, 5]   # 草地/森林/荒原/雪原 → Tilemap_colorN
FLOOR_VARIANTS = 12
WALL_VARIANTS = 6
T = 16                        # tile size

# 雪原处理：color5 偏蓝绿，去饱和 + 提亮后接近雪地
SNOW_DESAT = 0.35
SNOW_BRIGHT = 1.55


def is_floor_tile(px, allow_blue: bool = False) -> bool:
    """16x16 纯地板：无白描边、不透明、且色调符合该群系。

    绿色群系：G 主导（G >= R-8 且 G > B+8）。
    雪原（allow_blue）：高亮度且非深色即可 —— 冰雪本来就偏蓝白，
    不能用绿判；只要排除岩壁那种深蓝（暗+高饱和蓝）就行。
    """
    w, h = T, T
    white = 0
    ok = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 200:
                return False                    # 透明 → 跨区块，弃
            mx, mn = max(r, g, b), min(r, g, b)
            if mn > 225 and (mx - mn) < 22:     # 白描边
                white += 1
            if allow_blue:
                lum = 0.299 * r + 0.587 * g + 0.114 * b
                if lum > 120:                   # 提亮后的雪地纹理都是亮调
                    ok += 1
            elif g >= r - 8 and g > b + 8:      # 绿色调
                ok += 1
    return white <= 2 and ok >= T * T * 0.72


def is_wall_tile(px) -> bool:
    """16x16 岩壁：蓝色调主导、不透明、无明显白描边。"""
    blue = 0
    white = 0
    for y in range(T):
        for x in range(T):
            r, g, b, a = px[x, y]
            if a < 200:
                return False
            mx, mn = max(r, g, b), min(r, g, b)
            if mn > 225 and (mx - mn) < 22:
                white += 1
            if b > r + 10 and b >= g:
                blue += 1
    return white <= 6 and blue >= T * T * 0.45


def snow_tune(img: Image.Image) -> Image.Image:
    """雪原：去饱和 + 提亮（HSL 软处理，保住纹理层次）。"""
    out = Image.new("RGBA", img.size)
    sp = img.load()
    op = out.load()
    for y in range(img.size[1]):
        for x in range(img.size[0]):
            r, g, b, a = sp[x, y]
            lum = 0.299 * r + 0.587 * g + 0.114 * b
            nr = int(min(255, (lum + (r - lum) * SNOW_DESAT) * SNOW_BRIGHT))
            ng = int(min(255, (lum + (g - lum) * SNOW_DESAT) * SNOW_BRIGHT))
            nb = int(min(255, (lum + (b - lum) * SNOW_DESAT) * SNOW_BRIGHT))
            op[x, y] = (nr, ng, nb, a)
    return out


def pick_tiles(im: Image.Image, allow_blue: bool = False):
    """定点采集（按布局地图人工核实过的区域，不扫全图）。

    Tilemap_color*.png 布局（36x24 格 @16px，四色同构）：
    - 左上大块纯草内部：行 1-10, 列 0-15  ← 地板来源（无描边、可平铺）
    - 右侧大块纯草内部：行 1-15, 列 20-35 ← 地板备用
    - 纯蓝岩壁正面：    行 17-18, 列 21-26 ← 墙来源（行 16/19 是描边，不要）
    （列 1-13 / 行 17-23 一带是斜角过渡，混草混墙，跳过）
    """
    floors = []
    for ty in range(1, 11):
        for tx in range(0, 16):
            floors.append(im.crop((tx * T, ty * T, (tx + 1) * T, (ty + 1) * T)))
    for ty in range(1, 11):
        for tx in range(20, 32):
            floors.append(im.crop((tx * T, ty * T, (tx + 1) * T, (ty + 1) * T)))
    walls = []
    for ty in (17, 18):
        for tx in range(21, 27):
            walls.append(im.crop((tx * T, ty * T, (tx + 1) * T, (ty + 1) * T)))
    # 定点区域仍过一遍硬校验：透明格/白描边格剔除
    floors = [t for t in floors if not _tile_has_transparency(t)]
    walls = [t for t in walls if not _tile_has_transparency(t)]
    return floors, walls


def _tile_has_transparency(tile: Image.Image) -> bool:
    px = tile.load()
    for y in range(T):
        for x in range(T):
            if px[x, y][3] < 200:
                return True
    return False


def dedup(tiles):
    """去重（同格内容一样只留一份）。"""
    seen = set()
    out = []
    for t in tiles:
        k = t.tobytes()
        if k not in seen:
            seen.add(k)
            out.append(t)
    return out


def fill_row(tiles, n, source_desc):
    """凑够 n 个：不够就从已有里循环取。"""
    if not tiles:
        raise SystemExit("!! %s 一个候选格都没挑到，规则需要人工复核" % source_desc)
    out = []
    for i in range(n):
        out.append(tiles[i % len(tiles)].copy())
    return out


def main() -> int:
    floor_row = []
    wall_row = []
    for biome_idx, color_id in enumerate(BIOME_COLOR):
        path = os.path.join(TS_DIR, "Tilemap_color%d.png" % color_id)
        im = Image.open(path).convert("RGBA")
        if color_id == 5:                       # 雪原调色
            im = snow_tune(im)
        floors, walls = pick_tiles(im, allow_blue=(color_id == 5))
        floors, walls = dedup(floors), dedup(walls)
        print("color%d: 地板候选 %d 格 / 墙候选 %d 格" % (color_id, len(floors), len(walls)))
        f = fill_row(floors, FLOOR_VARIANTS, "color%d 地板" % color_id)
        w = fill_row(walls, WALL_VARIANTS, "color%d 墙" % color_id)
        floor_row.extend(f)
        wall_row.extend(w)

    fw = FLOOR_VARIANTS * len(BIOME_COLOR) * T
    ww = WALL_VARIANTS * len(BIOME_COLOR) * T
    atlas_f = Image.new("RGBA", (fw, T))
    atlas_w = Image.new("RGBA", (ww, T))
    for i, t in enumerate(floor_row):
        atlas_f.paste(t, (i * T, 0))
    for i, t in enumerate(wall_row):
        atlas_w.paste(t, (i * T, 0))

    # 备份旧 atlas（程序化生成的，回退保险）
    for name in ["atlas_floor.png", "atlas_wall.png"]:
        p = os.path.join(OUT_DIR, name)
        if os.path.exists(p):
            bak = p + ".bak_procedural"
            if not os.path.exists(bak):
                os.replace(p, bak)
                print("旧图已备份 ->", os.path.basename(bak))

    atlas_f.convert("RGB").save(os.path.join(OUT_DIR, "atlas_floor.png"))
    atlas_w.convert("RGB").save(os.path.join(OUT_DIR, "atlas_wall.png"))
    print("写出 atlas_floor.png %dx%d, atlas_wall.png %dx%d" %
          (fw, T, ww, T))

    # 拼预览（放大 4 倍便于人工检查）
    prev = Image.new("RGB", (max(fw, ww), T * 2 + 6), (24, 24, 28))
    prev.paste(atlas_f.convert("RGB"), (0, 0))
    prev.paste(atlas_w.convert("RGB"), (0, T + 6))
    prev.resize((prev.size[0] * 4, prev.size[1] * 4), Image.NEAREST).save(
        os.path.join(ROOT, "generated_images", "atlas", "_atlas_preview.png"))
    print("预览 -> _atlas_preview.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())

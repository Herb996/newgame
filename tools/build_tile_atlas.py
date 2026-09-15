# -*- coding: utf-8 -*-
"""
把 AI 生成的 1024x1024 无缝地形纹理，切成游戏用的瓦片变体。

v3（数据驱动群系）：
  群系数 N = Data/config.json 的 map.biomes 长度，不再写死 4。
  每个 biome 若有 floor_src，用对应 AI 纹理采样 12 个变体；否则程序化生成。
  墙体用一份共享金属纹理（所有群系共用，仅放置在不同列块）。
  图集列数随 N 自动缩放：地板 = N*12 列，墙 = N*6 列，墙顶 = N*6 列。

  加新地形（雪原等）只需在 config 的 map.biomes 加一项并（可选）放一张
  floor_src 纹理，重跑本脚本即可，GDScript 零改动。
"""
import os
import json
import random
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "Assets", "Art", "Raw", "Terrain")
OUT = os.path.join(ROOT, "Assets", "Art", "Tiles")
os.makedirs(OUT, exist_ok=True)

TILE = 16              # 瓦片边长（与 config map.tile_size 一致）
SRC_SIZE = 512         # 纹理降采样后的尺寸
FLOOR_VARIANTS = 12    # 单群系地板变体数
WALL_VARIANTS = 6      # 单群系墙体变体数
CONTRAST = 0.82        # 对比度压缩系数（越小越平，越不容易看出格子）
WALL_DARKEN = 0.80     # 墙体整体压暗
DEFAULT_WALL_SRC = "Seamless_tileable_texture_of_a_2026-09-14T23-35-17.png"


def load_biomes():
    with open(os.path.join(ROOT, "Data", "config.json"), encoding="utf-8") as f:
        cfg = json.load(f)
    biomes = cfg["map"]["biomes"]
    if not biomes:
        raise RuntimeError("config.map.biomes 为空")
    return biomes


def clamp255(v):
    return max(0, min(255, int(round(v))))


def sample_tiles(im, count, tile, protect_br=True, seed=7):
    """在图上均匀采样 count 个互不重叠的 tile 方块。"""
    w, h = im.size
    cols, rows = w // tile, h // tile
    cells = []
    for gy in range(rows):
        for gx in range(cols):
            x0, y0 = gx * tile, gy * tile
            if protect_br and x0 > w * 0.74 and y0 > h * 0.85:
                continue
            if gx == 0 or gy == 0 or gx == cols - 1 or gy == rows - 1:
                continue
            cells.append((x0, y0))
    rnd = random.Random(seed)
    rnd.shuffle(cells)
    if len(cells) < count:
        raise RuntimeError("可用采样块不足：%d < %d" % (len(cells), count))
    picked = cells[:count]
    rnd.shuffle(picked)
    return [(x0, y0) for (x0, y0) in picked]


def extract(im, count, seed):
    """采样并归一化，返回 tile Image 列表（全部统一亮度与对比度）。"""
    boxes = sample_tiles(im, count, TILE, seed=seed)
    raw = [np.asarray(im.crop((x, y, x + TILE, y + TILE))).astype(np.float32)
           for (x, y) in boxes]
    target_mean = float(np.mean([a.mean() for a in raw]))
    target_std = float(np.mean([a.std() for a in raw])) * CONTRAST
    rnd = random.Random(seed * 31 + 7)
    out = []
    for a in raw:
        s = a.std()
        if s < 1e-3:
            s = 1e-3
        n = (a - a.mean()) / s * target_std + target_mean
        n *= rnd.uniform(0.97, 1.03)
        out.append(Image.fromarray(np.clip(n, 0, 255).astype(np.uint8), "RGB"))
    return out


def procedural_floor(base, count, seed):
    """无 AI 源图时，按基色程序化生成 count 个带噪点的地面瓦片。"""
    rnd = random.Random(seed)
    br, bg, bb = float(base[0]), float(base[1]), float(base[2])
    out = []
    for _i in range(count):
        img = Image.new("RGB", (TILE, TILE))
        px = img.load()
        bright = 0.82 + 0.32 * rnd.random()
        for y in range(TILE):
            for x in range(TILE):
                n = (rnd.random() - 0.5) * 0.16
                r = clamp255((br * bright + n) * 255)
                g = clamp255((bg * bright + n) * 255)
                b = clamp255((bb * bright + n) * 255)
                px[x, y] = (r, g, b)
        for _j in range(rnd.randint(1, 3)):
            sx, sy = rnd.randint(2, TILE - 3), rnd.randint(2, TILE - 3)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    xx, yy = sx + dx, sy + dy
                    if 0 <= xx < TILE and 0 <= yy < TILE:
                        p = px[xx, yy]
                        px[xx, yy] = (int(p[0] * 0.7), int(p[1] * 0.7), int(p[2] * 0.7))
        out.append(img)
    return out


def main():
    biomes = load_biomes()
    N = len(biomes)
    print("=== 群系数 N = %d ===" % N)

    # ---- 地板图集：每个 biome 12 变体，草地等无源图者程序化 ----
    print("=== 地板图集 ===")
    floor_tiles = []
    for i, b in enumerate(biomes):
        name = b.get("name", "?")
        src = b.get("floor_src", "")
        if src:
            im = Image.open(os.path.join(RAW, src)).convert("RGB").resize(
                (SRC_SIZE, SRC_SIZE), Image.LANCZOS)
            tiles = extract(im, FLOOR_VARIANTS, seed=100 + i)
            print("  [%s] AI 纹理 %d 变体" % (name, len(tiles)))
        else:
            tiles = procedural_floor(b.get("floor", [0.3, 0.3, 0.3]),
                                     FLOOR_VARIANTS, seed=200 + i)
            print("  [%s] 程序化 %d 变体" % (name, len(tiles)))
        floor_tiles.extend(tiles)
    atlas = Image.new("RGB", (FLOOR_VARIANTS * N * TILE, TILE), (0, 0, 0))
    for i, t in enumerate(floor_tiles):
        atlas.paste(t, (i * TILE, 0))
    dst = os.path.join(OUT, "atlas_floor.png")
    atlas.save(dst)
    print("   -> %s (%dx%d)" % (dst, atlas.size[0], atlas.size[1]))

    # ---- 墙体图集：共享金属纹理，N*6 变体 ----
    print("=== 墙体图集 ===")
    wi = Image.open(os.path.join(RAW, DEFAULT_WALL_SRC)).convert("RGB").resize(
        (SRC_SIZE, SRC_SIZE), Image.LANCZOS)
    wall_tiles = extract(wi, WALL_VARIANTS * N, seed=777)
    atlas = Image.new("RGB", (WALL_VARIANTS * N * TILE, TILE), (0, 0, 0))
    for i, t in enumerate(wall_tiles):
        a = np.asarray(t).astype(np.float32) * WALL_DARKEN
        atlas.paste(Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGB"),
                    (i * TILE, 0))
    dst = os.path.join(OUT, "atlas_wall.png")
    atlas.save(dst)
    print("   -> %s (%dx%d) = %d 群系 x %d 变体，整体压暗 %.0f%%"
          % (dst, atlas.size[0], atlas.size[1], N, WALL_VARIANTS,
             (1 - WALL_DARKEN) * 100))
    print("DONE")


if __name__ == "__main__":
    main()

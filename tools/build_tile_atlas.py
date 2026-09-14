# -*- coding: utf-8 -*-
"""
把 AI 生成的 1024x1024 无缝地形纹理，切成游戏用的瓦片变体。

v2 关键改进（消除"棋盘格"拼贴感）：
  v1 直接把图不同位置的 16px 方块拼成图集，各块亮度/对比度天生不同，
  铺到地图上就形成明显的格子感。本版对**每个采样瓦片做亮度与对比度归一化**
  （统一到全图均值 + 略微压缩的对比度），只保留"内容差异"（这格是裂纹、
  那格是苔藓），消除"明暗差异"。再叠一点点随机亮度抖动避免呆板。

另外墙体单独暗化处理：金属板纹理在 16px 下会被平均成亮灰蓝块，和地表
反差过大，压暗 20% 后与地面衔接自然得多。

输出：
  Assets/Art/Tiles/atlas_floor.png —— 4 群系 x FLOOR_VARIANTS 列
  Assets/Art/Tiles/atlas_wall.png  —— 4 群系 x WALL_VARIANTS 列
"""
import os
import random
import numpy as np
from PIL import Image

RAW = r"D:/SteamPunkExtraction/Assets/Art/Raw/Terrain"
OUT = r"D:/SteamPunkExtraction/Assets/Art/Tiles"
os.makedirs(OUT, exist_ok=True)

TILE = 16              # 瓦片边长（与 config map.tile_size 一致）
SRC_SIZE = 512         # 纹理降采样后的尺寸
FLOOR_VARIANTS = 12    # 单群系地板变体数
WALL_VARIANTS = 6      # 单群系墙体变体数
CONTRAST = 0.82        # 对比度压缩系数（越小越平，越不容易看出格子）
WALL_DARKEN = 0.80     # 墙体整体压暗

FLOOR_SRC = [
    ("林地", "Seamless_tileable_ground_textu_2026-09-14T23-34-47.png"),
    ("荒原", "Seamless_tileable_ground_textu_2026-09-14T23-35-17.png"),
    ("锈泽", "Seamless_tileable_ground_textu_2026-09-14T23-35-18.png"),
    ("石原", "Seamless_tileable_ground_textu_2026-09-14T23-35-22.png"),
]
WALL_SRC = "Seamless_tileable_texture_of_a_2026-09-14T23-35-17.png"


def sample_tiles(im, count, tile, protect_br=True, seed=7):
    """在图上均匀采样 count 个互不重叠的 tile 方块。"""
    w, h = im.size
    cols, rows = w // tile, h // tile
    cells = []
    for gy in range(rows):
        for gx in range(cols):
            x0, y0 = gx * tile, gy * tile
            # 水印保护区：右下角 22% x 14% 不采样
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
    # 目标：全图均值 + 压缩后的对比度
    target_mean = float(np.mean([a.mean() for a in raw]))
    target_std = float(np.mean([a.std() for a in raw])) * CONTRAST
    rnd = random.Random(seed * 31 + 7)
    out = []
    for a in raw:
        s = a.std()
        if s < 1e-3:
            s = 1e-3
        n = (a - a.mean()) / s * target_std + target_mean
        n *= rnd.uniform(0.97, 1.03)          # 极轻微逐块抖动，避免完全一致的呆板
        out.append(Image.fromarray(np.clip(n, 0, 255).astype(np.uint8), "RGB"))
    return out


def tile_to_array(t):
    return t


print("=== 地板图集 ===")
atlas = Image.new("RGB", (FLOOR_VARIANTS * 4 * TILE, TILE), (0, 0, 0))
for i, (name, fname) in enumerate(FLOOR_SRC):
    im = Image.open(os.path.join(RAW, fname)).convert("RGB").resize(
        (SRC_SIZE, SRC_SIZE), Image.LANCZOS)
    tiles = extract(im, FLOOR_VARIANTS, seed=100 + i)
    for v, t in enumerate(tiles):
        atlas.paste(t, ((i * FLOOR_VARIANTS + v) * TILE, 0))
    print("  [%s] %d 个变体" % (name, len(tiles)))
dst = os.path.join(OUT, "atlas_floor.png")
atlas.save(dst)
print("   -> %s (%dx%d)" % (dst, atlas.size[0], atlas.size[1]))

print("=== 墙体图集 ===")
wi = Image.open(os.path.join(RAW, WALL_SRC)).convert("RGB").resize(
    (SRC_SIZE, SRC_SIZE), Image.LANCZOS)
wall_tiles = extract(wi, WALL_VARIANTS * 4, seed=777)
atlas = Image.new("RGB", (WALL_VARIANTS * 4 * TILE, TILE), (0, 0, 0))
for i, t in enumerate(wall_tiles):
    a = np.asarray(t).astype(np.float32) * WALL_DARKEN
    atlas.paste(Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGB"),
                (i * TILE, 0))
dst = os.path.join(OUT, "atlas_wall.png")
atlas.save(dst)
print("   -> %s (%dx%d) = 4 群系 x %d 变体，整体压暗 %.0f%%"
      % (dst, atlas.size[0], atlas.size[1], WALL_VARIANTS, (1 - WALL_DARKEN) * 100))
print("DONE")

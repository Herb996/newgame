#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
build_ts_terrain.py — 把 Tiny Swords 官方地形素材搬进项目 res://。

原则：**地形图集整张原样搬运**，不在离线阶段裁剪或缩放 —— 96x96/64x64 的
网格由 Godot 运行时按 BLOB_AUTOTILE 规则切片。之前版本把 64px 的官方瓦片
抠成 16px 横条再拼，正是"地图看着跟素材包完全不一样"的根因。

同时把 Terrain/Resources 与 Terrain/Decorations 里的序列帧裁成单帧精灵，
按"占几格"换算成目标尺寸（tile_size = 16px）。

用法：
    python tools/build_ts_terrain.py           # 搬运 + 生成装饰
"""
from __future__ import annotations

import os
import shutil

from PIL import Image

SRC_ROOT = r"D:\SteamPunkExtraction\images\Tiny Swords (Free Pack)"
TERRAIN_SRC = os.path.join(SRC_ROOT, "Terrain")
PROJ = r"D:\SteamPunkExtraction"

# 地形图集：res://Assets/Art/Tiles/TS/
TERRAIN_DST = os.path.join(PROJ, "Assets", "Art", "Tiles", "TS")
TERRAIN_FILES = [
    ("Tilemap_color1.png", "tilemap_color1.png"),
    ("Tilemap_color2.png", "tilemap_color2.png"),
    ("Tilemap_color3.png", "tilemap_color3.png"),
    ("Tilemap_color4.png", "tilemap_color4.png"),
    ("Tilemap_color5.png", "tilemap_color5.png"),
    ("Water Background color.png", "water_bg.png"),
]

# 装饰精灵：res://Assets/Art/Sprites/Decor/
DECOR_DST = os.path.join(PROJ, "Assets", "Art", "Sprites", "Decor")

TILE = 16          # config.map.tile_size


def _resample(img: Image.Image, target_h: int) -> Image.Image:
    """等比缩放：按目标高度算宽度，保持原图长宽比（像素风用 NEAREST 保边缘干净）。"""
    w, h = img.size
    if h <= 0:
        return img
    scale = float(target_h) / float(h)
    tw = max(1, int(round(w * scale)))
    return img.resize((tw, target_h), Image.NEAREST)


def _trim_keep_box(img: Image.Image, alpha_floor: int = 8):
    """返回不透明像素的包围盒；全透明则返回 None。"""
    a = img.split()[-1]
    return a.getbbox()


def make_decor(name: str, src_rel: str, frame_index: int, frame_w: int,
               target_h: int, crop_bottom: int = 0) -> None:
    """从横向序列帧里取第 frame_index 帧，去掉透明边后等比缩到 target_h。"""
    src = os.path.join(TERRAIN_SRC, src_rel)
    if not os.path.exists(src):
        print("  [skip] missing:", src_rel)
        return
    img = Image.open(src).convert("RGBA")
    x0 = frame_index * frame_w
    frame = img.crop((x0, 0, min(x0 + frame_w, img.width), img.height))
    frame.load()
    if crop_bottom > 0:
        frame = frame.crop((0, 0, frame.width, max(1, frame.height - crop_bottom)))
    box = _trim_keep_box(frame)
    if box is None:
        print("  [skip] empty frame:", name)
        return
    frame = frame.crop(box)
    out = _resample(frame, target_h)
    dst = os.path.join(DECOR_DST, name)
    out.save(dst)
    print("  ok  %-22s %dx%d  <- %s frame %d" % (name, out.width, out.height,
                                                 src_rel, frame_index))


def copy_terrain() -> None:
    os.makedirs(TERRAIN_DST, exist_ok=True)
    print("[terrain] ->", TERRAIN_DST)
    for src_name, dst_name in TERRAIN_FILES:
        src = os.path.join(TERRAIN_SRC, "Tileset", src_name)
        if not os.path.exists(src):
            print("  [skip] missing:", src_name)
            continue
        dst = os.path.join(TERRAIN_DST, dst_name)
        shutil.copy2(src, dst)
        im = Image.open(dst)
        print("  ok  %-22s (%dx%d)" % (dst_name, im.width, im.height))


def build_decor() -> None:
    os.makedirs(DECOR_DST, exist_ok=True)
    print("[decor] ->", DECOR_DST)
    # 树 / 树桩：Trees/Stumps 源为 192 宽 x 256 高的横向序列帧（8 帧），
    # 第 0 帧是完整形态。目标是"约占 3x4 格"。
    for i in range(1, 5):
        make_decor("tree_%02d.png" % (i - 1),
                   "Resources/Wood/Trees/Tree%d.png" % i,
                   0, 192, TILE * 4)
    for i in range(1, 5):
        make_decor("stump_%02d.png" % (i - 1),
                   "Resources/Wood/Trees/Stump %d.png" % i,
                   0, 192, TILE * 2)
    # 岩石装饰：Rocks 是 64x64 单图
    for i in range(1, 5):
        make_decor("rock_%02d.png" % (i - 1),
                   "Decorations/Rocks/Rock%d.png" % i,
                   0, 64, TILE * 2)
    # 金矿石（旧 石头 位）
    for i in range(1, 5):
        make_decor("gold_stone_%02d.png" % (i - 1),
                   "Resources/Gold/Gold Stones/Gold Stone %d.png" % i,
                   0, 128, int(TILE * 2.0))
    # 灌木：1024x128 = 8 帧 x 128 宽
    for i in range(1, 5):
        make_decor("bush_%02d.png" % (i - 1),
                   "Decorations/Bushes/Bushe%d.png" % i,
                   0, 128, int(TILE * 2.2))


def main() -> None:
    copy_terrain()
    build_decor()
    print("done.")


if __name__ == "__main__":
    main()

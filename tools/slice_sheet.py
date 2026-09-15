#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tools/slice_sheet.py — 2x2 sprite sheet → 对齐后的单帧 PNG（PlayerHD 管线）

用法：
  python tools/slice_sheet.py <sheet.png> <输出目录> <帧名前缀> [--mirror-out 前缀]

做什么：
  1. 1024x1024 的 2x2 sheet 按 512 切成 4 帧
  2. 每帧按 alpha 包围盒做**只平移不对齐缩放**的对齐：
       水平 → 包围盒中心对到画布中心
       垂直 → 包围盒底边对到统一基线（脚底贴地，动画不抖）
     绝不逐帧缩放 —— 逐帧缩放会让角色在动画里忽大忽小。
  3. --mirror-out 时同时输出水平镜像帧（walk_right ← walk_left）

为什么基线是 0.92*画布：给靴子下面留一点余量，避免公告板底边贴着选中环。
"""
import argparse
import os

from PIL import Image

CELL = 512
BASELINE = int(CELL * 0.92)


def align_frame(cell: Image.Image) -> Image.Image:
    cell = cell.convert("RGBA")
    bbox = cell.getchannel("A").point(lambda a: 255 if a > 10 else 0).getbbox()
    if bbox is None:
        raise SystemExit("空帧（alpha 全透明）——抠图可能失败了")
    fig = cell.crop(bbox)
    canvas = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    x = (CELL - fig.width) // 2
    y = BASELINE - fig.height
    if y < 0:                     # 人物比画布高（不该发生）：贴底保脚，裁头顶
        y = 0
    canvas.paste(fig, (x, y))
    return canvas


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("sheet")
    ap.add_argument("outdir")
    ap.add_argument("prefix")
    ap.add_argument("--mirror-out", default="")
    args = ap.parse_args()

    sheet = Image.open(args.sheet).convert("RGBA")
    w, h = sheet.size
    if (w, h) != (1024, 1024):
        print("警告：sheet 尺寸 %sx%s，仍按 2x2 四等分切" % (w, h))
    cells = [sheet.crop((i % 2 * CELL, i // 2 * CELL,
                         i % 2 * CELL + CELL, i // 2 * CELL + CELL))
             for i in range(4)]

    os.makedirs(args.outdir, exist_ok=True)
    for i, cell in enumerate(cells):
        out = os.path.join(args.outdir, "%s_%02d.png" % (args.prefix, i))
        align_frame(cell).save(out)
        print("->", out)
    if args.mirror_out:
        for i, cell in enumerate(cells):
            out = os.path.join(args.outdir, "%s_%02d.png" % (args.mirror_out, i))
            align_frame(cell).transpose(Image.FLIP_LEFT_RIGHT).save(out)
            print("->", out)


if __name__ == "__main__":
    main()

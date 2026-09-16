#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把 Tiny Swords 资源点素材处理成项目 Decor 约定的三张贴图。

项目约定（map_generator.gd DECOR_PATHS，1px = 1 游戏像素，立体件脚底贴格心）：
- Assets/Art/Sprites/Decor/tree_00.png    树（阻挡）
- Assets/Art/Sprites/Decor/rock_00.png    石（阻挡）
- Assets/Art/Sprites/Decor/debris_00.png  残骸（不阻挡）

素材映射（Terrain/Resources）：
- Tree1.png 1536x256（6 帧摇摆动画）→ 取第 0 帧 256x256 → 缩到 TS_OUT
- Gold Stone 1.png 128x128 → rock（金色矿石感，比灰石好看）
- Stump 1.png 192x256 → debris（树桩当残骸，语义贴合"森林废土"）

输出尺寸按格子（16px）估算：
- 树：128px 宽（8 格冠幅，玩家 z=1 永远在前景不会被吞）
- 石：48px（3 格）
- 树桩：44px 宽（比例保持）

用法：python tools/build_ts_decor.py
"""
import os
import sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "images", "Tiny Swords (Free Pack)", "Terrain", "Resources")
OUT = os.path.join(ROOT, "Assets", "Art", "Sprites", "Decor")

JOBS = [
    # (源, 源帧框(或None=整图), 输出名, 目标尺寸px, 按宽/高缩放)
    # Tree1.png 1536x256 实为 8 帧 x 192x256 的摇摆动画（6x256 会对到相邻半棵树）
    # 树高按玩家（96px）1.5 倍取 144px，冠幅约 5.6 格
    (os.path.join(SRC, "Wood", "Trees", "Tree1.png"), (0, 0, 192, 256),
     "tree_00.png", (None, 144), "h"),
    (os.path.join(SRC, "Gold", "Gold Stones", "Gold Stone 1.png"), None,
     "rock_00.png", (48, None), "w"),
    (os.path.join(SRC, "Wood", "Trees", "Stump 1.png"), None,
     "debris_00.png", (44, None), "w"),
]


def main() -> int:
    for src, frame, name, target, mode in JOBS:
        if not os.path.exists(src):
            print("!! 缺源：", src)
            return 1
        im = Image.open(src).convert("RGBA")
        if frame:
            im = im.crop(frame)
        # 裁掉透明边再等比缩放（让"贴地"尺寸准确）
        bbox = im.getchannel("A").point(lambda a: 255 if a > 10 else 0).getbbox()
        if bbox:
            im = im.crop(bbox)
        w, h = im.size
        if mode == "h":
            nh = target[1]
            nw = round(w * nh / h)
        else:
            nw = target[0]
            nh = round(h * nw / w)
        im = im.resize((nw, nh), Image.LANCZOS)
        dst = os.path.join(OUT, name)
        bak = dst + ".bak_old"
        if os.path.exists(dst) and not os.path.exists(bak):
            os.replace(dst, bak)
            print("旧图备份 ->", os.path.basename(bak))
        im.save(dst)
        print("%-16s %dx%d -> %dx%d" % (name, w, h, nw, nh))

    # 预览：深色底拼三张
    prev = Image.new("RGB", (420, 180), (52, 58, 50))
    x = 10
    for _, _, name, _t, _m in JOBS:
        t = Image.open(os.path.join(OUT, name)).convert("RGBA")
        prev.paste(t, (x, 170 - t.size[1]), t)
        x += t.size[0] + 30
    prev.save(os.path.join(ROOT, "_decor_preview.png"))
    print("预览 -> _decor_preview.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())

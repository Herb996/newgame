# -*- coding: utf-8 -*-
"""逐帧量单位包围盒，确认"脚底是不是恒定在同一 y"。

为什么需要：单位帧的脚底基准决定 sprite_offset_y。如果只看全组并集，
挥砍帧伸出的武器会把包围盒撑大，推出的偏移就偏了；如果只看 idle 单帧，
又无法确认这个基准在整组动画里是否稳定。

用法：python tools/probe_unit_idle.py
"""
import os

from PIL import Image

UNIT_DIR = r"D:\SteamPunkExtraction\Assets\Art\Sprites\Units"
GROUPS = ["blue_warrior", "red_pawn", "sheep"]


def bbox(img):
    return img.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()


for g in GROUPS:
    d = os.path.join(UNIT_DIR, g)
    if not os.path.isdir(d):
        continue
    print("== %s ==" % g)
    by_action = {}
    for f in sorted(os.listdir(d)):
        if not f.endswith(".png"):
            continue
        action = f.rsplit("_", 1)[0]
        by_action.setdefault(action, []).append(f)
    for action, files in sorted(by_action.items()):
        bottoms = []
        lefts = []
        rights = []
        w = h = 0
        for f in files:
            im = Image.open(os.path.join(d, f)).convert("RGBA")
            w, h = im.width, im.height
            bb = bbox(im)
            if bb is None:
                continue
            lefts.append(bb[0]); rights.append(bb[2]); bottoms.append(bb[3])
        if not bottoms:
            continue
        print("  %-10s n=%-3d canvas=%dx%d  bottom y[%d..%d] (local %+d..%+d)  x[%d..%d]"
              % (action, len(files), w, h,
                 min(bottoms), max(bottoms),
                 min(bottoms) - h // 2, max(bottoms) - h // 2,
                 min(lefts), max(rights)))

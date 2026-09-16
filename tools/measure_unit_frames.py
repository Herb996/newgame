# -*- coding: utf-8 -*-
"""量单位帧里角色的实际不透明包围盒，用于推导 Sprite2D 的 scale / offset。"""
import os
from PIL import Image

ROOT = r"D:\SteamPunkExtraction\Assets\Art\Sprites\Units"


def bbox(img):
    return img.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()


def main():
    lines = []
    for unit in sorted(os.listdir(ROOT)):
        d = os.path.join(ROOT, unit)
        if not os.path.isdir(d):
            continue
        for anim in sorted(os.listdir(d)):
            if not anim.endswith(".png"):
                continue
            p = os.path.join(d, anim)
            im = Image.open(p).convert("RGBA")
            b = bbox(im)
            if b is None:
                lines.append("%-28s %dx%d  EMPTY" % (unit + "/" + anim, im.width, im.height))
                continue
            lines.append("%-28s canvas=%dx%d  bbox=(%d,%d)-(%d,%d)  w=%d h=%d  feet_gap=%d"
                         % (unit + "/" + anim, im.width, im.height,
                            b[0], b[1], b[2], b[3], b[2] - b[0], b[3] - b[1],
                            im.height - b[3]))
    open(r"C:\Users\Administrator\WorkBuddy\2026-09-15-23-06-42\_unit_bbox.txt",
         "w", encoding="utf-8").write("\n".join(lines))


main()

# -*- coding: utf-8 -*-
"""量各单位"脚底 y"和"横向半宽"，用来一次性生成各兵种的 offset_y / 碰撞半径。

脚底 y 在 idle/run 两组帧里必须一致（官方素材就是这么做的）；
不一致说明素材被裁过，需要人工确认。

用法：python tools/probe_unit_feet.py
"""
import os

from PIL import Image

UNIT_DIR = r"D:\SteamPunkExtraction\Assets\Art\Sprites\Units"


def bbox(img):
    return img.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()


print("%-14s %-6s %-7s %-8s %-8s %-8s" % ("unit", "canvas", "feet_y", "offset_y",
                                          "idle_w", "half_w"))
for g in sorted(os.listdir(UNIT_DIR)):
    d = os.path.join(UNIT_DIR, g)
    if not os.path.isdir(d):
        continue
    feet = {}
    widths = {}
    canvas = (0, 0)
    for f in sorted(os.listdir(d)):
        if not f.endswith(".png"):
            continue
        action = f.rsplit("_", 1)[0]
        if action not in ("idle", "run"):
            continue
        im = Image.open(os.path.join(d, f)).convert("RGBA")
        canvas = (im.width, im.height)
        bb = bbox(im)
        if bb is None:
            continue
        feet.setdefault(action, set()).add(bb[3])
        widths.setdefault(action, []).append(bb[2] - bb[0])
    if "idle" not in feet:
        continue
    f_idle = sorted(feet["idle"])
    f_run = sorted(feet.get("run", []))
    if len(f_idle) != 1:
        print("  !! %s idle 脚底不唯一: %s" % (g, f_idle))
    fy = f_idle[-1]
    w_idle = max(widths["idle"]) if widths.get("idle") else 0
    print("%-14s %-6s %-7d %-8d %-8d %-8.1f   run_feet=%s"
          % (g, "%dx%d" % canvas, fy, -(fy - canvas[1] // 2), w_idle, w_idle / 2.0, f_run))

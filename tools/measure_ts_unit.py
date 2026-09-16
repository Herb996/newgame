# -*- coding: utf-8 -*-
"""量 Tiny Swords 单位帧的实际包围盒，用来定碰撞半径/图标高度/脚底偏移。

背景：官方单位是 192x192 画布，角色本身只占中间一小块，四周全是透明留白。
不量清楚就会出现「碰撞体比人小一圈」「名字/图标飘在半空」这类问题。

用法：
    python tools/measure_ts_unit.py [单位目录名...]
默认量 blue_warrior / red_pawn / sheep。
"""
import os
import sys

from PIL import Image

UNIT_DIR = r"D:\SteamPunkExtraction\Assets\Art\Sprites\Units"


def bbox(img: Image.Image):
    return img.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()


def measure(name: str) -> None:
    d = os.path.join(UNIT_DIR, name)
    if not os.path.isdir(d):
        print("  [skip] 无此目录: %s" % name)
        return
    files = sorted(f for f in os.listdir(d) if f.endswith(".png"))
    if not files:
        print("  [skip] 无 PNG: %s" % name)
        return
    # 取全组帧的并集，避免单帧姿势（如挥砍）把包围盒带偏
    l = t = 10 ** 6
    r = b = -1
    w = h = 0
    for f in files:
        im = Image.open(os.path.join(d, f)).convert("RGBA")
        w, h = im.width, im.height
        bb = bbox(im)
        if bb is None:
            continue
        l = min(l, bb[0]); t = min(t, bb[1])
        r = max(r, bb[2]); b = max(b, bb[3])
    if r < 0:
        print("  [skip] 全透明: %s" % name)
        return
    cw, ch = r - l, b - t
    dx = (l + r) / 2.0 - w / 2.0          # 角色横向中心相对画布中心的偏移
    feet_local = b - h / 2.0              # 脚底相对画布中心（Sprite2D 的 offset 应取它的负值）
    print("%-14s 画布 %dx%d | 包围盒 x[%d,%d] y[%d,%d] = %dx%d"
          % (name, w, h, l, r, t, b, cw, ch))
    print("%-14s   横向中心偏移 %+.1f | 脚底局部 y %+.1f -> sprite_offset_y %.1f"
          % ("", dx, feet_local, -feet_local))
    print("%-14s   建议碰撞半径 ≈ %.1f（取宽度的 0.36）| 建议头顶 y ≈ %.1f"
          % ("", cw * 0.36, t - h / 2.0))


def main() -> int:
    names = sys.argv[1:] or ["blue_warrior", "red_pawn", "red_archer", "red_monk",
                             "yellow_pawn", "sheep"]
    for n in names:
        measure(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())

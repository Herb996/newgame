# -*- coding: utf-8 -*-
"""把 Assets/Art/Sprites/FX 里的横条拼成一张 contact sheet，用来看形状和配色对不对。

只读产物，不写回项目。背景刻意用草绿（贴近游戏内地面），白色/加色素材在绿地上会不会糊，
这里就能先看个大概。
"""
import os
import sys

from PIL import Image, ImageDraw

FX_DIR = r"D:\SteamPunkExtraction\Assets\Art\Sprites\FX"
CELL = 128
THUMB = 64
BG = (63, 107, 55, 255)
LABELS = [
    "slash_bite", "spit_web", "slam_ring", "burst_charge", "slash_rend",
    "spike_bone", "bash_rock", "slash_shadow", "thrust_harpoon", "splash_bomb",
    "sweep_fin", "slash_sabre", "shred_bolt", "slam_paw", "slash_tail",
    "hit_sword", "hit_pierce", "hit_holy", "hit_arrow",
]


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\Administrator\WorkBuddy\fx_batch2_sheet.png"
    rows = []
    for name in LABELS:
        p = os.path.join(FX_DIR, name + ".png")
        if not os.path.exists(p):
            print("!! missing", p)
            continue
        im = Image.open(p).convert("RGBA")
        n = max(1, im.size[0] // CELL)
        frames = [im.crop((i * CELL, 0, (i + 1) * CELL, CELL)).resize((THUMB, THUMB), Image.NEAREST)
                  for i in range(n)]
        rows.append((name, n, frames))
    w = 210 + max(len(f) for _, _, f in rows) * (THUMB + 2) + 10
    h = 30 + len(rows) * (THUMB + 12)
    sheet = Image.new("RGBA", (w, h), BG)
    d = ImageDraw.Draw(sheet)
    y = 8
    d.text((8, y + 22), "id / frames", fill=(255, 255, 255, 255))
    y = 28
    for name, n, frames in rows:
        d.text((8, y + THUMB // 2 - 5), "%s (%d)" % (name, n), fill=(255, 255, 255, 255))
        x = 210
        for f in frames:
            sheet.alpha_composite(f, (x, y))
            x += THUMB + 2
        y += THUMB + 12
    sheet.convert("RGB").save(out)
    print("sheet ->", out, sheet.size)


if __name__ == "__main__":
    main()

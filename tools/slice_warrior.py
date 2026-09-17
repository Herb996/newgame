# -*- coding: utf-8 -*-
"""切 Tiny Swords Warrior 的素材 -> Assets/Art/Sprites/Units/<tag>_warrior/

背景：剑士（sword -> sprites_ts）用的就是这套「战士」素材（单向、正视视角）。
    Warrior_Idle.png     8 帧
    Warrior_Run.png      6 帧
    Warrior_Attack1.png  4 帧
    Warrior_Attack2.png  4 帧
    Warrior_Guard.png    6 帧
    合计 28 帧，画布 192x192（与 Archer 同格）。

与 Lancer / Archer 不同：**战士不派生镜像帧** —— 官方没画左半边，而剑士的
现实用法是「四向共用同一组帧」（config sprites_ts 是扁平数组），镜像派生的
那一份至今没人用（sprites_lancer 的 *_m 也是同理的冗余）。保持与 blue_warrior
完全一致的输出集合，免得把既有精灵集结构改坏。

等级档位配色（2026-09-17 方案三）：Blue 之外还要给 Purple / Black / Yellow
各切一份 —— 玩家单位按等级换配色分档（0-2 蓝 / 3-5 紫 / 6-8 黑 / 9 金）。
四套源图同骨架同帧数、只换颜色，切片逻辑零改动，只换 SRC/DST。

用法：python tools/slice_warrior.py [Blue|Purple|Black|Yellow]
"""
from __future__ import annotations

import json
import os
import sys

from PIL import Image

FACTION = sys.argv[1] if len(sys.argv) > 1 else "Blue"
TAG = FACTION.lower()          # blue / purple / black / yellow

SRC = r"D:\SteamPunkExtraction\images\Tiny Swords (Free Pack)\Units\%s Units\Warrior" % FACTION
DST = r"D:\SteamPunkExtraction\Assets\Art\Sprites\Units\%s_warrior" % TAG
CONFIG_SNIPPET = r"C:\Users\Administrator\WorkBuddy\2026-09-15-23-06-42\_%s_warrior_frames.json" % TAG
REPORT = r"C:\Users\Administrator\WorkBuddy\2026-09-15-23-06-42\_%s_warrior_slice.txt" % TAG

FW = FH = 192
RES_DIR = "res://Assets/Art/Sprites/Units/%s_warrior/" % TAG

JOBS: list[tuple[str, str]] = [
    ("Warrior_Idle.png", "idle"),
    ("Warrior_Run.png", "run"),
    ("Warrior_Attack1.png", "attack1"),
    ("Warrior_Attack2.png", "attack2"),
    ("Warrior_Guard.png", "guard"),
]

written: list[str] = []
frame_map: dict[str, list[str]] = {}
lines: list[str] = []


def save(img: Image.Image, name: str) -> str:
    os.makedirs(DST, exist_ok=True)
    img.save(os.path.join(DST, name))
    written.append(name)
    return RES_DIR + name


def bbox_of(fr: Image.Image):
    return fr.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()


def main() -> int:
    total = 0
    for src_name, prefix in JOBS:
        src = os.path.join(SRC, src_name)
        if not os.path.exists(src):
            lines.append("!! 缺源 %s" % src_name)
            continue
        sheet = Image.open(src).convert("RGBA")
        if sheet.height != FH:
            lines.append("!! %s 高 %d != %d（画布不对，检查源图）" % (src_name, sheet.height, FH))
        n = sheet.width // FW
        frames = [sheet.crop((i * FW, 0, (i + 1) * FW, FH)) for i in range(n)]

        paths: list[str] = []
        for i, fr in enumerate(frames):
            paths.append(save(fr, "%s_%02d.png" % (prefix, i)))
        frame_map[prefix] = paths
        total += len(paths)

        bots = sorted({bbox_of(fr)[3] for fr in frames})
        lines.append("%-18s %d 帧  包围盒下沿 %s" % (prefix, n, bots))

    lines.append("")
    lines.append("共写出 %d 个 png -> %s" % (total, DST))
    lines.append("（战士不派生镜像帧；与 blue_warrior 输出集合保持一致）")

    with open(CONFIG_SNIPPET, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(frame_map, fh, ensure_ascii=False, indent=2)
    with open(REPORT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")

    print("OK  帧->%s  报告->%s" % (DST, REPORT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

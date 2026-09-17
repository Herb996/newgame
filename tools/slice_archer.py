# -*- coding: utf-8 -*-
"""切 Tiny Swords Archer 的素材 -> Assets/Art/Sprites/Units/blue_archer/
并把 Arrow.png 复制成独立弹道素材 -> Assets/Art/Sprites/Projectiles/arrow.png

背景：弓是免费包里**唯一自带完整动作集 + 独立弹道图**的武器。
    Archer_Idle.png   1152x192   6 帧
    Archer_Run.png     768x192   4 帧
    Archer_Shoot.png  1536x192   8 帧（完整拉弓->放箭）
    Arrow.png           64x64    1 帧  <-- 独立弹道素材（其余武器都是烘焙进角色帧的）

画布 192x192（与 Warrior 同格）。实测 Shoot / Idle / Run 三套的不透明包围盒
底部全部 = 136，彼此一致 -> offset_y = -(136 - 192/2) = -40。

Archer 是**单向**素材（正视视角、弓箭在画面右侧）-> 左半边由水平镜像派生，
与 slice_lancer.py 同策略：config 里 default=原图、left/down_left/up_left=镜像。

用法：python tools/slice_archer.py [Blue|Purple|Black|Yellow]

等级档位配色（2026-09-17 方案三）：除了 Blue，还要给 Purple / Black / Yellow
各切一份 —— 玩家单位按等级换配色分档（0-2 蓝 / 3-5 紫 / 6-8 黑 / 9 金）。
四套源图在免费包里是**同一套骨架、只换颜色**（帧数完全一致），所以切片逻辑零改动，
只换 SRC/DST。箭矢 Arrow.png 只有 Blue 才复制（弹道素材不该跟着换色）。
"""
from __future__ import annotations

import json
import os
import shutil
import sys

from PIL import Image

FACTION = sys.argv[1] if len(sys.argv) > 1 else "Blue"
TAG = FACTION.lower()          # blue / purple / black / yellow

SRC = r"D:\SteamPunkExtraction\images\Tiny Swords (Free Pack)\Units\%s Units\Archer" % FACTION
DST = r"D:\SteamPunkExtraction\Assets\Art\Sprites\Units\%s_archer" % TAG
PROJ_DST = r"D:\SteamPunkExtraction\Assets\Art\Sprites\Projectiles"
CONFIG_SNIPPET = r"C:\Users\Administrator\WorkBuddy\2026-09-15-23-06-42\_%s_archer_frames.json" % TAG
REPORT = r"C:\Users\Administrator\WorkBuddy\2026-09-15-23-06-42\_%s_archer_slice.txt" % TAG

FW = FH = 192
RES_DIR = "res://Assets/Art/Sprites/Units/%s_archer/" % TAG
RES_ARROW = "res://Assets/Art/Sprites/Projectiles/arrow.png"

# (源文件, 输出前缀)  -- 输出前缀即 config 里的动作名（run -> walk 由 config 映射）
JOBS: list[tuple[str, str]] = [
    ("Archer_Idle.png", "idle"),
    ("Archer_Run.png", "run"),
    ("Archer_Shoot.png", "shoot"),
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
        n = sheet.width // FW
        frames = [sheet.crop((i * FW, 0, (i + 1) * FW, FH)) for i in range(n)]

        paths: list[str] = []
        mpaths: list[str] = []
        for i, fr in enumerate(frames):
            paths.append(save(fr, "%s_%02d.png" % (prefix, i)))
            mpaths.append(save(fr.transpose(Image.FLIP_LEFT_RIGHT),
                               "%s_m_%02d.png" % (prefix, i)))
        frame_map[prefix] = paths
        frame_map[prefix + "_m"] = mpaths
        total += len(paths) + len(mpaths)

        bots = [bbox_of(fr)[3] for fr in frames]
        lines.append("%-20s %2d 帧  包围盒下沿 %s" % (prefix, n, sorted(set(bots))))

    # --- 箭矢：独立弹道素材（只有 Blue 才复制，别让档位配色污染弹道） ---
    arrow_src = os.path.join(SRC, "Arrow.png")
    arrow_line = ""
    if TAG != "blue":
        arrow_line = "（非 Blue 阵营：跳过 Arrow.png 复制，弹道沿用蓝色箭矢）"
    elif os.path.exists(arrow_src):
        os.makedirs(PROJ_DST, exist_ok=True)
        a = Image.open(arrow_src).convert("RGBA")
        bb = bbox_of(a)
        a.save(os.path.join(PROJ_DST, "arrow.png"))
        written.append("arrow.png")
        cx = (bb[0] + bb[2]) / 2.0
        cy = (bb[1] + bb[3]) / 2.0
        w = bb[2] - bb[0]
        h = bb[3] - bb[1]
        arrow_line = ("Arrow.png %dx%d  不透明包围盒 %s  ->  箭长 %d px  中心偏移 (%.1f, %.1f)"
                      "  画布中心 (%.1f, %.1f)"
                      % (a.width, a.height, str(bb), w, cx - a.width / 2.0,
                         cy - a.height / 2.0, a.width / 2.0, a.height / 2.0))
    else:
        arrow_line = "!! 缺 Arrow.png"

    lines.append("")
    lines.append(arrow_line)
    lines.append("")
    lines.append("offset_y 推导：下沿 136，画布高 192 -> -(136 - 96) = -40")
    lines.append("共写出 %d 个 png（角色帧） + 1 个箭矢" % total)

    with open(CONFIG_SNIPPET, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(frame_map, fh, ensure_ascii=False, indent=2)
    with open(REPORT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")

    print("OK  帧->%s  报告->%s" % (DST, REPORT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

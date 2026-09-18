# -*- coding: utf-8 -*-
"""切 Tiny Swords Monk（僧侣）素材 -> Assets/Art/Sprites/Units/<tag>_monk/

背景：Monk 是免费包里**唯一带治疗动画**的单位，也是四档配色（Blue/Purple/Black/Yellow）
齐全的少数单位之一。帧数（192x192 画布，与 Warrior / Archer 同格）：
    Idle.png          6 帧
    Run.png           4 帧
    Heal.png         11 帧     <- 施法动作（僧侣**没有** Attack 帧）
    Heal_Effect.png  11 帧     <- 治疗特效（法阵/光粒），与 Heal 同帧数、逐帧对齐

两个关键约定（别改回去）：
1. **Heal 帧就是 Monk 的 attack 帧**。官方没画 Attack，而敌人邪术师（cultist）早就这么用：
   `red_monk/attack1_00..10` 正是 Heal 的 11 帧（见 config enemies.cultist.attack）。
   所以输出里既有 `heal_*` 也有 `attack1_*`，是同一批像素的两份命名 —— 让玩家的僧侣
   与敌人邪术师共用同一条「施法动作 = 攻击动作」的语义。
2. **Heal_Effect 单独切一份**（`heal_fx_*`，**不**混进 attack 序列）：它是纯特效层，
   画在受术者身上而不是施法者身上，混进身体帧会让僧侣自己被光粒糊住。

与 Lancer / Archer 不同：**不派生镜像帧** —— 官方没画左半边，且玩家精灵集是四向共用
同一组帧（见 config sprites_monk 的扁平数组写法）。

用法：python tools/slice_monk.py [Blue|Purple|Black|Yellow]
"""
from __future__ import annotations

import json
import os
import sys

from PIL import Image

FACTION = sys.argv[1] if len(sys.argv) > 1 else "Blue"
TAG = FACTION.lower()          # blue / purple / black / yellow

SRC = r"D:\SteamPunkExtraction\images\Tiny Swords (Free Pack)\Units\%s Units\Monk" % FACTION
DST = r"D:\SteamPunkExtraction\Assets\Art\Sprites\Units\%s_monk" % TAG
CONFIG_SNIPPET = r"C:\Users\Administrator\WorkBuddy\2026-09-15-23-06-42\_%s_monk_frames.json" % TAG
REPORT = r"C:\Users\Administrator\WorkBuddy\2026-09-15-23-06-42\_%s_monk_slice.txt" % TAG

FW = FH = 192
RES_DIR = "res://Assets/Art/Sprites/Units/%s_monk/" % TAG

# (源文件名, 输出前缀, 是否同时复制一份 attack1_*)
JOBS: list[tuple[str, str, bool]] = [
    ("Idle.png", "idle", False),
    ("Run.png", "run", False),
    ("Heal.png", "heal", True),          # <- 施法动作，同时当 attack1
    ("Heal_Effect.png", "heal_fx", False),  # <- 纯特效层，不进 attack 序列
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
    for src_name, prefix, also_attack in JOBS:
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
            if also_attack:
                save(fr, "attack1_%02d.png" % i)   # 同一批像素的第二份命名
        frame_map[prefix] = paths
        total += len(paths)

        bots = sorted({bbox_of(fr)[3] for fr in frames})
        lines.append("%-14s %2d 帧  包围盒下沿 %s%s"
                     % (prefix, n, bots, "  (+attack1 副本)" if also_attack else ""))

    lines.append("")
    lines.append("共写出 %d 个 png（含 attack1 副本）-> %s" % (total, DST))
    lines.append("（不派生镜像帧；Heal 帧同时输出为 attack1_*，与 red_monk 保持同一约定）")

    with open(CONFIG_SNIPPET, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(frame_map, fh, ensure_ascii=False, indent=2)
    with open(REPORT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")

    print("OK  帧->%s  报告->%s" % (DST, REPORT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

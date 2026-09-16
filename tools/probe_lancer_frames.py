#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""probe_lancer_frames.py — Lancer 8 向帧的**像素级**校验。

为什么不用 GDScript 做：这类比对要逐像素读 PNG，GDScript 里既慢又绕；
而「左半边是不是右半边的严格水平镜像」「8 个方向是不是 8 张不同的画」
这种问题，只有像素级比对才算真的验过。

校验点：
  1) attack / guard 的 8 个方向首帧两两不同（不是同一张图改个名）；
  2) 左半边 == 右半边严格水平镜像（左/左下/左上 三组）；
  3) idle / run 的 _m 文件确实是原图的水平翻转；
  4) 所有帧都是 320x320 同画布（混画布会让 PlayerVisual3D 报警、角色比例错）。

用法：python tools/probe_lancer_frames.py
"""
from __future__ import annotations

import hashlib
import os

from PIL import Image

UNIT = r"D:\SteamPunkExtraction\Assets\Art\Sprites\Units\blue_lancer"
OUT = r"C:\Users\Administrator\WorkBuddy\2026-09-15-23-06-42\_lancer_frames_check.txt"

DIRS8 = ["down", "down_right", "right", "up_right",
         "up", "up_left", "left", "down_left"]

# 镜像对：(左系前缀, 右系前缀)
MIRROR_PAIRS = [
    ("attack_left", "attack_right"),
    ("attack_down_left", "attack_down_right"),
    ("attack_up_left", "attack_up_right"),
    ("guard_left", "guard_right"),
    ("guard_down_left", "guard_down_right"),
    ("guard_up_left", "guard_up_right"),
    ("idle_m", "idle"),
    ("run_m", "run"),
]

fails: list[str] = []
oks: list[str] = []
lines: list[str] = []


def check(ok: bool, msg: str) -> None:
    (oks if ok else fails).append(msg)
    lines.append("  %s %s" % ("OK  " if ok else "FAIL", msg))


def md5(path: str) -> str:
    return hashlib.md5(open(path, "rb").read()).hexdigest()[:10]


def main() -> int:
    lines.append("=== 1) 帧画布一致性 ===")
    sizes = {}
    n = 0
    for f in sorted(os.listdir(UNIT)):
        if not f.endswith(".png"):
            continue
        n += 1
        im = Image.open(os.path.join(UNIT, f))
        sizes.setdefault("%dx%d" % im.size, []).append(f)
    check(len(sizes) == 1 and "320x320" in sizes,
          "全部 %d 帧同画布：%s" % (n, {k: len(v) for k, v in sizes.items()}))

    lines.append("")
    lines.append("=== 2) attack / guard 的 8 向首帧两两不同 ===")
    for anim in ("attack", "guard"):
        hashes = {}
        for d in DIRS8:
            p = os.path.join(UNIT, "%s_%s_00.png" % (anim, d))
            if not os.path.exists(p):
                check(False, "%s_%s_00.png 存在" % (anim, d))
                continue
            hashes[d] = md5(p)
        uniq = len(set(hashes.values()))
        check(uniq == 8, "%s 八向首帧 md5 两两不同（%d/8）" % (anim, uniq))
        lines.append("      " + "  ".join("%s=%s" % (k, v) for k, v in hashes.items()))

    lines.append("")
    lines.append("=== 3) 左半边 == 右半边严格水平镜像 ===")
    for left_pref, right_pref in MIRROR_PAIRS:
        lp = os.path.join(UNIT, "%s_00.png" % left_pref)
        rp = os.path.join(UNIT, "%s_00.png" % right_pref)
        if not (os.path.exists(lp) and os.path.exists(rp)):
            check(False, "%s / %s 文件齐全" % (left_pref, right_pref))
            continue
        L = Image.open(lp).convert("RGBA")
        R = Image.open(rp).convert("RGBA")
        flipped = R.transpose(Image.FLIP_LEFT_RIGHT).tobytes()
        same = flipped == L.tobytes()
        check(same, "%s == flipH(%s)" % (left_pref, right_pref))

    lines.append("")
    lines.append("=== 4) idle / run 的原图与镜像确实不同 ===")
    for base in ("idle", "run"):
        a = md5(os.path.join(UNIT, "%s_00.png" % base))
        b = md5(os.path.join(UNIT, "%s_m_00.png" % base))
        check(a != b, "%s 原图与镜像 md5 不同（%s / %s）" % (base, a, b))

    lines.append("")
    lines.append("=== 共 %d 项，失败 %d 项 ===" % (len(oks) + len(fails), len(fails)))
    for m in fails:
        lines.append("  !! " + m)

    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    print("通过 %d / %d" % (len(oks), len(oks) + len(fails)))
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(main())

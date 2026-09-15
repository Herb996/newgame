#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tools/enable_hd_mipmap.py — 给指定目录的 PNG 纹理开 mipmap 导入

为什么需要：HD 序列帧 512px 在屏上只有 ~95px，是 5:1 缩小。不开 mipmap 时
LINEAR_WITH_MIPMAPS 退化为无 mip 线性采样 → 远处/缩小状态会闪成噪点。
Godot 对 2D 用途的 PNG 默认**不生成** mipmap（mipmaps/generate=false）。

用法（两段式，Godot 导入器不吃"改完立刻生效"这一套）：
  1) godot --headless --import            # 让 Godot 先生成默认 .import
  2) python tools/enable_hd_mipmap.py Assets/Art/Sprites/PlayerHD
  3) godot --headless --import            # 再跑一次，按新参数重新生成 .ctex
"""
import io
import os
import sys


def patch_import(path: str) -> bool:
    with io.open(path, encoding="utf-8") as f:
        lines = f.readlines()
    out, changed = [], False
    for ln in lines:
        if ln.strip().startswith("mipmaps/generate="):
            new = "mipmaps/generate=true\n"
            changed = ln != new
            out.append(new)
        else:
            out.append(ln)
    if changed:
        with io.open(path, "w", encoding="utf-8", newline="") as f:
            f.writelines(out)
    return changed


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    root = sys.argv[1] if os.path.isabs(sys.argv[1]) else os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), sys.argv[1])
    n = 0
    for f in sorted(os.listdir(root)):
        if not f.lower().endswith(".png"):
            continue
        ip = os.path.join(root, f + ".import")
        if not os.path.exists(ip):
            print("!! 缺 .import（先跑一次 godot --headless --import）:", f)
            continue
        if patch_import(ip):
            n += 1
            print("开 mipmap:", f)
    print("共修改 %d 个（其余已是 true）" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())

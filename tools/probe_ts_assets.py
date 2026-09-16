# -*- coding: utf-8 -*-
"""列出 Tiny Swords (Free Pack) 下所有 PNG 的尺寸，并猜测动画网格。

用途：在写切片脚本前，先确认每张 sheet 的像素尺寸 / 帧数 / 网格，
避免再犯"按错误的 tile 尺寸硬抠"的错误。
输出：JSON 清单（stdout）。
"""
import json
import os
import struct
import sys

ROOT = r"D:\SteamPunkExtraction\images\Tiny Swords (Free Pack)"


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    w, h = struct.unpack(">II", head[16:24])
    return w, h


def main():
    out = []
    for dirpath, _dirs, files in os.walk(ROOT):
        for name in sorted(files):
            if not name.lower().endswith(".png"):
                continue
            full = os.path.join(dirpath, name)
            sz = png_size(full)
            if sz is None:
                continue
            rel = os.path.relpath(full, ROOT).replace("\\", "/")
            out.append({"rel": rel, "w": sz[0], "h": sz[1]})
    out.sort(key=lambda d: d["rel"])
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()

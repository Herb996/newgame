#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""tools/preview_map.py — 把一整张局内地图合成为 PNG（无头可用）

原理：MapGenerator.build_preview() 在纯像素层把「地形图集 + 装饰 + 矿脉」拼成
一张大图，由 main.gd 的命令行入口 `--preview-map` save_png 后退出。
不依赖 GPU，所以 `--headless` 也能出图——这是它比"开窗口截图"好用的地方。

**不再改写 Data/config.json。** 老版本靠"临时改 config 再还原"传参，
一旦中途崩在写完之后，工程就留着一份被改过的配置（固定种子、预览路径），
下次跑会莫名其妙复现同一张图。现在全部走 `--` 之后的用户参数，config 全程只读。

用法：
    python tools/preview_map.py <输出png> [--cells 128] [--scale 0.125] [--seed N]
"""

import argparse
import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GODOT = os.environ.get(
    "GODOT_BIN", r"C:/Users/Administrator/Downloads/Godot_v4.7.2-stable_win64_console.exe")
LOG_DIR = os.environ.get("WB_LOG_DIR", ROOT)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--cells", type=int, default=0, help="只画前 N 格（0=整张图宽度）")
    ap.add_argument("--scale", type=float, default=0.125)
    ap.add_argument("--seed", type=int, default=20260916)
    args = ap.parse_args()

    out = args.out if os.path.isabs(args.out) else os.path.join(ROOT, args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    out = out.replace("\\", "/")

    # 场景必须显式给：project.godot 的 run/main_scene 指向 3D 入口（Main3D.tscn），
    # 不带场景参数跑起来的是 3D 那一套，2D 的命令行入口根本不会被调用。
    cmd = [GODOT, "--headless", "--path", ROOT, "--quit-after", "900",
           "res://Scenes/Main.tscn",
           "--", "--preview-map", out,
           "--cells", str(args.cells), "--scale", str(args.scale),
           "--seed", str(args.seed)]
    print("[preview] %s" % " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, timeout=900)
    text = (r.stdout + b"\n" + r.stderr).decode("utf-8", "replace")
    log = os.path.join(LOG_DIR, "_preview.log")
    io.open(log, "w", encoding="utf-8", newline="").write(text)
    print("[preview] exit=%d log=%s" % (r.returncode, log))
    for ln in text.splitlines():
        if "[Map]" in ln or "ERROR" in ln or "SCRIPT" in ln:
            print("   | " + ln)
    if not os.path.exists(out):
        print("[preview] !! 没有出图")
        return 1
    print("[preview] OK %s  %.0f KB" % (out, os.path.getsize(out) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())

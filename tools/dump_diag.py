#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""tools/dump_diag.py — 导出诊断图（运行时图集 / 群系分布）

排查"进游戏颜色不对"时最缺的是「中间产物」：图集不是磁盘文件而是运行时拼的，
群系分布只存在日志文字里。这两张图把它们落成 PNG。

用法：
    python tools/dump_diag.py [--out-dir DIR] [--zoom 2] [--seed N]
                              [--atlas] [--biome] [--both]
不带 --atlas/--biome 时两张都出。
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


def run(tag, out_png, extra, log_path):
    cmd = [GODOT, "--headless", "--path", ROOT, "--quit-after", "900",
           "res://Scenes/Main.tscn", "--"] + extra
    print("[diag:%s] %s" % (tag, " ".join(cmd)))
    r = subprocess.run(cmd, capture_output=True, timeout=900)
    text = (r.stdout + b"\n" + r.stderr).decode("utf-8", "replace")
    io.open(log_path, "a", encoding="utf-8", newline="").write(
        "\n===== %s =====\n%s" % (tag, text))
    for ln in text.splitlines():
        if "[Map]" in ln or "ERROR" in ln or "SCRIPT" in ln or "WARNING" in ln:
            print("   | " + ln)
    if not os.path.exists(out_png):
        print("[diag:%s] !! 没有出图" % tag)
        return 1
    print("[diag:%s] OK %s  %.0f KB" % (tag, out_png, os.path.getsize(out_png) / 1024.0))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default=ROOT)
    ap.add_argument("--zoom", type=int, default=2)
    ap.add_argument("--seed", type=int, default=20260916)
    ap.add_argument("--atlas", action="store_true")
    ap.add_argument("--biome", action="store_true")
    args = ap.parse_args()

    do_atlas = args.atlas or not args.biome
    do_biome = args.biome or not args.atlas

    d = args.out_dir.replace("\\", "/")
    log_path = os.path.join(LOG_DIR, "_diag_dump.log")
    io.open(log_path, "w", encoding="utf-8", newline="").write("")
    rc = 0
    if do_atlas:
        p = "%s/_dump_atlas.png" % d
        rc |= run("atlas", p, ["--dump-atlas", p, "--zoom", str(args.zoom)], log_path)
    if do_biome:
        p = "%s/_dump_biome.png" % d
        rc |= run("biome", p, ["--dump-biome", p, "--zoom", str(args.zoom),
                               "--seed", str(args.seed)], log_path)
    return rc


if __name__ == "__main__":
    sys.exit(main())

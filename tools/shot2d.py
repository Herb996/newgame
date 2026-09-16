#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""tools/shot2d.py — 2D 局内实拍截图（开窗口、真渲染）

为什么不能无头：--headless 用的是 dummy 渲染驱动，viewport 贴图永远是空的，
截出来是纯黑。所以这个工具**不加 --headless**，必须真的开一个窗口。

参数全部走 main.gd 的命令行入口，不改 Data/config.json。

用法：
    python tools/shot2d.py <输出png> [--delay 2.5] [--res 1600x900] [--seed N]
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
    ap.add_argument("--delay", type=float, default=2.5, help="进局后等多少秒再截")
    ap.add_argument("--res", default="1600x900")
    ap.add_argument("--seed", type=int, default=20260916)
    ap.add_argument("--no-fog", action="store_true",
                    help="关掉迷雾再截：看清地图本体（默认开雾，地面会被黑雾压暗）")
    ap.add_argument("--weapon", default="",
                    help="强制玩家武器（sword / bow），走 main.gd 的 --weapon 通道，不改 config")
    args = ap.parse_args()

    out = args.out if os.path.isabs(args.out) else os.path.join(ROOT, args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    out = out.replace("\\", "/")

    cmd = [GODOT, "--path", ROOT, "--resolution", args.res, "--quit-after", "400",
           "res://Scenes/Main.tscn",
           "--", "--capture2d", out,
           "--capture-delay", str(args.delay),
           "--seed", str(args.seed)]
    if args.no_fog:
        cmd.append("--no-fog")
    if args.weapon:
        cmd += ["--weapon", args.weapon]
    print("[shot2d] %s" % " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, timeout=300)
    text = (r.stdout + b"\n" + r.stderr).decode("utf-8", "replace")
    log = os.path.join(LOG_DIR, "_shot2d.log")
    io.open(log, "w", encoding="utf-8", newline="").write(text)
    print("[shot2d] exit=%d log=%s" % (r.returncode, log))
    for ln in text.splitlines():
        if any(k in ln for k in ("[Shot]", "[Map]", "[Enemy]", "[Animal]", "[Loot]",
                                 "ERROR", "SCRIPT", "[Run]")):
            print("   | " + ln)
    if not os.path.exists(out):
        print("[shot2d] !! 没有出图")
        return 1
    print("[shot2d] OK %s  %.0f KB" % (out, os.path.getsize(out) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())

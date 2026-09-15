#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tools/shot.py — 局内 3D 画面出图（画质对比 / 回归用）

用法：
  python tools/shot.py <输出png> [--res 1920x1080] [--renderer forward_plus|gl_compatibility]
                       [--method forward_plus|...] [--size 46] [--seed N] [--udbx]
                       [--driver vulkan|opengl3]

原理：临时改 Data/config.json（固定种子 + main3d_start=run + 截图路径），
      跑 Godot 窗口模式出图，结束后**一定还原** config（含异常路径）。

为什么要固定种子：画质对比必须同一张地图、同一个镜头位置，否则比不出东西。
"""
import argparse
import io
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, "Data", "config.json")
GODOT = os.environ.get(
    "GODOT_BIN", r"C:/Users/Administrator/Downloads/Godot_v4.7.2-stable_win64_console.exe")


def _load():
    with io.open(CONFIG, encoding="utf-8") as f:
        return json.load(f)


def _save(d):
    with io.open(CONFIG, "w", encoding="utf-8", newline="") as f:
        f.write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--res", default="1920x1080")
    ap.add_argument("--method", default="", help="rendering_method.mobile 时用")
    ap.add_argument("--renderer", default="", help="命令行覆盖渲染方法")
    ap.add_argument("--size", type=float, default=0.0, help="camera3d.size，0=不改")
    ap.add_argument("--seed", type=int, default=20260915)
    ap.add_argument("--delay", type=float, default=3.0)
    ap.add_argument("--extra-cfg", default="", help="JSON 片段，深度覆盖到 config")
    args = ap.parse_args()

    out = args.out if os.path.isabs(args.out) else os.path.join(ROOT, args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)

    d = _load()
    bak = CONFIG + ".bak_shot"
    shutil.copy2(CONFIG, bak)
    try:
        d["debug"]["main3d_start"] = "run"
        d["debug"]["main3d_capture"] = out.replace("\\", "/")
        d["debug"]["main3d_capture_delay"] = args.delay
        d["debug"]["main3d_capture_frames"] = 1
        d["map"]["force_seed"] = args.seed
        if args.size > 0.0:
            d["camera3d"]["size"] = args.size
        if args.extra_cfg:
            patch = json.loads(args.extra_cfg)

            def deep(dst, src):
                for k, v in src.items():
                    if isinstance(v, dict) and isinstance(dst.get(k), dict):
                        deep(dst[k], v)
                    else:
                        dst[k] = v
            deep(d, patch)
        _save(d)

        cmd = [GODOT, "--path", ROOT, "--resolution", args.res,
               "--quit-after", "260"]
        if args.renderer:
            cmd += ["--rendering-method", args.renderer]
        if args.method:
            cmd += ["--rendering-method", args.method]
        print("[shot] %s" % " ".join(cmd))
        r = subprocess.run(cmd, capture_output=True, timeout=300)
        text = (r.stdout + b"\n" + r.stderr).decode("utf-8", "replace")
        log = os.path.join(ROOT, "_shot.log")
        with io.open(log, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        print("[shot] exit=%d  log=%s" % (r.returncode, log))
        keep = ["ERROR", "Godot Engine v", "Vulkan", "OpenGL", "driver",
                "Main3D", "MapRender3D", "PlayerVisual3D"]
        for ln in text.splitlines():
            if any(k in ln for k in keep):
                print("   | " + ln)
        if os.path.exists(out):
            print("[shot] OK %s  %.0f KB" % (out, os.path.getsize(out) / 1024.0))
        else:
            print("[shot] !! 没有出图")
            return 1
    finally:
        shutil.copy2(bak, CONFIG)
        os.remove(bak)
        print("[shot] config 已还原")
    return 0


if __name__ == "__main__":
    sys.exit(main())

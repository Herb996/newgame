# -*- coding: utf-8 -*-
"""一次性跑完全部回归探针并打印关键结论。

为什么写成脚本而不是一串 shell 命令：本项目所在环境的 bash shim 时好时坏
（管道/引号/退出码都可能失真），用 Python 起子进程最稳，也能一次性把
多份日志汇总成一张表。

用法：
    python tools/run_regression.py
"""
import io
import json
import os
import subprocess
import sys

GODOT = r"C:/Users/Administrator/Downloads/Godot_v4.7.2-stable_win64_console.exe"
PROJ = "D:/SteamPunkExtraction"
OUT = "C:/Users/Administrator/WorkBuddy/2026-09-14-22-35-14"

# (场景, 日志名, 需要打印的关键前缀)
SUITES = [
    ("Dev/probe_registry.tscn", "_r_registry.log", ("[Probe]",)),
    ("Dev/probe_player_anim.tscn", "_r_anim.log", ("[ProbeAnim]",)),
    ("Dev/probe_zoom.tscn", "_r_zoom.log", ("[ZoomProbe]",)),
    ("Dev/probe_terrain_map.tscn", "_r_terrain.log", ("[TerrainProbe]", "[Map]")),
]

BAD_MARKS = ("SCRIPT ERROR", "Parse Error", "Invalid call", "Invalid access",
             "Attempt to call", "Node not found", "Failed to load")


def run(scene, logname, prefixes):
    log = os.path.join(OUT, logname)
    with io.open(log, "wb") as f:
        p = subprocess.run([GODOT, "--headless", "--path", PROJ, scene],
                           stdout=f, stderr=subprocess.STDOUT)
    text = io.open(log, encoding="utf-8", errors="replace").read()
    print("=" * 78)
    print("%s   EXIT=%d" % (scene, p.returncode))
    bad = 0
    for line in text.splitlines():
        st = line.strip()
        if any(m in st for m in BAD_MARKS):
            print("   !! %s" % st[:170])
            bad += 1
        if st.startswith(prefixes):
            print("   %s" % st[:180])
    print("   异常行: %d" % bad)
    return p.returncode, bad


def flow_test():
    """主流程自检：需要临时打开 debug.flow_test，跑完还原。"""
    cfg = os.path.join(PROJ, "Data/config.json")
    s = io.open(cfg, encoding="utf-8", newline="").read()
    if '"flow_test": false' not in s:
        print("!! config 里找不到 flow_test，跳过")
        return
    io.open(cfg, "w", encoding="utf-8", newline="").write(
        s.replace('"flow_test": false', '"flow_test": true'))
    json.loads(io.open(cfg, encoding="utf-8").read())
    try:
        log = os.path.join(OUT, "_r_flow.log")
        with io.open(log, "wb") as f:
            p = subprocess.run([GODOT, "--headless", "--path", PROJ],
                               stdout=f, stderr=subprocess.STDOUT)
        text = io.open(log, encoding="utf-8", errors="replace").read()
        print("=" * 78)
        print("flow_test (3D 主流程)   EXIT=%d" % p.returncode)
        bad = 0
        for line in text.splitlines():
            st = line.strip()
            if any(m in st for m in BAD_MARKS):
                print("   !! %s" % st[:170])
                bad += 1
            if st.startswith("[FlowTest]") and ("结束" in st or "!!" in st):
                print("   %s" % st[:180])
        print("   异常行: %d" % bad)
    finally:
        s2 = io.open(cfg, encoding="utf-8", newline="").read()
        io.open(cfg, "w", encoding="utf-8", newline="").write(
            s2.replace('"flow_test": true', '"flow_test": false'))
        print("   (flow_test 已还原为 false)")


if __name__ == "__main__":
    if not os.path.exists(GODOT):
        sys.exit("找不到 Godot: " + GODOT)
    total_bad = 0
    for scene, logname, prefixes in SUITES:
        rc, bad = run(scene, logname, prefixes)
        total_bad += bad
    flow_test()
    print("=" * 78)
    print("全部异常行合计: %d" % total_bad)

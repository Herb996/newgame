# -*- coding: utf-8 -*-
"""触发 Godot 资源导入（生成 .import + .godot/imported 缓存）。

为什么必须单独跑这步：`godot --path X` 直接跑项目时不会导入新素材，
`load("res://新图.png")` 会静默失败（返回 null），日志里只留一条"贴图缺失"警告。
导入必须走编辑器模式。

用法：
    python tools/godot_import.py [日志名]
"""
import subprocess
import sys
import io
import os

GODOT = r"C:/Users/Administrator/Downloads/Godot_v4.7.2-stable_win64_console.exe"
PROJ = "D:/SteamPunkExtraction"
OUT_DIR = os.environ.get("WB_LOG_DIR", "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42")


def main() -> int:
    log_name = sys.argv[1] if len(sys.argv) > 1 else "_import.log"
    cmd = [GODOT, "--headless", "--path", PROJ, "--import"]
    p = subprocess.run(cmd, capture_output=True)
    text = (p.stdout + b"\n" + p.stderr).decode("utf-8", "replace")
    path = os.path.join(OUT_DIR, log_name)
    io.open(path, "w", encoding="utf-8", newline="").write(text)
    # 只回显值得看的部分，避免几百行 import 噪音
    keep = [ln for ln in text.splitlines()
            if ("ERROR" in ln or "error" in ln or "WARNING" in ln
                or "Failed" in ln or "failed" in ln)]
    print("EXIT =", p.returncode)
    print("LOG  =", path, os.path.getsize(path), "bytes")
    print("--- 关键行 (%d) ---" % len(keep))
    for ln in keep[:80]:
        print(ln)
    return p.returncode


if __name__ == "__main__":
    sys.exit(main())

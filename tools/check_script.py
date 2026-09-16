# -*- coding: utf-8 -*-
"""语法检查指定 GDScript（不走主循环，不会挂）。

为什么不用 PowerShell 重定向：`>` / `*>` 在本机 PowerShell 5.1 下写的是 UTF-16，
读出来是"二进制文件"，中文报错全糊；而且子进程一旦往 stderr 写东西，
配合 $ErrorActionPreference='Stop' 会把整条管线当致命错误中断，
表现成"命令秒退、什么也没留下"。

用法：python tools/check_script.py res://Scripts/soak_probe.gd [更多脚本...]
"""
import io
import os
import subprocess
import sys

GODOT = r"C:/Users/Administrator/Downloads/Godot_v4.7.2-stable_win64_console.exe"
PROJ = "D:/SteamPunkExtraction"
OUT_DIR = os.environ.get("WB_LOG_DIR", "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42")


def main() -> int:
    scripts = sys.argv[1:] or ["res://Scripts/soak_probe.gd"]
    report = []
    worst = 0
    for s in scripts:
        cmd = [GODOT, "--headless", "--path", PROJ, "--check-only", "--script", s]
        p = subprocess.run(cmd, capture_output=True, timeout=120)
        text = (p.stdout + b"\n" + p.stderr).decode("utf-8", "replace")
        bad = [ln for ln in text.splitlines()
               if ("ERROR" in ln or "SCRIPT ERROR" in ln or "Parse Error" in ln)]
        report.append("=== %s  exit=%d  问题行=%d" % (s, p.returncode, len(bad)))
        for ln in bad[:40]:
            report.append("    " + ln)
        worst = max(worst, 1 if bad or p.returncode != 0 else 0)
    out = os.path.join(OUT_DIR, "_check.txt")
    io.open(out, "w", encoding="utf-8", newline="").write("\n".join(report) + "\n")
    return worst


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        import traceback
        io.open(os.path.join(OUT_DIR, "_check_error.txt"), "w",
                encoding="utf-8", newline="").write(traceback.format_exc())
        sys.exit(3)

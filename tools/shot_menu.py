# -*- coding: utf-8 -*-
"""开窗跑开始菜单并截图（验证界面用）。

为什么单独一个脚本、而不是在命令行里拼参数：
  1. 截图**必须开窗** —— 无头是 dummy 渲染驱动，viewport 贴图永远是空的，
     截出来只会是纯黑（这条在 tools/shot2d.py 里也踩过）。
  2. `--` 用户参数通道在 PowerShell 里容易被吞，Godot 会秒退且不留日志。
  3. 由 Python 统一落盘 UTF-8 日志、自己恒返回 0，日志才是唯一真相。

用法：
    python tools/shot_menu.py _menu_main.png
    python tools/shot_menu.py _menu_settings.png --panel settings
    python tools/shot_menu.py _menu_slots.png --panel new --delay 2.0

--panel 取值：new | load | settings | misc（截图前先打开对应面板）
--tab N      配合 --panel settings：打开后停在第 N 页
             （0 画面 / 1 音频 / 2 玩法 / 3 操作 / 4 语言 / 5 调试）
"""
import io
import os
import subprocess
import sys

GODOT = r"C:/Users/Administrator/Downloads/Godot_v4.7.2-stable_win64_console.exe"
PROJ = "D:/SteamPunkExtraction"
SCENE = "res://Scenes/StartMenu.tscn"
OUT_DIR = os.environ.get("WB_LOG_DIR", "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42")

BAD_PREFIX = ("WARNING", "ERROR", "SCRIPT ERROR", "USER WARNING", "USER ERROR")


def main() -> int:
    out_png = "_menu.png"
    panel = ""
    delay = 1.5
    tab = 0

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--panel":
            i += 1
            panel = args[i] if i < len(args) else ""
        elif a == "--delay":
            i += 1
            delay = float(args[i]) if i < len(args) else 1.5
        elif a == "--tab":
            i += 1
            tab = int(args[i]) if i < len(args) else 0
        elif not a.startswith("--"):
            out_png = a
        i += 1

    cmd = [GODOT, "--path", PROJ, SCENE, "--",
           "--menu-capture", out_png, "--menu-capture-delay", str(delay),
           "--menu-tab", str(tab)]
    if panel:
        cmd += ["--menu-panel", panel]

    p = subprocess.run(cmd, capture_output=True, timeout=180)
    text = (p.stdout + b"\n" + p.stderr).decode("utf-8", "replace")
    io.open(os.path.join(OUT_DIR, "_menu_shot.log"), "w",
            encoding="utf-8", newline="").write(text)

    summary = ["---------- 菜单截图  panel=%s  tab=%d  输出=%s  GODOT EXIT=%d"
               % (panel or "(主菜单)", tab, out_png, p.returncode)]
    for ln in text.splitlines():
        if ln.startswith(BAD_PREFIX) or ln.startswith("[Menu]") or "[Config]" in ln \
                or "[SaveSlots]" in ln or "[Meta]" in ln or "[DisplaySettings]" in ln:
            summary.append(ln)
    io.open(os.path.join(OUT_DIR, "_menu_shot_summary.txt"), "w",
            encoding="utf-8", newline="").write("\n".join(summary) + "\n")
    print("\n".join(summary))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        import traceback
        io.open(os.path.join(OUT_DIR, "_menu_shot_error.txt"), "w",
                encoding="utf-8", newline="").write(traceback.format_exc())
        sys.exit(3)

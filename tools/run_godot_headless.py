# -*- coding: utf-8 -*-
"""跑 Godot 并把 stdout+stderr 收集到一个 UTF-8 日志里。

为什么不用 shell 重定向：本机 Git Bash 的 shim 时好时坏（dirname/cd 报错、SIGTERM），
PowerShell 的 `*>` 会写成 UTF-16 让 Read 认为是二进制。用 subprocess 直接抓字节最稳。

用法：
    python tools/run_godot_headless.py <日志名> <场景相对路径(可省)> [--window] [--resolution WxH]
"""
import subprocess
import sys
import io
import os

GODOT = r"C:/Users/Administrator/Downloads/Godot_v4.7.2-stable_win64_console.exe"
PROJ = "D:/SteamPunkExtraction"
OUT_DIR = os.environ.get("WB_LOG_DIR", "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42")


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print("需要日志文件名，例如 _run.log")
        return 2
    log_name = args[0]
    rest = args[1:]

    cmd = [GODOT, "--path", PROJ]
    window = False
    scene = None
    user_args = []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--window":
            window = True
        elif a == "--resolution":
            i += 1
            cmd += ["--resolution", rest[i]]
        elif a == "--quit-after":
            i += 1
            cmd += ["--quit-after", rest[i]]
        elif a == "--fixed-fps":
            i += 1
            cmd += ["--fixed-fps", rest[i]]
        elif a == "--":
            # 后面的全部透传给 Godot 的 `--` 用户参数通道（--soak / --capture2d 等）
            user_args = rest[i + 1:]
            break
        else:
            scene = a
        i += 1

    if not window:
        cmd.insert(1, "--headless")
    if scene:
        cmd.append(scene)
    if user_args:
        cmd.append("--")
        cmd += user_args

    p = subprocess.run(cmd, capture_output=True)
    out = p.stdout + b"\n" + p.stderr
    text = out.decode("utf-8", "replace")
    path = os.path.join(OUT_DIR, log_name)
    io.open(path, "w", encoding="utf-8", newline="").write(text)

    print("EXIT =", p.returncode)
    print("LOG  =", path, os.path.getsize(path), "bytes")
    return p.returncode


if __name__ == "__main__":
    sys.exit(main())

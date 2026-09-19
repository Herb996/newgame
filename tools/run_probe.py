# -*- coding: utf-8 -*-
"""跑 Godot 探针/自检，把 stdout+stderr 收集到 UTF-8 日志里。

为什么不用 shell 重定向：本机 Git Bash 的 shim 时好时坏（dirname/cd 报错、SIGTERM），
PowerShell 的 `*>` 会写成 UTF-16。用 subprocess 直接抓字节最稳。

用法：
    python tools/run_probe.py <日志名> [场景相对路径] [--window] [--resolution WxH]

不传场景时跑项目主场景（F5 的入口）。
"""
import io
import os
import subprocess
import sys

GODOT = r"C:/Users/Administrator/Downloads/Godot_v4.7.2-stable_win64_console.exe"
PROJ = r"D:/SteamPunkExtraction"
OUT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
## 探针跑飞了（半路报错、没走到 quit()）时不能把调用方一起挂住 ——
## terrain 探针当年就是崩在半路，run_probe 一直没有超时，整条回归卡死。
TIMEOUT = 600


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print("需要日志文件名，例如 _probe.log")
        return 2
    log_name = args[0]
    rest = args[1:]

    cmd = [GODOT, "--path", PROJ]
    window = False
    scene = None
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
        else:
            scene = a
        i += 1

    if not window:
        cmd.insert(1, "--headless")
    if scene:
        cmd.append(scene)

    rc = -1
    timed_out = False
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=TIMEOUT)
        rc = p.returncode
        raw = p.stdout + b"\n" + p.stderr
    except subprocess.TimeoutExpired as e:
        timed_out = True
        raw = (e.stdout or b"") + b"\n" + (e.stderr or b"")
    text = raw.decode("utf-8", "replace")
    path = os.path.join(OUT_DIR, log_name)
    io.open(path, "w", encoding="utf-8", newline="").write(text)

    print("EXIT =", "超时 %ds，进程已杀（探针没走到 quit()）" % TIMEOUT
          if timed_out else rc)
    print("LOG  =", path, os.path.getsize(path), "bytes")
    print("----- tail -----")
    print("\n".join(text.splitlines()[-60:]))
    return 124 if timed_out else rc


if __name__ == "__main__":
    sys.exit(main())

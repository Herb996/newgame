# -*- coding: utf-8 -*-
"""跑行为验证探针（--soak）并把报告写成 UTF-8 日志。

为什么单独做一个包装脚本，而不是在命令行里拼参数：
  1. `--` 用户参数通道在 PowerShell 里容易和「结束参数解析」的语义打架，
     参数一多就被吞掉，表现为"命令秒退、日志压根没生成"。
  2. PowerShell 里 `2>&1` 配合 $ErrorActionPreference='Stop' 会把子进程的 stderr
     当致命错误，**中断整条管线** —— 后面的日志写入根本不会执行。
  3. 探针失败时 Godot 退出码是 1（这是设计：脚本化回归看退出码），
     但某些 shell 宿主见到非零退出码也会中断管线。
  所以统一：由本脚本 subprocess 拉起 Godot、把 UTF-8 日志落盘、
  再把关键行撇成 summary，**自身恒返回 0**，日志才是唯一真相。

用法：
    python tools/run_soak.py [--seconds 30] [--kill-ratio 0.3] [--trace]
                             [--seed 123] [--seed 456] [--log _soak.log]

给多个 --seed 会依次跑多张随机地图（每次覆盖同一张图会看不出是"运气好"还是"真修好了"），
最终 summary 里每行都带 seed 前缀。
"""
import io
import os
import subprocess
import sys

GODOT = r"C:/Users/Administrator/Downloads/Godot_v4.7.2-stable_win64_console.exe"
PROJ = "D:/SteamPunkExtraction"
OUT_DIR = os.environ.get("WB_LOG_DIR", "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42")

KEYS = ("[Soak]", "[SoakTrace]", "[SoakStall]")
BAD_PREFIX = ("WARNING", "ERROR", "SCRIPT ERROR", "USER WARNING", "USER ERROR")


def run_once(seconds, kill_ratio, trace, seed):
    cmd = [
        GODOT, "--headless", "--path", PROJ,
        # 固定帧率：模拟时间不再跟真实时间挂钩，40 秒行为几秒就跑完
        "--fixed-fps", "60",
        "res://Scenes/Main.tscn",
        "--",
        "--soak", str(seconds),
        "--soak-kill-ratio", str(kill_ratio),
    ]
    if seed is not None:
        cmd += ["--seed", str(seed)]
    if trace:
        cmd.append("--soak-trace")
    p = subprocess.run(cmd, capture_output=True)
    text = (p.stdout + b"\n" + p.stderr).decode("utf-8", "replace")
    return p.returncode, text


def main() -> int:
    seconds, kill_ratio, log_name, trace = 30.0, 0.3, "_soak.log", False
    seeds = []

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--seconds":
            i += 1
            seconds = float(args[i])
        elif a == "--kill-ratio":
            i += 1
            kill_ratio = float(args[i])
        elif a == "--log":
            i += 1
            log_name = args[i]
        elif a == "--trace":
            trace = True
        elif a == "--seed":
            i += 1
            seeds.append(int(args[i]))
        i += 1

    if not seeds:
        seeds = [None]

    summary = []
    warn = {}
    for seed in seeds:
        tag = "seed=%s" % (seed if seed is not None else "随机")
        code, text = run_once(seconds, kill_ratio, trace, seed)

        out_name = log_name if seed is None else log_name.replace(".log", "_%s.log" % seed)
        out_path = os.path.join(OUT_DIR, out_name)
        io.open(out_path, "w", encoding="utf-8", newline="").write(text)

        summary.append("---------- %s  GODOT EXIT=%d（0=PASS, 1=FAIL）  日志=%s"
                       % (tag, code, out_name))
        for ln in text.splitlines():
            if ln.startswith(BAD_PREFIX):
                warn[ln] = warn.get(ln, 0) + 1
                continue
            if any(ln.startswith(k) for k in KEYS):
                summary.append("[" + tag + "] " + ln)

    for ln, n in warn.items():
        summary.append("%s   ×%d" % (ln, n))

    io.open(os.path.join(OUT_DIR, "_soak_summary.txt"), "w",
            encoding="utf-8", newline="").write("\n".join(summary) + "\n")
    print("\n".join(summary))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # 把异常落到文件里：调用方看到的只会是"命令失败"，
        # 不落盘就完全无法排查（shell 管线可能已在非零退出码处中断）。
        import traceback
        io.open(os.path.join(OUT_DIR, "_soak_error.txt"), "w",
                encoding="utf-8", newline="").write(traceback.format_exc())
        sys.exit(3)

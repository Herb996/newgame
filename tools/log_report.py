# -*- coding: utf-8 -*-
"""汇总一次 Godot 日志：按标签分类计数 + 列出所有 ERROR/WARNING（去重）。

为什么需要它：本机 PowerShell 的管道会把中文糊掉，而且直接用 -match 统计
在几万行日志上很慢；统一用 Python 读文件最稳。

用法：python tools/log_report.py <日志路径>
"""
import io
import os
import re
import sys

TAGS = ("[Map]", "[Enemy]", "[Animal]", "[Loot]", "[Run]", "[Soak]", "[SoakStall]",
        "[PlayerAnimator]", "[Base]", "[Combat]", "[Skill]", "[Player]",
        "[ResourceRegistry]", "[Noise]", "[Shot]")


def main() -> int:
    path = sys.argv[1]
    text = io.open(path, encoding="utf-8", errors="replace").read()
    lines = text.splitlines()
    out = ["日志：%s（%d 行）" % (path, len(lines))]

    bad = {}
    for ln in lines:
        if re.match(r"^(ERROR|SCRIPT ERROR|WARNING|USER ERROR|USER WARNING)", ln):
            bad[ln] = bad.get(ln, 0) + 1
    out.append("ERROR/WARNING 唯一行 = %d，总出现次数 = %d"
               % (len(bad), sum(bad.values())))
    for ln, n in sorted(bad.items(), key=lambda kv: -kv[1]):
        out.append("    ×%-5d %s" % (n, ln))

    out.append("--- 关键标签行 ---")
    for ln in lines:
        if any(ln.startswith(t) for t in TAGS):
            out.append("    " + ln)
    io.open(path + ".report.txt", "w", encoding="utf-8", newline="").write(
        "\n".join(out) + "\n")
    print("report ->", path + ".report.txt")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        import traceback
        io.open(os.path.join(os.path.dirname(sys.argv[1]), "_logrep_error.txt"),
                "w", encoding="utf-8", newline="").write(traceback.format_exc())
        sys.exit(3)

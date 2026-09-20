# -*- coding: utf-8 -*-
"""一次性脚本：从 Data/config.json 里按文本行删掉指定的整块（保留其余字节不动）。

为什么不用 json.load/dump：config.json 里每个段都带 _comment / _note_* 长注释，
重新序列化会把 5000 行重排成另一副样子，别人的未提交改动也没法看 diff。
这里只按大括号配平切行区间，其余一个字节都不碰。
"""
import io
import sys

PATH = "Data/config.json"


def block_range(lines, key_line):
    """key_line = 0-based 行号，该行形如 `  "name": {` / `"name": [ ... ]` / `"name": 240,`。
    返回要删除的行区间 [start, end]（0-based，闭区间）。"""
    start = key_line
    depth = 0
    for i in range(start, len(lines)):
        line = lines[i]
        in_str = False
        esc = False
        for ch in line:
            if esc:
                esc = False
                continue
            if ch == "\\":
                esc = True
                continue
            if ch == '"':
                in_str = not in_str
                continue
            if in_str:
                continue
            if ch in "{[":
                depth += 1
            elif ch in "}]":
                depth -= 1
        if depth == 0:
            return start, i
        if depth < 0:
            raise SystemExit("配平失败（%d 行）：%r" % (i + 1, line[:80]))
    raise SystemExit("没找到块的结尾")


def find_key(lines, path):
    """path 形如 combat.weapons.sniper / sprites_pawn：按缩进层级找最后一段的键行。"""
    parts = path.split(".")
    key = '"%s"' % parts[-1]
    hits = [i for i, l in enumerate(lines) if key + ":" in l]
    if len(hits) != 1:
        raise SystemExit("键 %s 命中 %d 处，需要唯一：%s" % (key, len(hits), [h + 1 for h in hits]))
    return hits[0]


def main():
    paths = sys.argv[1:]
    raw = io.open(PATH, encoding="utf-8-sig").read()
    lines = raw.split("\n")
    doomed = set()
    blocks = []
    for p in paths:
        s, e = block_range(lines, find_key(lines, p))
        snippet = " | ".join(l.strip()[:40] for l in lines[s:e + 1][:2])
        print("删除 %-28s 行 %4d-%4d（%d 行）  %s" % (p, s + 1, e + 1, e - s + 1, snippet))
        blocks.append((s, e))
        doomed.update(range(s, e + 1))
    for s, e in blocks:
        if lines[e].rstrip().endswith(","):
            continue          # 后面还有兄弟项，逗号归前一行管
        prev = s - 1
        while prev >= 0 and (prev in doomed or lines[prev].strip() == ""):
            prev -= 1
        if prev >= 0 and lines[prev].rstrip().endswith(","):
            lines[prev] = lines[prev].rstrip()[:-1]
            print("   -> 行 %d 行尾逗号去掉：%s" % (prev + 1, lines[prev].strip()[:50]))
    out = "\n".join(l for i, l in enumerate(lines) if i not in doomed)
    io.open(PATH, "w", encoding="utf-8-sig", newline="").write(out)
    import json
    json.loads(io.open(PATH, encoding="utf-8-sig").read())
    print("JSON 仍然合法，共删 %d 行" % len(doomed))


if __name__ == "__main__":
    main()

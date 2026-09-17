#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""需求面板生成器（JSON 为唯一事实源）。

    python tools/gen_requirements_html.py

读取  docs/requirements.json
产出  docs/requirements.html   （可编辑可视化页面，导出即回写 JSON）

需求文档统一维护在 docs/DESIGN.md，本脚本不再单独生成 md。
项目搬家后无需改本脚本：路径全部相对脚本自身推导。
"""
import json
import sys
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent          # <root>/tools
ROOT = HERE.parent                              # <root>
SRC = ROOT / "docs" / "requirements.json"
OUT_HTML = ROOT / "docs" / "requirements.html"
OUT_MD = None  # 需求文档统一维护在 docs/DESIGN.md，本脚本不再单独生成 md

SM = {"done": "✅ 已完成", "doing": "🔄 进行中", "planned": "⏳ 已拍板未做",
      "design": "❓ 待设计", "blocked": "⛔ 素材阻塞", "p0": "⚠️ P0阻塞", "paused": "⏸ 暂缓"}


def build_md(data):
    L = []
    L.append("# requirements.md — 需求全景（自动生成，勿手改）\n")
    L.append("> 本文件由 `docs/requirements.json` 生成。修改需求请编辑 JSON，")
    L.append("> 或直接在网页 `docs/requirements.html` 中编辑后导出覆盖 JSON，")
    L.append("> 再运行 `python tools/gen_requirements_html.py` 同步本文件。\n")
    L.append("| 符号 | 含义 |")
    L.append("| :--- | :--- |")
    for k, v in SM.items():
        L.append(f"| {v.split(' ',1)[0]} | {v.split(' ',1)[1]} |")
    L.append("\n优先级：**P0** 试玩/发布前必须 · **P1** Phase 1 垂直切片 · **P2** Phase 2 内容填充 · **P3** 中长期\n")
    L.append("---\n")
    total = done = 0
    wsum = 0.0
    for cat in data["categories"]:
        items = [i for g in cat["groups"] for i in g["items"]]
        d = sum(1 for i in items if i["s"] == "done")
        w = sum(i.get("w", 0) for i in items if i["s"] != "done")
        total += len(items); done += d; wsum += w
        L.append(f"# {cat['icon']} {cat['name']}（{cat['key']}） — {d}/{len(items)} 完成 · 剩余约 {w:g} 人天\n")
        L.append(f"> {cat['desc']}\n")
        for g in cat["groups"]:
            if not g["items"]:
                continue
            L.append(f"## {g['name']}\n")
            L.append("| ID | 需求 | 状态 | 优先级 | 工作量(天) | 相关代码 | 依赖 | 来源 |")
            L.append("| :--- | :--- | :---: | :---: | :---: | :--- | :--- | :--- |")
            for i in g["items"]:
                c = "<br>".join(f"`{x}`" for x in i.get("c", [])) or "—"
                dep = " ".join(i.get("d", [])) or "—"
                old = ("（旧 " + " ".join(i["o"]) + "）") if i.get("o") else ""
                note = f" **{i['n']}**" if i.get("n") else ""
                L.append(f"| {i['id']} | {i['t']}{old}{note} | {SM[i['s']]} | {i['p'] or '—'} | "
                         f"{i.get('w',0) or '—'} | {c} | {dep} | {i.get('src','')} |")
            L.append("")
    L.append("---\n")
    L.append(f"# 汇总\n")
    L.append(f"- 需求总数 **{total}**，已完成 **{done}**（{round(done/total*100)}%），"
             f"未完成 **{total-done}**，剩余工作量约 **{wsum:g} 人天**")
    p0 = [i for cat in data["categories"] for g in cat["groups"] for i in g["items"] if i["s"] == "p0"]
    if p0:
        L.append(f"- ⚠️ P0 阻塞项：{', '.join(i['id']+' '+i['t'] for i in p0)}")
    L.append("\n## 待拍板清单\n")
    L.append("| # | 问题 | 阻塞 |")
    L.append("| :--- | :--- | :--- |")
    for o in data["meta"]["open_questions"]:
        L.append(f"| {o['no']} | {o['q']} | {', '.join(o['blocks'])} |")
    L.append("")
    return "\n".join(L)


def check_files(globs):
    found = []
    for g in globs:
        for h in sorted(ROOT.glob(g)):
            found.append(str(h.relative_to(ROOT)).replace("\\", "/"))
            if len(found) >= 8:
                return found
    return found


def build_checklist(data):
    """完整需求↔落地现状核对树：
    美术 = docs/asset_checklist.json 手工细项（逐素材 glob 核对）；
    其余 5 系统 = requirements.json 每条需求一个叶子（状态 + 代码文件在不在磁盘）；
    末节 = 待拍板 open_questions（MD 提了但没定的，一块反馈）。"""
    path = ROOT / "docs" / "asset_checklist.json"
    if path.exists():
        ck = json.loads(path.read_text(encoding="utf-8"))
    else:
        print("提示: 缺 docs/asset_checklist.json（美术细项树将为空）")
        ck = {"tree": []}

    def walk(node):
        if "children" in node:
            for ch in node["children"]:
                walk(ch)
            return
        node["img"] = True
        node["found"] = check_files(node.get("check", []))
        if node.get("verdict") == "missing":
            node["found"] = []   # 占位顶替文件不算"找到"
        elif not node.get("verdict"):
            node["verdict"] = "ok" if node["found"] else "missing"
    for t in ck["tree"]:
        walk(t)

    # 其余 5 系统：每条需求一行
    S_LBL = {"done": "已完成", "doing": "进行中", "planned": "已拍板未做", "design": "待设计",
             "blocked": "素材阻塞", "p0": "P0 阻塞", "paused": "暂缓"}
    auto = []
    for cat in data["categories"]:
        if cat["key"] == "art":
            continue
        groups = []
        for g in cat["groups"]:
            leaves = []
            for i in g["items"]:
                files = check_files(i.get("c", []))
                s = i["s"]
                if s == "done":
                    v = "ok" if files else "warn"
                    act = "已完成" + ("" if files else "（⚠ 标记完成但代码文件没找到）")
                elif s == "doing":
                    v, act = "warn", "进行中"
                elif s == "paused":
                    v, act = "warn", "暂缓"
                else:
                    v = "missing"
                    act = S_LBL.get(s, s) + ("（代码文件已存在，待接线）" if files else "")
                leaves.append({"key": i["id"], "name": i["t"], "expect": "出处 " + i.get("src", "—"),
                               "actual": act, "check": i.get("c", []), "found": files,
                               "img": False, "verdict": v, "req": ""})
            groups.append({"name": g["name"], "children": leaves})
        auto.append({"name": f"{cat['icon']} {cat['name']}", "children": groups})

    # 待拍板：MD 提了但没定的
    oq = [{"key": f"oq{o['no']}", "name": f"#{o['no']} {o['q']}", "expect": "需拍板后解锁",
           "actual": "阻塞：" + " ".join(o["blocks"]), "check": [], "found": [],
           "img": False, "verdict": "warn", "req": ""} for o in data["meta"]["open_questions"]]
    auto.append({"name": "❓ 待拍板（MD 提了但没定，一块反馈）", "children": [{"name": f"共 {len(oq)} 条", "children": oq}]})

    return {"tree": ck["tree"] + auto}


def main():
    if not SRC.exists():
        sys.exit("找不到 " + SRC)
    data = json.loads(SRC.read_text(encoding="utf-8"))
    data["meta"]["generated"] = datetime.now().strftime("%Y-%m-%d %H:%M")
    payload = json.dumps(data, ensure_ascii=False)
    assets = {"assets": []}
    apath = ROOT / "docs" / "assets.json"
    if apath.exists():
        assets = json.loads(apath.read_text(encoding="utf-8"))
    else:
        print("提示: 缺 docs/assets.json，先跑 python tools/gen_asset_gallery.py（素材库将为空）")
    checklist = build_checklist(data)
    html = (ROOT / "tools" / "panel_template.html").read_text(encoding="utf-8")
    html = (html.replace("/*__DATA__*/", payload)
                .replace("/*__ASSETS__*/", json.dumps(assets, ensure_ascii=False))
                .replace("/*__CHECKLIST__*/", json.dumps(checklist, ensure_ascii=False)))
    OUT_HTML.write_text(html, encoding="utf-8")
    # 不再写独立 md；需求文档统一维护在 docs/DESIGN.md（OUT_MD=None 时跳过）
    if OUT_MD is not None:
        OUT_MD.write_text(build_md(data), encoding="utf-8")
    n = sum(len(g["items"]) for c in data["categories"] for g in c["groups"])
    print("OK  docs/requirements.html")
    print(f"    类目 {len(data['categories'])} · 需求 {n} 条 · 待拍板 {len(data['meta']['open_questions'])}")


if __name__ == "__main__":
    main()

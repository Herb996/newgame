#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""解析 03_REQUIREMENTS.md，生成自包含可视化页面 docs/requirements.html。

用法:  python tools/gen_requirements_html.py
说明:  03_REQUIREMENTS.md 是唯一事实源；改完 md 重跑本脚本即可同步页面。
       产出的 HTML 不依赖任何外网资源，双击即可在浏览器打开。
"""
import json
import re
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "03_REQUIREMENTS.md"
OUT = ROOT / "docs" / "requirements.html"

# 状态 emoji -> 代码（⚠ 兼容不带变体选择符的写法）
STATUS_EMOJI = [
    ("✅", "done"),
    ("🔄", "doing"),
    ("⏳", "planned"),
    ("❓", "design"),
    ("⛔", "blocked"),
    ("⚠", "p0"),
    ("⏸", "paused"),
]

RID_RE = re.compile(r"R-[A-Z0-9]+-\d+[a-z]?")
SEC_RE = re.compile(r"^#\s+([一二三四五六])、")
MOD_RE = re.compile(r"^##\s+([A-Z][A-Z0-9 /]*)\s*·\s*(.+?)\s*$")
REQ_RE = re.compile(r"^\|\s*(R-[A-Z0-9]+-\d+[a-z]?)\s*\|")
PHASE_RE = re.compile(r"^\*\*(.+?)\*\*\s*$")
NUMITEM_RE = re.compile(r"^\d+\.\s+(.*)$")
OPENQ_RE = re.compile(r"^\|\s*(\d+)\s*\|(.+?)\|(.+?)\|\s*$")


def status_of(cell: str) -> str:
    cell = cell.strip()
    for emoji, code in STATUS_EMOJI:
        if cell.startswith(emoji):
            return code
    return "planned"


def md_inline(s: str) -> str:
    """极简 markdown 内联渲染（先转义再替换）。"""
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    return s


def parse(md: str):
    reqs = []
    open_questions = []
    phases = []
    drift = []
    section = None
    module = None
    cur_phase = None
    for ln in md.splitlines():
        m = SEC_RE.match(ln)
        if m:
            section = m.group(1)
            module = None
            cur_phase = None
            continue
        if section == "二":
            mm = MOD_RE.match(ln)
            if mm:
                module = (mm.group(1).strip(), mm.group(2).strip())
                continue
            if REQ_RE.match(ln):
                cells = [c.strip() for c in ln.strip().strip("|").split("|")]
                if len(cells) < 6:
                    continue
                rid, desc, st, pr, dep, src = cells[0], cells[1], cells[2], cells[3], cells[4], cells[5]
                deps = [d for d in RID_RE.findall(dep) if d != rid]
                openq = [int(n) for n in re.findall(r"待拍板\s*(\d+)", dep + " " + src)]
                reqs.append({
                    "id": rid,
                    "desc": desc,
                    "status": status_of(st),
                    "priority": "" if pr in ("—", "-", "") else pr,
                    "deps": deps,
                    "openq": openq,
                    "source": src,
                    "module": module[0] if module else "?",
                    "module_name": module[1] if module else "?",
                })
        elif section == "四":
            pm = PHASE_RE.match(ln)
            if pm:
                cur_phase = {"title": pm.group(1).strip(), "items": []}
                phases.append(cur_phase)
                continue
            nm = NUMITEM_RE.match(ln)
            if nm and cur_phase is not None:
                text = nm.group(1)
                cur_phase["items"].append({
                    "text": text,
                    "ids": RID_RE.findall(text),
                })
        elif section == "五":
            om = OPENQ_RE.match(ln)
            if om and om.group(1).isdigit():
                open_questions.append({
                    "no": int(om.group(1)),
                    "q": md_inline(om.group(2).strip()),
                    "blocks": RID_RE.findall(om.group(3)),
                    "blocks_text": om.group(3).strip(),
                })
        elif section == "六":
            dm = NUMITEM_RE.match(ln)
            if dm:
                drift.append(md_inline(dm.group(1)))
    return reqs, open_questions, phases, drift


def build_data(reqs, open_questions, phases, drift):
    ids = {r["id"] for r in reqs}
    edges = []
    for r in reqs:
        for d in r["deps"]:
            if d in ids:
                edges.append([d, r["id"]])  # 前置 -> 依赖方
    modules = []
    for r in reqs:
        if r["module"] not in [m["key"] for m in modules]:
            modules.append({"key": r["module"], "name": r["module_name"]})
    return {
        "reqs": reqs,
        "edges": edges,
        "modules": modules,
        "open_questions": open_questions,
        "phases": phases,
        "drift": drift,
        "generated": datetime.now().strftime("%Y-%m-%d %H:%M"),
    }


HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>Keep Quiet — 需求全景</title>
<style>
:root{
  --bg:#f4eee1; --panel:#fbf7ee; --ink:#2b2318; --sub:#7a6a52;
  --line:#d9cbae; --accent:#b06a2b; --accent2:#5b7f5e;
  --done:#2e9e5b; --doing:#3a7bd5; --planned:#d9a520; --design:#8e5bb5;
  --blocked:#d97b2e; --p0:#cc3333; --paused:#9aa0a6;
}
*{box-sizing:border-box}
body{margin:0;font-family:"Microsoft YaHei","PingFang SC",system-ui,sans-serif;
 background:var(--bg);color:var(--ink);font-size:14px}
header{position:sticky;top:0;z-index:20;background:linear-gradient(180deg,#3a2d1c,#2b2318);
 color:#f0e6d2;padding:10px 18px;display:flex;align-items:center;gap:14px;flex-wrap:wrap}
header h1{font-size:17px;margin:0;letter-spacing:1px}
header .gen{font-size:11px;color:#b9a87c;margin-left:auto}
nav{display:flex;gap:6px;flex-wrap:wrap}
nav button{background:transparent;border:1px solid #6b5836;color:#e8dcc0;
 padding:5px 14px;border-radius:16px;cursor:pointer;font-size:13px}
nav button.on{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:bold}
#qbox{background:#f0e6d2;border:none;border-radius:14px;padding:6px 12px;width:200px;outline:none}
main{padding:16px 18px;max-width:1400px;margin:0 auto}
section.view{display:none}
section.view.on{display:block}
.badge{display:inline-block;padding:1px 9px;border-radius:10px;color:#fff;font-size:12px;white-space:nowrap}
.b-done{background:var(--done)}.b-doing{background:var(--doing)}.b-planned{background:var(--planned)}
.b-design{background:var(--design)}.b-blocked{background:var(--blocked)}.b-p0{background:var(--p0)}
.b-paused{background:var(--paused)}
.prio{display:inline-block;padding:1px 7px;border-radius:4px;font-size:12px;border:1px solid}
.p-P0{color:var(--p0);border-color:var(--p0);font-weight:bold}
.p-P1{color:#b06a2b;border-color:#b06a2b}
.p-P2{color:#5b7f5e;border-color:#5b7f5e}
.p-P3{color:#8a8a8a;border-color:#8a8a8a}
.chip{display:inline-block;background:#efe4cb;border:1px solid var(--line);border-radius:10px;
 padding:0 8px;font-size:12px;cursor:pointer;color:var(--accent);margin:1px 2px}
.chip:hover{background:var(--accent);color:#fff}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 16px;
 margin-bottom:14px;box-shadow:0 1px 3px rgba(60,40,10,.06)}
h2.viewtitle{font-size:16px;margin:2px 0 12px;color:var(--accent)}
.statrow{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:14px}
.stat{flex:1;min-width:110px;background:var(--panel);border:1px solid var(--line);
 border-radius:10px;padding:10px 14px;text-align:center}
.stat .n{font-size:26px;font-weight:bold}
.stat .t{font-size:12px;color:var(--sub)}
.warn{background:#fdeaea;border:1px solid #e5b8b8;border-radius:10px;padding:10px 14px;margin-bottom:14px}
.warn b{color:var(--p0)}
.modbar{display:flex;align-items:center;gap:8px;margin:5px 0}
.modbar .mn{width:150px;font-size:12px;color:var(--sub);text-align:right;flex:none}
.modbar .bar{flex:1;height:16px;border-radius:8px;overflow:hidden;display:flex;background:#eadfc8}
.modbar .pct{width:44px;font-size:12px;flex:none}
.legend{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:10px;font-size:12px;align-items:center}
.legend span{cursor:pointer;padding:2px 8px;border-radius:10px;border:1px solid var(--line);user-select:none}
.legend span.off{opacity:.35}
table{width:100%;border-collapse:collapse;background:var(--panel);font-size:13px}
th,td{border-bottom:1px solid var(--line);padding:7px 9px;text-align:left;vertical-align:top}
th{background:#efe4cb;cursor:pointer;user-select:none;position:sticky;top:64px;z-index:5}
tr:hover td{background:#f6efdd}
td.dep{white-space:normal}
#graphwrap{position:relative;height:calc(100vh - 150px);min-height:480px;background:var(--panel);
 border:1px solid var(--line);border-radius:10px;overflow:hidden}
canvas{display:block;width:100%;height:100%;cursor:grab}
#gpanel{position:absolute;right:10px;top:10px;width:290px;max-height:calc(100% - 20px);overflow:auto;
 background:rgba(251,247,238,.97);border:1px solid var(--line);border-radius:10px;padding:12px;display:none}
#gpanel h3{margin:0 0 6px;font-size:14px;color:var(--accent)}
#gpanel .row{margin:4px 0;font-size:12px;color:var(--sub)}
#gtip{position:absolute;pointer-events:none;background:#2b2318;color:#f0e6d2;font-size:12px;
 padding:4px 8px;border-radius:6px;display:none;max-width:280px;z-index:9}
.gtools{position:absolute;left:10px;top:10px;display:flex;gap:6px}
.gtools button{background:#efe4cb;border:1px solid var(--line);border-radius:6px;padding:3px 10px;
 cursor:pointer;font-size:12px}
.phase{border-left:4px solid var(--accent);padding:2px 0 2px 14px;margin-bottom:18px}
.phase h3{margin:2px 0 8px;font-size:15px}
.pitem{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:7px 12px;
 margin:6px 0;font-size:13px}
.oq{background:var(--panel);border:1px solid var(--line);border-left:4px solid var(--design);
 border-radius:8px;padding:9px 13px;margin:8px 0}
.oq .no{font-weight:bold;color:var(--design);margin-right:8px}
.oq .bl{margin-top:4px;font-size:12px;color:var(--sub)}
code{background:#eadfc8;border-radius:4px;padding:0 5px;font-size:12px}
.foot{color:var(--sub);font-size:12px;text-align:center;margin:18px 0}
</style>
</head>
<body>
<header>
  <h1>⚙ Keep Quiet · 需求全景</h1>
  <nav id="nav"></nav>
  <input id="qbox" placeholder="搜索需求 / ID / 来源…">
  <span class="gen" id="gen"></span>
</header>
<main>
  <section class="view" id="v-overview">
    <h2 class="viewtitle">总览</h2>
    <div id="p0warn"></div>
    <div class="statrow" id="stats"></div>
    <div class="card"><h2 class="viewtitle">各模块完成率</h2><div id="modbars"></div></div>
    <div class="card"><h2 class="viewtitle">状态分布</h2><div id="donut" style="display:flex;gap:24px;align-items:center;flex-wrap:wrap"></div></div>
    <div class="card"><h2 class="viewtitle">文档-代码漂移（本页面生成时核实）</h2><ol id="drift" style="margin:0;padding-left:20px;line-height:1.9"></ol></div>
  </section>

  <section class="view" id="v-matrix">
    <h2 class="viewtitle">需求矩阵（点击表头排序 · 点击依赖 ID 跳转依赖图）</h2>
    <div class="legend" id="fstatus"></div>
    <div class="legend" id="fprio"></div>
    <div class="legend"><select id="fmodule" style="padding:3px 8px;border-radius:6px;border:1px solid var(--line)"></select>
      <span id="fcount" style="color:var(--sub)"></span></div>
    <div style="overflow:auto"><table id="mtab"></table></div>
  </section>

  <section class="view" id="v-graph">
    <h2 class="viewtitle">依赖关系图（拖拽移动 · 滚轮缩放 · 点击查看详情；箭头 = 前置 → 依赖方）</h2>
    <div id="graphwrap">
      <canvas id="gc"></canvas>
      <div class="gtools"><button id="gfit">复位视图</button><button id="gunpin">解除固定</button></div>
      <div class="legend" id="glegend" style="position:absolute;left:10px;bottom:10px;background:rgba(251,247,238,.9);padding:6px 10px;border-radius:8px;border:1px solid var(--line);margin:0"></div>
      <div id="gpanel"></div>
      <div id="gtip"></div>
    </div>
  </section>

  <section class="view" id="v-roadmap">
    <h2 class="viewtitle">建议执行路线</h2>
    <div id="phases"></div>
  </section>

  <section class="view" id="v-open">
    <h2 class="viewtitle">待拍板清单（点击阻塞项跳转）</h2>
    <div id="oqs"></div>
  </section>
</main>
<div class="foot">数据源：03_REQUIREMENTS.md（单一事实源）· 更新方式：改 md 后运行 <code>python tools/gen_requirements_html.py</code></div>

<script>
const DATA = /*__DATA__*/;
const SM = {
  done:{label:"已完成",c:"var(--done)",hex:"#2e9e5b"},
  doing:{label:"进行中",c:"var(--doing)",hex:"#3a7bd5"},
  planned:{label:"已拍板未做",c:"var(--planned)",hex:"#d9a520"},
  design:{label:"待设计",c:"var(--design)",hex:"#8e5bb5"},
  blocked:{label:"素材阻塞",c:"var(--blocked)",hex:"#d97b2e"},
  p0:{label:"P0阻塞",c:"var(--p0)",hex:"#cc3333"},
  paused:{label:"暂缓",c:"var(--paused)",hex:"#9aa0a6"}};
const RMAP = {}; DATA.reqs.forEach(r=>RMAP[r.id]=r);
const state = {status:new Set(), prio:new Set(), module:"", q:"", sel:null, sort:"id", asc:true};
function esc(s){return (s||"").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");}
function badge(r){return `<span class="badge b-${r.status}">${SM[r.status].label}</span>`;}
function prio(r){return r.priority?`<span class="p p-${r.priority}">${r.priority}</span>`:`<span class="p" style="color:#bbb">—</span>`;}
function depChips(ids){return ids.map(d=>`<span class="chip" data-goto="${d}">${d}</span>`).join("")||"<span style='color:#bbb'>—</span>";}
function matches(r){
  if(state.status.size && !state.status.has(r.status)) return false;
  if(state.prio.size && !state.prio.has(r.priority||"—")) return false;
  if(state.module && r.module!==state.module) return false;
  if(state.q){const q=state.q.toLowerCase();
    if(!(r.id+" "+r.desc+" "+r.source+" "+r.module+" "+r.module_name).toLowerCase().includes(q)) return false;}
  return true;}
function goGraph(id){ state.sel=id; showView("graph"); fitTo(id); }
document.addEventListener("click",e=>{const g=e.target.closest("[data-goto]");
  if(g){const id=g.dataset.goto; if(RMAP[id]) goGraph(id);}});

/* ---------- tabs ---------- */
const VIEWS=[["overview","总览"],["matrix","矩阵"],["graph","依赖图"],["roadmap","路线"],["open","待拍板"]];
const nav=document.getElementById("nav");
VIEWS.forEach(([k,t],i)=>{const b=document.createElement("button");b.textContent=t;b.dataset.v=k;
  if(i===0)b.classList.add("on");b.onclick=()=>showView(k);nav.appendChild(b);});
function showView(k){document.querySelectorAll("nav button").forEach(b=>b.classList.toggle("on",b.dataset.v===k));
  document.querySelectorAll("section.view").forEach(s=>s.classList.toggle("on",s.id==="v-"+k));
  if(k==="graph") resizeCanvas();}
function showView0(k){showView(k);}

/* ---------- overview ---------- */
function renderOverview(){
  const cnt={}; DATA.reqs.forEach(r=>cnt[r.status]=(cnt[r.status]||0)+1);
  const total=DATA.reqs.length, done=cnt.done||0;
  document.getElementById("stats").innerHTML=
    `<div class="stat"><div class="n">${total}</div><div class="t">需求总数</div></div>`+
    `<div class="stat"><div class="n" style="color:var(--done)">${done}</div><div class="t">已完成 (${Math.round(done/total*100)}%)</div></div>`+
    Object.keys(SM).filter(k=>k!=="done"&&cnt[k]).map(k=>
      `<div class="stat"><div class="n" style="color:${SM[k].hex}">${cnt[k]}</div><div class="t">${SM[k].label}</div></div>`).join("");
  const p0=DATA.reqs.filter(r=>r.status==="p0"||r.priority==="P0"&&r.status!=="done");
  document.getElementById("p0warn").innerHTML = p0.length?
    `<div class="warn"><b>⚠ P0 阻塞项</b>：`+p0.map(r=>`<span class="chip" data-goto="${r.id}">${r.id}</span> ${esc(r.desc)}`).join("　")+`</div>`:
    `<div class="warn" style="background:#eaf6ec;border-color:#bfe0c4"><b style="color:var(--done)">✓ 无 P0 阻塞项</b></div>`;
  const mods=DATA.modules.map(m=>{
    const rs=DATA.reqs.filter(r=>r.module===m.key);
    const d=rs.filter(r=>r.status==="done").length;
    return {m,rs,d,pct:Math.round(d/rs.length*100)};});
  document.getElementById("modbars").innerHTML=mods.map(x=>{
    const seg=Object.keys(SM).filter(k=>x.rs.some(r=>r.status===k)).map(k=>{
      const n=x.rs.filter(r=>r.status===k).length;
      return `<div style="width:${n/x.rs.length*100}%;background:${SM[k].hex}" title="${SM[k].label} ${n}"></div>`;}).join("");
    return `<div class="modbar"><div class="mn">${x.m.key} · ${x.m.name}</div><div class="bar">${seg}</div><div class="pct">${x.pct}%</div></div>`;}).join("");
  const order=Object.keys(SM).filter(k=>cnt[k]);
  let acc=0, circles=order.map(k=>{const frac=cnt[k]/total;const dash=`${frac*100.46} 100`;
    const off=-acc*100.46+25;acc+=frac;
    return `<circle r="15.915" cx="21" cy="21" fill="transparent" stroke="${SM[k].hex}" stroke-width="7" stroke-dasharray="${dash}" stroke-dashoffset="${off}"/>`;}).join("");
  document.getElementById("donut").innerHTML=
    `<svg width="150" height="150" viewBox="0 0 42 42">${circles}
     <text x="21" y="20.5" text-anchor="middle" font-size="6" font-weight="bold" fill="#2b2318">${Math.round(done/total*100)}%</text>
     <text x="21" y="26" text-anchor="middle" font-size="2.6" fill="#7a6a52">完成</text></svg>`+
    `<div>`+order.map(k=>`<div style="margin:3px 0"><span style="display:inline-block;width:10px;height:10px;border-radius:2px;background:${SM[k].hex};margin-right:6px"></span>${SM[k].label} <b>${cnt[k]}</b></div>`).join("")+`</div>`;
  document.getElementById("drift").innerHTML=DATA.drift.map(d=>`<li style="font-size:13px">${d}</li>`).join("");
}

/* ---------- matrix ---------- */
function renderFilters(){
  const cnt={}; DATA.reqs.forEach(r=>cnt[r.status]=(cnt[r.status]||0)+1);
  document.getElementById("fstatus").innerHTML=Object.keys(SM).map(k=>
    `<span data-s="${k}" class="${state.status.size&&!state.status.has(k)?"off":""}" style="background:${SM[k].hex};color:#fff;border:none">${SM[k].label} ${cnt[k]||0}</span>`).join("");
  document.getElementById("fprio").innerHTML="<b style='color:var(--sub);font-size:12px'>优先级:</b>"+
    ["P0","P1","P2","P3","—"].map(p=>{const n=DATA.reqs.filter(r=>(r.priority||"—")===p).length;
    return `<span data-p="${p}" class="${state.prio.size&&!state.prio.has(p)?"off":""}" style="background:${p==="—"?"#c9bda1":SM2[p]}">${p} ${n}</span>`;}).join("");
  const sel=document.getElementById("fmodule");
  if(!sel.options.length){sel.innerHTML=`<option value="">全部模块</option>`+DATA.modules.map(m=>`<option value="${m.key}">${m.key} · ${m.name}</option>`).join("");
    sel.onchange=()=>{state.module=sel.value;renderMatrix();};}
  sel.value=state.module;
  document.querySelectorAll("#fstatus span").forEach(s=>s.onclick=()=>{const k=s.dataset.s;
    state.status.has(k)?state.status.delete(k):state.status.add(k);renderMatrix();});
  document.querySelectorAll("#fprio span").forEach(s=>s.onclick=()=>{const k=s.dataset.p;
    state.prio.has(k)?state.prio.delete(k):state.prio.add(k);renderMatrix();});
}
const SM2={P0:"#cc3333",P1:"#b06a2b",P2:"#5b7f5e",P3:"#8a8a8a","—":"#c9bda1"};
function renderMatrix(){
  renderFilters();
  let rows=DATA.reqs.filter(matches);
  const key=state.sort;
  rows.sort((a,b)=>{let x=a[key],y=b[key];if(key==="status"){x=Object.keys(SM).indexOf(x);y=Object.keys(SM).indexOf(y);}
    if(x<y)return state.asc?-1:1;if(x>y)return state.asc?1:-1;return a.id<b.id?-1:1;});
  document.getElementById("fcount").textContent=`显示 ${rows.length} / ${DATA.reqs.length} 条`;
  const th=(k,t)=>`<th data-k="${k}">${t}${state.sort===k?(state.asc?" ▲":" ▼"):""}</th>`;
  document.getElementById("mtab").innerHTML=
    `<thead><tr>${th("id","ID")}${th("module","模块")}<th>需求</th>${th("status","状态")}${th("priority","优先级")}<th>依赖</th><th>来源</th></tr></thead><tbody>`+
    rows.map(r=>`<tr><td style="white-space:nowrap"><a href="#" data-goto="${r.id}" style="color:var(--accent);text-decoration:none;font-weight:bold">${r.id}</a></td>
      <td style="white-space:nowrap;color:var(--sub)">${r.module}</td><td>${esc(r.desc)}</td><td>${badge(r)}</td><td>${prio(r)}</td>
      <td class="dep">${depChips(r.deps)}</td><td style="color:var(--sub);font-size:12px">${esc(r.source)}</td></tr>`).join("")+`</tbody>`;
  document.querySelectorAll("#mtab th").forEach(h=>h.onclick=()=>{const k=h.dataset.k;if(!k)return;
    if(state.sort===k)state.asc=!state.asc;else{state.sort=k;state.asc=true;}renderMatrix();});
}

/* ---------- graph ---------- */
const cv=document.getElementById("gc"), ctx=cv.getContext("2d");
let W=800,H=600,dpr=1,view={k:1,x:0,y:0},alpha=1,nodes=[],nmap={},hover=null,drag=null,pan=null;
function initGraph(){
  nodes=DATA.reqs.map((r,i)=>({...r, x:0,y:0,vx:0,vy:0,fixed:false}));
  nodes.forEach(n=>nmap[n.id]=n);
  const mods=DATA.modules, anchor={};
  mods.forEach((m,i)=>{const a=i/mods.length*Math.PI*2-Math.PI/2;anchor[m.key]={x:Math.cos(a)*340,y:Math.sin(a)*340};});
  nodes.forEach(n=>{const a=anchor[n.module]||{x:0,y:0};n.x=a.x+(Math.random()-0.5)*120;n.y=a.y+(Math.random()-0.5)*120;});
  DATA.reqs.forEach(r=>{r.deg=0;});
  DATA.edges.forEach(([a,b])=>{if(nmap[a])nmap[a].deg++;if(nmap[b])nmap[b].deg++;});
  alpha=1;
  requestAnimationFrame(loop);
}
function resizeCanvas(){const r=cv.parentElement.getBoundingClientRect();dpr=window.devicePixelRatio||1;
  W=r.width;H=r.height;cv.width=W*dpr;cv.height=H*dpr;fitView();}
function fitView(){view.k=Math.min(W/900,H/900)*0.9;view.x=W/2;view.y=H/2;}
function fitTo(id){const n=nmap[id];view.k=1.1;view.x=W/2-n.x*view.k;view.y=H/2-n.y*view.k;state.sel=id;draw();showPanel();}
function sim(){
  if(alpha<0.003)return;
  for(let i=0;i<nodes.length;i++)for(let j=i+1;j<nodes.length;j++){
    const a=nodes[i],b=nodes[j];let dx=b.x-a.x,dy=b.y-a.y,d2=dx*dx+dy*dy;if(d2<1)d2=1;
    if(d2>90000)continue;const f=1400/d2*alpha;const d=Math.sqrt(d2);dx/=d;dy/=d;
    a.vx-=dx*f;a.vy-=dy*f;b.vx+=dx*f;b.vy+=dy*f;}
  DATA.edges.forEach(([ai,bi])=>{const a=nmap[ai],b=nmap[bi];if(!a||!b)return;
    let dx=b.x-a.x,dy=b.y-a.y,d=Math.sqrt(dx*dx+dy*dy)||1;const f=(d-95)*0.025*alpha;
    dx/=d;dy/=d;a.vx+=dx*f;a.vy+=dy*f;b.vx-=dx*f;b.vy-=dy*f;});
  nodes.forEach(n=>{n.vx+=-n.x*0.004*alpha;n.vy+=-n.y*0.004*alpha;
    if(!n.fixed){n.vx*=0.82;n.vy*=0.82;n.x+=n.vx;n.y+=n.vy;}else{n.vx=0;n.vy=0;}});
  alpha*=0.995;
}
function nodeR(n){return 7+Math.min(9,(n.deg||0)*1.6);}
function toWorld(px,py){return [(px-view.x)/view.k,(py-view.y)/view.k];}
function draw(){
  ctx.setTransform(dpr,0,0,dpr,0,0);ctx.clearRect(0,0,W,H);
  ctx.translate(view.x,view.y);ctx.scale(view.k,view.k);
  const sel=state.sel, conn=sel?new Set([sel]):null;
  if(sel){DATA.edges.forEach(([a,b])=>{if(a===sel||b===sel){conn.add(a);conn.add(b);}});}
  DATA.edges.forEach(([a,b])=>{const A=nmap[a],B=nmap[b];if(!A||!B)return;
    const dim=(A._dim&&B._dim)?false:(A._dim||B._dim);
    const hot=sel&&(a===sel||b===sel);
    ctx.strokeStyle=hot?"#b06a2b":(dim?"rgba(150,130,100,.08)":"rgba(150,130,100,.35)");
    ctx.lineWidth=hot?1.8:1;
    const ang=Math.atan2(B.y-A.y,B.x-A.x),rA=nodeR(A)+1,rB=nodeR(B)+4;
    const x1=A.x+Math.cos(ang)*rA,y1=A.y+Math.sin(ang)*rA,x2=B.x-Math.cos(ang)*rB,y2=B.y-Math.sin(ang)*rB;
    ctx.beginPath();ctx.moveTo(x1,y1);ctx.lineTo(x2,y2);ctx.stroke();
    ctx.beginPath();ctx.moveTo(x2,y2);
    ctx.lineTo(x2-Math.cos(ang-0.4)*7,y2-Math.sin(ang-0.4)*7);
    ctx.lineTo(x2-Math.cos(ang+0.4)*7,y2-Math.sin(ang+0.4)*7);
    ctx.fillStyle=ctx.strokeStyle;ctx.fill();});
  nodes.forEach(n=>{n._dim=!matches(n);
    const dim=n._dim&&!(conn&&conn.has(n.id));
    ctx.globalAlpha=dim?0.15:1;
    ctx.beginPath();ctx.arc(n.x,n.y,nodeR(n),0,7);
    ctx.fillStyle=SM[n.status].hex;ctx.fill();
    ctx.lineWidth=n.id===sel?3:1.2;ctx.strokeStyle=n.id===sel?"#2b2318":(n.fixed?"#b06a2b":"rgba(43,35,24,.35)");ctx.stroke();
    if(view.k>0.55||n.id===sel||n===hover){ctx.fillStyle=dim?"rgba(43,35,24,.2)":"#2b2318";
      ctx.font="bold 9px sans-serif";ctx.textAlign="center";
      ctx.fillText(n.id.replace(/^R-/,""),n.x,n.y+nodeR(n)+11);}});
  ctx.globalAlpha=1;
}
function loop(){sim();draw();requestAnimationFrame(loop);}
function pick(px,py){const [x,y]=toWorld(px,py);
  for(let i=nodes.length-1;i>=0;i--){const n=nodes[i],r=nodeR(n)+3;
    if((x-n.x)**2+(y-n.y)**2<r*r)return n;}return null;}
cv.addEventListener("mousedown",e=>{const n=pick(e.offsetX,e.offsetY);
  if(n){drag=n;n.fixed=true;alpha=Math.max(alpha,0.3);}else{pan=[e.clientX,e.clientY,view.x,view.y];cv.style.cursor="grabbing";}});
window.addEventListener("mousemove",e=>{
  if(drag){const r=cv.getBoundingClientRect();const [x,y]=toWorld(e.clientX-r.left,e.clientY-r.top);
    drag.x=x;drag.y=y;return;}
  if(pan){view.x=pan[2]+(e.clientX-pan[0]);view.y=pan[3]+(e.clientY-pan[1]);return;}});
window.addEventListener("mouseup",()=>{drag=null;pan=null;cv.style.cursor="grab";});
cv.addEventListener("wheel",e=>{e.preventDefault();
  const r=cv.getBoundingClientRect(),px=e.clientX-r.left,py=e.clientY-r.top;
  const [wx,wy]=toWorld(px,py);view.k*=e.deltaY<0?1.12:0.89;view.k=Math.max(0.25,Math.min(3,view.k));
  view.x=px-wx*view.k;view.y=py-wy*view.k;},{passive:false});
cv.addEventListener("click",e=>{const n=pick(e.offsetX,e.offsetY);state.sel=n?n.id:null;showPanel();draw();});
cv.addEventListener("mousemove",e=>{const n=pick(e.offsetX,e.offsetY);hover=n;
  const t=document.getElementById("gtip");
  if(n){t.style.display="block";t.style.left=(e.offsetX+14)+"px";t.style.top=(e.offsetY+8)+"px";
    t.textContent=`${n.id} [${SM[n.status].label}${n.priority?" "+n.priority:""}] ${n.desc}`;}
  else t.style.display="none";});
function showPanel(){const p=document.getElementById("gpanel");
  if(!state.sel){p.style.display="none";return;}
  const r=RMAP[state.sel];const up=r.deps.map(d=>`<span class="chip" data-goto="${d}">${d}</span>`).join(" ")||"—";
  const down=DATA.reqs.filter(x=>x.deps.includes(r.id)).map(x=>`<span class="chip" data-goto="${x.id}">${x.id}</span>`).join(" ")||"—";
  const oq=r.openq.map(n=>`<span class="chip" data-v="open">#${n}</span>`).join(" ")||"";
  p.style.display="block";
  p.innerHTML=`<h3>${r.id}</h3><div>${esc(r.desc)}</div>
   <div class="row">${badge(r)} ${prio(r)} <span style="margin-left:6px">${r.module} · ${r.module_name}</span></div>
   <div class="row"><b>前置依赖：</b>${up}</div><div class="row"><b>被依赖：</b>${down}</div>
   ${oq?`<div class="row"><b>关联待拍板：</b>${oq}</div>`:""}
   <div class="row">${esc(r.source)}</div>`;}
document.getElementById("gfit").onclick=fitView;
document.getElementById("gunpin").onclick=()=>{nodes.forEach(n=>n.fixed=false);alpha=0.6;};
document.getElementById("glegend").innerHTML=Object.keys(SM).map(k=>
  `<span style="color:${SM[k].hex};border-color:${SM[k].hex};cursor:default">● ${SM[k].label}</span>`).join("");

/* ---------- roadmap / open ---------- */
function renderRoadmap(){
  document.getElementById("phases").innerHTML=DATA.phases.map((ph,i)=>
    `<div class="phase"><h3>${["🧹","🔧","🎨","🚀"][i]||"▸"} ${esc(ph.title)}</h3>`+
    ph.items.map(it=>`<div class="pitem">${it.ids.length?it.ids.map(d=>`<span class="chip" data-goto="${d}">${d}</span>`).join(" "):""} ${esc(it.text.replace(/R-[A-Z0-9]+-\d+[a-z]?\s*/g,""))}</div>`).join("")+
    `</div>`).join("");
}
function renderOpen(){
  document.getElementById("oqs").innerHTML=DATA.open_questions.map(o=>
    `<div class="oq"><span class="no">#${o.no}</span>${o.q}
     <div class="bl">阻塞：${o.blocks.length?o.blocks.map(b=>`<span class="chip" data-goto="${b}">${b}</span>`).join(" "):esc(o.blocks_text)}</div></div>`).join("");
}

/* ---------- search ---------- */
document.getElementById("qbox").addEventListener("input",e=>{state.q=e.target.value.trim();
  renderMatrix();if(document.getElementById("v-graph").classList.contains("on"))draw();});
document.getElementById("gen").textContent="生成于 "+DATA.generated;

renderOverview();renderMatrix();initGraph();renderRoadmap();renderOpen();
showView0("overview");
</script>
</body>
</html>
"""


def main():
    if not SRC.exists():
        sys.exit("找不到 " + str(SRC))
    reqs, oqs, phases, drift = parse(SRC.read_text(encoding="utf-8"))
    if not reqs:
        sys.exit("未解析到任何需求行，请检查 03_REQUIREMENTS.md 矩阵格式")
    data = build_data(reqs, oqs, phases, drift)
    html = HTML.replace("/*__DATA__*/", json.dumps(data, ensure_ascii=False))
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(html, encoding="utf-8")
    print("OK  %s" % OUT)
    print("    需求 %d 条 · 依赖边 %d · 待拍板 %d · 路线 %d 阶段"
          % (len(data["reqs"]), len(data["edges"]), len(data["open_questions"]), len(data["phases"])))


if __name__ == "__main__":
    main()

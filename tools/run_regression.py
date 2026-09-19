# -*- coding: utf-8 -*-
"""一次性跑完全部回归探针并打印关键结论。

为什么写成脚本而不是一串 shell 命令：本项目所在环境的 bash shim 时好时坏
（管道/引号/退出码都可能失真），用 Python 起子进程最稳，也能一次性把
多份日志汇总成一张表。

用法：
    python tools/run_regression.py            # 全部探针 + flow_test
    python tools/run_regression.py --no-flow  # 只跑探针，不动 Data/config.json

--no-flow 存在的理由：flow_test 要临时把 config.json 里的 flow_test 改成 true
再改回来。中途别的会话要是写了这个文件，收尾那次"还原"会把人家的改动一起抹掉。
只要探针结果时就加它。
"""
import io
import json
import os
import subprocess
import sys

GODOT = r"C:/Users/Administrator/Downloads/Godot_v4.7.2-stable_win64_console.exe"
PROJ = "D:/SteamPunkExtraction"
OUT = "C:/Users/Administrator/WorkBuddy/2026-09-14-22-35-14"

# (场景, 日志名, 需要打印的关键前缀)
SUITES = [
    ("Dev/probe_registry.tscn", "_r_registry.log", ("[Probe]",)),
    ("Dev/probe_player_anim.tscn", "_r_anim.log", ("[ProbeAnim]",)),
    ("Dev/probe_zoom.tscn", "_r_zoom.log", ("[ZoomProbe]",)),
    ("Dev/probe_terrain_map.tscn", "_r_terrain.log", ("[TerrainProbe]", "[Map]")),
    ("Dev/probe_level.tscn", "_r_level.log", ("[probe_level]",)),
    ("Dev/probe_supplies.tscn", "_r_supplies.log", ("[probe_supplies]",)),
    ("Dev/probe_inventory.tscn", "_r_inventory.log", ("[probe_inventory]",)),
    ("Dev/probe_click_move.tscn", "_r_clickmove.log", ("[probe_click_move]",)),
    ("Dev/probe_dead_body.tscn", "_r_deadbody.log", ("[probe_dead_body]",)),
    ("Dev/probe_hit_feedback.tscn", "_r_hitfb.log", ("[HitFbProbe]",)),
    ("Dev/probe_collision_separation.tscn", "_r_sep.log", ("[SepProbe]",)),
    ("Dev/probe_move_giveup.tscn", "_r_giveup.log", ("[GiveupProbe]",)),
    ("Dev/probe_second_launch.tscn", "_r_launch2.log", ("[probe_second_launch]",)),
    ("Dev/probe_water_step.tscn", "_r_water.log", ("[WaterProbe]", "[Weather]")),
    # 2026-09-19 两条新规的守卫：主菜单悬停不许有介绍、脚步采样不许循环。
    # probe_step_audio 的 B 段（真播会自己停）要 --window，无头里会自己跳过并写明，
    # 不会假绿；A/C 段（循环标志 + 调用点）无头就能量。
    ("Dev/probe_menu_hover.tscn", "_r_menuhover.log", ("[probe_menu_hover]",)),
    ("Dev/probe_step_audio.tscn", "_r_stepaudio.log", ("[probe_step_audio]",)),
    # 2026-09-19「敌人不会攻击」那条 bug 的守卫：出手改成按射程判定，探针实算
    # 「射程 > 分离层最小间距」这条几何不等式，另盯冷却/前摇/挥空/挡下仍出手/掉落/死亡画面。
    ("Dev/probe_enemy_attack.tscn", "_r_enemylk.log", ("[EnemyAttackProbe]",)),
]

BAD_MARKS = ("SCRIPT ERROR", "Parse Error", "Invalid call", "Invalid access",
             "Attempt to call", "Node not found", "Failed to load")

# 单套探针的墙钟上限（秒）。必须有：探针是 Godot 进程，正常收尾会自己 quit()；
# 一旦脚本中途报错就没机会退出，subprocess.run 会永远等下去 —— 上一轮回归就是这么
# 卡死、三份日志互相覆盖的（根因见 Dev/probe_terrain_map.gd 的装饰 kind 写死 1~5）。
TIMEOUT = 900


def run(scene, logname, prefixes):
    log = os.path.join(OUT, logname)
    timed_out = False
    with io.open(log, "wb") as f:
        try:
            p = subprocess.run([GODOT, "--headless", "--path", PROJ, scene],
                               stdout=f, stderr=subprocess.STDOUT, timeout=TIMEOUT)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            timed_out = True
            rc = -1
    text = io.open(log, encoding="utf-8", errors="replace").read()
    print("=" * 78)
    print("%s   EXIT=%d%s" % (scene, rc, "   <<< 超时 %ds，进程已杀（探针没走到 quit()）"
                             % TIMEOUT if timed_out else ""))
    bad = 0
    if timed_out:
        bad += 1
    for line in text.splitlines():
        st = line.strip()
        if any(m in st for m in BAD_MARKS):
            print("   !! %s" % st[:170])
            bad += 1
        if st.startswith(prefixes):
            print("   %s" % st[:180])
    print("   异常行: %d" % bad)
    if rc != 0:
        print("   <<< 退出码 %d（探针自己的断言没全过；回归以退出码为准）" % rc)
        bad += 1
    return rc, bad


def flow_test():
    """主流程自检：需要临时打开 debug.flow_test，跑完还原。"""
    cfg = os.path.join(PROJ, "Data/config.json")
    # 本项目 config.json 带 UTF-8 BOM：读写都必须 utf-8-sig，否则 json.loads 报
    # "Unexpected UTF-8 BOM"，且写回时用 utf-8 会把 BOM 抹掉。
    s = io.open(cfg, encoding="utf-8-sig", newline="").read()
    if '"flow_test": false' not in s:
        print("!! config 里找不到 flow_test，跳过")
        return
    io.open(cfg, "w", encoding="utf-8-sig", newline="").write(
        s.replace('"flow_test": false', '"flow_test": true'))
    json.loads(io.open(cfg, encoding="utf-8-sig").read())
    try:
        log = os.path.join(OUT, "_r_flow.log")
        with io.open(log, "wb") as f:
            try:
                p = subprocess.run([GODOT, "--headless", "--path", PROJ],
                                   stdout=f, stderr=subprocess.STDOUT, timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                p = None
        text = io.open(log, encoding="utf-8", errors="replace").read()
        print("=" * 78)
        print("flow_test (3D 主流程)   EXIT=%s" % (str(p.returncode) if p else "超时"))
        bad = 0
        for line in text.splitlines():
            st = line.strip()
            if any(m in st for m in BAD_MARKS):
                print("   !! %s" % st[:170])
                bad += 1
            if st.startswith("[FlowTest]") and ("结束" in st or "!!" in st):
                print("   %s" % st[:180])
        print("   异常行: %d" % bad)
    finally:
        s2 = io.open(cfg, encoding="utf-8-sig", newline="").read()
        io.open(cfg, "w", encoding="utf-8-sig", newline="").write(
            s2.replace('"flow_test": true', '"flow_test": false'))
        print("   (flow_test 已还原为 false)")


if __name__ == "__main__":
    if not os.path.exists(GODOT):
        sys.exit("找不到 Godot: " + GODOT)
    total_bad = 0
    for scene, logname, prefixes in SUITES:
        rc, bad = run(scene, logname, prefixes)
        total_bad += bad
    if "--no-flow" in sys.argv:
        print("=" * 78)
        print("flow_test 已跳过（--no-flow）：Data/config.json 一个字节没动")
    else:
        flow_test()
    print("=" * 78)
    print("全部异常行合计: %d" % total_bad)

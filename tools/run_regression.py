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

# Windows 控制台默认 GBK：探针状态行里只要有一个 ⇒（U+21D2）这类编不出的字符，
# print() 就抛 UnicodeEncodeError，整轮回归跑到一半就断。改成替换而不是报错，
# 中文照常显示，个别符号变成问号——总比没有结果强。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(errors="replace")
    except Exception:
        pass

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
    # 2026-09-19 群系边界混合层：它是纯外观层，所以守卫的是「不许影响玩法」——
    # 同一颗种子开/关两次，terrain/walls/biome/decor 四张网格必须逐格相同，
    # 关掉后树里不许留节点；另查网点覆盖率确实按 lv/8 量化、混合格只长在边界上。
    ("Dev/probe_biome_blend.tscn", "_r_blend.log", ("[BlendProbe]",)),
    # 2026-09-20 群系边界描边（取代渐变混合层的现役方案）：把 blob 的"同类"判定从
    # 「邻格可走」收紧成「邻格可走且同群系」，于是群系交界自动描出官方自带的海岸线。
    # 守卫：关闭时接缝格 100% 拿到无描边内部块 k=5（这条就是当初"看不出区别"的真根因）、
    # 开启时 100% 变成有边且只加不减、terrain/walls/biome/decor/speed_mult 逐格不动、
    # stroke=light/dark 只换图集像素不换 blob 下标、非法 stroke 回退并警告。
    ("Dev/probe_biome_outline.tscn", "_r_outline.log", ("[OutlineProbe]",)),
    # 2026-09-19 敌人朝向：素材是「单侧画 + 8 方向复用同一批帧」，所以「向左」只能靠
    # Sprite2D.flip_h 镜像。守卫三件事：① 玩家枪兵的真 8 方向素材不许被镜像（默认关）；
    # ② 素材本身朝左的两只鲨鱼要反着判（一刀切 dir.x<0 就翻）；③ 受击压扁走
    # animator 的 scale_mul 通道，不再和每物理帧重写 _sprite.scale 的代码抢方向盘。
    ("Dev/probe_enemy_facing.tscn", "_r_facing.log", ("[EnemyFacingProbe]",)),
    # 2026-09-20 右键背包弹窗右侧的「建造」按钮：只发信号不接玩法。守卫的是一条
    # 很容易踩的输入顺序坑 —— Node._input 跑在 Control 的 GUI 分发之前，弹窗原先把
    # 面板内的点击全吞了，那样按钮永远点不着。所以既量位置（在明细列右侧、没被拉高、
    # 不越出视口），也量放行（点按钮不 set_input_as_handled、点背包照旧吞）。
    ("Dev/probe_build_button.tscn", "_r_buildbtn.log", ("[BuildButtonProbe]",)),
    # 2026-09-20 配置驱动的特效管线（fx.effects 库 + 三个引用点）。守的重点不是"好不好看"
    # 而是**表与素材必须自洽**：每条 fx.effects 的贴图宽度要 == frames×128，改了帧数没重切
    # 图，hframes 会把半格当一帧画；再加生成器语义（additive 挂 CanvasItemMaterial 的 ADD、
    # 播完自毁、fx.max_simultaneous 硬上限、空/未知 id 与总开关关掉一律不生成）和引用回落
    # （武器 fx_attack → 无；命中回落 combat.attack.fx_hit；兵种专属 → enemy.attack.fx_attack）。
    ("Dev/probe_fx.tscn", "_r_fx.log", ("[FxProbe]",)),
    # 2026-09-20 局内数值调试栏（F9）：它直接写 Config 的运行时覆盖层，所以守的是
    # 「改完必须能原样还回去」—— 覆盖层清空后敌人兵种表逐键回出厂值、在场单位数值
    # 跟着重算、出厂层与 user://settings.json 一个字节都不许被写脏、
    # clear_override 剪空壳字典（否则「已改 N 项」虚报）。S9 窗口实拍段无头会自己跳过。
    ("Dev/probe_stat_panel.tscn", "_r_statpanel.log", ("[Probe]",)),
    # 2026-09-20 伤害管线接通（暴击 / 浮动 / 减防不再是纸面蓝图）。守四件事：
    # ① 出厂 crit_chance=0、variance=0 时三条玩家路径（近战真实 Area2D 重叠 / 弹道出膛
    #    结算 / 瞬狙穿透）与敌人 roll 逐位等于接通前的值 —— 接线不许偷偷改平衡；
    # ② crit_chance=1 时三条路径真的各吃到 ×倍率，且一次挥击多个目标各抽一次；
    # ③ 回落链：武器表写 crit_chance/variance 盖过 combat.attack（按武器配是纯配置活）；
    # ④ 边界：玩家防御仍在 take_damage 里扣、敌人结算值与玩家防多少和距离无关
    #    （搬到攻击侧就会出现"要扣血才决定砍不砍"的倒置）。
    # 期望值一律由**生效配置**现算，所以 user://settings.json 里调过剑/弓伤害也不会假红。
    ("Dev/probe_damage_pipeline.tscn", "_r_dmgpipe.log", ("[DmgProbe]",)),
    # 2026-09-21 技能系统（skills.json + UnitStatus + SkillSystem + 魔法书）。守两件最容易
    # 悄悄烂掉的事：① 表必须自洽 —— 技能引用的 fx_cast/fx_hit/五行/状态 id 写错、热键撞号、
    #    槽数与技能数不符，在运行时全是"静默不放技能"，实拍看不出来；
    # ② 「局内学、撤离才永久」这条持久规矩 —— 阵亡不写档、这局没学不能清空名册已有技能、
    #    死 id 与越界等级在读档清洗时被剪掉、存盘读档一轮不变。
    # 中间三段（状态容器 / 学习成长 / 进局释放）顺带把冻结连冻免疫、灼烧按 tick 跳血、
    # 溅射传状态、护盾"先乘盾再扣防御"、skills.enabled=false 零释放这些行为钉住。
    ("Dev/probe_skills.tscn", "_r_skills.log", ("[probe_skills]",)),
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

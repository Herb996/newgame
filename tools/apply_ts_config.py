#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""apply_ts_config.py — 把 Data/config.json 切到 Tiny Swords 的 64px 网格。

【为什么用脚本改而不是手改】
1. 原工程所有手感数值（速度/攻击范围/拾取半径）都是**像素**单位，是按
   tile_size = 16 定的。切到 64px 后，凡是"像素"数值必须等比 ×4，
   否则玩家会在一个放大 4 倍的世界里以原来的像素速度爬行、
   打不到 1/4 屏外的敌人。逐条手改容易漏，脚本里一张表列全、可复核。
2. 单位序列帧路径按目录实际文件生成，避免手写 72 条路径写错一个字母。
3. 脚本可重复执行（幂等），配置被改乱时重跑一次即可回到已知状态。

【判据】配置项属于"像素"还是"格"？
  · 名字带 _px / speed / radius（不带 _cells）→ 像素 → ×4
  · 名字带 _cells / frequency / weight / count / seconds → 与格数或时间有关 → 不动
  · trigger_radius 例外：它写成不带 _cells，实际喂给 CollisionShape2D.radius → 像素 → ×4

用法：
    python tools/apply_ts_config.py
"""
from __future__ import annotations

import json
import os
import shutil

PROJ = r"D:\SteamPunkExtraction"
CFG = os.path.join(PROJ, "Data", "config.json")
UNITS = os.path.join(PROJ, "Assets", "Art", "Sprites", "Units")

PX_SCALE = 4.0   # 16px 网格 → 64px 网格

# (配置路径, 原值) —— 只用于打印对照，实际值从文件里读出来乘
PX_KEYS = [
    "player.speed",
    "player.select_radius_px",
    "camera.pan_speed",
    "combat.player.knockback_speed",
    "combat.attack.range_px",
    "combat.skills.steam_burst.radius_px",
    "combat.skills.steam_burst.knockback_speed",
    "combat.skills.grapple_dash.dash_speed",
    "combat.skills.grapple_dash.hit_radius_px",
    "enemy.speed",
    "enemy.knockback_px",
    "loot.pickup_radius_px",
    "extraction.trigger_radius",
]


def frames(unit_dir: str, anim: str) -> list:
    """列出某个单位动画的全部帧（按文件名排序 → 帧序正确）。"""
    d = os.path.join(UNITS, unit_dir)
    if not os.path.isdir(d):
        return []
    fs = sorted(f for f in os.listdir(d)
                if f.startswith(anim + "_") and f.lower().endswith(".png"))
    return ["res://Assets/Art/Sprites/Units/%s/%s" % (unit_dir, f) for f in fs]


def get(d: dict, path: str):
    cur = d
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def setv(d: dict, path: str, value) -> None:
    parts = path.split(".")
    cur = d
    for part in parts[:-1]:
        if part not in cur or not isinstance(cur[part], dict):
            cur[part] = {}
        cur = cur[part]
    cur[parts[-1]] = value


def main() -> int:
    with open(CFG, encoding="utf-8") as f:
        cfg = json.load(f)
    bak = CFG + ".bak_pre_ts"
    if not os.path.exists(bak):
        shutil.copy2(CFG, bak)
        print("原配置已备份 ->", os.path.basename(bak))

    m = cfg["map"]
    log = []

    # ---------- 1. 网格尺寸 ----------
    log.append("map.tile_size: %s -> 64" % m.get("tile_size"))
    m["tile_size"] = 64
    # width/height 保持 128：格数不变 → 群系/河道/裂缝的空间结构完全不变，
    # 只有"一格占多少像素"变了（世界 2048px → 8192px，同时官方 64px 美术 1:1 呈现）。
    log.append("map.width/height 保持 %sx%s（格数不变）" % (m.get("width"), m.get("height")))

    # ---------- 2. 群系：指定官方地形图集 + 重排装饰密度 ----------
    # 官方 5 套配色的实际地貌（见 tools/analyze_ts_blob.py 与素材目视）：
    #   color1 明亮草地 / color2 冷绿草 / color3 深林青绿 / color4 枯黄草原 / color5 海岸蓝绿
    # 本作 4 个群系各挑一套；雪原在免费包里没有对应素材（见缺失清单），
    # 改用 color5 并改名为"沼泽"——蓝绿湿地 + speed 0.62 的减速语义依然成立。
    # 装饰密度按"64px 一格、屏幕只显示约 30x17 格"重算：
    #   树原画 192x256 ≈ 3x4 格，要铺出"林子"的观感，森林里树格占比需 ≈8%。
    biome_patch = [
        {"name": "草地", "tileset": "tilemap_color1.png",
         "tint": [1.00, 1.00, 1.00],
         "tree": 0.015, "rock": 0.006, "bush": 0.030, "pebble": 0.005},
        {"name": "荒原", "tileset": "tilemap_color4.png",
         "tint": [1.02, 0.98, 0.94],
         "tree": 0.008, "rock": 0.050, "bush": 0.008, "pebble": 0.030},
        {"name": "森林", "tileset": "tilemap_color3.png",
         "tint": [0.94, 1.00, 0.96],
         "tree": 0.080, "rock": 0.006, "bush": 0.060, "pebble": 0.006},
        {"name": "沼泽", "tileset": "tilemap_color5.png",
         "tint": [0.95, 1.00, 1.02], "speed": 0.62,
         "tree": 0.025, "rock": 0.012, "bush": 0.050, "pebble": 0.040},
    ]
    biomes = m["biomes"]
    for b, patch in zip(biomes, biome_patch):
        name_old = b.get("name")
        b.update(patch)
        # 旧的程序化残留字段（3D 线的贴图名），2D 线不再使用，删掉免得误导
        for dead in ("floor_src", "ground_3d", "ground_tune", "crack"):
            b.pop(dead, None)
        log.append("biome %s -> %s / %s （tree %.3f rock %.3f bush %.3f pebble %.3f）"
                   % (name_old, b["name"], b["tileset"], b["tree"], b["rock"],
                      b["bush"], b["pebble"]))

    # ---------- 3. 调色分级关闭 / 宏观明暗减弱 ----------
    m.setdefault("grade", {})
    m["grade"] = {"enabled": False, "contrast": 1.12, "brightness": 0.0,
                  "saturation": 0.92}
    log.append("map.grade.enabled = false（官方素材已是成品配色，不再二次调色）")
    m.setdefault("macro_light", {})
    m["macro_light"]["strength"] = 0.10
    log.append("map.macro_light.strength = 0.10（世界变大后明暗块跟着变大，减弱一档）")

    # ---------- 4. 像素数值 ×4 ----------
    for key in PX_KEYS:
        v = get(cfg, key)
        if v is None:
            log.append("!! 缺配置项，跳过：%s" % key)
            continue
        setv(cfg, key, round(float(v) * PX_SCALE, 3))
        log.append("%-46s %8.2f -> %8.2f" % (key, float(v), float(v) * PX_SCALE))

    # ---------- 5. 玩家精灵集：Tiny Swords Warrior ----------
    cfg["player"]["sprite_set"] = "sprites_ts"
    cfg["player"]["sprite_scale"] = 1.0
    # 官方帧 192x192，角色脚底在帧内 y=137（实测包围盒），帧中心 96
    # → 脚底与节点对齐需要 offset.y = (96 - 137) * scale = -41
    cfg["player"]["sprite_offset_y"] = -41.0
    cfg["player"]["sprite_pixel_unit"] = 6.0
    log.append("player.sprite_set = sprites_ts（Warrior，192px 帧，scale 1.0，offset_y -41）")

    cfg["sprites_ts"] = {
        "_comment": "Tiny Swords Warrior（Blue 阵营）。官方单位是正面朝向的单向序列帧，"
                    "四个方向共用同一套帧（素材本身就是正视视角，左右翻转反而别扭）。"
                    "数组形式 = 四向共用，见 player_animator.gd 的 parse_spec。",
        "fps": {"idle": 8, "walk": 12, "attack": 12, "dodge": 16, "hit": 12, "dead": 8},
        "idle": frames("blue_warrior", "idle"),        # 8 帧
        "walk": frames("blue_warrior", "run"),         # 6 帧
        "attack": frames("blue_warrior", "attack1"),   # 4 帧
        "dodge": frames("blue_warrior", "attack2"),    # 4 帧（旋转挥砍，读起来像翻滚突进）
        "hit": frames("blue_warrior", "guard"),        # 6 帧（举盾，正好当受击姿态）
        "dead": [],                                    # 官方免费包**没有死亡动画** → 程序化倾倒
    }
    log.append("sprites_ts：idle %d / walk %d / attack %d / dodge %d / hit %d / dead %d 帧"
               % (len(cfg["sprites_ts"]["idle"]), len(cfg["sprites_ts"]["walk"]),
                  len(cfg["sprites_ts"]["attack"]), len(cfg["sprites_ts"]["dodge"]),
                  len(cfg["sprites_ts"]["hit"]), len(cfg["sprites_ts"]["dead"])))

    # ---------- 6. 敌人精灵：4 个兵种（不同阵营/兵种 = 不同强度） ----------
    cfg["enemy_types"] = {
        "_comment": "Tiny Swords 免费包没有「怪物」，但有 5 个阵营 × 4 个兵种的完整单位。"
                    "这里挑 4 个敌方阵营单位当敌人：强度递进，贴图/动画各不相同。"
                    "官方包**没有受击/死亡动画**，受击靠染色、死亡靠淡出（见 enemy.gd）。",
        "scale": 1.0,
        "offset_y": -40.0,     # 192x192 帧，脚底 y≈136
        "pixel_unit": 6.0,
        "types": [
            {"id": "brigand", "name": "劫掠者", "faction": "red", "unit": "pawn",
             "weight": 4, "hp": 40, "damage": 10, "speed_mult": 1.00,
             "fps": {"idle": 8, "walk": 10, "attack": 12},
             "idle": frames("red_pawn", "idle"),
             "walk": frames("red_pawn", "run"),
             "attack": frames("red_pawn", "attack1")},
            {"id": "raider", "name": "弓手", "faction": "red", "unit": "archer",
             "weight": 3, "hp": 30, "damage": 8, "speed_mult": 1.15,
             "fps": {"idle": 6, "walk": 12, "attack": 14},
             "idle": frames("red_archer", "idle"),
             "walk": frames("red_archer", "run"),
             "attack": frames("red_archer", "attack1")},
            {"id": "cultist", "name": "邪术师", "faction": "red", "unit": "monk",
             "weight": 2, "hp": 55, "damage": 14, "speed_mult": 0.85,
             "fps": {"idle": 6, "walk": 8, "attack": 14},
             "idle": frames("red_monk", "idle"),
             "walk": frames("red_monk", "run"),
             "attack": frames("red_monk", "attack1")},
            {"id": "marauder", "name": "掠夺者", "faction": "yellow", "unit": "pawn",
             "weight": 2, "hp": 70, "damage": 16, "speed_mult": 1.00,
             "fps": {"idle": 8, "walk": 10, "attack": 12},
             "idle": frames("yellow_pawn", "idle"),
             "walk": frames("yellow_pawn", "run"),
             "attack": frames("yellow_pawn", "attack1")},
        ],
    }
    for t in cfg["enemy_types"]["types"]:
        log.append("enemy type %-9s %-4s idle %d / walk %d / attack %d 帧"
                   % (t["id"], t["unit"], len(t["idle"]), len(t["walk"]), len(t["attack"])))

    # ---------- 7. 中立动物（羊）：让地图"活"起来 ----------
    cfg["animal_types"] = {
        "_comment": "官方包里的羊（吃草/待机/走动三套动画）。做成中立生物：地图上游荡，"
                    "玩家靠近就跑，被打死掉落食物。",
        "scale": 1.0,
        "offset_y": -20.0,     # 128x128 帧，脚底 y≈84
        "pixel_unit": 4.0,
        "types": [
            {"id": "sheep", "name": "野羊", "weight": 1, "hp": 12,
             "fps": {"idle": 6, "walk": 9, "grass": 5},
             "idle": frames("sheep", "idle"),
             "walk": frames("sheep", "run"),
             "extra": frames("sheep", "grass")},
        ],
    }
    cfg["animals"] = {
        "count": 60,
        "min_distance_from_player_cells": 10,
        "wander_radius_cells": 10,
        "flee_radius_cells": 6,
        "speed": 240.0,
        "drop": {"chance": 0.9, "res": "food", "amount_min": 1, "amount_max": 3},
    }
    log.append("animal_types/animals：羊 x%d（游荡 + 逃跑 + 掉食物）" % cfg["animals"]["count"])

    # ---------- 8. 资源点道具图标 ----------
    item_map = {
        "wood": "item_wood.png",
        "stone": "item_stone.png",
        "iron": "item_iron.png",
        "gold": "item_gold.png",
        "oil": "item_oil.png",
        "food": "item_food.png",
    }
    for rid, fname in item_map.items():
        if rid not in cfg["resources"]:
            continue
        cfg["resources"][rid]["sprite"] = "res://Assets/Art/Sprites/Items/" + fname
    cfg.setdefault("loot", {})
    cfg["loot"]["icon_px"] = 44          # 所有道具统一按 44px 高显示（原画尺寸不一，统一才整齐）
    cfg["loot"]["ring_radius_px"] = 26   # 脚下的资源点光圈
    log.append("resources[*].sprite 已指向 Assets/Art/Sprites/Items/，loot.icon_px = 44")

    # ---------- 9. 基地建筑贴图 ----------
    bld_map = {"warehouse": "house_large.png", "statue": "monastery.png",
               "gate": "castle.png"}
    for b in cfg["base"]["buildings"]:
        b["sprite"] = "res://Assets/Art/Sprites/Buildings/" + bld_map.get(
            b["id"], "house_small.png")
        log.append("building %-10s -> %s" % (b["id"], bld_map.get(b["id"], "house_small.png")))

    # ---------- 10. 调试：预览改成整图缩略 ----------
    cfg["debug"]["map_preview_cells"] = int(m["width"])
    cfg["debug"]["map_preview_scale"] = 0.125   # 8192px 世界 → 1024px 缩略图
    log.append("debug.map_preview_cells = %d, map_preview_scale = 0.125（整图 1024px 缩略）"
               % cfg["debug"]["map_preview_cells"])

    with open(CFG, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print("\n".join(log))
    print("\n已写回", CFG)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

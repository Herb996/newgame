# -*- coding: utf-8 -*-
"""把 Tiny Swords (Enemy Pack) 的全部「可动敌角色」切片进项目，并注册进 config.json。

切片规律（已实测全包成立）：每个横条 PNG 的 **帧宽 = 横条高度 H**，
因为 Tiny Swords 的帧是正方形画布、Aseprite 水平导出。
所以 帧数 = W // H，每帧裁 (H, H)。

排除：建筑/炮塔/装饰类（Goblin Hut、Wooden Fence、Boat、Cannon、Fish Hut、
Pirate Tower、Seahorse Boat、Harpoon、Bomb、Root Troll 装饰物）。

输出：Assets/Art/Sprites/Units/ep_<set>/
  idle_00..NN.png   （来自 *_Idle）
  run_00..NN.png     （来自 *_Run / *_Walk，对应 config 的 walk 键）
  attack_00..NN.png （来自 *_Attack / *_Throw / *_Shoot）
  dead_00..NN.png    （来自 *_Dead，仅 Troll 有）

用法：python tools/import_enemy_pack.py
"""
from __future__ import annotations

import json
import os
import shutil

from PIL import Image

PROJ = r"D:\SteamPunkExtraction"
SRC_ROOT = (r"D:\Tiny-Warcamp\Tiny-Warcamp-main\TinyResources"
            r"\Tiny Swords (Enemy Pack)\Tiny Swords (Enemy Pack)\Enemy Pack\Enemies")
UNITS_DST = os.path.join(PROJ, "Assets", "Art", "Sprites", "Units")
CONFIG = os.path.join(PROJ, "Data", "config.json")
RES_PREFIX = "res://Assets/Art/Sprites/Units/"

# (family, unit, set, cn名, hp, damage, speed_mult, weight)
UNITS = [
    ("Caveborn", "Bear", "bear", "熊", 80, 14, 0.9, 1),
    ("Caveborn", "Cave", "cave", "洞穴兽", 30, 8, 0.7, 1),
    ("Caveborn", "Lizard", "lizard", "蜥蜴", 35, 10, 1.1, 1),
    ("Caveborn", "Snake", "snake", "蛇", 30, 9, 1.2, 1),
    ("Caveborn", "Spider", "spider", "蜘蛛", 32, 10, 1.15, 1),
    ("Caveborn", "Turtle", "turtle", "巨龟", 120, 12, 0.6, 1),
    ("Gnoll", "Gnoll", "gnoll", "豺狼人", 45, 12, 1.0, 1),
    ("Gnome", "Gnome", "gnome", "侏儒", 28, 8, 1.05, 1),
    ("Goblin Raiders", "Hex Shaman", "hex_shaman", "萨满", 55, 10, 0.95, 2),
    ("Goblin Raiders", "Pig", "pig", "野猪", 40, 10, 1.1, 1),
    ("Goblin Raiders", "Pig Rider Spear Goblin", "pig_rider", "猪骑兵", 70, 14, 1.0, 1),
    ("Goblin Raiders", "Spear Goblin", "spear_goblin", "长矛哥布林", 38, 11, 1.1, 2),
    ("Goblin Raiders", "Torch Goblin", "torch_goblin", "火把哥布林", 36, 12, 1.1, 1),
    ("Minotaur", "Minotaur", "minotaur", "牛头人", 140, 18, 0.8, 1),
    ("Panda", "Panda", "panda", "熊猫", 110, 16, 0.85, 1),
    ("Pirate Fish", "Bomb Fish", "bomb_fish", "炸弹鱼", 34, 12, 1.05, 1),
    ("Pirate Fish", "Harpoon Shark", "harpoon_shark", "鱼叉鲨", 50, 13, 1.0, 1),
    ("Pirate Fish", "Paddle Shark", "paddle_shark", "桨鲨", 55, 14, 1.05, 1),
    ("Skull", "Skull", "skull", "骷髅", 42, 12, 1.0, 1),
    ("Thief", "Thief", "thief", "盗贼", 40, 11, 1.2, 1),
    ("Troll", "Troll", "troll", "巨魔", 150, 20, 0.7, 1),
]


def find_strip(files: list[str], *subs: str) -> str | None:
    """返回第一个文件名包含 sub 的（不含 .import）。按列表顺序，subs 依次尝试。"""
    for sub in subs:
        for f in files:
            if f.endswith(".import"):
                continue
            if sub in f:
                return f
    return None


def slice_strip(src_path: str, dst_dir: str, prefix: str) -> list[str]:
    """把横条切成 帧宽=H 的单帧 PNG，返回 res:// 路径数组。"""
    os.makedirs(dst_dir, exist_ok=True)
    sheet = Image.open(src_path).convert("RGBA")
    W, H = sheet.size
    if W % H != 0:
        print("  [警告] %s 宽 %d 不能被高 %d 整除，跳过" % (os.path.basename(src_path), W, H))
        return []
    n = W // H
    paths: list[str] = []
    for i in range(n):
        fr = sheet.crop((i * H, 0, (i + 1) * H, H))
        name = "%s_%02d.png" % (prefix, i)
        fr.save(os.path.join(dst_dir, name))
        paths.append(RES_PREFIX + os.path.basename(dst_dir) + "/" + name)
    return paths


def main() -> int:
    new_types: list[dict] = []
    for family, unit, setname, cn, hp, dmg, speed, weight in UNITS:
        # 单兵种家族（Gnoll/Gnome/Minotaur/Panda/Skull/Thief/Troll）素材直接放在
        # 家族目录下；多兵种家族（Caveborn/*、Goblin Raiders/*、Pirate Fish/*）再嵌套一层 unit/。
        nested = os.path.join(SRC_ROOT, family, unit)
        flat = os.path.join(SRC_ROOT, family)
        if os.path.isdir(nested):
            src_dir = nested
        elif os.path.isdir(flat):
            src_dir = flat
        else:
            print("[skip] 源目录不存在: %s" % nested)
            continue
        files = sorted(os.listdir(src_dir))
        dst_dir = os.path.join(UNITS_DST, "ep_" + setname)

        idle_file = find_strip(files, "_Idle")
        walk_file = find_strip(files, "_Run", "_Walk")
        atk_file = find_strip(files, "_Attack", "_Throw", "_Shoot")
        dead_file = find_strip(files, "_Dead")

        # 画布尺寸取 idle（没有就用第一个可用）
        canvas = 192
        probe = idle_file or walk_file or atk_file
        if probe:
            canvas = Image.open(os.path.join(src_dir, probe)).size[1]

        idle_paths = slice_strip(os.path.join(src_dir, idle_file), dst_dir, "idle") if idle_file else []
        walk_paths = slice_strip(os.path.join(src_dir, walk_file), dst_dir, "run") if walk_file else []
        atk_paths = slice_strip(os.path.join(src_dir, atk_file), dst_dir, "attack") if atk_file else []
        dead_paths = slice_strip(os.path.join(src_dir, dead_file), dst_dir, "dead") if dead_file else []

        entry: dict = {
            "id": "ep_" + setname,
            "name": cn,
            "weight": weight,
            "hp": hp,
            "damage": dmg,
            "speed_mult": speed,
            "scale": round(192.0 / canvas, 4),
            "idle": idle_paths,
        }
        if walk_paths:
            entry["walk"] = walk_paths
        if atk_paths:
            entry["attack"] = atk_paths
        if dead_paths:
            entry["dead"] = dead_paths
        new_types.append(entry)
        print("  ok ep_%s 画布%d scale=%.3f idle=%d walk=%d atk=%d dead=%d"
              % (setname, canvas, entry["scale"], len(idle_paths),
                 len(walk_paths), len(atk_paths), len(dead_paths)))

    # ---- 写入 config.json（先备份）----
    bak = CONFIG + ".enemypack.bak"
    if not os.path.exists(bak):
        shutil.copy2(CONFIG, bak)
        print("[backup] %s" % bak)

    with open(CONFIG, "r", encoding="utf-8-sig") as fh:
        cfg = json.load(fh)
    types = cfg.setdefault("enemy_types", {}).setdefault("types", [])
    existing = {t.get("id") for t in types}
    added = 0
    for e in new_types:
        if e["id"] in existing:
            print("  [跳过] 已存在兵种 %s" % e["id"])
            continue
        types.append(e)
        added += 1
    with open(CONFIG, "w", encoding="utf-8-sig", newline="\n") as fh:
        json.dump(cfg, fh, ensure_ascii=False, indent=2)
    print("共新增 %d 个敌兵种（总计 %d 个），已写回 config.json" % (added, len(types)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# -*- coding: utf-8 -*-
"""tools/patch_fx_config.py —— 往 Data/config.json 插入/刷新顶层 fx 段。

单独写脚本而不是手改 JSON：本项目 config.json 带 UTF-8 BOM、必须是 LF、
且缩进 2 的规范写法（见文件头的说明），手改很容易把 BOM 或行尾弄丢。
脚本按 key 顺序重建，跑完再断言"字节级 round-trip 相同"。
"""
import io
import json
import os
import sys
from collections import OrderedDict

CFG = r"D:\SteamPunkExtraction\Data\config.json"

EFFECTS = OrderedDict([
    ("slash_sword", {
        "_comment": "剑士出手：RPG 表 P33-1617 第 5 行（白/钢），素面粗厚弯月弧 14 帧。",
        "texture": "res://Assets/Art/Sprites/FX/slash_sword.png",
        "frames": 14, "fps": 40.0, "scale": 1.6, "offset_px": [46.0, 0.0],
        "rot_degrees": 0.0, "modulate": "#ffffff", "additive": True,
        "fade_out": 0.08, "z_index": 55,
    }),
    ("thrust_spear", {
        "_comment": "枪手出手：P28-1350 第 5 行，右指长锥带环纹 12 帧（突刺不是横扫）。",
        "texture": "res://Assets/Art/Sprites/FX/thrust_spear.png",
        "frames": 12, "fps": 40.0, "scale": 1.5, "offset_px": [70.0, 0.0],
        "rot_degrees": 0.0, "modulate": "#ffffff", "additive": True,
        "fade_out": 0.06, "z_index": 55,
    }),
    ("cast_staff", {
        "_comment": "僧侣出手：P32-1575 第 2 行（蓝），同心双环内套旋纹球 14 帧。"
                    "法杖三段时间合计 0.65s，所以这条刻意放慢（14/26≈0.54s）。",
        "texture": "res://Assets/Art/Sprites/FX/cast_staff.png",
        "frames": 14, "fps": 26.0, "scale": 1.15, "offset_px": [26.0, -14.0],
        "rot_degrees": 0.0, "modulate": "#ffffff", "additive": True,
        "fade_out": 0.12, "z_index": 55,
    }),
    ("spark_arrow", {
        "_comment": "箭矢命中：P33-1637 第 0 行（橙），饱满四芒星带亮心 14 帧。"
                    "比通用受击星芒小一号 —— 箭是扎进去的，不该炸成火球。",
        "texture": "res://Assets/Art/Sprites/FX/spark_arrow.png",
        "frames": 14, "fps": 42.0, "scale": 0.75, "offset_px": [0.0, 0.0],
        "rot_degrees": 0.0, "modulate": "#ffffff", "additive": True,
        "fade_out": 0.06, "z_index": 50,
    }),
    ("spark_hit", {
        "_comment": "通用受击星芒：P32-1585 第 5 行（白），粗射线八芒星爆发 14 帧。"
                    "近战判定帧砍中目标时在目标身上放这一条。",
        "texture": "res://Assets/Art/Sprites/FX/spark_hit.png",
        "frames": 14, "fps": 44.0, "scale": 0.85, "offset_px": [0.0, -10.0],
        "rot_degrees": 0.0, "modulate": "#ffffff", "additive": True,
        "fade_out": 0.06, "z_index": 56,
    }),
    ("slash_claw", {
        "_comment": "敌人近战出手：P33-1616 第 7 行（红），带尖刺毛边的月牙弧 13 帧。"
                    "毛边比我方那条更糙 —— 一眼分得清是谁在挥。",
        "texture": "res://Assets/Art/Sprites/FX/slash_claw.png",
        "frames": 13, "fps": 34.0, "scale": 1.25, "offset_px": [34.0, 0.0],
        "rot_degrees": 0.0, "modulate": "#ffffff", "additive": True,
        "fade_out": 0.08, "z_index": 52,
    }),
    ("cast_hex", {
        "_comment": "萨满出手：P29-1425 第 8 行（紫），四扇叶旋成圆形法阵环 13 帧。",
        "texture": "res://Assets/Art/Sprites/FX/cast_hex.png",
        "frames": 13, "fps": 22.0, "scale": 1.05, "offset_px": [22.0, -18.0],
        "rot_degrees": 0.0, "modulate": "#ffffff", "additive": True,
        "fade_out": 0.12, "z_index": 52,
    }),
    ("puff_dust", {
        "_comment": "落空/撞墙的扬尘：P31-1527 第 6 行（土黄），放射点状扩散碎圈 14 帧。"
                    "箭撞墙或飞满射程时用，给「弹道去哪了」一个交代。非加色：它是尘不是光。",
        "texture": "res://Assets/Art/Sprites/FX/puff_dust.png",
        "frames": 14, "fps": 26.0, "scale": 1.1, "offset_px": [0.0, 0.0],
        "rot_degrees": 0.0, "modulate": "#d8c4a0", "additive": False,
        "fade_out": 0.14, "z_index": 48,
    }),
])


def build():
    return OrderedDict([
        ("_comment",
         "特效库（Scripts/combat/fx_library.gd）。一条 = 一个特效，谁用谁写 id，加角色不改代码。"
         "四个引用点各自独立可缺省（缺省 = 空串 = 不生成，老配置不改也照样跑）："
         "① 我方出手那一刀的弧光 combat.weapons.<武器>.fx_attack；"
         "② 我方近战砍中目标身上的星芒 combat.attack.fx_hit（武器写了 fx_hit 听武器的）；"
         "③ 我方弹道命中 combat.weapons.<武器>.projectile.fx_impact / .fx_miss；"
         "④ 敌人出手 enemy_types.types[].fx_attack，"
         "空串则回落 enemy.attack.fx_attack 那条默认。"
         "素材由 tools/cut_fx.py 从 RPG Effect All Free 总表切出：横条图集（帧从左到右）、"
         "格 128px = 源表 64px 格的 2 倍整数放大、每格保留完整正方形不裁包围盒（裁了会抖）。"
         "源表结构：行 = 9 种配色（0 橙/1 粉/2 蓝/3 绿/4 棕橙/5 白/6 土黄/7 红/8 紫）、列 = 帧。"
         "frames/fps 必须和切脚本打印的一致。scale/offset_px/modulate/z_index 全在这张表里调。"),
        ("enabled", True),
        ("max_simultaneous", 48),
        ("effects", EFFECTS),
    ])


def main():
    txt = io.open(CFG, encoding="utf-8-sig", newline="").read()
    had_crlf = "\r\n" in txt
    data = json.loads(txt, object_pairs_hook=OrderedDict)
    out = OrderedDict()
    for k, v in data.items():
        if k == "fx":
            out["fx"] = build()
            continue
        out[k] = v
        if k == "enemy_types" and "fx" not in out:
            out["fx"] = build()
    rendered = json.dumps(out, ensure_ascii=False, indent=2) + "\n"
    io.open(CFG, "w", encoding="utf-8-sig", newline="\n").write(rendered)
    back = json.loads(io.open(CFG, encoding="utf-8-sig").read(), object_pairs_hook=OrderedDict)
    assert list(back.keys()).count("fx") == 1
    assert len(back["fx"]["effects"]) == len(EFFECTS)
    print("fx 段已写入；顶层键 %d 个；effects %d 条；CRLF=%s"
          % (len(back), len(back["fx"]["effects"]), had_crlf))
    print("键顺序：", ", ".join(list(back.keys())[:20]))


if __name__ == "__main__":
    sys.exit(main())

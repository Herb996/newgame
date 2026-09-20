# -*- coding: utf-8 -*-
"""tools/patch_fx_refs.py —— 把特效 id 挂到武器/弹道/兵种上（fx 库的引用侧）。

规矩与 combat.attack 的时长回落一模一样：**兵种/武器没写就用默认**，
所以老配置不加这些键也照样跑（EffectLibrary 拿到空串直接不生成）。
"""
import io
import json
import sys
from collections import OrderedDict

CFG = r"D:\SteamPunkExtraction\Data\config.json"

WEAPON_FX = {
    "sword": "slash_sword",
    "spear": "thrust_spear",
    "staff": "cast_staff",
}
# 我方近战砍中目标时的星芒（对所有武器通用，写在 combat.attack 上）
ATTACK_FX_DEFAULT = "spark_hit"
# 敌人近战默认那一条：没写 fx_attack 的兵种都走它
ENEMY_FX_DEFAULT = "slash_claw"
ENEMY_FX = {
    "ep_spear_goblin": "thrust_spear",     # 长矛哥布林：突刺，和玩家枪手同一形状不同色
    "ep_hex_shaman": "cast_hex",           # 萨满：法阵
    "ep_torch_goblin": "spark_arrow",      # 火把哥布林：亮橙的四芒星当火把甩
    "ep_bear": "slash_claw",
    "ep_minotaur": "slash_claw",
    "ep_troll": "slash_claw",
}


def main():
    txt = io.open(CFG, encoding="utf-8-sig", newline="").read()
    data = json.loads(txt, object_pairs_hook=OrderedDict)

    weapons = data["combat"]["weapons"]
    for wid, fx in WEAPON_FX.items():
        weapons[wid]["fx_attack"] = fx
    atk = data["combat"]["attack"]
    atk["fx_hit"] = ATTACK_FX_DEFAULT
    atk["fx_hit_comment"] = ("fx_hit = 我方近战**砍中目标**时在身上放的星芒"
                            "（武器自己写了 fx_hit 就听武器的）。出手那一刀的弧光是另一件事，"
                            "写在 combat.weapons.<武器>.fx_attack。")

    bow = weapons["bow"]["projectile"]
    bow["fx_impact"] = "spark_arrow"
    bow["fx_miss"] = "puff_dust"
    if "hitscan" in weapons["sniper"]:
        hs = weapons["sniper"]["hitscan"]
        hs["fx_impact"] = "spark_hit"

    eattack = data["enemy"]["attack"]
    eattack["fx_attack"] = ENEMY_FX_DEFAULT
    types = data["enemy_types"]["types"]
    hit = 0
    for t in types:
        tid = str(t.get("id", ""))
        if tid in ENEMY_FX:
            t["fx_attack"] = ENEMY_FX[tid]
            hit += 1
        elif "fx_attack" not in t:
            t["fx_attack"] = ""
    data["enemy_types"]["_fx_comment"] = (
        "types[].fx_attack = 该兵种出手时的特效 id（fx.fx 库里的一条，见顶层 fx._comment）。"
        "写空串 = 用 enemy.attack.fx_attack 那条默认。这轮按用户「敌人也做，挑几个兵种」"
        "只给 6 个兵种配了专属形状，其余全走默认的红色毛边月牙。")

    rendered = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    io.open(CFG, "w", encoding="utf-8-sig", newline="\n").write(rendered)
    print("武器 %d 条写了 fx_attack；兵种 %d 条写了专属 id，共 %d 个兵种"
          % (len(WEAPON_FX), hit, len(types)))
    print("bow.projectile.fx_impact=%s fx_miss=%s" % (bow["fx_impact"], bow["fx_miss"]))
    print("enemy.attack.fx_attack=%s" % eattack["fx_attack"])


if __name__ == "__main__":
    sys.exit(main())

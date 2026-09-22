"""技能批 1 的配置写入：stun 状态 + 落石 + 地裂 + defaults.knockback_px。

Data/config/*.json 的规矩（写死在这免得下次手滑）：无 BOM、LF、indent=2、
ensure_ascii=False。读也一样：utf-8-sig 兼容有无 BOM。
"""
import io
import json
import collections
import sys

PATH = "Data/config/skills.json"


def load():
    with io.open(PATH, "rb") as f:
        return json.loads(f.read().decode("utf-8-sig"), object_pairs_hook=collections.OrderedDict)


def save(doc):
    text = json.dumps(doc, ensure_ascii=False, indent=2) + "\n"
    with open(PATH, "wb") as f:
        f.write(text.encode("utf-8"))


def main():
    doc = load()
    s = doc["skills"]

    # 1) defaults 多一条：击退距离按招给，没写就是 0（不推）
    d = s["defaults"]
    nd = collections.OrderedDict()
    for k, v in d.items():
        nd[k] = v
        if k == "shock_ring_seconds":
            nd["knockback_px"] = 0.0
    s["defaults"] = nd
    nd["_comment"] = nd["_comment"].replace(
        "shock_ring_seconds = aoe_self 那圈地面冲击波的扩散时长（只有这一种 type 用）。",
        "shock_ring_seconds = aoe_self 那圈地面冲击波的扩散时长（只有这一种 type 用）。"
        "knockback_px = aoe_self 把目标沿「施法者→目标」推开多少像素（0 = 不推；"
        "写了才推，所以推不推得动是配置差异，代码里只有一句 has_method）。",
    )

    # 2) 新状态：眩晕
    st = s["statuses"]
    st["stun"] = collections.OrderedDict([
        ("_comment", "眩晕：停 AI + 速度归零，但比冻结短得多，且解冻免疫期更长 —— "
                     "落石/地裂这类控制技一旦能无缝续上，敌人就永远动不了了。"),
        ("name", "眩晕"),
        ("color", "#ffd166"),
        ("tint_blend", 0.25),
        ("duration_seconds", 0.8),
        ("stack_mode", "refresh"),
        ("speed_mult", 0.0),
        ("halt_ai", True),
        ("thaw_immunity_seconds", 2.0),
    ])

    # 3) 两招土系
    lst = s["list"]
    lst["falling_rocks"] = collections.OrderedDict([
        ("_comment", "落石：土系瞬发砸击，砸完把人推开 46px。控制靠眩晕而不是冻结 —— "
                     "冻结那 1.6s 配 0.9s 免疫期是冰链的专属节奏，土系要的是「打断一下、挤出空间」。"),
        ("name", "落石"),
        ("element", "earth"),
        ("type", "aoe_self"),
        ("key", 52),
        ("damage", 26),
        ("radius_px", 140.0),
        ("cooldown_seconds", 12.0),
        ("noise", 150.0),
        ("status", "stun"),
        ("knockback_px", 46.0),
        ("fx_cast", "bash_rock"),
        ("fx_hit", "slam_paw"),
        ("drop_weight", 1),
    ])
    lst["quake_split"] = collections.OrderedDict([
        ("_comment", "地裂：半径最大的一招（190px），击退也最狠（78px），代价是冷却最长、"
                     "噪音 200 —— 比一次普攻（120）响得多，砸完周围的敌人全听见了。"),
        ("name", "地裂"),
        ("element", "earth"),
        ("type", "aoe_self"),
        ("key", 53),
        ("damage", 20),
        ("radius_px", 190.0),
        ("cooldown_seconds", 14.0),
        ("noise", 200.0),
        ("status", "stun"),
        ("knockback_px", 78.0),
        ("fx_cast", "burst_charge"),
        ("fx_hit", "bash_rock"),
        ("drop_weight", 1),
    ])

    lst["_comment"] = ("技能池。type 只有三种，各走一条结算分支：aoe_self（以自己为圆心的一次性冲击）、"
                       "projectile（飞出去的单发弹道，命中点小范围溅射）、buff（不造成伤害，只给自己上一层乘数）。"
                       "新技能只要复用这三种 type 就零代码改动；要新机制（击退 / 治疗 / 增伤 / 多重弹幕）"
                       "才动 skill_system.gd，而且一律加在 defaults 里、按招覆盖。"
                       "fx_cast / fx_hit 必须是 fx.effects 表里真实存在的 id —— 写错不会崩，"
                       "但 EffectLibrary 会警告一次然后什么都不画（探针 A 段兜这一条）。"
                       "槽数（skills.slots）与池子大小是两回事：池子可以很大，身上同时只带 slots 招。")

    save(doc)
    print("skills now:", len([k for k in lst if not k.startswith("_")]))


if __name__ == "__main__":
    sys.exit(main())

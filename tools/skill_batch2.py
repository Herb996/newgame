"""技能批 2 的配置写入：治疗 + 吸血两条新机制，落到 圣光十字 / 嗜血 两招。

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


def insert_after(od, anchor, pairs):
    """在某个键后面按顺序插几项（保持 JSON 里的阅读顺序，别把新键甩到文件尾巴上）。"""
    out = collections.OrderedDict()
    for k, v in od.items():
        out[k] = v
        if k == anchor:
            for nk, nv in pairs:
                out[nk] = nv
    return out


def main():
    doc = load()
    s = doc["skills"]

    # 1) defaults 多两条：治疗量（一次性）与吸血比例（有时限的乘数）
    s["defaults"] = insert_after(s["defaults"], "damage", [
        ("heal_flat", 0),
        ("lifesteal", 0.0),
    ])
    s["defaults"]["_comment"] = s["defaults"]["_comment"].replace(
        "knockback_px = aoe_self 把目标沿「施法者→目标」推开多少像素（0 = 不推；"
        "写了才推，所以推不推得动是配置差异，代码里只有一句 has_method）。",
        "knockback_px = aoe_self 把目标沿「施法者→目标」推开多少像素（0 = 不推；"
        "写了才推，所以推不推得动是配置差异，代码里只有一句 has_method）。"
        "heal_flat = buff 型放完当场回多少点血（整数血，与 max_hp 同一把尺；0 = 不回，"
        "heal() 自己夹到上限，所以满血放治疗不浪费冷却之外的任何东西）。"
        "lifesteal = buff 型给自己那层嗜血的比例：此后**任何**来源的我方伤害（普攻近战、"
        "箭、技能）按打出去的伤害回这么多成。两条都是按招覆盖，没写的技能一个都不碰。",
    )

    # 2) progression 多一条：治疗自己的成长档
    s["progression"] = insert_after(s["progression"], "damage_per_level", [
        ("heal_per_level", 0.25),
    ])
    s["progression"]["_comment"] = s["progression"]["_comment"].replace(
        "成长全是乘算：伤害 ×(1 + damage_per_level×(等级−1))、",
        "成长全是乘算：伤害 ×(1 + damage_per_level×(等级−1))、"
        "治疗 ×(1 + heal_per_level×(等级−1))（治疗单独一档，因为「回得更多」与"
        "「转得更快」是两种手感，共用一条曲线就再也调不动其中一个）、",
    )

    # 3) 两招：圣光十字（瞬发回血）+ 嗜血（打人就回血的一层增益）
    lst = s["list"]
    lst["holy_cross"] = collections.OrderedDict([
        ("_comment", "圣光十字：金系自我治疗，放完当场回一口血，不进状态容器（血已经回去了，"
                     "没有剩余时长可倒数）。自动释放只在残血时开 —— 治疗招平时放就是浪费，"
                     "门槛写在 auto_cast_hp_below。没有 buff_duration_seconds / damage / status "
                     "这些键：一条都不生效，写了就是死配置。"),
        ("name", "圣光十字"),
        ("element", "metal"),
        ("type", "buff"),
        ("key", 54),
        ("heal_flat", 34),
        ("cooldown_seconds", 13.0),
        ("noise", 45.0),
        ("auto_cast_hp_below", 0.6),
        ("fx_cast", "hit_holy"),
        ("drop_weight", 1),
    ])
    lst["blood_hunger"] = collections.OrderedDict([
        ("_comment", "嗜血：给自己挂一层 6 秒的吸血，期间我方**所有**出手都回血（普攻那一刀、"
                     "飞出去的箭、技能砸的范围伤，三个出口同一个口径：按打出去的伤害算，"
                     "不看目标扣完防御实际掉几滴）。自动时机同样是残血 —— 残血才开狂暴，"
                     "满血开着纯属白占一层增益。时长按等级放大走 duration_per_level。"),
        ("name", "嗜血"),
        ("element", "fire"),
        ("type", "buff"),
        ("key", 55),
        ("lifesteal", 0.25),
        ("buff_duration_seconds", 6.0),
        ("cooldown_seconds", 16.0),
        ("noise", 60.0),
        ("auto_cast_hp_below", 0.5),
        ("fx_cast", "slash_rend"),
        ("drop_weight", 1),
    ])

    lst["_comment"] = ("技能池。type 只有三种，各走一条结算分支：aoe_self（以自己为圆心的一次性冲击）、"
                       "projectile（飞出去的单发弹道，命中点小范围溅射）、buff（不碰别人，只往自己身上"
                       "做事：上一层有时限的乘数，或者当场结一次治疗，两样可以只做一样）。"
                       "新技能只要复用这三种 type 就零代码改动；要新机制（击退 / 多重弹幕）"
                       "才动 skill_system.gd，而且一律加在 defaults 里、按招覆盖。"
                       "fx_cast / fx_hit 必须是 fx.effects 表里真实存在的 id —— 写错不会崩，"
                       "但 EffectLibrary 会警告一次然后什么都不画（探针 A 段兜这一条）。"
                       "槽数（skills.slots）与池子大小是两回事：池子可以很大，身上同时只带 slots 招。")

    save(doc)
    print("skills now:", len([k for k in lst if not k.startswith("_")]))


if __name__ == "__main__":
    sys.exit(main())

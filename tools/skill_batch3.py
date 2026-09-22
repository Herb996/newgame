"""技能批 3 的配置写入：增伤 / 加速两条新机制，落到 狂战面具 / 疾风羽 两招。

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

    # 1) defaults 多两条：出手侧的增伤、移动侧的加速
    s["defaults"] = insert_after(s["defaults"], "lifesteal", [
        ("damage_bonus", 0.0),
        ("speed_bonus", 0.0),
    ])
    s["defaults"]["_comment"] = s["defaults"]["_comment"].replace(
        "两条都是按招覆盖，没写的技能一个都不碰。",
        "damage_bonus = buff 型的出手侧增伤：+0.40 表示此后我方**所有**伤害（普攻、箭、"
        "技能）在抽暴击之前先乘 1.4。与 damage_reduction 是两把独立的尺，一张面具可以"
        "既砍得痛又扛不住。speed_bonus = buff 型的移速加成：+0.50 表示这 4 秒里跑得快一半，"
        "走的是 UnitStatus.speed_mult 那条既有通道（冻结把它乘成 0，加速把它乘大，同一句）。"
        "四条乘数键全是按招覆盖，没写的技能一个都不碰。",
    )

    # 2) 两招：狂战面具（增伤 + 代价）+ 疾风羽（加速，纯手动）
    #    注意 damage_reduction **不**进 defaults：_cast_buff 是直接 d.get("damage_reduction", 0.0)
    #    读技能自己那一段的，落到 defaults 里就成了一份没人读的死配置。
    lst = s["list"]
    lst["battle_madness"] = collections.OrderedDict([
        ("_comment", "狂战面具：金系自我增益，5 秒里出手伤害 ×1.4，代价是承伤 ×1.15"
                     "（damage_reduction 写成负数就是「多挨打」）。这是全表第一招带代价的增益 ——"
                     "没有代价的增伤技能等于没有决策。自动时机是残血 70%：越打越疯，"
                     "满血时不替玩家做这个亏本决定。"),
        ("name", "狂战面具"),
        ("element", "metal"),
        ("type", "buff"),
        ("key", 56),
        ("damage_bonus", 0.4),
        ("damage_reduction", -0.15),
        ("buff_duration_seconds", 5.0),
        ("cooldown_seconds", 18.0),
        ("noise", 40.0),
        ("auto_cast_hp_below", 0.7),
        ("fx_cast", "burst_charge"),
        ("drop_weight", 1),
    ])
    lst["swift_feather"] = collections.OrderedDict([
        ("_comment", "疾风羽：木系自我增益，4 秒里移速 ×1.5。全表第一招 auto_cast=false ——"
                     "跑与不停是玩家的判断（追、绕、撤），替玩家决定「什么时候该跑」的技能"
                     "只会让人觉得角色不听话。没有伤害、没有状态、没有治疗：这一招改的只有腿。"),
        ("name", "疾风羽"),
        ("element", "wood"),
        ("type", "buff"),
        ("key", 57),
        ("speed_bonus", 0.5),
        ("buff_duration_seconds", 4.0),
        ("cooldown_seconds", 12.0),
        ("noise", 20.0),
        ("auto_cast", False),
        ("fx_cast", "puff_dust"),
        ("drop_weight", 1),
    ])

    save(doc)
    print("skills now:", len([k for k in lst if not k.startswith("_")]))


if __name__ == "__main__":
    sys.exit(main())

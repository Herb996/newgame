"""技能批 4 的配置写入：多重弹幕机制（一发变数发），落到 火星溅 / 落叶刃 两招。

同时把 skills.allowed_keys 从 #69 提前带进来：数字键 49..57（1~9）已经被九招占满，
再加招必须换一段键码，而「哪些键码算合法」这件事得有一张表来管，不能散在每招里。

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

    # 1) defaults 多两条：一发变数发 + 这几发摊开多少度
    s["defaults"] = insert_after(s["defaults"], "speed_bonus", [
        ("projectile_count", 1),
        ("spread_deg", 0.0),
    ])
    s["defaults"]["_comment"] = s["defaults"]["_comment"].replace(
        "四条乘数键全是按招覆盖，没写的技能一个都不碰。",
        "四条乘数键全是按招覆盖，没写的技能一个都不碰。"
        "projectile_count = projectile 型一次出手放出几发（1 = 单发，就是老行为；只有 projectile 型读它，"
        "写在别的 type 上不生效）。spread_deg = 这几发一共摊开多少度，以瞄准方向为**正中**对称散开，"
        "所以 count=3、spread=34 是三发分别在 −17°/0°/+17°。两个键配套用：只写 count 不写 spread 会打出"
        "一串重叠的弹道（等于浪费），只写 spread 则是单发偏个角度。**升级不加发数**——发数是一招的身份，"
        "随等级长的仍然是伤害/冷却/半径那几条（见 progression），不然顶级招会把低级招的观感整个换掉。",
    )

    # 2) allowed_keys：合法键码的白名单（探针断言每招的 key 都在表内、且互不重复）
    s = insert_after(s, "slots", [(
        "allowed_keys",
        [49, 50, 51, 52, 53, 54, 55, 56, 57,
         81, 84, 89, 85, 73, 79, 80, 71, 74, 75, 76, 90, 88, 67, 86, 78, 77],
    )])
    doc["skills"] = s
    s["_comment"] = s["_comment"].replace(
        "与 combat.input.dodge_key 同一套读法 —— 项目没有 InputMap，全是 physical_keycode 直比。",
        "与 combat.input.dodge_key 同一套读法 —— 项目没有 InputMap，全是 physical_keycode 直比。"
        "键码不是随便挑的：allowed_keys（紧跟 slots 那一条）列出了允许用的键码，按顺序取用即可 —— "
        "前九个是数字 1~9，后面按键盘行序取那一片没人占的字母：Q T Y U I O P、G J K L（H 被 run.eat_key "
        "占了所以跳过）、Z X C V、N M。表里没有的键码探针会直接判失败；别的系统用掉的键"
        "（dodge=Space、return=F、eat=H、背包=B、stat panel=F9，加上移动那四个 WASD 与 E/R/A）也都避开了。",
    )

    # 3) 两招：一次三发的火星溅 + 一次两发带眩晕的落叶刃
    lst = s["list"]
    lst["cinder_sparks"] = collections.OrderedDict([
        ("_comment", "火星溅：多重弹幕的第一招。三发窄扇面摊开，每发自己抽一次伤害（暴击与浮动"
                     "逐发算，所以三发全中不会得到整齐的 3×数字），每发都挂灼烧。单发比余烬弹弱很多——"
                     "全中才赚，贴脸站成一排时最划算，这正是它与余烬弹的分工。没有 aoe_radius_px："
                     "溅射会让三发在落点又各炸一次，等于把扇面白摊了。"),
        ("name", "火星溅"),
        ("element", "fire"),
        ("type", "projectile"),
        ("key", 81),
        ("damage", 12),
        ("projectile_count", 3),
        ("spread_deg", 34.0),
        ("range_px", 260.0),
        ("cooldown_seconds", 7.0),
        ("noise", 85.0),
        ("status", "burning"),
        ("variance", 0.2),
        ("fx_cast", "shred_bolt"),
        ("projectile", collections.OrderedDict([
            ("_comment", "与余烬弹同一张箭图，只改配色与大小：多重弹幕要的是「一串小东西散开」，"
                         "单发大箭反而读成一颗。speed 略慢，让三发在屏幕上分开得更久一点。"),
            ("texture", "res://Assets/Art/Sprites/Projectiles/arrow.png"),
            ("modulate", "#ff8a3c"),
            ("scale", 0.9),
            ("speed", 680.0),
            ("hit_radius_px", 14.0),
            ("muzzle_offset_px", 20.0),
            ("fx_impact", "spark_hit"),
            ("fx_miss", "puff_dust"),
        ])),
        ("drop_weight", 1),
    ])
    lst["leaf_blade"] = collections.OrderedDict([
        ("_comment", "落叶刃：两发一左一右，带眩晕。与火星溅的区别在用途而不是数量——那招是面杀伤，"
                     "这招是「一定打得到东西」：窄扇面 + 短冷却，两发里只要有一发命中就停住对面 0.8 秒，"
                     "被打断的敌人不会立刻反打。木系配眩晕是刻意的（藤蔓缠一下），"
                     "冷却与噪音都比火星溅低一档：控制不该比伤害更便宜。"),
        ("name", "落叶刃"),
        ("element", "wood"),
        ("type", "projectile"),
        ("key", 84),
        ("damage", 18),
        ("projectile_count", 2),
        ("spread_deg", 16.0),
        ("range_px", 240.0),
        ("cooldown_seconds", 6.5),
        ("noise", 55.0),
        ("status", "stun"),
        ("variance", 0.1),
        ("fx_cast", "sweep_fin"),
        ("projectile", collections.OrderedDict([
            ("_comment", "同一张箭图，绿配大一号：两发要看得出来是两片叶子甩出去，不是同一支箭重影。"),
            ("texture", "res://Assets/Art/Sprites/Projectiles/arrow.png"),
            ("modulate", "#9fd86a"),
            ("scale", 1.1),
            ("speed", 820.0),
            ("hit_radius_px", 16.0),
            ("muzzle_offset_px", 22.0),
            ("fx_impact", "spark_hit"),
            ("fx_miss", "puff_dust"),
        ])),
        ("drop_weight", 1),
    ])

    # 4) 类型介绍里那句「单发弹道」从这一批起不成立了（replace 幂等：已经改过就原样不动）
    lst["_comment"] = lst["_comment"].replace(
        "projectile（飞出去的单发弹道，命中点小范围溅射）",
        "projectile（飞出去的弹道，一到数发、多发起时按扇形摊开，命中点小范围溅射）")

    save(doc)
    print("skills now:", len([k for k in lst if not k.startswith("_")]))


if __name__ == "__main__":
    sys.exit(main())

# -*- coding: utf-8 -*-
import io, json
P = 'Data/config/skills.json'
d = json.load(io.open(P, encoding='utf-8'))
S = d['skills']

# 新键：牵引。放在 defaults 里 = 每一招都接得到，没写就是 0（不拉）。
S['defaults']['pull_px'] = 0.0
c = S['defaults']['_comment']
c = c.replace(
    "knockback_px = aoe_self 把目标沿「施法者→目标」推开多少像素（0 = 不推；写了才推，所以推不推得动是配置差异，代码里只有一句 has_method）。",
    "knockback_px = aoe_self 把目标沿「施法者→目标」推开多少像素（0 = 不推；写了才推，所以推不推得动是配置差异，代码里只有一句 has_method）。"
    "pull_px = 同一套 aoe_self 位移的反方向：把目标沿「目标→施法者」**拽近**多少像素（0 = 不拽）。"
    "两条走的是敌人身上同一个 apply_knockback()，所以代码里是 if/elif —— 同时写两个不会互相抵消，是推的那条赢；"
    "A 段另有一条断言直接拦住「一招同时写推和拉」，免得配表的人以为自己配出了漩涡 + 冲击波。")
S['defaults']['_comment'] = c

ARROW = "res://Assets/Art/Sprites/Projectiles/arrow.png"


def proj(mod, scale, speed, hit, muzzle, impact="hit_pierce", miss="puff_dust"):
    return {"texture": ARROW, "modulate": mod, "scale": scale, "speed": speed,
            "hit_radius_px": hit, "muzzle_offset_px": muzzle,
            "fx_impact": impact, "fx_miss": miss}


L = S['list']

L['meteor_fall'] = {
 "name": "陨星坠", "element": "fire", "type": "aoe_self", "key": 75,
 "damage": 34, "radius_px": 130.0, "cooldown_seconds": 20.0, "noise": 210.0,
 "knockback_px": 55.0, "variance": 0.15, "status": "stun",
 "fx_cast": "thrust_harpoon", "fx_hit": "bash_rock",
 "drop_weight": 1,
 "_comment": "三顶帽子同时戴在这招上：全池最痛（34，压过余烬弹与落石的 26）、最长冷却（20 秒）、最吵（210，比地裂的 200 还响）。这不是数值通胀，是「一颗星砸下来」这一件事的完整读法：砸得狠、要攒很久、整张图都听见。半径故意只给 130（地裂 190）—— 天灾落在一小块地上才有躲的意义，摊成一片就成了第二场地裂。knockback 55 落在落石 46 与地裂 78 之间：冲击波把人掀开，但掀不过那道真裂缝。"}

L['ember_storm'] = {
 "name": "烈焰风暴", "element": "fire", "type": "aoe_self", "key": 76,
 "damage": 11, "radius_px": 200.0, "cooldown_seconds": 13.0, "noise": 95.0,
 "variance": 0.18, "status": "burning", "auto_cast_targets_min": 2,
 "fx_cast": "cast_hex", "fx_hit": "spark_hit",
 "drop_weight": 1,
 "_comment": "全池最广的一圈（200，超过地裂 190），代价是单发只有 11 点：这一招的收益全在 burning 那几跳上，风暴本身不该秒人 —— 否则「最广 + 秒人」两件事凑在一招里，别的范围技就没有存在理由了。auto_cast_targets_min 抄孢子雾那条门槛（2 个人才自动放）：一场火盖住一群人是清场，盖住一个人是浪费，自动释放不该分得出这两者的区别，所以让它等。噪音 95 压在陨星坠与地裂之下：火是烧出来的响，不是砸出来的响。"}

L['abyss_vortex'] = {
 "name": "深渊漩涡", "element": "water", "type": "aoe_self", "key": 90,
 "damage": 7, "radius_px": 175.0, "cooldown_seconds": 12.0, "noise": 40.0,
 "variance": 0.1, "status": "slow", "pull_px": 70.0,
 "fx_cast": "slash_shadow", "fx_hit": "puff_dust",
 "drop_weight": 1,
 "_comment": "全池唯一往回拉的一招（pull_px 70，走敌人身上同一个 apply_knockback，方向反过来）。伤害 7 是纯装饰 —— 这招要的是「把人拽到脸上」，之后由队友收尾；所以配套挂缓滞而不是眩晕：拽过来之后还能让他慢着走，比钉在原地更像一个漩涡。半径 175 比寒潭涟漪（150）大一圈：拉人的范围必须大于人挨打的半径，否则拉不到。噪音 40 静得很 —— 水开的洞不该像塌方。"}

L['sword_array'] = {
 "name": "剑阵", "element": "metal", "type": "aoe_self", "key": 88,
 "damage": 16, "radius_px": 145.0, "cooldown_seconds": 10.0, "noise": 120.0,
 "variance": 0.12, "status": "vulnerable",
 "fx_cast": "hit_sword", "fx_hit": "hit_pierce",
 "drop_weight": 1,
 "_comment": "裂甲痕的群体版：一圈人同时挂易伤（承伤 ×1.3 / 5 秒）。裂甲痕是单体 + 溅射 40，这一招是整片直接铺开 —— 两招并存的理由是「标记谁」这件事在 3 槽 build 里有两种排法：一发点掉带队的，或者一阵盖住一群。伤害 16 只是「这一圈确实打到了人」的凭据，真正的收益要按接下来 5 秒全队打进去多少来读。金属性 + 120 噪音：剑落成一圈是很响的一件事。"}

L['bone_spike'] = {
 "name": "骨刺", "element": "earth", "type": "projectile", "key": 67,
 "damage": 15, "range_px": 200.0, "cooldown_seconds": 7.5, "noise": 65.0,
 "variance": 0.12, "status": "bleed", "aoe_radius_px": 36.0,
 "fx_cast": "spike_bone",
 "projectile": proj("#d3ad7c", 1.1, 700.0, 13.0, 18.0),
 "drop_weight": 1,
 "_comment": "弹道里射程最短的一发（200，霜牙 280 / 蛇咬 220 都比它远），换来命中点 36px 溅射 + 流血：一记土刺从地里顶出来，扎穿一个人、崩到旁边的人 —— 溅射半径比麻骨镖那种纯单体大、比裂甲痕的 40 小，因为它靠的是刺尖崩土，不是冲击波。弹速 700 是全池最慢（其余 820~950）：骨刺是「顶出来」的，不是「射出去」的，慢一点玩家才读得出它是从脚下长的。流血与蛇咬共用一条状态，但蛇咬是快手的单体撕咬（4.5 秒冷却），这一发是慢手的范围崩刺。"}

io.open(P, 'w', encoding='utf-8', newline='\n').write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
n = lambda x: len([k for k in x if not k.startswith('_')])
print("skills=%d statuses=%d" % (n(L), n(S['statuses'])))

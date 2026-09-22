# -*- coding: utf-8 -*-
import io, json
P='Data/config/skills.json'
d=json.load(io.open(P,encoding='utf-8'))
S=d['skills']

S['statuses']['slow']={
 "name":"缓滞","color":"#7fb0c8","tint_blend":0.18,"duration_seconds":3.0,
 "stack_mode":"refresh","speed_mult":0.55,"thaw_immunity_seconds":0.0,
 "_comment":"缓滞：只把腿放慢（speed_mult 0.55），AI 照跑、刀照挥 —— 与冻结（×0 且 halt_ai）是同一把尺的两端。stack_mode 用 refresh 而不是 stack：减速按层数再乘一次会变成 ×0.3，那等于偷偷做出第二个定身，两条状态就没分工了。染色比冻结淡一档（0.18），因为它常年和别的状态叠着挂，两层都染重就看不出是谁在生效。"}
S['statuses']['root']={
 "name":"定身","color":"#7aa85a","tint_blend":0.26,"duration_seconds":1.6,
 "stack_mode":"refresh","speed_mult":0.0,"thaw_immunity_seconds":2.5,
 "_comment":"定身：speed_mult 归零，但**不写 halt_ai**（默认 false）—— 他动不了，可他还在打你。这是与眩晕（halt_ai=true，整段 AI 停）唯一的区别，也是这一条存在的理由：控制要分「打断他」与「困住他」两档，否则落石和藤蔓就是同一招。免疫期 2.5 秒比时长本身还长：定身一旦能无缝续上，boss 战就退化成打木桩。"}
S['statuses']['vulnerable']={
 "name":"易伤","color":"#ff5f8a","tint_blend":0.2,"duration_seconds":5.0,
 "stack_mode":"refresh","damage_mult":1.3,"thaw_immunity_seconds":0.0,
 "_comment":"易伤：承伤 ×1.3，不减速不停手 —— 这批三条里唯一一条伤害侧的尺，走 UnitStatus.damage_taken_mult：我方在 player.take_damage、敌方在 enemy.incoming_damage，两边同一个位置。时长给到 5 秒（比定身长得多）：标记类状态的收益是「这段时间里他多挨了多少打」，1.6 秒根本轮不到第二个人出手。damage_mult 与 speed_mult 互不干涉，所以易伤可以和缓滞同时挂在一个人身上。"}

ARROW="res://Assets/Art/Sprites/Projectiles/arrow.png"
def proj(mod,scale,speed,hit,muzzle,impact="hit_pierce",miss="puff_dust"):
    return {"texture":ARROW,"modulate":mod,"scale":scale,"speed":speed,
            "hit_radius_px":hit,"muzzle_offset_px":muzzle,
            "fx_impact":impact,"fx_miss":miss}
L=S['list']
L['ripple_cold']={
 "name":"寒潭涟漪","element":"water","type":"aoe_self","key":73,
 "damage":10,"radius_px":150.0,"cooldown_seconds":8.0,"noise":35.0,
 "variance":0.1,"status":"slow","fx_cast":"splash_bomb","fx_hit":"spark_hit",
 "drop_weight":1,
 "_comment":"水系第二招。缓滞不伤人，伤的是「他跑不掉了」：伤害只有冰霜新星的六成，换来的是半径 150 的整圈减速。噪音 35 按 skills.defaults 那把尺（走一步 22 / 闪避 40）= 比一次闪避还轻，所以它是潜行流能连着的控场。不写 knockback_px：把人推开等于替他解围。"}
L['vine_grasp']={
 "name":"藤蔓缠绕","element":"wood","type":"aoe_self","key":79,
 "damage":8,"radius_px":112.0,"cooldown_seconds":11.0,"noise":25.0,
 "variance":0.1,"status":"root","fx_cast":"spit_web","fx_hit":"spit_web",
 "drop_weight":1,
 "_comment":"木系的贴脸控场：半径 112 比冰霜新星还小一圈，代价换来的是全池最静的一档（25，只比走一步响一点）。定身与眩晕的分工见 statuses.root —— 被缠住的人还能原地砍你，所以这招是「别站在这儿」而不是「别动了」。不写 knockback_px：推开等于替他解开藤。"}
L['ice_shard']={
 "name":"霜牙","element":"water","type":"projectile","key":80,
 "damage":14,"range_px":280.0,"cooldown_seconds":6.0,"noise":55.0,
 "variance":0.12,"status":"slow","fx_cast":"shred_bolt",
 "projectile":proj("#a6dcff",1.0,820.0,14.0,20.0),
 "drop_weight":1,
 "_comment":"缓滞的第二条路：寒潭涟漪要贴脸，这一发隔着半张图就能把人拖慢。射程 280 与普攻同一口径（会被 min(射程, 观察视野) 截断，打不到看不见的目标这条不变式对技能同样成立）。冷却 6 秒是全池第二快（蛇咬 4.5 最快），因为减速断了就会有人跑掉。"}
L['numb_dart']={
 "name":"麻骨镖","element":"wood","type":"projectile","key":71,
 "damage":9,"range_px":240.0,"cooldown_seconds":9.5,"noise":30.0,
 "variance":0.1,"status":"root","fx_cast":"spark_arrow",
 "projectile":proj("#9ae082",0.8,950.0,12.0,18.0),
 "drop_weight":1,
 "_comment":"定身做成单体 + 短射程：1.6 秒的定身要是能全屏扔，就等于远程点杀。伤害 9 打不死人，够把一次逃跑变成一次围殴。弹道比余烬弹细一号（scale 0.8）、快一档（950）：麻骨镖是「嗖」的一下，不是砸过来的。"}
L['fault_mark']={
 "name":"裂甲痕","element":"metal","type":"projectile","key":74,
 "damage":12,"range_px":260.0,"cooldown_seconds":8.5,"noise":70.0,
 "variance":0.1,"status":"vulnerable","aoe_radius_px":40.0,"fx_cast":"thrust_spear",
 "projectile":proj("#f6e3a8",1.15,880.0,14.0,20.0),
 "drop_weight":1,
 "_comment":"这批唯一一条伤害侧的状态：易伤把承伤乘到 1.3，收益要按「接下来 5 秒全队打他多少」读，不是按这一发多少。aoe_radius_px 40 是必须的：单体标记在 3 槽 build 里等于废招，砸在一群人身上把整片标了才有意义。金系 = 破甲这一层意思全在配色与图标上（首发范围里五行只做标签与配色，不做克制表）。"}

io.open(P,'w',encoding='utf-8',newline='\n').write(json.dumps(d,ensure_ascii=False,indent=2)+"\n")
print("skills=%d statuses=%d"%(len([k for k in L if not k.startswith('_')]),
                               len([k for k in S['statuses'] if not k.startswith('_')])))

class_name DamagePipeline
extends RefCounted
## ============================================================
## DamagePipeline — 伤害结算管线（DESIGN.md 第二部分 伤害与判定）
##
## 采用修饰器模式：基础伤害依次经过若干乘算修饰器（暴击/背刺/难度系数…），
## 再减防御，最后叠随机浮动。调用方只需传 multipliers 数组。
##
##   FinalDmg = (BaseDmg × Π multipliers − Defense) × RandomVariance
##
## 全部数值由调用方从 Data/config.json 传入，本类不读配置、不硬编码。
## ============================================================

## 计算最终伤害（向下取整，最低 0）
## base_damage：基础伤害 / defense：防御（固定减伤）
## multipliers：乘算修饰器数组，如 [1.5] 表示暴击
## variance：随机浮动幅度，0.1 = ±10%（蓝图公式末尾的 RandomVariance）
static func compute(base_damage: float, defense: float = 0.0,
		multipliers: Array = [], variance: float = 0.0) -> int:
	var dmg := base_damage
	for m in multipliers:
		dmg *= float(m)
	dmg -= defense
	if dmg <= 0.0:
		return 0
	if variance > 0.0:
		dmg *= randf_range(1.0 - variance, 1.0 + variance)
	return maxi(int(dmg), 1)

class_name DamagePipeline
extends RefCounted
## ============================================================
## DamagePipeline — 伤害结算管线（DESIGN.md 第二部分 伤害与判定）
##
## 采用修饰器模式：基础伤害依次经过若干乘算修饰器（暴击…），
## 再减防御，最后叠随机浮动。调用方只需传 multipliers 数组。
##
##   FinalDmg = (BaseDmg × Π multipliers − Defense) × RandomVariance
##
## 全部数值由调用方从 Data/config/ 传入，本类不读配置、不硬编码。
##
## 【边界：只管攻击侧】本类负责的是**攻击方自己知道**的那几件事 ——
## 基础伤害、暴击这类乘算修饰器、随机浮动。防守侧的减免**不在这里**：
##   · 玩家防御 → `player.gd::take_damage()` 里扣；
##   · 敌人「血越少越硬」（爆裂鼓手）/「分身越多越硬」→ `enemy.gd::incoming_damage()`。
## 这条切分不是偷懒，是必须的：敌人在 `_deal_attack_damage()` 里算完伤害就交出去，
## 玩家挡不挡住都得照样进冷却、照样播动作（用户 2026-09-19 定的，见该函数注释）。
## 若把玩家防御搬到攻击方结算，就会出现「要扣血才决定砍不砍」的倒置。
## `compute()` 仍保留 defense 形参 —— 那是留给「护甲值攻击方已知」的那种目标用的入口。
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


## 抽一次暴击并结算：返回 {damage:int, crit:bool}。
##
## 为什么要单独一个函数：暴击必须**每次命中各抽一次**（一剑砍三个 = 三次抽样，
## 可能只有一下冒红字），所以它不能是"起手时算好的常数"；而两条攻击路径
## （近战 / 弹道）都得抽，抽法又得一模一样 —— 写在这唯一的纯函数里，
## 探针才能拿固定种子复现。
##
## crit_chance 出厂 0 ⇒ 一次都不抽中 ⇒ 结果与直接调 `compute()` 逐位相同
## （加这段代码不改变任何现有数值）。
## `crit` 是给表现层的钩子（暴击要换特效 / 飘字），结算本身用不到它。
static func roll(base_damage: float, defense: float = 0.0,
		crit_chance: float = 0.0, crit_multiplier: float = 1.5,
		variance: float = 0.0) -> Dictionary:
	var is_crit := crit_chance > 0.0 and randf() < crit_chance
	var multipliers: Array = [crit_multiplier] if is_crit else []
	return {"damage": compute(base_damage, defense, multipliers, variance),
			"crit": is_crit}

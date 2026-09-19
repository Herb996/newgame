extends Node
## ============================================================
## probe_supplies — 局内物资消耗机制（各吃各的 / 短缺只降那个人的属性 / 永不致死）
##
## 2026-09-19 背包拆成每人一份后，本探针全部按「一个人」驱动：
##   A) 配置结构：survival.supplies 每项都有 id/per_meal/shortage_debuff，
##      id 在 resources 里、属性键在 Player 接线列表内（配错必须当场看到）
##   B) 逐项消耗：他自己够 → 从他背包扣 per_meal 且不算短缺；不够 → 只记他短缺
##   C) 短缺真的降属性：trait_damage 与 speed 各按配置掉点数（不是只改字典）
##   D) 补上立刻还原：他捡到货后**不用等下一个 tick**，属性当场回来
##   E) 永不致死：饥饿反复扣血只打短缺的他，血量封在 starvation_hp_floor 之上
##   F) 结构可扩展：往 supplies 里 override 第二种物资（油），不需要改代码就生效
##   G) 主动进食（按 H）吃的是他自己包里的食物
##
## 跨角色的对照（甲缺乙不缺 → 只有甲掉属性 / 拾取归属 / 阵亡撒包）在
## Dev/probe_inventory.gd —— 本探针出击一名角色，测不了"两个人各算各的"。
##
## ⚠ 会写 user://save.json（出击/名册），开跑备份、收尾原样还原。
## ============================================================

const OUT := "user://_probe_supplies.txt"
const SAVE_PATH := "user://save.json"

var _lines: Array = []
var _n := 0
var _fails: Array = []

var _save_backup := ""
var _save_existed := false

var _main: Node = null
var _surv: Node = null
var _run: Node = null
var _players: Array = []


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


## 等 player 组成员稳定（连续 15 帧不变）后返回存活角色列表
func _settle_players() -> Array:
	var prev: Dictionary = {}
	var stable := 0
	for _guard in range(400):
		await get_tree().process_frame
		var cur := {}
		for q in get_tree().get_nodes_in_group("player"):
			cur[q.get_instance_id()] = q
		if cur == prev:
			stable += 1
			if stable >= 15:
				break
		else:
			stable = 0
			prev = cur
	var out: Array = []
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q) and not bool(q.is_dead()):
			out.append(q)
	return out


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	_main = main
	await _frames(30)

	Meta.roster = []
	Meta.seeded_ids = []
	Meta.ensure_roster()

	# 真实出击：要的是「RunManager 进 RUNNING + 玩家身上有 traits/等级」这条完整链路
	# 关掉刷怪：探针要等几十个 tick，场上有敌人会在断言中途把角色打死
	Config.set_override("enemy.count", 0)
	main.call("_on_launch", [{"uid": int(Meta.roster[0].get("uid", 0)),
			"id": "spearman", "name": "枪手", "level": 0}])
	var waited := 0
	while get_tree().get_nodes_in_group("player").is_empty() and waited < 400:
		await get_tree().process_frame
		waited += 1
	# 出击会把旧场景的角色一起带走：等 player 组不再变化再取，否则拿到的是待释放的幽灵
	_players = await _settle_players()
	_run = get_tree().get_first_node_in_group("run_manager")
	_surv = get_tree().get_first_node_in_group("survival_system")
	_say("--- 前置 ---")
	_check(not _players.is_empty(), "出击后拿到 %d 名玩家" % _players.size())
	_check(_run != null and int(_run.state) == int(_run.State.RUNNING), "RunManager 在 RUNNING")
	_check(_surv != null, "场景里有 SurvivalSystem")
	if _run == null or _surv == null or _players.is_empty():
		_finish()
		return
	# 自动 tick 会让断言飘：把倒计时顶到跑不完的数值，全部由探针手动驱动
	_surv.set("next_meal_in", 9999.0)
	_clear_hostiles()

	await _a_config()
	await _b_consume()
	await _c_penalties()
	await _d_recover()
	await _f_extensible()
	await _g_eat()
	await _e_no_death()      # 会把人打死，放最后

	_finish()


# ------------------------------------------------------------
# A) 配置结构
# ------------------------------------------------------------
func _a_config() -> void:
	_say("--- A 段：配置结构 ---")
	var supplies: Array = Config.get_value("survival.supplies", [])
	_check(supplies is Array and not supplies.is_empty(),
			"survival.supplies 是非空列表（%d 项）" % supplies.size())
	var wired: Array = _surv.WIRED_STATS
	var known: Dictionary = Config.get_value("resources", {})
	var bad_field := 0
	var bad_id := 0
	var bad_stat := 0
	for e in supplies:
		if not (e is Dictionary):
			bad_field += 1
			continue
		var id := str((e as Dictionary).get("id", ""))
		if id == "" or not (e as Dictionary).has("per_meal") \
				or not ((e as Dictionary).get("shortage_debuff", {}) is Dictionary):
			bad_field += 1
		if not known.has(id):
			bad_id += 1
		for st in ((e as Dictionary).get("shortage_debuff", {}) as Dictionary).keys():
			if not wired.has(str(st)):
				bad_stat += 1
				_say("       没接线的属性：%s（物资 %s）" % [str(st), id])
	_check(bad_field == 0, "每项都带 id / per_meal / shortage_debuff")
	_check(bad_id == 0, "物资 id 全部存在于 resources")
	_check(bad_stat == 0, "shortage_debuff 的属性键全部已接线")
	_check(int(Config.get_value("survival.starvation_hp_floor", 0)) >= 1,
			"starvation_hp_floor >= 1（实得 %s）"
			% str(Config.get_value("survival.starvation_hp_floor", "缺")))


# ------------------------------------------------------------
# B) 逐项消耗
# ------------------------------------------------------------
func _b_consume() -> void:
	_say("--- B 段：逐项消耗（各吃各的）---")
	_reset()
	var e: Dictionary = (_surv._supplies()[0] as Dictionary)
	var id := str(e.get("id", ""))
	var need := int(e.get("per_meal", 1))
	var p: Node = _players[0]

	p.inventory = {id: need + 2}
	_surv._consume_tick()
	_check(int(p.item_count(id)) == need + 1,
			"够 → 从他背包扣掉 per_meal=%d（%d → %d）" % [need, need + 2, int(p.item_count(id))])
	_check(_surv.shortages.is_empty() and not bool(_surv.starving),
			"够 → 不算短缺（shortages=%s）" % str(_surv.shortages))

	p.inventory = {}
	_surv._consume_tick()
	_check(bool(_surv.shortage_ids(p).has(id)), "不够 → 他的 %s 记为短缺" % id)
	_check(bool(_surv.starving), "短缺时 starving = true（HUD 标红靠它）")
	_check(int(p.item_count(id)) == 0, "扣不到不会把背包扣成负数")


# ------------------------------------------------------------
# C) 短缺真的降属性
# ------------------------------------------------------------
func _c_penalties() -> void:
	_say("--- C 段：短缺降属性 ---")
	_reset()
	var p: Node = _players[0]
	var debuff: Dictionary = p.supply_penalties
	var dmg_before := float(p.trait_damage(100.0))
	var speed_before := float(p.speed)
	var range_before := float(p.attack_range_px())
	var vision_before := float(p.vision_px())

	# 让消耗失败一次 → 短缺成立
	_surv._consume_tick()
	var pen: Dictionary = p.supply_penalties
	_check(not pen.is_empty(), "短缺后玩家拿到扣减表：%s" % str(pen))
	var e: Dictionary = (_surv._supplies()[0] as Dictionary)
	var want: Dictionary = e.get("shortage_debuff", {})
	var merged_ok := true
	for k in want.keys():
		if not pen.has(k) or int(round(float(pen[k]))) != int(round(float(want[k]))):
			merged_ok = false
	_check(merged_ok, "扣减表 = 配置 shortage_debuff 合并结果（期望 %s 实得 %s）"
			% [str(want), str(pen)])

	_check(is_equal_approx(dmg_before - float(want.get("attack", 0)),
			float(p.trait_damage(100.0))),
			"攻击力真的下降：%f → %f" % [dmg_before, float(p.trait_damage(100.0))])
	_check(is_equal_approx(speed_before - float(want.get("move_speed", 0)), float(p.speed)),
			"移速真的下降：%f → %f（refresh_supply_stats 重算过）"
			% [speed_before, float(p.speed)])
	# 没配的属性必须一动不动
	_check(is_equal_approx(range_before, float(p.attack_range_px())),
			"配置里没写攻击距离 → 射程不受影响（%f）" % float(p.attack_range_px()))
	_check(is_equal_approx(vision_before, float(p.vision_px())),
			"配置里没写视野 → 视野不受影响（%f）" % float(p.vision_px()))
	# 临时角色（没被系统注入过）不该凭空变弱：不入树，只看默认值
	var fresh: Node = load("res://Scenes/Player.tscn").instantiate()
	_check((fresh.supply_penalties as Dictionary).is_empty(),
			"新建角色的扣减表默认为空")
	_check(is_equal_approx(float(fresh.trait_damage(100.0)), 100.0),
			"未被注入扣减的角色不吃惩罚（trait_damage=%f）" % float(fresh.trait_damage(100.0)))
	fresh.free()


# ------------------------------------------------------------
# D) 补上立刻还原
# ------------------------------------------------------------
func _d_recover() -> void:
	_say("--- D 段：补上物资立刻还原 ---")
	_reset()
	var e: Dictionary = (_surv._supplies()[0] as Dictionary)
	var id := str(e.get("id", ""))
	var p: Node = _players[0]
	_surv._consume_tick()
	_check(not (p.supply_penalties as Dictionary).is_empty(), "先制造短缺，扣减表非空")

	# 走真实拾取接口补货（add_loot 现在把东西交给第一名存活角色），
	# 然后**只等帧**（不手动 tick）→ 证明不用等下一分钟
	_run.add_loot(id, int(e.get("per_meal", 1)))
	_check(int(p.item_count(id)) == int(e.get("per_meal", 1)),
			"补货落到被派的那个角色身上（%s 有 %d 份）" % [str(p.character_name),
			int(p.item_count(id))])
	await _frames(3)
	_check((p.supply_penalties as Dictionary).is_empty(),
			"补货后扣减表清空（实得 %s）" % str(p.supply_penalties))
	_check(not bool(_surv.starving), "starving 归 false")
	_check(is_equal_approx(float(p.trait_damage(100.0)), 100.0 + float(p.trait_flat("attack"))),
			"攻击力还原到基础值：%f" % float(p.trait_damage(100.0)))
	_check(bool(_surv.shortages.is_empty()), "shortages 集合已清空")


# ------------------------------------------------------------
# E) 永不致死
# ------------------------------------------------------------
func _e_no_death() -> void:
	_say("--- E 段：饥饿封底不致死 ---")
	_reset()
	var floor_hp := int(Config.get_value("survival.starvation_hp_floor", 1))
	var dmg := int(Config.get_value("survival.starvation_damage", 5))
	var p: Node = _players[0]
	# 现在饥饿只打短缺的人（各吃各的）→ 先让他的消耗失败一次，短缺成立
	_surv._consume_tick()
	_check(bool(_surv.is_short(p)), "先制造短缺：只有短缺的角色才会被饥饿扣血")
	p.hp = dmg + floor_hp        # 正好一次多一点的量
	for _i in range(6):
		_surv._apply_starvation()
	_check(int(p.hp) == floor_hp,
			"反复饥饿 6 次，血量停在封底 %d 而不是 0（实得 %d，单次伤害 %d）"
			% [floor_hp, int(p.hp), dmg])
	_check(not bool(p.is_dead()), "is_dead() 仍为假：物资机制杀不死人")
	# 战斗伤害不受这条下限保护（封底只管非战斗来源）
	p.set("_invincible_timer", 0.0)
	p.set("_dodge_invincible", false)
	p.take_damage(500, Vector2.ZERO)
	_check(bool(p.is_dead()) or int(p.hp) <= 0, "敌人补刀照样能打死（下限不越权）")


# ------------------------------------------------------------
# F) 结构可扩展
# ------------------------------------------------------------
func _f_extensible() -> void:
	_say("--- F 段：加一种物资不改代码 ---")
	_reset()
	var base: Array = _surv._supplies().duplicate(true)
	var two: Array = base.duplicate(true)
	two.append({"id": "oil", "per_meal": 2, "shortage_debuff": {"attack_speed": 10}})
	Config.set_override("survival.supplies", two)

	_clear_bags()
	_surv._consume_tick()
	var p: Node = _players[0]
	var merged: Dictionary = _surv.merged_penalties()
	_check(bool(_surv.shortage_ids(p).has("oil")), "新增的油也被判为短缺（shortages=%s）"
			% str(_surv.shortages))
	_check(int(merged.get("attack_speed", 0)) == 10,
			"两种物资的扣减合并进同一张表：%s" % str(merged))
	_check(int(merged.get("attack", 0)) == 7 and int(merged.get("move_speed", 0)) == 10,
			"原有食物的扣减还在（没被第二项顶掉）")
	_check(int(p.supply_penalties.get("attack_speed", 0)) == 10, "合并结果注入到了玩家身上")

	Config.clear_override("survival.supplies")
	_reset()


# ------------------------------------------------------------
# G) 主动进食
# ------------------------------------------------------------
func _g_eat() -> void:
	_say("--- G 段：主动进食回血（吃自己包里的）---")
	_reset()
	var p: Node = _surv._heal_target()
	var heal := int(Config.get_value("survival.heal_per_food", 25))
	p.hp = 1
	p.inventory = {"food": 3}
	_surv.set("_eat_cooldown", 0.0)
	var ok: bool = _surv.eat()
	_check(ok, "有食物 + 非满血 → 按 H 进食成功")
	_check(int(p.hp) == 1 + heal, "回 %d 血（实得 HP %d）" % [heal, int(p.hp)])
	_check(int(p.item_count("food")) == 2, "进食扣掉他自己包里的 1 份食物")
	_surv.set("_eat_cooldown", 0.0)
	p.hp = int(p.max_hp)
	_check(not bool(_surv.eat()), "满血时拒绝进食（不白吃食物）")


# ------------------------------------------------------------
func _reset() -> void:
	## 回到「无短缺 + 每人背包都空」的干净起点，并让倒计时跑不完
	_surv.shortages = {}
	_surv.set("_starve_timer", 0.0)
	_surv.set("_eat_cooldown", 0.0)
	_surv.set("next_meal_in", 9999.0)
	_surv._sync_starving()
	_clear_bags()
	# 掉线保护：只留活着的角色（尸体在死亡动画结束前还挂在 player 组里，取到就是 freed 实例）
	_players = []
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q) and not bool(q.is_dead()):
			_players.append(q)
	for p in _players:
		if int(p.hp) < int(p.max_hp):
			p.hp = int(p.max_hp)


## 清空场上所有角色的背包（含结算后仍挂着的尸体，免得总账读数被污染）
func _clear_bags() -> void:
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q):
			q.inventory = {}
	_run._unassigned_loot = {}


## 兜底清场：enemy.count 已被压成 0，这里只是把漏网的敌对 AI 一并删掉
func _clear_hostiles() -> void:
	var n := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e):
			e.queue_free()
			n += 1
	_say("       已清场敌人 %d 个（探针期间不受战斗干扰）" % n)


func _backup_save() -> void:
	_save_existed = FileAccess.file_exists(SAVE_PATH)
	if _save_existed:
		_save_backup = FileAccess.get_file_as_string(SAVE_PATH)


func _restore_save() -> void:
	if _save_existed:
		var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_save_backup)
			f.close()
	elif FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))


func _finish() -> void:
	_restore_save()
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for msg in _fails:
		_say("  !! " + msg)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_supplies] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

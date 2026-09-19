extends Node
## ============================================================
## SurvivalSystem — 局内生存（每分钟消耗物资 / 短缺降属性 / 进食回血）
##
## 2026-09-14 用户定：食物"战斗用的，每分钟消耗一个单位，并且可以回复血量"。
## 2026-09-18 用户改成通用物资机制；2026-09-19 背包拆成每人一份后，
## 用户定「**各吃各的**」，四条规则：
##   · **每分钟逐项消耗**：遍历存活角色，各自按 survival.supplies 列表每项
##     从**他自己那份背包**（player.inventory）扣 per_meal 份。
##   · **短缺只降属性、不致死**：某人某项没扣到 → 只给他记下短缺，把各短缺项的
##     shortage_debuff 合并成 {"attack": 7, "move_speed": 10} 注入
##     该角色的 Player.supply_penalties 并调 refresh_supply_stats()。
##     **他补上物资当帧就还原**（见 _refresh_shortages 的解锁判定）。
##     队友背包满不影响他挨扣 —— 谁缺谁降，一人一份账。
##   · **饥饿掉血保留但封底**：仍每 starvation_interval_seconds 掉
##     starvation_damage 血，但**只掉短缺那几个人的血**，且不低于
##     survival.starvation_hp_floor（1）—— 物资系统永不把人耗死，
##     最后一滴只能由敌人补刀。
##   · **主动进食（按 H）**吃的是目标角色自己包里的食物。
##
## 短缺的判定是「上一次消耗 tick 没扣到」，不是「背包现在是空的」：
## 开局背包本来就没东西，用消耗失败当触发点才留得出第一分钟的宽限。
##
## shortages 的形状：{角色实例 id: {物资 id: true}}。按实例而不是按角色名 ——
## 同名队友得各算各的，人离场（阵亡/回基地）后那格也该自动作废。
##
## 计时走局内时间轴（乘 debug.time_scale），与倒计时/撤离点调度一致。
## 所有数值在 Data/config.json 的 survival 节点。
## accesses：Player（背包、血量、属性），不自己开倒计时；
## RunManager 只用来判「本局还在跑」。
## ============================================================

signal food_eaten(healed: int)
signal starving_changed(starving: bool)
## 短缺集合变了（{实例 id: {物资 id: true}}）。HUD 与背包弹窗读它显示
## "谁缺什么、降哪条属性"。
signal supplies_changed(shortages: Dictionary)

## 按 H 主动进食回血是食物专属；每分钟消耗哪些物资看 survival.supplies
const FOOD_ID := "food"

## Player 那边真正接线了的属性 id（= shortage_debuff 允许写的键）。
## 配了没接线的键（如 hp：中途缩上限要牵动已有血量与血条，故意没做）
## 会静默失效，所以 _ready 里体检一次喊出来。
const WIRED_STATS := ["attack", "defense", "move_speed", "vision",
		"attack_range", "attack_speed", "projectile_speed"]

## 各角色当前短缺哪些物资：{player.get_instance_id(): {res_id: true}}。
## 只有消耗失败的那个人、那一项会被记进来。
var shortages: Dictionary = {}
## 场上**有任何人**短缺（沿用旧字段名：HUD 与 starving_changed 一直在用它；
## 具体谁缺什么读 shortages / is_short()）
var starving := false
## 距下次物资消耗的剩余秒数（HUD 显示）
var next_meal_in := 60.0

var _run: Node = null
var _starve_timer := 0.0
var _eat_cooldown := 0.0


func _ready() -> void:
	add_to_group("survival_system")
	_run = get_tree().get_first_node_in_group("run_manager")
	if _run != null:
		_run.run_started.connect(_on_run_started)
	next_meal_in = _meal_interval()
	_validate_supplies()


## 主动进食键
func _unhandled_input(event: InputEvent) -> void:
	if get_tree().paused:
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.physical_keycode == int(Config.get_value("survival.eat_key", 72)):
		eat()


func _process(delta: float) -> void:
	if _run == null or _run.state != _run.State.RUNNING:
		return
	# 与局内倒计时同步加速（debug.time_scale 只影响局内时间，不影响玩家操作速度）
	var scaled := delta * float(Config.get_value("debug.time_scale", 1.0))
	if _eat_cooldown > 0.0:
		_eat_cooldown = maxf(_eat_cooldown - scaled, 0.0)
	next_meal_in -= scaled
	if next_meal_in <= 0.0:
		next_meal_in += _meal_interval()
		_consume_tick()
	_refresh_shortages()
	if starving:
		_starve_timer += scaled
		if _starve_timer >= float(Config.get_value("survival.starvation_interval_seconds", 30.0)):
			_starve_timer = 0.0
			_apply_starvation()
	else:
		_starve_timer = 0.0


func _on_run_started() -> void:
	next_meal_in = _meal_interval()
	_starve_timer = 0.0
	_eat_cooldown = 0.0
	shortages = {}
	_set_starving(false)
	_inject_penalties()


func _meal_interval() -> float:
	return float(Config.get_value("survival.meal_interval_seconds", 60.0))


## 消耗表（config survival.supplies）。写成空列表 = 这套机制整体关掉。
func _supplies() -> Array:
	var raw = Config.get_value("survival.supplies", [])
	return raw if raw is Array else []


## 到点逐项消耗：每个人只从**自己**那份背包扣。扣到 → 他不缺；扣不到 → 只给他记短缺
func _consume_tick() -> void:
	for p in _alive_players():
		var uid: int = p.get_instance_id()
		for e in _supplies():
			if not (e is Dictionary):
				continue
			var id := str((e as Dictionary).get("id", ""))
			var need := int((e as Dictionary).get("per_meal", 1))
			if id == "" or need <= 0:
				continue
			if int(p.item_count(id)) >= need:
				p.take_item(id, need)
				print("[Survival] %s 消耗 %s x%d（他身上还剩 %d）"
						% [_name(p), _display(id), need, int(p.item_count(id))])
			else:
				_mark_shortage(uid, id)
				print("[Survival] %s 的 %s 不够 %d 份，消耗失败 → 他的属性下降"
						% [_name(p), _display(id), need])
	_sync_starving()


## 记下某角色某项物资短缺（{实例 id: {物资 id: true}}）
func _mark_shortage(uid: int, id: String) -> void:
	# 必须 has 再取：缺键时 get(uid, {}) 给的是个游离的空字典，判它 "is Dictionary"
	# 恒真 → 下一行 shortages[uid] 直接踩空（probe_inventory 的 C 段抓到的）
	if not shortages.has(uid):
		shortages[uid] = {}
	(shortages[uid] as Dictionary)[id] = true


## 短缺解除：某人某项一旦存量够下一次消耗就立刻还原（不用等下一个 tick）。
## 只在集合真的变了时才重推扣减表，避免每帧刷玩家属性。
func _refresh_shortages() -> void:
	if shortages.is_empty():
		return
	var changed := false
	for uid in shortages.keys().duplicate():
		var p := _player_by_uid(int(uid))
		if p == null:
			# 尸体 / 已离场：他的短缺随之作废（属性也就不用再扣了）
			shortages.erase(uid)
			changed = true
			continue
		var s: Dictionary = shortages[uid]
		for id in s.keys().duplicate():
			if int(p.item_count(str(id))) >= _per_meal(str(id)):
				s.erase(id)
				changed = true
				print("[Survival] %s 的 %s 补上了，他的属性立即还原"
						% [_name(p), _display(str(id))])
		if s.is_empty():
			shortages.erase(uid)
	if changed:
		_sync_starving()


## 某物资每次要消耗几份（探针 / 解除判定共用；缺配置按 1 份算）
func _per_meal(id: String) -> int:
	for e in _supplies():
		if e is Dictionary and str((e as Dictionary).get("id", "")) == id:
			return maxi(int((e as Dictionary).get("per_meal", 1)), 1)
	return 1


func _sync_starving() -> void:
	_inject_penalties()
	_set_starving(not shortages.is_empty())
	supplies_changed.emit(shortages)


## 把每个人自己短缺项的 shortage_debuff 合并成一张「属性 id → 要扣的点数」表，
## 只推给他本人。多种物资同时缺同一属性 → 点数相加（各扣各的，不取最大）。
## 队友缺不缺、缺几种，与他的属性无关 —— 这是"各吃各的"的另一半。
func _inject_penalties() -> void:
	for p in _alive_players():
		p.supply_penalties = penalties_for(p)
		if p.has_method("refresh_supply_stats"):
			p.refresh_supply_stats()


## 某角色当前短缺哪些物资（["food", ...]）
func shortage_ids(p: Node) -> Array:
	if p == null or not is_instance_valid(p):
		return []
	var s: Dictionary = shortages.get(p.get_instance_id(), {})
	return s.keys()


## 某角色当前是否处于短缺状态
func is_short(p: Node) -> bool:
	return not shortage_ids(p).is_empty()


## 某角色当前该被扣的属性表（背包弹窗直接读这个，不用自己遍历配置）
func penalties_for(p: Node) -> Dictionary:
	return _merge_debuffs(shortage_ids(p))


## 全队所有短缺项合起来要扣的属性（HUD 生存行用；各人真正挨扣的看 penalties_for）
func merged_penalties() -> Dictionary:
	var all_ids: Array = []
	for s in shortages.values():
		if not (s is Dictionary):
			continue
		for id in (s as Dictionary).keys():
			if not all_ids.has(str(id)):
				all_ids.append(str(id))
	return _merge_debuffs(all_ids)


## 正在短缺的存活角色名字（HUD「短缺：枪手、弓兵」用）
func hungry_names() -> Array:
	var out: Array = []
	for p in _alive_players():
		if is_short(p):
			out.append(_name(p))
	return out


## 物资 id 列表 → 合并后的属性扣减表
func _merge_debuffs(ids: Array) -> Dictionary:
	var merged := {}
	for e in _supplies():
		if not (e is Dictionary):
			continue
		var id := str((e as Dictionary).get("id", ""))
		if not ids.has(id):
			continue
		var debuff = (e as Dictionary).get("shortage_debuff", {})
		if not (debuff is Dictionary):
			continue
		for stat in (debuff as Dictionary).keys():
			var key := str(stat)
			merged[key] = float(merged.get(key, 0.0)) + float((debuff as Dictionary)[stat])
	return merged


## 饥饿掉血：**只掉短缺那几个人**的血（各吃各的 —— 背包够的人不该替队友挨饿），
## 血量仍封在 survival.starvation_hp_floor，物资永不致死。
func _apply_starvation() -> void:
	var dmg := int(Config.get_value("survival.starvation_damage", 5))
	var floor_hp := maxi(int(Config.get_value("survival.starvation_hp_floor", 1)), 0)
	var hit: Array = []
	for p in _alive_players():
		if not is_short(p):
			continue
		if int(p.hp) > floor_hp:
			hit.append(_name(p))
			p.apply_direct_damage(dmg, floor_hp)
	if not hit.is_empty():
		print("[Survival] 饥饿：%s 各损失 %d 生命（HP 封底 %d，物资永不致死）"
				% ["、".join(hit), dmg, floor_hp])


## 主动进食：吃掉**那个人自己背包里**的 1 份食物回血。
## who 省略 = 当前被指挥的角色（按 H 的行为）。满血/无食物/冷却中都会失败。
func eat(who: Node = null) -> bool:
	if _run == null or _run.state != _run.State.RUNNING:
		return false
	if _eat_cooldown > 0.0:
		return false
	var p := who if who != null and is_instance_valid(who) else _heal_target()
	if p == null:
		return false
	if int(p.hp) >= int(p.max_hp):
		print("[Survival] %s 生命已满，无需进食" % _name(p))
		return false
	if int(p.item_count(FOOD_ID)) < 1:
		print("[Survival] %s 背包里没有食物" % _name(p))
		return false
	p.take_item(FOOD_ID, 1)
	var healed: int = p.heal(int(Config.get_value("survival.heal_per_food", 25)))
	_eat_cooldown = float(Config.get_value("survival.eat_cooldown_seconds", 1.0))
	print("[Survival] %s 进食：回复 %d 生命，HP %d/%d" % [_name(p), healed,
			int(p.hp), int(p.max_hp)])
	food_eaten.emit(healed)
	return true


func _set_starving(value: bool) -> void:
	if starving == value:
		return
	starving = value
	starving_changed.emit(starving)


## 配置体检：shortage_debuff 写了没接线的属性、或物资 id 不在 resources 里，
## 都是静默失效的坑（症状是"配了却没效果"），必须在启动时就报出来。
func _validate_supplies() -> void:
	var known = Config.get_value("resources", {})
	for e in _supplies():
		if not (e is Dictionary):
			push_warning("[Survival] survival.supplies 里有条目不是字典：%s" % str(e))
			continue
		var id := str((e as Dictionary).get("id", ""))
		if id == "":
			push_warning("[Survival] survival.supplies 有条目缺 id")
			continue
		if known is Dictionary and not (known as Dictionary).has(id):
			push_warning("[Survival] 物资 id 不在 resources 里：%s" % id)
		var debuff = (e as Dictionary).get("shortage_debuff", {})
		if not (debuff is Dictionary):
			continue
		for stat in (debuff as Dictionary).keys():
			if not WIRED_STATS.has(str(stat)):
				push_warning("[Survival] shortage_debuff 的属性没接线：%s（可用：%s）"
						% [str(stat), ", ".join(WIRED_STATS)])


## 全部存活玩家（每人一份背包，短缺扣减与饥饿掉血都按各自的那份算）
func _alive_players() -> Array:
	var out: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and not bool(p.is_dead()):
			out.append(p)
	return out


## 实例 id → 角色节点（找不到 = 已离场，短缺记录该作废）
func _player_by_uid(uid: int) -> Node:
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and p.get_instance_id() == uid:
			return p
	return null


## 日志与界面里的称呼：角色名，没名字就用"角色"兜底
func _name(p: Node) -> String:
	if p == null or not is_instance_valid(p):
		return "无人"
	var nm := str(p.get("character_name"))
	return nm if nm != "" else "角色"


## 主动进食的回血目标：优先当前被指挥的角色，否则第一名存活角色
## （吃的是**他自己**包里的食物 —— 所以给谁吃就得看谁有存货）
func _heal_target() -> Node:
	var players := _alive_players()
	if players.is_empty():
		return null
	for p in players:
		if bool(p.selected):
			return p
	return players[0]


func _display(id: String) -> String:
	return str(Config.get_value("resources.%s.name" % id, id))

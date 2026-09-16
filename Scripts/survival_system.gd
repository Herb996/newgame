extends Node
## ============================================================
## SurvivalSystem — 局内生存（食物消耗 / 饥饿 / 进食回血）
##
## 用户定（2026-09-14）：食物是"战斗用的，每分钟消耗一个单位，并且可以回复血量"。
##   · 自动进食：局内每 meal_interval_seconds（60s）消耗 food_per_meal（1）个食物，
##     时间走局内时间轴（乘 debug.time_scale），与倒计时/撤离点调度保持一致。
##   · 饥饿：背包里没食物时进入饥饿状态，每 starvation_interval_seconds 扣一次血
##     （直接扣血，不走受击硬直/击退）。
##   · 主动进食：按 H（survival.eat_key）消耗 1 食物回 heal_per_food 血，带冷却。
##
## 所有数值在 Data/config.json 的 survival 节点。
##  accesses：RunManager（背包）/ Player（血量），不自己开倒计时。
## ============================================================

signal food_eaten(healed: int)
signal starving_changed(starving: bool)

const FOOD_ID := "food"

## 是否处于饥饿状态（HUD 显示 + 持续掉血开关）
var starving := false
## 距下次自动进食的剩余秒数（HUD 显示）
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
		_meal_tick()
	if starving:
		_starve_timer += scaled
		if _starve_timer >= float(Config.get_value("survival.starvation_interval_seconds", 30.0)):
			_starve_timer = 0.0
			_apply_starvation()


func _on_run_started() -> void:
	next_meal_in = _meal_interval()
	_starve_timer = 0.0
	_eat_cooldown = 0.0
	_set_starving(false)


func _meal_interval() -> float:
	return float(Config.get_value("survival.meal_interval_seconds", 60.0))


## 到点自动进食：有食物就扣，没食物进饥饿
func _meal_tick() -> void:
	var need := int(Config.get_value("survival.food_per_meal", 1))
	if _run.consume_loot(FOOD_ID, need):
		_set_starving(false)
		print("[Survival] 自动进食：消耗食物 x%d" % need)
	else:
		_set_starving(true)
		print("[Survival] 背包没有食物，进入饥饿状态！")


func _apply_starvation() -> void:
	var players := _alive_players()
	if players.is_empty():
		return
	var dmg := int(Config.get_value("survival.starvation_damage", 5))
	for p in players:
		p.apply_direct_damage(dmg)
	print("[Survival] 饥饿：全队各损失 %d 生命" % dmg)


## 主动进食：消耗 1 食物回血（满血/无食物/冷却中都会失败）
func eat() -> bool:
	if _run == null or _run.state != _run.State.RUNNING:
		return false
	if _eat_cooldown > 0.0:
		return false
	var p := _heal_target()
	if p == null:
		return false
	if int(p.hp) >= int(p.max_hp):
		print("[Survival] 生命已满，无需进食")
		return false
	if not _run.consume_loot(FOOD_ID, 1):
		print("[Survival] 背包里没有食物")
		return false
	var healed: int = p.heal(int(Config.get_value("survival.heal_per_food", 25)))
	_eat_cooldown = float(Config.get_value("survival.eat_cooldown_seconds", 1.0))
	_set_starving(false)
	print("[Survival] 进食：回复 %d 生命，HP %d/%d" % [healed, int(p.hp), int(p.max_hp)])
	food_eaten.emit(healed)
	return true


func _set_starving(value: bool) -> void:
	if starving == value:
		return
	starving = value
	starving_changed.emit(starving)


## 全部存活玩家（小队共享同一份背包，饥饿按人扣血）
func _alive_players() -> Array:
	var out: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and not bool(p.is_dead()):
			out.append(p)
	return out


## 主动进食的回血目标：优先当前被指挥的角色，否则第一名存活角色
func _heal_target() -> Node:
	var players := _alive_players()
	if players.is_empty():
		return null
	for p in players:
		if bool(p.selected):
			return p
	return players[0]

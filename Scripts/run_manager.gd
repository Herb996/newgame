extends Node
## ============================================================
## RunManager — 局内总管家（挂在 Main 场景下）
## 职责：一局的生命周期管理。
##
## 状态机：IDLE → RUNNING → (结算) → IDLE
## 结局只有三种：
##   extracted  撤离成功：本局资源入库（Meta.bank_loot）
##   died       玩家死亡：全部丢失
##   timeout    时间耗尽：全部丢失（与死亡同罚，见 DESIGN.md）
##
## 背包（2026-09-19 起）：**每个角色一份**，存在 player.inventory。
## 本文件不再自己记账，只提供全队汇总视图 total_loot()（HUD 的「背包」栏、
## 撤离入库都读它）。add_loot() 保留是给调试/自检路径的便利入口 ——
## 它把东西交给第一名存活角色，不是「放进公共池」。
##
## 后续系统（地图生成/搜刮/敌人/撤离点）都通过本脚本的
## 公共接口接入，不要自己另开倒计时或另写结算逻辑。
## ============================================================

signal run_started
signal run_ended(result: String, banked_loot: Dictionary)

enum State { IDLE, RUNNING, ENDED }

var state: int = State.IDLE
var time_remaining: float = 0.0
## 局外养成加成注入后的局内玩家属性（由 Meta.get_run_stats() 生成）
var player_stats: Dictionary = {}
## 「场上没有角色」时 add_loot 的挂账处（debug.smoke_test 直接调用 RunManager，
## 那一刻既没进局也没角色）。正常局内永远为空 —— 别把它当第二本公共背包用。
var _unassigned_loot: Dictionary = {}


func start_run() -> void:
	if state == State.RUNNING:
		return
	_unassigned_loot = {}
	time_remaining = float(Config.get_value("session.time_limit_seconds", 3600))
	player_stats = Meta.get_run_stats()
	state = State.RUNNING
	run_started.emit()
	print("[Run] 一局开始：时长 %d 秒 | 玩家属性 %s" % [int(time_remaining), player_stats])


func _ready() -> void:
	add_to_group("run_manager")


func _process(delta: float) -> void:
	if state != State.RUNNING:
		return
	# debug.time_scale 仅加速倒计时（测试用），不影响玩家移动速度
	time_remaining -= delta * float(Config.get_value("debug.time_scale", 1.0))
	if time_remaining <= 0.0:
		_end_run("timeout")


## 搜刮系统 / 调试入口调用：把资源交给**第一名存活角色**（不再是公共池）。
## 真正的拾取归属在 loot_node.gd —— 那里按「谁走进范围」分给谁；这里只是
## 给 main.gd 的自检与 --walk-test 那类"凭空塞东西"的调试路径留个入口。
## 背包规则照旧：每种占 1 格、种类数 ≤ 该角色的 backpack_capacity()。
func add_loot(resource_id: String, amount: int) -> bool:
	if state != State.RUNNING:
		return false
	var p := carrier()
	if p == null:
		_unassigned_loot[resource_id] = int(_unassigned_loot.get(resource_id, 0)) + amount
		return true
	return p.add_item(resource_id, amount)


## 当前背包的持有者：第一名活着的主角（小队模式下队友共用同一套拾取规则）
func carrier() -> Node:
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and not bool(p.is_dead()):
			return p
	return null


## 全队背包总账（HUD「背包」栏与撤离入库读这里）。
## 每种数量 = 各人身上那份相加；阵亡者此刻背包已空（东西撒在地上了）。
func total_loot() -> Dictionary:
	var out := _unassigned_loot.duplicate()
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		for res_id in p.inventory.keys():
			out[res_id] = int(out.get(res_id, 0)) + int(p.inventory[res_id])
	return out


## 全队格数上限（局外养成注入的那一档）。每人各自享有这么多个格子。
func backpack_capacity() -> int:
	return int(player_stats.get("survival.backpack_capacity",
		Config.get_value("meta_progression.survival.backpack_capacity.base", 10)))


## 拾取成功反馈（HUD 由 main 侧监听信号刷新；此处打日志）
func loot_pickup_feedback(who: Node, resource_id: String, amount: int) -> void:
	var display: String = str(Config.get_value("resources.%s.name" % resource_id, resource_id))
	if who == null or not is_instance_valid(who):
		print("[Run] %s x%d 没入包（场上没有存活角色）" % [display, amount])
		return
	var nm := str(who.character_name)
	if nm == "":
		nm = "角色"
	print("[Run] %s 拾取 %s x%d（他 %d/%d 格 · 全队 %d 格）" % [nm, display, amount,
			who.inventory.size(), who.backpack_capacity(), total_loot().size()])


## 撤离系统调用：站够 N 秒撤离成功，资源带回基地
func extract() -> void:
	_end_run("extracted")


## 战斗系统调用：玩家死亡
func player_died() -> void:
	_end_run("died")


func _end_run(result: String) -> void:
	if state != State.RUNNING:
		return
	state = State.ENDED
	var carried := total_loot()
	var banked: Dictionary = {}
	if result == "extracted":
		banked = carried.duplicate()
		Meta.bank_loot(banked)
		# 撤离成功 = 唯一的经验来源（progression.xp.per_extraction）。
		# 发经验只认**活着的名册成员**：阵亡的已经在 player.on_death() 里除名了，
		# 这里再按 is_dead() 兜一道；没有名册身份的临时角色（命令行 / 无头回归）跳过。
		Meta.grant_xp_to_survivors()
		# 技能同一条规矩：撤离成功才把局内学会的招抄回名册（用户 2026-09-21 定）。
		# died / timeout 不会走到这里，所以「死了白学」不需要任何回滚代码。
		Meta.bank_skills_from_survivors()
	# died / timeout：banked 保持为空 —— 全员身上的东西一件都带不走
	run_ended.emit(result, banked)
	print("[Run] 一局结束：%s | 带回资源 %s | 丢弃资源 %s" % [
			result, banked, carried if banked.is_empty() else {}])
	# 保持 ENDED 状态（main 据此允许 R 返回基地），下次 start_run 可正常开局

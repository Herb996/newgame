extends Node
## ============================================================
## RunManager — 局内总管家（挂在 Main 场景下）
## 职责：一局的生命周期管理。
##
## 状态机：IDLE → RUNNING → (结算) → IDLE
## 结局只有三种：
##   extracted  撤离成功：本局资源入库（Meta.bank_loot）
##   died       玩家死亡：全部丢失
##   timeout    时间耗尽：全部丢失（与死亡同罚，见 01_GAME_DESIGN.md）
##
## 后续系统（地图生成/搜刮/敌人/撤离点）都通过本脚本的
## 公共接口接入，不要自己另开倒计时或另写结算逻辑。
## ============================================================

signal run_started
signal run_ended(result: String, banked_loot: Dictionary)

enum State { IDLE, RUNNING, ENDED }

var state: int = State.IDLE
var time_remaining: float = 0.0
## 本局已搜刮、尚未撤离确认的资源
var loot: Dictionary = {}
## 局外养成加成注入后的局内玩家属性（由 Meta.get_run_stats() 生成）
var player_stats: Dictionary = {}


func start_run() -> void:
	if state == State.RUNNING:
		return
	loot = {}
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


## 搜刮系统调用：把搜到的资源放进背包。
## 背包规则：每种物品占 1 格，物品种类数 ≤ backpack_capacity（局外升级）。
## 新种类且格子已满 → 拾取失败返回 false；已有种类继续叠加 → 成功。
func add_loot(resource_id: String, amount: int) -> bool:
	if state != State.RUNNING:
		return false
	if not loot.has(resource_id):
		var capacity := int(player_stats.get("survival.backpack_capacity",
			Config.get_value("meta_progression.survival.backpack_capacity.base", 10)))
		if loot.size() >= capacity:
			return false  # 格子满，拒绝新种类
	loot[resource_id] = int(loot.get(resource_id, 0)) + amount
	return true


## 消耗背包里的资源（食物系统用）。不足返回 false；扣到 0 时释放该格。
func consume_loot(resource_id: String, amount: int) -> bool:
	if state != State.RUNNING:
		return false
	if int(loot.get(resource_id, 0)) < amount:
		return false
	loot[resource_id] = int(loot[resource_id]) - amount
	if int(loot[resource_id]) <= 0:
		loot.erase(resource_id)   # 归零即释放背包格
	return true


## 当前背包容量（格数）
func backpack_capacity() -> int:
	return int(player_stats.get("survival.backpack_capacity",
		Config.get_value("meta_progression.survival.backpack_capacity.base", 10)))


## 拾取成功反馈（HUD 由 main 侧监听信号刷新；此处打日志）
func loot_pickup_feedback(resource_id: String, amount: int) -> void:
	var display: String = str(Config.get_value("resources.%s.name" % resource_id, resource_id))
	print("[Run] 拾取 %s x%d（背包 %d/%d 格）" % [display, amount, loot.size(), backpack_capacity()])


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
	var banked: Dictionary = {}
	if result == "extracted":
		banked = loot.duplicate()
		Meta.bank_loot(banked)
	# died / timeout：banked 保持为空 —— 全部丢失
	run_ended.emit(result, banked)
	print("[Run] 一局结束：%s | 带回资源 %s | 丢弃资源 %s" % [result, banked, loot if banked.is_empty() else {}])
	# 保持 ENDED 状态（main 据此允许 R 返回基地），下次 start_run 可正常开局

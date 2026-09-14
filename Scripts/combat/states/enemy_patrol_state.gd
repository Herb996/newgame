class_name EnemyPatrolState
extends State
## ============================================================
## EnemyPatrolState — 敌人巡逻（06_FIGHT.md 蓝图 Phase 3 基础 AI）
## 行为：在出生点附近随机游走；走到点后停留 patrol_idle_seconds 再选新点。
## 优先级：看到玩家 → 立刻切 Chase（追击）。
## 移动实现全在 enemy.gd 功能层，本状态只下命令、不碰寻路细节。
## ============================================================

var _wait := 0.0


func _init(p_actor: Node = null) -> void:
	super(&"patrol", p_actor)


func enter(_msg: Dictionary = {}) -> void:
	_wait = 0.0
	if not actor.has_move_target():
		actor.pick_patrol_target()


func physics_update(delta: float) -> void:
	if actor.can_see_player():
		request_transition(&"chase")
		return
	# 听到足够大的噪音（达到 investigate 阈值）→ 去声源调查（06_FIGHT.md 第 8 节）
	if actor.noise_alertness >= float(Config.get_value("noise.thresholds.investigate", 50.0)):
		request_transition(&"investigate")
		return
	# 到达巡逻点后的停留（模拟"站岗观察"）
	if _wait > 0.0:
		_wait -= delta
		if _wait <= 0.0:
			actor.pick_patrol_target()
		return
	if actor.follow_path(actor.patrol_speed()):
		_wait = float(Config.get_value("enemy.patrol_idle_seconds", 1.5))
		actor.clear_move_target()

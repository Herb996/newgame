class_name EnemyInvestigateState
extends State
## ============================================================
## EnemyInvestigateState — 敌人调查（06_FIGHT.md 第 8 节 噪音机制）
##
## 触发：noise_alertness 达到 investigate 阈值（默认 50），由 patrol / chase 状态切过来。
## 行为：前往最后听到的声源位置（repath_to_noise_source）；到达后原地搜索。
##   · 期间警觉度随时间衰减；衰减到 suspicious 阈值（默认 20）以下 → 放弃，回巡逻。
##   · 期间又听到新位置（不同声源）→ 更新目标再走过去。
##   · 警觉度达到 combat 阈值（默认 100）→ 用追击速度走（表现"狂暴"）。
##   · 任何时刻看到玩家 → 直接切 Chase（追击优先）。
## 复用 enemy.gd 的导航/路径接口，本状态只做决策。
## ============================================================

var _target := Vector2.ZERO
var _arrived := false


func _init(p_actor: Node = null) -> void:
	super(&"investigate", p_actor)


func enter(_msg: Dictionary = {}) -> void:
	_target = Vector2.ZERO
	_arrived = false
	_repath()


func _repath() -> void:
	var src := actor.noise_source()
	if src == Vector2.ZERO:
		return
	_target = src
	actor.repath_to_noise_source()


func physics_update(delta: float) -> void:
	# 看见玩家 → 直接追击（优先级最高）
	if actor.can_see_player():
		request_transition(&"chase")
		return
	var susp := float(Config.get_value("noise.thresholds.suspicious", 20.0))
	var inv := float(Config.get_value("noise.thresholds.investigate", 50.0))
	var combat := float(Config.get_value("noise.thresholds.combat", 100.0))
	# 警觉度衰减到疑惑阈值以下 → 放弃调查，回巡逻（"慢慢放松"）
	if actor.noise_alertness < susp:
		request_transition(&"patrol")
		return
	# 听到新的、不同位置的噪音 → 更新调查目标
	if actor.noise_alertness >= inv and actor.noise_source() != _target:
		_repath()
		_arrived = false
	var speed := actor.patrol_speed()
	if actor.noise_alertness >= combat:
		speed = actor.chase_speed()   # 狂暴：用追击速度
	if not _arrived:
		if actor.follow_path(speed):
			_arrived = true
			actor.clear_move_target()   # 到达：停下搜索，等衰减或新噪音

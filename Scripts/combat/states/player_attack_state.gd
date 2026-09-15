class_name PlayerAttackState
extends State
## ============================================================
## PlayerAttackState — 攻击状态（蓝图 Phase 1：单次轻攻击）
## 生命周期：PreCast 前摇 → Cast 判定帧 → PostCast 后摇
##   windup   前摇：不能移动、不能取消（可被受击 HitStun 打断）
##   active   判定帧：开启 Hitbox，逐帧结算命中（内部去重，同一次挥击只打一次）
##   recovery 后摇：固定时长，结束即回 Idle（本作非动作游戏，不接后摇取消/连招）
## 移动：整个攻击期间速度归零（本作偏策略，不做攻击位移）
## ============================================================

enum Phase { WINDUP, ACTIVE, RECOVERY }

var _phase: int = Phase.WINDUP
var _timer := 0.0


func _init(p_actor: Node = null) -> void:
	super(&"attack", p_actor)


func enter(_msg: Dictionary = {}) -> void:
	actor.stop_moving()
	actor.aim_at_mouse()          # 朝鼠标方向挥击
	_phase = Phase.WINDUP
	_timer = 0.0


func exit() -> void:
	actor.end_attack_hit()        # 兜底：任何原因离开都关闭判定框
	# 丢弃缓冲攻击输入：攻击离散、不连招（已移除连招派生链）
	actor.consume_input(&"attack")


func physics_update(delta: float) -> void:
	var windup := float(Config.get_value("combat.attack.windup_seconds", 0.12))
	var active := float(Config.get_value("combat.attack.active_seconds", 0.08))
	var recovery := float(Config.get_value("combat.attack.recovery_seconds", 0.2))

	_timer += delta
	actor.velocity = Vector2.ZERO
	actor.move_and_slide()

	match _phase:
		Phase.WINDUP:
			if _timer >= windup:
				_phase = Phase.ACTIVE
				_timer = 0.0
				actor.begin_attack_hit()
				# 挥击发声：惊动附近敌人（02_TECH_BUILD.md 第二部分 噪音机制）
				NoiseSystem.emit(actor.global_position,
						float(Config.get_value("noise.sources.attack", 55.0)))
		Phase.ACTIVE:
			actor.resolve_attack_hit()   # 判定帧内每帧结算（内部按目标去重）
			if _timer >= active:
				_phase = Phase.RECOVERY
				_timer = 0.0
				actor.end_attack_hit()
		Phase.RECOVERY:
			# 本作非动作游戏：攻击为离散动作，后摇结束直接回 Idle；
			# 缓冲里的攻击输入在 exit() 丢弃，避免刚结束又立刻起一击（已移除连招派生链）
			if _timer >= recovery:
				request_transition(&"idle")

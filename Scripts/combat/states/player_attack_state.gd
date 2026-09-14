class_name PlayerAttackState
extends State
## ============================================================
## PlayerAttackState — 攻击状态（蓝图 Phase 1：单次轻攻击）
## 生命周期：PreCast 前摇 → Cast 判定帧 → PostCast 后摇
##   windup   前摇：不能移动、不能取消（可被受击 HitStun 打断）
##   active   判定帧：开启 Hitbox，逐帧结算命中（内部去重，同一次挥击只打一次）
##   recovery 后摇：进入 cancel_window 后，缓冲里的攻击输入可取消后摇直接接下一击
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


func physics_update(delta: float) -> void:
	var windup := float(Config.get_value("combat.attack.windup_seconds", 0.12))
	var active := float(Config.get_value("combat.attack.active_seconds", 0.08))
	var recovery := float(Config.get_value("combat.attack.recovery_seconds", 0.2))
	var cancel_window := float(Config.get_value("combat.attack.cancel_window_seconds", 0.08))

	_timer += delta
	actor.velocity = Vector2.ZERO
	actor.move_and_slide()

		match _phase:
		Phase.WINDUP:
			if _timer >= windup:
				_phase = Phase.ACTIVE
				_timer = 0.0
				actor.begin_attack_hit()
				# 挥击发声：惊动附近敌人（06_FIGHT.md 第 8 节 噪音机制）
				NoiseSystem.emit(actor.global_position,
						float(Config.get_value("noise.sources.attack", 55.0)))
		Phase.ACTIVE:
			actor.resolve_attack_hit()   # 判定帧内每帧结算（内部按目标去重）
			if _timer >= active:
				_phase = Phase.RECOVERY
				_timer = 0.0
				actor.end_attack_hit()
		Phase.RECOVERY:
			# 取消后摇（Cancel Window）：缓冲里有攻击输入 → 立即接下一击
			if _timer >= recovery - cancel_window and actor.consume_input(&"attack"):
				enter({})
				return
			if _timer >= recovery:
				request_transition(&"idle")

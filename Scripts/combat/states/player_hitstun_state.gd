class_name PlayerHitStunState
extends State
## ============================================================
## PlayerHitStunState — 受击硬直（蓝图 Phase 1：基础受击硬直）
## 进入时：停脚但**保留移动指令**（被打断不等于作废），按击退方向做一段衰减位移。
## 硬直期间不接受新的移动/攻击输入（输入缓冲里的按键指令会在硬直结束后自然过期），
## 硬直结束 → Idle（Idle 看到还有移动目标就接着走）。
## ============================================================

var _timer := 0.0
var _knockback := Vector2.ZERO


func _init(p_actor: Node = null) -> void:
	super(&"hitstun", p_actor)


func enter(msg: Dictionary = {}) -> void:
	# 受击只停脚：玩家的点击是"站着有效"的命令，不该被一巴掌打掉
	actor.halt_in_place()
	_timer = 0.0
	_knockback = msg.get("knockback", Vector2.ZERO)


func physics_update(delta: float) -> void:
	var duration := float(Config.get_value("combat.player.hitstun_seconds", 0.25))
	_timer += delta
	# 击退：初速最大，硬直内线性衰减到 0
	actor.velocity = _knockback * maxf(1.0 - _timer / maxf(duration, 0.0001), 0.0)
	actor.move_and_slide()
	if _timer >= duration:
		request_transition(&"idle")

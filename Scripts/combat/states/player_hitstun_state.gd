class_name PlayerHitStunState
extends State
## ============================================================
## PlayerHitStunState — 受击硬直（蓝图 Phase 1：基础受击硬直）
## 进入时：停脚但**保留移动指令**（被打断不等于作废），按击退方向做一段衰减位移。
## 硬直期间不接受新的移动/攻击指令（输入缓冲里的按键指令会在硬直结束后自然过期），
## 唯一例外是冲刺：满 combat.player.dodge_cancel_after_seconds 后按冲刺即可取消硬直
## （开关 combat.player.dodge_cancel_enabled，关掉就是原来的"硬直期间完全不吃输入"）。
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
	# 冲刺取消硬直（dodge-cancel）：满 cancel_after 才认，一挨打就立刻闪 = 硬直白给。
	# 走输入缓冲，所以硬直期间按下的那一下不会丢（与 idle/move 里同一套 consume_input）。
	if bool(Config.get_value("combat.player.dodge_cancel_enabled", true)) \
			and _timer >= float(Config.get_value("combat.player.dodge_cancel_after_seconds", 0.08)) \
			and actor.can_dodge() and actor.consume_input(&"dodge"):
		request_transition(&"dodge")
		return
	# 击退：初速最大，硬直内线性衰减到 0
	actor.velocity = _knockback * maxf(1.0 - _timer / maxf(duration, 0.0001), 0.0)
	actor.move_and_slide()
	if _timer >= duration:
		request_transition(&"idle")

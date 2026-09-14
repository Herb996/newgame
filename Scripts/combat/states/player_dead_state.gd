class_name PlayerDeadState
extends State
## ============================================================
## PlayerDeadState — 死亡状态（蓝图 FSM 必含状态之一）
## 进入即调用 Player.on_death() → RunManager.player_died() 结算本局。
## 之后速度归零、不再响应任何输入，等待玩家按 R 回基地。
## ============================================================

var _death_reported := false


func _init(p_actor: Node = null) -> void:
	super(&"dead", p_actor)


func enter(_msg: Dictionary = {}) -> void:
	actor.stop_moving()
	actor.velocity = Vector2.ZERO
	actor.move_and_slide()
	if not _death_reported:
		_death_reported = true
		actor.on_death()


func physics_update(_delta: float) -> void:
	actor.velocity = Vector2.ZERO
	actor.move_and_slide()

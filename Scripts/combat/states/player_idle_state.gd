class_name PlayerIdleState
extends State
## ============================================================
## PlayerIdleState — 玩家待机状态
## 进入时立刻停下（移动是功能层的事，状态只下命令）。
## 行为优先级：攻击输入 > 冲刺输入 > 移动目标（鼠标点了地面）。
## ============================================================


func _init(p_actor: Node = null) -> void:
	super(&"idle", p_actor)


func enter(_msg: Dictionary = {}) -> void:
	actor.stop_moving()


func physics_update(_delta: float) -> void:
	# 技能优先：缓冲里有技能指令且资源/冷却允许 → 进 skill 状态
	if actor.try_cast_buffered_skill():
		return
	# 输入缓冲：先按下的指令不会被丢掉（蓝图 2.1 Input Buffer）
	if actor.consume_input(&"attack"):
		request_transition(&"attack")
		return
	if actor.can_dodge() and actor.consume_input(&"dodge"):
		request_transition(&"dodge")
		return
	if actor.has_move_target():
		request_transition(&"move")

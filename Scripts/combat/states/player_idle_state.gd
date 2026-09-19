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
	actor.halt_in_place()


func physics_update(_delta: float) -> void:
	# 玩家点过的移动指令优先于自动战斗：指令没走完就先去走，
	# 到了（或被右键取消）再恢复自动索敌，否则角色会为了眼前一只怪永远不赶路。
	if actor.has_move_target():
		request_transition(&"move")
		return
	# 自动战斗（2026-09-17）：锁定到「视野内 ∩ 攻击距离内」的敌人就自动起手，
	# 不再需要手动按攻击键。够不着的敌人不会触发 —— 角色不自动追击。
	if actor.auto_target() != null:
		request_transition(&"attack")
		return
	# 输入缓冲：先按下的指令不会被丢掉（蓝图 2.1 Input Buffer）
	if actor.can_dodge() and actor.consume_input(&"dodge"):
		request_transition(&"dodge")

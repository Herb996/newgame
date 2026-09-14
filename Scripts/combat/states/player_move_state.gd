class_name PlayerMoveState
extends State
## ============================================================
## PlayerMoveState — 玩家移动状态
## 只做两件事：跟随路径移动（调用功能层的 follow_path）、
## 目标消失/已到达时切回 Idle。
## 移动的具体实现（A* 寻路、路点推进、卡住重算）全在 player.gd，
## 状态机不感知 —— 满足蓝图"移动逻辑与状态机解耦"的要求。
## 后续加冲刺（Dodge）时：在这里判定冲刺输入 → 切 &"dodge" 即可。
## ============================================================


func _init(p_actor: Node = null) -> void:
	super(&"move", p_actor)


func physics_update(_delta: float) -> void:
	# 技能可以打断移动（进入 skill 状态时会 stop_moving）
	if actor.try_cast_buffered_skill():
		return
	# 攻击 / 冲刺可以打断移动（进入对应状态时会 stop_moving）
	if actor.consume_input(&"attack"):
		request_transition(&"attack")
		return
	if actor.can_dodge() and actor.consume_input(&"dodge"):
		request_transition(&"dodge")
		return
	if not actor.has_move_target():
		request_transition(&"idle")
		return
	actor.follow_path()

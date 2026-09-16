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


var _footstep := 0.0


func physics_update(delta: float) -> void:
	# 行走脚步声：周期性发出（比攻击/技能轻），惊动附近敌人
	_footstep += delta
	if _footstep >= float(Config.get_value("noise.footstep_interval_seconds", 0.4)):
		_footstep = 0.0
		NoiseSystem.emit(actor.global_position,
				float(Config.get_value("noise.sources.walk", 10.0)))
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

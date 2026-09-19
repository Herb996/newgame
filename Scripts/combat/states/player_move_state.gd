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
		var pos: Vector2 = actor.global_position
		# from_player=true → 计入菜单栏「当前/累积噪音」读数（脚步也算暴露度）
		NoiseSystem.emit(pos, float(Config.get_value("noise.sources.walk", 10.0)), true, actor)
		# 湿地脚步：草地/森林下雨就是湿的，同一次脚步额外出波纹 + 播水声。
		# 噪声照常发（踩水不豁免噪音暴露）。这是 0.4s 一次的低频路径，
		# 直接查组即可、不缓存（缓存反而要处理切图时 WeatherSystem 引用失效）。
		# is_wet_at 内部已判 _active，基地/未激活/无该节点时安全返回 false。
		var weather := actor.get_tree().get_first_node_in_group("weather_system")
		if weather != null:
			if weather.is_wet_at(pos):   # 邻域判定，见 weather.rain_ground.step_wet_radius_cells
				weather.on_wet_step(pos)
			else:
				weather.on_dry_step(pos)   # 干地脚步：只有闷响，不出波纹
	# 移动指令优先于自动战斗（2026-09-19 修「点十几次后控制不了」）：
	# 还带着目标点就一直走，打到一半停下来跟眼前这只对砍 = 玩家的下一次点击会被
	# attack.enter 清掉，赶路永远走不完。到点清空指令后，Idle 才恢复自动索敌。
	if not actor.has_move_target():
		request_transition(&"idle")
		return
	# 冲刺可以打断移动（进入对应状态时会停脚，但同样不丢这条移动指令）
	if actor.can_dodge() and actor.consume_input(&"dodge"):
		request_transition(&"dodge")
		return
	actor.follow_path()

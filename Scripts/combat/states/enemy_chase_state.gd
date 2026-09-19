class_name EnemyChaseState
extends State
## ============================================================
## EnemyChaseState — 敌人追击（DESIGN.md 第二部分 Phase 3 基础 AI）
## 行为：持续朝玩家寻路移动（速度 × chase_speed_multiplier，比玩家慢一点）；
##       脱离视野满 lose_sight_seconds 判定跟丢 → 回 Patrol。
## 路径按 repath_interval_seconds 节流重算（100 个敌人的 CPU 保护）。
## 隔墙看不见（enemy.vision_blocked_by_walls）：跟丢期间不再追玩家实时坐标，
## 只走向最后已知位置（last known position），走到后原地搜索直到放弃。
## ============================================================

var _lost := 0.0


func _init(p_actor: Node = null) -> void:
	super(&"chase", p_actor)


func enter(_msg: Dictionary = {}) -> void:
	_lost = 0.0
	actor.repath_to_player()
	# 发现玩家 → 咆哮，惊动附近敌人（通过噪音系统统一广播，形成"警报扩散"）
	NoiseSystem.emit(actor.global_position,
			float(Config.get_value("noise.sources.shout", 70.0)))


func physics_update(delta: float) -> void:
	if actor.can_see_player():
		_lost = 0.0
		actor.remember_player_position()
		actor.tick_repath(delta)      # 看得见才刷新到玩家实时位置
	else:
		_lost += delta
		if _lost >= float(Config.get_value("enemy.lose_sight_seconds", 3.0)):
			# 跟丢：把最后已知位置当作声源，让调查状态前往那里再搜索
			actor.set_noise_source(actor.last_known_position())
			# 仍高度警觉 → 去调查；否则直接回巡逻
			if actor.noise_alertness >= float(Config.get_value("noise.thresholds.investigate", 50.0)):
				request_transition(&"investigate")
			else:
				request_transition(&"patrol")
			return
		# 跟丢（多数是被墙挡住）：只朝最后已知位置走，不透视追踪
		if not actor.has_move_target():
			actor.repath_to_last_known()
	# 进了射程就站住：出手由 enemy.gd::_tick_attack() 负责，这里只管别再挪。
	# 分离层已经把敌人顶在接触距离外，再往前挤也只是推着玩家走；而且边走边挥会让
	# 攻击动作下一帧就被 walk 覆盖，玩家看不见"它在打我"。
	if actor.in_attack_range():
		actor.clear_move_target()
		return
	if actor.follow_path(actor.chase_speed()):
		actor.clear_move_target()  # 走到最后已知位置后停下，等放弃计时

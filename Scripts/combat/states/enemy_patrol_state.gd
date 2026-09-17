class_name EnemyPatrolState
extends State
## ============================================================
## EnemyPatrolState — 敌人巡逻（DESIGN.md 第二部分 Phase 3 基础 AI）
## 行为：走到下一个巡逻点、到达后停留 patrol_idle_seconds 再选新点。
##   「下一个点」是谁选的、在哪，按兵种的 ai.roam.mode 由 enemy.gd 决定：
##     home_radius（默认）= 出生点周围那一小片；whole_map = 整张地图（劫掠者）。
## 优先级：看到玩家 → 立刻切 Chase（追击）；听到大噪音 → Investigate（调查）。
## 成群（2026-09-17，劫掠者）：如果我是**跟随者**（群里还有别人、群主不是我），
##   本状态就只剩一件事 —— 跟上群主（actor.follow_pack_leader()）；选目标交给群主。
##   群主自己走下面那条常规路径（所以「整群一起移动」= 群主游走 + 成员跟队形）。
## 移动实现全在 enemy.gd 功能层，本状态只下命令、不碰寻路细节。
## ============================================================

var _wait := 0.0


func _init(p_actor: Node = null) -> void:
	super(&"patrol", p_actor)


## 我是不是「成群里的跟随者」。has_method 只是为了让状态机能被别的 actor 复用而不炸。
func _is_follower() -> bool:
	return actor.has_method("is_pack_follower") and bool(actor.is_pack_follower())


func enter(_msg: Dictionary = {}) -> void:
	_wait = 0.0
	if _is_follower():
		actor.follow_pack_leader()
		return
	if not actor.has_move_target():
		actor.pick_patrol_target()


func physics_update(delta: float) -> void:
	if actor.can_see_player():
		request_transition(&"chase")
		return
	# 听到足够大的噪音（达到 investigate 阈值）→ 去声源调查（DESIGN.md 第二部分 噪音机制）
	if actor.noise_alertness >= float(Config.get_value("noise.thresholds.investigate", 50.0)):
		request_transition(&"investigate")
		return
	# 成群成员：本状态只有「跟住群主」这一件事（跟到位就原地待命）
	if _is_follower():
		actor.follow_pack_leader()
		return
	# 到达巡逻点后的停留（模拟"站岗观察"）
	if _wait > 0.0:
		_wait -= delta
		if _wait <= 0.0:
			actor.pick_patrol_target()
		return
	if actor.follow_path(actor.patrol_speed()):
		_wait = float(Config.get_value("enemy.patrol_idle_seconds", 1.5))
		actor.clear_move_target()

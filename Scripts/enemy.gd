extends Area2D
## ============================================================
## Enemy — 敌人单位（功能组件层 + 巡逻/追击 AI）
##
## 分层（与 player.gd 同构）：
##   · 本文件 = 功能组件层：导航、寻路、感知、移动、受击、接触伤害
##   · Scripts/combat/states/enemy_*.gd = 行为决策层（FSM）：决定巡逻还是追击
##
## AI（2026-09-14 用户定：巡逻 + 追击）：
##   Patrol 巡逻 —— 在出生点周围 patrol_radius_cells 内随机选可达点走过去，
##                  到达后停留 patrol_idle_seconds，再选下一个点。
##   Chase  追击 —— 视野（vision_cells）内发现玩家即追，追击速度更快；
##                  脱离视野 lose_sight_seconds 后放弃，回到巡逻。
##
## 视野（2026-09-15 用户定：加墙体遮挡）：
##   can_see_player() = 距离判定 + 视线射线（沿线段按 los_step_cells 采样墙体格）。
##   隔墙看不见；跟丢后不再追玩家实时位置，只走向最后已知位置（last known position）。
##
## 掉落（2026-09-15 用户定：击杀掉落）：
##   死亡时按 enemy.drop.chance 概率在原地生成一个 LootNode（复用资源点场景），
##   种类按 enemy.drop.weights 加权随机，数量在 amount_min~amount_max 之间。
##
## 性能保护（一局 100 个敌人）：
##   1. AStarGrid2D 由 EnemySystem 构建一次，全体敌人共享（绝不每人建网格）
##   2. 追击时按 repath_interval_seconds 节流重算路径，不是每帧重算
##   3. 距玩家超过 ai_active_radius_cells 的敌人进入休眠，完全不跑 AI
## ============================================================

const DROP_SCENE := preload("res://Scenes/LootNode.tscn")

var hp := 0
var max_hp := 0
var _contact_cooldown := 0.0
var _last_known := Vector2.ZERO   # 玩家最后被看到的位置（跟丢后走这里）

# --- 导航（由 EnemySystem 注入） ---
var _walls: Array = []
var _tile_size: int = 16
var _astar: AStarGrid2D = null       # 共享网格，勿在本脚本内重建
var _home := Vector2.ZERO            # 巡逻中心（出生点）

var _path := PackedVector2Array()
var _path_index := 0
var _has_target := false
var _repath_timer := 0.0

var _player: Node2D = null
var _dormant := false
var _dormant_check := 0.0

var state_machine: StateMachine


func _ready() -> void:
	add_to_group("enemies")
	visible = false  # 初始隐藏，等雾系统第一帧判定
	max_hp = int(Config.get_value("enemy.max_hp", 40))
	hp = max_hp
	body_entered.connect(_on_body_entered)
	_home = global_position
	_init_state_machine()


func _physics_process(delta: float) -> void:
	if _contact_cooldown > 0.0:
		_contact_cooldown -= delta
	# 休眠判定（0.5 秒一次，避免每帧测量距离）
	_dormant_check += delta
	if _dormant_check >= 0.5:
		_dormant_check = 0.0
		_dormant = distance_to_player_cells() \
				> float(Config.get_value("enemy.ai_active_radius_cells", 32))
	if _dormant:
		return
	state_machine.physics_update(delta)


func _init_state_machine() -> void:
	state_machine = StateMachine.new()
	state_machine.name = "StateMachine"
	add_child(state_machine)
	state_machine.setup(self, &"patrol",
			bool(Config.get_value("debug.log_state_transitions", false)))
	state_machine.add_state(EnemyPatrolState.new(self))
	state_machine.add_state(EnemyChaseState.new(self))
	state_machine.start()


## 由 EnemySystem 调用：注入地图导航数据（共享 A* 网格）
func setup(walls: Array, tile_size: int, astar: AStarGrid2D) -> void:
	_walls = walls
	_tile_size = tile_size
	_astar = astar
	_home = global_position


# ------------------------------------------------------------
# 感知
# ------------------------------------------------------------

func _get_player() -> Node2D:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	return _player


## 与玩家的距离（单位：格）
func distance_to_player_cells() -> float:
	var p := _get_player()
	if p == null:
		return INF
	return global_position.distance_to(p.global_position) / float(_tile_size)


## 视野内是否能看到玩家 = 距离判定 + 墙体遮挡（隔墙看不见）
func can_see_player() -> bool:
	var p := _get_player()
	if p == null:
		return false
	if p.has_method("is_dead") and bool(p.is_dead()):
		return false
	var vision_px := float(Config.get_value("enemy.vision_cells", 10)) * float(_tile_size)
	if global_position.distance_to(p.global_position) > vision_px:
		return false
	if not bool(Config.get_value("enemy.vision_blocked_by_walls", true)):
		return true
	return has_line_of_sight(global_position, p.global_position)


## 视线检测：沿两点连线按 los_step_cells（格）采样，命中任一墙格即被遮挡。
## 不做物理射线（100 个敌人每帧 physics raycast 太贵），网格采样足够且廉价。
func has_line_of_sight(from: Vector2, to: Vector2) -> bool:
	if _walls.is_empty():
		return true
	var step_px := float(Config.get_value("enemy.los_step_cells", 0.35)) * float(_tile_size)
	var steps := int(from.distance_to(to) / maxf(step_px, 1.0)) + 1
	for i in range(1, steps):
		var cell := _cell_of(from.lerp(to, float(i) / float(steps)))
		if not _in_bounds(cell):
			return false
		if _walls[cell.y][cell.x]:
			return false   # 中间隔着墙 → 看不见
	return true


## 记住玩家当前位置（追击中看到玩家时每帧刷新）
func remember_player_position() -> void:
	var p := _get_player()
	if p != null:
		_last_known = p.global_position


# ------------------------------------------------------------
# 移动（功能层：只管沿路径推进，不管为什么走）
# ------------------------------------------------------------

func has_move_target() -> bool:
	return _has_target


func clear_move_target() -> void:
	_has_target = false
	_path = PackedVector2Array()
	_path_index = 0


func patrol_speed() -> float:
	return float(Config.get_value("enemy.speed", 90))


func chase_speed() -> float:
	return patrol_speed() * float(Config.get_value("enemy.chase_speed_multiplier", 1.35))


## 沿缓存路径推进；到达终点返回 true。Area2D 无 move_and_slide，直接推进坐标。
func follow_path(speed: float) -> bool:
	if not _has_target or _path.is_empty() or _path_index >= _path.size():
		return true
	var delta := get_physics_process_delta_time()
	var waypoint := _path[_path_index]
	var dir := waypoint - global_position
	if dir.length() < 4.0:
		_path_index += 1
		return _path_index >= _path.size()
	global_position += dir.normalized() * speed * delta
	return false


## 巡逻：在出生点附近随机选一个可达点
func pick_patrol_target() -> void:
	var radius := float(Config.get_value("enemy.patrol_radius_cells", 6))
	for _attempt in range(8):
		var offset := Vector2(randf_range(-radius, radius), randf_range(-radius, radius))
		if _set_path_to(_home + offset * float(_tile_size)):
			return
	clear_move_target()   # 周围选不到点（被墙包围）就原地待着


## 追击：把路径指向玩家当前位置
func repath_to_player() -> void:
	var p := _get_player()
	if p == null:
		return
	if not _set_path_to(p.global_position):
		clear_move_target()


## 跟丢后：走向最后已知位置（不再读玩家实时坐标，避免隔墙"透视追踪"）
func repath_to_last_known() -> void:
	if _last_known == Vector2.ZERO:
		return
	if not _set_path_to(_last_known):
		clear_move_target()


## 追击路径节流重算（避免每帧 A*）
func tick_repath(delta: float) -> void:
	_repath_timer += delta
	if _repath_timer >= float(Config.get_value("enemy.repath_interval_seconds", 0.4)):
		_repath_timer = 0.0
		repath_to_player()


## 计算到目标点的路径（共享网格 + 格心换算）；不可达返回 false
func _set_path_to(target: Vector2) -> bool:
	if _astar == null:
		return false
	var from := _cell_of(global_position)
	var to := _cell_of(target)
	if not _in_bounds(from) or not _in_bounds(to):
		return false
	if _walls[from.y][from.x] or _walls[to.y][to.x]:
		return false
	var ids := _astar.get_id_path(from, to)
	if ids.is_empty():
		return false
	_path = MapGenerator.ids_to_centers(ids, _tile_size)
	_path_index = 1 if _path.size() >= 2 else 0
	_has_target = true
	return true


func _cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(int(pos.x / _tile_size), int(pos.y / _tile_size))


func _in_bounds(cell: Vector2i) -> bool:
	var h: int = _walls.size()
	if h == 0:
		return false
	var w: int = _walls[0].size()
	return cell.x >= 0 and cell.y >= 0 and cell.x < w and cell.y < h


# ------------------------------------------------------------
# 战斗
# ------------------------------------------------------------

## 受到玩家攻击伤害（由 Player.resolve_attack_hit / 技能效果调用）
func take_damage(amount: int) -> void:
	if hp <= 0:
		return
	hp -= amount
	if hp <= 0:
		_die()
		return
	print("[Combat] 敌人剩余 HP %d/%d" % [hp, max_hp])


## 死亡结算：按概率掉落资源 → 移除自身
func _die() -> void:
	_spawn_drop()
	queue_free()


## 掉落：在原地生成一个资源点（复用 LootNode 场景，玩家走近自动拾取）
func _spawn_drop() -> void:
	if randf() > float(Config.get_value("enemy.drop.chance", 0.75)):
		return
	var res_id := _pick_drop_resource()
	if res_id.is_empty():
		return
	var amount: int = int(Config.get_value("enemy.drop.amount_min", 2))
	var amount_max: int = int(Config.get_value("enemy.drop.amount_max", 6))
	if amount_max > amount:
		amount = randi_range(amount, amount_max)
	var parent := get_parent()
	if parent == null:
		return
	var drop := DROP_SCENE.instantiate()
	parent.add_child(drop)
	drop.global_position = global_position
	drop.setup(res_id, amount, 0.8)   # 比地图资源点略小，便于区分
	print("[Combat] 敌人被击杀，掉落 %s x%d" % [
		str(Config.get_value("resources.%s.name" % res_id, res_id)), amount])


## 按 enemy.drop.weights 加权随机抽一种资源；未配置则退回 resources 稀有度权重
func _pick_drop_resource() -> String:
	var weights = Config.get_value("enemy.drop.weights", {})
	if not (weights is Dictionary) or (weights as Dictionary).is_empty():
		weights = {}
		for res in Config.get_value("resources", {}):
			weights[res] = 3 if str(Config.get_value("resources.%s.rarity" % res,
					"common")) == "common" else 1
	var pool: Array = []
	for res in weights:
		for i in range(int(weights[res])):
			pool.append(res)
	if pool.is_empty():
		return ""
	return str(pool[randi() % pool.size()])


## 被技能击退（蒸汽爆发）：按冲量做一段位移；接 AI 后可改为速度冲量
func apply_knockback(impulse: Vector2) -> void:
	if impulse.length() < 1.0:
		return
	global_position += impulse.normalized() * float(Config.get_value("enemy.knockback_px", 8.0))


## 玩家碰到敌人 → 接触伤害（带冷却，避免每帧掉血）
func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	if _contact_cooldown > 0.0:
		return
	if body.take_damage(int(Config.get_value("enemy.contact_damage", 10)), global_position):
		_contact_cooldown = float(Config.get_value("enemy.contact_cooldown_seconds", 1.0))

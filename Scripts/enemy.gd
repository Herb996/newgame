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
##
## 美术（2026-09-15 定：Tiny Swords 免费包）：
##   官方包没有"怪物"，用 4 个阵营/兵种单位当敌人，每人一套 idle/run/attack 帧。
##   表现层复用 PlayerAnimator（它的 parse_spec 支持"四向共用一组帧"的扁平写法），
##   所以敌人与玩家播帧逻辑完全一致，不需要第二套动画代码。
##   官方**没有受击/死亡动画** → 受击靠瞬间泛红，死亡靠缩放淡出（见 take_damage/_die）。
## ============================================================

const DROP_SCENE := preload("res://Scenes/LootNode.tscn")

var hp := 0
var max_hp := 0
var damage := 10                   # 接触伤害（由类型覆盖）
var speed_mult := 1.0              # 相对 enemy.speed 的速度倍率
var type_id := &""                 # 类型 id（调试/统计用）
var type_name := ""                # 类型中文名（HUD/调试用）
var _contact_cooldown := 0.0
var _last_known := Vector2.ZERO   # 玩家最后被看到的位置（跟丢后走这里）

# --- 表现层 ---
var _body: Sprite2D = null
var _animator: PlayerAnimator = null
var _anim_state := PlayerAnimator.Anim.IDLE
var _attack_timer := 0.0           # >0 表示正在播攻击动作，播完回 idle/walk
var _hit_flash := 0.0              # 受击泛红剩余秒数
var _dying := false                # 已进入死亡淡出，不再参与 AI/受伤

# --- 噪音警觉度（DESIGN.md 第二部分 噪音机制）---
var noise_alertness := 0.0
var _noise_source := Vector2.ZERO   # 最后听到的声源位置（调查状态前往这里）

# --- 导航（由 EnemySystem 注入） ---
var _walls: Array = []
var _tile_size: int = 16
var _astar: AStarGrid2D = null       # 共享网格，勿在本脚本内重建
var _home := Vector2.ZERO            # 巡逻中心（出生点）

var _path := PackedVector2Array()
var _path_index := 0
var _has_target := false
var _repath_timer := 0.0

var _dormant := false
var _dormant_check := 0.0

var state_machine: StateMachine


func _ready() -> void:
	add_to_group("enemies")
	visible = false  # 初始隐藏，等雾系统第一帧判定
	_body = get_node_or_null("Body") as Sprite2D
	# 兜底：类型由 setup() 注入，但 _ready 早于 setup，先用全局默认值起手
	max_hp = int(Config.get_value("enemy.max_hp", 40))
	hp = max_hp
	body_entered.connect(_on_body_entered)
	_home = global_position
	_init_state_machine()


func _physics_process(delta: float) -> void:
	if _dying:
		return                       # 死亡淡出中：不再跑 AI、不再受伤
	if _contact_cooldown > 0.0:
		_contact_cooldown -= delta
	if _attack_timer > 0.0:
		_attack_timer -= delta
	if _hit_flash > 0.0:
		_hit_flash -= delta
	# 噪音警觉度随时间衰减（听到动静→去查看→没发现→慢慢放松）
	if noise_alertness > 0.0:
		noise_alertness = maxf(0.0, noise_alertness
				- float(Config.get_value("noise.decay_per_second", 10.0)) * delta)
	# 休眠判定（0.5 秒一次，避免每帧测量距离）
	_dormant_check += delta
	if _dormant_check >= 0.5:
		_dormant_check = 0.0
	_dormant = distance_to_player_cells() \
			> float(Config.get_value("enemy.ai_active_radius_cells", 32))
	if _dormant:
		return
	state_machine.physics_update(delta)
	_update_anim(delta)
	# 染色必须在动画器之后：动画器每帧会写 modulate，放前面会被覆盖掉
	_update_alert_visual()


func _init_state_machine() -> void:
	state_machine = StateMachine.new()
	state_machine.name = "StateMachine"
	add_child(state_machine)
	state_machine.setup(self, &"patrol",
			bool(Config.get_value("debug.log_state_transitions", false)))
	state_machine.add_state(EnemyPatrolState.new(self))
	state_machine.add_state(EnemyInvestigateState.new(self))
	state_machine.add_state(EnemyChaseState.new(self))
	state_machine.start()


## 由 EnemySystem 调用：注入地图导航数据（共享 A* 网格）+ 本实例的兵种配置。
## type_cfg 为空时退化为 config 的 enemy.max_hp / enemy.contact_damage 单一敌人类型。
func setup(walls: Array, tile_size: int, astar: AStarGrid2D,
		type_cfg: Dictionary = {}) -> void:
	_walls = walls
	_tile_size = tile_size
	_astar = astar
	_home = global_position
	_apply_type(type_cfg)


## 套用兵种：属性 + 帧序列 + 脚底偏移。所有数值都能在 config 的 enemy_types 里调。
func _apply_type(type_cfg: Dictionary) -> void:
	if not type_cfg.is_empty():
		type_id = StringName(str(type_cfg.get("id", "")))
		type_name = str(type_cfg.get("name", type_cfg.get("id", "")))
		max_hp = int(type_cfg.get("hp", Config.get_value("enemy.max_hp", 40)))
		damage = int(type_cfg.get("damage", Config.get_value("enemy.contact_damage", 10)))
		speed_mult = float(type_cfg.get("speed_mult", 1.0))
	hp = max_hp

	if _body == null:
		return
	# 帧序列：enemy_types 里直接写成 idle/walk/attack 三段扁平数组，
	# 与 sprites_ts 同一套写法，PlayerAnimator.parse_spec 直接吃得下。
	var view := {
		"offset_y": float(type_cfg.get("offset_y", Config.get_value("enemy_types.offset_y", -40.0))),
		"scale": float(type_cfg.get("scale", Config.get_value("enemy_types.scale", 1.0))),
		"pixel_unit": float(type_cfg.get("pixel_unit",
				Config.get_value("enemy_types.pixel_unit", 6.0))),
	}
	var view_cfg := {
		"sprite_scale": view["scale"],
		"sprite_offset_y": view["offset_y"],
		"sprite_pixel_unit": view["pixel_unit"],
	}
	# 用 PlayerAnimator.Anim 的名字约定做键：idle / walk / attack
	var spec := {}
	for key in ["idle", "walk", "attack"]:
		if type_cfg.has(key):
			spec[key] = type_cfg[key]
	spec["fps"] = type_cfg.get("fps", {})
	_animator = PlayerAnimator.new(_body)
	_animator.load_from_config(spec, view_cfg, "")   # 空 label = 不打印（100 个会刷屏）


# ------------------------------------------------------------
# 感知
# ------------------------------------------------------------

## 最近的一名存活玩家。小队模式下感知/追击/休眠距离都按最近者算；
## 全队覆灭后返回 null（AI 自然停摆，等待超时结算）。
func _get_player() -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		if p.has_method("is_dead") and bool(p.is_dead()):
			continue
		var d: float = global_position.distance_squared_to((p as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = p
	return best


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
# 噪音感知（DESIGN.md 第二部分 噪音机制）
# ------------------------------------------------------------

## 听到一次噪音：累加警觉度并记录声源（阈值驱动状态切换在 enemy_*_state 里）
func hear_noise(source_pos: Vector2, intensity: float) -> void:
	noise_alertness = minf(noise_alertness + intensity,
			float(Config.get_value("noise.max_alertness", 150.0)))
	_noise_source = source_pos


## 调查目标位置（最后听到的声源）
func noise_source() -> Vector2:
	return _noise_source


## 写入调查目标（追击跟丢时把最后已知位置当作声源，让调查状态走向它）
func set_noise_source(pos: Vector2) -> void:
	_noise_source = pos


## 玩家最后被看到的位置（供 chase 跟丢后使用）
func last_known_position() -> Vector2:
	return _last_known


## 走向噪音声源（与 repath_to_last_known 同构，但目标来自听力）
func repath_to_noise_source() -> void:
	if _noise_source == Vector2.ZERO:
		return
	if not _set_path_to(_noise_source):
		clear_move_target()


## 表现层每帧推进：把 FSM/移动状态翻译成动画状态。
## ATTACK 优先级最高（接触伤害时短暂播放），其次是"有路径在走"→ walk，否则 idle。
func _update_anim(delta: float) -> void:
	if _animator == null:
		return
	var st := PlayerAnimator.Anim.IDLE
	if _attack_timer > 0.0:
		st = PlayerAnimator.Anim.ATTACK
	elif _has_target and not _path.is_empty():
		st = PlayerAnimator.Anim.WALK
	_anim_state = st
	# 官方单位是正面单朝向帧，四向共用；朝向参数只影响无帧状态的程序化位移
	_animator.update(delta, st, Vector2(0.0, 1.0))


## 警觉视觉反馈：本体染色（红=巡逻常态，黄=疑惑，橙=调查，亮红=看见玩家）
## 官方包没有受击帧，受击反馈只能靠"瞬间泛红"叠加在这套警觉色之上。
## 调用时机必须在 _update_anim 之后 —— 动画器每帧都会写 modulate。
func _update_alert_visual() -> void:
	if _body == null or _dying:
		return                        # 死亡淡出由 tween 独占 modulate
	var susp := float(Config.get_value("noise.thresholds.suspicious", 20.0))
	var inv := float(Config.get_value("noise.thresholds.investigate", 50.0))
	var tint := Color(1.0, 1.0, 1.0)
	if can_see_player():
		tint = Color(1.0, 0.35, 0.2)
	elif noise_alertness >= inv:
		tint = Color(1.0, 0.7, 0.2)    # 调查：橙
	elif noise_alertness >= susp:
		tint = Color(1.0, 0.9, 0.4)    # 疑惑：浅黄
	if _hit_flash > 0.0:
		var full := maxf(float(Config.get_value("enemy.hit_flash_seconds", 0.18)), 0.01)
		tint = tint.lerp(Color(1.0, 0.25, 0.2), clampf(_hit_flash / full, 0.0, 1.0))
	_body.modulate = tint


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
	return float(Config.get_value("enemy.speed", 90)) * speed_mult


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
	# 与玩家同一套兜底：被击退推进树/石格后也要能自己走出来，
	# 否则敌人会永久卡在障碍格里（A* 对 solid 起点一律返回空路径）。
	var r: int = int(Config.get_value("nav.unstick_radius_cells", 4))
	from = MapGenerator.nearest_open_cell(_walls, from, r)
	to = MapGenerator.nearest_open_cell(_walls, to, r)
	if from.x < 0 or to.x < 0:
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
	if hp <= 0 or _dying:
		return
	hp -= amount
	_hit_flash = float(Config.get_value("enemy.hit_flash_seconds", 0.18))
	if hp <= 0:
		_die()
		return


## 死亡结算：按概率掉落资源 → 淡出 → 移除自身。
## 不再"瞬间消失"：淡出期间 _dying=true，AI、受伤、接触伤害全部停摆，
## 敌人不会在倒下动画里还能打人，也不会被重复结算掉落。
func _die() -> void:
	if _dying:
		return
	_dying = true
	_spawn_drop()
	_fade_out()


## 死亡淡出：同时做 透明 / 缩小 / 下沉，读起来像"倒下了"而不是"被抠掉"。
## 时长取 0，或没有 Body 节点时，直接释放（无头跑测试更干净）。
func _fade_out() -> void:
	var dur := float(Config.get_value("enemy.death_fade_seconds", 0.45))
	if _body == null or dur <= 0.0:
		queue_free()
		return
	set_physics_process(false)     # 停止一切逻辑，只留 tween
	var tween := create_tween().set_parallel(true)
	tween.tween_property(_body, "modulate", Color(0.45, 0.45, 0.45, 0.0), dur)
	tween.tween_property(_body, "scale", _body.scale * 0.7, dur)
	tween.tween_property(_body, "position:y", _body.position.y + 12.0, dur)
	tween.chain().tween_callback(queue_free)


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


## 被击退：按冲量做一段位移
func apply_knockback(impulse: Vector2) -> void:
	if impulse.length() < 1.0:
		return
	global_position += impulse.normalized() * float(Config.get_value("enemy.knockback_px", 8.0))


## 玩家碰到敌人 → 接触伤害（带冷却，避免每帧掉血）
func _on_body_entered(body: Node) -> void:
	if _dying:
		return
	if not body.is_in_group("player"):
		return
	if _contact_cooldown > 0.0:
		return
	if body.take_damage(damage, global_position):
		_contact_cooldown = float(Config.get_value("enemy.contact_cooldown_seconds", 1.0))
		# 打中玩家的同时播一下挥击动作，让"谁在打我"一眼可辨
		_attack_timer = float(Config.get_value("enemy.attack_anim_seconds", 0.35))

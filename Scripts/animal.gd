extends Area2D
## ============================================================
## Animal — 中立生物（Tiny Swords 的羊）
##
## 为什么要有它：地图上如果只有敌人和资源点，玩家逛图时"活着的东西"只有一种，
## 野外会显得空。羊是低成本的气氛填充——游荡、吃草、被靠近就跑、打死掉食物。
##
## 行为（不需要完整 FSM，三个模式用计时器切换就够）：
##   WALK  游荡 —— 在 wander_radius_cells 内随机挑一个可走格走过去
##   GRAZE 吃草 —— 到达后低头啃草（循环动画），一段时间后继续游荡
##   IDLE  待机 —— 另一种停顿，让节奏不单调
##   FLEE  逃跑 —— 玩家进入 flee_radius_cells 就跑，持续数秒后恢复
##
## 移动（"不会卡住"的关键）：
##   不用 A*。羊只走短距离，直接用「目标点 + 逐帧直走 + 单轴滑动」：
##   每一步先检查落点格子是否可走，主方向被挡就尝试只走 x 或只走 y，
##   两边都被挡就当作到达、立刻重选目标。
##   另配一个卡住计时器（1.2 秒位移不足 4px 就重选目标）兜底。
##   比给 60 只羊各建一条 A* 路径便宜得多，而且不会出现"路径算不出→原地发呆"。
##
## 美术：Assets/Art/Sprites/Units/sheep/*.png（官方 idle/run/grass 三套）。
##   官方没有受击/死亡动画 → 受击泛红、死亡淡出（与 enemy.gd 同一套做法）。
## ============================================================

const DROP_SCENE := preload("res://Scenes/LootNode.tscn")

enum Mode { WALK, GRAZE, IDLE, FLEE }

const ARRIVE_DIST := 6.0          # 距目标小于此值算到达
const STUCK_WINDOW := 1.2         # 位移监测窗口（秒）
const STUCK_MIN_MOVE := 4.0       # 窗口内位移不足此值 → 判定卡住

var hp := 0
var max_hp := 12
var type_id := &"sheep"
var type_name := "野羊"

var _body: Sprite2D = null
var _animator: PlayerAnimator = null

var _walls: Array = []
var _tile_size: int = 64
var _player: Node2D = null

var _mode: int = Mode.WALK
var _mode_timer := 0.0
var _target := Vector2.ZERO
var _has_target := false
var _flee_dir := Vector2.ZERO
var _flee_timer := 0.0

var _hit_flash := 0.0
var _dying := false
var _stuck_timer := 0.0
var _stuck_anchor := Vector2.ZERO


func _ready() -> void:
	add_to_group("animals")
	visible = false            # 初始隐藏，等雾系统判定
	_home_anim()


## 由 AnimalSystem 注入导航网格与类型配置
func setup(walls: Array, tile_size: int, type_cfg: Dictionary = {}) -> void:
	_walls = walls
	_tile_size = tile_size
	if not type_cfg.is_empty():
		type_id = StringName(str(type_cfg.get("id", "sheep")))
		type_name = str(type_cfg.get("name", type_cfg.get("id", "sheep")))
		max_hp = int(type_cfg.get("hp", 12))
	hp = max_hp
	_apply_type_frames(type_cfg)
	_stuck_anchor = global_position
	_pick_wander_target()


# ------------------------------------------------------------
# 表现层
# ------------------------------------------------------------

func _home_anim() -> void:
	_body = get_node_or_null("Body") as Sprite2D


## 帧序列：animal_types 里 idle/walk/graze 三段扁平数组，直接交给 PlayerAnimator。
## graze 走的是动画器的 GRAZE 槽（循环），语义上就是"低头吃草"。
func _apply_type_frames(type_cfg: Dictionary) -> void:
	if _body == null:
		_home_anim()
	if _body == null:
		return
	var view_cfg := {
		"sprite_scale": float(type_cfg.get("scale",
				Config.get_value("animal_types.scale", 1.0))),
		"sprite_offset_y": float(type_cfg.get("offset_y",
				Config.get_value("animal_types.offset_y", -20.0))),
		"sprite_pixel_unit": float(type_cfg.get("pixel_unit",
				Config.get_value("animal_types.pixel_unit", 4.0))),
	}
	var spec := {}
	for key in ["idle", "walk", "graze"]:
		if type_cfg.has(key):
			spec[key] = type_cfg[key]
	spec["fps"] = type_cfg.get("fps", {})
	_animator = PlayerAnimator.new(_body)
	_animator.load_from_config(spec, view_cfg, "")


func _anim_for_mode() -> int:
	match _mode:
		Mode.GRAZE: return PlayerAnimator.Anim.GRAZE
		Mode.WALK, Mode.FLEE: return PlayerAnimator.Anim.WALK
		_: return PlayerAnimator.Anim.IDLE


# ------------------------------------------------------------
# 每帧
# ------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _dying:
		return
	if _hit_flash > 0.0:
		_hit_flash -= delta
	_mode_timer -= delta

	var player := _get_player()
	var fleeing := false
	if player != null:
		var to_player := player.global_position - global_position
		var flee_px := float(Config.get_value("animals.flee_radius_cells", 6)) * float(_tile_size)
		if to_player.length() <= flee_px:
			fleeing = true
			_flee_dir = -to_player.normalized()
			_flee_timer = 1.6      # 每次都刷新：玩家一直在旁边就一直跑

	match _mode:
		Mode.FLEE:
			fleeing = true
		_:
			if fleeing:
				_set_mode(Mode.FLEE)

	if _mode == Mode.FLEE:
		if _flee_timer <= 0.0:
			_set_mode(Mode.WALK)
			_pick_wander_target()
		else:
			_flee_timer -= delta
			_run_flee(delta)
	else:
		_run_idle_life(delta, player)

	_update_tint()
	if _animator != null:
		_animator.update(delta, _anim_for_mode(), Vector2(0.0, 1.0))


## 非逃跑状态：走到目标 → 停下吃草/待机 → 再挑下一个目标
func _run_idle_life(delta: float, _player: Node2D) -> void:
	if _mode == Mode.GRAZE or _mode == Mode.IDLE:
		if _mode_timer <= 0.0:
			_set_mode(Mode.WALK)
			_pick_wander_target()
		return
	# WALK
	if not _has_target or _move_toward(_target, _speed(), delta):
		_has_target = false
		# 走完了：交替"吃草"和"发呆"，让野外的羊不是一排同步机器
		_set_mode(Mode.GRAZE if randf() < 0.65 else Mode.IDLE)
		_mode_timer = randf_range(2.0, 5.0) if _mode == Mode.GRAZE else randf_range(1.0, 2.5)
		return
	_tick_stuck(delta)


func _run_flee(delta: float) -> void:
	var speed := _speed() * float(Config.get_value("animals.flee_speed_mult", 1.6))
	# 逃跑不看远目标，只朝"远离玩家"的方向直走；撞墙时靠单轴滑动绕开
	if _move_toward(global_position + _flee_dir * float(_tile_size) * 2.0, speed, delta):
		# 被墙顶住逃不动 → 往侧面拐一下，别原地抖
		_flee_dir = _flee_dir.orthogonal()
	_tick_stuck(delta)


func _speed() -> float:
	return float(Config.get_value("animals.speed", 240.0))


# ------------------------------------------------------------
# 移动原语（无 A*）
# ------------------------------------------------------------

## 朝目标走一步。返回 true = 已到达/走不过去（上层应重选目标）。
func _move_toward(target: Vector2, speed: float, delta: float) -> bool:
	var to := target - global_position
	if to.length() <= ARRIVE_DIST:
		return true
	var step := to.normalized() * speed * delta
	if _can_stand(global_position + step):
		global_position += step
	elif absf(step.x) > 0.01 and _can_stand(global_position + Vector2(step.x, 0.0)):
		global_position += Vector2(step.x, 0.0)      # 沿墙滑 x
	elif absf(step.y) > 0.01 and _can_stand(global_position + Vector2(0.0, step.y)):
		global_position += Vector2(0.0, step.y)      # 沿墙滑 y
	else:
		return true                                   # 死角：交给上层重选
	return false


## 落点所在格是否可站立（越界或墙 = 不可）
func _can_stand(pos: Vector2) -> bool:
	var c := Vector2i(int(pos.x / _tile_size), int(pos.y / _tile_size))
	if _walls.is_empty():
		return true
	if c.y < 0 or c.y >= _walls.size():
		return false
	if c.x < 0 or c.x >= (_walls[c.y] as Array).size():
		return false
	return not _walls[c.y][c.x]


## 卡住兜底：窗口内位移不足就立刻重选目标，避免"顶着墙来回抖"
func _tick_stuck(delta: float) -> void:
	_stuck_timer += delta
	if _stuck_timer < STUCK_WINDOW:
		return
	_stuck_timer = 0.0
	var moved := global_position.distance_to(_stuck_anchor)
	_stuck_anchor = global_position
	if moved < STUCK_MIN_MOVE:
		_set_mode(Mode.WALK)
		_pick_wander_target()


func _set_mode(m: int) -> void:
	_mode = m


## 在 wander_radius_cells 内挑一个可走的格子当目标（最多试 12 次）
func _pick_wander_target() -> void:
	var radius := float(Config.get_value("animals.wander_radius_cells", 10))
	for _attempt in range(12):
		var offset := Vector2(randf_range(-radius, radius), randf_range(-radius, radius))
		var cand := global_position + offset * float(_tile_size)
		if _can_stand(cand):
			_target = cand
			_has_target = true
			return
	_has_target = false


# ------------------------------------------------------------
# 视觉
# ------------------------------------------------------------

func _update_tint() -> void:
	if _body == null or _dying:
		return
	var tint := Color(1, 1, 1)
	if _mode == Mode.FLEE:
		tint = Color(1.0, 0.92, 0.85)     # 逃跑时略微发白，提示"它慌了"
	if _hit_flash > 0.0:
		var full := maxf(float(Config.get_value("enemy.hit_flash_seconds", 0.18)), 0.01)
		tint = tint.lerp(Color(1.0, 0.25, 0.2), clampf(_hit_flash / full, 0.0, 1.0))
	_body.modulate = tint


func _get_player() -> Node2D:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	return _player


# ------------------------------------------------------------
# 战斗
# ------------------------------------------------------------

func take_damage(amount: int) -> void:
	if hp <= 0 or _dying:
		return
	hp -= amount
	_hit_flash = float(Config.get_value("enemy.hit_flash_seconds", 0.18))
	# 被打就立刻逃（比"站着挨打"自然）
	if _mode != Mode.FLEE:
		var player := _get_player()
		if player != null:
			_flee_dir = (global_position - player.global_position).normalized()
		_set_mode(Mode.FLEE)
		_flee_timer = 2.4
	if hp <= 0:
		_die()


## 被击退：与 enemy.gd 同接口
func apply_knockback(impulse: Vector2) -> void:
	if impulse.length() < 1.0:
		return
	global_position += impulse.normalized() * float(Config.get_value("enemy.knockback_px", 32.0))


func _die() -> void:
	if _dying:
		return
	_dying = true
	_spawn_drop()
	var dur := float(Config.get_value("enemy.death_fade_seconds", 0.45))
	if _body == null or dur <= 0.0:
		queue_free()
		return
	set_physics_process(false)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(_body, "modulate", Color(0.5, 0.5, 0.5, 0.0), dur)
	tween.tween_property(_body, "scale", _body.scale * 0.7, dur)
	tween.tween_property(_body, "position:y", _body.position.y + 8.0, dur)
	tween.chain().tween_callback(queue_free)


## 掉落：按 animals.drop 生成食物资源点（复用 LootNode）
func _spawn_drop() -> void:
	if randf() > float(Config.get_value("animals.drop.chance", 0.9)):
		return
	var res_id := str(Config.get_value("animals.drop.res", "food"))
	if res_id == "":
		return
	var amount: int = int(Config.get_value("animals.drop.amount_min", 1))
	var amount_max: int = int(Config.get_value("animals.drop.amount_max", 3))
	if amount_max > amount:
		amount = randi_range(amount, amount_max)
	var parent := get_parent()
	if parent == null:
		return
	var drop := DROP_SCENE.instantiate()
	parent.add_child(drop)
	drop.global_position = global_position
	drop.setup(res_id, amount, 0.8)
	print("[Animal] %s 被击杀，掉落 %s x%d" % [type_name,
			str(Config.get_value("resources.%s.name" % res_id, res_id)), amount])

extends Node2D
## ============================================================
## Projectile — 直线弹道（远程武器普攻的判定载体）
##
## 为什么需要它：本作原来的普攻是「扇形 Hitbox 逐帧重叠检测」，被 `player_attack_state`
## 的判定帧驱动。远程武器不能复用那条路 —— 箭要飞出去、要撞墙、要在半空消失，
## 判定点必须随时间移动，而不是围着玩家转。
##
## 设计上刻意**不新增物理层**：碰撞层/掩码是全局约定，为一个弹道去改容易牵动
## 敌人、动物、瓦片三层。这里沿用工程里已有的两套现成做法：
##   · 打谁  —— 与 `player._damageable_nodes()` 同思路，直接遍历 enemies/animals 组；
##   · 撞墙  —— 与 A* 同思路，直接查 `map` 生成的 `walls` 格子表。
## 两者都是纯数据判定，**可在无头环境下逐帧断言**，不依赖物理服务器。
##
## 防穿透：单帧步长可能跨过格子（900px/s @60fps ≈ 15px）或跨过敌人，
## 所以撞墙按 ≤半格 采样、命中按「点到飞行线段的最近距离」判定，二者都与步长无关。
##
## 用法（player.gd::fire_projectile）：
##   var p := PROJECTILE.new()
##   parent.add_child(p)          # 先入树，global_position 才有效
##   p.global_position = muzzle
##   p.setup(cfg, facing, damage, _walls, _tile_size)
## 播完 / 命中 / 撞墙自行 queue_free，无需外部管理。
## ============================================================

## 可被玩家伤害的分组。**必须与 player.gd 的 DAMAGEABLE_GROUPS 保持一致**
## （player.gd 没有 class_name，无法直接引用该常量，改动时两处都要动）。
const DAMAGEABLE_GROUPS := ["enemies", "animals"]

var dir := Vector2.RIGHT
var speed := 900.0
var max_distance := 640.0
var damage := 20
var hit_radius := 16.0
var walls: Array = []
var tile_size: int = 16
## 出膛点。命中时用它当「攻击者位置」告诉挨打的敌人往哪边走
## （见 enemy.gd::alert_from_attacker）——**不能**用命中点，那就在敌人脚下。
## 由 setup() 从当时的 global_position 抓取，所以调用方必须先摆位再 setup。
var origin := Vector2.ZERO

var _travelled := 0.0
var _done := false
var _sprite: Sprite2D = null


## cfg 直接吃 config 的 combat.weapons.<id>.projectile 段
func setup(cfg: Dictionary, p_dir: Vector2, p_damage: int,
		p_walls: Array, p_tile_size: int) -> void:
	dir = p_dir.normalized() if p_dir.length() > 0.0001 else Vector2.RIGHT
	origin = global_position          # 先摆位再 setup（见 origin 的说明）
	damage = p_damage
	walls = p_walls
	tile_size = maxi(p_tile_size, 1)
	speed = float(cfg.get("speed", 900.0))
	max_distance = float(cfg.get("max_distance_px", 640.0))
	hit_radius = float(cfg.get("hit_radius_px", 16.0))

	z_index = 30
	rotation = dir.angle()          # 贴图朝速度方向；Arrow.png 在画布里居中，不用补偿
	var tex_path := str(cfg.get("texture", ""))
	if tex_path != "" and ResourceLoader.exists(tex_path):
		_sprite = Sprite2D.new()
		_sprite.name = "Icon"
		_sprite.texture = load(tex_path)
		var s := float(cfg.get("scale", 1.0))
		_sprite.scale = Vector2(s, s)
		add_child(_sprite)


func _physics_process(delta: float) -> void:
	if _done:
		return
	if speed <= 0.0 or max_distance <= 0.0:
		_finish()
		return
	var step := speed * delta
	if step <= 0.0:
		return

	var from := global_position
	var to := from + dir * step
	# 先算再动：两个判定都基于「本帧走过的线段」，与之后把位置推到哪无关
	var target := nearest_target_on_segment(from, to, hit_radius, _targets())
	var blocked := segment_hits_wall(walls, tile_size, from, to)

	global_position = to
	_travelled += step

	# 命中优先于撞墙：贴脸射击时两者可能同时成立，打中比消失更符合直觉
	if target != null:
		target.take_damage(damage)
		# 「受到攻击也要动」：告诉它这一箭是从哪飞来的（出膛点，不是命中点 ——
		# 命中点就在它脚下，拿它当声源等于没让它动）。见 enemy.gd::alert_from_attacker。
		if origin != Vector2.ZERO and target.has_method("alert_from_attacker"):
			target.call("alert_from_attacker", origin)
		# 受击视觉反馈（白闪+挤压+击退）；origin 已在上面判过非零，方向=远离箭来向
		if origin != Vector2.ZERO and target.has_method("play_hit_fx"):
			target.call("play_hit_fx", origin)
		# 命中微冻：本项目弹道只出自玩家武器，所以算"我方打出伤害"那一档
		HitStop.pulse(get_tree(), "on_deal_damage")
		_finish()
		return
	if blocked:
		_finish()
		return
	if _travelled >= max_distance:
		_finish()


func _targets() -> Array:
	var out: Array = []
	var tree := get_tree()
	if tree == null:
		return out
	for g in DAMAGEABLE_GROUPS:
		for n in tree.get_nodes_in_group(g):
			if is_instance_valid(n) and n is Node2D:
				out.append(n)
	return out


func _finish() -> void:
	if _done:
		return
	_done = true
	queue_free()


# ------------------------------------------------------------
# 纯函数判定（无状态，供无头探针直接断言）
# ------------------------------------------------------------

## 该点所在格是否阻挡。**越界视为阻挡** —— 箭不该飞出地图边界。
static func is_blocked(p_walls: Array, p_tile: int, p: Vector2) -> bool:
	if p_walls.is_empty() or p_tile <= 0:
		return false                     # 没有导航数据（灰盒/单测）时不做墙判定
	var cx := int(floor(p.x / float(p_tile)))
	var cy := int(floor(p.y / float(p_tile)))
	if cy < 0 or cy >= p_walls.size():
		return true
	var row: Array = p_walls[cy]
	if cx < 0 or cx >= row.size():
		return true
	return bool(row[cx])


## 线段是否穿墙。按 ≤半格 采样，保证单帧步长再大也不会漏掉一整格。
static func segment_hits_wall(p_walls: Array, p_tile: int,
		from: Vector2, to: Vector2) -> bool:
	if p_walls.is_empty() or p_tile <= 0:
		return false
	var seg := to - from
	var dist := seg.length()
	if dist <= 0.0001:
		return is_blocked(p_walls, p_tile, to)
	var n := maxi(1, int(ceil(dist / maxf(float(p_tile) * 0.5, 1.0))))
	for i in range(1, n + 1):
		if is_blocked(p_walls, p_tile, from + seg * (float(i) / float(n))):
			return true
	return false


## 线段半径内最近的目标（点到线段距离），没有则返回 null。
## 取「最近」而不是「第一个」：命中帧里同时压到两个目标时结果才稳定。
static func nearest_target_on_segment(from: Vector2, to: Vector2, radius: float,
		nodes: Array) -> Node:
	var best: Node = null
	var best_d := radius
	for n in nodes:
		if not is_instance_valid(n) or not (n is Node2D):
			continue
		var npos: Vector2 = (n as Node2D).global_position
		var d := npos.distance_to(Geometry2D.get_closest_point_to_segment(npos, from, to))
		if d <= best_d:
			best_d = d
			best = n
	return best


## 【瞬狙用】线段上第一个被墙挡住的采样点；没有墙则返回 null。
## 与 segment_hits_wall 相同的半格采样密度 —— 大步长也不会跳过一整格。
static func first_wall_point(p_walls: Array, p_tile: int,
		from: Vector2, to: Vector2):
	if p_walls.is_empty() or p_tile <= 0:
		return null
	var seg := to - from
	var dist := seg.length()
	if dist <= 0.0001:
		return to if is_blocked(p_walls, p_tile, to) else null
	var n := maxi(1, int(ceil(dist / maxf(float(p_tile) * 0.5, 1.0))))
	for i in range(1, n + 1):
		var p := from + seg * (float(i) / float(n))
		if is_blocked(p_walls, p_tile, p):
			return p
	return null


## 【瞬狙用】线段半径内的**全部**目标，按「沿射线的先后」排序（先挡枪线的先中）。
## 与 nearest_target_on_segment 的差别：那个只取最近一个（箭），这个要支持穿透。
static func targets_on_segment(from: Vector2, to: Vector2, radius: float,
		nodes: Array) -> Array:
	var dir := to - from
	var len2 := maxf(dir.length_squared(), 0.0001)
	var out: Array = []      # [{node, along}]
	for n in nodes:
		if not is_instance_valid(n) or not (n is Node2D):
			continue
		var npos: Vector2 = (n as Node2D).global_position
		var closest := Geometry2D.get_closest_point_to_segment(npos, from, to)
		if npos.distance_to(closest) > radius:
			continue
		out.append({"node": n, "along": (closest - from).dot(dir) / len2})
	out.sort_custom(func(a, b): return float(a["along"]) < float(b["along"]))
	var nodes_only: Array = []
	for e in out:
		nodes_only.append(e["node"])
	return nodes_only

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
##   · 打谁  —— 直接遍历 enemies/animals 两个组（与 player 的近战判定同一套分组）；
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
## 射手本体（玩家）。命中时要按它身上的吸血层数回血，所以这一发得知道自己是谁打的。
## 走独立字段而不是 setup() 的参数：普攻那一份调用与技能那一份都要顺手带上，
## 参数位一挤就得改两处签名。**箭落地时人可能已经没了**（换局/死亡回收），
## 所以用之前一律 is_instance_valid 过一遍。
## 只拿它做"回血"这一件事：伤害仍然在出膛那帧算好塞进 damage —— 见 player.gd
## 那句"不在命中帧回头找射手要武器参数"，这条规矩没被这个字段推翻。
var source: Node = null

var _travelled := 0.0
var _done := false
var _sprite: Sprite2D = null
## 弹道结束时的特效 id（命中 = fx_impact，撞墙/飞满射程 = fx_miss）。
## 空串 = 不放，与"配置里没这两个键"完全等价（EffectLibrary 见空串直接 return）。
var _fx_impact := ""
var _fx_miss := ""
## 命中后附加的状态（技能弹道用；普攻那两张表不写这两个键 → 全程空串/0，行为不变）。
## status_id 查的是 skills.statuses，与近战范围技走的是同一个 apply_status() 入口。
var _status_id := ""
var _status_def: Dictionary = {}
## >0 = 命中点周围这么多个像素内的其他目标也吃**同一发**伤害（溅射）。
var _aoe_radius := 0.0


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
	_fx_impact = str(cfg.get("fx_impact", ""))
	_fx_miss = str(cfg.get("fx_miss", ""))
	_status_id = str(cfg.get("status_id", ""))
	var sd = cfg.get("status_def", null)
	_status_def = sd if sd is Dictionary else {}
	_aoe_radius = float(cfg.get("aoe_radius_px", 0.0))

	z_index = 30
	rotation = dir.angle()          # 贴图朝速度方向；Arrow.png 在画布里居中，不用补偿
	var tex_path := str(cfg.get("texture", ""))
	if tex_path != "" and ResourceLoader.exists(tex_path):
		_sprite = Sprite2D.new()
		_sprite.name = "Icon"
		_sprite.texture = load(tex_path)
		var s := float(cfg.get("scale", 1.0))
		_sprite.scale = Vector2(s, s)
		# 可选整体染色：技能弹道借用现成箭图也能看出"这发不一样"（余烬=橙）。
		# 普攻表里没这个键 → 不调 modulate，与改动前完全一致。
		var mod := str(cfg.get("modulate", ""))
		if mod != "":
			_sprite.modulate = Color(mod)
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
		_strike(target)
		# 溅射：技能弹道（余烬弹）在命中点再扫一圈。普攻那两张表没有 aoe_radius_px
		# 这个键 → 这里恒为 0，一句都不执行，箭的行为与改动前逐帧一致。
		if _aoe_radius > 0.0:
			var r2 := _aoe_radius * _aoe_radius
			for n in _targets():
				if n == target:
					continue
				if global_position.distance_squared_to((n as Node2D).global_position) <= r2:
					_strike(n)
		# 命中微冻：本项目弹道只出自玩家武器与玩家技能，都算"我方打出伤害"那一档
		HitStop.pulse(get_tree(), "on_deal_damage")
		_spawn_fx(_fx_impact)
		_finish()
		return
	if blocked:
		_spawn_fx(_fx_miss)
		_finish()
		return
	if _travelled >= max_distance:
		_spawn_fx(_fx_miss)
		_finish()


## 打到**一个**目标：伤害 + （技能弹道才有的）状态 + 受击反馈。
## 直击与溅射共用这一句，所以"烧到的人一定被灼烧"不会因为走了第二条路径而漏掉。
func _strike(t: Node) -> void:
	t.take_damage(damage)
	# 吸血：这一发打出去多少，射手身上那层嗜血就按成数回多少（口径与范围技一致）。
	# 与下面几条同一个约定 —— 只认方法名，射手没这个方法就是不回血，不在此处特判谁。
	if source != null and is_instance_valid(source) and source.has_method("apply_lifesteal"):
		source.call("apply_lifesteal", damage)
	# 状态施加只认方法名：敌人/动物各自实现 apply_status()，没实现的就是不吃状态，
	# 弹道这边不需要知道谁是谁（与 player.gd 范围技那条路同一个约定）。
	if _status_id != "" and t.has_method("apply_status"):
		t.call("apply_status", _status_id, _status_def)
	# 「受到攻击也要动」：告诉它这一箭是从哪飞来的（出膛点，不是命中点 ——
	# 命中点就在它脚下，拿它当声源等于没让它动）。见 enemy.gd::alert_from_attacker。
	if origin != Vector2.ZERO and t.has_method("alert_from_attacker"):
		t.call("alert_from_attacker", origin)
	# 受击视觉反馈（白闪+挤压+击退）
	if origin != Vector2.ZERO and t.has_method("play_hit_fx"):
		t.call("play_hit_fx", origin)


## 弹道收尾时的特效：挂在**自己的父节点**上而不是自己身上 —— 自己这一帧就 queue_free，
## 挂下面的话特效会跟着一起消失（连一帧都看不见）。
func _spawn_fx(id: String) -> void:
	EffectLibrary.spawn(id, get_parent(), global_position, dir.angle())


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

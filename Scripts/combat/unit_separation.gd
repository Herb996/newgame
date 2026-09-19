extends Node2D
## ============================================================
## UnitSeparation — 单位轻量分离层（碰撞方案 A，用户 2026-09-19 定）
##
## 定位：**敌人/动物仍是 Area2D 传感器，follow_path() 照旧直接写坐标** ——
## 不改节点类型、不碰寻路，只在每物理帧收尾补一轮"圆-圆互推"，再把推出来的
## 位移夹回可走格（沿墙滑 x / 滑 y，与 animal.gd::_can_stand 同一套规则）。
##
## 说清楚它做不到什么：这是**软阻挡**。它能消掉"一队人叠成一个点"的主要观感，
## 但窄门口仍会挤过去 —— 真要门口堵住得换 CharacterBody2D（方案 B）或
## 网格占位（方案 C）。别把这里当成碰撞系统。
##
## 为什么按地图格分桶：单位半径 ≤ 格宽一半时，任何一对可能重叠的单位必定落在
## 3x3 邻格内，于是 100+ 单位也不用做 O(N²)。这条约束由探针按 config 实算把住
## （radius_px ≤ map.tile_size / 2），改大半径会立刻红。
##
## 为什么玩家只推别人、不被推：玩家是 CharacterBody2D，自己有 move_and_slide，
## 再被外力推一下就和点击寻路打架（手感变成"我被人潮挤着走"）。所以玩家在这一层
## 里是**不可动的墙**（absorb=1）：撞上去的单位独自承担整份重叠。
## ============================================================

## 参与分离的组（顺序即处理顺序）。玩家单列：它只当障碍，不被推动。
const GROUPS: Array = [&"enemies", &"animals"]

## 黄金角 ≈ 137.5°：同一点叠成一坨时，用它给每家算一个互不重复的脱离方向。
const GOLDEN_ANGLE_RAD := 2.399963229728653

var _walls: Array = []
var _tile: int = 64
var _radii: Dictionary = {}       # 组名(String) -> 半径 px
var _units: Array = []            # 本帧单位表：[{n, p, r, movable}]
var _buckets: Dictionary = {}     # Vector2i 格 -> Array[int]（_units 下标）
var _strength := 0.55             # 每帧从 config 现读一次，见 _physics_process
var _max_push := 8.0
var _clamp_walkable := true


## 进局时由 main.gd 注入地图数据（与其它 system 同一套 setup(map_data) 约定）。
func setup(map_data: Dictionary) -> void:
	_walls = map_data.get("walls", [])
	_tile = maxi(1, int(Config.get_value("map.tile_size", 64)))
	var rr: Dictionary = Config.get_value("combat.separation.radius_px", {})
	_radii.clear()
	for g in GROUPS:
		_radii[str(g)] = maxf(1.0, float(rr.get(str(g), 22.0)))
	_radii["player"] = maxf(1.0, float(rr.get("player", 20.0)))
	# 必须排在所有"自己写坐标"的移动之后，否则推完又被寻路覆盖一轮。
	# Godot 4 里 _process 和 _physics_process 共用 process_priority，值越大越晚跑。
	process_priority = 100


func _physics_process(_delta: float) -> void:
	# 开关每帧现读：这是这套机制唯一的总闸，关掉就该回到"完全没有分离"的老行为，
	# 不该要求重启或重新进局才生效。
	if not bool(Config.get_value("combat.separation.enabled", true)) or _walls.is_empty():
		return
	_strength = float(Config.get_value("combat.separation.strength", 0.55))
	_max_push = float(Config.get_value("combat.separation.max_push_px_per_frame", 8.0))
	_clamp_walkable = bool(Config.get_value("combat.separation.clamp_to_walkable", true))
	_gather()
	if _units.size() < 2:
		return
	for i in range(_units.size()):
		_resolve_one(i)


# ------------------------------------------------------------
## 收集本帧单位并按格分桶。死亡淡出中的单位不参与（它们已经不算活人）。
func _gather() -> void:
	_units.clear()
	_buckets.clear()
	for g in GROUPS:
		_collect(get_tree().get_nodes_in_group(g), float(_radii.get(str(g), 22.0)), true)
	if bool(Config.get_value("combat.separation.player_is_wall", true)):
		_collect(get_tree().get_nodes_in_group(&"player"), float(_radii.get("player", 20.0)), false)
	for i in range(_units.size()):
		var key := _cell(_units[i]["p"])
		if not _buckets.has(key):
			_buckets[key] = []
		_buckets[key].append(i)


func _collect(nodes: Array, radius: float, movable: bool) -> void:
	for n in nodes:
		if n == null or not is_instance_valid(n) or n.is_queued_for_deletion():
			continue
		if not (n is Node2D):
			continue
		# 两个坑：GDScript 的 get() 只收一个参数（没有带默认值的那个重载），
		# 而节点没这个属性时它返回 null —— bool(null) 在 Godot 4.7 里又直接报错。
		# 玩家就没有 _dying，所以这里必须先容住 null。
		var dying = n.get("_dying")
		if dying != null and bool(dying):
			continue
		_units.append({"n": n, "p": (n as Node2D).global_position, "r": radius, "movable": movable})


## 单位 i 被周围所有重叠单位推开，位移算完一次写回（就地更新，后面的单位看到新位置）。
func _resolve_one(i: int) -> void:
	var a: Dictionary = _units[i]
	if not bool(a["movable"]):
		return
	var pos: Vector2 = a["p"]
	var ca := _cell(pos)
	var disp := Vector2.ZERO
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			var bucket: Array = _buckets.get(Vector2i(ca.x + ox, ca.y + oy), [])
			for j in bucket:
				if int(j) == i:
					continue   # 自己不是自己的邻居
				disp += _push_from(a, _units[j], i)
	if disp == Vector2.ZERO:
		return
	_move(a, pos + disp.limit_length(_max_push))


## a 因 b 而该挪多少：方向 = b→a，大小 = 重叠比例 × 名义间距 × strength × 份额。
## 份额：两个活单位各担一半；b 是玩家这种不可动障碍时，a 独自担满。
func _push_from(a: Dictionary, b: Dictionary, i: int) -> Vector2:
	var pos_a: Vector2 = a["p"]
	var pos_b: Vector2 = b["p"]
	var min_d: float = float(a["r"]) + float(b["r"])
	var d := pos_a - pos_b
	var d2 := d.length_squared()
	if d2 > min_d * min_d:
		return Vector2.ZERO
	var dir := Vector2.ZERO
	if d2 < 0.0001:
		# 完全重合时法向算不出来 —— 按被推者的下标定一个确定方向（黄金角，保证每家的
		# 方向不重复）。不能按"对"取方向：一坨人叠在同一点时成对方向会互相抵消，
		# 那坨就永远拆不开。也不能用随机数：回归每次结论不同，"推开没推开"就判不准。
		dir = Vector2.RIGHT.rotated(float(i) * GOLDEN_ANGLE_RAD)
	else:
		dir = d / sqrt(d2)
	var overlap := 1.0 - sqrt(d2) / min_d
	var absorb := 0.5 if bool(b["movable"]) else 1.0
	return dir * overlap * min_d * _strength * absorb


## 写回位移，并把越界的落点夹回可走格（整段不行就试单轴 = 沿墙滑，都不行就原地不动）。
func _move(a: Dictionary, to: Vector2) -> void:
	if _clamp_walkable:
		var pos: Vector2 = a["p"]
		if not _can_stand(to):
			if _can_stand(Vector2(to.x, pos.y)):
				to = Vector2(to.x, pos.y)
			elif _can_stand(Vector2(pos.x, to.y)):
				to = Vector2(pos.x, to.y)
			else:
				return
	if to.distance_squared_to(a["p"]) < 0.0001:
		return
	(a["n"] as Node2D).global_position = to
	a["p"] = to


# ------------------------------------------------------------
## 落点所在格是否可站立（越界或墙 = 不可）。与 animal.gd::_can_stand 同规则：
## 这一层只管"中心别进墙"，圆的边缘压到墙脚是允许的（轻量分离，不是硬阻挡）。
func _can_stand(pos: Vector2) -> bool:
	var c := _cell(pos)
	if c.y < 0 or c.y >= _walls.size():
		return false
	var row: Array = _walls[c.y]
	if c.x < 0 or c.x >= row.size():
		return false
	return not bool(row[c.x])


func _cell(pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(pos.x / float(_tile))), int(floor(pos.y / float(_tile))))

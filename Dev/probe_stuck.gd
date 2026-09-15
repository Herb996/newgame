extends Node
## ============================================================
## probe_stuck — 「人物卡到树里」回归探针
## 运行：Godot --headless --path . Dev/probe_stuck.tscn
##
## 背景（2026-09-15 用户报："人物会卡到树里面"）
##   树/石头在 map_generator 里被标成 walls=true（寻路障碍），但**渲染成地板瓦片**，
##   而 TileSet 的碰撞只加在墙变体上 → 这些格子**没有碰撞体**。
##   后果分两层：
##     A 逻辑硬卡死：冲刺（速度×3 持续 0.22s ≈ 6.6 格）/ 击退可以把玩家推进树格，
##       之后 player._query_path 判定"起点是 solid"直接返回空路径 → 永久走不动。
##     B 视觉穿模：3D 树被缩放到 6.5 世界单位高、冠幅约 4.75 格（1 格 = 1 世界单位），
##       而它只阻挡 1 格 → 玩家站在邻格（距离 1.0）时整个人被树冠罩住。
##
## 覆盖：
##   A 阻挡装饰格统计：有多少格 walls=true 却渲染为地板（= 无碰撞体）
##   B 硬卡死复现：把玩家放进树格再下令移动，看是否永久放弃目标
##   C 点击树格：目标落在阻挡格时是否吸附到最近可走格
##   D 3D 装饰占地：每类装饰在世界里的高度与水平直径（格），是否越过邻格中心
##
## 用 _check 收集失败而不是 assert：assert 会中断 _ready 导致进程不退出。

const PLAYER_SCENE := preload("res://Scenes/Player.tscn")

const MAP_SEED := 20260915

var _fails: Array = []
var _checks := 0


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("[Probe] OK   %s" % msg)
	else:
		_fails.append(msg)
		print("[Probe] FAIL %s" % msg)


func _ready() -> void:
	seed(MAP_SEED)
	var result: Dictionary = MapGenerator.generate()
	_probe_mismatch(result)
	await _probe_hard_stuck(result)
	await _probe_click_on_tree(result)
	_probe_footprint()
	print("[Probe] ==== 共 %d 项断言，失败 %d 项 ====" % [_checks, _fails.size()])
	for m in _fails:
		print("[Probe] !! %s" % m)
	get_tree().quit(0 if _fails.is_empty() else 1)


## 等 n 个物理帧。
## 必须 await：CharacterBody2D.move_and_slide() 的默认 delta 取
## get_physics_process_delta_time()，而它在**第一个物理帧之前是 0** ——
## 同步连调 follow_path 会得到"速度有、位移恒为 0"的假失败。
func _settle(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


# ------------------------------------------------------------ A 阻挡/渲染不一致
func _probe_mismatch(result: Dictionary) -> void:
	var walls: Array = result["walls"]
	var terrain: Array = result["terrain"]
	var h: int = walls.size()
	var w: int = walls[0].size()
	var ghost := 0          # walls=true 但渲染为地板 → 无碰撞体的"幽灵墙"
	var real_wall := 0
	for y in range(h):
		for x in range(w):
			if not walls[y][x]:
				continue
			if terrain[y][x]:
				real_wall += 1
			else:
				ghost += 1
	print("[Probe] 阻挡格：真墙 %d，装饰幽灵格（无碰撞体）%d" % [real_wall, ghost])
	# 只统计数量，不断言——树/石本来就该阻挡，问题在于它们没有碰撞体
	var blocking_decor := 0
	for y in range(h):
		for x in range(w):
			if walls[y][x] and not terrain[y][x]:
				blocking_decor += 1
	_check(ghost == blocking_decor and ghost > 0,
			"A 存在 %d 个「阻挡但无碰撞」的装饰格（树/石）" % ghost)


# ------------------------------------------------------------ B 硬卡死
## 把玩家瞬移进一个树格，再下令移动到出生点。
## 修复前：_query_path 判定起点 solid → 返回空 → clear_move_target → 永久卡死。
## 修复后：应吸附到最近可走格并真的走起来。
## 注意：本函数内含 await，是协程，调用方必须 await（见 _ready）
func _probe_hard_stuck(result: Dictionary) -> void:
	var walls: Array = result["walls"]
	var terrain: Array = result["terrain"]
	var tile: int = int(Config.get_value("map.tile_size", 16))
	var h: int = walls.size()
	var w: int = walls[0].size()

	# 找一个离出生点不算太远的树格（太远的话修复后要走很久，探针只关心"有没有在动"）
	var center := Vector2i(w / 2, h / 2)
	var target_cell := Vector2i(-1, -1)
	var best_d := 999999
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			if not (walls[y][x] and not terrain[y][x]):
				continue
			var d: int = abs(x - center.x) + abs(y - center.y)
			if d < best_d:
				best_d = d
				target_cell = Vector2i(x, y)
	if target_cell.x < 0:
		_check(false, "B 地图里找不到阻挡装饰格，无法复现")
		return

	var p: CharacterBody2D = PLAYER_SCENE.instantiate()
	add_child(p)
	p.setup_navigation(walls, tile, result.get("speed_mult", []))
	p.global_position = Vector2(target_cell) * float(tile) + Vector2(tile * 0.5, tile * 0.5)

	var start := p.global_position
	p.set_move_target(start + Vector2(0.0, -float(tile) * 6.0))   # 往上方 6 格下令
	p.follow_path()
	var kept: bool = p.has_move_target()
	for i in range(30):
		await get_tree().physics_frame
	var moved: float = p.global_position.distance_to(start)
	print("[Probe] 起点在阻挡格：保留目标=%s，30 物理帧后位移 %.2f px" % [
			str(kept), moved])
	_check(kept, "B 玩家身处阻挡格时仍能接受移动指令（不再永久放弃）")
	_check(moved > 4.0, "B 玩家身处阻挡格时能真的挪动（位移 %.2f px）" % moved)
	p.queue_free()


# ------------------------------------------------------------ C 点击树格
## 3D 里点地面用射线打 y=0 平面，点中树是很常见的操作。
## 修复前：目标格 solid → 空路径 → 角色一动不动，玩家以为点坏了。
## 注意：本函数内含 await，是协程，调用方必须 await（见 _ready）
func _probe_click_on_tree(result: Dictionary) -> void:
	var walls: Array = result["walls"]
	var terrain: Array = result["terrain"]
	var tile: int = int(Config.get_value("map.tile_size", 16))
	var h: int = walls.size()
	var w: int = walls[0].size()
	var center := Vector2i(w / 2, h / 2)
	var spawn := Vector2(center) * float(tile) + Vector2(tile * 0.5, tile * 0.5)

	var tree_cell := Vector2i(-1, -1)
	var best_d := 999999
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			if not (walls[y][x] and not terrain[y][x]):
				continue
			var d: int = abs(x - center.x) + abs(y - center.y)
			if d < best_d:
				best_d = d
				tree_cell = Vector2i(x, y)
	if tree_cell.x < 0:
		_check(false, "C 地图里找不到树格")
		return

	var p: CharacterBody2D = PLAYER_SCENE.instantiate()
	add_child(p)
	p.setup_navigation(walls, tile, result.get("speed_mult", []))
	p.global_position = spawn
	p.set_move_target(Vector2(tree_cell) * float(tile) + Vector2(tile * 0.5, tile * 0.5))
	p.follow_path()
	var kept: bool = p.has_move_target()
	var p0 := p.global_position
	for i in range(20):
		await get_tree().physics_frame
	var moved: float = p.global_position.distance_to(p0)
	print("[Probe] 点击树格 %s：保留目标=%s，20 物理帧后位移 %.2f px" % [
			str(tree_cell), str(kept), moved])
	_check(kept, "C 点击树/石时吸附到最近可走格（而不是原地不动）")
	_check(moved > 2.0, "C 点击树/石后确实走了起来（位移 %.2f px）" % moved)
	p.queue_free()


# ------------------------------------------------------------ D 3D 装饰占地
## 1 格 = 1 世界单位（坐标桥接：3D 单位 = 2D 像素 / tile_size）。
## 装饰的水平直径必须 < 2 格，否则站在邻格中心的玩家（距离 1.0）会被罩进去。
func _probe_footprint() -> void:
	for kind in [MapGenerator.DECOR_TREE, MapGenerator.DECOR_ROCK,
			MapGenerator.DECOR_DEBRIS]:
		var sz: Vector2 = MapRender3D.decor_world_size(kind)
		print("[Probe] 装饰 kind=%d 世界高 %.2f / 水平直径 %.2f 格" % [
				kind, sz.x, sz.y])
		if kind == MapGenerator.DECOR_DEBRIS:
			continue          # 残骸不阻挡，占地大无所谓
		_check(sz.y < 2.0, "D kind=%d 水平直径 %.2f 格 < 2 格（不会罩住邻格玩家）" % [
				kind, sz.y])

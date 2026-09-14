extends Node
## ============================================================
## ExtractionSystem — 撤离点调度（挂在 Main 下）
## 按局内经过时间执行时间轴（全部读 Data/config.json 的 extraction 节点）：
##   spawn_at_minutes（30 分钟）    ：随机开启 count（3）个撤离点，弹出小地图
##   close_one_at_minutes（45, 55） ：按"生成时预定"的顺序各关闭 1 个
##   最后一个撤离点保持开放至超时（60 分钟 = 死亡，由 RunManager 处理）
##
## 关闭顺序：撤离点生成时就洗牌定好（_close_order），不是到点才随机。
## 关闭保护：轮到关闭的点若玩家正在圈内，则改关顺序中的下一个；
## 全都有玩家在场则本轮作废。
## 小地图：开启时弹出 duration_seconds；每次关闭前
## warn_before_close_seconds 再弹出，并高亮即将关闭的点。
## ============================================================

const POINT_SCENE := preload("res://Scenes/ExtractionPoint.tscn")

var game_root: Node2D
var walls: Array = []
var reachable: Array = []
var tile_size := 16
var map_w := 0
var map_h := 0
var spawn_cell := Vector2i.ZERO

var points: Array = []
var _close_order: Array = []  # 预定的关闭顺序（生成时洗牌确定）
var _run: Node
var _minimap: CanvasLayer
var _spawn_time := 0.0
var _close_times: Array = []
var _spawned := false
var _close_idx := 0
var _warn_idx := 0


func _ready() -> void:
	_run = get_tree().get_first_node_in_group("run_manager")


## 由 main.gd 在地图生成后调用，传入 MapGenerator 的结果
func setup(root: Node2D, map_data: Dictionary) -> void:
	# 跨局状态全部重置（每局都是全新撤离点）
	points.clear()
	_close_order.clear()
	_spawned = false
	_close_idx = 0
	_warn_idx = 0
	game_root = root
	walls = map_data["walls"]
	reachable = map_data["reachable"]
	tile_size = int(map_data["tile_size"])
	spawn_cell = map_data["spawn_cell"]
	map_w = int(walls[0].size())
	map_h = int(walls.size())
	_spawn_time = float(Config.get_value("extraction.spawn_at_minutes", 30)) * 60.0
	_close_times.clear()
	for m in Config.get_value("extraction.close_one_at_minutes", [45, 55]):
		_close_times.append(float(m) * 60.0)


func _process(_delta: float) -> void:
	if _run == null or _run.state != _run.State.RUNNING:
		return
	if _minimap == null:
		_minimap = get_tree().get_first_node_in_group("minimap")

	var limit := float(Config.get_value("session.time_limit_seconds", 3600))
	var elapsed: float = limit - float(_run.time_remaining)

	if not _spawned and elapsed >= _spawn_time:
		_spawn_points()

	if not _spawned:
		return

	# 关闭前预警：弹小地图并高亮即将关闭的点
	var warn_before := float(Config.get_value("extraction.minimap.warn_before_close_seconds", 60))
	while _warn_idx < _close_times.size() and elapsed >= _close_times[_warn_idx] - warn_before:
		_warn_next_close()
		_warn_idx += 1

	# 到点关闭（按预定顺序）
	while _close_idx < _close_times.size() and elapsed >= _close_times[_close_idx]:
		_close_scheduled()
		_close_idx += 1


func _spawn_points() -> void:
	_spawned = true
	var count := int(Config.get_value("extraction.count", 3))
	var min_d_spawn := float(Config.get_value("extraction.min_distance_from_spawn_cells", 24))
	var min_d_between := float(Config.get_value("extraction.min_distance_between_points_cells", 28))
	var tries := 0
	while points.size() < count and tries < 3000:
		tries += 1
		if tries == 1500:
			# 空间不足时放宽一半距离约束，保证一定刷得出来
			min_d_spawn *= 0.5
			min_d_between *= 0.5
		var c := Vector2i(randi() % map_w, randi() % map_h)
		# 只刷在可达地板格上（从出生点洪水填充判定），保证玩家走得通
		if walls[c.y][c.x] or not reachable[c.y][c.x]:
			continue
		if Vector2(c).distance_to(Vector2(spawn_cell)) < min_d_spawn:
			continue
		var too_close := false
		for p in points:
			if Vector2(c).distance_to(p.position / tile_size) < min_d_between:
				too_close = true
				break
		if too_close:
			continue
		var pt := POINT_SCENE.instantiate()
		pt.position = Vector2(c) * tile_size + Vector2(tile_size * 0.5, tile_size * 0.5)
		game_root.add_child(pt)
		pt.open()
		points.append(pt)

	# 生成时即预定关闭顺序（洗牌），后续按此顺序关闭
	_close_order = points.duplicate()
	_close_order.shuffle()

	print("[Extraction] 撤离点已开启：%d 个（局内 %.0f 分钟），关闭顺序已预定" % [
		points.size(), _spawn_time / 60.0])
	if _minimap != null:
		_minimap.show_for(float(Config.get_value("extraction.minimap.duration_seconds", 60)))


## 关闭前预警：弹出小地图并高亮预定关闭的下一个点
func _warn_next_close() -> void:
	if _close_order.is_empty():
		return
	var pt: Node2D = _close_order[0]
	if not pt.is_open:
		return
	if _minimap != null:
		_minimap.show_for(
			float(Config.get_value("extraction.minimap.duration_seconds", 60)), pt)
	print("[Extraction] 预警：%.0f 分钟后关闭一个撤离点（小地图已弹出）" % [
		float(Config.get_value("extraction.minimap.warn_before_close_seconds", 60)) / 60.0])


## 到点关闭：按预定顺序取第一个"开放且玩家不在圈内"的点
## （玩家正站在轮到的点上时，改关下一个；全都有人则本轮作废）
func _close_scheduled() -> void:
	var idx := -1
	for i in range(_close_order.size()):
		var p: Node2D = _close_order[i]
		if p.is_open and not p.has_player_inside():
			idx = i
			break
	if idx == -1:
		print("[Extraction] 所有开放撤离点都有玩家在场，本轮关闭作废")
		return
	var pt: Node2D = _close_order[idx]
	_close_order.remove_at(idx)
	pt.close()
	var remain: int = points.filter(func(p): return p.is_open).size()
	print("[Extraction] 按预定顺序关闭 1 个撤离点，剩余 %d 个" % remain)

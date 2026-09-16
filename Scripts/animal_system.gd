extends Node
## ============================================================
## AnimalSystem — 中立生物生成（挂在 Main 下）
## 规则（Data/config.json 的 animals / animal_types 节点）：
##   animals.count                     一局生成数量
##   animals.min_distance_from_player_cells  距玩家出生点下限
##   animal_types.types[*].weight      抽样权重
## 只刷在「可达地板」上（不可达区域的羊玩家永远看不到，纯浪费）。
##
## 与 EnemySystem 的区别：羊不需要共享 A*（它们不做长距离寻路，
## 见 animal.gd 的"直走 + 单轴滑动"），所以这里不构建网格，只注入墙体。
## ============================================================

const ANIMAL_SCENE := preload("res://Scenes/Animal.tscn")


## 由 main.gd 在地图生成后调用，传入 MapGenerator 的结果
func setup(root: Node2D, map_data: Dictionary) -> void:
	var walls: Array = map_data["walls"]
	var reachable: Array = map_data["reachable"]
	var tile_size: int = int(map_data["tile_size"])
	var spawn_cell: Vector2i = map_data["spawn_cell"]
	var map_w: int = walls[0].size()
	var map_h: int = walls.size()

	var count := int(Config.get_value("animals.count", 60))
	if count <= 0:
		return
	var min_d := float(Config.get_value("animals.min_distance_from_player_cells", 10))

	var candidates: Array = []
	for y in range(map_h):
		for x in range(map_w):
			if walls[y][x] or not reachable[y][x]:
				continue
			if Vector2(x, y).distance_to(Vector2(spawn_cell)) < min_d:
				continue
			candidates.append(Vector2i(x, y))

	if candidates.size() < count:
		push_warning("[Animal] 合法格不足（%d < %d），只生成 %d 个" % [
			candidates.size(), count, candidates.size()])
		count = candidates.size()

	var types := _type_pool()
	var tally := {}

	candidates.shuffle()
	for i in range(count):
		var c: Vector2i = candidates[i]
		var animal := ANIMAL_SCENE.instantiate()
		animal.position = Vector2(c) * tile_size + Vector2(tile_size * 0.5, tile_size * 0.5)
		root.add_child(animal)
		var t: Dictionary = types[randi() % types.size()]
		animal.setup(walls, tile_size, t)
		var tid := str(t.get("id", "?"))
		tally[tid] = int(tally.get(tid, 0)) + 1

	print("[Animal] 中立生物生成完成：%d 个（距出生点 ≥ %.0f 格）｜种类 %s"
			% [count, min_d, str(tally)])


## 按 animal_types.types[*].weight 展开抽样池。
## 注意：这里**不能**像 EnemySystem 那样在空配置时塞一个匿名 {}——
## 羊没有贴图就是纯白方块，宁可一个都不生成。
func _type_pool() -> Array:
	var out: Array = []
	for t in Config.get_value("animal_types.types", []):
		if not (t is Dictionary):
			continue
		var d: Dictionary = t
		if not d.has("id"):
			continue
		var w: int = maxi(1, int(d.get("weight", 1)))
		for _k in range(w):
			out.append(d)
	return out

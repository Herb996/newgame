extends Node
## ============================================================
## LootSystem — 资源点生成（挂在 Main 下）
## 规则（Data/config.json 的 loot 节点）：
##   density：资源点占可达地板格的比例（0.05 ≈ 128 图约 300+ 个）
##   amount_per_node：每个点拾取获得的单位数（10）
## 每个点随机绑定一种资源（resources 节点定义的全部种类，
## 按 rarity 加权：common 权重高、rare 权重低）。
## 只刷在可达格内（与撤离点/敌人一致）。
## ============================================================

const NODE_SCENE := preload("res://Scenes/LootNode.tscn")


## 由 main.gd 在地图生成后调用
func setup(root: Node2D, map_data: Dictionary) -> void:
	var walls: Array = map_data["walls"]
	var reachable: Array = map_data["reachable"]
	var tile_size: int = int(map_data["tile_size"])
	var map_w: int = walls[0].size()
	var map_h: int = walls.size()
	var density := float(Config.get_value("loot.density", 0.05))

	# 收集可达地板格
	var candidates: Array = []
	for y in range(map_h):
		for x in range(map_w):
			if not walls[y][x] and reachable[y][x]:
				candidates.append(Vector2i(x, y))
	candidates.shuffle()

	# 按 density 抽取生成数量
	var count := int(roundf(candidates.size() * density))

	# 资源池（按 rarity 加权：common 3 份 / rare 1 份）
	var pool: Array = []
	var kind_count := 0
	for res in Config.get_value("resources", {}):
		kind_count += 1
		var weight := 3 if str(Config.get_value("resources.%s.rarity" % res, "common")) == "common" else 1
		for i in range(weight):
			pool.append(res)

	for i in range(count):
		var c: Vector2i = candidates[i]
		var node := NODE_SCENE.instantiate()
		node.position = Vector2(c) * tile_size + Vector2(tile_size * 0.5, tile_size * 0.5)
		root.add_child(node)
		node.setup(pool[randi() % pool.size()])

	print("[Loot] 资源点生成完成：%d 个（密度 %.0f%%，%d 种资源按稀有度加权）" % [
		count, density * 100.0, kind_count])

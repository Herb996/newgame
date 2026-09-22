extends Node
## ============================================================
## LootSystem — 资源点生成（挂在 Main 下）
## 规则（Data/config/ 的 loot 节点）：
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

	var spawn_px: Vector2 = map_data.get("spawn", Vector2.ZERO)
	var books := _spawn_grimoires(root, candidates, count, spawn_px, tile_size)

	print("[Loot] 资源点生成完成：%d 个（密度 %.0f%%，%d 种资源按稀有度加权）+ 魔法书 %d 本" % [
		count, density * 100.0, kind_count, books])


## 魔法书掉在**没被资源点用掉**的格子上（candidates 已经洗过牌，所以位置天然随机）。
## 数量、离出生点的最小距离都在 skills.grimoire 里；nodes_per_run<=0 就是这局没有书。
## 刻意离出生点远：出门两步就捡到书 = 技能白送，走一段路才有取舍。
func _spawn_grimoires(root: Node2D, candidates: Array, used: int, spawn_px: Vector2,
		tile_size: int) -> int:
	var want := int(Config.get_value("skills.grimoire.nodes_per_run", 0))
	if want <= 0:
		return 0
	var min_cells := float(Config.get_value("skills.grimoire.min_distance_from_spawn_cells", 0.0))
	var spawn_cell := spawn_px / float(tile_size)
	var made := 0
	for i in range(used, candidates.size()):
		if made >= want:
			break
		var c: Vector2i = candidates[i]
		if Vector2(float(c.x - int(spawn_cell.x)), float(c.y - int(spawn_cell.y))).length() < min_cells:
			continue
		var node := NODE_SCENE.instantiate()
		node.position = Vector2(c) * tile_size + Vector2(tile_size * 0.5, tile_size * 0.5)
		root.add_child(node)
		node.setup_grimoire()
		made += 1
	if made < want:
		push_warning("[Loot] 魔法书只放下 %d/%d 本（可达空格不够远或不够多）" % [made, want])
	return made

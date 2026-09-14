extends Node
## ============================================================
## EnemySystem — 敌人生成（挂在 Main 下）
## 规则（Data/config.json 的 enemy 节点）：
##   count：一局生成数量（100）
##   min_distance_from_player_cells：距玩家出生点 ≥ 20 格
## 只刷在地板格上，位置不重复（先收集所有合法格再随机抽取）。
## 敌人 AI = 巡逻 + 追击（2026-09-14 用户定）：由 enemy.gd + enemy_*_state 实现，
## 这里负责构建共享 A* 网格并注入给每个敌人（性能关键：只建一次）。
## ============================================================

const ENEMY_SCENE := preload("res://Scenes/Enemy.tscn")


## 由 main.gd 在地图生成后调用，传入 MapGenerator 的结果
func setup(root: Node2D, map_data: Dictionary) -> void:
	var walls: Array = map_data["walls"]
	var reachable: Array = map_data["reachable"]
	var tile_size: int = int(map_data["tile_size"])
	var spawn_cell: Vector2i = map_data["spawn_cell"]
	var map_w: int = walls[0].size()
	var map_h: int = walls.size()

	var count := int(Config.get_value("enemy.count", 100))
	var min_d := float(Config.get_value("enemy.min_distance_from_player_cells", 20))

	# 收集所有"可达地板 + 距出生点足够远"的格子（不可达区域的敌人无意义）
	var candidates: Array = []
	for y in range(map_h):
		for x in range(map_w):
			if walls[y][x] or not reachable[y][x]:
				continue
			if Vector2(x, y).distance_to(Vector2(spawn_cell)) < min_d:
				continue
			candidates.append(Vector2i(x, y))

	if candidates.size() < count:
		push_warning("[Enemy] 合法格不足（%d < %d），只生成 %d 个" % [
			candidates.size(), count, candidates.size()])
		count = candidates.size()

	# A* 网格全体敌人共享：只构建一次（每个敌人各建一次会直接卡死）
	var astar := MapGenerator.build_astar(walls, tile_size)

	# 把墙体网格注入噪音系统（供隔墙衰减），只注一次
	NoiseSystem.setup(walls, tile_size)

	# 洗牌抽取，保证不重复
	candidates.shuffle()
	for i in range(count):
		var c: Vector2i = candidates[i]
		var enemy := ENEMY_SCENE.instantiate()
		enemy.position = Vector2(c) * tile_size + Vector2(tile_size * 0.5, tile_size * 0.5)
		root.add_child(enemy)
		# 入树后再注入导航数据，保证 global_position（= 巡逻中心）已正确
		enemy.setup(walls, tile_size, astar)

	print("[Enemy] 敌人生成完成：%d 个（距出生点 ≥ %.0f 格，AI = 巡逻 + 追击）" % [
		count, min_d])

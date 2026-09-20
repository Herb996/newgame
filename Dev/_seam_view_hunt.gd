extends Node
## 一次性工具（不进回归）：挑一颗"出生镜头正好压在群系交界上"的种子
##
## 实拍截图必须是窗口模式截当前镜头，而镜头跟着出生点，出生点又是地图中心，
## 所以能不能拍到描边线完全取决于地图中心附近有没有群系边界。
## 这里无头批量生成、按镜头可见格数统计边界长度，选出最好的那颗给 tools/shot2d.py 用。
const VIEW_HALF_X := 13          # 1600px / 64px 瓦 / 2
const VIEW_HALF_Y := 8           # 900px / 64px 瓦 / 2
const TARGET_SEED := 20260915    # tools/shot2d.py 实拍用的那颗

## 群系两两之间的"肉眼可分辨度"：雪地最跳，其次是森林 vs 高原。
const PAIR_SCORE := {
	"0-1": 1, "0-2": 2, "0-3": 4,
	"1-2": 3, "1-3": 4, "2-3": 4,
}


func _pair_key(a: int, b: int) -> String:
	return "%d-%d" % [mini(a, b), maxi(a, b)]


func _ready() -> void:
	Config.set_override("map.biome_outline.enabled", true)
	Config.set_override("map.biome_outline.stroke", "dark")
	var terrain: Array = []
	var biome: Array = []
	var rows: Array = []
	for s in range(20260901, 20260941):
		seed(s)
		var m: Dictionary = MapGenerator.generate()
		terrain = m["terrain"]
		biome = m["biome"]
		var c: Vector2i = m["spawn_cell"]
		var hits := 0          # 可见格里的群系交界格
		var score := 0
		var pairs := {}
		for y in range(maxi(1, c.y - VIEW_HALF_Y), mini(terrain.size() - 1, c.y + VIEW_HALF_Y + 1)):
			for x in range(maxi(1, c.x - VIEW_HALF_X), mini((terrain[0] as Array).size() - 1, c.x + VIEW_HALF_X + 1)):
				if bool(terrain[y][x]):
					continue
				var own: int = int(biome[y][x])
				for d in [[0, -1], [0, 1], [-1, 0], [1, 0]]:
					var nx: int = x + d[0]
					var ny: int = y + d[1]
					if bool(terrain[ny][nx]):
						continue
					if int(biome[ny][nx]) == own:
						continue
					hits += 1
					var k := _pair_key(own, int(biome[ny][nx]))
					score += int(PAIR_SCORE.get(k, 1))
					pairs[k] = int(pairs.get(k, 0)) + 1
		rows.append({"seed": s, "spawn": c, "hits": hits, "score": score,
				"pairs": pairs})
		(m["node"] as Node).free()
	rows.sort_custom(func(a, b): return int(a["score"]) > int(b["score"]))
	for r in rows:
		print("[Hunt] seed=%d spawn=%s 交界格=%d 分=%d %s"
				% [int(r["seed"]), str(r["spawn"]), int(r["hits"]), int(r["score"]),
				   str(r["pairs"])])
	print("[Hunt] 地图尺寸 %dx%d，镜头可见窗 %dx%d 格"
			% [terrain[0].size(), terrain.size(),
			   VIEW_HALF_X * 2 + 1, VIEW_HALF_Y * 2 + 1])
	_dump_seam_edges()
	get_tree().quit(0)


## 实拍用的那颗种子：把镜头可见范围内每条群系交界边的中点世界坐标吐出来。
## 描边画在"不连通的那一侧"，所以中点 = 本格中心 + 差邻方向 × 半格。
func _dump_seam_edges() -> void:
	seed(TARGET_SEED)
	var m: Dictionary = MapGenerator.generate()
	var t: Array = m["terrain"]
	var biome: Array = m["biome"]
	var ts: int = int(m["tile_size"])
	var c: Vector2i = m["spawn_cell"]
	var n := 0
	for y in range(maxi(1, c.y - VIEW_HALF_Y), mini(t.size() - 1, c.y + VIEW_HALF_Y + 1)):
		for x in range(maxi(1, c.x - VIEW_HALF_X), mini((t[0] as Array).size() - 1, c.x + VIEW_HALF_X + 1)):
			if bool(t[y][x]):
				continue
			var own: int = int(biome[y][x])
			for d in [[0, -1], [0, 1], [-1, 0], [1, 0]]:
				var nx: int = x + d[0]
				var ny: int = y + d[1]
				if bool(t[ny][nx]) or int(biome[ny][nx]) == own:
					continue
				print("SEAM|%d|%d|%d|%d" % [(x + 0.5 + d[0] * 0.5) * ts,
						(y + 0.5 + d[1] * 0.5) * ts,
						(x + 0.5) * ts, (y + 0.5) * ts])
				n += 1
	(m["node"] as Node).free()
	print("[Hunt] TARGET_SEED=%d 可见交界边 %d 条" % [TARGET_SEED, n])


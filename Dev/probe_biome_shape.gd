extends Node2D
## 一次性诊断：群系区域为什么是矩形。
## 假设：biome_edge_blend 先把边界打成犬牙，随后 _consolidate_biome 的
## 3 轮「多数投票」+ _remove_biome_islands(最小 40 格) 又把犬牙抹平成
## 曼哈顿式矩形，并删掉了参考图里那种小岛。这里逐个关掉对比形状。

const MAP_SEED := 20260919
const GX := 88
const GY := 8
const WW := 56
const WH := 30
const GLYPH := "RGBAUVWX"

var _biome: Array
var _terrain: Array


func _ready() -> void:
	Config.set_override("map.biome_blend.enabled", false)
	_dump_freq("群系噪声 0.008/格（出厂值，周期=125格 > 全图）", 0.008)
	_dump_freq("群系噪声 0.03/格（周期≈33格≈2100px）", 0.03)
	_dump_freq("群系噪声 0.05/格（周期=20格=1280px）", 0.05)
	_dump_freq("群系噪声 0.05 + 边界抖动加倍", 0.05, 0.12)
	get_tree().quit(0)


func _dump_freq(title: String, bfreq: float, jfreq := -1.0) -> void:
	seed(MAP_SEED)
	Config.set_override("map.biome_noise_frequency", bfreq)
	if jfreq > 0.0:
		Config.set_override("map.biome_border_frequency", jfreq)
	else:
		Config.clear_override("map.biome_border_frequency")
	_dump(title)
	Config.clear_override("map.biome_noise_frequency")
	Config.clear_override("map.biome_border_frequency")


func _dump(title: String) -> void:
	Config.set_override("map.biome_smooth_iterations", 3)
	Config.set_override("map.biome_remove_islands", true)
	Config.set_override("map.biome_min_region_cells", 40)
	Config.clear_override("map.biome_edge_blend")
	var res: Dictionary = MapGenerator.generate()
	_biome = res["biome"]
	_terrain = res["terrain"]
	var h: int = _biome.size()
	var w: int = _biome[0].size()
	print("\n[Shape] ===== %s =====  地图 %dx%d（全图缩览：每 2 格取 1 列、每 4 格取 1 行）" % [title, w, h])
	for y in range(0, h, 4):
		var row := ""
		for x in range(0, w, 2):
			if bool(_terrain[y][x]):
				row += "#"
			else:
				row += GLYPH[int(_biome[y][x]) % GLYPH.length()]
		print("[Shape] %s" % row)
	var cnt := {}
	for b in range(MapGenerator.biome_count()):
		cnt[MapGenerator.biome_name(b)] = 0
	for y in range(h):
		for x in range(w):
			if not bool(_terrain[y][x]):
				cnt[MapGenerator.biome_name(int(_biome[y][x]))] += 1
	print("[Shape] 全图占比 %s" % str(cnt))

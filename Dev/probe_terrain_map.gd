extends Node
## Dev 探针 — 地形/装饰分布的**量化诊断**（不属于游戏本体）
## 目的：把「森林树木密度够不够」「裂缝看不看得见」「河水像不像河」这类
##       主观问题，变成逐群系的硬数字 + 两张示意图，避免靠肉眼看小图猜。
## 输出：
##   terrain_stats.png  — 4px/格 示意：群系底色 + 装饰标记（树=红 石=蓝 残骸=紫 裂缝=黑 水=青）
##   terrain_decor.png  — 白底只画装饰（看密度与连续性最直观）
const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-14-22-35-14"
const MAP_SEED := 20260915
const PX := 4                        # 每格像素（示意图）

const BIOME_COL := [
	Color(0.42, 0.62, 0.24),   # 0 草地
	Color(0.66, 0.52, 0.30),   # 1 荒原
	Color(0.16, 0.30, 0.16),   # 2 森林
	Color(0.88, 0.91, 0.95),   # 3 雪原
]
# kind -> 标记色，键 = MapGenerator.DECOR_*
const MARK_COL := {
	1: Color(0.95, 0.15, 0.15),   # 树
	2: Color(0.20, 0.35, 0.95),   # 石头
	3: Color(0.65, 0.20, 0.85),   # 残骸
	4: Color(0.00, 0.00, 0.00),   # 裂缝
	5: Color(0.00, 0.85, 0.95),   # 河水
}


func _ready() -> void:
	seed(MAP_SEED)
	var m: Dictionary = MapGenerator.generate()
	if m.get("node") != null:
		m["node"].free()

	var terrain: Array = m["terrain"]
	var biome: Array = m["biome"]
	var decor: Array = m["decor"]
	var h: int = terrain.size()
	var w: int = terrain[0].size()
	var nb: int = MapGenerator.biome_count()

	# ---- 逐群系统计 ----
	var cells := []
	var dcount := []
	for i in range(nb):
		cells.append(0)
		dcount.append({1: 0, 2: 0, 3: 0, 4: 0, 5: 0})
	var floor_dcount := {1: 0, 2: 0, 3: 0, 4: 0, 5: 0}
	var total_decor := {1: 0, 2: 0, 3: 0, 4: 0, 5: 0}
	var floor_total := 0

	for y in range(h):
		for x in range(w):
			var b: int = int(biome[y][x])
			cells[b] = int(cells[b]) + 1
			var k: int = int(decor[y][x])
			if k != MapGenerator.DECOR_NONE:
				dcount[b][k] = int(dcount[b][k]) + 1
				total_decor[k] = int(total_decor[k]) + 1
			if not terrain[y][x]:
				floor_total += 1
				if k != MapGenerator.DECOR_NONE:
					floor_dcount[k] = int(floor_dcount[k]) + 1

	print("=== [TerrainProbe] 地图 %dx%d 地板 %d 格 ===" % [w, h, floor_total])
	print("%-8s %8s %7s | %6s %6s %6s %6s %6s" %
			["群系", "格数", "占全图", "树", "石", "残骸", "裂缝", "河水"])
	for i in range(nb):
		var c: int = int(cells[i])
		print("%-8s %8d %6.1f%% | %6d %6d %6d %6d %6d" % [
				MapGenerator.biome_name(i), c, 100.0 * float(c) / float(w * h),
				dcount[i][1], dcount[i][2], dcount[i][3], dcount[i][4], dcount[i][5]])
	print("合计装饰：树 %d / 石 %d / 残骸 %d / 裂缝 %d / 河水 %d" %
			[total_decor[1], total_decor[2], total_decor[3], total_decor[4], total_decor[5]])
	print("--- 关键密度（占该群系格数的百分比）---")
	for i in range(nb):
		var c: int = maxi(1, int(cells[i]))
		print("  %-8s 树 %.2f%%  石 %.2f%%  裂缝 %.2f%%  水 %.2f%%" % [
				MapGenerator.biome_name(i),
				100.0 * float(dcount[i][1]) / float(c),
				100.0 * float(dcount[i][2]) / float(c),
				100.0 * float(dcount[i][4]) / float(c),
				100.0 * float(dcount[i][5]) / float(c)])
	print("--- 全图占地板比 ---")
	for k in [1, 2, 3, 4, 5]:
		print("  kind=%d 占地板 %.2f%%" % [k, 100.0 * float(floor_dcount[k]) / float(maxi(1, floor_total))])

	# ---- 示意图 ----
	var img := Image.create(w * PX, h * PX, false, Image.FORMAT_RGB8)
	var solo := Image.create(w * PX, h * PX, false, Image.FORMAT_RGB8)
	solo.fill(Color(1, 1, 1))
	for y in range(h):
		for x in range(w):
			var b: int = int(biome[y][x])
			var base: Color = BIOME_COL[b] if b < BIOME_COL.size() else Color(0.5, 0.5, 0.5)
			if terrain[y][x]:
				base = base.darkened(0.45)          # 墙/阻挡格加深，方便看出障碍分布
			var k: int = int(decor[y][x])
			var mk: Color = MARK_COL.get(k, base)
			var c: Color = mk if k != MapGenerator.DECOR_NONE else base
			_fill(img, x, y, c)
			if k != MapGenerator.DECOR_NONE:
				_fill(solo, x, y, mk)
	img.save_png(OUT_DIR + "/terrain_stats.png")
	solo.save_png(OUT_DIR + "/terrain_decor.png")
	print("[TerrainProbe] 已输出 terrain_stats.png / terrain_decor.png（%dx%d）"
			% [w * PX, h * PX])
	get_tree().quit(0)


func _fill(img: Image, cx: int, cy: int, c: Color) -> void:
	var r := Rect2i(cx * PX, cy * PX, PX, PX)
	img.fill_rect(r, c)

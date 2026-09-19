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
	6: Color(0.25, 0.60, 0.30),   # 灌木
}
## 统计与出图覆盖的装饰 kind 全集。**必须与 MapGenerator.DECOR_* 同步**：
## 早先这里写死 1~5，灌木（6）一加进来就抛 "Invalid access to key '6'"，
## 而探针崩在半路就不会 quit()，整个回归套件跟着挂住（见 run_regression.py）。
const KINDS := [1, 2, 3, 4, 5, 6]
const KIND_NAME := {
	1: "树", 2: "石", 3: "残骸", 4: "裂缝", 5: "河水", 6: "灌木",
}


func _ready() -> void:
	seed(MAP_SEED)
	var m: Dictionary = MapGenerator.generate()
	if m.get("node") != null:
		m["node"].free()

	var terrain: Array = m["terrain"]
	var walls: Array = m["walls"]
	var biome: Array = m["biome"]
	var decor: Array = m["decor"]
	var h: int = terrain.size()
	var w: int = terrain[0].size()
	var nb: int = MapGenerator.biome_count()

	# ---- 逐群系统计（遍历 KINDS，不在表里的 kind 也会兜住）----
	var cells := []
	var dcount := []
	for i in range(nb):
		cells.append(0)
		var z := {}
		for k in KINDS:
			z[k] = 0
		dcount.append(z)
	var floor_dcount := {}
	var total_decor := {}
	for k in KINDS:
		floor_dcount[k] = 0
		total_decor[k] = 0
	var floor_total := 0

	for y in range(h):
		for x in range(w):
			var b: int = int(biome[y][x])
			cells[b] = int(cells[b]) + 1
			# 地板 = 通行格（树/石所在格渲染成地板但 walls 里是障碍，所以这里
			# 和 MapGenerator 的 floor_count 一样看 walls，不看 terrain —— terrain
			# 是渲染用的图集列号，拿它当布尔会把「地板」量成「图集 0 列的格子」。）
			var is_floor: bool = not bool(walls[y][x])
			if is_floor:
				floor_total += 1
			var k: int = int(decor[y][x])
			if k == MapGenerator.DECOR_NONE:
				continue
			if not total_decor.has(k):          # 新装饰类型没登记进 KINDS 也不崩
				push_warning("[TerrainProbe] 未登记的装饰 kind=%d，已计入合计" % k)
				total_decor[k] = 0
				dcount[b][k] = 0
			dcount[b][k] = int(dcount[b][k]) + 1
			total_decor[k] = int(total_decor[k]) + 1
			if is_floor:
				if not floor_dcount.has(k):
					floor_dcount[k] = 0
				floor_dcount[k] = int(floor_dcount[k]) + 1

	var all_kinds: Array = total_decor.keys()
	all_kinds.sort()
	print("=== [TerrainProbe] 地图 %dx%d 地板 %d 格 ===" % [w, h, floor_total])
	var head := "%-8s %8s %7s |" % ["群系", "格数", "占全图"]
	for k in all_kinds:
		head += " %6s" % KIND_NAME.get(k, "k%d" % k)
	print(head)
	for i in range(nb):
		var c: int = int(cells[i])
		var line := "%-8s %8d %6.1f%% |" % [
				MapGenerator.biome_name(i), c, 100.0 * float(c) / float(w * h)]
		for k in all_kinds:
			line += " %6d" % int(dcount[i].get(k, 0))
		print(line)
	var parts := []
	for k in all_kinds:
		parts.append("%s %d" % [str(KIND_NAME.get(k, "k%d" % k)), int(total_decor[k])])
	print("合计装饰：" + " / ".join(parts))
	print("--- 关键密度（占该群系格数的百分比）---")
	for i in range(nb):
		var c: int = maxi(1, int(cells[i]))
		var seg := []
		for k in all_kinds:
			seg.append("%s %.2f%%" % [str(KIND_NAME.get(k, "k%d" % k)),
					100.0 * float(dcount[i].get(k, 0)) / float(c)])
		print("  %-8s %s" % [MapGenerator.biome_name(i), "  ".join(seg)])
	print("--- 全图占地板比 ---")
	for k in all_kinds:
		print("  %-4s 占地板 %.2f%%" % [str(KIND_NAME.get(k, "k%d" % k)),
				100.0 * float(floor_dcount.get(k, 0)) / float(maxi(1, floor_total))])

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

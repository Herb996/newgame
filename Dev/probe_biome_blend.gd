extends Node
## Dev 探针 — 群系边界混合层（BiomeBlendLayer）
##
## 混合层是"外观层"：它必须只在群系边界上出现、覆盖率与权重量化吻合，
## 而且**绝不能碰玩法**。所以这里除了正向断言，还做两件更重要的事：
##   1) 负对照：关掉 map.biome_blend.enabled 再生成一次同一张图，
##      terrain / walls / biome / decor 四张网格必须与开启时逐格相同；
##   2) 节点对照：关闭时树里不该有 BiomeBlendLayer、blend_cells 应为空。
## 另附两张 build_preview 成品图（开 / 关），断言全绿也还是要肉眼过一遍。
const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const MAP_SEED := 20260919
const PREVIEW_CELLS := 24          # build_preview 边长（格）

var _pass := 0
var _fail := 0


func _ok(msg: String) -> void:
	_pass += 1
	print("  [ok]   " + msg)


func _bad(msg: String) -> void:
	_fail += 1
	print("  [FAIL] " + msg)


func _check(what: String, cond: bool, detail := "") -> void:
	if cond:
		_ok(what)
	else:
		_bad(what + (("" if detail == "" else "  ← " + detail)))


func _ready() -> void:
	_check_bayer()

	Config.set_override("map.biome_blend.enabled", true)
	Config.set_override("map.biome_blend.radius_cells", 1)
	# 下面的网点覆盖率容差（trans*lv/8+8）是按**浅描边块**的 alpha 轮廓标定的：
	# 官方深描边块（源表 col 5-8）圆角的像素分布不同，边界档会顶偏 1 个像素。
	# 描边风格本身由 Dev/probe_biome_outline.gd 管，这里只锁住自己的标定前提。
	Config.set_override("map.biome_outline.stroke", "light")
	seed(MAP_SEED)
	var on: Dictionary = MapGenerator.generate()
	_check_generated(on, true)
	var prev_on: Image = MapGenerator.build_preview(on, PREVIEW_CELLS)

	# ---- 负对照：同一颗种子、只关开关 ----
	Config.set_override("map.biome_blend.enabled", false)
	seed(MAP_SEED)
	var off: Dictionary = MapGenerator.generate()
	_check_generated(off, false)
	var prev_off: Image = MapGenerator.build_preview(off, PREVIEW_CELLS)

	_check_grids_identical(on, off)

	_check_blend_image(4)
	_check_blend_image(16)
	Config.set_override("map.biome_blend.dither", 6)      # 非法值：必须回退到 8 并警告
	_check("dither=6（不整除 64）回退到默认 8", _blend_dither_size_fallback())
	Config.clear_override("map.biome_blend.dither")

	prev_on.save_png(OUT_DIR + "/probe_blend_on.png")
	prev_off.save_png(OUT_DIR + "/probe_blend_off.png")
	print("[BlendProbe] 已输出 probe_blend_on.png / probe_blend_off.png（%d 格）" % PREVIEW_CELLS)

	on["node"].free()
	off["node"].free()
	print("[BlendProbe] 通过 %d / %d" % [_pass, _pass + _fail])
	if _fail > 0:
		print("[BlendProbe] 失败 %d 项" % _fail)
	get_tree().quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------- Bayer 矩阵
func _check_bayer() -> void:
	print("--- [BlendProbe] Bayer 矩阵 ---")
	for n in [1, 2, 4, 8, 16]:
		var m: Array = MapGenerator._bayer(n)
		var vals := []
		var ok_dim: bool = m.size() == n
		for y in range(n):
			if (m[y] as Array).size() != n:
				ok_dim = false
			for x in range(n):
				vals.append(int(m[y][x]))
		vals.sort()
		var expect := []
		for i in range(n * n):
			expect.append(i)
		_check("B(%d) 是 0..%d 的排列（网点均匀）" % [n, n * n - 1],
				ok_dim and vals == expect)


## dither=4 与 dither=16：每档不透明像素数必须正好是 4096 * lv / 8。
## 这条是整个设计的支点 —— tile_size(64) 是 dither 的整数倍，所以网点相位
## 在瓦片边界上自对齐，相邻瓦片才能连成一张连续的网。
func _check_blend_image(dither: int) -> void:
	print("--- [BlendProbe] 混合图集 dither=%d ---" % dither)
	var ts: int = int(Config.get_value("map.tile_size", 64))
	var img := MapGenerator._build_blend_image(ts, dither)
	var cols: int = MapGenerator.blend_atlas_cols()
	_check("图集尺寸 %d×%d == cols*ts × BLD_LEVELS*ts" % [img.get_width(), img.get_height()],
			img.get_width() == cols * ts and img.get_height() == MapGenerator.BLD_LEVELS * ts)
	var src := MapGenerator._atlas_img
	if src == null:
		_bad("主图集 _atlas_img 未缓存，无法比对像素")
		return
	var area := ts * ts
	var trans := {}                      # 列 -> 主图集该瓦片里的透明像素数
	for c in [0, 8, cols - 1]:
		var n := 0
		for y in range(ts):
			for x in range(ts):
				if src.get_pixel(c * ts + x, y).a > 0.5:
					n += 1
		trans[c] = area - n
		print("       主图集列 %d：不透明 %d/%d" % [c, n, area])
	for lv in range(1, MapGenerator.BLD_LEVELS + 1):
		var worst := 0
		var worst_c := 0
		for c in [0, 8, cols - 1]:
			var n := 0
			for y in range(ts):
				for x in range(ts):
					if img.get_pixel(c * ts + x, (lv - 1) * ts + y).a > 0.5:
						n += 1
			# 网点每 8×8 块恰好点亮 8*lv 个相位，一格 64 块 → 512*lv。
			# 主图集里本来就透明的格子照抄后仍然透明，所以要按 lv 比例放宽那么多。
			var dev: int = absi(n - 512 * lv)
			if dev > worst:
				worst = dev
				worst_c = c
		_check("lv=%d 覆盖率 = %d/8（最大偏差 %d，列 %d）" % [lv, lv, worst, worst_c],
				worst <= int(trans[worst_c]) * lv / 8 + 8)
		if lv == 3:
			var same := true
			for y in range(ts):
				for x in range(ts):
					var b: Color = img.get_pixel(x, (lv - 1) * ts + y)
					if b.a <= 0.5:
						continue
					var a: Color = src.get_pixel(x, y)
					if not (is_equal_approx(b.r, a.r) and is_equal_approx(b.g, a.g)
							and is_equal_approx(b.b, a.b)):
						same = false
						break
			_check("第 3 档照抄主图集配色（无混色）", same)
	# 网点必须整块镂空：第 lv 档亮的格子是第 lv+1 档的子集（单调加密，不会花）
	var mono := true
	for y in range(0, ts, 1):
		for x in range(0, ts, 1):
			var lo: Color = img.get_pixel(x, 0 * ts + y)
			var hi: Color = img.get_pixel(x, (MapGenerator.BLD_LEVELS - 1) * ts + y)
			if lo.a > 0.5 and hi.a <= 0.5:
				mono = false
	_check("lv=1 的网点是 lv=7 的子集（覆盖率单调）", mono)


func _blend_dither_size_fallback() -> bool:
	return MapGenerator._blend_dither_size(64) == MapGenerator.BLD_DEFAULT_DITHER


# ---------------------------------------------------------------- 生成结果
func _check_generated(m: Dictionary, expect_layer: bool) -> void:
	print("--- [BlendProbe] %s ---" % ("启用" if expect_layer else "关闭（负对照）"))
	var root: Node = m["node"]
	var terrain: Array = m["terrain"]
	var biome: Array = m["biome"]
	var cells: Dictionary = m.get("blend_cells", {})
	var h: int = terrain.size()
	var w: int = terrain[0].size()
	var radius: int = int(Config.get_value("map.biome_blend.radius_cells", 1))

	_check("混合格数 = %d（>0）" % cells.size(), expect_layer == (cells.size() > 0),
			"cells=%d expected_layer=%s" % [cells.size(), expect_layer])

	var blend: TileMapLayer = null
	var names := []
	for ch in root.get_children():
		names.append(ch.name)
		if ch is TileMapLayer and ch.name == "BiomeBlendLayer":
			blend = ch
	_check("节点树里 BiomeBlendLayer %s" % ("存在" if expect_layer else "不存在"),
			expect_layer == (blend != null), "children=" + str(names))
	if not expect_layer:
		return

	_check("混合层夹在主图层与装饰层之间",
			names.find("TileMapLayer") < names.find("BiomeBlendLayer")
			and names.find("BiomeBlendLayer") < names.find("DecorLayer"),
			"children=" + str(names))
	_check("混合层用最近邻过滤（线性过滤会把 1-bit 网点糊成灰膜）",
			blend.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST)
	_check("混合层无碰撞（纯外观层）", blend.tile_set.get_physics_layers_count() == 0,
			"physics_layers=%d" % blend.tile_set.get_physics_layers_count())
	_check("混合层格数与 blend_cells 一致", blend.get_used_cells().size() == cells.size())

	var bad_alt := 0
	var bad_lv := 0
	var bad_k := 0
	var bad_wall := 0
	var far_from_alt := 0
	var max_lv := 0
	for pos in cells:
		var e: Dictionary = cells[pos]
		var x: int = pos.x
		var y: int = pos.y
		var lv: int = int(e["lv"])
		var alt: int = int(e["alt"])
		max_lv = maxi(max_lv, lv)
		if lv < 1 or lv > MapGenerator.BLD_LEVELS:
			bad_lv += 1
		if alt == int(biome[y][x]) or alt < 0 or alt >= MapGenerator.biome_count():
			bad_alt += 1
		if int(e["k"]) < 0 or int(e["k"]) >= MapGenerator.BLOB_N:
			bad_k += 1
		if bool(terrain[y][x]):
			bad_wall += 1
		# 次主导群系必须在模糊窗口（切比雪夫半径 radius）内真的有格子，
		# 否则这条混合带就是凭空的 —— 也就是"边界没画错、却在地块中间起网点"。
		var found := false
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var nx: int = x + dx
				var ny: int = y + dy
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				if not bool(terrain[ny][nx]) and int(biome[ny][nx]) == alt:
					found = true
		if not found:
			far_from_alt += 1
	_check("带内每格 alt ≠ 本格群系（%d 格）" % cells.size(), bad_alt == 0, "违例 %d" % bad_alt)
	_check("1 ≤ lv ≤ BLD_LEVELS（实测最高 %d 档）" % max_lv, bad_lv == 0, "违例 %d" % bad_lv)
	_check("blob 下标在 0..15 内", bad_k == 0, "违例 %d" % bad_k)
	_check("混合格全是可走格（水面不掺和）", bad_wall == 0, "违例 %d" % bad_wall)
	_check("混合格附近 radius=%d 内确有该群系（不凭空起带）" % radius,
			far_from_alt == 0, "违例 %d" % far_from_alt)

	# 图集坐标合法 + 与 CPU 侧一致
	var bad_cell := 0
	for pos in cells:
		var e: Dictionary = cells[pos]
		var at := blend.get_cell_atlas_coords(pos)
		var want := MapGenerator.blend_atlas_pos(int(e["alt"]), int(e["k"]), int(e["lv"]))
		if blend.get_cell_source_id(pos) != 0 or at != want:
			bad_cell += 1
	_check("层内瓦片坐标 = blend_atlas_pos(alt,k,lv)", bad_cell == 0, "违例 %d" % bad_cell)


## 玩法数据不受影响：混合开关只改观感，四张网格必须逐格相同。
func _check_grids_identical(a: Dictionary, b: Dictionary) -> void:
	print("--- [BlendProbe] 开启 / 关闭 的玩法网格比对 ---")
	for key in ["terrain", "walls", "biome", "decor"]:
		var ga: Array = a[key]
		var gb: Array = b[key]
		var diff := 0
		if ga.size() != gb.size():
			diff = -1
		else:
			for y in range(ga.size()):
				for x in range((ga[y] as Array).size()):
					if int(ga[y][x]) != int(gb[y][x]):
						diff += 1
		_check("%s 网格逐格相同（%dx%d）" % [key, ga[0].size(), ga.size()], diff == 0,
				"差异 %d 格" % diff)
	_check("出生格相同", a["spawn_cell"] == b["spawn_cell"],
			"%s vs %s" % [str(a["spawn_cell"]), str(b["spawn_cell"])])

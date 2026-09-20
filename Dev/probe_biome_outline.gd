extends Node
## Dev 探针 — 群系边界描边（map.biome_outline）
##
## 这条线是官方 blob 瓦**自带**的海岸线描边，做法只是把 blob 的"同类"判定
## 从「邻格可走」收紧成「邻格可走且同群系」。所以探针要钉死四件事：
##   1) 真根因：关闭时，四邻都可走但混着别的群系的格子一律拿到内部实心块 k=5
##      （= 一条线都没有）；开启时同一批格子必须变成 k!=5。
##   2) 纯外观：同一颗种子开/关两次，terrain / walls / biome / decor / speed_mult
##      五张网格逐格相同。
##   3) stroke 只换皮：light 与 dark 两套描边的 blob 下标逐格相同，图集像素不同。
##   4) 重构不改变老行为：地图外圈仍然自动描完整崖壁。
## 另输出 build_preview 三张成品图（关 / 开-浅 / 开-深），断言全绿也要肉眼过一遍。

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const MAP_SEED := 20260919
const PREVIEW_CELLS := 24
const BLOB_INTERIOR := 5          # 四邻全连通 = 无描边的内部实心块

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


func _gen() -> Dictionary:
	seed(MAP_SEED)
	return MapGenerator.generate()


## 主图层每格实际拿到的 blob 下标（col = b*BLOB_N+k → k = col % BLOB_N）。
func _blob_map(m: Dictionary) -> Dictionary:
	var out := {}
	var layer: TileMapLayer = null
	for ch in (m["node"] as Node).get_children():
		if ch is TileMapLayer and ch.name == "TileMapLayer":
			layer = ch
	if layer == null:
		return out
	var terrain: Array = m["terrain"]
	for pos in layer.get_used_cells():
		if bool(terrain[pos.y][pos.x]):
			continue                       # 水面格不参与 blob 编码
		out[pos] = layer.get_cell_atlas_coords(pos).x % MapGenerator.BLOB_N
	return out


## 四邻都可走、但至少有一邻是别的群系 —— 这些格子就是"该有线却什么都没有"的那批。
func _seam_cells(m: Dictionary) -> Array:
	var terrain: Array = m["terrain"]
	var biome: Array = m["biome"]
	var h: int = terrain.size()
	var w: int = terrain[0].size()
	var out: Array = []
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			if bool(terrain[y][x]):
				continue
			var own: int = int(biome[y][x])
			var all_walkable := true
			var differs := false
			for d in [[0, -1], [0, 1], [-1, 0], [1, 0]]:
				var nx: int = x + d[0]
				var ny: int = y + d[1]
				if bool(terrain[ny][nx]):
					all_walkable = false
				elif int(biome[ny][nx]) != own:
					differs = true
			if all_walkable and differs:
				out.append(Vector2i(x, y))
	return out


func _grids_equal(a: Dictionary, b: Dictionary) -> PackedStringArray:
	var bad := PackedStringArray()
	for key in ["terrain", "walls", "biome", "decor"]:
		var ga: Array = a[key]
		var gb: Array = b[key]
		if ga.size() != gb.size():
			bad.append(key)
			continue
		for y in range(ga.size()):
			for x in range((ga[y] as Array).size()):
				if int(ga[y][x]) != int(gb[y][x]):
					bad.append("%s[%d,%d]" % [key, x, y])
					return bad
	var sa: Array = a["speed_mult"]
	var sb: Array = b["speed_mult"]
	for y in range(sa.size()):
		for x in range((sa[y] as Array).size()):
			if not is_equal_approx(float(sa[y][x]), float(sb[y][x])):
				bad.append("speed_mult[%d,%d]" % [x, y])
				return bad
	return bad


func _ready() -> void:
	print("=== [OutlineProbe] seed=%d ===" % MAP_SEED)

	# ---- 1) 关闭 = 老行为：群系接缝上根本没有线 ----
	Config.set_override("map.biome_outline.enabled", false)
	Config.set_override("map.biome_outline.stroke", "light")
	var off: Dictionary = _gen()
	var off_blobs := _blob_map(off)
	var seams := _seam_cells(off)
	var seams_missing_line := 0
	for pos in seams:
		if int(off_blobs.get(pos, BLOB_INTERIOR)) == BLOB_INTERIOR:
			seams_missing_line += 1
	_check("接缝格样本量足够（%d 格）" % seams.size(), seams.size() > 200)
	_check("关闭时接缝格 100% 拿到无描边内部块 k=5（真根因）",
			seams_missing_line == seams.size(),
			"%d/%d" % [seams_missing_line, seams.size()])
	_check("关闭时用的是官方图集", MapGenerator._used_ai_atlas)
	var prev_off: Image = MapGenerator.build_preview(off, PREVIEW_CELLS)

	# ---- 2) 开启 = 同一批接缝格全部描上边 ----
	Config.set_override("map.biome_outline.enabled", true)
	var on: Dictionary = _gen()
	var on_blobs := _blob_map(on)
	var seams2 := _seam_cells(on)
	_check("开/关两次接缝格集合相同（纯外观不动群系网格）", seams2.size() == seams.size())
	var lined := 0
	for pos in seams2:
		if int(on_blobs.get(pos, BLOB_INTERIOR)) != BLOB_INTERIOR:
			lined += 1
	_check("开启时接缝格 100% 拿到带描边的 blob", lined == seams2.size(),
			"%d/%d" % [lined, seams2.size()])
	var prev_light: Image = MapGenerator.build_preview(on, PREVIEW_CELLS)

	# ---- 3) 负对照：五张玩法网格逐格相同 ----
	var diff := _grids_equal(off, on)
	_check("开启描边不动 terrain/walls/biome/decor/speed_mult", diff.is_empty(),
			str(diff.slice(0, 3)))
	_check("开启描边不新增 TileMapLayer",
			(on["node"] as Node).get_child_count() == (off["node"] as Node).get_child_count(),
			"%d vs %d" % [(on["node"] as Node).get_child_count(),
						 (off["node"] as Node).get_child_count()])

	# ---- 4) stroke 只换皮：blob 逐格相同、图集像素不同 ----
	var atlas_light: Image = MapGenerator._atlas_img.duplicate()
	Config.set_override("map.biome_outline.stroke", "dark")
	var dark: Dictionary = _gen()
	var dark_blobs := _blob_map(dark)
	var mismatch := 0
	for pos in on_blobs:
		if int(on_blobs[pos]) != int(dark_blobs.get(pos, -1)):
			mismatch += 1
	_check("light/dark 两套描边的 blob 下标逐格相同", mismatch == 0, "违例 %d" % mismatch)
	var atlas_dark: Image = MapGenerator._atlas_img
	_check("dark 图集与 light 图集像素不同（确实换了描边块）",
			not _images_equal(atlas_light, atlas_dark))
	_check("dark 图集列数不变（没多采一份）",
			atlas_dark.get_width() == atlas_light.get_width())
	var prev_dark: Image = MapGenerator.build_preview(dark, PREVIEW_CELLS)

	# ---- 5) 非法 stroke 值回退 light ----
	Config.set_override("map.biome_outline.stroke", "pitch-black")
	var bogus: Dictionary = _gen()
	_check("stroke 非法值回退到 light 的采样列",
			MapGenerator.outline_src_col0() == MapGenerator.SRC_OUTLINE_COL_LIGHT)
	var bogus_blobs := _blob_map(bogus)
	var bogus_mismatch := 0
	for pos in dark_blobs:
		if int(bogus_blobs.get(pos, -9)) != int(dark_blobs[pos]):
			bogus_mismatch += 1
	_check("stroke 非法值不改任何铺瓦结果", bogus_mismatch == 0, "违例 %d" % bogus_mismatch)

	# ---- 6) 越界仍算不连通：直接拿合成网格测 _blob_linked 的三条规则 ----
	var solo := [[1, 1, 1], [1, 0, 1], [1, 1, 1]]
	_check("合成：四周全是水的孤立可走格 → 四边全描边 k=15",
			MapGenerator.blob_index(solo, 1, 1) == 15,
			"k=%d" % MapGenerator.blob_index(solo, 1, 1))
	var full := [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
	_check("合成：整片可走时正中心仍无描边 k=5",
			MapGenerator.blob_index(full, 1, 1) == 5)
	_check("合成：左上角越界的两个方向算不连通 → k=0",
			MapGenerator.blob_index(full, 0, 0) == 0,
			"k=%d" % MapGenerator.blob_index(full, 0, 0))
	var bnd := [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
	var bnd_biome := [[0, 0, 0], [0, 1, 1], [0, 1, 1]]
	var k_off: int = MapGenerator.blob_index(bnd, 1, 1)
	Config.set_override("map.biome_outline.enabled", true)
	var k_on: int = MapGenerator.blob_index(bnd, 1, 1, bnd_biome)
	_check("合成：同群系一侧不描边、异群系一侧描边（k %d → %d）" % [k_off, k_on],
			k_off == 5 and k_on != 5)
	Config.set_override("map.biome_outline.enabled", false)
	_check("合成：关掉开关后群系差异被忽略（回到只看可走性）",
			MapGenerator.blob_index(bnd, 1, 1, bnd_biome) == 5)

	# ---- 7) 真图不变式：开启描边只加边、绝不减边 ----
	Config.set_override("map.biome_outline.enabled", false)
	var plain: Dictionary = _gen()
	var plain_blobs := _blob_map(plain)
	Config.set_override("map.biome_outline.enabled", true)
	var edged: Dictionary = _gen()
	var edged_blobs := _blob_map(edged)
	var reversed := 0
	for pos in plain_blobs:
		var a: int = int(plain_blobs[pos])
		var b: int = int(edged_blobs.get(pos, -1))
		if a != BLOB_INTERIOR and b == BLOB_INTERIOR:
			reversed += 1
	_check("开启描边不会让原本已有的岸线消失（只加不减）", reversed == 0, "违例 %d" % reversed)

	prev_off.save_png(OUT_DIR + "/probe_outline_off.png")
	prev_light.save_png(OUT_DIR + "/probe_outline_light.png")
	prev_dark.save_png(OUT_DIR + "/probe_outline_dark.png")
	print("[OutlineProbe] 已输出 probe_outline_off / _light / _dark.png（%d 格）" % PREVIEW_CELLS)

	for m in [off, on, dark, bogus]:
		(m["node"] as Node).free()
	print("[OutlineProbe] 通过 %d / %d" % [_pass, _pass + _fail])
	if _fail > 0:
		print("[OutlineProbe] 失败 %d 项" % _fail)
	get_tree().quit(0 if _fail == 0 else 1)


func _images_equal(a: Image, b: Image) -> bool:
	if a.get_size() != b.get_size():
		return false
	for y in range(a.get_height()):
		for x in range(a.get_width()):
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				return false
	return true

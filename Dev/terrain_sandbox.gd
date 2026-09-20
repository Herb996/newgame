extends Node
## ============================================================
## Terrain Set 沙盒（一次性验证，不接进游戏）—— 全程代码建，不用点编辑器
##
## 要证明的事：Tiny Swords 官方地形图集 `tilemap_colorN.png` 能不能喂给 Godot 4.7
## 的 **地形集（Terrain Set）**，让 TileMapLayer 在「两块不同地表相接」时自动挑对
## 过渡瓦片。输出按教程的 6 步分段打印，一段一段对着看。
##
## 【2026-09-20 的关键纠正】原先我用「量每条边 2px 带的 alpha」反推每格的连通性，
## 结果大图 99 处选错、且错得只集中在 右/下 两边（上0 左0 右50 下49）。用 PIL 把
## 两张图集的边覆盖率打出来才看清：这些 blob 的边**根本不是双峰**（同一方向上
## 0.11~1.00 都有，均值 上0.67 / 右0.75 / 下0.73 / 左0.74），也就是说 alpha 阈值
## 怎么挑都是在猜，猜出来的连通性还必然和美术对不上。
## 而本项目**早就有一份逐格验证过的官方 blob 表**：map_generator.gd:120-131 的
## blob_row/blob_col（右通⟺col∈{0,1}、下通⟺row∈{0,1}、左通⟺col∈{1,2}、
## 上通⟺row∈{1,2}），出厂就在游戏里渲染，已经在跑。所以这里改成**照表写 bit**，
## 彻底不碰像素。表和画也对得上：图集左上 4x4 里 (0,0) 是大圆角块的左上角
## （上/左断、下/右通），(1,1) 是全通的内部块，(3,3) 是孤立小块。
##
## 图集 blob 的切边是**透明**的（不是把底层地表画在同一格里），所以底下必须垫一层
## 实心背景 TileMapLayer，否则交界处是洞。
## ============================================================

const TILE := 64
const ATLAS_A := "res://Assets/Art/Tiles/TS/tilemap_color1.png"   # 地形 0 亮草
const ATLAS_B := "res://Assets/Art/Tiles/TS/tilemap_color3.png"   # 地形 1 青苔
const GRID_W := 24
const GRID_H := 16
## 官方 16 块 blob 在源表里的位置：col = k%4、row = k/4，浅描边包从第 0 列起，
## 深描边包从第 5 列起（见 map_generator.gd:68 SRC_OUTLINE_COL_LIGHT/DARK）。
const SRC_COL0 := 0
## 全连通的那一块（row1,col1）——背景层要用的"实心内部块"
const SOLID_COORDS := Vector2i(1, 1)

# ---- peering bit 整数：照 Godot 4.7.2 引擎源码校准，不靠猜 ----
# 4.7 里这套位叫 `TileSet.CellNeighbor`，是个 **16 项**枚举（每个方向 side + corner 各一项），
# 从 RIGHT_SIDE=0 起顺时针排：右0 右角1 右下侧2 右下角3 下4 下角5 左下侧6 左下角7
# 左8 左角9 左上侧10 左上角11 上12 上角13 右上侧14 右上角15。
# 正方形网格只认其中 8 个 —— 见 `is_valid_terrain_peering_bit_for_mode()`
# （scene/resources/2d/tile_set.cpp:887）：侧 0/4/8/12、角 3/7/11/15。
# 【踩过的坑】先前按 4.3 的 8 项 `TerrainPeeringBit`（top_left=0…left=7）写，
# 于是把 1/3/5/7 当成上下左右，实际是**四个角**，全部被引擎判非法。
const BIT_TOP := 12     # CELL_NEIGHBOR_TOP_SIDE
const BIT_RIGHT := 0    # CELL_NEIGHBOR_RIGHT_SIDE
const BIT_BOTTOM := 4   # CELL_NEIGHBOR_BOTTOM_SIDE
const BIT_LEFT := 8     # CELL_NEIGHBOR_LEFT_SIDE
# TerrainMode 整数：0=角+侧、1=只角、2=只侧 ⇒ 「匹配侧边」= 2
const MODE_MATCH_SIDES := 2
const DIR_VEC := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const DIR_BIT := [BIT_TOP, BIT_RIGHT, BIT_BOTTOM, BIT_LEFT]
const _DIR_NAME := ["上", "右", "下", "左"]
const _STEP := "\n[TerrainSandbox] ── 第%d步：%s"


# ------------------------------------------------------------
# 官方 blob 表：k（0..15）↔ [上,右,下,左] 是否和本地形相连
# 这是 map_generator.gd:120-128 那两条 static func 的反函数，
# 那里是「连通性 → 下标」，这里要「下标 → 连通性」。
# ------------------------------------------------------------

func _blob_sides(k: int) -> Array:
	var row := k >> 2
	var col := k & 3
	return [
		row == 1 or row == 2,   # 上通
		col == 0 or col == 1,   # 右通
		row == 0 or row == 1,   # 下通
		col == 1 or col == 2,   # 左通
	]


func _pat_str(key: int) -> String:
	var s := ""
	for d in range(4):
		s += "1" if (key >> d) & 1 else "0"
	return s


func _sides_key(sides: Array) -> int:
	var key := 0
	for d in range(4):
		if bool(sides[d]):
			key |= 1 << d
	return key


func _step(n: int, title: String) -> void:
	print(_STEP % [n, title])


func _ready() -> void:
	print("\n[TerrainSandbox] ===== 开始 =====")
	_step(0, "校准引擎枚举（TerrainMode / CellNeighbor 的整数，4.7.2）")
	_probe_modes()

	_step(1, "建 TileSet + tile_size，两个 TileMapLayer（背景层 / 地形层）")
	_step(2, "加 TileSetAtlasSource：贴图集 + texture_region_size（默认 16x16，必须显式设）")
	_step(3, "add_terrain_set + set_terrain_set_mode(2=匹配侧边)")
	_step(4, "add_terrain 定义两个地形（亮草 / 青苔）")
	_step(5, "给 16 块 blob 逐格写 peering bit（照官方表，不量像素）")
	var ts := _build_tileset(MODE_MATCH_SIDES)
	if ts == null:
		return

	# 先单独验「引擎的自动过渡本身」：3x3 小图、中心 1 格 A、四邻按 mask 决定是不是 A，
	# 期望中心选到侧边组合正好等于 mask。这里期望值由我直接构造，不涉及铺图顺序。
	print("[TerrainSandbox]   单格探针：16 种邻接组合 × 2 种底层铺法，选错 %d 例（0 ⇒ 引擎的自动过渡本身没问题）" % [
			_probe_connect(ts)])

	# 分批铺（先铺满 B，再压一个 A 岛）时，`ignore_empty_terrains` 是真凶之一：
	# 引擎给某格定 side bit 时读的是**邻居瓦片指回来的那个 peering bit**
	# （tile_map_layer.cpp:1970）。铺 B 时 A 岛还是空格，`false` 会把这些 bit 落成
	# -1（无地形）；等第二批改画 A 时，它要的是 0/1，约束里却夹着一条"-1"，
	# **永远无法满足** ⇒ 求解器退让、整圈选错块。反之 `true` 又会留下漏铺。
	# 到底哪种铺法干净，用 4 种组合各铺一遍、由 oracle 排名，不靠猜。
	_step(6, "set_cells_terrain_connect 铺图（4 种铺法各铺一遍，由 oracle 排名）")
	var best_root: Node2D = null
	var best_bad := 1 << 30
	var best_desc := ""
	for base_connect in [true, false]:
		for ignore_empty in [false, true]:
			var desc := "B 底层用 %-14s ｜ 两批 ignore_empty_terrains=%s" % [
					"connect" if base_connect else "set_cell 实心块", str(ignore_empty)]
			# 每种铺法**另建一套 TileSet**：地形组合的候选缓存挂在 TileSet 上，
			# 共用一份缓存会互相串味，测出来的数就不是独立实验了。
			var ts_i: TileSet = _build_tileset(MODE_MATCH_SIDES, false)
			var root := _build_scene(ts_i, base_connect, ignore_empty)
			var bad := _verify(root, true)
			print("[TerrainSandbox]   %s → 不合格 %d 处（漏铺+铺错地形+共享边对不上+内部缝）" % [desc, bad])
			if bad < best_bad:
				if best_root != null:
					best_root.free()
				best_root = root
				best_bad = bad
				best_desc = desc
			else:
				root.free()
	_dump_map(best_root)
	var bad_final := _verify(best_root, false)
	_save(best_root)
	print("[TerrainSandbox] 结论：mode=%d（匹配侧边），最干净的铺法是「%s」→ 不合格 %d 处，应为 0" % [
			MODE_MATCH_SIDES, best_desc, bad_final])
	print("[TerrainSandbox] ===== 结束：%s =====" % ("PASS" if bad_final == 0 else "FAIL"))
	get_tree().quit(0 if bad_final == 0 else 1)


# ------------------------------------------------------------
# 0) 「模式 → 合法位」的实测表：和源码对不上就直接红，别往下跑
# ------------------------------------------------------------

func _probe_modes() -> void:
	var ts := TileSet.new()
	ts.add_terrain_set(0)
	ts.add_terrain(0, 0)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(Image.create(TILE, TILE, false, Image.FORMAT_RGBA8))
	src.texture_region_size = Vector2i(TILE, TILE)
	ts.add_source(src, 0)
	src.create_tile(Vector2i(0, 0))
	var td := src.get_tile_data(Vector2i(0, 0), 0)
	td.set_terrain_set(0)
	td.set_terrain(0)
	for mode in range(3):
		ts.set_terrain_set_mode(0, mode)
		var valid: Array = []
		for b in range(16):
			if td.is_valid_terrain_peering_bit(b):
				valid.append(b)
		# 正方形网格的实测表（照 tile_set.cpp:887 的分支推出来的）：
		# 0=角+侧 → 侧 0/4/8/12 + 角 3/7/11/15；1=只角；2=只侧
		var expect: Array = [[0, 3, 4, 7, 8, 11, 12, 15], [3, 7, 11, 15], [0, 4, 8, 12]][mode]
		var ok: bool = valid == expect
		print("[TerrainSandbox]   mode=%d 合法位 %s（期望 %s）%s" % [
				mode, str(valid), str(expect), "OK" if ok else "≠ 引擎枚举变了"])
		if not ok:
			_fail("mode=%d 的合法 peering bit 和源码对不上，DIR_BIT 常量需要重新校准" % mode)
			return


# ------------------------------------------------------------
# 1~5) 建 TileSet：两个图集源 = 两个地形，出边照官方表写
# ------------------------------------------------------------

func _build_tileset(sides_mode: int, verbose: bool = true) -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	ts.add_terrain_set(0)
	ts.set_terrain_set_mode(0, sides_mode)
	ts.add_terrain(0, 0)
	ts.add_terrain(0, 1)
	ts.set_terrain_name(0, 0, "亮草")
	ts.set_terrain_color(0, 0, Color(0.72, 0.73, 0.35))
	ts.set_terrain_name(0, 1, "青苔")
	ts.set_terrain_color(0, 1, Color(0.45, 0.70, 0.39))

	for src_idx in range(2):
		var path: String = ATLAS_A if src_idx == 0 else ATLAS_B
		# 用 load() 拿导入后的 CompressedTexture2D：存 .tres 时是一条 ext_resource
		# 引用；换成 Image.load_from_file + ImageTexture 会把整张图裸塞进 .tres（实测 7.5MB）。
		var tex: Texture2D = load(path)
		if tex == null:
			_fail("读不到图集 %s" % path)
			return null
		var src := TileSetAtlasSource.new()
		src.texture = tex
		# ⚠ texture_region_size 默认 16x16 且**不跟 tile_size 走**（本项目踩过，
		#    症状是"每格一小角色斑"），见 map_generator.gd:1430 的注释。
		src.texture_region_size = Vector2i(TILE, TILE)
		ts.add_source(src, src_idx)
		var have := {}
		for k in range(16):
			var coords := Vector2i(SRC_COL0 + (k & 3), k >> 2)
			src.create_tile(coords)
			var td: TileData = src.get_tile_data(coords, 0)
			if td == null:
				_fail("源%d 建不出瓦片 %s" % [src_idx, str(coords)])
				return null
			var sides := _blob_sides(k)
			td.set_terrain_set(0)
			td.set_terrain(src_idx)
			var other := 1 - src_idx
			for d in range(4):
				# 相连 = 这一侧允许本地形；断开 = 这一侧是另一种地形
				td.set_terrain_peering_bit(DIR_BIT[d], src_idx if bool(sides[d]) else other)
			have[_sides_key(sides)] = coords
		# 「引擎要不到瓦片就回退成全连本地形的块」是静默行为，所以先确认 16 种
		# 侧边组合齐不齐：缺哪一种，那种组合的格子就必然选错块。
		var missing: Array = []
		for key in range(16):
			if not have.has(key):
				missing.append(_pat_str(key))
		if verbose:
			print("[TerrainSandbox]   源%d %s → 16 块 blob 全进地形集，侧边组合覆盖 %d/16%s" % [
					src_idx, path.get_file(), have.size(),
					"" if missing.is_empty() else "，缺：%s" % ", ".join(missing)])
		if not missing.is_empty():
			_fail("源%d 缺侧边组合 %s：这张图集撑不起「匹配侧边」" % [src_idx, ", ".join(missing)])
			return null
	return ts


## 最小复现：3x3 图，中心 1 格 A，看它四邻里有哪几格是 A（mask 的 4 位=上右下左）
## 时，引擎给中心选的瓦片是不是正好那个侧边组合。两种铺 B 的方式各测一遍。
## 期望组合是我直接构造的（不经过任何像素测量），所以这里能把
## 「自动过渡没生效」和「我的 bit 写错」彻底分开。
func _probe_connect(ts: TileSet) -> int:
	var wrong := 0
	for base in range(2):
		print("[TerrainSandbox]   --- 探针：B 底层 = %s ---" % ("connect 铺" if base == 0 else "set_cell 实心块"))
		for mask in range(16):
			var root := Node2D.new()
			var layer := TileMapLayer.new()
			layer.tile_set = ts
			root.add_child(layer)
			var all_cells: Array[Vector2i] = []
			for y in range(3):
				for x in range(3):
					all_cells.append(Vector2i(x, y))
			if base == 0:
				layer.set_cells_terrain_connect(all_cells, 0, 1, false)
			else:
				for c in all_cells:
					layer.set_cell(c, 1, SOLID_COORDS)
			var a_cells: Array[Vector2i] = [Vector2i(1, 1)]
			for d in range(4):
				if (mask >> d) & 1:
					a_cells.append(Vector2i(1, 1) + DIR_VEC[d])
			layer.set_cells_terrain_connect(a_cells, 0, 0, false)
			var coords := layer.get_cell_atlas_coords(Vector2i(1, 1))
			var got: Array = _blob_sides(_blob_k(coords)) if _in_blob(coords) else []
			var actual := _sides_key(got) if got.size() == 4 else -1
			var ok: bool = actual == mask
			if not ok:
				wrong += 1
			print("[TerrainSandbox]     中心四邻 A=%s → 期望 %s，实得 %s（块 %s）%s" % [
					_pat_str(mask), _pat_str(mask),
					_pat_str(actual) if actual >= 0 else "无瓦片", str(coords), "OK" if ok else "✗"])
			root.free()
	return wrong


func _in_blob(coords: Vector2i) -> bool:
	return coords.x >= SRC_COL0 and coords.x < SRC_COL0 + 4 and coords.y >= 0 and coords.y < 4


## 图集格 → blob 下标（0..15）
func _blob_k(coords: Vector2i) -> int:
	return (coords.y << 2) + (coords.x - SRC_COL0)


# ------------------------------------------------------------
# 6) 铺地图：底层实心背景 + 上层地形集自动过渡
# ------------------------------------------------------------

## 铺法两个开关：
##   base_connect → B 底层是用 set_cells_terrain_connect 铺，还是用 set_cell 直接放实心块
##   ignore_empty → A 批 connect 的 ignore_empty_terrains（引擎默认 true）
func _build_scene(ts: TileSet, base_connect: bool, ignore_empty: bool) -> Node2D:
	var root := Node2D.new()
	root.name = "TerrainSandbox"

	var bg := TileMapLayer.new()
	bg.name = "Background"
	bg.tile_set = ts
	root.add_child(bg)

	var terrain := TileMapLayer.new()
	terrain.name = "Terrain"
	terrain.tile_set = ts
	root.add_child(terrain)
	# ⚠ PackedScene.pack() 只收 owner 指向根节点的子节点；不设 owner 的话
	#    存出来的 .tscn 会是个只剩空根节点的 3 行文件（实测踩过）。
	bg.owner = root
	terrain.owner = root

	var a_cells: Array[Vector2i] = []
	var b_cells: Array[Vector2i] = []
	for y in range(GRID_H):
		for x in range(GRID_W):
			if _is_a(x, y):
				a_cells.append(Vector2i(x, y))
			else:
				b_cells.append(Vector2i(x, y))
			bg.set_cell(Vector2i(x, y), 1, SOLID_COORDS)

	# 先铺满 B 再压 A：B 是底，A 是岛。connect 铺法会顺带修正邻居的瓦片。
	if base_connect:
		terrain.set_cells_terrain_connect(b_cells, 0, 1, ignore_empty)
	else:
		for c in b_cells:
			terrain.set_cell(c, 1, SOLID_COORDS)
	terrain.set_cells_terrain_connect(a_cells, 0, 0, ignore_empty)
	print("[TerrainSandbox]   铺完 %dx%d（B底层=%s，两批 ignore_empty_terrains=%s）：亮草 %d 格 / 青苔 %d 格" % [
			GRID_W, GRID_H, "connect" if base_connect else "set_cell 实心块",
			str(ignore_empty), a_cells.size(), b_cells.size()])
	return root


## 一个圆 + 一条斜长条，凑出「四边不同邻居」的各种组合
func _is_a(x: int, y: int) -> bool:
	var dx := float(x - 6)
	var dy := float(y - 5)
	if dx * dx + dy * dy <= 16.0:
		return true
	if y >= 6 and y <= 11 and x >= 13 and x <= 19 and (x + y) % 3 != 0:
		return true
	return false


# ------------------------------------------------------------
# oracle：地形集真正的不变量
#
# 【2026-09-20 纠正】原先我以为「每格存的 bit = 我这一侧连不连通」，于是拿它和邻居
# 的真实地形对表 —— 这个前提是错的。Godot 地形集里**相邻两格共享的那条边只有一个
# 地形值**：两格各自存在这条边上的 peering bit 必须**相等**（TerrainConstraint 把
# 一条竖边的基准点定在西格、横边定在北格，两格查的是同一个约束点）。
# 于是一条 A-B 交界边有两种合法画法：这条边归 A ⇒ A 格画满、B 格收圆角；归 B ⇒ 反过来。
# 旧 oracle 把「归对方」那种全判成选错块 —— 99 处"错"全是这个，而且必然只出现在
# 右/下 两个方向（拥有这条边的是西格/北格，只有它会报「我这边本该连通」）。
#
# 真正该断言的是三条：
#   ① 每格有瓦片，且瓦片的 terrain == 我要的那个（漏铺 / 铺错地形）
#   ② 每条内边两格的 bit 相等（不等 = 引擎给了对不上的两块，交界处会有缝）
#   ③ 两格同地形时，这条共享边必须归这个地形（否则区域中间凭空一条裂缝）
# ------------------------------------------------------------

## 取某格在某方向上存的 peering bit（对应地形编号）；没瓦片返回 -2
func _bit_of(layer: TileMapLayer, ts: TileSet, c: Vector2i, d: int) -> int:
	var src_id := int(layer.get_cell_source_id(c))
	if src_id < 0:
		return -2
	var coords := layer.get_cell_atlas_coords(c)
	var td: TileData = ts.get_source(src_id).get_tile_data(coords, 0)
	if td == null:
		return -2
	return int(td.get_terrain_peering_bit(DIR_BIT[d]))


func _terrain_of(layer: TileMapLayer, ts: TileSet, c: Vector2i) -> int:
	var src_id := int(layer.get_cell_source_id(c))
	if src_id < 0:
		return -2
	var td: TileData = ts.get_source(src_id).get_tile_data(layer.get_cell_atlas_coords(c), 0)
	return int(td.terrain) if td != null else -2


func _verify(root: Node2D, quiet: bool = false) -> int:
	var layer := root.get_node("Terrain") as TileMapLayer
	var ts: TileSet = layer.tile_set
	var holes := 0        # ① 没铺上瓦片（整图，含边框圈）
	var wrong_terr := 0   # ① 铺上了但不是要的那个地形
	var mismatch := 0     # ② 共享边两格 bit 不相等
	var seam := 0         # ③ 同地形内部被判给了另一个地形
	var edges := 0
	var by_dir := [0, 0, 0, 0]
	for y in range(GRID_H):
		for x in range(GRID_W):
			var c := Vector2i(x, y)
			var terr := _terrain_of(layer, ts, c)
			if terr < 0:
				holes += 1
				continue
			if terr != (0 if _is_a(x, y) else 1):
				wrong_terr += 1
				if not quiet and wrong_terr <= 6:
					print("[TerrainSandbox]     铺错地形 格%s =源%d %s terrain=%d，要的是 %d" % [
							str(c), int(layer.get_cell_source_id(c)),
							str(layer.get_cell_atlas_coords(c)), terr,
							0 if _is_a(x, y) else 1])
	for y in range(GRID_H):
		for x in range(GRID_W):
			var c := Vector2i(x, y)
			# 只查 右/下 两条边，另一侧的格子会重复覆盖同一条边
			for d in range(1, 3):
				var nb_c: Vector2i = c + DIR_VEC[d]
				if nb_c.x >= GRID_W or nb_c.y >= GRID_H:
					continue
				var b1 := _bit_of(layer, ts, c, d)
				var b2 := _bit_of(layer, ts, nb_c, (d + 2) % 4)
				if b1 < 0 or b2 < 0:
					continue
				edges += 1
				if b1 != b2:
					mismatch += 1
					by_dir[d] += 1
					if not quiet and mismatch <= 12:
						print("[TerrainSandbox]     共享边对不上 格%s %s bit=%d ≠ 邻居格%s 反向 bit=%d" % [
								str(c), _DIR_NAME[d], b1, str(nb_c), b2])
					continue
				var t1 := _terrain_of(layer, ts, c)
				var t2 := _terrain_of(layer, ts, nb_c)
				if t1 == t2 and b1 != t1:
					seam += 1
					if not quiet and seam <= 6:
						print("[TerrainSandbox]     区域内部有缝 格%s↔%s 都是地形%d，共享边却归 %d" % [
								str(c), str(nb_c), t1, b1])
	if not quiet:
		print("[TerrainSandbox]   校验：%d 条内边 ｜ 漏铺 %d 格 / 铺错地形 %d 格 / 共享边对不上 %d 条（右%d 下%d）/ 区域内部有缝 %d 条" % [
				edges, holes, wrong_terr, mismatch, by_dir[1], by_dir[2], seam])
	return holes + wrong_terr + mismatch + seam


## 把 Terrain 层打成字符栅格：.=没铺上，A/B=按图集源编号，数字=该格的侧边组合。
func _dump_map(root: Node2D) -> void:
	var layer := root.get_node("Terrain") as TileMapLayer
	print("[TerrainSandbox]   铺图栅格（. = 空格；A/B 后跟该格选中块的 上右下左 组合）：")
	for y in range(GRID_H):
		var line := ""
		for x in range(GRID_W):
			var s := int(layer.get_cell_source_id(Vector2i(x, y)))
			if s < 0:
				line += "  . "
				continue
			var coords := layer.get_cell_atlas_coords(Vector2i(x, y))
			line += "%s%s " % ["A" if s == 0 else "B", _pat_str(_sides_key(_blob_sides(_blob_k(coords))))]
		print("  %2d %s" % [y, line])


# ------------------------------------------------------------
# 存盘（.tres + .tscn），供编辑器打开继续看/改
# ------------------------------------------------------------

func _save(root: Node2D) -> void:
	var layer := root.get_node("Terrain") as TileMapLayer
	var err_ts := ResourceSaver.save(layer.tile_set, "res://Dev/terrain_sandbox_tileset.tres")
	var pack := PackedScene.new()
	var err_sc := pack.pack(root)
	var nodes := 0
	if err_sc == OK:
		nodes = pack.get_state().get_node_count()
		err_sc = ResourceSaver.save(pack, "res://Dev/terrain_sandbox.tscn")
	print("[TerrainSandbox] 存盘：tileset=%d scene=%d，场景里 %d 个节点（根 + 2 层，少于 3 就是 owner 没设）" % [
			err_ts, err_sc, nodes])
	if nodes < 3:
		_fail("存出来的 .tscn 只有 %d 个节点，编辑器里打开会是空的" % nodes)
		return
	var f := FileAccess.open("res://Dev/terrain_sandbox_tileset.tres", FileAccess.READ)
	if f != null:
		print("[TerrainSandbox]   .tres 大小 %d 字节" % f.get_length())


func _fail(msg: String) -> void:
	push_error("[TerrainSandbox] " + msg)
	get_tree().quit(1)

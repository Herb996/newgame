extends Node
## ============================================================
## Terrain Set 沙盒（一次性验证，不接进游戏） —— 全程代码建，不用点编辑器
##
## 要证明的事：Tiny Swords 的 `tilemap_colorN.png`（576x384 = 9x6 格 64px 的
## blob 图集）能不能喂给 Godot 4.7 的 **地形集（Terrain Set）**，让 TileMapLayer
## 在「两块不同地表相接」时自动挑对过渡瓦片。
##
## 三个刻意的设计：
## 1. **出边由图片自己算**，不手点 peering bits：每格量四条边 2px 带的平均 alpha，
##    ≥0.9 记「本地形铺到这一边」，否则记「这一边是另一种地形」。⇒ 配置错就是
##    测量阈值错，不会出现"手点 47 格点歪"这种无法复盘的错。
## 2. **整数不靠猜**：TerrainMode 与 CellNeighbor 的取值直接照 Godot 4.7.2 源码抄
##    （tile_set.h:218 / :240，tile_set.cpp:887），并把实测的「每模式合法位」打出来对表。
## 3. **有 oracle**：铺完把每格实际选中的瓦片再量一次出边，和「邻居到底是什么地形」
##    对表。这条同时验证了 peering bit 的方向映射（12=上/0=右/4=下/8=左）——
##    方向错位的话这里必然报不一致，而不是等眼睛看图。
##
## 图集 blob 的切边是**透明**的（不是把底层地表画在同一格里），所以底下必须垫一层
## 实心背景 TileMapLayer，否则交界处是洞。
## ============================================================

const TILE := 64
const COLS := 9
const ROWS := 6
const ATLAS_A := "res://Assets/Art/Tiles/TS/tilemap_color1.png"
const ATLAS_B := "res://Assets/Art/Tiles/TS/tilemap_color3.png"
const GRID_W := 24
const GRID_H := 16
const EDGE_FULL := 0.9      # 一边算"铺满"的 alpha 门槛
const CELL_MIN_ALPHA := 0.8 # 整格内容太少（特殊块）就不要它进地形集

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

## [source_index][Vector2i(col,row)] = Array[bool] 四条边是否铺满（顺序同上）
var _sides := [{}, {}]
## 每地形的"完全实心内部块"，背景层要用
var _solid := [Vector2i(-1, -1), Vector2i(-1, -1)]


func _ready() -> void:
	print("\n[TerrainSandbox] ===== 开始 =====")
	_probe_modes()
	var ts := _build_tileset(MODE_MATCH_SIDES)
	if ts == null:
		return
	var root := _build_scene(ts)
	var bad := _verify(root, false)
	_save(root)
	print("[TerrainSandbox] 结论：mode=%d（匹配侧边）出边不一致 %d 处，应为 0" % [MODE_MATCH_SIDES, bad])
	print("[TerrainSandbox] ===== 结束：%s =====" % ("PASS" if bad == 0 else "FAIL"))
	get_tree().quit(0 if bad == 0 else 1)


# ------------------------------------------------------------
# 1) 把「模式 → 合法位」的实测表打出来（只是给人看，判定不靠它）
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
		print("[TerrainSandbox] mode=%d 合法位 %s（期望 %s）%s" % [
				mode, str(valid), str(expect), "OK" if ok else "≠ 引擎枚举变了"])
		if not ok:
			_fail("mode=%d 的合法 peering bit 和源码对不上，DIR_BIT 常量需要重新校准" % mode)
			return


# ------------------------------------------------------------
# 2) 建 TileSet：两个图集源 = 两个地形，出边量出来
# ------------------------------------------------------------

func _build_tileset(sides_mode: int) -> TileSet:
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

	var used := 0
	for src_idx in range(2):
		var path: String = ATLAS_A if src_idx == 0 else ATLAS_B
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img == null:
			_fail("读不到图集 %s" % path)
			return null
		var src := TileSetAtlasSource.new()
		src.texture = ImageTexture.create_from_image(img)
		# ⚠ texture_region_size 默认 16x16 且**不跟 tile_size 走**（本项目踩过，
		#    症状是"每格一小角色斑"），见 map_generator.gd:1391 的注释。
		src.texture_region_size = Vector2i(TILE, TILE)
		ts.add_source(src, src_idx)
		for cy in range(ROWS):
			for cx in range(COLS):
				var sides := _cell_sides(img, cx, cy)
				if sides.is_empty():
					continue
				_sides[src_idx][Vector2i(cx, cy)] = sides
				src.create_tile(Vector2i(cx, cy))
				var td := src.get_tile_data(Vector2i(cx, cy), 0)
				if td == null:
					continue
				td.set_terrain_set(0)
				td.set_terrain(src_idx)
				var other := 1 - src_idx
				for d in range(4):
					# 铺到边 = 这一侧允许同地形；切开 = 这一侧是另一种地形
					td.set_terrain_peering_bit(DIR_BIT[d], src_idx if bool(sides[d]) else other)
				if not sides.has(false) and _solid[src_idx].x < 0:
					_solid[src_idx] = Vector2i(cx, cy)
				used += 1
		print("[TerrainSandbox] 源%d %s → 进地形集 %d 格，内部块 %s" % [
				src_idx, path.get_file(), _sides[src_idx].size(), str(_solid[src_idx])])
	if used < 32:
		_fail("可用瓦片太少（%d）：出边阈值或图集不对" % used)
		return null
	return ts


## 遍历 4 条边各取 2px 带，返回 [上,右,下,左] 是否铺满；整格内容不足则返回空数组
func _cell_sides(img: Image, cx: int, cy: int) -> Array:
	var x0 := cx * TILE
	var y0 := cy * TILE
	var total := 0
	for y in range(TILE):
		for x in range(TILE):
			if img.get_pixelv(Vector2i(x0 + x, y0 + y)).a > 0.15:
				total += 1
	if float(total) / float(TILE * TILE) < CELL_MIN_ALPHA:
		return []
	var out: Array = []
	for d in range(4):
		var hit := 0
		var cnt := 0
		for t in range(2):
			for k in range(TILE):
				var p := Vector2i(0, 0)
				match d:
					0: p = Vector2i(x0 + k, y0 + t)              # 上
					1: p = Vector2i(x0 + TILE - 1 - t, y0 + k)   # 右
					2: p = Vector2i(x0 + k, y0 + TILE - 1 - t)   # 下
					3: p = Vector2i(x0 + t, y0 + k)              # 左
				cnt += 1
				if img.get_pixelv(p).a > 0.15:
					hit += 1
		out.append(float(hit) / float(cnt) >= EDGE_FULL)
	return out


# ------------------------------------------------------------
# 3) 铺地图：底层实心背景 + 上层地形集自动过渡
# ------------------------------------------------------------

func _build_scene(ts: TileSet) -> Node2D:
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

	var a_cells: Array[Vector2i] = []
	var b_cells: Array[Vector2i] = []
	for y in range(GRID_H):
		for x in range(GRID_W):
			if _is_a(x, y):
				a_cells.append(Vector2i(x, y))
			else:
				b_cells.append(Vector2i(x, y))
			bg.set_cell(Vector2i(x, y), 1, _solid[1])

	# 先铺满 B 再压 A：B 是底，A 是岛。两次 connect 都会顺带修正邻居的瓦片。
	terrain.set_cells_terrain_connect(b_cells, 0, 1, false)
	terrain.set_cells_terrain_connect(a_cells, 0, 0, false)
	print("[TerrainSandbox] 铺完 %dx%d：亮草 %d 格 / 青苔 %d 格" % [
			GRID_W, GRID_H, a_cells.size(), b_cells.size()])
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
# 4) oracle：选中瓦片的实际出边 vs 邻居真实地形
# ------------------------------------------------------------

## 三条边对表：量出来的（我写进去的依据）↔ 瓦片里实际存的 bit ↔ 邻居到底是什么地形
## 只有第三种不一致才是「自动过渡没生效」，前一种是配置写错了，得分开计数。
func _verify(root: Node2D, quiet: bool = false) -> int:
	var layer := root.get_node("Terrain") as TileMapLayer
	var ts: TileSet = layer.tile_set
	var bad := 0        # 自动过渡选错瓦片
	var misconfig := 0  # 我写进去的 bit 和量出来的边不一致
	var checked := 0
	var no_tile := 0
	var by_dir := [0, 0, 0, 0]
	for y in range(1, GRID_H - 1):
		for x in range(1, GRID_W - 1):
			var c := Vector2i(x, y)
			var src_id := layer.get_cell_source_id(c)
			var coords := layer.get_cell_atlas_coords(c)
			if src_id < 0 or coords.x < 0:
				no_tile += 1
				continue
			var mine := int(src_id)
			var sides: Array = _sides[mine].get(coords, [])
			if sides.is_empty():
				no_tile += 1
				continue
			var td: TileData = ts.get_source(mine).get_tile_data(coords, 0)
			checked += 1
			for d in range(4):
				var nb_src := int(layer.get_cell_source_id(c + DIR_VEC[d]))
				# 我写 bit 时的意图：这一侧允许本地形（铺满）↔ 邻居就是本地形
				var want_same: bool = bool(sides[d])
				var stored := int(td.get_terrain_peering_bit(DIR_BIT[d]))
				if (stored == mine) != want_same:
					misconfig += 1
					if not quiet and misconfig <= 6:
						print("[TerrainSandbox] 写入错 格%s 源%d %s %s：边=%s 但存的 bit=%d" % [
								str(c), mine, str(coords), _DIR_NAME[d], str(want_same), stored])
					continue
				if want_same != (nb_src == mine):
					bad += 1
					by_dir[d] += 1
					if not quiet and bad <= 12:
						print("[TerrainSandbox] 选错块 格%s 源%d %s %s：瓦片出边=%s 邻居源=%d" % [
								str(c), mine, str(coords), _DIR_NAME[d], str(want_same), nb_src])
	if not quiet:
		print("[TerrainSandbox] 校验：查 %d 格 / 无瓦片 %d 格 ｜ 写入错 %d ｜ 自动过渡选错 %d（上%d 右%d 下%d 左%d）" % [
				checked, no_tile, misconfig, bad, by_dir[0], by_dir[1], by_dir[2], by_dir[3]])
	return bad + misconfig


# ------------------------------------------------------------
# 5) 存盘（.tres + .tscn），供编辑器打开继续看/改
# ------------------------------------------------------------

func _save(root: Node2D) -> void:
	var layer := root.get_node("Terrain") as TileMapLayer
	var err_ts := ResourceSaver.save(layer.tile_set, "res://Dev/terrain_sandbox_tileset.tres")
	var pack := PackedScene.new()
	var err_sc := pack.pack(root)
	if err_sc == OK:
		err_sc = ResourceSaver.save(pack, "res://Dev/terrain_sandbox.tscn")
	print("[TerrainSandbox] 存盘：tileset=%d scene=%d（.tres/.tscn 都是文本，编辑器里可直接打开）" % [
			err_ts, err_sc])


func _fail(msg: String) -> void:
	push_error("[TerrainSandbox] " + msg)
	get_tree().quit(1)

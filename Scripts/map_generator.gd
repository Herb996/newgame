class_name MapGenerator
extends RefCounted
## ============================================================
## MapGenerator — 程序化地图生成
##
## 分三层渲染（2026-09-15 改版，见 03_ART_STYLE_GUIDE「地形美术」）：
##   1. 地形层 TileMapLayer：噪声生成，地板 6 变体 / 墙 4 变体 + 墙顶受光变体，
##      变体按格子哈希确定性挑选（同一格每次生成同一张图，不会闪）。
##   2. 装饰层 Node2D：树 / 石头（并入 walls，参与寻路与连通性）、
##      地面残骸（纯视觉，不阻挡）。贴地投影 + 2.5D 高度。
##   3. 雾层（FogSystem，z_index 5）：盖住未探索区，装饰层 z_index 0 会被盖住。
##
## 关键区分：
##   terrain[y][x] → 渲染用（0 地板 / 1 墙）
##   walls[y][x]   → 通行用（墙 或 树 或 石头 = true）
##   两者不同：树所在格渲染成地板，但通行上是障碍。
##
## 数值全部来自 Data/config.json 的 map / map.decor 节点。
##
## 用法：var result = MapGenerator.generate()
##   result.node    → Node2D（含 TileMapLayer + 装饰层），加入场景树即显示
##   result.spawn   → Vector2 玩家出生点（像素坐标）
##   result.walls   → 通行网格；result.reachable → 可达网格（从出生点走得到）
##   result.reachable_ratio → 可达地板占比，低于 map.min_reachable_ratio 应重生成
##
## 连通性：生成后从出生点洪水填充；main.gd 按 reachable_ratio 决定是否
## 换种子重新生成，撤离点/敌人只刷在可达格内。
## ============================================================

# ---------- 瓦片图集布局（一行排列，图集 y 恒为 0）----------
const FLOOR_VARIANTS := 6        # 地板变体数
const WALL_VARIANTS := 4         # 墙体变体数
const ATLAS_FLOOR := 0           # 地板起始列
const ATLAS_WALL := 6            # 墙体起始列（= FLOOR_VARIANTS）
const ATLAS_WALL_TOP := 10       # 墙顶受光起始列（= FLOOR + WALL）
const ATLAS_COLS := 14           # 图集总列数
const ATLAS_SEED := 20260915     # 图集固定种子：外观稳定，不随地图变化

# ---------- 装饰物类型 ----------
const DECOR_NONE := 0
const DECOR_TREE := 1
const DECOR_ROCK := 2
const DECOR_DEBRIS := 3

# ---------- 调色板（03_ART_STYLE_GUIDE：暗棕/铜锈/蒸汽白）----------
const C_FLOOR := Color(0.23, 0.18, 0.14)   # 暗棕地面
const C_WALL := Color(0.55, 0.33, 0.16)    # 铜锈墙体
const C_RUST := Color(0.66, 0.45, 0.24)    # 铜锈高光
const C_MOSS := Color(0.20, 0.24, 0.16)    # 苔藓暗绿
const C_STONE := Color(0.36, 0.31, 0.26)   # 碎石
const C_DARK := Color(0.12, 0.09, 0.07)    # 裂纹 / 阴影
const C_OIL := Color(0.09, 0.08, 0.09)     # 油污

static var _decor_tex: Dictionary = {}     # 装饰物贴图缓存（只生成一次）
static var _decor_img: Dictionary = {}     # 装饰物原始 Image（预览合成用）
static var _atlas_img: Image = null        # 瓦片图集 Image（预览合成用）


static func generate() -> Dictionary:
	var width: int = int(Config.get_value("map.width", 128))
	var height: int = int(Config.get_value("map.height", 128))
	var tile_size: int = int(Config.get_value("map.tile_size", 16))
	var threshold: float = float(Config.get_value("map.noise_threshold", 0.25))

	var noise := FastNoiseLite.new()
	noise.frequency = float(Config.get_value("map.noise_frequency", 0.03))
	noise.seed = randi()  # 每局随机种子

	# 装饰物用独立噪声：成片分布（林子/石堆），而不是均匀撒点
	var veg := FastNoiseLite.new()
	veg.frequency = float(Config.get_value("map.decor.noise_frequency", 0.09))
	veg.seed = randi()

	var rng := RandomNumberGenerator.new()
	rng.seed = randi()

	var tree_d: float = float(Config.get_value("map.decor.tree_density", 0.035))
	var rock_d: float = float(Config.get_value("map.decor.rock_density", 0.022))
	var debris_d: float = float(Config.get_value("map.decor.debris_density", 0.030))
	var veg_threshold: float = float(Config.get_value("map.decor.noise_threshold", 0.10))
	var clear_r: int = int(Config.get_value("map.decor.clear_spawn_radius_cells", 3))

	var layer := TileMapLayer.new()
	layer.name = "TileMapLayer"
	layer.tile_set = _build_tileset(tile_size)

	var center := Vector2i(width / 2, height / 2)

	# ---- 第一遍：地形 + 装饰选址 ----
	var terrain: Array = []   # 渲染用：0 地板 / 1 墙
	var walls: Array = []     # 通行用：墙或实体装饰 = true
	var decor: Array = []     # 装饰类型
	for y in range(height):
		var trow: Array = []
		var wrow: Array = []
		var drow: Array = []
		for x in range(width):
			var is_wall: bool = noise.get_noise_2d(x, y) > threshold
			# 地图四周强制 1 圈墙：玩家不可能跑出地图（与基地外圈墙一致）
			if x == 0 or y == 0 or x == width - 1 or y == height - 1:
				is_wall = true
			# 中心 5x5 出生区强制为地板，保证玩家不出生在墙里
			elif abs(x - center.x) <= 2 and abs(y - center.y) <= 2:
				is_wall = false
			trow.append(is_wall)
			wrow.append(is_wall)
			drow.append(DECOR_NONE)
		terrain.append(trow)
		walls.append(wrow)
		decor.append(drow)

	# 装饰只落在地板上；出生区留空；树/石头并入 walls（寻路会绕开）
	for y in range(1, height - 1):
		for x in range(1, width - 1):
			if terrain[y][x]:
				continue
			if abs(x - center.x) <= clear_r and abs(y - center.y) <= clear_r:
				continue
			if veg.get_noise_2d(x, y) <= veg_threshold:
				continue
			var r := rng.randf()
			var kind := DECOR_NONE
			if r < tree_d:
				kind = DECOR_TREE
			elif r < tree_d + rock_d:
				kind = DECOR_ROCK
			elif r < tree_d + rock_d + debris_d:
				kind = DECOR_DEBRIS
			if kind == DECOR_NONE:
				continue
			decor[y][x] = kind
			if kind == DECOR_TREE or kind == DECOR_ROCK:
				walls[y][x] = true   # 实体障碍，参与寻路与连通性

	# ---- 第二遍：渲染瓦片（墙顶受光判断依赖最终 terrain）----
	for y in range(height):
		for x in range(width):
			if terrain[y][x]:
				# 上方是地板 → 这格是墙的顶面，加受光边（2.5D 俯视的体积感）
				var is_top: bool = (y > 0 and not terrain[y - 1][x])
				var v := _variant(x, y, WALL_VARIANTS)
				var col: int = ATLAS_WALL_TOP + v if is_top else ATLAS_WALL + v
				layer.set_cell(Vector2i(x, y), 0, Vector2i(col, 0))
			else:
				layer.set_cell(Vector2i(x, y), 0, Vector2i(_variant(x, y, FLOOR_VARIANTS), 0))

	# ---- 装饰层 ----
	var decor_root := Node2D.new()
	decor_root.name = "DecorLayer"
	decor_root.y_sort_enabled = true   # 同层内按 y 排序，下方的树遮上方的树
	var counts := {DECOR_TREE: 0, DECOR_ROCK: 0, DECOR_DEBRIS: 0}
	for y in range(height):
		for x in range(width):
			var k: int = decor[y][x]
			if k == DECOR_NONE:
				continue
			var s := Sprite2D.new()
			s.texture = _decor_texture(k)
			if s.texture == null:
				continue
			s.centered = false
			var tex_size := Vector2(s.texture.get_size())
			# 脚底对齐格心（图片底边落在格心下方 2px，视觉上"站在"这一格）
			s.position = Vector2(x * tile_size + tile_size * 0.5,
								 y * tile_size + tile_size * 0.5)
			s.offset = Vector2(-tex_size.x * 0.5, 2.0 - tex_size.y)
			s.z_index = 0   # 与地形同层：玩家（z=1）始终在前景，未探索区被雾盖住
			decor_root.add_child(s)
			counts[k] = int(counts[k]) + 1

	var root := Node2D.new()
	root.name = "MapRoot"
	root.add_child(layer)
	root.add_child(decor_root)

	var spawn := Vector2(center) * tile_size + Vector2(tile_size * 0.5, tile_size * 0.5)

	# 可达性分析：从出生点洪水填充，算出玩家实际走得到的区域
	var reachable := _flood_fill(walls, center)
	var floor_count := 0
	var reach_count := 0
	for y in range(height):
		for x in range(width):
			if not walls[y][x]:
				floor_count += 1
				if reachable[y][x]:
					reach_count += 1
	var ratio := float(reach_count) / maxf(float(floor_count), 1.0)

	print("[Map] 地图生成完成：%dx%d 瓦片（%dx%d 像素），地板 %d 格，可达 %d 格（%.0f%%），"
		% [width, height, width * tile_size, height * tile_size, floor_count, reach_count,
		   ratio * 100.0])
	print("[Map] 装饰物：树 %d / 石头 %d / 残骸 %d，出生点 %s"
		% [int(counts[DECOR_TREE]), int(counts[DECOR_ROCK]), int(counts[DECOR_DEBRIS]), spawn])
	return {"node": root, "spawn": spawn, "spawn_cell": center,
			"walls": walls, "reachable": reachable, "reachable_ratio": ratio,
			"terrain": terrain, "decor": decor, "tile_size": tile_size}


## ------------------------------------------------------------
## 预览合成：不依赖渲染驱动，直接把瓦片与装饰像素拼成一张 PNG。
## cells = 截取边长（格），以出生点为中心。供 debug.map_preview 使用，
## 无头环境（dummy 驱动）也能出图。
## ------------------------------------------------------------
static func build_preview(result: Dictionary, cells: int) -> Image:
	var ts: int = int(result["tile_size"])
	var terrain: Array = result["terrain"]
	var decor: Array = result["decor"]
	var h: int = terrain.size()
	var w: int = terrain[0].size()
	var c: Vector2i = result["spawn_cell"]
	var x0: int = clampi(c.x - cells / 2, 0, maxi(0, w - cells))
	var y0: int = clampi(c.y - cells / 2, 0, maxi(0, h - cells))
	var out := Image.create(mini(cells, w) * ts, mini(cells, h) * ts, false,
			Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 1))

	# 地形层：从缓存图集按格复制（变体选择逻辑与渲染时完全一致）
	if _atlas_img != null:
		for y in range(mini(cells, h)):
			for x in range(mini(cells, w)):
				var gx: int = x0 + x
				var gy: int = y0 + y
				var col: int
				if terrain[gy][gx]:
					var is_top: bool = (gy > 0 and not terrain[gy - 1][gx])
					var v := _variant(gx, gy, WALL_VARIANTS)
					col = ATLAS_WALL_TOP + v if is_top else ATLAS_WALL + v
				else:
					col = _variant(gx, gy, FLOOR_VARIANTS)
				out.blit_rect(_atlas_img, Rect2i(col * ts, 0, ts, ts),
						Vector2i(x * ts, y * ts))

	# 装饰层：按 y 递增绘制（等价于 y_sort，下方的遮上方的）
	for y in range(mini(cells, h)):
		for x in range(mini(cells, w)):
			var gy: int = y0 + y
			var gx: int = x0 + x
			var k: int = decor[gy][gx]
			if k == DECOR_NONE or not _decor_img.has(k):
				continue
			var src: Image = _decor_img[k]
			# 与游戏中 Sprite2D 的对齐方式一致：脚底落在格心下方 2px
			var dx: int = int(x * ts + ts * 0.5 - src.get_width() * 0.5)
			var dy: int = int(y * ts + ts * 0.5 + 2.0 - src.get_height())
			_blend(out, src, dx, dy)
	return out


## 把 src 以 alpha 混合方式叠到 out 的 (dx, dy) 处
static func _blend(out: Image, src: Image, dx: int, dy: int) -> void:
	for y in range(src.get_height()):
		for x in range(src.get_width()):
			var s := src.get_pixel(x, y)
			if s.a <= 0.02:
				continue
			var ox: int = dx + x
			var oy: int = dy + y
			if ox < 0 or oy < 0 or ox >= out.get_width() or oy >= out.get_height():
				continue
			var d := out.get_pixel(ox, oy)
			var a: float = s.a
			out.set_pixel(ox, oy, Color(s.r * a + d.r * (1.0 - a),
					s.g * a + d.g * (1.0 - a), s.b * a + d.b * (1.0 - a), 1.0))


## ------------------------------------------------------------
## 瓦片图集：程序化生成多纹理变体（零素材依赖，改配色即生效）
## ------------------------------------------------------------

## 确定性变体选择：同一格永远得到同一个变体，重生成地图不会闪烁
static func _variant(x: int, y: int, count: int) -> int:
	var h: int = (x * 73856093) ^ (y * 19349663)
	h = h ^ (h >> 13)
	h = h ^ (h << 7)
	return absi(h) % count


static func _build_tileset(tile_size: int) -> TileSet:
	var img := Image.create(tile_size * ATLAS_COLS, tile_size, false, Image.FORMAT_RGB8)
	img.fill(C_FLOOR)
	var rng := RandomNumberGenerator.new()
	rng.seed = ATLAS_SEED  # 固定种子：图集外观稳定

	for v in range(FLOOR_VARIANTS):
		_paint_floor(img, (ATLAS_FLOOR + v) * tile_size, tile_size, v, rng)
	for v in range(WALL_VARIANTS):
		_paint_wall(img, (ATLAS_WALL + v) * tile_size, tile_size, v, rng, false)
	for v in range(WALL_VARIANTS):
		_paint_wall(img, (ATLAS_WALL_TOP + v) * tile_size, tile_size, v, rng, true)
	# 缓存一份 RGBA 副本供预览合成（图集本身是 RGB8，无法直接 blit 到 RGBA 画布）
	_atlas_img = img.duplicate()
	_atlas_img.convert(Image.FORMAT_RGBA8)

	var ts := TileSet.new()
	ts.tile_size = Vector2i(tile_size, tile_size)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	for i in range(ATLAS_COLS):
		src.create_tile(Vector2i(i, 0))
	ts.add_source(src, 0)

	# 碰撞：所有墙变体（普通 + 墙顶）都是整格实心
	ts.add_physics_layer()
	for i in range(ATLAS_WALL, ATLAS_WALL_TOP + WALL_VARIANTS):
		var d := src.get_tile_data(Vector2i(i, 0), 0)
		d.set_collision_polygons_count(0, 1)
		d.set_collision_polygon_points(0, 0, PackedVector2Array([
			Vector2(0, 0), Vector2(tile_size, 0),
			Vector2(tile_size, tile_size), Vector2(0, tile_size),
		]))
	return ts


## 地板：暗棕底 + 颗粒噪点，各变体再加一种地表特征
static func _paint_floor(img: Image, ox: int, ts: int, variant: int,
		rng: RandomNumberGenerator) -> void:
	for y in range(ts):
		for x in range(ts):
			_set_rgb(img, ox + x, y, C_FLOOR * rng.randf_range(0.82, 1.18))
	match variant:
		1:  # 碎石：几颗亮石子 + 下方投影
			for _i in range(rng.randi_range(3, 6)):
				var px := rng.randi_range(1, ts - 2)
				var py := rng.randi_range(1, ts - 3)
				_set_rgb(img, ox + px, py, C_STONE * rng.randf_range(0.85, 1.15))
				_set_rgb(img, ox + px, py + 1, C_DARK)
		2:  # 裂纹：一条自上而下的折线
			var cx := rng.randi_range(2, ts - 3)
			for y in range(1, ts - 1):
				_set_rgb(img, ox + cx, y, C_DARK)
				cx = clampi(cx + rng.randi_range(-1, 1), 1, ts - 2)
		3:  # 苔藓：几团暗绿
			for _i in range(3):
				var mx := rng.randi_range(2, ts - 3)
				var my := rng.randi_range(2, ts - 3)
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if rng.randf() < 0.62:
							_set_rgb(img, ox + mx + dx, my + dy,
								C_MOSS * rng.randf_range(0.85, 1.2))
		4:  # 金属碎屑：零星铜锈点
			for _i in range(rng.randi_range(2, 5)):
				var px := rng.randi_range(1, ts - 2)
				var py := rng.randi_range(1, ts - 2)
				_set_rgb(img, ox + px, py, C_RUST * rng.randf_range(0.7, 1.0))
		5:  # 油污：中央一团暗斑
			var mx := rng.randi_range(4, ts - 5)
			var my := rng.randi_range(4, ts - 5)
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					if dx * dx + dy * dy <= 5 and rng.randf() < 0.8:
						_set_rgb(img, ox + mx + dx, my + dy, C_OIL)
		_:
			pass  # 变体 0：纯噪点，作为"干净地面"间隔用


## 墙体：铜锈底 + 颗粒噪点，变体加砖缝/铆钉/管道；
## is_top（墙顶）整体提亮并在首行加高光边，模拟 2.5D 受光顶面
static func _paint_wall(img: Image, ox: int, ts: int, variant: int,
		rng: RandomNumberGenerator, is_top: bool) -> void:
	var base := C_WALL
	if is_top:
		base = base.lightened(0.16)
	for y in range(ts):
		for x in range(ts):
			_set_rgb(img, ox + x, y, base * rng.randf_range(0.86, 1.14))
	match variant:
		1:  # 砖缝：两条横向暗线 + 交错竖缝
			for line_y in [ts / 3, ts * 2 / 3]:
				for x in range(ts):
					_set_rgb(img, ox + x, line_y, base * 0.55)
			var sx := ts / 2 if (variant % 2 == 0) else ts / 4
			for y in range(ts / 3):
				_set_rgb(img, ox + sx, y, base * 0.6)
		2:  # 铆钉：四角亮点 + 下方暗边
			for p in [Vector2i(2, 2), Vector2i(ts - 3, 2),
					  Vector2i(2, ts - 3), Vector2i(ts - 3, ts - 3)]:
				_set_rgb(img, ox + p.x, p.y, C_RUST)
				_set_rgb(img, ox + p.x, p.y + 1, base * 0.5)
		3:  # 竖管道：中间一条铜锈凸管
			var px := ts / 2 - 1
			for y in range(ts):
				_set_rgb(img, ox + px, y, C_RUST * rng.randf_range(0.9, 1.1))
				_set_rgb(img, ox + px + 1, y, base * 0.6)
		_:
			pass
	if is_top:
		for x in range(ts):
			_set_rgb(img, ox + x, 0, base.lightened(0.45))


## ------------------------------------------------------------
## 装饰物贴图（程序化，缓存复用；素材到位后可换成外部 PNG）
## ------------------------------------------------------------

static func _decor_texture(kind: int) -> Texture2D:
	if _decor_tex.has(kind):
		return _decor_tex[kind]
	var img: Image
	match kind:
		DECOR_TREE:
			img = _make_tree()
		DECOR_ROCK:
			img = _make_rock()
		DECOR_DEBRIS:
			img = _make_debris()
		_:
			return null
	_decor_img[kind] = img
	var tex := ImageTexture.create_from_image(img)
	_decor_tex[kind] = tex
	return tex


## 蒸汽朋克枯树：暗棕树干 + 铜锈色枯枝 + 稀疏暗绿树冠 + 脚下投影
static func _make_tree() -> Image:
	var w := 26
	var h := 34
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 776241
	# 脚下投影（贴地感）
	_ellipse(img, w / 2, h - 3, 8, 3, Color(0, 0, 0, 0.35), rng, 0.0)
	# 树干：下粗上细
	for y in range(13, h - 2):
		var tw: int = 3 if y > 25 else 2
		for x in range(w / 2 - tw, w / 2 + tw + 1):
			_set_rgba(img, x, y, Color(0.26, 0.19, 0.13) * rng.randf_range(0.85, 1.15))
	# 树冠：四团错落，暗绿偏枯
	var blobs: Array = [[13, 11, 9, 8], [8, 15, 6, 5], [18, 14, 6, 6], [13, 4, 6, 5]]
	for b in blobs:
		_ellipse(img, b[0], b[1], b[2], b[3], Color(0.22, 0.26, 0.17), rng, 0.12)
	# 枯枝点缀：铜锈色短线，破掉纯绿树冠
	for _i in range(6):
		var bx: int = rng.randi_range(6, 19)
		var by: int = rng.randi_range(4, 18)
		_set_rgba(img, bx, by, C_RUST * 0.8)
		_set_rgba(img, bx + 1, by, C_RUST * 0.6)
	return img


## 石头：灰岩团块 + 左上受光 + 右下暗部
static func _make_rock() -> Image:
	var w := 20
	var h := 16
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 512927
	_ellipse(img, w / 2, h - 3, 7, 2, Color(0, 0, 0, 0.32), rng, 0.0)
	_ellipse(img, w / 2, h / 2 - 1, 8, 5, Color(0.35, 0.35, 0.38), rng, 0.10)
	# 左上高光
	_ellipse(img, w / 2 - 3, h / 2 - 4, 4, 2, Color(0.52, 0.52, 0.55), rng, 0.06)
	# 右下暗部
	_ellipse(img, w / 2 + 3, h / 2 + 2, 5, 3, Color(0.20, 0.20, 0.22), rng, 0.06)
	return img


## 地面残骸：齿轮碎片 / 断管，贴地不阻挡
static func _make_debris() -> Image:
	var w := 16
	var h := 12
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 314159
	# 两段铜锈断管
	for y in range(5, 8):
		for x in range(2, 9):
			_set_rgba(img, x, y, C_RUST * rng.randf_range(0.7, 1.0))
	for y in range(6, 10):
		for x in range(9, 12):
			_set_rgba(img, x, y, C_RUST * rng.randf_range(0.6, 0.85))
	# 齿轮碎块
	_ellipse(img, 12, 5, 3, 3, Color(0.42, 0.38, 0.30), rng, 0.14)
	_ellipse(img, 12, 5, 1, 1, Color(0.16, 0.14, 0.12), rng, 0.0)
	return img


## ------------------------------------------------------------
## 像素绘制小工具（全部带越界保护）
## ------------------------------------------------------------

static func _set_rgb(img: Image, x: int, y: int, c: Color) -> void:
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return
	img.set_pixel(x, y, Color(clampf(c.r, 0.0, 1.0), clampf(c.g, 0.0, 1.0),
							  clampf(c.b, 0.0, 1.0)))


static func _set_rgba(img: Image, x: int, y: int, c: Color) -> void:
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return
	var a: float = c.a
	img.set_pixel(x, y, Color(clampf(c.r, 0.0, 1.0), clampf(c.g, 0.0, 1.0),
							  clampf(c.b, 0.0, 1.0), clampf(a, 0.0, 1.0)))


## 填充椭圆（cx,cy 中心；rx,ry 半径；noise 为逐像素亮度扰动幅度）
static func _ellipse(img: Image, cx: int, cy: int, rx: int, ry: int, c: Color,
		rng: RandomNumberGenerator, noise: float) -> void:
	if rx <= 0 or ry <= 0:
		return
	for y in range(cy - ry, cy + ry + 1):
		for x in range(cx - rx, cx + rx + 1):
			var dx := float(x - cx) / float(rx)
			var dy := float(y - cy) / float(ry)
			if dx * dx + dy * dy > 1.0:
				continue
			var col := c
			if noise > 0.0:
				col = Color(c.r * rng.randf_range(1.0 - noise, 1.0 + noise),
							c.g * rng.randf_range(1.0 - noise, 1.0 + noise),
							c.b * rng.randf_range(1.0 - noise, 1.0 + noise),
							c.a)
			# 边缘做半透明羽化，避免硬锯齿
			var edge := 1.0 - (dx * dx + dy * dy)
			if edge < 0.35 and c.a >= 1.0:
				col = Color(col.r, col.g, col.b, 0.65)
			_set_rgba(img, x, y, col)


## ------------------------------------------------------------
## 连通性 / 寻路
## ------------------------------------------------------------

## 从 start 出发对可通行格做 BFS 洪水填充，返回 reachable[y][x] 布尔网格。
## 撤离点/敌人都应只刷在 reachable = true 的格子，保证玩家走得通。
static func _flood_fill(walls: Array, start: Vector2i) -> Array:
	var h: int = walls.size()
	var w: int = walls[0].size()
	var reachable: Array = []
	for y in range(h):
		var row: Array = []
		row.resize(w)
		for x in range(w):
			row[x] = false
		reachable.append(row)
	if walls[start.y][start.x]:
		return reachable  # 出生点本身是墙（理论上不会发生，有 5x5 清空区）
	var queue: Array = [start]
	reachable[start.y][start.x] = true
	var head := 0
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + dir
			if n.x < 0 or n.y < 0 or n.x >= w or n.y >= h:
				continue
			if walls[n.y][n.x] or reachable[n.y][n.x]:
				continue
			reachable[n.y][n.x] = true
			queue.append(n)
	return reachable


## ============================================================
## 瓦片级寻路（Godot 内置 AStarGrid2D，C++ 实现）
##
## 性能铁律：AStarGrid2D 的构建（update + 逐格 set_point_solid）是
## O(宽×高) 的 GDScript 循环，一张 128x128 图约 1.6 万格，
## 绝不能每帧执行！正确用法：
##   1. 地图生成/切换时调用一次 build_astar(walls, tile_size) 缓存网格；
##   2. 每次寻路直接对缓存网格调 get_point_path（纯 C++，微秒级）。
##
## astar_path() 是"一次性构建+查询"的便捷封装，仅适合低频调用
## （如点击移动的单次寻路），禁止放进 _process/_physics_process。
## 输出：PackedVector2Array 格子中心像素坐标路径；无解返回空数组
## 4 方向 ONLY，避免切角。
## ============================================================

## 构建并缓存用 AStarGrid2D（每张地图只调一次）
static func build_astar(walls: Array, tile_size: int) -> AStarGrid2D:
	var h: int = walls.size()
	var w: int = walls[0].size()
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, w, h)
	grid.cell_size = Vector2i(tile_size, tile_size)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.update()
	for y in range(h):
		for x in range(w):
			if walls[y][x]:
				grid.set_point_solid(Vector2i(x, y))
	return grid


## 把 AStarGrid2D.get_id_path 返回的格子坐标换算成格心像素坐标。
## 铁律：不要直接用 get_point_path 的返回值——它给出的是格子左上角
## （= region.position + 格子坐标 × cell_size），比格心偏半个格，
## 路径会贴着墙线和墙角走，玩家在拐角必然顶墙卡死。
static func ids_to_centers(ids: Array, tile_size: int) -> PackedVector2Array:
	var half := tile_size * 0.5
	var path := PackedVector2Array()
	path.resize(ids.size())
	for i in range(ids.size()):
		var c: Vector2i = ids[i]
		path[i] = Vector2(c.x * tile_size + half, c.y * tile_size + half)
	return path


## 一次性"构建+查询"封装（低频调用；高频寻路请用 build_astar 缓存网格）
static func astar_path(walls: Array, tile_size: int, start_px: Vector2,
		end_px: Vector2) -> PackedVector2Array:
	var h: int = walls.size()
	if h == 0:
		return PackedVector2Array()
	var w: int = walls[0].size()
	var start_cell := Vector2i(int(start_px.x / tile_size), int(start_px.y / tile_size))
	var end_cell := Vector2i(int(end_px.x / tile_size), int(end_px.y / tile_size))
	if start_cell.x < 0 or start_cell.y < 0 or start_cell.x >= w or start_cell.y >= h:
		return PackedVector2Array()
	if end_cell.x < 0 or end_cell.y < 0 or end_cell.x >= w or end_cell.y >= h:
		return PackedVector2Array()
	if walls[start_cell.y][start_cell.x] or walls[end_cell.y][end_cell.x]:
		return PackedVector2Array()
	if start_cell == end_cell:
		var c: Vector2 = Vector2(end_cell.x * tile_size + tile_size * 0.5,
								 end_cell.y * tile_size + tile_size * 0.5)
		return PackedVector2Array([c])

	var grid := build_astar(walls, tile_size)
	return ids_to_centers(grid.get_id_path(start_cell, end_cell), tile_size)

class_name MapGenerator
extends RefCounted
## ============================================================
## MapGenerator — 程序化地图生成
##
## 三层渲染（2026-09-15 改版，见 03_ART_STYLE_GUIDE「地形美术」）：
##   1. 地形层 TileMapLayer：生物群系分区（数量由 config.json 的 map.biomes 决定，
##      当前含草地共 5 种）+ 每群系地板 12 变体 / 墙 6 变体 + 墙顶受光变体；
##      变体按格子哈希确定性挑选。
##   2. 装饰层 Node2D：树 / 石头（并入 walls，参与寻路与连通性）、
##      地面残骸（纯视觉，不阻挡）。贴地投影 + 2.5D 高度。
##      每株装饰随机缩放/翻转/亮度 + 按群系色调，消除克隆感。
##   3. 雾层（FogSystem，z_index 5）：盖住未探索区，装饰层 z_index 0 会被盖住。
##
## 【贴图来源】地形瓦片与装饰物贴图均为 AI 生成的 2.5D 手绘质感素材，
## 由 tools/ 下的 Python 脚本离线处理好放进 Assets/Art/：
##   Assets/Art/Tiles/atlas_floor.png  N 群系 x 12 变体（横向一行，N=biome_count）
##   Assets/Art/Tiles/atlas_wall.png   N 群系 x  6 变体
##   Assets/Art/Sprites/Decor/{tree,rock,debris}_00.png  透明通道精灵
## 贴图缺失时自动回退到程序化逐像素绘制（_paint_floor/_paint_wall/
## _make_tree/...），保证工程在任何状态下都能跑起来。
##
## 关键区分：
##   terrain[y][x] → 渲染用（0 地板 / 1 墙）
##   walls[y][x]   → 通行用（墙 或 树 或 石头 = true）
##   biome[y][x]   → 生物群系 id（0..BIOME_COUNT-1），决定地板/墙基色与装饰配方
##   三者不同：树所在格渲染成地板，但通行上是障碍。
##
## 数值全部来自 Data/config.json 的 map / map.decor 节点。
##
## 用法：var result = MapGenerator.generate()
##   result.node    → Node2D（含 TileMapLayer + 装饰层），加入场景树即显示
##   result.spawn   → Vector2 玩家出生点（像素坐标）
##   result.walls   → 通行网格；result.reachable → 可达网格（从出生点走得到）
##   result.biome   → 群系网格
##   result.reachable_ratio → 可达地板占比，低于 map.min_reachable_ratio 应重生成
##
## 连通性：生成后从出生点洪水填充；main.gd 按 reachable_ratio 决定是否
## 换种子重新生成，撤离点/敌人只刷在可达格内。
## ============================================================

# ---------- 瓦片图集布局（横向一行，图集 y 恒为 0）----------
# 每个 biome 各自拥有一组地板/墙/墙顶变体，使不同区域观感明显区分
const FLOOR_VARIANTS := 12       # 单 biome 地板变体数
const WALL_VARIANTS := 6         # 单 biome 墙体变体数
const ATLAS_FLOOR := 0           # 地板起始列
const ATLAS_SEED := 20260915     # 回退图集固定种子：外观稳定，不随地图变化

# 生物群系数量与图集列布局：不再写死常量，改为运行时从 config.json 的
# map.biomes 读取（biome_count()），因此【加一种地形只改配置、GDScript 零改码】。
# 草地、雪原等后续地形都只需在 config 里加一项，再跑一次 build_tile_atlas.py。
# 图集列数学仍按 BIOME_COUNT 推导，所以自动跟着变。
# 注意：3D 迁移时 RGBA 四通道权重贴图最多只能 4 群系，N 群系需改用
# 「主导群系 id + 次主导 id/权重」数据贴图（见 memory 记录），现在定数据格式就按 N 设计。
static func biome_count() -> int:
	return _biomes().size()

static func atlas_wall_start() -> int:      # 墙体起始列 = 全群系地板列之后
	return FLOOR_VARIANTS * biome_count()

static func atlas_wall_top_start() -> int:  # 墙顶受光起始列 = 全群系墙体列之后
	return atlas_wall_start() + WALL_VARIANTS * biome_count()

static func atlas_cols() -> int:            # 图集总列数
	return atlas_wall_top_start() + WALL_VARIANTS * biome_count()

# ---------- 外部 AI 贴图资源 ----------
const ATLAS_FLOOR_PATH := "res://Assets/Art/Tiles/atlas_floor.png"
const ATLAS_WALL_PATH := "res://Assets/Art/Tiles/atlas_wall.png"
const SRC_TILE := 16             # AI 图集原始瓦片边长（缩放前）

# ---------- 生物群系定义（数据驱动，唯一真相源 = Data/config.json 的 map.biomes）----------
# 每项：{id, name, floor:[r,g,b], wall:[r,g,b], tint:[r,g,b], tree, rock, debris,
#        floor_src?（AI 无缝地面纹理文件名，缺省则程序化生成）}
# 历史默认值（config 缺失时回落，确保工程随时可跑）：
const _DEFAULT_BIOMES := [
	{"name": "林地", "floor": Color(0.20, 0.28, 0.15), "wall": Color(0.42, 0.30, 0.17),
	 "tint": Color(0.93, 0.98, 0.95), "tree": 0.16, "rock": 0.03, "debris": 0.02},
	{"name": "荒原", "floor": Color(0.33, 0.27, 0.18), "wall": Color(0.52, 0.37, 0.20),
	 "tint": Color(1.06, 1.02, 0.96), "tree": 0.025, "rock": 0.040, "debris": 0.07},
	{"name": "锈泽", "floor": Color(0.17, 0.22, 0.16), "wall": Color(0.46, 0.31, 0.18),
	 "tint": Color(0.86, 0.92, 0.93), "tree": 0.05, "rock": 0.02, "debris": 0.06},
	{"name": "石原", "floor": Color(0.31, 0.31, 0.33), "wall": Color(0.50, 0.42, 0.35),
	 "tint": Color(0.85, 0.83, 0.82), "tree": 0.03, "rock": 0.14, "debris": 0.02},
]

static var _biome_cache: Array = []

static func _biomes() -> Array:
	if _biome_cache.is_empty():
		_biome_cache = _load_biomes()
	return _biome_cache

static func _load_biomes() -> Array:
	var raw = Config.get_value("map.biomes", null)
	if raw == null or not (raw is Array) or raw.is_empty():
		return _DEFAULT_BIOMES.duplicate(true)
	var out: Array = []
	for entry in raw:
		var b: Dictionary = {}
		b["name"] = str(entry.get("name", "?"))
		b["floor"] = _arr_to_color(entry.get("floor", [0.30, 0.30, 0.30]))
		b["wall"] = _arr_to_color(entry.get("wall", [0.40, 0.35, 0.30]))
		b["tint"] = _arr_to_color(entry.get("tint", [1.0, 1.0, 1.0]))
		b["tree"] = float(entry.get("tree", 0.05))
		b["rock"] = float(entry.get("rock", 0.03))
		b["debris"] = float(entry.get("debris", 0.02))
		out.append(b)
	return out

static func _biome_at(i: int) -> Dictionary:
	var bs: Array = _biomes()
	return bs[clampi(i, 0, bs.size() - 1)]

static func _biome_tint(i: int) -> Color:
	return _biome_at(i)["tint"]

static func _arr_to_color(a) -> Color:
	if a is Array and a.size() >= 3:
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return Color(0.30, 0.30, 0.30)

# ---------- 调色板（回退绘制用；03_ART_STYLE_GUIDE：暗棕/铜锈/蒸汽白）----------
const C_RUST := Color(0.66, 0.45, 0.24)    # 铜锈高光
const C_MOSS := Color(0.20, 0.24, 0.16)    # 苔藓暗绿
const C_STONE := Color(0.36, 0.31, 0.26)   # 碎石
const C_DARK := Color(0.12, 0.09, 0.07)    # 裂纹 / 阴影
const C_OIL := Color(0.09, 0.08, 0.09)     # 油污

# ---------- 装饰物类型 ----------
const DECOR_NONE := 0
const DECOR_TREE := 1
const DECOR_ROCK := 2
const DECOR_DEBRIS := 3

const DECOR_PATHS := {
	DECOR_TREE: "res://Assets/Art/Sprites/Decor/tree_00.png",
	DECOR_ROCK: "res://Assets/Art/Sprites/Decor/rock_00.png",
	DECOR_DEBRIS: "res://Assets/Art/Sprites/Decor/debris_00.png",
}

# 每类装饰物的基准亮度：石头原画偏浅，直接铺在暗色地表上会过于抢眼，压暗一档
const DECOR_BASE_TINT := {
	DECOR_TREE: Color(1.00, 1.00, 1.00),
	DECOR_ROCK: Color(0.80, 0.80, 0.82),
	DECOR_DEBRIS: Color(0.95, 0.95, 0.95),
}

# ---------- 矿脉（地图资源节点，非装饰、不阻挡通行）----------
const VEIN_IRON := 0
const VEIN_GOLD := 1
const VEIN_OIL := 2
const VEIN_RES := {"iron": VEIN_IRON, "gold": VEIN_GOLD, "oil": VEIN_OIL}
static var _ore_tex: Dictionary = {}     # 矿脉贴图缓存（按 kind）

static var _decor_tex: Dictionary = {}     # 装饰物贴图缓存（只加载/生成一次）
static var _decor_img: Dictionary = {}     # 装饰物原始 Image（预览合成用）
static var _decor_shadow_tex: Dictionary = {}  # 装饰物落地投影贴图缓存（按类别）
static var _atlas_img: Image = null        # 瓦片图集 Image（预览合成用）
static var _used_ai_atlas := false         # 本次图集是否来自 AI 素材（调试用）


static func generate() -> Dictionary:
	var width: int = int(Config.get_value("map.width", 128))
	var height: int = int(Config.get_value("map.height", 128))
	var tile_size: int = int(Config.get_value("map.tile_size", 16))
	var threshold: float = float(Config.get_value("map.noise_threshold", 0.25))

	var noise := FastNoiseLite.new()
	noise.frequency = float(Config.get_value("map.noise_frequency", 0.03))
	noise.seed = randi()  # 每局随机种子

	# 生物群系：低频噪声，把地图切成几大片区域（林地/荒原/锈泽/石原）
	var biome_noise := FastNoiseLite.new()
	biome_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	biome_noise.frequency = float(Config.get_value("map.biome_noise_frequency", 0.008))
	biome_noise.seed = randi()

	# 群系边界抖动噪声：中频，叠在低频群系噪声上，把平滑边界打散成自然犬牙。
	# 没有它，四个群系就是四块硬边色块，像油漆桶填色分区图。
	var edge_noise := FastNoiseLite.new()
	edge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	edge_noise.frequency = float(Config.get_value("map.biome_border_frequency", 0.06))
	edge_noise.seed = randi()

	# 宏观明暗噪声：超低频，制造"大片区"明暗落差（见 _make_macro_light_image）
	var macro_noise := FastNoiseLite.new()
	macro_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	macro_noise.frequency = float(Config.get_value("map.macro_light.frequency", 0.013))
	macro_noise.seed = randi()

	# 装饰物用独立噪声：成片分布（林子/石堆），而不是均匀撒点
	var veg := FastNoiseLite.new()
	veg.frequency = float(Config.get_value("map.decor.noise_frequency", 0.09))
	veg.seed = randi()

	# 成簇噪声：高值区域=植被成片（林子），低值区域=稀疏，制造"成林"而非均匀撒点
	var cluster := FastNoiseLite.new()
	cluster.frequency = float(Config.get_value("map.cluster_noise_frequency", 0.05))
	cluster.seed = randi()

	var density: float = float(Config.get_value("map.decor.density", 0.6))
	var cluster_threshold: float = float(Config.get_value("map.cluster_threshold", 0.5))
	var border_jitter: float = float(Config.get_value("map.biome_border_jitter", 0.055))
	var biome_spread: float = float(Config.get_value("map.biome_spread", 1.35))
	var edge_blend: float = float(Config.get_value("map.biome_edge_blend", 0.45))
	var macro_on: bool = bool(Config.get_value("map.macro_light.enabled", true))
	var macro_strength: float = float(Config.get_value("map.macro_light.strength", 0.22))
	var shadow_on: bool = bool(Config.get_value("map.decor.shadow", true))

	var rng := RandomNumberGenerator.new()
	rng.seed = randi()

	var veg_threshold: float = float(Config.get_value("map.decor.noise_threshold", 0.10))
	var clear_r: int = int(Config.get_value("map.decor.clear_spawn_radius_cells", 3))

	var layer := TileMapLayer.new()
	layer.name = "TileMapLayer"
	layer.tile_set = _build_tileset(tile_size)

	var center := Vector2i(width / 2, height / 2)

	# ---- 第一遍：地形 + 生物群系 + 装饰选址 ----
	var terrain: Array = []   # 渲染用：0 地板 / 1 墙
	var walls: Array = []     # 通行用：墙或实体装饰 = true
	var decor: Array = []     # 装饰类型
	var biome: Array = []     # 生物群系 id（0..BIOME_COUNT-1）
	for y in range(height):
		var trow: Array = []
		var wrow: Array = []
		var drow: Array = []
		var brow: Array = []
		for x in range(width):
			var is_wall: bool = noise.get_noise_2d(x, y) > threshold
			# 地图四周强制 1 圈墙：玩家不可能跑出地图（与基地外圈墙一致）
			if x == 0 or y == 0 or x == width - 1 or y == height - 1:
				is_wall = true
			# 中心 5x5 出生区强制为地板，保证玩家不出生在墙里
			elif abs(x - center.x) <= 2 and abs(y - center.y) <= 2:
				is_wall = false
			# 生物群系：低频噪声分段，再叠中频抖动把边界打散成犬牙。
			# 必须先"扩幅"（biome_spread）：simplex 噪声值集中在 0 附近，直接
			# (n+1)/2 分段会让中间两段吃掉近九成面积，四个群系严重失衡。
			var bf: float = clampf(0.5 + biome_noise.get_noise_2d(x, y) * biome_spread,
					0.0, 1.0)
			bf += edge_noise.get_noise_2d(x, y) * border_jitter
			var b: int = clampi(int(bf * biome_count()), 0, biome_count() - 1)
			trow.append(is_wall)
			wrow.append(is_wall)
			drow.append(DECOR_NONE)
			brow.append(b)
		terrain.append(trow)
		walls.append(wrow)
		decor.append(drow)
		biome.append(brow)

	# 边界渗透：处在两群系交界的格子按概率改判为邻格群系，让两块区域互相"咬"进去。
	# 只靠抖动噪声，边界仍是一条格级直角折线（像素台阶）；渗透才能把它打散成互相
	# 交错的混合带。必须在生成阶段做——放到渲染时临时算，biome 数组与实际渲染、
	# 装饰物偏色就会不一致。
	if edge_blend > 0.0:
		var blended: Array = []
		for y in range(height):
			var brow2: Array = []
			brow2.resize(width)
			for x in range(width):
				brow2[x] = _blended_biome(biome, x, y, edge_blend)
			blended.append(brow2)
		biome = blended

	# 装饰只落在地板上；出生区留空；树/石头并入 walls（寻路会绕开）
	# 权重按所在生物群系取，树在"成簇噪声"高值区会被放大 → 形成树林而非均匀撒点
	for y in range(1, height - 1):
		for x in range(1, width - 1):
			if terrain[y][x]:
				continue
			if abs(x - center.x) <= clear_r and abs(y - center.y) <= clear_r:
				continue
			if veg.get_noise_2d(x, y) <= veg_threshold:
				continue
			var b: int = biome[y][x]
			var w: Dictionary = _biome_at(b)
			var in_patch: bool = cluster.get_noise_2d(x, y) > cluster_threshold
			var p_tree: float = w["tree"] * density * (3.0 if in_patch else 1.0)
			var p_rock: float = w["rock"] * density
			var p_debris: float = w["debris"] * density
			var r := rng.randf()
			var acc := 0.0
			var kind := DECOR_NONE
			acc += p_tree
			if r < acc:
				kind = DECOR_TREE
			else:
				acc += p_rock
				if r < acc:
					kind = DECOR_ROCK
				else:
					acc += p_debris
					if r < acc:
						kind = DECOR_DEBRIS
			if kind == DECOR_NONE:
				continue
			decor[y][x] = kind
			if kind == DECOR_TREE or kind == DECOR_ROCK:
				walls[y][x] = true   # 实体障碍，参与寻路与连通性

	# ---- 矿脉生成：从 config.map.veins 读取 iron/gold/oil 的限定群系 + 数量 + 距出生点 ----
	# 矿脉落在地板格（非墙、非装饰、限定群系内、距出生点足够远），不阻挡通行；
	# 视觉上是一块矿石露头精灵，数据上登记进 ResourceRegistry 供采集。
	var veins: Array = []
	var vein_occ: Dictionary = {}   # "x,y" -> true，避免矿脉互相重叠
	var vein_cfg: Dictionary = Config.get_value("map.veins", {})
	for res_key in vein_cfg.keys():
		var vc: Dictionary = vein_cfg[res_key]
		# JSON 数值默认解析为 float，而 biome 数组存的是 int；两侧都转 int，
		# 避免 [3.0].has(3) 在本版 GDScript 下返回 false 导致矿脉一个都生成不出来。
		var v_allowed_raw: Array = vc.get("biomes", [])
		var v_allowed: Array = []
		for bid in v_allowed_raw:
			v_allowed.append(int(bid))
		var v_wanted: int = int(vc.get("count", 0))
		var v_min_dist: int = int(vc.get("min_distance_from_spawn_cells", 8))
		for _n in range(v_wanted):
			var tries := 0
			while tries < 250:
				tries += 1
				var gx: int = rng.randi_range(2, width - 3)
				var gy: int = rng.randi_range(2, height - 3)
				if terrain[gy][gx]:
					continue                       # 不能压在墙上
				if decor[gy][gx] != DECOR_NONE:
					continue                       # 不与树/石重叠
				if not v_allowed.has(int(biome[gy][gx])):
					continue                       # 只在限定群系出矿
				var d: int = abs(gx - center.x) + abs(gy - center.y)
				if d < v_min_dist:
					continue                       # 离出生点太近
				var vkey: String = "%d,%d" % [gx, gy]
				if vein_occ.has(vkey):
					continue
				vein_occ[vkey] = true
				veins.append({"res_id": str(res_key), "gx": gx, "gy": gy})
				break

	# ---- 第二遍：渲染瓦片（按生物群系取对应变体列；墙顶受光判断依赖最终 terrain）----
	for y in range(height):
		for x in range(width):
			var b: int = biome[y][x]
			if terrain[y][x]:
				# 上方是地板 → 这格是墙的顶面，加受光边（2.5D 俯视的体积感）
				var is_top: bool = (y > 0 and not terrain[y - 1][x])
				var v := _variant(x, y, WALL_VARIANTS)
				var col: int = (atlas_wall_top_start() if is_top else atlas_wall_start()) + b * WALL_VARIANTS + v
				layer.set_cell(Vector2i(x, y), 0, Vector2i(col, 0))
			else:
				var v := _variant(x, y, FLOOR_VARIANTS)
				layer.set_cell(Vector2i(x, y), 0, Vector2i(b * FLOOR_VARIANTS + v, 0))

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
			var tex := _decor_texture(k)
			if tex == null:
				continue
			var tex_size := Vector2(tex.get_size())
			# 每株装饰做随机缩放/翻转/亮度抖动，消除克隆感
			var sc := Vector2(rng.randf_range(0.88, 1.12), rng.randf_range(0.88, 1.12))
			# 脚底对齐格心（图片底边落在格心下方 2px，视觉上"站在"这一格）
			var pos := Vector2(x * tile_size + tile_size * 0.5,
							   y * tile_size + tile_size * 0.5)
			# 落地投影：必须先添加影子再添加本体——同 y 时 y_sort 保持添加序，
			# 影子就永远压在本体下面。残骸本来就平摊在地上，不需要投影。
			if shadow_on and k != DECOR_DEBRIS:
				var shadow_tex := _decor_shadow_texture(k, tex_size.x)
				if shadow_tex != null:
					var sh := Sprite2D.new()
					sh.texture = shadow_tex
					sh.centered = false
					sh.scale = sc
					sh.position = pos
					sh.offset = Vector2(-shadow_tex.get_width() * 0.5, 0.0)
					sh.z_index = 0
					decor_root.add_child(sh)
			var s := Sprite2D.new()
			s.texture = tex
			s.centered = false
			s.scale = sc
			s.flip_h = rng.randf() < 0.5
			# 群系整体色调（与地表同源：地面亮的地方物件也亮）× 类别基准亮度 × 随机抖动
			var tint: Color = _biome_tint(biome[y][x])
			var base_tint: Color = DECOR_BASE_TINT.get(k, Color(1, 1, 1))
			s.modulate = Color(tint.r * base_tint.r, tint.g * base_tint.g,
					tint.b * base_tint.b) * rng.randf_range(0.90, 1.08)
			s.position = pos
			s.offset = Vector2(-tex_size.x * 0.5, 2.0 - tex_size.y)
			s.z_index = 0   # 与地形同层：玩家（z=1）始终在前景，未探索区被雾盖住
			decor_root.add_child(s)
			counts[k] = int(counts[k]) + 1

	# 矿脉精灵：矿石露头，非阻挡。按类型配色，采完由 ResourceRegistry 隐藏
	for vd in veins:
		var kind: int = int(VEIN_RES.get(vd["res_id"], -1))
		if kind < 0:
			continue
		var otex := _ore_texture(kind)
		if otex == null:
			continue
		var opos := Vector2(vd["gx"] * tile_size + tile_size * 0.5,
							vd["gy"] * tile_size + tile_size * 0.5)
		var osc := Vector2(rng.randf_range(0.85, 1.1), rng.randf_range(0.85, 1.1))
		# 落地软影（比树小）
		if shadow_on:
			var osh := _decor_shadow_texture(DECOR_ROCK, otex.get_width() * 0.7)
			if osh != null:
				var sh := Sprite2D.new()
				sh.texture = osh
				sh.centered = false
				sh.scale = osc
				sh.position = opos
				sh.offset = Vector2(-osh.get_width() * 0.5, 0.0)
				sh.z_index = 0
				decor_root.add_child(sh)
		var os := Sprite2D.new()
		os.texture = otex
		os.centered = false
		os.scale = osc
		os.flip_h = rng.randf() < 0.5
		var bt: Color = _biome_tint(biome[vd["gy"]][vd["gx"]])
		os.modulate = bt * rng.randf_range(0.92, 1.06)
		os.position = opos
		os.offset = Vector2(-otex.get_width() * 0.5, 2.0 - otex.get_height())
		os.z_index = 0
		decor_root.add_child(os)
		vd["sprite"] = os

	var root := Node2D.new()
	root.name = "MapRoot"
	root.add_child(layer)
	root.add_child(decor_root)
	# 宏观明暗层：低分辨率光照图放大后乘法混合。刻意最后添加 —— 同 z_index 下
	# 绘制在最上层，连装饰一起受光；否则会出现"地面有明暗、树却一样亮"的割裂。
	var macro_img: Image = null
	if macro_on and macro_strength > 0.0:
		macro_img = _make_macro_light_image(width, height, macro_noise, macro_strength)
		if macro_img != null:
			root.add_child(_wrap_macro_light(macro_img, tile_size))

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

	# 群系分布统计（调试用）
	var biome_counts := []
	biome_counts.resize(biome_count())
	for i in range(biome_count()):
		biome_counts[i] = 0
	for y in range(height):
		for x in range(width):
			biome_counts[biome[y][x]] += 1

	print("[Map] 地图生成完成：%dx%d 瓦片（%dx%d 像素），地板 %d 格，可达 %d 格（%.0f%%），贴图=%s"
		% [width, height, width * tile_size, height * tile_size, floor_count, reach_count,
		   ratio * 100.0, "AI" if _used_ai_atlas else "程序化(回退)"])
	print("[Map] 装饰物：树 %d / 石头 %d / 残骸 %d，出生点 %s"
		% [int(counts[DECOR_TREE]), int(counts[DECOR_ROCK]), int(counts[DECOR_DEBRIS]), spawn])
	var biome_str := ""
	for i in range(biome_count()):
		if i > 0:
			biome_str += ", "
		biome_str += "%s %d" % [_biome_at(i)["name"], int(biome_counts[i])]
	print("[Map] 群系分布：" + biome_str)
	return {"node": root, "spawn": spawn, "spawn_cell": center,
			"walls": walls, "reachable": reachable, "reachable_ratio": ratio,
			"terrain": terrain, "decor": decor, "biome": biome, "tile_size": tile_size,
			"veins": veins, "macro": macro_img}


## ------------------------------------------------------------
## 预览合成：不依赖渲染驱动，直接把瓦片与装饰像素拼成一张 PNG。
## cells = 截取边长（格），以出生点为中心。供 debug.map_preview 使用，
## 无头环境（dummy 驱动）也能出图。
## ------------------------------------------------------------
static func build_preview(result: Dictionary, cells: int) -> Image:
	var ts: int = int(result["tile_size"])
	var terrain: Array = result["terrain"]
	var decor: Array = result["decor"]
	var biome: Array = result.get("biome", [])
	var h: int = terrain.size()
	var w: int = terrain[0].size()
	var c: Vector2i = result["spawn_cell"]
	var x0: int = clampi(c.x - cells / 2, 0, maxi(0, w - cells))
	var y0: int = clampi(c.y - cells / 2, 0, maxi(0, h - cells))
	var out := Image.create(mini(cells, w) * ts, mini(cells, h) * ts, false,
			Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 1))

	# 地形层：从缓存图集按格复制（变体选择逻辑与渲染时完全一致，含群系偏移）
	if _atlas_img != null:
		for y in range(mini(cells, h)):
			for x in range(mini(cells, w)):
				var gx: int = x0 + x
				var gy: int = y0 + y
				var b: int = 0
				if gy < biome.size() and gx < biome[gy].size():
					b = int(biome[gy][gx])
				var col: int
				if terrain[gy][gx]:
					var is_top: bool = (gy > 0 and not terrain[gy - 1][gx])
					var v := _variant(gx, gy, WALL_VARIANTS)
					col = (atlas_wall_top_start() if is_top else atlas_wall_start()) + b * WALL_VARIANTS + v
				else:
					var v := _variant(gx, gy, FLOOR_VARIANTS)
					col = b * FLOOR_VARIANTS + v
				out.blit_rect(_atlas_img, Rect2i(col * ts, 0, ts, ts),
						Vector2i(x * ts, y * ts))

	# 装饰层：按 y 递增绘制（等价于 y_sort，下方的遮上方的）
	var shadow_on: bool = bool(Config.get_value("map.decor.shadow", true))
	for y in range(mini(cells, h)):
		for x in range(mini(cells, w)):
			var gy: int = y0 + y
			var gx: int = x0 + x
			var k: int = decor[gy][gx]
			if k == DECOR_NONE or not _decor_img.has(k):
				continue
			var src: Image = _decor_img[k]
			var tint: Color = _biome_tint(biome[gy][gx])
			var base_tint: Color = DECOR_BASE_TINT.get(k, Color(1, 1, 1))
			var use_tint := Color(tint.r * base_tint.r, tint.g * base_tint.g,
					tint.b * base_tint.b)
			# 落地投影：与运行时同序（先影后本体），残骸不投影
			if shadow_on and k != DECOR_DEBRIS:
				var sw: float = maxf(6.0, src.get_width() * 0.80)
				var shh: float = maxf(3.0, sw * 0.34)
				_blend_shadow(out, int(x * ts + ts * 0.5),
						int(y * ts + ts * 0.5 + shh * 0.5), sw * 0.5, shh * 0.5)
			# 与游戏中 Sprite2D 的对齐方式一致：脚底落在格心下方 2px
			var dx: int = int(x * ts + ts * 0.5 - src.get_width() * 0.5)
			var dy: int = int(y * ts + ts * 0.5 + 2.0 - src.get_height())
			_blend(out, src, dx, dy, use_tint)

	# 宏观明暗：等价于运行时 MacroLight 的乘法混合（先放大插值，再逐像素乘）
	var macro: Image = result.get("macro", null)
	if macro != null and macro.get_width() > 0:
		var cw: int = mini(cells, w)
		var chh: int = mini(cells, h)
		var region := macro.get_region(Rect2i(x0, y0, cw, chh))
		region.resize(out.get_width(), out.get_height(), Image.INTERPOLATE_BILINEAR)
		for py in range(out.get_height()):
			for px in range(out.get_width()):
				var m := region.get_pixel(px, py)
				var px_col := out.get_pixel(px, py)
				out.set_pixel(px, py, Color(clampf(px_col.r * m.r, 0.0, 1.0),
						clampf(px_col.g * m.g, 0.0, 1.0),
						clampf(px_col.b * m.b, 0.0, 1.0), 1.0))
	return out


## 把 src 以 alpha 混合方式叠到 out 的 (dx, dy) 处，tint 决定叠上去时的色调
static func _blend(out: Image, src: Image, dx: int, dy: int,
		tint: Color = Color(1, 1, 1)) -> void:
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
			out.set_pixel(ox, oy, Color(s.r * tint.r * a + d.r * (1.0 - a),
					s.g * tint.g * a + d.g * (1.0 - a),
					s.b * tint.b * a + d.b * (1.0 - a), 1.0))


## 在 out 上叠一个椭圆软影（形状与 _decor_shadow_texture 一致，供预览复用）
static func _blend_shadow(out: Image, cx: int, cy: int, rx: float, ry: float) -> void:
	var py0: int = int(float(cy) - ry) - 1
	var py1: int = int(float(cy) + ry) + 1
	var px0: int = int(float(cx) - rx) - 1
	var px1: int = int(float(cx) + rx) + 1
	for y in range(py0, py1 + 1):
		if y < 0 or y >= out.get_height():
			continue
		for x in range(px0, px1 + 1):
			if x < 0 or x >= out.get_width():
				continue
			var dx := (float(x) - float(cx)) / maxf(rx, 1.0)
			var dy := (float(y) - float(cy)) / maxf(ry, 1.0)
			var dd := dx * dx + dy * dy
			if dd > 1.0:
				continue
			var a: float = (1.0 - dd) * 0.42
			if a <= 0.02:
				continue
			var d := out.get_pixel(x, y)
			out.set_pixel(x, y, Color(d.r * (1.0 - a), d.g * (1.0 - a),
					d.b * (1.0 - a), 1.0))


## ------------------------------------------------------------
## 瓦片图集：优先用 AI 生成的 2.5D 手绘贴图，缺失时回退程序化绘制
## ------------------------------------------------------------

## 确定性二维哈希：同一格 + 同一 salt 永远得到同一个值（重生成地图不闪烁）
static func _hash_xy(x: int, y: int, salt: int) -> int:
	var h: int = (x * 73856093) ^ (y * 19349663) ^ (salt * 83492791)
	h = h ^ (h >> 13)
	h = h ^ (h << 7)
	return absi(h)


## 确定性变体选择：同一格永远得到同一个变体，重生成地图不会闪烁
static func _variant(x: int, y: int, count: int) -> int:
	return _hash_xy(x, y, 17) % count


## 群系边界渗透：若该格处在两个群系的交界且哈希命中，则改用某个邻格的群系。
## 效果是把"一条硬直的切缝"变成"互相咬进去的混合带"。
static func _blended_biome(biome: Array, x: int, y: int, blend: float) -> int:
	var b: int = biome[y][x]
	if blend <= 0.0:
		return b
	var h: int = biome.size()
	var w: int = biome[0].size()
	# 先看四邻有没有别的群系。绝大多数格子不属于边界，在这里就早退了。
	var cand: Array = []
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx: int = x + d.x
		var ny: int = y + d.y
		if nx < 0 or ny < 0 or nx >= w or ny >= h:
			continue
		var nb: int = biome[ny][nx]
		if nb != b and not cand.has(nb):
			cand.append(nb)
	if cand.is_empty():
		return b
	# 用确定性随机决定「咬不咬」以及「咬向谁」
	if float(_hash_xy(x, y, 91) % 1000) >= blend * 1000.0:
		return b
	return cand[_hash_xy(x, y, 53) % cand.size()]


## 读出 PNG 的 Image（未导入的 PNG 会返回 null，交给调用方回退）
static func _load_image(path: String) -> Image:
	if path == "" or not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	if res is Texture2D:
		var im: Image = (res as Texture2D).get_image()
		if im != null:
			if im.is_compressed():
				im.decompress()
			im.convert(Image.FORMAT_RGB8)
			return im
	return null


## 把横向排列的源图集按列重采样到目标瓦片边长
static func _resize_atlas(src: Image, tile_size: int, cols: int) -> Image:
	var dst := Image.create(tile_size * cols, tile_size, false, Image.FORMAT_RGB8)
	dst.fill(Color(0, 0, 0))
	for i in range(cols):
		var sx: int = i * SRC_TILE
		if sx + SRC_TILE > src.get_width():
			break
		var region := src.get_region(Rect2i(sx, 0, SRC_TILE, SRC_TILE))
		if tile_size != SRC_TILE:
			region.resize(tile_size, tile_size, Image.INTERPOLATE_LANCZOS)
		dst.blit_rect(region, Rect2i(0, 0, tile_size, tile_size),
				Vector2i(i * tile_size, 0))
	return dst


## 墙顶受光：整体提亮 + 首行加一条高光边，模拟 2.5D 俯视的受光顶面
## 提亮幅度刻意压小（1.10）——过大时墙体在 16px 下会变成亮块，与地表脱节
static func _paint_top_light(col: Image, ts: int) -> void:
	for y in range(ts):
		for x in range(ts):
			var c := col.get_pixel(x, y)
			col.set_pixel(x, y, Color(minf(c.r * 1.10, 1.0), minf(c.g * 1.10, 1.0),
					minf(c.b * 1.10, 1.0)))
	for x in range(ts):
		var c := col.get_pixel(x, 0)
		col.set_pixel(x, 0, Color(minf(c.r * 1.18 + 0.06, 1.0),
				minf(c.g * 1.18 + 0.06, 1.0), minf(c.b * 1.18 + 0.06, 1.0)))


## 组装完整图集：地板列 + 墙体列 + 墙顶列
static func _build_atlas_image(tile_size: int) -> Image:
	var img := Image.create(tile_size * atlas_cols(), tile_size, false, Image.FORMAT_RGB8)
	img.fill(Color(0, 0, 0))

	var floor_img := _load_image(ATLAS_FLOOR_PATH)
	var wall_img := _load_image(ATLAS_WALL_PATH)
	if floor_img != null and wall_img != null:
		var fi := _resize_atlas(floor_img, tile_size, biome_count() * FLOOR_VARIANTS)
		var wi := _resize_atlas(wall_img, tile_size, biome_count() * WALL_VARIANTS)
		img.blit_rect(fi, Rect2i(0, 0, fi.get_width(), fi.get_height()), Vector2i(0, 0))
		img.blit_rect(wi, Rect2i(0, 0, wi.get_width(), wi.get_height()),
				Vector2i(atlas_wall_start() * tile_size, 0))
		# 墙顶受光变体由墙体列派生（省一份素材，且光照关系天然一致）
		for i in range(biome_count() * WALL_VARIANTS):
			var col := wi.get_region(Rect2i(i * tile_size, 0, tile_size, tile_size))
			_paint_top_light(col, tile_size)
			img.blit_rect(col, Rect2i(0, 0, tile_size, tile_size),
					Vector2i((atlas_wall_top_start() + i) * tile_size, 0))
		_used_ai_atlas = true
		_grade_atlas(img, tile_size)
		return img

	# ---- 回退：AI 贴图缺失时用程序化逐像素绘制 ----
	_used_ai_atlas = false
	var rng := RandomNumberGenerator.new()
	rng.seed = ATLAS_SEED  # 固定种子：图集外观稳定
	for b in range(biome_count()):
		var w: Dictionary = _biome_at(b)
		for v in range(FLOOR_VARIANTS):
			_paint_floor(img, (b * FLOOR_VARIANTS + v) * tile_size, tile_size, v, rng, w["floor"])
		for v in range(WALL_VARIANTS):
			_paint_wall(img, (atlas_wall_start() + b * WALL_VARIANTS + v) * tile_size, tile_size,
					v, rng, false, w["wall"])
		for v in range(WALL_VARIANTS):
			_paint_wall(img, (atlas_wall_top_start() + b * WALL_VARIANTS + v) * tile_size, tile_size,
					v, rng, true, w["wall"])
	_grade_atlas(img, tile_size)
	return img


## 色调分级：对整张图集做「对比曲线 + 去饱和 + 群系色调」。
## 顺序有讲究：
##   1. 对比曲线把灰糊的中间调拉开，同时整体压暗一点（给群系提亮留空间）；
##   2. 去饱和让画面沉稳——AI 贴图本身的饱和度偏高，直接叠色调会"艳"；
##   3. 最后才乘 BIOME_TINT，四个区域的明暗和色温才真正分开。
static func _grade_atlas(img: Image, ts: int) -> void:
	var contrast: float = float(Config.get_value("map.grade.contrast", 1.12))
	var bright: float = float(Config.get_value("map.grade.brightness", -0.03))
	var sat: float = float(Config.get_value("map.grade.saturation", 0.82))
	for y in range(ts):
		for x in range(img.get_width()):
			var tint: Color = _biome_tint(_biome_of_column(x / ts))
			var c := img.get_pixel(x, y)
			var r: float = clampf((c.r - 0.5) * contrast + 0.5 + bright, 0.0, 1.0)
			var g: float = clampf((c.g - 0.5) * contrast + 0.5 + bright, 0.0, 1.0)
			var b: float = clampf((c.b - 0.5) * contrast + 0.5 + bright, 0.0, 1.0)
			# 去饱和：向亮度灰靠拢（Rec.601 权重）
			var luma: float = r * 0.299 + g * 0.587 + b * 0.114
			r = luma + (r - luma) * sat
			g = luma + (g - luma) * sat
			b = luma + (b - luma) * sat
			img.set_pixel(x, y, Color(
					clampf(r * tint.r, 0.0, 1.0),
					clampf(g * tint.g, 0.0, 1.0),
					clampf(b * tint.b, 0.0, 1.0)))


## 图集列号 → 所属群系（地板 / 墙体 / 墙顶三段列区各自换算）
static func _biome_of_column(col: int) -> int:
	if col < atlas_wall_start():
		return clampi(col / FLOOR_VARIANTS, 0, biome_count() - 1)
	if col < atlas_wall_top_start():
		return clampi((col - atlas_wall_start()) / WALL_VARIANTS, 0, biome_count() - 1)
	return clampi((col - atlas_wall_top_start()) / WALL_VARIANTS, 0, biome_count() - 1)


static func _build_tileset(tile_size: int) -> TileSet:
	var img := _build_atlas_image(tile_size)
	# 缓存一份 RGBA 副本供预览合成（图集本身是 RGB8，无法直接 blit 到 RGBA 画布）
	_atlas_img = img.duplicate()
	_atlas_img.convert(Image.FORMAT_RGBA8)

	var ts := TileSet.new()
	ts.tile_size = Vector2i(tile_size, tile_size)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	for i in range(atlas_cols()):
		src.create_tile(Vector2i(i, 0))
	ts.add_source(src, 0)

	# 碰撞：所有墙变体（普通 + 墙顶，含各群系）都是整格实心
	ts.add_physics_layer()
	for i in range(atlas_wall_start(), atlas_cols()):
		var d := src.get_tile_data(Vector2i(i, 0), 0)
		d.set_collision_polygons_count(0, 1)
		d.set_collision_polygon_points(0, 0, PackedVector2Array([
			Vector2(0, 0), Vector2(tile_size, 0),
			Vector2(tile_size, tile_size), Vector2(0, tile_size),
		]))
	return ts


## ------------------------------------------------------------
## 宏观明暗层：把"均匀铺满整张图"变成"有明暗节奏"
##
## TileMapLayer 做不到单格 modulate，所以改为生成一张与地图等格数的低分辨率
## 灰度图（每格 1 像素），用 BLEND_MODE_MUL 放大混合。线性过滤把低频噪声
## 平滑成大片渐变，既省显存又天然没有硬边。
## ------------------------------------------------------------
static func _make_macro_light_image(width: int, height: int, noise: FastNoiseLite,
		strength: float) -> Image:
	var img := Image.create(width, height, false, Image.FORMAT_RGB8)
	for y in range(height):
		for x in range(width):
			var v: float = (noise.get_noise_2d(x, y) + 1.0) * 0.5
			# 映射到 [1-strength, 1]：乘法混合下 1 = 不变，越暗越压暗。
			# 刻意不做提亮（>1 会被 RGB8 截断），改用"整体压暗"留出对比空间。
			var k: float = clampf(1.0 - strength * (1.0 - v), 0.0, 1.0)
			img.set_pixel(x, y, Color(k, k, k))
	return img


## 把宏观明暗图包成乘法混合的 Sprite2D（scale = 瓦片边长 → 正好铺满整张地图）
static func _wrap_macro_light(img: Image, tile_size: int) -> Sprite2D:
	var s := Sprite2D.new()
	s.name = "MacroLight"
	s.texture = ImageTexture.create_from_image(img)
	s.centered = false
	s.scale = Vector2(tile_size, tile_size)
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	s.z_index = 0
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	s.material = mat
	return s


## 地板（回退绘制）：基色 + 颗粒噪点，各变体再加一种地表特征
static func _paint_floor(img: Image, ox: int, ts: int, variant: int,
		rng: RandomNumberGenerator, base: Color) -> void:
	for y in range(ts):
		for x in range(ts):
			_set_rgb(img, ox + x, y, base * rng.randf_range(0.82, 1.18))
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
			pass


## 墙体（回退绘制）：基色 + 颗粒噪点，变体加砖缝/铆钉/管道；
## is_top（墙顶）整体提亮并在首行加高光边，模拟 2.5D 受光顶面
static func _paint_wall(img: Image, ox: int, ts: int, variant: int,
		rng: RandomNumberGenerator, is_top: bool, base: Color) -> void:
	var bcol: Color = base
	if is_top:
		bcol = bcol.lightened(0.16)
	for y in range(ts):
		for x in range(ts):
			_set_rgb(img, ox + x, y, bcol * rng.randf_range(0.86, 1.14))
	match variant:
		1:  # 砖缝：两条横向暗线 + 交错竖缝
			for line_y in [ts / 3, ts * 2 / 3]:
				for x in range(ts):
					_set_rgb(img, ox + x, line_y, bcol * 0.55)
			var sx := ts / 2 if (variant % 2 == 0) else ts / 4
			for y in range(ts / 3):
				_set_rgb(img, ox + sx, y, bcol * 0.6)
		2:  # 铆钉：四角亮点 + 下方暗边
			for p in [Vector2i(2, 2), Vector2i(ts - 3, 2),
					  Vector2i(2, ts - 3), Vector2i(ts - 3, ts - 3)]:
				_set_rgb(img, ox + p.x, p.y, C_RUST)
				_set_rgb(img, ox + p.x, p.y + 1, bcol * 0.5)
		3:  # 竖管道：中间一条铜锈凸管
			var px := ts / 2 - 1
			for y in range(ts):
				_set_rgb(img, ox + px, y, C_RUST * rng.randf_range(0.9, 1.1))
				_set_rgb(img, ox + px + 1, y, bcol * 0.6)
		_:
			pass
	if is_top:
		for x in range(ts):
			_set_rgb(img, ox + x, 0, bcol.lightened(0.45))


## ------------------------------------------------------------
## 装饰物贴图：优先 AI 生成精灵，缺失时回退程序化
## ------------------------------------------------------------

static func _decor_texture(kind: int) -> Texture2D:
	if _decor_tex.has(kind):
		return _decor_tex[kind]

	# 优先加载 AI 生成的透明精灵
	var path: String = DECOR_PATHS.get(kind, "")
	if path != "" and ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is Texture2D:
			var tex2: Texture2D = res
			_decor_tex[kind] = tex2
			var im: Image = tex2.get_image()
			if im != null:
				if im.is_compressed():
					im.decompress()
				im.convert(Image.FORMAT_RGBA8)
				_decor_img[kind] = im
			return tex2

	# ---- 回退：程序化逐像素绘制 ----
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


## 装饰物落地投影：按物件宽度生成椭圆软影（中心最暗、边缘羽化）。
## 改动很小，但能去掉"贴纸浮在地面上"的观感。
static func _decor_shadow_texture(kind: int, base_width: float) -> Texture2D:
	if _decor_shadow_tex.has(kind):
		return _decor_shadow_tex[kind]
	var w: int = maxi(6, int(base_width * 0.80))
	var h: int = maxi(3, int(float(w) * 0.34))
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := float(w - 1) * 0.5
	var cy := float(h - 1) * 0.5
	var rx := maxf(float(w) * 0.5, 1.0)
	var ry := maxf(float(h) * 0.5, 1.0)
	for y in range(h):
		for x in range(w):
			var dx := (float(x) - cx) / rx
			var dy := (float(y) - cy) / ry
			var d := dx * dx + dy * dy
			if d > 1.0:
				continue
			img.set_pixel(x, y, Color(0.0, 0.0, 0.0, (1.0 - d) * 0.42))
	var tex := ImageTexture.create_from_image(img)
	_decor_shadow_tex[kind] = tex
	return tex


## 蒸汽朋克枯树（回退）：暗棕树干 + 铜锈色枯枝 + 稀疏暗绿树冠 + 脚下投影
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


## 石头（回退）：灰岩团块 + 左上受光 + 右下暗部
static func _make_rock() -> Image:
	var w := 20
	var h := 16
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 512927
	_ellipse(img, w / 2, h - 3, 7, 2, Color(0, 0, 0, 0.32), rng, 0.0)
	_ellipse(img, w / 2, h / 2 - 1, 8, 5, Color(0.35, 0.35, 0.38), rng, 0.10)
	_ellipse(img, w / 2 - 3, h / 2 - 4, 4, 2, Color(0.52, 0.52, 0.55), rng, 0.06)
	_ellipse(img, w / 2 + 3, h / 2 + 2, 5, 3, Color(0.20, 0.20, 0.22), rng, 0.06)
	return img


## 地面残骸（回退）：齿轮碎片 / 断管，贴地不阻挡
static func _make_debris() -> Image:
	var w := 16
	var h := 12
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 314159
	for y in range(5, 8):
		for x in range(2, 9):
			_set_rgba(img, x, y, C_RUST * rng.randf_range(0.7, 1.0))
	for y in range(6, 10):
		for x in range(9, 12):
			_set_rgba(img, x, y, C_RUST * rng.randf_range(0.6, 0.85))
	_ellipse(img, 12, 5, 3, 3, Color(0.42, 0.38, 0.30), rng, 0.14)
	_ellipse(img, 12, 5, 1, 1, Color(0.16, 0.14, 0.12), rng, 0.0)
	return img


## 矿脉露头贴图（缓存）：铁灰 / 金黄 / 油黑，含落地投影与高光矿点
static func _ore_texture(kind: int) -> Texture2D:
	if _ore_tex.has(kind):
		return _ore_tex[kind]
	var img := _make_ore(kind)
	var tex := ImageTexture.create_from_image(img)
	_ore_tex[kind] = tex
	return tex


static func _make_ore(kind: int) -> Image:
	var w := 18
	var h := 14
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 1000 + kind
	# 落地投影
	_ellipse(img, w / 2, h - 2, 7, 2, Color(0, 0, 0, 0.30), rng, 0.0)
	var base: Color
	match kind:
		VEIN_IRON: base = Color(0.55, 0.52, 0.50)
		VEIN_GOLD: base = Color(0.85, 0.65, 0.20)
		VEIN_OIL:  base = Color(0.10, 0.09, 0.11)
	# 主体团块
	_ellipse(img, w / 2, h / 2 - 1, 7, 4, base, rng, 0.08)
	# 高光矿点
	for _i in range(4):
		var px := rng.randi_range(4, w - 5)
		var py := rng.randi_range(3, h - 4)
		var hl: Color
		match kind:
			VEIN_IRON: hl = Color(0.78, 0.75, 0.72)
			VEIN_GOLD: hl = Color(1.0, 0.86, 0.38)
			VEIN_OIL:  hl = Color(0.32, 0.30, 0.36)
		_set_rgba(img, px, py, hl)
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
	img.set_pixel(x, y, Color(clampf(c.r, 0.0, 1.0), clampf(c.g, 0.0, 1.0),
							  clampf(c.b, 0.0, 1.0), clampf(c.a, 0.0, 1.0)))


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

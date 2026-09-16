class_name MapGenerator
extends RefCounted
## ============================================================
## MapGenerator — 程序化地图生成
##
## 三层渲染（2026-09-16 改版，见 docs/DESIGN.md 的「缺失素材清单」章与 tools/build_ts_assets.py）：
##   1. 地形层 TileMapLayer：生物群系分区（数量由 config.json 的 map.biomes 决定）
##      × 每群系 16 个 blob 自动拼接瓦片。**直接用 Tiny Swords 官方 64px 图集原样
##      切片**，四邻连通性决定用哪一块，岸线/崖壁由素材自带的描边自然生成。
##   2. 装饰层 Node2D：树 / 石头（并入 walls，参与寻路与连通性）、
##      灌木 / 碎石（纯视觉，不阻挡）。每类有多套原画随机抽，消除克隆感。
##   3. 雾层（FogSystem，z_index 5）：盖住未探索区，装饰层 z_index 0 会被盖住。
##
## 【贴图来源】全部为 Tiny Swords (Free Pack)（Pixel Frog，CC0）官方素材，
## 由 tools/build_ts_assets.py 离线搬进 Assets/Art/：
##   Assets/Art/Tiles/TS/tilemap_colorN.png   地形（576x384 = 64px 网格 9x6）
##   Assets/Art/Tiles/TS/water_bg.png         水面（64x64 可平铺）
##   Assets/Art/Sprites/Decor/*.png           树/石/灌木/碎石/矿脉
## 贴图缺失时自动回退到程序化逐像素绘制（_paint_blob/_paint_water/
## _make_crack/...），保证工程在任何状态下都能跑起来。
##
## 关键区分：
##   terrain[y][x] → 渲染用（0 地板 / 1 墙）
##   walls[y][x]   → 通行用（墙 或 树 或 石头 = true）
##   biome[y][x]   → 生物群系 id（0..BIOME_COUNT-1），决定用哪张官方地形图集与装饰配方
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
# 【2026-09-16 改版】地形全面改用 Tiny Swords 官方图集 Terrain/Tileset。
#
# 官方 Tilemap_colorN.png 是 576x384 = 64px 网格 x 9 列 x 6 行，其中
# **cols 0-3 / rows 0-3 是一个标准的 4-bit blob autotile**：每格表示"该格四个方向
# 是否与同类地形相连"的一种组合（共 2^4 = 16 种）。编码规则：
#     右连通 ⟺ col ∈ {0,1}      左连通 ⟺ col ∈ {1,2}
#     下连通 ⟺ row ∈ {0,1}      上连通 ⟺ row ∈ {1,2}
# （由 tools/analyze_ts_blob.py 逐格统计边缘暗带反推，5 张配色图全部吻合。）
# 于是 atlas 列 = row * 4 + col，渲染时按四邻是否为同类地形反查即可（自动描岸线）。
#
# 旧实现是"每 biome 12 个随机地板变体"，且把官方图按 16px 硬抠成横条 ——
# 描边关系丢了，地图看着跟素材包完全两回事——本次即修正这一点。
#
# 官方这套素材**没有岩石山体**，它表达"不可通行地形"的方式是水。因此：
#   floor（可走） → 该群系的地形 blob（自动拼接，岸线天然吻合）
#   wall（不可走） → 官方水面（Water Background color.png，64x64 可平铺）铺满
const BLOB_N := 16              # 单 biome 地形 blob 组合数（row*4+col）
const SRC_TILE := 64            # Tiny Swords 官方瓦片边长（重采样前）
const WALL_VARIANTS := 1        # 水面列数（官方水面只有一张可平铺瓦片）
const ATLAS_SEED := 20260915    # 回退图集固定种子：外观稳定，不随地图变化

# 生物群系数量与图集列布局：不再写死常量，改为运行时从 config.json 的
# map.biomes 读取（biome_count()），因此【加一种地形只改配置、GDScript 零改码】：
# 在 config 里加一项（含 tileset 字段指向某张 Tilemap_colorN.png）即可。
# 图集列数学仍按 biome_count() 推导，所以自动跟着变。
# 注意：3D 迁移时 RGBA 四通道权重贴图最多只能 4 群系，N 群系需改用
# 「主导群系 id + 次主导 id/权重」数据贴图（见 memory 记录），现在定数据格式就按 N 设计。
static func biome_count() -> int:
	return _biomes().size()

static func biome_tileset(i: int) -> String:   # 该群系用的官方地形图集文件名
	return str(_biome_at(i).get("tileset", DEFAULT_TERRAIN))

static func biome_name(i: int) -> String:          # 群系显示名（日志与断言用）
	return str(_biome_at(i).get("name", "?"))

static func biome_speed(i: int) -> float:          # 基础移速系数（雪原 < 1）
	return clampf(float(_biome_at(i).get("speed", 1.0)), 0.05, 4.0)

static func biome_weight(i: int) -> float:         # 噪声区间权重（越大越常见）
	return maxf(0.0001, float(_biome_at(i).get("weight", 1.0)))

static func atlas_wall_start() -> int:      # 水面起始列 = 全群系地形 blob 列之后
	return BLOB_N * biome_count()

static func atlas_cols() -> int:            # 图集总列数（不再有"墙顶受光"段）
	return atlas_wall_start() + WALL_VARIANTS

# ---------- blob autotile 编码（Tiny Swords 官方 4x4 布局）----------
# 输入：四方向是否与**同类地形**（此处就是可走地面）相连。
# 输出：blob 在图集中的列偏移（0..15）= row * 4 + col。
# 规则来自对 Tilemap_colorN.png 逐格边缘不透明度的反推（tools/inspect_ts_tileset.py）。
static func blob_row(t_ok: bool, b_ok: bool) -> int:
	if b_ok:
		return 1 if t_ok else 0
	return 2 if t_ok else 3

static func blob_col(l_ok: bool, r_ok: bool) -> int:
	if r_ok:
		return 1 if l_ok else 0
	return 2 if l_ok else 3

static func blob_offset(t_ok: bool, b_ok: bool, l_ok: bool, r_ok: bool) -> int:
	return blob_row(t_ok, b_ok) * 4 + blob_col(l_ok, r_ok)


## 直接对地形网格取某格的 blob 下标（4 邻是否同为可走地形）。
## 已由 tools/analyze_ts_blob.py 逐格像素统计验证：Tilemap_color1.png 的
## 4x4 区块 16 格与上面两条规则**完全吻合**（右通⟺col∈{0,1}，下通⟺row∈{0,1}）。
## 地图外圈一律当作"不可走" → 地图边缘自动生成完整崖壁，不会出现半截贴图。
static func blob_index(terrain: Array, x: int, y: int) -> int:
	var h: int = terrain.size()
	if h == 0:
		return 0
	var w: int = (terrain[0] as Array).size()
	var t_ok: bool = y > 0 and not bool(terrain[y - 1][x])
	var b_ok: bool = y < h - 1 and not bool(terrain[y + 1][x])
	var l_ok: bool = x > 0 and not bool(terrain[y][x - 1])
	var r_ok: bool = x < w - 1 and not bool(terrain[y][x + 1])
	return blob_offset(t_ok, b_ok, l_ok, r_ok)

# ---------- 外部贴图资源（Tiny Swords 官方 CC0 素材，见 assets/README）----------
const TERRAIN_DIR := "res://Assets/Art/Tiles/TS/"
const DEFAULT_TERRAIN := "tilemap_color1.png"
const WATER_SRC := "water_bg.png"

# ---------- 生物群系定义（数据驱动，唯一真相源 = Data/config.json 的 map.biomes）----------
# 每项：{id, name, floor:[r,g,b], wall:[r,g,b], tint:[r,g,b], tree, rock, debris,
#        floor_src?（AI 无缝地面纹理文件名，缺省则程序化生成）}
# 历史默认值（config 缺失时回落，确保工程随时可跑）：
# tileset 指定 Tiny Swords 官方图集文件名（Assets/Art/Tiles/TS/ 下）
const _DEFAULT_BIOMES := [
	{"name": "草地", "weight": 3.4, "speed": 1.0, "floor": Color(0.30, 0.36, 0.18),
	 "wall": Color(0.50, 0.46, 0.34), "tint": Color(1.0, 1.0, 1.0),
	 "tileset": "tilemap_color1.png",
	 "tree": 0.030, "rock": 0.015, "debris": 0.012, "crack": 0.015},
	{"name": "荒原", "weight": 1.05, "speed": 1.0, "floor": Color(0.33, 0.27, 0.18),
	 "wall": Color(0.52, 0.37, 0.20), "tint": Color(1.0, 1.0, 1.0),
	 "tileset": "tilemap_color4.png",
	 "tree": 0.020, "rock": 0.160, "debris": 0.050, "crack": 0.070},
	{"name": "森林", "weight": 1.25, "speed": 1.0, "floor": Color(0.20, 0.28, 0.15),
	 "wall": Color(0.42, 0.30, 0.17), "tint": Color(1.0, 1.0, 1.0),
	 "tileset": "tilemap_color3.png",
	 "tree": 0.330, "rock": 0.020, "debris": 0.030, "crack": 0.010},
	{"name": "雪原", "weight": 0.95, "speed": 0.62, "floor": Color(0.82, 0.86, 0.90),
	 "wall": Color(0.72, 0.76, 0.80), "tint": Color(1.0, 1.0, 1.0),
	 "tileset": "tilemap_color2.png",
	 "tree": 0.045, "rock": 0.030, "debris": 0.012, "crack": 0.020},
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
		b["weight"] = maxf(0.0001, float(entry.get("weight", 1.0)))
		b["speed"] = clampf(float(entry.get("speed", 1.0)), 0.05, 4.0)
		b["tree"] = float(entry.get("tree", 0.05))
		b["rock"] = float(entry.get("rock", 0.03))
		b["bush"] = float(entry.get("bush", 0.02))
		b["pebble"] = float(entry.get("pebble", 0.02))
		b["tileset"] = str(entry.get("tileset", DEFAULT_TERRAIN))
		out.append(b)
	return out

static func _biome_at(i: int) -> Dictionary:
	var bs: Array = _biomes()
	return bs[clampi(i, 0, bs.size() - 1)]

static func _biome_tint(i: int) -> Color:
	return _biome_at(i)["tint"]

## 群系权重 → 归一化累积边界，供噪声分段使用。
## 例：权重 [3.4, 1.05, 1.25, 0.95] → [0.513, 0.671, 0.859, 1.0]
## 于是"草地"独占 51% 的噪声区间（= 大部分是平地），而不是每种群系各 25%。
static func biome_weight_edges() -> Array:
	var n := biome_count()
	var edges: Array = []
	var total := 0.0
	for i in range(n):
		total += float(_biome_at(i).get("weight", 1.0))
	if total <= 0.0:
		total = 1.0
	var acc := 0.0
	for i in range(n):
		acc += float(_biome_at(i).get("weight", 1.0))
		edges.append(acc / total)
	return edges


## 直接在噪声场上取分位数当群系边界：返回的 edges 满足
## "落在第 i 段（edges[i-1] .. edges[i]）的格数 / 总格数 == 群系 i 的权重占比"。
## 用先采样后排序实现（O(N log N)，128×128 约 1.6 万格，生成期一次性开销）。
static func _biome_quantile_edges(width: int, height: int, biome_noise: FastNoiseLite,
		edge_noise: FastNoiseLite, spread: float, jitter: float) -> Array:
	var vals: Array = []
	vals.resize(width * height)
	var k := 0
	for y in range(height):
		for x in range(width):
			# 必须与 generate 主循环里的算法**逐字一致**，否则分位数对不上
			var bf: float = clampf(0.5 + biome_noise.get_noise_2d(x, y) * spread,
					0.0, 1.0)
			bf += edge_noise.get_noise_2d(x, y) * jitter
			vals[k] = bf
			k += 1
	vals.sort()
	var n := vals.size()
	var fracs: Array = biome_weight_edges()      # 累积权重比例，末项 = 1.0
	var edges: Array = []
	for i in range(fracs.size()):
		var idx: int = clampi(int(float(fracs[i]) * float(n)), 0, n - 1)
		edges.append(float(vals[idx]))
	return edges


## 把 0..1 的噪声值按权重边界映射成群系 id
static func biome_from_unit(u: float, edges: Array) -> int:
	for i in range(edges.size()):
		if u <= float(edges[i]):
			return i
	return maxi(0, edges.size() - 1)


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
# 1~3、6 是"立体"物件：底边对齐格心、带落地投影，其中树/石并入 walls 阻挡通行。
# 4~5 是"贴地"地表特征：整格居中铺、无投影、不阻挡通行 ——
#   DECOR_CRACK 地表裂缝（纯视觉，暗示地层破碎，荒原多）
#   DECOR_WATER 河水浅滩（可涉水通过，但降速，系数见 map.river.slow）
const DECOR_NONE := 0
const DECOR_TREE := 1
const DECOR_ROCK := 2
const DECOR_DEBRIS := 3      # 碎石/断枝（贴地立体件，不阻挡）
const DECOR_CRACK := 4
const DECOR_WATER := 5
const DECOR_BUSH := 6        # 灌木（不阻挡，给森林加层次）

# 【2026-09-16】每种装饰给**一组**贴图，按格子哈希确定性抽一个 —— 一片林子里
# 出现 4 种树、4 种石头，消除"复制粘贴"感。数组顺序即变体下标，勿随意调序
# （哈希取模依赖它，调序会让同一张地图的观感变化）。
const DECOR_PATH_LISTS := {
	DECOR_TREE: [
		"res://Assets/Art/Sprites/Decor/tree_00.png", "res://Assets/Art/Sprites/Decor/tree_01.png",
		"res://Assets/Art/Sprites/Decor/tree_02.png", "res://Assets/Art/Sprites/Decor/tree_03.png",
		"res://Assets/Art/Sprites/Decor/tree_04.png", "res://Assets/Art/Sprites/Decor/tree_05.png",
		"res://Assets/Art/Sprites/Decor/tree_06.png", "res://Assets/Art/Sprites/Decor/tree_07.png",
		"res://Assets/Art/Sprites/Decor/tree_08.png", "res://Assets/Art/Sprites/Decor/tree_09.png",
		"res://Assets/Art/Sprites/Decor/tree_10.png", "res://Assets/Art/Sprites/Decor/tree_11.png",
		"res://Assets/Art/Sprites/Decor/tree_12.png", "res://Assets/Art/Sprites/Decor/tree_13.png",
		"res://Assets/Art/Sprites/Decor/tree_14.png", "res://Assets/Art/Sprites/Decor/tree_15.png",
	],
	DECOR_ROCK: [
		"res://Assets/Art/Sprites/Decor/rock_00.png", "res://Assets/Art/Sprites/Decor/rock_01.png",
		"res://Assets/Art/Sprites/Decor/rock_02.png", "res://Assets/Art/Sprites/Decor/rock_03.png",
		"res://Assets/Art/Sprites/Decor/stump_00.png", "res://Assets/Art/Sprites/Decor/stump_01.png",
		"res://Assets/Art/Sprites/Decor/stump_02.png", "res://Assets/Art/Sprites/Decor/stump_03.png",
	],
	DECOR_DEBRIS: [
		"res://Assets/Art/Sprites/Decor/pebble_00.png", "res://Assets/Art/Sprites/Decor/pebble_01.png",
		"res://Assets/Art/Sprites/Decor/pebble_02.png", "res://Assets/Art/Sprites/Decor/pebble_03.png",
		"res://Assets/Art/Sprites/Decor/pebble_04.png", "res://Assets/Art/Sprites/Decor/pebble_05.png",
		"res://Assets/Art/Sprites/Decor/pebble_06.png", "res://Assets/Art/Sprites/Decor/pebble_07.png",
		"res://Assets/Art/Sprites/Decor/pebble_08.png", "res://Assets/Art/Sprites/Decor/pebble_09.png",
		"res://Assets/Art/Sprites/Decor/pebble_10.png", "res://Assets/Art/Sprites/Decor/pebble_11.png",
		"res://Assets/Art/Sprites/Decor/pebble_12.png", "res://Assets/Art/Sprites/Decor/pebble_13.png",
		"res://Assets/Art/Sprites/Decor/pebble_14.png", "res://Assets/Art/Sprites/Decor/pebble_15.png",
	],
	DECOR_BUSH: [
		"res://Assets/Art/Sprites/Decor/bush_00.png", "res://Assets/Art/Sprites/Decor/bush_01.png",
		"res://Assets/Art/Sprites/Decor/bush_02.png", "res://Assets/Art/Sprites/Decor/bush_03.png",
		"res://Assets/Art/Sprites/Decor/bush_04.png", "res://Assets/Art/Sprites/Decor/bush_05.png",
		"res://Assets/Art/Sprites/Decor/bush_06.png", "res://Assets/Art/Sprites/Decor/bush_07.png",
		"res://Assets/Art/Sprites/Decor/bush_08.png", "res://Assets/Art/Sprites/Decor/bush_09.png",
		"res://Assets/Art/Sprites/Decor/bush_10.png", "res://Assets/Art/Sprites/Decor/bush_11.png",
		"res://Assets/Art/Sprites/Decor/bush_12.png", "res://Assets/Art/Sprites/Decor/bush_13.png",
		"res://Assets/Art/Sprites/Decor/bush_14.png", "res://Assets/Art/Sprites/Decor/bush_15.png",
	],
	DECOR_CRACK: [],      # 程序化绘制
	DECOR_WATER: [],      # 走官方水面贴图（water_bg，见 _decor_texture）
}

# 每类装饰物的基准亮度：石头原画偏浅，直接铺在暗色地表上会过于抢眼，压暗一档
const DECOR_BASE_TINT := {
	DECOR_TREE: Color(1.00, 1.00, 1.00),
	DECOR_ROCK: Color(1.00, 1.00, 1.00),   # Tiny Swords 原画自带配色，压灰可惜
	DECOR_DEBRIS: Color(0.98, 0.98, 0.98),
	DECOR_CRACK: Color(1.00, 1.00, 1.00),
	DECOR_WATER: Color(1.00, 1.00, 1.00),
	DECOR_BUSH: Color(1.00, 1.00, 1.00),
}

# 【贴地纯色块：整片统一，禁止逐格上色调】
#
# 河水用的是官方 water_bg.png，那是一张 **64x64 单色、完全不透明** 的平铺贴图
# （实测：64x64 只有 1 种像素 (71,171,169,255)，行/列均值波动都是 0）。
# 正因为它是"平的"，逐格乘群系 tint + 0.90~1.08 亮度抖动会立刻把格子网格
# 暴露出来：同一条河在沼泽格里被染成 (96,140,71) 的泥绿、在草地里还是青色，
# 于是整条河看起来像"一堆青绿小方块拼的色斑"，而不是水。
# （立体物件可以逐格抖动——原画本身有细节，抖动被读作光影变化，不会露格子。）
#
# 这里改成整片恒定色调，并留一点透明度让地表透出来：
#   ① 相邻水格颜色完全一致 → 河面连成整片，看不到格子缝；
#   ② 半透明读作"可涉水的浅滩"，与不可通行的整块水面（不透明、纯青）区分开 ——
#      这正是当初给沼泽加 tint 想解决的问题（玩家要能一眼看出哪儿能走）。
const DECOR_UNIFORM_TINT := {
	DECOR_WATER: Color(0.88, 0.95, 1.00, 0.80),
}

# 阻挡通行的装饰类别：只有树与石头（碎石、灌木、裂缝、河水可走）
const DECOR_BLOCKING := [DECOR_TREE, DECOR_ROCK]
# 贴地类装饰：整格居中、无投影、不做随机缩放（缩放会露出格子缝）
const DECOR_FLAT := [DECOR_CRACK, DECOR_WATER]
# 渲染顺序：先铺地表特征（河水 → 裂缝），再放立体物件（碎石 → 灌木 → 树 → 石）。
# 同层 add 顺序即绘制顺序，保证水在裂缝之下、物件在地表特征之上。
const DECOR_RENDER_ORDER := [DECOR_WATER, DECOR_CRACK, DECOR_DEBRIS, DECOR_BUSH,
		DECOR_TREE, DECOR_ROCK]
# 立体物件里"本身平摊在地上"的类别：不需要落地投影
const DECOR_NO_SHADOW := [DECOR_DEBRIS, DECOR_BUSH]

# ---------- 矿脉（地图资源节点，非装饰、不阻挡通行）----------
const VEIN_IRON := 0
const VEIN_GOLD := 1
const VEIN_OIL := 2
const VEIN_RES := {"iron": VEIN_IRON, "gold": VEIN_GOLD, "oil": VEIN_OIL}
# 每种矿脉一组贴图（金矿用官方 Gold Stone 1~6；铁矿由金矿去色派生；油田为程序化占位）。
# 官方免费包里只有金矿，铁矿/油田见 docs/DESIGN.md 的「缺失素材清单」章。
const ORE_PATH_LISTS := {
	VEIN_IRON: [
		"res://Assets/Art/Sprites/Decor/ore_iron_00.png",
		"res://Assets/Art/Sprites/Decor/ore_iron_01.png",
		"res://Assets/Art/Sprites/Decor/ore_iron_02.png",
	],
	VEIN_GOLD: [
		"res://Assets/Art/Sprites/Decor/ore_gold_00.png",
		"res://Assets/Art/Sprites/Decor/ore_gold_01.png",
		"res://Assets/Art/Sprites/Decor/ore_gold_02.png",
		"res://Assets/Art/Sprites/Decor/ore_gold_03.png",
		"res://Assets/Art/Sprites/Decor/ore_gold_04.png",
		"res://Assets/Art/Sprites/Decor/ore_gold_05.png",
	],
	VEIN_OIL: [
		"res://Assets/Art/Sprites/Decor/ore_oil_00.png",
	],
}
static var _ore_tex: Dictionary = {}     # 矿脉贴图缓存（按 kind -> Array[Texture2D]）

static var _decor_tex: Dictionary = {}     # 装饰物贴图缓存（kind -> Array[Texture2D]）
static var _decor_img: Dictionary = {}     # 装饰物原始 Image（kind -> Array[Image]，预览合成用）
static var _decor_shadow_tex: Dictionary = {}  # 装饰物落地投影贴图缓存（按类别）
static var _atlas_img: Image = null        # 瓦片图集 Image（预览合成用）
static var _used_ai_atlas := false         # 本次图集是否来自官方素材（调试用）

## 关掉宏观明暗层（由 main.gd 的 `--no-macro` 设置）。
## 为什么要留这个开关：MacroLight 是"整图叠加的乘法着色"，一旦它有问题，
## 症状会出现在**所有**东西上（地面看着脏、水面出条纹），容易误判成地形贴图坏了。
## 能一键关掉它，就能立刻二分出"到底是叠加层还是地形本身"。
static var disable_macro := false


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

	# 成簇对比度：把"植被噪声"从**硬闸门**改成**均值≈1 的乘性调制**。
	# 旧实现是 `if veg_noise <= threshold: continue`，那会在 config 密度之上
	# 再乘掉约 0.2（实测：森林 tree 写 0.330，实际只落 9%）。改成
	# `mul = clamp(1 + n*contrast, ...)`（n 均值 0）后，config 里的值才真的
	# 等于目标密度，同时保留"高值区成片、低值区稀疏"的自然成簇感。
	var veg_contrast: float = float(Config.get_value("map.decor.veg_contrast", 0.85))
	var clear_r: int = int(Config.get_value("map.decor.clear_spawn_radius_cells", 3))

	var layer := TileMapLayer.new()
	layer.name = "TileMapLayer"
	layer.tile_set = _build_tileset(tile_size)

	var center := Vector2i(width / 2, height / 2)
	# 群系边界 = 噪声场的**分位数**（而不是固定阈值）。
	# 原因：simplex 噪声近似钟形分布，固定阈值下"中间"的群系会吃掉远超权重的面积
	#       （实测雪原 25.8% vs 权重 13%）。取分位数后每个群系的格数占比 == 它的
	#       weight 占比，"草地 weight=3.4 → 大部分是平地" 就是字面意思。
	#       注意 spread 从此只影响空间结构（边界锐利度），不再影响各群系面积。
	var biome_edges: Array = _biome_quantile_edges(width, height, biome_noise,
			edge_noise, biome_spread, border_jitter)

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
			var b: int = biome_from_unit(bf, biome_edges)
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

	# 群系聚合：多数投票 N 次，把「东一块西一块」的孤立小岛并入周围同类。
	var smooth_iters: int = int(Config.get_value("map.biome_smooth_iterations", 3))
	if smooth_iters > 0:
		for _it in range(smooth_iters):
			biome = _consolidate_biome(biome, width, height)

	# 去飞地：任何不接地图边缘、被别的群系整个包住的孤立块，并入周围主导群系。
	# 保证「一个地形不会包含另一个地形」。反复到稳定（最多 8 遍）。
	if bool(Config.get_value("map.biome_remove_islands", true)):
		var min_region: int = int(Config.get_value("map.biome_min_region_cells", 40))
		var _isl_guard := 0
		while _isl_guard < 8 and _remove_biome_islands(biome, width, height, min_region):
			_isl_guard += 1

	# 河流与裂缝均已按需求移除，地图不再产生任何水格。
	# river_slow 仅保留给下方减速表兜底（无 DECOR_WATER 时该分支不触发）。
	var river_slow: float = clampf(float(Config.get_value("map.river.slow", 0.72)), 0.1, 1.0)

	# 装饰只落在地板上；出生区留空；树/石头并入 walls（寻路会绕开）
	# 权重按所在生物群系取，树在"成簇噪声"高值区会被放大 → 形成树林而非均匀撒点
	# 已被裂缝/河水占住的格子会被跳过 —— 保证地表特征带连续不被树截断。
	for y in range(1, height - 1):
		for x in range(1, width - 1):
			if terrain[y][x]:
				continue
			if abs(x - center.x) <= clear_r and abs(y - center.y) <= clear_r:
				continue
			if decor[y][x] != DECOR_NONE:
				continue                       # 已被裂缝/河水占住，不再放立体物件
			var veg_mul: float = clampf(1.0 + veg.get_noise_2d(x, y) * veg_contrast,
					0.05, 1.95)
			var b: int = biome[y][x]
			var w: Dictionary = _biome_at(b)
			var in_patch: bool = cluster.get_noise_2d(x, y) > cluster_threshold
			# 树/石/铁/油改由 _place_clustered_resources 成簇放置；这里只留灌木/碎石点缀。
			var p_bush: float = w["bush"] * density * veg_mul * (1.6 if in_patch else 1.0)
			var p_debris: float = w["pebble"] * density * veg_mul
			var r := rng.randf()
			var kind := DECOR_NONE
			if r < p_bush:
				kind = DECOR_BUSH
			elif r < p_bush + p_debris:
				kind = DECOR_DEBRIS
			if kind == DECOR_NONE:
				continue
			decor[y][x] = kind

	# ---- 地图资源成簇放置：树/石（阻挡 decor）+ 铁/油（可采集 vein）----
	# 每种资源在每个群系放 count 个相连簇，每簇格数 = weight[群系]，
	# 于是「最小聚合单位」和「各群系总量比例」都由 weight 一个数决定。
	var veins: Array = _place_clustered_resources(
			decor, terrain, biome, walls, width, height, center, rng)

	# ---- 第二遍：按四邻连通性反查官方 blob 瓦片（自动描出岸线/崖壁）----
	for y in range(height):
		for x in range(width):
			if terrain[y][x]:
				# 不可通行地形 = 官方水面（共用一份贴图，不分群系）
				layer.set_cell(Vector2i(x, y), 0, Vector2i(atlas_wall_start(), 0))
			else:
				var b: int = biome[y][x]
				layer.set_cell(Vector2i(x, y), 0,
						Vector2i(b * BLOB_N + blob_index(terrain, x, y), 0))

	# ---- 装饰层 ----
	# 按 DECOR_RENDER_ORDER 分趟绘制：先铺地表特征（河水 → 裂缝），再放立体物件
	# （碎石 → 灌木 → 树 → 石）。同层 add 顺序即绘制顺序，保证水在最底、物件压在最上。
	var decor_root := Node2D.new()
	decor_root.name = "DecorLayer"
	decor_root.y_sort_enabled = true   # 同层内按 y 排序，下方的树遮上方的树
	var counts := {DECOR_TREE: 0, DECOR_ROCK: 0, DECOR_DEBRIS: 0, DECOR_CRACK: 0,
			DECOR_WATER: 0, DECOR_BUSH: 0}
	for k in DECOR_RENDER_ORDER:
		var kk: int = int(k)
		var tex_list := _decor_textures(kk)
		if tex_list.is_empty():
			continue
		# 贴地类（裂缝/河水）整格居中且不缩放——缩放会让相邻水格之间露出格子缝
		var is_flat: bool = DECOR_FLAT.has(kk)
		var no_shadow: bool = DECOR_NO_SHADOW.has(kk)
		for y in range(height):
			for x in range(width):
				if int(decor[y][x]) != kk:
					continue
				var tex: Texture2D = tex_list[_decor_variant(x, y, tex_list.size())]
				if tex == null:
					continue
				var tex_size := Vector2(tex.get_size())
				# 立体物件做随机缩放/翻转/亮度抖动，消除克隆感
				var sc := Vector2.ONE
				if is_flat:
					# 贴地贴图按"覆盖一整格"缩放：贴图分辨率比格大（水 64 / 缝 32），
					# 不缩就一张铺开好几格，格子对不上。
					sc = Vector2(float(tile_size) / maxf(tex_size.x, 1.0),
							float(tile_size) / maxf(tex_size.y, 1.0))
				else:
					sc = Vector2(rng.randf_range(0.92, 1.08), rng.randf_range(0.92, 1.08))
				var pos := Vector2(x * tile_size + tile_size * 0.5,
								   y * tile_size + tile_size * 0.5)
				# 落地投影：必须先添加影子再添加本体——同 y 时 y_sort 保持添加序，
				# 影子就永远压在本体下面。裂缝/河水/碎石/灌木本来就贴地，不需要投影。
				if shadow_on and not is_flat and not no_shadow:
					var shadow_tex := _decor_shadow_texture(kk, tex_size.x)
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
				if DECOR_UNIFORM_TINT.has(kk):
					# 贴地纯色块（河水）：整片恒定，不理会所在格子的群系与抖动。
					# 见 DECOR_UNIFORM_TINT 上方的说明——逐格上色会让平色贴图露格子。
					s.modulate = DECOR_UNIFORM_TINT[kk]
				else:
					# 群系整体色调（与地表同源：地面亮的地方物件也亮）× 类别基准亮度 × 随机抖动
					var tint: Color = _biome_tint(biome[y][x])
					var base_tint: Color = DECOR_BASE_TINT.get(kk, Color(1, 1, 1))
					s.modulate = Color(tint.r * base_tint.r, tint.g * base_tint.g,
							tint.b * base_tint.b) * rng.randf_range(0.90, 1.08)
				s.position = pos
				if is_flat:
					# 贴地：整格居中
					s.offset = Vector2(-tex_size.x * 0.5, -tex_size.y * 0.5)
				else:
					# 立体：脚底对齐格心（图片底边落在格心下方 2px，"站在"这一格）
					s.offset = Vector2(-tex_size.x * 0.5, 2.0 - tex_size.y)
				s.z_index = 0   # 与地形同层：玩家（z=1）始终在前景，未探索区被雾盖住
				decor_root.add_child(s)
				counts[kk] = int(counts[kk]) + 1

	# 矿脉精灵：矿石露头，非阻挡。按类型配色，采完由 ResourceRegistry 隐藏
	for vd in veins:
		var kind: int = int(VEIN_RES.get(vd["res_id"], -1))
		if kind < 0:
			continue
		var otex := _ore_texture(kind, int(vd["gx"]), int(vd["gy"]))
		if otex == null:
			continue
		var opos := Vector2(vd["gx"] * tile_size + tile_size * 0.5,
							vd["gy"] * tile_size + tile_size * 0.5)
		var osc := Vector2(rng.randf_range(0.9, 1.05), rng.randf_range(0.9, 1.05))
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
		os.modulate = bt * rng.randf_range(0.94, 1.04)
		os.position = opos
		os.offset = Vector2(-otex.get_width() * 0.5, 2.0 - otex.get_height())
		os.z_index = 0
		decor_root.add_child(os)
		vd["sprite"] = os

	var root := Node2D.new()
	root.name = "MapRoot"
	root.add_child(layer)
	root.add_child(decor_root)

	# ---- 阻挡型装饰的碰撞体（2026-09-15 修「人物卡到树里」）----
	# 树/石在 walls 里是障碍（参与 A* 与连通性），但**渲染成地板瓦片**，
	# 而 TileSet 的碰撞只加在墙变体上 —— 这些格子实际上没有碰撞体。
	# 于是冲刺（速度×3 持续 0.22s ≈ 6.6 格）和受击击退都能把玩家推进树格，
	# 之后 _query_path 判定"起点是 solid"直接返回空路径 → 永久走不动。
	# 这里补上静态碰撞，让物理层与寻路层说同一套话。
	if bool(Config.get_value("map.decor_collision.enabled", true)):
		var coll := _build_decor_collision(walls, terrain, decor, width, height, tile_size)
		if coll != null:
			root.add_child(coll)
	# 宏观明暗层：低分辨率光照图放大后乘法混合。刻意最后添加 —— 同 z_index 下
	# 绘制在最上层，连装饰一起受光；否则会出现"地面有明暗、树却一样亮"的割裂。
	var macro_img: Image = null
	if macro_on and macro_strength > 0.0 and not disable_macro:
		macro_img = _make_macro_light_image(width, height, macro_noise, macro_strength)
		if macro_img != null:
			root.add_child(_wrap_macro_light(macro_img, tile_size))

	# 地形速度系数网格：基础取群系 speed（雪原 < 1 表示雪地难行），
	# 水格再取更小者（map.river.slow）。player.follow_path 每帧按所在格查这张表。
	var speed_mult: Array = []
	for y in range(height):
		var srow: Array = []
		srow.resize(width)
		for x in range(width):
			var sp: float = float(_biome_at(biome[y][x]).get("speed", 1.0))
			if decor[y][x] == DECOR_WATER:
				sp = minf(sp, river_slow)
			srow[x] = sp
		speed_mult.append(srow)

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
	print("[Map] 装饰物：树 %d / 石头 %d / 灌木 %d / 碎石 %d / 裂缝 %d / 河水 %d，出生点 %s"
		% [int(counts[DECOR_TREE]), int(counts[DECOR_ROCK]), int(counts[DECOR_BUSH]),
		   int(counts[DECOR_DEBRIS]), int(counts[DECOR_CRACK]),
		   int(counts[DECOR_WATER]), spawn])
	print("[Map] 矿脉 %d 处" % veins.size())
	var biome_str := ""
	for i in range(biome_count()):
		if i > 0:
			biome_str += ", "
		biome_str += "%s %d" % [_biome_at(i)["name"], int(biome_counts[i])]
	print("[Map] 群系分布：" + biome_str)
	return {"node": root, "spawn": spawn, "spawn_cell": center,
			"walls": walls, "reachable": reachable, "reachable_ratio": ratio,
			"terrain": terrain, "decor": decor, "biome": biome, "tile_size": tile_size,
			"veins": veins, "macro": macro_img,
			"speed_mult": speed_mult, "river_slow": river_slow}


## 为"阻挡型装饰"（树/石）生成静态碰撞体，让物理层与 A* 的 walls 网格一致。
##
## 只覆盖 DECOR_BLOCKING（树/石）：残骸/裂缝/河水/矿脉都不阻挡，不该有碰撞。
## 实现上用**一个 StaticBody2D 挂 N 个 CollisionShape2D**，而不是 N 个 StaticBody2D：
## 节点数少一个量级，而 2D 宽相对静态形状的处理与地形瓦片同量级（地形还是逐格形状）。
static func _build_decor_collision(walls: Array, terrain: Array, decor: Array,
		width: int, height: int, tile_size: int) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.name = "DecorCollision"
	var n := 0
	for y in range(height):
		for x in range(width):
			if not walls[y][x] or terrain[y][x]:
				continue                              # 真墙已有瓦片碰撞；地板不管
			if not DECOR_BLOCKING.has(int(decor[y][x])):
				continue
			var sh := CollisionShape2D.new()
			var rect := RectangleShape2D.new()
			rect.size = Vector2(tile_size, tile_size)
			sh.shape = rect
			sh.position = Vector2(x * tile_size + tile_size * 0.5,
					y * tile_size + tile_size * 0.5)
			body.add_child(sh)
			n += 1
	if n == 0:
		body.free()
		return null
	print("[Map] 装饰碰撞体：%d 格（树/石，物理层与寻路层已对齐）" % n)
	return body


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

	# 地形层：从缓存图集按格复制（blob 选择逻辑与渲染时**逐字一致**）
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
					col = atlas_wall_start()
				else:
					col = b * BLOB_N + blob_index(terrain, gx, gy)
				out.blit_rect(_atlas_img, Rect2i(col * ts, 0, ts, ts),
						Vector2i(x * ts, y * ts))

	# 装饰层：按 y 递增绘制（等价于 y_sort，下方的遮上方的）
	var shadow_on: bool = bool(Config.get_value("map.decor.shadow", true))
	for y in range(mini(cells, h)):
		for x in range(mini(cells, w)):
			var gy: int = y0 + y
			var gx: int = x0 + x
			var k: int = decor[gy][gx]
			var imgs: Array = _decor_img.get(k, [])
			if k == DECOR_NONE or imgs.is_empty():
				continue
			var src: Image = imgs[_decor_variant(gx, gy, imgs.size())]
			if src == null:
				continue
			var tint: Color = _biome_tint(biome[gy][gx])
			var base_tint: Color = DECOR_BASE_TINT.get(k, Color(1, 1, 1))
			var use_tint := Color(tint.r * base_tint.r, tint.g * base_tint.g,
					tint.b * base_tint.b)
			var flat: bool = DECOR_FLAT.has(k)
			# 落地投影：与运行时同序（先影后本体）；裂缝/河水/碎石/灌木贴地，不投影
			if shadow_on and not flat and not DECOR_NO_SHADOW.has(k):
				var sw: float = maxf(6.0, src.get_width() * 0.80)
				var shh: float = maxf(3.0, sw * 0.34)
				_blend_shadow(out, int(x * ts + ts * 0.5),
						int(y * ts + ts * 0.5 + shh * 0.5), sw * 0.5, shh * 0.5)
			# 与游戏中 Sprite2D 的对齐方式一致：立体物件脚底落在格心下方 2px，
			# 贴地类（裂缝/河水）整格居中
			var dx: int = int(x * ts + ts * 0.5 - src.get_width() * 0.5)
			var dy: int = int(y * ts + ts * 0.5 + 2.0 - src.get_height())
			if flat:
				# 贴地贴图先缩到"一格见方"，再整格居中
				src = src.duplicate()
				src.resize(ts, ts, Image.INTERPOLATE_LANCZOS)
				dx = int(x * ts)
				dy = int(y * ts)
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


## 确定性变体选择：同一格永远得到同一个变体，重生成地图不会闪烁。
## 【2026-09-16】装饰物改成"一组贴图随机抽一张"后由它决定抽哪张。salt 与
## 地形/群系用的 salt 分开，调装饰不会连带改动地形观感。
static func _decor_variant(x: int, y: int, count: int) -> int:
	if count <= 1:
		return 0
	return _hash_xy(x, y, 29) % count


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


## 群系聚合：对整张 biome 网格做一遍「3×3 多数投票」(mode filter)。
## 每格改成邻域(含自身)内出现次数最多的群系 id；平票时保留自身。
## 目的：把边界抖动 / 渗透留下的孤立小岛并入周围同类，让「同样的东西在一起」。
## 双缓冲：读旧网格、写新网格，避免同一遍里边算边改造成级联漂移。
static func _consolidate_biome(biome: Array, width: int, height: int) -> Array:
	var out: Array = []
	for y in range(height):
		out.append((biome[y] as Array).duplicate())
	for y in range(height):
		for x in range(width):
			var counts := {}
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nx: int = x + dx
					var ny: int = y + dy
					if nx < 0 or ny < 0 or nx >= width or ny >= height:
						continue
					var b: int = int(biome[ny][nx])
					counts[b] = int(counts.get(b, 0)) + 1
			var self_b: int = int(biome[y][x])
			var best_id: int = self_b
			var best_cnt: int = int(counts.get(self_b, 0))
			for k in counts.keys():
				var cnt: int = int(counts[k])
				if cnt > best_cnt:
					best_cnt = cnt
					best_id = int(k)
			out[y][x] = best_id
	return out


## 去飞地：把「不接地图边缘、被别的群系整个包住」的孤立群系块并入周围主导群系。
## 一遍扫完当前所有飞地并原地改 biome；返回是否有改动（调用方循环到稳定）。
## 效果：每个群系的每块区域都接地图边缘 → 不存在「一个地形包含另一个地形」。
static func _remove_biome_islands(biome: Array, w: int, h: int, min_region: int) -> bool:
	var visited: Array = []
	for y in range(h):
		var row: Array = []
		row.resize(w)
		row.fill(0)
		visited.append(row)
	var changed := false
	var d4: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for y in range(h):
		for x in range(w):
			if int(visited[y][x]) == 1:
				continue
			var b: int = int(biome[y][x])
			var stack: Array = [Vector2i(x, y)]
			visited[y][x] = 1
			var cells: Array = []
			var touches_border := false
			var neigh := {}
			while not stack.is_empty():
				var c: Vector2i = stack.pop_back()
				cells.append(c)
				if c.x == 0 or c.y == 0 or c.x == w - 1 or c.y == h - 1:
					touches_border = true
				for d in d4:
					var nx: int = c.x + d.x
					var ny: int = c.y + d.y
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					var nb: int = int(biome[ny][nx])
					if nb == b:
						if int(visited[ny][nx]) == 0:
							visited[ny][nx] = 1
							stack.append(Vector2i(nx, ny))
					else:
						neigh[nb] = int(neigh.get(nb, 0)) + 1
			if touches_border or neigh.is_empty() or cells.size() >= min_region:
				continue
			var best: int = -1
			var bestc: int = -1
			for k in neigh.keys():
				if int(neigh[k]) > bestc:
					bestc = int(neigh[k])
					best = int(k)
			for cc in cells:
				var p: Vector2i = cc
				biome[p.y][p.x] = best
			changed = true
	return changed


## 读出 PNG 的 Image（未导入的 PNG 会返回 null，交给调用方回退）。
## 统一转 RGBA8：官方瓦片边缘带透明像素（崖壁下方是镂空的），转 RGB 会把
## 透明区变成黑块，拼图时在地图边缘露出一圈黑边。
static func _load_image(path: String) -> Image:
	if path == "" or not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	if res is Texture2D:
		var im: Image = (res as Texture2D).get_image()
		if im != null:
			if im.is_compressed():
				im.decompress()
			im.convert(Image.FORMAT_RGBA8)
			return im
	return null


## 从源图里取一块并（必要时）重采样到 ts×ts。
## 官方瓦片是 64px，tile_size 也是 64 时**完全不动像素**（NEAREST 只用于缩小时）。
static func _grab(src: Image, rect: Rect2i, ts: int) -> Image:
	var region := src.get_region(rect)
	if region.get_width() != ts or region.get_height() != ts:
		region.resize(ts, ts, Image.INTERPOLATE_LANCZOS)
	return region


## 把图按系数乘色（RGB 各乘 tint 分量，alpha 原样）。tint 全 1 时直接返回原图，
## 避免四个群系都白白跑一遍逐像素循环。
static func _tinted(src: Image, tint: Color) -> Image:
	if is_equal_approx(tint.r, 1.0) and is_equal_approx(tint.g, 1.0) \
			and is_equal_approx(tint.b, 1.0):
		return src
	# 必须显式写 Image：Image.duplicate() 的静态返回类型是 Resource，
	# 用 := 推断会把 out 定成 Resource，后面 out.get_pixel() 就成了 Variant，
	# `var c := out.get_pixel(..)` 直接报 "Cannot infer the type of c"。
	var out: Image = src.duplicate()
	out.convert(Image.FORMAT_RGBA8)
	for y in range(out.get_height()):
		for x in range(out.get_width()):
			var c := out.get_pixel(x, y)
			if c.a <= 0.0:
				continue          # 透明区跳过，省一半循环
			out.set_pixel(x, y, Color(clampf(c.r * tint.r, 0.0, 1.0),
					clampf(c.g * tint.g, 0.0, 1.0),
					clampf(c.b * tint.b, 0.0, 1.0), c.a))
	return out


## 组装完整图集（横向一行，y 恒为 0）：
##   [0, BLOB_N * biome_count)       每个群系 16 个 blob 组合（官方 4x4 区块，原样）
##   [atlas_wall_start, atlas_cols)  不可通行地形 = 官方水面（一份贴图共用）
##
## 素材缺失（PNG 没导入 / 路径写错）时整张图集回退到程序化绘制，保证工程随时能跑。
static func _build_atlas_image(tile_size: int) -> Image:
	var img := Image.create(tile_size * atlas_cols(), tile_size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	var ok := true
	for b in range(biome_count()):
		var sheet := _load_image(TERRAIN_DIR + biome_tileset(b))
		if sheet == null:
			push_warning("[Map] 地形图集缺失，回退程序化绘制：%s%s"
					% [TERRAIN_DIR, biome_tileset(b)])
			ok = false
			break
		# 群系色调：必须在**这里**乘上去，不能只靠 _grade_atlas——
		# _grade_atlas 默认关闭（官方素材本身就是成品配色），挂在它下面的 tint
		# 等于死配置。以前"沼泽"用的是官方 color5（一片青绿），跟不可通行水面
		# 撞色、玩家分不清哪儿能走；现在靠 tint 把它压成沼泽黄绿就能一眼区分。
		var tint: Color = _biome_tint(b)
		for k in range(BLOB_N):
			var rect := Rect2i((k % 4) * SRC_TILE, (k / 4) * SRC_TILE, SRC_TILE, SRC_TILE)
			if rect.end.x > sheet.get_width() or rect.end.y > sheet.get_height():
				push_warning("[Map] 地形图集尺寸不足，缺少 blob 区块：%s" % biome_tileset(b))
				ok = false
				break
			img.blit_rect(_tinted(_grab(sheet, rect, tile_size), tint),
					Rect2i(0, 0, tile_size, tile_size),
					Vector2i((b * BLOB_N + k) * tile_size, 0))
		if not ok:
			break

	var water := _load_image(TERRAIN_DIR + WATER_SRC)
	if ok and water != null:
		img.blit_rect(_grab(water, Rect2i(0, 0, water.get_width(), water.get_height()), tile_size),
				Rect2i(0, 0, tile_size, tile_size),
				Vector2i(atlas_wall_start() * tile_size, 0))
	else:
		if water == null:
			push_warning("[Map] 水面贴图缺失：%s%s" % [TERRAIN_DIR, WATER_SRC])
		ok = false

	if ok:
		_used_ai_atlas = true
		_grade_atlas(img, tile_size)
		return img

	# ---- 回退：官方素材缺失时用程序化逐像素绘制 ----
	# 同样按 blob 语义画：四邻不连通的一侧描一道暗边，至少能看出地形结构。
	_used_ai_atlas = false
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = ATLAS_SEED  # 固定种子：图集外观稳定
	for b in range(biome_count()):
		var w: Dictionary = _biome_at(b)
		for k in range(BLOB_N):
			_paint_blob(img, (b * BLOB_N + k) * tile_size, tile_size, k, rng, w["floor"])
	_paint_water(img, atlas_wall_start() * tile_size, tile_size, rng)
	_grade_atlas(img, tile_size)
	return img


## 色调分级：对整张图集做「对比曲线 + 去饱和」。
##
## 【2026-09-16】默认**关闭**（map.grade.enabled = false）：官方 Tiny Swords 素材
## 本身已经是成品配色，再压对比、去饱和只会把它弄脏，四个群系的区分靠
## config 里各自挑不同的 Tilemap_colorN 来实现，比后期调色自然得多。
## 只有回退到程序化贴图时才建议打开（那时颜色是脚本糊出来的，需要拉对比）。
##
## 注意：这里**不再**乘群系 tint。tint 已经挪到 _build_atlas_image 的 blit 阶段，
## 两处都乘会让色调被平方（本来想压 0.4，结果压成 0.16）。_grade_atlas 现在只管
## 对比/亮度/饱和度这三项全局调整。
static func _grade_atlas(img: Image, ts: int) -> void:
	if not bool(Config.get_value("map.grade.enabled", false)):
		return
	var contrast: float = float(Config.get_value("map.grade.contrast", 1.12))
	var bright: float = float(Config.get_value("map.grade.brightness", 0.0))
	var sat: float = float(Config.get_value("map.grade.saturation", 0.92))
	for y in range(ts):
		for x in range(img.get_width()):
			var c := img.get_pixel(x, y)
			var r: float = clampf((c.r - 0.5) * contrast + 0.5 + bright, 0.0, 1.0)
			var g: float = clampf((c.g - 0.5) * contrast + 0.5 + bright, 0.0, 1.0)
			var b: float = clampf((c.b - 0.5) * contrast + 0.5 + bright, 0.0, 1.0)
			# 去饱和：向亮度灰靠拢（Rec.601 权重）
			var luma: float = r * 0.299 + g * 0.587 + b * 0.114
			r = luma + (r - luma) * sat
			g = luma + (g - luma) * sat
			b = luma + (b - luma) * sat
			img.set_pixel(x, y, Color(r, g, b, c.a))


static func _build_tileset(tile_size: int) -> TileSet:
	var img := _build_atlas_image(tile_size)
	# 缓存一份副本供预览合成（build_preview 用 blit_rect 拼图）
	_atlas_img = img.duplicate()
	_atlas_img.convert(Image.FORMAT_RGBA8)

	var ts := TileSet.new()
	ts.tile_size = Vector2i(tile_size, tile_size)
	# 自检：tile_size 与 atlas 源的实际取样区域必须一致。TileSetAtlasSource 的
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	# 【必须显式设置】TileSetAtlasSource.texture_region_size 的默认值是 **16x16**，
	# 它不会跟着 TileSet.tile_size 走。官方素材是 64px 格，如果不设，图集就会按
	# 16px 去切 64px 的瓦片：set_cell 取到的是"某个瓦片左上角 16px 的一小块"，
	# 再被拉成整格。症状是地面变成"深色底 + 每格一小块色斑"，而 —— 关键 ——
	# **build_preview 走的是 blit_rect 直拼、按 64px 正确切片，所以预览图是对的**，
	# 于是出现"预览好看、进游戏全黑"这种极难定位的偏差（这个坑踩过）。
	src.texture_region_size = Vector2i(tile_size, tile_size)
	for i in range(atlas_cols()):
		src.create_tile(Vector2i(i, 0))
	ts.add_source(src, 0)

	# 碰撞：只有水面列是整格实心（地形 blob 全部可走；树/石的碰撞由
	# map_generator 自己用 _build_decor_collision 补，见 generate()）
	#
	# 【必须绕原点（=格心）画，不能从 (0,0) 画到 (tile_size,tile_size)】
	# TileData 的碰撞多边形坐标系是**以格心为原点**的：编辑器里画满一格，得到的
	# 顶点就是 (-ts/2,-ts/2)…(ts/2,ts/2)。写成 (0,0)→(ts,ts) 会让整块碰撞体
	# 相对瓦片右下偏移半格（64px 格 → 偏 32px），于是：
	#   · A* 的 walls 网格认为某格可走，物理上却在"自己格子的正中间"撞墙；
	#   · 玩家能往水里走进 32px 后被卡住，而且重算路径仍是同一条 → 永久僵在原地
	#     （stall 重算救不了，因为第一步方向没变）。
	# 这个坑是行为验证探针（tools/run_soak.py）抓出来的：玩家在 move 状态
	# 有目标却静止 7.5 秒，把碰撞体 dump 出来才看到接触点正好落在格心。
	var half := float(tile_size) * 0.5
	ts.add_physics_layer()
	for i in range(atlas_wall_start(), atlas_cols()):
		var d := src.get_tile_data(Vector2i(i, 0), 0)
		d.set_collision_polygons_count(0, 1)
		d.set_collision_polygon_points(0, 0, PackedVector2Array([
			Vector2(-half, -half), Vector2(half, -half),
			Vector2(half, half), Vector2(-half, half),
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


## 填充矩形（带越界保护），回退绘制用
static func _fill_rect(img: Image, x0: int, y0: int, w: int, h: int, c: Color) -> void:
	for y in range(y0, y0 + h):
		for x in range(x0, x0 + w):
			_set_rgba(img, x, y, c)


## 单个 blob 瓦片（回退绘制）：基色 + 颗粒噪点，四邻**不连通**的一侧描一道暗边。
## 这是官方 blob 的极简近似——至少能看出"哪里是地、哪里是崖"，
## 官方 PNG 到位时走不到这里（见 _build_atlas_image 的分支）。
static func _paint_blob(img: Image, ox: int, ts: int, k: int,
		rng: RandomNumberGenerator, base: Color) -> void:
	var row: int = k / 4
	var col: int = k % 4
	var up_open: bool = row >= 1 and row <= 2
	var down_open: bool = row <= 1
	var left_open: bool = col >= 1 and col <= 2
	var right_open: bool = col <= 1
	for y in range(ts):
		for x in range(ts):
			_set_rgba(img, ox + x, y, Color(base.r, base.g, base.b, 1.0)
					* rng.randf_range(0.94, 1.06))
	var edge: int = maxi(2, ts / 12)
	var dark := Color(base.r * 0.42, base.g * 0.38, base.b * 0.34, 1.0)
	if not up_open:
		_fill_rect(img, ox, 0, ts, edge, dark)
	if not down_open:
		_fill_rect(img, ox, ts - edge, ts, edge, dark)
	if not left_open:
		_fill_rect(img, ox, 0, edge, ts, dark)
	if not right_open:
		_fill_rect(img, ox + ts - edge, 0, edge, ts, dark)


## 水面瓦片（回退绘制）：深青蓝 + 波纹颗粒
static func _paint_water(img: Image, ox: int, ts: int,
		rng: RandomNumberGenerator) -> void:
	for y in range(ts):
		for x in range(ts):
			var wave: float = 0.5 + 0.5 * sin(float(x) / float(ts) * TAU * 2.0)
			var c := Color(0.10, 0.24, 0.34).lerp(Color(0.18, 0.40, 0.52), wave)
			c = c * rng.randf_range(0.94, 1.06)
			_set_rgba(img, ox + x, y, Color(c.r, c.g, c.b, 1.0))


## ------------------------------------------------------------
## 装饰物贴图：优先 AI 生成精灵，缺失时回退程序化
## ------------------------------------------------------------

## 地表特征带（河水 / 裂缝）的通用绘制。
##
## 为什么不用朴素的 `|noise| < 阈值`：那样带宽会被噪声梯度带着跑 —— 梯度小的地方
## （噪声驻点附近）糊成一大块（实测出现过 30×27 格的水塘），梯度大的地方细成一条线。
## 除以 |∇n| 得到的是"到零等值线的近似格距"，于是带子**等宽**：多宽只由
## width_cells 决定，不再看噪声碰巧长成什么样。
##
## 本函数只决定"哪些格属于这条带"，不管纹路朝哪：贴地贴图本身做成**四向贯通**的
## （暗纹从四条边的中点接入），所以无论带往哪个方向拐，相邻格的纹路都接得上。
static func _paint_band(kind: int, prefix: String, terrain: Array, biome: Array,
		decor: Array, walls: Array, w: int, h: int,
		center: Vector2i, rng: RandomNumberGenerator) -> int:
	if not bool(Config.get_value(prefix + ".enabled", true)):
		return 0
	var width_cells: float = float(Config.get_value(prefix + ".width_cells", 0.0))
	if width_cells <= 0.0:
		return 0
	var freq: float = float(Config.get_value(prefix + ".frequency", 0.012))
	var jitter: float = float(Config.get_value(prefix + ".jitter", 0.0))
	var min_dist: int = int(Config.get_value(prefix + ".min_dist_from_spawn_cells", 0))
	var orient: Array = Config.get_value(prefix + ".orientation", [[1.0, 1.0]])
	var biome_scale: Array = Config.get_value(prefix + ".biome_scale", [])
	# 每条水系/缝系 = 主噪声（定路径）+ 摆动噪声（让岸线自然扭曲）。
	#
	# orientation 的每一项是采样域的**线性变换矩阵 [a, b, c, d]**：
	#     u = a*x + b*y ,  v = c*x + d*y
	# 对噪声做各向异性变换，零等值线才会被拉长成蜿蜒的**河/缝**；不变换的话
	# 各向同性噪声的等值线会闭合成一个个**水塘**（早期版本实测出 30×27 的大水洼）。
	# 只给两个数时按对角阵理解（[sx, sy]，纯拉伸）；给四个数就能做旋转/错切 ——
	# 用来让多组河道互不平行，避免出现"井字格"式的死板路网。
	var systems: Array = []
	for o in orient:
		var a := 1.0
		var b := 0.0
		var c := 0.0
		var d := 1.0
		if o is Array and (o as Array).size() >= 4:
			a = float(o[0])
			b = float(o[1])
			c = float(o[2])
			d = float(o[3])
		elif o is Array and (o as Array).size() >= 2:
			a = float(o[0])
			d = float(o[1])
		# 退化阵（不可逆）会把整个采样域压成一条线，直接判为无效
		if absf(a * d - b * c) < 1.0e-6:
			continue
		var n_main := FastNoiseLite.new()
		n_main.noise_type = FastNoiseLite.TYPE_SIMPLEX
		n_main.frequency = freq
		n_main.seed = rng.randi()
		var n_wob := FastNoiseLite.new()
		n_wob.noise_type = FastNoiseLite.TYPE_SIMPLEX
		n_wob.frequency = freq * 3.0
		n_wob.seed = rng.randi()
		systems.append({"main": n_main, "wob": n_wob, "a": a, "b": b, "c": c, "d": d})
	if systems.is_empty():
		return 0

	var painted := 0
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			if terrain[y][x]:
				continue                        # 不淹墙
			if decor[y][x] != DECOR_NONE:
				continue                        # 已被别的特征占住（带子要连续）
			if min_dist > 0 and abs(x - center.x) + abs(y - center.y) < min_dist:
				continue                        # 出生点附近留空
			var b: int = int(biome[y][x])
			var scale := 1.0
			if b >= 0 and b < biome_scale.size():
				scale = float(biome_scale[b])
			var wc: float = width_cells * scale
			if wc <= 0.0:
				continue                        # 该群系不出这种特征（如雪原无水）
			var best_d := 1.0e20
			for si in systems:
				var sd: Dictionary = si
				# 矩阵分量用 ma/mb/mc/md 命名：本块内已有一个变量 d（到带心的距离），
				# 且外层循环已用掉 b（群系 id）。同名会直接解析失败（同作用域重复声明）。
				var ma: float = float(sd["a"])
				var mb: float = float(sd["b"])
				var mc: float = float(sd["c"])
				var md: float = float(sd["d"])
				var ux: float = float(x) * ma + float(y) * mb
				var uy: float = float(x) * mc + float(y) * md
				var sn_main: FastNoiseLite = sd["main"]
				var sn_wob: FastNoiseLite = sd["wob"]
				var n0: float = sn_main.get_noise_2d(ux, uy) + sn_wob.get_noise_2d(ux, uy) * jitter
				# 沿 x 走 1 格 → u 增 ma、v 增 mc；沿 y 走 1 格 → u 增 mb、v 增 md。
				# 这样得到的就是**每格**的噪声变化率，与变换矩阵严格对应（链式法则）。
				var n_dx: float = sn_main.get_noise_2d(ux + ma, uy + mc)
				n_dx += sn_wob.get_noise_2d(ux + ma, uy + mc) * jitter
				var n_dy: float = sn_main.get_noise_2d(ux + mb, uy + md)
				n_dy += sn_wob.get_noise_2d(ux + mb, uy + md) * jitter
				var gx: float = n_dx - n0
				var gy: float = n_dy - n0
				var g: float = sqrt(gx * gx + gy * gy)
				# g ≈ 0 是噪声驻点，|n|/g 会炸；按"离得很远"处理
				var band_d: float = 1.0e6 if g < 1.0e-6 else absf(n0) / g
				if band_d < best_d:
					best_d = band_d
			if best_d > wc:
				continue
			decor[y][x] = kind
			walls[y][x] = false                 # 地表特征不阻挡通行
			painted += 1
	return painted


## 共享装饰贴图入口：2D（地图生成）与 3D（MapRender3D）都从这里取，
## 保证两个入口用的是同一张图、同一份缓存。kind 见 DECOR_*，未知类别返回 null。
## 单个 Texture2D 版本给 3D 用（3D 只按类别建 instanced mesh，不做形态变化）。
static func decor_texture(kind: int) -> Texture2D:
	var list := _decor_textures(kind)
	return list[0] if not list.is_empty() else null


## 取某类装饰的**全部**贴图（按 DECOR_PATH_LISTS 的顺序）。未知类别返回空数组。
## 贴图与 Image 两份缓存同步装载，索引一一对应（预览合成用 Image）。
static func _decor_textures(kind: int) -> Array:
	if _decor_tex.has(kind):
		return _decor_tex[kind]
	var tex_list: Array = []
	var img_list: Array = []

	# 1) 官方素材（一组 PNG）
	for path in DECOR_PATH_LISTS.get(kind, []):
		if not ResourceLoader.exists(path):
			push_warning("[Map] 装饰贴图缺失：" + str(path))
			continue
		var res: Resource = load(path)
		if res is Texture2D:
			var t: Texture2D = res
			tex_list.append(t)
			var im: Image = t.get_image()
			if im != null:
				if im.is_compressed():
					im.decompress()
				im.convert(Image.FORMAT_RGBA8)
				img_list.append(im)
			else:
				img_list.append(null)

	# 2) 河水/裂缝没有 PNG：裂缝纯程序化，河水取官方水面底色（整格可平铺）
	if tex_list.is_empty():
		var proc := _make_procedural_decor(kind)
		if proc == null:
			_decor_tex[kind] = []
			_decor_img[kind] = []
			return []
		tex_list.append(ImageTexture.create_from_image(proc))
		img_list.append(proc)

	_decor_tex[kind] = tex_list
	_decor_img[kind] = img_list
	return tex_list


## 无 PNG 素材的装饰类别的程序化版本（裂缝 / 河水）
static func _make_procedural_decor(kind: int) -> Image:
	match kind:
		DECOR_CRACK:
			return _make_crack()
		DECOR_WATER:
			# 官方水面底色是 64x64 可平铺瓦片；缺失时回退程序化波纹。
			var w := _load_image(TERRAIN_DIR + WATER_SRC)
			if w != null:
				w.convert(Image.FORMAT_RGBA8)
				return _shallow_water(w)
			return _make_water()
	return null


## 把深水底色提亮成"可涉水的浅滩"：与不可通行的深水拉开亮度差，
## 玩家一眼能看出哪片水走得过去。等官方浅滩瓦片到位后可替换（见缺失清单）。
static func _shallow_water(src: Image) -> Image:
	var img: Image = src.duplicate()
	img.convert(Image.FORMAT_RGBA8)
	# 【2026-09-16 修正】原实现是 k = 0.40 + 0.16*sin(x / width * TAU * 2.0)，
	# 即在**每一格 64px 内画两整周期**正弦亮带，想冒充波纹。后果是灾难性的：
	#   ① 每格图案完全相同 ⇒ 全图水面条纹相位一致、跨格严丝合缝，连成一整片
	#      "印刷网纹"（实测周期 32px、亮度在 86↔117 之间来回摆），
	#      看上去像贴图坏了，而不像水；
	#   ② 振幅最大 +0.31（单 R 通道约 +79），远超"浅滩"该有的亮度差；
	#   ③ 只跟 x 有关 ⇒ 纵向恒定、横向高频闪烁，最刺眼的方向正好朝人。
	# 浅滩要解决的是"整片水换个色调、让人看出能走"，不是"每格画波纹"。
	# 波浪/岸线的活儿应由官方 water_foam / 动画水面瓦片承担（见缺失清单）。
	# 这里改为**整片恒定提亮**：相邻水格颜色完全一致 → 河面连成一片，
	# 既没有格子缝也没有条纹。
	var k := 0.30
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(minf(c.r + k * 0.55, 1.0),
					minf(c.g + k * 0.50, 1.0), minf(c.b * 1.0 + k * 0.35, 1.0), c.a))
	return img


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


## 地表裂缝：32×32，**四向贯通**的碎裂纹。
##
## 关键设计：暗纹必须从**四条边的中点**接入（上-下、左-右各一条），这样无论带状
## 地形往哪个方向拐，相邻两格的缝都接得上。只在格中间画一小段的话，
## 铺出来是一地散点而不是一条裂缝（旧版就是这个毛病）。
static func _make_crack() -> Image:
	var n := 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var mid := n / 2
	# 纵向主缝：从上边中点走到下边中点，沿途左右抖动
	var px := float(mid)
	for y in range(n):
		var ix := clampi(int(round(px)), 1, n - 2)
		img.set_pixel(ix, y, Color(C_DARK.r, C_DARK.g, C_DARK.b, 0.90))
		img.set_pixel(ix + 1, y, Color(C_DARK.r, C_DARK.g, C_DARK.b, 0.44))
		img.set_pixel(ix - 1, y, Color(C_STONE.r, C_STONE.g, C_STONE.b, 0.20))
		px += rng.randf_range(-1.25, 1.25)
		px = clampf(px, 4.0, float(n) - 5.0)
	# 横向副缝：同上，但细一档、断断续续（避免每格都是整齐的十字）
	var py := float(mid)
	for x in range(n):
		if rng.randf() < 0.22:
			py += rng.randf_range(-0.8, 0.8)
			py = clampf(py, 4.0, float(n) - 5.0)
			continue
		var iy := clampi(int(round(py)), 1, n - 2)
		var c0: Color = img.get_pixel(x, iy)
		img.set_pixel(x, iy, c0.lerp(Color(C_DARK.r, C_DARK.g, C_DARK.b, 0.78), 1.0))
		var c1: Color = img.get_pixel(x, iy + 1)
		img.set_pixel(x, iy + 1, c1.lerp(Color(C_DARK.r, C_DARK.g, C_DARK.b, 0.32), 1.0))
	# 缝口两侧的崩碎颗粒
	for _i in range(14):
		var sx := rng.randi_range(0, n - 1)
		var sy := rng.randi_range(0, n - 1)
		var cp: Color = img.get_pixel(sx, sy)
		img.set_pixel(sx, sy, cp.lerp(Color(C_STONE.r, C_STONE.g, C_STONE.b, 0.18), 1.0))
	return img


## 河水：64×64，整格平铺的浅水 + 波纹高光。
##
## 分辨率必须比 16px 的瓦片高：3D 里这张贴图铺满 1 个世界单位（≈40 屏幕像素），
## 16×16 放大后是一片糊，与旁边的地面（1024² 铺 4.5 单位）档次差太远。
## 波纹用**整数周期**的正弦算，保证上下左右平铺无缝 —— 否则相邻水格之间会露出缝线。
## 刻意"整格不透明"，相邻水格拼起来才是连续水面，而不是一颗颗水方块。
static func _make_water() -> Image:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var deep := Color(0.09, 0.19, 0.27)
	var mid := Color(0.16, 0.31, 0.40)
	var hi := Color(0.36, 0.56, 0.64)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4711
	for y in range(n):
		for x in range(n):
			var u := float(x) / float(n)
			var v := float(y) / float(n)
			var a: float = sin(TAU * (u * 2.0 + sin(TAU * v) * 0.10))
			var b: float = sin(TAU * (v * 3.0 + sin(TAU * u * 2.0) * 0.08))
			var wave: float = clampf((a * 0.6 + b * 0.4) * 0.5 + 0.5, 0.0, 1.0)
			var c: Color = deep.lerp(mid, wave)
			c = c.lerp(hi, clampf(wave * wave * 0.60, 0.0, 1.0))
			c = c.lerp(hi, rng.randf() * 0.10)          # 细碎波光
			c.a = 0.90
			img.set_pixel(x, y, c)
	return img


## 矿脉露头贴图（缓存）：按 ORE_PATH_LISTS 抽形态；素材缺失时回退程序化。
## gx/gy 用于确定性取形态（同一处矿脉每次生成长得一样）。
static func _ore_texture(kind: int, gx: int = 0, gy: int = 0) -> Texture2D:
	var list: Array = _ore_tex.get(kind, [])
	if list.is_empty():
		var paths: Array = ORE_PATH_LISTS.get(kind, [])
		for path in paths:
			if not ResourceLoader.exists(path):
				push_warning("[Map] 矿脉贴图缺失：" + str(path))
				continue
			var res: Resource = load(path)
			if res is Texture2D:
				list.append(res)
		if list.is_empty():
			# 回退：程序化矿石露头
			list.append(ImageTexture.create_from_image(_make_ore(kind)))
		_ore_tex[kind] = list
	var idx: int = _decor_variant(gx, gy, list.size())
	return list[idx]


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


## 以 cell 为中心按**环**向外找最近的可通行格（含自身）；找不到返回 (-1,-1)。
##
## 寻路兜底用（玩家与敌人共用，避免两套实现各说各话）：
## AStarGrid2D 对 solid 点一律返回空路径，所以只要起点或终点落在障碍格
## （击退/冲刺把人推进树里、或点击点正好在树上）就"永远走不动"。
## 出发前先把两端吸附到最近的可走格，行为就稳定了。
## 半径写死成小值：太大会让"点树"变成"绕到很远的地方去"，反而迷惑。
static func nearest_open_cell(walls: Array, cell: Vector2i, radius: int) -> Vector2i:
	var h: int = walls.size()
	if h == 0:
		return Vector2i(-1, -1)
	var w: int = walls[0].size()
	for r in range(0, radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue                       # 只扫当前环；内圈上一轮已扫过
				var c := Vector2i(cell.x + dx, cell.y + dy)
				if c.x < 0 or c.y < 0 or c.x >= w or c.y >= h:
					continue
				if not walls[c.y][c.x]:
					return c
	return Vector2i(-1, -1)


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

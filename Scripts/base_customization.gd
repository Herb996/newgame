class_name BaseCustomization
extends RefCounted
## ============================================================
## BaseCustomization — 玩家自定义基地的地面与摆件（数据 + 渲染）
##
## 为什么不走 MapGenerator.generate()：随机撒点摆出来的基地"太丑"（树穿过房子、
## 湖占掉三分之一），玩家要的是自己决定每棵树站哪。所以这里只有**稀疏格子表**
## 和**把表画出来**这两件事，贴图与瓦片算法全部复用 MapGenerator。
##
## 数据形状（整个存进存档槽的一个键 base_custom，见 meta_progression / save_slots）：
##   { "v": 1,
##     "size": 64,
##     "ground": {"12,30": 2},   # 稀疏：只有玩家改过的格子。值 = 群系 id（0草/1荒/2林/3沼）
##     "water":  {"30,10": 1},   # 稀疏：被涂成水的格子。擦掉 = 键不存在
##     "props":  {"12,31": 1},   # 稀疏：值 = 摆件 id，见下面 PROP_*
##     "buildings": {"20,40": "farm"} }  # 稀疏：键 = 占地**左上角**格，值 = base.buildings 的 id
## 没改过的格子一律走默认（草地 + 无水 + 无摆件），所以老存档缺这个键 = 空表，
## 不需要版本迁移。
##
## ⚠ 与局内地图生成器的两处**刻意**不同，别"顺手统一"掉：
##   1. 抖动是**格子坐标的稳定 hash**，不是每局重掷的 RNG —— 基地必须每次进来
##      长得一样，树不会今天歪一点明天正一点。
##   2. 不产生碰撞、不参与寻路：基地没有可走角色（DESIGN §2.4「纯布景」）。
## ============================================================

## 存档格式版本（以后加图层时递增，读旧档按 v 判断缺什么）
const DATA_VERSION := 1

# --- 摆件 id：1~6 直接对齐 MapGenerator.DECOR_*，7~9 是矿脉 ---
const PROP_TREE := 1
const PROP_ROCK := 2
const PROP_DEBRIS := 3
const PROP_CRACK := 4
const PROP_RIVER := 5
const PROP_BUSH := 6
const PROP_VEIN_IRON := 7
const PROP_VEIN_GOLD := 8
const PROP_VEIN_OIL := 9
const PROP_MIN := 1
const PROP_MAX := 9
const PROP_VEIN_BASE := 6      # 矿脉 id 减 6 = MapGenerator.VEIN_* 的 kind

const BIOME_MIN := 0
const BIOME_MAX := 3           # 群系数量由 config map.biomes 决定，这里只做越界兜底


# ------------------------------------------------------------
# 数据：空表 / 出厂默认布置 / 存档清洗
# ------------------------------------------------------------

static func empty() -> Dictionary:
	return {"v": DATA_VERSION, "size": 0, "ground": {}, "water": {}, "props": {}, "buildings": {}}


static func is_empty(custom: Dictionary) -> bool:
	return (custom.get("ground", {}) as Dictionary).is_empty() \
			and (custom.get("water", {}) as Dictionary).is_empty() \
			and (custom.get("props", {}) as Dictionary).is_empty() \
			and (custom.get("buildings", {}) as Dictionary).is_empty()


## 层枚举 → 稀疏表的键。编辑器那边 Layer 枚举多了 BUILDINGS 之后，
## ["ground","water","props"] 这种按下标取表的写法会直接越界 —— 统一走这里。
static func layer_key(layer: int) -> String:
	match layer:
		0: return "ground"
		1: return "water"
		2: return "props"
		3: return "buildings"
		_: return ""


## 存档里读出来的东西一律清洗：手改过的 JSON、半截写入、以后改格式，都不能让
## 基地画崩或者把越界 id 喂给贴图函数。非 Dictionary 直接当空表。
static func sanitize(raw) -> Dictionary:
	var out := empty()
	if not (raw is Dictionary):
		return out
	var src: Dictionary = raw
	out["v"] = int(src.get("v", DATA_VERSION))
	out["size"] = maxi(0, int(src.get("size", 0)))
	# 地面可用的值域是**素材表**决定的，不再是局内那 4 个群系 ——
	# 这几行是最容易漏改的地方：漏了的话玩家刷的第 4 号往后全会被夹回 3（沼泽）。
	out["ground"] = _sanitize_cells(src.get("ground"), _max_ground_id(), true)
	out["water"] = _sanitize_cells(src.get("water"), 1, true)
	out["props"] = _sanitize_cells(src.get("props"), maxi(PROP_MAX, BaseMaterials.prop_count()), false)
	out["buildings"] = _sanitize_buildings(src.get("buildings"))
	return out


## 建筑实例表：**值是 id 字符串**，所以不走 _sanitize_cells（那个只认整数）。
## id 必须还在 config 的 base.buildings 里才知道怎么画；已经下线的 id 直接丢 ——
## 留着的话重建时会实例化出一堆缺图建筑，还往日志里刷一堆警告。
static func _sanitize_buildings(raw) -> Dictionary:
	var out := {}
	if not (raw is Dictionary):
		return out
	var known := BaseMaterials.building_ids()
	for k in (raw as Dictionary).keys():
		var cell := parse_key(str(k))
		if cell.is_empty():
			continue
		var bid := str((raw as Dictionary)[k])
		if bid.is_empty() or not known.has(bid):
			continue
		out[key_of(int(cell[0]), int(cell[1]))] = bid
	return out


## 通用格子清洗：键必须是 "x,y" 且落在 [0,size) 内，值必须是 [0,max] 的整数。
## clamp_to_max=false 时越界值直接丢弃（摆件 id 越界没有"就近夹一下"的意义）。
static func _sanitize_cells(raw, max_v: int, clamp_to_max: bool) -> Dictionary:
	var out := {}
	if not (raw is Dictionary):
		return out
	for k in (raw as Dictionary).keys():
		var cell := parse_key(str(k))
		if cell.is_empty():
			continue
		var v := int((raw as Dictionary)[k])
		if v < 0:
			continue
		if v > max_v:
			if not clamp_to_max:
				continue
			v = max_v
		out["%d,%d" % [int(cell[0]), int(cell[1])]] = v
	return out


## 合法素材数（清洗存档时的上界）。以前等于群系数，现在读的是素材表。
static func _biome_count() -> int:
	return BaseMaterials.ground_count()


static func parse_key(key: String) -> Array:
	var parts := key.split(",")
	if parts.size() != 2:
		return []
	var x := int(parts[0])
	var y := int(parts[1])
	if str(x) != parts[0].strip_edges() or str(y) != parts[1].strip_edges():
		return []
	return [x, y]


static func key_of(x: int, y: int) -> String:
	return "%d,%d" % [x, y]


## 出厂默认布置：config `base.default_layout` 里的矩形展开成稀疏格子表。
## 新存档（没有 base_custom 键）拿它当起点，老玩家改过的表**不会被覆盖** ——
## 判定在 meta_progression 里：只有键缺失才展开默认。
##   ground: [{"biome":2,"rect":[x,y,w,h]}]
##   water:  [{"rect":[x,y,w,h]}]
##   props:  [{"kind":1,"rect":[x,y,w,h],"step":2}]   # step=每 N 格放一个
## 越界与 step 都在展开时处理，所以美术改完不用自己数格子有没有出图。
static func from_default_layout(size: int) -> Dictionary:
	var out := empty()
	out["size"] = size
	var layout: Dictionary = Config.get_value("base.default_layout", {})
	var side: int = maxi(0, size - 1)
	for e in (layout.get("ground", []) as Array):
		if not (e is Dictionary):
			continue
		var b := int((e as Dictionary).get("biome", 0))
		if b < BIOME_MIN or b > _max_ground_id():
			push_warning("[BaseCustom] 默认布置里的群系 id 越界：%d，跳过" % b)
			continue
		for c in _cells_in_rect((e as Dictionary).get("rect", []), 1, side):
			out.ground[key_of(c[0], c[1])] = b
	for e in (layout.get("water", []) as Array):
		if not (e is Dictionary):
			continue
		for c in _cells_in_rect((e as Dictionary).get("rect", []), 1, side):
			out.water[key_of(c[0], c[1])] = 1
	for e in (layout.get("props", []) as Array):
		if not (e is Dictionary):
			continue
		var k := int((e as Dictionary).get("kind", 0))
		if k < PROP_MIN or k > PROP_MAX:
			push_warning("[BaseCustom] 默认布置里的摆件 id 越界：%d，跳过" % k)
			continue
		var step := maxi(1, int((e as Dictionary).get("step", 1)))
		for c in _cells_in_rect((e as Dictionary).get("rect", []), step, side):
			out.props[key_of(c[0], c[1])] = k
	return out


## 基地扩图后的存档迁移：只把出厂默认布置补进**新长出来的那一圈**
## （任一坐标 >= old_size 的格子），老区域里玩家自己改过的一律不动。
## 不这么做的话，多出来的那条边带会因为稀疏表里没记录而全落回默认草皮
## （ground_at 的兜底），基地外圈凭空多出一圈"太干净的新地面"。
static func pad_default_layout_band(custom: Dictionary, old_size: int, new_size: int) -> Dictionary:
	var out := sanitize(custom)
	if new_size <= old_size:
		return out
	var d := from_default_layout(new_size)
	for layer in ["ground", "water", "props"]:
		var dst: Dictionary = out[layer]
		var src: Dictionary = d[layer]
		for k in src.keys():
			if dst.has(k):
				continue
			var cell := parse_key(str(k))
			if cell.is_empty():
				continue
			if int(cell[0]) < old_size and int(cell[1]) < old_size:
				continue
			dst[k] = src[k]
	return out


## 矩形 → 格子列表。rect = [x,y,w,h]，step 沿两个方向同时跳格。
static func _cells_in_rect(raw, step: int, side: int) -> Array:
	var out: Array = []
	if not (raw is Array) or (raw as Array).size() < 4:
		push_warning("[BaseCustom] 默认布置的 rect 不是 [x,y,w,h]，跳过")
		return out
	var x0 := int(raw[0])
	var y0 := int(raw[1])
	var w := int(raw[2])
	var h := int(raw[3])
	var y := y0
	while y <= y0 + h - 1:
		var x := x0
		while x <= x0 + w - 1:
			if x >= 0 and y >= 0 and x <= side and y <= side and ((x - x0) % step == 0) \
					and ((y - y0) % step == 0):
				out.append([x, y])
			x += step
		y += step
	return out


# ------------------------------------------------------------
# 查询（渲染与编辑模式共用）
# ------------------------------------------------------------

static func ground_at(custom: Dictionary, x: int, y: int) -> int:
	var g: Dictionary = custom.get("ground", {})
	if not g.has(key_of(x, y)):
		return 0
	# 素材表缩过栏目（或手改存档写了不存在的 id）→ 夹回最大那款，
	# 总比把越界 id 直接喂给 set_cell 拿一块不存在的图集列强。
	return clampi(int(g[key_of(x, y)]), 0, _max_ground_id())


static func is_water(custom: Dictionary, x: int, y: int) -> bool:
	var w: Dictionary = custom.get("water", {})
	return w.has(key_of(x, y))


static func prop_at(custom: Dictionary, x: int, y: int) -> int:
	var p: Dictionary = custom.get("props", {})
	return int(p.get(key_of(x, y), 0)) if p.has(key_of(x, y)) else 0


## 点到的这格属于哪栋「玩家额外摆的建筑」？返回 {"anchor": Vector2i, "id": String}，
## 没有就返回空字典。
## 为什么要回溯：表里的键是**占地左上角**，而玩家擦除时随手点在房子中间，
## 只查当前这格永远擦不掉东西。footprint 是建筑的占地边长（config base.building_cells）。
static func building_instance_at(custom: Dictionary, x: int, y: int, footprint: int) -> Dictionary:
	var b: Dictionary = custom.get("buildings", {})
	if b.is_empty() or footprint <= 0:
		return {}
	for dy in range(footprint):
		for dx in range(footprint):
			var ax := x - dx
			var ay := y - dy
			var k := key_of(ax, ay)
			if b.has(k):
				return {"anchor": Vector2i(ax, ay), "id": str(b[k])}
	return {}


## 某栋建筑占了哪些格子（给「这格能不能放」的重叠判定用）
static func building_footprint_keys(x: int, y: int, footprint: int) -> Array:
	var out: Array = []
	for dy in range(footprint):
		for dx in range(footprint):
			out.append(key_of(x + dx, y + dy))
	return out


# ------------------------------------------------------------
# 渲染
# ------------------------------------------------------------

## 地面层：把稀疏表摊成生成器认得的 terrain/biome 二维数组，再按四邻连通性
## 反查官方 blob 瓦片（同一套算法，所以群系交界的岸线/崖壁描边跟局内地图一致）。
## ⚠ terrain 的约定与直觉相反：**true = 不可走（水）**。MapGenerator._blob_linked
##   里写的是 `if bool(terrain[ny][nx]): return false`（邻格是墙就不连通）。
##   第一次接这里把 true 当成"是地板"，结果每一格都被判成孤岛、整张基地铺满
##   带描边的单格瓦片，看着像棋盘。改的时候连下面 set_cell 的分支一起看。
## 地面材质：底下可选的素材不再等于局内那 4 个群系 —— 见 base_materials.gd。
## 可能一批 id（0..N），每块地面的 id 由玩家在编辑模式里刷出来。
static func _max_ground_id() -> int:
	return BaseMaterials.max_ground_id()


static var _ts_cache: TileSet = null
static var _ts_key := ""
static var _ts_wall_start := 0


## 基地地面用的 TileSet（**整个基地共用一份**，刷一格用的也是它）。
##
## ⚠ 必须缓存：_build_tileset 是把每种素材的 16 块 blob 逐张 blit 成一张大图的活，
##   10 种素材 = 161 格 × 64px 的 Image。编辑模式里每拖一下鼠标都重来一遍会直接卡死手感，
##   而 TileSet 本身跟有没有改过地面无关（图集列布局只取决于素材表），所以缓存是安全的。
##   key 里带上素材数与最大 id —— 以后加素材会自然失效重来。
static func base_tileset(tile_size: int) -> TileSet:
	var key := "%d|%d|%d" % [tile_size, BaseMaterials.ground_count(),
			BaseMaterials.max_ground_id()]
	if _ts_cache != null and _ts_key == key:
		return _ts_cache
	BaseMaterials.begin_ground_scope()
	var ts := MapGenerator._build_tileset(tile_size)
	_ts_wall_start = MapGenerator.atlas_wall_start()
	BaseMaterials.end_ground_scope()
	_ts_cache = ts
	_ts_key = key
	return ts


## 水面在图集里的列号（= 所有素材的 blob 段之后）。同样要在建图集之后才算得准。
static func wall_atlas_col(tile_size: int) -> int:
	base_tileset(tile_size)
	return _ts_wall_start


## 地形/群系二维数组，增量刷新与整层重建共用（见 terrain_arrays）。
static func _cell_atlas(arrays: Array, x: int, y: int, wall_col: int) -> Vector2i:
	var terrain: Array = arrays[0]
	var biome: Array = arrays[1]
	if bool(terrain[y][x]):
		return Vector2i(wall_col, 0)
	var b: int = int(biome[y][x])
	return Vector2i(b * MapGenerator.BLOB_N + MapGenerator.blob_index(terrain, x, y, biome), 0)


## 稀疏表 → MapGenerator 认得的地形/群系二维数组。[terrain, biome]
## ⚠ terrain 的约定与直觉相反：**true = 不可走（水）**。MapGenerator._blob_linked
##   里写的是 `if bool(terrain[ny][nx]): return false`（邻格是墙就不连通）。
##   第一次接这里把 true 当成"是地板"，结果每一格都被判成孤岛、整张基地铺满
##   带描边的单格瓦片，看着像棋盘。改的时候连下面 set_cell 的分支一起看。
static func terrain_arrays(custom: Dictionary, size: int) -> Array:
	var terrain: Array = []
	var biome: Array = []
	for y in range(size):
		var trow: Array = []
		var brow: Array = []
		for x in range(size):
			trow.append(is_water(custom, x, y))          # true = 水 / 不可走
			brow.append(ground_at(custom, x, y))
		terrain.append(trow)
		biome.append(brow)
	return [terrain, biome]


static func build_ground_layer(custom: Dictionary, size: int, tile_size: int) -> TileMapLayer:
	var arrays := terrain_arrays(custom, size)
	var layer := TileMapLayer.new()
	layer.name = "BaseGround"
	layer.tile_set = base_tileset(tile_size)
	var wall_col := wall_atlas_col(tile_size)
	for y in range(size):
		for x in range(size):
			layer.set_cell(Vector2i(x, y), 0, _cell_atlas(arrays, x, y, wall_col))
	return layer


## 增量刷新：只重画 center 这一格**以及它的四邻**。
##
## 为什么必须带上四邻：图集是 4-bit blob autotile，每格画哪一块取决于它四边跟谁连通
## （有没有岸线/描边）。只重画改动格会让邻居还留着旧接缝 —— 表现为"刚涂的方块边上
## 一圈豁口"。改一格要重算 5 格，这是这套素材的固有成本。
## arrays 是调用方持有的那份 terrain/biome —— 它必须先被同步更新过。
static func paint_cells(layer: TileMapLayer, arrays: Array, x: int, y: int, size: int,
		tile_size: int) -> void:
	if layer == null:
		return
	var wall_col := wall_atlas_col(tile_size)
	for c in [[x, y], [x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
		var nx: int = c[0]
		var ny: int = c[1]
		if nx < 0 or ny < 0 or nx >= size or ny >= size:
			continue
		layer.set_cell(Vector2i(nx, ny), 0, _cell_atlas(arrays, nx, ny, wall_col))


## 改动了一格数据之后同步 arrays（terrain / biome 两个格里的值），
## 再交给 paint_cells 重画。错开这两步会画出"数据已改、画面没跟上"的诡异中间态。
static func sync_arrays(arrays: Array, custom: Dictionary, x: int, y: int) -> void:
	if x < 0 or y < 0:
		return
	var terrain: Array = arrays[0]
	var biome: Array = arrays[1]
	if y >= terrain.size() or x >= (terrain[0] as Array).size():
		return
	terrain[y][x] = is_water(custom, x, y)
	biome[y][x] = ground_at(custom, x, y)


## 摆件层：树/石/灌木/碎石/裂缝/河水/矿脉。按 DECOR_RENDER_ORDER 分趟，
## 保证贴地的在最底、立体物件压在上面并且影子先于本体入树。
## blocked = 要跳过的格子集合（"x,y" -> true）：建筑占地里长树就是刚才那种丑法，
## 与其要求美术摆的时候数格子，不如渲染时一律不画。
static func build_props_layer(custom: Dictionary, size: int, tile_size: int,
		blocked: Dictionary = {}) -> Node2D:
	var root := Node2D.new()
	root.name = "BaseProps"
	root.y_sort_enabled = true
	var shadow_on := bool(Config.get_value("map.decor.shadow", true))
	var props: Dictionary = custom.get("props", {})

	for k in MapGenerator.DECOR_RENDER_ORDER:
		var kind := int(k)
		var cells := _cells_of_kind(props, kind, blocked)
		if cells.is_empty():
			continue
		var tex_list := MapGenerator._decor_textures(kind)
		if tex_list.is_empty():
			continue
		for c in cells:
			_add_decor(root, tex_list, kind, c[0], c[1], size, tile_size, custom, shadow_on)

	for c in _cells_in_range(props, PROP_VEIN_IRON, PROP_VEIN_OIL, blocked):
		_add_vein(root, int(props[key_of(c[0], c[1])]) - PROP_VEIN_BASE,
				c[0], c[1], tile_size, custom, shadow_on)
	return root


static func _cells_of_kind(props: Dictionary, kind: int, blocked: Dictionary) -> Array:
	return _cells_in_range(props, kind, kind, blocked)


static func _cells_in_range(props: Dictionary, lo: int, hi: int,
		blocked: Dictionary = {}) -> Array:
	var out: Array = []
	for key in props.keys():
		var v := int(props[key])
		if v < lo or v > hi:
			continue
		var k := str(key)
		if blocked.has(k):
			continue
		var cell := parse_key(k)
		if cell.is_empty():
			continue
		out.append(cell)
	out.sort_custom(func(a, b): return a[1] < b[1] if a[1] != b[1] else a[0] < b[0])
	return out


static func _add_decor(root: Node2D, tex_list: Array, kind: int, x: int, y: int,
		size: int, tile_size: int, custom: Dictionary, shadow_on: bool) -> void:
	var tex: Texture2D = tex_list[_hash(x, y, 11) % tex_list.size()]
	if tex == null:
		return
	var tex_size := Vector2(tex.get_size())
	var flat: bool = MapGenerator.DECOR_FLAT.has(kind)
	var pos := Vector2(x * tile_size + tile_size * 0.5, y * tile_size + tile_size * 0.5)
	var sc := Vector2.ONE
	if flat:
		sc = Vector2(float(tile_size) / maxf(tex_size.x, 1.0),
				float(tile_size) / maxf(tex_size.y, 1.0))
	else:
		var j := _jitter(x, y)
		sc = Vector2(0.92 + j * 0.16, 0.94 + _jitter(x, y + 7) * 0.14)

	if shadow_on and not flat and not MapGenerator.DECOR_NO_SHADOW.has(kind):
		var shadow_tex := MapGenerator._decor_shadow_texture(kind, tex_size.x)
		if shadow_tex != null:
			var sh := Sprite2D.new()
			sh.texture = shadow_tex
			sh.centered = false
			sh.scale = sc
			sh.position = pos
			sh.offset = Vector2(-shadow_tex.get_width() * 0.5, 0.0)
			root.add_child(sh)          # 影子必须先入树：同 y 时 y_sort 保持添加序

	var s := Sprite2D.new()
	s.texture = tex
	s.centered = false
	s.scale = sc
	s.flip_h = _hash(x, y, 23) % 2 == 0
	if MapGenerator.DECOR_UNIFORM_TINT.has(kind):
		s.modulate = MapGenerator.DECOR_UNIFORM_TINT[kind]
	else:
		var tint: Color = MapGenerator._biome_tint(ground_at(custom, x, y))
		var base_tint: Color = MapGenerator.DECOR_BASE_TINT.get(kind, Color(1, 1, 1))
		s.modulate = Color(tint.r * base_tint.r, tint.g * base_tint.g, tint.b * base_tint.b) \
				* (0.94 + _jitter(x, y + 31) * 0.12)
	s.position = pos
	s.offset = Vector2(-tex_size.x * 0.5, -tex_size.y * 0.5) if flat \
			else Vector2(-tex_size.x * 0.5, 2.0 - tex_size.y)
	s.set_meta("refl", not flat)        # 与局内一致：weather 侧按这个 meta 找倒影源
	root.add_child(s)


static func _add_vein(root: Node2D, vein_kind: int, x: int, y: int, tile_size: int,
		custom: Dictionary, shadow_on: bool) -> void:
	var tex := MapGenerator._ore_texture(vein_kind, x, y)
	if tex == null:
		return
	var pos := Vector2(x * tile_size + tile_size * 0.5, y * tile_size + tile_size * 0.5)
	var sc := Vector2(0.94 + _jitter(x, y) * 0.11, 0.94 + _jitter(x + 5, y) * 0.11)
	if shadow_on:
		var osh := MapGenerator._decor_shadow_texture(MapGenerator.DECOR_ROCK,
				tex.get_width() * 0.7)
		if osh != null:
			var sh := Sprite2D.new()
			sh.texture = osh
			sh.centered = false
			sh.scale = sc
			sh.position = pos
			sh.offset = Vector2(-osh.get_width() * 0.5, 0.0)
			root.add_child(sh)
	var s := Sprite2D.new()
	s.texture = tex
	s.centered = false
	s.scale = sc
	s.flip_h = _hash(x, y, 41) % 2 == 0
	s.modulate = MapGenerator._biome_tint(ground_at(custom, x, y)) \
			* (0.96 + _jitter(x, y + 17) * 0.08)
	s.position = pos
	s.offset = Vector2(-tex.get_width() * 0.5, 2.0 - tex.get_height())
	s.set_meta("refl", true)
	root.add_child(s)


# ------------------------------------------------------------
# 稳定抖动：同一个格子永远同一个值（基地要"每次进来长得一样"）
# ------------------------------------------------------------

static func _hash(x: int, y: int, salt: int) -> int:
	var v := (x * 73856093) ^ (y * 19349663) ^ (salt * 83492791)
	return absi(v)


## 0..1 的稳定伪随机
static func _jitter(x: int, y: int) -> float:
	return float(_hash(x, y, 7) % 1000) / 1000.0

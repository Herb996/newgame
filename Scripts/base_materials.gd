class_name BaseMaterials
extends RefCounted
## ============================================================
## BaseMaterials — 基地自定义地面的「素材表」
##
## 一条素材 = **一张 Tiny Swords 官方地形图 + 一个染色**：
##   tileset 取 TS 目录下那 5 张配色图之一（决定地形轮廓/描边的走向），
##   tint 是逐通道乘数（>1 提亮、<1 压暗）。两者相乘才是玩家看到的那块地面，
##   所以「加一款新地面」不需要新画图 —— 换图或调色即可（雪原/沙漠/焦土都是这么来的）。
##
## id 就是存档 base_custom.ground 里存的那个值。
## ⚠ id 一旦投入使用就**终身不许改指向**：老存档里存的是裸整数，
##   把 id 4 从「雪原」改成「熔岩」会让玩家上一版铺的雪原整片变色。要改外观只能加新 id。
##
## 为什么素材表要临时写进 Config 覆盖层（begin_ground_scope）：
##   MapGenerator 里所有图集布局（biome_count / atlas_cols / _build_tileset /
##   blob_index）都是**从 `map.biomes` 派生**的。基地想多出几种可选地面，最省事且
##   零改 MapGenerator 的做法就是：渲染基地图集的那一瞬间把素材表当成「群系表」
##   喂进去，图集白捡 blob 自动拼接 + 岸线描边 +  Hybrid；用完立刻还原。
##   代价是这条切换是**进程级全局**的，见 MapGenerator.clear_biome_cache 的警告。
## ============================================================

const GROUND_KEY := "base.ground_materials"
const PROP_KEY := "base.prop_materials"
## 建筑画笔的调色板 = 基地出厂布局那份 base.buildings（同一份配置兼顾两处，
## 所以新增一栋结构中的房子，它立刻既能出现在基地里、也能出现在画笔上）。
const BUILDING_KEY := "base.buildings"

## 素材条目的兜底（配置项缺一半时也不至于让整张基地画不出来）
const FALLBACK_TILESET := "tilemap_color1.png"
const FALLBACK_TINT := [1.0, 1.0, 1.0]
const FALLBACK_SWATCH := [0.30, 0.36, 0.18]


static var _cache: Array = []
static var _prop_cache: Array = []
static var _bld_cache: Array = []


# ------------------------------------------------------------
# 地面素材
# ------------------------------------------------------------

## 全部可用地面素材，按 id 升序。形状：
##   [{"id":int, "name":String, "tileset":String, "tint":Color, "swatch":Color}, ...]
static func ground_materials() -> Array:
	if _cache.is_empty():
		_cache = _load()
	return _cache


static func ground_count() -> int:
	return ground_materials().size()


static func _material_at(id: int) -> Dictionary:
	var list := ground_materials()
	if list.is_empty():
		return {}
	return list[clampi(id, 0, list.size() - 1)] as Dictionary


static func ground_name(id: int) -> String:
	var m := _material_at(id)
	return str(m.get("name", "?")) if not m.is_empty() else "?"


## 编辑面板上的色卡颜色（不参与渲染）。
static func ground_swatch(id: int) -> Color:
	var m := _material_at(id)
	return m.get("swatch", Color(0.3, 0.36, 0.18)) if not m.is_empty() \
			else Color(0.3, 0.36, 0.18)


static func max_ground_id() -> int:
	var list := ground_materials()
	return int(list[list.size() - 1]["id"]) if not list.is_empty() else 0


## 没配 / 配坏了 → 回落到「局内那套群系」，保证基地永远画得出来，
## 且行为与加素材表之前完全一致（那段时间的存档也全部兼容）。
static func _load() -> Array:
	var raw = Config.get_value(GROUND_KEY, null)
	if raw is Array and not (raw as Array).is_empty():
		var parsed := _sanitize_list(raw as Array)
		if not parsed.is_empty():
			return parsed
		push_warning("[BaseMat] %s 一条都不合法，回落到局内群系" % GROUND_KEY)
	var out: Array = []
	for i in range(MapGenerator.biome_count()):
		out.append({
			"id": i,
			"name": MapGenerator.biome_name(i),
			"tileset": MapGenerator.biome_tileset(i),
			"tint": MapGenerator._biome_tint(i),
			"swatch": Color(0.3, 0.36, 0.18),
		})
	return out


static func _sanitize_list(raw: Array) -> Array:
	var seen := {}
	var out: Array = []
	for entry in raw:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var id := int(e.get("id", -1))
		if id < 0 or seen.has(id):
			continue                      # id 重复：后者可能是复制粘贴忘记改，直接丢
		var ts := str(e.get("tileset", FALLBACK_TILESET))
		if ts == "":
			ts = FALLBACK_TILESET
		seen[id] = true
		out.append({
			"id": id,
			"name": str(e.get("name", "素材%d" % id)),
			"tileset": ts,
			"tint": _arr_to_color(e.get("tint", FALLBACK_TINT)),
			"swatch": _arr_to_color(e.get("swatch", FALLBACK_SWATCH)),
		})
	out.sort_custom(func(a, b): return int(a["id"]) < int(b["id"]))
	return out


static func _arr_to_color(v) -> Color:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return Color(1, 1, 1)


# ------------------------------------------------------------
# 建筑调色板（画笔用的规格表，与出厂那份 base.buildings 同源）
#
# 注意一处**刻意不同**：地面/摆件的稀疏表记的是整数 id，建筑表记的是 **id 字符串**。
#   整数 id 会随着 config 里删一栋楼而整体错位（第 5 栋变第 4 栋，玩家存档里那一整排
#   房子集体换脸）；字符串至少能把「配错了」识别成「不存在」，读档时安全跳过。
# 出厂那 12 栋是**功能入口**（传送门/仓库/升级），不在画笔的增删范围内 —— 见
#   base_custom_editor 建筑层的规则：只能清空画笔自己摆出来的实例。
# ------------------------------------------------------------

## [{"id":String, "name":String, "hint":String, "sprite":String, "anim_frames":int, "anim_fps":float}, ...]
## 顺序 = config 里的顺序，也是画笔按钮的顺序（斑点的 _value = 这个下标）。
static func building_specs() -> Array:
	if _bld_cache.is_empty():
		_bld_cache = _load_buildings()
	return _bld_cache


static func building_count() -> int:
	return building_specs().size()


## 画笔按下标换 id。越界一律返回空串（不夹到最后一栋）：
## 拿不到 id 的那次涂抹会被调用方跳过，总比玩家选第 3 栋却摆出第 12 栋好。
static func building_id(index: int) -> String:
	var list := building_specs()
	if list.is_empty() or index < 0 or index >= list.size():
		return ""
	return str((list[index] as Dictionary).get("id", ""))


static func building_spec(id: String) -> Dictionary:
	if id.is_empty():
		return {}
	for e in building_specs():
		var d: Dictionary = e
		if str(d.get("id", "")) == id:
			return d
	return {}


## id -> true，给存档清洗用（删掉已经下线的建筑 id）
static func building_ids() -> Dictionary:
	var out := {}
	for e in building_specs():
		var d: Dictionary = e
		out[str(d.get("id", ""))] = true
	return out


static func _load_buildings() -> Array:
	var raw = Config.get_value(BUILDING_KEY, [])
	if not (raw is Array):
		return []
	var seen := {}
	var out: Array = []
	for entry in raw as Array:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var id := str(e.get("id", ""))
		if id.is_empty() or seen.has(id):
			continue                       # 缺 id / id 重复：不进画笔（这栋也没法重建）
		seen[id] = true
		out.append({
			"id": id,
			"name": str(e.get("name", id)),
			"hint": str(e.get("hint", "")),
			"sprite": str(e.get("sprite", "")),
			"anim_frames": int(e.get("anim_frames", 0)),
			"anim_fps": float(e.get("anim_fps", 8.0)),
		})
	return out


# ------------------------------------------------------------
# 喂给 MapGenerator（「设 → 用 → 清」三步必须同步串在一起）
# ------------------------------------------------------------

## 把素材表伪装成群系表写进 Config 覆盖层，并让 MapGenerator 立刻重读。
## 之后所有 *算子*（biome_count / _build_tileset / blob_index）说的都是基地这套素材。
static func begin_ground_scope() -> void:
	Config.set_override("map.biomes", _as_biome_payload())
	MapGenerator.clear_biome_cache()


static func end_ground_scope() -> void:
	Config.clear_override("map.biomes")
	MapGenerator.clear_biome_cache()


## 素材 → MapGenerator._load_biomes() 认得的那几个字段。
## 基地不做 generator，所以 weights/装饰密度这些一个都不填（缺了走默认 0/1.0 也无妨，
## 唯一要紧的是 tileset 与 tint —— 图集就是靠这两项拼出来的）。
static func _as_biome_payload() -> Array:
	var out: Array = []
	for m in ground_materials():
		var e: Dictionary = m
		var c: Color = e.get("tint", Color(1, 1, 1))
		out.append({
			"name": e["name"],
			"tileset": e["tileset"],
			"tint": [c.r, c.g, c.b],
			"weight": 1.0,
			"speed": 1.0,
			"floor": [0.30, 0.36, 0.18],
			"wall": [0.50, 0.46, 0.34],
		})
	return out


# ------------------------------------------------------------
# 摆件素材（名字而已，贴图在 MapGenerator 那边按 id 取）
# ------------------------------------------------------------

static func prop_materials() -> Array:
	if _prop_cache.is_empty():
		_prop_cache = _load_props()
	return _prop_cache


static func prop_count() -> int:
	return prop_materials().size()


static func prop_name(id: int) -> String:
	var list := prop_materials()
	for e in list:
		var m: Dictionary = e
		if int(m.get("id", -1)) == id:
			return str(m.get("name", "摆件%d" % id))
	return "摆件%d" % id


static func _load_props() -> Array:
	var raw = Config.get_value(PROP_KEY, null)
	if raw is Array and not (raw as Array).is_empty():
		var out: Array = []
		var seen := {}
		for entry in raw:
			if not (entry is Dictionary):
				continue
			var id := int((entry as Dictionary).get("id", -1))
			if id < 0 or seen.has(id):
				continue
			seen[id] = true
			out.append({"id": id, "name": str((entry as Dictionary).get("name", "摆件%d" % id))})
		out.sort_custom(func(a, b): return int(a["id"]) < int(b["id"]))
		if not out.is_empty():
			return out
	return [
		{"id": 1, "name": "树"}, {"id": 2, "name": "岩石"}, {"id": 3, "name": "碎石"},
		{"id": 4, "name": "地裂"}, {"id": 5, "name": "浅滩"}, {"id": 6, "name": "灌木"},
		{"id": 7, "name": "铁矿脉"}, {"id": 8, "name": "金矿脉"}, {"id": 9, "name": "油矿脉"},
	]

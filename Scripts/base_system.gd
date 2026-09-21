extends Node
## ============================================================
## BaseSystem — 局外基地（挂在 Main 下）
## 地面 = **玩家自定义表**（Meta.base_custom：稀疏的群系/水面/摆件格子，
## 渲染在 base_customization.gd），新档起点是 config `base.default_layout` 手工摆的一套。
## base.terrain.enabled=true 时才改跑局内那套 MapGenerator（64×64）—— 那是编辑模式里
## 「随机铺一版」的重掷工具，不是默认地面（随机摆出来树穿房子、湖占三分之一，已否）。
## 建筑按 config 的 base.buildings 布局摆放（每栋 building_cells×building_cells 格），
## 但**每个存档槽可有自己的建筑位置**（Meta.base_layout 覆盖 config 默认）。
##
## 交互：
##   · 左键点建筑 → building_interacted(id) → main 路由（传送门/仓库/升级）
##   · 右键点建筑 → reposition_requested(id) → main 启动 PlacementMode 重摆
##   · 重摆落位 → apply_reposition(id, 左上角格) → 更新节点 + 写 Meta.base_layout + 存档
## ============================================================

signal building_interacted(building_id: String)
signal reposition_requested(building_id: String)

const BUILDING_SCENE := preload("res://Scenes/Building.tscn")
## 基地地形基准种子：槽号 × 7919 加在它上面（7919 是质数，相邻槽不会撞种子）。
## 槽 0（命令行直跑 / 无激活槽）拿到的就是这个值本身 → 无头回归每次同一张基地。
const TERRAIN_SEED_BASE := 20260920

var _spawn: Vector2 = Vector2.ZERO
var _entered := {}          # 防同一帧重复触发交互
var _buildings: Dictionary = {}   # id -> Building 节点
var _cells: Dictionary = {}       # id -> Vector2i 占地左上角格
var _size := 64
var _tile := 64
var _footprint := 4
## 自定义摆件层要挂到哪个节点（地面建好时记下，建筑摆完再补一层摆件）。
## 走生成器那条路时保持 null —— 装饰已经在那一坨节点里了。
var _props_host: Node2D = null


## 生成基地（由 main 调用），返回玩家出生点
func setup(root: Node2D) -> Vector2:
	_entered.clear()
	_buildings.clear()
	_cells.clear()
	_props_host = null
	_tile = int(Config.get_value("map.tile_size", 64))
	_size = int(Config.get_value("base.map_size", 64))
	_footprint = int(Config.get_value("base.building_cells", 4))

	# 地面：默认画玩家自定义表（新档 = config base.default_layout 那一套）；
	# base.terrain.enabled=true 时才改跑生成器（编辑模式里的「随机铺一版」）。
	var map_root := Node2D.new()
	map_root.name = "BaseMapRoot"
	root.add_child(map_root)
	var ground := _build_ground(map_root)

	# 玩家出生点
	var spawn_cell_cfg: Array = Config.get_value("base.player_spawn_cell", [32, 32])
	var spawn_cell := Vector2i(int(spawn_cell_cfg[0]), int(spawn_cell_cfg[1]))
	_spawn = Vector2(spawn_cell) * _tile + Vector2(_tile * 0.5, _tile * 0.5)

	# 建筑布局：优先用存档槽里保存的位置（Meta.base_layout），否则用 config 默认
	var saved: Dictionary = Meta.base_layout
	var cfg_list: Array = Config.get_value("base.buildings", [])
	for b in cfg_list:
		var id := str(b["id"])
		var cell_cfg: Array = saved[id] if saved.has(id) else b["cell"]
		var cell := Vector2i(int(cell_cfg[0]), int(cell_cfg[1]))
		var bld := BUILDING_SCENE.instantiate()
		root.add_child(bld)
		bld.setup(id, str(b["name"]), str(b.get("hint", "按 E")), str(b.get("sprite", "")))
		bld.set_cell(cell)
		bld.interacted.connect(_on_building_interacted)
		bld.reposition_requested.connect(_on_reposition_requested)
		_buildings[id] = bld
		_cells[id] = cell

	# 摆件必须在建筑之后：要拿建筑占地把"房子里长树"的格子筛掉
	_build_custom_props()

	print("[Base] 基地就绪：%dx%d 地面=%s，建筑 %d 栋，出生点 %s" % [
		_size, _size, ground, cfg_list.size(), _spawn])
	return _spawn


# ------------------------------------------------------------
# 地面（默认 = 玩家自定义表；生成器只当编辑模式里的「随机铺一版」，见 DESIGN §2.4）
# ------------------------------------------------------------

## 基地地面。返回"用的哪条路径"打进日志 —— 实拍翻车时第一眼就要知道这片地是怎么来的。
## 默认走玩家自定义表（base_custom）；base.terrain.enabled=true 时才跑生成器
## （那是编辑模式里「随机铺一版」的重掷工具，不是默认地面）。
func _build_ground(host: Node2D) -> String:
	if not bool(Config.get_value("base.terrain.enabled", false)):
		return _build_custom_ground(host)

	var ov := _terrain_overrides()
	for k in ov:
		Config.set_override(k, ov[k])
	seed(_terrain_seed())
	var res: Dictionary = MapGenerator.generate()
	for k in ov:
		Config.clear_override(k)

	var node: Node = res.get("node")
	if node == null:
		push_warning("[Base] 地形生成没返回节点，回落到玩家自定义地面")
		return _build_custom_ground(host)
	# 不叫 MapRoot：局内那张地图的根节点就叫 MapRoot，两个同名会让
	# 「基地节点有没有跟进关卡」这类排查看花眼。BaseMapRoot 才是探针认的基地标志，
	# 地面挂在它下面，跟着它一起被 _clear_game_root() 释放。
	node.name = "BaseTerrain"
	host.add_child(node)
	return "生成器（种子 %d）" % _terrain_seed()


## 玩家自定义地面：稀疏格子表 → 一层瓦片。空表就是整片草地，所以旧的"整片铺同一种
## 草"分支不需要再单独留一份代码。摆件**不在这里画**，见 _build_custom_props()。
func _build_custom_ground(host: Node2D) -> String:
	var c: Dictionary = Meta.base_custom
	host.add_child(BaseCustomization.build_ground_layer(c, _size, _tile))
	_props_host = host
	return "自定义（地面 %d / 水 %d / 摆件 %d 格）" % [
		(c.get("ground", {}) as Dictionary).size(),
		(c.get("water", {}) as Dictionary).size(),
		(c.get("props", {}) as Dictionary).size()]


## 摆件层延后到建筑摆完之后再画：建筑占地里的格子一律不画树/石（刚才随机版最丑的就是
## 一丛树直接穿过出发大门）。走生成器那条路时 _props_host 是 null —— 装饰已经在那一坨
## 节点里了，不再叠第二层。
func _build_custom_props() -> void:
	if _props_host == null:
		return
	_props_host.add_child(BaseCustomization.build_props_layer(
			Meta.base_custom, _size, _tile, _building_cells_set()))
	_props_host = null


## 所有建筑的占地格子（每栋 footprint×footprint），键同 base_customization 的 "x,y"
func _building_cells_set() -> Dictionary:
	var occ := {}
	for id in _cells.keys():
		var c: Vector2i = _cells[id]
		for dy in range(_footprint):
			for dx in range(_footprint):
				occ[BaseCustomization.key_of(c.x + dx, c.y + dy)] = true
	return occ


## 基地地形 → 生成器实际读的 map.* 路径。generate() 只认 map.*，所以基地这套参数只能
## 以「临时覆盖」喂进去，而不是给基地另写一套生成器。
## ⚠ 覆盖是**进程级全局**的（Config._overrides）：设 → 生成 → 清三步必须待在同一个
##   同步函数体里。generate() 全程不 await，中间插不进别的代码；哪天给它加了 await、
##   或有人在 clear 之前 return，覆盖就泄漏到局内地图 —— `_enter_run()` 只重设
##   map.force_seed、不会清这些键，表现为"局内地图突然变成 64×64 的基地地形"。
func _terrain_overrides() -> Dictionary:
	var t: Dictionary = Config.get_value("base.terrain", {})
	var ov := {
		"map.width": _size,
		"map.height": _size,
		"map.biome_noise_frequency": float(t.get("biome_noise_frequency", 0.02)),
		"map.biome_min_region_cells": int(t.get("biome_min_region_cells", 24)),
		"map.decor.density": float(t.get("decor_density", 0.55)),
		# 基地没有可走角色（DESIGN §2.4「纯布景」），树/石的碰撞体是白给开销
		"map.decor_collision.enabled": false,
	}
	var w: Dictionary = t.get("biome_weights", {})
	for k in w:
		ov["map.biome_weights.%s" % k] = float(w[k])
	return ov


## 每个存档槽一片固定的地：种子按槽号派生，**不写进存档** —— 省一次存档格式迁移，
## 而且"换槽 → 换地形"天然成立。槽 0（命令行直跑 Main.tscn / 无激活槽）拿基准种子，
## 无头回归每次跑出同一张基地，图可复现。base.terrain.seed 非 0 时强制固定（摆构图用）。
func _terrain_seed() -> int:
	var forced := int(Config.get_value("base.terrain.seed", 0))
	if forced != 0:
		return forced
	return TERRAIN_SEED_BASE + maxi(0, int(SaveSlots.active_slot)) * 7919


func _on_building_interacted(building_id: String) -> void:
	if _entered.has(building_id):
		return
	_entered[building_id] = true
	building_interacted.emit(building_id)


func _on_reposition_requested(building_id: String) -> void:
	reposition_requested.emit(building_id)


## 交互处理完毕后由 main 重置（允许下一次交互）
func reset_interaction(building_id: String) -> void:
	_entered.erase(building_id)


# ------------------------------------------------------------
# 重摆（配合 PlacementMode）
# ------------------------------------------------------------

## 除 except_id 外其它建筑占用的格子集合（Vector2i -> true）
func _occupied_cells(except_id: String) -> Dictionary:
	var occ := {}
	for id in _cells.keys():
		if id == except_id:
			continue
		var c: Vector2i = _cells[id]
		for dy in range(_footprint):
			for dx in range(_footprint):
				occ[c + Vector2i(dx, dy)] = true
	return occ


## 该建筑可放置的所有左上角锚点：留 1 格外圈墙、且 footprint 不与其它建筑重叠
func compute_anchors(except_id: String) -> Array:
	var occ := _occupied_cells(except_id)
	var out: Array = []
	for y in range(1, _size - _footprint):
		for x in range(1, _size - _footprint):
			var ok := true
			for dy in range(_footprint):
				for dx in range(_footprint):
					if occ.has(Vector2i(x + dx, y + dy)):
						ok = false
						break
				if not ok:
					break
			if ok:
				out.append(Vector2i(x, y))
	return out


## 开始重摆某建筑：藏起本体（幽灵接管），返回 {footprint, anchors, texture}
func begin_reposition(id: String) -> Dictionary:
	if not _buildings.has(id):
		return {}
	var bld: Node2D = _buildings[id]
	bld.visible = false
	var tex: Texture2D = null
	var body := bld.get_node_or_null("Body") as Sprite2D
	if body != null:
		tex = body.texture
	return {
		"footprint": Vector2i(_footprint, _footprint),
		"anchors": compute_anchors(id),
		"texture": tex,
	}


## 落位：更新节点位置 + 记录 + 写存档槽
func apply_reposition(id: String, anchor: Vector2i) -> void:
	if not _buildings.has(id):
		return
	var bld: Node2D = _buildings[id]
	bld.set_cell(anchor)
	bld.visible = true
	_cells[id] = anchor
	Meta.set_building_cell(id, anchor)


## 取消重摆：把本体显示回来（位置不变）
func cancel_reposition(id: String) -> void:
	if _buildings.has(id):
		(_buildings[id] as Node2D).visible = true

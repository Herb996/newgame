extends Node
## ============================================================
## BaseSystem — 局外基地（挂在 Main 下）
## 固定平地地图（base.map_size=64x64，外圈 1 格墙防走出），
## 建筑按 config 的 base.buildings 布局摆放（每栋 building_cells×building_cells 格），
## 但**每个存档槽可有自己的建筑位置**（Meta.base_layout 覆盖 config 默认）。
##
## 交互：
##   · 左键点建筑 → building_interacted(id) → main 路由（仓库/升级/大门）
##   · 右键点建筑 → reposition_requested(id) → main 启动 PlacementMode 重摆
##   · 重摆落位 → apply_reposition(id, 左上角格) → 更新节点 + 写 Meta.base_layout + 存档
## ============================================================

signal building_interacted(building_id: String)
signal reposition_requested(building_id: String)

const BUILDING_SCENE := preload("res://Scenes/Building.tscn")

var _spawn: Vector2 = Vector2.ZERO
var _entered := {}          # 防同一帧重复触发交互
var _buildings: Dictionary = {}   # id -> Building 节点
var _cells: Dictionary = {}       # id -> Vector2i 占地左上角格
var _size := 64
var _tile := 64
var _footprint := 4


## 生成基地（由 main 调用），返回玩家出生点
func setup(root: Node2D) -> Vector2:
	_entered.clear()
	_buildings.clear()
	_cells.clear()
	_tile = int(Config.get_value("map.tile_size", 64))
	_size = int(Config.get_value("base.map_size", 64))
	_footprint = int(Config.get_value("base.building_cells", 4))

	# 整片草地（外圈不再铺墙瓦片 —— 四周边框与内部统一；基地无角色，不需要挡边）
	var floor_col := MapGenerator.blob_offset(true, true, true, true)
	var layer := TileMapLayer.new()
	layer.name = "BaseTileMap"
	layer.tile_set = MapGenerator._build_tileset(_tile)
	for y in range(_size):
		for x in range(_size):
			layer.set_cell(Vector2i(x, y), 0, Vector2i(floor_col, 0))
	var map_root := Node2D.new()
	map_root.name = "BaseMapRoot"
	map_root.add_child(layer)
	root.add_child(map_root)

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

	print("[Base] 基地就绪：%dx%d 平地，建筑 %d 栋，出生点 %s" % [
		_size, _size, cfg_list.size(), _spawn])
	return _spawn


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

extends Node
## ============================================================
## BaseSystem — 局外基地（挂在 Main 下）
## 固定平地地图（base.map_size=64x64，外圈 1 格墙防走出），
## 建筑按 config 的 base.buildings 布局手工摆放（每栋 4x4 格）。
## 建筑交互信号 building_interacted(id) 由 main 路由：
##   warehouse → 仓库面板；statue → 升级面板；gate → 进局
## ============================================================

signal building_interacted(building_id: String)

const BUILDING_SCENE := preload("res://Scenes/Building.tscn")

var _spawn: Vector2 = Vector2.ZERO
var _entered := {}  # 防同一帧重复触发


## 生成基地（由 main 调用），返回玩家出生点
func setup(root: Node2D) -> Vector2:
	_entered.clear()
	var tile_size: int = int(Config.get_value("map.tile_size", 16))
	var size: int = int(Config.get_value("base.map_size", 64))

	# 平地 + 外圈墙（复用局内瓦片集：地板/墙样式一致）
	var layer := TileMapLayer.new()
	layer.name = "BaseTileMap"
	layer.tile_set = MapGenerator._build_tileset(tile_size)
	for y in range(size):
		for x in range(size):
			var is_wall: bool = x == 0 or y == 0 or x == size - 1 or y == size - 1
			layer.set_cell(Vector2i(x, y), 0, Vector2i(1 if is_wall else 0, 0))
	var map_root := Node2D.new()
	map_root.name = "BaseMapRoot"
	map_root.add_child(layer)
	root.add_child(map_root)

	# 玩家出生点
	var spawn_cell_cfg: Array = Config.get_value("base.player_spawn_cell", [32, 32])
	var spawn_cell := Vector2i(int(spawn_cell_cfg[0]), int(spawn_cell_cfg[1]))
	_spawn = Vector2(spawn_cell) * tile_size + Vector2(tile_size * 0.5, tile_size * 0.5)

	# 建筑布局（cell = 建筑 4x4 的左上角格）
	for b in Config.get_value("base.buildings", []):
		var bld := BUILDING_SCENE.instantiate()
		var cell: Array = b["cell"]
		# 建筑中心 = 左上角 + 2 格（4x4 的一半）
		bld.position = Vector2(cell[0] + 2, cell[1] + 2) * tile_size
		bld.setup(str(b["id"]), str(b["name"]), str(b.get("hint", "按 E")))
		bld.interacted.connect(_on_building_interacted)
		root.add_child(bld)

	print("[Base] 基地就绪：%dx%d 平地，建筑 %d 栋（仓库/雕像/大门），出生点 %s" % [
		size, size, Config.get_value("base.buildings", []).size(), _spawn])
	return _spawn


func _on_building_interacted(building_id: String) -> void:
	# 同一帧多栋建筑同时触发时只处理一次（大门优先）
	if _entered.has(building_id):
		return
	_entered[building_id] = true
	building_interacted.emit(building_id)


## 交互处理完毕后由 main 重置（允许下一次交互）
func reset_interaction(building_id: String) -> void:
	_entered.erase(building_id)

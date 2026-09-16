extends Node
## ============================================================
## FogSystem — 战争迷雾 + 敌人显隐（挂在 Main 下）
## 规则（Data/config.json）：
##   player.vision_radius_cells：视野半径 10 格
##   - 未探索区域：黑色遮罩（雾层瓦片覆盖全图，z_index 最高）
##   - 已探索区域：永久揭开（瓦片移除，记忆保留）
##   - 敌人：只在玩家当前视野半径内显示，视野外一律隐藏
##     （即使所在区域已被探索过）
## ============================================================

var fog_layer: TileMapLayer
var tile_size := 16
var map_w := 0
var map_h := 0
var radius_cells := 10
var vision_px := 160.0
var _explored: Dictionary = {}
var _player: Node2D
var _active := false  # 仅局内激活（基地无雾）


## 由 main.gd 在地图生成后调用（玩家出生后再调用，避免第一帧闪现）
func setup(root: Node2D, map_data: Dictionary) -> void:
	_active = true
	_explored.clear()
	_player = null
	tile_size = int(map_data["tile_size"])
	var walls: Array = map_data["walls"]
	map_w = walls[0].size()
	map_h = walls.size()
	radius_cells = int(Config.get_value("player.vision_radius_cells", 10))
	vision_px = float(radius_cells * tile_size)

	fog_layer = TileMapLayer.new()
	fog_layer.name = "FogLayer"
	fog_layer.tile_set = _build_fog_tileset(tile_size)
	fog_layer.z_index = 5  # 盖住地图、敌人、撤离点，玩家在其内已揭开
	for y in range(map_h):
		for x in range(map_w):
			fog_layer.set_cell(Vector2i(x, y), 0, Vector2i(0, 0))
	root.add_child(fog_layer)


## 由 main.gd 离开局内时调用
func deactivate() -> void:
	_active = false


## 调试/出图用：连遮罩层一起拆掉。
## deactivate() 只是停掉逻辑，黑色雾瓦片还压在地图上（z_index=5），
## 想看清地图本体（截图、比对贴图）必须用这个。
func disable() -> void:
	deactivate()
	if fog_layer != null and is_instance_valid(fog_layer):
		fog_layer.queue_free()
	fog_layer = null


func _process(_delta: float) -> void:
	if not _active or fog_layer == null:
		return
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")
		if _player == null:
			return
	_reveal_around(_player.position)
	_update_enemy_visibility(_player.position)


## 揭开玩家周围的圆形区域（已揭开的跳过，探索记忆永久保留）
func _reveal_around(pos: Vector2) -> void:
	var pc := Vector2i(floori(pos.x / tile_size), floori(pos.y / tile_size))
	var r := radius_cells
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r:
				continue
			var c := pc + Vector2i(dx, dy)
			if c.x < 0 or c.y < 0 or c.x >= map_w or c.y >= map_h:
				continue
			if not _explored.has(c):
				_explored[c] = true
				fog_layer.set_cell(c, -1)  # -1 = 移除瓦片


## 实体显隐白名单：视野半径内可见，视野外隐藏（不看探索记忆）。
## 用数组而不是三段重复代码——以后再加一类场上实体（比如中立商队）只需往这里加组名。
const VISION_GROUPS := ["enemies", "animals", "loot_nodes"]


func _update_enemy_visibility(player_pos: Vector2) -> void:
	for g in VISION_GROUPS:
		for n in get_tree().get_nodes_in_group(g):
			n.visible = n.position.distance_to(player_pos) <= vision_px


## 黑色不透明遮罩瓦片集（1 格）
static func _build_fog_tileset(tile_size: int) -> TileSet:
	var img := Image.create(tile_size, tile_size, false, Image.FORMAT_RGB8)
	img.fill(Color(0, 0, 0))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(tile_size, tile_size)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.create_tile(Vector2i(0, 0))
	ts.add_source(src, 0)
	return ts

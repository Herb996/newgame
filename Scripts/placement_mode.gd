extends Node2D
## ============================================================
## PlacementMode — 可复用的「网格放置模式」
##
## 铺出瓦片网格、把可放置区标绿、半透明幽灵跟随光标、点格子落位。
## 基地用它移动建筑；之后进图放东西也复用同一套。
##
## 用法：
##   var p := PlacementMode.new(); add_child(p)
##   p.placed.connect(...); p.cancelled.connect(...)
##   p.begin(map_cells, tile, footprint, valid_anchors, ghost_texture)
##   # 玩家左键点合法锚点 → placed(anchor 左上角格)；右键/ESC → cancelled
##
## 约定：本节点挂在世界原点（game_root 下），坐标 = 格 × tile，与基地/地图瓦片同系。
## 激活期间把自己加入组 "placement_active"，让建筑等控件让位（不响应普通点击）。
## ============================================================

signal placed(anchor: Vector2i)
signal cancelled

var _tile := 64
var _footprint := Vector2i(4, 4)
var _map_cells := Vector2i(64, 64)
var _anchors: Dictionary = {}     # 合法左上角锚点 Vector2i -> true
var _cover: Dictionary = {}       # 被任一合法放置覆盖的格子（画绿）Vector2i -> true
var _ghost_tex: Texture2D = null
var _hover := Vector2i(0, 0)
var _hover_ok := false
var _active := false

var grid_color := Color(1, 1, 1, 0.10)
var cover_color := Color(0.30, 0.85, 0.35, 0.20)
var ghost_ok_color := Color(0.30, 0.90, 0.40, 0.35)
var ghost_bad_color := Color(0.90, 0.30, 0.30, 0.35)


func begin(map_cells: Vector2i, tile: int, footprint: Vector2i,
		valid_anchors: Array, ghost_tex: Texture2D) -> void:
	_map_cells = map_cells
	_tile = tile
	_footprint = footprint
	_ghost_tex = ghost_tex
	_anchors.clear()
	_cover.clear()
	for a in valid_anchors:
		var ac: Vector2i = a
		_anchors[ac] = true
		for dy in range(footprint.y):
			for dx in range(footprint.x):
				_cover[ac + Vector2i(dx, dy)] = true
	z_index = 40
	visible = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	_active = true
	add_to_group("placement_active")
	_refresh_hover()


func end() -> void:
	_active = false
	visible = false
	if is_inside_tree():
		remove_from_group("placement_active")


func _world_to_cell(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / _tile), floori(pos.y / _tile))


func _hover_anchor() -> Vector2i:
	var c := _world_to_cell(get_global_mouse_position())
	c.x = clampi(c.x, 0, maxi(0, _map_cells.x - _footprint.x))
	c.y = clampi(c.y, 0, maxi(0, _map_cells.y - _footprint.y))
	return c


func _refresh_hover() -> void:
	_hover = _hover_anchor()
	_hover_ok = _anchors.has(_hover)
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseMotion:
		_refresh_hover()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_refresh_hover()
			if _hover_ok:
				placed.emit(_hover)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			cancelled.emit()
			get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		cancelled.emit()
		get_viewport().set_input_as_handled()


func _draw() -> void:
	if not _active:
		return
	var w := _map_cells.x * _tile
	var h := _map_cells.y * _tile
	# 瓦片网格线（把格子展示出来）
	for x in range(_map_cells.x + 1):
		draw_line(Vector2(x * _tile, 0), Vector2(x * _tile, h), grid_color, 1.0)
	for y in range(_map_cells.y + 1):
		draw_line(Vector2(0, y * _tile), Vector2(w, y * _tile), grid_color, 1.0)
	# 可放置覆盖格（绿）
	for cell in _cover.keys():
		var c: Vector2i = cell
		draw_rect(Rect2(c.x * _tile, c.y * _tile, _tile, _tile), cover_color, true)
	# 幽灵 footprint
	if _hover.x >= 0:
		var col: Color = ghost_ok_color if _hover_ok else ghost_bad_color
		var rect := Rect2(_hover.x * _tile, _hover.y * _tile,
				_footprint.x * _tile, _footprint.y * _tile)
		draw_rect(rect, col, true)
		draw_rect(rect, col.lightened(0.35), false, 2.0)
		if _ghost_tex != null:
			var ts := _ghost_tex.get_size()
			if ts.x > 0.0 and ts.y > 0.0:
				var k := minf(_footprint.x * _tile / ts.x, _footprint.y * _tile * 1.4 / ts.y)
				var sz := ts * k
				var foot_bottom := Vector2((_hover.x + _footprint.x * 0.5) * _tile,
						(_hover.y + _footprint.y) * _tile)
				var dst := Rect2(foot_bottom.x - sz.x * 0.5, foot_bottom.y - sz.y, sz.x, sz.y)
				draw_texture_rect(_ghost_tex, dst, false, Color(1, 1, 1, 0.5))

extends CanvasLayer
## ============================================================
## Minimap — 左上角小地图（挂在 Main 下，组: minimap）
## 按比例缩放呈现整张大地图（地形纹理一次性预生成）。
## 显示内容：玩家（绿点，实时位置）、撤离点（白点），
## 即将关闭的撤离点额外套警示橙圈闪烁。
## 显示时机（由 extraction_system 触发）：
##   - 撤离点开启时弹出，显示 duration_seconds（60 秒）
##   - 每个撤离点关闭前 warn_before_close_seconds（60 秒）再弹出
## 数值全部来自 Data/config.json 的 extraction.minimap 节点。
## ============================================================

var _panel: Control
var _terrain_tex: ImageTexture
var _map_px := Vector2.ZERO
var _size_px := 220.0
var _show_remaining := 0.0
var _closing_point: Node2D = null
var _blink_t := 0.0


## 绘制代理：CanvasLayer 不能自绘，用内部 Control 转发 _draw
class DrawPanel extends Control:
	var mm: CanvasLayer
	func _init(m: CanvasLayer) -> void:
		mm = m
	func _draw() -> void:
		if mm != null:
			mm._render(self)


func _ready() -> void:
	add_to_group("minimap")
	_size_px = float(Config.get_value("extraction.minimap.size_px", 220))
	_panel = DrawPanel.new(self)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_panel.offset_left = 10.0
	_panel.offset_top = 10.0
	_panel.size = Vector2(_size_px, _size_px)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	visible = false


## 由 main.gd 在地图生成后调用，预生成按比例缩放的地形纹理
func setup(map_data: Dictionary) -> void:
	var walls: Array = map_data["walls"]
	var w: int = walls[0].size()
	var h: int = walls.size()
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	img.fill(Color(0.23, 0.18, 0.14))  # 地板：暗棕
	for y in range(h):
		for x in range(w):
			if walls[y][x]:
				img.set_pixel(x, y, Color(0.45, 0.30, 0.16))  # 墙：暗铜锈
	_terrain_tex = ImageTexture.create_from_image(img)
	_map_px = Vector2(w, h) * float(map_data["tile_size"])


## 弹出显示 duration 秒；closing_point 非 null 时该点套橙色警示圈
func show_for(duration: float, closing_point: Node2D = null) -> void:
	_show_remaining = duration
	_closing_point = closing_point
	visible = true
	_panel.queue_redraw()


func _process(delta: float) -> void:
	if not visible:
		return
	_blink_t += delta
	_show_remaining -= delta
	if _show_remaining <= 0.0:
		visible = false
		return
	_panel.queue_redraw()  # 玩家绿点实时移动，每帧重绘


## 实际绘制（由 DrawPanel._draw 调用）
func _render(panel: Control) -> void:
	if _terrain_tex == null:
		return
	# 地形（整图缩放到小地图尺寸）+ 边框
	panel.draw_texture_rect(_terrain_tex, Rect2(Vector2.ZERO, panel.size), false)
	panel.draw_rect(Rect2(Vector2.ZERO, panel.size), Color(0.55, 0.33, 0.16), false, 2.0)

	var scale := panel.size / _map_px

	# 撤离点：白点；即将关闭的点：警示橙圈闪烁
	for p in get_tree().get_nodes_in_group("extraction_points"):
		if not p.is_open:
			continue
		var pos: Vector2 = p.position * scale
		panel.draw_circle(pos, 4.0, Color(0.91, 0.90, 0.86))
		if p == _closing_point:
			var blink: float = 0.5 + 0.5 * sin(_blink_t * 8.0)
			panel.draw_arc(pos, 8.0, 0.0, TAU, 32,
				Color(1.0, 0.55, 0.15, 0.4 + 0.6 * blink), 2.0)

	# 小队成员：每人一个绿点（蒸汽白描边保证暗色背景可辨）
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		var pos: Vector2 = p.position * scale
		panel.draw_circle(pos, 5.0, Color(0.2, 0.85, 0.35))
		panel.draw_arc(pos, 5.0, 0.0, TAU, 32, Color(0.91, 0.90, 0.86), 1.5)

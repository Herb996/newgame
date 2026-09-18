extends CanvasLayer
## ============================================================
## Minimap — 小地图（两种模式，同一份绘制代码）
##
## 【embed 模式】局内菜单栏左侧的常驻槽（2026-09-17 起的主用法）：
##   menu_bar.gd 调 set_embed_mode(true) + set_slot_rect(rect) 把面板钉进栏内左槽，
##   开局就有、全程可见；**点它 = 把大世界镜头平移到对应的世界坐标**（RTS 式导航，
##   换算好世界坐标后经 map_clicked 交给 menu_bar，由它移镜头）。给单位下令/指定攻击/
##   巡逻设点改走「点大世界地图」（player.gd 世界左键 → command_click）。
##
## 【legacy 模式】独立弹出（3D 线 Scenes/Main3D.tscn 仍在用）：
##   撤离点开启 / 关闭前预警时弹出 duration_seconds，见 show_for()。
##   Main3D 不调 set_embed_mode，因此行为与改造前一字不差（它的自检依赖这个）。
##
## 画什么（**绘制顺序就是分层，动顺序前先读这里**，2026-09-17 起）：
##   1. 地形底图（地板=暗棕、墙=暗铜锈），按本地图一次性预生成
##   2. 资源点（树→木、石→石、矿脉）—— 生成后**烘焙进底图**，运行时零开销
##   3. 撤离点（白点）+ 即将关闭的那个（橙色闪烁圈）
##   4. **迷雾层**——未探索区纯黑，纹理与主地图同源，见 set_fog_texture()
##   5. 小队成员（绿点，实时位置，蒸汽白描边保证暗底可辨）
##
## 迷雾插在 3 与 5 之间 = 「未探索处的撤离点自动被盖住，自己人永远看得见」。
## 这一条**靠叠放顺序实现，不查任何探索状态**：资源点已烘焙进底图，天然被第 4 层盖住；
## 撤离点画在雾下面，未探索处自然看不见。所以别把 _draw_fog 提到前面，
## 也别把 _draw_squad 放到它前面 —— 那两种改法都会让迷雾形同虚设。
##
## 数值来自 Data/config.json 的 extraction.minimap 与 menu_bar.minimap。
## ============================================================

signal map_clicked(world_pos: Vector2)

var _panel: Control
var _terrain_tex: ImageTexture
var _map_px := Vector2.ZERO
var _size_px := 220.0
var _show_remaining := 0.0       # legacy 模式：还剩多少秒后自动隐藏
var _embed := false              # embed 模式：常驻 + 可点击
var _blink_t := 0.0
var _warn_remaining := 0.0       # 关闭预警高亮剩余秒数（两模式共用）
var _closing_point: Node2D = null
var _fog_tex: ImageTexture = null   # 迷雾层：与主地图同一张探索遮罩（未探索处 a=1）

## 绘制层顺序 —— **唯一真相源**，_render() 就按这个数组依次分派。
## 为什么写成数据而不是直接顺序调用：顺序写错不会报任何错，只会让迷雾形同虚设
## （雾提到撤离点前面 → 未探索处的撤离点照样亮着），肉眼极难发现。
## 写成数组后探针能直接断言「fog 必须夹在 extraction 与 squad 之间」。
## 动这个数组 = 动画面分层，先回去读文件头那段说明。
const RENDER_LAYERS := ["terrain", "extraction", "fog", "squad"]


## 绘制代理：CanvasLayer 不能自绘，用内部 Control 转发 _draw；
## gui_input 也在这里转发到 _on_panel_input（embed 模式下接点击）。
class DrawPanel extends Control:
	var mm: CanvasLayer
	func _init(m: CanvasLayer) -> void:
		mm = m
	func _draw() -> void:
		if mm != null:
			mm._render(self)
	func _gui_input(event: InputEvent) -> void:
		if mm != null:
			mm._on_panel_input(event, self)


func _ready() -> void:
	add_to_group("minimap")
	_size_px = float(Config.get_value("extraction.minimap.size_px", 220))
	_panel = DrawPanel.new(self)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_panel.offset_left = 10.0
	_panel.offset_top = 10.0
	_panel.size = Vector2(_size_px, _size_px)
	# 默认 IGNORE：legacy 模式下小地图不该挡住点击、也不该挡住边缘滚屏
	# （camera_controller.gd 的 edge_pan_ignore_ui 会看 gui_get_hovered_control）。
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 底图是「一格 = 一个像素」的像素画：用最近邻放大才看得出墙/地边界，
	# 线性过滤会把它糊成一片棕。资源点也是靠这个才点得出来。
	_panel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_panel)
	visible = false


## 切到「菜单栏常驻」模式：不再自动弹/收，改为固定槽位 + 可点击下令。
func set_embed_mode(on: bool) -> void:
	_embed = on
	if on:
		_panel.mouse_filter = Control.MOUSE_FILTER_STOP
		visible = true


## 由 menu_bar 在布局变化时调用：把面板钉在指定的视口矩形里（正方形槽）。
func set_slot_rect(rect: Rect2) -> void:
	if _panel == null:
		return
	_size_px = maxf(rect.size.x, rect.size.y)
	_panel.position = rect.position
	_panel.size = rect.size
	_panel.queue_redraw()


## 由 main.gd 在地图生成后调用：预生成按比例缩放的地形纹理（含资源点烘焙）
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
	_bake_resources(img, int(map_data.get("tile_size", 64)))
	_terrain_tex = ImageTexture.create_from_image(img)
	_map_px = Vector2(w, h) * float(map_data["tile_size"])
	_warn_remaining = 0.0
	_closing_point = null
	_panel.queue_redraw()


## 由 main.gd 在生成地图后调用：挂上本局的探索遮罩（fog_system.minimap_fog_texture）。
## 传 null = 本局不叠雾（基地 / --no-fog / Main3D 线），行为与改造前一致。
## **换局必须重挂**：fog_system.setup 每局新建一张遮罩，留着旧引用就是上一局的数据。
func set_fog_texture(tex: ImageTexture) -> void:
	_fog_tex = tex
	if _panel != null:
		_panel.queue_redraw()


func fog_texture() -> ImageTexture:
	return _fog_tex


## 把资源点画进底图（树/石/矿脉各一个像素点，按类型配色）。
## 为什么烘焙而不是每帧画：资源点是静态的（几百个），每帧 draw_circle 是纯浪费；
## 烘焙只在进局时跑一次，之后运行时开销为 0。
## 取色规则：menu_bar.minimap.resource_colors（缺配色的类型跳过，不画错颜色）。
func _bake_resources(img: Image, tile_size: int) -> void:
	if not bool(Config.get_value("menu_bar.minimap.show_resources", true)):
		return
	var colors = Config.get_value("menu_bar.minimap.resource_colors", {})
	if not (colors is Dictionary):
		return
	var w := img.get_width()
	var h := img.get_height()
	for node in ResourceRegistry.get_all():
		var res_id: String = str(node.res_id)
		if not (colors as Dictionary).has(res_id):
			continue
		var gx := int(node.world_pos.x / float(tile_size))
		var gy := int(node.world_pos.y / float(tile_size))
		if gx < 0 or gy < 0 or gx >= w or gy >= h:
			continue
		var c := Color(str((colors as Dictionary)[res_id]))
		c.a = 1.0
		img.set_pixel(gx, gy, c)


## 弹出显示 duration 秒；closing_point 非 null 时该点套橙色警示圈。
## embed 模式下不隐藏面板（常驻），只把「关闭预警」高亮跑 duration 秒。
func show_for(duration: float, closing_point: Node2D = null) -> void:
	_warn_remaining = duration
	_closing_point = closing_point
	_show_remaining = duration
	if not _embed:
		visible = true
	_panel.queue_redraw()


func _process(delta: float) -> void:
	if not visible:
		return
	_blink_t += delta
	if _warn_remaining > 0.0:
		_warn_remaining -= delta
	# legacy 模式：到点自动收起（embed 模式面板常驻，不参与这段）
	if not _embed:
		_show_remaining -= delta
		if _show_remaining <= 0.0:
			visible = false
			return
	_panel.queue_redraw()  # 玩家绿点实时移动，每帧重绘


## 小地图点击（embed 模式）：本地点 → 世界坐标，抛给 menu_bar 转成单位指令。
func _on_panel_input(event: InputEvent, panel: Control) -> void:
	if not _embed:
		return
	if not (event is InputEventMouseButton and event.pressed):
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	panel.accept_event()
	map_clicked.emit(world_pos_at(event.position))


## 面板本地坐标 → 世界坐标（供点击换算；也是探针可直接断言的纯函数）
func world_pos_at(local: Vector2) -> Vector2:
	if _map_px.x <= 0.0 or _map_px.y <= 0.0 or _panel.size.x <= 0.0 or _panel.size.y <= 0.0:
		return Vector2.ZERO
	return Vector2(local.x * _map_px.x / _panel.size.x,
			local.y * _map_px.y / _panel.size.y)


## 实际绘制（由 DrawPanel._draw 调用）。按 RENDER_LAYERS 依次分派 —— 顺序即语义。
func _render(panel: Control) -> void:
	if _terrain_tex == null:
		return
	for layer in RENDER_LAYERS:
		match layer:
			"terrain":
				_draw_terrain(panel)
			"extraction":
				_draw_extraction(panel)
			"fog":
				_draw_fog(panel)
			"squad":
				_draw_squad(panel)
			_:
				push_warning("[Minimap] RENDER_LAYERS 里有未知层：%s" % layer)


## 层 1~2：地形底图（整图缩放到小地图尺寸，资源点已烘焙在其中）+ 边框
func _draw_terrain(panel: Control) -> void:
	panel.draw_texture_rect(_terrain_tex, Rect2(Vector2.ZERO, panel.size), false)
	var border := Color(0.55, 0.33, 0.16)
	if _warn_remaining > 0.0:
		# 撤离点有变动（开启 / 即将关闭）时，整块小地图描边闪烁提醒
		var b := 0.5 + 0.5 * sin(_blink_t * 8.0)
		border = border.lerp(Color(1.0, 0.6, 0.15), b)
	panel.draw_rect(Rect2(Vector2.ZERO, panel.size), border, false, 2.0)


## 层 3：撤离点：白点；即将关闭的点：警示橙圈闪烁。
## 画在雾**之下** —— 未探索处的撤离点会被下一层盖掉，与主地图一致（那里 z=0 < 雾 z=5）。
func _draw_extraction(panel: Control) -> void:
	var scale := _scale_of(panel)
	for p in get_tree().get_nodes_in_group("extraction_points"):
		if not p.is_open:
			continue
		var pos: Vector2 = p.position * scale
		panel.draw_circle(pos, 4.0, Color(0.91, 0.90, 0.86))
		if p == _closing_point and _warn_remaining > 0.0:
			var blink: float = 0.5 + 0.5 * sin(_blink_t * 8.0)
			panel.draw_arc(pos, 8.0, 0.0, TAU, 32,
				Color(1.0, 0.55, 0.15, 0.4 + 0.6 * blink), 2.0)


## 层 4：迷雾 —— 与主地图同一张探索遮罩，逐格对齐直接缩放铺满。
## 未探索处 a=1 纯黑（盖住地形/资源点/撤离点），已探索处 a=0 全透。
## 这里不做羽化：小地图 1 格≈1.7px，硬边比模糊更利落，也和像素风底图一致。
## 没有迷雾时（基地 / --no-fog / Main3D 线）_fog_tex 为 null，整层跳过。
func _draw_fog(panel: Control) -> void:
	if _fog_tex == null:
		return
	panel.draw_texture_rect(_fog_tex, Rect2(Vector2.ZERO, panel.size), false)


## 层 5：小队成员，每人一个绿点（蒸汽白描边保证暗色背景可辨）。
## 画在雾**之上**：自己人在哪儿永远看得见，哪怕站在没探索过的黑区里。
func _draw_squad(panel: Control) -> void:
	var scale := _scale_of(panel)
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		var pos: Vector2 = p.position * scale
		panel.draw_circle(pos, 5.0, Color(0.2, 0.85, 0.35))
		panel.draw_arc(pos, 5.0, 0.0, TAU, 32, Color(0.91, 0.90, 0.86), 1.5)


## 世界坐标 → 面板像素的比例（地形与雾同尺寸，共用这一个比例才不会错位）
func _scale_of(panel: Control) -> Vector2:
	if _map_px.x <= 0.0 or _map_px.y <= 0.0:
		return Vector2.ZERO
	return panel.size / _map_px

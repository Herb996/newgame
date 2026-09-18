extends Control
## ============================================================
## SelectionController — 局内鼠标「选择 / 框选 / 下令」的统一入口
##
## 为什么要有它：左键既要「选中/框选单位」又要「点空地下令」，还得区分
## 「点击」和「按住拖动」—— 若在 Player._unhandled_input 里按键就立刻下令，
## 拖框选人的起手那一下会被误判成「移动到起点」。所以把空地左键集中到这里：
##   · 按下不做事，只记起点；
##   · 拖动超过阈值 → 进入框选，画选框；
##   · 松开：拖过 = 框选矩形内所有单位（多选）；没拖 = 空地点击，
##     把这道指令同时下达给「当前所有选中单位」（移动/指定按各自 arm_mode）。
##
## 点「单位本体」仍由各 Player 的 SelectArea 负责（排他单选）：Area2D 拾取会吃掉
## 那一下左键，事件不会到这里，所以两条路天然不打架 —— 也意味着框选要从空地起手
## （从单位身上起手会被 SelectArea 先消费，退化成单选，符合常见手感）。
##
## 全屏 Control + mouse_filter=IGNORE：不吃 GUI 点击（面板/小地图/按钮各自 STOP
## 消费，事件根本不进 _unhandled_input），只在没人消费的左键上做文章。
## 挂在 HUD(CanvasLayer) 下，坐标系即视口屏幕坐标；世界↔屏幕用相机画布变换换算，
## 于是缩放/平移都自动跟手。数值来自 Data/config.json 的 player.*。
## ============================================================

const GROUP := &"selection"

var _cam: Camera2D = null
var _threshold := 6.0                 # 超过该屏幕像素位移算「拖框」而非「点击」

var _pressing := false
var _dragging := false
var _start := Vector2.ZERO            # 按下时的屏幕坐标（画框 + 判位移）
var _cur := Vector2.ZERO              # 当前屏幕坐标

## 拖框配色（config player.box_select_*，缺省用一抹半透明绿）
var _line_color := Color(0.6, 0.9, 0.6, 0.9)
var _fill_color := Color(0.6, 0.9, 0.6, 0.14)


func _ready() -> void:
	add_to_group(GROUP)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_threshold = float(Config.get_value("player.box_select_threshold_px", 6.0))
	_line_color = Color(str(Config.get_value("player.box_select_line_color", "#99E699")))
	_fill_color = _line_color
	_fill_color.a = float(Config.get_value("player.box_select_fill_alpha", 0.14))


## main.gd 进局时把当前生效的相机交进来（世界↔屏幕换算要用到画布变换）。
func setup(cam: Camera2D) -> void:
	_cam = cam


func _unhandled_input(event: InputEvent) -> void:
	if _cam == null or get_tree().paused:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressing = true
			_dragging = false
			_start = event.position
			_cur = event.position
		elif _pressing:
			_pressing = false
			if _dragging:
				_box_select(_screen_rect(_start, event.position))
			else:
				_command_at_world(_world_of(event.position))
			_dragging = false
			queue_redraw()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and _pressing:
		_cur = event.position
		if not _dragging and _cur.distance_to(_start) > _threshold:
			_dragging = true
		if _dragging:
			queue_redraw()
			get_viewport().set_input_as_handled()


# ------------------------------------------------------------
# 三种动作
# ------------------------------------------------------------

## 空地点击（没拖框）：把这条指令下达给所有选中单位。
## command_click 内部按各单位的 arm_mode 分派（移动 / 指定攻击 / 巡逻设点）。
func _command_at_world(world_pos: Vector2) -> void:
	for p in _selected():
		p.command_click(world_pos)


## 松开拖框：框内单位成为新的选择集（清掉框外的）。框内无人 = 清空选择。
func _box_select(rect: Rect2) -> void:
	var picked: Array = []
	for p in _alive_players():
		if rect.has_point(_screen_of(p.global_position)):
			picked.append(p)
	for p in _alive_players():
		p.deselect()
	for p in picked:
		p.select_keep_others()


# ------------------------------------------------------------
# 选择集 / 单位查询
# ------------------------------------------------------------

func _alive_players() -> Array:
	var out: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and not bool(p.call("is_dead")):
			out.append(p)
	return out


func _selected() -> Array:
	var out: Array = []
	for p in _alive_players():
		if bool(p.get("selected")):
			out.append(p)
	return out


# ------------------------------------------------------------
# 坐标换算（视口画布变换含相机缩放/平移，故自动跟手）
# ------------------------------------------------------------

func _world_of(screen: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen


func _screen_of(world: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform() * world


## 两角点 → 归一化屏幕矩形。
func _screen_rect(a: Vector2, b: Vector2) -> Rect2:
	return Rect2(minf(a.x, b.x), minf(a.y, b.y), absf(a.x - b.x), absf(a.y - b.y))


func _draw() -> void:
	if not _dragging:
		return
	var r := _screen_rect(_start, _cur)
	draw_rect(r, _fill_color, true)
	draw_rect(r, _line_color, false, 1.5)

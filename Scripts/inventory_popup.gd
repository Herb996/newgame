extends Control
## ============================================================
## InventoryPopup — 右键角色 → 在他头顶弹出「他这一份背包」
##
## 2026-09-19 用户定：背包改成每人一份，右键人物时在他上方弹出，
## 底部菜单栏同步展示同一个角色（"同步"由 menu_bar.gd 读本文件的 unit 实现）。
##
## 只读面板：这里只解决「看清楚谁身上有什么、他缺什么」。
## 要把东西挪走就走一走 —— 拾取归属是"范围内最近的那个活人"（loot_node.gd），
## 阵亡则整包就地撒成一地（player.drop_inventory），没有第四种搬运方式。
##
## 为什么在 _input 里自己判命中，而不是挂到 player 的 SelectArea.input_event：
##   · 右键那一下本来归 Player._unhandled_input 的「右键 = 取消指令」管，
##     两条规则会抢同一次点击；Node._input 跑在所有 _unhandled_input 之前，
##     在这里判完并 set_input_as_handled()，外面的规则根本看不到这一下；
##   · 无头探针没法伪造 Area2D 拾取，却可以直接调 right_click_at()。
##
## 挂在 HUD(CanvasLayer) 下：坐标系即视口屏幕坐标；世界↔屏幕用相机画布变换
## 换算，于是缩放/平移自动跟手（与 selection_controller.gd 同一套路）。
## 位置：头顶 inventory_popup.head_offset_px 世界像素，横向居中，夹在视口内
## 并且不让开底部菜单栏（让位公式与 HUD 同源 UiKit.menu_bar_height）。
## ============================================================

const GROUP := &"inventory_popup"

## 正在看谁的背包；null = 没弹。菜单栏同步读它（有它时优先显示它）。
var unit: Node = null

var _panel: PanelContainer
var _box: VBoxContainer
var _title: Label
var _sub: Label
var _rows: VBoxContainer
var _warn: Label
var _sig := ""              # 上一次画的内容指纹：没变就不重排节点
var _run: Node = null
var _survival: Node = null
## 定位参数 _ready 读一次就够：_follow() 是每帧路径，缺键时 Config 每次查都刷一条警告
var _head_offset := 44.0
var _margin := 8.0
var _min_width := 210.0


func _ready() -> void:
	add_to_group(GROUP)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 全屏垫层本身不吃点击（否则局内点不了地），只有面板本体吃
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_head_offset = float(Config.get_value("inventory_popup.head_offset_px", 44.0))
	_margin = float(Config.get_value("inventory_popup.viewport_margin_px", 8.0))
	_min_width = float(Config.get_value("inventory_popup.min_width_px", 210.0))
	_build()
	visible = false


# ------------------------------------------------------------
# 对外接口（右键逻辑 / 探针都走这几个）
# ------------------------------------------------------------

func is_open() -> bool:
	return unit != null


## 弹出某角色的背包
func open_for(p: Node) -> void:
	if p == null or not is_instance_valid(p):
		return
	if unit != p:
		_sig = ""       # 换人：内容指纹作废，逼下一帧重画一遍
	unit = p
	visible = true
	_refresh_text()
	_follow()


func close_bag() -> void:
	unit = null
	visible = false
	_sig = ""


## 右键一下（screen = 视口屏幕坐标）。返回 true = 这一下被弹窗吃掉，别再往下传。
## 没弹窗时点空地返回 false —— 右键空地的老规矩（取消指令）完全不变。
func right_click_at(screen: Vector2) -> bool:
	var hit := _unit_at(screen)
	if hit != null:
		if hit == unit:
			close_bag()
		else:
			open_for(hit)
		return true
	if unit == null:
		return false
	if _panel.get_global_rect().has_point(screen):
		return true     # 点在自己面板上：既不关也不穿透成取消指令
	close_bag()
	return true


## 面板当前占据的屏幕矩形（探针量位置用）
func panel_rect() -> Rect2:
	return _panel.get_global_rect()


func _input(event: InputEvent) -> void:
	if get_tree().paused:
		return
	if event is InputEventMouseButton and event.pressed:
		# 注意别写 `and not event.echo`：echo 是 InputEventKey 才有的属性，
		# 挂在鼠标分支上每次右键都会抛 "Invalid access to property 'echo'"
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if right_click_at(event.position):
				get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_LEFT and is_open() \
				and _panel.get_global_rect().has_point(event.position):
			get_viewport().set_input_as_handled()   # 面板内部点击不外泄成移动令
			return
	if is_open() and event.is_action_pressed("ui_cancel"):
		close_bag()
		get_viewport().set_input_as_handled()       # ESC 这次只用来收弹窗


func _process(_delta: float) -> void:
	if not is_open():
		return
	# 回基地（HUD 整层隐藏）、本局结束、人阵亡、节点被释放 —— 一律收起
	if not visible or _layer_hidden() or not _run_running() or not _alive(unit):
		close_bag()
		return
	_refresh_text()
	_follow()


# ------------------------------------------------------------
# 内容
# ------------------------------------------------------------

func _build() -> void:
	_panel = PanelContainer.new()
	_panel.name = "Bag"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.075, 0.07, 0.96)
	sb.border_color = Color(0.38, 0.30, 0.19, 1.0)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	sb.set_content_margin_all(9)
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	_box = UiKit.vbox(3)
	# 给个下限宽度：短缺那行开了自动换行，不撑住宽度的话面板会缩成一条竖带
	_box.custom_minimum_size = Vector2(_min_width, 0)
	_panel.add_child(_box)

	_title = UiKit.label("", 15, UiKit.COL_AMBER)
	_box.add_child(_title)
	_sub = UiKit.dim("", 12)
	_box.add_child(_sub)
	_rows = UiKit.vbox(1)
	_box.add_child(_rows)
	_warn = UiKit.warn("", 12)
	_warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# autowrap 的 Label 在容器里按"一个词一行"算最小高度：不给宽度下限，
	# reset_size() 量到的就是撑成一条竖带的面板（实拍抓到 601px 高）
	_warn.custom_minimum_size = Vector2(_min_width, 0)
	_warn.visible = false
	_box.add_child(_warn)


## 内容指纹：换人 / 格数变了 / 物品种类数量变了 / 短缺状态变了 都要重画
func _signature() -> String:
	if unit == null or not is_instance_valid(unit):
		return ""
	var parts: Array = []
	for res_id in unit.inventory.keys():
		parts.append("%s=%d" % [str(res_id), int(unit.inventory[res_id])])
	parts.sort()
	return "%d|%d|%s|%s" % [unit.get_instance_id(), unit.backpack_capacity(),
			",".join(parts), _shortage_line(unit)]


func _refresh_text() -> void:
	var sig := _signature()
	if sig == _sig:
		return
	_sig = sig
	_title.text = "%s 的背包" % _name(unit)
	_sub.text = "%d/%d 格　·　右键他处 / ESC 收起" % [unit.inventory.size(),
			unit.backpack_capacity()]
	for c in _rows.get_children():
		# 必须先摘下来：只 queue_free 的话本帧它们仍算在容器最小尺寸里，
		# 紧接着的 reset_size() 会把旧行数进去 —— 满包切空包会留一块大白边
		_rows.remove_child(c)
		c.queue_free()
	if unit.inventory.is_empty():
		_rows.add_child(UiKit.dim("（空的 · 走进资源点范围就能捡进来）", 13))
	else:
		for res_id in unit.inventory.keys():
			_rows.add_child(_item_row(str(res_id), int(unit.inventory[res_id])))
	var line := _shortage_line(unit)
	_warn.text = line
	_warn.visible = line != ""
	_panel.reset_size()   # 内容变了就把面板缩放到新的最小尺寸，再定位


func _item_row(res_id: String, amount: int) -> Control:
	var h := UiKit.hbox(6)
	var path := str(Config.get_value("resources.%s.sprite" % res_id, ""))
	if path != "" and ResourceLoader.exists(path):
		var icon := TextureRect.new()
		icon.texture = load(path)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		# 必须 IGNORE_SIZE：默认的 KEEP_SIZE 会拿源图尺寸当最小尺寸，
		# 下面那行 20 根本压不住，每行高度跟着各资源源图大小不一
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.custom_minimum_size = Vector2(20, 20)
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # 像素画别糊
		h.add_child(icon)
	var nm := str(Config.get_value("resources.%s.name" % res_id, res_id))
	h.add_child(UiKit.label("%s x%d" % [nm, amount], 14, UiKit.COL_TEXT))
	return h


## 短缺提示："短缺 食物 → 攻击-7 移速-10（补上即恢复）"。不缺就空串（不占行）。
func _shortage_line(p: Node) -> String:
	if _survival == null or not is_instance_valid(_survival):
		_survival = get_tree().get_first_node_in_group("survival_system")
	if _survival == null or p == null or not is_instance_valid(p):
		return ""
	var ids: Array = _survival.shortage_ids(p)
	if ids.is_empty():
		return ""
	var names: Array = []
	for id in ids:
		names.append(str(Config.get_value("resources.%s.name" % str(id), str(id))))
	return "短缺 %s → %s（补上即恢复，不会死）" % [
			"、".join(names), Meta.penalty_line(_survival.penalties_for(p))]


# ------------------------------------------------------------
# 定位：钉在头顶，跟着缩放/移动走，夹在视口与菜单栏之间
# ------------------------------------------------------------

func _follow() -> void:
	var canvas := get_viewport().get_canvas_transform()
	var zoom := canvas.get_scale().x
	if zoom <= 0.0:
		zoom = 1.0
	var head: Vector2 = canvas * unit.global_position
	head.y -= _head_offset * zoom
	var vp := get_viewport().get_visible_rect().size
	var s := _panel.size
	var x := clampf(head.x - s.x * 0.5, _margin, maxf(_margin, vp.x - s.x - _margin))
	# 底部不让位给菜单栏的话，蹲在画面下缘的角色会被栏盖住半截面板
	var bar := UiKit.menu_bar_height(vp.y) if UiKit.menu_bar_enabled() else 0.0
	var bottom := maxf(_margin, vp.y - bar - _margin)
	var y := clampf(head.y - s.y, _margin, maxf(_margin, bottom - s.y))
	_panel.position = Vector2(x, y)


## 屏幕坐标下点到的角色（没有就 null）。半径与 SelectArea 同源：
## select_radius_px 是世界像素，先换算到世界再比 —— 缩放/平移都自动跟手。
func _unit_at(screen: Vector2) -> Node:
	var world := get_viewport().get_canvas_transform().affine_inverse() * screen
	var r := float(Config.get_value("player.select_radius_px", 16.0))
	var best: Node = null
	var best_d := INF
	for p in get_tree().get_nodes_in_group("player"):
		if not _alive(p):
			continue
		var d: float = world.distance_squared_to(p.global_position)
		if d <= r * r and d < best_d:
			best_d = d
			best = p
	return best


func _alive(p: Node) -> bool:
	return p != null and is_instance_valid(p) and not bool(p.is_dead())


func _run_running() -> bool:
	if _run == null or not is_instance_valid(_run):
		_run = get_tree().get_first_node_in_group("run_manager")
	return _run != null and _run.state == _run.State.RUNNING


## 宿主 HUD（CanvasLayer）被关掉 = 回基地了。弹窗自己 visible 仍是 true，
## is_visible_in_tree() 也看不到 CanvasLayer.visible，只能直接查父层。
func _layer_hidden() -> bool:
	var host := get_parent()
	return host is CanvasLayer and not (host as CanvasLayer).visible


func _name(p: Node) -> String:
	var nm := str(p.get("character_name"))
	return nm if nm != "" else "角色"

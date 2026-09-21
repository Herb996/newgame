extends CanvasLayer
## ============================================================
## WarehousePanel — 仓库面板（点仓库建筑打开）
## 显示 Meta.bank 中全部资源。打开时暂停游戏，E/ESC 或右上「关闭」关闭。
##
## 皮肤走 UiKit.dialog()（与主菜单/设置面板同一套木框 + 石板芯），
## 每行一个 row_box：资源图标（config resources.<id>.sprite）+ 名称 + 数量/叠加上限。
## 行数上限 = storage.max_slots（可被升级顶到很大）→ 列表套 ScrollContainer。
## ============================================================

var _content: VBoxContainer
var _slots_label: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # 暂停时仍可交互
	_build_ui()
	visible = false


func _build_ui() -> void:
	var col := UiKit.dialog(self, 560, "仓库", close)

	_slots_label = UiKit.dim("", UiKit.FS_SMALL)
	_slots_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_slots_label)

	col.add_child(_scroll(320))

	var hint := UiKit.dim("按 E 或 ESC 关闭", UiKit.FS_SMALL)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(hint)


## 资源列表的滚动容器：固定限高，免得仓库格数升上去后面板顶出屏幕，
## 也免得「多一件物品」就撑一下面板。
func _scroll(list_h: float) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, list_h)
	_content = UiKit.vbox(6)
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content)
	UiKit.skin_scroll(scroll)
	return scroll


func open() -> void:
	_refresh()
	visible = true
	get_tree().paused = true


func close() -> void:
	visible = false
	get_tree().paused = false


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE or event.physical_keycode == KEY_E:
			close()
			get_viewport().set_input_as_handled()


func _refresh() -> void:
	for c in _content.get_children():
		c.queue_free()
	var stack_limit := int(Config.get_value("storage.stack_limit", 1000))
	_slots_label.text = "格子 %d/%d · 每种物品叠加上限 %d" % [
		Meta.bank.size(), Meta.warehouse_slots(), stack_limit]
	if Meta.bank.is_empty():
		var l := UiKit.dim("空空如也——先去废墟搜刮吧", UiKit.FS_BODY)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_content.add_child(l)
		return
	for res in Meta.bank:
		_content.add_child(_make_row(str(res), int(Meta.bank[res]), stack_limit))


## 一行：图标 | 名称 | 数量/上限
func _make_row(res: String, amount: int, stack_limit: int) -> PanelContainer:
	var box := UiKit.row_box(UiKit.COL_ROW)
	var h := UiKit.hbox(10)
	box.add_child(h)

	var icon := UiKit.resource_icon(res, 26.0)
	if icon != null:
		h.add_child(icon)
	h.add_child(UiKit.label(
			str(Config.get_value("resources.%s.name" % res, res)), UiKit.FS_BODY))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(spacer)

	# 到顶的转橙红并写明「已满」：COL_WARN 与 COL_AMBER 差得太小，光换色看不出异常
	var full := amount >= stack_limit
	var val := UiKit.value_label(150)
	val.text = "%d / %d%s" % [amount, stack_limit, "（已满）" if full else ""]
	val.add_theme_color_override("font_color", UiKit.COL_WARN if full else UiKit.COL_AMBER)
	h.add_child(val)
	return box

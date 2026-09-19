extends CanvasLayer
## ============================================================
## WarehousePanel — 仓库面板（靠近仓库按 E 打开）
## 显示 Meta.bank 中全部资源。打开时暂停游戏，E/ESC 关闭。
## ============================================================

var _panel: PanelContainer
var _content: VBoxContainer
var _slots_label: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # 暂停时仍可交互
	_build_ui()
	visible = false


func _build_ui() -> void:
	_panel = UiKit.centered_dialog(self, 360)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_panel.add_child(vbox)

	var title := Label.new()
	title.text = "仓库"
	title.add_theme_font_size_override("font_size", 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_slots_label = Label.new()
	_slots_label.add_theme_font_size_override("font_size", 14)
	_slots_label.add_theme_color_override("font_color", Color(0.85, 0.62, 0.30))
	_slots_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_slots_label)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 4)
	vbox.add_child(_content)

	var hint := Label.new()
	hint.text = "按 E 或 ESC 关闭"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.7, 0.68, 0.63))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)


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
	# 格子占用 + 叠加上限提示
	var stack_limit := int(Config.get_value("storage.stack_limit", 1000))
	_slots_label.text = "格子 %d/%d · 每种物品叠加上限 %d" % [
		Meta.bank.size(), Meta.warehouse_slots(), stack_limit]
	if Meta.bank.is_empty():
		var l := Label.new()
		l.text = "空空如也——先去废墟搜刮吧"
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_content.add_child(l)
		return
	for res in Meta.bank:
		var display: String = str(Config.get_value("resources.%s.name" % res, res))
		var l := Label.new()
		l.text = "%s：%d / %d" % [display, int(Meta.bank[res]), stack_limit]
		l.add_theme_font_size_override("font_size", 18)
		_content.add_child(l)

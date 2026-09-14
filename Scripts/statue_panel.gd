extends CanvasLayer
## ============================================================
## StatuePanel — 雕像升级面板（靠近雕像按 E 打开）
## 两条养成线（生存/获取），每项显示：名称、等级、当前值、
## 下一级费用、升级按钮（满级/资源不足自动禁用）。
## 购买即时生效并存档（Meta.buy_upgrade）。打开时暂停，E/ESC 关闭。
## ============================================================

var _panel: PanelContainer
var _content: VBoxContainer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(560, 0)
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_panel.add_child(vbox)

	var title := Label.new()
	title.text = "蒸汽先贤雕像 — 局外养成"
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 12)
	vbox.add_child(_content)

	var hint := Label.new()
	hint.text = "点击按钮购买升级 · 按 E 或 ESC 关闭"
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

	for line in [["survival", "生存线"], ["acquisition", "获取线"]]:
		var header := Label.new()
		header.text = "— %s —" % line[1]
		header.add_theme_font_size_override("font_size", 17)
		header.add_theme_color_override("font_color", Color(0.85, 0.62, 0.30))
		header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_content.add_child(header)

		for key in Meta.get_upgrade_keys():
			if not String(key).begins_with(line[0] + "."):
				continue
			_content.add_child(_make_row(key))


## 单个升级项一行：名称+等级+数值 | 费用 | 按钮
func _make_row(key: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var lv: int = Meta.get_upgrade_level(key)
	var max_lv: int = int(Config.get_value("meta_progression.%s.max_level" % key, 0))
	var display_name: String = str(Config.get_value("meta_progression.%s.name" % key, key))
	var fmt: String = str(Config.get_value("meta_progression.%s.format" % key, "int"))

	var info := Label.new()
	info.text = "%s  Lv.%d/%d  当前：%s" % [
		display_name, lv, max_lv, _format_stat(Meta.get_stat(key), fmt)]
	info.add_theme_font_size_override("font_size", 16)
	info.custom_minimum_size = Vector2(300, 0)
	row.add_child(info)

	var cost := Label.new()
	cost.text = _cost_text(key)
	cost.add_theme_font_size_override("font_size", 15)
	cost.custom_minimum_size = Vector2(150, 0)
	row.add_child(cost)

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(80, 0)
	if lv >= max_lv:
		btn.text = "已满级"
		btn.disabled = true
	else:
		btn.text = "升级"
		btn.disabled = not Meta.can_afford(key)
		btn.pressed.connect(func():
			Meta.buy_upgrade(key)
			_refresh())
	row.add_child(btn)
	return row


func _cost_text(key: String) -> String:
	var cost: Dictionary = Meta.get_upgrade_cost(key)
	if cost.is_empty():
		return "免费"
	var parts: Array = []
	for res in cost:
		var display: String = str(Config.get_value("resources.%s.name" % res, res))
		parts.append("%s x%d" % [display, int(cost[res])])
	return "，".join(parts)


func _format_stat(v: float, fmt: String) -> String:
	if fmt == "percent":
		return "%d%%" % roundi(v * 100.0)
	return str(roundi(v))

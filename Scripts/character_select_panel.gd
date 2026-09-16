extends CanvasLayer
## ============================================================
## CharacterSelectPanel — 出发大门角色选择面板（靠近大门按 E 打开）
## 角色表来自 config 的 characters.list（当前 2 名：枪剑士=近战剑 / 弓手=远程弓）。
## 点「出击」发 character_selected(character)（由 main 接管：记选择 → 进局）；
## E / ESC 关闭面板留在基地。打开时暂停，与仓库/雕像面板同一套交互约定。
## ============================================================

signal character_selected(character: Dictionary)

var _panel: PanelContainer
var _content: VBoxContainer
var _current_id := ""   # 上次选择的角色 id（面板里标注「上次选择」）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(640, 0)
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_panel.add_child(vbox)

	var title := Label.new()
	title.text = "出发大门 — 选择出击角色"
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 12)
	vbox.add_child(_content)

	var hint := Label.new()
	hint.text = "点击「出击」进入废墟 · 按 E 或 ESC 取消返回基地"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.7, 0.68, 0.63))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)


## current_id：上次选择的角色 id（空 = 用 config 的 characters.default 高亮预选）
func open(current_id: String = "") -> void:
	_current_id = current_id
	if _current_id == "":
		_current_id = str(Config.get_value("characters.default", ""))
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
	var list: Array = Config.get_value("characters.list", [])
	if list.is_empty():
		push_warning("[CharacterPanel] characters.list 为空，面板没有可选角色")
		return
	for entry in list:
		if entry is Dictionary and not (entry as Dictionary).is_empty():
			_content.add_child(_make_row(entry))


## 单个角色一行：名称+描述 | 出击按钮
func _make_row(character: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var char_id := str(character.get("id", ""))
	var name_label := Label.new()
	var suffix := "（上次选择）" if char_id == _current_id else ""
	name_label.text = "%s%s\n%s" % [
		str(character.get("name", char_id)), suffix,
		str(character.get("desc", ""))]
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.custom_minimum_size = Vector2(460, 0)
	row.add_child(name_label)

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(110, 0)
	btn.text = "出击"
	btn.pressed.connect(func():
		close()
		character_selected.emit(character))
	row.add_child(btn)
	return row

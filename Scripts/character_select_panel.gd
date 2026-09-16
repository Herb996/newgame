extends CanvasLayer
## ============================================================
## CharacterSelectPanel — 出发大门选人面板（鼠标点击大门 / 按 E 打开）
## 角色表来自 config 的 characters.list（当前 2 名：枪剑士=近战剑 / 弓手=远程弓）。
## **可多选**：勾选若干角色组成小队，点「出击」发 launch_requested(characters)
## （由 main 接管：记名单 → 按名单生成玩家 → 进局）；E / ESC 取消留在基地。
## 打开时暂停，与仓库/雕像面板同一套交互约定。
## ============================================================

signal launch_requested(characters: Array)

var _content: VBoxContainer
var _launch_btn: Button
var _checks: Array = []   # [{id, name, checkbox}]，保持 config 顺序


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(680, 0)
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "出发大门 — 选择出击小队（可多选）"
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 12)
	vbox.add_child(_content)

	var hint := Label.new()
	hint.text = "勾选要带进废墟的角色 · 点「出击」出发 · 按 E 或 ESC 取消返回基地"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.7, 0.68, 0.63))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)

	_launch_btn = Button.new()
	_launch_btn.custom_minimum_size = Vector2(0, 40)
	_launch_btn.pressed.connect(_on_launch_pressed)
	vbox.add_child(_launch_btn)


## preselected_ids：上次选中的角色 id（会话内重开面板时保留勾选）；空 = 全选
func open(preselected_ids: Array = []) -> void:
	_refresh(preselected_ids)
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


func _refresh(preselected_ids: Array) -> void:
	for c in _content.get_children():
		c.queue_free()
	_checks.clear()
	var list: Array = Config.get_value("characters.list", [])
	if list.is_empty():
		push_warning("[CharacterPanel] characters.list 为空，面板没有可选角色")
		_launch_btn.text = "没有可用角色"
		_launch_btn.disabled = true
		return
	var default_id := str(Config.get_value("characters.default", ""))
	for entry in list:
		if not (entry is Dictionary) or (entry as Dictionary).is_empty():
			continue
		var char_id := str(entry.get("id", ""))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		var check := CheckBox.new()
		# 预选规则：上次选过的按上次；从未选过时全选（默认角色至少在内）
		check.button_pressed = true if preselected_ids.is_empty() \
				else preselected_ids.has(char_id)
		check.toggled.connect(func(_on: bool): _update_launch_btn())
		row.add_child(check)

		var info := Label.new()
		info.text = "%s\n%s" % [
			str(entry.get("name", char_id)), str(entry.get("desc", ""))]
		info.add_theme_font_size_override("font_size", 16)
		info.custom_minimum_size = Vector2(520, 0)
		row.add_child(info)
		_content.add_child(row)
		_checks.append({"id": char_id, "name": str(entry.get("name", char_id)),
				"checkbox": check})
	_update_launch_btn()


func _update_launch_btn() -> void:
	var n := _checked().size()
	_launch_btn.text = "出击（已选 %d 名）" % n
	_launch_btn.disabled = n == 0


func _checked() -> Array:
	var out: Array = []
	for e in _checks:
		if bool(e["checkbox"].button_pressed):
			out.append(e)
	return out


func _on_launch_pressed() -> void:
	var checked := _checked()
	if checked.is_empty():
		return
	var characters: Array = []
	for e in checked:
		characters.append({"id": e["id"], "name": e["name"]})
	close()
	launch_requested.emit(characters)

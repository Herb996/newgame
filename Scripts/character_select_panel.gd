extends CanvasLayer
## ============================================================
## CharacterSelectPanel — 出发大门「名册」面板（鼠标点击大门 / 按 E 打开）
##
## 2026-09-17 改版：列表来源从 config `characters.list`（**兵种原型**）换成
## Meta.roster（**名册里的具体的人**）。起因是用户定了等级系统：
##   · 最多 9 级、初始 0 级、跨局持久
##   · **死亡永久**（复活功能以后再加）
## ⇒ 等级挂在「人」身上而不是兵种上。同一个兵种可以有两个人、各自等级不同，
##    而且死一个就少一个。所以面板必须列出名册里的人，不能列兵种原型。
##
## 兵种原型（characters.list）仍然在：它提供武器 / 指令集 / 描述 / 图标配色，
## 名册条目里的 `id` 就是指向它的外键。
##
## **可多选**：勾选若干人组成小队，点「出击」发 launch_requested(units)
## （units = [{"uid","id","name","level"}]，由 main 接管 → 生成玩家 → 进局）；
## E / ESC 取消留在基地。打开时暂停，与仓库/雕像面板同一套交互约定。
##
## 名册空/不满时提供「补招新兵」（progression.roster.recruit_free）——
## 没有这一步的话，「全员阵亡 + 还没有复活功能」会让玩家彻底卡死没得玩。
## ============================================================

signal launch_requested(characters: Array)

var _content: VBoxContainer
var _launch_btn: Button
var _recruit_row: HBoxContainer
var _checks: Array = []   # [{uid, id, name, level, checkbox}]，保持名册顺序


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(720, 0)
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "出发大门 — 选择出击小队（从名册点人，可多选）"
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 10)
	vbox.add_child(_content)

	var hint := Label.new()
	hint.text = "等级与经验跨局保留 · **阵亡即从名册除名（永久）**\n" \
			+ "点「出击」出发 · 点「放弃」或按 E / ESC 返回基地"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.7, 0.68, 0.63))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)

	# 补招行：名册不满 且 允许免费补招时才有内容（_refresh 里填）
	_recruit_row = HBoxContainer.new()
	_recruit_row.add_theme_constant_override("separation", 10)
	_recruit_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(_recruit_row)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 12)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_row)

	var cancel_btn := Button.new()
	cancel_btn.text = "放弃 · 返回基地"
	cancel_btn.custom_minimum_size = Vector2(220, 40)
	cancel_btn.pressed.connect(close)
	btn_row.add_child(cancel_btn)

	_launch_btn = Button.new()
	_launch_btn.custom_minimum_size = Vector2(240, 40)
	_launch_btn.pressed.connect(_on_launch_pressed)
	btn_row.add_child(_launch_btn)


## preselected：上次选中的小队（main 传 _selected_units，条目形如 {"uid","id","level"}）。
## 空 = 全选。为了向后兼容，也接受纯 uid / 纯 id 字符串的数组。
func open(preselected: Array = []) -> void:
	_refresh(preselected)
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


func _refresh(preselected: Array) -> void:
	for c in _content.get_children():
		c.queue_free()
	for c in _recruit_row.get_children():
		c.queue_free()
	_checks.clear()

	var want_uids := _preselected_uids(preselected)
	var roster: Array = Meta.roster
	for u in roster:
		if u is Dictionary:
			_add_unit_row(u, want_uids)
	_build_recruit_row(roster.size())
	_update_launch_btn()


## 预选集合 → uid 集合。兼容三种入参：名册条目字典 / uid 整数 / 兵种 id 字符串。
func _preselected_uids(preselected: Array) -> Dictionary:
	var out := {}
	for e in preselected:
		if e is Dictionary:
			out[int((e as Dictionary).get("uid", 0))] = true
		elif typeof(e) == TYPE_INT or typeof(e) == TYPE_FLOAT:
			out[int(e)] = true
		else:
			out[str(e)] = true      # 兵种 id：下面按 id 兜底匹配
	return out


func _add_unit_row(u: Dictionary, want: Dictionary) -> void:
	var uid := int(u.get("uid", 0))
	var level := int(u.get("level", 0))
	var tier_id := Meta.tier_id_of_level(level)
	var arch_id := str(u.get("id", ""))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var check := CheckBox.new()
	# 预选规则：上次选过的按上次；从未选过时全选（一队默认全带上）
	check.button_pressed = want.is_empty() or want.has(uid) or want.has(arch_id)
	check.toggled.connect(func(_on: bool): _update_launch_btn())
	row.add_child(check)

	# 档位色块：和局内头顶徽章的圈色是同一个颜色（视觉上把面板和战场钉在一起）
	var chip := ColorRect.new()
	chip.color = Color(str(Config.get_value(
			"progression.badge.colors.%s" % tier_id, "#378ADD")))
	chip.custom_minimum_size = Vector2(18, 18)
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(chip)

	var arch := _archetype(arch_id)
	var info := Label.new()
	info.text = "%s · Lv%d %s\n%s\n%s" % [
		str(u.get("name", arch_id)), level, Meta.tier_name_of_level(level),
		str(arch.get("desc", "")), _xp_line(level, float(u.get("xp", 0.0)))]
	info.add_theme_font_size_override("font_size", 15)
	info.custom_minimum_size = Vector2(560, 0)
	row.add_child(info)

	_content.add_child(row)
	_checks.append({"uid": uid, "id": arch_id, "name": str(u.get("name", arch_id)),
			"level": level, "checkbox": check})


func _xp_line(level: int, xp: float) -> String:
	if level >= Meta.max_level():
		return "已满级（Lv%d）" % Meta.max_level()
	return "经验 %d / %d（距下一级）" % [int(round(xp)), int(Meta.xp_to_next(level))]


## 补招行：每个兵种原型一个按钮，点了立刻入册并重画面板。
## 名册已满 / 不允许免费补招时不显示任何按钮。
func _build_recruit_row(size_now: int) -> void:
	var cap := int(Config.get_value("progression.roster.max_size", 8))
	if not Meta.can_recruit() or size_now >= cap:
		return
	var label := Label.new()
	label.text = "补招新兵（Lv0，占名额 %d/%d）：" % [size_now, cap]
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.7, 0.68, 0.63))
	_recruit_row.add_child(label)
	for entry in Config.get_value("characters.list", []):
		if not (entry is Dictionary):
			continue
		var id := str((entry as Dictionary).get("id", ""))
		var b := Button.new()
		b.text = str((entry as Dictionary).get("name", id))
		b.pressed.connect(func():
			var unit := Meta.recruit(id)
			if unit.is_empty():
				return          # 名册满 / 原型不存在
			var keep := _checked_uids()
			keep.append(int(unit.get("uid", 0)))   # 新招的人默认一起带上
			_refresh(keep)
		)
		_recruit_row.add_child(b)


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


## 当前勾选者的 uid 列表（补招后重画时保住已有勾选）
func _checked_uids() -> Array:
	var out: Array = []
	for e in _checked():
		out.append(int(e["uid"]))
	return out


func _archetype(id: String) -> Dictionary:
	for entry in Config.get_value("characters.list", []):
		if entry is Dictionary and str((entry as Dictionary).get("id", "")) == id:
			return entry
	return {}


func _on_launch_pressed() -> void:
	var checked := _checked()
	if checked.is_empty():
		return
	var units: Array = []
	for e in checked:
		units.append({"uid": int(e["uid"]), "id": str(e["id"]),
				"name": str(e["name"]), "level": int(e["level"])})
	close()
	launch_requested.emit(units)

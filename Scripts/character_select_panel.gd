extends CanvasLayer
## ============================================================
## CharacterSelectPanel — 出击传送门「名册」面板（鼠标点击传送门 / 按 E 打开）
## （2026-09-20：出击入口从「出发大门」换到「出击传送门」，见 DESIGN §2.4）
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
##
## 2026-09-20 换皮：与主菜单同一套 UiKit 皮肤，每人一张行卡（勾选时卡片提亮），
## 名册上限 progression.roster.max_size 人 → 列表套固定限高的 ScrollContainer，
## 否则 8 人会把「出击」按钮顶出屏幕。
## ============================================================

signal launch_requested(characters: Array)

var _content: VBoxContainer
var _launch_btn: Button
var _recruit_row: HBoxContainer
var _checks: Array = []   # [{uid, id, name, level, checkbox, box}]，保持名册顺序


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


func _build_ui() -> void:
	var vbox := UiKit.dialog(self, 820, "出击传送门", close)

	var sub := UiKit.dim("从名册点人组成出击小队 · 可多选", UiKit.FS_SMALL)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(sub)

	# 固定限高的滚动列表：4 人时刚好不裁卡片，8 人时滚动而不是把按钮顶出屏幕
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 500)
	UiKit.skin_scroll(scroll)
	_content = UiKit.vbox(8)
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content)
	vbox.add_child(scroll)

	var hint := UiKit.dim(
			"等级与经验跨局保留 · 阵亡即从名册除名（永久）\n" \
			+ "点「出击」出发 · 点「放弃」或按 E / ESC 返回基地", UiKit.FS_SMALL)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)

	# 补招行：名册不满 且 允许免费补招时才有内容（_refresh 里填）
	_recruit_row = UiKit.hbox(10)
	_recruit_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(_recruit_row)

	var btn_row := UiKit.hbox(12)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_row)

	var cancel_btn := UiKit.button("放弃 · 返回基地", 240)
	cancel_btn.pressed.connect(close)
	btn_row.add_child(cancel_btn)

	_launch_btn = UiKit.button("出击", 280)
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


## 一张行卡：勾选框 | 档位色块 | 名称+档位 / 描述 / 经验条 / 特性
func _add_unit_row(u: Dictionary, want: Dictionary) -> void:
	var uid := int(u.get("uid", 0))
	var level := int(u.get("level", 0))
	var tier_id := Meta.tier_id_of_level(level)
	var arch_id := str(u.get("id", ""))
	var arch := _archetype(arch_id)

	var box := UiKit.row_box(UiKit.COL_ROW)
	var row := UiKit.hbox(12)
	box.add_child(row)

	# 预选规则：上次选过的按上次；从未选过时全选（一队默认全带上）
	var check := UiKit.checkbox("", want.is_empty() or want.has(uid) or want.has(arch_id))
	check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	check.toggled.connect(func(_on: bool): _update_launch_btn())
	row.add_child(check)

	# 档位色块：和局内头顶徽章的圈色是同一个颜色（视觉上把面板和战场钉在一起）
	var chip := ColorRect.new()
	chip.color = Color(str(Config.get_value(
			"progression.badge.colors.%s" % tier_id, "#378ADD")))
	chip.custom_minimum_size = Vector2(16, 16)
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(chip)

	var info := UiKit.vbox(2)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var title_row := UiKit.hbox(8)
	title_row.add_child(UiKit.label(str(u.get("name", arch_id)), UiKit.FS_BODY))
	title_row.add_child(UiKit.label(
			"Lv%d · %s" % [level, Meta.tier_name_of_level(level)],
			UiKit.FS_BODY, UiKit.COL_AMBER))
	info.add_child(title_row)

	info.add_child(UiKit.dim(str(arch.get("desc", "")), UiKit.FS_SMALL))
	info.add_child(_xp_line(level, float(u.get("xp", 0.0))))
	info.add_child(UiKit.dim(_traits_line(u), UiKit.FS_SMALL))
	row.add_child(info)

	box.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			check.button_pressed = not check.button_pressed)
	check.toggled.connect(func(_on: bool): _set_row_bg(box, _on))
	_set_row_bg(box, check.button_pressed)

	_content.add_child(box)
	_checks.append({"uid": uid, "id": arch_id, "name": str(u.get("name", arch_id)),
			"level": level, "checkbox": check})


## 勾选态 = 卡片底色 + 左边框：选中提亮一档并描一圈琥珀。
## 只换底色实测分不出来（COL_ROW 与 COL_ROW_HI 差得太小），所以加边框。
func _set_row_bg(box: Control, on: bool) -> void:
	var sb := box.get_theme_stylebox("panel") as StyleBoxFlat
	if sb == null:
		return
	sb.bg_color = UiKit.COL_ROW_HI if on else UiKit.COL_ROW
	sb.border_color = UiKit.COL_AMBER if on \
			else Color(UiKit.COL_LINE.r, UiKit.COL_LINE.g, UiKit.COL_LINE.b, 0.55)
	sb.set_border_width_all(2 if on else 1)


## 经验行：文字 + 一条进度条
func _xp_line(level: int, xp: float) -> Control:
	var wrap := UiKit.hbox(8)
	var maxed := level >= Meta.max_level()
	var need := float(Meta.xp_to_next(level))
	var txt := "已满级（Lv%d）" % Meta.max_level() if maxed \
			else "经验 %d / %d" % [int(round(xp)), int(need)]
	var lab := UiKit.dim(txt, UiKit.FS_SMALL)
	lab.custom_minimum_size = Vector2(150, 0)
	wrap.add_child(lab)

	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 8)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.show_percentage = false
	bar.max_value = 1.0 if maxed else need
	bar.value = 1.0 if maxed else xp
	# 底槽/填充用扁平 StyleBoxFlat：滑条那套九宫格木条贴图压到 8px 高会糊成一整条白带
	var trough := StyleBoxFlat.new()
	trough.bg_color = UiKit.COL_TROUGH
	trough.border_color = Color(UiKit.COL_LINE.r, UiKit.COL_LINE.g, UiKit.COL_LINE.b, 0.6)
	trough.set_border_width_all(1)
	trough.set_corner_radius_all(3)
	var fill := StyleBoxFlat.new()
	fill.bg_color = UiKit.COL_AMBER
	fill.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("background", trough)
	bar.add_theme_stylebox_override("fill", fill)
	wrap.add_child(bar)
	return wrap


## 特性层数一览（升级随机攒的）：按 config progression.traits.list 的固定顺序列，
## 只显示层数 > 0 的；一个都没有时给一句提示，免得空着像坏了。
func _traits_line(u: Dictionary) -> String:
	var tr = u.get("traits", {})
	if not (tr is Dictionary) or (tr as Dictionary).is_empty():
		return "特性：尚无（每升 1 级随机获得一个）"
	var parts: Array = []
	for id in Meta.trait_ids():
		var s := int((tr as Dictionary).get(id, 0))
		if s > 0:
			var d: Dictionary = Meta.trait_defs().get(id, {})
			parts.append("%s×%d" % [str(d.get("name", id)), s])
	if parts.is_empty():
		return "特性：尚无（每升 1 级随机获得一个）"
	return "特性：" + " · ".join(parts)


## 补招行：每个兵种原型一个按钮，点了立刻入册并重画面板。
## 名册已满 / 不允许免费补招时不显示任何按钮。
func _build_recruit_row(size_now: int) -> void:
	var cap := int(Config.get_value("progression.roster.max_size", 8))
	if not Meta.can_recruit() or size_now >= cap:
		return
	var label := UiKit.dim("补招新兵（Lv0，占名额 %d/%d）：" % [size_now, cap], UiKit.FS_SMALL)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_recruit_row.add_child(label)
	for entry in Config.get_value("characters.list", []):
		if not (entry is Dictionary):
			continue
		var id := str((entry as Dictionary).get("id", ""))
		var b := UiKit.small_button(str((entry as Dictionary).get("name", id)), 96)
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

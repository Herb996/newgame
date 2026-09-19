extends Control
## ============================================================
## SlotPanel — 存档槽面板（「新建存档」与「历史存档」共用）
##
## mode = "new"  ：空槽可新建（弹窗填名字）；已有槽显示「覆盖」并二次确认。
## mode = "load" ：已有槽可「进入」；空槽按钮禁用。
## 两种模式都能删除槽（二次确认）。
##
## 选定后：SaveSlots.activate(slot) → 发 launch_requested，由 StartMenu 换场景。
##
## 用法（在 StartMenu 里）：
##   var p: Control = SLOT_PANEL.new()
##   p.mode = "new"
##   p.launch_requested.connect(_launch_game)
##   _open_panel(p)
## ============================================================

signal close_requested
signal launch_requested

## 面板模式："new" | "load"
var mode := "load"

var _list: VBoxContainer
var _hint: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 裸 Control 的 rect 是 0×0（本面板由 StartMenu 用 .new() 造出来再挂上去），
	# 不铺满的话 CenterContainer 会在 0×0 里居中，面板整体缩到左上角。
	UiKit.stretch(self)
	# 皮肤贴图是像素画：整棵 UI 树用最近邻采样
	texture_filter = UiKit.TS_NEAREST
	_build_ui()
	_refresh()


# ------------------------------------------------------------
# 界面
# ------------------------------------------------------------

func _build_ui() -> void:
	add_child(UiKit.overlay())

	# 与设置面板同一套全屏骨架：10px 黑边 + 木框 + 石板芯
	var panel := UiKit.fullscreen_panel(self)

	var col := UiKit.vbox(10)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(col)

	col.add_child(UiKit.ribbon_title("新建存档" if mode == "new" else "历史存档", 380, 26))

	_hint = UiKit.dim("")
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_hint)

	col.add_child(UiKit.spacer(4))

	var scroll := ScrollContainer.new()
	# 高度按「槽位数 × 行高」给足，别让最后一槽被裁掉（6 槽 ≈ 6×65 + 间隔）
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)

	_list = UiKit.vbox(8)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	col.add_child(UiKit.spacer(6))

	# 底部一行：打开存档目录（排查用）+ 返回，靠右等宽
	var footer := UiKit.hbox(10)
	col.add_child(footer)

	footer.add_child(_expander())

	var open_dir := UiKit.button("打开存档目录", 150)
	open_dir.pressed.connect(func():
		OS.shell_open(ProjectSettings.globalize_path(SaveSlots.DIR)))
	footer.add_child(open_dir)

	var back := UiKit.button("返回", 150)
	back.pressed.connect(func(): close_requested.emit())
	footer.add_child(back)

	# 右上角关闭钮，等价返回
	var close_btn := UiKit.small_button("X", 0, UiKit.FS_HEADER)
	close_btn.custom_minimum_size = Vector2(48, 48)
	close_btn.tooltip_text = "关闭（返回菜单）"
	close_btn.pressed.connect(func(): close_requested.emit())
	close_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	close_btn.offset_left = -92.0
	close_btn.offset_top = 40.0
	close_btn.offset_right = -44.0
	close_btn.offset_bottom = 88.0
	add_child(close_btn)


func _expander() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _refresh() -> void:
	_hint.text = ("选择一个空槽存档；已有存档会被覆盖（会二次确认）"
			if mode == "new" else "选择一个存档继续游戏")
	for c in _list.get_children():
		c.queue_free()
	for info in SaveSlots.list_slots():
		_list.add_child(_make_row(info))


# ------------------------------------------------------------
# 单行
# ------------------------------------------------------------

func _make_row(info: Dictionary) -> Control:
	var exists: bool = info["exists"]
	# 上次游玩过的那一槽用暖色底，一眼能找到"我上次玩的是哪个"
	var box := UiKit.row_box(UiKit.COL_ROW_HI if info["is_last"] and exists else UiKit.COL_ROW, 10)

	var row := UiKit.hbox(12)
	box.add_child(row)

	# 左：槽号 + 名称
	var left := UiKit.vbox(2)
	left.custom_minimum_size = Vector2(300, 0)
	row.add_child(left)
	var name_color: Color = UiKit.COL_TEXT if exists else UiKit.COL_DIM
	var name_label := UiKit.label("%d. %s" % [info["slot"], info["name"]], UiKit.FS_HEADER, name_color)
	left.add_child(name_label)
	left.add_child(UiKit.dim(_sub_text(info)))

	# 中：存档内容概览
	var mid := UiKit.vbox(2)
	mid.custom_minimum_size = Vector2(230, 0)
	row.add_child(mid)
	if exists:
		mid.add_child(UiKit.dim(_content_text(info), UiKit.FS_BODY))
		mid.add_child(UiKit.dim(tr("创建：%s") % info["created"]))
	else:
		mid.add_child(UiKit.dim("— 空槽 —", UiKit.FS_BODY))

	# 右：动作按钮
	var right := UiKit.hbox(8)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.alignment = BoxContainer.ALIGNMENT_END
	row.add_child(right)

	if mode == "new":
		var b := UiKit.small_button("覆盖" if exists else "新建", 96)
		b.pressed.connect(_on_create_pressed.bind(info))
		right.add_child(b)
	elif exists:
		var b := UiKit.small_button("进入", 96)
		b.pressed.connect(_on_load_pressed.bind(int(info["slot"])))
		right.add_child(b)
	else:
		var b := UiKit.small_button("空槽", 96)
		b.disabled = true
		right.add_child(b)

	if exists:
		var del := UiKit.small_button("删除", 80)
		del.pressed.connect(_on_delete_pressed.bind(info))
		right.add_child(del)

	return box


func _sub_text(info: Dictionary) -> String:
	if not info["exists"]:
		return "未使用"
	return tr("上次游玩：%s") % info["last_played"]


func _content_text(info: Dictionary) -> String:
	return tr("资源 %d 种 / 共 %d · 升级 %d 级") % [
		info["bank_kinds"], info["bank_total"], info["upgrade_total"]]


# ------------------------------------------------------------
# 动作
# ------------------------------------------------------------

func _on_create_pressed(info: Dictionary) -> void:
	var slot := int(info["slot"])
	if not info["exists"]:
		_ask_name(slot, SaveSlots.default_slot_name(slot))
		return
	_confirm("覆盖存档",
			tr("槽 %d「%s」里已有进度：\n%s\n\n覆盖后这些内容将全部丢失，确定吗？")
					% [slot, info["name"], _content_text(info)],
			"覆盖", func(): _ask_name(slot, str(info["name"])))


func _ask_name(slot: int, default_name: String) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "命名存档"
	dlg.dialog_text = tr("给 %d 号槽起个名字：") % slot
	dlg.ok_button_text = "创建并进入"
	dlg.cancel_button_text = "取消"
	dlg.process_mode = Node.PROCESS_MODE_ALWAYS

	var edit := UiKit.line_edit(default_name, 300)
	edit.max_length = 24
	dlg.add_child(edit)

	dlg.confirmed.connect(func():
		var name := edit.text.strip_edges()
		if name == "":
			name = SaveSlots.default_slot_name(slot)
		if SaveSlots.create_slot(slot, name):
			launch_requested.emit()
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()
	edit.grab_focus()
	edit.select_all()


func _on_load_pressed(slot: int) -> void:
	if SaveSlots.activate(slot):
		launch_requested.emit()
	else:
		push_warning("[SlotPanel] 槽 %d 激活失败" % slot)


func _on_delete_pressed(info: Dictionary) -> void:
	var slot := int(info["slot"])
	_confirm("删除存档",
			tr("确定删除槽 %d「%s」？\n此操作不可撤销。") % [slot, info["name"]],
			"删除", func():
				if SaveSlots.delete_slot(slot):
					_refresh())


## 统一的二次确认弹窗
func _confirm(title_text: String, text: String, ok_text: String, on_ok: Callable) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = title_text
	dlg.dialog_text = text
	dlg.ok_button_text = ok_text
	dlg.cancel_button_text = "取消"
	dlg.process_mode = Node.PROCESS_MODE_ALWAYS
	dlg.confirmed.connect(func():
		if on_ok.is_valid():
			on_ok.call()
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()

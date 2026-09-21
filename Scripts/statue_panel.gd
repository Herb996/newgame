extends CanvasLayer
## ============================================================
## StatuePanel — 雕像升级面板（点修道院建筑打开）
## 两条养成线（生存/获取），每项一行卡片：名称 + 等级、当前值 → 下一级值、
## 费用（资源图标，够=绿 / 不够=橙红）、升级按钮（满级/资源不足自动禁用）。
## 购买即时生效并存档（Meta.buy_upgrade）。打开时暂停，E/ESC 或右上「关闭」关闭。
##
## 下一级值 = 当前值 + config 的 per_level（Meta.get_stat 是线性公式，见其注释）。
## ============================================================

var _content: VBoxContainer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


func _build_ui() -> void:
	var col := UiKit.dialog(self, 680, "蒸汽先贤雕像", close)

	var sub := UiKit.dim("局外养成 · 升级永久生效，写进当前存档槽", UiKit.FS_SMALL)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(sub)

	# 升级项共 6~8 条，加上两条线标题，限高滚动防顶出屏幕
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 460)
	_content = UiKit.vbox(10)
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content)
	UiKit.skin_scroll(scroll)
	col.add_child(scroll)

	var hint := UiKit.dim("点击按钮购买升级 · 按 E 或 ESC 关闭", UiKit.FS_SMALL)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(hint)


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
		_content.add_child(UiKit.section(line[1]))
		for key in Meta.get_upgrade_keys():
			if not String(key).begins_with(line[0] + "."):
				continue
			_content.add_child(_make_row(key))


## 单个升级项一行卡片：[名称/等级 + 当前值→下一级] | [费用] | [按钮]
func _make_row(key: String) -> PanelContainer:
	var lv: int = Meta.get_upgrade_level(key)
	var max_lv: int = int(Config.get_value("meta_progression.%s.max_level" % key, 0))
	var display_name: String = str(Config.get_value("meta_progression.%s.name" % key, key))
	var fmt: String = str(Config.get_value("meta_progression.%s.format" % key, "int"))
	var maxed := lv >= max_lv
	var afford := Meta.can_afford(key)

	var box := UiKit.row_box(UiKit.COL_ROW)
	var h := UiKit.hbox(12)
	box.add_child(h)

	# 左：名称 + 等级 / 当前值 → 下一级值
	var info := UiKit.vbox(2)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title_row := UiKit.hbox(8)
	title_row.add_child(UiKit.label(display_name, UiKit.FS_BODY))
	var ttl := Control.new()
	ttl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(ttl)
	title_row.add_child(UiKit.label("Lv.%d/%d" % [lv, max_lv], UiKit.FS_BODY, UiKit.COL_AMBER))
	info.add_child(title_row)

	var cur := _format_stat(Meta.get_stat(key), fmt)
	var stat_line: Label
	if maxed:
		stat_line = UiKit.dim("当前 %s（已满级）" % cur, UiKit.FS_SMALL)
	else:
		var per_level := float(Config.get_value("meta_progression.%s.per_level" % key, 0))
		var nxt := _format_stat(Meta.get_stat(key) + per_level, fmt)
		stat_line = UiKit.label("当前 %s  →  下一级 %s" % [cur, nxt], UiKit.FS_SMALL, UiKit.COL_DIM)
	info.add_child(stat_line)
	h.add_child(info)

	# 中：费用（图标 + 数量，竖排右对齐）。整行 tooltip 给「仓库现有」，
	# 差多少一目了然，不用再去开仓库面板对数字。
	var cost_box := UiKit.vbox(2)
	cost_box.alignment = BoxContainer.ALIGNMENT_CENTER
	var cost: Dictionary = Meta.get_upgrade_cost(key)
	if cost.is_empty():
		cost_box.add_child(UiKit.dim("免费", UiKit.FS_SMALL))
	else:
		for res in cost:
			cost_box.add_child(_cost_line(str(res), int(cost[res]), afford))
		cost_box.tooltip_text = _bank_tooltip(cost)
	h.add_child(cost_box)

	# 右：按钮（皮肤同主菜单的蓝色小方块，禁用态自带半透明）
	var btn := UiKit.small_button("已满级" if maxed else "升级", 96)
	btn.disabled = maxed or not afford
	if not maxed:
		btn.tooltip_text = "消耗仓库资源，立即生效"
		btn.pressed.connect(func():
			Meta.buy_upgrade(key)
			_refresh())
	h.add_child(btn)
	return box


## 单项费用一行：图标 + ×数量；够=绿、不够=橙红
func _cost_line(res: String, need: int, afford: bool) -> Control:
	var line := UiKit.hbox(6)
	var icon := UiKit.resource_icon(res, 22.0)
	if icon != null:
		line.add_child(icon)
	var have := int(Meta.bank.get(res, 0))
	var lab := UiKit.label("×%d" % need, UiKit.FS_SMALL,
			UiKit.COL_OK if afford else UiKit.COL_WARN)
	lab.tooltip_text = "%s：仓库 %d / 需要 %d" % [
		str(Config.get_value("resources.%s.name" % res, res)), have, need]
	line.add_child(lab)
	return line


## 费用区总 tooltip：把每一项的「仓库现有 / 需要」列一遍
func _bank_tooltip(cost: Dictionary) -> String:
	var parts: Array = []
	for res in cost:
		parts.append("%s %d/%d" % [str(Config.get_value("resources.%s.name" % res, res)),
				int(Meta.bank.get(res, 0)), int(cost[res])])
	return "仓库现有 / 需要：" + "　".join(parts)


func _format_stat(v: float, fmt: String) -> String:
	if fmt == "percent":
		return "%d%%" % roundi(v * 100.0)
	return str(roundi(v))

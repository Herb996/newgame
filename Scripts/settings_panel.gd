extends Control
## ============================================================
## SettingsPanel — 参数配置面板（开始菜单 → 参数配置）
##
## 分页：画面 / 音频 / 玩法 / 操作 / 语言 / 调试
## 表驱动：所有条目写在 _make_schema() 里，每项一行，加参数只改那张表。
##
## 值怎么存：写进 Config 的**用户层** → user://settings.json。
## 不去改 Data/config/ —— 导出后 res:// 只读，而且会和版本管理打架。
## 每行右上角的 ↺ 只重置该项，底部「恢复默认设置」清空整个用户层。
##
## 生效时机：标 live=true 的（窗口/帧率/音量）改完立即作用；
## 其余是「下次进局/下次生成地图」才读的键，行内 note 会写明。
##
## 【键位必须存物理键码】player.gd / survival_system.gd / camera_controller.gd
## 消费的都是 `event.physical_keycode` / `Input.is_physical_key_pressed`，
## 所以这里捕获也用 physical_keycode —— 存逻辑键码的话，非 QWERTY 布局会错位。
## ============================================================

signal close_requested

const RATIO_BAR_SCRIPT := preload("res://Scripts/ratio_bar.gd")

## 打开时默认停在第几页（截图验证用；正常进入是 0 = 画面）
var initial_tab := 0

## 行内控件（下拉框 / 改键按钮 / 执行按钮）与底部按钮的统一宽度：
## 一列控件同宽，右缘才是一条直线
const ROW_CONTROL_W := 220
const _FOOTER_BTN_W := 150

var _tab_bar: HBoxContainer
var _content: VBoxContainer
var _tabs: Array = []
var _active := 0

# 改键状态
var _awaiting_path := ""
var _awaiting_button: Button = null

# 暂存改动：面板里所有编辑先进这两个字典，点「确认应用」才落盘 + 生效；返回则丢弃。
var _pending_set: Dictionary = {}
var _pending_clear: Dictionary = {}
var _confirm_btn: Button = null
var _dirty_label: Label = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 皮肤贴图是像素画：整棵 UI 树用最近邻采样，避免放大发糊
	texture_filter = UiKit.TS_NEAREST
	# 面板由 StartMenu 用 .new() 造出来再挂到宿主上，裸 Control 的 rect 是 0×0 ——
	# 不铺满的话里面的 CenterContainer 在 0×0 里居中，整个面板会缩到左上角。
	UiKit.stretch(self)
	_tabs = _make_schema()
	_build_ui()
	_show_tab(initial_tab)


# ------------------------------------------------------------
# 界面骨架
# ------------------------------------------------------------

func _build_ui() -> void:
	add_child(UiKit.overlay())

	# 全屏骨架（10px 黑边 + 木框 + 石板芯）与存档/其他面板共用同一份实现
	var panel := UiKit.fullscreen_panel(self)

	var col := UiKit.vbox(10)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(col)

	col.add_child(UiKit.ribbon_title("参数配置", 430, 28))

	var sub := UiKit.dim("改动先暂存，点右下「确认应用」才生效并保存 · 标「下次进局」的项要重新进一局才读到")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(sub)

	# --- 分页按钮 ---
	var bar_wrap := CenterContainer.new()
	col.add_child(bar_wrap)
	_tab_bar = UiKit.hbox(6)
	bar_wrap.add_child(_tab_bar)

	var group := ButtonGroup.new()
	for i in range(_tabs.size()):
		var b := UiKit.small_button(str(_tabs[i]["name"]), 104)
		b.toggle_mode = true
		b.button_group = group
		# 没有这一步的话首屏所有页签都是"未选中"外观，看不出当前在哪一页
		if i == initial_tab:
			b.button_pressed = true
		b.pressed.connect(_show_tab.bind(i))
		_tab_bar.add_child(b)

	col.add_child(UiKit.spacer(4))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# 右侧留白：行尾的「默认 / 未确认」角标不贴着面板边框
	var scroll_wrap := MarginContainer.new()
	scroll_wrap.add_theme_constant_override("margin_right", 14)
	scroll_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_wrap.add_child(scroll)
	col.add_child(scroll_wrap)

	_content = UiKit.vbox(10)
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content)

	col.add_child(UiKit.spacer(4))

	# --- 底部：左侧弹性空隙，三个按钮等宽靠右排（确认应用 · 恢复默认设置 · 返回） ---
	var footer := UiKit.hbox(10)
	col.add_child(footer)

	footer.add_child(_expander())

	_dirty_label = UiKit.label("", UiKit.FS_SMALL, UiKit.COL_AMBER)
	footer.add_child(_dirty_label)

	_confirm_btn = UiKit.button("确认应用", _FOOTER_BTN_W)
	_confirm_btn.pressed.connect(_on_confirm)
	_confirm_btn.disabled = true
	footer.add_child(_confirm_btn)

	var reset := UiKit.button("恢复默认设置", _FOOTER_BTN_W)
	reset.pressed.connect(_on_reset_all)
	footer.add_child(reset)

	var back := UiKit.button("返回", _FOOTER_BTN_W)
	back.pressed.connect(_on_back)
	footer.add_child(back)

	_update_footer()

	# 右上角关闭钮：贴在木框角上，等价于「返回」（有未确认改动会先询问）
	var close_btn := UiKit.small_button("X", 0, UiKit.FS_HEADER)
	close_btn.custom_minimum_size = Vector2(48, 48)
	close_btn.tooltip_text = "关闭（返回菜单）"
	close_btn.pressed.connect(_on_back)
	close_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	close_btn.offset_left = -92.0
	close_btn.offset_top = 40.0
	close_btn.offset_right = -44.0
	close_btn.offset_bottom = 88.0
	add_child(close_btn)


func _show_tab(index: int) -> void:
	_active = clampi(index, 0, _tabs.size() - 1)
	for c in _content.get_children():
		c.queue_free()
	for entry in _tabs[_active]["entries"]:
		_content.add_child(_make_entry(entry))
	_update_footer()


# ------------------------------------------------------------
# 单条目
# ------------------------------------------------------------

func _make_entry(entry: Dictionary) -> Control:
	var kind := str(entry.get("type", "number"))

	if kind == "divider":
		return UiKit.section(str(entry["label"]))

	if kind == "info":
		var l := UiKit.dim(str(entry["label"]))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		return l

	if kind == "ratio_bar":
		var rb := UiKit.vbox(4)
		rb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var paths: Array = entry.get("paths", [])
		var min_paths: Array = entry.get("min_paths", [])
		var max_paths: Array = entry.get("max_paths", [])
		var vals: Array = []
		for p in paths:
			vals.append(float(_eff(str(p))))
		var mins: Array = []
		for p in min_paths:
			mins.append(float(_eff(str(p))))
		var maxs: Array = []
		for p in max_paths:
			maxs.append(float(_eff(str(p))))
		var bar = RATIO_BAR_SCRIPT.new()
		bar.setup(_biome_bar_labels(paths.size()), _biome_bar_colors(paths.size()), vals, mins, maxs)
		bar.changed.connect(func(new_vals: Array): _stage_ratio(paths, new_vals))
		bar.bounds_changed.connect(func(new_mins: Array, new_maxs: Array): _stage_bounds(min_paths, max_paths, new_mins, new_maxs))
		rb.add_child(bar)
		if str(entry.get("note", "")) != "":
			var n := UiKit.note(str(entry["note"]))
			n.custom_minimum_size = Vector2(840, 0)
			rb.add_child(n)
		return rb

	var box := UiKit.vbox(2)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 用 get 而不是 []：action 之类没有对应配置键的条目没有 path
	var path := str(entry.get("path", ""))

	var row := UiKit.hbox(10)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(row)

	# 名称列固定宽度：所有行的文字从同一条左基线开始（左对齐），控件列全部推到右侧
	var name_label := UiKit.label(str(entry["label"]), UiKit.FS_BODY)
	name_label.custom_minimum_size = Vector2(300, 0)
	row.add_child(name_label)

	# 数值行滑条自己撑满；其它类型加弹性空隙把控件推到右边 → 两边对齐
	if kind != "number":
		row.add_child(_expander())

	match kind:
		"bool":
			var cb := UiKit.checkbox("", bool(_eff(path)))
			cb.toggled.connect(func(v: bool): _commit(entry, v))
			row.add_child(cb)
		"number":
			row.add_child(_make_number(entry))
		"enum":
			var o := UiKit.option(_enum_labels(entry), _enum_index(entry), ROW_CONTROL_W)
			o.item_selected.connect(func(i: int): _commit(entry, _enum_value(entry, i)))
			row.add_child(o)
		"key":
			var b := UiKit.small_button(UiKit.key_name(int(_eff(path))), ROW_CONTROL_W)
			b.pressed.connect(func(): _begin_key_capture(path, b))
			row.add_child(b)
		"action":
			var b := UiKit.small_button(str(entry.get("button", "执行")), ROW_CONTROL_W)
			if entry.get("handler") is Callable:
				b.pressed.connect(entry["handler"])
			row.add_child(b)

	# 只有真的"有值可重置"的类型才挂 默认
	if kind in ["bool", "number", "enum", "key"]:
		row.add_child(_make_reset_button(entry))
	if path != "":
		if _is_dirty(path):
			var pb := UiKit.label("未确认", UiKit.FS_SMALL, UiKit.COL_AMBER)
			pb.custom_minimum_size = Vector2(52, 0)
			row.add_child(pb)

	if str(entry.get("note", "")) != "":
		var note := UiKit.note(str(entry["note"]))
		# 说明文字随行宽撑满（左对齐、自动换行），不再固定 840px
		note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_child(note)

	return box


## 数值行：滑块 + 实时数值 + 单位说明
func _make_number(entry: Dictionary) -> HBoxContainer:
	var path := str(entry["path"])
	var step := float(entry.get("step", 1.0))
	var _e = _eff(path)
	var cur := float(_e) if _e != null else float(entry.get("min", 0.0))
	var box := UiKit.hbox(10)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var s := UiKit.slider(float(entry.get("min", 0.0)), float(entry.get("max", 1.0)), step, cur, 300)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(s)

	var vl := UiKit.value_label(120)
	vl.text = _format_value(cur, entry)
	box.add_child(vl)

	s.value_changed.connect(func(v: float):
		vl.text = _format_value(v, entry)
		_commit(entry, _typed(entry, v)))
	return box


func _make_reset_button(entry: Dictionary) -> Button:
	# 别用 "↺" 这类符号字符：默认字体里没有这个字形，屏上只剩一个"小方块/小三角"，
	# 玩家根本不知道是什么按钮。用中文字更稳。
	var path := str(entry["path"])
	var b := UiKit.small_button("默认", 56, UiKit.FS_SMALL)
	b.tooltip_text = "把这一项恢复成出厂值（点「确认应用」后生效）"
	b.disabled = not (Config.has_user_value(path) or _pending_set.has(path) or _pending_clear.has(path))
	b.pressed.connect(func():
		_pending_clear[path] = true
		_pending_set.erase(path)
		_show_tab(_active))
	return b


func _format_value(v: float, entry: Dictionary) -> String:
	match str(entry.get("fmt", "")):
		"duration":
			return UiKit.duration(v)
		"percent":
			return "%d%%" % roundi(v * 100.0)
		"times":
			return "%.2fx" % v
		"px":
			return "%.0fpx" % v
	return UiKit.number(v, float(entry.get("step", 1.0)))


# ------------------------------------------------------------
# 写入与生效
# ------------------------------------------------------------

## 按出厂值的类型决定存 int 还是 float：
## enemy.count 是整数（存 100.5 会让 `int(...)` 读出来变成截断值，读代码的人会困惑），
## enemy.attack.cooldown_seconds 是小数（存成 int 就把 0.35 秒存成 0 了）。
func _typed(entry: Dictionary, v: float) -> Variant:
	var base = Config.get_base_value(str(entry["path"]), null)
	if typeof(base) == TYPE_INT:
		return roundi(v)
	return v


func _commit(entry: Dictionary, value: Variant) -> void:
	var path := str(entry.get("path", ""))
	if path == "":
		return
	# 只暂存，不落盘、不即时生效；点「确认应用」才写进 user://settings.json 并 apply。
	_pending_set[path] = value
	_pending_clear.erase(path)
	_update_footer()


# ------------------------------------------------------------
# 暂存 / 生效辅助
# ------------------------------------------------------------

## 横向弹性空隙：把后面的控件推到右边（两边对齐）。
func _expander() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## 某项当前应显示的值：暂存清除→出厂值；暂存写入→暂存值；否则走 Config 合并值。
func _eff(path: String):
	if _pending_clear.has(path):
		return Config.get_base_value(path, null)
	if _pending_set.has(path):
		return _pending_set[path]
	return Config.get_value(path, null)


func _is_dirty(path: String) -> bool:
	return _pending_set.has(path) or _pending_clear.has(path)


func _any_dirty() -> bool:
	return _pending_set.size() > 0 or _pending_clear.size() > 0


func _update_footer() -> void:
	if _confirm_btn != null:
		_confirm_btn.disabled = not _any_dirty()
	if _dirty_label != null:
		var n := _pending_set.size() + _pending_clear.size()
		_dirty_label.text = (tr("%d 处未确认") % n) if n > 0 else ""


## 确认应用：把暂存批量落盘 + 存盘 + 生效，然后关闭面板。
func _on_confirm() -> void:
	if not _any_dirty():
		return
	for p in _pending_set.keys():
		Config.set_user_value(p, _pending_set[p], false)
	for p in _pending_clear.keys():
		Config.clear_user_setting(p, false)
	Config.save_user_settings()
	_pending_set.clear()
	_pending_clear.clear()
	DisplaySettings.apply_all()
	_update_footer()
	close_requested.emit()


## 返回：有未确认改动先确认是否放弃，否则直接关。
func _on_back() -> void:
	if _any_dirty():
		_confirm("放弃未确认的修改？",
				tr("你有 %d 处改动还没点「确认应用」。\n返回会丢弃这些改动。确定返回？") % (_pending_set.size() + _pending_clear.size()),
				"放弃并返回", func():
					_pending_set.clear()
					_pending_clear.clear()
					close_requested.emit())
		return
	close_requested.emit()


func _on_reset_all() -> void:
	_confirm("恢复默认设置",
			"将清空 user://settings.json 里全部自定义项，\n所有参数回到 Data/config/ 的出厂值。确定吗？",
			"恢复默认", func():
				Config.reset_user_settings()
				_pending_set.clear()
				_pending_clear.clear()
				DisplaySettings.apply_all()
				_show_tab(_active))


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


# ------------------------------------------------------------
# 改键
# ------------------------------------------------------------

func _begin_key_capture(path: String, btn: Button) -> void:
	if _awaiting_path != "":
		return
	_awaiting_path = path
	_awaiting_button = btn
	btn.text = "按任意键…（ESC 取消）"


func _input(event: InputEvent) -> void:
	if _awaiting_path == "":
		return
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	# 按下与抬起都吃掉，免得同一个键被下游（菜单 ESC / 游戏内快捷键）再处理一次
	get_viewport().set_input_as_handled()
	if not k.pressed:
		return
	if k.physical_keycode == KEY_ESCAPE:
		_cancel_key_capture()
		return
	# 与消费端一致：存 physical_keycode（先暂存，点确认才落盘）
	_pending_set[_awaiting_path] = int(k.physical_keycode)
	_pending_clear.erase(_awaiting_path)
	if _awaiting_button != null and is_instance_valid(_awaiting_button):
		_awaiting_button.text = UiKit.key_name(int(k.physical_keycode))
	_awaiting_path = ""
	_awaiting_button = null
	_update_footer()
	_show_tab(_active)


func _cancel_key_capture() -> void:
	if _awaiting_button != null and is_instance_valid(_awaiting_button):
		_awaiting_button.text = UiKit.key_name(
				int(_eff(_awaiting_path)))
	_awaiting_path = ""
	_awaiting_button = null


# ------------------------------------------------------------
# 枚举辅助
# ------------------------------------------------------------

func _enum_items(entry: Dictionary) -> Array:
	var items = entry.get("items", [])
	if items is Callable:
		return items.call()
	return items


func _enum_labels(entry: Dictionary) -> Array:
	var out: Array = []
	for it in _enum_items(entry):
		out.append(str(it[0]))
	return out


func _enum_value(entry: Dictionary, index: int) -> Variant:
	var items := _enum_items(entry)
	if index < 0 or index >= items.size():
		return null
	return items[index][1]


func _enum_index(entry: Dictionary) -> int:
	var cur = _eff(str(entry["path"]))
	var items := _enum_items(entry)
	for i in range(items.size()):
		if _same(items[i][1], cur):
			return i
	return 0


## 宽松比较：config 里 2 与用户层读回来的 2.0 要算同一个；
## 分辨率那种数组值则按字符串比（Array 的 == 在 GDScript 里是逐元素比，
## 但 int/float 混着来仍会不等，所以统一走 str）。
func _same(a, b) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	return str(a) == str(b)


# ------------------------------------------------------------
# 表：所有可调参数
# ------------------------------------------------------------

func _make_schema() -> Array:
	return [
		{"name": "画面", "entries": _schema_display()},
		{"name": "性能", "entries": _schema_performance()},
		{"name": "音频", "entries": _schema_audio()},
		{"name": "玩法", "entries": _schema_gameplay()},
		{"name": "资源", "entries": _schema_resources()},
		{"name": "操作", "entries": _schema_controls()},
		{"name": "语言", "entries": _schema_language()},
		{"name": "调试", "entries": _schema_debug()},
	]


func _schema_display() -> Array:
	return [
		{"type": "divider", "label": "窗口"},
		{"path": "display.window_mode", "label": "窗口模式", "type": "enum", "live": true,
			"items": [["窗口化", "windowed"], ["全屏", "fullscreen"], ["无边框", "borderless"]],
			"note": "无边框 = 铺满屏幕且没有标题栏。全屏/无边框下分辨率设置不生效。"},
		{"path": "display.resolution", "label": "分辨率", "type": "enum", "live": true,
			"items": [["1280 × 720", [1280, 720]], ["1600 × 900", [1600, 900]],
				["1920 × 1080", [1920, 1080]], ["2560 × 1440", [2560, 1440]],
				["3840 × 2160", [3840, 2160]]],
			"note": "仅「窗口化」模式下生效。"},
		{"path": "display.vsync", "label": "垂直同步", "type": "enum", "live": true,
			"items": [["关闭", "disabled"], ["开启", "enabled"], ["自适应", "adaptive"]],
			"note": "撕裂就开，输入延迟高就关。上限与「帧率上限」冲突时取较小者。"},
		{"path": "display.max_fps", "label": "帧率上限", "type": "enum", "live": true,
			"items": [["不限（默认）", 0], ["30", 30], ["60", 60], ["75", 75], ["90", 90],
				["120", 120], ["144", 144], ["165", 165], ["240", 240]],
			"note": "默认「不限」。笔记本想降温省电选 60。改成下拉是为了不再出现「拖到 1 帧把游戏卡死」的情况。上限与垂直同步冲突时取较小者。"},

		{"type": "divider", "label": "画面缩放"},
		{"path": "display.stretch_mode", "label": "缩放模式", "type": "enum", "live": true,
			"items": [["不缩放（1:1）", "disabled"], ["等比放大（UI 清晰）", "canvas_items"],
				["整张放大（像素锐利）", "viewport"]],
			"note": "把 1920×1080 的设计分辨率映射到实际窗口。像素画想要锐利选「整张放大」，"
				+ "UI 文字要清晰选「等比放大」。改完立刻生效。"},
		{"path": "display.stretch_aspect", "label": "宽高比策略", "type": "enum", "live": true,
			"items": [["保留黑边", "keep"], ["多露出画面", "expand"], ["拉伸变形", "ignore"],
				["锁宽度", "keep_width"], ["锁高度", "keep_height"]],
			"note": "窗口不是 16:9 时怎么补。只在「缩放模式」不是「不缩放」时有意义。"},

		{"type": "divider", "label": "相机"},
		{"path": "camera.pan_speed", "label": "相机平移速度", "type": "number",
			"min": 200, "max": 4000, "step": 50,
			"note": "WASD 与边缘滚屏共用的速度基准（像素/秒）。下次进局生效。"},

		{"type": "divider", "label": "边缘滚屏"},
		{"path": "camera.edge_pan_enabled", "label": "启用边缘滚屏", "type": "bool",
			"note": "鼠标贴到窗口边，画面就往那个方向滚（RTS 手感）。窗口失去焦点时不滚。"},
		{"path": "camera.edge_pan_margin", "label": "触发边距", "type": "number",
			"min": 4, "max": 200, "step": 2, "fmt": "px",
			"note": "距窗口边缘多少像素内算「贴边」。开画面缩放时视口恒为 1920×1080，24 ≈ 短边 2.2%。"},
		{"path": "camera.edge_pan_speed_mult", "label": "滚屏速度倍率", "type": "number",
			"min": 0.1, "max": 4.0, "step": 0.1, "fmt": "times",
			"note": "相对「相机平移速度」的倍率，1.0 = 与按 WASD 同速。"},
		{"path": "camera.edge_pan_ignore_ui", "label": "悬停界面时不滚", "type": "bool",
			"note": "鼠标停在按钮/面板上时不滚，避免点界面顺手把画面带走。"},

		{"type": "divider", "label": "滚轮缩放"},
		{"path": "camera.zoom_min", "label": "最小放大倍数", "type": "number",
			"min": 0.1, "max": 1.0, "step": 0.05, "fmt": "times",
			"note": "缩到最远时的倍数（0.35 ≈ 视野宽 2.9 倍）。实际下限还会按地图/窗口尺寸收敛，保证整张地图能装下。"},
		{"path": "camera.zoom_max", "label": "最大放大倍数", "type": "number",
			"min": 1.0, "max": 6.0, "step": 0.1, "fmt": "times",
			"note": "推到最近时的倍数。"},
		{"path": "camera.zoom_step", "label": "每档步长", "type": "number",
			"min": 0.02, "max": 0.4, "step": 0.01, "fmt": "percent",
			"note": "滚一格缩放多少。进/出互为倒数，来回滚不会漂移。下次进局生效。"},
		{"path": "camera.zoom_smooth", "label": "缩放平滑速度", "type": "number",
			"min": 0.0, "max": 30.0, "step": 1.0,
			"note": "越大越跟手；0 = 滚一档立刻到位。"},
		{"path": "camera.zoom_at_cursor", "label": "以光标为锚点缩放", "type": "bool",
			"note": "开：朝鼠标指的位置放大；关：以屏幕中心缩放。"},
		{"path": "camera.zoom_invert", "label": "滚轮方向反向", "type": "bool"},
		{"path": "camera.zoom_fit_bounds", "label": "缩到底时整图入画", "type": "bool",
			"note": "按窗口与地图尺寸收紧缩放下限，避免缩出一片白边。"},
		{"path": "camera.zoom_hud", "label": "显示视野倍数提示", "type": "bool",
			"note": "滚轮时右下角淡入的「视野 ×N」，松手 1.5 秒后自动淡出。"},

		{"path": "player.weapon", "label": "当前武器", "type": "enum",
			"items": [["剑士（剑·近战）", "sword"], ["枪手（长枪·近战）", "spear"],
				["弓兵（弓·远程）", "bow"]],
			"note": "决定攻击方式与动作：剑士 = 原来的扇形挥击（战士贴图）；枪手 = 长枪突刺（枪兵 8 向贴图，射程更长）；"
				+ "弓 = 判定帧发射箭矢（会飞、撞墙消失、命中结算），并且强制使用弓兵贴图集。"
				+ "下次进局生效。"},

		{"path": "player.sprite_set", "label": "玩家贴图集（近战用）", "type": "enum",
			"items": [["枪手 8 向", "sprites_lancer"], ["弓兵 单向", "sprites_archer"],
				["剑士 单向", "sprites_ts"], ["HD 手绘", "sprites_hd"], ["早期 48px", "sprites"]],
			"note": "只有「枪手」有真正的 8 向素材：待机/受击按朝向播不同帧，攻击也按朝向出招；"
				+ "其余四套是单向或仅四向，斜向与朝向差异会自动回退。"
				+ "画布参数（缩放/脚底偏移）已随贴图集自动切换，不用手调。"
				+ "当前武器是「弓」时本项无效（弓锁定弓手贴图）。下次进局生效。"},

		{"type": "divider", "label": "局内界面（下次进局生效）"},
		{"path": "menu_bar.enabled", "label": "底部菜单栏", "type": "bool",
			"note": "局内最下面 1/5 那条栏：左 = 小地图（常驻）、中 = 选中单位的指令、"
				+ "右 = 噪音读数（当前/累积/被惊动数）。关掉后小地图与指令入口都不显示 —— "
				+ "自动战斗照常跑，只是没有手动指令（指定攻击 / 巡逻 / 索敌策略）。"},
		{"path": "menu_bar.height_ratio", "label": "菜单栏高度占比", "type": "number",
			"min": 0.12, "max": 0.3, "step": 0.01, "fmt": "percent",
			"note": "占屏幕高度的比例，默认 20%（= 最下面 1/5）。小地图边长随栏高自适应，"
				+ "HUD 的背包/血量/生存三行也会跟着让位。"},

		{"type": "divider", "label": "风格化（下次生成地图生效）"},
		{"path": "map.macro_light.enabled", "label": "宏观明暗层", "type": "bool",
			"note": "整图叠一层大尺度明暗。关掉画面更平，但能确认地形问题不是它造成的。"},
		{"path": "map.macro_light.strength", "label": "明暗强度", "type": "number",
			"min": 0.0, "max": 0.4, "step": 0.01},
		{"path": "map.grade.enabled", "label": "画面调色", "type": "bool",
			"note": "整图对比度/亮度/饱和度的后处理。"},
		{"path": "map.grade.contrast", "label": "对比度", "type": "number",
			"min": 0.5, "max": 2.0, "step": 0.02, "fmt": "times"},
		{"path": "map.grade.brightness", "label": "亮度", "type": "number",
			"min": -0.3, "max": 0.3, "step": 0.01},
		{"path": "map.grade.saturation", "label": "饱和度", "type": "number",
			"min": 0.0, "max": 2.0, "step": 0.02, "fmt": "times"},
	]


## 「性能优先」预设一次性写入的一组用户层覆盖（键 → 流畅档取值）。
## 只写用户层，不碰 Data/config/；「恢复均衡」逐项清掉即回到出厂值。
const _PERF_BUNDLE: Dictionary = {
	"map.decor.shadow": false,
	"map.decor.density": 0.6,
	"map.macro_light.enabled": false,
	"map.grade.enabled": false,
	"player.vision_radius_cells": 8,
	"enemy.ai_active_radius_cells": 16,
	"enemy.los_step_cells": 0.6,
	"enemy.count": 60,
	"animals.count": 30,
	"loot.density": 0.02,
	"display.max_fps": 60,
}


func _schema_performance() -> Array:
	return [
		{"type": "info", "label": "这一页是「降配提速」的开关。生效时机各不同：AI 活跃半径、视线步长每帧读取，"
			+ "改完下一帧即见效；视野半径、资源点/装饰/敌人数量、投影、明暗调色要在设置里改完后重新进一局 / 重新生成地图才读到。"},

		{"type": "divider", "label": "一键预设（只写用户层，可随时用「恢复均衡」或底部「恢复默认」撤销）"},
		{"type": "action", "label": "性能优先", "button": "应用 · 降配流畅",
			"handler": Callable(self, "_apply_perf_preset"),
			"note": "把资源点/装饰/敌人数量与视野等一次性降到流畅档。开局明显掉帧时用；会改变本局体感，但不动出厂配置。"},
		{"type": "action", "label": "恢复均衡", "button": "清除降配",
			"handler": Callable(self, "_clear_perf_preset"),
			"note": "清掉「性能优先」写下的全部用户层覆盖，回到 Data/config/ 的出厂值。"},

		{"type": "divider", "label": "AI 开销（每帧读取 · 即时生效）"},
		{"path": "enemy.ai_active_radius_cells", "label": "敌人 AI 活跃半径（格）", "type": "number",
			"min": 8, "max": 48, "step": 1,
			"note": "超出此半径的敌人休眠，不跑状态机与视线检测 —— 地图大、敌人多时最省 CPU 的一档（默认 32）。调小远处敌人反应会变迟钝。"},
		{"path": "enemy.los_step_cells", "label": "视线采样步长（格）", "type": "number",
			"min": 0.2, "max": 1.5, "step": 0.05,
			"note": "敌人判断能否看见玩家时，沿视线每隔多远采一个墙格。越大越省、越粗糙（默认 0.35）。墙后视野判定会变松。"},

		{"type": "divider", "label": "视野与迷雾（下次进局生效）"},
		{"path": "player.vision_radius_cells", "label": "玩家视野半径（格）", "type": "number",
			"min": 5, "max": 20, "step": 1,
			"note": "迷雾揭示半径，也是敌人 / 资源点的可见范围。每帧揭示面积随半径平方增长，调小可减负，但缩短可视距离（默认 10，硬核向不建议太小）。"},

		{"type": "divider", "label": "地图生成开销（下次生成地图生效）"},
		{"path": "map.decor.shadow", "label": "装饰投影", "type": "bool",
			"note": "关掉后每棵树 / 石少画一个投影 Sprite2D，装饰密的地图能明显减负（默认开）。"},
		{"type": "info", "label": "更多降配项已在各页：资源点密度、敌人 / 中立数量、装饰密度在「玩法」页；"
			+ "宏观明暗层、画面调色、帧率上限、垂直同步在「画面」页顶部。"},
	]


func _apply_perf_preset() -> void:
	for k in _PERF_BUNDLE.keys():
		_pending_set[k] = _PERF_BUNDLE[k]
		_pending_clear.erase(k)
	_show_tab(_active)


func _clear_perf_preset() -> void:
	for k in _PERF_BUNDLE.keys():
		_pending_clear[k] = true
		_pending_set.erase(k)
	_show_tab(_active)


func _schema_audio() -> Array:
	return [
		{"type": "info", "label": "项目目前还没有接入音频资源，这几项属于提前把线接好："
			+ "改动会即时作用到对应的 AudioBus（Music / SFX 总线不存在时自动创建）。"},
		{"path": "audio.master", "label": "主音量", "type": "number", "live": true,
			"min": 0.0, "max": 1.0, "step": 0.05, "fmt": "percent"},
		{"path": "audio.music", "label": "音乐", "type": "number", "live": true,
			"min": 0.0, "max": 1.0, "step": 0.05, "fmt": "percent"},
		{"path": "audio.sfx", "label": "音效", "type": "number", "live": true,
			"min": 0.0, "max": 1.0, "step": 0.05, "fmt": "percent"},
		{"path": "audio.mute", "label": "静音", "type": "bool", "live": true,
			"note": "一键静音，不改上面三个滑块的值。"},
	]


func _schema_gameplay() -> Array:
	return [
		{"type": "info", "label": "这一页全部是「下次进局」才读到的键 —— 改完请重新进一局。"},
		{"type": "divider", "label": "地图生成"},
		{"path": "map.width", "label": "地图宽（格）", "type": "number",
			"min": 64, "max": 256, "step": 8, "note": "128 格 = 8192 像素见方。"},
		{"path": "map.height", "label": "地图高（格）", "type": "number",
			"min": 64, "max": 256, "step": 8},
		{"path": "map.force_seed", "label": "固定种子", "type": "number",
			"min": 0, "max": 999999, "step": 1,
			"note": "0 = 每局随机；非 0 = 每局同一张图（复现 bug 用）。"},
		{"path": "map.crack.enabled", "label": "地表裂缝", "type": "bool"},
		{"path": "map.decor.density", "label": "装饰密度", "type": "number",
			"min": 0.0, "max": 2.0, "step": 0.05, "fmt": "times",
			"note": "树/石/灌木/碎石的总体倍率。"},
		{"path": "map.decor_collision.enabled", "label": "装饰碰撞", "type": "bool",
			"note": "关掉后树石不再挡路（排查「卡住」时用来二分）。"},
		{"path": "map.min_reachable_ratio", "label": "最低可达率", "type": "number",
			"min": 0.1, "max": 1.0, "step": 0.05, "fmt": "percent",
			"note": "低于这个连通率就换种子重新生成整张图。"},

		{"type": "divider", "label": "局内节奏"},
		{"path": "session.time_limit_seconds", "label": "局内时长", "type": "number",
			"min": 300, "max": 7200, "step": 60, "fmt": "duration"},
		{"path": "extraction.count", "label": "撤离点数量", "type": "number",
			"min": 1, "max": 8, "step": 1},
		{"path": "enemy.count", "label": "敌人数量", "type": "number",
			"min": 0, "max": 300, "step": 5},
		{"path": "animals.count", "label": "中立生物数量", "type": "number",
			"min": 0, "max": 200, "step": 5, "note": "野羊，打死掉食物。"},
		{"path": "loot.density", "label": "资源点密度", "type": "number",
			"min": 0.0, "max": 0.3, "step": 0.005, "fmt": "percent",
			"note": "地上可拾取资源点的占比。调高会明显增加地图负担。"},
		{"path": "survival.meal_interval_seconds", "label": "物资消耗间隔", "type": "number",
			"min": 10, "max": 600, "step": 10, "fmt": "duration",
			"note": "每过这么久按 survival.supplies 逐项扣一次物资。"
				+ "缺哪种就按配置降哪种属性，补上立刻还原（不会把人耗死）。"},

		{"type": "divider", "label": "玩家与战斗"},
		{"path": "combat.auto_attack.enabled", "label": "自动战斗", "type": "bool",
			"note": "开启后角色自动索敌开打：只打「观察视野 ∩ 攻击距离」内的敌人，"
				+ "够不着的不追、原地不动；关掉则完全不开火（只能靠走位）。"},
		{"path": "player.vision_radius_cells", "label": "观察视野（格）", "type": "number",
			"min": 1, "max": 40, "step": 1,
			"note": "能看见多远。实际攻击距离取「武器射程与观察视野的较小值」，"
				+ "所以调小它等于同时削所有武器的射程；设计上应大于攻击距离。"},
		{"path": "combat.auto_attack.scan_interval_seconds", "label": "索敌间隔", "type": "number",
			"min": 0.05, "max": 1.0, "step": 0.05, "fmt": "times",
			"note": "每隔多久重扫一次附近敌人（秒）。越小索敌越灵敏、开销越大。"},
		{"path": "player.speed", "label": "移动速度", "type": "number",
			"min": 100, "max": 2000, "step": 20, "note": "像素/秒。"},
		{"path": "combat.player.max_hp", "label": "基础生命上限", "type": "number",
			"min": 20, "max": 500, "step": 10,
			"note": "实际生命上限还要加上局外养成（雕像升级）。"},
		{"path": "combat.weapons.sword.damage", "label": "近战攻击伤害", "type": "number",
			"min": 1, "max": 200, "step": 1,
			"note": "剑等近战武器的单次伤害。已按武器拆开 —— 原来那个全局的 "
				+ "combat.attack.damage 现在只是「武器表没写时才用」的兜底值，改它不再生效。"},
		{"path": "combat.weapons.bow.damage", "label": "弓箭伤害", "type": "number",
			"min": 1, "max": 200, "step": 1,
			"note": "每支箭的伤害。敌人默认 40 生命，20 伤害 = 两箭一只。"},
		{"path": "combat.dodge.cooldown_seconds", "label": "闪避冷却", "type": "number",
			"min": 0.0, "max": 3.0, "step": 0.05},

		{"type": "divider", "label": "敌人"},
		{"path": "enemy.speed", "label": "基础速度", "type": "number",
			"min": 100, "max": 800, "step": 20, "note": "像素/秒；追击时还会乘倍率。"},
		{"path": "enemy.max_hp", "label": "基础生命", "type": "number",
			"min": 10, "max": 500, "step": 10},
		{"path": "enemy.contact_damage", "label": "近战伤害", "type": "number",
			"min": 1, "max": 100, "step": 1,
			"note": "敌人一刀的基础伤害；兵种在 enemy_types 里写的 damage 会盖掉它。"},
		{"path": "enemy.attack.range_px", "label": "近战射程", "type": "number",
			"min": 30, "max": 200, "step": 2,
			"note": "与玩家的圆心距小于这个数才挥砍。必须「大于」单位分离把敌人顶住的那圈（敌人半径 + 玩家半径，默认 42px），否则敌人永远够不着玩家（2026-09-19 那个「敌人不打人」的 bug 就是这两个数没对上）。兵种可用 attack_range_px 单独覆盖。改完对「新刷出」的敌人生效。"},
		{"path": "enemy.attack.cooldown_seconds", "label": "出手间隔", "type": "number",
			"min": 0.2, "max": 5.0, "step": 0.1,
			"note": "两刀之间的间隔秒数。只要挥了就进冷却 —— 被玩家挡下或挥空都不回收。"},
		{"path": "enemy.vision_cells", "label": "视野（格）", "type": "number",
			"min": 2, "max": 30, "step": 1},
	]


## 比例条拖动 → 把四段新权重写进暂存（对应 map.biome_weights.0~3），刷新页脚。
func _stage_ratio(paths: Array, new_vals: Array) -> void:
	for i in range(paths.size()):
		if i < new_vals.size():
			var p := str(paths[i])
			_pending_set[p] = float(new_vals[i])
			_pending_clear.erase(p)
	_update_footer()


func _stage_bounds(min_paths: Array, max_paths: Array, mins: Array, maxs: Array) -> void:
	for i in range(min_paths.size()):
		if i < mins.size():
			var pm := str(min_paths[i])
			_pending_set[pm] = float(mins[i])
			_pending_clear.erase(pm)
	for i in range(max_paths.size()):
		if i < maxs.size():
			var px := str(max_paths[i])
			_pending_set[px] = float(maxs[i])
			_pending_clear.erase(px)
	_update_footer()


func _biome_bar_labels(n: int) -> Array:
	var out: Array = []
	var biomes: Array = Config.get_value("map.biomes", [])
	for i in range(n):
		if i < biomes.size() and biomes[i] is Dictionary:
			out.append(str((biomes[i] as Dictionary).get("name", "地形%d" % i)))
		else:
			out.append("地形%d" % i)
	return out


func _biome_bar_colors(n: int) -> Array:
	var out: Array = []
	var biomes: Array = Config.get_value("map.biomes", [])
	for i in range(n):
		var c := Color(0.5, 0.5, 0.5)
		if i < biomes.size() and biomes[i] is Dictionary:
			var f = (biomes[i] as Dictionary).get("floor", null)
			if f is Array and (f as Array).size() >= 3:
				c = Color(float(f[0]), float(f[1]), float(f[2]))
		out.append(c.lightened(0.25))   # 提亮，深色面板上更好分辨
	return out


func _schema_resources() -> Array:
	var out: Array = []
	out.append({"type": "divider", "label": "地形出现比例（面积∝此值）"})
	out.append({"type": "ratio_bar", "label": "地形占比",
		"paths": ["map.biome_weights.0", "map.biome_weights.1", "map.biome_weights.2", "map.biome_weights.3"],
		"min_paths": ["map.biome_min_pct.0", "map.biome_min_pct.1", "map.biome_min_pct.2", "map.biome_min_pct.3"],
		"max_paths": ["map.biome_max_pct.0", "map.biome_max_pct.1", "map.biome_max_pct.2", "map.biome_max_pct.3"],
		"note": "拖白色分界线自由改地形占比（相邻两段此消彼长、总长恒 100%，段内实时显示各地形百分比）；拖每段两侧的橙色 | | 改该地形的占比下限 / 上限——这里的百分比是「占这段地形自身宽度」的比例，两个把手只能在 10%~30% 之间拖、拖不出这个范围，也不会跑到别的地形，把手上方标出各自的百分比。下次生成地图生效。"})
	out.append({"path": "map.biome_min_region_cells", "label": "最小地块尺寸（格）", "type": "number",
		"min": 0, "max": 200, "step": 5,
		"note": "小于此格数的独立地形块会被并入周围地形（去掉过小的碎地块/被夹的小地块）；0 = 不去小地块。下次生成地图生效。"})
	out.append({"type": "divider", "label": "群系边界混合"})
	out.append({"type": "info", "label": "两个群系之间原本是一条 1 格宽的直角阶梯硬线（边界两侧什么都没画）。"
		+ "开启后在边界两侧各铺 radius 格的「抖动带」：把对面群系的同一块地形按 1-bit 网点盖上来，"
		+ "近看是细密网点、拉远（滚轮缩小）就被平均成一条柔和过渡。只改观感，碰撞/寻路/移速一律不动。下次生成地图生效。"})
	out.append({"path": "map.biome_blend.enabled", "label": "启用边界混合", "type": "bool"})
	out.append({"path": "map.biome_blend.radius_cells", "label": "混合带宽（格）", "type": "number",
		"min": 1, "max": 4, "step": 1,
		"note": "边界每侧铺几格。1 = 只化开一条紧贴原边界的窄带（推荐）；调到 3~4 群系区域会开始糊成一团、认不出边界。"})
	out.append({"path": "map.biome_blend.dither", "label": "网点大小（像素）", "type": "enum",
		"items": [["4", 4], ["8（推荐）", 8], ["16", 16]],
		"note": "Bayer 网点周期。越小过渡越细，但满铺整张地面都会起网点；必须整除瓦片边长（64），否则相邻瓦片的网点对不上。"})
	out.append({"type": "divider", "label": "地图资源成簇（树/石/铁/油）"})
	out.append({"type": "info", "label": "全图一共放「总簇数」个簇，按各类型 share 比例分给树/石/铁/油；"
		+ "每种类型的簇再按其 biome_weight 分到各群系；每簇大小在 [最小, 最大] 随机（最小调大即避免过小孤簇）。全部下次生成地图才生效。"})
	out.append({"path": "map.resource_clusters.total", "label": "总簇数（全图）", "type": "number",
		"min": 0, "max": 400, "step": 5, "note": "所有类型加起来一共放多少个簇。"})
	var biome_cols: Array = [["草地", "0"], ["荒原", "1"], ["森林", "2"], ["沼泽", "3"]]
	var res_defs: Array = [["tree", "树木"], ["rock", "石头"], ["iron", "钢铁"], ["oil", "魔法油潭"]]
	for rd in res_defs:
		var key: String = str(rd[0])
		out.append({"type": "divider", "label": str(rd[1])})
		out.append({"path": "map.resource_clusters.types.%s.share" % key, "label": "占总数比例", "type": "number",
			"min": 0, "max": 100, "step": 1, "note": "该类型分到总簇数的相对份额（四类型之和不必为100）。"})
		out.append({"path": "map.resource_clusters.types.%s.min_size" % key, "label": "每簇最小格数", "type": "number",
			"min": 1, "max": 24, "step": 1})
		out.append({"path": "map.resource_clusters.types.%s.max_size" % key, "label": "每簇最大格数", "type": "number",
			"min": 1, "max": 40, "step": 1})
		for bc in biome_cols:
			out.append({"path": "map.resource_clusters.types.%s.biome_weight.%s" % [key, str(bc[1])],
				"label": "  %s（分布比例）" % str(bc[0]), "type": "number",
				"min": 0, "max": 12, "step": 1})
	return out


func _schema_controls() -> Array:
	return [
		{"type": "info", "label": "键位一律用「物理键码」记录（与游戏内消费端一致），"
			+ "所以非 QWERTY 键盘也不会错位。点按钮后按任意键即可改；ESC 取消。"},
		{"type": "info", "label": "攻击没有键位 —— 2026-09-17 起战斗全自动："
			+ "敌人进入「观察视野 ∩ 攻击距离」就自动起手，够不着的不会追。想关掉去「玩法」页的自动战斗开关。"},
		{"type": "divider", "label": "动作"},
		{"path": "combat.input.dodge_key", "label": "闪避", "type": "key"},
		{"path": "survival.eat_key", "label": "进食", "type": "key"},
		{"path": "camera.return_key", "label": "相机回到玩家", "type": "key"},
	]


func _schema_language() -> Array:
	return [
		{"type": "info", "label": "语言已接入 i18n：菜单与各面板支持简体中文 / English，下拉选择后点「确认应用」整体切换。"},
		{"path": "language.current", "label": "界面语言", "type": "enum", "live": true,
			"items": _language_items(),
			"note": "确认应用后界面文字整体切换；数据存进 user://settings.json。"},
		{"type": "divider", "label": "如何新增语言"},
		{"type": "info", "label": "1. 在 Data/language/translations.csv 加一列（表头写语言代码）；2. 在 Data/config/ 的 language.available 登记 code / name，ready 设为 true。"},
	]


## 语言下拉的项直接从 config.language.available 生成，加语言不用改代码
func _language_items() -> Array:
	var out: Array = []
	var avail: Array = Config.get_value("language.available", [])
	for lang in avail:
		if not (lang is Dictionary):
			continue
		var label := str(lang.get("name", lang.get("code", "?")))
		if not bool(lang.get("ready", false)):
			label += "（未接线）"
		out.append([label, str(lang.get("code", ""))])
	if out.is_empty():
		out.append(["简体中文", "zh_CN"])
	return out


func _schema_debug() -> Array:
	return [
		{"type": "info", "label": "调试项：影响的是开发期行为，不是游戏平衡。发布前建议恢复默认。"},
		{"path": "debug.time_scale", "label": "局内时间流速", "type": "number",
			"min": 1.0, "max": 50.0, "step": 1.0, "fmt": "times",
			"note": "放大后倒计时/饥饿/撤离点调度都跟着加速，但玩家移动速度不变 —— 用来快速过一遍长局。"},
		{"path": "debug.log_state_transitions", "label": "打印状态机切换", "type": "bool",
			"note": "刷日志，排查 AI/动画问题时开。"},
		{"path": "debug.auto_enter_run", "label": "跳过基地直接进局", "type": "bool",
			"note": "给无头回归用的。注意：从菜单点进游戏时会被临时压掉（菜单要落在基地），所以在菜单里改这项不影响菜单启动。"},
		{"type": "divider", "label": "文件位置"},
		{"type": "info", "label": "用户设置（本页改的所有值）：user://settings.json\n"
			+ "存档槽：user://saves/slot_NN.json\n"
			+ "旧版单槽存档：user://save.json（未删，仍被不用菜单的入口读取）"},
	]

extends Control
## ============================================================
## SettingsPanel — 参数配置面板（开始菜单 → 参数配置）
##
## 分页：画面 / 音频 / 玩法 / 操作 / 语言 / 调试
## 表驱动：所有条目写在 _make_schema() 里，每项一行，加参数只改那张表。
##
## 值怎么存：写进 Config 的**用户层** → user://settings.json。
## 不去改 Data/config.json —— 导出后 res:// 只读，而且会和版本管理打架。
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

## 打开时默认停在第几页（截图验证用；正常进入是 0 = 画面）
var initial_tab := 0

var _tab_bar: HBoxContainer
var _content: VBoxContainer
var _tabs: Array = []
var _active := 0

# 改键状态
var _awaiting_path := ""
var _awaiting_button: Button = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
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

	var center := CenterContainer.new()
	UiKit.stretch(center)
	add_child(center)

	var panel := UiKit.panel(UiKit.COL_PANEL, 20)
	panel.custom_minimum_size = Vector2(940, 620)
	center.add_child(panel)

	var col := UiKit.vbox(10)
	panel.add_child(col)

	col.add_child(UiKit.title("参数配置"))

	var sub := UiKit.dim("改动即时保存 · 标「下次进局」的项要重新进一局才读到")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(sub)

	# --- 分页按钮 ---
	var bar_wrap := CenterContainer.new()
	col.add_child(bar_wrap)
	_tab_bar = UiKit.hbox(6)
	bar_wrap.add_child(_tab_bar)

	var group := ButtonGroup.new()
	for i in range(_tabs.size()):
		var b := UiKit.button(str(_tabs[i]["name"]), 0, UiKit.FS_BODY)
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(110, 34)
		# 没有这一步的话首屏所有页签都是"未选中"外观，看不出当前在哪一页
		if i == initial_tab:
			b.button_pressed = true
		b.pressed.connect(_show_tab.bind(i))
		_tab_bar.add_child(b)

	col.add_child(UiKit.spacer(4))

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 400)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)

	_content = UiKit.vbox(10)
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content)

	col.add_child(UiKit.spacer(4))

	# --- 底部 ---
	var footer := UiKit.hbox(10)
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(footer)

	var reset := UiKit.button("恢复默认设置", 0, UiKit.FS_SMALL)
	reset.pressed.connect(_on_reset_all)
	footer.add_child(reset)

	var open_file := UiKit.button("打开设置文件所在目录", 0, UiKit.FS_SMALL)
	open_file.pressed.connect(func():
		OS.shell_open(ProjectSettings.globalize_path("user://")))
	footer.add_child(open_file)

	var back := UiKit.button("返回", 120)
	back.pressed.connect(func(): close_requested.emit())
	footer.add_child(back)


func _show_tab(index: int) -> void:
	_active = clampi(index, 0, _tabs.size() - 1)
	for c in _content.get_children():
		c.queue_free()
	for entry in _tabs[_active]["entries"]:
		_content.add_child(_make_entry(entry))


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
		l.custom_minimum_size = Vector2(840, 0)
		return l

	var box := UiKit.vbox(2)
	# 用 get 而不是 []：action 之类没有对应配置键的条目没有 path
	var path := str(entry.get("path", ""))

	var row := UiKit.hbox(10)
	box.add_child(row)

	var name_label := UiKit.label(str(entry["label"]), UiKit.FS_BODY)
	name_label.custom_minimum_size = Vector2(200, 0)
	row.add_child(name_label)

	match kind:
		"bool":
			var cb := UiKit.checkbox("", bool(Config.get_value(path, false)))
			cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cb.toggled.connect(func(v: bool): _commit(entry, v))
			row.add_child(cb)
		"number":
			row.add_child(_make_number(entry))
		"enum":
			var o := UiKit.option(_enum_labels(entry), _enum_index(entry), 220)
			o.item_selected.connect(func(i: int): _commit(entry, _enum_value(entry, i)))
			row.add_child(o)
		"key":
			var b := UiKit.button(UiKit.key_name(int(Config.get_value(path, 0))), 160)
			b.pressed.connect(func(): _begin_key_capture(path, b))
			row.add_child(b)
		"action":
			var b := UiKit.button(str(entry.get("button", "执行")), 160)
			if entry.get("handler") is Callable:
				b.pressed.connect(entry["handler"])
			row.add_child(b)

	# 只有真的"有值可重置"的类型才挂 ↺
	if kind in ["bool", "number", "enum", "key"]:
		row.add_child(_make_reset_button(entry))
	if path != "" and Config.has_user_value(path):
		var badge := UiKit.label("已改", UiKit.FS_SMALL, UiKit.COL_AMBER)
		badge.custom_minimum_size = Vector2(38, 0)
		row.add_child(badge)

	if str(entry.get("note", "")) != "":
		var note := UiKit.note(str(entry["note"]))
		note.custom_minimum_size = Vector2(840, 0)
		box.add_child(note)

	return box


## 数值行：滑块 + 实时数值 + 单位说明
func _make_number(entry: Dictionary) -> HBoxContainer:
	var path := str(entry["path"])
	var step := float(entry.get("step", 1.0))
	var cur := float(Config.get_value(path, entry.get("min", 0.0)))
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
	var b := UiKit.button("默认", 60, UiKit.FS_SMALL)
	b.tooltip_text = "把这一项恢复成出厂值"
	b.disabled = not Config.has_user_value(str(entry["path"]))
	b.pressed.connect(func():
		Config.clear_user_setting(str(entry["path"]))
		_after_change(entry)
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
## map.river.width_cells 是小数（存成 int 就把河宽精度丢了）。
func _typed(entry: Dictionary, v: float) -> Variant:
	var base = Config.get_base_value(str(entry["path"]), null)
	if typeof(base) == TYPE_INT:
		return roundi(v)
	return v


func _commit(entry: Dictionary, value: Variant) -> void:
	Config.set_user_value(str(entry["path"]), value)
	_after_change(entry)


## live=true 的项改完立刻作用到引擎（窗口模式、帧率、音量这些）
func _after_change(entry: Dictionary) -> void:
	if bool(entry.get("live", false)):
		DisplaySettings.apply_all()


func _on_reset_all() -> void:
	_confirm("恢复默认设置",
			"将清空 user://settings.json 里全部自定义项，\n所有参数回到 Data/config.json 的出厂值。确定吗？",
			"恢复默认", func():
				Config.reset_user_settings()
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
	# 与消费端一致：存 physical_keycode
	Config.set_user_value(_awaiting_path, int(k.physical_keycode))
	if _awaiting_button != null and is_instance_valid(_awaiting_button):
		_awaiting_button.text = UiKit.key_name(int(k.physical_keycode))
	_awaiting_path = ""
	_awaiting_button = null
	_show_tab(_active)


func _cancel_key_capture() -> void:
	if _awaiting_button != null and is_instance_valid(_awaiting_button):
		_awaiting_button.text = UiKit.key_name(
				int(Config.get_value(_awaiting_path, 0)))
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
	var cur = Config.get_value(str(entry["path"]), null)
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
			"items": [["剑（近战）", "sword"], ["弓（远程）", "bow"],
				["狙击枪（穿透）", "sniper"]],
			"note": "决定攻击方式与动作：剑 = 原来的扇形挥击；弓 = 判定帧发射箭矢（会飞、撞墙消失、命中结算）；"
				+ "狙击枪 = 瞬间命中 + 曳光，高伤穿透 2 个目标、射程 900，但前摇长、后摇长、枪声极大（240）。"
				+ "「弓」会强制使用弓手贴图集；「狙击枪」用挂点贴图（跟随瞄准方向旋转），角色贴图集不受影响。下次进局生效。"},

		{"path": "player.sprite_set", "label": "玩家贴图集（近战用）", "type": "enum",
			"items": [["枪兵 8 向", "sprites_lancer"], ["弓手 单向", "sprites_archer"],
				["战士 单向", "sprites_ts"], ["HD 手绘", "sprites_hd"], ["早期 48px", "sprites"]],
			"note": "只有「枪兵」有真正的 8 向素材：待机/受击按朝向播不同帧，攻击也按朝向出招；"
				+ "其余四套是单向或仅四向，斜向与朝向差异会自动回退。"
				+ "画布参数（缩放/脚底偏移）已随贴图集自动切换，不用手调。"
				+ "当前武器是「弓」时本项无效（弓锁定弓手贴图）。下次进局生效。"},

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
## 只写用户层，不碰 Data/config.json；「恢复均衡」逐项清掉即回到出厂值。
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
			"note": "清掉「性能优先」写下的全部用户层覆盖，回到 Data/config.json 的出厂值。"},

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
	var lines := ""
	for k in _PERF_BUNDLE.keys():
		lines += "%s → %s\n" % [k, str(_PERF_BUNDLE[k])]
	_confirm("性能优先",
			"将把以下参数写入用户层（可随时用「恢复均衡」或底部「恢复默认」撤销）：\n\n"
			+ lines + "\n多数项要重新进一局 / 重新生成地图才生效。确定？",
			"应用",
			func():
				for k in _PERF_BUNDLE.keys():
					Config.set_user_value(k, _PERF_BUNDLE[k], false)
				Config.save_user_settings()
				DisplaySettings.apply_all()
				_show_tab(_active))


func _clear_perf_preset() -> void:
	_confirm("恢复均衡",
			"清除「性能优先」写下的全部用户层覆盖，回到出厂值？",
			"清除",
			func():
				for k in _PERF_BUNDLE.keys():
					Config.clear_user_setting(k, false)
				Config.save_user_settings()
				DisplaySettings.apply_all()
				_show_tab(_active))


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
		{"path": "map.river.enabled", "label": "河流", "type": "bool",
			"note": "图中蜿蜒的河带，可以涉水但减速。"},
		{"path": "map.river.width_cells", "label": "河流宽度", "type": "number",
			"min": 0.0, "max": 4.0, "step": 0.05, "note": "单位是格；0 等于没有河。"},
		{"path": "map.river.slow", "label": "涉水速度系数", "type": "number",
			"min": 0.2, "max": 1.0, "step": 0.02, "fmt": "times"},
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
		{"path": "survival.meal_interval_seconds", "label": "饥饿间隔", "type": "number",
			"min": 10, "max": 600, "step": 10, "fmt": "duration",
			"note": "每过这么久消耗 1 份食物。"},

		{"type": "divider", "label": "玩家与战斗"},
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
		{"path": "enemy.contact_damage", "label": "接触伤害", "type": "number",
			"min": 1, "max": 100, "step": 1},
		{"path": "enemy.vision_cells", "label": "视野（格）", "type": "number",
			"min": 2, "max": 30, "step": 1},
	]


func _schema_controls() -> Array:
	return [
		{"type": "info", "label": "键位一律用「物理键码」记录（与游戏内消费端一致），"
			+ "所以非 QWERTY 键盘也不会错位。点按钮后按任意键即可改；ESC 取消。"},
		{"type": "divider", "label": "动作"},
		{"path": "combat.input.attack_key", "label": "普通攻击", "type": "key"},
		{"path": "combat.input.dodge_key", "label": "闪避", "type": "key"},
		{"path": "survival.eat_key", "label": "进食", "type": "key"},
		{"path": "camera.return_key", "label": "相机回到玩家", "type": "key"},
		{"path": "combat.input.attack_mouse_button", "label": "攻击鼠标键", "type": "enum",
			"items": [["鼠标左键", 1], ["鼠标右键", 2], ["鼠标中键", 3]]},
	]


func _schema_language() -> Array:
	return [
		{"type": "info", "label": "语言目前是占位：下拉可以选、选择会存进 user://settings.json，"
			+ "但还没有接 i18n —— 没有翻译表，界面文案仍是代码里的中文。"},
		{"path": "language.current", "label": "界面语言", "type": "enum",
			"items": _language_items(),
			"note": "标「未接线」的选了也不会改变界面文字，先把位置占上。"},
		{"type": "divider", "label": "接真翻译要做什么"},
		{"type": "info", "label": "1. 在 Data/language/<code>.po 里放译文；"
			+ "2. 启动时 TranslationServer.set_locale(Config.get_value(\"language.current\"))；"
			+ "3. 界面文字从字面量改成 tr(\"KEY\")；"
			+ "4. 把 config 里 language.available 对应项的 ready 改成 true（下面就会显示「可用」）。"},
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

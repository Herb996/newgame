extends Control
## ============================================================
## StartMenu — 游戏开始菜单（项目的启动场景）
##
## 五个入口：
##   新建存档 / 历史存档 → 存档槽面板（两种模式共用 Scripts/slot_panel.gd）
##   参数配置            → Scripts/settings_panel.gd（画面/音频/玩法/操作/语言）
##   其他                → Scripts/misc_panel.gd（占位）
##   退出游戏
##
## 子面板都在**同一个进程**里挂到 _panel_host 上（不切场景），
## 返回时只摘掉面板，菜单状态（按钮焦点、上次游玩槽）原地保留。
##
## 进游戏：激活槽（SaveSlots）→ 换场景到 config 的 menu.game_scene。
## 关键一处：从菜单进游戏会临时压掉 `debug.auto_enter_run`（见 _launch_game），
## 否则 main.gd 会像无头回归那样跳过基地直接进局。
##
## 调试用命令行参数（`--` 之后，不影响正常运行）：
##   --menu-capture <png>      截图后退出（验证界面用，需要开窗，无头截不到图）
##   --menu-capture-delay <秒> 截图前等待，默认 1.5
##   --menu-panel <new|load|settings|misc>  截图前先打开指定面板
##   --menu-tab <n>            配合 --menu-panel settings：打开后停在第 n 页
##   --menu-action <new|load>  自动执行「新建/载入 N 号槽 + 进游戏」后退出（验证用）
##   --menu-slot <n>           配合 --menu-action 指定槽号，默认 1
## ============================================================

const SLOT_PANEL := preload("res://Scripts/slot_panel.gd")
const SETTINGS_PANEL := preload("res://Scripts/settings_panel.gd")
const MISC_PANEL := preload("res://Scripts/misc_panel.gd")

var _menu_box: VBoxContainer
var _panel_host: Control
var _panel_layer: CanvasLayer
var _current_panel: Control = null
var _status: Label
var _slot_line: Label

# --- 命令行截图（仅调试）---
var _capture_path := ""
var _capture_delay := 1.5
var _capture_panel := ""
var _capture_tab := 0
var _capture_left := -1.0
# --- 命令行自动执行（仅验证）---
var _auto_action := ""
var _auto_slot := 1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_parse_cli()
	_build_ui()
	_refresh_status()
	# 自动执行要等菜单进树之后再改场景，_ready 里直接切场景容易切在"半初始化"状态
	if _auto_action != "":
		call_deferred("_run_auto_action")
		return
	if _capture_path != "":
		if _capture_panel != "":
			_open_named_panel(_capture_panel)
		_capture_left = _capture_delay


func _process(delta: float) -> void:
	if _capture_left < 0.0:
		return
	_capture_left -= delta
	if _capture_left < 0.0:
		_capture_now()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode != KEY_ESCAPE:
		return
	if _current_panel != null:
		_close_panel()
		get_viewport().set_input_as_handled()


# ------------------------------------------------------------
# 界面
# ------------------------------------------------------------

func _build_ui() -> void:
	add_child(UiKit.solid(UiKit.COL_BG))

	# 顶部一条琥珀色细线，纯装饰，让标题不显得悬空
	var top_line := ColorRect.new()
	top_line.color = UiKit.COL_AMBER * Color(1, 1, 1, 0.55)
	top_line.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_line.custom_minimum_size = Vector2(0, 2)
	top_line.offset_bottom = 2
	top_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top_line)

	var center := CenterContainer.new()
	UiKit.stretch(center)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_menu_box = UiKit.vbox(10)
	center.add_child(_menu_box)

	var title := UiKit.hero(str(Config.get_value("menu.title", "蒸汽朋克：废墟提取")))
	_menu_box.add_child(title)
	var subtitle := UiKit.label(str(Config.get_value("menu.subtitle", "SteamPunk Extraction")),
			UiKit.FS_BODY, UiKit.COL_DIM)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_box.add_child(subtitle)
	_menu_box.add_child(UiKit.spacer(26))

	# --- 主按钮列 ---
	var entries := [
		["新建存档", "开一个新的存档槽，从头开始", _on_new_save],
		["历史存档", "读取已有存档继续游戏", _on_load_save],
		["参数配置", "画面 / 音频 / 玩法 / 操作 / 语言", _on_settings],
		["其他", "制作人员 / 统计 / 成就 / 图鉴（占位）", _on_misc],
		["退出游戏", "", _on_quit],
	]
	for e in entries:
		var b := UiKit.menu_button(str(e[0]), str(e[1]))
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		if e[2] is Callable:
			b.pressed.connect(e[2])
		_menu_box.add_child(b)
		if str(e[0]) == "退出游戏":
			_menu_box.add_child(UiKit.spacer(6))

	_menu_box.add_child(UiKit.spacer(14))
	_slot_line = UiKit.dim("")
	_slot_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_box.add_child(_slot_line)

	var ver := UiKit.dim(str(Config.get_value("menu.version_label", "开发版")), UiKit.FS_SMALL)
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_box.add_child(ver)

	# 默认灰字放 config 里的提示语；只有真出错才改成警告色（见 _launch_game）
	_status = UiKit.dim("")
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_box.add_child(_status)

	# --- 子面板宿主：独立 CanvasLayer，保证盖在菜单之上且不受 CenterContainer 布局影响 ---
	_panel_layer = CanvasLayer.new()
	_panel_layer.layer = 10
	_panel_layer.visible = false
	add_child(_panel_layer)
	_panel_host = Control.new()
	UiKit.stretch(_panel_host)
	_panel_layer.add_child(_panel_host)


func _refresh_status() -> void:
	var hint := str(Config.get_value("menu.hint", ""))
	if SaveSlots.last_slot > 0 and SaveSlots.exists(SaveSlots.last_slot):
		var info := SaveSlots.slot_info(SaveSlots.last_slot)
		_slot_line.text = "上次游玩：%s · %s" % [info["name"], info["last_played"]]
	else:
		_slot_line.text = "尚无存档"
	_status.text = hint


# ------------------------------------------------------------
# 面板开关
# ------------------------------------------------------------

func _open_panel(panel: Control) -> void:
	_close_panel()
	_current_panel = panel
	if panel.has_signal("close_requested"):
		panel.close_requested.connect(_close_panel)
	_panel_host.add_child(panel)
	_panel_layer.visible = true
	_menu_box.visible = false


func _close_panel() -> void:
	if _current_panel != null and is_instance_valid(_current_panel):
		_current_panel.queue_free()
	_current_panel = null
	_panel_layer.visible = false
	_menu_box.visible = true
	_refresh_status()


func _open_named_panel(which: String) -> void:
	match which:
		"new":
			_on_new_save()
		"load":
			_on_load_save()
		"settings":
			_on_settings()
		"misc":
			_on_misc()


# ------------------------------------------------------------
# 按钮回调
# ------------------------------------------------------------

func _on_new_save() -> void:
	var p: Control = SLOT_PANEL.new()
	p.mode = "new"
	p.launch_requested.connect(_launch_game)
	_open_panel(p)


func _on_load_save() -> void:
	var p: Control = SLOT_PANEL.new()
	p.mode = "load"
	p.launch_requested.connect(_launch_game)
	_open_panel(p)


func _on_settings() -> void:
	var p: Control = SETTINGS_PANEL.new()
	p.initial_tab = _capture_tab
	_open_panel(p)


func _on_misc() -> void:
	var p: Control = MISC_PANEL.new()
	_open_panel(p)


func _on_quit() -> void:
	print("[Menu] 退出游戏")
	get_tree().quit()


# ------------------------------------------------------------
# 进入游戏
# ------------------------------------------------------------

func _launch_game() -> void:
	var scene := str(Config.get_value("menu.game_scene", "res://Scenes/Main.tscn"))
	# 从菜单进游戏必须落在**基地**：main.gd 那句 auto_enter_run 是给无头回归
	# 跳过基地用的（config 里默认 true），不压掉的话点开游戏就直接在局内了。
	# 用运行时覆盖而不是改写 config.json —— 命令行回归不受影响，退出即忘。
	if bool(Config.get_value("menu.enter_base_from_menu", true)):
		Config.set_override("debug.auto_enter_run", false)
	print("[Menu] 进入游戏：%s（槽 %d）" % [scene, SaveSlots.active_slot])
	var err := get_tree().change_scene_to_file(scene)
	if err != OK:
		push_error("[Menu] 切换场景失败：%s（err=%d）" % [scene, err])
		_status.add_theme_color_override("font_color", UiKit.COL_WARN)
		_status.text = "进入游戏失败：%s（err=%d）" % [scene, err]


# ------------------------------------------------------------
# 命令行截图（验证界面用）
# ------------------------------------------------------------

func _parse_cli() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i < argv.size():
		match argv[i]:
			"--menu-capture":
				i += 1
				_capture_path = argv[i] if i < argv.size() else ""
			"--menu-capture-delay":
				i += 1
				_capture_delay = float(argv[i]) if i < argv.size() else 1.5
			"--menu-panel":
				i += 1
				_capture_panel = argv[i] if i < argv.size() else ""
			"--menu-tab":
				i += 1
				_capture_tab = maxi(0, int(argv[i])) if i < argv.size() else 0
			"--menu-action":
				i += 1
				_auto_action = argv[i] if i < argv.size() else ""
			"--menu-slot":
				i += 1
				_auto_slot = maxi(1, int(argv[i])) if i < argv.size() else 1
		i += 1


## 自动执行「建/读槽 → 进游戏」，只给验证用（正常玩法走面板点击）。
## 目的：把 存档槽 → Meta 重载 → 场景切换 → 落在基地 这条链一次跑通，
## 而不是只验证"菜单能画出来"。
func _run_auto_action() -> void:
	print("[Menu] 自动执行：%s 槽 %d" % [_auto_action, _auto_slot])
	var ok := false
	if _auto_action == "new":
		ok = SaveSlots.create_slot(_auto_slot, "自动验证槽")
	elif _auto_action == "load":
		ok = SaveSlots.activate(_auto_slot)
	else:
		push_error("[Menu] 未知的 --menu-action：%s" % _auto_action)
		get_tree().quit(2)
		return
	if not ok:
		push_error("[Menu] 自动执行失败（槽 %d：%s）" % [_auto_slot, _auto_action])
		get_tree().quit(3)
		return
	_launch_game()


func _capture_now() -> void:
	_capture_left = -1.0
	# 必须等这一帧画完；_process 里直接取会拿到上一帧甚至空图
	await RenderingServer.frame_post_draw
	var tex := get_viewport().get_texture()
	if tex == null:
		push_error("[Menu] 拿不到 viewport 贴图（是不是 --headless？无头没有渲染输出）")
		get_tree().quit(1)
		return
	var img := tex.get_image()
	var err := img.save_png(_capture_path)
	print("[Menu] 菜单截图已输出：%s（%dx%d，err=%d）" % [
		_capture_path, img.get_width(), img.get_height(), err])
	get_tree().quit(0 if err == OK else 1)

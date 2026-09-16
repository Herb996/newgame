extends Node
## ============================================================
## DisplaySettings — 显示/音频设置的应用器（自动加载单例，用 `DisplaySettings` 访问）
##
## 职责：把「用户可改的画面与音量设置」真正作用到引擎上。
## 设置面板改完值会调 apply_all()，本单例也在启动时跑一次，
## 这样手动编辑 user://settings.json 也能生效。
##
## 分工（避免两处真相）：
##   · Data/config.json 的 display.*        —— 本项目新增的窗口/帧率/缩放项
##   · Data/config.json 的 audio.*          —— 音量
##   · Data/config.json 的 camera.*、map.grade.*、map.macro_light.*
##     —— **本来就是 config 的键**，设置面板直接写它们，游戏各系统自己会读；
##        本文件不重复接管，只在需要即时刷新时补一刀。
##
## 本项目当前**只做 2D 线**（Scenes/Main.tscn）：渲染相关只处理
## 「窗口 + 2D 缩放策略」，不碰 msaa_3d / anisotropic 这类 3D 项
## （它们由 project.godot 的 rendering/* 决定，3D 场景不列入计划）。
##
## 无头（--headless）下 dummy DisplayServer 对窗口操作会刷警告，
## 而回归验证要看的正是日志——所以这里整体跳过窗口相关调用。
## ============================================================

const MIX_BUSES := {
	"master": "Master",
	"music": "Music",
	"sfx": "SFX",
}


func _ready() -> void:
	apply_all()


## 一次性应用全部画面/音频设置
func apply_all() -> void:
	apply_display()
	apply_audio()


func apply_display() -> void:
	# 无头：dummy 驱动没有窗口，设置窗口模式只会刷警告，直接跳过
	if _is_headless():
		return
	_apply_window_mode(str(Config.get_value("display.window_mode", "windowed")))
	_apply_resolution()
	_apply_vsync(str(Config.get_value("display.vsync", "enabled")))
	Engine.max_fps = maxi(0, int(Config.get_value("display.max_fps", 0)))
	_apply_stretch(str(Config.get_value("display.stretch_mode", "disabled")),
			str(Config.get_value("display.stretch_aspect", "keep")))


func apply_audio() -> void:
	var mute := bool(Config.get_value("audio.mute", false))
	for key in MIX_BUSES:
		var bus_name: String = MIX_BUSES[key]
		var idx := _ensure_bus(bus_name)
		if idx < 0:
			continue
		var linear := clampf(float(Config.get_value("audio.%s" % key, 1.0)), 0.0, 1.0)
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))
		AudioServer.set_bus_mute(idx, mute)


func current_window_mode() -> String:
	return str(Config.get_value("display.window_mode", "windowed"))


# ------------------------------------------------------------
# 内部
# ------------------------------------------------------------

func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


func _apply_window_mode(mode: String) -> void:
	# 每次都先把无边框标志清掉再按需加，否则从「无边框」切回「窗口」会留着旧标志
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
	match mode:
		"fullscreen":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		"borderless":
			# Godot 没有独立的"无边框全屏窗口"枚举，用无边框标志 + 铺满屏幕模拟
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_size(DisplayServer.screen_get_size())
			_center_on_screen()
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


func _apply_resolution() -> void:
	var res: Array = Config.get_value("display.resolution", [1920, 1080])
	if res.size() < 2:
		return
	var w := maxi(320, int(res[0]))
	var h := maxi(240, int(res[1]))
	# 全屏/无边框模式下窗口尺寸由屏幕决定，别去覆盖它
	if current_window_mode() == "windowed":
		DisplayServer.window_set_size(Vector2i(w, h))
		_center_on_screen()


func _center_on_screen() -> void:
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var win := DisplayServer.window_get_size()
	DisplayServer.window_set_position(usable.position + (usable.size - win) / 2)


func _apply_vsync(mode: String) -> void:
	match mode:
		"disabled":
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		"adaptive":
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ADAPTIVE)
		_:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)


## 2D 缩放策略：设计分辨率固定 1920×1080（project.godot 的 viewport_*），
## 由引擎把它映射到实际窗口。
##   disabled     —— 1:1，不缩放（当前默认，与改造前行为一致）
##   canvas_items —— 坐标系按窗口等比放大，UI/文字仍是矢量清晰（像素画会变糊/不齐）
##   viewport     —— 先渲染到 1920×1080 再整张放大（像素画锐利，推荐配 nearest 过滤）
## aspect 决定窗口比例不是 16:9 时怎么补：keep 保留黑边 / expand 多露出画面 /
## ignore 拉伸变形 / keep_width / keep_height。
## 注意 content_scale_size 不在这里设：留着引擎默认（= project.godot 的 viewport 尺寸），
## 避免和 `--resolution` 这类命令行参数打架。
func _apply_stretch(mode: String, aspect: String) -> void:
	var win := get_window()
	if win == null:
		return
	const MODES := {
		"disabled": Window.CONTENT_SCALE_MODE_DISABLED,
		"canvas_items": Window.CONTENT_SCALE_MODE_CANVAS_ITEMS,
		"viewport": Window.CONTENT_SCALE_MODE_VIEWPORT,
	}
	const ASPECTS := {
		"ignore": Window.CONTENT_SCALE_ASPECT_IGNORE,
		"keep": Window.CONTENT_SCALE_ASPECT_KEEP,
		"keep_width": Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH,
		"keep_height": Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT,
		"expand": Window.CONTENT_SCALE_ASPECT_EXPAND,
	}
	win.content_scale_mode = MODES.get(mode, Window.CONTENT_SCALE_MODE_DISABLED)
	win.content_scale_aspect = ASPECTS.get(aspect, Window.CONTENT_SCALE_ASPECT_KEEP)


## 取总线下标；不存在则创建（项目还没配 bus layout，Music/SFX 得补上）
func _ensure_bus(bus_name: String) -> int:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		return idx
	if bus_name == "Master":
		return 0
	idx = AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, "Master")
	print("[DisplaySettings] 已创建音频总线：%s" % bus_name)
	return idx

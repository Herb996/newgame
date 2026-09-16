extends Node
## ============================================================
## probe_stretch — 验证 display.stretch_mode / stretch_aspect 是否真的作用到根窗口
##
## 为什么要有这个探针：DisplaySettings 在 --headless 下整体跳过窗口操作
## （dummy DisplayServer 会刷警告，污染回归日志），所以「2D 缩放策略」这条路
## 在无头回归里**永远不会被走到** —— 必须开窗单独验一次，否则就是没验。
##
## 全程用 Config.set_override（只改内存，不落盘），跑完 clear_overrides，
## 不会污染 user://settings.json。
## ============================================================

var _fails: Array = []
var _n := 0


func _check(ok: bool, msg: String) -> void:
	_n += 1
	if not ok:
		_fails.append(msg)
	print("[Stretch] %s %s" % ["OK  " if ok else "FAIL", msg])


func _ready() -> void:
	var win := get_window()
	# 本单例已不再接管 msaa_3d/anisotropic（3D 项），记一份初值，最后确认 apply_all 没碰它
	var msaa0 := get_viewport().msaa_3d
	var aniso0 := get_viewport().anisotropic_filtering_level
	print("[Stretch] 根窗口=%s  当前 mode=%d aspect=%d content_scale_size=%s  视口=%s"
			% [win.name, win.content_scale_mode, win.content_scale_aspect,
			str(win.content_scale_size), str(win.get_visible_rect().size)])

	# 1) 出厂值：必须还是 disabled —— 也就是改造前后行为一致（关键回归点）
	_check(win.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED,
			"出厂值 content_scale_mode == DISABLED（实际 %d）" % win.content_scale_mode)
	_check(win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP,
			"出厂值 content_scale_aspect == KEEP（实际 %d）" % win.content_scale_aspect)

	# 2) viewport + keep_width 应该真的改到窗口上
	Config.set_override("display.stretch_mode", "viewport")
	Config.set_override("display.stretch_aspect", "keep_width")
	DisplaySettings.apply_all()
	_check(win.content_scale_mode == Window.CONTENT_SCALE_MODE_VIEWPORT,
			"viewport 生效（实际 %d）" % win.content_scale_mode)
	_check(win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH,
			"keep_width 生效（实际 %d）" % win.content_scale_aspect)

	# 3) canvas_items 这条路也要通
	Config.set_override("display.stretch_mode", "canvas_items")
	Config.set_override("display.stretch_aspect", "expand")
	DisplaySettings.apply_all()
	_check(win.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS,
			"canvas_items 生效（实际 %d）" % win.content_scale_mode)
	_check(win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND,
			"expand 生效（实际 %d）" % win.content_scale_aspect)

	# 4) 非法值回落而不是崩（手改 settings.json 写错字的场景）
	Config.set_override("display.stretch_mode", "Viewport")   # 大小写错
	Config.set_override("display.stretch_aspect", "16:9")     # 不存在的值
	DisplaySettings.apply_all()
	_check(win.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED,
			"非法 mode 回落 DISABLED（实际 %d）" % win.content_scale_mode)
	_check(win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP,
			"非法 aspect 回落 KEEP（实际 %d）" % win.content_scale_aspect)

	# 5) 清 override 后回到出厂值，且没写进 user://settings.json
	Config.clear_overrides()
	DisplaySettings.apply_all()
	_check(win.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED,
			"clear_overrides 后回到 DISABLED（实际 %d）" % win.content_scale_mode)
	_check(not Config.has_user_value("display.stretch_mode"),
			"全程未写入 user://settings.json")
	_check(not Config.has_user_value("display.stretch_aspect"),
			"aspect 也未写入 user://settings.json")

	# 6) 旧的 3D 项不该再被本单例碰：键都删了，apply_all 也不该再改这两个渲染属性
	_check(get_viewport().msaa_3d == msaa0,
			"apply_all 未改动 msaa_3d（初值 %d → 现值 %d）"
			% [msaa0, get_viewport().msaa_3d])
	_check(get_viewport().anisotropic_filtering_level == aniso0,
			"apply_all 未改动 anisotropic（初值 %d → 现值 %d）"
			% [aniso0, get_viewport().anisotropic_filtering_level])

	print("=== [Stretch] 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		print("[Stretch] !! ", m)
	get_tree().quit(0 if _fails.is_empty() else 1)

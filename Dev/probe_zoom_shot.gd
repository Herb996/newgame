extends Node
## Dev 探针 — 窗口化实拍滚轮缩放三档（临时，不属于游戏本体）
## 必须**不加 --headless** 跑：headless 是 dummy 渲染驱动，frame_post_draw 不触发，拍不到图。

const OUT := "C:/Users/Administrator/WorkBuddy/2026-09-14-22-35-14"


func _ready() -> void:
	# 同 probe_zoom：Main3D 开头那几个 debug 自检会接管进程并自己 quit()，实拍就跑完了
	Config.set_override("debug.smoke_test", false)
	Config.set_override("debug.flow_test", false)
	Config.set_override("debug.map_preview", "")
	var main: Node = load("res://Scenes/Main3D.tscn").instantiate()
	add_child(main)
	for i in range(60):
		await get_tree().process_frame

	var cam: Camera3D = main.get("_cam")
	var hint: Node = main.get_node_or_null("ViewHint")
	if cam == null:
		print("[ZoomShot] !! 拿不到相机")
		get_tree().quit(1)
		return

	var vp := get_viewport().get_visible_rect().size
	print("[ZoomShot] 视口 %s | 初始 size=%.2f | 限位 [%.2f, %.2f]"
			% [str(vp), cam.size, cam._zoom_lo, cam._zoom_hi])
	# 把系统光标挪到画面正中，用来演示"指着哪就缩哪"
	Input.warp_mouse(vp * 0.5)
	for i in range(20):
		await get_tree().process_frame
	print("[ZoomShot] 光标位置 = %s" % str(get_viewport().get_mouse_position()))

	await _shot(cam, hint, "zoom_00_default.png", "默认视野（base_size=40）")
	await _wheel(false, 3)
	await _shot(cam, hint, "zoom_01_out.png", "滚轮向下 ×3 → 缩小")
	await _wheel(true, 8)
	await _shot(cam, hint, "zoom_02_in.png", "滚轮向上 ×8 → 放大（撞下限）")
	get_tree().quit(0)


func _wheel(up: bool, n: int) -> void:
	var vp := get_viewport().get_visible_rect().size
	for _i in range(n):
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
		ev.pressed = true
		ev.position = vp * 0.5
		ev.factor = 1.0
		Input.parse_input_event(ev)
	Input.flush_buffered_events()
	# 等平滑过渡走完（物理帧固定 60Hz，45 帧 ≈ 0.75s）
	for i in range(45):
		await get_tree().physics_frame
		await get_tree().process_frame


func _shot(cam: Camera3D, hint: Node, fname: String, tag: String) -> void:
	for i in range(4):
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path: String = OUT + "/" + fname
	var err := img.save_png(path)
	var zl = hint.get("_label") if hint != null else null
	print("[ZoomShot] %s | size=%.2f ratio=%.3f | 提示=\"%s\" 可见=%s | %s err=%d"
			% [tag, cam.size, cam.zoom_ratio(),
			   (str(zl.text) if zl != null else "-"),
			   (str(zl.is_visible_in_tree()) if zl != null else "-"), path, err])

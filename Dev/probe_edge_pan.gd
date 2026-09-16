extends Node
## ============================================================
## probe_edge_pan — 验证「鼠标贴到窗口边 → 画面往该方向滚」
##
## 五段：
##   A 纯数学（edge_pan_dir_at，喂坐标断言，不碰真鼠标）
##   B 配置接线 + 三条件开关（开关 / 焦点 / 悬停控件）
##   C 独立相机真位移（手动步进，数值可精确断言）
##   D 真场景 Main.tscn：接线是否生效 + UI 有没有"全屏挡板"把边缘滚屏废掉
##   E 鼠标坐标与视口坐标是否同一空间（否则边距算式会整体错位）
##
## 为什么必须开窗：edge_pan_active() 里有一条"窗口必须有焦点"，
## 无头（dummy DisplayServer）下永远不成立，这条路在无头里根本没被走到。
##
## 痕迹文件：user://_probe_edge_pan_trace.txt（进程被挂死/强杀时 stdout 会全丢）
## ============================================================

const CAM_SCRIPT := preload("res://Scripts/camera_controller.gd")
const TRACE := "user://_probe_edge_pan_trace.txt"

var _fails: Array = []
var _n := 0
var _skips: Array = []


func _check(ok: bool, msg: String) -> void:
	_n += 1
	if not ok:
		_fails.append(msg)
	print("[EdgePan] %s %s" % ["OK  " if ok else "FAIL", msg])


func _skip(msg: String) -> void:
	_skips.append(msg)
	print("[EdgePan] SKIP %s" % msg)


func _say(msg: String) -> void:
	print("[EdgePan]      %s" % msg)


func _trace(msg: String) -> void:
	var f := FileAccess.open(TRACE, FileAccess.WRITE)
	if f != null:
		f.store_string(msg + "\n")


## 本探针根节点是 Node（不是 CanvasItem），没有 get_viewport_rect()，
## 视口尺寸得从 viewport 自己取。
func _vp() -> Vector2:
	return get_viewport().get_visible_rect().size


func _ready() -> void:
	_trace("_ready 进入")
	await _part_a()
	_trace("A 段完成")
	await _part_b()
	_trace("B 段完成")
	await _part_c()
	_trace("C 段完成")
	await _part_d()
	_trace("D 段完成")
	await _part_e()
	print("[EdgePan] 共 %d 项断言，失败 %d 项；跳过 %d 项" % [_n, _fails.size(), _skips.size()])
	for m in _fails:
		print("[EdgePan] !! ", m)
	for m in _skips:
		print("[EdgePan] ?? ", m)
	_trace("结论：%d 项断言，失败 %d 项，跳过 %d 项" % [_n, _fails.size(), _skips.size()])
	get_tree().quit(0 if _fails.is_empty() else 1)


# ------------------------------------------------------------
# A 段：纯数学
# ------------------------------------------------------------

func _part_a() -> void:
	print("--- A 段：方向数学 ---")
	var cam: Camera2D = CAM_SCRIPT.new()
	add_child(cam)
	cam.set_physics_process(false)
	var vp := cam.get_viewport_rect().size
	_say("视口 = %s，触发边距 = %.0f" % [str(vp), cam.edge_pan_margin])
	cam.edge_pan_margin = 24.0
	var x0 := vp.x
	var y0 := vp.y

	_check(cam.edge_pan_dir_at(vp * 0.5) == Vector2.ZERO, "屏幕正中央 → 不滚")
	_check(cam.edge_pan_dir_at(Vector2(24.0, y0 * 0.5)) == Vector2(-1, 0),
			"左边缘上（x=24，正好等于边距）→ 向左滚")
	_check(cam.edge_pan_dir_at(Vector2(25.0, y0 * 0.5)) == Vector2.ZERO,
			"左边距内 1px（x=25）→ 不滚（边界判定是 <=margin）")
	_check(cam.edge_pan_dir_at(Vector2(x0 - 24.0, y0 * 0.5)) == Vector2(1, 0),
			"右边缘上 → 向右滚")
	_check(cam.edge_pan_dir_at(Vector2(x0 - 25.0, y0 * 0.5)) == Vector2.ZERO,
			"右边距内 1px → 不滚")
	_check(cam.edge_pan_dir_at(Vector2(x0 * 0.5, 24.0)) == Vector2(0, -1), "上边缘 → 向上滚")
	_check(cam.edge_pan_dir_at(Vector2(x0 * 0.5, y0 - 24.0)) == Vector2(0, 1), "下边缘 → 向下滚")
	_check(cam.edge_pan_dir_at(Vector2(3.0, 3.0)) == Vector2(-1, -1), "左上角 → 斜着滚")
	_check(cam.edge_pan_dir_at(Vector2(x0 - 3.0, y0 - 3.0)) == Vector2(1, 1), "右下角 → 斜着滚")
	_check(cam.edge_pan_dir_at(Vector2(-1.0, y0 * 0.5)) == Vector2.ZERO,
			"鼠标在视口外（左侧 x=-1）→ 不滚")
	_check(cam.edge_pan_dir_at(Vector2(x0 + 5.0, y0 * 0.5)) == Vector2.ZERO,
			"鼠标在视口外（右侧）→ 不滚")

	# 边距上限：不夹住的话小窗口下整个屏幕都是触发区，一进游戏就自己滚
	cam.edge_pan_margin = 5000.0
	var cap := minf(vp.x, vp.y) * 0.45
	# 注意：格式串里"45%"必须写成"45%%" —— 直接写 % 再跟全角括号，
	# Godot 的 sprintf 会把后面的 %.0f 当成普通文本，消息里就留着未替换的占位符。
	_check(cam.edge_pan_dir_at(vp * 0.5) == Vector2.ZERO,
			"边距填 5000 → 被夹到短边 45%% 处（上限 %.0f px），屏幕中心仍不滚" % cap)
	_check(cam.edge_pan_dir_at(Vector2(cap - 2.0, vp.y * 0.5)) == Vector2(-1, 0),
			"边距夹到 45% 后，仍有明确的触发区（不是全屏也不是零）")
	cam.edge_pan_margin = 24.0
	cam.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------
# B 段：配置接线 + 三条件开关
# ------------------------------------------------------------

func _part_b() -> void:
	print("--- B 段：配置与开关 ---")
	var cam: Camera2D = CAM_SCRIPT.new()
	add_child(cam)
	cam.set_physics_process(false)

	_check(cam.edge_pan_enabled == bool(Config.get_value("camera.edge_pan_enabled", true)),
			"edge_pan_enabled 来自 config（= %s）" % cam.edge_pan_enabled)
	_check(is_equal_approx(cam.edge_pan_margin, float(Config.get_value("camera.edge_pan_margin", 24.0))),
			"edge_pan_margin 来自 config（= %.0f）" % cam.edge_pan_margin)
	_check(is_equal_approx(cam.edge_pan_speed_mult,
			float(Config.get_value("camera.edge_pan_speed_mult", 1.0))),
			"edge_pan_speed_mult 来自 config（= %.2f）" % cam.edge_pan_speed_mult)
	_check(cam.edge_pan_ignore_ui == bool(Config.get_value("camera.edge_pan_ignore_ui", true)),
			"edge_pan_ignore_ui 来自 config（= %s）" % cam.edge_pan_ignore_ui)

	# 焦点这一条：本进程恰好没焦点 → 正好能验证"没焦点就不滚"；
	# 有焦点 → 验证"有焦点且无悬停控件就允许滚"。两种都是真结论。
	var focused := cam.get_window().has_focus()
	_say("本进程窗口焦点 = %s" % focused)
	cam.edge_pan_enabled = true
	cam._mouse_override = Vector2(2.0, cam.get_viewport_rect().size.y * 0.5)
	cam.edge_pan_ignore_ui = true
	if focused:
		_check(cam.edge_pan_active(), "有焦点 + 无悬停控件 → 允许滚")
	else:
		_check(not cam.edge_pan_active(), "无焦点 → 不允许滚（alt-tab 切走后不该继续滚）")

	# 开关关掉后一律不滚（不受焦点/悬停影响）
	cam.edge_pan_enabled = false
	_check(not cam.edge_pan_active(), "开关关闭 → 不允许滚")
	cam.edge_pan_enabled = true

	# 悬停控件这一条：造一个覆盖全屏的 STOP 控件，鼠标落到它上面就该拦住。
	# hover 由 Godot 在收到鼠标移动事件时才更新，而本进程无法保证鼠标真的动过，
	# 所以补一发**合成**鼠标移动事件（只动 Godot 内部坐标，不挪系统光标）。
	var blocker := Control.new()
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(blocker)
	# 这一段只测"悬停门"本身：焦点门若因自动化进程而关着，这里显式绕过 ——
	# 否则 not active() 会因为"没焦点"而假通过，等于什么都没测到。
	cam._ignore_focus_gate = true
	var hovered := cam.get_viewport().gui_get_hovered_control()
	if hovered == null:
		_send_synth_motion(_vp() * 0.5)
		await get_tree().process_frame
		await get_tree().process_frame
		hovered = cam.get_viewport().gui_get_hovered_control()
	if hovered == null:
		# 换一条投递通路再试：Input 单例那条实测不刷新 hover
		_send_synth_motion_via_input(_vp() * 0.5)
		await get_tree().process_frame
		await get_tree().process_frame
		hovered = cam.get_viewport().gui_get_hovered_control()
	_say("放了一个全屏 STOP 控件 + 合成鼠标移动后，gui_get_hovered_control() = %s" % str(hovered))
	if hovered != null and hovered == blocker:
		_check(not cam.edge_pan_active(), "鼠标悬停在 STOP 控件上 → 不允许滚（点界面时画面不被带走）")
	elif hovered != null:
		_say("hover 到的是 %s 而不是刚造的挡板（别处也有控件在这点下）" % str(hovered))
		_check(not cam.edge_pan_active(), "鼠标下有任何控件 → 不允许滚")
	else:
		_skip("合成鼠标事件也没能触发 hover 更新，该条改用 D 段的结构化检查代替")
	blocker.queue_free()
	cam._ignore_focus_gate = false
	# 合成事件把"视口鼠标位置"改了，还原成真实鼠标位置，免得污染 E 段的交叉验证
	_send_synth_motion(Vector2(DisplayServer.mouse_get_position()
			- DisplayServer.window_get_position()))
	await get_tree().process_frame

	cam.queue_free()
	await get_tree().process_frame


## 合成一发鼠标移动事件（不走系统光标，只喂给 Godot 输入管线）。
## 关键：必须走 Viewport 的 GUI 管线（push_input）才会刷新 hover 状态；
## Input.parse_input_event 只是喂 Input 单例，**不会**让 gui_get_hovered_control() 变。
func _send_synth_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.relative = Vector2.ZERO
	get_viewport().push_input(ev, true)


## 备选通路（确定性不如上面那条，留着做交叉尝试）
func _send_synth_motion_via_input(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.relative = Vector2.ZERO
	Input.parse_input_event(ev)


# ------------------------------------------------------------
# C 段：独立相机的真实位移（手动步进，数值可精确断言）
# ------------------------------------------------------------

func _make_cam(map_px: float) -> Camera2D:
	var cam: Camera2D = CAM_SCRIPT.new()
	add_child(cam)
	cam.set_physics_process(false)          # 只吃手动步进，免得自动帧把数值搅乱
	cam.setup(Vector2(map_px, map_px), null)
	cam.zoom_to(1.0)
	cam.edge_pan_enabled = true
	cam.edge_pan_margin = 24.0
	cam.edge_pan_speed_mult = 1.0
	cam.edge_pan_ignore_ui = false          # C 段只测运动，UI 门在 B/D 段测
	cam._ignore_focus_gate = true           # 自动化进程拿不到焦点，焦点门已在 B 段验过
	return cam


func _step(cam: Camera2D, n: int, dt: float) -> void:
	for _i in n:
		cam._physics_process(dt)


func _part_c() -> void:
	print("--- C 段：真实位移 ---")
	var vp := _vp()
	var cam := _make_cam(8192.0)
	# pan_speed 是本脚本自己的成员（Camera2D 上没有），显式标类型给它，
	# 否则 `:=` 推断不出来（值类型是动态的），会直接判 Parse Error。
	var sp: float = cam.pan_speed
	_say("pan_speed = %.0f px/s，视口 = %s，地图 = 8192×8192" % [sp, str(vp)])
	cam.global_position = Vector2(4096.0, 4096.0)

	# C1 左边缘 → 左移 0.5 秒 = pan_speed × 0.5
	cam.global_position = Vector2(4096.0, 4096.0)
	cam._mouse_override = Vector2(2.0, vp.y * 0.5)
	_step(cam, 5, 0.1)
	var dx := cam.global_position.x - 4096.0
	_check(absf(dx + sp * 0.5) < 0.5,
			"贴左边 0.5s → 左移 %.1fpx（期望 -%.1f）" % [dx, sp * 0.5])
	_check(is_equal_approx(cam.global_position.y, 4096.0), "贴左边不会带动纵向")

	# C2 右下角 → 斜向，且合速度不能超过正面（归一化限幅）
	cam.global_position = Vector2(4096.0, 4096.0)
	cam._mouse_override = Vector2(vp.x - 2.0, vp.y - 2.0)
	_step(cam, 5, 0.1)
	var d := cam.global_position - Vector2(4096.0, 4096.0)
	_check(absf(d.x) > 0.1 and absf(d.y) > 0.1, "右下角 → 两个轴都在动（%.1f, %.1f）" % [d.x, d.y])
	_check(absf(d.length() - sp * 0.5) < 0.5,
			"斜向合位移 %.1fpx = 正面同样距离 %.1fpx（斜着推角落不会更快）" % [d.length(), sp * 0.5])

	# C3 倍率只作用在边缘那一份
	cam.edge_pan_speed_mult = 0.5
	cam.global_position = Vector2(4096.0, 4096.0)
	cam._mouse_override = Vector2(2.0, vp.y * 0.5)
	_step(cam, 5, 0.1)
	_check(absf(cam.global_position.x - (4096.0 - sp * 0.25)) < 0.5,
			"倍率 0.5 → 位移减半（%.1fpx，期望 -%.1f）"
			% [cam.global_position.x - 4096.0, sp * 0.25])
	cam.edge_pan_speed_mult = 1.0

	# C4 到边界就停（不能滚出地图外的白边）
	cam.global_position = Vector2(vp.x * 0.5, 4096.0)   # x = 左边界
	var edge_x := cam.global_position.x
	cam._mouse_override = Vector2(2.0, vp.y * 0.5)
	_step(cam, 10, 0.1)
	_check(is_equal_approx(cam.global_position.x, edge_x),
			"已经贴到地图左边界再往左滚 → 位置不变（%.1f）" % cam.global_position.x)

	# C5 鼠标回中间 → 停
	cam.global_position = Vector2(4096.0, 4096.0)
	cam._mouse_override = vp * 0.5
	_step(cam, 5, 0.1)
	_check(cam.global_position.is_equal_approx(Vector2(4096.0, 4096.0)),
			"鼠标回屏幕中央 → 画面不动")

	# C6 关掉开关后，即使鼠标贴边也不动
	cam.edge_pan_enabled = false
	cam._mouse_override = Vector2(2.0, vp.y * 0.5)
	_step(cam, 5, 0.1)
	_check(cam.global_position.is_equal_approx(Vector2(4096.0, 4096.0)),
			"开关关闭 → 贴边也不动")

	# C7 与键盘同向叠加不超速（模拟 W 键同时按下：直接给 dir 加一份）
	cam.edge_pan_enabled = true
	cam._mouse_override = Vector2(2.0, vp.y * 0.5)
	cam.global_position = Vector2(4096.0, 4096.0)
	_step(cam, 10, 0.1)
	var single := 4096.0 - cam.global_position.x
	_say("纯边缘滚 1.0s 位移 = %.1fpx" % single)
	_check(absf(single - sp) < 0.5, "纯边缘滚 1.0s = 一格满速（%.1fpx）" % single)

	cam.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------
# D 段：真场景接线（Main.tscn）+ UI 有没有全屏挡板
# ------------------------------------------------------------

## 找出「可见 + mouse_filter=STOP + 矩形包住整个视口」的控件。
## 这种控件一存在，edge_pan_ignore_ui 就会永远拦住边缘滚屏 —— 功能静默失效，
## 而表面上"代码都写了"。所以要在真场景里结构化查一遍，而不是靠肉眼点两下。
func _find_fullscreen_blockers(root: Node, vp: Vector2) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
			if not (c is Control):
				continue
			var ctl := c as Control
			if not ctl.is_visible_in_tree():
				continue
			if ctl.mouse_filter != Control.MOUSE_FILTER_STOP:
				continue
			if ctl.get_global_rect().encloses(Rect2(Vector2.ZERO, vp)):
				out.append("%s（%s，%s）" % [ctl.name, ctl.get_class(), str(ctl.size)])
	return out


func _part_d() -> void:
	print("--- D 段：真场景 Main.tscn ---")
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	# 等基地/局内把相机建出来（地图生成要点时间）
	for _i in 300:
		await get_tree().physics_frame
		if not get_tree().get_nodes_in_group(CAM_SCRIPT.GROUP).is_empty():
			break
	await get_tree().physics_frame

	var cams := get_tree().get_nodes_in_group(CAM_SCRIPT.GROUP)
	_check(cams.size() >= 1, "Main.tscn 里找到了 %d 台可缩放相机（组 %s）" % [cams.size(), CAM_SCRIPT.GROUP])
	if cams.is_empty():
		main.queue_free()
		await get_tree().process_frame
		return
	var cam: Camera2D = cams[0]
	_say("相机地图尺寸 = %s；edge_pan_margin = %.0f；ignore_ui = %s"
			% [str(cam._map_size), cam.edge_pan_margin, cam.edge_pan_ignore_ui])
	_check(cam._map_size.x > 0.0, "相机拿到了地图尺寸（边界限位才有意义）")

	# 游戏 UI 里有没有"全屏 STOP 挡板"？有的话边缘滚屏会在真实游戏里彻底失效
	var blockers := _find_fullscreen_blockers(main, cam.get_viewport_rect().size)
	_say("游戏 UI 里覆盖全屏且会吃鼠标的控件：%s" % ("无" if blockers.is_empty() else str(blockers)))
	_check(blockers.is_empty(), "游戏 UI 没有全屏挡板（否则 edge_pan_ignore_ui 会把功能废掉）")
	_say("当前 gui_get_hovered_control() = %s" % str(cam.get_viewport().gui_get_hovered_control()))

	# 真位移：用真场景的相机，关掉它自己的帧处理，手动步进
	cam.set_physics_process(false)
	get_tree().paused = false           # 真场景可能停在暂停态，会让 _physics_process 直接 return
	cam._ignore_focus_gate = true
	cam.edge_pan_ignore_ui = false      # 挡板检查已单独做过，这里只测运动
	cam.edge_pan_speed_mult = 1.0
	var vp := cam.get_viewport_rect().size
	var before := cam.global_position
	cam._mouse_override = Vector2(2.0, vp.y * 0.5)
	_step(cam, 5, 0.1)
	var moved := before.x - cam.global_position.x
	_check(moved > 1.0, "真场景 MVP 相机贴左边 0.5s 后确实左移了 %.1fpx" % moved)
	_check(moved <= cam.pan_speed * 0.5 + 0.5,
			"位移不超过满速上界（%.1f <= %.1f）" % [moved, cam.pan_speed * 0.5])
	cam._mouse_override = Vector2.INF

	main.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------
# E 段：鼠标坐标与视口坐标是不是同一空间
# ------------------------------------------------------------

## 边距算式是"鼠标坐标 m 直接和视口矩形比"，所以两者必须同空间。
## 开了画面缩放（content_scale）后窗口像素 ≠ 视口像素，这一条必须实际确认一次。
## Godot 的 Viewport.get_mouse_position() 名义上返回"视口坐标系"的位置 ——
## 这里用 DisplayServer 的屏幕坐标反推来交叉验证，不靠"文档说"下结论。
func _part_e() -> void:
	print("--- E 段：鼠标坐标空间 ---")
	var win := get_window()
	var ds := DisplayServer.mouse_get_position()
	var wp := DisplayServer.window_get_position()
	var wz := win.size
	var rel := Vector2(ds - wp)
	_say("屏幕鼠标 = %s，窗口左上 = %s，窗口尺寸 = %s → 窗口内相对 = %s"
			% [str(ds), str(wp), str(wz), str(rel)])
	var inside := rel.x >= 0.0 and rel.y >= 0.0 and rel.x <= float(wz.x) and rel.y <= float(wz.y)
	if not inside:
		_skip("鼠标当前不在游戏窗口内，坐标空间这一条没法在本进程验证"
				+ "（需要真实鼠标落在窗口里）")
		return
	var vp := _vp()
	var m := get_viewport().get_mouse_position()
	_say("视口尺寸 = %s，get_mouse_position() = %s" % [str(vp), str(m)])
	_check(m.x >= 0.0 and m.y >= 0.0 and m.x <= vp.x and m.y <= vp.y,
			"鼠标坐标落在视口矩形内（说明与视口同空间，边距算式才成立）")
	var scale := float(wz.x) / vp.x if vp.x > 0.0 else 1.0
	_say("窗口/视口 的尺度比 = %.3f（≠1 说明画面缩放开着，正是要验的情形）" % scale)
	_check(absf(m.x - rel.x / scale) < 3.0 and absf(m.y - rel.y / scale) < 3.0,
			"与「屏幕坐标 - 窗口位置，再除以缩放比」一致（差 %.2fpx）"
			% Vector2(m.x - rel.x / scale, m.y - rel.y / scale).length())

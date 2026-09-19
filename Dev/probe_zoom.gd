extends Node
## Dev 探针 — 滚轮缩放自检（临时，不属于游戏本体）
## A 段：裸相机上的缩放数学（进出对称 / 光标锚点 / 上下限 / 取景居中）
## B 段：在真 Main3D 场景里走**真实输入管线**注入滚轮，并确认 HUD 提示亮起
##
## 为什么分两段：A 段能精确控制锚点屏幕坐标（headless 下鼠标位置不可控），
## B 段才能覆盖"事件会不会被 HUD / _input 吞掉"这类集成问题。

const ISO_CAM := preload("res://Scripts/iso_camera_3d.gd")

var _fails: Array = []
var _n := 0
var _temp_cams: Array = []


func _check(ok: bool, msg: String) -> void:
	_n += 1
	if not ok:
		_fails.append(msg)
	print("[ZoomProbe] %s %s" % ["OK  " if ok else "FAIL", msg])


func _ready() -> void:
	# B 段要实例化真 Main3D，而 main3d.gd 开头那几个 debug 自检会**接管整个进程**
	# （跑完自己 get_tree().quit()）：debug.flow_test=true 时 B 段在 B1 之后就被
	# FlowTest 的退出码掐死，本探针的汇总行根本没机会打 —— 看着像 zoom 挂了，
	# 其实是自检在替它说话。探针要的是自己的结论，一律钉回关闭。
	Config.set_override("debug.smoke_test", false)
	Config.set_override("debug.flow_test", false)
	Config.set_override("debug.map_preview", "")
	# B5 断的是**基地模式**下 HUD 该整体隐藏；debug.auto_enter_run=true 会让 Main3D
	# 开局直接进战斗（main3d.gd:89 → _enter_run 把 hud.visible 设回 true），那 B5 量的
	# 就不是同一件事了。这台机器上它现在确实是 true（别的会话留的）。
	Config.set_override("debug.auto_enter_run", false)
	await _part_a()
	await _part_b()
	print("=== [ZoomProbe] 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		print("[ZoomProbe] !! ", m)
	get_tree().quit(0 if _fails.is_empty() else 1)


# ------------------------------------------------------------
# A 段：缩放数学
# ------------------------------------------------------------

## 按 main3d._setup_camera 的同一套公式造一台裸相机
func _make_cam(map_cells: int, view_size: float) -> Camera3D:
	var cam: Camera3D = ISO_CAM.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.far = 600.0
	add_child(cam)
	var focus := Vector3(float(map_cells) * 0.5, 0.0, float(map_cells) * 0.5)
	var dist := 120.0
	var pitch := deg_to_rad(45.5)
	var horiz := dist * cos(pitch)
	cam.global_position = focus + Vector3(horiz * 0.70710678, dist * sin(pitch),
			horiz * 0.70710678)
	cam.look_at(focus, Vector3.UP)
	cam.make_current()
	cam.setup(null, 16, focus)
	cam.set_bounds(map_cells, map_cells)
	cam.set_view_size(view_size)
	_temp_cams.append(cam)
	return cam


func _wheel(cam: Camera3D, up: bool, times: int = 1) -> void:
	var screen: Vector2 = get_viewport().get_visible_rect().size * 0.5
	for _i in range(times):
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
		ev.pressed = true
		ev.position = screen
		ev.factor = 1.0
		cam._unhandled_input(ev)


func _part_a() -> void:
	print("--- A 段：缩放数学 ---")
	var cam := _make_cam(128, 46.0)

	# A1 进 / 出必须互为倒数，否则来回滚会一路漂小。
	# 注意只能取 3 档：从 46 连滚 6 档会撞到下限 24，被截断后就回不到原点，
	# 那是限位在正常工作（见 A4），不是不对称。
	var s0: float = cam.size
	_wheel(cam, true, 3)
	var s_up: float = cam._zoom_target
	_wheel(cam, false, 3)
	var s_back: float = cam._zoom_target
	_check(absf(s_back - s0) < 0.0001,
			"A1 步进对称：%.4f →(上3格)→ %.4f →(下3格)→ %.4f（应回到 %.4f）"
			% [s0, s_up, s_back, s0])
	# 每档乘数的乘积应恰好为 1（旧实现 0.88 × 1.12 = 0.9856 会持续漂小）
	var prod: float = cam._step_factor(1.0) * cam._step_factor(-1.0)
	_check(absf(prod - 1.0) < 1e-9,
			"A1 单档进/出乘数互为倒数：%.6f × %.6f = %.9f"
			% [cam._step_factor(1.0), cam._step_factor(-1.0), prod])

	# A2 缩放时光标下的地面点应钉住不动
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var pts: Array = [
		vp * Vector2(0.5, 0.5), vp * Vector2(0.5, 0.22),
		vp * Vector2(0.24, 0.5), vp * Vector2(0.72, 0.68),
	]
	for p in pts:
		cam.focus_on_world(Vector3(64.0, 0.0, 64.0))
		cam.set_view_size(60.0)
		var hit0: Variant = cam._ground_point(p)
		if hit0 == null:
			_check(false, "A2 锚点 %s 求交失败" % str(p))
			continue
		var w0: Vector3 = hit0
		var prev: float = cam.size
		cam._apply_zoom(prev, prev * 0.7, p)
		var hit1: Variant = cam._ground_point(p)
		if hit1 == null:
			_check(false, "A2 锚点 %s 缩放后求交失败" % str(p))
			continue
		var w1: Vector3 = hit1
		var d := Vector2(w0.x - w1.x, w0.z - w1.z).length()
		_check(d < 0.05,
				"A2 光标锚点 (%.0f,%.0f)：地面点 (%.3f, %.3f) → (%.3f, %.3f)，偏移 %.4f 世界单位"
				% [p.x, p.y, w0.x, w0.z, w1.x, w1.z, d])

	# A3 上限被地图尺寸收敛：缩到底正好装下整张图
	var bc := _make_cam(64, 40.0)
	_wheel(bc, false, 60)
	var hi: float = bc._zoom_hi
	var aspect: float = vp.x / maxf(vp.y, 1.0)
	var ground_h := hi / sin(deg_to_rad(45.5))
	var cover_w := hi * aspect
	_check(ground_h >= 64.0 and cover_w >= 64.0,
			"A3 基地缩到底 hi=%.2f：可见地面 %.1f×%.1f（地图 64×64，应不小于）"
			% [hi, cover_w, ground_h])
	_check(hi < 149.0, "A3 上限确实被地图收敛：hi=%.2f < config 上限 150" % hi)

	# A4 反复滚不越界
	_wheel(bc, true, 120)
	_check(is_equal_approx(bc._zoom_target, bc._zoom_lo),
			"A4 一直放大：target=%.3f 停在 lo=%.3f" % [bc._zoom_target, bc._zoom_lo])
	_wheel(bc, false, 240)
	_check(is_equal_approx(bc._zoom_target, bc._zoom_hi),
			"A4 一直缩小：target=%.3f 停在 hi=%.3f" % [bc._zoom_target, bc._zoom_hi])

	# A5 视口大于地图时，取景应被居中（不能一路平移出图外）
	bc.set_view_size(bc._zoom_hi)
	bc.focus_on_world(Vector3(0.0, 0.0, 0.0))
	var f: Vector3 = bc.global_position - bc._offset
	_check(absf(f.x - 32.0) < 0.01 and absf(f.z - 32.0) < 0.01,
			"A5 缩到底时焦点被居中到 (32,32)，实测 (%.2f,%.2f)" % [f.x, f.z])


# ------------------------------------------------------------
# B 段：集成（真场景 + 真输入管线 + HUD）
# ------------------------------------------------------------

func _part_b() -> void:
	print("--- B 段：集成 ---")
	# 清掉 A 段的临时相机：它们也在 "iso_cam" 组里，会让 HUD 抓到错的那台
	for c in _temp_cams:
		c.remove_from_group(ISO_CAM.GROUP)
		c.queue_free()
	_temp_cams.clear()
	await get_tree().process_frame

	var main: Node = load("res://Scenes/Main3D.tscn").instantiate()
	add_child(main)
	for i in range(40):
		await get_tree().process_frame

	var mcam = main.get("_cam")
	_check(mcam != null, "B1 Main3D 相机已装配")
	if mcam == null:
		return
	var s_before: float = mcam.size
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP
	ev.pressed = true
	ev.position = get_viewport().get_visible_rect().size * 0.5
	ev.factor = 1.0
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	for i in range(30):
		await get_tree().physics_frame
		await get_tree().process_frame
	_check(mcam.size < s_before - 0.5,
			"B2 真实输入管线注入滚轮：size %.2f → %.2f（应变小=放大）"
			% [s_before, mcam.size])

	var vh: Node = main.get_node_or_null("ViewHint")
	var zl = vh.get("_label") if vh != null else null
	var txt: String = str(zl.text) if zl != null else "-"
	# 必须断言 is_visible_in_tree()，不能只看 zl.visible ——
	# 提示层如果被挂在"基地模式会整体隐藏"的 HUD 下，
	# 标签自身 visible 仍是 true，但祖先不可见 → 屏幕上什么都没有。
	_check(zl != null and zl.is_visible_in_tree(),
			"B3 视野提示已亮（含祖先可见性）：visible=%s in_tree=%s text=\"%s\""
			% [str(zl.visible) if zl != null else "-",
			   str(zl.is_visible_in_tree()) if zl != null else "-", txt])
	_check(mcam.zoom_ratio() > 1.0,
			"B4 视野倍数 zoom_ratio=%.3f（>1 表示放大）" % mcam.zoom_ratio())
	# 直接锁住这次的回归：基地模式下 HUD 整体是隐藏的，提示层不能挂在它下面
	var hud_vis: bool = (main.get_node("HUD") as CanvasLayer).visible
	_check(not hud_vis and zl != null and zl.is_visible_in_tree(),
			"B5 基地模式下 HUD 整体隐藏（hud.visible=%s），视野提示仍可见 —— 提示必须独立成层"
			% str(hud_vis))

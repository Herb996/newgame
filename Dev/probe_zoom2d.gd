extends Node
## Dev 探针（临时，验证完即删）— 2D 滚轮缩放自检
##
## A 段：裸相机上的缩放数学（步进对称 / 光标锚点 / 上下限 / 取景收敛 / 边界钳制）
## B 段：真 Main.tscn 里走**真实输入管线**注入滚轮，并确认提示层亮起
##
## 为什么分两段（照抄 3D 版 probe_zoom.gd 的思路）：A 段能精确控制锚点屏幕坐标
## （headless 下鼠标位置不可控），B 段才能覆盖"事件会不会被 HUD 吞掉""相机有没有挂对组"。

const CAM := preload("res://Scripts/camera_controller.gd")

## 探针自己写痕迹文件：本机 shell 抓 stdout 不可靠，进程被强杀时更是什么都不剩。
## 路径在 user:// 下（= %APPDATA%/Godot/app_userdata/SteamPunkExtraction/）。
const TRACE := "user://_probe_zoom2d_trace.txt"

var _fails: Array = []
var _n := 0
var _temp: Array = []


func _trace(msg: String) -> void:
	var f := FileAccess.open(TRACE, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(TRACE, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(msg)
	f.flush()


func _check(ok: bool, msg: String) -> void:
	_n += 1
	if not ok:
		_fails.append(msg)
	print("[Zoom2D] %s %s" % ["OK  " if ok else "FAIL", msg])
	_trace("%s %s" % ["OK  " if ok else "FAIL", msg])


func _ready() -> void:
	_trace("--- 探针启动 ---")
	await _part_a()
	_trace("--- A 段结束 ---")
	await _part_b()
	_trace("--- B 段结束，失败 %d 项 ---" % _fails.size())
	print("=== [Zoom2D] 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		print("[Zoom2D] !! ", m)
	get_tree().quit(0 if _fails.is_empty() else 1)


# ------------------------------------------------------------
# A 段：缩放数学
# ------------------------------------------------------------

func _make_cam(map_px: float) -> Camera2D:
	var cam: Camera2D = CAM.new()
	add_child(cam)
	cam.setup(Vector2(map_px, map_px), null)
	_temp.append(cam)
	return cam


func _part_a() -> void:
	print("--- A 段：缩放数学 ---")
	# headless 的根视口只有 64×64，"视口 ÷ 地图收敛下限"那条路会被这个尺寸掩盖掉
	# （64/4096 远小于 zoom_min，永远撞不到收敛分支）。显式撑到 1080p 再测。
	get_tree().root.size = Vector2i(1920, 1080)
	await get_tree().process_frame
	var vp: Vector2 = get_viewport().get_visible_rect().size
	print("[Zoom2D] 视口 = %s" % str(vp))

	# A1 进 / 出必须互为倒数，否则来回滚会一路漂小
	var cam := _make_cam(8192.0)
	var prod: float = cam._step_factor(1.0) * cam._step_factor(-1.0)
	_check(absf(prod - 1.0) < 1e-9,
			"A1 单档乘数互为倒数：%.6f × %.6f = %.9f"
			% [cam._step_factor(1.0), cam._step_factor(-1.0), prod])
	var s0: float = cam._zoom_target
	for _i in range(3):
		cam._zoom_by(cam._step_factor(1.0))
	var s_up: float = cam._zoom_target
	for _i in range(3):
		cam._zoom_by(cam._step_factor(-1.0))
	_check(absf(cam._zoom_target - s0) < 1e-6,
			"A1 步进对称：%.4f →(上3格)→ %.4f →(下3格)→ %.4f（应回到 %.4f）"
			% [s0, s_up, cam._zoom_target, s0])

	# A2 缩放时光标下的地图点应钉住不动
	var pts: Array = [
		vp * Vector2(0.5, 0.5), vp * Vector2(0.5, 0.22),
		vp * Vector2(0.24, 0.5), vp * Vector2(0.72, 0.68),
	]
	for p in pts:
		cam.zoom = Vector2(1.0, 1.0)
		cam.global_position = Vector2(4096.0, 4096.0)
		cam.reset_smoothing()
		var w0: Vector2 = cam.global_position + (p - vp * 0.5) / cam.zoom
		cam._apply_zoom(cam.zoom.x, cam.zoom.x * 1.6, p)
		var w1: Vector2 = cam.global_position + (p - vp * 0.5) / cam.zoom
		_check((w0 - w1).length() < 0.05,
				"A2 光标锚点 (%.0f,%.0f)：地图点 (%.2f,%.2f) → (%.2f,%.2f)，偏移 %.4f px"
				% [p.x, p.y, w0.x, w0.y, w1.x, w1.y, (w0 - w1).length()])

	# A3 反复滚不越界
	for _i in range(200):
		cam._zoom_by(cam._step_factor(1.0))
	_check(is_equal_approx(cam._zoom_target, cam._zoom_hi),
			"A3 一直放大：target=%.3f 停在 hi=%.3f（config 上限 3.0）"
			% [cam._zoom_target, cam._zoom_hi])
	for _i in range(400):
		cam._zoom_by(cam._step_factor(-1.0))
	_check(is_equal_approx(cam._zoom_target, cam._zoom_lo),
			"A3 一直缩小：target=%.3f 停在 lo=%.3f" % [cam._zoom_target, cam._zoom_lo])
	_check(cam._zoom_lo >= 0.35 - 1e-6,
			"A3 下限不许低于 config 的 zoom_min=0.35：实测 lo=%.3f" % cam._zoom_lo)

	# A4 缩到底时地图应刚好入画（基地 64×64 格 × 64px = 4096）
	var bcam := _make_cam(4096.0)
	var expect_lo: float = maxf(0.35, maxf(vp.x / 4096.0, vp.y / 4096.0))
	_check(absf(bcam._zoom_lo - expect_lo) < 0.01,
			"A4 基地(4096px)缩放下限被收敛到 %.3f（期望 %.3f = 视口/地图）"
			% [bcam._zoom_lo, expect_lo])
	_check(expect_lo > 0.35 and bcam._zoom_lo > 0.35 + 1e-6,
			"A4 该收敛确实发生了（下限 %.3f > config 的 zoom_min 0.35）" % bcam._zoom_lo)

	# A5 放大后平移必须被钳在图内（否则能飘到地图外的白边）
	var pcam := _make_cam(8192.0)
	pcam.zoom_to(2.0)
	pcam.global_position = Vector2(-99999.0, -99999.0)
	pcam._clamp_to_bounds()
	var vis: Vector2 = vp / pcam.zoom
	_check(pcam.global_position.x >= vis.x * 0.5 - 0.01
			and pcam.global_position.y >= vis.y * 0.5 - 0.01,
			"A5 放大后平移钳在图内：pos=(%.1f,%.1f)，半视野=(%.1f,%.1f)"
			% [pcam.global_position.x, pcam.global_position.y, vis.x * 0.5, vis.y * 0.5])
	pcam.global_position = Vector2(99999.0, 99999.0)
	pcam._clamp_to_bounds()
	_check(pcam.global_position.x <= 8192.0 - vis.x * 0.5 + 0.01,
			"A5 另一侧同样钳住：pos=(%.1f,%.1f)" % [pcam.global_position.x, pcam.global_position.y])

	# A6 缩到底时：视野（视口/倍数）仍然小于地图 → 相机遇界钳制，而不是被居中
	pcam.zoom_to(pcam._zoom_lo)
	pcam.global_position = Vector2(10.0, 10.0)
	pcam._clamp_to_bounds()
	var vis_lo: Vector2 = vp / pcam._zoom_lo
	_check(absf(pcam.global_position.x - vis_lo.x * 0.5) < 0.01
			and absf(pcam.global_position.y - vis_lo.y * 0.5) < 0.01,
			"A6 缩到底 + 图仍比视野大：钳到下边界 (%.1f,%.1f)（半视野 (%.1f,%.1f)，不该被居中到 4096）"
			% [pcam.global_position.x, pcam.global_position.y, vis_lo.x * 0.5, vis_lo.y * 0.5])
	# 反过来：地图比视野小（小图 + 缩到底）时必须固定在图心，否则会飘出地图边
	var scam := _make_cam(1024.0)
	scam.zoom_to(scam._zoom_lo)
	scam.global_position = Vector2(5.0, 5.0)
	scam._clamp_to_bounds()
	_check(absf(scam.global_position.x - 512.0) < 0.01,
			"A6 地图(1024)比视野小时被居中到图心 (%.1f,%.1f)"
			% [scam.global_position.x, scam.global_position.y])


# ------------------------------------------------------------
# B 段：集成（真场景 + 真输入管线 + 提示层）
# ------------------------------------------------------------

func _part_b() -> void:
	print("--- B 段：集成 ---")
	_trace("B: 清理 A 段临时相机")
	for c in _temp:
		c.remove_from_group(CAM.GROUP)
		c.queue_free()
	_temp.clear()
	await get_tree().process_frame

	_trace("B: 实例化 Main.tscn")
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	_trace("B: Main.tscn 已加入，等 180 帧")
	for i in range(180):
		await get_tree().process_frame
		if i % 30 == 29:
			_trace("B: 已等 %d 帧" % (i + 1))
	_trace("B: 等待结束")

	var cam = get_tree().get_first_node_in_group(CAM.GROUP)
	_check(cam != null, "B1 场景里的相机已挂进 %s 组" % CAM.GROUP)
	if cam == null:
		return
	var z0: float = cam.zoom.x
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP
	ev.pressed = true
	ev.position = get_viewport().get_visible_rect().size * 0.5
	ev.factor = 1.0
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	for _i in range(40):
		await get_tree().physics_frame
		await get_tree().process_frame
	_check(cam.zoom.x > z0 + 0.05,
			"B2 真实输入管线注入滚轮：zoom %.3f → %.3f（应变大 = 放大）"
			% [z0, cam.zoom.x])

	var vh: Node = main.get_node_or_null("ViewHint")
	var zl = vh.get("_label") if vh != null else null
	# 必须断言 is_visible_in_tree()：提示层若被挂到"基地模式整体隐藏"的 HUD 下，
	# 标签自身 visible 仍是 true，但屏幕上什么都没有。
	_check(zl != null and zl.is_visible_in_tree(),
			"B3 视野提示已亮（含祖先可见性）：visible=%s in_tree=%s text=\"%s\""
			% [str(zl.visible) if zl != null else "-",
			   str(zl.is_visible_in_tree()) if zl != null else "-",
			   str(zl.text) if zl != null else "-"])
	_check(cam.zoom_ratio() > 1.0,
			"B4 视野倍数 zoom_ratio=%.3f（>1 表示放大）" % cam.zoom_ratio())
	_check(cam.zoom_hud_enabled(),
			"B5 zoom_hud_enabled() 可被提示层询问（config camera.zoom_hud）")

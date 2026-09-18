extends Camera2D
## ============================================================
## CameraController — 2D 入口（Scenes/Main.tscn）的相机控制器
##
## 平移：WASD / 方向键；鼠标贴到窗口边自动朝该方向滚（edge_pan_*）；
##       F（可配 return_key）一键回到玩家。
## 缩放：滚轮 / 触控板捏合 —— 平滑逼近目标倍数，可锚定光标下的地图点。
##
## 与 3D 入口（iso_camera_3d.gd）刻意保持同一套手感：
##   · 每档乘数进 / 出互为倒数（来回滚不会一路漂小）；
##   · 同样的光标锚点、同样的「视野 ×N」提示层（view_hint.gd 靠组名找相机）；
##   · 同名配置项（zoom_min / zoom_max / zoom_step / zoom_smooth …）。
## 只有单位不同：Camera2D.zoom 是「放大倍数」（越大越近），
## 3D 正交相机用的是 size（越大越远）。所以 camera.zoom_min 是"最小放大倍数"。
## 相机脱离玩家独立存在，由 main.gd 在进入基地/进局时创建并挂载地图边界。
## camera.* 全部来自 Data/config.json，禁止硬编码。
## ============================================================

## 可缩放相机统一挂这个组，view_hint.gd 靠它找"当前生效的那台相机"
## （进基地/进局都会重建相机，所以提示层每帧校验有效性）。
## 名字沿用 3D 时期的 iso_cam：两条渲染线共用一个提示层，改名要同时动三处。
const GROUP := &"iso_cam"
const HUD_HOLD := 1.5              # 提示保持时长（秒），与 view_hint.gd 一致

var pan_speed := 400.0
var _return_key := KEY_F
var _map_size: Vector2 = Vector2.ZERO  # 地图像素尺寸；ZERO = 不限制边界
var _player: CharacterBody2D = null

# --- 滚轮缩放（config 的 camera.zoom_*） ---
var zoom_min := 0.35               # 最小放大倍数 = 视野最远
var zoom_max := 3.0                # 最大放大倍数 = 视野最近
var zoom_step := 0.12              # 每档比例
var zoom_smooth := 14.0            # 平滑逼近速度，<=0 = 瞬间到位
var zoom_at_cursor := true         # 以鼠标光标为锚点缩放
var zoom_invert := false           # 反转滚轮方向
var zoom_fit_bounds := true        # 缩到最远时至少整张地图入画（下限按视口收敛）
var zoom_hud := true               # 是否显示「视野 ×N」提示（view_hint 会问）

# --- 边缘滚屏（config 的 camera.edge_pan_*）：鼠标贴边 → 画面往那边走 ---
var edge_pan_enabled := true       # 总开关
var edge_pan_margin := 24.0        # 触发边距（逻辑像素）
var edge_pan_speed_mult := 1.0     # 相对 pan_speed 的倍率
var edge_pan_ignore_ui := true     # 鼠标悬停在可交互控件上时不滚（面板/按钮）

## 探针用：非 INF 时用它代替真实鼠标位置。生产路径恒为 INF。
var _mouse_override := Vector2.INF
## 探针用：忽略"窗口必须有焦点"这一条（自动化进程里窗口常常拿不到焦点）。
## 生产路径恒为 false —— 焦点门是真实需要的，不能因为不好测就砍掉。
var _ignore_focus_gate := false

var _zoom_target := 1.0            # 平滑目标（放大倍数）
var _zoom_lo := 0.35               # 实际生效的下限（可能被地图尺寸收紧）
var _zoom_hi := 3.0
var _zoom_ref := 1.0               # 基准倍数，提示条用它算 ×倍数
var _zoom_idle := 999.0            # 距上次滚轮的秒数（提示淡出用）


func _ready() -> void:
	pan_speed = float(Config.get_value("camera.pan_speed", 400.0))
	_return_key = int(Config.get_value("camera.return_key", KEY_F))
	zoom_min = float(Config.get_value("camera.zoom_min", 0.35))
	zoom_max = float(Config.get_value("camera.zoom_max", 3.0))
	zoom_step = float(Config.get_value("camera.zoom_step", 0.12))
	zoom_smooth = float(Config.get_value("camera.zoom_smooth", 14.0))
	zoom_at_cursor = bool(Config.get_value("camera.zoom_at_cursor", true))
	zoom_invert = bool(Config.get_value("camera.zoom_invert", false))
	zoom_fit_bounds = bool(Config.get_value("camera.zoom_fit_bounds", true))
	zoom_hud = bool(Config.get_value("camera.zoom_hud", true))
	edge_pan_enabled = bool(Config.get_value("camera.edge_pan_enabled", true))
	edge_pan_margin = float(Config.get_value("camera.edge_pan_margin", 24.0))
	edge_pan_speed_mult = float(Config.get_value("camera.edge_pan_speed_mult", 1.0))
	edge_pan_ignore_ui = bool(Config.get_value("camera.edge_pan_ignore_ui", true))
	add_to_group(GROUP)
	_zoom_target = zoom.x
	_zoom_ref = zoom.x
	_refresh_zoom_limits()


## 由 main.gd 调用：告知地图尺寸（用于边界限制）+ 玩家节点（用于跟随/回到玩家）
func setup(map_size: Vector2, player_node: CharacterBody2D) -> void:
	_map_size = map_size
	_player = player_node
	# 出生时相机先对齐玩家（平滑过渡）
	if player_node:
		global_position = player_node.global_position
	# 地图尺寸到手后限位才有意义：基地比视口小 → 缩到底正好装下整块基地
	_refresh_zoom_limits()
	reset_smoothing()


## 把某个世界矩形框进视口（居中 + 缩放到刚好装下，四周留 margin_px 像素边距）。
## 用于进基地时一眼看全所有建筑。
func frame_world_rect(rect: Rect2, margin_px: float = 80.0) -> void:
	_refresh_zoom_limits()
	var vp := get_viewport_rect().size
	var rw := maxf(rect.size.x, 1.0)
	var rh := maxf(rect.size.y, 1.0)
	var avail_x := maxf(vp.x - margin_px * 2.0, 1.0)
	var avail_y := maxf(vp.y - margin_px * 2.0, 1.0)
	var fit := minf(avail_x / rw, avail_y / rh)
	_zoom_target = clampf(fit, _zoom_lo, _zoom_hi)
	_zoom_ref = _zoom_target
	global_position = rect.get_center()
	_apply_zoom(zoom.x, _zoom_target)
	_clamp_to_bounds()
	_zoom_idle = 999.0


## 把镜头中心平移到某个世界坐标（小地图点击导航用），保持当前缩放不变。
## 越过地图边缘会被 _clamp_to_bounds 收住；相机开了位置平滑，这里立刻落位，
## 免得上层（探针/手感）等到镜头慢慢滑过去。
func focus_world_pos(world_pos: Vector2) -> void:
	global_position = world_pos
	_clamp_to_bounds()
	reset_smoothing()


func _physics_process(delta: float) -> void:
	if get_tree().paused:
		return
	# WASD（物理键位，不随键盘布局漂移）+ 方向键（复用 ui_* 动作）
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if Input.is_physical_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		dir.x += 1.0
	if Input.is_physical_key_pressed(KEY_W):
		dir.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		dir.y += 1.0
	# 边缘滚屏：鼠标贴边时给出一个方向，和键盘方向相加
	# （倍率只作用在它自己那部分，所以"贴边 + 按 W"不会变成两倍速）
	var edge := _edge_pan_dir()
	if edge != Vector2.ZERO:
		edge *= clampf(edge_pan_speed_mult, 0.0, 4.0)
	var move := dir + edge
	# 归一化 + 限幅：斜着推角落不比正面快；键盘与边缘同时触发也不超速
	if move.length() > 0.001:
		position += move.normalized() * minf(move.length(), 1.0) * pan_speed * delta
		_clamp_to_bounds()
	# 回到玩家
	if Input.is_physical_key_pressed(_return_key) and _player:
		global_position = _player.global_position
	_step_zoom(delta)


# ------------------------------------------------------------
# 边缘滚屏：鼠标贴到窗口边 → 画面往该方向滚（RTS 手感）
# ------------------------------------------------------------

## 允许滚屏的条件：开关开 + 窗口有焦点 + （可选）鼠标下没有"会抢输入的模态 UI"。
##   · 没焦点（alt-tab 切走）：鼠标停在窗口内最后位置会一直滚，故要求有焦点；
##   · 鼠标下有 STOP 的模态控件（仓库/雕像面板、弹窗按钮）：玩家在下指令，不该顺手带走画面。
## 底部特例：常驻底部菜单栏占屏高 1/5，鼠标贴底必然压在栏上——只要鼠标进到最底 margin
##   就**无条件允许向下滚**（位置兜底，不依赖 hovered 控件的父链判断），保证"推到最底边就往下滚"。
##   左右上三边仍尊重 ignore_ui（且 _is_menu_bar_control 让菜单栏在非底部区域也不误挡）。
func edge_pan_active() -> bool:
	if not edge_pan_enabled:
		return false
	var win := get_window()
	if win == null:
		return false
	if not _ignore_focus_gate and not win.has_focus():
		return false
	if edge_pan_ignore_ui:
		var mp := get_viewport().get_mouse_position()
		var vp := get_viewport_rect().size
		var margin := clampf(edge_pan_margin, 1.0, minf(vp.x, vp.y) * 0.45)
		if vp.y > 0.0 and mp.y >= vp.y - margin:
			return true   # 最底边：菜单栏不挡向下滚屏
		var hc := get_viewport().gui_get_hovered_control()
		if hc != null and not _is_menu_bar_control(hc):
			return false
	return true


## 沿父链判断某控件是否属于常驻底部菜单栏（CanvasLayer "MenuBar" 在 group "menu_bar"）。
## ⚠ `n` 必须显式声明成 **Node**：`var n := c` 会被推断成 Control，
## 于是 `n = n.get_parent()`（返回 Node）每帧抛「Trying to assign Node to Control」——
## 而且是**运行时**错误，会把 `edge_pan_active()` 的剩余代码整个吞掉
## （见 MEMORY「隔山打牛」）。悬停到任何非菜单栏控件上都会踩到。
func _is_menu_bar_control(c: Control) -> bool:
	var n: Node = c
	while n != null:
		if n.is_in_group("menu_bar"):
			return true
		n = n.get_parent()
	return false


func _edge_pan_dir() -> Vector2:
	if not edge_pan_active():
		return Vector2.ZERO
	var m := _mouse_override if _mouse_override != Vector2.INF \
			else get_viewport().get_mouse_position()
	return edge_pan_dir_at(m)


## 纯函数：给定鼠标位置（视口坐标）算出平移方向，分量为 -1/0/1。
## 拆出来的原因 —— 探针可以直接喂坐标断言，不必真的去挪用户的鼠标。
## 底部不为菜单栏预留：鼠标一路推到窗口最底边就向下滚（原始手感）。
func edge_pan_dir_at(m: Vector2) -> Vector2:
	var vp := get_viewport_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return Vector2.ZERO
	# 鼠标在视口外（多显示器、拖出窗口）→ 不滚
	if m.x < 0.0 or m.y < 0.0 or m.x > vp.x or m.y > vp.y:
		return Vector2.ZERO
	# 边距上限 = 短边的 45%：否则窗口一变小，整个屏幕都算触发区 → 一进游戏就自己滚
	var margin := clampf(edge_pan_margin, 1.0, minf(vp.x, vp.y) * 0.45)
	var d := Vector2.ZERO
	if m.x <= margin:
		d.x = -1.0
	elif m.x >= vp.x - margin:
		d.x = 1.0
	if m.y <= margin:
		d.y = -1.0
	elif m.y >= vp.y - margin:
		d.y = 1.0
	return d


# ------------------------------------------------------------
# 缩放：输入
# ------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if get_tree().paused:
		return
	# 触控板双指捏合：factor > 1 就是放大，和 zoom 的方向天然一致（不像 3D 要取倒数）
	if event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		if absf(mg.factor - 1.0) > 0.0005:
			_zoom_by(mg.factor)
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return
	var dir := 0.0
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			dir = 1.0
		MOUSE_BUTTON_WHEEL_DOWN:
			dir = -1.0
		_:
			return
	if zoom_invert:
		dir = -dir
	_zoom_by(_step_factor(dir))


## 一档滚轮对应的 zoom 乘数。进 / 出必须互为倒数 ——
## 若 up 用 (1-r)、down 用 (1+r)，0.88 × 1.12 = 0.9856，
## "滚上一格再滚下一格"回不到原位，会一路慢慢漂小。
func _step_factor(dir: float) -> float:
	var r := maxf(zoom_step, 0.001)
	return 1.0 + r if dir > 0.0 else 1.0 / (1.0 + r)


## 缩放一档：只改"平滑目标"，真正生效的 zoom 由 _step_zoom() 每帧逼近。
func _zoom_by(factor: float) -> void:
	_refresh_zoom_limits()          # 窗口尺寸若变过，限位/取景跟着自愈
	if _zoom_target <= 0.0:
		_zoom_target = zoom.x
	var before := _zoom_target
	_zoom_target = clampf(_zoom_target * factor, _zoom_lo, _zoom_hi)
	if is_equal_approx(before, _zoom_target):
		return                      # 已贴到上下限，不算一次有效操作
	_zoom_idle = 0.0


## 直接设定放大倍数（调试 / 探针用）：走与滚轮同一条应用路径，不绕开限位。
## 名字必须是 zoom_to 而不是 set_zoom —— Camera2D 原生就有 set_zoom(Vector2)，
## 在子类里用同名方法会顶掉原生 setter，静态类型调用还会直接判解析错误。
func zoom_to(v: float) -> void:
	_refresh_zoom_limits()
	_zoom_target = clampf(v, _zoom_lo, _zoom_hi)
	_zoom_ref = _zoom_target
	_apply_zoom(zoom.x, _zoom_target)
	_zoom_idle = 999.0


func _step_zoom(delta: float) -> void:
	if _zoom_target <= 0.0:
		_zoom_target = zoom.x
	_zoom_idle += delta
	if is_equal_approx(zoom.x, _zoom_target):
		if zoom.x != _zoom_target:
			_apply_zoom(zoom.x, _zoom_target)
		return
	var k := 1.0 if zoom_smooth <= 0.0 else clampf(zoom_smooth * delta, 0.0, 1.0)
	var next := lerpf(zoom.x, _zoom_target, k)
	if absf(next - _zoom_target) <= _zoom_target * 0.0015:
		next = _zoom_target         # 收尾吸附，免得无限逼近
	_apply_zoom(zoom.x, next)


## 真正改 zoom，并把"光标下的地图点"钉住不动。
## screen 传 Vector2.INF 表示"取当前鼠标位置"（生产路径）；
## 显式传点则用该点作锚（探针用，便于精确断言）。
func _apply_zoom(prev: float, next: float, screen: Vector2 = Vector2.INF) -> void:
	if prev <= 0.0:
		prev = zoom.x
	if next <= 0.0 or prev <= 0.0:
		return
	if zoom_at_cursor and not is_equal_approx(prev, next):
		var p := screen
		if p == Vector2.INF:
			p = get_viewport().get_mouse_position()
		# Camera2D（DRAG_CENTER 锚点）的屏幕→世界：world = 相机位置 + (屏幕点 − 视口中心)/zoom
		# 要让光标下的世界点不动，相机位置就得反向补偿两档 zoom 之差
		global_position += (p - get_viewport_rect().size * 0.5) * (1.0 / prev - 1.0 / next)
	zoom = Vector2(next, next)
	_clamp_to_bounds()
	# 位置平滑会把上面"钉住光标"的补偿糊掉（相机慢半拍追过去），锚定后立刻落到位
	reset_smoothing()


## 上下限：窗口尺寸或地图尺寸变了都要重算（否则会出现"缩放没反应"）。
func _refresh_zoom_limits() -> void:
	_zoom_lo = maxf(zoom_min, 0.02)
	var hi := maxf(zoom_max, _zoom_lo + 0.01)
	var vp := get_viewport_rect().size
	if zoom_fit_bounds and vp.x > 0.0 and vp.y > 0.0 \
			and _map_size.x > 0.0 and _map_size.y > 0.0:
		# 视口 ÷ 地图 = 让整张地图刚好入画的倍数；比它还小就只能看到图外的空白
		var fit := maxf(vp.x / _map_size.x, vp.y / _map_size.y)
		if fit > _zoom_lo:
			_zoom_lo = minf(fit, hi - 0.01)
	_zoom_hi = maxf(hi, _zoom_lo + 0.01)
	_zoom_target = clampf(_zoom_target, _zoom_lo, _zoom_hi)
	var cur := clampf(zoom.x, _zoom_lo, _zoom_hi)
	if not is_equal_approx(cur, zoom.x):
		_apply_zoom(zoom.x, cur)


func _clamp_to_bounds() -> void:
	if _map_size == Vector2.ZERO:
		return
	var vp := get_viewport_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return
	# 视野（世界像素）= 视口 ÷ 放大倍数 —— 缩放会改变"看得见多少世界"，
	# 边界必须跟着变，否则放大之后能一路平移到地图外的空白里
	var visible := vp / maxf(zoom.x, 0.001)
	# 地图比视野还小（基地 + 缩到底）→ 相机固定在图中心
	if _map_size.x <= visible.x or _map_size.y <= visible.y:
		position = _map_size * 0.5
		return
	var half := visible * 0.5
	position = Vector2(
		clampf(position.x, half.x, _map_size.x - half.x),
		clampf(position.y, half.y, _map_size.y - half.y),
	)


# ------------------------------------------------------------
# 供 view_hint.gd 读取（两条渲染线共用同一个提示层，接口保持一致）
# ------------------------------------------------------------

func zoom_ratio() -> float:
	return zoom.x / _zoom_ref if _zoom_ref > 0.0 else 1.0


func zoom_hud_idle() -> float:
	return _zoom_idle


func zoom_hud_active() -> bool:
	return _zoom_idle < HUD_HOLD


func zoom_hud_enabled() -> bool:
	return zoom_hud

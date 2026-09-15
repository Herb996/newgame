extends Camera3D
## ============================================================
## IsoCamera3D — 3D 正交等距相机控制器（路线 2「双轨制」渲染层）
##
## 由 main3d.gd 创建并 setup()，替代 2D 的 camera_controller.gd：
##   · WASD / 方向键   → 沿"屏幕方向的水平分量"在 XZ 平面平移
##   · 鼠标滚轮        → 缩放（正交投影改 size）：平滑过渡 + 以光标为锚点
##   · 触控板双指捏合  → 缩放
##   · F（可配置）     → 一键回到玩家
##   · 取景钳制        → 视野不越出地图；缩到底正好装下整张图
##
## 参数全部读 config：camera3d.* / camera.return_key，禁止硬编码。
## 注意：与 2D 版一致，相机独立于玩家存在（不是父子关系）。
## ============================================================

const GROUP := &"iso_cam"          # 视野提示层（view_hint.gd）靠它找到相机
const FIT_MARGIN := 1.06           # 缩到底时地图四周留的余地
const HUD_HOLD := 1.5              # 缩放提示的保持时长（秒），HUD 用

var pan_speed := 26.0              # 世界单位/秒
var zoom_min := 24.0               # 正交 size 下限（数值越小越"近"= 放得越大）
var zoom_max := 150.0              # 正交 size 上限（数值越大越"远"= 缩得越小）
var zoom_step := 0.12              # 每档滚轮的缩放比例
var zoom_smooth := 14.0            # 平滑逼近速度，<=0 表示瞬间到位
var zoom_at_cursor := true         # 以鼠标光标为缩放锚点（false = 以屏幕中心）
var zoom_invert := false           # 反转滚轮方向
var zoom_fit_bounds := true        # 缩放下限按地图尺寸收敛（缩到底 = 整张图）
var initial_size := 46.0

var _return_key := KEY_F
var _target: Node2D = null         # 2D 逻辑层玩家（用于 F 键回中）
var _tile := 16.0
var _map_w := 0.0                  # 地图尺寸（世界单位 = 格数）
var _map_h := 0.0
var _offset := Vector3.ZERO        # 焦点 → 相机 的固定位移（保持等距视角不变）
var _pitch := 45.5                 # 俯角（度）：取景钳制要做竖直压缩换算

var _zoom_target := 0.0            # 平滑目标（size）
var _zoom_lo := 24.0               # 实际生效的 size 区间（可能被地图尺寸收紧）
var _zoom_hi := 150.0
var _zoom_ref := 46.0              # 本模式的基准 size，HUD 用它算"×倍数"
var _zoom_idle := 999.0            # 距上次滚轮的秒数（HUD 提示淡出用）


func _ready() -> void:
	add_to_group(GROUP)
	pan_speed = float(Config.get_value("camera3d.pan_speed", 26.0))
	zoom_min = float(Config.get_value("camera3d.zoom_min", 24.0))
	zoom_max = float(Config.get_value("camera3d.zoom_max", 150.0))
	zoom_step = float(Config.get_value("camera3d.zoom_step", 0.12))
	zoom_smooth = float(Config.get_value("camera3d.zoom_smooth", 14.0))
	zoom_at_cursor = bool(Config.get_value("camera3d.zoom_at_cursor", true))
	zoom_invert = bool(Config.get_value("camera3d.zoom_invert", false))
	zoom_fit_bounds = bool(Config.get_value("camera3d.zoom_fit_bounds", true))
	initial_size = float(Config.get_value("camera3d.size", 46.0))
	_pitch = float(Config.get_value("camera3d.pitch_deg", 45.5))
	_return_key = int(Config.get_value("camera.return_key", KEY_F))
	_zoom_lo = maxf(zoom_min, 4.0)
	_zoom_hi = maxf(zoom_max, _zoom_lo + 1.0)
	_zoom_target = initial_size
	_zoom_ref = initial_size


## 由 main3d.gd 调用：告知 2D 玩家、瓦片尺寸、当前聚焦的世界点。
func setup(target: Node2D, tile_size: int, focus_world: Vector3) -> void:
	_target = target
	_tile = float(tile_size)
	# 记录"焦点 → 相机"的位移，之后回中只需换焦点
	_offset = global_position - focus_world
	size = initial_size
	_zoom_target = size
	_zoom_ref = size
	_zoom_idle = 999.0


func set_bounds(w_cells: int, h_cells: int) -> void:
	_map_w = float(w_cells)
	_map_h = float(h_cells)
	_refresh_zoom_limits()


## 设定本模式的基准视野（正交 size）。必须在 setup() 之后调用 ——
## 基地 64×64 与局内 128×128 的合适倍率不同，基准也跟着变。
func set_view_size(v: float) -> void:
	size = clampf(v, _zoom_lo, _zoom_hi)
	_zoom_target = size
	_zoom_ref = size
	_refresh_zoom_limits()
	_clamp_to_bounds()


# ------------------------------------------------------------
# 缩放：限位 / 输入 / 平滑
# ------------------------------------------------------------

## 缩放下限：最多缩到"整张地图刚好装下"，免得继续滚只剩一片黑。
## 正交相机竖直可见 = size，而地面在竖直方向被俯角压扁，可见地面高度 = size / sin(俯角)；
## 水平方向不受俯角影响，可见宽度 = size × 视口宽高比。
func _refresh_zoom_limits() -> void:
	_zoom_lo = maxf(zoom_min, 4.0)
	var hi := maxf(zoom_max, _zoom_lo + 1.0)
	if zoom_fit_bounds and _map_w > 0.0 and _map_h > 0.0:
		var aspect := _viewport_aspect()
		var s := maxf(sin(deg_to_rad(_pitch)), 0.05)
		var fit := maxf(_map_h * s, _map_w / maxf(aspect, 0.05)) * FIT_MARGIN
		hi = minf(hi, fit)
	_zoom_hi = maxf(hi, _zoom_lo + 1.0)
	_zoom_target = clampf(_zoom_target, _zoom_lo, _zoom_hi)
	size = clampf(size, _zoom_lo, _zoom_hi)


func _unhandled_input(event: InputEvent) -> void:
	if get_tree().paused:
		return
	# 触控板双指捏合：factor > 1 是放大（正交 size 要变小，所以取倒数）
	if event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		if absf(mg.factor - 1.0) > 0.0005:
			_zoom_by(1.0 / maxf(mg.factor, 0.01))
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


## 一档滚轮对应的 size 乘数。进 / 出必须互为倒数 ——
## 原来 up 用 (1-r)、down 用 (1+r)，0.88 × 1.12 = 0.9856，
## 于是"滚上一格再滚下一格"回不到原位，会一路慢慢漂小。
func _step_factor(dir: float) -> float:
	var r := maxf(zoom_step, 0.001)
	return 1.0 / (1.0 + r) if dir > 0.0 else 1.0 + r


## 缩放一档：只改"平滑目标"，真正生效的 size 由 _step_zoom() 每帧逼近。
func _zoom_by(factor: float) -> void:
	_refresh_zoom_limits()          # 窗口尺寸若变过，限位/取景跟着自愈
	if _zoom_target <= 0.0:
		_zoom_target = size
	var before := _zoom_target
	_zoom_target = clampf(_zoom_target * factor, _zoom_lo, _zoom_hi)
	if is_equal_approx(before, _zoom_target):
		return                      # 已贴到上下限，不算一次有效操作
	_zoom_idle = 0.0


func _step_zoom(delta: float) -> void:
	if _zoom_target <= 0.0:
		_zoom_target = size
	_zoom_idle += delta
	if is_equal_approx(size, _zoom_target):
		if size != _zoom_target:
			_apply_zoom(size, _zoom_target)
		return
	var k := 1.0 if zoom_smooth <= 0.0 else clampf(zoom_smooth * delta, 0.0, 1.0)
	var next := lerpf(size, _zoom_target, k)
	if absf(next - _zoom_target) <= _zoom_target * 0.0015:
		next = _zoom_target         # 收尾吸附，免得无限逼近
	_apply_zoom(size, next)


## 真正改 size，并把"光标下的地面点"钉住不动。
## screen 传 Vector2.INF 表示"取当前鼠标位置"（生产路径）；
## 显式传点则用该点作锚（探针用，便于精确断言）。
func _apply_zoom(prev: float, next: float, screen: Vector2 = Vector2.INF) -> void:
	if is_equal_approx(prev, next):
		size = next
		return
	var focus := global_position - _offset
	if zoom_at_cursor and prev > 0.0:
		var vp := get_viewport()
		if vp != null:
			var mp := screen
			if not is_finite(mp.x):
				mp = vp.get_mouse_position()
			if vp.get_visible_rect().has_point(mp):
				var hit: Variant = _ground_point(mp)   # 注意：要用"旧 size"求交
				if hit != null:
					var w: Vector3 = hit
					# 正交投影下地面成像以焦点为中心按 size 线性缩放，
					# 要让光标下的地面点不动，焦点反向补偿：
					#     f1 = f0 + (1 - s1/s0) × (w - f0)
					focus += (1.0 - next / prev) * (w - focus)
	size = next
	global_position = focus + _offset
	_clamp_to_bounds()


## 屏幕点 → 地面 y=0 平面上的世界点（正交相机射线求交）。无交点返回 null。
func _ground_point(screen: Vector2) -> Variant:
	var from := project_ray_origin(screen)
	var dir := project_ray_normal(screen)
	if absf(dir.y) < 0.00001:
		return null
	var t := -from.y / dir.y
	if t <= 0.0:
		return null
	return from + dir * t


# ------------------------------------------------------------
# 视野提示层（view_hint.gd）取用
# ------------------------------------------------------------

## 当前缩放相对本模式基准的倍数（> 1 = 放大）
func zoom_ratio() -> float:
	return _zoom_ref / size if size > 0.0 else 1.0


## 距上次有效缩放过了几秒（HUD 用作淡出计时）
func zoom_hud_idle() -> float:
	return _zoom_idle


func zoom_hud_active() -> bool:
	return _zoom_idle < HUD_HOLD


# ------------------------------------------------------------
# 平移 / 回中 / 取景钳制
# ------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if get_tree().paused:
		return
	_step_zoom(delta)

	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if Input.is_physical_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		dir.x += 1.0
	if Input.is_physical_key_pressed(KEY_W):
		dir.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		dir.y += 1.0

	if dir.length() > 0.001:
		# 屏幕方向映射到世界 XZ 平面（去掉 Y 分量后归一化），视觉上"上是屏幕上"
		var right := global_transform.basis.x
		right.y = 0.0
		var fwd := -global_transform.basis.z
		fwd.y = 0.0
		if right.length() > 0.001 and fwd.length() > 0.001:
			var move := (right.normalized() * dir.x + fwd.normalized() * (-dir.y))
			move = move.normalized() * pan_speed * delta
			global_position += move
			_clamp_to_bounds()

	if _target != null and Input.is_physical_key_pressed(_return_key):
		focus_on_player()


## 把相机中心移到某个世界点（保持等距视角与缩放）
func focus_on_world(p: Vector3) -> void:
	global_position = p + _offset
	_clamp_to_bounds()


## 回到 2D 玩家位置（2D 像素 → 3D 世界单位）
func focus_on_player() -> void:
	if _target == null:
		return
	focus_on_world(Vector3(_target.global_position.x / _tile, 0.0,
			_target.global_position.y / _tile))


## 取景钳制：视野不越出地图。视口比地图大时直接居中 ——
## 否则缩到底还能一路平移到图上，半边屏幕全是黑的。
func _clamp_to_bounds() -> void:
	if _map_w <= 0.0 or _map_h <= 0.0:
		return
	var aspect := _viewport_aspect()
	var s := maxf(sin(deg_to_rad(_pitch)), 0.05)
	var half_h := size * 0.5 / s          # 可见地面高度的一半（竖直被俯角压扁）
	var half_w := size * aspect * 0.5     # 水平方向不受俯角影响
	var focus := global_position - _offset
	focus.x = _clamp_axis(focus.x, half_w, _map_w)
	focus.z = _clamp_axis(focus.z, half_h, _map_h)
	global_position = focus + _offset


func _clamp_axis(v: float, half: float, total: float) -> float:
	if half * 2.0 >= total:
		return total * 0.5
	return clampf(v, half, total - half)


func _viewport_aspect() -> float:
	var vp := get_viewport()
	if vp == null:
		return 16.0 / 9.0
	var s := vp.get_visible_rect().size
	return s.x / maxf(s.y, 1.0)

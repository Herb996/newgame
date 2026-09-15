extends Camera3D
## ============================================================
## IsoCamera3D — 3D 正交等距相机控制器（路线 2「双轨制」渲染层）
##
## 由 main3d.gd 创建并 setup()，替代 2D 的 camera_controller.gd：
##   · WASD / 方向键 → 沿"屏幕方向的水平分量"在 XZ 平面平移
##   · 鼠标滚轮      → 缩放（正交投影改 size）
##   · F（可配置）    → 一键回到玩家
##   · 方向键 / 边界  → 限制在地图范围内
##
## 参数全部读 config：camera3d.* / camera.return_key，禁止硬编码。
## 注意：与 2D 版一致，相机独立于玩家存在（不是父子关系）。
## ============================================================

var pan_speed := 26.0            # 世界单位/秒
var zoom_min := 24.0
var zoom_max := 150.0
var zoom_step := 0.12            # 每档滚轮的缩放比例
var initial_size := 46.0

var _return_key := KEY_F
var _target: Node2D = null        # 2D 逻辑层玩家（用于 F 键回中）
var _tile := 16.0
var _map_w := 0.0                 # 地图尺寸（世界单位）
var _map_h := 0.0
var _offset := Vector3.ZERO       # 焦点 → 相机 的固定位移（保持等距视角不变）


func _ready() -> void:
	pan_speed = float(Config.get_value("camera3d.pan_speed", 26.0))
	zoom_min = float(Config.get_value("camera3d.zoom_min", 24.0))
	zoom_max = float(Config.get_value("camera3d.zoom_max", 150.0))
	zoom_step = float(Config.get_value("camera3d.zoom_step", 0.12))
	initial_size = float(Config.get_value("camera3d.size", 46.0))
	_return_key = int(Config.get_value("camera.return_key", KEY_F))


## 由 main3d.gd 调用：告知 2D 玩家、瓦片尺寸、当前聚焦的世界点与地图边界。
func setup(target: Node2D, tile_size: int, focus_world: Vector3) -> void:
	_target = target
	_tile = float(tile_size)
	size = initial_size
	# 记录"焦点 → 相机"的位移，之后回中只需换焦点
	_offset = global_position - focus_world


func set_bounds(w_cells: int, h_cells: int) -> void:
	_map_w = float(w_cells)
	_map_h = float(h_cells)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		size = clampf(size * (1.0 - zoom_step), zoom_min, zoom_max)
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		size = clampf(size * (1.0 + zoom_step), zoom_min, zoom_max)


func _physics_process(delta: float) -> void:
	if get_tree().paused:
		return
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


func _clamp_to_bounds() -> void:
	if _map_w <= 0.0 or _map_h <= 0.0:
		return
	var focus := global_position - _offset
	focus.x = clampf(focus.x, 0.0, _map_w)
	focus.z = clampf(focus.z, 0.0, _map_h)
	global_position = focus + _offset

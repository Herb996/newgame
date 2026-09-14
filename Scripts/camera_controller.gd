extends Camera2D
## ============================================================
## CameraController — 独立相机控制器
## WASD / 方向键平移屏幕，按 F（可配置 return_key）一键回到玩家位置。
## 相机脱离玩家独立存在，由 main.gd 在进入基地/进局时创建并挂载地图边界。
## camera.pan_speed、camera.return_key 来自 Data/config.json，禁止硬编码。
## ============================================================

var pan_speed := 400.0
var _return_key := KEY_F
var _map_size: Vector2 = Vector2.ZERO  # 地图像素尺寸；ZERO = 不限制边界
var _player: CharacterBody2D = null


func _ready() -> void:
	pan_speed = float(Config.get_value("camera.pan_speed", 400.0))
	_return_key = int(Config.get_value("camera.return_key", KEY_F))


## 由 main.gd 调用：告知地图尺寸（用于边界限制）+ 玩家节点（用于跟随/回到玩家）
func setup(map_size: Vector2, player_node: CharacterBody2D) -> void:
	_map_size = map_size
	_player = player_node
	# 出生时相机先对齐玩家（平滑过渡）
	if player_node:
		global_position = player_node.global_position


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
	if dir.length() > 0.001:
		position += dir.normalized() * pan_speed * delta
		_clamp_to_bounds()
	# 回到玩家
	if Input.is_physical_key_pressed(_return_key) and _player:
		global_position = _player.global_position


func _clamp_to_bounds() -> void:
	if _map_size == Vector2.ZERO:
		return
	var viewport_size := get_viewport_rect().size
	var half_viewport := viewport_size * 0.5
	# 地图小于视口时相机固定中心（基地场景）
	if _map_size.x < viewport_size.x or _map_size.y < viewport_size.y:
		position = _map_size * 0.5
		return
	var min_pos := half_viewport
	var max_pos := _map_size - half_viewport
	position = Vector2(
		clampf(position.x, min_pos.x, max_pos.x),
		clampf(position.y, min_pos.y, max_pos.y),
	)

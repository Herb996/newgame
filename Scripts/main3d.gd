extends Node
## ============================================================
## Main3D — 3D 全量渲染入口（路线 2「双轨制」）
##
## 设计原则：**逻辑留在 2D，渲染换成 3D**。
##   · LogicRoot (Node2D, visible=false)
##       └ 地图逻辑节点 + 玩家 CharacterBody2D —— 物理、A* 寻路、
##         战斗状态机、资源注册表全部照旧跑在 2D 像素坐标里，不参与渲染。
##   · World3D  (Node3D)
##       ├ Sun / Env（环境光照，一次装配）
##       ├ MapRender3D   —— 地板/墙/装饰/矿脉 的 3D 表现
##       ├ PlayerVisual3D—— 玩家：2D 序列帧 + 朝向相机的公告板（HD-2D）
##       └ IsoCam        —— 正交等距相机（3D 版相机控制器）
##
## 坐标桥接：3D 世界单位 = 2D 像素 / map.tile_size；3D (x, z) ↔ 2D (x, y)。
##
## 与 Main.tscn 的关系：完全并行，互不影响。Main.tscn / main.gd 是 2D 版，
## 本入口是 3D 版，可随时回退。敌人/资源点/撤离点的 3D 化按阶段推进。
##
## 操作：左键点地面 → 3D 射线打到 y=0 平面 → 换算成 2D 坐标驱动玩家寻路；
##       WASD 平移相机，滚轮缩放，F 回到玩家，R 局结束后重开，ESC 退出。
## ============================================================

const MapRender3DClass := preload("res://Scripts/map_render_3d.gd")
const ISO_CAM := preload("res://Scripts/iso_camera_3d.gd")
const PLAYER_SCENE := preload("res://Scenes/Player.tscn")
const PLAYER_VISUAL := preload("res://Scripts/player_visual_3d.gd")

@onready var run: Node = $RunManager
@onready var logic_root: Node2D = $LogicRoot
@onready var world: Node3D = $World3D
@onready var hud: CanvasLayer = $HUD

var _tile := 16
var _map_w := 0
var _map_h := 0
var _result: Dictionary = {}

# 每局重建的 3D 节点
var _renderer: Node3D = null
var _visual: Node3D = null            # 玩家 3D 视觉（序列帧公告板，或素材缺失时的胶囊占位）
var _visual_is_sprite := false
var _cam: Camera3D = null

# 2D 逻辑层实体
var _player: CharacterBody2D = null
var _map_node: Node2D = null


func _ready() -> void:
	_tile = int(Config.get_value("map.tile_size", 16))
	_setup_world()
	var capture := str(Config.get_value("debug.main3d_capture", ""))
	_enter_run()
	if not capture.is_empty():
		_auto_capture(capture)


func _process(_delta: float) -> void:
	_sync_player_visual()
	# 局结束（撤离/死亡/超时）后按 R 重开一局
	if Input.is_physical_key_pressed(KEY_R) and run.state == run.State.ENDED:
		_enter_run()


func _input(event: InputEvent) -> void:
	if _player == null or _cam == null or get_tree().paused:
		return
	if not (event is InputEventMouseButton and event.pressed):
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	var mb := event as InputEventMouseButton
	# 屏幕点 → 世界射线 → 与地面平面 y=0 求交
	var from := _cam.project_ray_origin(mb.position)
	var dir := _cam.project_ray_normal(mb.position)
	if absf(dir.y) < 0.00001:
		return
	var t := -from.y / dir.y
	if t <= 0.0:
		return
	var hit := from + dir * t
	# 3D 世界单位 → 2D 像素，交给 2D 玩家自己的 A* 寻路
	_player.set_move_target(Vector2(hit.x * float(_tile), hit.z * float(_tile)))
	get_viewport().set_input_as_handled()   # 拦下事件，避免 2D 版的鼠标处理误判


# ------------------------------------------------------------
# 世界环境（一次装配，不随每局重建）
# ------------------------------------------------------------

func _setup_world() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-40.0, 135.0, 0.0)
	sun.light_energy = 1.38
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.shadow_enabled = true
	sun.shadow_bias = 0.025
	sun.shadow_normal_bias = 0.8
	sun.shadow_blur = 1.4
	sun.shadow_opacity = 0.80
	sun.directional_shadow_max_distance = 160.0
	sun.light_angular_distance = 2.0
	world.add_child(sun)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.085, 0.088, 0.098)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.58, 0.58, 0.62)
	env.ambient_light_energy = 0.58
	env.fog_enabled = true
	env.fog_light_color = Color(0.34, 0.33, 0.34)
	env.fog_light_energy = 0.9
	env.fog_density = 0.0032
	env.fog_sky_affect = 0.0
	env.glow_enabled = true
	env.glow_intensity = 0.28
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.25
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 1.0
	env.tonemap_exposure = 1.00
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.00
	env.adjustment_contrast = 1.12
	env.adjustment_saturation = 0.98
	var we := WorldEnvironment.new()
	we.name = "Env"
	we.environment = env
	world.add_child(we)


# ------------------------------------------------------------
# 进入一局
# ------------------------------------------------------------

func _clear_run() -> void:
	for n in [_renderer, _visual, _cam]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	_renderer = null
	_visual = null
	_visual_is_sprite = false
	_cam = null
	_player = null
	_map_node = null
	for c in logic_root.get_children():
		c.queue_free()


func _enter_run() -> void:
	_clear_run()
	hud.visible = true
	run.start_run()
	# 固定种子只给开发/对比用（0 = 每局随机）。**只 seed 一次**：
	# 这样可达率不达标重试时仍会换到别的地图，不会卡在同一张上死循环。
	var forced_seed := int(Config.get_value("map.force_seed", 0))
	if forced_seed != 0:
		seed(forced_seed)
	_result = _generate_valid_map()

	# ---- 2D 逻辑层（不渲染，但物理/寻路/注册表全部照常） ----
	logic_root.visible = false
	_map_node = _result.get("node", null)
	if _map_node != null:
		logic_root.add_child(_map_node)
	_player = PLAYER_SCENE.instantiate()
	_player.position = _result.spawn
	_player.setup_navigation(_result.walls, _tile)
	logic_root.add_child(_player)
	ResourceRegistry.build_from_map(_result)

	# ---- 3D 渲染层 ----
	var terrain: Array = _result["terrain"]
	_map_w = terrain[0].size()
	_map_h = terrain.size()
	_renderer = MapRender3DClass.new()
	_renderer.name = "MapRender3D"
	world.add_child(_renderer)
	_renderer.build_from_map(_result)
	_build_player_visual()
	_setup_camera()
	print("[Main3D] 进入 3D 局：地图 %dx%d，可拾取资源 %s" % [
			_map_w, _map_h, ResourceRegistry.count_by_type()])


# ------------------------------------------------------------
# 玩家 3D 视觉
# ------------------------------------------------------------

## 优先用序列帧公告板；素材/接口缺失时回退到胶囊占位，保证 3D 场景永远能跑起来。
func _build_player_visual() -> void:
	var v: Node3D = PLAYER_VISUAL.new()
	v.name = "PlayerVisual"
	world.add_child(v)
	if v.build(Config.get_value("sprites", {}), Config.get_value("player3d", {})):
		_visual = v
		_visual_is_sprite = true
		return
	v.queue_free()
	_visual = null
	_visual_is_sprite = false
	_build_player_fallback()


## 回退视觉：胶囊 + 朝向鼻尖 + 选中环（3D 全量迁移第一阶段的占位）
func _build_player_fallback() -> void:
	var marker := Node3D.new()
	marker.name = "PlayerFallback"

	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.34
	cap.height = 1.25
	body.mesh = cap
	body.position = Vector3(0.0, 0.625, 0.0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(1.0, 0.82, 0.30)
	bmat.roughness = 0.45
	bmat.metallic = 0.35
	body.material_override = bmat
	marker.add_child(body)

	var nose := MeshInstance3D.new()
	var nb := BoxMesh.new()
	nb.size = Vector3(0.20, 0.16, 0.42)
	nose.mesh = nb
	nose.position = Vector3(0.0, 0.95, 0.42)
	var nmat := StandardMaterial3D.new()
	nmat.albedo_color = Color(0.30, 0.72, 1.0)
	nmat.emission_enabled = true
	nmat.emission = Color(0.30, 0.72, 1.0)
	nmat.emission_energy_multiplier = 0.6
	nose.material_override = nmat
	marker.add_child(nose)

	var ring := MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = 0.42
	tor.outer_radius = 0.56
	ring.mesh = tor
	ring.position = Vector3(0.0, 0.03, 0.0)
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(0.31, 0.76, 0.97)
	rmat.emission_enabled = true
	rmat.emission = Color(0.31, 0.76, 0.97)
	rmat.emission_energy_multiplier = 0.9
	ring.material_override = rmat
	marker.add_child(ring)

	world.add_child(marker)
	_visual = marker
	print("[Main3D] 玩家视觉回退到胶囊占位")


func _sync_player_visual() -> void:
	if _player == null or _visual == null or not is_instance_valid(_player):
		return
	_visual.position = Vector3(_player.global_position.x / float(_tile), 0.0,
			_player.global_position.y / float(_tile))
	if _visual_is_sprite:
		# 公告板由 4 向帧表达朝向，节点本身不旋转
		_visual.set_state(_player.current_anim(),
				PlayerAnimator.dir_from_facing(_player.facing))
		_visual.set_selected(_player.selected)
	else:
		var f: Vector2 = _player.facing
		_visual.rotation.y = atan2(f.x, f.y)


func _visual_key() -> String:
	if _visual_is_sprite and _visual != null:
		return String(_visual.current_key())
	return "(胶囊占位)"


func _setup_camera() -> void:
	var cam := Camera3D.new()
	cam.set_script(ISO_CAM)
	cam.name = "IsoCam"
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.far = 400.0
	world.add_child(cam)
	var focus := Vector3(_player.global_position.x / float(_tile), 0.0,
			_player.global_position.y / float(_tile))
	# 相机偏移由「俯角 + 距离」推出（俯角已配置化，取代原先硬编码的 0.5/0.72/0.5 比例）。
	# 方位固定 45°：等距视角下相机落在 XZ 平面的对角线上。
	var dist := float(Config.get_value("camera3d.cam_distance", 120.0))
	var pitch := deg_to_rad(float(Config.get_value("camera3d.pitch_deg", 45.5)))
	var horiz := dist * cos(pitch)
	cam.global_position = focus + Vector3(horiz * 0.70710678, dist * sin(pitch),
			horiz * 0.70710678)
	cam.look_at(focus, Vector3.UP)
	cam.make_current()
	cam.setup(_player, _tile, focus)
	cam.set_bounds(_map_w, _map_h)
	_cam = cam


## 生成地图并校验连通性（与 main.gd 同规则：可达率不达标就换种子重生成）
func _generate_valid_map() -> Dictionary:
	var min_ratio := float(Config.get_value("map.min_reachable_ratio", 0.3))
	var max_attempts := int(Config.get_value("map.max_regen_attempts", 10))
	var result: Dictionary = {}
	for attempt in range(1, max_attempts + 1):
		result = MapGenerator.generate()
		if float(result.reachable_ratio) >= min_ratio:
			return result
		print("[Map] 第 %d/%d 次生成可达率仅 %.0f%%，换种子重试" % [
				attempt, max_attempts, float(result.reachable_ratio) * 100.0])
		result.node.free()
	push_warning("[Map] 连续 %d 次未达到可达率标准，使用最后一张地图" % max_attempts)
	return result


# ------------------------------------------------------------
# 调试：延时截图后退出（debug.main3d_capture 指定输出绝对路径）
# ------------------------------------------------------------

func _auto_capture(path: String) -> void:
	var delay := float(Config.get_value("debug.main3d_capture_delay", 3.0))
	var burst := int(Config.get_value("debug.main3d_capture_frames", 0))
	var vp := get_viewport().get_visible_rect().size
	# 先做一次输入桥接自检：模拟"左键点地面 → 3D 射线 → 2D 寻路"
	await get_tree().create_timer(0.6, true, false, true).timeout
	if _player != null:
		var p0: Vector2 = _player.global_position
		var mid_key := ""
		var moved := false
		# 地图每局随机，随便点一处很容易落在墙里或不可达格 —— 试几个候选点，
		# 直到玩家真的动起来，否则这条"输入桥接"自检会假失败（踩过）。
		for cand in [Vector2(0.66, 0.34), Vector2(0.34, 0.34), Vector2(0.70, 0.25),
				Vector2(0.30, 0.70), Vector2(0.62, 0.72)]:
			_click_at(Vector2(vp.x * cand.x, vp.y * cand.y))
			await get_tree().create_timer(0.45, true, false, true).timeout
			if _player.global_position.distance_to(p0) > 2.0:
				mid_key = _visual_key()
				moved = true
				break
		await get_tree().create_timer(2.1, true, false, true).timeout
		var p1: Vector2 = _player.global_position
		print("[Main3D][自检] 点击移动 %s → %s，位移 %.1f px，仍有寻路目标=%s%s" % [
				p0, p1, p0.distance_to(p1), str(_player.has_move_target()),
				"" if moved else "（⚠ 候选点全不可达，非桥接故障，换局再看）"])
		print("[Main3D][自检] 3D 玩家动画：移动中=%s，停下后=%s，朝向=%s" % [
				mid_key, _visual_key(), str(PlayerAnimator.dir_from_facing(_player.facing))])

	# 等场景稳定后，把相机压到玩家身上、再点一个近点 —— 这样出图时玩家正好在画面中心"走着"
	await get_tree().create_timer(delay, true, false, true).timeout
	if _player != null and _cam != null:
		_cam.focus_on_player()
		print("[Main3D][自检] 相机回中 → %s" % str(_cam.global_position))
		await get_tree().create_timer(0.2, true, false, true).timeout
		print("[Main3D][自检] 玩家世界 %s → 屏幕 %s" % [
				str(_player_world()), str(_player_screen())])
		# 注意：这里不用"点屏幕某处"来驱动 —— 调试点很容易落在墙里，玩家会原地贴着墙
		# 空转（看着像没动）。改成扫一圈找一个连续 4 格无墙的方向，保证真的走起来。
		_walk_to_open_cell()
		await get_tree().create_timer(0.30, true, false, true).timeout
		print("[Main3D][自检] 出图时动画=%s（有寻路目标=%s）" % [
				_visual_key(), str(_player.has_move_target())])

	if burst > 1:
		await _capture_burst(path, burst)
	else:
		var img: Image = await _grab_frame()
		if img != null:
			var err := img.save_png(path)
			print("[Main3D] 截图已输出 %s err=%d 尺寸=%dx%d" % [
					path, err, img.get_width(), img.get_height()])
	get_tree().quit(0)


func _player_world() -> Vector3:
	return Vector3(_player.global_position.x / float(_tile), 0.0,
			_player.global_position.y / float(_tile))


func _player_screen() -> Vector2:
	if _player == null or _cam == null:
		return Vector2.ZERO
	return _cam.unproject_position(_player_world())


## 抓当前视口一帧（必须先等 frame_post_draw，否则拿不到已绘制的画面）
func _grab_frame() -> Image:
	for i in range(2):
		await RenderingServer.frame_post_draw
	var tex := get_viewport().get_texture()
	if tex == null:
		print("[Main3D] 截图失败：拿不到视口纹理")
		return null
	var img := tex.get_image()
	if img == null:
		print("[Main3D] 截图失败：纹理转 Image 失败")
	return img


## 连拍 n 帧（间隔 0.1s ≈ walk 的 10fps 一帧），用来证明 3D 里序列帧真的在动。
## 逐帧打印玩家的屏幕坐标与当前动画名，方便离线裁剪/拼图核对。
func _capture_burst(path: String, n: int) -> void:
	for i in range(n):
		# 玩家可能已经到站停下了 —— 补一个新目标，保证每一帧都拍在"走"的状态
		if _player != null and not _player.has_move_target():
			_walk_to_open_cell()
		var img: Image = await _grab_frame()
		if img == null:
			return
		var fp: String = path.replace(".png", "_f%02d.png" % i)
		img.save_png(fp)
		print("[Main3D] 连拍 %d/%d → %s  玩家屏幕=%s  动画=%s" % [
				i + 1, n, fp, str(_player_screen()), _visual_key()])
		await get_tree().create_timer(0.10, true, false, true).timeout


func _click_at(pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = pos
	Input.parse_input_event(ev)


## 调试连拍专用：扫一圈，挑「连续无墙格数最多」的方向，把目标设在最多 10 格外。
## 比"点屏幕某处"可靠得多 —— 点屏幕很容易落在墙里，玩家会贴着墙原地空转（踩过）。
## 走得越远，连拍窗口内越不会中途到站。
func _walk_to_open_cell() -> bool:
	var walls: Array = _result.get("walls", [])
	if walls.is_empty() or _player == null:
		return false
	var w: int = walls[0].size()
	var h: int = walls.size()
	var c := Vector2i(int(_player.global_position.x / float(_tile)),
			int(_player.global_position.y / float(_tile)))
	var dirs := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
	var best_d := Vector2i.ZERO
	var best_run := 0
	for d in dirs:
		var run := 0
		for r in range(1, 13):
			var t: Vector2i = c + d * r
			if t.x < 1 or t.y < 1 or t.x >= w - 1 or t.y >= h - 1 or walls[t.y][t.x]:
				break
			run = r
		if run > best_run:
			best_run = run
			best_d = d
	if best_run < 2:
		print("[Main3D][自检] 四周都太挤，连拍可能拍到原地空转")
		return false
	var dst: Vector2i = c + best_d * mini(best_run, 10)
	_player.set_move_target(Vector2((float(dst.x) + 0.5) * float(_tile),
			(float(dst.y) + 0.5) * float(_tile)))
	print("[Main3D][自检] 连拍走向 %s（该方向连续 %d 格无墙）" % [str(best_d), best_run])
	return true

extends Node
## ============================================================
## Main3D — 3D 主入口（基地 / 局内 双模式）· 项目唯一入口
##
## 设计原则：**逻辑留在 2D，渲染换成 3D**（路线 2「双轨制」）。
##   · LogicRoot (Node2D, visible=false)
##       地图逻辑 + 玩家 + 敌人 + 资源点 + 撤离点 + 建筑 —— 物理、
##       A* 寻路、战斗状态机、AI、拾取、交互全部照旧跑在 2D 像素坐标里，
##       不参与渲染（visible=false 只影响显示，不影响物理与 process）。
##   · World3D  (Node3D)
##       ├ Sun / Env（环境光照，一次装配）
##       ├ MapRender3D    —— 局内：地板/墙/装饰/矿脉
##       ├ BaseRender3D   —— 基地：平地 + 外圈墙
##       ├ EntityVisual3D —— 敌人/资源点/撤离点/建筑 的 3D 表现
##       ├ PlayerVisual3D —— 玩家：2D 序列帧 + 朝相机公告板（HD-2D）
##       ├ Fog3D          —— 战争迷雾（未探索变黑，探索过的记住）
##       └ IsoCam         —— 正交等距相机
##
## 坐标桥接：3D 世界单位 = 2D 像素 / map.tile_size；3D (x, z) ↔ 2D (x, y)。
##
## 模式：
##   BASE 基地（64×64 平地，仓库/雕像/大门）→ 大门按 E 进局
##   RUN  局内（随机地图 + 敌人 + 资源点 + 撤离点 + 迷雾）→ 局结束按 R 回基地
##
## 操作：左键点地面寻路；WASD 平移相机；滚轮缩放；F 回玩家；E 交互建筑；
##       H 进食；R 局结束回基地；ESC 退出。
## ============================================================

const MapRender3DClass := preload("res://Scripts/map_render_3d.gd")
const BaseRender3DClass := preload("res://Scripts/base_render_3d.gd")
const EntityVisual3DClass := preload("res://Scripts/entity_visual_3d.gd")
const Fog3DClass := preload("res://Scripts/fog_3d.gd")
const ISO_CAM := preload("res://Scripts/iso_camera_3d.gd")
const PLAYER_SCENE := preload("res://Scenes/Player.tscn")
const PLAYER_VISUAL := preload("res://Scripts/player_visual_3d.gd")

enum Mode { BASE, RUN }

@onready var run: Node = $RunManager
@onready var logic_root: Node2D = $LogicRoot
@onready var world: Node3D = $World3D
@onready var hud: CanvasLayer = $HUD
@onready var extraction_system: Node = $ExtractionSystem
@onready var enemy_system: Node = $EnemySystem
@onready var loot_system: Node = $LootSystem
@onready var survival_system: Node = $SurvivalSystem
@onready var base_system: Node = $BaseSystem
@onready var minimap: CanvasLayer = $Minimap
@onready var warehouse_panel: CanvasLayer = $WarehousePanel
@onready var statue_panel: CanvasLayer = $StatuePanel

var mode: int = Mode.BASE

var _tile := 16
var _map_w := 0
var _map_h := 0
var _result: Dictionary = {}

# 每种模式重建的 3D 节点
var _renderer: Node3D = null          # 局内地形
var _base_render: Node3D = null       # 基地地形
var _entity_visual: Node3D = null     # 实体表现层
var _visual: Node3D = null            # 玩家 3D 视觉
var _visual_is_sprite := false
var _cam: Camera3D = null
var _fog: Fog3D = null                # 常驻（跨局复用）

# 2D 逻辑层实体
var _player: CharacterBody2D = null
var _map_node: Node2D = null


func _ready() -> void:
	_tile = int(Config.get_value("map.tile_size", 16))
	_setup_world()
	base_system.building_interacted.connect(_on_building_interacted)

	if bool(Config.get_value("debug.smoke_test", false)):
		_smoke_test()
		return
	if bool(Config.get_value("debug.flow_test", false)):
		_flow_test()
		return
	if str(Config.get_value("debug.map_preview", "")) != "":
		_render_map_preview()
		return

	var start := str(Config.get_value("debug.main3d_start", "base"))
	if start == "run" or bool(Config.get_value("debug.auto_enter_run", false)):
		_enter_run()
	else:
		_enter_base()

	var capture := str(Config.get_value("debug.main3d_capture", ""))
	if not capture.is_empty():
		_auto_capture(capture)


func _process(_delta: float) -> void:
	_sync_player_visual()
	if _entity_visual != null and is_instance_valid(_entity_visual):
		_entity_visual.sync()
	if _fog != null and _fog.is_active() and _player != null and is_instance_valid(_player):
		_fog.update_fog(_player.global_position)
	# ESC 退出
	if Input.is_action_just_pressed("ui_cancel"):
		get_tree().quit()
	# 局结束按 R 回基地
	if mode == Mode.RUN and Input.is_physical_key_pressed(KEY_R) and run.state == run.State.ENDED:
		_enter_base()


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
	get_viewport().set_input_as_handled()   # 拦下事件，避免 2D 层的鼠标处理误判


# ------------------------------------------------------------
# 世界环境（一次装配，不随模式重建）
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

	# 迷雾常驻节点（跨局复用，只换遮罩尺寸）
	_fog = Fog3DClass.new()
	_fog.name = "Fog3D"
	_fog.tile = _tile
	_fog.configure()
	world.add_child(_fog)


# ------------------------------------------------------------
# 清理
# ------------------------------------------------------------

func _clear_world() -> void:
	for n in [_renderer, _base_render, _entity_visual, _visual, _cam]:
		if n != null and is_instance_valid(n):
			if n.get_parent() == world:
				world.remove_child(n)
			n.queue_free()
	_renderer = null
	_base_render = null
	_entity_visual = null
	_visual = null
	_visual_is_sprite = false
	_cam = null
	if _fog != null and is_instance_valid(_fog):
		_fog.set_active(false)
		_fog.reset()      # 清掉上一局的探索记忆，避免回基地后仍留着旧局数据


func _clear_logic() -> void:
	_player = null
	_map_node = null
	for c in logic_root.get_children():
		logic_root.remove_child(c)
		c.queue_free()


# ------------------------------------------------------------
# 基地
# ------------------------------------------------------------

func _enter_base() -> void:
	mode = Mode.BASE
	hud.visible = false
	minimap.visible = false
	get_tree().paused = false
	warehouse_panel.close()
	statue_panel.close()
	_clear_world()
	_clear_logic()
	_result = {}

	var spawn: Vector2 = base_system.setup(logic_root)
	var tile_size: int = int(Config.get_value("map.tile_size", 16))
	var base_size: int = int(Config.get_value("base.map_size", 64))

	# 基地 walls：外圈 1 圈墙，内部全是地板（与 BaseSystem 的 2D 瓦片一致）
	var base_walls: Array = []
	for y in range(base_size):
		var row: Array = []
		row.resize(base_size)
		for x in range(base_size):
			row[x] = (x == 0 or y == 0 or x == base_size - 1 or y == base_size - 1)
		base_walls.append(row)

	_player = PLAYER_SCENE.instantiate()
	_player.position = spawn
	_player.setup_navigation(base_walls, tile_size)
	logic_root.add_child(_player)
	logic_root.visible = false

	_base_render = BaseRender3DClass.new()
	_base_render.name = "BaseRender3D"
	world.add_child(_base_render)
	_base_render.build()

	_entity_visual = EntityVisual3DClass.new()
	_entity_visual.name = "EntityVisual3D"
	world.add_child(_entity_visual)
	_entity_visual.setup(tile_size, null)     # 基地无迷雾

	_build_player_visual()
	_setup_camera(_pixel_to_world(spawn), base_size, base_size,
			float(Config.get_value("camera3d.base_size", 78.0)))
	print("[Main3D] 进入基地：%dx%d，建筑 %d 栋" % [
			base_size, base_size, Config.get_value("base.buildings", []).size()])


# ------------------------------------------------------------
# 局内
# ------------------------------------------------------------

func _enter_run() -> void:
	mode = Mode.RUN
	hud.visible = true
	get_tree().paused = false
	warehouse_panel.close()
	statue_panel.close()
	_clear_world()
	_clear_logic()
	run.start_run()

	# 固定种子只给开发/对比用（0 = 每局随机）。**只 seed 一次**：
	# 这样可达率不达标重试时仍会换到别的地图，不会卡在同一张上死循环。
	var forced_seed := int(Config.get_value("map.force_seed", 0))
	if forced_seed != 0:
		seed(forced_seed)
	_result = _generate_valid_map()

	# ---- 2D 逻辑层（不渲染，但物理/寻路/AI/拾取全部照常） ----
	logic_root.visible = false
	_map_node = _result.get("node", null)
	if _map_node != null:
		logic_root.add_child(_map_node)
	_player = PLAYER_SCENE.instantiate()
	_player.position = _result.spawn
	# 地形速度系数（雪原 <1 / 河水更慢）随导航一起注入：follow_path 每帧按所在格乘。
	_player.setup_navigation(_result.walls, _tile, _result.get("speed_mult", []))
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

	_entity_visual = EntityVisual3DClass.new()
	_entity_visual.name = "EntityVisual3D"
	world.add_child(_entity_visual)
	_entity_visual.setup(_tile, _fog)

	_build_player_visual()

	# 迷雾：换遮罩尺寸 + 清空记忆，然后立刻揭开出生点一圈（避免第一帧全黑）
	_fog.setup(_map_w, _map_h, _tile)
	_fog.set_active(true)
	_fog.update_fog(_player.global_position)
	_fog.apply_mask()

	_setup_camera(_pixel_to_world(_result.spawn), _map_w, _map_h,
			float(Config.get_value("camera3d.size", 46.0)))

	# ---- 局内系统（全部写进 2D 逻辑层） ----
	extraction_system.setup(logic_root, _result)
	enemy_system.setup(logic_root, _result)
	loot_system.setup(logic_root, _result)
	minimap.setup(_result)

	print("[Main3D] 进入 3D 局：地图 %dx%d，可拾取资源 %s" % [
			_map_w, _map_h, ResourceRegistry.count_by_type()])


## 建筑交互路由（BaseSystem 转发）
func _on_building_interacted(building_id: String) -> void:
	match building_id:
		"gate":
			_enter_run()
		"warehouse":
			warehouse_panel.open()
			base_system.reset_interaction(building_id)
		"statue":
			statue_panel.open()
			base_system.reset_interaction(building_id)
		_:
			push_warning("[Main3D] 未知建筑：%s" % building_id)
			base_system.reset_interaction(building_id)


# ------------------------------------------------------------
# 坐标桥接
# ------------------------------------------------------------

func _pixel_to_world(p: Vector2) -> Vector3:
	return Vector3(p.x / float(_tile), 0.0, p.y / float(_tile))


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


## 回退视觉：胶囊 + 朝向鼻尖 + 选中环
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
	if not is_instance_valid(_visual):
		return
	_visual.position = _pixel_to_world(_player.global_position)
	if _visual_is_sprite:
		# 公告板由 4 向帧表达朝向，节点本身不旋转
		_visual.set_state(_player.current_anim(),
				PlayerAnimator.dir_from_facing(_player.facing))
		_visual.set_selected(_player.selected)
	else:
		var f: Vector2 = _player.facing
		_visual.rotation.y = atan2(f.x, f.y)


func _visual_key() -> String:
	if _visual_is_sprite and _visual != null and is_instance_valid(_visual):
		return String(_visual.current_key())
	return "(胶囊占位)"


# ------------------------------------------------------------
# 相机
# ------------------------------------------------------------

func _setup_camera(focus: Vector3, w_cells: int, h_cells: int, view_size: float) -> void:
	var cam := Camera3D.new()
	cam.set_script(ISO_CAM)
	cam.name = "IsoCam"
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.far = 600.0
	world.add_child(cam)
	# 相机偏移由「俯角 + 距离」推出。方位固定 45°：等距视角下相机落在 XZ 对角线上。
	var dist := float(Config.get_value("camera3d.cam_distance", 120.0))
	var pitch := deg_to_rad(float(Config.get_value("camera3d.pitch_deg", 45.5)))
	var horiz := dist * cos(pitch)
	cam.global_position = focus + Vector3(horiz * 0.70710678, dist * sin(pitch),
			horiz * 0.70710678)
	cam.look_at(focus, Vector3.UP)
	cam.make_current()
	cam.setup(_player, _tile, focus)
	cam.set_bounds(w_cells, h_cells)
	# 用 set_view_size 而不是直接改 size：它同时把平滑目标与"基准视野"对齐，
	# 否则上一模式的缩放目标会漏到下一模式（基地→局内视野会莫名跳到极值）。
	cam.set_view_size(view_size)
	_cam = cam


# ------------------------------------------------------------
# 地图生成（含连通性校验）
# ------------------------------------------------------------

## 生成地图并校验连通性：可达地板占比低于 map.min_reachable_ratio
## 时换种子重新生成，最多 max_regen_attempts 次；全失败则用最后一张。
func _generate_valid_map() -> Dictionary:
	var min_ratio := float(Config.get_value("map.min_reachable_ratio", 0.3))
	var max_attempts := int(Config.get_value("map.max_regen_attempts", 10))
	var result: Dictionary = {}
	for attempt in range(1, max_attempts + 1):
		result = MapGenerator.generate()
		if float(result.reachable_ratio) >= min_ratio:
			return result
		print("[Map] 第 %d/%d 次生成可达率仅 %.0f%%（需 ≥%.0f%%），换种子重试" % [
				attempt, max_attempts, float(result.reachable_ratio) * 100.0,
				min_ratio * 100.0])
		var n = result.get("node", null)
		if n != null:
			n.free()
	push_warning("[Map] 连续 %d 次未达到可达率标准，使用最后一张地图" % max_attempts)
	return result


## 生成一张局内地图并输出 PNG（debug.map_preview）；不用渲染驱动，无头也能出图
func _render_map_preview() -> void:
	var out_path: String = str(Config.get_value("debug.map_preview", ""))
	var result := _generate_valid_map()
	var cells: int = int(Config.get_value("debug.map_preview_cells", 40))
	var img := MapGenerator.build_preview(result, cells)
	var err := img.save_png(out_path)
	print("[Map] 预览已输出：%s（%dx%d，err=%d）" % [out_path, img.get_width(),
			img.get_height(), err])
	get_tree().quit()


# ------------------------------------------------------------
# 调试：延时截图后退出（debug.main3d_capture 指定输出绝对路径）
# ------------------------------------------------------------

func _auto_capture(path: String) -> void:
	var delay := float(Config.get_value("debug.main3d_capture_delay", 3.0))
	var burst := int(Config.get_value("debug.main3d_capture_frames", 0))
	var vp := get_viewport().get_visible_rect().size

	await get_tree().create_timer(0.6, true, false, true).timeout
	if mode == Mode.RUN and _player != null:
		_run_self_check(vp)

	# 等场景稳定后把相机压到玩家身上，再驱动一次行走（这样出图时玩家正好在走着）
	await get_tree().create_timer(delay, true, false, true).timeout
	if _player != null and _cam != null:
		_cam.focus_on_player()
		print("[Main3D][自检] 相机回中 → %s" % str(_cam.global_position))
		await get_tree().create_timer(0.2, true, false, true).timeout
		print("[Main3D][自检] 玩家世界 %s → 屏幕 %s" % [
				str(_pixel_to_world(_player.global_position)), str(_player_screen())])
		if mode == Mode.RUN:
			_walk_to_open_cell()
			await get_tree().create_timer(0.30, true, false, true).timeout
			print("[Main3D][自检] 出图时动画=%s（有寻路目标=%s）" % [
					_visual_key(), str(_player.has_move_target())])

	if burst > 1 and mode == Mode.RUN:
		await _capture_burst(path, burst)
	else:
		var img: Image = await _grab_frame()
		if img != null:
			var err := img.save_png(path)
			print("[Main3D] 截图已输出 %s err=%d 尺寸=%dx%d" % [
					path, err, img.get_width(), img.get_height()])
	get_tree().quit(0)


## 局内自检：模拟"左键点地面 → 3D 射线 → 2D 寻路"
func _run_self_check(vp: Vector2) -> void:
	var p0: Vector2 = _player.global_position
	var mid_key := ""
	var moved := false
	# 地图每局随机，随便点一处很容易落在墙里或不可达格 —— 试几个候选点，
	# 直到玩家真的动起来，否则这条"输入桥接"自检会假失败。
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


func _player_screen() -> Vector2:
	if _player == null or _cam == null:
		return Vector2.ZERO
	return _cam.unproject_position(_pixel_to_world(_player.global_position))


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


## 连拍 n 帧（间隔 0.1s ≈ walk 的 10fps 一帧），逐帧打印玩家屏幕坐标与动画名
func _capture_burst(path: String, n: int) -> void:
	for i in range(n):
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


## 调试连拍专用：扫一圈挑「连续无墙格数最多」的方向，目标设在最多 10 格外。
## 比"点屏幕某处"可靠得多 —— 点屏幕很容易落在墙里，玩家会贴着墙原地空转。
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


# ------------------------------------------------------------
# 端到端流程自检（debug.flow_test=true 时启用）
#
# 静态截图只能证明"画出来了"，证明不了 BASE↔RUN 往返时清理与重建是否正确
# （_clear_world / _clear_logic 走的是 remove_child + queue_free，
#   漏清或重复建在截图里完全看不出来）。所以这里把整条流程真跑一遍：
#   基地 → 真按键 E 交互三栋建筑 → 大门进局 → 超时结算 → 回基地 → 再进局。
# 按键用 Input.parse_input_event 注入，走的是和玩家完全一样的输入路径。
# ------------------------------------------------------------

## 注入一次按键按下（走真实输入管线，与玩家按键等价）
func _press_key(kc: int) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = kc
	ev.keycode = kc
	ev.pressed = true
	Input.parse_input_event(ev)


func _release_key(kc: int) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = kc
	ev.keycode = kc
	ev.pressed = false
	Input.parse_input_event(ev)


var _flow_checks := 0                # flow_test 断言计数


func _check(fails: Array, ok: bool, msg: String) -> void:
	_flow_checks += 1
	if ok:
		print("[FlowTest]   OK   %s" % msg)
	else:
		print("[FlowTest]   FAIL %s" % msg)
		fails.append(msg)


## 等待 n 个物理帧 + 1 个渲染帧（让 queue_free / 组刷新都落地）
func _settle(n: int = 2) -> void:
	for i in range(n):
		await get_tree().physics_frame
	await get_tree().process_frame


## 把玩家瞬移到某栋建筑中心，按 E，返回是否成功触发
func _try_building(bid: String) -> bool:
	var cell: Array = []
	for b in Config.get_value("base.buildings", []):
		if str(b.get("id", "")) == bid:
			cell = b.get("cell", [])
			break
	if cell.is_empty() or _player == null:
		return false
	# 建筑中心 = 左上角格 + 2 格（与 base_system.gd 的摆放公式一致）
	_player.global_position = Vector2(float(cell[0]) + 2.0, float(cell[1]) + 2.0) * float(_tile)
	_player.velocity = Vector2.ZERO
	await _settle(3)
	_press_key(KEY_E)
	await _settle(3)
	_release_key(KEY_E)
	await _settle(3)
	return true


func _flow_test() -> void:
	print("=== [FlowTest] 3D 主流程自检开始 ===")
	var fails: Array = []

	# ---------------- 1) 基地 ----------------
	_enter_base()
	await _settle(3)
	var bld_count: int = get_tree().get_nodes_in_group("buildings").size()
	var base_logic_n: int = logic_root.get_child_count()
	_check(fails, mode == Mode.BASE, "进入基地：mode == BASE")
	_check(fails, _player != null, "进入基地：玩家已装配")
	_check(fails, _base_render != null, "进入基地：3D 地形已渲染")
	_check(fails, _entity_visual != null, "进入基地：实体表现层已装配")
	_check(fails, bld_count == 3, "进入基地：建筑 %d 栋（期望 3）" % bld_count)
	_check(fails, not _fog.is_active(), "进入基地：迷雾关闭")
	_check(fails, not hud.visible, "进入基地：HUD 隐藏")
	_check(fails, logic_root.get_child_count() == base_logic_n and base_logic_n >= 4,
			"进入基地：LogicRoot 子节点 %d（地图 + 玩家 + 建筑）" % base_logic_n)

	# ---------------- 2) 建筑交互（真按键） ----------------
	await _try_building("warehouse")
	_check(fails, warehouse_panel.visible, "仓库：按 E 后面板打开")
	_press_key(KEY_E)
	await _settle(3)
	_release_key(KEY_E)
	await _settle(3)
	_check(fails, not warehouse_panel.visible, "仓库：再按 E 面板关闭")
	_check(fails, not get_tree().paused, "仓库：关闭后不处于暂停")

	await _try_building("statue")
	_check(fails, statue_panel.visible, "雕像：按 E 后面板打开")
	_press_key(KEY_E)
	await _settle(3)
	_release_key(KEY_E)
	await _settle(3)
	_check(fails, not statue_panel.visible, "雕像：再按 E 面板关闭")

	# ---------------- 3) 大门 → 进局 ----------------
	await _try_building("gate")
	await _settle(4)
	var enemy_n: int = get_tree().get_nodes_in_group("enemies").size()
	var loot_n: int = get_tree().get_nodes_in_group("loot_nodes").size()
	var ext_n: int = get_tree().get_nodes_in_group("extraction_points").size()
	_check(fails, mode == Mode.RUN, "大门：按 E 进入局内（mode == RUN）")
	_check(fails, _renderer != null, "局内：3D 地形已渲染")
	_check(fails, not logic_root.visible, "局内：LogicRoot 隐藏（只做逻辑不渲染）")
	_check(fails, hud.visible, "局内：HUD 显示")
	_check(fails, _fog.is_active(), "局内：迷雾开启")
	_check(fails, _fog.explored_cells() > 0, "局内：出生点周围已揭开 %d 格" % _fog.explored_cells())
	_check(fails, enemy_n > 0, "局内：敌人 %d 个" % enemy_n)
	_check(fails, loot_n > 0, "局内：资源点 %d 个" % loot_n)
	_check(fails, ext_n == 0,
			"局内：撤离点开局为 0（设计如此——要到 spawn_at_minutes 才开）")
	var registry_total := 0
	for k in ResourceRegistry.count_by_type().keys():
		registry_total += int(ResourceRegistry.total_amount(str(k)))
	_check(fails, registry_total > 0,
			"局内：ResourceRegistry 总储量 %d" % registry_total)
	_check(fails, minimap.visible == false, "局内：撤离点未开时小地图隐藏")

	# ---------------- 3b) 推进局内时钟 → 撤离点开启 ----------------
	# 不去等真实时间，直接把倒计时拨到 spawn_at_minutes 之后，让 extraction_system
	# 自己按 elapsed 判定开点（走的就是它每帧那段真实逻辑）。
	var limit := float(Config.get_value("session.time_limit_seconds", 3600))
	var spawn_at := float(Config.get_value("extraction.spawn_at_minutes", 30)) * 60.0
	run.time_remaining = limit - spawn_at - 5.0
	await _settle(4)
	var ext_after: int = get_tree().get_nodes_in_group("extraction_points").size()
	var open_n := 0
	for p in get_tree().get_nodes_in_group("extraction_points"):
		if bool(p.get("is_open")):
			open_n += 1
	_check(fails, ext_after > 0, "撤离点开启：局内推进到 %.0f 分钟后生成 %d 个" % [
			spawn_at / 60.0, ext_after])
	_check(fails, open_n == ext_after, "撤离点开启：%d 个全部处于开放状态" % open_n)
	_check(fails, minimap.visible, "撤离点开启：小地图自动弹出")
	_check(fails, _entity_visual.get_child_count() == 2 + ext_after,
			"撤离点开启：3D 表现层已建出 %d 个撤离点节点" % (ext_after))
	var vis_v: Node = null
	var first_pt: Node = get_tree().get_nodes_in_group("extraction_points")[0]
	if first_pt is Node2D:
		vis_v = _entity_visual.get_node_or_null(
				"Extract_%d" % (first_pt as Node2D).get_instance_id())
	_check(fails, vis_v != null, "撤离点开启：对应的 3D 形态已建立")

	# ---------------- 4) 超时结算 → 回基地 ----------------

	# 视野判定：远处敌人应不可见（迷雾生效），近处可见
	var far_ok := true
	for e in get_tree().get_nodes_in_group("enemies"):
		if _fog.is_visible_px((e as Node2D).global_position):
			if (e as Node2D).global_position.distance_to(_player.global_position) > _fog.vision_px:
				far_ok = false
				break
	_check(fails, far_ok, "局内：视野半径外的敌人被判定为不可见")

	# ---------------- 4) 超时结算 → 回基地 ----------------
	run.time_remaining = 0.01
	var guard := 0
	while run.state != run.State.ENDED and guard < 300:
		guard += 1
		await get_tree().process_frame
	_check(fails, run.state == run.State.ENDED, "结算：计时归零后局状态为 ENDED")
	_enter_base()
	await _settle(4)
	_check(fails, mode == Mode.BASE, "回基地：mode == BASE")
	_check(fails, _renderer == null, "回基地：局内 3D 地形已销毁")
	_check(fails, _base_render != null, "回基地：基地 3D 地形已重建")
	_check(fails, not _fog.is_active(), "回基地：迷雾已关闭")
	_check(fails, _fog.explored_cells() == 0, "回基地：迷雾记忆已清空")
	_check(fails, get_tree().get_nodes_in_group("enemies").size() == 0, "回基地：敌人无残留")
	_check(fails, get_tree().get_nodes_in_group("loot_nodes").size() == 0, "回基地：资源点无残留")
	_check(fails, get_tree().get_nodes_in_group("extraction_points").size() == 0,
			"回基地：撤离点无残留")
	_check(fails, get_tree().get_nodes_in_group("buildings").size() == 3,
			"回基地：建筑重新建好 %d 栋" % get_tree().get_nodes_in_group("buildings").size())
	var logic_after: int = logic_root.get_child_count()
	_check(fails, logic_after == base_logic_n,
			"回基地：LogicRoot 子节点 %d == 首次 %d（逻辑层无泄漏）" % [logic_after, base_logic_n])

	# ---------------- 5) 二次进局（验证重建路径可重复） ----------------
	_enter_run()
	await _settle(4)
	_check(fails, mode == Mode.RUN, "二次进局：mode == RUN")
	_check(fails, get_tree().get_nodes_in_group("enemies").size() > 0, "二次进局：敌人已重建")
	_check(fails, _fog.is_active() and _fog.explored_cells() > 0, "二次进局：迷雾重新揭开")
	_check(fails, _renderer != null and _entity_visual != null, "二次进局：3D 层已重建")
	_check(fails, get_tree().get_nodes_in_group("extraction_points").size() == 0,
			"二次进局：撤离点计数已重置（新局重新计时）")
	_check(fails, not minimap.visible, "二次进局：小地图已复位隐藏")

	print("=== [FlowTest] 结束：共 %d 项断言，失败 %d 项 ===" % [_flow_checks, fails.size()])
	if not fails.is_empty():
		for m in fails:
			print("[FlowTest] !! %s" % m)
	get_tree().quit(0 if fails.is_empty() else 1)


# ------------------------------------------------------------
# 烟雾测试（debug.smoke_test=true 时启用）
# ------------------------------------------------------------

func _smoke_test() -> void:
	print("=== SteamPunk Extraction — 框架自检开始 ===")
	run.start_run()
	run.add_loot("scrap", 30)
	run.add_loot("steam_core", 2)
	run.extract()
	print("[自检] 1. 撤离局后仓库：", Meta.bank)
	assert(Meta.bank.get("scrap", 0) >= 30, "撤离资源未入库！")

	var bought: bool = Meta.buy_upgrade("survival.max_hp")
	print("[自检] 2. 升级 max_hp 成功：", bought, "，当前生命上限：", Meta.get_stat("survival.max_hp"))
	assert(bought, "资源足够却升级失败！")

	var scrap_before := int(Meta.bank.get("scrap", 0))
	run.start_run()
	run.add_loot("scrap", 99)
	run.player_died()
	print("[自检] 3. 死亡局后仓库：", Meta.bank)
	assert(int(Meta.bank.get("scrap", 0)) == scrap_before, "死亡局资源不应入库！")

	run.start_run()
	run.time_remaining = 0.01
	print("[自检] 4. 已启动超时测试局，等待下一帧触发…")

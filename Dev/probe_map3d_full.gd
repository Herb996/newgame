extends Node3D
## Dev 探针 — 全量 3D 渲染验证（临时，不属于游戏本体）
## 目的：用可复用的 MapRender3D（5 群系 Texture2DArray 方案）渲染真实地图，
##       确认地板/墙/装饰/矿脉都能出图，且无 SCRIPT ERROR。
const MapRender3DClass = preload("res://Scripts/map_render_3d.gd")

const OUT := "D:/SteamPunkExtraction/Dev/probe_map3d_full.png"
const MAP_SEED := 20260915
const HALF_VIEW_X := 60
const HALF_VIEW_Y := 42
const WALL_H := 1.8


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	seed(MAP_SEED)
	var map: Dictionary = MapGenerator.generate()
	if map.get("node") != null:
		map["node"].free()
	var terrain: Array = map["terrain"]
	var biome: Array = map["biome"]
	var w: int = terrain[0].size()
	var h: int = terrain.size()
	var center: Vector2i = map.get("spawn_cell", Vector2i(int(w / 2), int(h / 2)))
	var view_c := Vector3(center.x + 0.5, 0.0, center.y + 0.5)

	# 群系统计（确认 5 群系都在）
	var counts := {}
	for y in range(h):
		for x in range(w):
			var b: int = int(biome[y][x])
			counts[b] = int(counts.get(b, 0)) + 1
	print("[Probe3D] 地图 %dx%d 群系统计=%s" % [w, h, counts])

	var renderer := MapRender3DClass.new()
	renderer.name = "MapRender3D"
	add_child(renderer)
	renderer.build_from_map(map)
	var veins: Array = map.get("veins", [])
	print("[Probe3D] 矿脉数=%d" % veins.size())

	_setup_camera(view_c)
	_setup_light()
	_setup_env()
	print("[Probe3D] 场景构建耗时 %d ms" % (Time.get_ticks_msec() - t0))
	_capture()


func _setup_camera(target: Vector3) -> void:
	var cam := Camera3D.new()
	cam.name = "IsoCam"
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 60.0
	add_child(cam)
	cam.position = target + Vector3(60.0, 60.0, 60.0)
	cam.look_at(target, Vector3.UP)
	cam.make_current()
	cam.far = 400.0


func _setup_light() -> void:
	var l := DirectionalLight3D.new()
	l.name = "Sun"
	l.rotation_degrees = Vector3(-40.0, 135.0, 0.0)
	l.light_energy = 1.38
	l.light_color = Color(1.0, 0.95, 0.86)
	l.shadow_enabled = true
	l.shadow_bias = 0.025
	l.shadow_normal_bias = 0.8
	l.shadow_blur = 1.4
	l.shadow_opacity = 0.80
	l.directional_shadow_max_distance = 160.0
	l.light_angular_distance = 2.0
	add_child(l)


func _setup_env() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.085, 0.088, 0.098)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.58, 0.58, 0.62)
	env.ambient_light_energy = 0.58
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.9
	env.ssao_power = 1.4
	env.ssao_light_affect = 0.35
	env.fog_enabled = true
	env.fog_light_color = Color(0.34, 0.33, 0.34)
	env.fog_light_energy = 0.9
	env.fog_density = 0.0032
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.0
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
	add_child(we)


func _capture() -> void:
	for i in range(16):
		await RenderingServer.frame_post_draw
	var tex := get_viewport().get_texture()
	if tex == null:
		print("[Probe3D] 错误：拿不到视口纹理")
		get_tree().quit(1)
		return
	var img := tex.get_image()
	if img == null:
		print("[Probe3D] 错误：纹理转 Image 失败")
		get_tree().quit(1)
		return
	var err := img.save_png(OUT)
	print("[Probe3D] 输出=%s err=%d 尺寸=%dx%d" % [OUT, err, img.get_width(), img.get_height()])
	get_tree().quit(0)

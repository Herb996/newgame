extends Node3D
## ============================================================
## Dev 探针 — 渲染链路验证（临时，不属于游戏本体）
## 目的：确认本机能否用真实渲染驱动出图（此前只能用无头像素合成）。
## 场景内容：地面 + 一排立方体 + 正交等距相机 + 带阴影方向光 + 环境雾。
## 跑法：godot --path <项目> res://Dev/probe_render.gd 不需要，用 .tscn 启动
## ============================================================

const OUT := "D:/SteamPunkExtraction/Dev/probe_render.png"


func _ready() -> void:
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 60.0
	add_child(cam)
	# 正交等距：方位 45°、俯角约 35°（从水平面算起），对准原点
	cam.position = Vector3(60.0, 60.0, 60.0)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	cam.make_current()

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35.0, 40.0, 0.0)
	light.shadow_enabled = true
	light.light_energy = 1.5
	add_child(light)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.085, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.36, 0.34, 0.31)
	env.ambient_light_energy = 0.15
	env.fog_enabled = true
	env.fog_light_color = Color(0.20, 0.19, 0.17)
	env.fog_density = 0.012
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(80.0, 80.0)
	ground.mesh = pm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.30, 0.26, 0.19)
	gmat.roughness = 0.95
	ground.material_override = gmat
	add_child(ground)

	# 材质差异对照：金属感（左）vs 无光泽（右）
	for i in range(7):
		var b := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(2.0, 3.0, 2.0)
		b.mesh = bm
		b.position = Vector3(-12.0 + i * 4.0, 1.5, 0.0)
		var bmat := StandardMaterial3D.new()
		bmat.albedo_color = Color(0.44, 0.31, 0.18)
		bmat.metallic = 0.0 if i < 4 else 0.75
		bmat.roughness = 0.9 if i < 4 else 0.35
		b.material_override = bmat
		add_child(b)

	_capture()


func _capture() -> void:
	for i in range(8):
		await RenderingServer.frame_post_draw
	var tex := get_viewport().get_texture()
	if tex == null:
		print("[Probe] 错误：拿不到视口纹理")
		get_tree().quit(1)
		return
	var img := tex.get_image()
	if img == null:
		print("[Probe] 错误：纹理转 Image 失败")
		get_tree().quit(1)
		return
	var err := img.save_png(OUT)
	print("[Probe] 输出=%s err=%d 尺寸=%dx%d" % [OUT, err, img.get_width(), img.get_height()])
	print("[Probe] 渲染方法=", ProjectSettings.get_setting("rendering/renderer/rendering_method"))
	get_tree().quit(0)

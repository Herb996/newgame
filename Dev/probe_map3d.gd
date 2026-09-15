extends Node3D
## ============================================================
## Dev 探针 — 3D 小样（临时，不属于游戏本体）
## 目的：用真 3D 渲染重建地图，验证"换渲染范式"能到多少精致度。
##
## 数据来源完全复用现有 MapGenerator.generate()（地形/墙体/装饰/群系四张二维表），
## 只是换了呈现方式：
##   - 地板：按群系合并成一个 ArrayMesh（每群系 1 个 draw call），1024² 原始纹理平铺
##   - 墙体：MultiMeshInstance3D + BoxMesh 抬成实体，顶面受光由真实光照天然产生
##   - 装饰：GLB 模型 MultiMesh 摆放，随机 Y 旋转与缩放
##   - 相机：Camera3D 正交投影 + 等距角；光照：DirectionalLight3D 开阴影
## ============================================================

const TEX_DIR := "res://Assets/Art/Terrain3D/"
const GROUND_TEX := ["ground_forest.png", "ground_waste.png", "ground_marsh.png", "ground_rock.png"]
const WALL_TEX := "wall_plate.png"

const MODEL_DIR := "res://Assets/Art/Models/"
const MODEL_FILES := ["tree.glb", "rock.glb", "debris.glb"]
const MODEL_HEIGHT := [3.4, 1.2, 0.45]      # 各类装饰物目标世界高度（格 = 1 单位）
const MODEL_CAP := 130                      # 单类装饰物在小样中的上限（控制显存）

const OUT := "D:/SteamPunkExtraction/Dev/probe_map3d.png"
const UV_PER_TEX := 6.0                     # 一张纹理覆盖多少格
const WALL_H := 1.35
const HALF_VIEW_X := 44                     # 取景窗口半宽（格）
const HALF_VIEW_Y := 30


func _ready() -> void:
	var t0 := Time.get_ticks_msec()

	# ---- 1. 复用现有地图生成（拿到四张数据表，丢弃它建的 2D 节点树）----
	var map: Dictionary = MapGenerator.generate()
	if map.get("node") != null:
		map["node"].free()
	var terrain: Array = map["terrain"]
	var decor: Array = map["decor"]
	var biome: Array = map["biome"]
	var w: int = terrain[0].size()
	var h: int = terrain.size()
	var center: Vector2i = map["spawn_cell"]
	var view_c := Vector3(center.x + 0.5, 0.0, center.y + 0.5)
	print("[3D] 地图 %dx%d，出生格 %s" % [w, h, center])

	var x0: int = maxi(0, center.x - HALF_VIEW_X)
	var x1: int = mini(w, center.x + HALF_VIEW_X)
	var y0: int = maxi(0, center.y - HALF_VIEW_Y)
	var y1: int = mini(h, center.y + HALF_VIEW_Y)

	# ---- 2. 地板：按群系合并网格 ----
	for b in range(MapGenerator.BIOME_COUNT):
		var mesh := _build_ground_mesh(terrain, biome, b, x0, x1, y0, y1)
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = "Ground_B%d" % b
		mi.mesh = mesh
		mi.material_override = _ground_material(b)
		add_child(mi)

	# ---- 3. 墙体：MultiMesh 立方体 ----
	_wall_multimesh(terrain, x0, x1, y0, y1)

	# ---- 4. 装饰物：GLB + MultiMesh ----
	_decor_multimesh(decor, biome, x0, x1, y0, y1)

	# ---- 5. 相机 / 光照 / 环境 ----
	_setup_camera(view_c)
	_setup_light()
	_setup_env()

	print("[3D] 场景构建耗时 %d ms" % (Time.get_ticks_msec() - t0))
	_capture()


# ------------------------------------------------------------
# 地板
# ------------------------------------------------------------

func _ground_material(b: int) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var path := TEX_DIR + GROUND_TEX[b]
	if ResourceLoader.exists(path):
		mat.albedo_texture = load(path)
	# 世界尺寸的 UV（顶点 UV 直接写格坐标），靠 uv1_scale 控制平铺密度
	mat.uv1_scale = Vector3(1.0 / UV_PER_TEX, 1.0 / UV_PER_TEX, 1.0)
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _build_ground_mesh(terrain: Array, biome: Array, b: int,
		x0: int, x1: int, y0: int, y1: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for y in range(y0, y1):
		for x in range(x0, x1):
			if terrain[y][x]:
				continue
			if int(biome[y][x]) != b:
				continue
			var base := verts.size()
			verts.push_back(Vector3(x, 0.0, y))
			verts.push_back(Vector3(x + 1, 0.0, y))
			verts.push_back(Vector3(x + 1, 0.0, y + 1))
			verts.push_back(Vector3(x, 0.0, y + 1))
			for i in range(4):
				norms.push_back(Vector3.UP)
			uvs.push_back(Vector2(x, y))
			uvs.push_back(Vector2(x + 1, y))
			uvs.push_back(Vector2(x + 1, y + 1))
			uvs.push_back(Vector2(x, y + 1))
			idx.push_back(base + 0)
			idx.push_back(base + 1)
			idx.push_back(base + 2)
			idx.push_back(base + 0)
			idx.push_back(base + 2)
			idx.push_back(base + 3)
	if idx.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# ------------------------------------------------------------
# 墙体（立体化：顶面受光由真实光照产生，不再需要"墙顶变体"贴图）
# ------------------------------------------------------------

func _wall_multimesh(terrain: Array, x0: int, x1: int, y0: int, y1: int) -> void:
	var cells: Array[Vector3i] = []
	for y in range(y0, y1):
		for x in range(x0, x1):
			if terrain[y][x]:
				cells.append(Vector3i(x, y, 0))
	if cells.is_empty():
		return
	var box := BoxMesh.new()
	box.size = Vector3(1.0, WALL_H, 1.0)
	var mat := StandardMaterial3D.new()
	var wp := TEX_DIR + WALL_TEX
	if ResourceLoader.exists(wp):
		mat.albedo_texture = load(wp)
	mat.uv1_scale = Vector3(1.0, WALL_H, 1.0)
	mat.roughness = 0.75
	mat.metallic = 0.35
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = cells.size()
	for i in range(cells.size()):
		var c := cells[i]
		mm.set_instance_transform(i, Transform3D(Basis(),
				Vector3(c.x + 0.5, WALL_H * 0.5, c.y + 0.5)))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Walls"
	mmi.multimesh = mm
	mmi.material_override = mat
	add_child(mmi)
	print("[3D] 墙体实例 %d" % cells.size())


# ------------------------------------------------------------
# 装饰物
# ------------------------------------------------------------

func _decor_multimesh(decor: Array, biome: Array, x0: int, x1: int, y0: int, y1: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260915
	var kinds := [MapGenerator.DECOR_TREE, MapGenerator.DECOR_ROCK, MapGenerator.DECOR_DEBRIS]
	for k_i in range(kinds.size()):
		var kind: int = kinds[k_i]
		var src: PackedScene = _load_model(k_i)
		var mesh: Mesh = null
		var mat: Material = null
		var node_xf := Transform3D.IDENTITY
		if src != null:
			var inst: Node = src.instantiate()
			var mi := _find_mesh_instance(inst)
			if mi != null:
				mesh = mi.mesh
				node_xf = mi.transform
				mat = mi.material_override
				if mat == null and mesh != null and mesh.get_surface_count() > 0:
					mat = mesh.surface_get_material(0)
			inst.free()
		if mesh == null:
			# 模型缺失时的替代几何体，保证探针仍可出图
			var fb := BoxMesh.new()
			fb.size = Vector3(0.8, MODEL_HEIGHT[k_i], 0.8)
			mesh = fb
		# GLB 常自带轴修正等节点变换，AABB 必须跟着变换后再用，否则会躺倒或尺寸失控
		var aabb := _transformed_aabb(mesh.get_aabb(), node_xf)
		var base_s := MODEL_HEIGHT[k_i] / maxf(aabb.size.y, 0.001)
		var pts: Array[Vector3] = []
		for y in range(y0, y1):
			for x in range(x0, x1):
				if int(decor[y][x]) != kind:
					continue
				pts.append(Vector3(x + 0.5 + rng.randf_range(-0.18, 0.18), 0.0,
						y + 0.5 + rng.randf_range(-0.18, 0.18)))
		if pts.is_empty():
			continue
		if pts.size() > MODEL_CAP:
			pts.shuffle()
			pts.resize(MODEL_CAP)
		_place_decor(kind, mesh, mat, node_xf, aabb, base_s, pts, rng, k_i, src != null)


## 摆放装饰物实例：单曲面网格走 MultiMesh（一次 draw call），
## 多材质网格 MultiMesh 不支持，退回逐实例节点（数量已由 MODEL_CAP 限制）。
func _place_decor(kind: int, mesh: Mesh, mat: Material, node_xf: Transform3D, aabb: AABB,
		base_s: float, pts: Array[Vector3], rng: RandomNumberGenerator,
		k_i: int, from_glb: bool) -> void:
	var xfs: Array[Transform3D] = []
	for p in pts:
		var s := base_s * rng.randf_range(0.82, 1.18)
		var rot := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(
				Vector3(s, s, s))
		var anchor := Vector3(aabb.get_center().x, aabb.position.y, aabb.get_center().z)
		xfs.append(Transform3D(rot, p - rot * anchor) * node_xf)
	var surfaces := 1 if mesh == null else mesh.get_surface_count()
	if surfaces == 1:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = xfs.size()
		for i in range(xfs.size()):
			mm.set_instance_transform(i, xfs[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Decor_%d" % kind
		mmi.multimesh = mm
		mmi.material_override = mat
		add_child(mmi)
	else:
		var holder := Node3D.new()
		holder.name = "Decor_%d" % kind
		for xf in xfs:
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = mat
			mi.transform = xf
			holder.add_child(mi)
		add_child(holder)
	print("[3D] 装饰 kind=%d 实例 %d 曲面数=%d（模型=%s，目标高 %.2f，原始高 %.2f）"
			% [kind, xfs.size(), surfaces, "GLB" if from_glb else "替代",
			   MODEL_HEIGHT[k_i], aabb.size.y])


func _load_model(i: int) -> PackedScene:
	var p := MODEL_DIR + String(MODEL_FILES[i]).replace(".glb", "") + ".glb"
	if not ResourceLoader.exists(p):
		return null
	var r = load(p)
	return r as PackedScene


func _find_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh_instance(c)
		if r != null:
			return r
	return null


## 把模型 AABB 的 8 个角点按变换投影后重新求包围盒
func _transformed_aabb(a: AABB, xf: Transform3D) -> AABB:
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for i in range(8):
		var c := a.position + Vector3(
				a.size.x if (i & 1) else 0.0,
				a.size.y if (i & 2) else 0.0,
				a.size.z if (i & 4) else 0.0)
		var p := xf * c
		mn = Vector3(minf(mn.x, p.x), minf(mn.y, p.y), minf(mn.z, p.z))
		mx = Vector3(maxf(mx.x, p.x), maxf(mx.y, p.y), maxf(mx.z, p.z))
	return AABB(mn, mx - mn)


# ------------------------------------------------------------
# 相机 / 光照 / 环境
# ------------------------------------------------------------

func _setup_camera(target: Vector3) -> void:
	var cam := Camera3D.new()
	cam.name = "IsoCam"
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 48.0
	add_child(cam)
	# 方位 45°、俯角约 35°（从水平面算起）
	cam.position = target + Vector3(60.0, 60.0, 60.0)
	cam.look_at(target, Vector3.UP)
	cam.make_current()
	cam.far = 400.0


func _setup_light() -> void:
	var l := DirectionalLight3D.new()
	l.name = "Sun"
	l.rotation_degrees = Vector3(-42.0, 38.0, 0.0)
	l.light_energy = 1.35
	l.light_color = Color(1.0, 0.95, 0.87)
	l.shadow_enabled = true
	l.shadow_bias = 0.04
	l.directional_shadow_max_distance = 140.0
	l.light_angular_distance = 1.6      # 软阴影（Forward+ 有效）
	add_child(l)


func _setup_env() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.055, 0.052, 0.05)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.42, 0.45, 0.52)
	env.ambient_light_energy = 0.32
	env.fog_enabled = true
	env.fog_light_color = Color(0.13, 0.13, 0.13)
	env.fog_light_energy = 0.6
	env.fog_density = 0.0055
	env.fog_sky_affect = 0.0
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.15
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 1.0
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 0.94
	var we := WorldEnvironment.new()
	we.name = "Env"
	we.environment = env
	add_child(we)


# ------------------------------------------------------------
# 出图
# ------------------------------------------------------------

func _capture() -> void:
	for i in range(10):
		await RenderingServer.frame_post_draw
	var tex := get_viewport().get_texture()
	if tex == null:
		print("[3D] 错误：拿不到视口纹理")
		get_tree().quit(1)
		return
	var img := tex.get_image()
	if img == null:
		print("[3D] 错误：纹理转 Image 失败")
		get_tree().quit(1)
		return
	var err := img.save_png(OUT)
	print("[3D] 输出=%s err=%d 尺寸=%dx%d" % [OUT, err, img.get_width(), img.get_height()])
	get_tree().quit(0)

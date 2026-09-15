extends Node3D
## ============================================================
## Dev 探针 — 3D 小样 v2（临时，不属于游戏本体）
## 目的：在 v1 的骨架上只做「调料」，验证能不能从"骨架对"推到"够精致"。
##
## v1 → v2 只动四件事，架构零改动：
##   1. 群系边界：从「每群系各一个网格、硬切」改为「整张一个网格 + 4 通道权重贴图软混合」
##   2. 环境光遮蔽：开 SSAO，让物件与地面、墙脚"贴实"，消掉发飘感
##   3. 雾：密度/色温上调，给远景空气感，并让地图边缘自然消隐
##   4. 光照调性：环境光 0.28 → 0.52（暗部糊死的根因），阴影加不透明度控制避免死黑
##
## 相机方位、光源方位、地形数据来源全部与 v1 一致，保证对比公平。
## ============================================================

const TEX_DIR := "res://Assets/Art/Terrain3D/"
const GROUND_TEX := ["ground_forest.png", "ground_waste.png", "ground_marsh.png", "ground_rock.png"]
const WALL_TEX := "wall_plate.png"

const MODEL_DIR := "res://Assets/Art/Models/"
const MODEL_FILES := ["tree.glb", "rock.glb", "debris.glb"]
const MODEL_HEIGHT := [6.5, 1.7, 0.6]       # 各类装饰物目标世界高度（格 = 1 单位）
const MODEL_CAP := 130                      # 单类装饰物在小样中的上限（控制显存）

const OUT := "D:/SteamPunkExtraction/Dev/probe_map3d_v2.png"
const OUT_WEIGHTS := "D:/SteamPunkExtraction/Dev/probe_biome_weights.png"
## 调试开关：为 true 时把"群系权重场"直接当颜色输出，用于验证软混合是否真的生效
const DEBUG_WEIGHTS := false
## 仅探针用：MapGenerator 内部用 randi() 播种，每局地图都不同。
## A/B 对比必须同源，所以这里固定全局种子（与 v1 探针取同一值）。
const MAP_SEED := 20260915
const UV_PER_TEX := 4.5                     # 一张纹理覆盖多少格
const WALL_H := 1.8
const HALF_VIEW_X := 44                     # 取景窗口半宽（格）
const HALF_VIEW_Y := 30

const BIOME_BLEND_RADIUS := 4               # 群系交界模糊半径（格）→ 交界宽度约 2*R

# 装饰物材质亮度校正（AI 原画明度不一，石头偏白会抢眼）
const DECOR_TINT := [
	Color(1.00, 1.00, 1.00),   # 树
	Color(0.70, 0.70, 0.72),   # 石头
	Color(0.88, 0.88, 0.88),   # 残骸
]

# 群系亮度校正：AI 原画本身明度差太多（石原接近白色），直接铺上去会曝白
const BIOME_TUNE := [
	Color(1.06, 1.06, 1.02),   # 林地：原画偏暗，略提
	Color(0.96, 0.93, 0.88),   # 荒原：原画偏橙，稍收
	Color(0.94, 1.00, 0.97),   # 锈泽
	Color(0.56, 0.57, 0.60),   # 石原：v1 用 0.44，在 3D 里几乎全黑（占了地图一大块），抬到 0.56
]


func _ready() -> void:
	var t0 := Time.get_ticks_msec()

	# ---- 1. 复用现有地图生成（拿到四张数据表，丢弃它建的 2D 节点树）----
	seed(MAP_SEED)   # 固定种子：A/B 对比必须同源
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
	print("[3Dv2] 地图 %dx%d，出生格 %s" % [w, h, center])

	var x0: int = maxi(0, center.x - HALF_VIEW_X)
	var x1: int = mini(w, center.x + HALF_VIEW_X)
	var y0: int = maxi(0, center.y - HALF_VIEW_Y)
	var y1: int = mini(h, center.y + HALF_VIEW_Y)

	# ---- 2. 地板：整张合一个网格 + 群系权重软混合（v1 是每群系硬切）----
	var gmesh := _build_ground_mesh(terrain, x0, x1, y0, y1)
	var gmat := _ground_material(biome, w, h)
	if gmesh != null and gmat != null:
		var mi := MeshInstance3D.new()
		mi.name = "Ground"
		mi.mesh = gmesh
		mi.material_override = gmat
		add_child(mi)
		print("[3Dv2] 地板：单网格 + 群系软混合（半径 %d 格）" % BIOME_BLEND_RADIUS)

	# ---- 3. 墙体：MultiMesh 立方体 ----
	_wall_multimesh(terrain, x0, x1, y0, y1)

	# ---- 4. 装饰物：GLB + MultiMesh ----
	_decor_multimesh(decor, biome, x0, x1, y0, y1)

	# ---- 5. 相机 / 光照 / 环境 ----
	_setup_camera(view_c)
	_setup_light()
	_setup_env()

	print("[3Dv2] 场景构建耗时 %d ms" % (Time.get_ticks_msec() - t0))
	_capture()


# ------------------------------------------------------------
# 地板
# ------------------------------------------------------------

## 地面着色器：4 个群系纹理按权重贴图混合，权重贴图带模糊 → 交界是渐变不是刀切。
## 每个群系仍走三尺度错位采样 + 低频噪声补大尺度明暗（沿用 v1 已验证的做法）。
## 只写 ALBEDO/ROUGHNESS，光照、阴影仍由引擎 PBR 管线负责。
const GROUND_SHADER := """
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D tex0 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex1 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex2 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex3 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D biome_map : filter_linear, repeat_disable;
uniform vec2 map_size = vec2(128.0, 128.0);
uniform vec3 tint0 : source_color = vec3(1.0);
uniform vec3 tint1 : source_color = vec3(1.0);
uniform vec3 tint2 : source_color = vec3(1.0);
uniform vec3 tint3 : source_color = vec3(1.0);
uniform float base_scale = 0.22;
uniform float rough = 1.0;
uniform float debug_weights = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

vec3 tri(sampler2D t, vec2 uv) {
	vec3 c = texture(t, uv).rgb * 0.52;
	c += texture(t, uv * 0.383 + vec2(0.317, 0.173)).rgb * 0.30;
	c += texture(t, uv * 0.113 + vec2(0.631, 0.419)).rgb * 0.18;
	return c;
}

void fragment() {
	vec2 uv = UV * base_scale;
	vec4 w = texture(biome_map, UV / map_size);
	float tot = w.r + w.g + w.b + w.a;
	if (tot < 0.001) {
		w = vec4(1.0, 0.0, 0.0, 0.0);
		tot = 1.0;
	}
	w /= tot;
	vec3 c;
	if (debug_weights > 0.5) {
		// 调试：直接输出权重场。平滑渐变 = 软混合生效；色块边界 = 没生效
		// （Godot 着色语言不允许在 fragment 里 return，必须走 if/else）
		c = w.rgb;
	} else {
		c = tri(tex0, uv) * tint0 * w.r
		  + tri(tex1, uv) * tint1 * w.g
		  + tri(tex2, uv) * tint2 * w.b
		  + tri(tex3, uv) * tint3 * w.a;
		float macro = vnoise(UV * 0.032) * 0.65 + vnoise(UV * 0.085) * 0.35;
		c *= (0.80 + 0.40 * macro);
	}
	ALBEDO = c;
	ROUGHNESS = rough;
	METALLIC = 0.0;
}
"""


func _ground_material(biome: Array, w: int, h: int) -> Material:
	var texs: Array = []
	for i in range(GROUND_TEX.size()):
		var path: String = TEX_DIR + String(GROUND_TEX[i])
		if not ResourceLoader.exists(path):
			return null
		# 手动生成 mipmap：贴图在屏幕上被大幅缩小，没 mipmap 就是一片高频噪点
		var img := Image.load_from_file(path)
		if img == null:
			return null
		img.generate_mipmaps()
		texs.append(ImageTexture.create_from_image(img))
	var m := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = GROUND_SHADER
	m.shader = sh
	for i in range(4):
		m.set_shader_parameter("tex%d" % i, texs[i])
		m.set_shader_parameter("tint%d" % i, BIOME_TUNE[i])
	var wimg := _biome_weight_image(biome, w, h)
	wimg.save_png(OUT_WEIGHTS)
	print("[3Dv2] 群系权重图已导出 %s（软混合半径 %d 格）" % [OUT_WEIGHTS, BIOME_BLEND_RADIUS])
	m.set_shader_parameter("biome_map", ImageTexture.create_from_image(wimg))
	m.set_shader_parameter("map_size", Vector2(float(w), float(h)))
	m.set_shader_parameter("base_scale", 1.0 / UV_PER_TEX)
	m.set_shader_parameter("rough", 1.0)
	m.set_shader_parameter("debug_weights", 1.0 if DEBUG_WEIGHTS else 0.0)
	return m


## 把群系索引表转成「4 通道权重贴图」：第 b 通道 = 该格属于群系 b 的权重。
## 再对 4 个通道分别做可分离盒式模糊，交界就从"一刀切"变成有宽度的渐变。
## 不能直接把「群系索引」放进单通道再模糊 —— 相邻 0 与 3 会平均出 1.5（错误的中间群系）。
func _biome_weight_image(biome: Array, w: int, h: int) -> Image:
	var n := w * h
	var src := PackedFloat32Array()
	src.resize(n * 4)
	for y in range(h):
		for x in range(w):
			var b: int = clampi(int(biome[y][x]), 0, 3)
			src[(y * w + x) * 4 + b] = 1.0

	var r: int = BIOME_BLEND_RADIUS
	var taps := float(2 * r + 1)
	var inv := 1.0 / taps

	# 水平 pass
	var tmp := PackedFloat32Array()
	tmp.resize(n * 4)
	for y in range(h):
		var row := y * w
		for x in range(w):
			var a0 := 0.0
			var a1 := 0.0
			var a2 := 0.0
			var a3 := 0.0
			for k in range(-r, r + 1):
				var i := (row + clampi(x + k, 0, w - 1)) * 4
				a0 += src[i]
				a1 += src[i + 1]
				a2 += src[i + 2]
				a3 += src[i + 3]
			var o := (row + x) * 4
			tmp[o] = a0 * inv
			tmp[o + 1] = a1 * inv
			tmp[o + 2] = a2 * inv
			tmp[o + 3] = a3 * inv

	# 垂直 pass
	var out := PackedFloat32Array()
	out.resize(n * 4)
	for y in range(h):
		for x in range(w):
			var a0 := 0.0
			var a1 := 0.0
			var a2 := 0.0
			var a3 := 0.0
			for k in range(-r, r + 1):
				var i := (clampi(y + k, 0, h - 1) * w + x) * 4
				a0 += tmp[i]
				a1 += tmp[i + 1]
				a2 += tmp[i + 2]
				a3 += tmp[i + 3]
			var o := (y * w + x) * 4
			out[o] = a0 * inv
			out[o + 1] = a1 * inv
			out[o + 2] = a2 * inv
			out[o + 3] = a3 * inv

	var bytes := PackedByteArray()
	bytes.resize(n * 4)
	for i in range(n * 4):
		bytes[i] = int(clampf(out[i], 0.0, 1.0) * 255.0 + 0.5)
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)


## 整张地图（取景窗口内）合一个网格：非墙格各出一个四边形，UV 直接写格坐标。
func _build_ground_mesh(terrain: Array, x0: int, x1: int, y0: int, y1: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for y in range(y0, y1):
		for x in range(x0, x1):
			if terrain[y][x]:
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
	var wp: String = TEX_DIR + WALL_TEX
	if ResourceLoader.exists(wp):
		var wimg := Image.load_from_file(wp)
		if wimg != null:
			wimg.generate_mipmaps()
			mat.albedo_texture = ImageTexture.create_from_image(wimg)
	mat.uv1_scale = Vector3(1.5, 1.5, 1.5)
	mat.albedo_color = Color(0.88, 0.88, 0.90)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.roughness = 0.80
	mat.metallic = 0.25
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
	print("[3Dv2] 墙体实例 %d" % cells.size())


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
		# 模型材质做一份亮度校正副本（原画明度不统一）
		if mat != null:
			var m2: Material = mat.duplicate()
			if m2 is StandardMaterial3D:
				var sm := m2 as StandardMaterial3D
				sm.albedo_color = sm.albedo_color * DECOR_TINT[k_i]
				sm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
			mat = m2
		if mesh == null:
			# 模型缺失时的替代几何体，保证探针仍可出图
			var fb := BoxMesh.new()
			fb.size = Vector3(0.8, MODEL_HEIGHT[k_i], 0.8)
			mesh = fb
		# GLB 常自带轴修正等节点变换，AABB 必须跟着变换后再用，否则会躺倒或尺寸失控
		var aabb := _transformed_aabb(mesh.get_aabb(), node_xf)
		var base_s: float = float(MODEL_HEIGHT[k_i]) / maxf(aabb.size.y, 0.001)
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
	print("[3Dv2] 装饰 kind=%d 实例 %d 曲面数=%d（模型=%s，目标高 %.2f，原始高 %.2f）"
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
# 相机 / 光照 / 环境（相机方位与 v1 完全一致，保证对比公平）
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
	# 光源方位取相机方位 +90°：物体侧面受光、阴影横投，既看得见又不背光成剪影
	l.rotation_degrees = Vector3(-40.0, 135.0, 0.0)
	# v2：直射略收，把"暗部"交给环境光去补，避免高光过曝而暗处仍死黑
	l.light_energy = 1.38
	l.light_color = Color(1.0, 0.95, 0.86)
	l.shadow_enabled = true
	l.shadow_bias = 0.025
	l.shadow_normal_bias = 0.8
	l.shadow_blur = 1.4
	l.shadow_opacity = 0.80          # v2：阴影不再压到纯黑
	l.directional_shadow_max_distance = 160.0
	l.light_angular_distance = 2.0   # 软阴影（Forward+ 有效）
	add_child(l)


func _setup_env() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.085, 0.088, 0.098)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.58, 0.58, 0.62)
	env.ambient_light_energy = 0.58   # v1 是 0.28 —— 暗部糊成一片、树变剪影的根因

	# v2 新增：SSAO，让物件与地面接触处、墙脚产生接触阴影，消除"贴纸感/发飘"
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.9
	env.ssao_power = 1.4
	env.ssao_light_affect = 0.35

	# v2 调整：雾只负责远景空气感与边缘消隐，第一版密度 0.009 太浓，把整张图压成了灰饼
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


# ------------------------------------------------------------
# 出图
# ------------------------------------------------------------

func _capture() -> void:
	for i in range(16):
		await RenderingServer.frame_post_draw
	var tex := get_viewport().get_texture()
	if tex == null:
		print("[3Dv2] 错误：拿不到视口纹理")
		get_tree().quit(1)
		return
	var img := tex.get_image()
	if img == null:
		print("[3Dv2] 错误：纹理转 Image 失败")
		get_tree().quit(1)
		return
	var err := img.save_png(OUT)
	print("[3Dv2] 输出=%s err=%d 尺寸=%dx%d" % [OUT, err, img.get_width(), img.get_height()])
	get_tree().quit(0)

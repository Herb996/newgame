extends Node3D
class_name MapRender3D
##
## 3D 地图渲染层（路线 2 双轨制：游戏逻辑在 2D，本节点只负责把地图数据画成 3D）
##
## build_from_map(result) 读取 MapGenerator.generate() 返回的数据表，渲染：
##   - 地板：单网格 + Texture2DArray 群系软混合（主导+次主导 id/权重，支持任意 N 群系）
##   - 墙体：MultiMesh 立方体
##   - 装饰：GLB + MultiMesh
##   - 矿脉：彩色发光标记 MultiMesh
##
## 与 v2 探针的差异：地板不再用 4 通道 RGBA 权重贴图（只能 4 群系），
## 改用 Texture2DArray（每群系一层地面纹理）+ 主导/次主导数据贴图，
## 因此加新群系（如草地）只改 config，着色器无需改动。

const TEX_DIR := "res://Assets/Art/Terrain3D/"
# 地面纹理的**回退**表，顺序必须与 config map.biomes 的 biome id 对齐。
# 正常运行走数据驱动：读 config map.biomes[i].ground_3d（见 ground_textures()），
# 只有 config 里没写 ground_3d 时才落到这里。加群系请改 config，不要改这张表。
const GROUND_TEX := [
	"ground_grass.png",   # 0 草地
	"ground_waste.png",   # 1 荒原
	"ground_forest.png",  # 2 森林
	"ground_snow.png",    # 3 雪原
]
const WALL_TEX := "wall_plate.png"

const MODEL_DIR := "res://Assets/Art/Models/"
const MODEL_FILES := ["tree.glb", "rock.glb", "debris.glb"]
const MODEL_CAP := 400

# ---- 装饰物尺寸（1 格 = 1 世界单位；坐标桥接：3D 单位 = 2D 像素 / tile_size）----
# 【2026-09-15 修「人物卡到树里」】
# 旧版只给一个"高度"，再由高度**等比**推出水平缩放。树模型是矮胖的（宽高比 0.73），
# 等比放大到 6.5 高时树冠横跨 5.3~6.3 格，而它在 walls 里只占 1 格 ——
# 玩家站在邻格（中心距离 1.0）整个人被树冠罩住，就是用户看到的"卡进树里"。
# 现在**高度与水平占地分开控制**：树做成细高，水平占地压到 1.5 格以内
# （半径 0.75 < 邻格距离 1.0），角色不会再被吞掉。
# 数值可改 config 的 map3d.model_height / map3d.model_footprint，缺省回落这里。
const MODEL_HEIGHT := [4.0, 1.2, 0.55]        # 世界高度
const MODEL_FOOTPRINT := [1.5, 1.35, 1.6]     # 水平占地直径**上限**（格），已含随机缩放
const MODEL_RAND_SCALE := [0.82, 1.18]        # 每实例的随机缩放区间

# 模型在 **GLB 节点变换之后** 的实测跨度（解析 GLB 的 POSITION accessor min/max，
# 再套 node 的 +90°X 四元数旋转；水平取 XZ 对角线，因为实例有随机 Y 旋转）：
#   tree   raw(0.798, 0.405, 1.092) → 变换后 X 0.798 / Y 1.092 / Z 0.405 → 对角 0.895
#   rock   raw(0.884, 0.944, 0.595) → 变换后 X 0.884 / Y 0.595 / Z 0.944 → 对角 1.293
#   debris raw(1.024, 1.051, 0.475) → 变换后 X 1.024 / Y 0.475 / Z 1.051 → 对角 1.467
# 只在模型没加载过时（如探针只想要数字）兜底；真正建装饰时以实测 AABB 为准。
const MODEL_SPAN_XZ := [0.895, 1.293, 1.467]
const MODEL_SPAN_Y := [1.092, 0.595, 0.475]

# 建装饰时把实测值缓存进来，供 decor_world_size() 复用（保证"设计值"与"实际值"同源）
static var _span_xz_cache: Array = []
static var _span_y_cache: Array = []

const UV_PER_TEX := 4.5
const WALL_H := 1.8
const BIOME_BLEND_RADIUS := 4

# 群系亮度校正的**回退**表：AI 原画明度不一，直接铺会曝白/过暗。
# 正常运行读 config map.biomes[i].ground_tune（见 biome_tunes()）。
const BIOME_TUNE := [
	Color(1.00, 1.00, 0.95),  # 0 草地（程序化，本身偏亮）
	Color(0.96, 0.93, 0.88),  # 1 荒原（AI 原画偏亮，压一档）
	Color(1.06, 1.06, 1.02),  # 2 森林（AI 原画偏暗，提一档）
	Color(0.84, 0.87, 0.92),  # 3 雪原（雪很亮，必须压暗否则曝白）
]

# 各类装饰的顶点色（键 = MapGenerator.DECOR_*）
const DECOR_TINT := {
	1: Color(1.00, 1.00, 1.00),  # 树
	2: Color(0.70, 0.70, 0.72),  # 石头（原画偏浅，压一档）
	3: Color(0.88, 0.88, 0.88),  # 残骸
	4: Color(1.00, 1.00, 1.00),  # 裂缝（贴地贴图，不动色）
	5: Color(1.00, 1.00, 1.00),  # 河水（贴地贴图，靠材质做透明/反光）
}

# 贴地特征（裂缝/河水）在 3D 里的高度偏移：必须离地一点，否则与地面网格 z-fighting。
# 相机距离 120、地面在 y=0，0.03 在深度缓冲里足够分开，视觉上仍贴着地。
const DECOR_FLAT_Y := 0.03

# 矿脉颜色（铁灰 / 金黄 / 油黑）
const VEIN_COLOR := {
	"iron": Color(0.62, 0.64, 0.68),
	"gold": Color(0.92, 0.74, 0.22),
	"oil":  Color(0.16, 0.15, 0.18),
}

# 着色器数组固定容量（最多 8 群系；超过需同步改这里）
const MAX_BIOMES := 8


func build_from_map(result: Dictionary) -> void:
	var terrain: Array = result["terrain"]
	var decor: Array = result["decor"]
	var biome: Array = result["biome"]
	var w: int = terrain[0].size()
	var h: int = terrain.size()
	_build_ground(terrain, biome, w, h)
	_build_walls(terrain, w, h)
	_build_decor(decor, w, h)
	_build_veins(result.get("veins", []))


# ------------------------------------------------------------
# 地板（Texture2DArray + 主导/次主导数据贴图）
# ------------------------------------------------------------

const GROUND_SHADER := """
shader_type spatial;
render_mode cull_disabled;

uniform sampler2DArray biome_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D data_map : filter_linear, repeat_disable;
uniform vec2 map_size = vec2(128.0, 128.0);
uniform int biome_count = 5;
uniform float base_scale = 0.22;
uniform float rough = 1.0;
uniform float debug_weights = 0.0;
uniform vec3 tints[8];

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

vec3 tri_arr(int layer, vec2 uv) {
	vec3 c = texture(biome_tex, vec3(uv, float(layer))).rgb * 0.52;
	c += texture(biome_tex, vec3(uv * 0.383 + vec2(0.317, 0.173), float(layer))).rgb * 0.30;
	c += texture(biome_tex, vec3(uv * 0.113 + vec2(0.631, 0.419), float(layer))).rgb * 0.18;
	return c;
}

void fragment() {
	vec2 uv = UV * base_scale;
	vec4 d = texture(data_map, UV / map_size);
	int i0 = int(clamp(floor(d.r * float(biome_count - 1) + 0.5), 0.0, float(biome_count - 1)));
	int i1 = int(clamp(floor(d.b * float(biome_count - 1) + 0.5), 0.0, float(biome_count - 1)));
	vec3 c;
	if (debug_weights > 0.5) {
		c = vec3(d.g, 0.0, d.a);
	} else {
		vec3 c0 = tri_arr(i0, uv) * tints[i0];
		vec3 c1 = tri_arr(i1, uv) * tints[i1];
		c = c0 * d.g + c1 * d.a;
		float macro = vnoise(UV * 0.032) * 0.65 + vnoise(UV * 0.085) * 0.35;
		c *= (0.80 + 0.40 * macro);
	}
	ALBEDO = c;
	ROUGHNESS = rough;
	METALLIC = 0.0;
}
"""


func _build_ground(terrain: Array, biome: Array, w: int, h: int) -> void:
	var gmesh := _build_ground_mesh(terrain, w, h)
	if gmesh == null:
		return
	var mat := _ground_material(biome, w, h)
	if mat == null:
		return                      # ArrayMesh 是 RefCounted，交给 GC，不能 free()
	var mi := MeshInstance3D.new()
	mi.name = "Ground"
	mi.mesh = gmesh
	mi.material_override = mat
	add_child(mi)


func _ground_material(biome: Array, w: int, h: int) -> Material:
	# 1) 每群系地面纹理装进 Texture2DArray（一层 = 一个群系）
	#    文件名数据驱动：config map.biomes[i].ground_3d，缺省回退 GROUND_TEX
	var tex_files: Array = ground_textures()
	var imgs: Array = []
	for i in range(tex_files.size()):
		var path: String = TEX_DIR + String(tex_files[i])
		var img := _load_ground_image(path)
		if img == null:
			push_error("[MapRender3D] 缺少地面纹理: " + path)
			return null
		if img.get_format() != Image.FORMAT_RGB8:
			img.convert(Image.FORMAT_RGB8)
		img.generate_mipmaps()
		imgs.append(img)
	var tex_arr := Texture2DArray.new()
	tex_arr.create_from_images(imgs)

	# 2) 主导/次主导权重数据贴图（R=id0, G=w0, B=id1, A=w1）
	var wimg := _biome_data_image(biome, w, h, tex_files.size())
	if wimg == null:
		return null

	var m := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = GROUND_SHADER
	m.shader = sh
	m.set_shader_parameter("biome_tex", tex_arr)
	m.set_shader_parameter("data_map", ImageTexture.create_from_image(wimg))
	m.set_shader_parameter("map_size", Vector2(float(w), float(h)))
	m.set_shader_parameter("biome_count", tex_files.size())
	m.set_shader_parameter("base_scale", 1.0 / UV_PER_TEX)
	m.set_shader_parameter("rough", 1.0)
	m.set_shader_parameter("debug_weights", 0.0)
	var tunes: Array = biome_tunes()
	var tints: Array = []
	tints.resize(MAX_BIOMES)
	for i in range(MAX_BIOMES):
		tints[i] = tunes[i] if i < tunes.size() else Color.WHITE
	m.set_shader_parameter("tints", tints)
	return m


## 3D 地面纹理文件名列表：优先 config map.biomes[i].ground_3d，缺省回退 GROUND_TEX。
## 加新群系（如雪原）时只需在 config 里补 "ground_3d"，本脚本零改动。
static func ground_textures() -> Array:
	var out: Array = []
	var bs: Array = Config.get_value("map.biomes", [])
	var n: int = bs.size() if bs.size() > 0 else GROUND_TEX.size()
	for i in range(n):
		var f: String = ""
		if i < bs.size() and bs[i] is Dictionary:
			f = str((bs[i] as Dictionary).get("ground_3d", ""))
		if f.is_empty() and i < GROUND_TEX.size():
			f = String(GROUND_TEX[i])
		if not f.is_empty():
			out.append(f)
	return out


## 3D 地面亮度校正表：优先 config map.biomes[i].ground_tune，缺省回退 BIOME_TUNE。
static func biome_tunes() -> Array:
	var out: Array = []
	var bs: Array = Config.get_value("map.biomes", [])
	var n: int = bs.size() if bs.size() > 0 else BIOME_TUNE.size()
	for i in range(n):
		var c: Color = BIOME_TUNE[i] if i < BIOME_TUNE.size() else Color.WHITE
		if i < bs.size() and bs[i] is Dictionary:
			var raw: Variant = (bs[i] as Dictionary).get("ground_tune", null)
			if raw is Array and (raw as Array).size() >= 3:
				c = Color(float(raw[0]), float(raw[1]), float(raw[2]))
		out.append(c)
	return out


## 健壮的地面纹理加载：已导入的走 Resource（导出安全、无警告），
## 尚未导入的新图（如刚生成的 ground_grass.png）回退 Image.load_from_file。
func _load_ground_image(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	if ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is Texture2D:
			var im: Image = (res as Texture2D).get_image()
			if im != null:
				return im
		elif res is Image:
			return res as Image
	if path.begins_with("res://"):
		return Image.load_from_file(ProjectSettings.globalize_path(path))
	return Image.load_from_file(path)


## 把群系索引表转成「主导+次主导 id/权重」数据贴图（支持任意 N 群系）。
## 先对每群系权重做可分离盒式模糊（交界变渐变），再每格取最大的两个群系归一化编码：
##   R = 主导群系 id/(N-1)，G = 主导权重，B = 次主导 id/(N-1)，A = 次主导权重。
func _biome_data_image(biome: Array, w: int, h: int, biome_n: int) -> Image:
	var n := w * h
	var nb := biome_n
	if nb < 2:
		push_error("[MapRender3D] 群系数 < 2，无法做主导/次主导混合")
		return null
	var src := PackedFloat32Array()
	src.resize(n * nb)
	for y in range(h):
		for x in range(w):
			var b: int = clampi(int(biome[y][x]), 0, nb - 1)
			src[(y * w + x) * nb + b] = 1.0

	var r: int = BIOME_BLEND_RADIUS
	var inv := 1.0 / float(2 * r + 1)

	# 水平 pass
	var tmp := PackedFloat32Array()
	tmp.resize(n * nb)
	for y in range(h):
		var row := y * w
		for x in range(w):
			for c in range(nb):
				var acc := 0.0
				for k in range(-r, r + 1):
					acc += src[(row + clampi(x + k, 0, w - 1)) * nb + c]
				tmp[(row + x) * nb + c] = acc * inv

	# 垂直 pass
	var out := PackedFloat32Array()
	out.resize(n * nb)
	for y in range(h):
		for x in range(w):
			for c in range(nb):
				var acc := 0.0
				for k in range(-r, r + 1):
					acc += tmp[(clampi(y + k, 0, h - 1) * w + x) * nb + c]
				out[(y * w + x) * nb + c] = acc * inv

	# 每格取 top2 群系，归一化后编码进 RGBA
	var idn := float(nb - 1)
	var bytes := PackedByteArray()
	bytes.resize(n * 4)
	for y in range(h):
		for x in range(w):
			var base := (y * w + x) * nb
			var i0 := 0
			var i1 := 0
			var w0 := -1.0
			var w1 := -1.0
			for c in range(nb):
				var v := out[base + c]
				if v > w0:
					w1 = w0
					i1 = i0
					w0 = v
					i0 = c
				elif v > w1:
					w1 = v
					i1 = c
			var sum := w0 + w1
			if sum < 0.001:
				w0 = 1.0
				w1 = 0.0
				sum = 1.0
			var n0 := w0 / sum
			var n1 := w1 / sum
			bytes[(y * w + x) * 4 + 0] = int(clampf(float(i0) / idn, 0.0, 1.0) * 255.0 + 0.5)
			bytes[(y * w + x) * 4 + 1] = int(clampf(n0, 0.0, 1.0) * 255.0 + 0.5)
			bytes[(y * w + x) * 4 + 2] = int(clampf(float(i1) / idn, 0.0, 1.0) * 255.0 + 0.5)
			bytes[(y * w + x) * 4 + 3] = int(clampf(n1, 0.0, 1.0) * 255.0 + 0.5)
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)


## 整张地图合一个网格：非墙格各出一个四边形，UV 直接写格坐标（供 data_map 采样）。
func _build_ground_mesh(terrain: Array, w: int, h: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for y in range(h):
		for x in range(w):
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

func _build_walls(terrain: Array, w: int, h: int) -> void:
	var cells: Array[Vector3i] = []
	for y in range(h):
		for x in range(w):
			if terrain[y][x]:
				cells.append(Vector3i(x, y, 0))
	if cells.is_empty():
		return
	var box := BoxMesh.new()
	box.size = Vector3(1.0, WALL_H, 1.0)
	var mat := StandardMaterial3D.new()
	var wp: String = TEX_DIR + WALL_TEX
	var wimg := _load_ground_image(wp)
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


# ------------------------------------------------------------
# 装饰物
# ------------------------------------------------------------

func _build_decor(decor: Array, w: int, h: int) -> void:
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
		if mat != null:
			var m2: Material = mat.duplicate()
			if m2 is StandardMaterial3D:
				var sm := m2 as StandardMaterial3D
				sm.albedo_color = sm.albedo_color * decor_tint(kind)
				sm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
			mat = m2
		if mesh == null:
			var fb := BoxMesh.new()
			fb.size = Vector3(0.8, model_height(k_i), 0.8)
			mesh = fb
		var aabb := _transformed_aabb(mesh.get_aabb(), node_xf)
		_cache_span(k_i, aabb)
		# 水平 / 垂直**分开缩放**（修「人物卡到树里」的关键）：
		#   x = 水平缩放：由"目标占地直径"反推，保证冠幅不越过邻格中心
		#   y = 垂直缩放：由"目标高度"反推，保证树还是树，不会被压成矮墩
		var scales := Vector2(
				model_footprint(k_i) / float(MODEL_RAND_SCALE[1]) / _span_xz(k_i),
				model_height(k_i) / _span_y(k_i))
		var pts: Array[Vector3] = []
		for y in range(h):
			for x in range(w):
				if int(decor[y][x]) != kind:
					continue
				pts.append(Vector3(x + 0.5 + rng.randf_range(-0.18, 0.18), 0.0,
						y + 0.5 + rng.randf_range(-0.18, 0.18)))
		if pts.is_empty():
			continue
		if pts.size() > MODEL_CAP:
			pts.shuffle()
			pts.resize(MODEL_CAP)
		_place_decor(kind, mesh, mat, node_xf, aabb, scales, pts, rng, k_i, src != null)

	# ---- 贴地特征：裂缝 / 河水 ----
	# 它们不是"物件"而是地表的一部分：整格铺一张程序化贴图，不做缩放/避免露格缝。
	# 贴图直接复用 MapGenerator 的生成函数（2D 与 3D 用同一张，观感一致）。
	_build_flat_decor(MapGenerator.DECOR_CRACK, decor, w, h, rng)
	_build_flat_decor(MapGenerator.DECOR_WATER, decor, w, h, rng)


## scales: x = 水平缩放，y = 垂直缩放（两者独立，见 _build_decor 的说明）
func _place_decor(kind: int, mesh: Mesh, mat: Material, node_xf: Transform3D, aabb: AABB,
		scales: Vector2, pts: Array[Vector3], rng: RandomNumberGenerator,
		k_i: int, from_glb: bool) -> void:
	var xfs: Array[Transform3D] = []
	for p in pts:
		var s := rng.randf_range(float(MODEL_RAND_SCALE[0]), float(MODEL_RAND_SCALE[1]))
		var rot := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(
				Vector3(scales.x * s, scales.y * s, scales.x * s))
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
	print("[MapRender3D] 装饰 kind=%d 实例 %d 曲面数=%d（模型=%s）"
			% [kind, xfs.size(), surfaces, "GLB" if from_glb else "替代"])


## 装饰顶点色（键 = DECOR_*）。未知类别返回白（不改色）。
static func decor_tint(kind: int) -> Color:
	return DECOR_TINT.get(kind, Color(1.0, 1.0, 1.0))


## 贴地特征（地表裂缝 / 河水）：整格 1×1 的朝上平面 + 程序化贴图。
## 与 2D 版共用 MapGenerator 的生成函数，保证两个入口看到的是同一张纹理。
## 河水额外做半透明 + 低粗糙 + 微自发光：浅水反光，且能隐约透出河床。
func _build_flat_decor(kind: int, decor: Array, w: int, h: int,
		rng: RandomNumberGenerator) -> void:
	# 贴图从 MapGenerator 的共享入口取：2D 与 3D 用同一张（同一份缓存）。
	# 注意：不能写 MapGenerator.call("_make_crack") —— call() 是 Object 的**非静态**
	# 成员，而 MapGenerator 是脚本类而非实例，直接调会编译不过。
	var tex: Texture2D = MapGenerator.decor_texture(kind)
	if tex == null:
		push_error("[MapRender3D] 贴地特征贴图缺失: kind=%d" % kind)
		return

	var is_water: bool = (kind == MapGenerator.DECOR_WATER)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.86 if is_water else 1.0)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.roughness = 0.14 if is_water else 0.95
	mat.metallic = 0.30 if is_water else 0.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if is_water:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = Color(0.16, 0.30, 0.38)
		mat.emission_energy_multiplier = 0.28

	var quad := PlaneMesh.new()
	quad.size = Vector2(1.0, 1.0)

	var xfs: Array[Transform3D] = []
	for y in range(h):
		for x in range(w):
			if int(decor[y][x]) != kind:
				continue
			# 裂缝随机 90° 旋转增加变化（贴图是四向贯通的，转 90° 不影响与邻格接缝）；
			# 河水**不旋转**，否则波纹方向会乱。
			var yaw := 0.0
			if not is_water:
				yaw = float(rng.randi_range(0, 3)) * PI * 0.5
			# 注意：**不要**再乘 Basis(RIGHT, -90°)。PlaneMesh 默认 orientation = FACE_Y，
			# AABB 是 (1, 0, 1)，本来就是水平的；再绕 X 转 90° 会把它立起来变成竖直的板子
			# （实测 AABB 变 (1, 1, 0)），裂缝和河水会像一堵堵墙一样站在地上。
			var basis := Basis(Vector3.UP, yaw)
			var pos := Vector3(float(x) + 0.5, DECOR_FLAT_Y, float(y) + 0.5)
			xfs.append(Transform3D(basis, pos))
	if xfs.is_empty():
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = xfs.size()
	for i in range(xfs.size()):
		mm.set_instance_transform(i, xfs[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Decor_%d" % kind
	mmi.multimesh = mm
	mmi.material_override = mat
	add_child(mmi)
	print("[MapRender3D] 贴地特征 kind=%d 实例 %d（%s）"
			% [kind, xfs.size(), "河水" if is_water else "裂缝"])


## 装饰在 3D 世界里**实际占多大**：返回 Vector2(世界高, 水平直径)，单位 = 格。
##
## 用途：判断"站着会不会被罩住"。1 格 = 1 世界单位，玩家站在邻格中心时距离
## 树心正好 1.0 —— 水平直径一旦 ≥ 2.0，人就被树冠整个罩进去（视觉穿模，
## 与"人物卡到树里"这条反馈直接相关）。
##
## 走的是与 _place_decor 完全相同的换算（同样的 model_height / model_footprint /
## 随机缩放上限），所以这里报出来的数字就是场景里真实落出来的尺寸。
static func decor_world_size(kind: int) -> Vector2:
	var k_i := _kind_index(kind)
	if k_i < 0 or k_i >= MODEL_HEIGHT.size():
		return Vector2.ZERO
	var span_y := _span_y(k_i)
	var span_xz := _span_xz(k_i)
	if span_y <= 0.0001 or span_xz <= 0.0001:
		return Vector2.ZERO
	var vs := model_height(k_i) / span_y
	var hs := model_footprint(k_i) / float(MODEL_RAND_SCALE[1]) / span_xz
	return Vector2(vs * span_y, hs * span_xz * float(MODEL_RAND_SCALE[1]))


## DECOR_* → 模型数组下标（DECOR_TREE(1) → 0 / ROCK(2) → 1 / DEBRIS(3) → 2）
static func _kind_index(kind: int) -> int:
	return clampi(kind - int(MapGenerator.DECOR_TREE), 0, MODEL_FILES.size() - 1)


## 世界高度（读 config map3d.model_height）
static func model_height(k_i: int) -> float:
	var arr: Array = Config.get_value("map3d.model_height", [])
	if arr.size() > k_i:
		return maxf(float(arr[k_i]), 0.01)
	return float(MODEL_HEIGHT[k_i])


## 水平占地直径上限（格，读 config map3d.model_footprint）
static func model_footprint(k_i: int) -> float:
	var arr: Array = Config.get_value("map3d.model_footprint", [])
	if arr.size() > k_i:
		return maxf(float(arr[k_i]), 0.01)
	return float(MODEL_FOOTPRINT[k_i])


static func _span_xz(k_i: int) -> float:
	if _span_xz_cache.size() > k_i:
		return maxf(float(_span_xz_cache[k_i]), 0.001)
	return float(MODEL_SPAN_XZ[k_i])


static func _span_y(k_i: int) -> float:
	if _span_y_cache.size() > k_i:
		return maxf(float(_span_y_cache[k_i]), 0.001)
	return float(MODEL_SPAN_Y[k_i])


## 把实测 AABB 缓存下来（供 decor_world_size 复用），
## 并与常量表比对 —— 换了模型却忘了改表时，日志里能直接看见。
static func _cache_span(k_i: int, aabb: AABB) -> void:
	var sxz := sqrt(aabb.size.x * aabb.size.x + aabb.size.z * aabb.size.z)
	if _span_xz_cache.size() <= k_i:
		_span_xz_cache.resize(k_i + 1)
	if _span_y_cache.size() <= k_i:
		_span_y_cache.resize(k_i + 1)
	_span_xz_cache[k_i] = sxz
	_span_y_cache[k_i] = aabb.size.y
	var ref_xz := float(MODEL_SPAN_XZ[k_i])
	var ref_y := float(MODEL_SPAN_Y[k_i])
	if ref_xz > 0.0 and absf(sxz - ref_xz) / ref_xz > 0.15:
		push_warning("[MapRender3D] 装饰 %d 实测水平跨度 %.3f 与常量表 %.3f 偏差 >15%%，"
				% [k_i, sxz, ref_xz] + " 模型换过了，请更新 MODEL_SPAN_XZ")
	if ref_y > 0.0 and absf(aabb.size.y - ref_y) / ref_y > 0.15:
		push_warning("[MapRender3D] 装饰 %d 实测高度 %.3f 与常量表 %.3f 偏差 >15%%，"
				% [k_i, aabb.size.y, ref_y] + " 模型换过了，请更新 MODEL_SPAN_Y")


func _load_model(i: int) -> PackedScene:
	var p := MODEL_DIR + String(MODEL_FILES[i]).replace(".glb", "") + ".glb"
	if not ResourceLoader.exists(p):
		return null
	var r = load(p)
	return r as PackedScene


static func _find_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh_instance(c)
		if r != null:
			return r
	return null


## 把模型 AABB 的 8 个角点按变换投影后重新求包围盒（GLB 自带轴修正时必需）。
static func _transformed_aabb(a: AABB, xf: Transform3D) -> AABB:
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
# 矿脉（彩色发光标记，便于 3D 下识别铁/金/油点位）
# ------------------------------------------------------------

func _build_veins(veins: Array) -> void:
	if veins.is_empty():
		return
	var by_res: Dictionary = {}
	for vd in veins:
		var rid: String = str(vd.get("res_id", ""))
		if not by_res.has(rid):
			by_res[rid] = []
		by_res[rid].append(Vector3(float(vd["gx"]) + 0.5, 0.0, float(vd["gy"]) + 0.5))
	for rid in by_res.keys():
		var pts: Array = by_res[rid]
		var box := BoxMesh.new()
		box.size = Vector3(0.55, 0.20, 0.55)
		var mat := StandardMaterial3D.new()
		var col: Color = VEIN_COLOR.get(rid, Color(1.0, 0.0, 1.0))
		mat.albedo_color = col
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = 0.7
		mat.roughness = 0.5
		mat.metallic = (rid == "iron" or rid == "gold")
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = box
		mm.instance_count = pts.size()
		for i in range(pts.size()):
			mm.set_instance_transform(i, Transform3D(Basis(), pts[i] + Vector3(0.0, 0.11, 0.0)))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Vein_" + rid
		mmi.multimesh = mm
		mmi.material_override = mat
		add_child(mmi)
	print("[MapRender3D] 矿脉标记：%s" % by_res)

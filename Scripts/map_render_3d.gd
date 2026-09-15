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
# 群系地面纹理，顺序必须与 config map.biomes 的 biome id 对齐
const GROUND_TEX := [
	"ground_forest.png",  # 0 林地
	"ground_waste.png",   # 1 荒原
	"ground_marsh.png",   # 2 锈泽
	"ground_rock.png",    # 3 石原
	"ground_grass.png",   # 4 草地（程序化生成）
]
const WALL_TEX := "wall_plate.png"

const MODEL_DIR := "res://Assets/Art/Models/"
const MODEL_FILES := ["tree.glb", "rock.glb", "debris.glb"]
const MODEL_HEIGHT := [6.5, 1.7, 0.6]
const MODEL_CAP := 400

const UV_PER_TEX := 4.5
const WALL_H := 1.8
const BIOME_BLEND_RADIUS := 4

# 群系亮度校正：AI 原画明度不一，直接铺会曝白/过暗
const BIOME_TUNE := [
	Color(1.06, 1.06, 1.02),  # 0 林地
	Color(0.96, 0.93, 0.88),  # 1 荒原
	Color(0.94, 1.00, 0.97),  # 2 锈泽
	Color(0.56, 0.57, 0.60),  # 3 石原
	Color(1.00, 1.00, 0.95),  # 4 草地
]
const DECOR_TINT := [
	Color(1.00, 1.00, 1.00),  # 树
	Color(0.70, 0.70, 0.72),  # 石头
	Color(0.88, 0.88, 0.88),  # 残骸
]

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
	var tints: Array = []
	tints.resize(MAX_BIOMES)
	for i in range(MAX_BIOMES):
		tints[i] = BIOME_TUNE[i] if i < BIOME_TUNE.size() else Color.WHITE
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
				sm.albedo_color = sm.albedo_color * DECOR_TINT[k_i]
				sm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
			mat = m2
		if mesh == null:
			var fb := BoxMesh.new()
			fb.size = Vector3(0.8, MODEL_HEIGHT[k_i], 0.8)
			mesh = fb
		var aabb := _transformed_aabb(mesh.get_aabb(), node_xf)
		var base_s: float = float(MODEL_HEIGHT[k_i]) / maxf(aabb.size.y, 0.001)
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
		_place_decor(kind, mesh, mat, node_xf, aabb, base_s, pts, rng, k_i, src != null)


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
	print("[MapRender3D] 装饰 kind=%d 实例 %d 曲面数=%d（模型=%s）"
			% [kind, xfs.size(), surfaces, "GLB" if from_glb else "替代"])


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


## 把模型 AABB 的 8 个角点按变换投影后重新求包围盒（GLB 自带轴修正时必需）。
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

extends Node3D
class_name BaseRender3D
## ============================================================
## BaseRender3D — 基地 3D 地形渲染层
##
## 基地是一块固定平地（base.map_size × base.map_size，外圈 1 格墙），
## 本节点只负责把"地面"画成 3D：
##   · 地板：整块平面 + 三平面（triplanar）平铺的金属板纹理
##   · 外圈墙：MultiMesh 立方体（四条边）
##
## 建筑本体（仓库/雕像/大门）由 EntityVisual3D 按组 buildings 渲染，
## 逻辑层依旧是 2D（BaseSystem 造的 TileMapLayer 负责物理碰撞），
## 本节点不参与物理、不参与交互。
##
## 参数全部读 config 的 base 段，禁止硬编码。
## ============================================================

const TEX_DIR := "res://Assets/Art/Terrain3D/"


## 由 main3d.gd 在进入基地模式时调用
func build() -> void:
	var size: int = int(Config.get_value("base.map_size", 64))
	var wall_h: float = float(Config.get_value("base.wall_height", 1.8))
	var tex: String = str(Config.get_value("base.floor_3d", "wall_plate.png"))
	var uv_scale: float = float(Config.get_value("base.floor_uv_scale", 0.35))
	var mat := _plate_material(tex, uv_scale)
	_build_floor(size, mat)
	_build_ring_walls(size, wall_h, mat)
	print("[BaseRender3D] 基地 %dx%d 已渲染（墙高 %.1f，地板贴图 %s）" % [
			size, size, wall_h, tex])


## 金属板材质：三平面平铺，不必给每个网格准备 UV
func _plate_material(tex: String, uv_scale: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var path := TEX_DIR + tex
	if ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is Texture2D:
			mat.albedo_texture = res as Texture2D
	else:
		push_warning("[BaseRender3D] 缺少地板纹理 %s，使用纯色" % path)
	mat.albedo_color = Color(0.90, 0.88, 0.85)
	mat.uv1_triplanar = true
	mat.uv1_scale = Vector3(uv_scale, uv_scale, uv_scale)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.roughness = 0.72
	mat.metallic = 0.30
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _build_floor(size: int, mat: Material) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(float(size), float(size))
	var mi := MeshInstance3D.new()
	mi.name = "BaseFloor"
	mi.mesh = plane
	mi.material_override = mat
	# PlaneMesh 以原点为中心，挪到 [0, size] × [0, size] 的地图范围
	mi.position = Vector3(float(size) * 0.5, 0.0, float(size) * 0.5)
	add_child(mi)


func _build_ring_walls(size: int, wall_h: float, mat: Material) -> void:
	# 注意：Vector3i 的第二槽是 y，格坐标要放 (x, 0, z)，别把 z 塞进 y
	var cells: Array[Vector3i] = []
	for i in range(size):
		cells.append(Vector3i(i, 0, 0))                  # z = 0 边
		cells.append(Vector3i(0, 0, i))                  # x = 0 边
		cells.append(Vector3i(size - 1, 0, i))           # x = size-1 边
		cells.append(Vector3i(i, 0, size - 1))           # z = size-1 边
	var box := BoxMesh.new()
	box.size = Vector3(1.0, wall_h, 1.0)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = cells.size()
	for i in range(cells.size()):
		var c: Vector3i = cells[i]
		mm.set_instance_transform(i, Transform3D(Basis(),
				Vector3(float(c.x) + 0.5, wall_h * 0.5, float(c.z) + 0.5)))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "BaseWalls"
	mmi.multimesh = mm
	mmi.material_override = mat
	add_child(mmi)

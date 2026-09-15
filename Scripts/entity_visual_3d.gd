extends Node3D
class_name EntityVisual3D
## ============================================================
## EntityVisual3D — 实体 3D 表现层
##
## 双轨制的"渲染侧"：把 LogicRoot 里那些**不可见**的 2D 逻辑实体
## 映射成 3D 表现。逻辑（碰撞 / AI / 拾取 / 交互）仍然全跑在 2D，
## 本节点只负责"跟着画"。
##
## 覆盖四类实体：
##   · 敌人（组 enemies）          MultiMesh 棱柱，颜色随警觉状态（读 Body.modulate）
##   · 资源点（组 loot_nodes）      MultiMesh 低模球，颜色 = resources.<id>.color
##   · 撤离点（组 extraction_points）圆环 + 光柱，开放=蒸汽白，关闭=暗红
##   · 建筑（组 buildings）        BoxMesh + Label3D（基地用）
##
## 可见性：由 Fog3D 判定（当前视野半径内才显示）；基地无迷雾则全部可见。
## 敌人/资源点用 MultiMesh 承载（一局最多 100 敌人 / 数百资源点），
## 逐帧只改 transform 与 color，不重建节点。
## ============================================================

const ENEMY_CAP := 512
const LOOT_CAP := 2048

## 3D 占位造型尺寸（正式模型到位后替换 mesh 即可，接口不变）
const ENEMY_HEIGHT := 1.05
const ENEMY_RADIUS := 0.30
const LOOT_RADIUS := 0.22
const BUILDING_FOOT := 4.2

## 建筑配色（与 2D 版 building.gd::_color_for 保持一致）
const BUILDING_COLOR := {
	"warehouse": Color(0.55, 0.33, 0.16),   # 铜锈
	"statue": Color(0.82, 0.78, 0.62),      # 淡金/蒸汽白系
	"gate": Color(0.30, 0.24, 0.19),        # 深棕
}
const BUILDING_HEIGHT := {"warehouse": 2.6, "statue": 3.4, "gate": 2.2}

var tile := 16.0

var _fog: Fog3D = null
var _player: Node2D = null

var _enemy_mm: MultiMesh = null
var _loot_mm: MultiMesh = null
var _res_colors: Dictionary = {}
var _bld_height: Dictionary = {}

# 逐节点表现（撤离点 / 建筑，数量少，不值得上 MultiMesh）
var _ext_vis: Dictionary = {}
var _bld_vis: Dictionary = {}


## 由 main3d.gd 每种模式重建一次。fog 传 null 表示无迷雾（基地）
func setup(tile_size: int, fog: Fog3D) -> void:
	tile = float(tile_size)
	_fog = fog
	_player = null
	_ext_vis.clear()
	_bld_vis.clear()
	_cache_res_colors()
	_cache_building_heights()
	_build_enemy_multimesh()
	_build_loot_multimesh()


# ------------------------------------------------------------
# 每帧同步
# ------------------------------------------------------------

func sync() -> void:
	_refresh_player()
	_sync_enemies()
	_sync_loot()
	_sync_extraction()
	_sync_buildings()


func _refresh_player() -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node2D


## 2D 像素坐标 → 3D 世界坐标
func _world(pos: Vector2, y: float) -> Vector3:
	return Vector3(pos.x / tile, y, pos.y / tile)


func _visible(pos: Vector2) -> bool:
	if _fog == null:
		return true
	return _fog.is_visible_px(pos)


# ------------------------------------------------------------
# 敌人
# ------------------------------------------------------------

func _build_enemy_multimesh() -> void:
	var cyl := CylinderMesh.new()
	cyl.top_radius = ENEMY_RADIUS * 0.55
	cyl.bottom_radius = ENEMY_RADIUS
	cyl.height = ENEMY_HEIGHT
	cyl.radial_segments = 6
	cyl.rings = 1
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 1.0)
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	mat.metallic = 0.10
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_enemy_mm = MultiMesh.new()
	_enemy_mm.transform_format = MultiMesh.TRANSFORM_3D
	_enemy_mm.use_colors = true
	_enemy_mm.mesh = cyl
	_enemy_mm.instance_count = ENEMY_CAP
	_enemy_mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Enemies"
	mmi.multimesh = _enemy_mm
	mmi.material_override = mat
	add_child(mmi)


func _sync_enemies() -> void:
	if _enemy_mm == null:
		return
	var list: Array = get_tree().get_nodes_in_group("enemies")
	var i := 0
	for e in list:
		if i >= ENEMY_CAP:
			break
		if not (e is Node2D):
			continue
		var n2 := e as Node2D
		var pos: Vector2 = n2.global_position
		if not _visible(pos):
			continue
		var body := n2.get_node_or_null("Body")
		var mod := Color.WHITE
		if body != null and body is CanvasItem:
			mod = (body as CanvasItem).modulate
		var col := Color(0.78, 0.25, 0.10) * mod
		col.a = 1.0
		_enemy_mm.set_instance_transform(i,
				Transform3D(Basis(), _world(pos, ENEMY_HEIGHT * 0.5)))
		_enemy_mm.set_instance_color(i, col)
		i += 1
	_enemy_mm.visible_instance_count = i


# ------------------------------------------------------------
# 资源点
# ------------------------------------------------------------

func _cache_res_colors() -> void:
	_res_colors.clear()
	var res: Dictionary = Config.get_value("resources", {})
	for rid in res.keys():
		var v = res[rid]
		if v is Dictionary:
			_res_colors[str(rid)] = Color(str((v as Dictionary).get("color", "#ffffff")))


func _build_loot_multimesh() -> void:
	var sph := SphereMesh.new()
	sph.radius = LOOT_RADIUS
	sph.height = LOOT_RADIUS * 2.0
	sph.radial_segments = 8
	sph.rings = 4
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 1.0)
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.55
	mat.emission_enabled = true
	mat.emission = Color(1.0, 1.0, 1.0)
	mat.emission_energy_multiplier = 0.30
	_loot_mm = MultiMesh.new()
	_loot_mm.transform_format = MultiMesh.TRANSFORM_3D
	_loot_mm.use_colors = true
	_loot_mm.mesh = sph
	_loot_mm.instance_count = LOOT_CAP
	_loot_mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "LootNodes"
	mmi.multimesh = _loot_mm
	mmi.material_override = mat
	add_child(mmi)


func _sync_loot() -> void:
	if _loot_mm == null:
		return
	var list: Array = get_tree().get_nodes_in_group("loot_nodes")
	var i := 0
	for n in list:
		if i >= LOOT_CAP:
			break
		if not (n is Node2D):
			continue
		var n2 := n as Node2D
		var pos: Vector2 = n2.global_position
		if not _visible(pos):
			continue
		var rid: String = str(n2.get("resource_id"))
		var col: Color = _res_colors.get(rid, Color(1.0, 0.0, 1.0))
		var s: float = clampf(n2.scale.x, 0.4, 1.6)      # 敌人掉落物 scale=0.8，略小
		var b := Basis().scaled(Vector3(s, s, s))
		_loot_mm.set_instance_transform(i, Transform3D(b, _world(pos, LOOT_RADIUS * s)))
		_loot_mm.set_instance_color(i, col)
		i += 1
	_loot_mm.visible_instance_count = i


# ------------------------------------------------------------
# 撤离点
# ------------------------------------------------------------

func _sync_extraction() -> void:
	var list: Array = get_tree().get_nodes_in_group("extraction_points")
	var alive: Dictionary = {}
	for p in list:
		if not (p is Node2D):
			continue
		var n2 := p as Node2D
		var id: int = n2.get_instance_id()
		alive[id] = true
		if not _ext_vis.has(id):
			_ext_vis[id] = _make_extraction_visual(n2)
		_update_extraction_visual(_ext_vis[id], n2)
	for id in _ext_vis.keys().duplicate():
		if not alive.has(id):
			_drop(_ext_vis[id])
			_ext_vis.erase(id)


func _make_extraction_visual(p: Node2D) -> Node3D:
	var radius_world: float = maxf(float(p.get("radius")) / tile, 0.8)
	var root := Node3D.new()
	root.name = "Extract_%d" % p.get_instance_id()

	var tor := TorusMesh.new()
	tor.inner_radius = radius_world - 0.10
	tor.outer_radius = radius_world + 0.10
	tor.rings = 32
	tor.ring_segments = 6
	var ring := MeshInstance3D.new()
	ring.name = "Ring"
	ring.mesh = tor
	ring.position = Vector3(0.0, 0.08, 0.0)
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(0.91, 0.90, 0.86)
	rmat.emission_enabled = true
	rmat.emission = Color(0.91, 0.90, 0.86)
	rmat.emission_energy_multiplier = 1.2
	rmat.roughness = 0.4
	ring.material_override = rmat
	root.add_child(ring)

	var cyl := CylinderMesh.new()
	cyl.top_radius = radius_world * 0.92
	cyl.bottom_radius = radius_world * 0.92
	cyl.height = 3.4
	cyl.radial_segments = 24
	var pil := MeshInstance3D.new()
	pil.name = "Pillar"
	pil.mesh = cyl
	pil.position = Vector3(0.0, 1.7, 0.0)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.91, 0.90, 0.86, 0.10)
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pmat.emission_enabled = true
	pmat.emission = Color(0.91, 0.90, 0.86)
	pmat.emission_energy_multiplier = 0.25
	pmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pil.material_override = pmat
	root.add_child(pil)

	var label := Label3D.new()
	label.name = "Title"
	label.text = "撤离点"
	label.font_size = 72
	label.pixel_size = 0.022
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.outline_size = 16
	label.modulate = Color(0.95, 0.94, 0.90)
	label.position = Vector3(0.0, 4.2, 0.0)
	root.add_child(label)

	add_child(root)
	return root


func _update_extraction_visual(root: Node3D, p: Node2D) -> void:
	if root == null or not is_instance_valid(root):
		return
	var pos: Vector2 = p.global_position
	root.position = _world(pos, 0.0)
	root.visible = _visible(pos)
	var open: bool = bool(p.get("is_open"))
	var hold: float = float(p.get("hold_progress"))
	var hold_max: float = maxf(float(p.get("hold_seconds")), 0.001)
	var frac: float = clampf(hold / hold_max, 0.0, 1.0)
	var ring := root.get_node_or_null("Ring") as MeshInstance3D
	if ring != null and ring.material_override is StandardMaterial3D:
		var m := ring.material_override as StandardMaterial3D
		if open:
			# 开放：蒸汽白，撤离进度越高越亮（警示橙偏色）
			var base := Color(0.91, 0.90, 0.86).lerp(Color(1.0, 0.55, 0.15), frac)
			m.albedo_color = base
			m.emission = base
			m.emission_energy_multiplier = 1.0 + 1.6 * frac
		else:
			m.albedo_color = Color(0.45, 0.14, 0.10)
			m.emission = Color(0.45, 0.14, 0.10)
			m.emission_energy_multiplier = 0.5
	var pil := root.get_node_or_null("Pillar") as MeshInstance3D
	if pil != null:
		pil.visible = open
		if pil.material_override is StandardMaterial3D:
			var pm := pil.material_override as StandardMaterial3D
			pm.albedo_color = Color(0.91, 0.90, 0.86, 0.08 + 0.12 * frac)
	var title := root.get_node_or_null("Title") as Label3D
	if title != null:
		title.text = "撤离点" if open else "撤离点（已关闭）"
		title.modulate = Color(0.95, 0.94, 0.90) if open else Color(0.62, 0.30, 0.26)


# ------------------------------------------------------------
# 建筑（基地）
# ------------------------------------------------------------

func _cache_building_heights() -> void:
	_bld_height.clear()
	for b in Config.get_value("base.buildings", []):
		if b is Dictionary:
			var bd := b as Dictionary
			var bid := str(bd.get("id", ""))
			if bid.is_empty():
				continue
			var h := float(bd.get("h3d", BUILDING_HEIGHT.get(bid, 2.4)))
			_bld_height[bid] = h


func _sync_buildings() -> void:
	var list: Array = get_tree().get_nodes_in_group("buildings")
	var alive: Dictionary = {}
	for b in list:
		if not (b is Node2D):
			continue
		var n2 := b as Node2D
		var id: int = n2.get_instance_id()
		alive[id] = true
		if not _bld_vis.has(id):
			_bld_vis[id] = _make_building_visual(n2)
		_update_building_visual(_bld_vis[id], n2)
	for id in _bld_vis.keys().duplicate():
		if not alive.has(id):
			_drop(_bld_vis[id])
			_bld_vis.erase(id)


func _make_building_visual(b: Node2D) -> Node3D:
	var bid: String = str(b.get("building_id"))
	var h: float = float(_bld_height.get(bid, 2.4))
	var root := Node3D.new()
	root.name = "Building_%s" % bid

	var box := BoxMesh.new()
	box.size = Vector3(BUILDING_FOOT, h, BUILDING_FOOT)
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = box
	body.position = Vector3(0.0, h * 0.5, 0.0)
	var mat := StandardMaterial3D.new()
	var col: Color = BUILDING_COLOR.get(bid, Color(0.5, 0.5, 0.5))
	mat.albedo_color = col
	mat.roughness = 0.70
	mat.metallic = 0.35
	body.material_override = mat
	root.add_child(body)

	# 屋顶挑檐：让体块不那么"方"，一眼能认出是建筑
	var roof := BoxMesh.new()
	roof.size = Vector3(BUILDING_FOOT + 0.6, 0.22, BUILDING_FOOT + 0.6)
	var rmi := MeshInstance3D.new()
	rmi.name = "Roof"
	rmi.mesh = roof
	rmi.position = Vector3(0.0, h + 0.11, 0.0)
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = col.darkened(0.35)
	rmat.roughness = 0.75
	rmat.metallic = 0.30
	rmi.material_override = rmat
	root.add_child(rmi)

	var name_label := Label3D.new()
	name_label.name = "Name"
	name_label.text = str(b.get("display_name"))
	name_label.font_size = 72
	name_label.pixel_size = 0.022
	name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_label.no_depth_test = true
	name_label.outline_size = 16
	name_label.modulate = Color(0.96, 0.94, 0.88)
	name_label.position = Vector3(0.0, h + 1.15, 0.0)
	root.add_child(name_label)

	var hint_label := Label3D.new()
	hint_label.name = "Hint"
	hint_label.text = str(b.get("hint"))
	hint_label.font_size = 56
	hint_label.pixel_size = 0.020
	hint_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	hint_label.no_depth_test = true
	hint_label.outline_size = 16
	hint_label.modulate = Color(0.31, 0.76, 0.97)
	hint_label.position = Vector3(0.0, h + 0.62, 0.0)
	hint_label.visible = false
	root.add_child(hint_label)

	add_child(root)
	return root


func _update_building_visual(root: Node3D, b: Node2D) -> void:
	if root == null or not is_instance_valid(root):
		return
	var pos: Vector2 = b.global_position
	root.position = _world(pos, 0.0)
	root.visible = _visible(pos)
	# 玩家靠近 → 显示"按 E"提示（替代 2D 版挂在建筑头上的 Label）
	var hint := root.get_node_or_null("Hint") as Label3D
	if hint != null and _player != null and is_instance_valid(_player):
		var d_cells: float = pos.distance_to(_player.global_position) / tile
		hint.visible = d_cells <= float(Config.get_value("base.interact_radius_cells", 4.5))


## 统一回收：先摘出场景树再 queue_free，避免同名节点残留
func _drop(n: Node) -> void:
	if n != null and is_instance_valid(n):
		if n.get_parent() == self:
			remove_child(n)
		n.queue_free()

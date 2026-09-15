extends Node3D
class_name Fog3D
## ============================================================
## Fog3D — 3D 战争迷雾（替代 2D 的 fog_system.gd 黑色瓦片遮罩）
##
## 做法：
##   · 维护一张「地图格分辨率」的遮罩贴图（R 通道 = 已探索强度 0..1）
##   · 贴在一块贴着地面的水平面上，着色器按 R 输出 alpha：
##         R = 1 → 完全透明（看得见）    R = 0 → 不透明黑（未探索）
##   · 材质关闭深度测试并在最后绘制 → 能盖住墙 / 树 / 敌人，
##     不会出现「未探索区域还能看见墙顶」的穿帮
##   · 探索记忆只增不减（按 max 累积），每次揭开写入带软边的圆，边界平滑
##
## 世界坐标对齐：水平面若抬到高度 H，等距投影会让它相对地面偏移
##   L = H / tan(pitch)，方向沿 ±x ±z 各 L/√2。
## 着色器按 uv_shift 反向补偿，因此抬到任意高度都能与地面精确对齐
## （默认 H 很小 → 偏移≈0，对齐自然成立；想抬高也不会错位）。
##
## 敌人 / 资源点的可见性判定用 is_visible_px()：只看当前视野半径，
## 不看探索记忆（与 2D 版 fog_system 一致）。
##
## 参数：player.vision_radius_cells / fog3d.* / camera3d.pitch_deg
## ============================================================

const FOG_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, blend_mix, shadows_disabled;

uniform sampler2D mask : filter_linear, repeat_disable;
uniform vec2 uv_shift = vec2(0.0);
uniform float soft_lo = 0.22;
uniform float soft_hi = 0.68;
uniform vec4 fog_color : source_color = vec4(0.015, 0.015, 0.020, 1.0);

void fragment() {
	float e = texture(mask, UV + uv_shift).r;
	ALBEDO = fog_color.rgb;
	ALPHA = fog_color.a * (1.0 - smoothstep(soft_lo, soft_hi, e));
}
"""

var tile := 16
var map_w := 0
var map_h := 0
var radius_cells := 10
var vision_px := 160.0

var _soft_cells := 2.2
var _height := 0.06
var _active := false
var _armed := false                 # 是否已经 setup 过（有遮罩面）

var _explored := PackedByteArray()  # map_w*map_h，R8 强度
var _img: Image = null
var _tex: ImageTexture = null
var _plane: MeshInstance3D = null
var _mat: ShaderMaterial = null
var _last_player_px := Vector2.ZERO
var _revealed_cells := 0


## 由 main3d.gd 在装配世界时调用一次（常驻节点，跨局复用）
func configure() -> void:
	radius_cells = int(Config.get_value("player.vision_radius_cells", 10))
	vision_px = float(radius_cells * tile)
	_soft_cells = float(Config.get_value("fog3d.reveal_soft_cells", 2.2))
	_height = float(Config.get_value("fog3d.height", 0.06))


## 每局开始时重建遮罩（尺寸随地图变）
func setup(w: int, h: int, tile_size: int) -> void:
	tile = tile_size
	radius_cells = int(Config.get_value("player.vision_radius_cells", 10))
	vision_px = float(radius_cells * tile)
	_soft_cells = float(Config.get_value("fog3d.reveal_soft_cells", 2.2))
	_height = float(Config.get_value("fog3d.height", 0.06))
	if w == map_w and h == map_h and _armed:
		reset()
		return
	map_w = w
	map_h = h
	_explored = PackedByteArray()
	_explored.resize(map_w * map_h)
	_img = Image.create(map_w, map_h, false, Image.FORMAT_R8)
	_img.fill(Color(0, 0, 0, 1))
	_tex = ImageTexture.create_from_image(_img)
	if _plane != null and is_instance_valid(_plane):
		remove_child(_plane)
		_plane.queue_free()
	_build_plane()
	_armed = true
	_revealed_cells = 0
	print("[Fog3D] 迷雾就绪：%dx%d 格（视野半径 %d 格，软边 %.1f 格）"
			% [map_w, map_h, radius_cells, _soft_cells])


## 清空探索记忆（重开一局）
func reset() -> void:
	if _explored.size() != map_w * map_h:
		return
	_explored.fill(0)
	if _img != null:
		_img.fill(Color(0, 0, 0, 1))
		_tex.update(_img)
	_revealed_cells = 0


## 基地模式关掉；局内打开
func set_active(value: bool) -> void:
	_active = value
	if _plane != null and is_instance_valid(_plane):
		_plane.visible = value and bool(Config.get_value("fog3d.enabled", true))


func is_active() -> bool:
	return _active


## 每帧调用：揭开玩家周围 + 刷新贴图
func update_fog(player_px: Vector2) -> void:
	if not _active or _img == null:
		return
	_last_player_px = player_px
	if not _reveal_around(player_px):
		return
	apply_mask()


## 把累积的探索数据刷进 GPU 贴图
func apply_mask() -> void:
	if _img != null and _tex != null:
		_tex.update(_img)


## 当前视野半径内是否可见（敌人 / 资源点显隐用；不看探索记忆）
func is_visible_px(pos_px: Vector2) -> bool:
	if not _active:
		return true
	return pos_px.distance_to(_last_player_px) <= vision_px


func explored_cells() -> int:
	return _revealed_cells


## 揭开玩家周围一圈（带软边），返回是否有新进展
func _reveal_around(pos: Vector2) -> bool:
	var pc := Vector2i(int(floor(pos.x / float(tile))), int(floor(pos.y / float(tile))))
	var r := float(radius_cells)
	var reach := int(ceil(r + _soft_cells))
	var changed := false
	for dy in range(-reach, reach + 1):
		var y := pc.y + dy
		if y < 0 or y >= map_h:
			continue
		for dx in range(-reach, reach + 1):
			var x := pc.x + dx
			if x < 0 or x >= map_w:
				continue
			var d := sqrt(float(dx * dx + dy * dy))
			if d > r + _soft_cells:
				continue
			# 半径内=1；往外 _soft_cells 格线性衰减到 0
			var t := clampf((r + _soft_cells - d) / maxf(_soft_cells, 0.001), 0.0, 1.0)
			var v := int(t * 255.0 + 0.5)
			var i := y * map_w + x
			if v > int(_explored[i]):
				if int(_explored[i]) == 0:
					_revealed_cells += 1
				_explored[i] = v
				_img.set_pixel(x, y, Color(t, 0.0, 0.0, 1.0))
				changed = true
	return changed


# ------------------------------------------------------------
# 遮罩面
# ------------------------------------------------------------

func _build_plane() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(float(map_w), float(map_h))
	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = FOG_SHADER
	_mat.shader = sh
	_mat.set_shader_parameter("mask", _tex)
	_mat.set_shader_parameter("uv_shift", _uv_shift())
	_mat.set_shader_parameter("soft_lo", float(Config.get_value("fog3d.soft_lo", 0.22)))
	_mat.set_shader_parameter("soft_hi", float(Config.get_value("fog3d.soft_hi", 0.68)))
	var c := Color(str(Config.get_value("fog3d.color", "#040405")))
	_mat.set_shader_parameter("fog_color", c)
	_mat.render_priority = 100          # 最后绘制，压在所有几何之上
	_plane = MeshInstance3D.new()
	_plane.name = "FogPlane"
	_plane.mesh = plane
	_plane.material_override = _mat
	_plane.position = Vector3(float(map_w) * 0.5, _height, float(map_h) * 0.5)
	_plane.visible = _active
	add_child(_plane)
	print("[Fog3D] 遮罩面 %dx%d，高度 %.2f，UV 补偿 %s"
			% [map_w, map_h, _height, str(_uv_shift())])


## 水平面抬高 _height 后，等距投影相对地面的偏移补偿
func _uv_shift() -> Vector2:
	var pitch := deg_to_rad(float(Config.get_value("camera3d.pitch_deg", 45.5)))
	var tan_p := maxf(tan(pitch), 0.0001)
	var l := _height / tan_p / 1.41421356      # 相机方位 45°，x/z 各偏 L/√2
	return Vector2(l / maxf(float(map_w), 1.0), l / maxf(float(map_h), 1.0))

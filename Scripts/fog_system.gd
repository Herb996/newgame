extends Node
## ============================================================
## FogSystem — 2D 战争迷雾（软边羽化）+ 实体显隐（挂在 Main 下）
##
## 规则（Data/config/）：
##   player.vision_radius_cells：视野半径（格）
##   fog.feather_cells：揭示圈羽化半径（格，0=硬边）
##   - 未探索区域：黑色遮罩（覆盖全图，z_index=5）
##   - 已探索区域：永久揭开（探索记忆）
##   - 敌人/动物/资源点：只在玩家当前视野半径内可见
##
## 渲染：不再用逐格 TileMapLayer（硬边、且曾出现"黑点"），改为
##   一张「每格 1 像素」的探索遮罩纹理 + 覆盖全图的 Sprite2D 着色器。
##   着色器对遮罩做小半径高斯模糊 + smoothstep → 揭示圈边缘自然羽化。
##   用 Sprite2D(CanvasItem) 而非 ColorRect(Control)：Control 会进 GUI 输入层、
##   全屏覆盖可能吃掉 RTS 的点击/选中，Sprite2D 完全不参与输入。
##   CPU 只在探索到新格时更新遮罩并上传纹理（每帧至多一次），模糊在 GPU 做。
##
## 【一张遮罩，两个消费者】（2026-09-17 小地图同步迷雾）
##   遮罩是 RGBA8，每格 1 像素，两个通道各表达一件事：
##     .r = 已探索（1 已探索 / 0 未探索）→ 主地图着色器读它做羽化
##     .a = 未探索（1 未探索 / 0 已探索）→ 小地图直接当黑色遮罩叠上去
##   已探索 = (1,1,1,0)、未探索 = (0,0,0,1)，两者互为补，**同一张图同一份真相**。
##   为什么不让小地图自己维护一份：那样每次揭格要写两处、回基地/重开要清两处，
##   迟早对不上。改成「谁揭的格谁写这一个像素」，小地图只是消费者、零同步代码。
##   小地图零额外接口，只多做一次 draw_texture_rect；--no-fog / 局外时
##   minimap_fog_texture() 返回 null，小地图就不叠（行为同改造前）。
## ============================================================

var map_w := 0
var map_h := 0
var tile_size := 64
var radius_cells := 10
var vision_px := 640.0
var _explored: Dictionary = {}
var _active := false  # 仅局内激活（基地无雾）

var _mask: Image = null          # 每格 1 像素，RGBA8：R=已探索(0/1)、A=未探索(0/1)
var _mask_tex: ImageTexture = null   # 主地图着色器与小地图共用（小地图只读 .a）
var _overlay: Sprite2D = null
var _mat: ShaderMaterial = null
var _dirty := false

## 遮罩像素语义（互为补色，改这里两处消费者同时生效）：
##   未探索 → 主图 r=0（雾满）／小地图 a=1（盖住地形）
##   已探索 → 主图 r=1（雾空）／小地图 a=0（透出地形）
const UNEXPLORED := Color(0, 0, 0, 1)
const EXPLORED := Color(1, 1, 1, 0)

const FOG_SHADER := """
shader_type canvas_item;
uniform sampler2D explored_mask : filter_linear;
uniform vec2 texel = vec2(0.0078, 0.0078);   // 1 / 地图格数
uniform float blur = 2.0;                     // 羽化半径（格）
void fragment() {
	vec2 uv = UV;
	float e = 0.0;
	float wsum = 0.0;
	for (int i = -2; i <= 2; i++) {
		for (int j = -2; j <= 2; j++) {
			float w = 1.0 - length(vec2(float(i), float(j))) / 2.6;
			if (w <= 0.0) {
				continue;
			}
			e += texture(explored_mask, uv + vec2(float(i), float(j)) * texel * blur).r * w;
			wsum += w;
		}
	}
	e /= max(wsum, 1e-4);
	float fog = 1.0 - smoothstep(0.0, 1.0, e);
	COLOR = vec4(0.0, 0.0, 0.0, fog);
}
"""


## 由 main.gd 在地图生成后调用（玩家出生后再调用，避免第一帧闪现）
func setup(root: Node2D, map_data: Dictionary) -> void:
	_active = true
	_explored.clear()
	tile_size = int(map_data["tile_size"])
	var walls: Array = map_data["walls"]
	map_w = walls[0].size()
	map_h = walls.size()
	radius_cells = int(Config.get_value("player.vision_radius_cells", 10))
	vision_px = float(radius_cells * tile_size)
	var feather: float = float(Config.get_value("fog.feather_cells", 2.0))

	# 未探索初值 (0,0,0,1)：黑且不透明 —— 主着色器读到 r=0 → 全遮；
	# 小地图读到 a=1 → 同一格也是纯黑。一处赋值同时喂两边。
	_mask = Image.create(map_w, map_h, false, Image.FORMAT_RGBA8)
	_mask.fill(UNEXPLORED)
	_mask_tex = ImageTexture.create_from_image(_mask)

	var sh := Shader.new()
	sh.code = FOG_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.set_shader_parameter("explored_mask", _mask_tex)
	_mat.set_shader_parameter("texel", Vector2(1.0 / float(map_w), 1.0 / float(map_h)))
	_mat.set_shader_parameter("blur", maxf(feather, 0.0))

	# Sprite2D 铺满整图：CanvasItem，不参与 GUI/鼠标输入（避免挡住 RTS 选中）；
	# 纹理是每格 1 像素的探索遮罩，按 tile 放大铺满地图，UV 天然 0..1。
	_overlay = Sprite2D.new()
	_overlay.name = "FogOverlay"
	_overlay.centered = false
	_overlay.texture = _mask_tex
	_overlay.scale = Vector2(float(tile_size), float(tile_size))
	_overlay.material = _mat
	_overlay.z_index = 5
	root.add_child(_overlay)
	_dirty = true


## 由 main.gd 离开局内时调用
func deactivate() -> void:
	_active = false


## 调试/出图用：连遮罩层一起拆掉（--no-fog）。
func disable() -> void:
	deactivate()
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null


## 小地图的迷雾层来源：与主地图着色器**同一张纹理**（未探索处 a=1 = 纯黑）。
## 局外（基地）或 --no-fog 已 disable 时返回 null → 小地图不叠雾；
## 这条「同生共死」的规则很重要：否则 --no-fog 出图会出现主图没雾、小地图一片黑。
func minimap_fog_texture() -> ImageTexture:
	if not _active or _mask_tex == null:
		return null
	return _mask_tex


## 该格是否已探索（越界算未探索）。小地图/探针可查，避免各自重算记忆。
func is_explored_cell(c: Vector2i) -> bool:
	if c.x < 0 or c.y < 0 or c.x >= map_w or c.y >= map_h:
		return false
	return _explored.has(c)


func is_explored_world(pos: Vector2) -> bool:
	if tile_size <= 0:
		return false
	return is_explored_cell(Vector2i(floori(pos.x / tile_size), floori(pos.y / tile_size)))


## 已探索格数（探针/调试；3D 线同名方法叫什么这里就跟着叫什么）
func explored_cells() -> int:
	return _explored.size()


func _process(_delta: float) -> void:
	if not _active or _overlay == null:
		return
	var players := _alive_players()
	if players.is_empty():
		return
	# 小队模式：每名存活成员各自揭示一圈（探索记忆全队共享）
	var positions: Array = []
	for p in players:
		positions.append((p as Node2D).position)
	for pos in positions:
		_reveal_around(pos)
	_update_entity_visibility(positions)
	# 探索遮罩变化时上传一次纹理（模糊在着色器里做，CPU 不算）
	if _dirty:
		_mask_tex.update(_mask)
		_dirty = false


## 全部存活玩家（死亡成员不再揭示视野/不再照亮敌人）
func _alive_players() -> Array:
	var out: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and not bool(p.is_dead()):
			out.append(p)
	return out


## 揭开玩家周围的圆形区域（写进探索遮罩；已揭开的跳过，记忆永久保留）
func _reveal_around(pos: Vector2) -> void:
	var pc := Vector2i(floori(pos.x / tile_size), floori(pos.y / tile_size))
	var r := radius_cells
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r:
				continue
			var c := pc + Vector2i(dx, dy)
			if c.x < 0 or c.y < 0 or c.x >= map_w or c.y >= map_h:
				continue
			if not _explored.has(c):
				_explored[c] = true
				_mask.set_pixelv(c, EXPLORED)   # 小地图那一侧同时变透明
				_dirty = true


## 实体显隐白名单：视野半径内可见，视野外隐藏（不看探索记忆）。
const VISION_GROUPS := ["enemies", "animals", "loot_nodes"]


func _update_entity_visibility(positions: Array) -> void:
	for g in VISION_GROUPS:
		for n in get_tree().get_nodes_in_group(g):
			var vis := false
			for pos in positions:
				if n.position.distance_to(pos) <= vision_px:
					vis = true
					break
			n.visible = vis

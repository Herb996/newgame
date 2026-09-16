extends Area2D
## ============================================================
## Building — 基地建筑（占 base.building_cells 格见方，默认 4x4）
## 数据由 base_system 按 Data/config.json 的 base.buildings 注入：
##   building_id / display_name / hint（按 E 提示文本）/ sprite（Tiny Swords 建筑图）
## 玩家靠近时头顶显示提示，按 E 发出 interacted 信号（由 main 路由）。
##
## 摆放规则（2026-09-16 定）：节点原点 = 占地格的中心，所以贴图要"脚踩"在
## 占地格底边上——按占地尺寸等比缩放到不超出 (占地宽 x 占地高*1.4) 的框，
## 再把贴图底边对齐到 +占地高/2。这样屋顶可以向上探出占地，符合俯视透视。
## ============================================================

signal interacted(building_id: String)

var building_id := ""
var display_name := ""
var hint := ""
var _hint_label: Label
var _e_was_pressed := false  # 边沿检测：按住 E 只触发一次


func _ready() -> void:
	add_to_group("buildings")
	_hint_label = $HintLabel
	_hint_label.visible = false


func setup(id: String, b_name: String, hint_text: String, sprite_path: String = "") -> void:
	building_id = id
	display_name = b_name
	hint = hint_text
	$NameLabel.text = b_name
	_apply_sprite(sprite_path)
	_apply_footprint()
	_layout_labels()


## 贴图 + 缩放 + 脚踩对齐。缺图时保留一块 id 配色的方块，避免"建筑凭空消失"。
func _apply_sprite(sprite_path: String) -> void:
	var body := get_node_or_null("Body") as Sprite2D
	if body == null:
		return
	var cells := float(Config.get_value("base.building_cells", 4))
	var tile := float(Config.get_value("map.tile_size", 64))
	var foot_w := cells * tile
	var foot_h := cells * tile
	if sprite_path == "" or not ResourceLoader.exists(sprite_path):
		push_warning("[Building] 建筑贴图缺失：%s -> %s" % [building_id, sprite_path])
		return
	body.texture = load(sprite_path)
	var ts := body.texture.get_size()
	if ts.x <= 0.0 or ts.y <= 0.0:
		return
	# 等比缩放到不超出目标框；屋顶允许比占地高一档（1.4 倍）
	var k: float = minf(foot_w / ts.x, foot_h * 1.4 / ts.y)
	body.scale = Vector2(k, k)
	body.offset = Vector2(0.0, foot_h * 0.5 - ts.y * k * 0.5)
	body.modulate = Color(1, 1, 1)


## 占地碰撞 = 建筑实际占用的格子范围（不是贴图范围：屋顶能穿，墙不能穿）
func _apply_footprint() -> void:
	var shape_node := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node == null:
		return
	var cells := float(Config.get_value("base.building_cells", 4))
	var tile := float(Config.get_value("map.tile_size", 64))
	var side := cells * tile * 0.86     # 略小于占地，贴近墙体、不挡住门口
	if shape_node.shape is RectangleShape2D:
		(shape_node.shape as RectangleShape2D).size = Vector2(side, side)


## 名字/提示标签贴在贴图顶边之上（贴图高度随素材变化，硬编码偏移会飘）
func _layout_labels() -> void:
	var body := get_node_or_null("Body") as Sprite2D
	var top := -100.0
	if body != null and body.texture != null:
		top = body.offset.y - body.texture.get_size().y * body.scale.y * 0.5
	var name_label := get_node_or_null("NameLabel") as Label
	if name_label != null:
		name_label.offset_top = top - 30.0
		name_label.offset_bottom = top - 6.0
	var hint_label := get_node_or_null("HintLabel") as Label
	if hint_label != null:
		hint_label.offset_top = top - 8.0
		hint_label.offset_bottom = top + 16.0


## 建筑配色（01_ART_GUIDE.md 色调）。
## 2D 现在用 Tiny Swords 建筑贴图，不再靠纯色块；这张表保留给
## 「贴图缺失时的兜底色」与 3D 视觉层（entity_visual_3d.gd）共用。
func _color_for(id: String) -> Color:
	match id:
		"warehouse": return Color(0.55, 0.33, 0.16)   # 铜锈
		"statue": return Color(0.82, 0.78, 0.62)      # 淡金/蒸汽白系
		"gate": return Color(0.30, 0.24, 0.19)        # 深棕
		_: return Color(0.5, 0.5, 0.5)


func _physics_process(_delta: float) -> void:
	var player_inside := false
	for body in get_overlapping_bodies():
		if body.is_in_group("player"):
			player_inside = true
			break
	_hint_label.visible = player_inside
	_hint_label.text = hint
	var e_now: bool = Input.is_physical_key_pressed(KEY_E)
	if player_inside and e_now and not _e_was_pressed:
		interacted.emit(building_id)
	_e_was_pressed = e_now

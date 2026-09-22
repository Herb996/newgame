extends Area2D
## ============================================================
## Building — 基地建筑（占 base.building_cells 格见方，默认 4x4）
## 数据由 base_system 按 Data/config/ 的 base.buildings 注入：
##   building_id / display_name / hint（按 E 提示文本）/ sprite（Tiny Swords 建筑图）
## 玩家靠近时头顶显示提示，按 E 发出 interacted 信号（由 main 路由）。
##
## 摆放规则（2026-09-16 定）：节点原点 = 占地格的中心，所以贴图要"脚踩"在
## 占地格底边上——按占地尺寸等比缩放到不超出 (占地宽 x 占地高*1.4) 的框，
## 再把贴图底边对齐到 +占地高/2。这样屋顶可以向上探出占地，符合俯视透视。
## ============================================================

signal interacted(building_id: String)
signal reposition_requested(building_id: String)

## 序列帧动画名（AnimatedSprite2D 用）。动画建筑走 AnimBody，静态建筑走 Body，
## 两个节点同时存在、按需显示其一（见 _apply_sprite）。
const ANIM_NAME := "idle"

var building_id := ""
var display_name := ""
var hint := ""
var cell := Vector2i.ZERO          # 占地左上角格（base.buildings[*].cell）
## >1 = 本建筑走序列帧动画（AnimBody）；0 = 静态贴图（Body）
var _anim_frames := 0
## 参与布局的**单帧**尺寸（动画 = 一帧大小，静态 = 整图大小），给标签定位用
var _tex_size := Vector2.ZERO
var _hint_label: Label
var _e_was_pressed := false  # 边沿检测：按住 E 只触发一次


func _ready() -> void:
	add_to_group("buildings")
	_hint_label = $HintLabel
	_hint_label.visible = false
	# 基地无玩家角色（2026-09-16 改）：交互主方式 = 鼠标左键点击建筑本体。
	# 下方按 E 靠近交互逻辑保留，日后若在基地重新放置代理角色仍可用。
	input_event.connect(_on_area_input)


## 是否有放置模式在跑（跑的时候建筑不响应普通点击/交互，避免误触）
func _placing() -> bool:
	return get_tree() != null and get_tree().get_first_node_in_group("placement_active") != null


## 按占地左上角格摆位（节点原点 = 占地中心）
func set_cell(c: Vector2i) -> void:
	cell = c
	var tile := float(Config.get_value("map.tile_size", 64))
	var cells := float(Config.get_value("base.building_cells", 4))
	position = Vector2(c.x + cells * 0.5, c.y + cells * 0.5) * tile


## 鼠标点击建筑：左键=交互，右键=请求重摆。放置模式激活时忽略。
func _on_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if _placing():
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			interacted.emit(building_id)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			reposition_requested.emit(building_id)


## anim_frames > 1 → 按横排序列帧切图并循环播放（AnimBody）；否则走静态贴图（Body）。
## 帧宽 = 整图宽 ÷ anim_frames，帧高 = 整图高（目前两张素材都是单行）。
func setup(id: String, b_name: String, hint_text: String, sprite_path: String = "",
		anim_frames: int = 0, anim_fps: float = 8.0) -> void:
	building_id = id
	display_name = b_name
	hint = hint_text
	$NameLabel.text = b_name
	_apply_sprite(sprite_path, anim_frames, anim_fps)
	_apply_footprint()
	_layout_labels()


## 贴图 + 缩放 + 脚踩对齐。缺图时保留一块 id 配色的方块，避免"建筑凭空消失"。
func _apply_sprite(sprite_path: String, anim_frames: int = 0, anim_fps: float = 8.0) -> void:
	var body := get_node_or_null("Body") as Sprite2D
	var anim_body := get_node_or_null("AnimBody") as AnimatedSprite2D
	var cells := float(Config.get_value("base.building_cells", 4))
	var tile := float(Config.get_value("map.tile_size", 64))
	var foot_w := cells * tile
	var foot_h := cells * tile
	_anim_frames = 0
	if sprite_path == "" or not ResourceLoader.exists(sprite_path):
		push_warning("[Building] 建筑贴图缺失：%s -> %s" % [building_id, sprite_path])
		return
	var tex := load(sprite_path) as Texture2D
	if tex == null:
		return
	if anim_frames > 1 and anim_body != null:
		if _build_animation(anim_body, tex, anim_frames, anim_fps, foot_w, foot_h):
			_anim_frames = anim_frames
			# 静态 Body 留着不删：切回静态素材 / 缺帧回退时还要用它
			if body != null:
				body.visible = false
			return
	if anim_body != null:
		anim_body.visible = false
	if body == null:
		return
	body.texture = tex
	var ts := body.texture.get_size()
	if ts.x <= 0.0 or ts.y <= 0.0:
		return
	_tex_size = ts
	# 等比缩放到不超出目标框；屋顶允许比占地高一档（1.4 倍）
	var k: float = minf(foot_w / ts.x, foot_h * 1.4 / ts.y)
	body.scale = Vector2(k, k)
	body.offset = Vector2(0.0, foot_h * 0.5 - ts.y * k * 0.5)
	body.modulate = Color(1, 1, 1)


## 把横排 sheet 切成 frames 帧塞进 SpriteFrames 并播放。返回 false = 切不了（回退静态）。
## ⚠ 每帧用 AtlasTexture 引用**同一张**导入贴图，不是拆成 frames 张小图 —— 拆图要改
##   落盘资源，而 AtlasTexture 是纯运行时对象，换素材不用重新导入。
func _build_animation(node: AnimatedSprite2D, tex: Texture2D, frames: int, fps: float,
		foot_w: float, foot_h: float) -> bool:
	var ts := tex.get_size()
	if ts.x <= 0.0 or ts.y <= 0.0:
		return false
	var fw := ts.x / float(frames)
	var fh := ts.y
	var sf := SpriteFrames.new()
	if not sf.has_animation(ANIM_NAME):
		sf.add_animation(ANIM_NAME)
	sf.set_animation_speed(ANIM_NAME, fps)
	sf.set_animation_loop(ANIM_NAME, true)
	for i in range(frames):
		var atlas := AtlasTexture.new()
		atlas.atlas = tex
		atlas.region = Rect2(float(i) * fw, 0.0, fw, fh)
		sf.add_frame(ANIM_NAME, atlas)
	node.sprite_frames = sf
	# 同一套「占地方框 + 屋顶可上探 1.4 倍」规则，保证动画/静态建筑一样大
	var k: float = minf(foot_w / fw, foot_h * 1.4 / fh)
	node.scale = Vector2(k, k)
	node.offset = Vector2(0.0, foot_h * 0.5 - fh * k * 0.5)
	node.modulate = Color(1, 1, 1)
	node.visible = true
	node.play(ANIM_NAME)
	_tex_size = Vector2(fw, fh)
	return true


## 当前用于显示的贴图（动画建筑 = 第 0 帧）。重摆幽灵图 / 出图探针取这个，
## 免得外面还要判断「这栋是动画还是静态」。
func get_body_texture() -> Texture2D:
	if _anim_frames > 0:
		var anim_body := get_node_or_null("AnimBody") as AnimatedSprite2D
		if anim_body != null and anim_body.sprite_frames != null:
			return anim_body.sprite_frames.get_frame_texture(ANIM_NAME, 0)
	var body := get_node_or_null("Body") as Sprite2D
	return body.texture if body != null else null


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
	var top := -100.0
	var off_y := 0.0
	var k := 1.0
	var h := 0.0
	if _anim_frames > 0:
		var anim_body := get_node_or_null("AnimBody") as AnimatedSprite2D
		if anim_body != null:
			off_y = anim_body.offset.y
			k = anim_body.scale.y
			h = _tex_size.y
	else:
		var body := get_node_or_null("Body") as Sprite2D
		if body != null and body.texture != null:
			off_y = body.offset.y
			k = body.scale.y
			h = body.texture.get_size().y
	if h > 0.0:
		top = off_y - h * k * 0.5
	var name_label := get_node_or_null("NameLabel") as Label
	if name_label != null:
		name_label.offset_top = top - 30.0
		name_label.offset_bottom = top - 6.0
	var hint_label := get_node_or_null("HintLabel") as Label
	if hint_label != null:
		hint_label.offset_top = top - 8.0
		hint_label.offset_bottom = top + 16.0


## 建筑配色（DESIGN.md 色调）。
## 2D 现在用 Tiny Swords 建筑贴图，不再靠纯色块；这张表保留给
## 「贴图缺失时的兜底色」与 3D 视觉层（entity_visual_3d.gd）共用。
func _color_for(id: String) -> Color:
	match id:
		"warehouse": return Color(0.55, 0.33, 0.16)   # 铜锈
		"statue": return Color(0.82, 0.78, 0.62)      # 淡金/蒸汽白系
		"gate": return Color(0.30, 0.24, 0.19)        # 深棕
		_: return Color(0.5, 0.5, 0.5)


func _physics_process(_delta: float) -> void:
	if _placing():
		_hint_label.visible = false
		return
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

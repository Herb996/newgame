class_name PlayerVisual3D
extends Node3D
## ============================================================
## PlayerVisual3D — 3D 玩家视觉层（HD-2D：2D 序列帧 + 朝向相机的公告板）
##
## 为什么不是真 3D 模型：
##   Assets/Art/Source3D/player_character.glb 是 AI 文生 3D 的**静态网格**
##   （50 万三角面、skins=0、animations=[]）—— 没有骨骼就没有行走动画，
##   要在 3D 里真动起来只能进 Blender 绑骨重做。序列帧这条路与项目现有
##   2D 像素风同源，且 **2D 版与 3D 版共用同一份 config sprites 数据、
##   同一套 FSM 状态判定**（都从 PlayerAnimator 取），画面上是同一款游戏。
##
## 坐标：本节点放在「脚底」对应的世界点上（3D 单位 = 2D 像素 / tile_size）。
##       贴图用 offset 对齐到画布底边中心，与 PlayerAnimator.SPRITE_OFFSET_Y 同约定。
##
## 使用（main3d.gd）：
##   var v := PlayerVisual3D.new()
##   world.add_child(v)
##   if not v.build(Config.get_value("sprites", {}), Config.get_value("player3d", {})):
##       v.queue_free(); v = null      # 素材缺失 → 调用方回退到胶囊占位
##   # 每帧：
##   v.position = Vector3(px / tile, 0.0, py / tile)
##   v.set_state(player.current_anim(), PlayerAnimator.dir_from_facing(player.facing))
##   v.set_selected(player.selected)
## ============================================================

const ANIMATOR := preload("res://Scripts/player_animator.gd")

## 帧画布边长**不再写死**：HD 序列帧是 512，旧像素帧是 48，必须按首张贴图实测，
## 否则 pixel_size 会差一个数量级（画布错 → 角色要么米粒要么顶天）。
var _canvas := 48.0

var _anim: AnimatedSprite3D = null
var _shadow: MeshInstance3D = null
var _ring: MeshInstance3D = null
var _cur_key: StringName = &""
var _brightness := 1.0


## 装配视觉。返回 false = 一份帧都没装载成功，调用方应回退到占位视觉。
func build(sprites_cfg: Dictionary, cfg: Dictionary) -> bool:
	var spec: Dictionary = ANIMATOR.parse_spec(sprites_cfg)
	var anims: Dictionary = spec["anims"]
	var fps_map: Dictionary = spec["fps"]

	var sf := SpriteFrames.new()
	sf.remove_animation(&"default")
	var loaded := 0
	for anim in ANIMATOR.ANIM_NAMES:
		var loop: bool = anim in ANIMATOR.LOOPING
		for dir in ANIMATOR.DIRS:
			var list: Array = []
			for p in anims[anim][dir]:
				if ResourceLoader.exists(p):
					var tex := load(p)
					if tex != null:
						list.append(tex)
			if list.is_empty():
				continue          # 该状态没帧 → set_state 会自动回退到 idle
			# 画布 = 首个装载帧的宽度（正方形画布约定）。后续帧若宽度不一致要立刻吼出来：
			# pixel_size 是全局的，48px 像素帧混进 512px HD 集会让角色放大/缩小一个数量级。
			if loaded == 0:
				_canvas = maxf(float(list[0].get_width()), 1.0)
			elif not is_equal_approx(float(list[0].get_width()), _canvas):
				push_warning("[PlayerVisual3D] 帧分辨率混用：%s 是 %dpx，画布按 %dpx 算，" +
						"该方向角色比例会错" % [String(anim), list[0].get_width(), int(_canvas)])
			var key := StringName("%s_%s" % [String(anim), String(dir)])
			sf.add_animation(key)
			sf.set_animation_speed(key, float(fps_map[anim]))
			sf.set_animation_loop(key, loop)
			for tex in list:
				sf.add_frame(key, tex)
			loaded += list.size()
	if loaded == 0:
		push_warning("[PlayerVisual3D] 没有找到任何玩家帧序列，将回退到占位视觉")
		return false

	var pixel_size := float(cfg.get("world_height", 1.6)) / _canvas   # 一整张画布的世界高度
	_brightness = float(cfg.get("brightness", 1.06))

	_anim = AnimatedSprite3D.new()
	_anim.name = "Frames"
	_anim.sprite_frames = sf
	_anim.billboard = BaseMaterial3D.BILLBOARD_ENABLED      # 永远朝向相机 = HD-2D 的关键
	# 过滤器按素材分辨率选（config player3d.filter）：
	#   nearest — 旧 48px 像素帧，放大要保持硬边；
	#   linear  — HD 帧（512px 缩到屏上 ~95px 是 5:1 缩小），NEAREST 会闪成噪点，
	#             必须 LINEAR_WITH_MIPMAPS（导入需开 mipmap，见 tools/enable_hd_mipmap.py）。
	match String(cfg.get("filter", "nearest")):
		"linear":
			_anim.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		_:
			_anim.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# HD 手绘帧有软边（半透明 anti-alias 像素），DISCARD 会把软边切成锯齿硬边 → 默认关闭；
	# 旧像素帧要保持利落轮廓可配 alpha_cut=true。
	_anim.alpha_cut = (SpriteBase3D.ALPHA_CUT_DISCARD
			if bool(cfg.get("alpha_cut", false)) else SpriteBase3D.ALPHA_CUT_DISABLED)
	_anim.shaded = bool(cfg.get("shaded", false))
	_anim.pixel_size = pixel_size
	_anim.centered = true
	# 锚点=画布底边中心，与 2D 版 SPRITE_OFFSET_Y=-24 同约定。
	# 注意：offset 的"像素→世界"换算与直觉不完全一致，anchor_offset_px 做成配置项，
	# 配合 debug_marker（在地面点放一颗品红小球）用来实测校准。默认=半画布。
	_anim.offset = Vector2(0.0, float(cfg.get("anchor_offset_px", _canvas * 0.5)))
	_anim.modulate = Color(_brightness, _brightness, _brightness, 1.0)
	_anim.play(_first_key(sf))
	add_child(_anim)

	_build_shadow(cfg)
	_build_ring(cfg)
	if bool(cfg.get("debug_marker", false)):
		_build_ground_marker()
	print("[PlayerVisual3D] 就绪：%d 张贴图，画布 %.2f 世界单位高，pixel_size=%.4f，shaded=%s"
			% [loaded, float(cfg.get("world_height", 1.6)), pixel_size, str(_anim.shaded)])
	return true


static func _first_key(sf: SpriteFrames) -> StringName:
	var names := sf.get_animation_names()
	if names.is_empty():
		return &""
	return StringName(names[0])


# ------------------------------------------------------------
# 每帧驱动
# ------------------------------------------------------------

## 切状态：anim 用 PlayerAnimator.Anim，dir 用 PlayerAnimator.DIRS 之一
func set_state(anim: int, dir: StringName) -> void:
	if _anim == null or _anim.sprite_frames == null:
		return
	_apply_tint(anim)
	var key := StringName("%s_%s" % [String(ANIMATOR.anim_name_of(anim)), String(dir)])
	if key == _cur_key:
		return
	if not _anim.sprite_frames.has_animation(key):
		key = StringName("idle_%s" % String(dir))     # 该状态没帧 → 退回待机
	if not _anim.sprite_frames.has_animation(key):
		return
	_cur_key = key
	_anim.play(key)


## 选中环显隐（与 2D 版 player.selected 同步）
func set_selected(value: bool) -> void:
	if _ring != null:
		_ring.visible = value


## 当前正在播的动画键（调试/自检用）
func current_key() -> StringName:
	return _cur_key


func _apply_tint(anim: int) -> void:
	var b := _brightness
	var c := Color(b, b, b, 1.0)
	if anim == ANIMATOR.Anim.HIT:
		c = Color(b, b * 0.52, b * 0.46, 1.0)
	elif anim == ANIMATOR.Anim.DEAD:
		c = Color(b * 0.48, b * 0.48, b * 0.48, 1.0)
	elif anim == ANIMATOR.Anim.DODGE:
		c = Color(b, b, b, 0.62)
	_anim.modulate = c


# ------------------------------------------------------------
# 部件
# ------------------------------------------------------------

## 脚下软投影：一块平铺的径向渐变 quad。公告板角色没有真实投影会"发飘"。
func _build_shadow(cfg: Dictionary) -> void:
	if not bool(cfg.get("shadow", true)):
		return
	var size := float(cfg.get("shadow_size", 0.86))
	_shadow = MeshInstance3D.new()
	_shadow.name = "Shadow"
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	_shadow.mesh = quad
	_shadow.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_shadow.position = Vector3(0.0, 0.02, 0.0)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = _blob_texture(64)
	m.albedo_color = Color(0.0, 0.0, 0.0, float(cfg.get("shadow_alpha", 0.34)))
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_shadow.material_override = m
	add_child(_shadow)


## 脚底选中环（与 2D 版 SELECT 环呼应）
func _build_ring(cfg: Dictionary) -> void:
	var radius := float(cfg.get("ring_radius", 0.34))
	_ring = MeshInstance3D.new()
	_ring.name = "SelectRing"
	var torus := TorusMesh.new()
	torus.inner_radius = radius
	torus.outer_radius = radius * 1.28
	torus.rings = 28
	torus.ring_segments = 8
	_ring.mesh = torus
	_ring.position = Vector3(0.0, 0.05, 0.0)
	var c := Color(str(cfg.get("ring_color", "#4fc3f7")))
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 0.9
	_ring.material_override = m
	_ring.visible = false
	add_child(_ring)


## 径向渐变（外软内实）的圆形贴图，给软投影用
static func _blob_texture(size: int) -> ImageTexture:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size - 1) * 0.5
	for y in range(size):
		for x in range(size):
			var d := Vector2(float(x) - c, float(y) - c).length() / c
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)     # smoothstep，边缘更软
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)


## 调试：在本节点原点（= 角色"应该"踩到的地面点）放一颗品红小球。
## 品红在游戏配色里不会出现，截图里一眼能找到，用来实测精灵脚底有没有对齐地面点。
func _build_ground_marker() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "DebugGroundMarker"
	var sph := SphereMesh.new()
	sph.radius = 0.085
	sph.height = 0.17
	mi.mesh = sph
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.0, 1.0)
	mi.material_override = m
	add_child(mi)

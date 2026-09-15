class_name PlayerAnimator
extends RefCounted
## ============================================================
## PlayerAnimator — 玩家表现层：4 向精灵方向切换 + 序列帧动画
##
## 素材来源：Assets/Art/Sprites/Player/player_{action}_{dir}_{frame}.png
##   （当前 idle 2 帧、walk 4 帧，由 tools/gen_player_frames.py 从基准帧派生）
##
## 职责：
##   1) 4 向朝向解析（down/up/left/right），由外部传入的 facing 向量决定；
##   2) 6 个动画状态（idle/walk/attack/dodge/hit/dead），由 FSM 当前状态 + 是否移动决定；
##   3) 每个 (状态, 方向) 播放一段帧序列：config 里值既可写单个路径（字符串，单帧）
##      也可写路径数组（多帧）；帧率读 sprites.fps.<状态>。idle/walk 循环播放，
##      attack/dodge/hit/dead 播完停在末帧（一次性动作）；
##   4) **只有"没配帧序列"的状态**才叠加程序化运动（呼吸/挥击前冲/冲刺拉伸/受击抖动/死亡倾倒）——
##      配了帧序列的状态以帧本身为准，避免"帧在动、代码又动"叠加成抖动。
##
## 缺帧容错链：该状态该方向无帧 → 复用同方向 idle 帧 → idle 也缺 → 保留当前贴图。
##
## 解析逻辑抽成 static parse_spec()，**3D 表现层（PlayerVisual3D）复用同一份数据**，
## 保证 2D 版与 3D 版永远播的是同一套帧、同一套帧率。
##
## 用法（player.gd）：
##   _animator = PlayerAnimator.new($Body)
##   _animator.load_from_config(Config.get_value("sprites", {}))
##   # 每物理帧：_animator.update(delta, _current_anim(), facing)
## ============================================================

enum Anim { IDLE, WALK, ATTACK, DODGE, HIT, DEAD }

const DIR_DOWN := &"down"
const DIR_UP := &"up"
const DIR_LEFT := &"left"
const DIR_RIGHT := &"right"
const DIRS := [DIR_DOWN, DIR_UP, DIR_LEFT, DIR_RIGHT]

const ANIM_NAMES := [&"idle", &"walk", &"attack", &"dodge", &"hit", &"dead"]
const LOOPING := [&"idle", &"walk"]
const DEFAULT_FPS := {
	"idle": 3.0, "walk": 10.0, "attack": 14.0, "dodge": 14.0, "hit": 16.0, "dead": 8.0,
}

const SPRITE_OFFSET_Y := -24.0   # 脚底对齐偏移（锚点=画布底边中心，见 03 规格）
const SPRITE_SCALE := 0.5        # 48×48 画布按 2 倍超采样显示
## 位移单位：48×48 是 2 倍超采样画布，源图 2px = 屏幕 1px。
## 所以帧动画/程序化位移都应取偶数像素，否则降采样后糊边、且幅度只有半像素看不出来。
const PIXEL_UNIT := 2.0

var _sprite: Sprite2D
var _frames: Dictionary = {}      # _frames[anim_name][dir] = Array[Texture2D]
var _fps: Dictionary = {}         # _fps[anim_name] = float（帧/秒）
var _frame_t: Dictionary = {}     # _frame_t[anim_name] = float（该动画已播放秒数）
var _cur_anim: StringName = &""   # 状态切换时把 _frame_t 归零，一次性动作才能从首帧播
var _time := 0.0


func _init(sprite: Sprite2D) -> void:
	_sprite = sprite


# ------------------------------------------------------------
# 数据解析（2D / 3D 共用）
# ------------------------------------------------------------

## config 的 sprites 节点 → 帧序列规格。
## 返回 { "anims": { anim_name: { dir: PackedStringArray } }, "fps": { anim_name: float } }
static func parse_spec(sprites_cfg: Dictionary) -> Dictionary:
	var fps_cfg: Dictionary = sprites_cfg.get("fps", {})
	var anims := {}
	var fps := {}
	for anim in ANIM_NAMES:
		var a: Dictionary = sprites_cfg.get(String(anim), {})
		var m := {}
		for dir in DIRS:
			m[dir] = _paths_of(a.get(String(dir), null))
		# idle 是必选：config 没配就退回历史默认路径（引擎只保证 4 向待机帧存在）
		if anim == &"idle":
			for dir in DIRS:
				if (m[dir] as PackedStringArray).is_empty():
					m[dir] = PackedStringArray([_idle_path_for(dir)])
		anims[anim] = m
		fps[anim] = float(fps_cfg.get(String(anim), DEFAULT_FPS.get(String(anim), 6.0)))
	return {"anims": anims, "fps": fps}


## config 值 → 路径数组：兼容「单个字符串」与「字符串数组」两种写法
static func _paths_of(v) -> PackedStringArray:
	var out := PackedStringArray()
	if v == null:
		return out
	var t := typeof(v)
	if t == TYPE_STRING:
		var s := String(v)
		if s != "":
			out.append(s)
	elif t == TYPE_ARRAY or t == TYPE_PACKED_STRING_ARRAY:
		for s in v:
			var one := str(s)
			if one != "":
				out.append(one)
	return out


## idle 帧的绝对兜底路径（与 03 命名规范一致）
static func _idle_path_for(dir: StringName) -> String:
	match dir:
		DIR_DOWN: return "res://Assets/Art/Sprites/Player/player_idle_down_00.png"
		DIR_UP: return "res://Assets/Art/Sprites/Player/player_idle_up_00.png"
		DIR_LEFT: return "res://Assets/Art/Sprites/Player/player_idle_left_00.png"
		DIR_RIGHT: return "res://Assets/Art/Sprites/Player/player_idle_right_00.png"
	return ""


# ------------------------------------------------------------
# 装载
# ------------------------------------------------------------

func load_from_config(sprites_cfg: Dictionary) -> void:
	_frames.clear()
	_fps.clear()
	_frame_t.clear()
	_cur_anim = &""

	var spec := parse_spec(sprites_cfg)
	var anims: Dictionary = spec["anims"]
	var fps_map: Dictionary = spec["fps"]

	for anim in ANIM_NAMES:
		var m := {}
		var src: Dictionary = anims[anim]
		for dir in DIRS:
			var list: Array = []
			for p in src[dir]:
				if ResourceLoader.exists(p):
					var tex := load(p)
					if tex != null:
						list.append(tex)
				else:
					push_warning("[PlayerAnimator] 帧缺失：" + str(p))
			m[dir] = list
		_frames[anim] = m
		_fps[anim] = float(fps_map[anim])
		_frame_t[anim] = 0.0

	# 注意：这里**不要**把 idle 帧回填进"没配帧"的状态。
	# 一旦回填，"本状态是否配了帧序列"这条信息就丢了，update() 会把 attack/hit 之类
	# 误判成多帧状态，从而丢掉挥击前冲 / 受击抖动 / 死亡倾倒（踩过）。
	# 贴图回退统一在 update() 里做，_frames 只存"真正配置了的帧"。
	print("[PlayerAnimator] 帧序列就绪：%s" % _summary())


func _summary() -> String:
	var parts := PackedStringArray()
	for anim in ANIM_NAMES:
		var m: Dictionary = _frames.get(anim, {})
		var n := 0
		for dir in DIRS:
			var list: Array = m.get(dir, [])
			n = maxi(n, list.size())
		if n > 1:
			parts.append("%s=%d帧/%.0ffps" % [String(anim), n, float(_fps.get(anim, 0.0))])
		else:
			parts.append("%s=程序化" % String(anim))
	return " ".join(parts)


# ------------------------------------------------------------
# 每帧更新
# ------------------------------------------------------------

## 每物理帧调用：推进帧计时，按当前动画状态 + 朝向刷新贴图与形变。
##
## 关键语义：**只有"显式配了帧序列"的状态才走帧动画**；没配的状态（如 attack/attack/
## dodge/hit/dead）只从 idle 借一张贴图、仍走程序化运动。
## 不能按"回退后数组的帧数"来判断 —— idle 一旦有了 2 帧，所有回退状态都会被动
## 变成"多帧状态"，从而丢掉挥击前冲/受击抖动/死亡倾倒这些反馈（这个坑踩过）。
func update(delta: float, anim: int, facing: Vector2) -> void:
	_time += delta
	var anim_name := anim_name_of(anim)
	var dir := dir_from_facing(facing)
	var own_per_dir: Dictionary = _frames.get(anim_name, {})
	var own: Array = own_per_dir.get(dir, [])          # 该状态自己配的帧（可为空）
	var animated := own.size() > 1
	var frames: Array = own if not own.is_empty() else _frames.get(&"idle", {}).get(dir, [])
	if frames.is_empty():
		return

	var idx := 0
	if animated:
		if anim_name != _cur_anim:
			_cur_anim = anim_name
			_frame_t[anim_name] = 0.0
		_frame_t[anim_name] = float(_frame_t.get(anim_name, 0.0)) + delta
		var sec_per_frame := 1.0 / maxf(float(_fps.get(anim_name, 6.0)), 0.01)
		var step := int(_frame_t[anim_name] / sec_per_frame)
		if anim_name in LOOPING:
			idx = step % frames.size()
		else:
			idx = mini(step, frames.size() - 1)     # 一次性动作：停在末帧
	else:
		_cur_anim = anim_name
		idx = 0                                    # 无帧序列：固定用第一张（通常借 idle 帧）

	var tex: Texture2D = frames[idx]
	if tex != null and _sprite.texture != tex:
		_sprite.texture = tex

	if animated:
		_apply_frame_pose(anim)     # 多帧：位移交给帧序列，这里只对齐锚点 + 状态染色
	else:
		_apply_motion(anim, facing)  # 无帧序列：程序化运动制造动作


# ------------------------------------------------------------
# 朝向 / 状态名
# ------------------------------------------------------------

## facing 向量 → 4 向：水平分量更大取左右，否则取上下（与移动/瞄准语义一致）
static func dir_from_facing(f: Vector2) -> StringName:
	if absf(f.x) > absf(f.y):
		return DIR_RIGHT if f.x >= 0.0 else DIR_LEFT
	return DIR_DOWN if f.y >= 0.0 else DIR_UP


static func anim_name_of(anim: int) -> StringName:
	match anim:
		Anim.WALK: return &"walk"
		Anim.ATTACK: return &"attack"
		Anim.DODGE: return &"dodge"
		Anim.HIT: return &"hit"
		Anim.DEAD: return &"dead"
		_: return &"idle"


# ------------------------------------------------------------
# 程序化运动（仅单帧状态使用）
# ------------------------------------------------------------

## 多帧状态：位移/缩放交给帧序列本身，这里只做锚点对齐与状态染色
func _apply_frame_pose(anim: int) -> void:
	_sprite.offset = Vector2(0.0, SPRITE_OFFSET_Y)
	_sprite.rotation = 0.0
	_sprite.scale = Vector2(SPRITE_SCALE, SPRITE_SCALE)
	_sprite.modulate = tint_for(anim)


## 状态染色（受击泛红 / 死亡变暗 / 冲刺半透明）
static func tint_for(anim: int) -> Color:
	if anim == Anim.HIT:
		return Color(1.0, 0.55, 0.5)
	if anim == Anim.DEAD:
		return Color(0.55, 0.55, 0.55)
	if anim == Anim.DODGE:
		return Color(1, 1, 1, 0.65)
	return Color(1, 1, 1)


## 程序化运动（单帧状态的"零素材动画"）：对基础贴图做位移/旋转/缩放/染色
func _apply_motion(anim: int, facing: Vector2) -> void:
	var off := Vector2(0.0, SPRITE_OFFSET_Y)
	var rot := 0.0
	var sc := Vector2(SPRITE_SCALE, SPRITE_SCALE)
	var mod := Color(1, 1, 1)
	var t := _time

	match anim:
		Anim.IDLE:
			# 极轻的呼吸起伏
			off.y += sin(t * 2.2) * PIXEL_UNIT * 0.5
		Anim.WALK:
			# 走路：上下起伏 + 轻轻左右摆
			var w := t * 14.0
			off.y += sin(w) * PIXEL_UNIT
			rot = sin(w) * 0.05
		Anim.ATTACK:
			# 挥击：朝 facing 前冲 + 摆臂
			off += facing * PIXEL_UNIT * 1.5
			rot = sin(t * 26.0) * 0.10
		Anim.DODGE:
			# 冲刺：沿朝向拉伸 + 半透明（配合无敌帧）
			if absf(facing.x) > absf(facing.y):
				sc = Vector2(SPRITE_SCALE * 1.3, SPRITE_SCALE * 0.85)
			else:
				sc = Vector2(SPRITE_SCALE * 0.88, SPRITE_SCALE * 1.2)
			mod = Color(1, 1, 1, 0.65)
		Anim.HIT:
			# 受击：高频抖动 + 泛红
			off.x += sin(t * 55.0) * PIXEL_UNIT * 1.0
			mod = Color(1.0, 0.55, 0.5)
		Anim.DEAD:
			# 死亡：倾倒 + 变暗
			rot = 0.4
			off.y += PIXEL_UNIT * 2.5
			mod = Color(0.55, 0.55, 0.55)

	_sprite.offset = off
	_sprite.rotation = rot
	_sprite.scale = sc
	_sprite.modulate = mod

class_name PlayerAnimator
extends RefCounted
## ============================================================
## PlayerAnimator — 玩家表现层：4 向精灵方向切换 + 序列帧动画
##
## 素材来源：Assets/Art/Sprites/Player/player_{action}_{dir}_{frame}.png
##   （当前 idle 2 帧、walk 4 帧，由 tools/gen_player_frames.py 从基准帧派生）
##
## 职责：
##   1) 8 向朝向解析（down / up / left / right + 四个斜向），由外部传入的 facing 向量决定；
##      素材只有 4 向甚至单向时，斜向会在 parse_spec 里回退到主方向（DIR_FALLBACK），
##      所以调用方不必关心素材有几个方向。
##   2) 6 个动画状态（idle/walk/attack/dodge/hit/dead），由 FSM 当前状态 + 是否移动决定；
##   3) 每个 (状态, 方向) 播放一段帧序列：config 里值既可写单个路径（字符串，单帧）
##      也可写路径数组（多帧）；帧率读 sprites.fps.<状态>。idle/walk 循环播放，
##      attack/dodge/hit/dead 播完停在末帧（一次性动作）；
##   4) **只有"没配帧序列"的状态**才叠加程序化运动（呼吸/挥击前冲/冲刺拉伸/受击抖动/死亡倾倒）——
##      配了帧序列的状态以帧本身为准，避免"帧在动、代码又动"叠加成抖动。
##   5) **水平镜像**：素材只画了一个侧向时（敌人 21 个兵种全是扁平单侧帧），
##      靠 Sprite2D.flip_h 补出另一半方向。默认关闭（FLIP_NONE），只在 view_cfg 显式
##      配 sprite_flip_h 时才生效，所以玩家的 8 向枪兵绝不会被二次镜像。见 FLIP_* 。
##
## 缺帧容错链：该状态该方向无帧 → 复用同方向 idle 帧 → idle 也缺 → 保留当前贴图。
## （方向层面还有一条更早的回退：斜向 → 主方向，见 DIR_FALLBACK / parse_spec。）
##
## 解析逻辑抽成 static parse_spec()，**3D 表现层（PlayerVisual3D）复用同一份数据**，
## 保证 2D 版与 3D 版永远播的是同一套帧、同一套帧率。
##
## 用法（player.gd）：
##   _animator = PlayerAnimator.new($Body)
##   _animator.load_from_config(Config.get_value("sprites", {}))
##   # 每物理帧：_animator.update(delta, _current_anim(), facing)
## ============================================================

## GRAZE 追加在末尾：中立生物（羊）吃草用的循环动作。
## **不要插在中间**——插队会让已有的 int 映射整体错位。
enum Anim { IDLE, WALK, ATTACK, DODGE, HIT, DEAD, GRAZE }

const DIR_DOWN := &"down"
const DIR_UP := &"up"
const DIR_LEFT := &"left"
const DIR_RIGHT := &"right"
## 斜向。**一律追加在 4 向之后，不要插队** —— DIRS 的顺序是 summary() 与
## PlayerVisual3D 预载遍历的依据，插队会让既有顺序整体错位。
## 旧素材集只写了 4 向（`sprites` / `sprites_hd` / 敌人 / 羊），斜向靠 DIR_FALLBACK 兜住；
## 只有 `sprites_lancer` 是真正的 8 向（Lancer 是免费包唯一画出多方向的兵种）。
const DIR_DOWN_RIGHT := &"down_right"
const DIR_DOWN_LEFT := &"down_left"
const DIR_UP_RIGHT := &"up_right"
const DIR_UP_LEFT := &"up_left"
const DIRS := [
	DIR_DOWN, DIR_UP, DIR_LEFT, DIR_RIGHT,
	DIR_DOWN_RIGHT, DIR_DOWN_LEFT, DIR_UP_RIGHT, DIR_UP_LEFT,
]

## 斜向 → 主方向。查不到斜向帧时回退到这里。
## 特意选**水平**主方向而不是垂直：俯视游戏里斜向走动用侧面轮廓更自然
## （素材的 up/down 多为正/背面，斜走时用它会显得没在斜着走）。
const DIR_FALLBACK := {
	DIR_DOWN_RIGHT: DIR_RIGHT,
	DIR_DOWN_LEFT: DIR_LEFT,
	DIR_UP_RIGHT: DIR_RIGHT,
	DIR_UP_LEFT: DIR_LEFT,
}

const ANIM_NAMES := [&"idle", &"walk", &"attack", &"dodge", &"hit", &"dead", &"graze"]
const LOOPING := [&"idle", &"walk", &"graze"]
const DEFAULT_FPS := {
	"idle": 3.0, "walk": 10.0, "attack": 14.0, "dodge": 14.0, "hit": 16.0, "dead": 8.0,
	"graze": 5.0,
}

## 以下三个是可被 config 覆盖的**默认值**（旧 48×48 程序化派生帧的规格）。
## Tiny Swords 官方单位是 192×192 画布、角色脚底在 y≈137，所以 config 里给了
## sprite_scale / sprite_offset_y / sprite_pixel_unit。真正生效的值见 load_from_config()。
const DEFAULT_SPRITE_OFFSET_Y := -24.0
const DEFAULT_SPRITE_SCALE := 0.5
const DEFAULT_PIXEL_UNIT := 2.0

## 水平镜像的三档。写在 config/view_cfg 的 `sprite_flip_h`，值可以是字符串或 int。
##   none  = 永不镜像（玩家的 8 向素材、静态物件如 ep_cave 洞口）
##   right = 素材原画朝右 → 朝左看时镜像（敌人绝大多数兵种）
##   left  = 素材原画朝左 → 朝右看时镜像（ep_harpoon_shark / ep_paddle_shark 头在左边，
##           按 right 的规则翻正好翻反，所以必须有这一档）
const FLIP_NONE := 0
const FLIP_RIGHT := 1
const FLIP_LEFT := 2
## 朝向的水平分量小于这个值 = 正上/正下走，此时**保持上一次镜像**不改。
## 没有死区的话，竖着走时 facing.x 在 0 附近抖，精灵会一帧朝左一帧朝右地抽风。
const FLIP_DEADZONE_X := 0.25

var _sprite: Sprite2D
var _offset_y := DEFAULT_SPRITE_OFFSET_Y   # 脚底对齐偏移（锚点=画布底边中心）
var _scale := DEFAULT_SPRITE_SCALE         # 画布缩放
var _pixel_unit := DEFAULT_PIXEL_UNIT      # 程序化位移的"1 像素"等于多少屏幕单位
var _flip_mode := FLIP_NONE                # 见 FLIP_* ；默认关，老素材集行为不变
var _flip_deadzone := FLIP_DEADZONE_X
## 外部叠加的整体缩放倍数（受击挤压）。本类每帧都会把 _scale * _scale_mul 写进
## _sprite.scale，所以外部只改这个倍数、不要去直接改 _sprite.scale —— 会被这里盖掉。
var _scale_mul := Vector2.ONE
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
		var raw = sprites_cfg.get(String(anim), null)
		var m := {}
		if raw is Dictionary:
			# 写法 A：按方向分组 { "down": [...] , "up": [...] , "up_right": [...] }
			#   · 只写「真有专属帧」的方向，其余留空；
			#   · 斜向缺帧 → 自动回退到 DIR_FALLBACK 指定的主方向；
			#   · 可选 "default" 键给所有方向兜底（不想把同一批帧写 8 遍时用它）。
			var a: Dictionary = raw
			var shared := _paths_of(a.get("default", null))
			for dir in DIRS:
				var paths := _paths_of(a.get(String(dir), null))
				if paths.is_empty():
					var prim := primary_dir(dir)
					if prim != dir:
						paths = _paths_of(a.get(String(prim), null))
				if paths.is_empty():
					paths = shared
				m[dir] = paths
		else:
			# 写法 B：扁平数组/单字符串，**所有**方向共用同一套帧。
			# Tiny Swords 官方多数单位是正面单向序列帧（Warrior / Archer / Monk / Pawn / 羊），
			# 八个方向共用同一组帧最自然；硬做左右翻转会与其余美术风格冲突。
			var shared := _paths_of(raw)
			for dir in DIRS:
				m[dir] = shared
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


## 斜向归一化成主方向；本身就是主方向时原样返回。
static func primary_dir(dir: StringName) -> StringName:
	var v: StringName = DIR_FALLBACK.get(dir, dir)
	return v


## `sprite_flip_h` 的取值 → FLIP_*。config 写字符串（"right"/"left"/"none"），
## 探针和内部代码也可以直接传 int。认不出的值一律当 none：**宁可不动画**，
## 也不要在装载路径里 push_warning —— 一局 100 个敌人会把日志刷爆。
static func flip_mode_of(v) -> int:
	if v is int or v is float:
		var n := int(v)
		if n >= FLIP_NONE and n <= FLIP_LEFT:
			return n
		return FLIP_NONE
	var s := str(v).strip_edges().to_lower()
	if s == "right":
		return FLIP_RIGHT
	if s == "left":
		return FLIP_LEFT
	return FLIP_NONE


## 纯函数版镜像判定（探针直接测它，不用造一个真 Sprite2D）。
## `held` = 上一次的镜像状态：死区内（正上/正下走、或还没朝过任何方向）原样保持。
static func flip_for(mode: int, facing: Vector2, held: bool, deadzone: float) -> bool:
	if mode == FLIP_NONE:
		return false
	if facing.length_squared() < 0.000001 or absf(facing.x) < deadzone:
		return held
	if mode == FLIP_RIGHT:
		return facing.x < 0.0
	if mode == FLIP_LEFT:
		return facing.x > 0.0
	return held


## idle 帧的绝对兜底路径（与 03 命名规范一致）。
## 只保证 4 个主方向的文件存在，斜向先归一化再取。
static func _idle_path_for(dir: StringName) -> String:
	match primary_dir(dir):
		DIR_DOWN: return "res://Assets/Art/Sprites/Player/player_idle_down_00.png"
		DIR_UP: return "res://Assets/Art/Sprites/Player/player_idle_up_00.png"
		DIR_LEFT: return "res://Assets/Art/Sprites/Player/player_idle_left_00.png"
		DIR_RIGHT: return "res://Assets/Art/Sprites/Player/player_idle_right_00.png"
	return ""


# ------------------------------------------------------------
# 装载
# ------------------------------------------------------------

## view_cfg（可省）来自 config 的 player 节点，用于覆盖画布缩放 / 脚底偏移 / 位移单位：
##   { "sprite_scale": 1.0, "sprite_offset_y": -41.0, "sprite_pixel_unit": 6.0 }
## 不传就沿用旧 48×48 程序化帧的默认值，老工程不会因为这次改动而变样。
##
## log_label：装载完成后打印一行摘要，便于调试；传空字符串则不打印。
## 敌人/动物是同类复数实例（一局 100 个），必须传空，否则日志被刷爆。
func load_from_config(sprites_cfg: Dictionary, view_cfg: Dictionary = {},
		log_label: String = "PlayerAnimator") -> void:
	_frames.clear()
	_fps.clear()
	_frame_t.clear()
	_cur_anim = &""

	_scale = float(view_cfg.get("sprite_scale", DEFAULT_SPRITE_SCALE))
	_offset_y = float(view_cfg.get("sprite_offset_y", DEFAULT_SPRITE_OFFSET_Y))
	_pixel_unit = float(view_cfg.get("sprite_pixel_unit", DEFAULT_PIXEL_UNIT))
	_flip_mode = flip_mode_of(view_cfg.get("sprite_flip_h", "none"))
	_flip_deadzone = float(view_cfg.get("sprite_flip_deadzone", FLIP_DEADZONE_X))
	_scale_mul = Vector2.ONE

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
	if log_label != "":
		print("[%s] 帧序列就绪：%s" % [log_label, _summary()])


## 供外部（如 EnemySystem）在静默装载后统一打印一行摘要
func summary() -> String:
	return _summary()


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
	# 镜像放在最前面，且在下面 frames.is_empty() 提前 return **之前**：
	# 只配了 idle 帧的兵种（如无 walk 的 ep_cave）也要能跟着转向。
	# FLIP_NONE 时 flip_for 恒返回 false，玩家那套真 8 向素材永远不会被二次镜像。
	_sprite.flip_h = flip_for(_flip_mode, facing, _sprite.flip_h, _flip_deadzone)
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

## facing 向量 → 8 向。
##
## 用**角度切扇区**（45° 一格），而不是旧的「比绝对值大小」——
## 后者只能表达 4 向，45° 的斜向会被吞掉退化成上下。y 轴向下为正，
## 故 angle()：0=右、PI/2=下、-PI/2=上、±PI=左。
##
## 调用方不止玩家：敌人 / 羊 / 3D 表现层共用本函数，而它们的帧集可能只有 4 向
## 甚至单向。斜向取不到帧时由 parse_spec 的 DIR_FALLBACK 回退到主方向，
## 所以这里可以放心返回斜向。
static func dir_from_facing(f: Vector2) -> StringName:
	if f.length_squared() < 0.000001:
		return DIR_DOWN          # 零向量（还没朝过任何方向）：与旧默认一致
	var oct := int(round(f.angle() / (PI / 4.0)))     # -4..4，正好覆盖 8 个扇区
	match oct:
		-4, 4: return DIR_LEFT
		-3: return DIR_UP_LEFT
		-2: return DIR_UP
		-1: return DIR_UP_RIGHT
		1: return DIR_DOWN_RIGHT
		2: return DIR_DOWN
		3: return DIR_DOWN_LEFT
		_: return DIR_RIGHT


static func anim_name_of(anim: int) -> StringName:
	match anim:
		Anim.WALK: return &"walk"
		Anim.ATTACK: return &"attack"
		Anim.DODGE: return &"dodge"
		Anim.HIT: return &"hit"
		Anim.DEAD: return &"dead"
		Anim.GRAZE: return &"graze"
		_: return &"idle"


# ------------------------------------------------------------
# 程序化运动（仅单帧状态使用）
# ------------------------------------------------------------

## 多帧状态：位移/缩放交给帧序列本身，这里只做锚点对齐与状态染色
func _apply_frame_pose(anim: int) -> void:
	_sprite.offset = Vector2(0.0, _offset_y)
	_sprite.rotation = 0.0
	_sprite.scale = Vector2(_scale * _scale_mul.x, _scale * _scale_mul.y)
	_sprite.modulate = tint_for(anim)


## 外部叠加缩放倍数（受击挤压走这条通道）。**不要**去直接 tween _sprite.scale ——
## 本类每个物理帧都会按 _scale * _scale_mul 重写它，直接写会被盖掉，
## 而 scale≠1 的兵种（troll 0.5 / minotaur 0.6）因此根本看不到挤压。
func set_scale_mul(v: Vector2) -> void:
	_scale_mul = v


func get_scale_mul() -> Vector2:
	return _scale_mul


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
	var off := Vector2(0.0, _offset_y)
	var rot := 0.0
	var sc := Vector2(_scale * _scale_mul.x, _scale * _scale_mul.y)
	var mod := Color(1, 1, 1)
	var t := _time

	match anim:
		Anim.IDLE:
			# 极轻的呼吸起伏
			off.y += sin(t * 2.2) * _pixel_unit * 0.5
		Anim.WALK:
			# 走路：上下起伏 + 轻轻左右摆
			var w := t * 14.0
			off.y += sin(w) * _pixel_unit
			rot = sin(w) * 0.05
		Anim.ATTACK:
			# 挥击：朝 facing 前冲 + 摆臂
			off += facing * _pixel_unit * 1.5
			rot = sin(t * 26.0) * 0.10
		Anim.DODGE:
			# 冲刺：沿朝向拉伸 + 半透明（配合无敌帧）
			if absf(facing.x) > absf(facing.y):
				sc = Vector2(_scale * 1.3, _scale * 0.85)
			else:
				sc = Vector2(_scale * 0.88, _scale * 1.2)
			mod = Color(1, 1, 1, 0.65)
		Anim.HIT:
			# 受击：高频抖动 + 泛红
			off.x += sin(t * 55.0) * _pixel_unit * 1.0
			mod = Color(1.0, 0.55, 0.5)
		Anim.DEAD:
			# 死亡：倾倒 + 变暗（只在这零点几秒的淡出里可见，之后节点移除）
			rot = 0.4
			off.y += _pixel_unit * 2.5
			mod = Color(0.55, 0.55, 0.55)

	_sprite.offset = off
	_sprite.rotation = rot
	_sprite.scale = sc
	_sprite.modulate = mod

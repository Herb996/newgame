class_name PlayerAnimator
extends RefCounted
## ============================================================
## PlayerAnimator — 玩家表现层：4 向精灵方向切换 + 动画状态机
##
## 设计依据：Assets/Art 当前只有 4 向「待机基准帧」，动作用代码驱动的程序化
## 动画（见 03_ART_STYLE_GUIDE.md）。本类把原来散在 player.gd _update_sprite
## 里的逻辑抽成正式的"动画状态机"，职责单一、数据驱动、易扩展。
##
## 职责：
##   1) 4 向朝向解析（down/up/left/right），由外部传入的 facing 向量决定；
##   2) 6 个动画状态（idle/walk/attack/dodge/hit/dead），由 FSM 当前状态 + 是否移动决定；
##   3) 每个 (状态, 方向) 选贴图——贴图路径读 config 的 sprites 节点，缺省回退到 idle 帧，
##      再缺则保留当前贴图（保证任何状态都有图可显示）；
##   4) 每个状态一套程序化运动（呼吸 / 走路起伏 / 挥击前冲 / 冲刺拉伸 / 受击抖动 / 死亡倾倒），
##      即"动画"。后续补真动画帧时，只需往 config 的 sprites 里给对应状态按方向加帧路径，
##      animator 自动使用对应贴图（命名规范见 03：player_{action}_{dir}_{frame}.png）。
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

const SPRITE_OFFSET_Y := -24.0   # 脚底对齐偏移（锚点=脚底中心，见 03 规格）
const SPRITE_SCALE := 0.5        # 48×48 画布按 2 倍超采样显示

var _sprite: Sprite2D
var _textures: Dictionary = {}   # _textures[anim_name][dir] = Texture2D
var _time := 0.0


func _init(sprite: Sprite2D) -> void:
	_sprite = sprite


## 从 config 的 sprites 节点装载贴图映射。
## 结构：{ "idle": {"down": "res://...", ...}, "walk": {...}, ... }
## idle 为必选（引擎只保证 4 向待机帧存在）；其余状态缺图时直接复用同方向 idle 帧对象，
## 通过程序化运动制造差异（呼吸/走路/挥击/冲刺/受击/死亡），即"零素材动画"。
func load_from_config(sprites_cfg: Dictionary) -> void:
	_textures.clear()
	var idle: Dictionary = {}
	var idle_cfg: Dictionary = sprites_cfg.get("idle", {})
	for dir in [DIR_DOWN, DIR_UP, DIR_LEFT, DIR_RIGHT]:
		var p: String = idle_cfg.get(str(dir), _idle_path_for(dir))
		if ResourceLoader.exists(p):
			idle[dir] = load(p)
		else:
			push_warning("[PlayerAnimator] idle 贴图缺失：" + p)
	_textures[&"idle"] = idle

	for anim in [&"walk", &"attack", &"dodge", &"hit", &"dead"]:
		var m := {}
		var a: Dictionary = sprites_cfg.get(str(anim), {})
		for dir in [DIR_DOWN, DIR_UP, DIR_LEFT, DIR_RIGHT]:
			var p: String = a.get(str(dir), "")
			if p != "" and ResourceLoader.exists(p):
				m[dir] = load(p)
			else:
				m[dir] = idle.get(dir, null)   # 没单独配 → 复用 idle 帧对象
		_textures[anim] = m


## idle 帧的绝对兜底路径（与 player.gd 历史 SPRITE_IDLE_PATH 一致，见 03 命名规范）
func _idle_path_for(dir: StringName) -> String:
	match dir:
		DIR_DOWN: return "res://Assets/Art/Sprites/Player/player_idle_down_00.png"
		DIR_UP: return "res://Assets/Art/Sprites/Player/player_idle_up_00.png"
		DIR_LEFT: return "res://Assets/Art/Sprites/Player/player_idle_left_00.png"
		DIR_RIGHT: return "res://Assets/Art/Sprites/Player/player_idle_right_00.png"
	return ""


## 每物理帧调用：推进动画计时，按当前动画状态 + 朝向刷新贴图与程序化形变
func update(delta: float, anim: int, facing: Vector2) -> void:
	_time += delta
	var dir := _dir_from_facing(facing)
	var tex := _texture_for(anim, dir)
	if tex != null and _sprite.texture != tex:
		_sprite.texture = tex
	_apply_motion(anim, facing)


## facing 向量 → 4 向：水平分量更大取左右，否则取上下（与移动/瞄准语义一致）
func _dir_from_facing(f: Vector2) -> StringName:
	if absf(f.x) > absf(f.y):
		return DIR_RIGHT if f.x >= 0.0 else DIR_LEFT
	return DIR_DOWN if f.y >= 0.0 else DIR_UP


func _texture_for(anim: int, dir: StringName) -> Texture2D:
	var anim_name := _anim_name(anim)
	var t: Texture2D = _textures.get(anim_name, {}).get(dir, null)
	if t == null:
		t = _textures.get(&"idle", {}).get(dir, null)
	return t


func _anim_name(anim: int) -> StringName:
	match anim:
		Anim.WALK: return &"walk"
		Anim.ATTACK: return &"attack"
		Anim.DODGE: return &"dodge"
		Anim.HIT: return &"hit"
		Anim.DEAD: return &"dead"
		_: return &"idle"


## 程序化运动（即动画）：按动画状态对基础贴图做位移/旋转/缩放/染色
func _apply_motion(anim: int, facing: Vector2) -> void:
	var off := Vector2(0.0, SPRITE_OFFSET_Y)
	var rot := 0.0
	var sc := Vector2(SPRITE_SCALE, SPRITE_SCALE)
	var mod := Color(1, 1, 1)
	var t := _time

	match anim:
		Anim.IDLE:
			# 极轻的呼吸起伏
			off.y += sin(t * 2.2) * 0.5
		Anim.WALK:
			# 走路：上下起伏 + 轻微左右摆动
			var w := t * 14.0
			off.y += sin(w) * 1.5
			rot = sin(w) * 0.05
		Anim.ATTACK:
			# 挥击：朝 facing 前冲 + 摆臂
			off += facing * 2.5
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
			off.x += sin(t * 55.0) * 2.0
			mod = Color(1.0, 0.55, 0.5)
		Anim.DEAD:
			# 死亡：倾倒 + 变暗
			rot = 0.4
			off.y += 5.0
			mod = Color(0.55, 0.55, 0.55)

	_sprite.offset = off
	_sprite.rotation = rot
	_sprite.scale = sc
	_sprite.modulate = mod

extends Node
## ============================================================
## probe_enemy_facing — 敌人朝向 / 水平镜像 / 受击挤压通道（headless 可跑）
##
## 起因（2026-09-19 用户）：「游戏里面的敌人怎么就一个方向，给左边也加一个方向」。
## 根因两层：
##   ① enemy.gd 把朝向写死成 Vector2(0,1)（旧注释：官方单位是正面单朝向帧，四向共用）；
##   ② 更底层 —— 21 个兵种的 idle/walk/attack 在 config 里全是**扁平数组**，
##      PlayerAnimator.parse_spec 的"写法 B"会让 8 个方向共用同一组帧。
##      所以光把朝向传进去也不会变，只能靠 Sprite2D.flip_h 水平镜像补出"朝左"。
## 逐兵种看首帧（Dev/shot_enemy_facing.gd 出接触表）发现**原画侧向并不统一**：
## 绝大多数头朝右，但 ep_harpoon_shark / ep_paddle_shark 头朝左 —— 一刀切的
## `if dir.x < 0: flip` 会把这两只翻反（追人时朝右倒着跑）。所以有 ART_FACING 表。
##
## 本探针逐段守的不变量：
##   A) flip_for 纯函数：三档模式 × 8 向 × 死区"保持上一次"
##   B) flip_mode_of 取值兼容：字符串/int/大小写/未知值一律安全退回 none
##   C) resolve_flip_mode：兵种 art_facing 键 > ART_FACING 表 > 默认 right；
##      以及 enemy.flip_h_with_facing=false 时全部退回不镜像
##   D) 端到端：真敌人追左边的玩家 → flip_h=true；玩家挪到右边 → 翻回 false；
##      鲨鱼（原画朝左）追左边的玩家 → flip_h 必须是 false
##   E) 玩家那套真 8 向素材（sprites_lancer）绝不能被二次镜像
##   F) 受击挤压走 PlayerAnimator.scale_mul：直接写 _body.scale 会被动画器每帧盖掉
##      （这条同时把"scale≠1 的兵种看不到挤压"的老 bug 钉住）
##   G) 死亡后 _update_anim 不再跑 → 镜像冻结在最后一帧朝向，不会临死翻回朝右
##
## 跑法：python tools/run_probe.py _probe_enemy_facing.log res://Dev/probe_enemy_facing.tscn
## 注：不加载 Main.tscn，自搭开阔网格 + 独立 EnemySystem（与 enemy_attack 探针同一套搭台）。
## ============================================================

const OUT := "user://_probe_enemy_facing.txt"
const ENEMY_SYS := preload("res://Scripts/enemy_system.gd")
const ENEMY_SCENE := preload("res://Scenes/Enemy.tscn")
const TILE := 64
const FPS := 60.0
## 跨脚本 const 引用（PlayerAnimator.FLIP_DEADZONE_X）在 GDScript 里有初始化顺序风险，
## 所以放成运行时 var。
var _dz: float = PlayerAnimator.FLIP_DEADZONE_X

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _walls: Array = []


## 假玩家：敌人靠"附近有玩家"决定自己不休眠，位置决定它往哪追。
class FakePlayer extends Area2D:
	func take_damage(_amount: int, _from: Vector2) -> bool:
		return true


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


## FLIP_* 数字 → 可读串（断言文案用）
func _flip_name(n: int) -> String:
	if n == PlayerAnimator.FLIP_RIGHT:
		return "RIGHT"
	if n == PlayerAnimator.FLIP_LEFT:
		return "LEFT"
	return "NONE"


func _phys(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame


# ------------------------------------------------------------
# 搭台
# ------------------------------------------------------------

func _open_walls(size: int) -> Array:
	var w: Array = []
	for _y in range(size):
		var row: Array = []
		for _x in range(size):
			row.append(false)
		w.append(row)
	return w


## 兵种配置的深拷贝（改它不污染 Config）
func _cfg(id: String) -> Dictionary:
	for t in Config.get_value("enemy_types.types", []):
		if t is Dictionary and str((t as Dictionary).get("id", "")) == id:
			return (t as Dictionary).duplicate(true)
	return {}


func _make_system(world: Node2D):
	var sys = ENEMY_SYS.new()
	sys.name = "Sys"
	add_child(sys)
	sys._root = world
	sys._walls = _walls
	sys._tile_size = TILE
	sys._astar = MapGenerator.build_astar(_walls, TILE)
	return sys


func _spawn(world: Node2D, pos: Vector2, type_cfg: Dictionary, sys):
	var e = ENEMY_SCENE.instantiate()
	e.position = pos
	world.add_child(e)
	e.setup(_walls, TILE, sys._astar, type_cfg, {}, sys)
	return e


func _add_player(world: Node2D) -> FakePlayer:
	var fp := FakePlayer.new()
	world.add_child(fp)
	fp.add_to_group("player")
	return fp


func _ready() -> void:
	_walls = _open_walls(48)
	NoiseSystem.setup([], TILE)
	NoiseSystem.reset()

	await _a_pure_mapping()
	await _b_mode_coercion()
	await _c_per_type_mode()
	await _d_live_movement()
	await _e_player_never_flipped()
	await _f_squash_channel()
	await _g_death_freezes()

	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[EnemyFacingProbe] 通过 %d / %d" % [_n - _fails.size(), _n])
	Config.clear_overrides()
	get_tree().quit(0 if _fails.is_empty() else 1)


# ------------------------------------------------------------
# A) 纯映射表
# ------------------------------------------------------------

func _a_pure_mapping() -> void:
	_say("--- A 段：flip_for(模式, 朝向, 上一次, 死区) ---")
	var R := PlayerAnimator.FLIP_RIGHT
	var L := PlayerAnimator.FLIP_LEFT
	var N := PlayerAnimator.FLIP_NONE
	# 素材朝右：只有水平分量明确朝左才翻
	_check(PlayerAnimator.flip_for(R, Vector2.LEFT, false, _dz) == true, "right + 朝左 → 镜像")
	_check(PlayerAnimator.flip_for(R, Vector2.RIGHT, true, _dz) == false, "right + 朝右 → 不镜像")
	_check(PlayerAnimator.flip_for(R, Vector2(-1, 1).normalized(), false, _dz) == true,
			"right + 左下（斜向取水平分量）→ 镜像")
	_check(PlayerAnimator.flip_for(R, Vector2(1, -1).normalized(), true, _dz) == false,
			"right + 右上 → 取消镜像（上下不做处理，只看水平分量）")
	# 素材朝左（两只鲨鱼）：规则整个反过来
	_check(PlayerAnimator.flip_for(L, Vector2.LEFT, true, _dz) == false, "left + 朝左 → 不镜像")
	_check(PlayerAnimator.flip_for(L, Vector2.RIGHT, false, _dz) == true, "left + 朝右 → 镜像")
	# 不镜像档：恒 false，且**不吃**上一次的值（玩家的 8 向素材靠这条保底）
	_check(PlayerAnimator.flip_for(N, Vector2.LEFT, true, _dz) == false, "none + 朝左 → 恒不镜像")
	_check(PlayerAnimator.flip_for(N, Vector2.ZERO, true, _dz) == false, "none + 零向量 → 恒不镜像")
	# 死区：正上/正下走时保持上一次，避免 facing.x 在 0 附近抖成抽风
	_check(PlayerAnimator.flip_for(R, Vector2.UP, true, _dz) == true,
			"right + 正上 → 保持上一次(镜像)")
	_check(PlayerAnimator.flip_for(R, Vector2.UP, false, _dz) == false,
			"right + 正上 → 保持上一次(不镜像)")
	_check(PlayerAnimator.flip_for(R, Vector2.DOWN, true, _dz) == true,
			"right + 正下 → 保持上一次")
	_check(PlayerAnimator.flip_for(R, Vector2.ZERO, true, _dz) == true,
			"right + 零向量 → 保持上一次")
	# 死区边界：|x| 等于阈值算"明确朝左"，不到阈值算"保持"。
	# 注意**不要先 normalized()** —— 归一化会把 |x| 缩到阈值以下，测的就不是同一条线了。
	_check(PlayerAnimator.flip_for(R, Vector2(-_dz, -1.0), false, _dz) == true,
			"|x|=%.2f 达阈值 → 翻" % _dz)
	_check(PlayerAnimator.flip_for(R, Vector2(-_dz * 0.5, -1.0), false, _dz) == false,
			"|x|=%.3f 不到阈值 → 保持" % (_dz * 0.5))


# ------------------------------------------------------------
# B) 取值兼容
# ------------------------------------------------------------

func _b_mode_coercion() -> void:
	_say("--- B 段：flip_mode_of 取值兼容 ---")
	_check(PlayerAnimator.flip_mode_of("right") == PlayerAnimator.FLIP_RIGHT, "\"right\" → RIGHT")
	_check(PlayerAnimator.flip_mode_of("LEFT") == PlayerAnimator.FLIP_LEFT, "\"LEFT\" 大小写不敏感")
	_check(PlayerAnimator.flip_mode_of(" left ") == PlayerAnimator.FLIP_LEFT, "前后空格吃掉")
	_check(PlayerAnimator.flip_mode_of("none") == PlayerAnimator.FLIP_NONE, "\"none\" → NONE")
	_check(PlayerAnimator.flip_mode_of(1) == PlayerAnimator.FLIP_RIGHT, "int 1 → RIGHT")
	_check(PlayerAnimator.flip_mode_of(2) == PlayerAnimator.FLIP_LEFT, "int 2 → LEFT")
	_check(PlayerAnimator.flip_mode_of(0) == PlayerAnimator.FLIP_NONE, "int 0 → NONE")
	_check(PlayerAnimator.flip_mode_of(9) == PlayerAnimator.FLIP_NONE, "越界 int → NONE（不崩）")
	_check(PlayerAnimator.flip_mode_of("朝左边") == PlayerAnimator.FLIP_NONE, "认不出的串 → NONE")
	_check(PlayerAnimator.flip_mode_of(null) == PlayerAnimator.FLIP_NONE, "null → NONE")


# ------------------------------------------------------------
# C) 兵种级模式解析
# ------------------------------------------------------------

func _c_per_type_mode() -> void:
	_say("--- C 段：resolve_flip_mode（ART_FACING 表 + 全局开关）---")
	var world: Node2D = Node2D.new()
	add_child(world)
	var sys = _make_system(world)
	var fp := _add_player(world)
	fp.global_position = Vector2(10000.0, 10000.0)   # 远到不影响本段，只是让休眠判定成立

	var cases := {
		"ep_bear": PlayerAnimator.FLIP_RIGHT,
		"ep_troll": PlayerAnimator.FLIP_RIGHT,
		"ep_harpoon_shark": PlayerAnimator.FLIP_LEFT,
		"ep_paddle_shark": PlayerAnimator.FLIP_LEFT,
		"ep_cave": PlayerAnimator.FLIP_NONE,
	}
	for id in cases:
		var cfg: Dictionary = _cfg(str(id))
		_check(not cfg.is_empty(), "%s 兵种配置存在" % id)
		var e = _spawn(world, Vector2(24 * TILE, 24 * TILE), cfg, sys)
		var got: int = int(e._flip_mode)
		var want := int(cases[id])
		_check(got == want, "%s → %s（实际 %s）" % [id, _flip_name(want), _flip_name(got)])
		e.queue_free()
	await _phys(2)

	# 兵种自己在 config 里写 art_facing 可以覆盖代码表（将来搬进 config 就靠这个键）
	var over: Dictionary = _cfg("ep_bear")
	over["art_facing"] = "none"
	var e_none = _spawn(world, Vector2(25 * TILE, 24 * TILE), over, sys)
	_check(int(e_none._flip_mode) == PlayerAnimator.FLIP_NONE, "兵种 art_facing=\"none\" 覆盖代码表")
	e_none.queue_free()

	# 全局开关：关掉 → 全部退回旧行为（不镜像）。写 enemy 子树里，不用新增顶层键。
	var off := {"flip_h_with_facing": false}
	Config.set_override("enemy", off)
	var e_off = _spawn(world, Vector2(26 * TILE, 24 * TILE), _cfg("ep_bear"), sys)
	_check(int(e_off._flip_mode) == PlayerAnimator.FLIP_NONE,
			"enemy.flip_h_with_facing=false → 全关")
	Config.clear_overrides()
	e_off.queue_free()
	await _phys(2)
	sys.queue_free()
	world.queue_free()
	await _phys(2)


# ------------------------------------------------------------
# D) 端到端：追左边/右边的玩家
# ------------------------------------------------------------

func _d_live_movement() -> void:
	_say("--- D 段：真敌人追左/追右（走完整 AI 路径）---")
	var world: Node2D = Node2D.new()
	add_child(world)
	var sys = _make_system(world)
	var fp := _add_player(world)
	var home := Vector2(24 * TILE, 24 * TILE)
	var e = _spawn(world, home, _cfg("ep_bear"), sys)
	var body: Sprite2D = e._body

	# 玩家在左边 6 格 → 敌人向西追 → facing.x<0 → 镜像
	fp.global_position = home + Vector2(-6 * TILE, 0)
	await _phys(40)
	_check(e.facing().x < 0.0, "追左边的玩家：facing.x < 0（实际 %.2f）" % e.facing().x)
	_check(body.flip_h == true, "追左边的玩家：已水平镜像")
	_check(e.global_position.x < home.x, "确实往左挪了（%.0f < %.0f）" % [e.global_position.x, home.x])

	# 玩家挪到右边 6 格 → 敌人掉头向东 → 取消镜像
	var was := body.flip_h
	fp.global_position = e.global_position + Vector2(6 * TILE, 0)
	await _phys(60)
	_check(e.facing().x > 0.0, "玩家换到右边：facing.x > 0（实际 %.2f）" % e.facing().x)
	_check(was == true and body.flip_h == false, "掉头后镜像已取消")

	# 死区：正上方追人时不该左右抽风（A 段测规则，这里测"接上了真敌人"）
	body.flip_h = true
	for _k in range(6):
		e._animator.update(1.0 / FPS, PlayerAnimator.Anim.WALK, Vector2.UP)
	_check(body.flip_h == true, "正上方向：镜像保持，不来回抖")
	for _k in range(4):
		e._animator.update(1.0 / FPS, PlayerAnimator.Anim.WALK, Vector2.LEFT)
	_check(body.flip_h == true, "左下/正上交替后朝左仍是镜像（无残留）")

	# 鲨鱼：原画头朝左 → 追左边的玩家时**不该**镜像
	var es = _spawn(world, home + Vector2(0, 4 * TILE), _cfg("ep_harpoon_shark"), sys)
	var shark_body: Sprite2D = es._body
	fp.global_position = es.global_position + Vector2(-6 * TILE, 0)
	await _phys(40)
	_check(es.facing().x < 0.0, "鲨鱼也在追左边的玩家")
	_check(shark_body.flip_h == false, "鲨鱼（原画朝左）朝左走时不镜像 —— 一刀切规则会翻反")
	fp.global_position = es.global_position + Vector2(6 * TILE, 0)
	await _phys(60)
	_check(shark_body.flip_h == true, "鲨鱼朝右走时反而要镜像")

	e.queue_free()
	es.queue_free()
	await _phys(2)
	sys.queue_free()
	world.queue_free()
	await _phys(2)


# ------------------------------------------------------------
# E) 玩家素材绝不被二次镜像
# ------------------------------------------------------------

func _e_player_never_flipped() -> void:
	_say("--- E 段：玩家 8 向素材不受镜像影响 ---")
	var sp: Sprite2D = Sprite2D.new()
	add_child(sp)
	var an := PlayerAnimator.new(sp)
	var pview: Dictionary = Config.get_value("player", {})
	an.load_from_config(Config.get_value("sprites_lancer", {}), {
		"sprite_scale": float(pview.get("sprite_scale", 0.6)),
		"sprite_offset_y": float(pview.get("sprite_offset_y", -38.0)),
		"sprite_pixel_unit": float(pview.get("sprite_pixel_unit", 6.0)),
	}, "")
	for _k in range(12):
		an.update(1.0 / FPS, PlayerAnimator.Anim.WALK, Vector2.LEFT)
	_check(sp.flip_h == false, "lancer 未配 sprite_flip_h → 朝左也不镜像（走的是真 left 帧）")
	var left_tex: Texture2D = sp.texture
	# 同一条 facing=LEFT，换成显式 FLIP_RIGHT 才会翻 —— 证明默认值真的是"关"
	var sp2: Sprite2D = Sprite2D.new()
	add_child(sp2)
	var an2 := PlayerAnimator.new(sp2)
	an2.load_from_config(Config.get_value("sprites_lancer", {}), {
		"sprite_scale": 0.6, "sprite_offset_y": -38.0, "sprite_pixel_unit": 6.0,
		"sprite_flip_h": "right",
	}, "")
	an2.update(1.0 / FPS, PlayerAnimator.Anim.WALK, Vector2.LEFT)
	_check(sp2.flip_h == true, "显式 sprite_flip_h=\"right\" 才生效（默认确实是关）")
	_check(left_tex != null, "lancer 的 left 帧真的取到了贴图")
	sp.queue_free()
	sp2.queue_free()


# ------------------------------------------------------------
# F) 受击挤压通道
# ------------------------------------------------------------

func _f_squash_channel() -> void:
	_say("--- F 段：挤压走 scale_mul，不再被动画器每帧盖掉 ---")
	var world: Node2D = Node2D.new()
	add_child(world)
	var sys = _make_system(world)
	var fp := _add_player(world)
	fp.global_position = Vector2(10000.0, 10000.0)
	var home := Vector2(24 * TILE, 24 * TILE)
	var cfg: Dictionary = _cfg("ep_troll")      # scale 0.5：正是老 bug 下"挤压看不见"的那档
	var e = _spawn(world, home, cfg, sys)
	var body: Sprite2D = e._body
	var base_scale: float = e._animator._scale
	_check(absf(base_scale - 0.5) < 0.001, "troll 的兵种 scale=0.5 已生效（实际 %.2f）" % base_scale)

	# 旧写法：直接写 _body.scale → 动画器下一帧按 _scale 重写，挤压被吃掉
	body.scale = Vector2(0.82, 1.18)
	e._animator.update(1.0 / FPS, PlayerAnimator.Anim.WALK, Vector2.RIGHT)
	_check(absf(body.scale.x - base_scale) < 0.001,
			"复现老 bug：直接写 _body.scale 会被动画器打回 %.2f（所以必须走通道）" % base_scale)

	# 新写法：写 scale_mul → 动画器每帧乘进去
	e.play_hit_fx(home + Vector2(40.0, 0.0))
	var mul: Vector2 = e._animator.get_scale_mul()
	_check(absf(mul.x - (1.0 - 0.18)) < 0.02 and absf(mul.y - (1.0 + 0.18)) < 0.02,
			"play_hit_fx 后 scale_mul=(%.2f, %.2f) ≈ 压扁拉长" % [mul.x, mul.y])
	e._animator.update(1.0 / FPS, PlayerAnimator.Anim.WALK, Vector2.RIGHT)
	_check(absf(body.scale.x - base_scale * mul.x) < 0.001,
			"动画器把倍数乘进了 _body.scale（%.3f ≈ %.2f×%.2f）" % [body.scale.x, base_scale, mul.x])
	# 回弹要真的收回去（tween_method 驱动，跑够 0.16s 以上）
	await _phys(16)
	var settled: Vector2 = e._animator.get_scale_mul()
	_check(absf(settled.x - 1.0) < 0.02 and absf(settled.y - 1.0) < 0.02,
			"挤压回弹到 (1,1)（实际 %.2f, %.2f）" % [settled.x, settled.y])

	e.queue_free()
	await _phys(2)
	sys.queue_free()
	world.queue_free()
	await _phys(2)


# ------------------------------------------------------------
# G) 死亡冻结镜像
# ------------------------------------------------------------

func _g_death_freezes() -> void:
	_say("--- G 段：死亡后镜像冻结，不会临死翻回朝右 ---")
	var world: Node2D = Node2D.new()
	add_child(world)
	var sys = _make_system(world)
	var fp := _add_player(world)
	var home := Vector2(24 * TILE, 24 * TILE)
	fp.global_position = home + Vector2(-6 * TILE, 0)
	var e = _spawn(world, home, _cfg("ep_bear"), sys)
	var body: Sprite2D = e._body
	await _phys(40)
	_check(body.flip_h == true, "死前正在朝左走（已镜像）")
	e.take_damage(99999)
	_check(e._dying, "已进入死亡流程")
	# 淡出 0.45s ≈ 27 物理帧后节点自毁，所以只跑 12 帧，趁 Body 还在时验镜像
	await _phys(12)
	if is_instance_valid(e):
		_check(body.flip_h == true, "死亡动画期间镜像保持不变（_update_anim 已停跑）")
	else:
		_check(false, "敌人过早被释放，G 段最后一条没测到东西")
	e.queue_free()
	await _phys(2)
	sys.queue_free()
	world.queue_free()
	await _phys(2)

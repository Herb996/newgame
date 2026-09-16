extends Node
## ============================================================
## probe_anim8 — 8 向朝向解析的验证探针（headless 可跑）
##
## 验四件事：
##   A) dir_from_facing() 的八个扇区映射对不对（含边界与零向量）
##   B) parse_spec() 对三类精灵集的处理：真 8 向 / 扁平共用 / 4 向字典的回退
##   C) 真实 Main.tscn 里玩家拿到的帧表与画布参数（view 覆盖是否生效）
##   D) 连续驱动八个朝向，sprite.texture 是否真的换（不只是配置对，而是画出来对）
##
## 为什么要 headless 也能跑：这些都是纯逻辑 + 资源装载，不依赖渲染；
## 无头跑得快，且能顺带暴露「帧路径写错 → load 静默返回 null」这类问题。
## ============================================================

const OUT := "user://_probe_anim8.txt"

var _lines: Array = []
var _fails: Array = []
var _n := 0


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _ready() -> void:
	_section_a()
	_section_b()
	await _section_c()
	await _section_d()
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_anim8] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)


# ------------------------------------------------------------
func _section_a() -> void:
	_say("--- A 段：dir_from_facing 八向映射 ---")
	var cases := [
		[Vector2(1, 0), "right"],
		[Vector2(1, 1), "down_right"],
		[Vector2(0, 1), "down"],
		[Vector2(-1, 1), "down_left"],
		[Vector2(-1, 0), "left"],
		[Vector2(-1, -1), "up_left"],
		[Vector2(0, -1), "up"],
		[Vector2(1, -1), "up_right"],
	]
	for c in cases:
		var got := PlayerAnimator.dir_from_facing(c[0])
		_check(got == StringName(c[1]), "%s -> %s（实得 %s）"
				% [str(c[0]), String(c[1]), String(got)])

	_check(PlayerAnimator.dir_from_facing(Vector2.ZERO) == PlayerAnimator.DIR_DOWN,
			"零向量 -> down（与旧实现的默认一致）")
	_check(PlayerAnimator.dir_from_facing(Vector2(10, 1)) == PlayerAnimator.DIR_RIGHT,
			"10:1 轻微偏下 -> 仍是 right（不误判成斜向）")
	_check(PlayerAnimator.dir_from_facing(Vector2(1, 10)) == PlayerAnimator.DIR_DOWN,
			"1:10 轻微偏右 -> 仍是 down")

	_check(PlayerAnimator.primary_dir(PlayerAnimator.DIR_UP_LEFT) == PlayerAnimator.DIR_LEFT,
			"primary_dir(up_left) = left")
	_check(PlayerAnimator.primary_dir(PlayerAnimator.DIR_DOWN) == PlayerAnimator.DIR_DOWN,
			"primary_dir(down) 原样返回（主方向不动）")
	_check(PlayerAnimator.DIRS.size() == 8, "DIRS 共 8 个方向（实得 %d）"
			% PlayerAnimator.DIRS.size())
	# 前四个必须是原 4 向且顺序不变 —— 顺序变了会让 summary / 预载遍历错位
	_check(PlayerAnimator.DIRS[0] == PlayerAnimator.DIR_DOWN
			and PlayerAnimator.DIRS[1] == PlayerAnimator.DIR_UP
			and PlayerAnimator.DIRS[2] == PlayerAnimator.DIR_LEFT
			and PlayerAnimator.DIRS[3] == PlayerAnimator.DIR_RIGHT,
			"DIRS 前四项仍是 down/up/left/right（追加而非插队）")


# ------------------------------------------------------------
func _section_b() -> void:
	_say("")
	_say("--- B 段：parse_spec 对三类精灵集 ---")

	# (1) 真 8 向：sprites_lancer
	var lan: Dictionary = Config.get_value("sprites_lancer", {})
	_check(not lan.is_empty(), "config 存在 sprites_lancer 段")
	var spec := PlayerAnimator.parse_spec(lan)
	var anims: Dictionary = spec["anims"]
	var miss := 0
	var miss_names: Array = []
	for anim in PlayerAnimator.ANIM_NAMES:
		for dir in PlayerAnimator.DIRS:
			if (anims[anim][dir] as PackedStringArray).is_empty():
				# dodge/dead 故意留空 -> 走程序化运动；
				# graze 是羊（animal）吃的动作，玩家精灵集本来就不需要配。
				if anim != &"dodge" and anim != &"dead" and anim != &"graze":
					miss += 1
					miss_names.append("%s/%s" % [String(anim), String(dir)])
	_check(miss == 0, "除 dodge/dead/graze 外 8 向全都有帧（缺 %d %s）"
			% [miss, str(miss_names).left(80)])
	_check((anims[&"attack"][PlayerAnimator.DIR_UP_LEFT] as PackedStringArray).size() == 3,
			"attack/up_left 有 3 帧（镜像派生方向也在）")
	_check((anims[&"hit"][PlayerAnimator.DIR_DOWN_RIGHT] as PackedStringArray).size() == 6,
			"hit/down_right 有 6 帧")

	# (2) 扁平数组：sprites_ts —— 八向应全部拿到同一批帧
	var ts: Dictionary = Config.get_value("sprites_ts", {})
	var ta: Dictionary = PlayerAnimator.parse_spec(ts)["anims"]
	var n_up_r: int = (ta[&"idle"][PlayerAnimator.DIR_UP_RIGHT] as PackedStringArray).size()
	var n_down: int = (ta[&"idle"][PlayerAnimator.DIR_DOWN] as PackedStringArray).size()
	_check(n_up_r == n_down and n_up_r > 0,
			"sprites_ts（扁平数组）斜向也能取到帧：up_right %d 帧 = down %d 帧" % [n_up_r, n_down])

	# (3) 老 4 向字典：sprites —— 斜向必须回退到水平主方向
	var sp: Dictionary = Config.get_value("sprites", {})
	var sa: Dictionary = PlayerAnimator.parse_spec(sp)["anims"]
	var up_r: PackedStringArray = sa[&"walk"][PlayerAnimator.DIR_UP_RIGHT]
	var right: PackedStringArray = sa[&"walk"][PlayerAnimator.DIR_RIGHT]
	var got_fallback := up_r.size() > 0 and up_r.size() == right.size() and up_r[0] == right[0]
	_check(got_fallback, "sprites（4 向字典）up_right 回退到 right 的帧（%s）"
			% (up_r[0].get_file() if up_r.size() > 0 else "空"))
	var dn_l: PackedStringArray = sa[&"walk"][PlayerAnimator.DIR_DOWN_LEFT]
	var left: PackedStringArray = sa[&"walk"][PlayerAnimator.DIR_LEFT]
	_check(dn_l.size() > 0 and dn_l[0] == left[0],
			"sprites 的 down_left 回退到 left 的帧（%s）"
			% (dn_l[0].get_file() if dn_l.size() > 0 else "空"))

	# (4) 敌人 / 羊用的也是同一套解析（扁平），斜向不能缺
	var et: Dictionary = Config.get_value("enemy_types", {})
	if not et.is_empty():
		var types: Array = et.get("types", [])
		if types.size() > 0:
			var t0: Dictionary = types[0]
			var ea: Dictionary = PlayerAnimator.parse_spec(t0)["anims"]
			var ok := true
			for dir in PlayerAnimator.DIRS:
				if (ea[&"walk"][dir] as PackedStringArray).is_empty():
					ok = false
			_check(ok, "敌人（%s）的 walk 八向都有帧" % String(t0.get("id", "?")))


# ------------------------------------------------------------
var _player: Node = null


func _section_c() -> void:
	_say("")
	_say("--- C 段：真实 Main.tscn 里玩家的帧表与画布参数 ---")
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	for _i in range(120):
		await get_tree().process_frame

	_player = get_tree().get_first_node_in_group("player")
	_check(_player != null, "场景里找到 group=player 的节点")
	if _player == null:
		return
	var anim = _player._animator
	_check(anim != null, "玩家挂上了 PlayerAnimator")
	if anim == null:
		_player = null
		return

	# 画布参数必须取自 sprites_lancer.view（而不是 player 段的旧值）
	_check(is_equal_approx(anim._scale, 0.6),
			"sprite_scale 取自 view = 0.6（实得 %.3f）" % anim._scale)
	_check(is_equal_approx(anim._offset_y, -38.0),
			"sprite_offset_y 取自 view = -38（实得 %.1f）" % anim._offset_y)
	_check(is_equal_approx(anim._pixel_unit, 10.0),
			"sprite_pixel_unit 取自 view = 10（实得 %.1f）" % anim._pixel_unit)

	# 贴图必须真的装载出来（路径写错会静默 null）
	var nulls := 0
	for anim_name in PlayerAnimator.ANIM_NAMES:
		for dir in PlayerAnimator.DIRS:
			for t in (anim._frames[anim_name][dir] as Array):
				if t == null:
					nulls += 1
	_check(nulls == 0, "所有已配置帧都装载成功，没有 null（%d 个）" % nulls)

	for anim_name in [&"idle", &"walk", &"attack", &"hit"]:
		_say("   %s：8 向共 %d 种不同首帧"
				% [String(anim_name), _uniq_first(anim, anim_name)])
	_check(_uniq_first(anim, &"attack") == 8, "attack 八向各不相同（实得 %d 种）"
			% _uniq_first(anim, &"attack"))
	_check(_uniq_first(anim, &"hit") == 8, "hit 八向各不相同（实得 %d 种）"
			% _uniq_first(anim, &"hit"))
	_check(_uniq_first(anim, &"idle") == 2,
			"idle 只有 2 种（原图 + 镜像）—— 官方 Idle 是单向素材（实得 %d 种）"
			% _uniq_first(anim, &"idle"))
	_check(_uniq_first(anim, &"walk") == 2,
			"walk 只有 2 种（原图 + 镜像）—— 官方 Run 是单向素材（实得 %d 种）"
			% _uniq_first(anim, &"walk"))


func _uniq_first(anim, anim_name: StringName) -> int:
	var uniq := {}
	for dir in PlayerAnimator.DIRS:
		var arr: Array = anim._frames[anim_name][dir]
		if not arr.is_empty() and arr[0] != null:
			uniq[arr[0].get_instance_id()] = true
	return uniq.size()


# ------------------------------------------------------------
func _section_d() -> void:
	_say("")
	_say("--- D 段：连续驱动八个朝向，看 sprite 是否真的换图 ---")
	if _player == null:
		_say("   [跳过] C 段没拿到玩家")
		return
	var anim = _player._animator
	var sprite: Sprite2D = _player._sprite
	if sprite == null:
		_check(false, "玩家有 Sprite2D")
		return

	var vecs := [
		["down", Vector2(0, 1)], ["up", Vector2(0, -1)],
		["left", Vector2(-1, 0)], ["right", Vector2(1, 0)],
		["down_right", Vector2(1, 1)], ["down_left", Vector2(-1, 1)],
		["up_right", Vector2(1, -1)], ["up_left", Vector2(-1, -1)],
	]
	# delta 传 0：让帧计时不推进，八个朝向都停在第 0 帧，比较的才是「方向」而不是「帧号」
	var ids := {}
	for v in vecs:
		anim.update(0.0, PlayerAnimator.Anim.ATTACK, v[1])
		if sprite.texture != null:
			ids[sprite.texture.get_instance_id()] = true
	_check(ids.size() == 8,
			"驱动 8 个朝向后 sprite.texture 出现 8 种不同贴图（实得 %d）" % ids.size())

	# 注意：不能用「帧宽度」判断朝向不同 —— 所有帧都是整张 320 画布，
	# 宽度恒等于 320。方向确实不同这一点由上面的 instance_id 计数，
	# 加上 python 侧 tools/probe_lancer_frames.py 的像素级比对共同保证。
	var atk_dr: Texture2D = anim._frames[&"attack"][PlayerAnimator.DIR_DOWN_RIGHT][0]
	var atk_r: Texture2D = anim._frames[&"attack"][PlayerAnimator.DIR_RIGHT][0]
	var atk_dl: Texture2D = anim._frames[&"attack"][PlayerAnimator.DIR_DOWN_LEFT][0]
	_check(atk_dr != atk_r, "attack 的 down_right 与 right 不是同一张图（斜向没退化成主方向）")
	_check(atk_dl != atk_dr, "attack 的 down_left 与 down_right 不是同一张图")
	var atk_first: Texture2D = anim._frames[&"attack"][PlayerAnimator.DIR_DOWN][0]
	var hit_first: Texture2D = anim._frames[&"hit"][PlayerAnimator.DIR_DOWN][0]
	_check(atk_first != hit_first, "attack 与 hit 用的是不同帧（动作没混用）")

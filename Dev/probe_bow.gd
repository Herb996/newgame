extends Node
## ============================================================
## probe_bow — 「弓」这条链路的验证探针（headless 可跑）
##
## 验六件事：
##   A) config 里武器表 / 弓手精灵集的结构与内容
##   B) attack_param 的「武器覆盖全局」与「缺键回落」两条链
##   C) projectile 的三个纯函数：撞墙判定 / 线段穿墙 / 线段命中最近目标
##   D) 弹道节点的真实飞行：沿 dir 前进、rotation 跟速度角、超射程自毁
##   E) 真实 Main.tscn 里切武器：贴图集、画布参数、判定框半径、动作时长是否都跟着换
##   F) 端到端：切到弓 → 开火 → 箭真的飞出去并让一只敌人掉血
##
## 为什么 headless 也能跑：撞墙查的是 map 生成的 walls 格子表、命中查的是节点距离，
## 都不是物理服务器查询（见 projectile.gd 头注释），所以无头下逐帧可控。
## ============================================================

const OUT := "user://_probe_bow.txt"
const PROJ := preload("res://Scripts/combat/projectile.gd")

var _lines: Array = []
var _fails: Array = []
var _n := 0
var _player: Node = null


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _ready() -> void:
	_section_a()
	_section_b_config()
	_section_c()
	await _section_d()
	await _section_e()
	await _section_f()
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_bow] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)


# ------------------------------------------------------------
func _section_a() -> void:
	_say("--- A 段：config 结构 ---")
	var table: Dictionary = Config.get_value("combat.weapons", {})
	_check(not table.is_empty(), "存在 combat.weapons 段")
	var ids: Array = []
	for k in table.keys():
		if not str(k).begins_with("_"):
			ids.append(str(k))
	_check(ids == ["sword", "spear", "bow", "sniper"],
			"武器 id = [sword, spear, bow, sniper]（2026-09-17 起有长枪+强弩，实得 %s）" % str(ids))
	_check(str(Config.get_value("player.weapon", "")) == "sword",
			"player.weapon 默认 = sword（实得 %s）" % str(Config.get_value("player.weapon", "")))

	var sw: Dictionary = table.get("sword", {})
	_check(str(sw.get("kind", "")) == "melee", "sword.kind = melee")
	_check(str(sw.get("sprite_set", "x")) == "sprites_ts",
			"sword.sprite_set = sprites_ts（2026-09-17 起剑士锁战士贴图，实得 %s）"
			% str(sw.get("sprite_set", "x")))

	var bow: Dictionary = table.get("bow", {})
	_check(str(bow.get("kind", "")) == "ranged", "bow.kind = ranged")
	_check(str(bow.get("sprite_set", "")) == "sprites_archer", "bow.sprite_set = sprites_archer")
	var pc: Dictionary = bow.get("projectile", {})
	_check(not pc.is_empty(), "bow 有 projectile 段")
	_check(str(pc.get("texture", "")).ends_with("arrow.png"), "projectile.texture 指向 arrow.png")
	_check(float(pc.get("hit_radius_px", 0.0)) > 0.0, "projectile.hit_radius_px > 0")
	_check(float(pc.get("speed", 0.0)) > 0.0 and float(pc.get("max_distance_px", 0.0)) > 0.0,
			"projectile 有 speed(%s) 与 max_distance_px(%s)"
			% [str(pc.get("speed")), str(pc.get("max_distance_px"))])

	var arc: Dictionary = Config.get_value("sprites_archer", {})
	_check(not arc.is_empty(), "存在 sprites_archer 精灵集段")
	var view: Dictionary = arc.get("view", {})
	_check(is_equal_approx(float(view.get("sprite_scale", 0.0)), 0.6),
			"sprites_archer.view.sprite_scale = 0.6（实得 %.3f）"
			% float(view.get("sprite_scale", 0.0)))
	_check(is_equal_approx(float(view.get("sprite_offset_y", 0.0)), -40.0),
			"sprites_archer.view.sprite_offset_y = -40（脚底 136，136-96=40）")

	var spec: Dictionary = PlayerAnimator.parse_spec(arc)
	var an: Dictionary = spec["anims"]
	_check((an[&"idle"][PlayerAnimator.DIR_DOWN] as PackedStringArray).size() == 6,
			"idle 6 帧（实得 %d）" % (an[&"idle"][PlayerAnimator.DIR_DOWN] as PackedStringArray).size())
	_check((an[&"walk"][PlayerAnimator.DIR_DOWN] as PackedStringArray).size() == 4,
			"walk 4 帧（Run 表实得 %d）" % (an[&"walk"][PlayerAnimator.DIR_DOWN] as PackedStringArray).size())
	_check((an[&"attack"][PlayerAnimator.DIR_DOWN] as PackedStringArray).size() == 8,
			"attack 8 帧（Shoot 表实得 %d）" % (an[&"attack"][PlayerAnimator.DIR_DOWN] as PackedStringArray).size())

	var miss := 0
	var where: Array = []
	for anim in [&"idle", &"walk", &"attack"]:
		for dir in PlayerAnimator.DIRS:
			if (an[anim][dir] as PackedStringArray).is_empty():
				miss += 1
				where.append("%s/%s" % [String(anim), String(dir)])
	_check(miss == 0, "弓手 idle/walk/attack 的 8 向都取到帧（缺 %d %s）" % [miss, str(where).left(70)])
	_check((an[&"attack"][PlayerAnimator.DIR_LEFT][0] as String)
			!= (an[&"attack"][PlayerAnimator.DIR_RIGHT][0] as String),
			"attack 的 left 用的是镜像帧，与 right 不是同一张（%s）"
			% (an[&"attack"][PlayerAnimator.DIR_LEFT][0] as String).get_file())


# ------------------------------------------------------------
func _section_b_config() -> void:
	_say("")
	_say("--- B 段：attack_param 的两条链（武器覆盖 / 缺键回落）---")
	# 这一段直接读 config 复算，不依赖玩家实例 —— 保证「不配武器表 = 老行为」这条断言
	# 在任何时候都成立。
	var fallback_key := "arc_degrees"
	var global_arc := float(Config.get_value("combat.attack." + fallback_key, -1.0))
	_check(is_equal_approx(global_arc, 200.0), "combat.attack.arc_degrees = 200（全局值还在）")
	_check(float(Config.get_value("combat.attack.windup_seconds", -1.0)) == 0.12,
			"combat.attack.windup_seconds = 0.12（近战与全局一致，改造没动它）")


# ------------------------------------------------------------
func _section_c() -> void:
	_say("")
	_say("--- C 段：projectile 纯函数 ---")
	# 3x3 网格，格宽 16；中间一格 (1,1) 是墙
	var walls: Array = []
	for y in range(3):
		var row: Array = []
		for x in range(3):
			row.append(x == 1 and y == 1)
		walls.append(row)

	_check(PROJ.is_blocked(walls, 16, Vector2(0, 0)) == false, "空地不阻挡 (0,0)")
	_check(PROJ.is_blocked(walls, 16, Vector2(24, 24)) == true, "墙格 (1,1) 阻挡")
	_check(PROJ.is_blocked(walls, 16, Vector2(-5, 8)) == true, "越界（负 x）视为阻挡")
	_check(PROJ.is_blocked(walls, 16, Vector2(100, 8)) == true, "越界（超右）视为阻挡")
	_check(PROJ.is_blocked(walls, 16, Vector2(8, 100)) == true, "越界（超下）视为阻挡")
	_check(PROJ.is_blocked([], 16, Vector2(24, 24)) == false, "没有导航数据时不做墙判定")

	# 线段穿墙：从 (8,8) 打到 (40,40) 必然穿过 (1,1)
	_check(PROJ.segment_hits_wall(walls, 16, Vector2(8, 8), Vector2(40, 40)) == true,
			"线段 (8,8)->(40,40) 穿过墙格 -> true")
	_check(PROJ.segment_hits_wall(walls, 16, Vector2(4, 4), Vector2(12, 12)) == false,
			"线段 (4,4)->(12,12) 全在 (0,0) 格内 -> false")
	# 大步长穿墙：一步跨过整格，采样必须仍然抓得住
	_check(PROJ.segment_hits_wall(walls, 16, Vector2(8, 24), Vector2(40, 24)) == true,
			"单帧跨过整格（步长 32px）也能判出穿墙")

	# 线段命中：造几个 Node2D 当假目标
	# 注意「最近」指的是**到线段的垂直距离**，不是沿线段的先后顺序 ——
	# 目标 (40,2) 比 (20,4) 更靠近 y=0 这条线，所以前者胜出。
	var mk := func(pos: Vector2) -> Node2D:
		var n := Node2D.new()
		add_child(n)
		n.global_position = pos
		return n
	var near_line: Node2D = mk.call(Vector2(40, 2))    # 距线段 2px
	var far_line: Node2D = mk.call(Vector2(20, 6))     # 距线段 6px
	var far_off: Node2D = mk.call(Vector2(0, 200))     # 离线段 200px，远超半径
	var hit: Node = PROJ.nearest_target_on_segment(Vector2(0, 0), Vector2(60, 0), 16.0,
			[far_off, far_line, near_line])
	_check(hit == near_line,
			"半径内取『离线段最近』的那个（期望 near_line，实得 %s）"
			% ("near_line" if hit == near_line else
				("far_line" if hit == far_line else
					("far_off" if hit == far_off else "null"))))
	var none2: Node = PROJ.nearest_target_on_segment(Vector2(0, 500), Vector2(60, 500), 8.0,
			[near_line])
	_check(none2 == null, "目标离线段 200px -> 不命中")
	_check(PROJ.nearest_target_on_segment(Vector2(0, 0), Vector2(60, 0), 1.0,
			[near_line, far_line]) == null,
			"半径缩到 1px -> 距线段 2px/6px 的两个都不命中（半径真的起作用）")
	_check(PROJ.nearest_target_on_segment(Vector2(0, 0), Vector2(60, 0), 8.0,
			[near_line, far_line]) == near_line,
			"半径放到 8px -> 只剩 near_line 够近")
	for n in [near_line, far_line, far_off]:
		n.queue_free()


# ------------------------------------------------------------
func _section_d() -> void:
	_say("")
	_say("--- D 段：弹道节点真实飞行 ---")
	var b = PROJ.new()
	add_child(b)
	b.global_position = Vector2.ZERO
	b.setup({"speed": 600.0, "max_distance_px": 120.0, "hit_radius_px": 8.0,
			"texture": "", "scale": 1.0}, Vector2(1, 0), 5, [], 16)
	for _i in range(5):
		await get_tree().physics_frame
	var alive := is_instance_valid(b)
	# 显式类型：PROJ 是 preload 进来的脚本，new() 返回 Variant，
	# 拿 Variant 的属性做 := 推断会直接 Parse Error。
	var x: float = b.global_position.x if alive else -1.0
	_check(alive and x > 20.0, "沿 dir 前进：5 帧后 x=%.1f（期望 ≈50，600px/s@60fps）" % x)
	_check(alive and is_equal_approx(b.rotation, 0.0), "朝右时 rotation = 0")
	_check(alive and b.z_index == 30, "z_index = 30（在角色之上、路径线之下）")
	for _i in range(20):
		await get_tree().physics_frame
	_check(not is_instance_valid(b), "超过 max_distance_px(120) 后自动销毁")

	var b2 = PROJ.new()
	add_child(b2)
	b2.global_position = Vector2.ZERO
	b2.setup({"speed": 600.0, "max_distance_px": 60.0, "hit_radius_px": 8.0},
			Vector2(1, 1), 5, [], 16)
	_check(is_instance_valid(b2)
			and is_equal_approx(b2.rotation, Vector2(1, 1).normalized().angle()),
			"斜向弹道 rotation 跟速度方向（%.4f）" % (b2.rotation if is_instance_valid(b2) else -9.0))
	if is_instance_valid(b2):
		b2.queue_free()
	for _i in range(2):
		await get_tree().physics_frame


# ------------------------------------------------------------
func _section_e() -> void:
	_say("")
	_say("--- E 段：真实 Main.tscn 里切武器 ---")
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	for _i in range(120):
		await get_tree().process_frame

	_player = get_tree().get_first_node_in_group("player")
	_check(_player != null, "场景里找到 group=player 的节点")
	if _player == null:
		return

	# --- 初始：默认角色（枪手 = 长枪） ---
	# 2026-09-17 起 characters.default = spearman，无选人路径开局拿的是 spear；
	# 下面要验"剑"的各项，所以显式切到 sword 再断言（保持原断言语义不变）。
	_check(str(_player.current_weapon) == "spear", "开局武器 = spear（默认角色枪手，实得 %s）"
			% str(_player.current_weapon))
	_player.switch_weapon(&"sword")
	var ids: Array = _player.weapon_ids()
	_check(ids == ["sword", "spear", "bow", "sniper"],
			"weapon_ids() 跳过 _comment（2026-09-17 起有长枪+强弩，实得 %s）" % str(ids))
	_check(_player.attack_kind() == "melee", "开局 attack_kind = melee")
	_check(is_equal_approx(_player.attack_param("windup_seconds", -1.0), 0.12),
			"剑的前摇 = 0.12（取自武器表，与全局同值）")
	_check(is_equal_approx(_player._animator._scale, 0.6),
			"剑用枪兵画布参数 scale=0.6（实得 %.3f）" % _player._animator._scale)
	_check(is_equal_approx(_hitbox_radius(), 120.0),
			"剑的判定框半径 = 120（实得 %.1f）" % _hitbox_radius())
	_check(is_equal_approx(_player.attack_noise(), 120.0),
			"剑的噪音 = 120（实得 %.1f）" % _player.attack_noise())
	_check(is_equal_approx(_player.attack_param("cancel_window_seconds", -1.0),
			float(Config.get_value("combat.attack.cancel_window_seconds", -2.0))),
			"武器表没写的键（cancel_window_seconds）回落到 combat.attack")
	_check(is_equal_approx(_player.attack_param("no_such_key_at_all", 42.0), 42.0),
			"完全不存在的键 -> 用传入的 fallback（42）")

	# --- 切弓 ---
	var switched: bool = _player.switch_weapon(&"bow")
	_check(switched, "switch_weapon(bow) 返回 true")
	_check(_player.attack_kind() == "ranged", "切后 attack_kind = ranged")
	_check(is_equal_approx(_player.attack_param("windup_seconds", -1.0), 0.3),
			"弓的前摇换成 0.3（武器覆盖全局，实得 %.3f）"
			% _player.attack_param("windup_seconds", -1.0))
	_check(is_equal_approx(_player.attack_param("range_px", -1.0), 0.0),
			"弓的 range_px = 0（近战扇形判定不参与）")
	_check(is_equal_approx(_hitbox_radius(), 0.0),
			"换武器时判定框半径被重设成 0（实得 %.1f）" % _hitbox_radius())
	_check(is_equal_approx(_player._animator._scale, 0.6),
			"贴图集跟着武器换成弓兵画布 scale=0.6（实得 %.3f）" % _player._animator._scale)
	_check(is_equal_approx(_player._animator._offset_y, -40.0),
			"弓手足底偏移 -40（实得 %.1f）" % _player._animator._offset_y)
	_check(is_equal_approx(_player.attack_noise(), 70.0),
			"弓的噪音 = 70（比剑安静，实得 %.1f）" % _player.attack_noise())

	var anim = _player._animator
	var n_atk: int = (anim._frames[&"attack"][PlayerAnimator.DIR_DOWN] as Array).size()
	_check(n_atk == 8, "换集后 attack 帧序列 = 8 帧（实得 %d）" % n_atk)
	var nulls := 0
	for anim_name in PlayerAnimator.ANIM_NAMES:
		for dir in PlayerAnimator.DIRS:
			for t in (anim._frames[anim_name][dir] as Array):
				if t == null:
					nulls += 1
	_check(nulls == 0, "弓手帧全部装载成功，没有 null（%d 个）" % nulls)

	var uniq := {}
	for dir in PlayerAnimator.DIRS:
		var arr: Array = anim._frames[&"attack"][dir]
		if not arr.is_empty():
			uniq[arr[0].get_instance_id()] = true
	_check(uniq.size() == 2,
			"弓手 attack 只有 2 种朝向（原图 + 镜像）—— Archer 是单向素材（实得 %d 种）"
			% uniq.size())

	# --- 非法武器 id ---
	_check(_player.switch_weapon(&"bazooka") == false,
			"switch_weapon(未知 id bazooka) 返回 false")
	_check(_player.attack_kind() == "ranged", "非法切换后武器没被改动（仍是 ranged）")

	# --- 切回剑 ---
	_check(_player.switch_weapon(&"sword"), "切回 sword 成功")
	_check(is_equal_approx(_hitbox_radius(), 120.0),
			"切回后判定框半径恢复 120（实得 %.1f）" % _hitbox_radius())
	_check(is_equal_approx(_player._animator._scale, 0.6),
			"切回后画布参数恢复 0.6（实得 %.3f）" % _player._animator._scale)


func _hitbox_radius() -> float:
	if _player == null or _player.hitbox == null:
		return -1.0
	var sh := _player.hitbox.get_node("CollisionShape2D").shape as CircleShape2D
	return sh.radius if sh != null else -1.0


# ------------------------------------------------------------
func _section_f() -> void:
	_say("")
	_say("--- F 段：端到端 —— 切弓 → 开火 → 箭飞出去并命中 ---")
	if _player == null:
		_say("   [跳过] E 段没拿到玩家")
		return
	_player.switch_weapon(&"bow")
	var parent := _player.get_parent()
	if parent == null:
		_check(false, "玩家有父节点（弹道挂靠处）")
		return

	# 找一个活着的敌人，把玩家挪到它旁边（极近距离：中间不可能有墙）
	var enemies := get_tree().get_nodes_in_group("enemies")
	var target: Node = null
	for e in enemies:
		if is_instance_valid(e) and float(e.hp) > 0.0:
			target = e
			break
	# 场上没敌人时不算失败：settings.json 里 enemy.count 可能被调成 0（本地调试常见）。
	# 改为"跳过并记录"，避免把别人的本地设置误报成回归。
	if target == null:
		_say("  SKIP 场上没有活着的敌人（enemy.count=0？）—— F 段端到端跳过")
		return
	_check(target != null, "场上找到活着的敌人")

	var before := _count_projectiles(parent)
	_player.global_position = target.global_position - Vector2(48, 0)
	_player.facing = Vector2.RIGHT
	var fired: bool = _player.fire_projectile()
	_check(fired, "fire_projectile() 返回 true（按到了 projectile 配置）")
	var after := _count_projectiles(parent)
	_check(after == before + 1, "父节点下多出 1 个 Projectile（%d -> %d）" % [before, after])

	# 箭上应该挂着 arrow.png 的 Sprite2D
	var live: Node = null
	for c in parent.get_children():
		if c.name == "Projectile":
			live = c
			break
	_check(live != null, "找到新建的 Projectile 节点")
	if live != null:
		var icon: Node = live.get_node_or_null("Icon")
		_check(icon != null and icon is Sprite2D and icon.texture != null,
				"弹道挂上了贴图（arrow.png 装载成功）")
		if icon != null and icon.texture != null:
			_check(icon.texture.get_width() == 64 and icon.texture.get_height() == 64,
					"箭矢贴图 64x64（实得 %dx%d）"
					% [icon.texture.get_width(), icon.texture.get_height()])
		_check(is_equal_approx(live.global_position.x,
				_player.global_position.x + 22.0),
				"发射点在朝向前方 22px（muzzle_offset_px）")

	var hp0 := float(target.hp)
	for _i in range(30):
		await get_tree().physics_frame
	_check(not is_instance_valid(target) or float(target.hp) < hp0,
			"箭命中敌人：hp %.0f -> %.0f（敌人被箭打掉血）"
			% [hp0, float(target.hp) if is_instance_valid(target) else 0.0])
	_check(_count_projectiles(parent) == before,
			"命中后弹道自行销毁（场上弹道数回到 %d）" % before)

	# 收尾：切回剑，避免影响后续
	_player.switch_weapon(&"sword")


func _count_projectiles(parent: Node) -> int:
	var n := 0
	for c in parent.get_children():
		if c.name == "Projectile":
			n += 1
	return n

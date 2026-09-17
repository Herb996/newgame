extends Node
## ============================================================
## probe_sniper — 「强弩」这条链路的验证探针（headless 可跑）
##
## 验四件事：
##   A) config：sniper 进了武器表、hitscan 段齐全、无 rifle 挂点（弩已画进帧）、噪音档就位
##   B) 纯函数：first_wall_point（射线截断）/ targets_on_segment（按沿线先后排序）
##   C) 真实 Main.tscn 里切强弩：kind/radius/时长/噪音/精灵集=sprites_crossbowman
##   D) 端到端：fire_hitscan 命中线上目标（穿透 2 个）、曳光节点生成并自毁、切回剑正常
##
## 为什么 headless 能跑：与弓同一理由 —— 墙查 walls 格子表、命中查节点距离，
## 全是纯数据判定（见 projectile.gd 头注释）。
## ============================================================

const OUT := "user://_probe_sniper.txt"
const PROJ := preload("res://Scripts/combat/projectile.gd")

## 假目标：带 take_damage，加入 enemies 组，供 fire_hitscan 结算。
class FakeTarget extends Node2D:
	var hp := 100.0
	func take_damage(amount: int) -> void:
		hp -= float(amount)

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
	print("[probe_sniper] 通过 %d / %d" % [_n - _fails.size(), _n])
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
	_check(ids == ["sword", "spear", "bow", "sniper"], "武器 id = [sword, spear, bow, sniper]（实得 %s）"
			% str(ids))

	var sn: Dictionary = table.get("sniper", {})
	_check(not sn.is_empty(), "sniper 段存在")
	_check(str(sn.get("kind", "")) == "hitscan", "sniper.kind = hitscan")
	_check(str(sn.get("sprite_set", "x")) == "sprites_crossbowman",
			"sniper.sprite_set = sprites_crossbowman（2026-09-17 起弩画进角色帧）")
	_check(is_equal_approx(float(sn.get("damage", 0.0)), 90.0), "sniper.damage = 90")
	_check(is_equal_approx(float(sn.get("windup_seconds", 0.0)), 0.55),
			"sniper.windup = 0.55（长瞄准）")
	_check(is_equal_approx(float(sn.get("recovery_seconds", 0.0)), 0.9),
			"sniper.recovery = 0.9（长拉栓）")
	_check(int(sn.get("noise", 0)) == 240, "sniper.noise = 240（枪声震天）")

	var hc: Dictionary = sn.get("hitscan", {})
	_check(not hc.is_empty(), "sniper 有 hitscan 段")
	_check(is_equal_approx(float(hc.get("max_distance_px", 0.0)), 900.0),
			"hitscan.max_distance_px = 900")
	_check(int(hc.get("pierce", 0)) == 2, "hitscan.pierce = 2（穿透两个）")
	_check(float(hc.get("hit_radius_px", 0.0)) > 0.0, "hitscan.hit_radius_px > 0")

	_check(sn.get("rifle", null) == null, "sniper 无 rifle 段（弩已烘焙进角色帧，不再挂点叠加）")
	_check(ResourceLoader.exists("res://Assets/Art/Sprites/Units/blue_crossbowman/idle_00.png"),
			"blue_crossbowman 角色帧已导入")
	_check(is_equal_approx(float(Config.get_value("noise.sources.sniper_shot", 0.0)), 240.0),
			"noise.sources.sniper_shot = 240（独立噪音档就位）")


# ------------------------------------------------------------
func _section_b() -> void:
	_say("")
	_say("--- B 段：hitscan 两个纯函数 ---")
	# 3x3 网格，格宽 16；中间一格 (1,1) 是墙
	var walls: Array = []
	for y in range(3):
		var row: Array = []
		for x in range(3):
			row.append(x == 1 and y == 1)
		walls.append(row)

	var w1 = PROJ.first_wall_point(walls, 16, Vector2(8, 8), Vector2(40, 40))
	_check(w1 != null, "穿墙射线返回第一个墙点（非 null）")
	if w1 != null:
		var p: Vector2 = w1
		_check(p.x >= 16.0 and p.x <= 40.0 and p.y >= 16.0 and p.y <= 40.0,
				"墙点落在墙格 (1,1) 内（实得 %s）" % str(p))
	_check(PROJ.first_wall_point(walls, 16, Vector2(4, 4), Vector2(12, 12)) == null,
			"全程空地的射线 -> null")
	_check(PROJ.first_wall_point([], 16, Vector2(8, 8), Vector2(40, 40)) == null,
			"没有导航数据 -> 不截断（null）")
	# 反方向打（从墙格打到空地）：起点已在墙里，第一个采样点立刻命中
	var w2 = PROJ.first_wall_point(walls, 16, Vector2(24, 24), Vector2(60, 24))
	_check(w2 != null, "起点就在墙内的射线也能截断")

	var mk := func(pos: Vector2) -> FakeTarget:
		var t := FakeTarget.new()
		add_child(t)
		t.global_position = pos
		return t
	var t_far: FakeTarget = mk.call(Vector2(50, 1))
	var t_near: FakeTarget = mk.call(Vector2(20, 1))
	var t_mid: FakeTarget = mk.call(Vector2(35, 1))
	var t_off: FakeTarget = mk.call(Vector2(40, 30))   # 距线 30px，远超半径

	var order: Array = PROJ.targets_on_segment(Vector2(0, 0), Vector2(60, 0), 16.0,
			[t_far, t_near, t_mid, t_off])
	# 注意：`order == [a, b] as Array` 会被 GDScript 解析成 `(order == [a, b]) as Array`
	#（bool 转 Array -> Parse Error），数组相等要逐元素比。
	_check(order.size() == 3 and order[0] == t_near and order[1] == t_mid
			and order[2] == t_far,
			"命中列表按沿线先后排序 [near, mid, far]，线外的被排除（实得 %d 个）" % order.size())
	_check(PROJ.targets_on_segment(Vector2(0, 0), Vector2(60, 0), 16.0, []).is_empty(),
			"空目标表 -> 空结果")
	for t in [t_far, t_near, t_mid, t_off]:
		t.queue_free()


# ------------------------------------------------------------
func _section_c() -> void:
	_say("")
	_say("--- C 段：真实 Main.tscn 里切强弩 ---")
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	for _i in range(120):
		await get_tree().process_frame

	_player = get_tree().get_first_node_in_group("player")
	_check(_player != null, "场景里找到 group=player 的节点")
	if _player == null:
		return
	_check(_player.weapon_ids() == ["sword", "spear", "bow", "sniper"],
			"weapon_ids() = [sword, spear, bow, sniper]（实得 %s）" % str(_player.weapon_ids()))

	var switched: bool = _player.switch_weapon(&"sniper")
	_check(switched, "switch_weapon(sniper) 返回 true")
	_check(_player.attack_kind() == "hitscan", "切后 attack_kind = hitscan")
	_check(is_equal_approx(_player.attack_param("windup_seconds", -1.0), 0.55),
			"前摇换 0.55（实得 %.3f）" % _player.attack_param("windup_seconds", -1.0))
	_check(is_equal_approx(_hitbox_radius(), 0.0),
			"判定框半径重设为 0（判定在射线上不在身上，实得 %.1f）" % _hitbox_radius())
	_check(is_equal_approx(_player.attack_noise(), 240.0),
			"噪音 = 240（实得 %.1f）" % _player.attack_noise())
	_check(is_equal_approx(_player._animator._scale, 0.6),
			"角色 scale=0.6（sprites_crossbowman，实得 %.3f）" % _player._animator._scale)

	# 弩已画进角色帧：不应再有 Rifle 挂点节点
	var rifle: Node = _player.get_node_or_null("Rifle")
	_check(rifle == null, "强弩无挂点节点（弩在 blue_crossbowman 帧里）")


func _hitbox_radius() -> float:
	if _player == null or _player.hitbox == null:
		return -1.0
	var sh := _player.hitbox.get_node("CollisionShape2D").shape as CircleShape2D
	return sh.radius if sh != null else -1.0


# ------------------------------------------------------------
func _section_d() -> void:
	_say("")
	_say("--- D 段：端到端 —— 瞬狙命中 / 穿透 / 曳光 / 挂点朝向 / 换回回收 ---")
	if _player == null:
		_say("   [跳过] C 段没拿到玩家")
		return
	var parent := _player.get_parent()
	if parent == null:
		_check(false, "玩家有父节点（曳光挂靠处）")
		return

	# 玩家脚下必须无墙（出生点一般空地；保险起见把射线附近的目标放近一点）
	_player.facing = Vector2.RIGHT

	# 假目标：线上两只（间距 60，都在 900px 射程内），线外一只
	var mk := func(pos: Vector2) -> FakeTarget:
		var t := FakeTarget.new()
		parent.add_child(t)
		t.global_position = pos
		t.add_to_group("enemies")
		return t
	var muzzle: Vector2 = _player.global_position + Vector2(34, 0)
	var a: FakeTarget = mk.call(muzzle + Vector2(80, 0))
	var b: FakeTarget = mk.call(muzzle + Vector2(140, 2))
	var c: FakeTarget = mk.call(muzzle + Vector2(200, 60))   # 线外

	var hits: int = _player.fire_hitscan()
	_check(hits == 2, "fire_hitscan 命中 2 个（pierce=2，实得 %d）" % hits)
	_check(float(a.hp) < 100.0, "目标 A 掉血（100 -> %.0f）" % float(a.hp))
	_check(float(b.hp) < 100.0, "目标 B 掉血（穿透第二只，100 -> %.0f）" % float(b.hp))
	_check(is_equal_approx(float(c.hp), 100.0), "线外目标 C 无伤（%.0f）" % float(c.hp))

	# 曳光：生成过、且会在 tracer_fade_seconds 后自毁
	var tracer: Node = null
	for ch in parent.get_children():
		if ch.name == "SniperTracer":
			tracer = ch
	_check(tracer != null, "父层生成过 SniperTracer 曳光节点")
	var gone := false
	for _i in range(40):
		await get_tree().physics_frame
		if tracer == null or not is_instance_valid(tracer):
			gone = true
			break
	_check(gone, "曳光淡出后自毁（≤0.7s 内消失）")

	# 命中冲击环：fx_ring 挂在世界层（非玩家脚下）
	var ring_found := false
	for ch in parent.get_children():
		if ch.get_script() != null and str(ch.get_script().resource_path).ends_with("fx_ring.gd"):
			ring_found = true
	_check(ring_found, "命中点生成过冲击环（fx_ring）")

	# 2026-09-17 起弩画进角色帧、无挂点 —— 原来的 flip_v/rotation 跟随断言已删。
	# 这里只验证朝向切换本身不影响 hitscan 状态。
	_player.facing = Vector2.LEFT
	await get_tree().process_frame
	await get_tree().process_frame
	var rifle: Node = _player.get_node_or_null("Rifle")
	_check(rifle == null, "朝左时同样无挂点（弩在帧里）")
	_player.facing = Vector2.RIGHT
	await get_tree().process_frame
	await get_tree().process_frame

	for t in [a, b, c]:
		if is_instance_valid(t):
			t.remove_from_group("enemies")
			t.queue_free()

	# 换回剑：挂点回收
	_player.switch_weapon(&"sword")
	await get_tree().process_frame
	var r2: Node = _player.get_node_or_null("Rifle")
	_check(r2 == null or not is_instance_valid(r2), "切回剑后挂点被回收")
	_check(is_equal_approx(_hitbox_radius(), 120.0),
			"切回剑判定框恢复 120（实得 %.1f）" % _hitbox_radius())

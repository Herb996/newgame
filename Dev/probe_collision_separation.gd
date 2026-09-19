extends Node
## ============================================================
## probe_collision_separation — 碰撞方案 A「单位轻量分离层」的验证探针
##
## 三件事分别判：
##   A) config 结构：combat.separation 键齐，且 radius ≤ tile/2
##      （分离层按地图格分桶、只查 3x3 邻格 —— 半径超过半格就会漏配对，
##       而漏掉的配对是"偶尔叠一下"，最难查，所以必须在 config 层就卡死）
##   B) 纯逻辑（不进真实局）：造假墙 + 假单位，直接喂给分离层
##      1. 两个重叠敌人一帧内就被推开；连推若干帧后分到不再重叠
##      2. 完全重合（法向算不出）也要岔开
##      3. 距离够远 → 一动不动（分离层绝不自己造位移）
##      4. 玩家是不可动的墙：单位被推开、玩家纹丝不动
##      5. _dying 的单位不参与（尸体不配当碰撞体）
##      6. 夹回可走格：正对墙推 → 不许进墙；斜推 → 沿墙滑；
##         关掉 clamp_to_walkable → 确实会进墙（证明是这道夹子在保护，不是巧合）
##      7. enabled=false → 完全回到老行为；拨回来立刻生效（不用重开一局）
##   C) 真实局对照：同一坨敌人，关掉分离层 vs 开着，重叠对数必须下降
##      （只断言"开了会分开"没有信息量：寻路本来也会把他们带走 —— 要靠对照组）
##
## 跑法：python tools/run_probe.py _probe_sep.log res://Dev/probe_collision_separation.tscn
## ============================================================

const OUT := "user://_probe_collision_separation.txt"
const SEP_SCRIPT := "res://Scripts/combat/unit_separation.gd"

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


func _tile() -> int:
	return int(Config.get_value("map.tile_size", 64))


func _ready() -> void:
	_section_a()
	await _section_b()
	await _section_c()
	Config.clear_overrides()
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[SepProbe] 通过 %d / %d" % [_n - _fails.size(), _n])
	print("[SepProbe] fails=%d -> %s" % [_fails.size(), "PASS" if _fails.is_empty() else "FAIL"])
	get_tree().quit(0 if _fails.is_empty() else 1)


# ------------------------------------------------------------
func _section_a() -> void:
	_say("--- A 段：config 结构 ---")
	var sep: Dictionary = Config.get_value("combat.separation", {})
	_check(not sep.is_empty(), "存在 combat.separation 段")
	for k in ["enabled", "strength", "max_push_px_per_frame", "clamp_to_walkable",
			"player_is_wall", "radius_px"]:
		_check(sep.has(k), "separation 有 %s" % k)
	_check(bool(sep.get("enabled", false)), "enabled 默认开着")
	_check(bool(sep.get("clamp_to_walkable", false)), "clamp_to_walkable 默认开着（默认就该护着墙）")
	_check(bool(sep.get("player_is_wall", false)), "player_is_wall 默认开着")
	var st := float(sep.get("strength", 0.0))
	_check(st > 0.0 and st <= 1.0, "strength 在 (0,1]（实得 %.2f）" % st)
	var tile := float(_tile())
	var mp := float(sep.get("max_push_px_per_frame", 0.0))
	# 单帧位移超过半格 = 一帧就能从"这格"跳进"墙那格"，夹子就成了事后追认。
	_check(mp > 0.0 and mp <= tile * 0.5,
			"max_push_px_per_frame 在 (0, 半格=%.0f]（实得 %.0f）" % [tile * 0.5, mp])
	var rr: Dictionary = sep.get("radius_px", {})
	for g in ["enemies", "animals", "player"]:
		var r := float(rr.get(g, 0.0))
		_check(r > 0.0, "radius_px.%s > 0（实得 %.0f）" % [g, r])
		# 分桶只看 3x3 邻格：两圆要重叠，圆心距 ≤ r_a + r_b ≤ 格宽 ⇒ 任一半径都得 ≤ 半格
		_check(r <= tile * 0.5, "radius_px.%s ≤ 半格 %.0f（否则分桶会漏配对）" % [g, tile * 0.5])


# ------------------------------------------------------------
## 假墙网格：默认全可走，把 x=6 这一列的 y=3..8 砌成墙。
func _fake_walls() -> Array:
	var walls: Array = []
	for y in range(12):
		var row: Array = []
		for x in range(12):
			row.append(x == 6 and y >= 3 and y <= 8)
		walls.append(row)
	return walls


## 返回值故意不写类型：探针要直接调分离层的内部方法（_move/_can_stand），
## 写成 Node 会让分析器按 Node 的接口判，认不出这些方法。
func _mk_sep():
	var sep = load(SEP_SCRIPT).new()
	sep.name = "Sep"
	add_child(sep)
	sep.setup({"walls": _fake_walls()})
	return sep


## 造一个假单位（Area2D + 进组）。dying=true 时挂一段带 _dying 的脚本，
## 用来验"死亡淡出的单位不参与分离"。
func _mk_unit(pos: Vector2, group: StringName, dying := false) -> Node2D:
	var n: Node2D = Area2D.new()
	if dying:
		var s := GDScript.new()
		s.source_code = "extends Area2D\nvar _dying := true\n"
		if s.reload() == OK:
			n.set_script(s)
	n.position = pos
	n.add_to_group(group)
	add_child(n)
	return n


## 先丢掉分离层再丢单位：分离层每物理帧都在推，留着它，await 的那几帧还会继续挪这些
## 单位；而 in-tree 节点也不能直接 free()，只能 queue_free。
func _free(nodes: Array, sep = null) -> void:
	if sep != null:
		sep.queue_free()
	for nd in nodes:
		(nd as Node).queue_free()
	for _i in range(3):
		await get_tree().process_frame


func _dist(a: Node2D, b: Node2D) -> float:
	return a.global_position.distance_to(b.global_position)


## 没有 _dying 这个属性的节点算"活着"：GDScript 的 get() 只收一个参数，
## 取不到就返回 null，而 bool(null) 会直接报错。
func _dying(n: Object) -> bool:
	var v = n.get("_dying")
	return v != null and bool(v)


func _section_b() -> void:
	_say("")
	_say("--- B 段：分离层纯逻辑 ---")
	var tile := float(_tile())
	var r := float(Config.get_value("combat.separation.radius_px.enemies", 22.0))
	var touch := r * 2.0

	# 1) 重叠 → 一帧就推开，连推到不再重叠
	var sep = _mk_sep()
	var a := _mk_unit(Vector2(tile * 3.0, tile * 3.0), &"enemies")
	var b := _mk_unit(Vector2(tile * 3.0 + r, tile * 3.0), &"enemies")   # 重叠一半
	var d0 := _dist(a, b)
	sep._physics_process(0.016)
	var d1 := _dist(a, b)
	_check(d1 > d0, "两个重叠敌人一帧内就被推开（%.1f → %.1f px）" % [d0, d1])
	for _i in range(60):
		sep._physics_process(0.016)
	var d2 := _dist(a, b)
	_check(d2 >= touch - 1.0, "连推 60 帧后分到不再重叠（%.1f ≥ %.1f）" % [d2, touch])
	await _free([a, b], sep)

	# 2) 完全重合也要岔开（法向算不出来的退化情形）
	sep = _mk_sep()
	var o1 := _mk_unit(Vector2(tile * 7.0, tile * 7.0), &"enemies")
	var o2 := _mk_unit(Vector2(tile * 7.0, tile * 7.0), &"enemies")
	sep._physics_process(0.016)
	_check(_dist(o1, o2) > 0.0, "两点完全重合时也能岔开（实得 %.2f px）" % _dist(o1, o2))
	await _free([o1, o2], sep)

	# 3) 距离够远 → 一动不动
	sep = _mk_sep()
	var f1 := _mk_unit(Vector2(tile, tile), &"enemies")
	var f2 := _mk_unit(Vector2(float(tile) + touch + 200.0, float(tile)), &"enemies")
	var fp1: Vector2 = f1.global_position
	var fp2: Vector2 = f2.global_position
	for _i in range(10):
		sep._physics_process(0.016)
	_check(f1.global_position == fp1 and f2.global_position == fp2,
			"没有重叠的单位绝不被动（分离层不自己造位移）")

	# 4) 玩家是不可动的墙
	var pr := float(Config.get_value("combat.separation.radius_px.player", 20.0))
	var pl := _mk_unit(Vector2(tile, tile * 5.0), &"player")
	var pp: Vector2 = pl.global_position
	var near_pos := Vector2(tile + r + pr - 10.0, tile * 5.0)
	var near := _mk_unit(near_pos, &"enemies")
	sep._physics_process(0.016)
	_check(pl.global_position == pp, "玩家绝不被人群推着走（它是 CharacterBody2D，有自己的寻路）")
	_check(near.global_position != near_pos, "贴着玩家的单位被推开（独自承担整份重叠）")

	# 5) _dying 的单位不参与
	var dying_pos := Vector2(tile, tile * 8.0)
	var dying := _mk_unit(dying_pos, &"enemies", true)
	var pusher := _mk_unit(Vector2(tile + r, tile * 8.0), &"enemies")
	sep._physics_process(0.016)
	_check(dying.global_position == dying_pos, "死亡淡出中的单位不参与分离（尸体不配当碰撞体）")
	await _free([f1, f2, pl, near, dying, pusher], sep)

	# 6) 夹回可走格：直接喂 _move，把动力学和夹子分开判
	_say("")
	_say("  · 夹回可走格（直接测 _move）")
	sep = _mk_sep()
	var u := _mk_unit(Vector2(tile * 5.0 + 50.0, tile * 5.0), &"enemies")
	var dict: Dictionary = {"n": u, "p": u.global_position, "r": r, "movable": true}
	var before: Vector2 = u.global_position
	sep._move(dict, Vector2(tile * 6.0 + 20.0, tile * 5.0))     # 目标落在墙格里
	_check(u.global_position == before,
			"正对墙推 → 一步都不许进墙格（实得 %s）" % str(u.global_position))
	sep._move(dict, Vector2(tile * 6.0 + 20.0, tile * 5.0 + 40.0))   # 斜推：x 被墙挡，y 还能走
	_check(u.global_position.x < tile * 6.0 and u.global_position.y > tile * 5.0,
			"斜推撞墙 → 沿墙滑（x 不进墙、y 照走，实得 %s）" % str(u.global_position))
	_check(sep._can_stand(u.global_position), "滑完之后仍站在可走格上")
	Config.set_override("combat.separation.clamp_to_walkable", false)
	sep._physics_process(0.016)     # 重跑一帧，让 _move 读到新开关
	dict["p"] = u.global_position
	sep._move(dict, Vector2(tile * 6.0 + 20.0, tile * 5.0))
	_check(u.global_position.x > tile * 6.0,
			"关掉 clamp_to_walkable 就真会进墙（证明上面是这道夹子在保护）")
	Config.clear_override("combat.separation.clamp_to_walkable")
	await _free([u], sep)

	# 7) 总开关
	sep = _mk_sep()
	var s1 := _mk_unit(Vector2(tile * 9.0, tile * 9.0), &"enemies")
	var s2 := _mk_unit(Vector2(tile * 9.0 + 10.0, tile * 9.0), &"enemies")
	var sp1: Vector2 = s1.global_position
	Config.set_override("combat.separation.enabled", false)
	for _i in range(10):
		sep._physics_process(0.016)
	_check(s1.global_position == sp1 and s2.global_position == Vector2(tile * 9.0 + 10.0, tile * 9.0),
			"enabled=false → 完全回到老行为（重叠也不推）")
	Config.clear_override("combat.separation.enabled")
	sep._physics_process(0.016)
	_check(s1.global_position != sp1, "开关拨回来立刻又开始推（不用重开一局）")
	await _free([s1, s2], sep)


# ------------------------------------------------------------
func _section_c() -> void:
	_say("")
	_say("--- C 段：真实局里对照（同一坨敌人，开 / 关分离层）---")
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	for _i in range(150):
		await get_tree().process_frame
	var player = get_tree().get_first_node_in_group("player")
	var enemies = get_tree().get_nodes_in_group("enemies")
	_check(enemies.size() >= 8, "场上有足够敌人可测（实得 %d）" % enemies.size())
	_check(player != null, "局里有玩家")
	if enemies.size() < 8 or player == null:
		return
	var sep = main.get_node_or_null("GameRoot/UnitSeparation")
	_check(sep != null, "game_root 下挂着 UnitSeparation")
	if sep == null:
		return
	_check(int(sep.process_priority) > 0,
			"分离层排在移动之后（priority=%d，越大越晚）" % int(sep.process_priority))

	var r := float(Config.get_value("combat.separation.radius_px.enemies", 22.0))
	var crowd: Array = []
	for e in enemies:
		if crowd.size() < 12:
			crowd.append(e)

	# 夹子只保证"分离层不许把人推进墙"，不保证"刷怪器本来就把人放在可走格"。
	# 先记下发局时的越界数，最后判"没变多"，否则生成器的历史问题会算到这一层头上。
	var wall_baseline := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if not sep._can_stand((e as Node2D).global_position):
			wall_baseline += 1
	_say("   发局时已有 %d 个敌人压在墙格里（生成器遗留，不归分离层管）" % wall_baseline)

	# 聚拢点是探针自己传送出来的：它要是落在墙格，后面所有断言都失去意义
	# （分离层从一个非法位置开始推，"推进墙"这件事本来就绕不开）。找一格可站的。
	var home := Vector2.ZERO
	var found := false
	for ring in range(1, 8):
		if found:
			break
		for k in range(12):
			var ang := float(k) * TAU / 12.0
			var cand: Vector2 = player.global_position + Vector2(cos(ang), sin(ang)) * (240.0 + float(ring) * 60.0)
			if sep._can_stand(cand):
				home = cand
				found = true
				break
	_check(found, "在玩家周围找到一个可走格作为聚拢点")
	if not found:
		return

	var off = await _clump(sep, crowd, home, false)
	var off_pairs := _measure_overlap(off, r)
	_check(off_pairs > 0, "关掉分离层时这 %d 个确实叠在一起（重叠对 %d = 对照组有效）" % [
		crowd.size(), off_pairs])
	var on = await _clump(sep, crowd, home, true)
	var on_pairs := _measure_overlap(on, r)
	_check(on_pairs < off_pairs, "开着分离层，同一坨的重叠对变少（%d → %d）" % [
		off_pairs, on_pairs])
	_say("   （开/关各自快照 %d / %d 个单位，深重叠阈值 %.0f px）" % [
		on.size(), off.size(), r * 2.0 * 0.8])
	_check(on_pairs == 0, "开分离层后这坨里已没有深重叠对（实得 %d）" % on_pairs)

	# 夹子的真实局保证：跑完一圈，压在墙格里的敌人数不许比开局多。
	var inside := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if not sep._can_stand(e.global_position):
			inside += 1
	_check(inside <= wall_baseline,
			"分离层没把任何敌人推进墙格（开局 %d → 现在 %d）" % [wall_baseline, inside])


## 把 crowd 全塞到 home 这一点，按开关跑 1 秒，返回结束时的位置快照。
func _clump(sep, crowd: Array, home: Vector2, enabled: bool) -> Array:
	Config.set_override("combat.separation.enabled", enabled)
	for e in crowd:
		if is_instance_valid(e):
			(e as Node2D).global_position = home
	for _i in range(60):
		await get_tree().physics_frame
	var snap: Array = []
	for e in crowd:
		# 只数还活着的：淡出中的尸体不参与分离，把它们算进"重叠"会得到假 FAIL
		if is_instance_valid(e) and _dying(e) == false:
			snap.append((e as Node2D).global_position)
	return snap


## 重叠对数：圆心距 < (r_a+r_b) 的八成 —— 只看"确实叠在一起"的，
## 擦边不算（擦边是分离层的正常余量）。
func _measure_overlap(snap: Array, r: float) -> int:
	var n := 0
	var limit := r * 2.0 * 0.8
	for i in range(snap.size()):
		for j in range(i + 1, snap.size()):
			if (snap[i] as Vector2).distance_to(snap[j]) < limit:
				n += 1
	return n

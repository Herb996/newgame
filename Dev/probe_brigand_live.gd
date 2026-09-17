extends Node
## ============================================================
## probe_brigand_live — 劫掠者（满地图游走 + 成群）在**真实 Main.tscn** 里的端到端冒烟
##
## 与 probe_brigand_ai 的分工：那个用自建空网格逐条单测；这个只回答
## 「真进一局（真地图：有树、有石头、有水的墙格）之后：
##   ① 劫掠者挑的『满地图』目标是不是真的可达、真的远（空网格上能跑不代表真地图上能跑）；
##   ② 两只劫掠者靠近后会不会真的并成一个群、并且不超过 5 只；
##   ③ 别的兵种有没有被带偏（仍旧只在出生点那一小片里晃）」。
##
## 环境干预：本机 user://settings.json 把 enemy.count 设成 0，这里临时顶到 90
## 让敌人刷得出来（不写盘、不动用户设置），结束时清掉。
## 注：真场景里玩家小队会自己开火，测期间把玩家冻住（不然被验的怪会被打死）。
## ============================================================

const OUT := "user://_probe_brigand_live.txt"
const COUNT := 90

var _lines: Array = []
var _n := 0
var _fails: Array = []


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _end_of_path(e) -> Vector2:
	var p = e.get("_path")
	if p is PackedVector2Array and (p as PackedVector2Array).size() > 0:
		return (p as PackedVector2Array)[(p as PackedVector2Array).size() - 1]
	return Vector2.ZERO


func _ready() -> void:
	Config.set_override("enemy.count", COUNT)
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	main._enter_base()
	await _frames(6)
	main._on_launch([{"id": "archer", "name": "弓兵"}])
	await _frames(60)

	# 玩家冻住：自动战斗会自己索敌开火，被验的怪会被打死
	for pl in get_tree().get_nodes_in_group("player"):
		pl.set_physics_process(false)

	_say("=== 实机（Main.tscn）冒烟：劫掠者 ===")
	var all: Array = get_tree().get_nodes_in_group("enemies")
	var brigands: Array = []
	var raiders: Array = []
	for e in all:
		if not e.has_method("roam_mode"):
			continue
		if str(e.get("type_id")) == "brigand":
			brigands.append(e)
		elif str(e.get("type_id")) == "raider":
			raiders.append(e)
	_say("  场上敌人 %d｜劫掠者 %d｜弓手 %d" % [all.size(), brigands.size(), raiders.size()])
	_check(all.size() > 0, "进局后敌人刷出来了（%d 个）" % all.size())
	_check(brigands.size() >= 6, "劫掠者 ≥ 6 只（实得 %d，成群测试要用）" % brigands.size())
	if brigands.size() < 6 or raiders.is_empty():
		Config.clear_override("enemy.count")
		_finish()
		return

	# --- ① 满地图目标：真地图上可达 + 够远 ---
	var b0 = brigands[0]
	b0.set_physics_process(false)
	_check(b0.roam_mode() == "whole_map", "劫掠者的 roam.mode = whole_map")
	_check(is_equal_approx(b0.noise_sensitivity(), 1.8),
			"劫掠者的听力倍率 = %.2f" % b0.noise_sensitivity())
	_check(b0.pack_enabled() and b0.pack_size() >= 1,
			"劫掠者一出生就有群（群内 %d 只）" % int(b0.pack_size()))
	var min_d := 400.0
	var tries := 24
	var ok_far := 0
	var sum_d := 0.0
	var max_d := 0.0
	var start: Vector2 = b0.global_position
	for _i in range(tries):
		b0.clear_move_target()
		b0.pick_patrol_target()
		if not b0.has_move_target():
			continue
		var d := _end_of_path(b0).distance_to(start)
		sum_d += d
		max_d = maxf(max_d, d)
		if d >= min_d - 1.0:
			ok_far += 1
	_check(ok_far >= int(float(tries) * 0.75),
			"真地图上 %d 次选点有 %d 次挑到 %.0fpx 之外（其余是抽到不可达的水中小块）"
			% [tries, ok_far, min_d])
	_check(max_d > 1500.0, "最远一次目标 %.0fpx（真的是跨地图，不是原地打转）" % max_d)

	# --- ③ 别的兵种没被带偏 ---
	var r0 = raiders[0]
	r0.set_physics_process(false)
	_check(r0.roam_mode() == "home_radius", "弓手仍是 home_radius")
	_check(is_equal_approx(r0.noise_sensitivity(), 1.0),
			"弓手的听力倍率 = %.2f（没被劫掠者带偏）" % r0.noise_sensitivity())
	var r_start: Vector2 = r0.global_position
	var r_out := 0
	for _i in range(12):
		r0.clear_move_target()
		r0.pick_patrol_target()
		if r0.has_move_target() and _end_of_path(r0).distance_to(r_start) > 6.0 * 64.0 * 1.45:
			r_out += 1
	_check(r_out == 0, "弓手 12 次选点全在出生点那一小片里（越界 %d 次）" % r_out)

	# --- ② 成群：把 6 只搬到同一处，手动驱动扫描 ---
	var gather: Array = brigands.slice(0, 6)
	var spot: Vector2 = gather[0].global_position
	for i in range(gather.size()):
		var e = gather[i]
		e.set_physics_process(false)
		e.global_position = spot + Vector2(float(i) * 40.0, 0.0)
	for _round in range(20):
		for e in gather:
			e._pack_scan_timer = 999.0
			e._tick_pack(0.6)
	var max_size := 0
	var seen: Array = []
	for e in gather:
		max_size = maxi(max_size, int(e.pack_size()))
		var pd = e.pack_dict()
		var found := false
		for s in seen:
			if s == pd:
				found = true
				break
		if not found:
			seen.append(pd)
	_say("  聚在一起的 6 只 → 最大群 %d 只，共 %d 个群" % [max_size, seen.size()])
	_check(max_size >= 3, "凑到一起会并群（最大群 %d 只）" % max_size)
	_check(max_size <= 5, "没有任何一群超过 5（最大 %d 只）" % max_size)
	_check(seen.size() <= 3, "群数明显少于人数（%d 个群 / 6 只）" % seen.size())
	var big: Node2D = null
	for e in gather:
		if int(e.pack_size()) == max_size and big == null:
			big = e
	var same_leader := true
	if big != null:
		for m in big.pack_members():
			if m.pack_leader() != big.pack_leader():
				same_leader = false
	_check(same_leader, "同群成员认同一个群主（全群共用同一份群字典）")

	# --- ④ 真地图上真的在走（防止「满地图游走」被墙卡死、或原地抖） ---
	# 用没被上面冻住/搬动过的劫掠者；休眠（离玩家 > 活跃半径 48 格）的跳过。
	var movers: Array = []
	for e in brigands.slice(6, brigands.size()):
		if bool(e.get("_dormant")):
			continue
		movers.append(e)
		if movers.size() >= 5:
			break
	_check(movers.size() >= 3, "找到 %d 只活跃的劫掠者（休眠的不算）" % movers.size())
	if movers.is_empty():
		Config.clear_override("enemy.count")
		_finish()
		return
	var starts: Array = []
	for e in movers:
		starts.append(e.global_position)
	await _frames(240)                       # 240 个 process 帧（无头下不保证等于 4 秒，够走一段就行）
	var moved := 0
	var max_move := 0.0
	for i in range(movers.size()):
		var dm: float = movers[i].global_position.distance_to(starts[i])
		max_move = maxf(max_move, dm)
		if dm > 64.0:
			moved += 1
	_check(moved >= maxi(1, movers.size() - 1),
			"240 帧里 %d/%d 只真的挪了地方（最远 %.0fpx；0 = 被墙卡死或原地抖）"
			% [moved, movers.size(), max_move])

	Config.clear_override("enemy.count")
	_finish()


func _finish() -> void:
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_brigand_live] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

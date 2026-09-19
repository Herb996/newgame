extends Node
## ============================================================
## probe_move_giveup — 多选下令"有人一直在跑"的修复验证
##
## 症状：框选几个角色一起点地面，先到的站在目标格里，后到的被同伴身体挡住
## （两个半径 16 的圆最多贴近到 32px），那一格可能永远踩不进去；而它每帧都在
## 侧滑/换格，旧版唯一的兜底 stall 计数要求"这一帧几乎没挪动（<0.2px）"、
## 且每次换格重算都会把它清零 → 永不触发 → 指令永远不结束。
##
## 三段分别判：
##   A) config 结构：附近半径必须 > 两个身体的最近圆心距（32px），否则这条规则
##      永远不会被触发（等于没写）；耐心帧数不能短到把一次正常绕路误判成受阻。
##   B) 真实场景 A/B：4 个角色点同一个地方，只拨 blocked_give_up_frames ——
##      极大 = 旧行为（复现"有人一直在跑"），默认 = 没人再挂着指令。
##      没有这个对照组，"都停了"可能只是运气好，说明不了是这条规则救的。
##   C) 不误伤：一个人、路通畅、目标很远 → 只能因为"真进了目标格"而停。
##
## 跑法：python tools/run_probe.py _probe_giveup.log res://Dev/probe_move_giveup.tscn
## ============================================================

const OUT := "user://_probe_move_giveup.txt"
const BODY_R := 16.0          # Scenes/Player.tscn 里身体的圆碰撞半径
const IDS := ["spearman", "archer", "swordsman", "monk"]

var _main: Node
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
	_say("=== probe_move_giveup ===")
	_section_a()
	await _setup_run()
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
	print("[GiveupProbe] 通过 %d / %d" % [_n - _fails.size(), _n])
	print("[GiveupProbe] fails=%d -> %s" % [_fails.size(), "PASS" if _fails.is_empty() else "FAIL"])
	get_tree().quit(0 if _fails.is_empty() else 1)


# ------------------------------------------------------------
func _section_a() -> void:
	_say("--- A 段：config 结构 ---")
	var tile := float(Config.get_value("map.tile_size", 64))
	var near := float(Config.get_value("player.blocked_give_up_radius_px", -1.0))
	var touch := BODY_R * 2.0
	# 半径小于"两个身体贴在一起的圆心距"，被挡住的人永远不算"在目标附近"→ 规则形同虚设
	_check(near > touch, "附近半径 %.0f > 两身体最近圆心距 %.0f（否则这条规则永远不触发）" % [
			near, touch])
	# 一个人挡不住时后面还排着第二圈：半径至少要容得下两圈身体，否则外层的人照样永远跑
	_check(near >= touch * 3.0, "附近半径 %.0f ≥ 三圈身体 %.0f（第 3、4 名也要算'到了'）" % [
			near, touch * 3.0])
	_check(near <= tile * 3.0, "附近半径 %.0f ≤ 三格 %.0f（再大就是没到就停 = 假到达）" % [near, tile * 3.0])
	var patience := int(Config.get_value("player.blocked_give_up_frames", -1))
	# 一次正常接近里的瞬时绕路/减速不该被当成"受阻"，所以耐心要有几十帧
	_check(patience >= 10, "受阻窗口 %d 帧 ≥ 10（约 %.2f 秒，太短会误判瞬时绕路）" % [
			patience, float(patience) / 60.0])
	_check(patience <= 180, "受阻窗口 %d 帧 ≤ 180（超过 3 秒才停，玩家会觉得它坏了）" % patience)
	# 放行余量必须是"自由移动一个窗口能走的距离"的零头，否则正常赶路也会被掐
	var budget := float(Config.get_value("player.speed", 640.0)) / 60.0 * float(patience)
	var gain := float(Config.get_value("player.blocked_give_up_progress_px", -1.0))
	_check(gain > 0.0 and gain <= budget * 0.25,
			"放行余量 %.0f px ≤ 一窗口能走的 %.0f px 的 1/4（否则等于把正常绕路也判成受阻）" % [gain, budget])


func _alive_players() -> Array:
	var out: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and not bool(p.call("is_dead")):
			out.append(p)
	return out


func _setup_run() -> void:
	_say("")
	_say("--- 开局：招 4 名角色 ---")
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child(_main)
	await _frames(30)
	# 自动交战会把赶路的人拽进对砍，对砍会改位置/改状态，B/C 两段就没法判了
	Config.set_override("combat.auto_attack.enabled", false)
	var roster: Array = []
	for id in IDS:
		roster.append({"id": id, "name": id})
	_main.call("_on_launch", roster)
	var waited := 0
	while _alive_players().size() < IDS.size() and waited < 600:
		await get_tree().process_frame
		waited += 1
	await _frames(60)
	_check(_alive_players().size() >= 2, "拿到 %d 名角色（多选才测得出互相挡）" % _alive_players().size())


## 把 4 个人拉开站成一排：挤在一起开局就等于已经互相挡着，测不出"走到目标后被挡"。
## 站位要吸附到可走格（并且不重复）—— 直接 teleport 进树丛会先触发出一轮脱困逻辑，
## 测的就不是"到目标附近受阻"了。
func _spread(ps: Array, origin: Vector2) -> Array:
	var tile := float(Config.get_value("map.tile_size", 64))
	var used: Array = []
	for i in range(ps.size()):
		var p: Node = ps[i]
		var cell: Vector2i = p.call("_cell_of", origin + Vector2(float(i) * 80.0, 0.0))
		var open: Vector2i = p.call("_goal_cell", cell)
		var guard := 0
		while used.has(open) and guard < 32:
			cell = cell + Vector2i(1, 0)   # 这格被占了 → 沿排的方向再挪一格
			open = p.call("_goal_cell", cell)
			guard += 1
		used.append(open)
		(p as Node2D).global_position = Vector2(open.x * tile + tile * 0.5, open.y * tile + tile * 0.5)
		p.call("_clear_path_cache")
	await _pframes(10)
	return used


## 真实场景跑一遍：4 人点同一个地方，返回 {still_running, alive, walked, target}
func _run_squad(patience: int, frames_after_order: int) -> Dictionary:
	Config.set_override("player.blocked_give_up_frames", patience)
	var ps := _alive_players()
	var origin: Vector2 = (ps[0] as Node2D).global_position
	var cells: Array = await _spread(ps, origin)
	var target := _pick_target(ps[0])
	var starts: Array = []
	for p in ps:
		starts.append((p as Node2D).global_position)
	for p in ps:
		p.call("command_click", target)
	await _pframes(20)
	var walking := 0
	for i in range(ps.size()):
		if is_instance_valid(ps[i]) and (ps[i] as Node2D).global_position.distance_to(starts[i]) > 20.0:
			walking += 1
	for _i in range(frames_after_order - 20):
		await get_tree().physics_frame
	var alive := 0
	var still := 0
	for p in ps:
		if not is_instance_valid(p) or bool(p.call("is_dead")):
			continue
		alive += 1
		if bool(p.call("has_move_target")):
			still += 1
	Config.clear_override("player.blocked_give_up_frames")
	return {"still": still, "alive": alive, "walking": walking, "target": target, "squad": ps,
			"cells": cells, "diag": _diag(ps, target)}


## 每个角色一行：离目标多远 + 规则自己的窗口状态。FAIL 时要能看出是"没进半径"
## 还是"窗口攒不满"，否则只能瞎猜再跑一轮（一轮好几分钟）。
func _diag(ps: Array, target: Vector2) -> Array:
	var out: Array = []
	for p in ps:
		if not is_instance_valid(p):
			out.append("   [已失效]")
			continue
		var d: float = (p as Node2D).global_position.distance_to(target)
		out.append("   离目标 %6.1f  指令%s  窗口 %d 帧  本窗最近 %s  上窗最近 %s" % [
				d,
				"挂着" if bool(p.call("has_move_target")) else "已了结",
				int(p.get("_goal_win_frames")),
				_fmt(p.get("_goal_win_min")),
				_fmt(p.get("_goal_prev_min"))])
	return out


## INF（这一窗还没统计过）直接 %.1f 打出来是 "inf"，读日志时容易当成 0，故换行破折号。
func _fmt(v) -> String:
	var f := float(v)
	return "  —  " if is_inf(f) else "%.1f" % f


func _section_b() -> void:
	_say("")
	_say("--- B 段：4 人同点，只拨 blocked_give_up_frames ---")
	if _alive_players().size() < 2:
		_say("   [跳过] 角色不足")
		return
	# 负对照 = 旧行为：耐心拉到极大，等于这条规则不存在
	var old = await _run_squad(1000000, 420)
	_say("   [负对照/旧行为] 每角色结束状态：")
	for s in (old["diag"] as Array):
		_say(s)
	_check(_cells_distinct(old["cells"]), "开局站位有效：%s（都占自己的可走格，不是叠成一坨）" % str(old["cells"]))
	_check(int(old["walking"]) >= 2, "下令后 %d 个角色确实在移动（否则'都停了'是因为压根没动）" % int(old["walking"]))
	_check(int(old["still"]) > 0,
			"负对照：旧行为下 420 帧后仍有 %d/%d 人挂着移动指令（复现'有人一直在跑'）" % [
					int(old["still"]), int(old["alive"])])
	var fixed = await _run_squad(int(Config.get_value("player.blocked_give_up_frames", 45)), 420)
	_say("   [默认参数] 每角色结束状态：")
	for s in (fixed["diag"] as Array):
		_say(s)
	_check(int(fixed["still"]) == 0,
			"默认窗口下同样 420 帧，没人再挂着指令（旧 %d → 新 %d）" % [int(old["still"]), int(fixed["still"])])
	_check(int(fixed["alive"]) >= 2, "对照有效：结束时仍有 %d 个活人可判（不是全死了才'停'的）" % int(fixed["alive"]))
	var far := 0
	var t: Vector2 = fixed["target"]
	var bound := float(Config.get_value("player.blocked_give_up_radius_px", 128.0)) + float(
			Config.get_value("map.tile_size", 64))
	for p in (fixed["squad"] as Array):
		if is_instance_valid(p) and not bool(p.call("is_dead")):
			if (p as Node2D).global_position.distance_to(t) > bound:
				far += 1
	_check(far == 0, "停下的人都在目标附近（离目标 >%.0fpx 的有 %d 个）" % [bound, far])


## 开局站位是否有效：每个人各占一格、而且那一格确实可走（吸附后没被挪到别处）。
func _cells_distinct(cells: Array) -> bool:
	if cells.size() != IDS.size():
		return false
	for c in cells:
		if c.x < 0 or c.y < 0:
			return false
		if cells.count(c) > 1:
			return false
	return true


## 找一个离出发点足够远、且本身就是可走格的目标点（4 人都点它的格心）
func _pick_target(p: Node) -> Vector2:
	var tile := float(Config.get_value("map.tile_size", 64))
	for ring in range(1, 12):
		for k in range(16):
			var ang := float(k) * TAU / 16.0
			var cand: Vector2 = (p as Node2D).global_position + Vector2(cos(ang), sin(ang)) * (360.0 + float(ring) * 60.0)
			var cell: Vector2i = p.call("_cell_of", cand)
			if int(p.call("_goal_cell", cell).x) == cell.x and int(p.call("_goal_cell", cell).y) == cell.y:
				var half := tile * 0.5
				return Vector2(float(cell.x) * tile + half, float(cell.y) * tile + half)
	var tile2 := float(Config.get_value("map.tile_size", 64))
	return (p as Node2D).global_position + Vector2(tile2 * 6.0, 0.0)


func _section_c() -> void:
	_say("")
	_say("--- C 段：路通畅时不许提前停（防误伤）---")
	var ps := _alive_players()
	if ps.size() < 1:
		_say("   [跳过] 没有角色")
		return
	var p: Node = ps[0]
	# 其它队友挪远一点：这一段只验"正常赶路一定赶完"，不该有人挡路
	for i in range(1, ps.size()):
		(ps[i] as Node2D).global_position = (p as Node2D).global_position + Vector2(0.0, -600.0)
	await _pframes(10)
	var target := _pick_target(p)
	var want_cell: Vector2i = p.call("_goal_cell", p.call("_cell_of", target))
	p.call("command_click", target)
	var guard := 0
	while bool(p.call("has_move_target")) and guard < 900:
		await get_tree().physics_frame
		guard += 1
	_check(guard < 900, "赶路在 %d 帧内结束（没有永远跑下去）" % guard)
	var end_cell: Vector2i = p.call("_cell_of", p.global_position)
	_check(end_cell == want_cell,
			"结束是因为真踩进了目标格（%s == %s），不是被'受阻'提前掐掉" % [str(end_cell), str(want_cell)])


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _pframes(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame

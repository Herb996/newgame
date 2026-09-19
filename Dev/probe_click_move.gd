extends Node
## ============================================================
## probe_click_move — 复现「选中角色后左键点地移动，点十几次就控制不了」
##
## 三段，全部走**真实输入管线**（get_viewport().push_input 合成左右键），
## 因为「点了没反应」的根因可能就在事件分发那一层，直接调函数验不出来。
##
##   A) 连点 CLICKS 次：落点只从**可走格**里挑（enemy.count 临时置 0）。
##      这样"没走到"就只剩一个含义 —— 指令被吞或人卡死，不再和
##      「点了密林正中央（按设计会放弃指令）」「半路停下来打架」混在一起。
##      任一次失败都记诊断（状态机状态 / 有没有移动目标 / 所在格是否障碍 /
##      缓存路径长度 / 是否仍被选中）。
##   B) 脱困保证：把角色放到一块「四周 4 格内没有可走格」的实心区中心，
##      再点一次地面 —— 无论如何都得能动（这一条是"永不失控"的底线）。
##   C) 指令存活：自动战斗起手（attack.enter 会 halt_in_place）之后，
##      玩家刚下的移动指令不该被抹掉，打完这一刀要能继续赶路。
##
## ⚠ 会写 user://save.json（出击），开跑备份、收尾原样还原。
## ============================================================

const OUT := "user://_probe_click_move.txt"
const SAVE_PATH := "user://save.json"
const CLICKS := 16
const ARRIVE_DIST := 44.0           # 约 1/3 格：算走到点击点附近
const STALL_FRAMES := 90            # 连续这么久没挪动 = 这一条指令已经废了
const TRACE_LEN := 40               # 失败时回吐最后多少帧

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _save_backup := ""
var _save_existed := false
var _trace: Array = []              # 最近 TRACE_LEN 帧的逐帧读数（只在失败时写进报告）
var _visits := {}                   # 本次等待里「进入某格多少次」（绕圈证据）
var _last_cell_key := ""            # 上一帧所在格，用来识别"进格"这一动作
var _last_target := Vector2.INF

var _p: Node = null
var _cam: Node = null
var _rng := RandomNumberGenerator.new()


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


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()
	_rng.seed = 20260919
	seed(20260919)   # Array.shuffle() 用的是全局随机数，不种一次每次点到的格都不一样
	# 无头驱动给的视口是退化的 64×64：合成点击的屏幕坐标会被夹回视口里，
	# 落点全跑到角色脚下（指令"秒到达"被清），A 段整个失去意义 —— 而回归只跑无头。
	# 所以这里先把窗口撑到真实尺寸，再加载 Main（相机限位按视口算，顺序反了就白撑）。
	var win: Window = get_tree().root
	if win.size.x < 400.0 or win.size.y < 400.0:
		win.size = Vector2i(1280, 720)
		await _frames(2)

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	Meta.roster = []
	Meta.seeded_ids = []
	Meta.ensure_roster()
	# A 段问的是"点了动不动"，不是"打不打得过"：清场，免得半路停下打架被算成失控。
	Config.set_override("enemy.count", 0)
	Config.set_override("animals.count", 0)   # 60 只动物在 128×256 的图上跑，会把探针的墙钟吃掉
	main.call("_on_launch", [{"uid": int(Meta.roster[0].get("uid", 0)),
			"id": "spearman", "name": "枪手", "level": 0}])
	var waited := 0
	while get_tree().get_nodes_in_group("player").is_empty() and waited < 400:
		await get_tree().process_frame
		waited += 1
	var players := await _settle_players()
	if players.is_empty():
		_say("!! 没生成玩家")
		_finish()
		return
	_p = players[0]
	var cams := get_tree().get_nodes_in_group("iso_cam")
	_cam = cams[0] if not cams.is_empty() else null
	if _cam != null:
		_cam.set("edge_pan_enabled", false)   # 自动化时光标会触发边缘滚屏
	_p.call("select")
	# 血量顶满：探针要验的是「点了动不动」，不能因为角色半路阵亡而全体变死状态
	_p.set("max_hp", 100000)
	_p.set("hp", 100000)
	_say("--- 前置 ---")
	_say("  [诊断] 视口=%s config.player.speed=%s speed=%s traits=%s supply_penalties=%s" % [
			str(main.get_viewport().get_visible_rect().size),
			str(Config.get_value("player.speed", 0.0)), str(_p.get("speed")),
			str(_p.get("traits")), str(_p.get("supply_penalties"))])
	_check(_p != null, "拿到角色 %s" % str(_p.get("name")))
	_check(bool(_p.get("selected")), "角色处于选中状态（左键下令只发给选中的）")

	await _a_repeated_clicks()
	await _b_unstick()
	await _c_order_survives_attack()
	_finish()


# ------------------------------------------------------------
# A) 连点 CLICKS 次
# ------------------------------------------------------------
func _a_repeated_clicks() -> void:
	_say("--- A 段：连续 %d 次左键点地（落点全取可走且可达的格）---" % CLICKS)
	var dead := 0
	for i in range(CLICKS):
		var start: Vector2 = _p.global_position
		await _sync_cam()
		var cell_stats := {}
		var cell := _open_cell_near(start, 6, 16, true, cell_stats)
		if cell.x < 0:
			var xf: Transform2D = get_viewport().get_canvas_transform()
			# ⚠ 整条格式串先括号起来再 %：% 比 + 结合更紧，写成 "a" + "b%s" % [..]
			#    只会把参数喂给中间那段，报 "not all arguments converted"。
			_check(false, ("A 角色周围 6~16 格内找不到「可走 + 可达 + 落在地图区」的格"
					+ "，无法继续复现（%s｜相机 %s pos=%s zoom=%s offset=%s anchor=%s"
					+ " enabled=%s｜xf=%s｜角色投影 %s → %s，地图区 %s）") % [
					str(cell_stats),
					str(_cam),
					str(_cam.global_position) if _cam != null else "-",
					str(_cam.zoom) if _cam != null else "-",
					str(_cam.offset) if _cam != null else "-",
					str(_cam.anchor_mode) if _cam != null else "-",
					str(_cam.enabled) if _cam != null else "-",
					str(xf), str(start), str(xf * start), str(_map_band())])
			return
		var target := _center_of(cell)
		var screen: Vector2 = _send_click(target)
		var xf_send: Transform2D = get_viewport().get_canvas_transform()
		var cam_send: Vector2 = _cam.global_position if _cam != null else Vector2.INF
		await _frames(2)
		var why := ""
		if not bool(_p.call("has_move_target")):
			why = "指令未被受理"
		else:
			why = await _wait_for_arrival(start, target)
		if why != "":
			dead += 1
			_last_target = target
			_say("  第 %2d 次点击 %s 目标%s" % [i + 1, why, str(target)])
			# 同一个屏幕点，发出时和出事时各反算一次世界坐标：
			# 两个都 ≠ 目标点 → 相机在这几帧里把落点搬走了（真·点了没反应）；
			# 发出时那个正好等于目标点、出事时不等于 → 只是探针读到的变换陈旧。
			var xf_now: Transform2D = get_viewport().get_canvas_transform()
			_say("       [换算] 屏=%s 发出时逆变换=%s 现在逆变换=%s 相机 %s→%s" % [
					str(screen), str(xf_send.affine_inverse() * screen),
					str(xf_now.affine_inverse() * screen), str(cam_send),
					str(_cam.global_position if _cam != null else Vector2.INF)])
			_say("       " + _diag())
			_dump_trace()
	_check(dead == 0, "%d 次点击全部走到（失败 %d 次）" % [CLICKS, dead])


## 等这一次点击走完。返回 ""＝正常走完；其余字符串＝失败原因（直接写进报告）。
func _wait_for_arrival(start: Vector2, target: Vector2) -> String:
	var budget := _frame_budget(start, target)
	var moved := 0.0
	var walked := 0.0
	var stuck := 0
	var last: Vector2 = start
	_visits = {}                          # 格 → 进入过多少次（绕圈的直接证据）
	_last_cell_key = "%d,%d" % [_cell_of(start).x, _cell_of(start).y]
	_trace = []
	for frames_used in range(budget):
		# 物理帧：移动是在 _physics_process 里做的，无头的 _process 能跑到几百 fps，
		# 按渲染帧计预算会让"够不够时间走到"完全失真。
		await get_tree().physics_frame
		moved = maxf(moved, start.distance_to(_p.global_position))
		var step: float = last.distance_to(_p.global_position)
		walked += step
		var cell := _cell_of(_p.global_position)
		var key := "%d,%d" % [cell.x, cell.y]
		if key != _last_cell_key:          # 只数"进格"，不数"在格里待了几帧"
			_visits[key] = int(_visits.get(key, 0)) + 1
			_last_cell_key = key
		if step < 0.5:
			stuck += 1
		else:
			stuck = 0
		last = _p.global_position
		_trace.append("f%-4d 格%s idx=%d 距路点=%6.1f 距终点=%6.1f 本帧挪=%.2f 卡=%d" % [
				frames_used, str(_cell_of(last)), int(_p.get("_path_index")),
				_dist_to_waypoint(last), last.distance_to(target), step, stuck])
		if _trace.size() > TRACE_LEN:
			_trace.pop_front()
		if last.distance_to(target) < ARRIVE_DIST:
			return ""
		if stuck >= STALL_FRAMES:
			return "原地卡死（%d 帧没挪过 0.5px）" % stuck
		if not bool(_p.call("has_move_target")):
			return "没到就把指令丢了（还差 %.0fpx，走了 %.0fpx / %d 帧）" % [
					last.distance_to(target), moved, frames_used]
	return "预算内没走到（还差 %.0fpx，位移 %.0fpx / 实走 %.0fpx / %d 帧）" % [
			last.distance_to(target), moved, walked, budget]


## 角色此刻正追的那个路点有多远 —— 绕圈/贴角卡死的直接读数。
func _dist_to_waypoint(pos: Vector2) -> float:
	var cp: PackedVector2Array = _p.get("_cached_path")
	var i: int = int(_p.get("_path_index"))
	if i < 0 or i >= cp.size():
		return -1.0
	return pos.distance_to(cp[i])


func _cell_of(pos: Vector2) -> Vector2i:
	var tile: int = int(_p.get("_tile_size"))
	return Vector2i(int(pos.x / tile), int(pos.y / tile))


## 失败时把最后 TRACE_LEN 帧贴进报告：光看"还差 179px"分不出是绕圈、
## 贴角蹭墙，还是预算给少了 —— 只有逐帧的"距路点"曲线能说明是哪种。
func _dump_trace() -> void:
	_say("       [尾 %d 帧轨迹] 目标=%s 走过 %d 格" % [_trace.size(), str(_last_target), _visits.size()])
	_say("       [重访榜] " + _top_visits())
	for t in _trace:
		_say("         " + str(t))


## 少数几个格反复进出 = 来回弹（失控）；次数摊在很多格上 = 真在绕障。
func _top_visits() -> String:
	var pairs: Array = []
	for k in _visits:
		pairs.append([k, int(_visits[k])])
	pairs.sort_custom(func(a, b): return int(a[1]) > int(b[1]))
	var out: Array = []
	for i in range(mini(5, pairs.size())):
		out.append("(%s)×%d" % [str(pairs[i][0]), int(pairs[i][1])])
	return " ".join(out)


## 走这一趟给多少物理帧：按**当前实际移速**换算。
## 移速是设置面板里可改的（用户存档 140，出厂 640），写死帧数会让慢速档
## 一律"超时" —— 那是数值选择，不是本探针要抓的失控 bug。
## 优先用角色**当下缓存的 A* 折线**长度（发出点击两帧后它已经算好了）：
## 实测有一趟直线 1.5 格、绕障实走 4.5 格，按直线算 3 倍余量照样撞上限，
## 看起来像"走不到"，其实是预算给少了。直线只当兜底下限。
func _frame_budget(start: Vector2, target: Vector2) -> int:
	var per_frame: float = maxf(float(_p.get("speed")) / 60.0, 1.0)
	var route: float = start.distance_to(target)
	var cp: PackedVector2Array = _p.get("_cached_path")
	if cp.size() >= 2:
		route = 0.0
		for j in range(1, cp.size()):
			route += cp[j - 1].distance_to(cp[j])
	return clampi(int(route * 1.6 / per_frame) + 200, 300, 4000)


# ------------------------------------------------------------
# B) 卡在实心区中心也必须能动
# ------------------------------------------------------------
func _b_unstick() -> void:
	_say("--- B 段：陷入实心区后的脱困底线 ---")
	var walls: Array = _p.get("_walls")
	var tile: int = int(_p.get("_tile_size"))
	var home: Vector2 = _p.global_position
	var trap := _find_deep_solid_cell(walls, maxi(1, int(_p.call("_unstick_radius")) + 1))
	if trap.x < 0:
		_say("       这张地图没有「4 格内无解」的实心区，B 段跳过（换种子或换图再验）")
		return
	var start := Vector2(trap.x * tile + tile * 0.5, trap.y * tile + tile * 0.5)
	_p.global_position = start
	var open_cell := _nearest_open(walls, trap, 40)
	# 落点只能落在**屏幕内**：合成点击走真实输入管线，相机以角色为中心，
	# 几十格外的点换算到屏幕之外，事件根本进不了游戏（那是探针的锅不是 bug）。
	var dir := Vector2(open_cell - trap).normalized()
	var goal := _nearest_open(walls,
			trap + Vector2i(int(round(dir.x * 5.0)), int(round(dir.y * 5.0))), 6)
	if goal.x < 0:
		goal = open_cell
	var target := _center_of(goal)
	await _sync_cam()
	_send_click(target)
	var moved := 0.0
	for _i in range(_frame_budget(start, target)):
		await get_tree().physics_frame
		moved = maxf(moved, start.distance_to(_p.global_position))
		if moved > 30.0:
			break
	_check(moved > 30.0,
			"陷在 (%d,%d) 实心格里点了一下，角色还是挪得动（实得 %.1fpx）" % [trap.x, trap.y, moved])
	_p.global_position = home
	_p.call("cancel_commands")


# ------------------------------------------------------------
# C) 攻击不吃掉移动指令
# ------------------------------------------------------------
func _c_order_survives_attack() -> void:
	_say("--- C 段：自动战斗起手不该吞掉移动指令 ---")
	_p.call("cancel_commands")
	await _frames(2)
	var start: Vector2 = _p.global_position
	# C 段直接下 set_move_target，不经过屏幕点击，落点在不在地图区都无所谓
	var cell := _open_cell_near(start, 6, 12, false)
	if cell.x < 0:
		_check(false, "C 周围找不到可走格，无法验证")
		return
	var target := _center_of(cell)
	_p.call("set_move_target", target)
	_check(bool(_p.call("has_move_target")), "点了地面 → 有移动目标")
	_p.get("state_machine").call("force_transition", &"attack")
	await _frames(3)
	_check(bool(_p.call("has_move_target")),
			"进入 attack 后移动指令还在（实得 %s，状态=%s）"
			% [str(bool(_p.call("has_move_target"))), str(_p.get("state_machine").get_state_name())])
	for _i in range(500):
		await get_tree().process_frame
		if start.distance_to(_p.global_position) > 60.0:
			break
	var went: bool = start.distance_to(_p.global_position) > 60.0
	if not went:
		_say("       " + _diag())
	_check(went, "打完这一刀还能继续赶往刚才那一点（走了 %.0fpx）"
			% start.distance_to(_p.global_position))


# ------------------------------------------------------------
# 工具
# ------------------------------------------------------------
## 把相机挪到角色身上，并**等它真的追上**再返回。
## `get_canvas_transform()` 拿到的是上一帧定格的值：用它推屏幕点、游戏却用新一帧的
## 变换反算回去，落点能飘几百 px —— 偶尔正好落在角色自己脚下，指令当场"已到达"被清，
## 看起来就是"点了没反应"。
## ⚠ 必须等**物理帧**：`camera_controller._physics_process` 才是搬相机的那个人，而无头
## 里渲染帧能跑到几百 fps —— 之前只等 6 个 process_frame，读到的是相机还在半路上的
## 陈旧变换，角色自己都被投影到视口外，A 段于是"满图找不到一个落在地图区的可走格"
## （790 个候选、24 个采样全被判 off_map），红得毫无道理。
func _sync_cam() -> void:
	if _cam != null:
		_cam.global_position = _p.global_position
		_cam.call("reset_smoothing")
	for _i in range(40):
		await get_tree().physics_frame
		if _on_map(_p.global_position):
			return
	_say("  [警告] 40 个物理帧后角色仍在地图区外：pos=%s → 屏=%s（地图区 %s）" % [
			str(_p.global_position),
			str(get_viewport().get_canvas_transform() * _p.global_position),
			str(_map_band())])


## 一次「左键点地」：press + release（SelectionController 是在**松开**时才下
## 指令的，只发按下事件永远不会有反应）。调用前须先 _sync_cam() 选好落点。
func _send_click(world_pos: Vector2) -> Vector2:
	_press(world_pos, true)
	_press(world_pos, false)
	return get_viewport().get_canvas_transform() * world_pos


## 屏幕上的「地图区」= 整块视口减掉底部菜单栏。压在菜单栏上的点击会被它吃掉
## （产品正确行为），探针把落点选在那儿只会测出一场假红。
func _map_band() -> Rect2:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	return Rect2(0.0, 0.0, vp.x, maxf(vp.y - float(UiKit.menu_bar_height(vp.y)), 1.0))


func _on_map(world_pos: Vector2) -> bool:
	return _map_band().has_point(get_viewport().get_canvas_transform() * world_pos)


func _press(world_pos: Vector2, pressed: bool) -> void:
	var screen: Vector2 = get_viewport().get_canvas_transform() * world_pos
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = screen
	ev.global_position = screen
	get_viewport().push_input(ev, true)


## 随机挑一个"离角色 min_c~max_c 格、可走、且**从角色当前格真能规划出路**"的格子。
## 前两条不满足的话 follow_path 会按设计直接放弃指令（点密林正中央），
## 那是产品行为而不是本探针要复现的"失控"。可达性也一样：地图上确实存在
## 与主通路断开的可走孤岛，点进孤岛走不到不是 bug。
## on_map：要走真实点击的调用必须为真 —— 投影落在底部菜单栏上的点会被栏吃掉。
func _open_cell_near(from_pos: Vector2, min_c: int, max_c: int, on_map := true,
		stats = null) -> Vector2i:
	var walls: Array = _p.get("_walls")
	var tile: int = int(_p.get("_tile_size"))
	var astar: AStarGrid2D = _p.get("_astar")
	var h: int = walls.size()
	if h == 0:
		return Vector2i(-1, -1)
	var w: int = walls[0].size()
	var c := Vector2i(int(from_pos.x / tile), int(from_pos.y / tile))
	var cand: Array = []
	for y in range(maxi(1, c.y - max_c), mini(h - 1, c.y + max_c + 1)):
		var row: Array = walls[y]
		for x in range(maxi(1, c.x - max_c), mini(w - 1, c.x + max_c + 1)):
			if bool(row[x]):
				continue
			var d: int = maxi(absi(x - c.x), absi(y - c.y))
			if d < min_c or d > max_c:
				continue
			cand.append(Vector2i(x, y))
	cand.shuffle()
	# ⚠ 默认值不能写 {}：GDScript 的默认实参只求值一次，往里面写会污染所有调用方。
	var st: Dictionary = stats if stats is Dictionary else {}
	if not st.is_empty() or stats is Dictionary:
		st["cand"] = cand.size()
		st["unreachable"] = 0
		st["off_map"] = 0
	# 先按屏幕带筛（一次乘法），再对幸存者做 A*（贵）。反过来会只看前 24 个采样：
	# 6~16 格这一圈里"落在地图区"的本来就只占一小撮，24 个全踩空就会报"找不到格"。
	var on_screen: Array = []
	if on_map:
		for cell: Vector2i in cand:
			if _on_map(_center_of(cell)):
				on_screen.append(cell)
			else:
				st["off_map"] = int(st.get("off_map", 0)) + 1
		st["on_screen"] = on_screen.size()
		cand = on_screen
	for attempt in range(mini(24, cand.size())):
		var cell: Vector2i = cand[attempt]
		if astar != null and astar.get_id_path(c, cell).is_empty():
			st["unreachable"] = int(st.get("unreachable", 0)) + 1
			continue
		return cell
	return Vector2i(-1, -1)


func _center_of(cell: Vector2i) -> Vector2:
	var tile: int = int(_p.get("_tile_size"))
	return Vector2(cell) * float(tile) + Vector2(tile * 0.5, tile * 0.5)


func _diag() -> String:
	var sm: Node = _p.get("state_machine")
	var tile: int = int(_p.get("_tile_size"))
	var pos: Vector2 = _p.global_position
	var cell := Vector2i(int(pos.x / tile), int(pos.y / tile))
	var walls: Array = _p.get("_walls")
	var solid := false
	if cell.y >= 0 and cell.y < walls.size():
		var row: Array = walls[cell.y]
		if cell.x >= 0 and cell.x < row.size():
			solid = bool(row[cell.x])
	return "状态=%s 死亡=%s selected=%s 有移动目标=%s arm_mode=%s 所在格=%s(障碍=%s) 缓存路径=%d/%d 卡住计数=%d/%d | 指令点=%s speed=%.0f 地形=%.2f" % [
		str(sm.get_state_name()), str(bool(_p.call("is_dead"))),
		str(bool(_p.get("selected"))),
		str(bool(_p.call("has_move_target"))), str(_p.get("_arm_mode")),
		str(cell), str(solid),
		(_p.get("_cached_path") as PackedVector2Array).size(),
		int(_p.get("_path_index")),
		int(_p.get("_stall_frames")), int(_p.get("_stall_repaths")),
		str(_p.get("_final_target")),
		float(_p.get("speed")), float(_p.call("current_terrain_speed"))]


## 找一格：本身是实心，且以它为中心 radius 环内**全**是实心（真正的死区）
func _find_deep_solid_cell(walls: Array, radius: int) -> Vector2i:
	var h: int = walls.size()
	for y in range(radius, h - radius):
		var row: Array = walls[y]
		for x in range(radius, row.size() - radius):
			if not bool(row[x]):
				continue
			var deep := true
			for dy in range(-radius, radius + 1):
				for dx in range(-radius, radius + 1):
					var r: Array = walls[y + dy]
					if not bool(r[x + dx]):
						deep = false
						break
				if not deep:
					break
			if deep:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _nearest_open(walls: Array, cell: Vector2i, radius: int) -> Vector2i:
	return MapGenerator.nearest_open_cell(walls, cell, radius)


func _settle_players() -> Array:
	var prev: Dictionary = {}
	var stable := 0
	for _guard in range(400):
		await get_tree().process_frame
		var cur := {}
		for q in get_tree().get_nodes_in_group("player"):
			cur[q.get_instance_id()] = q
		if cur == prev:
			stable += 1
			if stable >= 15:
				break
		else:
			stable = 0
			prev = cur
	var out: Array = []
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q) and not bool(q.is_dead()):
			out.append(q)
	return out


func _backup_save() -> void:
	_save_existed = FileAccess.file_exists(SAVE_PATH)
	if _save_existed:
		_save_backup = FileAccess.get_file_as_string(SAVE_PATH)


func _restore_save() -> void:
	if _save_existed:
		var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_save_backup)
			f.close()
	elif FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))


func _finish() -> void:
	_restore_save()
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for msg in _fails:
		_say("  !! " + msg)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_click_move] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

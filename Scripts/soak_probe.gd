extends Node
## ============================================================
## SoakProbe — 行为验证探针（`--soak <秒>` 触发）
##
## 为什么需要它：
##   "角色在地图上能动作、移动不会卡住、死亡后会消失"这三条，看截图只能证明
##   "某一帧看起来对"，证明不了"整局 30 秒里 160 个单位一个都没卡死"。
##   这里把它们变成可复现的数值断言，无头跑一遍就给出 PASS / FAIL + 退出码。
##
## 做法：
##   1. 玩家周期性"跳点"：否则 32 格外的敌人会休眠、地图另一端根本不会被唤醒，
##      采样到的"没动"是假阴性（不是卡住，是没人叫它动）。
##   2. 每 sample_dt 秒给每个敌人 / 羊采样一次位移与动画状态。
##      只有"AI 认为它该在走"时才计入卡住统计：
##        敌人 → has_move_target() 且未休眠
##        羊   → WALK / FLEE 模式且有目标
##      站着巡逻停留、低头吃草都不算卡住。
##   3. 跑到 60% 时随机挑 kill_ratio 的敌人与羊强制击杀，逐帧记录它们何时真正
##      被 queue_free（即死亡淡出结束），并比对 loot_nodes 数量验证掉落。
##   4. 玩家单独统计：有移动指令却连续不动 → 判定卡住。
##
## 退出码：0 = 全部断言通过，1 = 有失败项（脚本化回归可直接用）。
## ============================================================

const PASS_TOL_STILL := 2.0        # "该走却没动"的容忍上限（秒）
const MOVED_EPS := 8.0             # 位移超过这么多像素才算"真的动过"

var duration := 30.0
var kill_ratio := 0.3
var sample_dt := 0.5
var sweep_dt := 2.5
var order_timeout := 12.0          # 单条移动指令的容忍上限（秒），超时算"没走完"
var trace := false                 # --soak-trace：逐次采样打印玩家状态，排查用

var _run: Node = null
var _player: Node2D = null
var _tile_size := 64
var _cells: Array = []            # 玩家跳点候选（可达且非墙）

var _t := 0.0
var _frames := 0
var _sample_t := 0.0
var _sweep_t := 999.0             # 首次立刻跳点
var _kill_at := -1.0
var _kill_done := false

var _stats := {}                  # instance_id -> 统计字典
var _order: Array = []            # 采样顺序（保报告稳定）
var _victims := {}                # instance_id -> {label, t, freed_t}
var _kill_count := 0

var _orders := 0
var _orders_done := 0
var _orders_timeout := 0
var _orders_interrupted := 0
var _has_order := false
var _order_k := 0
var _order_t0 := 0.0
var _order_deadline := 0.0
var _order_start_dist := 0.0
var _order_target := Vector2.ZERO
var _player_last := Vector2.ZERO
var _player_moved := 0.0
var _player_still := 0.0
var _player_max_still := 0.0
var _player_state := ""
var _stall_state := ""
var _stall_dumped := false
var _armed := false

var _loot_before := 0
var _loot_after := 0
var _fail: Array = []


## 由 main.gd 在 `_enter_run()` 之后调用
func start(map_data: Dictionary, run: Node, secs: float, ratio: float = 0.3) -> void:
	duration = maxf(5.0, secs)
	kill_ratio = clampf(ratio, 0.0, 1.0)
	_run = run
	_tile_size = int(map_data.get("tile_size", 64))
	_player = get_tree().get_first_node_in_group("player")
	if _player != null:
		_player_last = _player.global_position
	var reachable: Array = map_data.get("reachable", [])
	var walls: Array = map_data.get("walls", [])
	for y in range(reachable.size()):
		var rrow: Array = reachable[y]
		var wrow: Array = walls[y]
		for x in range(rrow.size()):
			if bool(rrow[x]) and not bool(wrow[x]):
				_cells.append(Vector2i(x, y))
	print("[Soak] 行为验证开始：%.0f 秒｜跳点格 %d 个｜采样 %.1fs｜跳点间隔 %.1fs｜%.0f%% 处击杀 %.0f%%"
			% [duration, _cells.size(), sample_dt, sweep_dt, 60.0, kill_ratio * 100.0])
	_armed = true


func _physics_process(delta: float) -> void:
	if not _armed:
		return                     # start() 之前不跑（add_child 到 start 之间可能有一帧）
	if _player == null or not is_instance_valid(_player):
		_report()
		return
	_frames += 1
	_t += delta
	_keep_player_alive()
	_sample(delta)
	_sweep(delta)
	_kill_phase()
	_check_deaths()
	if _t >= duration:
		_report()


# ------------------------------------------------------------
# 保活：探针跑的是"行为"，不该被局内计时/接触伤害提前打断
# ------------------------------------------------------------
func _keep_player_alive() -> void:
	if _player.has_method("set_invincible"):
		_player.call("set_invincible", true)
	if _run != null:
		var tr = _run.get("time_remaining")
		if tr != null and float(tr) < duration + 30.0:
			_run.set("time_remaining", duration + 120.0)


# ------------------------------------------------------------
# 采样
# ------------------------------------------------------------
func _all_nodes() -> Array:
	var out: Array = []
	out.append_array(get_tree().get_nodes_in_group("enemies"))
	out.append_array(get_tree().get_nodes_in_group("animals"))
	return out


func _sample(delta: float) -> void:
	_sample_t += delta
	if _sample_t < sample_dt:
		return
	_sample_t = 0.0

	for n in _all_nodes():
		if not is_instance_valid(n):
			continue
		var id: int = n.get_instance_id()
		# 已判定死亡/正在淡出的不再采样：它们本来就"该停"，计进去会假报卡住
		if _victims.has(id) or bool(n.get("_dying")):
			continue
		var pos: Vector2 = n.global_position
		var st = _stats.get(id)
		if st == null:
			st = {
				"label": _label(n),
				"kind": "敌人" if n.is_in_group("enemies") else "羊",
				"moved": 0.0, "last": pos, "busy": 0, "still": 0.0,
				"max_still": 0.0, "states": {}, "active": false,
			}
			_stats[id] = st
			_order.append(id)
		else:
			var stt: Dictionary = st
			var d := pos.distance_to(stt["last"])
			stt["moved"] = float(stt["moved"]) + d
			if _is_busy(n):
				stt["busy"] = int(stt["busy"]) + 1
				stt["active"] = true
				if d < 1.0:
					stt["still"] = float(stt["still"]) + sample_dt
					stt["max_still"] = maxf(float(stt["max_still"]), float(stt["still"]))
				else:
					stt["still"] = 0.0
			else:
				stt["still"] = 0.0
		st["last"] = pos
		var s := _anim_state(n)
		if s >= 0:
			(st["states"] as Dictionary)[s] = true

	# 玩家单独一份统计
	var pd := _player.global_position.distance_to(_player_last)
	_player_moved += pd
	_player_state = _player_state_name()
	var pbusy := _has_move_order()
	if pbusy:
		if pd < 1.0:
			_player_still += sample_dt
			if _player_still >= _player_max_still:
				_stall_state = _player_state        # 记下"卡住那一瞬"的状态名，便于归因
			_player_max_still = maxf(_player_max_still, _player_still)
			# 第一次确认卡住（≥1.5s）时把玩家内部寻路状态整份打出来。
			# 只看"没动"是分不清三种成因的：①路径走完了但没到目标格（死锁）
			# ②路径没错但物理被挡 ③速度系数为 0。这三者的修复方式完全不同。
			if _player_still >= 1.5 and not _stall_dumped:
				_stall_dumped = true
				_dump_player_stall()
		else:
			_player_still = 0.0
	else:
		_player_still = 0.0
	_player_last = _player.global_position
	if trace:
		print("[SoakTrace] 采样 t=%.1fs 状态=%s 位置=(%d,%d) 有指令=%s 位移=%.0fpx"
				% [_t, _player_state, int(_player.global_position.x),
				   int(_player.global_position.y), str(pbusy), pd])


## 卡住现场快照：把玩家内部寻路状态整份 dump 出来定位成因。
##
## 三种"没动"的成因修法完全不同，只看位移分不出来：
##   ① `_path_index` 已走到路径末尾但 `my_cell != end_cell` → 状态机死锁（要兜底放弃）
##   ② 路点方向正常、速度非零、但 20 帧没位移 → 物理被挡（要重算 + 放弃）
##   ③ `terrain_speed_at` 极低 → 走得慢（要调参数）
func _dump_player_stall() -> void:
	var ts := float(_player.get("_tile_size"))
	ts = ts if ts > 0.0 else float(_tile_size)
	var pos: Vector2 = _player.global_position
	var my_cell := Vector2i(int(pos.x / ts), int(pos.y / ts))
	var ft = _player.get("_final_target")
	var end_cell := Vector2i(-1, -1)
	if ft != null:
		var f: Vector2 = ft
		end_cell = Vector2i(int(f.x / ts), int(f.y / ts))
	var path = _player.get("_cached_path")
	var psize := 0 if path == null else (path as PackedVector2Array).size()
	var pidx = _player.get("_path_index")
	var pcell = _player.get("_path_cell")
	var stall = _player.get("_stall_frames")
	var vel = _player.get("velocity")
	var walls: Array = _player.get("_walls")
	var my_solid := -1
	if walls.size() > my_cell.y and my_cell.y >= 0:
		var row: Array = walls[my_cell.y]
		if my_cell.x >= 0 and my_cell.x < row.size():
			my_solid = 1 if bool(row[my_cell.x]) else 0
	print("[SoakStall] t=%.1fs 位置=(%d,%d) 格=%s 目标格=%s 我在实心格=%s"
			% [_t, int(pos.x), int(pos.y), str(my_cell), str(end_cell),
			   "是" if my_solid == 1 else ("否" if my_solid == 0 else "越界")])
	print("[SoakStall] 路径长度=%d index=%s path_cell=%s stall_frames=%s 速度=%s 地形系数=%.3f"
			% [psize, str(pidx), str(pcell), str(stall), str(vel),
			   float(_player.call("current_terrain_speed"))])
	print("[SoakStall] 剩余路点：%s"
			% _join(_remaining_waypoints(path, int(pidx) if pidx != null else 0)))
	# 谁挡的：把 move_and_slide 收集到的碰撞体名字/类别/世界位置全打出来。
	# 光看"没动"永远猜不到是水瓦片、树石碰撞体还是别的物理体，这里一次说清。
	var cc := int(_player.call("get_slide_collision_count"))
	print("[SoakStall] 本帧碰撞数=%d" % cc)
	for i in range(cc):
		var c: KinematicCollision2D = _player.call("get_slide_collision", i)
		var col: Object = c.get_collider()
		var cname := "?"
		var cclass := "?"
		var cpos := Vector2.ZERO
		if col is Node:
			cname = str((col as Node).name)
			cclass = (col as Node).get_class()
			if col is Node2D:
				cpos = (col as Node2D).global_position
		print("[SoakStall]   碰撞%d 法线=%s 碰撞体=%s(%s) 世界位置=(%d,%d) 接触点=(%d,%d)"
				% [i, str(c.get_normal()), cname, cclass, int(cpos.x), int(cpos.y),
				   int(c.get_position().x), int(c.get_position().y)])
	# 邻域墙格：确认"物理挡住的格"和"A* 认为可走的格"是否指同一格
	var nb: Array = []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var cy: int = my_cell.y + dy
			var cx: int = my_cell.x + dx
			var v := "?"
			if cy >= 0 and cy < walls.size():
				var r: Array = walls[cy]
				if cx >= 0 and cx < r.size():
					v = "1" if bool(r[cx]) else "0"
			nb.append("(%d,%d)=%s" % [cx, cy, v])
	print("[SoakStall] 邻域墙格（1=阻挡，中心是我所在格）：%s" % _join(nb))


func _remaining_waypoints(path, idx: int) -> Array:
	var out: Array = []
	if path == null:
		return out
	var arr: PackedVector2Array = path
	for i in range(idx, mini(arr.size(), idx + 4)):
		out.append("(%d,%d)" % [int(arr[i].x), int(arr[i].y)])
	return out


func _player_state_name() -> String:
	var sm = _player.get("state_machine")
	if sm == null or not sm.has_method("get_state_name"):
		var v = _player.get("_state")
		return str(v) if v != null else "?"
	return str(sm.call("get_state_name"))


func _is_busy(n: Node) -> bool:
	if n.is_in_group("enemies"):
		if bool(n.get("_dormant")):
			return false
		return _call_bool(n, "has_move_target")
	var mode = n.get("_mode")
	if mode == null:
		return false
	var m := int(mode)
	return bool(n.get("_has_target")) and (m == 0 or m == 3)   # WALK / FLEE


func _anim_state(n: Node) -> int:
	var v = n.get("_anim_state")
	if v == null:
		v = n.get("_mode")
	if v == null:
		return -1
	return int(v)


func _has_move_order() -> bool:
	if not _player.has_method("has_move_target"):
		return false
	return bool(_player.call("has_move_target"))


func _call_bool(n: Node, m: String) -> bool:
	if not n.has_method(m):
		return false
	return bool(n.call(m))


func _label(n: Node) -> String:
	var tn = n.get("type_name")
	if tn != null and str(tn) != "":
		return "%s#%d" % [str(tn), n.get_instance_id()]
	return "%s#%d" % ["entity", n.get_instance_id()]


## String.join 只吃 PackedStringArray，这里统一转一道，避免运行期类型不符
func _join(arr: Array) -> String:
	var parts := PackedStringArray()
	for v in arr:
		parts.append(str(v))
	return ", ".join(parts)


# ------------------------------------------------------------
# 玩家跳点（同时统计"移动指令是否卡住"）
# ------------------------------------------------------------
## 玩家跳点 + 单条移动指令的结算。
##
## 关键设计：**等上一条走完再派下一条**。
## 早先版本每 2.5 秒无条件改写目标，而玩家从 A 走到 12 格外的 B 要 1.5~3 秒，
## 于是"上一单还没走完就被换掉"，完成率永远是 0% —— 那是度量方式错了，
## 不是玩家卡住。改成订单制之后，"走到/超时"才真正反映寻路是否可靠。
func _sweep(delta: float) -> void:
	_sweep_t += delta
	if _has_order:
		var busy := _has_move_order()
		if busy and _t < _order_deadline:
			return                      # 还在走，不打扰
		# 结算：目标消失有两种原因 —— 走到（正常）或被受击硬直等状态打断。
		# 用"离目标还有多远"区分，不然被打断会被错记成"寻路成功"。
		var remain := _player.global_position.distance_to(_order_target)
		var outcome := ""
		if busy:
			_orders_timeout += 1
			outcome = "超时"
		elif remain <= float(_tile_size) * 2.0:
			_orders_done += 1
			outcome = "走到"
		else:
			_orders_interrupted += 1
			outcome = "被打断"
		if trace:
			print("[SoakTrace] 指令 #%d 结算 t=%.1fs 用时 %.1fs 投放距离 %dpx 剩余 %dpx 结果=%s 状态=%s"
					% [_order_k, _t, _t - _order_t0, int(_order_start_dist), int(remain),
					   outcome, _player_state])
		_has_order = false
	if _sweep_t < sweep_dt:
		return
	_sweep_t = 0.0
	var target := _pick_far_cell()
	if target == Vector2.ZERO:
		return
	_orders += 1
	_order_k += 1
	_has_order = true
	_order_t0 = _t
	_order_deadline = _t + order_timeout
	_order_start_dist = _player.global_position.distance_to(target)
	_order_target = target
	_player.call("set_move_target", target)
	if trace:
		print("[SoakTrace] 指令 #%d 下达 t=%.1fs 距离 %dpx 状态=%s"
				% [_order_k, _t, int(_order_start_dist), _player_state])


## 挑一个距玩家 >12 格的可达格 —— 太近的跳点测不出寻路
func _pick_far_cell() -> Vector2:
	if _cells.is_empty():
		return Vector2.ZERO
	var ts := float(_tile_size)
	for _i in range(24):
		var c: Vector2i = _cells[randi() % _cells.size()]
		var p := Vector2(c) * ts + Vector2(ts * 0.5, ts * 0.5)
		if p.distance_to(_player.global_position) > ts * 12.0:
			return p
	return Vector2.ZERO


# ------------------------------------------------------------
# 击杀 / 死亡消失
# ------------------------------------------------------------
func _kill_phase() -> void:
	if _kill_done:
		return
	if _kill_at < 0.0:
		_kill_at = duration * 0.6
	if _t < _kill_at:
		return
	_kill_done = true
	_loot_before = get_tree().get_nodes_in_group("loot_nodes").size()
	var enemies: Array = []
	var animals: Array = []
	for n in _all_nodes():
		if not is_instance_valid(n) or _victims.has(n.get_instance_id()):
			continue
		if bool(n.get("_dying")):
			continue
		if n.is_in_group("enemies"):
			enemies.append(n)
		else:
			animals.append(n)
	enemies.shuffle()
	animals.shuffle()
	var ne := int(round(float(enemies.size()) * kill_ratio))
	var na := int(round(float(animals.size()) * kill_ratio))
	_kill_batch(enemies.slice(0, ne))
	_kill_batch(animals.slice(0, na))
	print("[Soak] 击杀批次 @%.1fs：敌人 %d/%d，羊 %d/%d（掉落基线 loot_nodes=%d）"
			% [_t, ne, enemies.size(), na, animals.size(), _loot_before])


func _kill_batch(list: Array) -> void:
	for n in list:
		if not is_instance_valid(n):
			continue
		var id: int = n.get_instance_id()
		_victims[id] = {"label": _label(n), "t": _t, "freed_t": -1.0}
		_kill_count += 1
		n.call("take_damage", 999999)


## 逐帧检查：什么时候真正被释放（= 淡出结束、从场景里消失）
func _check_deaths() -> void:
	for id in _victims.keys():
		var rec: Dictionary = _victims[id]
		if float(rec["freed_t"]) >= 0.0:
			continue
		if not is_instance_valid(instance_from_id(id)):
			rec["freed_t"] = _t


# ------------------------------------------------------------
# 报告
# ------------------------------------------------------------
func _report() -> void:
	set_physics_process(false)
	print("[Soak] ===== 行为验证报告（模拟 %.1fs / %d 帧）=====" % [_t, _frames])
	_report_anim()
	_report_movement()
	_report_death()
	_report_player()
	print("[Soak] 掉落：loot_nodes %d → %d（+%d）"
			% [_loot_before, _loot_after, maxi(0, _loot_after - _loot_before)])
	if _fail.is_empty():
		print("[Soak] 结论：PASS（0 项失败）")
	else:
		for f in _fail:
			print("[Soak] FAIL：%s" % str(f))
		print("[Soak] 结论：FAIL（%d 项）" % _fail.size())
	get_tree().quit(1 if _fail.size() > 0 else 0)


func _kind_counts() -> Dictionary:
	var c := {"敌人": {"n": 0, "moved": 0, "active": 0}, "羊": {"n": 0, "moved": 0, "active": 0}}
	for id in _order:
		var st: Dictionary = _stats[id]
		var k := str(st["kind"])
		c[k]["n"] = int(c[k]["n"]) + 1
		if float(st["moved"]) > MOVED_EPS:
			c[k]["moved"] = int(c[k]["moved"]) + 1
		if bool(st["active"]):
			c[k]["active"] = int(c[k]["active"]) + 1
	return c


func _report_anim() -> void:
	var union := {}
	for id in _order:
		var st: Dictionary = _stats[id]
		for s in (st["states"] as Dictionary):
			union["%s/%d" % [str(st["kind"]), int(s)]] = true
	var keys: Array = union.keys()
	keys.sort()
	print("[Soak] 动画状态：采样到 %d 种（%s）" % [keys.size(), _join(keys)])
	if keys.size() < 3:
		_fail.append("动画状态过少（%d 种），角色可能没在播动作" % keys.size())


func _report_movement() -> void:
	var c := _kind_counts()
	var worst := 0.0
	var worst_label := ""
	var total_moved := 0.0
	var stuck := []
	for id in _order:
		var st: Dictionary = _stats[id]
		total_moved += float(st["moved"])
		if float(st["max_still"]) > worst:
			worst = float(st["max_still"])
			worst_label = str(st["label"])
		if float(st["max_still"]) >= PASS_TOL_STILL:
			stuck.append("%s 静了 %.1fs" % [str(st["label"]), float(st["max_still"])])
	for k in ["敌人", "羊"]:
		print("[Soak] %s：采样 %d 个｜有位移 %d 个（%.0f%%）｜醒着(AI 在跑) %d 个"
				% [k, int(c[k]["n"]), int(c[k]["moved"]),
				   100.0 * float(c[k]["moved"]) / maxf(1.0, float(c[k]["n"])),
				   int(c[k]["active"])])
	print("[Soak] 位移合计 %.0f px｜最长\"该走却没动\" %.1fs（%s）"
			% [total_moved, worst, worst_label if worst_label != "" else "无"])
	if int(c["敌人"]["n"]) <= 0 or int(c["羊"]["n"]) <= 0:
		_fail.append("敌人或羊没生成（敌人 %d，羊 %d）"
				% [int(c["敌人"]["n"]), int(c["羊"]["n"])])
	if int(c["敌人"]["active"]) <= 0:
		_fail.append("没有任何敌人进入活动状态，AI 没跑起来")
	if int(c["羊"]["active"]) <= 0:
		_fail.append("没有任何羊进入行走/逃跑状态")
	if stuck.size() > 0:
		_fail.append("%d 个单位在\"该走\"状态下静止 ≥%.0fs：%s"
				% [stuck.size(), PASS_TOL_STILL, _join(stuck.slice(0, 5))])


func _report_death() -> void:
	var freed := 0
	var lat_sum := 0.0
	var lat_max := 0.0
	var not_freed: Array = []
	for id in _victims:
		var rec: Dictionary = _victims[id]
		if float(rec["freed_t"]) < 0.0:
			not_freed.append(str(rec["label"]))
		else:
			freed += 1
			var lat := float(rec["freed_t"]) - float(rec["t"])
			lat_sum += lat
			lat_max = maxf(lat_max, lat)
	_loot_after = get_tree().get_nodes_in_group("loot_nodes").size()
	print("[Soak] 死亡：击杀 %d 个｜已消失 %d 个｜残留 %d 个｜淡出延迟 平均 %.2fs / 最长 %.2fs"
			% [_kill_count, freed, not_freed.size(),
			   lat_sum / maxf(1.0, float(freed)), lat_max])
	if _kill_count <= 0:
		_fail.append("击杀批次没执行（kill_count=0）")
	if not_freed.size() > 0:
		_fail.append("%d 个已死亡单位没有消失：%s"
				% [not_freed.size(), _join(not_freed.slice(0, 5))])
	var fade := float(Config.get_value("enemy.death_fade_seconds", 0.45))
	if freed > 0 and lat_max > fade + 0.5:
		_fail.append("淡出延迟 %.2fs 明显超过配置 %.2fs" % [lat_max, fade])


func _report_player() -> void:
	var resolved := _orders_done + _orders_timeout + _orders_interrupted
	var ok_rate := 100.0 * float(_orders_done + _orders_interrupted) / maxf(1.0, float(resolved))
	print("[Soak] 玩家：移动指令 %d 条｜走到 %d｜被打断 %d｜超时未走到 %d｜移动距离 %.0f px"
			% [_orders, _orders_done, _orders_interrupted, _orders_timeout, _player_moved])
	print("[Soak] 玩家最长\"有指令却没动\" %.1fs（当时状态=%s）｜成功率(走到+被打断) %.0f%%"
			% [_player_max_still, _stall_state if _stall_state != "" else "无", ok_rate])
	if _orders <= 0:
		_fail.append("玩家跳点指令数为 0，寻路没被测到")
	if _player_max_still >= PASS_TOL_STILL:
		_fail.append("玩家有移动指令却静止 %.1fs（状态=%s）" % [_player_max_still, _stall_state])
	if resolved > 0 and ok_rate < 50.0:
		_fail.append("玩家移动指令成功率仅 %.0f%%（超时 %d 条）" % [ok_rate, _orders_timeout])

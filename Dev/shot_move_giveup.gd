extends Node
## ============================================================
## shot_move_giveup — 实拍：4 个人点同一个地方，旧行为 vs 新行为
##
## 探针（probe_move_giveup）已经用数值证明"负对照 3/4 人挂着指令 → 修复后 0/4"。
## 数值之外还要看一眼：停在目标周围的那一圈人，画面上是不是真的"到了、站住了"，
## 而不是仍然保持跑步姿势原地打转（那是另一种难看）。
## 同一个点位、同一批人，只拨 player.blocked_give_up_frames 这一个键。
##
## 用法（**必须开窗**，无头是 dummy 驱动、viewport 贴图恒空）：
##   python tools/run_probe.py _shot_giveup.log Dev/shot_move_giveup.tscn --window
##
## ⚠ 会走一次 _on_launch，开跑备份 user://save.json、收尾原样还原。
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const SAVE_PATH := "user://save.json"
const IDS := ["spearman", "archer", "swordsman", "monk"]

var _save_backup := ""
var _save_existed := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()
	Config.set_override("display.window_mode", "windowed")
	Config.set_override("display.resolution", [1280, 720])
	Config.set_override("debug.auto_enter_run", false)
	# 自动交战会把赶路的人拽进对砍，位置和状态都不干净，图上看不出"到没到"
	Config.set_override("combat.auto_attack.enabled", false)

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	var roster: Array = []
	for id in IDS:
		roster.append({"id": id, "name": id})
	main.call("_on_launch", roster)
	var waited := 0
	while _players().size() < IDS.size() and waited < 600:
		await get_tree().process_frame
		waited += 1
	await _frames(90)
	var ps := _players()
	if ps.size() < 2:
		print("[ShotGiveup] !! 只有 %d 个角色，拍不了" % ps.size())
		_finish(1)
		return

	# 先站开：起点决定两次实验是否真的可对比
	await _spread(ps, (ps[0] as Node2D).global_position)
	var start: Vector2 = (ps[0] as Node2D).global_position
	# 目标点选在出发位置旁边 250px：离镜头远 = 拍到没揭开的雾（全黑），那没意义
	var target := _pick_near_walkable(ps[0], 250.0)
	print("[ShotGiveup] 角色 %d 个  出发点=%s  目标点=%s" % [ps.size(), str(start), str(target)])

	# ---- 旧行为：窗口拉到极大，等于这条规则不存在 ----
	Config.set_override("player.blocked_give_up_frames", 1000000)
	await _order(ps, target)
	await _pframes(240)
	_report("旧行为 下令后 4.0s", ps, target)
	await _shot(OUT_DIR + "/giveup_old_t4.png", "旧 4.0s")
	await _pframes(120)
	_report("旧行为 下令后 6.0s", ps, target)
	await _shot(OUT_DIR + "/giveup_old_t6.png", "旧 6.0s")

	# ---- 新行为：回到同一排站位、重新点同一个地方，只把窗口拨回默认 ----
	Config.clear_override("player.blocked_give_up_frames")
	ps = _players()
	await _spread(ps, start)
	await _order(ps, target)
	await _pframes(240)
	_report("新行为 下令后 4.0s", ps, target)
	await _shot(OUT_DIR + "/giveup_new_t4.png", "新 4.0s")
	await _pframes(120)
	_report("新行为 下令后 6.0s", ps, target)
	await _shot(OUT_DIR + "/giveup_new_t6.png", "新 6.0s")
	_finish(0)


func _players() -> Array:
	var out: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and not bool(p.call("is_dead")):
			out.append(p)
	return out


## 全员点同一个地方 —— 这正是 bug 的触发条件
func _order(ps: Array, target: Vector2) -> void:
	for p in ps:
		p.call("command_click", target)


## 每行一个角色：还挂着指令吗、还在动吗、离目标几像素。
## "挂着指令 + 速度不为 0"就是用户报的"一直在跑"。
func _report(tag: String, ps: Array, target: Vector2) -> void:
	var running := 0
	for p in ps:
		if not is_instance_valid(p) or bool(p.call("is_dead")):
			continue
		var holds := bool(p.call("has_move_target"))
		var v: Vector2 = p.get("velocity")
		var moving := v.length() > 8.0
		if holds and moving:
			running += 1
		var sm = p.get("state_machine")
		print("[ShotGiveup] %s  指令%s 速度%6.1f 离目标%6.1f 状态=%s" % [
				tag,
				"挂着" if holds else "了结",
				v.length(),
				(p as Node2D).global_position.distance_to(target),
				str(sm.call("get_state_name")) if sm != null else "?"])
	print("[ShotGiveup] >>> %s：%d/%d 人还在跑（挂着指令且速度>8）" % [tag, running, ps.size()])


## 出发位置周围找一个可走格心：太远的点会跑进没揭开的雾里，拍出来是黑的
func _pick_near_walkable(p: Node, dist: float) -> Vector2:
	var tile := float(Config.get_value("map.tile_size", 64))
	for ring in range(0, 10):
		for k in range(16):
			var ang := float(k) * TAU / 16.0
			var cand: Vector2 = (p as Node2D).global_position \
					+ Vector2(cos(ang), sin(ang)) * (dist + float(ring) * 60.0)
			var cell: Vector2i = p.call("_cell_of", cand)
			var open: Vector2i = p.call("_goal_cell", cell)
			if open == cell:
				return Vector2(open.x * tile + tile * 0.5, open.y * tile + tile * 0.5)
	return (p as Node2D).global_position + Vector2(dist, 0.0)


## 站成一排（吸附到可走格、互不重复），保证"是被走到目标后挡住的"，不是一开始就挤着
func _spread(ps: Array, origin: Vector2) -> void:
	var tile := float(Config.get_value("map.tile_size", 64))
	var used: Array = []
	for i in range(ps.size()):
		var p: Node = ps[i]
		var cell: Vector2i = p.call("_cell_of", origin + Vector2(float(i) * 90.0, 0.0))
		var open: Vector2i = p.call("_goal_cell", cell)
		var guard := 0
		while used.has(open) and guard < 32:
			cell = cell + Vector2i(1, 0)
			open = p.call("_goal_cell", cell)
			guard += 1
		used.append(open)
		(p as Node2D).global_position = Vector2(open.x * tile + tile * 0.5, open.y * tile + tile * 0.5)
		p.call("_clear_path_cache")
	await _pframes(10)


func _shot(path: String, tag: String) -> void:
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[ShotGiveup] !! viewport 贴图为空（忘了 --window？）")
		return
	var err := im.save_png(path)
	print("[ShotGiveup] %s -> %s err=%d %dx%d" % [tag, path, err, im.get_width(), im.get_height()])


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _pframes(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame


func _finish(code: int) -> void:
	_restore_save()
	get_tree().quit(code)


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

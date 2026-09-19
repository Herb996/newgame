extends Node
## ============================================================
## shot_separation — 实拍：一坨叠在一起的敌人，开/关分离层各长什么样
##
## 探针（probe_collision_separation）已经用数值证明"重叠对 42 → 0"。
## 但"数值上分开了"和"眼睛不再觉得是一根针"是两件事 —— 这张图专门看后者：
## 同一批敌人、同一个聚拢点，只拨 combat.separation.enabled 这一个开关，
## 在 clump 后 0.05s / 0.4s / 1.4s 各拍一张，并打印最小/平均圆心距。
##
## 用法（**必须开窗**，无头是 dummy 驱动、viewport 贴图恒空）：
##   python tools/run_probe.py _shot_sep.log Dev/shot_separation.tscn --window
##
## ⚠ 会走一次 _on_launch，开跑备份 user://save.json、收尾原样还原。
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const SAVE_PATH := "user://save.json"
const CROWD := 10

var _save_backup := ""
var _save_existed := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()
	Config.set_override("display.window_mode", "windowed")
	Config.set_override("display.resolution", [1280, 720])
	Config.set_override("debug.auto_enter_run", false)
	# 玩家别还手：自动交战会把这坨人打死，图上就没人可看了
	Config.set_override("combat.auto_attack.enabled", false)
	Config.set_override("combat.separation.enabled", false)

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	main.call("_on_launch", [{"id": "spearman", "name": "枪手"}])
	var waited := 0
	while get_tree().get_nodes_in_group("player").size() < 1 and waited < 400:
		await get_tree().process_frame
		waited += 1
	await _frames(90)

	var player: Node = get_tree().get_first_node_in_group("player")
	if player == null:
		print("[ShotSep] !! 没有玩家，拍不了")
		_finish(1)
		return
	var enemies: Array = _living_enemies()
	print("[ShotSep] 场上活敌 %d 个" % enemies.size())
	if enemies.size() < CROWD:
		print("[ShotSep] !! 敌人不够 %d 个，拍不了" % CROWD)
		_finish(1)
		return
	var crowd: Array = []
	for e in enemies:
		if crowd.size() < CROWD:
			crowd.append(e)

	var cam: Node = get_tree().get_first_node_in_group("iso_cam")
	# 聚拢点放在玩家旁边：镜头默认跟着玩家，把人群挪到远处等于挪进没揭开的雾里（拍出来全黑）。
	# 用分离层自己的 _can_stand 挑一格可走的地面，别把人群塞进树里。
	var sep: Node = main.get_node_or_null("GameRoot/UnitSeparation")
	var home := Vector2.ZERO
	var found := false
	for ring in range(1, 8):
		if found:
			break
		for k in range(12):
			var ang := float(k) * TAU / 12.0
			var cand: Vector2 = player.global_position + Vector2(cos(ang), sin(ang)) * (200.0 + float(ring) * 50.0)
			if sep == null or sep.call("_can_stand", cand):
				home = cand
				found = true
				break
	if not found:
		print("[ShotSep] !! 玩家周围找不到可走格")
		_finish(1)
		return
	await _pframes(20)

	# ---- 关：全叠在同一点 ----
	_clump(crowd, home)
	await _pframes(3)
	_report("分离层 OFF  t=0.05s", crowd)
	await _shot(OUT_DIR + "/sep_off_t0.png", "OFF t=0.05s")
	await _pframes(21)
	_report("分离层 OFF  t=0.4s ", crowd)
	await _shot(OUT_DIR + "/sep_off_t04.png", "OFF t=0.4s")

	# ---- 开：同一批人、同一个点，重新叠一次再放开 ----
	Config.set_override("combat.separation.enabled", true)
	_clump(crowd, home)
	await _pframes(3)
	_report("分离层 ON   t=0.05s", crowd)
	await _shot(OUT_DIR + "/sep_on_t0.png", "ON t=0.05s")
	await _pframes(21)
	_report("分离层 ON   t=0.4s ", crowd)
	await _shot(OUT_DIR + "/sep_on_t04.png", "ON t=0.4s")
	await _pframes(60)
	_report("分离层 ON   t=1.4s ", crowd)
	await _shot(OUT_DIR + "/sep_on_t14.png", "ON t=1.4s")
	print("[ShotSep] 聚拢点=%s 相机=%s" % [str(home), str(cam)])
	_finish(0)


func _living_enemies() -> Array:
	var out: Array = []
	for e in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e) and _dying(e) == false:
			out.append(e)
	return out


func _dying(n: Object) -> bool:
	var v = n.get("_dying")
	return v != null and bool(v)


func _clump(crowd: Array, home: Vector2) -> void:
	for e in crowd:
		if is_instance_valid(e):
			(e as Node2D).global_position = home


## 最小/平均圆心距：图上"是一根针还是一圈人"，这两个数就是它的量化版本。
## 名义不重叠间距 = 2×radius_px.enemies。
func _report(tag: String, crowd: Array) -> void:
	var pts: Array = []
	for e in crowd:
		if is_instance_valid(e) and _dying(e) == false:
			pts.append((e as Node2D).global_position)
	var nominal := float(Config.get_value("combat.separation.radius_px.enemies", 22.0)) * 2.0
	var lo := 1e9
	var sum := 0.0
	var n := 0
	var deep := 0
	for i in range(pts.size()):
		for j in range(i + 1, pts.size()):
			var d: float = (pts[i] as Vector2).distance_to(pts[j])
			lo = minf(lo, d)
			sum += d
			n += 1
			if d < nominal * 0.8:
				deep += 1
	if n == 0:
		print("[ShotSep] %s 只剩 %d 个活人，测不了" % [tag, pts.size()])
		return
	print("[ShotSep] %s 人数=%d 最小间距=%.1f 平均=%.1f（名义 %.0f）深重叠对=%d" % [
			tag, pts.size(), lo, sum / float(n), nominal, deep])


func _shot(path: String, tag: String) -> void:
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[ShotSep] !! viewport 贴图为空（忘了 --window？）")
		return
	var err := im.save_png(path)
	print("[ShotSep] %s -> %s err=%d %dx%d" % [tag, path, err, im.get_width(), im.get_height()])


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

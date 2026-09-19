extends Node
## ============================================================
## shot_dead_combat — 实机复现：被敌人打死之后，尸体到底还在不在
##
## 与 probe_dead_body / shot_dead_body 的区别：那两个是「探针一枪打死 +
## 关刷怪」的理想场景，尸体全程可见、20 秒后仍在原地。用户报的是**真打**，
## 所以这里把刷怪打开、单人出击，让敌人自己把他打死，死后每 2 秒抓一张，
## 连抓 30 秒 —— 中途任何一张里尸体没了，就能锁死是哪一秒、哪件事干的。
##
## 用法（**必须开窗**）：
##   python tools/run_probe.py _shot_dead_combat.log Dev/shot_dead_combat.tscn --window
##
## ⚠ 会走一次 _on_launch，开跑备份 user://save.json、收尾原样还原。
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const SAVE_PATH := "user://save.json"

var _save_backup := ""
var _save_existed := false
var _n := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()
	Config.set_override("display.window_mode", "windowed")
	Config.set_override("debug.auto_enter_run", false)
	# 刷怪保持本机实机量级：真被打死才是用户遇到的那条路
	Config.set_override("animals.count", 0)

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	main.call("_on_launch", [{"id": "spearman", "name": "独行"}])
	await _frames(60)

	var p: Node = get_tree().get_first_node_in_group("player")
	if p == null:
		print("[ShotCombat] !! 出击后没有角色")
		_finish(1)
		return
	var spawn: Vector2 = p.global_position
	print("[ShotCombat] 出击：1 名角色 @%.0f,%.0f，敌人 %d 个" % [spawn.x, spawn.y,
			get_tree().get_nodes_in_group("enemies").size()])

	# 最多等 90 秒让敌人把他打死；期间每 2 秒一张
	var killed_at := -1
	for i in range(45):
		await _pframes(120)
		if not is_instance_valid(p):
			print("[ShotCombat] 第 %d 张时角色节点已失效（被释放）" % i)
			break
		var dead := bool(p.call("is_dead"))
		print("[ShotCombat] t=%ds dead=%s state=%s hp=%s 敌近=%d 世界=%.0f,%.0f" % [
				i * 2, str(dead), _state(p), str(p.get("hp")), _enemies_near(p, 200.0),
				p.global_position.x, p.global_position.y])
		await _shot(p, "t%02d_%s" % [i, "dead" if dead else "alive"])
		if dead and killed_at < 0:
			killed_at = i
			print("[ShotCombat] 他被敌人打死了 @t=%ds，位置 %.0f,%.0f"
					% [i * 2, p.global_position.x, p.global_position.y])
		if killed_at >= 0 and i >= killed_at + 15:
			break

	if killed_at < 0:
		print("[ShotCombat] !! 90 秒内没死成，复现不了（敌人太弱或太远）")
		_finish(2)
		return
	_finish(0)


func _state(p: Node) -> String:
	var sm = p.get("state_machine")
	return str(sm.get_state_name()) if sm != null else "?"


func _enemies_near(p: Node, r: float) -> int:
	var n := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e.global_position.distance_to(p.global_position) <= r:
			n += 1
	return n


## 以角色为中心裁 480x480（比 shot_dead_body 大一圈：要看清周围压上来的敌人）
func _shot(p: Node, tag: String) -> void:
	_n += 1
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[ShotCombat] !! viewport 贴图为空（忘了 --window？）")
		return
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	var w := src.get_width()
	var h := src.get_height()
	var sp: Sprite2D = p.get_node_or_null("Body")
	var c := Vector2(w * 0.5, h * 0.5)
	if sp != null:
		c = sp.get_global_transform_with_canvas().get_origin()
	var half := 240
	var box := Rect2i(int(c.x) - half, int(c.y) - half, half * 2, half * 2)
	box.position.x = clampi(box.position.x, 0, maxi(w - 8, 0))
	box.position.y = clampi(box.position.y, 0, maxi(h - 8, 0))
	box.size.x = mini(box.size.x, w - box.position.x)
	box.size.y = mini(box.size.y, h - box.position.y)
	var out := Image.create(box.size.x, box.size.y, false, Image.FORMAT_RGBA8)
	out.blit_rect(src, box, Vector2i.ZERO)
	var path := "%s/combat_%02d_%s.png" % [OUT_DIR, _n, tag]
	var err := out.save_png(path)
	print("[ShotCombat]   -> %s err=%d 屏幕=%s 尸体读数=%s" % [path, err,
			str(box.get_center()), _line(p)])


func _line(p: Node) -> String:
	if not is_instance_valid(p):
		return "节点已失效"
	var sp: Sprite2D = p.get_node_or_null("Body")
	var fmt := ("in_view=%s visible=%s alpha=%.2f body_vis=%s body_alpha=%.2f "
			+ "tex=%s rot=%.2f scale=%.2f")
	return fmt % [p.is_visible_in_tree(), p.visible, float(p.modulate.a),
			sp.visible if sp != null else "?",
			float(sp.modulate.a) if sp != null else 0.0,
			str(sp.texture != null) if sp != null else "?",
			float(sp.rotation) if sp != null else 0.0,
			float(sp.scale.x) if sp != null else 0.0]


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

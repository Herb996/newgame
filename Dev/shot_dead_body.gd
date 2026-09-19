extends Node
## ============================================================
## shot_dead_body — 实拍：角色阵亡后**人消失、货留在原地**
##
## 用户 2026-09-19 定：「我就要他消失啊」。数值探针（probe_dead_body）
## 已量到淡出后第 20 个物理帧节点出树、掉物仍在死亡坐标；但"消失"这件事
## 最终得看图 —— 断言全绿也可能画面是歪的（§5.10 口径）。
##
## 拍四张：
##   1) 倒下前            —— 认人：甲在左、乙在右
##   2) 淡出中（~0.2s）    —— 人还看得见但在变淡：证明不是凭空抹掉
##   3) 移除后（~2s）      —— 死亡点只剩一地货，没有人
##   4) 20s 后             —— 人不会又长回来，货还在
## 每张同时打印「甲还在不在 / 死亡点资源点数 / 裁切框」。
##
## 用法（**必须开窗**，无头是 dummy 驱动、viewport 贴图恒空）：
##   python tools/run_probe.py _shot_dead_body.log Dev/shot_dead_body.tscn --window
##
## ⚠ 会走一次 _on_launch，开跑备份 user://save.json、收尾原样还原。
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const SAVE_PATH := "user://save.json"

var _save_backup := ""
var _save_existed := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()

	# 本机 settings.json 是 fullscreen：实拍要窗口，别把桌面糊掉
	Config.set_override("display.window_mode", "windowed")
	Config.set_override("display.resolution", [1280, 720])
	Config.set_override("debug.auto_enter_run", false)
	# 关掉刷怪：本脚本要盯 20 秒，有敌人会把乙也顺手打死，画面就乱了
	Config.set_override("enemy.count", 0)
	Config.set_override("animals.count", 0)

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(30)

	main.call("_on_launch", [{"id": "spearman", "name": "枪手"},
			{"id": "archer", "name": "弓兵"}])
	var waited := 0
	while get_tree().get_nodes_in_group("player").size() < 2 and waited < 400:
		await get_tree().process_frame
		waited += 1
	var players: Array = []
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q) and not bool(q.is_dead()):
			players.append(q)
	if players.size() < 2:
		print("[ShotDead] !! 只拿到 %d 名角色，拍不了" % players.size())
		_finish(1)
		return

	var a: Node = players[0]
	var b: Node = players[1]
	# 两人分开：挤在一起，掉物会被乙 0.5s 的拾取重试秒捡走，画面就只剩空地
	b.global_position = a.global_position + Vector2(420.0, 0.0)
	a.add_item("wood", 12)
	a.add_item("stone", 6)
	a.add_item("food", 4)
	await _frames(30)

	var cam: Node = get_tree().get_first_node_in_group("iso_cam")
	print("[ShotDead] 相机=%s 视口=%s" % [str(cam), str(get_viewport().get_visible_rect().size)])

	var die_pos: Vector2 = a.global_position
	print("[ShotDead] 倒下前 甲：%s" % _line(a))
	await _shot_at(die_pos, OUT_DIR + "/dead_0_before.png", "倒下前")

	a.call("take_damage", 999999, Vector2.ZERO)

	# 淡出中（~0.2s）：这一刻人应该还在、但在变淡
	await _pframes(12)
	print("[ShotDead] 淡出中 甲：%s" % _line(a))
	await _shot_at(die_pos, OUT_DIR + "/dead_1_mid_fade.png", "淡出中")

	# 移除后（~2s）：镜头先被控制权移交甩到活人身上，再拉回死亡点 —— 这才是玩家真实会看到的画面
	await _pframes(60)
	if cam != null:
		cam.call("focus_world_pos", b.global_position)
	await _pframes(60)
	if cam != null:
		cam.call("focus_world_pos", die_pos)
	await _pframes(30)
	print("[ShotDead] 移除后 甲：%s 死亡点资源点=%d" % [_line(a), _loot_near(die_pos)])
	await _shot_at(die_pos, OUT_DIR + "/dead_2_after_gone.png", "移除后")

	# 长时间：20 秒后人不会又长回来，货还在
	await _pframes(600)
	print("[ShotDead] 死后~20s 甲：%s 死亡点资源点=%d" % [_line(a), _loot_near(die_pos)])
	await _shot_at(die_pos, OUT_DIR + "/dead_3_after_20s.png", "死后20s")

	_finish(0)


## 一行读数：形参不写类型 —— 阵亡淡出后传进来的是 freed 对象，
## 声明成 Node 会在进函数前就抛 "Invalid type … previously freed"。
func _line(p) -> String:
	if not is_instance_valid(p):
		return "节点已失效（人已从场上移除）"
	var sp: Sprite2D = p.get_node_or_null("Body")
	var fmt := ("in_tree=%s in_view=%s alpha=%.2f body_vis=%s tex=%s "
			+ "state=%s 世界=%.0f,%.0f")
	return fmt % [
			p.is_inside_tree(), p.is_visible_in_tree(), float(p.modulate.a),
			str(sp.visible) if sp != null else "?",
			str(sp.texture != null) if sp != null else "?",
			str(p.get("state_machine").get_state_name()) if p.get("state_machine") != null else "?",
			p.global_position.x, p.global_position.y]


## 以「世界坐标」为中心裁 420x420：人不在了也要能把死亡点框进图里，
## 所以中心用 世界→屏幕 换算，不再挂节点的 Body。
func _shot_at(world_pos: Vector2, path: String, tag: String) -> void:
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[ShotDead] !! viewport 贴图为空（忘了 --window？）")
		return
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	var w := src.get_width()
	var h := src.get_height()
	var c: Vector2 = get_viewport().get_canvas_transform() * world_pos
	var half := 210
	var box := Rect2i(int(c.x) - half, int(c.y) - half, half * 2, half * 2)
	box.position.x = clampi(box.position.x, 0, maxi(w - 8, 0))
	box.position.y = clampi(box.position.y, 0, maxi(h - 8, 0))
	box.size.x = mini(box.size.x, w - box.position.x)
	box.size.y = mini(box.size.y, h - box.position.y)
	var out := Image.create(box.size.x, box.size.y, false, Image.FORMAT_RGBA8)
	out.blit_rect(src, box, Vector2i.ZERO)
	var err := out.save_png(path)
	print("[ShotDead] %s -> %s err=%d 裁切=%s 视口=%dx%d" % [tag, path, err, str(box), w, h])


func _loot_near(pos: Vector2) -> int:
	var n := 0
	for q in get_tree().get_nodes_in_group("loot_nodes"):
		if is_instance_valid(q) and q.global_position.distance_to(pos) <= 90.0:
			n += 1
	return n


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

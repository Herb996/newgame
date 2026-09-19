extends Node
## ============================================================
## shot_inventory — 实拍：右键角色弹出的背包面板 + 底部菜单栏那一行
##
## 探针能验数值与矩形，验不了「这面板摆在那儿读不读得通、有没有压住人」。
## 两种状态各来一张：充足（甲，两格货、无红字）/ 短缺（乙，红字要点名缺什么、
## 降了哪几条属性、承诺补上就恢复且不会死）。
##
## 用法（**必须开窗**，无头是 dummy 驱动、viewport 贴图恒空）：
##   godot --path D:/SteamPunkExtraction res://Dev/shot_inventory.tscn --window
## 也可以直接：python tools/run_probe.py _shot_inventory.log Dev/shot_inventory.tscn --window
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
	Config.set_override("debug.auto_enter_run", false)
	Config.set_override("enemy.count", 0)

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	for _i in range(30):
		await get_tree().process_frame

	main.call("_on_launch", [{"id": "spearman", "name": "枪手"},
			{"id": "archer", "name": "弓兵"}])
	var waited := 0
	while get_tree().get_nodes_in_group("player").size() < 2 and waited < 400:
		await get_tree().process_frame
		waited += 1
	for _i in range(60):
		await get_tree().process_frame

	var players: Array = []
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q) and not bool(q.is_dead()):
			players.append(q)
	var surv: Node = get_tree().get_first_node_in_group("survival_system")
	var popup: Control = get_tree().get_first_node_in_group("inventory_popup")
	var menu: Node = get_tree().get_first_node_in_group("menu_bar")
	if players.size() < 2 or popup == null or surv == null:
		print("[ShotInv] !! 前置不全：players=%d popup=%s surv=%s"
				% [players.size(), str(popup), str(surv)])
		_finish(1)
		return
	surv.set("next_meal_in", 9999.0)
	var a: Node = players[0]
	var b: Node = players[1]
	# 两人分开拍：挤在一起面板会压住另一个小人，看不出真实摆位
	b.global_position = a.global_position + Vector2(0.0, 260.0)
	a.add_item("wood", 20)
	a.add_item("stone", 8)
	a.add_item("food", 3)
	await _frames(4)

	popup.call("open_for", a)
	await _frames(6)
	await _shot(popup, OUT_DIR + "/inventory_a_stocked.png", "甲·充足")
	print("[ShotInv] 菜单栏：「%s」" % menu.call("bag_line_text"))

	# 短缺态必须先把地上扫干净：乙站的位置若压着资源点，几帧内他就顺手捡满，
	# 短缺自动解除 → 红字拍不出来（上一版实拍就是这么翻车的）
	for q in get_tree().get_nodes_in_group("loot_nodes"):
		if is_instance_valid(q):
			q.queue_free()
	b.inventory = {}
	surv.call("_consume_tick")      # 甲有存货照扣，乙空手 → 只有乙短缺
	await _frames(6)
	popup.call("open_for", b)
	await _frames(6)
	await _shot(popup, OUT_DIR + "/inventory_b_shortage.png", "乙·短缺")
	print("[ShotInv] 菜单栏：「%s」" % menu.call("bag_line_text"))

	_finish(0)


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


## 同一帧里裁两张：popup 附近（含角色本体）+ 画面底部（HUD 两行 + 菜单栏）
func _shot(popup: Control, path: String, tag: String) -> void:
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[ShotInv] !! viewport 贴图为空（是不是忘了 --window？）")
		return
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	var w := src.get_width()
	var h := src.get_height()
	var rect: Rect2 = popup.call("panel_rect")
	# 面板 + 下面 150px（要看见"钉在头顶"这件事）+ 左右各留 120px
	var box := Rect2i(int(rect.position.x) - 120, int(rect.position.y) - 30,
			int(rect.size.x) + 240, int(rect.size.y) + 180)
	box = _clamp_rect(box, w, h)
	_crop(src, box).save_png(path)
	var bottom := Rect2i(0, maxi(h - 470, 0), mini(1500, w), mini(470, h))
	_save_crop(src, bottom, path.replace(".png", "_bottom.png"))
	print("[ShotInv] %s -> %s  面板 %s  裁切 %s  视口 %dx%d" % [tag, path, str(rect),
			str(box), w, h])


func _crop(src: Image, box: Rect2i) -> Image:
	var out := Image.create(box.size.x, box.size.y, false, Image.FORMAT_RGBA8)
	out.blit_rect(src, box, Vector2i.ZERO)
	return out


func _save_crop(src: Image, box: Rect2i, path: String) -> void:
	_crop(src, box).save_png(path)


func _clamp_rect(r: Rect2i, w: int, h: int) -> Rect2i:
	var out := r
	out.position.x = clampi(out.position.x, 0, maxi(w - 8, 0))
	out.position.y = clampi(out.position.y, 0, maxi(h - 8, 0))
	out.size.x = mini(out.size.x, w - out.position.x)
	out.size.y = mini(out.size.y, h - out.position.y)
	return out


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

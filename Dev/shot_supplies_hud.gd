extends Node
## ============================================================
## shot_supplies_hud — 实拍：物资 HUD 那一行在「够 / 短缺」两种状态下的文案
##
## 探针能验数值，验不了「这行字读不读得通、有没有糊出屏幕」。短缺态尤其要紧：
## 它要把「缺什么、降了哪几条属性、补上就恢复、不会死」一次讲清，字长且标红。
##
## 用法（**必须开窗**，无头是 dummy 驱动、viewport 贴图恒空）：
##   godot --path D:/SteamPunkExtraction res://Dev/shot_supplies_hud.tscn
##
## ⚠ 会走一次 `_on_launch`，开跑备份 `user://save.json`、收尾原样还原。
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const OUT_OK := OUT_DIR + "/supplies_hud_ok.png"
const OUT_BAD := OUT_DIR + "/supplies_hud_shortage.png"
const SAVE_PATH := "user://save.json"
## 左下角那两行（物资 + 背包）的裁切框
const CROP := Rect2i(0, 0, 1000, 110)

var _save_backup := ""
var _save_existed := false


func _ready() -> void:
	_backup_save()
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	for _i in range(30):
		await get_tree().process_frame

	Meta.roster = []
	Meta.seeded_ids = []
	Meta.ensure_roster()
	Config.set_override("enemy.count", 0)
	main.call("_on_launch", [{"uid": int(Meta.roster[0].get("uid", 0)),
			"id": "spearman", "name": "枪手", "level": 0}])
	var waited := 0
	while get_tree().get_nodes_in_group("player").is_empty() and waited < 400:
		await get_tree().process_frame
		waited += 1
	for _i in range(60):
		await get_tree().process_frame

	var surv: Node = get_tree().get_first_node_in_group("survival_system")
	var run: Node = get_tree().get_first_node_in_group("run_manager")
	if surv == null or run == null:
		print("[SuppliesHud] !! 没拿到生存系统 / RunManager")
		_finish()
		return
	surv.set("next_meal_in", 42.0)

	# 1) 充足态：他身上有食物（背包现在每人一份），倒计时显示"下次消耗"
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q):
			q.inventory = {"food": 3, "wood": 20, "iron": 10}
	await _shot(OUT_OK, "物资充足")

	# 2) 短缺态：扣不到 → 属性下降 + 标红长文案
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q):
			q.inventory = {}
	surv.call("_consume_tick")
	await _shot(OUT_BAD, "食物短缺")

	_restore_save()
	get_tree().quit(0)


func _shot(path: String, tag: String) -> void:
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[SuppliesHud] !! viewport 贴图为空（是不是加了 --headless？）")
		return
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	var rect := CROP
	rect.position.y = maxi(src.get_height() - rect.size.y, 0)
	rect.size.x = mini(rect.size.x, src.get_width())
	var crop := Image.create(rect.size.x, rect.size.y, false, Image.FORMAT_RGBA8)
	crop.blit_rect(src, rect, Vector2i.ZERO)
	crop.save_png(path)
	print("[SuppliesHud] %s -> %s  %dx%d" % [tag, path, crop.get_width(), crop.get_height()])


func _finish() -> void:
	_restore_save()
	get_tree().quit(1)


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

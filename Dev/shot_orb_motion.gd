extends Node
## ============================================================
## shot_orb_motion — 局内**连拍**：验证光点真的「绕角色飞 + 时隐时现」
##
## 为什么不能靠 shot2d.py 连跑几次拼图：`unit_level_badge._phase = randf()`，
## 每次启动都不同 → 不同进程里光点的轨道相位不一样，拼出来的"轨迹"是假的。
## **必须在同一个进程里、沿着同一条时间线连拍**，才能看出它真的在绕、在明灭。
##
## 用法（**必须开窗**，无头是 dummy 渲染驱动 viewport 贴图永远空白）：
##   godot --path <项目根> res://Dev/shot_orb_motion.tscn
##
## 输出：12 帧（间隔 0.45s ≈ 5.4s，正好覆盖一圈轨道）裁成 COLS×N 的网格拼图。
## 裁切以**玩家的屏幕坐标**为中心（相机跟随模式，直接按窗口中心裁会偏）。
##
## ⚠ 会走一次 `_on_launch` 且调 `Meta.ensure_roster()`，名册为空时会写存档
##   → 开跑备份 `user://save.json`、收尾原样还原（和探针同一套）。
## ⚠ 展示文字只用 ASCII：`ThemeDB.fallback_font` 不含中日韩字形。
## ============================================================

const OUT := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42/orb_motion.png"
const FRAMES := 12
const GAP := 0.45          # 帧间隔（秒）：12 × 0.45 ≈ 5.4s，覆盖一整圈（ω≈1.2 rad/s）
const HALF := 150          # 每格裁切半径（像素）
const COLS := 4
const SAVE_PATH := "user://save.json"

var _save_backup := ""
var _save_existed := false
var _main: Node = null


func _ready() -> void:
	_backup_save()
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	_main = main
	await _wait_frames(30)
	Meta.ensure_roster()
	var uid := 0
	for u in Meta.roster:
		if int(u.get("uid", 0)) > 0:
			uid = int(u.get("uid", 0))
			break
	main.call("_on_launch", [{"id": "spearman", "name": "spearman", "uid": uid, "level": 0}])
	# 等进局完成（玩家进组）＋ 画面稳定
	var waited := 0
	while get_tree().get_nodes_in_group("player").is_empty() and waited < 300:
		await get_tree().process_frame
		waited += 1
	print("[Motion] player ready after %d frames" % waited)
	await _wait_frames(50)
	await _shoot()
	_restore_save()
	get_tree().quit(0)


func _wait_frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _shoot() -> void:
	var shots: Array = []
	var center := Vector2.ZERO
	for i in range(FRAMES):
		await RenderingServer.frame_post_draw
		var im := get_viewport().get_texture().get_image()
		if im == null:
			print("[Motion] !! viewport 贴图为空（是不是加了 --headless？）")
			return
		var src := im.duplicate() as Image
		if src.get_format() != Image.FORMAT_RGBA8:
			src.convert(Image.FORMAT_RGBA8)
		shots.append(src)
		if i == 0:
			center = _player_screen_pos()
			print("[Motion] player screen pos = %s (viewport %s)"
					% [str(center), str(get_viewport().get_visible_rect().size)])
		_dump(i)
		await get_tree().create_timer(GAP).timeout
	_save_sheet(shots, center)


## 每帧打印光点的真实运行时数值 —— 「局内看不见它」这种问题只有把
## zoom / 视野系数 / 明灭 / 最终不透明度 / 轨道偏移一起摊开才能定位。
func _dump(i: int) -> void:
	var b := _player_badge()
	if b == null:
		print("[Motion] f%d  没有 LevelBadge" % i)
		return
	print("[Motion] f%-2d zoom=%.2f view_a=%.2f vis=%.3f cur_a=%.3f t=%.2f off=%s r_world=%.2f"
			% [i, float(b.get("_zoom")), float(b.call("view_alpha")),
				float(b.call("visibility")), float(b.call("current_alpha")),
				float(b.get("_t")), str(b.call("_orbit_offset")),
				float(b.call("drawn_radius_world"))])


func _player_badge() -> Node:
	var ps := get_tree().get_nodes_in_group("player")
	if ps.is_empty():
		return null
	return (ps[0] as Node).get_node_or_null("LevelBadge")


## 玩家在**屏幕**上的坐标（相机跟随，不能直接按窗口中心裁）。
func _player_screen_pos() -> Vector2:
	var ps := get_tree().get_nodes_in_group("player")
	if ps.is_empty():
		return get_viewport().get_visible_rect().size * 0.5
	var p := ps[0] as Node2D
	return get_viewport().get_canvas_transform() * p.global_position


func _save_sheet(shots: Array, center: Vector2) -> void:
	if shots.is_empty():
		print("[Motion] !! 没抓到帧")
		return
	var cw := HALF * 2
	var ch := HALF * 2
	var first: Image = shots[0]
	# 光点在角色**身体中部偏上**，裁切中心跟着抬一点，别让它出框
	var cx := int(center.x)
	var cy := int(center.y) - 24
	var x0 := clampi(cx - HALF, 0, maxi(0, first.get_width() - cw))
	var y0 := clampi(cy - HALF, 0, maxi(0, first.get_height() - ch))
	var rows := int(ceil(float(shots.size()) / float(COLS)))
	var sheet := Image.create(cw * COLS, ch * rows, false, Image.FORMAT_RGBA8)
	for i in range(shots.size()):
		sheet.blit_rect(shots[i], Rect2i(x0, y0, cw, ch),
				Vector2i(cw * (i % COLS), ch * int(i / COLS)))
	sheet.save_png(OUT)
	print("[Motion] saved %s  %dx%d  (crop at %d,%d size %d)"
			% [OUT, sheet.get_width(), sheet.get_height(), x0, y0, cw])


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

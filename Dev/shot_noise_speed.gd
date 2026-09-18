extends Node
## ============================================================
## shot_noise_speed — 局内实拍：证明「自身噪音越大，等级光点移动越快」
##
## 两行对照：**同一进程、同一条时间线**上先安静拍 8 帧、再把同一角色的
## self_noise 顶满拍 8 帧。为什么不能跑两次拼图：`_phase = randf()`，
## 每次启动相位都不同，跨进程拼出来的「轨迹」是假的（老教训）。
##
## 用法（**必须开窗**，无头是 dummy 驱动 viewport 贴图永远空白）：
##   godot --path <项目根> res://Dev/shot_noise_speed.tscn
##
## 产出：
##   noise_speed.png  上排 = 安静（1 倍速）/ 下排 = 顶满噪音（3 倍速）
##   noise_menu.png   最后一帧全屏（菜单右下那两条读数此刻都在高位）
##
## ⚠ 会走一次 `_on_launch` 且调 `Meta.ensure_roster()`，名册为空时会写存档
##   → 开跑备份 `user://save.json`、收尾原样还原。
## ============================================================

const OUT_SHEET := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42/noise_speed.png"
const OUT_FULL := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42/noise_menu.png"
const FRAMES := 8
const GAP := 0.3            # 8 × 0.3 = 2.4s
const HALF := 140           # 每格裁切半径（像素）
const LOUD := 300.0         # noise.self.max —— 顶格
const SAVE_PATH := "user://save.json"

var _save_backup := ""
var _save_existed := false


func _ready() -> void:
	_backup_save()
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _wait(30)
	Meta.ensure_roster()
	var uid := 0
	for u in Meta.roster:
		if int(u.get("uid", 0)) > 0:
			uid = int(u.get("uid", 0))
			break
	main.call("_on_launch", [{"id": "spearman", "name": "spearman", "uid": uid, "level": 0}])
	var waited := 0
	while get_tree().get_nodes_in_group("player").is_empty() and waited < 300:
		await get_tree().process_frame
		waited += 1
	await _wait(50)
	await _shoot()
	_restore_save()
	get_tree().quit(0)


func _wait(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _shoot() -> void:
	_snap_camera()
	var quiet: Array = []
	var loud: Array = []
	var centers: Array = []          # 每帧各自的裁切中心（相机平滑跟随没跟上的话，第一帧的中心会作废）
	var last_full: Image = null

	for i in range(FRAMES):
		_set_self(0.0)
		var img := await _grab()
		if img == null:
			return
		quiet.append(img)
		centers.append(_player_screen_pos())
		_dump("QUIET", i)
		await get_tree().create_timer(GAP).timeout

	for i in range(FRAMES):
		_set_self(LOUD)
		var img := await _grab()
		if img == null:
			return
		loud.append(img)
		centers.append(_player_screen_pos())
		last_full = img
		_dump("LOUD ", i)
		await get_tree().create_timer(GAP).timeout

	if last_full != null:
		last_full.save_png(OUT_FULL)
		print("[NoiseShot] saved %s" % OUT_FULL)
	_save_sheet(quiet, loud, centers)


## `await RenderingServer.frame_post_draw` 之后拿到的才是刚画完那一帧
func _grab() -> Image:
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[NoiseShot] !! viewport 贴图为空（是不是加了 --headless？）")
		return null
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	return src


## 相机是 RTS 自由相机（**不自动跟人**，按 F 才回去）—— dev 拍摄前手动对准，
## 否则玩家根本不在画面里（首跑整版全黑就是它：玩家屏幕坐标 y=-816）。
func _snap_camera() -> void:
	var cams := get_tree().get_nodes_in_group("iso_cam")
	var p := _first_player()
	if cams.is_empty() or p == null:
		print("[NoiseShot] !! 没找到相机或玩家，拍出来多半是空的")
		return
	(cams[0] as Camera2D).global_position = (p as Node2D).global_position
	# ⚠ 必须关掉边缘滚屏：自动化进程的鼠标停在 (0,0)（左上角边距内），
	# 相机会被一路拽到地图边界外 → 玩家跑出画面、整版黑（首二跑都是这么废的）。
	(cams[0] as Camera2D).set("edge_pan_enabled", false)
	await _wait(5)
	print("[NoiseShot] camera snapped to player, screen pos now %s"
			% str(_player_screen_pos()))


func _set_self(v: float) -> void:
	var ps := get_tree().get_nodes_in_group("player")
	if ps.is_empty():
		return
	(ps[0] as Node).set("self_noise", v)


## ⚠ 必须写返回类型：返回 Variant 的话调用处 `var p := _first_player()`
## 会「Cannot infer type」→ Parse Error → 脚本整个不加载（老坑，已踩第三次）。
func _first_player() -> Node:
	var ps := get_tree().get_nodes_in_group("player")
	return null if ps.is_empty() else (ps[0] as Node)


## 每帧把真实的运行时数值摊开 —— 「为什么看不到 / 为什么没变快」靠这个定位
func _dump(tag: String, i: int) -> void:
	var b := _badge()
	if b == null:
		print("[NoiseShot] %s f%d  没有 LevelBadge" % [tag, i])
		return
	var p := _first_player()
	var selfn := float(p.get("self_noise")) if p != null else -1.0
	print("[NoiseShot] %s f%-2d self=%6.1f speed=%.2f _t=%7.2f ang=%6.2f vis=%.3f"
			% [tag, i, selfn, float(b.call("noise_speed")), float(b.get("_t")),
				float(b.call("orbit_angle")), float(b.call("visibility"))])


func _badge() -> Node:
	var p := _first_player()
	return (p as Node).get_node_or_null("LevelBadge") if p != null else null


func _player_screen_pos() -> Vector2:
	var p := _first_player()
	if p == null:
		return get_viewport().get_visible_rect().size * 0.5
	return get_viewport().get_canvas_transform() * (p as Node2D).global_position


func _save_sheet(quiet: Array, loud: Array, centers: Array) -> void:
	if quiet.is_empty() or loud.is_empty():
		print("[NoiseShot] !! 没抓到帧")
		return
	var first: Image = quiet[0]
	var cw := HALF * 2
	var ch := HALF * 2
	var sheet := Image.create(cw * FRAMES, ch * 2, false, Image.FORMAT_RGBA8)
	var all: Array = quiet + loud
	for i in range(all.size()):
		# **每帧按玩家当时的屏幕位置裁**：相机平滑跟随没跟上的话，
		# 只记第一帧中心会把所有格子都裁到空地（首跑整版全黑就是这个）。
		var c: Vector2 = centers[i]
		var x0 := clampi(int(c.x) - HALF, 0, maxi(0, first.get_width() - cw))
		var y0 := clampi(int(c.y) - 20 - HALF, 0, maxi(0, first.get_height() - ch))
		var row := 0 if i < quiet.size() else 1
		var col := i if row == 0 else i - quiet.size()
		sheet.blit_rect(all[i], Rect2i(x0, y0, cw, ch), Vector2i(cw * col, ch * row))
		if i == 0:
			print("[NoiseShot] f0 center=%s crop=(%d,%d)" % [str(c), x0, y0])
	sheet.save_png(OUT_SHEET)
	print("[NoiseShot] saved %s  %dx%d" % [OUT_SHEET, sheet.get_width(), sheet.get_height()])


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

extends Node
## ============================================================
## shot_monk_inrun — 局内实拍：验收「僧侣（Monk）」接入
##
## 验三件事 —— 都是探针验不出、只能开眼看的东西：
##   1. **外观**：僧侣和另外三个角色同屏时体型/脚底是否对齐（怕 offset_y 算错导致浮空或陷地）
##   2. **四档配色**：同一角色 apply_level(0/3/6/9) 是否真的换配色（怕 gold 档路径写成
##      gold_monk 而素材目录是 yellow_monk —— `load()` 缺帧静默 null，症状是升到 9 级人没了）
##   3. **攻击动作**：Monk 官方**没有 Attack 帧**，用的是 Heal（施法）那 11 帧。
##      要确认它当作攻击动作播放时观感成立，而不是「挥空气」
##
## 用法（**必须开窗**，无头是 dummy 驱动、viewport 贴图恒空）：
##   godot --path D:/SteamPunkExtraction res://Dev/shot_monk_inrun.tscn
##
## ⚠ 会走一次 `_on_launch` 且调 `Meta.ensure_roster()`，名册空时写存档
##   → 开跑备份 `user://save.json`、收尾原样还原。
## ============================================================

const OUT_LINEUP := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42/monk_lineup.png"
const OUT_TIERS := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42/monk_tiers.png"
const OUT_ATTACK := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42/monk_attack.png"
const SAVE_PATH := "user://save.json"
const HALF := 90            # 每格裁切半径
const TIER_LEVELS := [0, 3, 6, 9]

var _save_backup := ""
var _save_existed := false


func _ready() -> void:
	_backup_save()
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _wait(30)
	Meta.ensure_roster()
	main.call("_on_launch", [
		{"id": "monk", "name": "僧侣"},
		{"id": "spearman", "name": "枪手"},
		{"id": "archer", "name": "弓兵"},
		{"id": "swordsman", "name": "剑士"},
	])
	var waited := 0
	while get_tree().get_nodes_in_group("player").size() < 4 and waited < 400:
		await get_tree().process_frame
		waited += 1
	await _wait(50)

	_dump_squad()
	await _shoot_lineup()
	await _shoot_tiers()
	await _shoot_attack()

	_restore_save()
	get_tree().quit(0)


func _wait(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


# ------------------------------------------------------------
# 1) 四人列队：验证体型一致、脚底对齐
# ------------------------------------------------------------
func _shoot_lineup() -> void:
	var ps := get_tree().get_nodes_in_group("player")
	if ps.is_empty():
		print("[Monk] !! 没生成玩家")
		return
	# 把四人并排 apostles到自己脚下的一行排开，方便一眼对比
	var anchor: Node2D = ps[0] as Node2D
	var base: Vector2 = anchor.global_position
	for i in range(ps.size()):
		var p := ps[i] as Node2D
		p.global_position = base + Vector2(float(i) * 46.0, 0.0)
		if p.has_method("cancel_commands"):
			p.call("cancel_commands")
	await _snap_camera_to(ps[0] as Node2D)
	await _wait(40)      # 站定播 idle

	var img := await _grab()
	if img == null:
		return
	img.save_png(OUT_LINEUP)
	print("[Monk] saved %s" % OUT_LINEUP)


# ------------------------------------------------------------
# 2) 四档配色：同一角色切等级，裁成一格一格
# ------------------------------------------------------------
func _shoot_tiers() -> void:
	var p := _monk()
	if p == null:
		print("[Monk] !! 没有拿到僧侣（weapon != staff）")
		return
	await _snap_camera_to(p)
	var tiles: Array = []
	var centers: Array = []
	for lv in TIER_LEVELS:
		var lv_int: int = int(lv)
		if p.has_method("apply_level"):
			p.call("apply_level", lv_int)
		await _wait(20)
		var im := await _grab()
		if im == null:
			return
		tiles.append(im)
		centers.append(_screen_pos_of(p))
		print("[Monk] tier Lv%d -> set=%-22s body=%s"
				% [lv_int, _current_set(p), _tex_path(p).get_file()])

	if tiles.size() != TIER_LEVELS.size():
		return
	var first: Image = tiles[0]
	var cw := HALF * 2
	var ch := HALF * 2
	var sheet := Image.create(cw * tiles.size(), ch, false, Image.FORMAT_RGBA8)
	for i in range(tiles.size()):
		var c: Vector2 = centers[i]
		var x0 := clampi(int(c.x) - HALF, 0, maxi(0, first.get_width() - cw))
		var y0 := clampi(int(c.y) - 24 - HALF, 0, maxi(0, first.get_height() - ch))
		sheet.blit_rect(tiles[i], Rect2i(x0, y0, cw, ch), Vector2i(cw * i, 0))
	sheet.save_png(OUT_TIERS)
	print("[Monk] saved %s  %dx%d" % [OUT_TIERS, sheet.get_width(), sheet.get_height()])


# ------------------------------------------------------------
# 3) 攻击动作：Monk 没有 Attack 帧，用的是 Heal（施法）
# ------------------------------------------------------------
func _shoot_attack() -> void:
	var p := _monk()
	if p == null:
		return
	var foe := _nearest_enemy(p)
	if foe == null:
		print("[Monk] !! 地图上没敌人，跳过攻击实拍")
		return
	# 贴到射程内让自动战斗起手（staff range_px = 140）
	var foe_pos: Vector2 = (foe as Node2D).global_position
	p.global_position = foe_pos + Vector2(70.0, 0.0)
	await _snap_camera_to(p)

	var shots: Array = []
	var centers: Array = []
	for i in range(8):
		await get_tree().create_timer(0.12).timeout
		var im := await _grab()
		if im == null:
			return
		shots.append(im)
		centers.append(_screen_pos_of(p))
		print("[Monk] atk f%-2d anim=%s frame=%s pos=%s"
				% [i, str(_current_anim(p)), _tex_path(p).get_file(),
				   str((p as Node2D).global_position - foe_pos)])

	var first: Image = shots[0]
	var cw := HALF * 2
	var ch := HALF * 2
	var cols := 4
	var rows := (shots.size() + cols - 1) / cols
	var sheet := Image.create(cw * cols, ch * rows, false, Image.FORMAT_RGBA8)
	for i in range(shots.size()):
		var c: Vector2 = centers[i]
		var x0 := clampi(int(c.x) - HALF, 0, maxi(0, first.get_width() - cw))
		var y0 := clampi(int(c.y) - 24 - HALF, 0, maxi(0, first.get_height() - ch))
		sheet.blit_rect(shots[i], Rect2i(x0, y0, cw, ch),
				Vector2i(cw * (i % cols), ch * (i / cols)))
	sheet.save_png(OUT_ATTACK)
	print("[Monk] saved %s  %dx%d" % [OUT_ATTACK, sheet.get_width(), sheet.get_height()])


# ------------------------------------------------------------
# 工具
# ------------------------------------------------------------
func _grab() -> Image:
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[Monk] !! viewport 贴图为空（是不是加了 --headless？）")
		return null
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	return src


## 相机是 RTS 自由相机**不自动跟人** + 自动化进程鼠标停在 (0,0) 会触发边缘滚屏
## 把相机一路拽出地图 —— 两个坑都会让画面变全黑，必须手动对准并关边缘滚屏。
func _snap_camera_to(p: Node2D) -> void:
	var cams := get_tree().get_nodes_in_group("iso_cam")
	if cams.is_empty() or p == null:
		print("[Monk] !! 没找到相机")
		return
	var cam: Camera2D = cams[0] as Camera2D
	cam.global_position = p.global_position
	cam.set("edge_pan_enabled", false)
	await _wait(5)


func _monk() -> Node:
	for n in get_tree().get_nodes_in_group("player"):
		if str(n.get("current_weapon")) == "staff":
			return n as Node
	return null


func _nearest_enemy(from: Node2D) -> Node:
	var best: Node = null
	var bd := 1e18
	var pos: Vector2 = from.global_position
	for n in get_tree().get_nodes_in_group("enemies"):
		var d: float = pos.distance_to((n as Node2D).global_position)
		if d < bd:
			bd = d
			best = n as Node
	return best


func _screen_pos_of(p: Node2D) -> Vector2:
	return get_viewport().get_canvas_transform() * p.global_position


## ⚠ `PlayerAnimator` 是 **RefCounted**（不是 Node）—— 按 Node 取会抛
##   `Trying to assign value of type 'RefCounted' to a variable of type 'Node'`（刚踩）。
##   所以用 Object 接，别写 `var a: Node = p.get("_animator")`。
func _animator_of(p: Node) -> Object:
	var raw = p.get("_animator")
	return null if raw == null else (raw as Object)


## 验收关键：**看「身上贴的是哪套帧」要用 texture.resource_path** ——
## 不能用纹理对象 id（换帧要等 animator 下次 update，且播放中帧号本来就在变）。
func _tex_path(p: Node) -> String:
	var a := _animator_of(p)
	if a == null:
		return "(no animator)"
	var sp: Sprite2D = a.get("_sprite") as Sprite2D
	if sp == null or sp.texture == null:
		return "(no texture)"
	return sp.texture.resource_path


func _current_set(p: Node) -> String:
	return _tex_path(p).get_base_dir().get_file()


func _current_anim(p: Node) -> String:
	var a := _animator_of(p)
	return str(a.get("_anim")) if a != null else "?"


func _dump_squad() -> void:
	for n in get_tree().get_nodes_in_group("player"):
		print("[Monk] 单位 weapon=%-7s level=%s set=%-22s first=%s"
				% [str(n.get("current_weapon")), str(n.get("level")),
				   _current_set(n), _tex_path(n).get_file()])


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

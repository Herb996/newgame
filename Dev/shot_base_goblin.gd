extends Node
## ============================================================
## shot_base_goblin — 实拍：把 Downloads/gebulin 那 4 帧哥布林放进主基地
##
## 用户要的是"把这个角色放到游戏里面去，先放到主基地"。这一步只回答两件事：
##   1) **多大**：与现役枪兵（idle_00，可见 41×90 px）并排、脚底对齐，另配 ×1.5 / ×2
##   2) **会不会动**：4 帧按 4fps 循环，每张图停在不同帧上，证明序列帧真的在切
## 生产代码一行没改，素材也不进 Assets/（走绝对路径 Image.load_from_file），
## 免得为一次试看污染工程；真要当兵种用，见报告里那条接入清单。
##
## 沿用了 shot_base_guest 踩过的四个坑：
##   · Node2D 没有 get_global_rect()（那是 Control 的）→ 自己按贴图×缩放算矩形
##   · 参照物要按 used_rect 算，320 画布四周全透明，拿画布当身高会大一倍
##   · 导入的 PNG 是 CompressedTexture2D，`as ImageTexture` 恒 null → 用 Texture2D.get_image()
##   · camera.zoom_at_cursor 为真时 frame_world_rect 会按鼠标位置把镜头推开 → 探针里关掉
##
## 用法（**必须开窗**）：
##   python tools/run_probe.py _shot_base_goblin.log Dev/shot_base_goblin.tscn --window
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const SRC_DIR := "C:/Users/Administrator/Downloads/gebulin"
const REF_FRAME := "res://Assets/Art/Sprites/Units/blue_lancer/idle_00.png"
const M_BASE := 0
const FPS := 4.0
const MULTS := [1.0, 1.5, 2.0]

var _n := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Config.set_override("display.window_mode", "windowed")
	Config.set_override("debug.auto_enter_run", false)
	Config.set_override("camera.zoom_at_cursor", false)   # 见文件头第 4 条坑

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	var waited := 0
	while int(main.get("mode")) != M_BASE and waited < 300:
		await get_tree().process_frame
		waited += 1
	if int(main.get("mode")) != M_BASE:
		print("[Gob] !! 没进基地（mode=%s）" % str(main.get("mode")))
		get_tree().quit(1)
		return
	await _frames(30)

	var game_root: Node2D = main.get("game_root")
	var tile := int(Config.get_value("map.tile_size", 64))

	# ---- 4 帧素材 ----
	var frames: Array = []
	var union := Rect2i()
	for i in range(1, 5):
		var p := "%s/%d.png" % [SRC_DIR, i]
		var img: Image = Image.load_from_file(p)
		if img == null:
			print("[Gob] !! 读不到 %s" % p)
			get_tree().quit(1)
			return
		var r: Rect2i = img.get_used_rect()
		union = r if frames.is_empty() else union.merge(r)
		frames.append(ImageTexture.create_from_image(img))
		print("[Gob] 帧 %d：%d×%d 画布，可见 %d×%d（bbox %s）" % [
				i, img.get_width(), img.get_height(), r.size.x, r.size.y, str(r)])
	print("[Gob] 四帧合并可见框 %s → 摆进场上时按这个高度对齐，不按 128 画布" % str(union))

	# ---- 找一块离基地中心最近的空地（占用格按运行时 Meta.base_layout 现算）----
	var bs: Node = main.get("base_system")
	var occ: Dictionary = bs.call("_occupied_cells", "")
	var strip := _find_strip(occ, 14, 5, int(Config.get_value("base.map_size", 64)))
	if strip.x < 0:
		print("[Gob] !! 找不到 14×5 的空地")
		get_tree().quit(1)
		return
	var base := Vector2(float(strip.x + 1) * tile, float(strip.y + 4) * tile)

	# ---- 参照物：现役枪兵，按 player 表真实 view 参数渲染 ----
	var ref: Sprite2D = Sprite2D.new()
	ref.name = "RefLancer"
	ref.texture = load(REF_FRAME)
	ref.scale = Vector2.ONE * float(Config.get_value("player.sprite_scale", 0.6))
	game_root.add_child(ref)
	ref.position = base + Vector2(0, -38.0)
	await _frames(2)
	var ref_img: Image = ref.texture.get_image()
	var ref_bbox: Rect2i = ref_img.get_used_rect()
	var ref_vis_h: float = float(ref_bbox.size.y) * ref.scale.x
	var floor_y: float = ref.global_position.y + (float(ref_bbox.end.y)
			- float(ref_img.get_height()) * 0.5) * ref.scale.x
	print("[Gob] 参照枪兵：可见 %.0f×%.0f px（%.2f 格高），脚底 y=%.0f" % [
			float(ref_bbox.size.x) * ref.scale.x, ref_vis_h, ref_vis_h / float(tile), floor_y])

	var ruler: Line2D = Line2D.new()
	ruler.width = 2.0
	ruler.closed = true
	ruler.default_color = Color(1, 1, 1, 0.85)
	ruler.points = PackedVector2Array([
			Vector2(0, 0), Vector2(tile, 0), Vector2(tile, -tile), Vector2(0, -tile)])
	ruler.position = Vector2(base.x - 1.6 * tile, floor_y)
	ruler.z_index = 200
	game_root.add_child(ruler)

	# ---- 哥布林：每个倍率一组精灵，同一画布锚点，靠换 texture 播帧 ----
	var gobs: Array = []
	var x := base.x + 1.0 * tile
	for m in MULTS:
		var s: float = (ref_vis_h * float(m)) / float(union.size.y)
		var g: Sprite2D = Sprite2D.new()
		g.name = "Goblin_x%s" % str(m)
		g.texture = frames[0]
		g.scale = Vector2.ONE * s
		# 画布居中锚点：用第一帧的可见底边落到 floor_y（四帧画布一致，切帧不会跳脚）
		g.position = Vector2(x, floor_y + (float((frames[0] as Texture2D).get_size().y) * 0.5
				- float(union.end.y)) * s)
		game_root.add_child(g)
		gobs.append(g)
		print("[Gob]   ×%-4s 可见 %.0f×%.0f px = %.2f 格高 / %.1f 格宽，scale=%.4f" % [
				str(m), float(union.size.x) * s, float(union.size.y) * s,
				float(union.size.y) * s / float(tile), float(union.size.x) * s / float(tile), s])
		x += float((frames[0] as Texture2D).get_size().x) * s + 0.8 * tile

	var layer: CanvasLayer = CanvasLayer.new()
	game_root.add_child(layer)
	var lbl: Label = Label.new()
	lbl.text = "白框=1 格 %d px｜参照=现役枪兵 %.0f px 高｜哥布林 ×1 / ×1.5 / ×2，4 帧 %.0ffps 循环" % [
			tile, ref_vis_h, FPS]
	lbl.position = Vector2(10, 8)
	lbl.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 4)
	layer.add_child(lbl)

	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam == null:
		print("[Gob] !! 没有相机")
		get_tree().quit(1)
		return
	var all := _rect_of(ref)
	for g in gobs:
		all = all.merge(_rect_of(g as Sprite2D))
	var pad := 1.4 * tile
	var row: Rect2 = Rect2(all.position - Vector2(pad, pad), all.size + Vector2(pad, pad) * 2.0)
	cam.call("frame_world_rect", row, 40.0)
	await _frames(25)

	# ---- 播帧：每张图停在不同帧上 ----
	var per := 1.0 / FPS
	for i in range(4):
		for g in gobs:
			(g as Sprite2D).texture = frames[i]
		await _frames(int(per * 60.0))
		await _shot("gob_f%d" % (i + 1), row)

	# ---- 基地全貌：看它在整张地图里的分量 ----
	var whole := float(int(Config.get_value("base.map_size", 64)) * tile)
	cam.call("frame_world_rect", Rect2(0, 0, whole, whole), 0.0)
	await _frames(25)
	await _shot("gob_wide", Rect2(0, 0, whole, whole))

	print("[Gob] 完成，共 %d 张图 -> %s" % [_n, OUT_DIR])
	get_tree().quit(0)


# ------------------------------------------------------------

func _rect_of(sp: Sprite2D) -> Rect2:
	var sz: Vector2 = sp.texture.get_size() * sp.global_scale
	return Rect2(sp.global_position - sz * 0.5, sz)


func _find_strip(occ: Dictionary, w: int, h: int, size: int) -> Vector2i:
	var mid := float(size) * 0.5
	var best := Vector2i(-1, -1)
	var best_d := INF
	for y in range(2, size - h - 2):
		for x in range(2, size - w - 2):
			var free := true
			for dy in range(h):
				for dx in range(w):
					if occ.has(Vector2i(x + dx, y + dy)):
						free = false
			if not free:
				continue
			var d := Vector2(float(x + w / 2) - mid, float(y + h / 2) - mid).length_squared()
			if d < best_d:
				best_d = d
				best = Vector2i(x, y)
	return best


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _shot(tag: String, focus: Rect2) -> void:
	_n += 1
	await RenderingServer.frame_post_draw
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam != null:
		print("[Gob]   相机 pos=%s zoom=%.2f（焦点中心 %s）" % [
				str(cam.global_position), cam.zoom.x, str(focus.get_center())])
	var im: Image = get_viewport().get_texture().get_image()
	if im == null:
		print("[Gob] !! viewport 贴图为空（忘了 --window？）")
		return
	var path := "%s/%s_%02d_%s.png" % [OUT_DIR, "base", _n, tag]
	print("[Gob] %s -> %s err=%d" % [tag, path, im.save_png(path)])

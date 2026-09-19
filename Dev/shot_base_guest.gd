extends Node
## ============================================================
## shot_base_guest — 实拍：把 Demo/2.png 那张高清立绘摆进主基地看效果
##
## 背景：用户从特效清单 ④（混进来的非特效）里挑了 Demo 包的 2.png，说"放到主基地一下"。
## 这张图只回答一个问题：**这张画的尺寸/画风摆在基地里是什么观感**，不改任何生产代码。
##
## 为了让"多大"这件事有可比性，画面里同时摆：
##   · 现役枪兵的一帧 idle（按 player 表真实 scale 0.6 / offset_y -38 渲染）= 参照物
##   · 一个 64px 方框 = 一格（map.tile_size），基地里建筑占地是 4×4 格
##   · 客人三个尺寸：与枪兵同高 / 2 倍 / 4 倍
## 每样都打印世界矩形（_rect_of：贴图尺寸 × 全局缩放），图上的大小差必须能用数字对上。
##
## 素材走 Image.load_from_file（绝对路径）→ ImageTexture，**不进 Assets、不生成 .import**，
## 免得为一张试看的图污染工程资源（要真用再拷进 Assets 让编辑器导入）。
##
## 用法（**必须开窗**，无头是 dummy 驱动、viewport 贴图恒空）：
##   python tools/run_probe.py _shot_base_guest.log Dev/shot_base_guest.tscn --window
##
## ⚠ 本文件里所有节点变量都写显式类型：`var x := Sprite2D.new()` 推不出类型，
##   会让后面一整串 := 连锁报 "Cannot infer the type"，而探针的解析错误是静默的
##   （脚本没加载 → 不退出 → 看起来像卡死）。
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const GUEST_PATH := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42/_guest_2.png"
const REF_FRAME := "res://Assets/Art/Sprites/Units/blue_lancer/idle_00.png"
const M_BASE := 0

## 客人相对"枪兵画布高度"的倍数
const GUEST_MULTS := [1.0, 2.0, 4.0]

var _n := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Config.set_override("display.window_mode", "windowed")
	Config.set_override("display.resolution", [1280, 720])
	Config.set_override("debug.auto_enter_run", false)
	## ⚠ 必须关：frame_world_rect 内部走 _apply_zoom，而 zoom_at_cursor 为真时它会按
	## 「鼠标当前所在点」反向补偿相机位置（人手缩放要钉住光标下的地图点）。自动化窗口
	## 里鼠标停在角落，这一补偿就把镜头从目标上推开几百像素 —— 第一张"近景"拍出来是一
	## 整屏草皮，就是这个原因。
	Config.set_override("camera.zoom_at_cursor", false)

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	var waited := 0
	while int(main.get("mode")) != M_BASE and waited < 300:
		await get_tree().process_frame
		waited += 1
	if int(main.get("mode")) != M_BASE:
		print("[Guest] !! 没进基地（mode=%s）" % str(main.get("mode")))
		get_tree().quit(1)
		return
	await _frames(30)

	var game_root: Node2D = main.get("game_root")
	var tile := int(Config.get_value("map.tile_size", 64))
	print("[Guest] 基地就绪：格宽 %d px，GameRoot 子节点 %d 个" % [tile, game_root.get_child_count()])

	# ---- 找一条没有建筑的草地横带（建筑位置可能被存档 Meta.base_layout 改过，
	#      所以按运行时的占用格现算，不抄 config 的默认 cell）----
	var bs: Node = main.get("base_system")
	var occ: Dictionary = bs.call("_occupied_cells", "")
	var strip := _find_strip(occ, 14, 5, int(Config.get_value("base.map_size", 64)))
	if strip.x < 0:
		print("[Guest] !! 找不到 14×5 的空地")
		get_tree().quit(1)
		return
	var base := Vector2(float(strip.x + 1) * tile, float(strip.y + 4) * tile)
	print("[Guest] 空地左上格 %s → 摆放基线世界坐标 %s" % [str(strip), str(base)])

	# ---- 参照物：现役枪兵一帧，按 player 表的真实 view 参数渲染 ----
	var ref: Sprite2D = Sprite2D.new()
	ref.name = "RefLancer"
	ref.texture = load(REF_FRAME)
	ref.scale = Vector2.ONE * float(Config.get_value("player.sprite_scale", 0.6))
	game_root.add_child(ref)
	ref.position = base + Vector2(0, -38.0)   # player.sprite_offset_y
	await _frames(2)
	var ref_rect: Rect2 = _rect_of(ref)
	## ⚠ 参照物要按**看得见的那一段**算，不是按画布：idle_00 是 320×320 的画布，
	## 人物只占中间 69×150，四周全透明。拿画布高当"士兵身高"会把客人放大一倍多
	## （第一版就栽在这儿：标着 ×1 的图其实比士兵高 2.1 倍）。
	var ref_bbox := Rect2i(0, 0, int(ref_rect.size.x / ref.scale.x), int(ref_rect.size.y / ref.scale.x))
	## ⚠ 用 Texture2D.get_image()，别写 `as ImageTexture`：导入进来的 PNG 是
	## CompressedTexture2D，那个 as 恒为 null，可见框会静默退化成整张画布。
	var ref_img: Image = ref.texture.get_image()
	if ref_img != null:
		ref_bbox = ref_img.get_used_rect()
	var ref_vis_h: float = float(ref_bbox.size.y) * ref.scale.x
	var ref_vis_w: float = float(ref_bbox.size.x) * ref.scale.x
	var floor_y := ref.global_position.y + (float(ref_bbox.end.y)
			- float((ref.texture as Texture2D).get_size().y) * 0.5) * ref.scale.x   # 士兵可见脚底
	print(("[Guest] 参照枪兵：画布 %s × scale %.2f = %.0f×%.0f px，但**可见部分只有 %.0f×%.0f px"
			+ "（%.2f 格高）**，可见脚底 y=%.0f") % [str((ref.texture as Texture2D).get_size()),
			ref.scale.x, ref_rect.size.x, ref_rect.size.y,
			ref_vis_w, ref_vis_h, ref_vis_h / float(tile), floor_y])

	# ---- 一格标尺 ----
	var ruler: Line2D = Line2D.new()
	ruler.name = "Ruler1Tile"
	ruler.width = 2.0
	ruler.closed = true
	ruler.default_color = Color(1, 1, 1, 0.85)
	ruler.points = PackedVector2Array([
			Vector2(0, 0), Vector2(tile, 0), Vector2(tile, -tile), Vector2(0, -tile)])
	ruler.position = Vector2(base.x - 1.6 * tile, floor_y)
	ruler.z_index = 200
	game_root.add_child(ruler)

	# ---- 客人 ----
	var img: Image = Image.load_from_file(GUEST_PATH)
	if img == null:
		print("[Guest] !! 读不到 %s" % GUEST_PATH)
		get_tree().quit(1)
		return
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	var bbox: Rect2i = img.get_used_rect()
	print("[Guest] 素材：画布 %d×%d，有像素范围 %d×%d（透明边 左%d 上%d 下%d 右%d）" % [
			img.get_width(), img.get_height(), bbox.size.x, bbox.size.y,
			bbox.position.x, bbox.position.y,
			img.get_height() - bbox.end.y, img.get_width() - bbox.end.x])

	var guests: Array = []
	var x := base.x + 1.0 * tile
	for m in GUEST_MULTS:
		var want: float = ref_vis_h * float(m)               # 想要的"可见高度"（以士兵为准）
		var s: float = want / float(bbox.size.y)            # 按可见高度折算缩放
		var g: Sprite2D = Sprite2D.new()
		g.name = "Guest_x%s" % str(m)
		g.texture = tex
		g.scale = Vector2.ONE * s
		# 画布是居中锚点：可见底边在中心"下方"，所以中心要抬到 floor_y 之上
		g.position = Vector2(x, floor_y + (float(img.get_height()) * 0.5 - float(bbox.end.y)) * s)
		game_root.add_child(g)
		guests.append(g)
		var r: Rect2 = _rect_of(g)
		var vis_bottom: float = g.global_position.y + (float(bbox.end.y)
				- float(img.get_height()) * 0.5) * s
		print("[Guest]   ×%-4s 可见 %.0f×%.0f px = %.2f 格高 / %.1f 格宽，画布框 %.0f×%.0f，scale=%.4f，可见脚底与士兵差 %.1f px" % [
				str(m), float(bbox.size.x) * s, float(bbox.size.y) * s,
				float(bbox.size.y) * s / float(tile), float(bbox.size.x) * s / float(tile),
				r.size.x, r.size.y, s, vis_bottom - floor_y])
		x += r.size.x + 0.8 * tile

	# ---- 图例（叠在窗口左上，方便对着图念数字）----
	var layer: CanvasLayer = CanvasLayer.new()
	game_root.add_child(layer)
	var lbl: Label = Label.new()
	lbl.text = "参照=现役枪兵看得见的身高 %.0f px（%.1f 格）｜白框=1 格 %d px｜客人 = 枪兵的 ×1 / ×2 / ×4" % [
			ref_vis_h, ref_vis_h / float(tile), tile]
	lbl.position = Vector2(10, 8)
	lbl.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 4)
	layer.add_child(lbl)

	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam == null:
		print("[Guest] !! 场景里没有相机")
		get_tree().quit(1)
		return

	# ---- 三张图：近景（枪兵 vs 同高客人）/ 中景（整排）/ 全景（基地全貌）----
	var g0: Rect2 = _rect_of(guests[0] as Sprite2D)
	var g1: Rect2 = _rect_of(guests[1] as Sprite2D)
	var both: Rect2 = ref_rect.merge(g0)
	var pad := 1.2 * tile
	var close: Rect2 = Rect2(both.position - Vector2(pad, pad), both.size + Vector2(pad, pad) * 2.0)
	cam.call("frame_world_rect", close, 40.0)
	await _frames(20)
	await _shot("guest_close", close)

	var all: Rect2 = ref_rect.merge(g0).merge(g1).merge(
			_rect_of(guests[guests.size() - 1] as Sprite2D))
	var row: Rect2 = Rect2(all.position - Vector2(pad, pad), all.size + Vector2(pad, pad) * 2.0)
	cam.call("frame_world_rect", row, 40.0)
	await _frames(20)
	await _shot("guest_row", row)

	var whole := float(int(Config.get_value("base.map_size", 64)) * tile)
	cam.call("frame_world_rect", Rect2(0, 0, whole, whole), 0.0)
	await _frames(25)
	await _shot("guest_wide", Rect2(0, 0, whole, whole))

	print("[Guest] 完成，共 %d 张图 -> %s" % [_n, OUT_DIR])
	get_tree().quit(0)


# ------------------------------------------------------------

## Sprite2D 的世界矩形：贴图尺寸 × 全局缩放，锚点在画布中心。
## ⚠ Node2D 没有 get_global_rect()（那是 Control 的方法），直接调会在半路报
##   "Nonexistent function 'get_global_rect' in base 'Sprite2D'"，探针就此挂住。
func _rect_of(sp: Sprite2D) -> Rect2:
	var sz: Vector2 = sp.texture.get_size() * sp.global_scale
	return Rect2(sp.global_position - sz * 0.5, sz)


## 在 size×size 的基地里找一块 w×h 全空的格子带，取**离基地中心最近**的那块：
## 摆在建制中间才看得出"和建筑放一起是什么比例"，贴着地图边的话取景会被相机的
## 边界夹住，构图整个偏掉。（占用格按运行时的 Meta.base_layout 算，不抄 config。）
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
		print("[Guest]   相机实际 pos=%s zoom=%.2f（焦点矩形中心 %s）" % [
				str(cam.global_position), cam.zoom.x, str(focus.get_center())])
	var im: Image = get_viewport().get_texture().get_image()
	if im == null:
		print("[Guest] !! viewport 贴图为空（忘了 --window？）")
		return
	var path := "%s/base_guest_%02d_%s.png" % [OUT_DIR, _n, tag]
	print("[Guest] %s %dx%d（焦点世界矩形 %s）-> %s err=%d" % [
			tag, im.get_width(), im.get_height(), str(focus), path, im.save_png(path)])

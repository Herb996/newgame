extends Node
## ============================================================
## terrain_sandbox_shot —— Terrain Set 自动过渡的**窗口实拍**（必须开窗跑）
##
## 数值全绿不等于画面对：这里把 terrain_sandbox.gd 存下来的那张图真开一个窗口
## 渲出来，量给你看四张：
##   ① 整图（两层都开）：亮草岛压在青苔上，交界只有一条描边、没有洞
##   ② 交界特写（两层都开）：过渡块是圆角收边，不是阶梯状硬跳
##   ③④ 同样两张，但**关掉背景层**、底下垫洋红 —— 收边那格被切开的角立刻变洋红，
##      证明"blob 的切边是透明的、必须有一层实心背景垫在下面"不是玄学。
##      缺口一直都在，只是平时被背景层填上，所以 ① 和 ③ 看着几乎一样。
##
## 用法：python tools/run_probe.py _terrain_shot.log res://Dev/terrain_sandbox_shot.tscn --window
## ============================================================

const SCENE := "res://Dev/terrain_sandbox.tscn"
const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-14-22-35-14"
const TILE := 64
const GRID_W := 24
const GRID_H := 16

var _n := 0
var _bad := 0
var _lines: Array = []


func _ready() -> void:
	Config.set_override("display.window_mode", "windowed")
	var packed: PackedScene = load(SCENE)
	if packed == null:
		_die("加载不到 %s（先跑 terrain_sandbox_build.tscn 生成）" % SCENE)
		return
	var map := packed.instantiate()
	add_child(map)
	var bg := map.get_node("Background") as TileMapLayer
	var terrain := map.get_node("Terrain") as TileMapLayer
	if bg == null or terrain == null:
		_die("场景里没有 Background / Terrain 两层")
		return

	# 量：用的格数、图层实际占用的矩形，都要和铺图时一致
	var used: Rect2i = terrain.get_used_rect()
	_check(used == Rect2i(0, 0, GRID_W, GRID_H),
			"Terrain 层 used_rect = %s，期望 %s" % [str(used), str(Rect2i(0, 0, GRID_W, GRID_H))])
	var cells := terrain.get_used_cells().size()
	_check(cells == GRID_W * GRID_H, "Terrain 层铺了 %d 格，期望 %d" % [cells, GRID_W * GRID_H])
	print("[TerrainShot] 窗口尺寸 %s（跑的时候请确认它真的是开窗，不是 headless）" % [
			str(get_viewport().get_visible_rect().size)])

	var cam := Camera2D.new()
	cam.name = "ShotCam"
	map.add_child(cam)
	cam.make_current()

	var world_rect := _world_rect(terrain)
	print("[TerrainShot] 地图世界矩形 %s（一格 %d px）" % [str(world_rect), TILE])

	# 洋红底：blob 被切开的那一侧是**透明**的，垫在下面的是背景层还是洋红，一眼可辨
	var magenta := ColorRect.new()
	magenta.color = Color(0.90, 0.10, 0.75)
	magenta.position = world_rect.position - Vector2(4 * TILE, 4 * TILE)
	magenta.size = world_rect.size + Vector2(8 * TILE, 8 * TILE)
	magenta.z_index = -100
	map.add_child(magenta)

	# 圆岛边界特写（圆心在格 (6,5)）
	var focus := Rect2(Vector2(2.0 * TILE, 1.0 * TILE), Vector2(9.5 * TILE, 8.5 * TILE))

	# ①② 两层都开：整图 + 交界特写
	_label(map, world_rect.position + Vector2(0, -34),
			"① 整图 · 两层都开：亮草(A)岛压在青苔(B)上")
	_frame(cam, world_rect)
	await _shot("full", world_rect)
	_label(map, focus.position + Vector2(0, -30), "② 交界特写 · 两层都开：一条收边描边，没有第二道、也没有硬跳")
	_frame(cam, focus)
	await _shot("closeup", focus)

	# ③④ 关掉背景层：同样两张，切开的角从"青苔绿"变成"洋红" ⇒ 缺口一直是有的，
	#     只是平时被背景层填上了。这就是"必须垫一层实心背景"的实拍证据。
	bg.visible = false
	_label(map, world_rect.position + Vector2(0, -34),
			"③ 整图 · 关掉背景层（洋红底）")
	_frame(cam, world_rect)
	await _shot("no_background", world_rect)
	_label(map, focus.position + Vector2(0, -30),
			"④ 交界特写 · 关掉背景层：收边那格切开的角露出洋红 = 透明缺口")
	_frame(cam, focus)
	await _shot("closeup_no_bg", focus)
	bg.visible = true

	print("[TerrainShot] %s" % "\n".join(_lines))
	print("[TerrainShot] 共 %d 张图 -> %s；不符 %d 项" % [_n, OUT_DIR, _bad])
	get_tree().quit(0 if _bad == 0 else 1)


## TileMapLayer 的 used_rect → 世界像素矩形（map_to_local 给的是格中心，往外扩半格）
func _world_rect(layer: TileMapLayer) -> Rect2:
	var r: Rect2i = layer.get_used_rect()
	var top_left: Vector2 = layer.map_to_local(r.position) - Vector2(TILE, TILE) * 0.5
	return Rect2(top_left, Vector2(float(r.size.x) * TILE, float(r.size.y) * TILE))


func _frame(cam: Camera2D, r: Rect2) -> void:
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var z: float = minf(vs.x / r.size.x, vs.y / r.size.y)
	cam.zoom = Vector2(z, z)
	cam.global_position = r.get_center()
	print("[TerrainShot]   取景 %s → zoom=%.3f（窗口 %s）" % [str(r.size), z, str(vs)])


func _label(at_node: Node, at: Vector2, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.position = at
	lbl.add_theme_color_override("font_color", Color(1, 0.92, 0.45))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 4)
	at_node.add_child(lbl)


func _check(ok: bool, msg: String) -> void:
	_lines.append("  %s %s" % ["OK  " if ok else "!!  ", msg])
	if not ok:
		_bad += 1


func _shot(tag: String, focus: Rect2) -> void:
	_n += 1
	await RenderingServer.frame_post_draw
	var im: Image = get_viewport().get_texture().get_image()
	if im == null:
		_lines.append("!!  viewport 贴图为空（忘了 --window？）")
		_bad += 1
		return
	var path := "%s/terrain_%02d_%s.png" % [OUT_DIR, _n, tag]
	var err := im.save_png(path)
	_lines.append("  %s %s：%dx%d 焦点 %s → %s err=%d" % [
			"OK  " if err == OK else "!!  ", tag, im.get_width(), im.get_height(),
			str(focus.size), path.get_file(), err])
	if err != OK:
		_bad += 1


func _die(msg: String) -> void:
	push_error("[TerrainShot] " + msg)
	get_tree().quit(1)

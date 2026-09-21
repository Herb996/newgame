extends Node
## ============================================================
## shot_base_grid — 基地实拍：验收「扩到 80×80 后 12 栋按新 5×4 网格摆出来了」
##
## 只进基地（Main._ready 默认 _enter_base），逐栋打印运行时 cell 与贴图，
## 再出两张图：框住整片 80×80 的远景 + 中央广场特写。**必须开窗**
## （无头是 dummy 驱动、贴图恒空）。
##
## ⚠ 老坑三连：① 相机不自动跟东西 → 手动定位；② 自动化进程鼠标在 (0,0)
##   → 边缘滚屏会把相机拽出地图 → 关掉；③ 出厂 config 的
##   debug.auto_enter_run=true 必须关掉，否则进基地立刻被拉进局、建筑全没。
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/ref_style/"
## 新出厂网格（Data/config/run.json 的 base.buildings 为准）
const EXPECTED := {
	"archery": Vector2i(12, 21), "barracks": Vector2i(25, 21), "gate": Vector2i(38, 21),
	"tower": Vector2i(51, 21), "catapult": Vector2i(64, 21),
	"warehouse": Vector2i(12, 33), "statue": Vector2i(25, 33), "portal": Vector2i(38, 33),
	"house2": Vector2i(64, 33),
	"farm": Vector2i(12, 45), "house3": Vector2i(25, 45), "quarry": Vector2i(51, 45),
}
## 屋顶从占地顶边向上探出的格数（building.gd 的 1.4 倍上限 → 实测约 1.6）
const ROOF_OVERHANG := 2.0

var _fails := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	Config.set_override("debug.auto_enter_run", false)
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _wait(80)

	var cams := get_tree().get_nodes_in_group("iso_cam")
	if cams.is_empty():
		print("[Grid] !! 没找到相机")
		get_tree().quit(1)
		return
	var cam: Camera2D = cams[0] as Camera2D
	cam.set("edge_pan_enabled", false)

	var tile := float(Config.get_value("map.tile_size", 64))
	var size := int(Config.get_value("base.map_size", 64))
	print("[Grid] base.map_size = %d，layout_version = %d" % [
			size, int(Config.get_value("base.layout_version", 1))])

	var seen := {}
	for b in get_tree().get_nodes_in_group("buildings"):
		var id := str(b.get("building_id"))
		var cell: Vector2i = b.get("cell")
		seen[id] = cell
		var body := b.get_node_or_null("Body") as Sprite2D
		var tex := "(null)"
		if body != null and body.texture != null:
			tex = "%s %s k=%.2f" % [body.texture.resource_path.get_file(),
					str(body.texture.get_size()), body.scale.x]
			if body.texture.get_size().x <= 0.0:
				_fails += 1
				print("[Grid] !! %-10s 贴图尺寸为 0（没导入？）" % id)
		var want: Vector2i = EXPECTED.get(id, Vector2i(-9, -9))
		var ok := want == cell
		if not ok:
			_fails += 1
		print("[Grid] %-10s cell=%-12s %s %s" % [id, str(cell), tex, "" if ok else "!! 期望 %s" % str(want)])
	for id in EXPECTED.keys():
		if not seen.has(id):
			_fails += 1
			print("[Grid] !! 少一栋建筑：%s" % id)
	print("[Grid] 运行时建筑 %d 栋（应为 %d）" % [seen.size(), EXPECTED.size()])

	# 远景 = 玩家进基地真的看到的那一帧（main._enter_base 走同一个函数）。
	# ⚠ 别改成手动设 zoom：camera_controller._refresh_zoom_limits 的 _zoom_lo 按
	#   「视口宽 ÷ 地图宽」收口，16:9 下正方形地图的 zoom 设多小都会被夹回 0.375，
	#   纵向只能看到约 45/80 格 —— 这是相机策略，不是扩图引入的回归。
	cam.call("frame_world_rect", Rect2(0, 0, size * tile, size * tile), 0.0)
	await _wait(20)
	var vp: Vector2 = get_viewport().get_visible_rect().size
	print("[Grid] 进基地远景 zoom=%.3f → 覆盖 %.0f×%.0f 格 / 地图 %d×%d" % [
			cam.zoom.x, vp.x / cam.zoom.x / tile, vp.y / cam.zoom.y / tile, size, size])

	# 真正的验收点：视野纵向只有 map_h × (vp.y/vp.x) 格（相机按「宽度铺满」收口），
	# 所以建筑全在地图内 ≠ 全在画面内。少这一条，行距回到 18 也会报「全部通过」。
	var band_h := float(size) * vp.y / vp.x
	var band_top := float(size) * 0.5 - band_h * 0.5
	var band_bot := float(size) * 0.5 + band_h * 0.5
	print("[Grid] 纵向可视带 y∈[%.1f, %.1f]（%.0f 格）" % [band_top, band_bot, band_h])
	for id in EXPECTED.keys():
		var cell: Vector2i = seen.get(id, Vector2i(-9, -9))
		var top := float(cell.y) - ROOF_OVERHANG
		var bottom := float(cell.y + 4)
		if top < band_top or bottom > band_bot:
			_fails += 1
			print("[Grid] !! %-10s 出画：占位 y∈[%.1f, %.1f] 不在 [%.1f, %.1f]" % [
					id, top, bottom, band_top, band_bot])
		else:
			print("[Grid]    %-10s 入画 y∈[%.1f, %.1f]" % [id, top, bottom])
	var wide := await _grab()
	_save(wide, "grid_wide.png")

	# 走相机自己的 zoom_to / focus_world_pos：直接写 cam.zoom 会被 _step_zoom 拉回
	# 上一个平滑目标，直接写 global_position 会被位置平滑拽回图中心（实拍偏了半屏）。
	cam.call("zoom_to", 0.9)          # 中央广场：传送门 + 修道院 + 仓库
	cam.call("focus_world_pos", Vector2(40.0, 36.0) * tile)
	await _wait(12)
	var center := await _grab()
	_save(center, "grid_center.png")

	print("[Grid] %s" % ("FAIL = %d" % _fails if _fails > 0 else "全部通过"))
	get_tree().quit(1 if _fails > 0 else 0)


func _save(img: Image, name: String) -> void:
	if img == null:
		_fails += 1
		return
	var p := OUT_DIR + name
	img.save_png(p)
	print("[Grid] saved %s" % p)


func _wait(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[Grid] !! viewport 贴图为空（是不是 --headless？）")
		return null
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	return src

extends Node
## ============================================================
## shot_base_anim — 基地动画建筑实拍：采石场（滚轮）/ 传送门（漩涡）
##
## 每栋拍**两张不同时刻**的图：序列帧有没有真的动、动起来有没有跳/抖/闪，
## 静态图看不出来，必须前后两帧对比。最后补一张全景确认它们在基地里的位置。
##
## ⚠ 必须开窗（无头是 dummy 驱动、viewport 贴图恒空），相机不自动跟随 → 手动定位。
##
## 用法：python tools/run_godot_headless.py _shot_base_anim.log \
##           Dev/shot_base_anim.tscn --window --resolution 1600x900
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-21-22-02-00"


func _ready() -> void:
	Config.set_override("debug.auto_enter_run", false)
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _wait(80)

	var cams := get_tree().get_nodes_in_group("iso_cam")
	if cams.is_empty():
		print("[BaseAnimShot] !! 没找到相机")
		get_tree().quit(1)
		return
	var cam: Camera2D = cams[0] as Camera2D
	cam.set("edge_pan_enabled", false)
	# ⚠ 两个坑一起躲（踩过）：① 直接给 zoom 赋值没用，camera_controller 每帧
	#   _step_zoom 会把 zoom 平滑拉回它自己的 _zoom_target → 必须走 zoom_to()；
	#   ② 缩放平滑期每一帧都按"光标锚定"补偿相机位置，而自动化进程鼠标恒在 (0,0)，
	#   几十次补偿累积下来能把镜头推到千里之外（上一版实拍"画面中心是空地"就是这个）。
	cam.set("zoom_at_cursor", false)

	var tile := float(Config.get_value("map.tile_size", 64))
	# 两栋动画建筑的格位（Data/config/run.json → base.buildings）
	await _shoot_pair(cam, "quarry", Vector2(51.0, 45.0), tile, 1.6)
	await _shoot_pair(cam, "portal", Vector2(38.0, 33.0), tile, 1.6)

	# 全景：确认动画建筑在基地构图里的位置和大小有没有突兀
	_aim(cam, Vector2(38.0, 38.0), tile, 0.5)
	await _wait(20)
	await _grab(OUT_DIR + "/base_anim_full.png")
	get_tree().quit(0)


## 同一栋连拍两张（中间隔一段不是 fps 整数倍的时间 → 必然落在不同帧上）
func _shoot_pair(cam: Camera2D, tag: String, cell: Vector2, tile: float, zoom: float) -> void:
	var cells := float(Config.get_value("base.building_cells", 4))
	_aim(cam, cell + Vector2(cells * 0.5, cells * 0.5), tile, zoom)
	await _wait(25)
	await _grab("%s/base_anim_%s_a.png" % [OUT_DIR, tag])
	await _wait(9)
	await _grab("%s/base_anim_%s_b.png" % [OUT_DIR, tag])


## 定镜头：中心格 + 放大倍数。先 zoom_to（走限位、改 _zoom_target）再 focus_world_pos
## （立刻落位、重置平滑），顺序反了会被下一步的边界/平滑再拽一次。
func _aim(cam: Camera2D, center_cell: Vector2, tile: float, zoom: float) -> void:
	cam.call("zoom_to", zoom)
	cam.call("focus_world_pos", center_cell * tile)


func _wait(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _grab(path: String) -> void:
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[BaseAnimShot] !! viewport 贴图为空（是不是 --headless？）")
		return
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	var err := src.save_png(path)
	print("[BaseAnimShot] %s -> err=%d（0=成功）" % [path, err])

extends Node
## ============================================================
## shot_base_buildings — 基地实拍：验收「8 栋 Tiny Swords 建筑都摆出来了」
##
## 只进基地（Main._ready 默认 _enter_base），把相机拉到能看全建筑群，
## 抓一张全屏 + 建筑群特写。**必须开窗**（无头是 dummy 驱动、贴图恒空）。
##
## ⚠ 老坑三连都按规矩处理：① 相机不自动跟任何东西 → 手动定位；
##   ② 自动化进程鼠标在 (0,0) → 边缘滚屏会把相机拽出地图 → 关掉；
##   ③ 每帧打印运行时数值，否则「图里为什么少一栋」没法定位。
## ============================================================

const OUT_FULL := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42/base_full.png"
const OUT_ZOOM := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42/base_zoom.png"


func _ready() -> void:
	# 出厂 config 的 debug.auto_enter_run = true（headless 回归用），
	# 不关掉的话进基地立刻被拉进局、game_root 被清空 → 建筑全没了（刚踩）。
	Config.set_override("debug.auto_enter_run", false)
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _wait(80)      # 基地 tilemap + 建筑生成

	var cams := get_tree().get_nodes_in_group("iso_cam")
	if cams.is_empty():
		print("[BaseShot] !! 没找到相机")
		get_tree().quit(1)
		return
	var cam: Camera2D = cams[0] as Camera2D
	cam.set("edge_pan_enabled", false)

	# 建筑群几何中心：仓库(24,30)…大门(30,45)、塔(46,33) → 约 (34, 32) 格
	var tile := float(Config.get_value("map.tile_size", 64))
	var center := Vector2(34.0, 32.0) * tile
	cam.global_position = center
	cam.zoom = Vector2(0.55, 0.55)     # 拉远看全 8 栋
	await _wait(20)
	var img := await _grab()
	if img == null:
		get_tree().quit(1)
		return
	img.save_png(OUT_FULL)
	print("[BaseShot] saved %s" % OUT_FULL)

	cam.zoom = Vector2(1.0, 1.0)       # 拉近看细节
	await _wait(10)
	var img2 := await _grab()
	if img2 != null:
		img2.save_png(OUT_ZOOM)
		print("[BaseShot] saved %s" % OUT_ZOOM)

	# 运行时清单：8 栋是否都实例化了、贴图是否真的加载（空 texture = 缺图）
	var n := 0
	for b in get_tree().get_nodes_in_group("buildings"):
		var body: Sprite2D = b.get_node_or_null("Body") as Sprite2D
		var tex := body.texture.resource_path.get_file() if body != null and body.texture != null else "(null!)"
		print("[BaseShot] 建筑 %-10s %-8s cell=%s tex=%s"
				% [str(b.get("building_id")), str(b.get("display_name")),
				   str(b.get("cell")), tex])
		n += 1
	print("[BaseShot] 建筑总数 = %d（应为 8）" % n)
	get_tree().quit(0)


func _wait(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[BaseShot] !! viewport 贴图为空（是不是 --headless？）")
		return null
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	return src

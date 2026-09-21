extends Node
## ============================================================
## shot_base_ui — 主基地界面实拍（给"界面优化方案"当证据用）
##
## 出四张图：基地全景 / 仓库面板 / 升级面板 / 选人面板。
## 必须开窗跑（无头是 dummy 驱动，贴图与 Control 都画不出来）。
##
## 老坑三连（见 shot_base_buildings 注释 + DESIGN §2.4）：
##   ① debug.auto_enter_run=true 会把人立刻拉进局 → 基地被清空
##   ② debug.smoke_test=true 会在 main._ready 里早退出自检 → 探针跑不到
##   ③ 自动化进程鼠标在 (0,0) → 边缘滚屏把相机拽出地图 → 关掉
## ============================================================

const OUT_DIR := "C:/Users/Administrator/.qwenworkcn/workspace/mu9u0poaolyzy691/shots"


func _ready() -> void:
	Config.set_override("debug.auto_enter_run", false)
	Config.set_override("debug.smoke_test", false)
	if not DirAccess.dir_exists_absolute(OUT_DIR):
		DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _wait(90)          # 基地 tilemap + 8 栋建筑 + 相机 frame

	var cams := get_tree().get_nodes_in_group("iso_cam")
	if cams.is_empty():
		print("[BaseUI] !! 没找到相机")
		get_tree().quit(1)
		return
	var cam: Camera2D = cams[0] as Camera2D
	cam.set("edge_pan_enabled", false)
	await _wait(10)
	# 基地地面靠「临时压 map.* 覆盖」跑生成器（base_system._build_ground）。
	# 覆盖是进程级全局的，漏清一次就会把局内地图也变成 64×64 的基地地形，
	# 而这件事在基地画面上完全看不出来 —— 只能这样直接查。
	_say("生成基地后残留的 Config 覆盖 = %s（应为 []）" % str(Config.override_paths()))
	await _shot(main, "01_base_overview.png")

	# 自定义地面的第一不变量：**每次进基地长得一模一样**（摆件用的是格子坐标的稳定
	# hash 抖动，不是每局重掷的 RNG）。重进一次比节点数，变了就说明有人把随机塞回来了。
	var props1 := _count_under(main, "BaseProps")
	main.call("_enter_base")
	await _wait(60)
	var props2 := _count_under(main, "BaseProps")
	_say("两次进基地：摆件节点 %d / %d（必须相等）" % [props1, props2])

	# ⚠ _enter_base() 每次都新建一台相机，上面那个 cam 已经被释放了 —— 重新取
	var cams2 := get_tree().get_nodes_in_group("iso_cam")
	if cams2.is_empty():
		print("[BaseUI] !! 重进基地后找不到相机")
		get_tree().quit(1)
		return
	cam = cams2[0] as Camera2D
	cam.set("edge_pan_enabled", false)

	# 建筑名字标签在缩得极远时看不清 → 补一张中等距离特写
	cam.zoom = Vector2(0.9, 0.9)
	cam.global_position = Vector2(34.0, 32.0) * float(Config.get_value("map.tile_size", 64))
	await _wait(10)
	await _shot(main, "02_base_zoom.png")
	cam.set("edge_pan_enabled", false)

	# 仓库塞点货（只在内存里，不调 save_game 就不落盘）：空仓库看不出列表行、
	# 也看不出「快满」的告警色；升级面板的费用够/不够两种配色同样依赖它。
	Meta.bank = {"wood": 30, "stone": 40, "iron": 60, "gold": 2, "oil": 1000}

	# 三个面板：直接调各自 open()（与 main._on_building_interacted 的路由同一条路径）
	await _panel_shot(main.warehouse_panel, "03_warehouse.png", main)
	await _panel_shot(main.statue_panel, "04_statue.png", main)
	await _panel_shot(main.character_panel, "05_select.png", main)

	# 取消勾选第一个人 → 验「选中态卡片提亮」与出击按钮计数真的跟着走
	main.character_panel.open()
	await _wait(15)
	var checks: Array = main.character_panel._checks
	if not checks.is_empty():
		(checks[0]["checkbox"] as CheckBox).button_pressed = false
	await _wait(10)
	await _shot(main, "06_select_unchecked.png")
	main.character_panel.close()

	# ---- 出击入口换人（2026-09-20）：走 main 的真实路由，不是直接 open 面板 ----
	# 正例：点传送门 → 弹选人面板；反例：点出发大门 → 什么都不弹（已降为装饰）。
	# 反例必须一起验，否则「路由写错成两个都能开」这种问题截图看不出来。
	main.call("_on_building_interacted", "portal")
	await _wait(15)
	_say("点传送门 → 选人面板 visible = %s（应为 true）"
			% str(bool(main.character_panel.visible)))
	await _shot(main, "07_portal_launch.png")
	main.character_panel.close()
	main.call("_on_building_interacted", "gate")
	await _wait(15)
	_say("点出发大门 → 选人面板 visible = %s（应为 false）"
			% str(bool(main.character_panel.visible)))
	main.base_system.reset_interaction("gate")

	print("[BaseUI] 完成，输出目录 %s" % OUT_DIR)
	get_tree().quit(0)


func _say(s: String) -> void:
	print("[BaseUI] %s" % s)


## 递归找第一个叫 name 的节点，返回它的子节点数（找不到返回 -1）
func _count_under(node: Node, target: String) -> int:
	for c in node.get_children():
		if str(c.name) == target:
			return c.get_child_count()
		var n := _count_under(c, target)
		if n >= 0:
			return n
	return -1


func _panel_shot(panel: CanvasLayer, fname: String, main: Node) -> void:
	panel.open()
	await _wait(15)          # 等 _refresh 里 queue_free 的旧行真的释放、新行布局稳定
	await _shot(main, fname)
	panel.close()
	await _wait(5)


func _shot(main: Node, fname: String) -> void:
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[BaseUI] !! viewport 贴图为空（是不是 --headless？）")
		return
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	var path := OUT_DIR + "/" + fname
	var err := src.save_png(path)
	print("[BaseUI] saved %s (%dx%d err=%d)" % [path, src.get_width(), src.get_height(), err])


func _wait(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame

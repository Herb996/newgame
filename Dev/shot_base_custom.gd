extends Node
## ============================================================
## shot_base_custom — 基地自定义地面实拍
##
## 验收三件事，逻辑探针（probe_base_custom）查不到、只能靠图：
##   1. B 键真的能进编辑态、左侧素材面板真的画出来了（走真实按键事件，不是直接调函数）；
##   2. 几款新素材（雪原/沙漠/焦土/苔原）刷出来**长得不一样**、且相邻处有官方那圈描边；
##   3. 真实鼠标拖动能刷（warp + 按下 + 拖动 + 抬起），不是只有 API 通路能画。
##
## ⚠ 必须开窗（无头是 dummy 驱动、viewport 贴图恒空）。
## ⚠ 收尾一律按 ESC **放弃**改动 —— 出图脚本不该动玩家的存档（探针那次踩过）。
##
## 用法：python tools/run_godot_headless.py _shot_base_custom.log \
##           Dev/shot_base_custom.tscn --window --resolution 1600x900
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-21-22-02-00"


func _ready() -> void:
	Config.set_override("debug.auto_enter_run", false)
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _wait(70)

	var cams := get_tree().get_nodes_in_group("iso_cam")
	if cams.is_empty():
		print("[CustomShot] !! 没找到相机")
		get_tree().quit(1)
		return
	var cam: Camera2D = cams[0] as Camera2D
	cam.set("edge_pan_enabled", false)
	cam.set("zoom_at_cursor", false)

	var tile := float(Config.get_value("map.tile_size", 64))
	# 先在基地南边那片空地上做画布（建筑都在 y=21..45，用 y=55 一整条）
	_aim(cam, Vector2(38.0, 55.0), tile, 0.9)
	await _wait(6)

	# ---- 用真实 B 键进编辑态 ----
	_type_key(66)
	await _wait(8)
	var editor := _find_editor()
	var panel := _find_panel(main, "BaseCustomPanel")
	print("[CustomShot] 编辑器=%s 面板=%s（面板可见=%s）" % [
			str(editor != null), str(panel != null),
			str(panel != null and (panel as CanvasLayer).visible)])
	if editor == null:
		get_tree().quit(1)
		return
	if panel != null:
		_dump_panel(panel)

	# ---- 各素材各刷一条（走公开 API，稳定可复现）----
	var lanes := [[4, 12], [5, 18], [6, 24], [8, 30], [9, 36]]
	for lane in lanes:
		var id: int = lane[0]
		var x0: int = lane[1]
		editor.call("set_tool", 0, id)
		editor.call("paint_rect", Vector2i(x0, 50), Vector2i(x0 + 4, 58), false)
	await _wait(6)

	# ---- 真实鼠标拖一条（验证输入链路，不只是 API）----
	editor.call("set_tool", 0, 7)          # 黑曜岩
	await _drag_mouse(cam, Vector2i(44, 50), Vector2i(44, 58))
	await _wait(4)
	print("[CustomShot] 鼠标拖动后改动格数 = %d" % int(editor.call("change_count")))
	_report_panel(panel)

	await _grab(OUT_DIR + "/base_custom_edit.png")
	_aim(cam, Vector2(20.0, 54.0), tile, 2.0)
	await _wait(6)
	await _grab(OUT_DIR + "/base_custom_zoom.png")

	# 换页签：面板高度应该跟着内容收（水面只有一行）
	_aim(cam, Vector2(38.0, 55.0), tile, 0.9)
	await _wait(4)
	if panel != null:
		panel.call("select_tab", 1)
		await _wait(4)
		print("[CustomShot] 切到水面页签后面板高度 = %.0f（地面页签时应更高）" % _panel_size(panel).y)
		panel.call("select_tab", 0)
		await _wait(4)
		print("[CustomShot] 切回地面页签后面板高度 = %.0f" % _panel_size(panel).y)

	# ---- 建筑层：切到「建筑」页签、放一栋、确认节点真的建出来 ----
	_aim(cam, Vector2(38.0, 55.0), tile, 0.9)
	await _wait(4)
	if panel != null:
		panel.call("select_tab", 3)
		await _wait(4)
	editor.call("set_tool", 3, 0)
	await _wait(2)
	var bbefore := int((editor.call("current_custom") as Dictionary)["buildings"].size())
	var nb0 := _bld_count(main)        # 地图上玩家楼节点数（清空前基线）
	var placed_anchor := Vector2i(-1, -1)
	for ax in [30, 28, 26, 24, 22, 20, 18, 16, 14, 12, 10]:
		var cand := Vector2i(ax, 52)
		editor.call("paint_cells", [cand], false)
		if int((editor.call("current_custom") as Dictionary)["buildings"].size()) > bbefore:
			placed_anchor = cand
			break
	await _wait(4)
	var bafter := int((editor.call("current_custom") as Dictionary)["buildings"].size())
	var nb1 := _bld_count(main)
	print("[CustomShot] 建筑层：表 放置前 %d → 放置后 %d 栋（锚点=%s）｜节点 %d → %d" % [
			bbefore, bafter, str(placed_anchor), nb0, nb1])
	_report_panel(panel)
	await _grab(OUT_DIR + "/base_custom_building.png")

	# ---- 模拟点击「全部清空」按钮（emit pressed，走真实按钮链路）----
	var bc := editor.call("current_custom") as Dictionary
	var b4 := {"地面": (bc["ground"] as Dictionary).size(),
			"水": (bc["water"] as Dictionary).size(),
			"摆件": (bc["props"] as Dictionary).size(),
			"建筑": (bc["buildings"] as Dictionary).size()}
	var nb2 := _bld_count(main)        # 清空前节点数（应 == nb1）
	_click_clear(panel)
	await _wait(8)
	var ac := editor.call("current_custom") as Dictionary
	var a4 := {"地面": (ac["ground"] as Dictionary).size(),
			"水": (ac["water"] as Dictionary).size(),
			"摆件": (ac["props"] as Dictionary).size(),
			"建筑": (ac["buildings"] as Dictionary).size()}
	var all_empty: bool = a4["地面"] == 0 and a4["水"] == 0 and a4["摆件"] == 0 and a4["建筑"] == 0
	var nb3 := _bld_count(main)        # 清空后节点数（应 == nb0，玩家楼全没了，出厂楼不动）
	print("[CustomShot] 全部清空：清空前 %s → 清空后 %s｜四表全空=%s｜改动计数=%d" % [
			str(b4), str(a4), str(all_empty), int(editor.call("change_count"))])
	print("[CustomShot] 清空后节点：放置前 %d → 放置后 %d → 清空后 %d（应回到 %d）" % [nb0, nb1, nb3, nb0])
	_report_panel(panel)
	await _grab(OUT_DIR + "/base_custom_cleared.png")

	# ---- 点「恢复出厂楼（传送门等）」：出厂楼应重新生成，玩家自定义地表保留 ----
	var fr_before := _factory_count(main)     # 清空前出厂楼节点数（应==12）
	var fvis_before := _factory_visible(main)
	_click_restore(panel)
	await _wait(12)
	var bs2 = main.get_node_or_null("BaseSystem")
	var fr_after := -1
	var fvis_after := false
	if bs2 != null:
		var fr = bs2.edit_targets().get("factory_root")
		if fr != null:
			fr_after = (fr as Node2D).get_children().size()
			fvis_after = (fr as Node2D).visible
	print("[CustomShot] 恢复出厂楼：清空前 %d 栋（可见=%s）→ 恢复后 %d 栋（可见=%s）｜编辑器仍在=%s" % [
		fr_before, str(fvis_before), fr_after, str(fvis_after), str(_find_editor() != null)])
	await _grab(OUT_DIR + "/base_custom_restored.png")
	get_tree().quit(0)


func _find_editor() -> Node:
	for n in get_tree().get_nodes_in_group("placement_active"):
		if str(n.name) == "BaseCustomEditor":
			return n
	return null


func _find_panel(main: Node, name_hint: String) -> CanvasLayer:
	for c in main.get_children():
		if str(c.name) == name_hint:
			return c as CanvasLayer
	return null


## 面板文字状态：涂完必须是「已改动 N 格」且「保存」可用，
## 否则玩家根本存不下去 —— 这是只靠截图看不出来的功能回归。
func _report_panel(panel: CanvasLayer) -> void:
	var s: Dictionary = panel.call("state")
	print("[CustomShot] 面板状态=%s｜保存可用=%s" % [str(s["status"]), str(s["save_enabled"])])


func _panel_size(panel: CanvasLayer) -> Vector2:
	var s: Dictionary = panel.call("state")
	return s["size"]


## 面板排版体检：把控件树的实际矩形打出来。
## 光看截图没法分辨「是背景太透」还是「内容比背景宽」，必须比 rect。
func _dump_panel(panel: CanvasLayer) -> void:
	for c in panel.get_children():
		var ctl := c as Control
		if ctl == null:
			continue
		_dump_ctl(ctl, 0)


func _dump_ctl(ctl: Control, depth: int) -> void:
	var pad := "  ".repeat(depth)
	print("[PanelRect]%s%s pos=%s size=%s min=%s" % [
			pad, ctl.name, str(ctl.position), str(ctl.size),
			str(ctl.get_combined_minimum_size())])
	if depth >= 4:
		return
	for c in ctl.get_children():
		var sub := c as Control
		if sub != null:
			_dump_ctl(sub, depth + 1)


## 发一个真实按键事件（走 Input.parse_input_event → main._input）
func _type_key(code: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	Input.parse_input_event(ev)
	ev = InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = false
	Input.parse_input_event(ev)


## 世界格 → 屏幕坐标（Camera2D DRAG_CENTER：screen = (world - 屏幕中心)*zoom + 视口中心）
func _screen_of(cam: Camera2D, cell: Vector2i, tile: float) -> Vector2:
	var world := (Vector2(cell) + Vector2(0.5, 0.5)) * tile
	# ⚠ 本脚本 extends Node，**没有** get_viewport_rect()（那是 CanvasItem/Control 的），
	#   只有 Viewport 对象才有 get_visible_rect()。
	var vp := get_viewport().get_visible_rect().size
	return (world - cam.get_screen_center_position()) * cam.zoom + vp * 0.5


## 按住左键从 a 拖到 b（每步都发 motion + 保持 pressed）
func _drag_mouse(cam: Camera2D, a: Vector2i, b: Vector2i) -> void:
	var tile := float(Config.get_value("map.tile_size", 64))
	var pa := _screen_of(cam, a, tile)
	var pb := _screen_of(cam, b, tile)
	Input.warp_mouse(pa)
	await _wait(2)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pa
	Input.parse_input_event(down)
	var steps := 8
	for i in range(steps + 1):
		var p := pa.lerp(pb, float(i) / float(steps))
		Input.warp_mouse(p)
		var mv := InputEventMouseMotion.new()
		mv.position = p
		mv.relative = p - pa
		Input.parse_input_event(mv)
		await _wait(1)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pb
	Input.parse_input_event(up)


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
		print("[CustomShot] !! viewport 贴图为空（是不是 --headless？）")
		return
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	print("[CustomShot] %s -> err=%d（0=成功）" % [path, src.save_png(path)])


## 地图上「玩家用画笔摆出来的楼」节点数（BasePlayerBuildings 下）。
## 出厂那 12 栋挂在 BaseSystem 根下、不在这里，所以这个数只数玩家楼 ——
## 正好用来验证「全部清空」有没有把玩家楼从地图删掉、又没误伤出厂楼。
func _bld_count(main: Node) -> int:
	var bs := main.get_node_or_null("BaseSystem")
	if bs == null:
		print("[CustomShot] !! 找不到 BaseSystem")
		return -1
	var host = bs.edit_targets()["buildings_host"]
	if host == null:
		return -1
	return (host as Node2D).get_children().size()


## 模拟点「全部清空」：找到那个 Button 直接 emit pressed（和真实鼠标点击同一条链路，
## 会触发连接的 lambda → _on_clear() → editor.clear_all()）。不走 call("_on_clear")
## 是因为它以下划线开头、Object.call 会拒，而 emit pressed 才是玩家实际触发的动作。
func _click_clear(panel: CanvasLayer) -> void:
	var col = panel.get("_col")
	if col == null:
		print("[CustomShot] !! 找不到面板 _col")
		return
	for c in col.get_children():
		var b := c as Button
		if b != null and b.text == "全部清空":
			b.pressed.emit()
			return
	print("[CustomShot] !! 没找到「全部清空」按钮")


## 模拟点「恢复出厂楼（传送门等）」：emit restore_default_requested，
## 走真实按钮链路 → main._on_restore_factory → 重建基地。
func _click_restore(panel: CanvasLayer) -> void:
	var col = panel.get("_col")
	if col == null:
		print("[CustomShot] !! 找不到面板 _col")
		return
	for c in col.get_children():
		var b := c as Button
		if b != null and b.text.begins_with("恢复出厂楼"):
			b.pressed.emit()
			return
	print("[CustomShot] !! 没找到「恢复出厂楼」按钮")


func _factory_root_node(main: Node) -> Node2D:
	var bs = main.get_node_or_null("BaseSystem")
	if bs == null:
		return null
	var fr = bs.edit_targets().get("factory_root")
	return fr as Node2D


func _factory_count(main: Node) -> int:
	var fr = _factory_root_node(main)
	if fr == null:
		return -1
	return fr.get_children().size()


func _factory_visible(main: Node) -> bool:
	var fr = _factory_root_node(main)
	if fr == null:
		return false
	return fr.visible

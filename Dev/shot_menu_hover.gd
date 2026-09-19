extends Node
## ============================================================
## shot_menu_hover — 实拍主菜单：撤掉悬停介绍之后界面有没有被改坏
##
## ⚠ 这条路只能验"布局"，验不了"tooltip 弹不弹"：Godot 的悬停提示框是**独立
## OS 弹窗**，`get_viewport().get_texture()` 只拍主窗口，拍不到它。实测对照
## 按钮（故意写了 tooltip_text、光标钉在上面 4 秒）截出来也是干净的 —— 截图
## 对 tooltip 是瞎的，那"选项截图干净"就什么也证明不了。
## 所以 tooltip 有没有撤干净看数据断言：Dev/probe_menu_hover.gd（整棵菜单树
## 非空 tooltip_text == 0）。这里只留两件事：
##   1) 五个选项的 get_global_rect（宽 360 / 高 60 / 整列居中，改表列序最容易弄歪）
##   2) 每张悬停态截图 + 一张带对照按钮的截图，肉眼确认没有残留说明文字
##
## 用法（**必须开窗**）：
##   godot --path D:/SteamPunkExtraction res://Dev/shot_menu_hover.tscn
## 只读：不碰存档、不进游戏。
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const MENU_SCENE := "res://Scenes/StartMenu.tscn"
const WANT := ["新建存档", "历史存档", "参数配置", "其他", "退出游戏"]
## 悬停后等多久再截：Godot 的 tooltip 延迟约 1 秒，这里给足 4 秒
const HOVER_WAIT := 4.0


func _ready() -> void:
	var menu: Node = load(MENU_SCENE).instantiate()
	# 挂到 Window 而不是 self（self 是普通 Node）：Control 的锚点要拿视口当基准，
	# 挂错地方菜单会缩成 0 尺寸，量出来的 rect 全是假的。
	# 必须 call_deferred：_ready 期间根节点正在"搭孩子"，直接 add_child 会报
	# "Parent node is busy setting up children" 然后静默失败（实测菜单一个按钮都找不到）。
	get_tree().root.add_child.call_deferred(menu)
	for _i in range(30):
		await get_tree().process_frame

	var btns := {}
	var ctrls := 0
	for b in _all_controls(menu):
		ctrls += 1
		if b is Button and WANT.has(str(b.text)):
			btns[str(b.text)] = b
	print("[MenuHover] 菜单里 Control %d 个、主按钮 %d 个" % [ctrls, btns.size()])
	for t in WANT:
		var b: Button = btns.get(t, null)
		if b == null:
			print("[MenuHover] !! 菜单里没有 %s" % t)
			continue
		var r := b.get_global_rect()
		print("[MenuHover] %s rect=(%.0f,%.0f,%.0fx%.0f) tooltip_text=%s" % [
				t, r.position.x, r.position.y, r.size.x, r.size.y,
				"<空>" if str(b.tooltip_text) == "" else "\"" + str(b.tooltip_text) + "\""])
		await _hover_shot(r.get_center(), OUT_DIR + "/menu_hover_%s.png" % _tag(t), t)

	# --- 对照：故意带介绍的按钮，证明截图拍得到 tooltip ---
	var probe_btn := Button.new()
	probe_btn.text = "对照（带介绍）"
	probe_btn.tooltip_text = "这是一条故意留下的悬停介绍，用来证明截图能拍到弹框"
	probe_btn.position = Vector2(40, 40)
	probe_btn.size = Vector2(240, 52)
	get_tree().root.add_child.call_deferred(probe_btn)
	for _i in range(5):
		await get_tree().process_frame
	await _hover_shot(probe_btn.get_global_rect().get_center(),
			OUT_DIR + "/menu_hover_zz_control.png", "对照按钮")
	print("[MenuHover] done")
	get_tree().quit(0)


func _tag(t: String) -> String:
	return {"新建存档": "new", "历史存档": "load", "参数配置": "settings",
			"其他": "misc", "退出游戏": "quit", "对照按钮": "control"}.get(t, "x")


func _hover_shot(center: Vector2, path: String, tag: String) -> void:
	# warp 是真动光标（触发 GUI 悬停），再补发一个 motion 事件兜底：
	# 有的窗口焦点状态下 warp 不产生事件，光等 4 秒也不会弹框。
	Input.warp_mouse(center)
	var ev := InputEventMouseMotion.new()
	ev.position = center
	ev.global_position = center
	Input.parse_input_event(ev)
	# 用「真实毫秒 + process_frame」等，不用 create_timer()：那玩意的 timeout 在
	# SceneTree 暂停时根本不发，实测这么等会整个跑死、一张图都出不来。
	var deadline := Time.get_ticks_msec() + int(HOVER_WAIT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[MenuHover] !! viewport 贴图为空（忘了 --window？）")
		return
	var err := im.save_png(path)
	print("[MenuHover] 悬停 %s -> %s (%dx%d err=%d)" % [tag, path, im.get_width(), im.get_height(), err])


func _all_controls(n: Node, out: Array = []) -> Array:
	for c in n.get_children():
		if c is Control:
			out.append(c)
			_all_controls(c, out)
		else:
			_all_controls(c, out)
	return out

extends Node
## ============================================================
## probe_build_button — 右键背包弹窗右侧的「建造」按钮（2026-09-20）
##
## 用户这轮只要"按钮 + 空信号"，建筑选项不接。所以探针守的是**这个按钮
## 真的在右边、真的点得着、真的只发信号**这三件事：
##   A) 位置：按钮全局矩形在背包明细列的**右侧**、且整个还在面板矩形内；
##      面板变宽后仍夹在视口内（_follow 的夹取没被两列布局打破）。
##   B) 点击能到：Node._input 跑在 Control 的 GUI 分发**之前**，弹窗原本
##      会把面板内的左键整块吞掉（防外泄成移动令）。所以直接喂两次
##      _input 看 Viewport.is_input_handled()：落在按钮上 = 放行（false），
##      落在背包明细上 = 吞掉（true）。顺序不能反，标志位清了不回去。
##   C) 只发信号：pressed → build_requested(unit)，参数就是开着背包的那个人；
##      弹窗收起后再按**不发**（否则会把 null / 已释放节点传给未来的监听者）。
##   D) 负对照：inventory_popup.build_button.enabled=false 时整列不建，
##      面板宽度回到没有按钮的尺寸。
##
## 为什么 headless 能做：全是 Control 矩形和信号，不碰渲染。
## 但 UI 位置这种"断言全绿也可能画面是歪的"的结论仍要配一张实拍图。
## ============================================================

const POPUP_SCRIPT := "res://Scripts/inventory_popup.gd"
const OUT := "user://_probe_build_button.txt"

var _lines: Array = []
var _n := 0
var _fails: Array = []


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _ready() -> void:
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	main._enter_run()
	await _frames(30)

	var popup: Control = get_tree().get_first_node_in_group("inventory_popup")
	_check(popup != null, "局内建出了背包弹窗（group inventory_popup）")
	if popup == null:
		_finish()
		return
	var player: Node = get_tree().get_first_node_in_group("player")
	_check(player != null, "局内有角色")

	# ---- A：按钮在右侧、在面板内、面板不越界 ----
	var btn: Button = popup.get("_build_btn")
	var box: VBoxContainer = popup.get("_box")
	var side: VBoxContainer = popup.get("_side")
	_check(btn != null and btn.text == "建造", "按钮存在且文案是「建造」")
	if btn == null:
		_finish()
		return
	_check(bool(popup.get("_build_enabled")), "配置默认开启（build_button.enabled=true）")
	popup.open_for(player)
	await _frames(4)
	_check(btn.visible and btn.is_visible_in_tree(), "弹窗开着时按钮可见")

	var br: Rect2 = btn.get_global_rect()
	var xr: Rect2 = box.get_global_rect()
	var pr: Rect2 = popup.panel_rect()
	var vp: Vector2 = get_tree().root.get_visible_rect().size
	_say("  按钮 %s / 明细列 %s / 面板 %s / 视口 %s"
			% [str(br), str(xr), str(pr), str(vp)])
	_check(br.position.x >= xr.end.x - 1.0,
			"按钮在背包明细列的**右侧**（按钮左缘 %.1f ≥ 明细右缘 %.1f）"
			% [br.position.x, xr.end.x])
	_check(pr.encloses(br.grow(1.0)), "按钮整个还在面板矩形内")
	_check(br.size.x >= float(Config.get_value(
			"inventory_popup.build_button.min_width_px", 64.0)) - 1.0,
			"按钮宽度吃到了配置的最小宽度（%.1f）" % br.size.x)
	# headless 的视口是退化的（dummy 渲染器给 64x64），任何"夹在视口内"的判据
	# 在无头下都必然假失败 —— 与 probe_menu_bar 同一处理：只在真窗口里量。
	var real_viewport := vp.y >= 400.0
	if not real_viewport:
		_say("  (跳过视口夹取判据：headless 视口退化 64x64，实拍那张图来补)")
	_check(br.size.y <= xr.size.y + 1.0,
			"按钮没被 VBox 拉成整条高（%.1f ≤ 明细列 %.1f）" % [br.size.y, xr.size.y])
	if real_viewport:
		var margin := float(Config.get_value("inventory_popup.viewport_margin_px", 8.0))
		_check(pr.end.x <= vp.x - margin + 1.0 and pr.position.x >= margin - 1.0,
				"面板变宽后仍夹在视口内（%.1f..%.1f）" % [pr.position.x, pr.end.x])

	# ---- B：左键喂进 _input，按钮那一下必须放行 ----
	var root_vp := get_tree().root
	var on_btn := InputEventMouseButton.new()
	on_btn.button_index = MOUSE_BUTTON_LEFT
	on_btn.pressed = true
	on_btn.position = br.get_center()
	popup._input(on_btn)
	_check(not root_vp.is_input_handled(),
			"点在按钮上 → _input 放行（否则 GUI 永远收不到，按钮是死的）")
	var on_bag := InputEventMouseButton.new()
	on_bag.button_index = MOUSE_BUTTON_LEFT
	on_bag.pressed = true
	on_bag.position = Vector2(xr.get_center().x, xr.get_center().y)
	popup._input(on_bag)
	_check(root_vp.is_input_handled(),
			"点在背包明细上 → 照旧吞掉（不会外泄成移动令）")

	# ---- C：只发信号 ----
	var got: Array = []
	popup.build_requested.connect(func(u): got.append(u))
	btn.pressed.emit()
	_check(got.size() == 1 and got[0] == player,
			"按「建造」→ build_requested 带的是开背包的那个角色")
	popup.close_bag()
	got.clear()
	btn.pressed.emit()
	_check(got.is_empty(), "弹窗收起后再按不发信号（不会把 null 传给监听者）")

	# ---- D：负对照，enabled=false 整列不建 ----
	Config.set_override("inventory_popup.build_button.enabled", false)
	var p2: Control = load(POPUP_SCRIPT).new()
	get_tree().root.add_child(p2)
	await _frames(2)
	var side2: VBoxContainer = p2.get("_side")
	_check(side2 != null and not side2.visible, "关掉开关 → 右列整列不显示")
	p2.open_for(player)
	await _frames(4)
	var w_off: float = p2.panel_rect().size.x
	var w_on: float = pr.size.x
	_check(w_off < w_on,
			"关掉后面板变窄（%.1f < %.1f = 按钮那一列确实占过宽度）" % [w_off, w_on])
	p2.close_bag()
	p2.queue_free()
	Config.clear_override("inventory_popup.build_button.enabled")

	_finish()


func _finish() -> void:
	_say("")
	_say("通过 %d / %d" % [_n - _fails.size(), _n])
	for f in _fails:
		_say("  FAIL: " + str(f))
	var fa := FileAccess.open(OUT, FileAccess.WRITE)
	if fa != null:
		fa.store_string("\n".join(_lines))
	for l in _lines:
		print(str(l))
	print("[BuildButtonProbe] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

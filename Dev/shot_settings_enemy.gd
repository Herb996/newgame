extends Node
## ============================================================
## shot_settings_enemy — 实拍「参数配置 → 玩法」页的敌人近战三行
##
## 为什么单独开一个：2026-09-19 把 enemy.attack（射程 / 出手间隔）挂进设置面板
## 之后，光看代码绿是不够的 —— 面板是 VBox + ScrollContainer 拼的，行宽 300 的
## 名称列、被挤到可视区外面的行，都是「断言全绿但画面是歪的」高发区。
## 所以这里两件事一起做（用户定的规矩：UI 改动要量 get_global_rect + 开窗截图）：
##   1) 三行的 rect / 名称列宽 / 滑块当前值（值必须等于 config，证明路径没写错）
##   2) 把敌人那块滚进可视区再截图，并且断言它真的落在 ScrollContainer 里
##      —— 滚不到的行等于玩家点不到的行。
##
## 用法（**必须开窗**，无头 viewport 贴图为空）：
##   python tools/run_probe.py _shot_settings_enemy.log Dev/shot_settings_enemy.tscn --window
##
## 只读：只建面板、不调「确认应用」，一个 user:// 字节都不写。
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const SETTINGS_PANEL := preload("res://Scripts/settings_panel.gd")
const GAMEPLAY_TAB := 3        # 画面/性能/音频/**玩法**/资源/操作/语言/调试
const WANT := ["近战伤害", "近战射程", "出手间隔"]
const ABSENT := ["接触伤害"]
const EXPECT := {
	"enemy.contact_damage": 10.0,
	"enemy.attack.range_px": 52.0,
	"enemy.attack.cooldown_seconds": 1.0,
}
const NAME_COL_W := 300.0

var _fails := 0
var _passed := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Config.set_override("display.window_mode", "windowed")
	Config.set_override("display.resolution", [1280, 720])

	var p: Control = SETTINGS_PANEL.new()
	p.initial_tab = GAMEPLAY_TAB
	# 挂到 Window：Control 锚点要拿视口当基准，挂普通 Node 会缩成 0×0，rect 全假。
	# call_deferred：_ready 期间根节点正在搭孩子，直接 add_child 会静默失败。
	get_tree().root.add_child.call_deferred(p)
	await _frames(30)

	var rows := _rows_by_label(p)
	print("[ShotSettings] 玩法页 %d 个分区、可控件行 %d 行" % [_divider_labels(p).size(), rows.size()])

	# ---- 1) 旧标签必须彻底消失 ----
	for gone in ABSENT:
		var still = rows.get(gone, null)
		_check(still == null, "旧标签「%s」已从面板消失（改成「近战伤害」）" % gone)

	# ---- 2) 三行齐不齐、宽不宽、值对不对 ----
	var boxes: Array = []
	for name_lbl in WANT:
		var row: HBoxContainer = rows.get(name_lbl, null)
		if row == null:
			_fail("玩法页找不到「%s」这一行" % name_lbl)
			continue
		var box: Control = row.get_parent()
		boxes.append(box)
		var rr := row.get_global_rect()
		var lr: Rect2 = row.get_child(0).get_global_rect()
		print("[ShotSettings] 「%s」 row=(%.0f,%.0f %.0fx%.0f) 名称列=%.0fx%.0f" % [
				name_lbl, rr.position.x, rr.position.y, rr.size.x, rr.size.y, lr.size.x, lr.size.y])
		_check(rr.size.x > 0.0 and rr.size.y > 0.0, "「%s」有非零尺寸（%.0fx%.0f）"
				% [name_lbl, rr.size.x, rr.size.y])
		_check(lr.size.x >= NAME_COL_W - 1.0,
				"「%s」名称列宽 %.0f ≥ %.0f（与其它行同一条左基线）"
				% [name_lbl, lr.size.x, NAME_COL_W])
		var s := _slider(row)
		if s == null:
			_fail("「%s」行里没有滑块（类型不是 number？）" % name_lbl)
			continue
		var path := _path_of(p, name_lbl)
		var want_v: float = EXPECT.get(path, -1.0)
		var cfg_v: float = float(Config.get_value(path))
		_check(s.value == want_v and cfg_v == want_v,
				"「%s」滑块 %.1f == config %.1f == 预期 %.1f（%s）"
				% [name_lbl, s.value, cfg_v, want_v, path])
		var vl := _value_label(row)
		if vl != null:
			print("[ShotSettings]   数值文字=「%s」" % vl.text)
			_check(str(vl.text) != "", "「%s」数值文字非空（屏上是 %s）" % [name_lbl, vl.text])

	# ---- 3) 滚进可视区：滚不到 == 玩家点不到 ----
	var sc := _scroll_of(p)
	if sc == null or boxes.is_empty():
		_fail("拿不到 ScrollContainer 或敌人行，无法验证可见性")
	else:
		var first: Control = boxes[0]
		var last: Control = boxes[boxes.size() - 1]
		sc.scroll_vertical = int(maxf(0.0, first.position.y - 24.0))
		await _frames(4)
		var scr := sc.get_global_rect()
		var fr := first.get_global_rect()
		var lastr := last.get_global_rect()
		print("[ShotSettings] 滚动 %d → Scroll 视口=(%.0f,%.0f %.0fx%.0f) 首行 y=%.0f 末行 y=%.0f"
				% [sc.scroll_vertical, scr.position.x, scr.position.y, scr.size.x, scr.size.y,
						fr.position.y, lastr.position.y])
		_check(scr.has_point(fr.get_center()), "「%s」整行落在滚动可视区内（点得到）" % WANT[0])
		_check(scr.has_point(lastr.get_center()), "「%s」整行落在滚动可视区内（点得到）" % WANT[WANT.size() - 1])
		_check(lastr.end.y - fr.position.y < scr.size.y,
				"三行在同一屏内（跨 %.0f px ＜ 视口高 %.0f px）"
				% [lastr.end.y - fr.position.y, scr.size.y])
		await _shot(scr)

	print("[ShotSettings] 通过 %d / %d" % [_passed, _passed + _fails])
	get_tree().quit(0 if _fails == 0 else 1)


# ------------------------------------------------------------
# 找行 / 读数
# ------------------------------------------------------------

## 面板里每个「可控件行」的 VBoxes：child0 是 HBox，HBox 的 child0 是名称 Label
func _rows_by_label(p: Control) -> Dictionary:
	var out := {}
	for box in p._content.get_children():
		if not (box is VBoxContainer):
			continue
		var row = box.get_child(0)
		if not (row is HBoxContainer) or row.get_child_count() == 0:
			continue
		var lbl = row.get_child(0)
		if lbl is Label:
			out[str(lbl.text)] = row
	return out


func _divider_labels(p: Control) -> Array:
	var out: Array = []
	for box in p._content.get_children():
		if box is Label and str(box.text).begins_with("—"):
			out.append(box)
	return out


## 名称标签文字 → 这一行的配置路径（从 schema 里回查，不猜顺序）
func _path_of(p: Control, label: String) -> String:
	for entry in p._tabs[GAMEPLAY_TAB]["entries"]:
		if str(entry.get("label", "")) == label:
			return str(entry.get("path", ""))
	return ""


func _slider(row: HBoxContainer) -> Slider:
	for c in row.get_children():
		if c is HBoxContainer:
			for g in (c as Control).get_children():
				if g is Slider:
					return g as Slider
		if c is Slider:
			return c as Slider
	return null


func _value_label(row: HBoxContainer) -> Label:
	for c in row.get_children():
		if c is HBoxContainer:
			for g in (c as Control).get_children():
				if g is Label and str((g as Label).text) != "":
					return g as Label
	return null


func _scroll_of(p: Control) -> ScrollContainer:
	var n: Node = p._content.get_parent()
	while n != null:
		if n is ScrollContainer:
			return n as ScrollContainer
		n = n.get_parent()
	return null


# ------------------------------------------------------------
# 截图 / 断言
# ------------------------------------------------------------

## 裁滚动区那一块：整张窗口图里面板只占中间一小条，裁出来才看得清行
func _shot(scr: Rect2) -> void:
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[ShotSettings] !! viewport 贴图为空（忘了 --window？）")
		return
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	var w := src.get_width()
	var h := src.get_height()
	var box := Rect2i(int(scr.position.x), int(scr.position.y), int(scr.size.x), int(scr.size.y))
	box.position.x = clampi(box.position.x, 0, maxi(w - 8, 0))
	box.position.y = clampi(box.position.y, 0, maxi(h - 8, 0))
	box.size.x = mini(box.size.x, w - box.position.x)
	box.size.y = mini(box.size.y, h - box.position.y)
	var out := Image.create(box.size.x, box.size.y, false, Image.FORMAT_RGBA8)
	out.blit_rect(src, box, Vector2i.ZERO)
	var path := OUT_DIR + "/settings_enemy_rows.png"
	var err := out.save_png(path)
	print("[ShotSettings] -> %s err=%d 裁 %dx%d / 窗口 %dx%d"
			% [path, err, box.size.x, box.size.y, w, h])
	var full := OUT_DIR + "/settings_enemy_full.png"
	print("[ShotSettings] -> %s err=%d" % [full, im.save_png(full)])


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("[ShotSettings]   OK   %s" % what)
	else:
		_fails += 1
		print("[ShotSettings]   !!   %s" % what)


func _fail(what: String) -> void:
	_fails += 1
	print("[ShotSettings]   !!   %s" % what)


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame

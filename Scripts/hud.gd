extends CanvasLayer
## ============================================================
## HUD — 局内界面（步骤 3 最小版）
## - 顶部中央：倒计时 mm:ss（02 规格要求 UI 常驻）
## - 倒计时下方：阶段提示（搜刮期 / 撤离点开放数量）
## - 局结束：中央结算面板（撤离成功带回 / 死亡 / 超时）
## 数值全部来自 RunManager 与 Data/config.json。
## 注意：视野提示（滚轮缩放）**不在这一层**，见 Scripts/view_hint.gd ——
## 本 HUD 在基地模式整体隐藏，而缩放提示两种模式都要可见。
## ============================================================

## 右键角色弹出的背包面板（与 HUD 同层：基地模式跟着隐藏）
const INVENTORY_POPUP := preload("res://Scripts/inventory_popup.gd")

var _run: Node
var _time_label: Label
var _phase_label: Label
var _result_label: Label
var _bag_label: Label
var _hp_label: Label
var _survival_label: Label
var _survival: Node = null
var _popup: Control = null

## 局内底部菜单栏占了最下面 1/5 屏（背包/血量/生存三行原本就在那一带），
## 必须整体上移让位，否则会被栏压住。高度与菜单栏同源（UiKit.menu_bar_height），
## 不各算一份 —— 否则改 ratio 时一边挪一边不挪，文字正好卡在栏的边框上。
var _bottom_lift := 0.0
var _bottom_rows: Array = []   # [{label, margin}]：窗口缩放后重新贴一次


func _ready() -> void:
	_run = get_tree().get_first_node_in_group("run_manager")
	_run.run_started.connect(_on_run_started)
	_run.run_ended.connect(_on_run_ended)
	_bottom_lift = UiKit.menu_bar_height(get_viewport().get_visible_rect().size.y) \
			if UiKit.menu_bar_enabled() else 0.0
	get_viewport().size_changed.connect(_reflow_bottom)

	_time_label = _make_label(26, Control.PRESET_CENTER_TOP)
	_time_label.offset_top = 10
	_phase_label = _make_label(16, Control.PRESET_CENTER_TOP)
	_phase_label.offset_top = 46
	_phase_label.add_theme_color_override("font_color", Color(0.75, 0.73, 0.68))
	_result_label = _make_label(30, Control.PRESET_CENTER)
	# 背包栏：左下角常驻显示（种类数/容量 + 明细）
	_bag_label = _bottom_label(15, 12.0, Control.PRESET_BOTTOM_LEFT)
	_bag_label.offset_left = 12
	_bag_label.add_theme_color_override("font_color", Color(0.91, 0.90, 0.86))
	# 血量：左下角，背包栏上方
	_hp_label = _bottom_label(16, 36.0, Control.PRESET_BOTTOM_LEFT)
	_hp_label.offset_left = 12
	_hp_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.4))
	# 生存栏：左下角，血量上方（食物数量 + 下次进食倒计时 + 饥饿警告）
	_survival_label = _bottom_label(15, 60.0, Control.PRESET_BOTTOM_LEFT)
	_survival_label.offset_left = 12
	_survival_label.add_theme_color_override("font_color", Color(0.55, 0.78, 0.45))
	# 背包弹窗：右键角色 → 在他头顶弹出那一份背包（只读），菜单栏跟着同步。
	# 谁被点中、什么时候收起都由它自己监听输入（见 inventory_popup.gd）。
	_popup = INVENTORY_POPUP.new()
	_popup.name = "InventoryPopup"
	add_child(_popup)


func _make_label(size: int, preset: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.set_anchors_and_offsets_preset(preset)
	add_child(l)
	return l


## 底部标签：以「距屏幕底 margin 像素」定位。
## Label 默认是**顶对齐**，只改 offset_bottom 只会把矩形压扁、文字仍停在
## preset 算出的 offset_top 上 —— 几个标签就会画在同一 y 上互相叠字。
## 所以这里给足矩形高度并改成底对齐，margin 才真的是离底边距离。
const _BOTTOM_BOX := 64.0


func _bottom_label(size: int, margin: float, preset: int) -> Label:
	var l := _make_label(size, preset)
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_bottom_rows.append({"label": l, "margin": margin})
	_apply_bottom_row(l, margin)
	return l


## 把一行贴到「距底 margin + 让开菜单栏」的位置
func _apply_bottom_row(l: Label, margin: float) -> void:
	var lift := margin + _bottom_lift
	l.offset_top = -lift - _BOTTOM_BOX
	l.offset_bottom = -lift


## 窗口尺寸变了 → 菜单栏高度跟着变（它按视口高比例算），让位距离要重贴
func _reflow_bottom() -> void:
	var lift := UiKit.menu_bar_height(get_viewport().get_visible_rect().size.y) \
			if UiKit.menu_bar_enabled() else 0.0
	if is_equal_approx(lift, _bottom_lift):
		return
	_bottom_lift = lift
	for row in _bottom_rows:
		_apply_bottom_row(row["label"], float(row["margin"]))


func _process(_delta: float) -> void:
	if _run.state == _run.State.RUNNING:
		var t := maxf(_run.time_remaining, 0.0)
		_time_label.text = "%02d:%02d" % [floori(t / 60.0), int(t) % 60]
		_phase_label.text = _phase_text()
		_refresh_bag()
		_refresh_hp()
		_refresh_survival()


## 血量条：小队全员一行——"枪手 HP 80/100 | 弓兵 倒下 | 剑士 倒下"
func _refresh_hp() -> void:
	var parts: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		var nm := str(p.character_name)
		if nm == "":
			nm = "角色"
		if bool(p.is_dead()):
			parts.append("%s 倒下" % nm)
		else:
			parts.append("%s HP %d/%d" % [nm, int(p.hp), int(p.max_hp)])
	_hp_label.text = "  |  ".join(parts)


## 生存栏："物资 食物 x3   下次消耗 42s"
## 数字是**全队背包总账**（每人一份，各吃各的 —— 见 survival_system.gd）。
## 短缺时点名**谁缺**：扣的是他一个人的属性，队友不受牵连。
func _refresh_survival() -> void:
	if _survival == null or not is_instance_valid(_survival):
		_survival = get_tree().get_first_node_in_group("survival_system")
	var supplies: Array = Config.get_value("survival.supplies", [])
	if _survival == null or not (supplies is Array) or supplies.is_empty():
		_survival_label.text = ""
		return
	var total: Dictionary = _run.total_loot()
	var parts: Array = []
	for e in supplies:
		if not (e is Dictionary):
			continue
		var id := str((e as Dictionary).get("id", ""))
		if id == "":
			continue
		parts.append("%s x%d" % [str(Config.get_value("resources.%s.name" % id, id)),
				int(total.get(id, 0))])
	var txt := "物资 %s   下次消耗 %ds   每人各扣一份" % [" · ".join(parts),
			int(maxf(float(_survival.next_meal_in), 0.0))]
	if bool(_survival.starving):
		txt += "   【短缺：%s · %s · 补上即恢复，不会死】" % [
				"、".join(_survival.hungry_names()),
				Meta.penalty_line(_survival.merged_penalties())]
		_survival_label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.35))
	else:
		_survival_label.add_theme_color_override("font_color", Color(0.55, 0.78, 0.45))
	_survival_label.text = txt


## 背包栏：左下角。背包现在**一人一份**，这里给全队总账 + 各人占几格；
## 要看具体谁身上有什么 → 右键那个角色，头顶弹窗（底部菜单栏同步显示同一人）。
func _refresh_bag() -> void:
	var total: Dictionary = _run.total_loot()
	var who: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		var nm := str(p.character_name)
		if nm == "":
			nm = "角色"
		who.append("%s %d/%d格" % [nm, p.inventory.size(), p.backpack_capacity()])
	var line := "　·　".join(who)
	if total.is_empty():
		_bag_label.text = "背包 空   %s" % line
		return
	_bag_label.text = "背包 全队 %d 种：%s   ｜   %s" % [
			total.size(), _format_loot(total), line]


func _phase_text() -> String:
	var open_count := 0
	var total := 0
	for p in get_tree().get_nodes_in_group("extraction_points"):
		total += 1
		if p.is_open:
			open_count += 1
	if total == 0:
		return "阶段一 · 搜刮期（撤离点未开启）"
	return "撤离点开放：%d 个" % open_count


func _on_run_started() -> void:
	_result_label.text = ""


func _on_run_ended(result: String, banked: Dictionary) -> void:
	match result:
		"extracted":
			_result_label.text = "撤离成功！带回：%s\n\n按 R 返回基地 · ESC 退出" % _format_loot(banked)
		"died":
			_result_label.text = "你死了——本局资源全部丢失\n\n按 R 返回基地 · ESC 退出"
		"timeout":
			_time_label.text = "00:00"
			_result_label.text = "超时死亡——本局资源全部丢失\n\n按 R 返回基地 · ESC 退出"


## 把 {"scrap": 3} 格式化为 "废铁 x3"，资源名读 config 的 resources.*.name
func _format_loot(banked: Dictionary) -> String:
	if banked.is_empty():
		return "无"
	var parts: Array = []
	for res in banked:
		var display: String = str(Config.get_value("resources.%s.name" % res, res))
		parts.append("%s x%d" % [display, int(banked[res])])
	return "  ".join(parts)

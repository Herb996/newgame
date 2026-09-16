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

var _run: Node
var _player: Node
var _time_label: Label
var _phase_label: Label
var _result_label: Label
var _bag_label: Label
var _hp_label: Label
var _survival_label: Label
var _survival: Node = null


func _ready() -> void:
	_run = get_tree().get_first_node_in_group("run_manager")
	_run.run_started.connect(_on_run_started)
	_run.run_ended.connect(_on_run_ended)

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
	l.offset_top = -margin - _BOTTOM_BOX
	l.offset_bottom = -margin
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	return l


func _process(_delta: float) -> void:
	if _run.state == _run.State.RUNNING:
		var t := maxf(_run.time_remaining, 0.0)
		_time_label.text = "%02d:%02d" % [floori(t / 60.0), int(t) % 60]
		_phase_label.text = _phase_text()
		_refresh_bag()
		_refresh_hp()
		_refresh_survival()


## 血量条："HP 80/100"
func _refresh_hp() -> void:
	# 进局会重建 Player 节点，这里按需重新抓取
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	if _player == null or not is_instance_valid(_player):
		_hp_label.text = ""
		return
	_hp_label.text = "HP %d/%d" % [int(_player.hp), int(_player.max_hp)]


## 生存栏："食物 x30   下次进食 42s"（饥饿时标红并提示持续掉血）
func _refresh_survival() -> void:
	if _survival == null or not is_instance_valid(_survival):
		_survival = get_tree().get_first_node_in_group("survival_system")
	if _survival == null:
		_survival_label.text = ""
		return
	var food := int(_run.loot.get("food", 0))
	var txt := "食物 x%d   下次进食 %ds" % [food, int(maxf(float(_survival.next_meal_in), 0.0))]
	if bool(_survival.starving):
		txt += "   【饥饿！持续掉血，按 H 吃食物】"
		_survival_label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.35))
	else:
		_survival_label.add_theme_color_override("font_color", Color(0.55, 0.78, 0.45))
	_survival_label.text = txt


## 背包栏：左下角，"背包 3/10 格：木头 x20 铁 x10 ..."
func _refresh_bag() -> void:
	if _run.loot.is_empty():
		_bag_label.text = "背包 0/%d 格" % _run.backpack_capacity()
		return
	_bag_label.text = "背包 %d/%d 格：%s" % [
		_run.loot.size(), _run.backpack_capacity(), _format_loot(_run.loot)]


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
	# 每局玩家节点会重建，清空引用让 _refresh_hp 重新抓取
	_player = null


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

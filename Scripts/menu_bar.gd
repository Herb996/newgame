extends CanvasLayer
## ============================================================
## MenuBar — 局内底部菜单栏（占屏高 1/5，最下面那一条）
##
## 三槽布局（左中右）：
##   【左】小地图（Minimap 子节点，常驻、开局就有）
##         点它 = 给当前选中单位下一道指令（与点地图同义，巡逻设点也通用）
##   【中】指令面板 —— **内容随选中单位而变**：
##         显示单位名 / 武器 / 生命 / 观察视野 / 攻击距离，
##         下面一排按钮由 characters.list[].command_set 查 menu_bar.command_sets 得到。
##         战斗单位（当前 4 名角色）的指令集 combat：
##           自动攻击开关 / 索敌·最近 / 索敌·最强 / 指定攻击 / 巡逻 / 取消指令
##   【右】噪音显示 —— 当前噪音（现时有多吵）+ 累积噪音（本局暴露度）+ 被惊动的敌人数
##
## 只在局内显示：main._enter_run 里 set_active(true)，回基地 set_active(false)。
## 整条栏 mouse_filter = STOP —— 压在栏上的鼠标不会误给世界下移动令；
## 代价是**贴底那条边的边缘滚屏在栏区域内失效**（左右上三边与 WASD 照常）。
##
## 谁下指令：本文件只负责「读按钮 → 调角色的指令 API」，
## 真正的行为全在 player.gd 的指令段（auto_attack_on / target_stance /
## designated_target / 巡逻点）—— UI 与玩法各管一半，没有第二份状态。
## ============================================================

var _root: Control
var _bar: PanelContainer
var _left_slot: Control
var _cmd_col: VBoxContainer
var _noise_col: VBoxContainer
var _minimap: CanvasLayer

# --- 指令面板 ---
var _unit_title: Label
var _unit_stats: Label
var _cmd_row: HBoxContainer
var _cmd_status: Label
var _cmd_hint: Label
var _buttons: Dictionary = {}      # 按钮 id -> Button
var _stance_group: ButtonGroup
var _built_set := ""               # 已构建的指令集 id（变了才重建按钮）
var _had_selection := false

# --- 噪音表 ---
var _noise_title: Label
var _cur_bar: ProgressBar
var _cur_fill: StyleBoxFlat
var _cur_value: Label
var _cur_level: Label
var _acc_bar: ProgressBar
var _acc_value: Label
var _alert_label: Label
var _alert_timer := 0.0
var _alert_count := 0
var _last_slot_rect := Rect2()
var _last_vp_h := 0.0


func _ready() -> void:
	add_to_group("menu_bar")
	_minimap = get_node_or_null("Minimap") as CanvasLayer
	if _minimap != null and _minimap.has_signal("map_clicked"):
		_minimap.map_clicked.connect(_on_minimap_clicked)
	_build_ui()
	visible = false
	if _minimap != null:
		_minimap.visible = false
	get_viewport().size_changed.connect(_relayout)


func _process(delta: float) -> void:
	if not visible:
		return
	# 视口高度变了就重排（含「启动时窗口还没定型 → 变成最终尺寸」这一步）。
	# 比只听 viewport.size_changed 可靠：那个信号在窗口定型前就发过，
	# 期间算出来的栏高会一直错到玩家手动改窗口大小为止。
	var vp_h := get_viewport().get_visible_rect().size.y
	if not is_equal_approx(vp_h, _last_vp_h):
		_last_vp_h = vp_h
		_relayout()
	# 槽位矩形每帧对一次（容器布局是延迟到本帧末尾算的，不能只在 _ready 里量一次；
	# 顺便白嫖了窗口缩放：矩形变了就重新钉一次小地图面板）
	if _left_slot != null and _minimap != null:
		var r := _left_slot.get_global_rect()
		if r != _last_slot_rect:
			_last_slot_rect = r
			_minimap.set_slot_rect(r)
	_refresh_noise(delta)
	_refresh_commands()


# ------------------------------------------------------------
# 显隐与接线（由 main.gd 调用）
# ------------------------------------------------------------

## 局内开 / 基地关。小地图是独立 CanvasLayer（不继承父层 visible），必须一起切 ——
## 只关菜单栏的话，小地图会留在基地界面右下角"孤零零飘着"。
func set_active(on: bool) -> void:
	visible = on
	if _minimap != null:
		_minimap.visible = on


## 进局时接上地图数据：小地图切常驻并生成底图。
func setup(map_data: Dictionary) -> void:
	if _minimap == null:
		push_warning("[MenuBar] 找不到子节点 Minimap，小地图槽会是空的")
		return
	_minimap.set_embed_mode(true)
	_minimap.setup(map_data)
	_relayout()
	_last_slot_rect = Rect2()   # 逼下一帧重新钉一次槽位


## 应该有多高（像素，按视口高比例算）。HUD / 视野提示让位读的就是这个值。
## 【必须纯函数】早期版本这里返回「已布局的真实高度」，而 _relayout() 又拿这个值
## 去设 offset_top —— 自我反馈：启动瞬间视口还不是最终尺寸（拿到过
## 786×786 这种中间值），算出来的 157px 就被永久锁死，窗口变成 1920×1080
## 之后栏高还是 157，怎么改配置都不动。所以这里只算公式，
## 真实高度另开 bar_actual_height() 给探针核对。
func bar_height() -> float:
	return UiKit.menu_bar_height(get_viewport().get_visible_rect().size.y)


## 实际布局出来的高度（探针用：与 bar_height() 不等 → 内容把栏顶高了，
## 说明 min_height_px 给小了，HUD 让位距离会不够）。
func bar_actual_height() -> float:
	return _bar.size.y if _bar != null else 0.0


# --- 布局查询（探针用；运行时代码不读它们）---

## 整条栏占据的矩形（视口坐标）
func bar_rect() -> Rect2:
	return _bar.get_global_rect() if _bar != null else Rect2()


## 小地图槽的矩形（视口坐标；等于小地图面板被钉到的位置）
func minimap_slot_rect() -> Rect2:
	return _left_slot.get_global_rect() if _left_slot != null else Rect2()


## 当前指令面板上的按钮 id 列表（探针断言「换单位换指令」用）
func command_button_ids() -> Array:
	var out: Array = []
	for id in _buttons.keys():
		out.append(id)
	return out


# ------------------------------------------------------------
# 界面骨架
# ------------------------------------------------------------

func _build_ui() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_bar = PanelContainer.new()
	_bar.name = "Bar"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.065, 0.06, 0.94)
	sb.border_color = Color(0.38, 0.30, 0.19, 1.0)
	sb.border_width_top = 2
	sb.set_content_margin_all(float(Config.get_value("menu_bar.padding_px", 8)))
	_bar.add_theme_stylebox_override("panel", sb)
	_bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	# STOP：栏内一切都是界面，压在栏上的左键不该穿透到世界去下移动令
	_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_bar)

	var row := UiKit.hbox(12)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bar.add_child(row)

	# --- 左：小地图占位槽（Minimap 这个 CanvasLayer 悬在它正上方） ---
	_left_slot = Control.new()
	_left_slot.name = "MinimapSlot"
	_left_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 必须 SHRINK_CENTER：HBoxContainer 默认把子项在纵向上拉满，
	# 小地图槽就会被拉成长方形（116×141 这种），小地图跟着被拉伸变形。
	_left_slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_left_slot)

	# --- 中：单位指令面板 ---
	_cmd_col = UiKit.vbox(4)
	_cmd_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cmd_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(_cmd_col)

	_unit_title = UiKit.label("未选中单位", 17, UiKit.COL_AMBER)
	_cmd_col.add_child(_unit_title)

	_unit_stats = UiKit.dim("点画面里的角色即可指挥它（左键点角色选中 · 左键点地移动 · 右键取消指令）")
	_cmd_col.add_child(_unit_stats)

	_cmd_col.add_child(UiKit.spacer(2))

	_cmd_row = UiKit.hbox(6)
	_cmd_col.add_child(_cmd_row)
	_stance_group = ButtonGroup.new()

	_cmd_col.add_child(UiKit.spacer(2))

	_cmd_status = UiKit.label("", 14, UiKit.COL_TEXT)
	_cmd_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cmd_col.add_child(_cmd_status)

	_cmd_hint = UiKit.dim("", 12)
	_cmd_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cmd_col.add_child(_cmd_hint)

	# --- 右：噪音表 ---
	_noise_col = UiKit.vbox(2)
	_noise_col.custom_minimum_size = Vector2(
			float(Config.get_value("menu_bar.noise_slot_px", 300)), 0)
	row.add_child(_noise_col)

	var head := UiKit.hbox(8)
	_noise_col.add_child(head)
	_noise_title = UiKit.label("噪音", 17, UiKit.COL_AMBER)
	head.add_child(_noise_title)
	var head_sp := Control.new()
	head_sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(head_sp)
	_alert_label = UiKit.label("", 13, UiKit.COL_WARN)
	head.add_child(_alert_label)

	var cur := _make_meter("当前", float(Config.get_value("noise.sources.sniper_shot", 240)))
	_cur_bar = cur["bar"]
	_cur_fill = cur["fill"]
	_cur_value = cur["value"]
	_noise_col.add_child(cur["row"])
	_cur_level = UiKit.label("安静", 13, UiKit.COL_DIM)
	_noise_col.add_child(_cur_level)

	var acc := _make_meter("累积", float(Config.get_value("noise.display.accumulated_reference", 2000)))
	_acc_bar = acc["bar"]
	_acc_value = acc["value"]
	_noise_col.add_child(acc["row"])
	# 「累积」的含义写在标题的 tooltip 上而不是再加一行说明文字：
	# 菜单栏高度是按屏高比例算的（默认 1/5），多一行就可能把内容顶得比栏还高，
	# 栏会被自己的最小尺寸撑大、把上面 HUD 的文字压住。
	_noise_title.tooltip_text = "当前 = 小队最近一次发声的强度（会衰减）；累积 = 本局发声总量（暴露度）；被惊动 = 警觉度已达『调查』的敌人数"

	_relayout()


## 一行「标签 + 条 + 数值」。返回 {row, bar, fill, value}
func _make_meter(title: String, max_value: float) -> Dictionary:
	var row := UiKit.hbox(6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var l := UiKit.dim(title, 13)
	l.custom_minimum_size = Vector2(38, 0)
	row.add_child(l)

	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = maxf(max_value, 1.0)
	bar.value = 0.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 13)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.17, 0.15, 0.12, 1.0)
	bg.set_corner_radius_all(3)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.48, 0.78, 0.42, 1.0)
	fill.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	row.add_child(bar)

	var v := UiKit.value_label(64)
	v.add_theme_font_size_override("font_size", 13)
	row.add_child(v)
	return {"row": row, "bar": bar, "fill": fill, "value": v}


## 按当前视口算栏高、并把左侧小地图槽设成正方形（边长 = 栏高 - 2×内边距）
func _relayout() -> void:
	if _bar == null or _left_slot == null:
		return
	var pad := float(Config.get_value("menu_bar.padding_px", 8))
	var h := bar_height()
	_bar.offset_top = -h
	_bar.offset_bottom = 0.0
	var side := maxf(h - pad * 2.0, 48.0)
	_left_slot.custom_minimum_size = Vector2(side, side)
	_last_slot_rect = Rect2()

# ------------------------------------------------------------
# 指令面板
# ------------------------------------------------------------

## 当前被选中的角色（小队里同时只有一名选中，见 player._set_selected）
func _selected_player():
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and bool(p.get("selected")):
			return p
	return null


func _refresh_commands() -> void:
	var p = _selected_player()
	if p == null:
		if _had_selection:
			_had_selection = false
			_built_set = ""
			_clear_buttons()
			_unit_title.text = "未选中单位"
		_unit_stats.text = "点画面里的角色即可指挥它（左键点角色选中 · 左键点地移动 · 右键取消指令）"
		_cmd_status.text = ""
		_cmd_hint.text = ""
		return
	_had_selection = true

	var set_id := _command_set_of(p)
	if set_id != _built_set:
		_built_set = set_id
		_build_buttons(set_id)

	# 单位信息：换角色就换一整套数值（各武器射程/视野都不同，眼睛能直接对比）
	var w: Dictionary = p.weapon_data()
	var wname := str(w.get("name", "徒手"))
	_unit_title.text = "%s　·　%s" % [str(p.character_name), wname]
	_unit_stats.text = "HP %d/%d　·　观察视野 %.0fpx　·　武器射程 %.0fpx　·　有效射程 %.0fpx　·　噪音 %s" % [
		int(p.hp), int(p.max_hp), p.vision_px(), p.attack_range_px(),
		p.effective_attack_range_px(), _noise_word(p.attack_noise())]

	_sync_buttons(p)
	_cmd_status.text = _status_text(p)
	_cmd_hint.text = _hint_text(p)


func _noise_word(v: float) -> String:
	if v >= 200.0:
		return "震耳（%.0f）" % v
	if v >= 100.0:
		return "大（%.0f）" % v
	if v >= 50.0:
		return "中（%.0f）" % v
	return "小（%.0f）" % v


## 该角色用哪个指令集：角色自己带的 command_set 优先，缺了回落默认集
func _command_set_of(p) -> String:
	var cs := str(p.get("command_set"))
	if cs == "":
		cs = str(Config.get_value("menu_bar.default_command_set", "combat"))
	return cs


## 建按钮：按 config 的 command_sets[set_id] 顺序，只建这个单位有的那几个
func _build_buttons(set_id: String) -> void:
	_clear_buttons()
	var defs := _button_defs()
	var ids: Array = Config.get_value("menu_bar.command_sets.%s" % set_id, [])
	if ids.is_empty():
		_cmd_hint.text = "指令集 %s 没有配置按钮（menu_bar.command_sets）" % set_id
		return
	for raw in ids:
		var id := str(raw)
		if not defs.has(id):
			push_warning("[MenuBar] 未知指令按钮：%s（见 menu_bar.gd 的 _button_defs）" % id)
			continue
		var d: Dictionary = defs[id]
		var b := UiKit.button(str(d.get("text", id)), 0, 14)
		b.custom_minimum_size = Vector2(float(d.get("width", 130)), 34)
		b.tooltip_text = str(d.get("tip", ""))
		if bool(d.get("toggle", false)):
			b.toggle_mode = true
			if str(d.get("group", "")) != "":
				b.button_group = _stance_group
		b.pressed.connect(_on_command.bind(id))
		_cmd_row.add_child(b)
		_buttons[id] = b


func _clear_buttons() -> void:
	for c in _cmd_row.get_children():
		c.queue_free()
	_buttons.clear()


## 按钮表：id -> {text 基础名 / toggle / group / width / tip}。
## 动态部分（「开始巡逻(N 点)」、开关状态）在 _sync_buttons 里覆盖。
func _button_defs() -> Dictionary:
	return {
		"auto_attack": {"text": "自动攻击", "toggle": true, "width": 116,
			"tip": "关掉后本角色不再自动索敌开火（仍然可以下移动/巡逻指令）"},
		"stance_nearest": {"text": "索敌·最近", "toggle": true, "group": "stance", "width": 116,
			"tip": "自动挑射程内最近的敌人开打（默认）"},
		"stance_strongest": {"text": "索敌·最强", "toggle": true, "group": "stance", "width": 116,
			"tip": "优先打生命上限最高、打得最疼的那个（先拆威胁最大的）"},
		"attack_designated": {"text": "指定攻击", "width": 116,
			"tip": "点一下进入待选，再点一个敌人 = 锁定它（死后或跑出射程自动解除）"},
		"patrol": {"text": "巡逻", "width": 130,
			"tip": "点一下开始设巡逻点（点地面/小地图加点），再点一下开始巡逻，再点停下"},
		"cancel": {"text": "取消指令", "width": 116,
			"tip": "解除指定目标 + 停止巡逻 + 停下脚步（不影响自动攻击开关与索敌策略）"},
	}


func _on_command(id: String) -> void:
	var p = _selected_player()
	if p == null:
		return
	match id:
		"auto_attack":
			p.set_auto_attack(not bool(p.get("auto_attack_on")))
		"stance_nearest":
			p.set_target_stance(&"nearest")
		"stance_strongest":
			p.set_target_stance(&"strongest")
		"attack_designated":
			p.arm_designate()
		"patrol":
			match str(p.patrol_state()):
				"":
					p.begin_patrol_setup()
				"setting":
					# 已经点了地面加点 → 这一下 = 开始巡逻；一个点都没设就留在设点模式
					p.start_patrol()
				"active":
					p.stop_patrol()
		"cancel":
			p.cancel_commands()
	_refresh_commands()


## 每帧把按钮外观对齐角色状态（开关的亮灭、巡逻按钮的三态文字）
func _sync_buttons(p) -> void:
	if _buttons.has("auto_attack"):
		var b: Button = _buttons["auto_attack"]
		b.set_pressed_no_signal(bool(p.get("auto_attack_on")))
		b.text = "自动攻击：开" if bool(p.get("auto_attack_on")) else "自动攻击：关"
	if _buttons.has("stance_nearest"):
		(_buttons["stance_nearest"] as Button).set_pressed_no_signal(
				str(p.get("target_stance")) != "strongest")
	if _buttons.has("stance_strongest"):
		(_buttons["stance_strongest"] as Button).set_pressed_no_signal(
				str(p.get("target_stance")) == "strongest")
	if _buttons.has("attack_designated"):
		var b: Button = _buttons["attack_designated"]
		var armed := str(p.arm_mode()) == "designate"
		b.set_pressed_no_signal(armed)
		b.text = "点敌人…" if armed else "指定攻击"
	if _buttons.has("patrol"):
		var b: Button = _buttons["patrol"]
		match str(p.patrol_state()):
			"setting":
				b.set_pressed_no_signal(true)
				b.text = "开始巡逻（%d 点）" % int(p.patrol_point_count())
			"active":
				b.set_pressed_no_signal(true)
				b.text = "停止巡逻（%d 点）" % int(p.patrol_point_count())
			_:
				b.set_pressed_no_signal(false)
				b.text = "巡逻"


## 状态行：当前指令一句话（玩家据此确认「我刚才那下点到了没」）
func _status_text(p) -> String:
	var arm := str(p.arm_mode())
	if arm == "designate":
		return "指定攻击：请点一个敌人（ESC 或右键取消）"
	if arm == "patrol_set":
		return "巡逻设点中：%d 个点（点地面/小地图加点，ESC 取消）" % int(p.patrol_point_count())
	var ps := str(p.patrol_state())
	if ps == "active":
		return "巡逻中：%d 个点循环（右键或「取消指令」停下）" % int(p.patrol_point_count())
	var t = p.get("designated_target")
	if t != null and is_instance_valid(t):
		var nm := str(t.get("type_name"))
		if nm == "":
			nm = "目标"
		return "指定攻击 → %s（HP %d/%d）" % [nm, int(t.get("hp")), int(t.get("max_hp"))]
	var tgt = p.auto_target()
	if tgt != null and is_instance_valid(tgt):
		return "自动索敌中 → %s" % str(tgt.get("type_name"))
	if not bool(p.get("auto_attack_on")):
		return "自动攻击已关闭 —— 本角色不会主动开火"
	return "自动索敌中（射程内暂无敌情）"


func _hint_text(p) -> String:
	var stance := "最强" if str(p.get("target_stance")) == "strongest" else "最近"
	return "索敌策略：%s　·　左键点地/点小地图 = 移动　·　右键 = 取消指令　·　ESC 退出待点选" % stance


# ------------------------------------------------------------
# 噪音表
# ------------------------------------------------------------

func _refresh_noise(delta: float) -> void:
	var cur: float = NoiseSystem.current_noise
	var lv: Dictionary = NoiseSystem.noise_level()
	_cur_bar.value = minf(cur, _cur_bar.max_value)
	_cur_value.text = "%.0f" % cur
	_cur_fill.bg_color = lv["color"]
	_cur_level.text = "档位：%s" % str(lv["name"])
	_cur_level.add_theme_color_override("font_color", lv["color"])

	_acc_bar.value = NoiseSystem.accumulated_ratio() * _acc_bar.max_value
	_acc_value.text = "%.0f" % NoiseSystem.accumulated_noise

	# 被惊动的敌人数：0.25 秒一次就够（这是给玩家看的氛围读数，不是判定依据）
	_alert_timer -= delta
	if _alert_timer <= 0.0:
		_alert_timer = float(Config.get_value("noise.display.alert_watch_interval_seconds", 0.25))
		_alert_count = NoiseSystem.alerted_enemy_count()
	_alert_label.text = ("被惊动 %d" % _alert_count) if _alert_count > 0 else ""


## 小地图点击 → 世界坐标 → 交给选中单位执行（与直接点地图完全同一条路径）
func _on_minimap_clicked(world_pos: Vector2) -> void:
	var p = _selected_player()
	if p == null:
		return
	p.command_click(world_pos)

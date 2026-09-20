extends CanvasLayer
## ============================================================
## DebugStatPanel — 局内右侧「数值调试」栏（F9 开关，出厂默认关）
##
## 为什么要有它：调角色数值原本只有两条路 —— 改 Data/config/ 重开一局，
## 或者去局外「参数配置」面板（那是给**玩家**看的，写 user://settings.json，
## 还要点「确认应用」，而且只列了显示/音频/玩法那几项，不含战斗数值）。
## 本面板走第三条路：写 Config 的**运行时覆盖层**（只存内存，退出即忘）。
##
## 覆盖层这一选定了三条理由（不是随手挑的）：
##   · 不污染 Data/config/ —— 那是版本管理里的出厂值；
##   · 不污染 user://settings.json —— 那层会**悄悄盖住**出厂值，
##     调完忘了还原就会带进回归套件和导出包（本项目踩过一次时序坑）；
##   · 与探针/回归天然隔离：那些自己也用 set_override，面板关掉即可。
##
## 【改完多久生效】分三种，面板里用标记区分，别猜：
##   无标记  = 每次现算（伤害/视野/射程/攻速/弹速/时序/短缺扣减）→ 下一击就是新值
##   标记 ↻  = 开局缓存，本面板**已经顺手通知在场单位重算了**
##             （移速/生命上限/近战判定圆/敌人兵种数值/敌人 AI 缓存，
##              见 player.gd·enemy.gd·animal.gd 各自的 refresh_debug_stats）
##   标记 ↺  = 生成期才读（刷怪数量、抽样权重、地图）→ 本局看不到，**重出击**才生效
##
## 【兵种数值为什么不走覆盖层】enemy_types.types / animal_types.types /
## progression.traits.list / survival.supplies 都是**数组**，而 Config 的点路径
## 只穿字典（_probe 只认 Dictionary.has）。给覆盖层加数组下标要动取值主路径，
## 全工程每次读配置都走那儿，风险不成比例。所以这些行直接改**类型字典本身**：
## 那些字典被 EnemySystem 抽样池与每只怪的 _type_cfg 共用（引用语义），
## 改一次，在场怪与之后新刷的怪都读到新值。
## ⚠ 代价：这改的是内存里那份 _data，**退出即忘但本进程内不落盘**，
##   面板顶部会一直显示"本次改了几项兵种表数值"，「全部还原」按快照写回。
##
## 【血上限】改了 max_hp 当场**回满血**（用户 2026-09-20 定）：
##   调完数值还要先吃药或重开一局才看得出效果，调试节奏会被打断。
##
## 【布局】右侧竖条，宽 272（视口固定 960×540 → 约 28% 屏宽；这条宽度是探针实测
##   出来的最小够用值，见下面 DOCK_W 的预算注释），
##   底部让开常驻菜单栏（让位公式与 HUD 同源 UiKit.menu_bar_height），
##   整块 mouse_filter = STOP —— 否则在栏里拖滑块会顺手给世界下一条移动令；
##   并挂在组 debug_dock 里让 camera_controller 豁免它，不然鼠标停在栏上
##   会把边缘滚屏整个停掉（那个豁免原先只认 menu_bar 组）。
## ============================================================

## 栏宽预算（探针实测，别再凭感觉调）：一行 = 标签 104 + SpinBox + 还原 24 + 两个间隔 6。
## SpinBox 的 custom_minimum_size 只是**下限**，它固有最小宽约 110（内部 LineEdit + 箭头），
## 所以一行 241；再加纵向滚动条 12 + 内容边距 12 + 描边 2 = 267 → 252 撑不住。
## 272 / 960 ≈ 28% 屏宽，右边留出这条窄栏不影响战场读数。
const DOCK_W := 272.0
const TOP_MARGIN := 6.0
const SIDE_MARGIN := 6.0
const BOTTOM_GAP := 6.0
const REFRESH_SECONDS := 0.25

## 行控件宽度：一列同宽，右缘才是一条直线
const LABEL_W := 104.0
## SpinBox 的 custom_minimum_size 只是**下限**：它自身的输入框 + 箭头有更大的固有宽度
## （探针实测一行 241px），一列同宽排到 252 的栏里刚好顶满，所以这里留余量。
const SPIN_W := 72.0
const RESET_W := 24.0

var _panel: PanelContainer = null
var _list: VBoxContainer = null
var _live: VBoxContainer = null
var _live_labels: Array = []
var _status: Label = null
var _built := false

## 段展开状态：id -> true（默认只展开「在场单位」和第一段可调项）
var _open: Dictionary = {"live": true, "player": true}
## 兵种表改动的原值快照：_key(spec) -> {"el": 元素字典引用, "k": 键名, "orig": 原值}
## 存**字典引用**而不是路径字符串：那些字典被 EnemySystem 的抽样池和每只怪的
## _type_cfg 共用（引用语义），改它 == 改在场怪的来源；还原也就不用再反解一次路径。
var _type_edits: Dictionary = {}
## 在场兵种之外的兵种要不要列出来
var _show_all_types := false
var _tick := 0.0
var _last_vp := Vector2.ZERO


func _ready() -> void:
	layer = 2
	add_to_group("debug_stat_panel")
	# 暂停/模态面板开着也要按得动 F9（调数值时经常顺手暂停画面看细节）
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false


# ------------------------------------------------------------
# 开关
# ------------------------------------------------------------

func _input(event: InputEvent) -> void:
	var e := event as InputEventKey
	if e == null or not e.pressed or e.echo:
		return
	if e.physical_keycode != toggle_key():
		return
	toggle()
	get_viewport().set_input_as_handled()


## 快捷键（出厂 F9）。存物理键码：与项目里其它改键一致，非 QWERTY 布局不会错位。
func toggle_key() -> int:
	return int(Config.get_value("debug.stat_panel_key", KEY_F9))


func toggle() -> void:
	if not _built:
		_build()
	visible = not visible
	if visible:
		_rebuild_rows()
		_refresh_live()
		print("[DebugPanel] 打开：改动写在 Config 覆盖层（内存），退出即忘。按 F9 关闭。")


# ------------------------------------------------------------
# 骨架
# ------------------------------------------------------------

func _build() -> void:
	_built = true
	var host := Control.new()
	host.name = "DebugStatPanel"
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.stretch(host)
	add_child(host)

	_panel = _dock_panel()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.name = "Dock"
	# 右边缘竖条：锚点四角钉右满高，bottom offset 让开底部菜单栏
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -DOCK_W - SIDE_MARGIN
	_panel.offset_right = -SIDE_MARGIN
	_panel.offset_top = TOP_MARGIN
	_panel.add_to_group("debug_dock")
	host.add_child(_panel)
	_relayout()

	var col := UiKit.vbox(4)
	_panel.add_child(col)

	var head := UiKit.hbox(4)
	col.add_child(head)
	head.add_child(UiKit.section("数值调试"))
	var btn_close := UiKit.small_button("×", 24, UiKit.FS_SMALL)
	btn_close.tooltip_text = "关闭（F9）"
	btn_close.pressed.connect(func(): toggle())
	head.add_child(btn_close)

	var tools := UiKit.hbox(4)
	col.add_child(tools)
	# 文案只留两个字：small_button 的贴图自带 18px 左右内容边距，四字文案
	# 三个并排就是 276px，会把 252 宽的栏整个撑宽（右锚栏撑宽 = 往屏幕外长）。
	var btn_reset := UiKit.small_button("还原", 62, UiKit.FS_SMALL)
	btn_reset.tooltip_text = "全部还原：清掉内存覆盖层 + 把兵种表改动写回原值（不碰 settings.json / config.json）"
	btn_reset.pressed.connect(_reset_everything)
	tools.add_child(btn_reset)
	var btn_print := UiKit.small_button("打印", 62, UiKit.FS_SMALL)
	btn_print.tooltip_text = "打印改动：把本次改过的项连值一起打到控制台，方便抄回 Data/config/"
	btn_print.pressed.connect(_print_changes)
	tools.add_child(btn_print)
	var btn_types := UiKit.small_button("兵种", 62, UiKit.FS_SMALL)
	btn_types.tooltip_text = "全部兵种：列出所有兵种（默认只列场上活着的，省地方）"
	btn_types.pressed.connect(func():
		_show_all_types = not _show_all_types
		_rebuild_rows())
	tools.add_child(btn_types)
	tools.add_child(_expander())

	_status = UiKit.dim("无改动")
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)

	# 可调区整块可滚：视口只有 540 高，去掉底部菜单栏只剩 ~420px
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	_list = UiKit.vbox(3)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	get_viewport().size_changed.connect(_relayout)


## 视口高度变了要重让位（与 menu_bar.gd 同一个坑：size_changed 可能在窗口定型前就发过）
func _relayout() -> void:
	if _panel == null:
		return
	var vp := get_viewport().get_visible_rect().size
	_last_vp = vp
	var bar := UiKit.menu_bar_height(vp.y) if UiKit.menu_bar_enabled() else 0.0
	_panel.offset_bottom = -(bar + BOTTOM_GAP)


## 右栏专用壳：**不能**用 UiKit.panel() —— 那是对话框的 paper_dark 九宫格，
## 左右内容边距各 56（给描金角花留位），252 宽的栏会被直接撑到 388（探针实测），
## 右锚控件被撑宽就是往屏幕外长。调试工具不需要那层排场：扁平深色 + 一道描边。
func _dock_panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiKit.COL_PANEL
	sb.border_color = Color(UiKit.COL_LINE.r, UiKit.COL_LINE.g, UiKit.COL_LINE.b, 0.7)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 5
	sb.content_margin_bottom = 7
	p.add_theme_stylebox_override("panel", sb)
	return p


func _expander() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# ------------------------------------------------------------
# 行表构建
# ------------------------------------------------------------

func _rebuild_rows() -> void:
	for c in _list.get_children():
		c.queue_free()
	_list.add_child(_live_section())
	_list.add_child(_section_of("player", "玩家 · 全局", _rows_player()))
	_list.add_child(_section_of("traits", "升级特性 per_stack", _rows_trait_table()))
	_list.add_child(_section_of("weapons", "武器", _rows_weapons()))
	_list.add_child(_section_of("enemy", "敌人 · 全局", _rows_enemy()))
	_list.add_child(_section_of("etypes", "敌人 · 兵种", _rows_enemy_types()))
	_list.add_child(_section_of("animals", "中立生物", _rows_animals()))
	_list.add_child(_section_of("survival", "生存消耗", _rows_survival()))
	_list.add_child(_section_of("run", "局内节奏", _rows_run()))
	_refresh_status()


## 段容器：一个「▸ 标题」按钮 + 一个可折叠的 VBox
func _section_of(id: String, title: String, rows: Array) -> Control:
	var box := UiKit.vbox(2)
	var head := UiKit.small_button("", 0, UiKit.FS_SMALL)
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var body := UiKit.vbox(2)
	head.pressed.connect(func():
		_open[id] = not bool(_open.get(id, false))
		_apply_open(id, head, body, title))
	_apply_open(id, head, body, title)
	box.add_child(head)
	box.add_child(body)
	for spec in rows:
		_add_row(body, spec)
	if rows.is_empty():
		body.add_child(UiKit.dim("（场上没有这一类单位）"))
	return box


func _apply_open(id: String, head: Button, body: Control, title: String) -> void:
	var on := bool(_open.get(id, false))
	head.text = ("▾ " if on else "▸ ") + title
	body.visible = on


## 「在场单位」段：只读，显示**当前真正生效**的那套数值与它的来源拆解。
## 放在最顶是因为调完数值得先确认"到底吃进去没有"，光看滑块停在哪儿看不出来。
func _live_section() -> Control:
	var box := UiKit.vbox(2)
	var head := UiKit.small_button("", 0, UiKit.FS_SMALL)
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.text = "▾ 在场单位（生效值）"
	head.pressed.connect(func():
		_open["live"] = not bool(_open.get("live", false))
		head.text = ("▾ " if bool(_open["live"]) else "▸ ") + "在场单位（生效值）"
		_live.visible = bool(_open["live"]))
	_live = UiKit.vbox(1)
	# 标签池跟着 _live 一起作废：旧节点正随 _rebuild_rows 排队 free，
	# 留着引用就是往已释放的 Label 上写字（validate 报错 + 面板空白）。
	_live_labels = []
	box.add_child(head)
	box.add_child(_live)
	return box


func _add_row(box: Control, spec: Dictionary) -> void:
	if bool(spec.get("header", false)):
		var hdr := UiKit.dim(str(spec.get("label", "")), UiKit.FS_SMALL)
		box.add_child(hdr)
		return

	var row := UiKit.hbox(3)
	box.add_child(row)
	var name_lbl := UiKit.label(str(spec.get("label", "?")), UiKit.FS_SMALL)
	name_lbl.custom_minimum_size = Vector2(LABEL_W, 0)
	name_lbl.clip_text = true
	row.add_child(name_lbl)

	if bool(spec.get("bool", false)):
		var cb := UiKit.checkbox("开", bool(_read(spec, false)))
		cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cb.tooltip_text = str(spec.get("path", ""))
		cb.toggled.connect(func(on: bool): _write(spec, 1.0 if on else 0.0))
		var cb_reset := UiKit.small_button("×", RESET_W, UiKit.FS_SMALL)
		cb_reset.tooltip_text = "恢复这一项"
		cb_reset.disabled = not _is_dirty(spec)
		cb_reset.pressed.connect(func(): _reset_one(spec))
		row.add_child(cb)
		row.add_child(cb_reset)
		if _is_dirty(spec):
			name_lbl.modulate = UiKit.COL_AMBER
		return

	var spin := SpinBox.new()
	spin.min_value = float(spec.get("min", 0.0))
	spin.max_value = float(spec.get("max", 999999.0))
	var step := float(spec.get("step", 1.0))
	spin.step = step        # 小数位由 step 推（4.7 的 SpinBox 没有可写 digits 了）
	spin.custom_minimum_size = Vector2(SPIN_W, 0)
	spin.tooltip_text = str(spec.get("path", spec.get("note", "")))
	spin.value = float(_read(spec, 0.0))
	spin.value_changed.connect(func(v: float): _write(spec, v))
	row.add_child(spin)

	var reset := UiKit.small_button("×", RESET_W, UiKit.FS_SMALL)
	reset.tooltip_text = "恢复这一项"
	reset.pressed.connect(func(): _reset_one(spec))
	row.add_child(reset)

	# ↻ = 开局缓存（本面板已通知重算）；↺ = 生成期才读，本局看不到
	if bool(spec.get("cached", false)):
		name_lbl.text += " ↻"
	if bool(spec.get("regen", false)):
		name_lbl.text += " ↺"
		name_lbl.tooltip_text = "本局不生效：重出击后才读新值"
	if _is_dirty(spec):
		name_lbl.modulate = UiKit.COL_AMBER
	reset.disabled = not _is_dirty(spec)


# ------------------------------------------------------------
# 各段的行表
# ------------------------------------------------------------

func _rows_player() -> Array:
	return [
		{"label": "移速 px/s", "path": "player.speed", "cached": true},
		{"label": "视野 格", "path": "player.vision_radius_cells", "cached": true},
		{"label": "生命上限 出厂", "path": "combat.player.max_hp", "cached": true,
			"note": "改了当场回满血。⚠ 有局外养成值时被下面「养成」那行顶替"
					+ "（compute_max_hp：养成 base>0 就整个替换出厂值，不是相加）"},
		{"label": "生命上限 养成", "path": "meta_progression.survival.max_hp.base",
			"cached": true, "note": "真正生效的那一行：出厂 base=100 就已经盖住出厂 max_hp"},
		{"label": "基础伤害", "path": "combat.attack.damage"},
		{"label": "基础射程 px", "path": "combat.attack.range_px", "step": 1.0, "cached": true,
			"note": "近战判定圆半径跟着重算"},
		{"label": "扇形角度", "path": "combat.attack.arc_degrees"},
		{"label": "最多目标", "path": "combat.attack.max_targets"},
		{"label": "暴击率", "path": "combat.attack.crit_chance", "step": 0.05, "max": 1.0,
			"note": "每次**命中**各抽一次（砍中三个 = 抽三次）；武器表写了 crit_chance 的听武器表"},
		{"label": "暴击倍率", "path": "combat.attack.crit_multiplier", "step": 0.1},
		{"label": "伤害浮动", "path": "combat.attack.variance", "step": 0.05,
			"note": "0.1 = ±10%，最后向下取整；武器表同样可覆盖"},
		{"label": "前摇 s", "path": "combat.attack.windup_seconds", "step": 0.01, "min": -1.0},
		{"label": "判定 s", "path": "combat.attack.active_seconds", "step": 0.01, "min": -1.0},
		{"label": "后摇 s", "path": "combat.attack.recovery_seconds", "step": 0.01, "min": -1.0},
		{"label": "硬直 s", "path": "combat.player.hitstun_seconds", "step": 0.01},
		{"label": "无敌帧 s", "path": "combat.player.invincible_after_hit_seconds", "step": 0.01},
		{"label": "击退初速", "path": "combat.player.knockback_speed", "step": 10.0},
		{"label": "冲刺时长 s", "path": "combat.dodge.duration_seconds", "step": 0.01},
		{"label": "冲刺速度倍", "path": "combat.dodge.speed_multiplier", "step": 0.1},
		{"label": "冲刺冷却 s", "path": "combat.dodge.cooldown_seconds", "step": 0.01},
		{"label": "索敌间隔 s", "path": "combat.auto_attack.scan_interval_seconds", "step": 0.01},
		{"label": "自动攻击", "path": "combat.auto_attack.enabled", "bool": true, "cached": true},
		{"label": "背包格", "path": "meta_progression.survival.backpack_capacity.base",
			"cached": true, "note": "每人一份；已上身的东西不会被挤掉"},
	]


## 特性 per_stack 写在 progression.traits.list 数组里 → 走类型字典那条路
func _rows_trait_table() -> Array:
	return _table_rows("progression.traits.list", "per_stack",
			func(t: Dictionary) -> String: return "%s/层" % str(t.get("name", "?")))


## 武器段：id 是字典键，所以能走点路径（不用类型字典那条路）
func _rows_weapons() -> Array:
	var out: Array = []
	var table = Config.get_value("combat.weapons", {})
	if not (table is Dictionary):
		return out
	for wid in (table as Dictionary).keys():
		var key := str(wid)
		if key.begins_with("_"):
			continue
		var w: Dictionary = (table as Dictionary)[wid]
		if w.is_empty():
			continue
		var wn := str(w.get("name", key))
		out.append({"label": "— %s —" % wn, "header": true})
		out.append({"label": "%s 伤害" % wn, "path": "combat.weapons.%s.damage" % key})
		out.append({"label": "%s 射程" % wn, "path": "combat.weapons.%s.range_px" % key,
			"cached": true})
		out.append({"label": "%s 扇形°" % wn, "path": "combat.weapons.%s.arc_degrees" % key})
		out.append({"label": "%s 目标数" % wn, "path": "combat.weapons.%s.max_targets" % key})
		out.append({"label": "%s 前摇" % wn, "path": "combat.weapons.%s.windup_seconds" % key,
			"step": 0.01})
		out.append({"label": "%s 判定" % wn, "path": "combat.weapons.%s.active_seconds" % key,
			"step": 0.01})
		out.append({"label": "%s 后摇" % wn, "path": "combat.weapons.%s.recovery_seconds" % key,
			"step": 0.01})
		out.append({"label": "%s 噪音" % wn, "path": "combat.weapons.%s.noise" % key, "step": 10.0})
		var sd: Dictionary = w.get("projectile", {})
		if not sd.is_empty():
			if sd.has("max_distance_px"):
				out.append({"label": "%s 弹射程" % wn,
						"path": "combat.weapons.%s.projectile.max_distance_px" % key, "step": 10.0})
			if sd.has("speed"):
				out.append({"label": "%s 弹速" % wn,
						"path": "combat.weapons.%s.projectile.speed" % key, "step": 10.0})
	return out


func _rows_enemy() -> Array:
	return [
		{"label": "默认生命", "path": "enemy.max_hp", "cached": true,
			"note": "兵种没写 hp 才用它"},
		{"label": "默认伤害", "path": "enemy.contact_damage", "cached": true},
		{"label": "游速 px/s", "path": "enemy.speed", "step": 10.0},
		{"label": "追击倍率", "path": "enemy.chase_speed_multiplier", "step": 0.05},
		{"label": "视野 格", "path": "enemy.vision_cells"},
		{"label": "出手距离 px", "path": "enemy.attack.range_px", "cached": true},
		{"label": "出手冷却 s", "path": "enemy.attack.cooldown_seconds", "step": 0.01,
			"cached": true},
		{"label": "出手前摇 s", "path": "enemy.attack.windup_seconds", "step": 0.01,
			"cached": true},
		{"label": "伤害浮动", "path": "enemy.attack.variance", "step": 0.05, "cached": true,
			"note": "0.1 = ±10%；全局档，兵种不单独覆盖"},
		{"label": "受击泛红 s", "path": "enemy.hit_flash_seconds", "step": 0.01},
		{"label": "受击击退 px", "path": "enemy.hit_knockback_px", "step": 0.5},
		{"label": "受击微顿 s", "path": "enemy.hit_stun_seconds", "step": 0.01},
		{"label": "AI 活跃 格", "path": "enemy.ai_active_radius_cells"},
		{"label": "巡逻半径 格", "path": "enemy.ai.roam.patrol_radius_cells", "cached": true},
		{"label": "听力倍率", "path": "enemy.ai.noise_sensitivity", "step": 0.05, "cached": true},
		{"label": "结伙上限", "path": "enemy.ai.pack.max_members", "cached": true},
		{"label": "结伙开关", "path": "enemy.ai.pack.enabled", "bool": true, "cached": true},
		{"label": "刷怪数量", "path": "enemy.count", "regen": true, "step": 10.0},
	]


func _rows_enemy_types() -> Array:
	var alive := _alive_type_ids("enemies")
	return _table_rows("enemy_types.types", "",
			func(t: Dictionary) -> String: return str(t.get("name", t.get("id", "?"))),
			["hp", "damage", "speed_mult", "attack_range_px"],
			alive)


func _rows_animals() -> Array:
	return [
		{"label": "游速 px/s", "path": "animals.speed", "step": 10.0},
		{"label": "逃跑倍率", "path": "animals.flee_speed_mult", "step": 0.05},
		{"label": "逃跑半径 格", "path": "animals.flee_radius_cells"},
		{"label": "游荡半径 格", "path": "animals.wander_radius_cells"},
		{"label": "掉落概率", "path": "animals.drop.chance", "step": 0.05, "max": 1.0},
		{"label": "掉落少/多", "path": "animals.drop.amount_min"},
		{"label": "掉落上限", "path": "animals.drop.amount_max"},
		{"label": "数量", "path": "animals.count", "regen": true},
	] + _table_rows("animal_types.types", "",
			func(t: Dictionary) -> String: return str(t.get("name", t.get("id", "?"))),
			["hp"], _alive_type_ids("animals"))


func _rows_survival() -> Array:
	var out: Array = [
		{"label": "开饭间隔 s", "path": "survival.meal_interval_seconds", "step": 5.0},
		{"label": "饥饿掉血", "path": "survival.starvation_damage"},
		{"label": "饥饿间隔 s", "path": "survival.starvation_interval_seconds", "step": 5.0},
		{"label": "饥饿血量底", "path": "survival.starvation_hp_floor"},
		{"label": "进食回血", "path": "survival.heal_per_food"},
		{"label": "进食冷却 s", "path": "survival.eat_cooldown_seconds", "step": 0.1},
	]
	var supplies = Config.get_value("survival.supplies", [])
	if supplies is Array:
		for i in range((supplies as Array).size()):
			var s: Dictionary = (supplies as Array)[i]
			var sid := str(s.get("id", i))
			out.append({"label": "%s 每顿扣" % sid, "table": "survival.supplies",
				"index": i, "key": "per_meal", "cached": true})
			var debuffs = s.get("shortage_debuff", {})
			if debuffs is Dictionary:
				for attr in (debuffs as Dictionary).keys():
					out.append({"label": "%s缺·%s" % [sid, _attr_name(str(attr))],
						"table": "survival.supplies", "index": i, "sub": "shortage_debuff",
						"key": str(attr), "cached": true})
	return out


func _rows_run() -> Array:
	return [
		{"label": "局时长 s", "path": "session.time_limit_seconds", "regen": true, "step": 60.0},
		{"label": "倒计时倍速", "path": "debug.time_scale", "step": 0.5},
		{"label": "背包格数下限", "path": "storage.stack_limit", "regen": true, "step": 50.0},
	]


## 通用：把某个数组型配置表铺成行
##   keys   —— 要列出的字段（省略 = 只列 `one_key`）
##   alive  —— 在场 id 集合；给了它就只列在场的那些（_show_all_types 可强开全表）
func _table_rows(table_path: String, one_key: String, label_of: Callable,
		keys: Array = [], alive: Array = []) -> Array:
	var out: Array = []
	var arr = Config.get_value(table_path, [])
	if not (arr is Array):
		return out
	var cols := keys if not keys.is_empty() else [one_key]
	for i in range((arr as Array).size()):
		var el: Dictionary = (arr as Array)[i]
		var tid := str(el.get("id", ""))
		if not alive.is_empty() and not _show_all_types and not alive.has(tid):
			continue
		var who: String = str(label_of.call(el))
		for k in cols:
			var key := str(k)
			out.append({
				"label": "%s %s" % [who, _attr_name(key)],
				"table": table_path, "index": i, "key": key,
				"step": _step_for(el.get(key, 1)),
				"cached": true,
			})
	return out


func _step_for(v) -> float:
	if v is int:
		return 1.0
	if v is float:
		return 0.05 if absf(v) < 10.0 else 1.0
	return 1.0


func _attr_name(key: String) -> String:
	var names := {
		"hp": "生命", "damage": "伤害", "speed_mult": "速度倍", "attack_range_px": "射程",
		"per_stack": "每层", "weight": "权重",
		"attack": "攻击", "defense": "防御", "move_speed": "移速", "vision": "视野",
		"attack_range": "攻击距离", "attack_speed": "攻速", "projectile_speed": "弹速",
	}
	return str(names.get(key, key))


# ------------------------------------------------------------
# 读 / 写 / 还原
# ------------------------------------------------------------

func _read(spec: Dictionary, default):
	if spec.has("path"):
		return Config.get_value(str(spec["path"]), default)
	var el = _table_element(spec)
	var key := str(spec.get("key", ""))
	if el == null or not el.has(key):
		return default
	return el[key]


## 取类型字典（含 sub 子字典）。取不到返回 null —— 数组长度被 config 改短时
## 面板里那一行就该自己消失（下次 _rebuild_rows 就没有它了），不能崩在这儿。
func _table_element(spec: Dictionary):
	var arr = Config.get_value(str(spec.get("table", "")), [])
	if not (arr is Array):
		return null
	var i := int(spec.get("index", -1))
	if i < 0 or i >= (arr as Array).size():
		return null
	var node: Variant = (arr as Array)[i]
	if spec.has("sub") and node is Dictionary:
		node = (node as Dictionary).get(str(spec["sub"]), null)
	return node if node is Dictionary else null


func _key(spec: Dictionary) -> String:
	var key := str(spec["key"])
	if spec.has("sub"):
		key = "%s.%s" % [str(spec["sub"]), key]
	return "%s#%d.%s" % [str(spec["table"]), int(spec["index"]), key]


func _write(spec: Dictionary, v: float) -> void:
	if spec.has("path"):
		var base = Config.get_base_value(str(spec["path"]), null)
		Config.set_override(str(spec["path"]), _typed(v, base))
	else:
		var el = _table_element(spec)
		if el == null or not el.has(str(spec["key"])):
			push_warning("[DebugPanel] 写不进类型表：%s" % _key(spec))
			return
		var origin = el[str(spec["key"])]
		var k := _key(spec)
		if not _type_edits.has(k):
			_type_edits[k] = {"el": el, "k": str(spec["key"]), "orig": origin}
		el[str(spec["key"])] = _typed(v, origin)
	refresh_live_units()
	_refresh_status()


## 按**原值的类型**决定存 int 还是 float：0.35 秒存成 int 就变成 0 了，
## 而 enemy.count 这类整数存成 100.5 会被 int() 截断，读代码的人会看不懂。
func _typed(v: float, origin) -> Variant:
	if origin is bool:
		return v >= 0.5
	if origin is int:
		return roundi(v)
	return v


func _reset_one(spec: Dictionary) -> void:
	if spec.has("path"):
		Config.clear_override(str(spec["path"]))
	else:
		var k := _key(spec)
		if not _type_edits.has(k):
			return
		var rec: Dictionary = _type_edits[k]
		(rec["el"] as Dictionary)[rec["k"]] = rec["orig"]
		_type_edits.erase(k)
	refresh_live_units()
	_rebuild_rows()


func _reset_everything() -> void:
	Config.clear_overrides()
	for k in _type_edits.keys():
		var rec: Dictionary = _type_edits[k]
		(rec["el"] as Dictionary)[rec["k"]] = rec["orig"]
	_type_edits = {}
	refresh_live_units()
	_rebuild_rows()


func _is_dirty(spec: Dictionary) -> bool:
	if spec.has("path"):
		return Config.has_override(str(spec["path"]))
	return _type_edits.has(_key(spec))


## 通知在场单位按新配置重算「开局缓存」的那几个属性。
## 现算类（伤害/视野/射程/时序）不需要这一步，但也无害 —— 就是空跑一遍。
func refresh_live_units() -> void:
	for g in ["player", "enemies", "animals"]:
		for n in get_tree().get_nodes_in_group(g):
			if is_instance_valid(n) and n.has_method("refresh_debug_stats"):
				n.refresh_debug_stats()


func _refresh_status() -> void:
	var n := Config.override_paths().size() + _type_edits.size()
	if _status != null:
		_status.text = ("已改 %d 项（内存层，退出即忘）" % n) if n > 0 else "无改动"
		_status.modulate = UiKit.COL_AMBER if n > 0 else UiKit.COL_DIM


func _print_changes() -> void:
	var paths: Array = Config.override_paths()
	print("===== 数值调试面板：本次改动 =====")
	for p in paths:
		print("  %-52s %s （出厂 %s）" % [p, str(Config.get_value(p, null)),
				str(Config.get_base_value(p, null))])
	for k in _type_edits.keys():
		var rec: Dictionary = _type_edits[k]
		print("  %-52s %s （原 %s）" % [k, str((rec["el"] as Dictionary)[rec["k"]]),
				str(rec["orig"])])
	print("  —— 覆盖层退出即忘；要留下就照这张表改 Data/config/")
	print("====================================")


# ------------------------------------------------------------
# 在场单位的生效值（只读，每 0.25s 刷一次）
# ------------------------------------------------------------

func _process(delta: float) -> void:
	if not visible:
		return
	var vp := get_viewport().get_visible_rect().size
	if not is_equal_approx(vp.y, _last_vp.y):
		_relayout()
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = REFRESH_SECONDS
	_refresh_live()


func _refresh_live() -> void:
	if _live == null:
		return
	var lines: Array = _player_lines() + _crowd_lines("enemies", "敌") \
			+ _crowd_lines("animals", "兽")
	# 复用标签池：每 0.25s 重建整棵子树会白烧节点，也让滚动位置抖一下
	while _live_labels.size() < lines.size():
		var l := UiKit.dim("", UiKit.FS_SMALL)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_live.add_child(l)
		_live_labels.append(l)
	for i in range(_live_labels.size()):
		var lbl: Label = _live_labels[i]
		if i < lines.size():
			lbl.text = str(lines[i])
			lbl.visible = true
		else:
			lbl.visible = false


## 读数行必须**一行放得下**：栏只有 272 宽，标签开了自动换行，
## 一句长文案会被劈成两行（实拍里"射程 52"被折到下一行开头，读起来像坏了）。
## 所以这里一律短句 + 数字贴着单位，不带"px"这种赘字。
func _player_lines() -> Array:
	var out: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p) or bool(p.is_dead()):
			continue
		var base := float(p.attack_param("damage", 25.0))
		var w: Dictionary = p.weapon_data()
		out.append("%s Lv%d　HP %d/%d　速 %d" % [
			str(p.character_name), int(p.level), int(p.hp), int(p.max_hp),
			int(round(p.speed))])
		out.append("伤 %d（基础 %d %s%s）" % [
			int(round(float(p.trait_damage(base)))), int(round(base)),
			"+%d " % int(round(p.trait_flat("attack"))) if p.trait_flat("attack") != 0.0 else "",
			"-%d 短缺" % int(p.supply_penalty("attack")) if p.supply_penalty("attack") != 0.0 else ""])
		out.append("视野 %d　射程 %d　有效 %d" % [
			int(round(p.vision_px())), int(round(p.attack_range_px())),
			int(round(p.effective_attack_range_px()))])
		out.append("攻速 %+d%%　%s" % [
			int(round((p.call("_trait_cadence_scale") as float - 1.0) * 100.0)),
			str(w.get("name", "徒手"))])
	return out


## 敌人/动物按兵种汇总（21 个兵种 × 每只一行会把面板撑爆）。
## ⚠ 羊身上没有 damage / _attack_range，也没有 patrol_speed()：两类单位共用这条路径
## 就必须按成员/方法存在与否拼字。直接读会抛运行时错误，而错误发生在 _process 里
## —— 表现是整段「在场单位」空白，看起来像面板坏了，比数字写错难查得多。
func _crowd_lines(group: String, tag: String) -> Array:
	var out: Array = []
	var by_type: Dictionary = {}
	for n in get_tree().get_nodes_in_group(group):
		if not is_instance_valid(n) or not ("type_id" in n):
			continue
		if "hp" in n and int(n.get("hp")) <= 0:
			continue
		var tid := str(n.type_id)
		if not by_type.has(tid):
			by_type[tid] = {"node": n, "count": 0}
		var rec: Dictionary = by_type[tid]
		rec["count"] = int(rec["count"]) + 1
	var global_range := float(Config.get_value("enemy.attack.range_px", 52.0))
	for tid in by_type.keys():
		var rec: Dictionary = by_type[tid]
		var e: Node = rec["node"]
		var spd := 0.0
		if e.has_method("patrol_speed"):
			spd = float(e.call("patrol_speed"))
		elif e.has_method("_speed"):
			spd = float(e.call("_speed"))
		var line := "%s %s×%d HP%d 速%d" % [
			tag, str(e.type_name), int(rec["count"]), int(e.max_hp), int(round(spd))]
		if "damage" in e:
			line += " 伤%d" % int(e.damage)
		# 射程跟全局一样就不占地方（绝大多数兵种都一样）
		if "_attack_range" in e and not is_equal_approx(float(e.get("_attack_range")), global_range):
			line += " 程%d" % int(round(float(e.get("_attack_range"))))
		out.append(line)
	return out


func _alive_type_ids(group: String) -> Array:
	var out: Array = []
	for n in get_tree().get_nodes_in_group(group):
		if is_instance_valid(n) and "type_id" in n:
			var tid := str(n.type_id)
			if not out.has(tid):
				out.append(tid)
	return out

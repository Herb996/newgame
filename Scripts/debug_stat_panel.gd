extends CanvasLayer
## ============================================================
## DebugStatPanel — 按 F9 铺满屏幕的数值调试台（出厂默认关）
##
## 为什么要有它：调数值原本只有两条路 —— 改 Data/config/ 重开一局，
## 或者去局外「参数配置」面板（那是给**玩家**看的，写 user://settings.json，
## 只列显示/音频/玩法那几项，不含战斗数值）。本面板走第三条路。
##
## 【数据不是手写的】行表来自 res://Data/debug_stat_catalog.json，
## 由 tools/gen_stat_catalog.py 扫 Data/config/ 全部叶子 + 全工程
## 571 处 Config.get_value 调用点生成。加了配置项不用改面板，
## 重跑一次生成器就出现在正确的分类里。
##
## 【写哪儿】两步，不是一步到位：
##   第一步 改 → 只进内存，当场生效，退出即忘。按行的 via 字段分流：
##     override —— 纯字典路径：Config.set_override()。
##     inplace  —— 路径跨过数组（Config 的点路径只穿字典，_probe 不认下标），
##       只能就地改内存里那份共享容器；第一次改之前把原值存进 _edits，「还原」按快照写回。
##   第二步 顶栏「写入文件」→ 把内存里这些改动原地写进 Data/config/<域>.json。
##     写之前整份拷进 Backups/config/<时间戳>/（留最近 20 份），「还原备份」按最新一份拷回去。
##   为什么先内存后文件：调数值要的是「改一下马上看到」，而改文件对
##   重出击/重启两档的数值根本看不到效果，等于闭着眼睛改。
##   为什么落盘走 Config.write_domain_values 的原文替换而不是重新序列化：
##   JSON.stringify 会把键按字母排序，一次写入会把整份手写配置洗成字母序（git 炸）。
##   ⚠ 导出成 exe 后 res:// 只读，第二步会失败并提示，第一步照旧可用。
##   ⚠ user://settings.json 那层会**盖住**出厂值：被它遮住的行写完文件后
##   局内仍是旧值，面板会把这类行单独列出来（本项目踩过一次时序坑）。
##
## 【改了多久生效】五档，直接写在每一行右侧（TIER_CN），别猜：
##   立即     每次现算（伤害/射程/时序/扣减）
##   重算     开局缓存，但面板**已顺手通知在场单位重算**（refresh_debug_stats）
##   重出击   生成期才读（刷怪数量、抽样权重、地图）→ 本局看不到
##   重启     脚本顶层 const 编译期就固化了，重开进程才读
##   未接线   全工程找不到读点：配了也没人看（收进单独一类，见下）
##   ⚠ 档位是**静态推断**：读点函数名匹配出来的，当线索用别当合同。
##     早期版本用 ↻/↺ 两个箭头标，实拍里根本分不出来，已换成中文词。
##
## 【分类】左侧两级树：大类（角色/敌人/地图资源/升级特性/生存节奏/外观/未接线）
##   → 域文件名。域文件是刚拆出来的（Data/config/ 一个功能域一个 json），
##   所以它就是这个面板的权威分类，不再自己编第二套分组。
##
## 【布局】铺满 + 暂停：调数值时世界冻住才看得清效果，而且面板宽到
##   一定盖住战场。开面板 get_tree().paused=true，关掉恢复。
##   ⚠ 每次 _process 重新断言暂停：仓库/雕像/选人那几个模态面板关的时候会
##   把 paused 置回 false，不补这一刀就会出现「面板开着但怪在走动」。
##   「单步」按钮放行恰好一个 physics_frame，用来一帧一帧看受击/前摇时序。
##   行多：列数按视口宽度算（1920→4 列，1280→2 列），每类封顶 BUILD_CAP 行，
##   超了要求搜索或换域 —— 一次性铺 563 行会卡住开面板的那一帧。
##   壳不用 UiKit.fullscreen_panel()：那层 paper_dark 芯内容边距左右 56、
##   下 56（给描金角花留位），调试台是密集列表，112×86 的空白浪费不起，
##   所以只借它的木框，内芯换扁平深色 + 10px 边距。
##   还原/页签按钮也不用 UiKit.small_button()：那贴图最小高 42，
##   33 行就要 1400px，一屏放不下几行。这里换成扁平小按钮（26 高）。
##   整块 mouse_filter=STOP：否则在面板里拖滑块会顺手给世界下一条移动令。
##   挂组 debug_dock：不然鼠标停在面板上会把边缘滚屏整个停掉
##   （camera_controller 的豁免原先只认 menu_bar 组）。
## ============================================================

const CATALOG_PATH := "res://Data/debug_stat_catalog.json"
const REFRESH_SECONDS := 0.25
const BUILD_CAP := 400

## 行内各列宽度（行最小宽 = 之和 + 间隔，决定一屏放几列）。
## NAME_W 只是**下限**：行给了 EXPAND_FILL，实测 1920 下四列每列 421，
## 标题实际拿到 ~252px —— 再往下压就会看到成片的省略号（实拍里 138 就是这个下场）。
const NAME_W := 200.0
const SPIN_W := 92.0
const TIER_W := 46.0
const RESET_W := 22.0
const ROW_GAP := 3.0
const COL_GAP := 8.0
const TREE_W := 176.0
const ROW_MIN_W := NAME_W + SPIN_W + TIER_W + RESET_W + ROW_GAP * 3.0

const CATS := [
	["char", "角色"],
	["enemy", "敌人"],
	["map", "地图资源"],
	["trait", "升级特性"],
	["run", "生存节奏"],
	["look", "外观"],
	["dead", "未接线"],
]
const TIER_CN := ["", "立即", "重算", "重出击", "重启", "未接线"]
## 这些叶子名太通用（基础值/上限/启用…），光看它不知道是谁的属性，
## 显示时往前补一个非通用的段：meta_progression.survival.max_hp.base → "max_hp 基础值"
const GENERIC_LEAVES := ["base", "per_level", "max_level", "min", "max", "value", "cost",
	"chance", "enabled", "amount", "weight", "size", "color", "id", "name", "key",
	"exponent", "max_reduction", "min_damage", "strength", "seconds", "density"]

var _rows: Array = []
var _tier_names: Dictionary = {}
var _catalog_loaded := false
var _catalog_error := ""

var _root: Control = null
var _grid: GridContainer = null
var _live_box: VBoxContainer = null
var _live_labels: Array = []
var _tree_box: VBoxContainer = null
var _status: Label = null
var _search: LineEdit = null
var _only_dirty: CheckBox = null
var _tier_btns: Array = []
var _btn_resume: Button = null
var _built := false

var _cat := "char"
var _domain := ""
var _query := ""

## 筛选：档位勾选（默认全开）+ 只看已改
var _tier_on: Dictionary = {1: true, 2: true, 3: true, 4: true, 5: true}
var _show_dirty_only := false

## inplace 行的原值快照：path -> {"cont": 容器引用, "key": 键, "orig": 原值}
## 存**容器引用**不存路径：那些字典/数组被抽样池和每只怪的 _type_cfg 共用
## （引用语义），改它 == 改在场怪的来源，还原也省得再反解一次路径。
var _edits: Dictionary = {}
## 面板亲手改过的路径：path -> true。「写入文件」只写这些。
## 不能拿「哪行显示为已改」当依据 —— main.gd 进局时会 set_override 掉
## debug.auto_enter_run，探针也会，那些不是玩家调的数值，跟着落盘就是凭空改配置。
var _touched: Dictionary = {}
var _widgets: Array = []
var _shown := 0
var _tick := 0.0
var _last_vp := Vector2.ZERO
var _step_hold := false
var _resume := false
## 落盘那一步：按钮要随「待写入」计数改字，最近一次备份的目录名挂在状态栏上
var _btn_write: Button = null
var _last_backup := ""
var _flush_msg := ""


func _ready() -> void:
	# 10 不是随手写的：小地图是 Main.tscn 里 layer=3 的独立 CanvasLayer，
	# 早先 layer=2 时它整块糊在面板左下角（不继承父层可见性，盖得住全屏面板）。
	layer = 10
	add_to_group("debug_stat_panel")
	# 暂停/模态面板开着也要按得动 F9（调数值时经常顺手暂停画面看细节）
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_load_catalog()


# ------------------------------------------------------------
# 目录
# ------------------------------------------------------------

func _load_catalog() -> void:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
	if not (parsed is Dictionary):
		_catalog_error = "读不到 %s（先跑 python tools/gen_stat_catalog.py）" % CATALOG_PATH
		push_warning("[DebugPanel] " + _catalog_error)
		return
	var d: Dictionary = parsed
	_tier_names = d.get("tiers", {})
	var raw = d.get("rows", [])
	_rows = raw if raw is Array else []
	# 「未接线」单独成类：那些行留在原大类里只会让人以为改了有用
	for row in _rows:
		if int(row.get("tier", 1)) == 5:
			row["cat"] = "dead"
	_catalog_loaded = true
	print("[DebugPanel] 数值目录 %d 行（跑 tools/gen_stat_catalog.py 重新生成）" % _rows.size())


## 目录里有没有这一类的行（决定左树列不列它）
func _cat_count(cat: String) -> int:
	var n := 0
	for row in _rows:
		if str(row.get("cat", "")) == cat:
			n += 1
	return n


func _domains_of(cat: String) -> Array:
	var out: Array = []
	for row in _rows:
		if str(row.get("cat", "")) != cat:
			continue
		var dname := str(row.get("domain", ""))
		if not out.has(dname):
			out.append(dname)
	out.sort()
	return out


func _rows_of(cat: String, domain: String) -> Array:
	var out: Array = []
	for row in _rows:
		if str(row.get("cat", "")) != cat:
			continue
		if domain != "" and str(row.get("domain", "")) != domain:
			continue
		out.append(row)
	return out


# ------------------------------------------------------------
# 开关 / 暂停
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
		_set_resume(false)
		_rebuild_nav()
		_rebuild_rows()
		_refresh_live()
		print("[DebugPanel] 打开：改动写在 Config 覆盖层/内存目录（本进程内），退出即忘。F9 关闭。")
	else:
		get_tree().paused = false
		_resume = false


## 面板内继续：让画面跑起来但面板不动（覆盖层还留着，改的值照样吃进去）
func _set_resume(on: bool) -> void:
	_resume = on
	get_tree().paused = not on
	if _btn_resume != null:
		_btn_resume.text = "暂停" if on else "继续"


func _step_one() -> void:
	_resume = false
	get_tree().paused = false
	_step_hold = true
	await get_tree().physics_frame
	_step_hold = false
	if visible and not _resume:
		get_tree().paused = true


func _process(delta: float) -> void:
	if not visible:
		return
	if not _resume and not _step_hold and not get_tree().paused:
		get_tree().paused = true
	var vp := get_viewport().get_visible_rect().size
	if vp != _last_vp:
		_last_vp = vp
		_apply_columns()
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = REFRESH_SECONDS
	_refresh_live()
	_refresh_values()


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

	_root = UiKit.overlay()
	_root.add_to_group("debug_dock")
	host.add_child(_root)

	var shell := UiKit.wood_panel(6)
	UiKit.stretch(shell)
	_root.add_child(shell)
	shell.mouse_filter = Control.MOUSE_FILTER_STOP

	var inner := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiKit.COL_PANEL
	sb.set_content_margin_all(8)
	inner.add_theme_stylebox_override("panel", sb)
	shell.add_child(inner)

	var col := UiKit.vbox(6)
	inner.add_child(col)
	col.add_child(_build_topbar())

	var body := UiKit.hbox(COL_GAP)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(body)

	var tree_shell := UiKit.vbox(2)
	tree_shell.custom_minimum_size = Vector2(TREE_W, 0)
	body.add_child(tree_shell)
	var tree_head := _flat_label("分类", UiKit.FS_SMALL, UiKit.COL_AMBER)
	tree_shell.add_child(tree_head)
	_tree_box = UiKit.vbox(1)
	tree_shell.add_child(_tree_box)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(scroll)
	var list_wrap := UiKit.vbox(3)
	list_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_wrap)
	_live_box = UiKit.vbox(1)
	_live_box.visible = false
	list_wrap.add_child(_live_box)
	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", int(COL_GAP))
	_grid.add_theme_constant_override("v_separation", 2)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_wrap.add_child(_grid)
	_apply_columns()

	_status = UiKit.dim("", UiKit.FS_SMALL)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)
	get_viewport().size_changed.connect(_apply_columns)


func _build_topbar() -> Control:
	var bar := UiKit.hbox(4)
	bar.add_child(_flat_label("数值调试", UiKit.FS_HEADER, UiKit.COL_AMBER))

	_search = LineEdit.new()
	_search.placeholder_text = "搜索名称/路径/域"
	_search.custom_minimum_size = Vector2(180, 26)
	_search.add_theme_font_size_override("font_size", UiKit.FS_SMALL)
	_search.text_changed.connect(func(t: String):
		_query = t.strip_edges()
		_rebuild_rows())
	bar.add_child(_search)

	_only_dirty = CheckBox.new()
	_only_dirty.text = "只看已改"
	_only_dirty.add_theme_font_size_override("font_size", UiKit.FS_SMALL)
	_only_dirty.toggled.connect(func(on: bool):
		_show_dirty_only = on
		_rebuild_rows())
	bar.add_child(_only_dirty)

	bar.add_child(_flat_label("档位", UiKit.FS_SMALL, UiKit.COL_DIM))
	_tier_btns = []
	for t in range(1, 6):
		var b := _flat_button(TIER_CN[t], 0)
		b.add_theme_font_size_override("font_size", UiKit.FS_SMALL)
		b.tooltip_text = str(_tier_names.get(str(t), ""))
		var tier := t
		b.pressed.connect(func():
			_tier_on[tier] = not bool(_tier_on.get(tier, true))
			_refresh_tier_btns()
			_rebuild_rows())
		bar.add_child(b)
		_tier_btns.append(b)
	_refresh_tier_btns()

	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(gap)

	_btn_resume = _top_button("继续", func(): _set_resume(not _resume))
	bar.add_child(_btn_resume)
	bar.add_child(_top_button("单步", _step_one))
	_btn_write = _top_button("写入文件", _flush_to_files)
	_btn_write.disabled = true
	bar.add_child(_btn_write)
	bar.add_child(_top_button("还原备份", _restore_from_backup))
	bar.add_child(_top_button("全部还原", _reset_everything))
	bar.add_child(_top_button("打印改动", _print_changes))
	bar.add_child(_top_button("关闭 F9", func(): toggle()))
	return bar


func _top_button(text: String, on_press: Callable) -> Button:
	var b := _flat_button(text, 0)
	b.pressed.connect(on_press)
	return b


func _flat_label(text: String, size: int, color: Color) -> Label:
	var l := UiKit.label(text, size, color)
	l.custom_minimum_size = Vector2(0, 22)
	return l


## 扁平行内按钮：不要 UiKit.small_button 那套贴图（最小高 42），
## 调试台一行 26px，一屏才放得下三十几行。
func _flat_button(text: String, min_w: int) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", UiKit.FS_SMALL)
	b.custom_minimum_size = Vector2(min_w, 22)
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var s := StyleBoxFlat.new()
		s.bg_color = UiKit.COL_ROW if state == "normal" else UiKit.COL_ROW_HI
		if state == "disabled":
			s.bg_color = UiKit.COL_ROW
		s.border_color = Color(UiKit.COL_LINE.r, UiKit.COL_LINE.g, UiKit.COL_LINE.b, 0.6)
		s.set_border_width_all(1)
		s.set_corner_radius_all(3)
		s.content_margin_left = 6
		s.content_margin_right = 6
		b.add_theme_stylebox_override(state, s)
	b.add_theme_color_override("font_color", UiKit.COL_TEXT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", UiKit.COL_DIM)
	return b


func _refresh_tier_btns() -> void:
	for i in range(_tier_btns.size()):
		var t := i + 1
		var b: Button = _tier_btns[i]
		b.modulate = UiKit.COL_AMBER if bool(_tier_on.get(t, true)) else UiKit.COL_DIM


# ------------------------------------------------------------
# 左侧分类树
# ------------------------------------------------------------

## 先摘掉再 free：只 queue_free 的话旧行要到帧末才真消失，
## 同一帧里 GridContainer 会按「旧行 + 新行」排版，闪一下两倍长。
func _clear(box: Node) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()


func _rebuild_nav() -> void:
	_clear(_tree_box)
	var live_btn := _nav_button("在场单位", _cat == "live")
	live_btn.tooltip_text = "只读：场上每个人/每只怪**当前真正生效**的数值"
	live_btn.pressed.connect(func(): _select("live", ""))
	_tree_box.add_child(live_btn)
	_tree_box.add_child(UiKit.spacer(4))

	for pair in CATS:
		var cat := str(pair[0])
		var n := _cat_count(cat)
		var btn := _nav_button("%s（%d）" % [str(pair[1]), n], _cat == cat and _domain == "")
		if n == 0:
			btn.disabled = true
		btn.pressed.connect(func(): _select(cat, ""))
		_tree_box.add_child(btn)
		if _cat != cat:
			continue
		for dname in _domains_of(cat):
			var dn := str(dname)
			var sub := _nav_button("  %s（%d）" % [dn, _rows_of(cat, dn).size()], _domain == dn)
			sub.tooltip_text = "Data/config/%s.json" % dn
			sub.pressed.connect(func(): _select(cat, dn))
			_tree_box.add_child(sub)


func _nav_button(text: String, active: bool) -> Button:
	var b := _flat_button(text, int(TREE_W) - 6)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if active:
		b.modulate = UiKit.COL_AMBER
	return b


func _select(cat: String, domain: String) -> void:
	_cat = cat
	_domain = domain
	_rebuild_nav()
	_rebuild_rows()


# ------------------------------------------------------------
# 行
# ------------------------------------------------------------

func _apply_columns() -> void:
	if _grid == null:
		return
	var vp := get_viewport().get_visible_rect().size
	_last_vp = vp
	var chrome_w := (6.0 + 8.0) * 2.0   # 木框内容边距 + 内芯扁平边距，左右各一份
	var avail := vp.x - chrome_w - TREE_W - COL_GAP
	var cols := int((avail + COL_GAP) / (ROW_MIN_W + COL_GAP))
	_grid.columns = clampi(cols, 1, 6)


func _accept(row: Dictionary) -> bool:
	if not bool(_tier_on.get(int(row.get("tier", 1)), true)):
		return false
	if _show_dirty_only and not _is_dirty(row):
		return false
	if _query == "":
		return true
	var q := _query.to_lower()
	return str(row.get("label", "")).to_lower().find(q) >= 0 \
			or str(row.get("path", "")).to_lower().find(q) >= 0 \
			or str(row.get("domain", "")).to_lower().find(q) >= 0 \
			or str(row.get("group", "")).to_lower().find(q) >= 0


func _rebuild_rows() -> void:
	_widgets = []
	_clear(_grid)
	_grid.visible = _cat != "live"
	_live_box.visible = _cat == "live"
	if not _catalog_loaded:
		_grid.visible = true
		_shown = 0
		_add_note(_catalog_error)
		_refresh_status()
		return
	if _cat == "live":
		_shown = 0
		_refresh_live()
		_refresh_status()
		return
	var picked: Array = []
	for row in _rows_of(_cat, _domain):
		if _accept(row):
			picked.append(row)
	_shown = mini(picked.size(), BUILD_CAP)
	for i in range(_shown):
		_add_row(picked[i])
	if _shown < picked.size():
		_add_note("还有 %d 行没列出：换个域、用搜索，或提高 BUILD_CAP（一次铺满会卡住开面板那一帧）"
				% (picked.size() - _shown))
	elif picked.is_empty():
		_add_note("这一筛没有匹配项（试试把档位全勾上、取消「只看已改」）")
	_refresh_values()
	_refresh_status()


func _add_note(text: String) -> void:
	var l := UiKit.dim(text, UiKit.FS_SMALL)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size = Vector2(ROW_MIN_W * float(_grid.columns), 0)
	_grid.add_child(l)


func _add_row(row: Dictionary) -> void:
	var h := UiKit.hbox(int(ROW_GAP))
	# 不给 EXPAND_FILL 的话 GridContainer 只按内容最小宽排，实测 1920 下
	# 四列 362 只吃掉 1472，右边空 236px 全浪费
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lbl := UiKit.label(_base_name(row), UiKit.FS_SMALL)
	lbl.custom_minimum_size = Vector2(NAME_W, 22)
	lbl.clip_text = true
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(lbl)

	var input: Control = null
	if str(row.get("type", "")) == "bool":
		var cb := CheckBox.new()
		cb.text = "开"
		cb.add_theme_font_size_override("font_size", UiKit.FS_SMALL)
		cb.button_pressed = bool(_read_current(row, false))
		cb.toggled.connect(func(on: bool): _write(row, 1.0 if on else 0.0))
		input = cb
	else:
		var sp := SpinBox.new()
		var f := float(row.get("factory", 0.0))
		var lim := _limits(row, f)
		sp.min_value = float(lim[0])
		sp.max_value = float(lim[1])
		var st = row.get("step", null)
		sp.step = 1.0 if st == null else maxf(float(st), 0.0001)
		sp.custom_minimum_size = Vector2(SPIN_W, 22)
		sp.add_theme_font_size_override("font_size", UiKit.FS_SMALL)
		sp.get_line_edit().add_theme_font_size_override("font_size", UiKit.FS_SMALL)
		sp.value = float(_read_current(row, 0.0))
		sp.value_changed.connect(func(v: float): _write(row, v))
		input = sp
	h.add_child(input)

	var tier := int(row.get("tier", 1))
	var tl := UiKit.label(TIER_CN[tier], UiKit.FS_SMALL,
			UiKit.COL_OK if tier <= 2 else (UiKit.COL_WARN if tier <= 4 else UiKit.COL_DIM))
	tl.custom_minimum_size = Vector2(TIER_W, 22)
	h.add_child(tl)

	var reset := _flat_button("×", int(RESET_W))
	reset.tooltip_text = "恢复这一项"
	reset.pressed.connect(func(): _reset_one(row))
	h.add_child(reset)

	lbl.tooltip_text = _tooltip(row)
	_widgets.append({"row": row, "name": lbl, "input": input, "reset": reset})
	_grid.add_child(h)


func _tooltip(row: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append(str(row.get("path", "")))
	lines.append("出厂 %s ｜ %s" % [_fmt(row.get("factory", null)),
			str(_tier_names.get(str(int(row.get("tier", 1)))), "")])
	lines.append("改动落点：%s（%s）" % ["Data/config/%s.json" % str(row.get("domain", "")),
			"内存覆盖层" if str(row.get("via", "")) == "override" else "就地改内存容器，不落盘"])
	var rid := str(row.get("row_id", ""))
	if rid != "":
		lines.append("表行：%s" % rid)
	var sites = row.get("sites", [])
	if sites is Array and not (sites as Array).is_empty():
		var joined := PackedStringArray()
		for s in sites:
			joined.append(str(s))
		lines.append("读点：%s" % "、".join(joined))
	else:
		lines.append("读点：全工程找不到（这就是它进「未接线」的原因）")
	return "\n".join(lines)


## 行标题的不变部分：通用叶子名补一个所属段（max_hp.base → "max_hp 基础值"）、
## 数组表里的行补上那一行是谁（map.biomes.0.floor.0 → "草地 地面#0"）
func _base_name(row: Dictionary) -> String:
	var label := str(row.get("label", "?"))
	var segs: PackedStringArray = str(row.get("path", "")).split(".")
	var owner := ""
	var i := segs.size() - 2
	while i >= 0:
		var s := segs[i]
		if s.is_valid_int() or GENERIC_LEAVES.has(s):
			i -= 1
			continue
		owner = s
		break
	if owner != "" and not label.contains(owner):
		label = "%s %s" % [owner, label]
	var who := str(row.get("row_id", ""))
	if who == "":
		var grp := str(row.get("group", ""))
		who = _group_name(row, grp) if grp != "" else ""
	if who != "" and not label.contains(who):
		label = "%s %s" % [who, label]
	return label


func _group_name(row: Dictionary, fallback: String) -> String:
	var base = Config.get_value(str(row.get("base", "")), null)
	if not (base is Array):
		return fallback
	for el in (base as Array):
		if el is Dictionary and str(el.get("id", "")) == fallback:
			return str(el.get("name", fallback))
	return fallback


## 数组路径在点路径里到不了（_probe 只穿字典），所以从 base 拿到容器引用，
## 再按 path 里剩下的段一路下钻；返回 [容器, 键名]，取不到返回 []。
func _resolve(row: Dictionary) -> Array:
	var bpath := str(row.get("base", ""))
	if bpath == "":
		return []
	var node = Config.get_value(bpath, null)
	var segs: PackedStringArray = str(row.get("path", "")).split(".")
	var skip := bpath.split(".").size()
	if skip >= segs.size():
		return []
	var last := segs.size() - 1
	for i in range(skip, segs.size()):
		var seg := segs[i]
		if node is Array:
			var idx := seg.to_int()
			if idx < 0 or idx >= (node as Array).size():
				return []
			if i == last:
				return [node, idx]
			node = (node as Array)[idx]
		elif node is Dictionary:
			if i == last:
				return [node, seg]
			if not (node as Dictionary).has(seg):
				return []
			node = (node as Dictionary)[seg]
		else:
			return []
		if node == null:
			return []
	return []


## 容器可能是字典（键是字符串）也可能是数组（键是下标），所以只能动态取值。
func _read_slot(pair: Array, default):
	var cont = pair[0]
	if cont == null:
		return default
	return cont[pair[1]]


func _write_slot(pair: Array, v) -> void:
	var cont = pair[0]
	cont[pair[1]] = v


func _read_current(row: Dictionary, default):
	if str(row.get("via", "override")) == "override":
		return Config.get_value(str(row.get("path", "")), default)
	var pair := _resolve(row)
	if pair.is_empty():
		return default
	return _read_slot(pair, default)


## 概率/比例类夹在 0~1，其它给出厂值的 ±20 倍：
## 不给范围的话 SpinBox 上下箭头一步就顶到 999999，反而没法微调。
func _limits(row: Dictionary, f: float) -> Array:
	var p := str(row.get("path", "")).to_lower()
	if p.contains("chance") or p.contains("ratio") or p.contains("alpha") \
			or p.contains("prob") or p.contains("percent"):
		if f <= 1.0:
			return [0.0, 1.0]
	var span := maxf(absf(f) * 20.0, 10.0)
	return [0.0 if f >= 0.0 else -span, span]


func _fmt(v) -> String:
	if v == null:
		return "—"
	if v is bool:
		return "开" if bool(v) else "关"
	if v is float:
		var fv := float(v)
		return str(int(fv)) if is_equal_approx(fv, roundf(fv)) else str(fv)
	return str(v)


## 按**出厂值的类型**决定存 int 还是 float：0.35 秒存成 int 就变 0 了，
## 而 enemy.count 这类整数存成 100.5 会被读代码的人 int() 截断。
func _typed(v: float, origin) -> Variant:
	if origin is bool:
		return v >= 0.5
	if origin is int:
		return roundi(v)
	return v


func _write(row: Dictionary, v: float) -> void:
	if str(row.get("via", "override")) == "override":
		var path := str(row.get("path", ""))
		var base = Config.get_base_value(path, row.get("factory", null))
		Config.set_override(path, _typed(v, base))
	else:
		var pair := _resolve(row)
		if pair.is_empty():
			push_warning("[DebugPanel] 写不进去（配置结构变了，重跑生成器）：%s" % str(row.get("path", "")))
			return
		var path2 := str(row["path"])
		var origin = _read_slot(pair, null)
		if not _edits.has(path2):
			_edits[path2] = {"cont": pair[0], "key": pair[1], "orig": origin}
		_write_slot(pair, _typed(v, origin))
	_touched[str(row.get("path", ""))] = true
	refresh_live_units()
	_refresh_status()
	_mark_dirty(row)


## 脏了的行把出厂值挂在标题尾巴上：这一列本来就有「抄回 config」的用途，
## 再单开一列放出厂值的话，没改的行会看到两个一模一样的数字。
func _paint_dirty(w: Dictionary) -> bool:
	var row: Dictionary = w["row"]
	var dirty := _is_dirty(row)
	var lbl: Label = w["name"]
	lbl.text = _base_name(row) if not dirty else "%s ← 出厂 %s" % [
		_base_name(row), _fmt(row.get("factory", null))]
	lbl.modulate = UiKit.COL_AMBER if dirty else UiKit.COL_TEXT
	(w["reset"] as Button).disabled = not dirty
	return dirty


func _mark_dirty(row: Dictionary) -> void:
	for w in _widgets:
		if str((w["row"] as Dictionary).get("path", "")) == str(row.get("path", "")):
			_paint_dirty(w)


func _reset_one(row: Dictionary) -> void:
	var path := str(row.get("path", ""))
	if str(row.get("via", "override")) == "override":
		Config.clear_override(path)
	elif _edits.has(path):
		var rec: Dictionary = _edits[path]
		_write_slot([rec["cont"], rec["key"]], rec["orig"])
		_edits.erase(path)
	_touched.erase(path)
	refresh_live_units()
	_rebuild_rows()


func _reset_everything() -> void:
	Config.clear_overrides()
	for path in _edits.keys():
		var rec: Dictionary = _edits[path]
		_write_slot([rec["cont"], rec["key"]], rec["orig"])
	_edits = {}
	_touched = {}
	refresh_live_units()
	_rebuild_rows()


# ------------------------------------------------------------
# 落盘：把面板改过的那批值原地写回 Data/config/<域>.json
# ------------------------------------------------------------

## 待写入 = 面板亲手改过、现在确实还不等于出厂值的那些行。
## 整表扫 1320 行而不是维护增量名单：还原/写入/清空三处都会动状态，
## 多养一份名单只会漏。一次按钮点下去的开销，扫得动。
func _pending_rows() -> Array:
	var out: Array = []
	for row in _rows:
		var path := str(row.get("path", ""))
		if _touched.has(path) and _is_dirty(row):
			out.append(row)
	return out


## 写盘用的值要跟文件里那份同型：int 行写成 3 而不是 3.0，
## 否则域文件里会悄悄混进一堆假 float，git 上看不出是谁改坏的。
func _flush_value(row: Dictionary):
	var path := str(row.get("path", ""))
	var cur = _read_current(row, null)
	if cur is bool:
		return bool(cur)
	if not (cur is float) and not (cur is int):
		return cur
	return _typed(float(cur), Config.get_base_value(path, cur))


func _flush_to_files() -> void:
	var rows := _pending_rows()
	if rows.is_empty():
		_flush_msg = "没有待写入的改动"
		_refresh_status()
		return
	var by_domain: Dictionary = {}
	var row_by_path: Dictionary = {}
	for row in rows:
		var d := str(row.get("domain", ""))
		if d == "":
			continue
		if not by_domain.has(d):
			by_domain[d] = []
		var p := str(row.get("path", ""))
		row_by_path[p] = row
		(by_domain[d] as Array).append({"path": p, "value": _flush_value(row)})
	var done: Array = []
	var failed: Array = []
	var shadowed: Array = []
	for d in by_domain.keys():
		var edits: Array = by_domain[d]
		var res := Config.write_domain_values(str(d), edits)
		if not bool(res.get("ok", false)):
			failed.append("%s.json：%s" % [str(d), str(res.get("error", ""))])
			continue
		done.append({"domain": str(d), "edits": edits, "backup": str(res.get("backup", ""))})
		for e in edits:
			var p := str(e["path"])
			var row: Dictionary = row_by_path.get(p, {})
			# override 行：文件已经写了，内存也得跟上，再把覆盖层抹掉，
			# 否则「文件是新值、生效值也是新值但来自覆盖层」，还原备份时两层会打架。
			if str(row.get("via", "override")) == "override":
				Config.set_base_value(p, e["value"])
				Config.clear_override(p)
			# inplace 行改的就是 _data 里那份共享容器，内存本来就是新值，只需忘掉快照。
			_edits.erase(p)
			_touched.erase(p)
			if Config.has_user_value(p):
				shadowed.append(p)
	refresh_live_units()
	_rebuild_rows()
	_print_flush(done, failed, shadowed)
	_refresh_status()


func _print_flush(done: Array, failed: Array, shadowed: Array) -> void:
	var total := 0
	for g in done:
		total += (g["edits"] as Array).size()
	print("===== 数值调试台：写入 %d 项，涉及 %d 个域文件 =====" % [total, done.size()])
	for g in done:
		print("[Data/config/%s.json]  备份 -> %s" % [str(g["domain"]), str(g["backup"])])
		for e in (g["edits"] as Array):
			print("  %-56s = %s" % [str(e["path"]), str(e["value"])])
	for f in failed:
		print("!! 未写入 %s" % f)
	if not shadowed.is_empty():
		print("⚠ %d 项文件已写，但 user://settings.json 里还压着一份，局内看到的仍是那份：" % shadowed.size())
		for p in shadowed:
			print("     %s（去局外设置面板改回来，或删掉 settings.json 里这一项）" % p)
	if done.is_empty():
		_flush_msg = "写入失败，见控制台输出"
	else:
		_last_backup = str(done[done.size() - 1]["backup"]).get_file()
		_flush_msg = "已写入 %d 项（备份 %s）" % [total, _last_backup]
	if not failed.is_empty():
		_flush_msg += " ｜ %d 个文件没写成" % failed.size()


func _restore_from_backup() -> void:
	var res := Config.restore_backup()
	if not bool(res.get("ok", false)):
		_flush_msg = "还原失败：" + str(res.get("error", ""))
		_refresh_status()
		return
	var files: Array = res.get("files", [])
	var domains := PackedStringArray()
	for f in files:
		domains.append(str(f).trim_suffix(".json"))
	Config.load_config()
	# 只清被还原那几个域的覆盖层：别把 main.gd / 探针挂在别的域上的临时覆盖一起掀了
	for row in _rows:
		if domains.has(str(row.get("domain", ""))):
			Config.clear_override(str(row.get("path", "")))
	# _data 整棵换过了，快照里存的容器引用已经是孤儿
	_edits = {}
	_touched = {}
	_last_backup = str(res.get("stamp", ""))
	_flush_msg = "已从备份 %s 还原 %d 个域文件" % [_last_backup, files.size()]
	print("===== 数值调试台：%s =====" % _flush_msg)
	print("  ⚠ 在场单位身上缓存的数值不会跟着回滚（它们开局时抄了一份），要彻底回到备份那一版就重出击或重启")
	refresh_live_units()
	_rebuild_rows()
	_refresh_status()


func _is_dirty(row: Dictionary) -> bool:
	var path := str(row.get("path", ""))
	if str(row.get("via", "override")) == "override":
		return Config.has_override(path)
	return _edits.has(path)


## 只刷标签和还原按钮，不重建行：正在拖的 SpinBox 被重建会掉焦点。
## 唯一例外是「只看已改」开着时某项被还原干净了 —— 那时才整表重建一次，
## 而且要等循环结束再动手（循环里重建会把正在迭代的 _widgets 换掉）。
func _refresh_values() -> void:
	var need_rebuild := false
	for w in _widgets:
		if not _paint_dirty(w) and _show_dirty_only:
			need_rebuild = true
	if need_rebuild:
		_rebuild_rows()
		return
	_refresh_status()


func _refresh_status() -> void:
	if _status == null:
		return
	if not _catalog_loaded:
		_status.text = _catalog_error
		_status.modulate = UiKit.COL_WARN
		return
	var where := "在场单位" if _cat == "live" else "%s / %s" % [
		_str_of_cat(_cat), "全部域" if _domain == "" else _domain]
	var txt := "%s ｜ 列出 %d 行" % [where, _shown]
	if _cat != "live":
		var hidden := _picked_count() - _shown
		if hidden > 0:
			txt += "（另有 %d 行没列）" % hidden
	var pending := _pending_rows().size()
	if pending > 0:
		txt += " ｜ 待写入 %d 项（内存已生效，点「写入文件」落盘）" % pending
	else:
		txt += " ｜ 无改动"
	if _btn_write != null:
		_btn_write.text = "写入文件 (%d)" % pending if pending > 0 else "写入文件"
		_btn_write.disabled = pending == 0
	if _flush_msg != "":
		txt += " ｜ %s" % _flush_msg
	_status.text = txt
	_status.modulate = UiKit.COL_AMBER if pending > 0 else UiKit.COL_DIM


func _str_of_cat(cat: String) -> String:
	for pair in CATS:
		if str(pair[0]) == cat:
			return str(pair[1])
	return cat


func _picked_count() -> int:
	var n := 0
	for row in _rows_of(_cat, _domain):
		if _accept(row):
			n += 1
	return n


## 打印时按**域文件**归堆：抄回 config 的人是一个文件一个文件改的，
## 按字母排的路径清单会逼他把七域的值来回翻。
func _print_changes() -> void:
	var by_file: Dictionary = {}
	for p in Config.override_paths():
		var oline := "  %-52s %s （出厂 %s）" % [p, str(Config.get_value(p, null)),
				str(Config.get_base_value(p, null))]
		_add_change_line(by_file, _domain_of_path(str(p)), oline)
	for path in _edits.keys():
		var rec: Dictionary = _edits[path]
		var row := _row_by_path(path)
		var dname := "?" if row.is_empty() else str(row.get("domain", "?"))
		var iline := "  %-52s %s （原 %s）" % [path,
				str(_read_slot([rec["cont"], rec["key"]], null)), str(rec["orig"])]
		_add_change_line(by_file, dname, iline)
	var total := Config.override_paths().size() + _edits.size()
	print("===== 数值调试台：本次改动 %d 项 =====" % total)
	var files: Array = by_file.keys()
	files.sort()
	for f in files:
		print("[Data/config/%s.json]" % f)
		for line in (by_file[f] as Array):
			print(line)
	print("  —— 以上都只在内存里（退出即忘）。要留下点顶栏「写入文件」，")
	print("     它会先整份备份到 Backups/config/<时间戳>/ 再原地改对应域文件；「还原备份」拷回去。")
	print("========================================")


func _add_change_line(by_file: Dictionary, dname: String, line: String) -> void:
	if not by_file.has(dname):
		by_file[dname] = []
	(by_file[dname] as Array).append(line)


## 域文件名从目录里查（顶层段 → 域文件是多对多的，只有生成器知道答案）
func _domain_of_path(path: String) -> String:
	var row := _row_by_path(path)
	return "?" if row.is_empty() else str(row.get("domain", "?"))


func _row_by_path(path: String) -> Dictionary:
	for row in _rows:
		if str(row.get("path", "")) == path:
			return row
	return {}


# ------------------------------------------------------------
# 在场单位的生效值（只读，每 0.25s 刷一次）
# ------------------------------------------------------------

## 通知在场单位按新配置重算「开局缓存」的那几个属性。
## 现算类（伤害/视野/射程/时序）不需要这一步，但也无害 —— 就是空跑一遍。
func refresh_live_units() -> void:
	for g in ["player", "enemies", "animals"]:
		for n in get_tree().get_nodes_in_group(g):
			if is_instance_valid(n) and n.has_method("refresh_debug_stats"):
				n.refresh_debug_stats()


func _refresh_live() -> void:
	if _live_box == null:
		return
	var lines: Array = _player_lines() + _crowd_lines("enemies", "敌") \
			+ _crowd_lines("animals", "兽")
	# 复用标签池：每 0.25s 重建整棵子树会白烧节点，也让滚动位置抖一下
	while _live_labels.size() < lines.size():
		var l := UiKit.dim("", UiKit.FS_SMALL)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_live_box.add_child(l)
		_live_labels.append(l)
	for i in range(_live_labels.size()):
		var lbl: Label = _live_labels[i]
		if i < lines.size():
			lbl.text = str(lines[i])
			lbl.visible = true
		else:
			lbl.visible = false


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
	if out.is_empty():
		out.append("（场上没有活着的角色）")
	return out


## 敌人/动物按兵种汇总（21 个兵种 × 每只一行会刷屏）。
## ⚠ 羊身上没有 damage / _attack_range，也没有 patrol_speed()：两类单位共用这条路径
## 就得按成员/方法存在与否拼字。直接读会抛运行时错误，而错误在 _process 里
## —— 表现是整段读数空白，看起来像面板坏了，比数字写错难查得多。
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
		if "_attack_range" in e and not is_equal_approx(float(e.get("_attack_range")), global_range):
			line += " 程%d" % int(round(float(e.get("_attack_range"))))
		out.append(line)
	return out

extends CanvasLayer
## ============================================================
## BaseCustomPanel — 基地地面编辑器的左侧素材面板
##
## 配色 / 字号 / 按钮控件仍走 UiKit（跟仓库/设置面板同一套语言），但**不用 UiKit.dialog** ——
## dialog 是「全屏遮罩 + 居中弹窗」，会把玩家正在涂的那块地面整个盖住；
## 编辑器要的是「一边看基地一边改」，所以这里做成贴左侧的一条窄栏，右侧视野留白。
##
## 面板自己不管数据：选什么素材 / 换笔尖都调 editor 的接口，涂同一份稀疏表。
## 保存与取消也交给 editor —— 撤销 diff 记在那边，面板不知道「旧值」这回事。
##
## 皮肤为什么不用 UiKit.wood_panel()：
##   wood_panel.png 四边各有 **44px 全透明留白**（实测不透明范围 44,43 – 276,295），
##   而 UiKit 按 margin=44 切九宫格 → 四个角块与四条边带正好落在留白上，
##   面板四边等于没底。其它面板看不出毛病，是因为它们背后垫着 dialog 的深色遮罩；
##   本侧栏背后是明亮的基地地面，必须真的不透明，所以改成「不透明木色框 + 石板芯贴图」。
## ============================================================

const MARGIN := 12.0                                   # 距屏幕左/上边
const FRAME_PAD := 10.0                                # 木框厚度
const CORE_PAD_LR := 34.0                              # 石板芯左右内边距（> 角花，别压字）
const CORE_PAD_TOP := 46.0
const CORE_PAD_BOTTOM := 46.0
const PANEL_W := 374.0
## 可用内容宽度：总宽 − 两侧框厚 − 石板芯内边距。素材格 / 笔尖按钮都按它排。
const CONTENT_W := PANEL_W - FRAME_PAD * 2.0 - CORE_PAD_LR * 2.0

signal save_requested
signal cancel_requested
## 把被「全部清空」抹掉的出厂楼拉回来（只恢复传送门/仓库那 12 栋，不动玩家自定义的地表）。
signal restore_default_requested

var _editor: Node = null
var _shell: PanelContainer
var _core: PanelContainer
var _scroll: ScrollContainer
var _col: VBoxContainer
var _tab_row: HBoxContainer
var _grid: GridContainer
var _brush_row: HBoxContainer
var _status: Label
var _hint: Label
var _tab: int = BaseCustomEditor.Layer.GROUND
var _save_btn: Button


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


func _build_ui() -> void:
	_shell = _frame()
	# 贴左上角、高度随内容（锚点全 0 + offset_bottom == offset_top，实际高度由最小尺寸顶起来）
	_shell.anchor_left = 0.0
	_shell.anchor_top = 0.0
	_shell.anchor_right = 0.0
	_shell.anchor_bottom = 0.0
	_shell.offset_left = MARGIN
	_shell.offset_top = MARGIN
	_shell.offset_right = MARGIN + PANEL_W
	_shell.offset_bottom = MARGIN
	add_child(_shell)

	_core = _slate_core()
	_shell.add_child(_core)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	UiKit.skin_scroll(_scroll)
	_core.add_child(_scroll)

	var col := UiKit.vbox(8)
	_col = col
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(col)

	col.add_child(UiKit.title("地面编辑"))
	col.add_child(UiKit.dim("左键涂 · 右键擦 · Shift+左键拉矩形 · ESC 放弃", UiKit.FS_SMALL))

	_tab_row = UiKit.hbox(6)
	col.add_child(_tab_row)
	for pair in [["地面", BaseCustomEditor.Layer.GROUND],
			["水面", BaseCustomEditor.Layer.WATER],
			["摆件", BaseCustomEditor.Layer.PROPS],
			["建筑", BaseCustomEditor.Layer.BUILDINGS]]:
		var b := UiKit.small_button(str(pair[0]))
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): _pick_tab(int(pair[1])))
		_tab_row.add_child(b)

	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 6)
	col.add_child(_grid)

	col.add_child(UiKit.section("笔尖"))
	_brush_row = UiKit.hbox(6)
	col.add_child(_brush_row)

	_status = UiKit.dim("尚未改动", UiKit.FS_SMALL)
	col.add_child(_status)

	_hint = UiKit.dim("", UiKit.FS_SMALL)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(CONTENT_W, 0.0)
	col.add_child(_hint)

	var save_row := UiKit.hbox(8)
	col.add_child(save_row)
	_save_btn = UiKit.button("保存")
	_save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_btn.pressed.connect(func(): save_requested.emit())
	save_row.add_child(_save_btn)
	var cancel_btn := UiKit.button("取消")
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(func(): cancel_requested.emit())
	save_row.add_child(cancel_btn)

	var clear_btn := UiKit.small_button("全部清空")
	clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_btn.pressed.connect(func(): _on_clear())
	col.add_child(clear_btn)

	# 「恢复出厂楼」：专门救被上面「全部清空」一并抹掉的出厂楼（传送门/仓库等）。
	# 只把 factory_disabled 设回 false 并重建基地，玩家自己涂的地面/摆件/楼都留着 ——
	# 否则清了传送门就永远进不了局内，那是比崩溃更难发现的死局。
	var restore_btn := UiKit.small_button("恢复出厂楼（传送门等）")
	restore_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	restore_btn.pressed.connect(func(): restore_default_requested.emit())
	col.add_child(restore_btn)


# ------------------------------------------------------------
# 皮肤（两个零件都只在这里用，不走 UiKit 工厂 —— 理由见文件头注释）
# ------------------------------------------------------------

## 外框：不透明木色底 + 内边距堆出「框」的厚度。
## 关键就是**不透明**：侧栏压着基地，任何透光都等于字糊在草地上。
func _frame() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiKit.COL_BORDER                      # 木色，与按钮描边同色系
	sb.border_color = Color(0.16, 0.13, 0.09, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(FRAME_PAD)
	p.add_theme_stylebox_override("panel", sb)
	return p


## 石板芯：UiKit.panel() 的石板贴图（四角金花纹），只把内边距收窄。
## 它默认的 56 是给居中大窗留的，塞进 374 宽的侧栏会把素材格挤到放不下。
## 贴图自带 9/20/9/21 的透明留白 —— 这里透出来的是外框木色，正好当一圈衬边。
func _slate_core() -> PanelContainer:
	var p := UiKit.panel()
	var src := p.get_theme_stylebox("panel") as StyleBoxTexture
	if src != null:
		var sb := src.duplicate() as StyleBoxTexture
		sb.content_margin_left = CORE_PAD_LR
		sb.content_margin_right = CORE_PAD_LR
		sb.content_margin_top = CORE_PAD_TOP
		sb.content_margin_bottom = CORE_PAD_BOTTOM
		p.add_theme_stylebox_override("panel", sb)
	return p


## 高度贴着内容走：一块挂在左上角的牌子。
## 铺满整屏会在基地左侧压出一条深色竖条，把「一边看基地一边改」这件事毁掉。
## ⚠ ScrollContainer 的最小高度恒为 0，内容高度不会自己传上来，必须手动喂；
##   不喂的话外框只有 112px 高、素材格全被卷进滚动区里。
func _fit_height() -> void:
	if _scroll == null or _col == null:
		return
	var need: float = _col.get_combined_minimum_size().y
	var cap: float = get_viewport().get_visible_rect().size.y - (MARGIN + FRAME_PAD) * 2.0 \
			- CORE_PAD_TOP - CORE_PAD_BOTTOM
	_scroll.custom_minimum_size = Vector2(0.0, minf(need, cap))


## 换页签时清掉旧控件：必须先 remove_child 再 queue_free。
## queue_free 是延迟的，旧素材格会多留一帧参与最小尺寸计算，_fit_height() 就会量到偏高的值。
func _clear(host: Container) -> void:
	for c in host.get_children():
		host.remove_child(c)
		c.queue_free()


# ------------------------------------------------------------
# 打开 / 关闭
# ------------------------------------------------------------

func open_for(editor: Node) -> void:
	_editor = editor
	# 编辑器每次真改动都会发 changed —— 不接的话「已改动 N 格」永远停在 0，
	# 「保存」按钮也就一直禁用着（按钮的可用状态在 _refresh_status 里算）。
	if _editor != null and not _editor.is_connected("changed", _on_editor_changed):
		_editor.connect("changed", _on_editor_changed)
	visible = true
	_pick_tab(BaseCustomEditor.Layer.GROUND)
	_build_brush_row()
	_refresh_status()
	_fit_height()


func _on_editor_changed(_count: int) -> void:
	if visible:
		_refresh_status()


func close_ui() -> void:
	visible = false
	_editor = null


func refresh_status() -> void:
	if visible:
		_refresh_status()


## 给调用方 / 自动化脚本切页签（0=地面 1=水面 2=摆件）。
## 公开一层薄壳的理由同 base_custom_editor：Object.call() 调不到下划线开头的方法，
## 而"换一层素材"本来就该是面板的正式能力。
func select_tab(layer: int) -> void:
	_pick_tab(layer)


## 面板当前状态（验证用）：改动计数只在 changed 信号里刷新，
## 光看截图分不出「保存」到底是灰的还是亮的，所以把状态摊开给脚本读。
func state() -> Dictionary:
	return {
		"status": _status.text if _status != null else "",
		"save_enabled": _save_btn != null and not _save_btn.disabled,
		"size": _shell.size if _shell != null else Vector2.ZERO,
	}


func _refresh_status() -> void:
	if _editor == null:
		return
	var n: int = _editor.call("change_count")
	_status.text = "已改动 %d 处" % n
	_save_btn.disabled = n == 0


# ------------------------------------------------------------
# 内容
# ------------------------------------------------------------

func _pick_tab(layer: int) -> void:
	_tab = layer
	var i := 0
	for child in _tab_row.get_children():
		var b := child as Button
		if b != null:
			b.set_pressed_no_signal(i == layer)
		i += 1
	if _editor != null:
		_editor.call("set_tool", layer, _default_value_for(layer))
	_build_grid()
	_brush_row.visible = (_tab != BaseCustomEditor.Layer.BUILDINGS)
	_fit_height()


func _default_value_for(layer: int) -> int:
	match layer:
		BaseCustomEditor.Layer.WATER:
			return 1
		BaseCustomEditor.Layer.PROPS:
			return 1
		BaseCustomEditor.Layer.BUILDINGS:
			return 0
		_:
			return int(Config.get_value("base.custom_editor.default_material", 0))


## 素材格：地面按素材表、摆件按摆件表，水面只有一款（铺水 / 擦水由鼠标左右键决定）
func _build_grid() -> void:
	_clear(_grid)
	match _tab:
		BaseCustomEditor.Layer.GROUND:
			for m in BaseMaterials.ground_materials():
				var e: Dictionary = m
				_grid.add_child(_material_button(int(e["id"]), str(e["name"]),
						e.get("swatch", Color(0.3, 0.36, 0.18))))
		BaseCustomEditor.Layer.PROPS:
			for p in BaseMaterials.prop_materials():
				var pe: Dictionary = p
				var v := int(pe["id"])
				_grid.add_child(_material_button(v, str(pe["name"]),
						Color(0.42, 0.62, 0.40)))
		BaseCustomEditor.Layer.BUILDINGS:
			var idx := 0
			for spec in BaseMaterials.building_specs():
				var s: Dictionary = spec
				var id_str := str(s.get("id", ""))
				var name := str(s.get("name", id_str))
				_grid.add_child(_building_button(idx, name, _building_thumbnail(s), id_str))
				idx += 1
			var fc := int(Config.get_value("base.building_cells", 4))
			_hint.text = "建筑：左键在锚点盖一栋、右键点楼体擦掉整栋（占地 %dx%d 格，无笔尖 / 无矩形填充）。" % [fc, fc]
			return
		_:
			_grid.add_child(_material_button(1, "水面", Color(0.35, 0.62, 0.95)))
			_hint.text = "水面：左键铺水、右键把水擦掉（露出下面的地面）。"
			return
	_hint.text = ""


func _material_button(value: int, text: String, swatch: Color) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 34)
	var hb := UiKit.hbox(6)
	b.add_child(hb)
	var chip := ColorRect.new()
	chip.custom_minimum_size = Vector2(18, 18)
	chip.color = swatch
	chip.color.a = 1.0
	hb.add_child(chip)
	var lbl := UiKit.label(text, UiKit.FS_SMALL)
	hb.add_child(lbl)
	var want: int = _current_value()
	b.set_pressed_no_signal(value == want)
	b.pressed.connect(func():
			if _editor != null:
				_editor.call("set_tool", _tab, value)
			_sync_grid_pressed(value)
			if visible:
				_refresh_status()
	)
	return b


func _current_value() -> int:
	return int(_editor.call("tool_value")) if _editor != null else _default_value_for(_tab)


func _sync_grid_pressed(picked: int) -> void:
	for c in _grid.get_children():
		var b := c as Button
		if b == null:
			continue
		var idx: int = b.get_index()
		var v: int = _value_of_index(idx)
		b.set_pressed_no_signal(v == picked)


## 笔尖按钮：档位来自 config，所以改一次 snapping 粒度不用动代码。
func _build_brush_row() -> void:
	_clear(_brush_row)
	var sizes: Array = Config.get_value("base.custom_editor.brush_sizes", [1, 2, 3, 5])
	for s in sizes:
		var n := int(s)
		var b := UiKit.small_button("%d×%d" % [n, n])
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): _pick_brush(n))
		_brush_row.add_child(b)
	if _editor != null:
		_sync_brush(int(_editor.call("brush_size")))


func _pick_brush(n: int) -> void:
	if _editor != null:
		_editor.call("set_brush", n)
	_sync_brush(n)


func _sync_brush(n: int) -> void:
	for c in _brush_row.get_children():
		var b := c as Button
		if b != null:
			b.set_pressed_no_signal(int(b.text.split("×")[0]) == n)


func _value_of_index(idx: int) -> int:
	match _tab:
		BaseCustomEditor.Layer.GROUND:
			var list := BaseMaterials.ground_materials()
			var e: Dictionary = list[clampi(idx, 0, list.size() - 1)]
			return int(e["id"])
		BaseCustomEditor.Layer.PROPS:
			var lp := BaseMaterials.prop_materials()
			var pe: Dictionary = lp[clampi(idx, 0, lp.size() - 1)]
			return int(pe["id"])
		BaseCustomEditor.Layer.BUILDINGS:
			return idx          # 建筑层 value == 调色板下标
		_:
			return 1


## 建筑按钮：缩略图取序列帧第 0 格（与 building.gd 同套「横排 sheet 切帧」规则），
## 缺图 / 没配 sprite 时回落到一格暖色芯片。value = 调色板下标（与 editor._value 对齐）。
func _building_button(index: int, text: String, thumb: Texture2D, _id_str: String) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 40)
	var hb := UiKit.hbox(6)
	b.add_child(hb)
	if thumb != null:
		var tex := TextureRect.new()
		tex.texture = thumb
		tex.custom_minimum_size = Vector2(32, 32)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hb.add_child(tex)
	else:
		var chip := ColorRect.new()
		chip.custom_minimum_size = Vector2(18, 18)
		chip.color = Color(0.95, 0.70, 0.30)
		hb.add_child(chip)
	var lbl := UiKit.label(text, UiKit.FS_SMALL)
	hb.add_child(lbl)
	var want: int = _current_value()
	b.set_pressed_no_signal(index == want)
	b.pressed.connect(func():
		if _editor != null:
			_editor.call("set_tool", _tab, index)
		_sync_building_pressed(index)
		if visible:
			_refresh_status()
	)
	return b


func _sync_building_pressed(picked: int) -> void:
	for c in _grid.get_children():
		var b := c as Button
		if b == null:
			continue
		b.set_pressed_no_signal(b.get_index() == picked)


## 序列帧第 0 格的缩略图（AtlasTexture 引用原图，不落盘、换素材免重导）。
func _building_thumbnail(spec: Dictionary) -> Texture2D:
	var path := str(spec.get("sprite", ""))
	if path == "" or not ResourceLoader.exists(path):
		return null
	var tex := load(path) as Texture2D
	if tex == null:
		return null
	var ts := tex.get_size()
	if ts.x <= 0 or ts.y <= 0:
		return null
	var frames := int(spec.get("anim_frames", 0))
	var fw := ts.x / float(maxi(1, frames)) if frames > 1 else ts.x
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = Rect2(0.0, 0.0, fw, ts.y)
	return atlas


func _on_clear() -> void:
	if _editor != null:
		_editor.call("clear_all")
		_refresh_status()
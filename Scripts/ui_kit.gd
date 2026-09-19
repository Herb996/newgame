class_name UiKit
extends RefCounted
## ============================================================
## UiKit — 菜单类界面的共用样式与控件工厂（纯静态方法，无需实例化）
##
## 项目里的 UI 全部是「代码搭界面」（见 warehouse_panel.gd / statue_panel.gd），
## 没有 .theme 资源。菜单这一批界面较多，若各自抄一份配色和字号，
## 迟早会出现「这个面板按钮高 32、那个 28」这种漂移，所以统一收在这里。
##
## 配色沿用已有面板：琥珀色标题 + 米白正文 + 灰色提示 + 深棕底。
## 用法：UiKit.title("设置")、UiKit.button("返回")…
## ============================================================

# --- 配色 ---
const COL_BG := Color(0.07, 0.065, 0.06, 1.0)        # 全屏底色
const COL_OVERLAY := Color(0.0, 0.0, 0.0, 0.72)       # 弹层遮罩
const COL_PANEL := Color(0.12, 0.105, 0.085, 0.98)    # 面板底
const COL_ROW := Color(0.15, 0.185, 0.24, 0.85)       # 列表行（石板蓝，跟面板同色系）
const COL_ROW_HI := Color(0.21, 0.27, 0.35, 0.95)     # 高亮行（上次游玩）
const COL_BORDER := Color(0.30, 0.25, 0.18, 1.0)
const COL_LINE := Color(0.34, 0.42, 0.55, 1.0)        # 石板上的分隔线/输入框描边
const COL_AMBER := Color(0.85, 0.62, 0.30)            # 主强调色（沿用雕像面板）
const COL_TEXT := Color(0.91, 0.89, 0.85)
const COL_DIM := Color(0.70, 0.68, 0.63)
const COL_WARN := Color(0.90, 0.55, 0.35)
const COL_OK := Color(0.55, 0.78, 0.50)

# --- 字号 ---
const FS_HERO := 46
const FS_TITLE := 26
const FS_HEADER := 18
const FS_BODY := 16
const FS_SMALL := 13

# --- Tiny Swords UI 皮肤（蓝色系九宫格贴图，tools 生成于 Assets/Art/UI/tsui） ---
const TS_TEX_DIR := "res://Assets/Art/UI/tsui/"
## 贴图是像素画：挂皮肤的界面根节点请设 TEXTURE_FILTER_NEAREST（见 settings_panel._ready）
const TS_NEAREST := CanvasItem.TEXTURE_FILTER_NEAREST

static var _ts_cache: Dictionary = {}


static func ts_tex(name: String) -> Texture2D:
	if not _ts_cache.has(name):
		_ts_cache[name] = load(TS_TEX_DIR + name + ".png")
	return _ts_cache[name]


## 通用九宫格样式：margin 是贴图角部在屏幕上的像素数（贴图按 1:1 画角部、拉伸中间）
static func ts_nine(name: String, margin: float, pad_h: float = 0.0, pad_v: float = 0.0,
		tint: Color = Color.WHITE) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = ts_tex(name)
	sb.set_texture_margin_all(margin)
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	sb.modulate_color = tint
	return sb


## 按钮三态（normal/hover 用亮蓝，pressed 用压暗贴图）+ 文字颜色，控件工厂共用
static func _apply_button_skin(b: Button, small: bool = false) -> void:
	var base := "btn_small" if small else "btn_blue"
	var margin := 11.0 if small else 16.0
	# 左右 content margin 要盖过贴图自带的白边框（约 12px），否则文字压在框上
	var pad_h := 18.0 if small else 20.0
	var states := {
		"normal": ts_nine(base, margin, pad_h, 6),
		"hover": ts_nine(base, margin, pad_h, 6, Color(1.12, 1.12, 1.12)),
		"pressed": ts_nine(base + "_pressed", margin, pad_h, 6),
		"disabled": ts_nine(base, margin, pad_h, 6, Color(1, 1, 1, 0.45)),
	}
	states["focus"] = StyleBoxEmpty.new()
	for state in states:
		b.add_theme_stylebox_override(state, states[state])
	b.add_theme_color_override("font_color", COL_TEXT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_focus_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", COL_TEXT)
	b.add_theme_color_override("font_disabled_color", Color(0.75, 0.75, 0.75, 0.55))


# ------------------------------------------------------------
# 文本
# ------------------------------------------------------------

## 静态上下文的翻译入口：tr() 只在 Node 上可用，UiKit 全是静态工厂，
## 走 TranslationServer（查不到 key 时原样返回，中文是源语言天然兜底）
static func tr_dl(text: String) -> String:
	return TranslationServer.translate(text)


static func label(text: String, size: int = FS_BODY, color: Color = COL_TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func hero(text: String) -> Label:
	var l := label(text, FS_HERO, COL_AMBER)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


static func title(text: String) -> Label:
	var l := label(text, FS_TITLE, COL_TEXT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


static func section(text: String) -> Label:
	# 装饰线在运行时拼接，自动翻译只查最终文本查不到 —— 先译内容再拼线
	var l := label("— %s —" % tr_dl(text), FS_HEADER, COL_AMBER)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


## 缎带横幅标题：蓝青缎带打底 + 描边文字。scale 控制宽度（贴图 192×60 等比）。
static func ribbon_title(text: String, width: float = 420, font_size: int = FS_TITLE) -> Control:
	var wrap := CenterContainer.new()
	var rib := TextureRect.new()
	rib.texture = ts_tex("ribbon_blue")
	rib.stretch_mode = TextureRect.STRETCH_SCALE
	rib.custom_minimum_size = Vector2(width, width * 60.0 / 192.0)
	wrap.add_child(rib)
	var l := label(text, font_size, Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color(0.08, 0.12, 0.18))
	l.add_theme_constant_override("outline_size", int(font_size * 0.3))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rib.add_child(l)
	return wrap


static func dim(text: String, size: int = FS_SMALL) -> Label:
	return label(text, size, COL_DIM)


static func warn(text: String, size: int = FS_SMALL) -> Label:
	return label(text, size, COL_WARN)


# ------------------------------------------------------------
# 容器
# ------------------------------------------------------------

static func vbox(separation: int = 8) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", separation)
	return v


static func hbox(separation: int = 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", separation)
	return h


static func spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c


## 把控件铺满父级（anchors 15 = PRESET_FULL_RECT）
static func stretch(c: Control) -> Control:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return c


## 半透明遮罩（弹层用）。设了 mouse_filter=STOP 挡住底下的点击。
static func overlay() -> ColorRect:
	var r := ColorRect.new()
	r.color = COL_OVERLAY
	r.mouse_filter = Control.MOUSE_FILTER_STOP
	stretch(r)
	return r


static func solid(color: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	stretch(r)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## 深色罗盘面板：木框 + 深蓝石板芯，文字区落在石板上（浅色字可读）。
## texture margin 48 = 角上描金花纹的实际大小：花纹只画在四角 1:1 不被拉伸涂抹，
## 内容边距必须 ≥ 48，否则文字会压在角花上。
static func panel(bg: Color = COL_PANEL, pad: int = 18) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxTexture.new()
	sb.texture = ts_tex("paper_dark")
	sb.set_texture_margin_all(48)
	sb.content_margin_left = 56
	sb.content_margin_right = 56
	sb.content_margin_top = 30
	sb.content_margin_bottom = 56
	sb.modulate_color = Color(0.94, 0.94, 1.0)
	p.add_theme_stylebox_override("panel", sb)
	return p


## 外层木框（大面板的壳）：调用方往里再放 panel() 石板芯或直接放内容
static func wood_panel(pad: int = 14) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxTexture.new()
	sb.texture = ts_tex("wood_panel")
	sb.set_texture_margin_all(44)
	sb.set_content_margin_all(pad)
	p.add_theme_stylebox_override("panel", sb)
	return p


## 给列表行套一层带底色的容器（半透明石板蓝，跟 paper_dark 面板同色系）
static func row_box(bg: Color, pad: int = 10) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = Color(COL_LINE.r, COL_LINE.g, COL_LINE.b, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(pad)
	p.add_theme_stylebox_override("panel", sb)
	return p


## 全屏面板骨架：10px 黑边 + 木框 + 石板芯，返回石板 PanelContainer。
## 设置 / 存档 / 其他 等菜单面板都走这里，铺满风格只写一份。
static func fullscreen_panel(host: Control) -> PanelContainer:
	var margin := MarginContainer.new()
	stretch(margin)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	host.add_child(margin)
	var shell := wood_panel(6)
	margin.add_child(shell)
	var p := panel(COL_PANEL, 18)
	shell.add_child(p)
	return p


## 行内单行文本框（存档命名等）：石板底 + 蓝灰描边，与面板同色系
static func line_edit(text: String, min_w: float = 300) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.custom_minimum_size = Vector2(min_w, 40)
	e.add_theme_color_override("font_color", COL_TEXT)
	e.add_theme_color_override("cursor_color", COL_AMBER)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.14, 0.2)
	sb.border_color = COL_LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8)
	e.add_theme_stylebox_override("normal", sb)
	var sbf := sb.duplicate()
	sbf.border_color = Color(COL_LINE.r, COL_LINE.g, COL_LINE.b, 1.0)
	sbf.set_border_width_all(2)
	e.add_theme_stylebox_override("focus", sbf)
	return e


## 弹层面板挂到 CanvasLayer 上并真正屏幕居中，返回该面板（调用方往里塞内容）。
## 坑：Control 直接挂在 CanvasLayer 下时 PRESET_CENTER 不生效 —— 锚点参照不到屏幕矩形，
## 1920×1080 下面板左上角落在 (960, 540)，整块往右下偏半个屏幕。
## 所以垫一层铺满屏幕的半透明遮罩当锚点父级，面板在遮罩里四向 grow 居中。
static func centered_dialog(layer: CanvasLayer, min_w: float) -> PanelContainer:
	var scrim := ColorRect.new()
	scrim.color = Color(0.0, 0.0, 0.0, 0.45)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(scrim)
	var p := PanelContainer.new()
	p.set_anchors_preset(Control.PRESET_CENTER)
	p.grow_horizontal = Control.GROW_DIRECTION_BOTH
	p.grow_vertical = Control.GROW_DIRECTION_BOTH
	p.custom_minimum_size = Vector2(min_w, 0)
	scrim.add_child(p)
	return p


## 菜单背景：贴图平铺或整图（covered = 等比放大铺满裁边，用于地图/插画）+
## 压暗层。tex 换材质（wood_tile 实木 / slate_tile 软石板 / menu_map 地图）。
static func tiled_backdrop(tex: String, dim: float, shade: Color, covered: bool = false) -> Control:
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stretch(root)
	var pic := TextureRect.new()
	pic.texture = ts_tex(tex)
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED if covered \
			else TextureRect.STRETCH_TILE
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stretch(pic)
	root.add_child(pic)
	var shade_rect := ColorRect.new()
	shade_rect.color = shade
	shade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stretch(shade_rect)
	root.add_child(shade_rect)
	return root


static func wood_backdrop(dim: float = 0.62) -> Control:
	return tiled_backdrop("wood_tile", dim, Color(0.07, 0.065, 0.06, dim))


# ------------------------------------------------------------
# 交互控件
# ------------------------------------------------------------

static func button(text: String, width: int = 0, size: int = FS_BODY) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	if width > 0:
		b.custom_minimum_size = Vector2(width, 52)
	else:
		b.custom_minimum_size = Vector2(0, 52)
	_apply_button_skin(b)
	return b


## 小号蓝方块按钮（页签 / 行内小按钮）：高度矮一档，配 SmallBlueSquare 贴图
static func small_button(text: String, width: int = 0, size: int = FS_BODY) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	b.custom_minimum_size = Vector2(width, 42)
	_apply_button_skin(b, true)
	return b


## 主菜单用的大按钮：左对齐、固定高度，视觉上更整齐
static func menu_button(text: String, hint: String = "") -> Button:
	var b := button(text, 0, 20)
	b.custom_minimum_size = Vector2(360, 60)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.tooltip_text = hint
	return b


static func checkbox(text: String, pressed: bool) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = pressed
	c.add_theme_font_size_override("font_size", FS_BODY)
	c.add_theme_icon_override("checked", ts_tex("check_on"))
	c.add_theme_icon_override("unchecked", ts_tex("check_off"))
	return c


static func slider(min_v: float, max_v: float, step: float, value: float,
		width: int = 240) -> HSlider:
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(width, 0)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# 凹槽 = 木条底槽（提亮免得埋进深底里），填充 = 蓝条，拖拽点 = 圆蓝钮。
	# 注意 StyleBoxTexture 的最小尺寸只算 content margin —— 不给 pad_v 的话
	# 凹槽高度是 0，什么都画不出来。
	s.add_theme_stylebox_override("slider", ts_nine("bar_base", 8, 0, 6,
			Color(2.6, 2.6, 2.8)))
	s.add_theme_stylebox_override("grabber_area", ts_nine("bar_fill", 6, 0, 5))
	s.add_theme_stylebox_override("grabber_area_highlight", ts_nine("bar_fill", 6,
			0, 0, Color(1.15, 1.15, 1.15)))
	s.add_theme_icon_override("grabber", ts_tex("grabber"))
	s.add_theme_icon_override("grabber_highlight", ts_tex("grabber"))
	s.add_theme_icon_override("grabber_disabled", ts_tex("grabber"))
	return s


static func option(items: Array, selected: int, width: int = 200) -> OptionButton:
	var o := OptionButton.new()
	for i in range(items.size()):
		o.add_item(str(items[i]), i)
	o.selected = clampi(selected, 0, maxi(0, items.size() - 1))
	o.custom_minimum_size = Vector2(width, 42)
	o.add_theme_font_size_override("font_size", FS_BODY)
	_apply_button_skin(o, true)
	# 右侧多留一截：下拉箭头画在文字后面，边距不够时箭头会压到文字和白框
	for st in ["normal", "hover", "pressed", "disabled"]:
		var osb := o.get_theme_stylebox(st) as StyleBoxTexture
		if osb != null:
			osb.content_margin_right = 34.0
	# 下拉弹层：深色石板 + 蓝青高亮行，与面板同语言
	var pop := o.get_popup()
	var panel_sb := ts_nine("paper_dark", 16, 8, 8)
	pop.add_theme_stylebox_override("panel", panel_sb)
	var hover_sb := StyleBoxFlat.new()
	hover_sb.bg_color = Color(0.23, 0.42, 0.52, 0.9)
	pop.add_theme_stylebox_override("hover", hover_sb)
	pop.add_theme_color_override("font_color", COL_TEXT)
	pop.add_theme_color_override("font_hover_color", Color.WHITE)
	return o


## 数值显示标签：右对齐、固定宽度，避免跟着数字长短抖动
static func value_label(width: int = 96) -> Label:
	var l := label("", FS_BODY, COL_AMBER)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.custom_minimum_size = Vector2(width, 0)
	return l


## 设置项右侧的说明（灰色小字）
static func note(text: String) -> Label:
	var l := dim(text, FS_SMALL)
	l.custom_minimum_size = Vector2(0, 0)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


# ------------------------------------------------------------
# 格式化
# ------------------------------------------------------------

## 把秒数写成 30 分 / 1.5 小时这种可读形式
static func duration(seconds: float) -> String:
	if seconds <= 0.0:
		return tr_dl("不限")
	if seconds < 60.0:
		return tr_dl("%d 秒") % roundi(seconds)
	if seconds < 3600.0:
		return tr_dl("%.1f 分") % (seconds / 60.0)
	return tr_dl("%.2f 小时") % (seconds / 3600.0)


## 把浮点按「保留几位」显示；整数就不带小数点
static func number(v: float, step: float) -> String:
	if step >= 1.0:
		return str(roundi(v))
	return ("%.2f" % v) if step < 0.1 else ("%.1f" % v)


## Godot 键码 -> 玩家看得懂的键名
static func key_name(code: int) -> String:
	if code <= 0:
		return tr_dl("未绑定")
	var s := OS.get_keycode_string(code)
	return s if s != "" else tr_dl("键码 %d") % code


# ------------------------------------------------------------
# 局内菜单栏
# ------------------------------------------------------------

## 局内底部菜单栏的高度（像素）= 视口高 × menu_bar.height_ratio，再按 min/max 夹住。
## 为什么放这里：菜单栏自己要用它铺底，HUD 与视野提示要用它让位 ——
## 公式只写一份，避免两处 clamp 各写一遍后漂移（一边 20%、另一边 18% 这种）。
## 兜底默认值与 config 里保持一致，否则配置键被删掉时两处会算出不同的高度。
static func menu_bar_height(viewport_h: float) -> float:
	var h := viewport_h * float(Config.get_value("menu_bar.height_ratio", 0.2))
	return clampf(h, float(Config.get_value("menu_bar.min_height_px", 160)),
			float(Config.get_value("menu_bar.max_height_px", 320)))


## 菜单栏是否启用（关掉后不铺底，HUD 也不需要让位）
static func menu_bar_enabled() -> bool:
	return bool(Config.get_value("menu_bar.enabled", true))

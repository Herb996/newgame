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
const COL_ROW := Color(0.17, 0.15, 0.125, 0.85)       # 列表行
const COL_ROW_HI := Color(0.24, 0.20, 0.13, 0.95)     # 高亮行（上次游玩）
const COL_BORDER := Color(0.30, 0.25, 0.18, 1.0)
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


# ------------------------------------------------------------
# 文本
# ------------------------------------------------------------

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
	var l := label("— %s —" % text, FS_HEADER, COL_AMBER)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


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


## 带底色/内边距的面板
static func panel(bg: Color = COL_PANEL, pad: int = 18) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = COL_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(pad)
	p.add_theme_stylebox_override("panel", sb)
	return p


## 给列表行套一层带底色的容器
static func row_box(bg: Color, pad: int = 10) -> PanelContainer:
	var p := panel(bg, pad)
	return p


# ------------------------------------------------------------
# 交互控件
# ------------------------------------------------------------

static func button(text: String, width: int = 0, size: int = FS_BODY) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	if width > 0:
		b.custom_minimum_size = Vector2(width, 0)
	return b


## 主菜单用的大按钮：左对齐、固定高度，视觉上更整齐
static func menu_button(text: String, hint: String = "") -> Button:
	var b := button(text, 0, 20)
	b.custom_minimum_size = Vector2(340, 52)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.tooltip_text = hint
	return b


static func checkbox(text: String, pressed: bool) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = pressed
	c.add_theme_font_size_override("font_size", FS_BODY)
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
	return s


static func option(items: Array, selected: int, width: int = 200) -> OptionButton:
	var o := OptionButton.new()
	for i in range(items.size()):
		o.add_item(str(items[i]), i)
	o.selected = clampi(selected, 0, maxi(0, items.size() - 1))
	o.custom_minimum_size = Vector2(width, 0)
	o.add_theme_font_size_override("font_size", FS_BODY)
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
		return "不限"
	if seconds < 60.0:
		return "%d 秒" % roundi(seconds)
	if seconds < 3600.0:
		return "%.1f 分" % (seconds / 60.0)
	return "%.2f 小时" % (seconds / 3600.0)


## 把浮点按「保留几位」显示；整数就不带小数点
static func number(v: float, step: float) -> String:
	if step >= 1.0:
		return str(roundi(v))
	return ("%.2f" % v) if step < 0.1 else ("%.1f" % v)


## Godot 键码 -> 玩家看得懂的键名
static func key_name(code: int) -> String:
	if code <= 0:
		return "未绑定"
	var s := OS.get_keycode_string(code)
	return s if s != "" else "键码 %d" % code


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

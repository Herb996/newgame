extends Node2D
## ============================================================
## UnitLevelBadge — 单位头顶的等级徽章（0~9）
##
## 为什么是 UI 层 `_draw` 自绘、而不是烘进贴图：
##   等级 10 档 × 3 个角色 = 30 套帧，出图成本高，改一次数值就要重出一轮。
##   徽章只是一颗圈 + 一位数字，画在角色头顶最省事，也最容易调。
## 先例：`enemy_hp_bar.gd` 也是 `_draw` 自绘挂在单位上的。
##
## 配色随档位走（progression.badge.colors.<tier>）—— 与角色体色的档位一致，
## 这样「圈色」本身就是第二重档位提示：乱战里看不清体色时还能看圈。
##
## ⚠ 数字只画 0~9：等级上限是 9（progression.max_level），一位数刚好装得下。
## ============================================================

var level: int = 0
var tier_id: String = "blue"

var _enabled: bool = true
var _radius: float = 9.0
var _font_size: int = 11


func _ready() -> void:
	z_index = 6          # 盖住角色（z=1）和雾（z=5），别被雾吃掉了
	_apply_cfg()


func _apply_cfg() -> void:
	_enabled = bool(Config.get_value("progression.badge.enabled", true))
	_radius = float(Config.get_value("progression.badge.radius", 9.0))
	_font_size = int(Config.get_value("progression.badge.font_size", 11))
	position = Vector2(0.0, float(Config.get_value("progression.badge.offset_y", -46.0)))


## 由 player 在等级/档位变化时调用（改完立刻 queue_redraw）
func refresh(lv: int, tier: String) -> void:
	level = clampi(lv, 0, 9)
	tier_id = tier if tier != "" else "blue"
	_apply_cfg()
	queue_redraw()


func _draw() -> void:
	if not _enabled:
		return
	var col := Color(str(Config.get_value(
			"progression.badge.colors.%s" % tier_id, "#378ADD")))
	# 底盘：半透明黑，保证任何地形上都读得清
	draw_circle(Vector2.ZERO, _radius, Color(0.0, 0.0, 0.0, 0.55))
	# 圈：档位色
	draw_arc(Vector2.ZERO, _radius - 0.5, 0.0, TAU, 16, col, 1.5, true)

	var font := ThemeDB.fallback_font
	if font == null:
		return
	var s := str(level)
	var sz := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size)
	# 数字水平居中、垂直大致居中（draw_string 的原点是基线，往下偏一点）
	draw_string(font, Vector2(-sz.x * 0.5, sz.y * 0.35), s,
			HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, Color(1.0, 1.0, 1.0))

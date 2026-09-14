extends Node2D
## ============================================================
## SelectIcon — 选中高亮图标（替代原来的角色身上圆圈）
##
## 显示在角色头顶：一颗悬浮的朝下指示三角（尖端指向角色头部）
## + 上方小圆点，带轻微脉冲呼吸，表达"当前操控单位"。
## 由 player.gd 控制 visible，颜色取自 config 的 player.selected_color。
##
## 正式美术素材就位后，可把此节点的 _draw 换成贴图（Sprite2D），
## player.gd 的接口（visible / icon_color）保持不变。
## ============================================================

var icon_color := Color(0.31, 0.76, 0.97, 1.0)
var _t := 0.0


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	var pulse := 0.5 + 0.5 * sin(_t * 4.0)          # 0..1 呼吸节奏
	var a := 0.55 + 0.45 * pulse
	var c := Color(icon_color.r, icon_color.g, icon_color.b, a)
	# 朝下指示三角（尖端指向角色头部）
	var tip := Vector2(0.0, 4.0)
	var base_l := Vector2(-9.0, -6.0)
	var base_r := Vector2(9.0, -6.0)
	draw_colored_polygon(PackedVector2Array([tip, base_l, base_r]), c)
	# 上方悬浮圆点
	draw_circle(Vector2(0.0, -14.0), 3.0, c)

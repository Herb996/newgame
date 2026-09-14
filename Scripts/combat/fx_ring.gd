extends Node2D
## ============================================================
## FxRing — 冲击波圆环（灰盒阶段的临时视觉反馈）
## 用途：技能命中范围可视化（蒸汽爆发的圆形 AOE）。
## 用法：由 player.spawn_impact_ring() 生成并挂在角色下，
##       播完（扩散 + 淡出）自动 queue_free，无需外部管理。
## 正式美术素材就位后替换为粒子/贴图即可，接口不变。
## ============================================================

var radius := 60.0
var duration := 0.35
var ring_color := Color(1.0, 1.0, 1.0, 1.0)

var _t := 0.0


func setup(p_radius: float, p_duration: float, p_color: Color) -> void:
	radius = p_radius
	duration = maxf(p_duration, 0.05)
	ring_color = p_color
	z_index = 50
	queue_redraw()


func _process(delta: float) -> void:
	_t += delta
	if _t >= duration:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var k := clampf(_t / duration, 0.0, 1.0)
	var r := radius * (0.25 + 0.75 * k)
	var c := ring_color
	c.a = ring_color.a * (1.0 - k)
	# 分段数随半径增长，保证大圆也平滑
	draw_arc(Vector2.ZERO, r, 0.0, TAU, maxi(int(r * 0.5), 16), c, 3.0, true)

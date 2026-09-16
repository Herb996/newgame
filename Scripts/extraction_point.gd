extends Area2D
## ============================================================
## ExtractionPoint — 撤离点
## 开启后：玩家进入圆形触发区域，站够 session.extraction_hold_seconds
## 秒即撤离成功（调用 RunManager.extract()），离开则进度清零。
## 进度弧带脉冲动画（02_SYSTEM_SPEC 手感清单）。
## 关闭后：显示暗红叉，不再触发。
## 数值全部来自 Data/config.json 的 extraction / session 节点。
## ============================================================

var is_open := false
var hold_progress := 0.0
var hold_seconds := 0.0
var radius := 0.0
var _pulse_t := 0.0
var _run: Node


func _ready() -> void:
	add_to_group("extraction_points")
	radius = float(Config.get_value("extraction.trigger_radius", 24.0))
	$CollisionShape2D.shape.radius = radius
	hold_seconds = float(Config.get_value("session.extraction_hold_seconds", 3.0))
	monitoring = false


func open() -> void:
	is_open = true
	monitoring = true
	hold_progress = 0.0
	queue_redraw()


func close() -> void:
	is_open = false
	monitoring = false
	hold_progress = 0.0
	queue_redraw()


func _physics_process(delta: float) -> void:
	if not is_open:
		return
	_pulse_t += delta
	if _run == null:
		_run = get_tree().get_first_node_in_group("run_manager")

	var player_inside := false
	for body in get_overlapping_bodies():
		if body.is_in_group("player"):
			player_inside = true
			break

	if player_inside:
		hold_progress += delta
		if hold_progress >= hold_seconds and _run != null:
			_run.extract()
			return
	else:
		hold_progress = 0.0
	queue_redraw()


## 玩家是否正在圈内（供关闭调度检测，避免在玩家脚下关闭）
func has_player_inside() -> bool:
	if not is_open:
		return false
	for body in get_overlapping_bodies():
		if body.is_in_group("player"):
			return true
	return false


func _draw() -> void:
	if is_open:
		# 铜锈色地面底 + 蒸汽白脉冲外环
		var pulse := 0.5 + 0.5 * sin(_pulse_t * 4.0)
		draw_circle(Vector2.ZERO, radius, Color(0.55, 0.33, 0.16, 0.30))
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48,
			Color(0.91, 0.90, 0.86, 0.35 + 0.65 * pulse), 3.0)
		# 撤离进度弧（警示橙，从 12 点方向顺时针）
		if hold_progress > 0.0:
			var frac: float = clampf(hold_progress / maxf(hold_seconds, 0.001), 0.0, 1.0)
			draw_arc(Vector2.ZERO, radius + radius * 0.05, -PI / 2.0,
				-PI / 2.0 + TAU * frac, 48, Color(1.0, 0.55, 0.15, 0.9), radius * 0.05)
		draw_circle(Vector2.ZERO, radius * 0.07, Color(0.91, 0.90, 0.86))
	else:
		# 关闭态：暗警示红圆圈 + 叉。以下尺寸全部按 radius 取比例——
		# 触发半径会随地图格尺寸等比缩放（16px 格时代是 24，现在 64px 格是 96），
		# 写死像素值会让"叉"缩成一个点、或把整圈撑爆。
		var dim := Color(0.45, 0.14, 0.10, 0.85)
		var a := radius * 0.13
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, dim, maxf(2.0, radius * 0.025))
		draw_line(Vector2(-a, -a), Vector2(a, a), dim, maxf(2.0, radius * 0.035))
		draw_line(Vector2(a, -a), Vector2(-a, a), dim, maxf(2.0, radius * 0.035))

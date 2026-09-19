class_name HitDirectionIndicator
extends Control
## ============================================================
## HitDirectionIndicator — 受击方向指示（玩家挨打时那道朝攻击者的红楔）
##
## 为什么要有它：无敌帧（combat.player.invincible_after_hit_seconds）之前是**零视觉
## 反馈**的——血掉了一格、角色红一下，但"这发从哪来"完全读不出来。RTS 自由镜头下
## 尤其致命：镜头没跟着玩家时，你根本不知道该把谁拉出来。
##
## 钉在**挨打那名角色的世界位置**上（不是屏幕中心）：楔跟着镜头平移/缩放走，
## 所以它说的是"他在那个位置、朝那个方向挨了一下"，小队多人同时挨打就同时出多道。
## 角色已经死了/被镜头甩到屏外也照画 —— 中心夹进可视区，退化成屏幕边缘的一道提示。
##
## 上报走 call_group（见 player.gd::take_damage），所以角色生成/销毁都不用接线；
## 这里也不持有任何角色引用，只存那一刻的坐标，绝不会有悬挂节点。
##
## 全屏垫层必须 MOUSE_FILTER_IGNORE：局内的点击/框选要吃这一层的鼠标，
## 一个吃点击的全屏 Control 会直接让 RTS 操作失效（湿地层踩过同一个坑）。
## ============================================================

## 上报入口所在组名（player.gd 用 call_group 找它）
const GROUP := &"hit_direction_indicator"

var _marks: Array = []      # [{at: Vector2 世界坐标, src: Vector2 攻击者世界坐标, age: float}]
var _enabled := true
var _radius := 150.0
var _band := 46.0
var _half_arc := 0.4
var _fade := 0.7
var _peak := 0.85
var _color := Color(1.0, 0.35, 0.29)
var _max_marks := 4
var _segments := 12


func _ready() -> void:
	add_to_group(GROUP)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_enabled = bool(Config.get_value("combat.player.hit_direction_enabled", true))
	_radius = float(Config.get_value("combat.player.hit_direction_radius_px", 150.0))
	_band = float(Config.get_value("combat.player.hit_direction_band_px", 46.0))
	_half_arc = deg_to_rad(float(Config.get_value("combat.player.hit_direction_arc_degrees", 46.0)) * 0.5)
	_fade = maxf(0.05, float(Config.get_value("combat.player.hit_direction_fade_seconds", 0.7)))
	_peak = float(Config.get_value("combat.player.hit_direction_peak_alpha", 0.85))
	_max_marks = maxi(1, int(Config.get_value("combat.player.hit_direction_max_marks", 4)))
	_segments = maxi(3, int(Config.get_value("combat.player.hit_direction_segments", 12)))
	_color = Color.from_string(str(Config.get_value("combat.player.hit_direction_color", "#ff5a4a")),
			Color(1.0, 0.35, 0.29))
	visible = _enabled


## 由 player.take_damage 通过 call_group 打进来：单位位置 + 攻击者位置（世界坐标）。
func report_hit(at: Vector2, src: Vector2) -> void:
	if not _enabled or at.distance_squared_to(src) < 1.0:
		return
	_marks.append({"at": at, "src": src, "age": 0.0})
	while _marks.size() > _max_marks:
		_marks.pop_front()        # 挤掉最老的一道：新方向比旧方向有用
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	if _marks.is_empty():
		return
	var alive := false
	for m in _marks:
		m["age"] = float(m["age"]) + delta
		if float(m["age"]) < _fade:
			alive = true
	_marks = _marks.filter(func(m) -> bool: return float(m["age"]) < _fade)
	queue_redraw()
	if not alive:
		set_process(false)


func _draw() -> void:
	if _marks.is_empty():
		return
	var canvas := get_viewport().get_canvas_transform()
	var vp := get_viewport().get_visible_rect().size
	# 底部让位给菜单栏（和背包弹窗同一条约束），否则楔会糊在指令按钮上
	var bottom := vp.y - (UiKit.menu_bar_height(vp.y) if UiKit.menu_bar_enabled() else 0.0)
	for m in _marks:
		var center: Vector2 = canvas * (m["at"] as Vector2)
		center.x = clampf(center.x, _radius * 0.5, vp.x - _radius * 0.5)
		center.y = clampf(center.y, _radius * 0.5, maxf(bottom, _radius * 0.5) - _radius * 0.5)
		var dir: Vector2 = canvas * (m["src"] as Vector2) - canvas * (m["at"] as Vector2)
		if dir.length_squared() < 1.0:
			continue
		_draw_wedge(center, dir.angle(), 1.0 - float(m["age"]) / _fade)


## 一道楔：沿角度两侧各 _half_arc 张开放射状环带，逐段画四边形。
## 每段四个角各给一份 alpha ⇒ 楔的两头自然收尖（整块同色会画成一块贴上去的补丁）。
func _draw_wedge(center: Vector2, angle: float, life: float) -> void:
	var r_in := maxf(_radius - _band * 0.5, 1.0)
	var r_out := _radius + _band * 0.5
	for i in range(_segments):
		var t0 := float(i) / float(_segments)
		var t1 := float(i + 1) / float(_segments)
		# 角向衰减：两端到 0，中间满 —— 用 cos 而不是直线，边界不会有折角
		var a0 := life * _peak * _angular(t0)
		var a1 := life * _peak * _angular(t1)
		var d0 := Vector2.from_angle(lerpf(angle - _half_arc, angle + _half_arc, t0))
		var d1 := Vector2.from_angle(lerpf(angle - _half_arc, angle + _half_arc, t1))
		draw_polygon(
				PackedVector2Array([center + d0 * r_in, center + d0 * r_out,
						center + d1 * r_out, center + d1 * r_in]),
				PackedColorArray([_with_alpha(a0 * 0.55), _with_alpha(a0),
						_with_alpha(a1), _with_alpha(a1 * 0.55)]))


func _angular(t: float) -> float:
	# 升余弦钟形：t=0/1 恰好为 0，t=0.5 满 —— 两端收尖且没有折角。
	# （用 cos((2t-1)*PI/2) 会在两端留下 0.707 的硬边，看着像贴上去的补丁。）
	return (1.0 + cos((t * 2.0 - 1.0) * PI)) * 0.5


func _with_alpha(a: float) -> Color:
	var c: Color = _color
	c.a = clampf(a, 0.0, 1.0)
	return c

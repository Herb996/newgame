extends Node2D
## ============================================================
## RippleRing — 单个踩水波纹（池化元素，由 WeatherSystem 统一持有）
##
## 与 combat/fx_ring.gd 同一路子：`_draw()` 画贴地椭圆，灰盒阶段够用。
## 差别在两点：
##   1. **播完不 queue_free，而是 hide() 回池**。踩水是按脚步节奏（0.4s）持续
##      触发的消耗品，每圈都新建/销毁节点会在帧里堆出无谓的分配与 RID 抖动；
##      固定池 + 复位复用可以证明「跑两分钟节点数不增长」。
##   2. 不是整圈，是**一小撮各自独立的椭圆弧碎片**：每次 spawn() 按 config 掷出
##      N 段弧，每段的角度、跨角、半径倍率、起播延迟、亮度都不一样，外加主弧之外
##      一层错开半格的角度、更小的内弧。水面被踩了一下的真实读法就是"碎碎地荡开"，
##      而不是地上贴了个准星。
##
## 为什么不用 GPUParticles2D：波纹要的是「每次脚步恰好一组、从脚底扩出去」的
## 精确语义，用粒子还得处理发射同步与随机寿命；draw_polyline 与项目现有 FX 风格一致。
##
## 历史裁定（都是用户实测后否掉的形状，别再走回去）：
##   2026-09-18 首版：整圈拆随机短弧 + 高 glow → "地面上贴了一圈白色虚线靶子"。
##       那次的病根是所有碎片**共圆**（同半径、同一时刻扩到同一圈）→ 连读成一个环。
##       本版靠 rmul 半径抖动 + 延迟抖动 + 双层错角把"共圆"打散。
##   2026-09-18 二版：连续完整双圈细环 → 干地/浅水处像贴了条线，且完全没有"碎"的感觉。
##   2026-09-19 终版：椭圆 + 只显示部分图案 + 碎碎的感觉（本轮）。
## ============================================================

var radius := 46.0
var duration := 0.55
var ring_color := Color(0.75, 0.89, 1.0, 0.8)

## 本次 spawn 掷出的碎片弧集合：[{a0, span, rmul, alpha, delay}]。
## 探针要逐项核对（段数、跨角是否小于整圈、半径是否被打散），故公开。
var frags: Array = []

var _t := 0.0
var _active := false


## 从池里取出并复位：碎片在这里重掷，所以每次踩水的图案都不一样。
func spawn(pos: Vector2, p_radius: float, p_duration: float, p_color: Color) -> void:
	global_position = pos
	radius = maxf(p_radius, 4.0)
	duration = maxf(p_duration, 0.05)
	ring_color = p_color
	frags = _roll_frags()
	_t = 0.0
	_active = true
	visible = true
	queue_redraw()


func _process(delta: float) -> void:
	if not _active:
		return
	_t += delta
	if _t >= duration:
		_retire()
		return
	queue_redraw()


## 到期回收：隐藏并让出池位（不销毁节点）
func _retire() -> void:
	_active = false
	visible = false


func is_free() -> bool:
	return not _active


# ============================================================
# 掷碎片
# ============================================================

## 沿整圈均分出 N 个槽，每段弧只占自己槽内的一小截 → 天然不会铺满整圈；
## 再加一个整圈随机旋转，避免每圈碎片都卡在同样的角度上。
func _roll_frags() -> Array:
	var n := maxi(2, int(Config.get_value("weather.ripple.fragments", 5)))
	var span_deg := float(Config.get_value("weather.ripple.arc_span_deg", 30.0))
	var span_jitter := float(Config.get_value("weather.ripple.arc_span_jitter", 0.45))
	var radius_jitter := float(Config.get_value("weather.ripple.arc_radius_jitter", 0.18))
	var phase_jitter := float(Config.get_value("weather.ripple.arc_phase_jitter", 0.35))
	var alpha_jitter := float(Config.get_value("weather.ripple.arc_alpha_jitter", 0.45))
	var slot := TAU / float(n)
	var rot := randf() * TAU
	var out: Array = []
	for i in range(n):
		var span := deg_to_rad(span_deg) * (1.0 + randf_range(-span_jitter, span_jitter))
		# 硬上限：留够缺口。共 360° 里最多填掉八成，绝不出现闭合环。
		span = clampf(span, deg_to_rad(4.0), slot * 0.8)
		out.append({
			"a0": rot + slot * float(i) + randf() * (slot - span) * 0.7,
			"span": span,
			"rmul": 1.0 + randf_range(-radius_jitter, radius_jitter),
			"alpha": 1.0 + randf_range(-alpha_jitter, 0.0),
			"delay": randf() * phase_jitter,
		})
	return out


# ============================================================
# 绘制
# ============================================================

func _draw() -> void:
	var k := clampf(_t / duration, 0.0, 1.0)
	var squash := float(Config.get_value("weather.ripple.ellipse_squash", 0.45))
	var lw := float(Config.get_value("weather.ripple.line_width", 7.0))
	for f in frags:
		var kf := _frag_progress(float(f["delay"]), k)
		if kf <= 0.0:
			continue
		# 主弧：从 20% 半径扩到满，透明度随寿命衰减、线宽随扩张变细（外圈能量衰减）
		_draw_band(radius * float(f["rmul"]) * (0.2 + 0.8 * kf),
				ring_color.a * float(f["alpha"]) * (1.0 - kf),
				lw * (0.5 + 0.5 * (1.0 - kf)), squash,
				float(f["a0"]), float(f["span"]))

	# 内弧：起步晚 30%、半径只有主圈一半，且角度整体错开半个槽
	# —— 两层不同半径的碎片叠着扩，才有"往外荡了两下"的层次。
	var k2 := clampf((k - 0.3) / 0.7, 0.0, 1.0)
	if k2 > 0.0:
		var ir := float(Config.get_value("weather.ripple.inner_ratio", 0.55))
		var ia := float(Config.get_value("weather.ripple.inner_alpha", 0.25))
		var half := PI / float(maxi(2, frags.size()))
		for f in frags:
			_draw_band(radius * ir * float(f["rmul"]) * (0.3 + 0.7 * k2),
					ring_color.a * float(f["alpha"]) * (1.0 - k2) * ia,
					lw * 0.7 * (1.0 - k2), squash,
					float(f["a0"]) + half, float(f["span"]))


## 单段碎片的寿命进度：起播前为 0，之后把剩下的时间摊成 0..1。
func _frag_progress(delay: float, k: float) -> float:
	if k <= delay:
		return 0.0
	return (k - delay) / maxf(1.0 - delay, 0.0001)


## 软带弧段：多层同心描边叠出"中间亮、两侧淡"的径向衰减。
## 为什么要宽度：波纹要经半分辨率子视口 + 相机 zoom 两次缩小，
## 单条细线到屏上不足 1 像素（实测整屏只有十几个像素有信号）→ 看着就是没有波纹。
func _draw_band(r: float, alpha: float, width: float, squash: float, a0: float, span: float) -> void:
	if r < 2.0 or alpha <= 0.01 or width <= 0.01 or span <= 0.001:
		return
	var layers: Array = Config.get_value("weather.ripple.band_layers", [[1.0, 0.42], [0.7, 0.22], [0.42, 0.1]])
	for i in range(layers.size()):
		var L: Array = layers[i]
		var w := width * float(L[0])
		if w < 0.6:
			continue
		_stroke_arc(r, alpha * float(L[1]), w, squash, a0, span)


## 一段椭圆折线（a0..a0+span，顶点数按弧长走，短弧不留折角）。
func _stroke_arc(r: float, alpha: float, width: float, squash: float, a0: float, span: float) -> void:
	var n := clampi(int(r * span / 4.0), 4, 40)
	var pts := PackedVector2Array()
	pts.resize(n + 1)
	for i in range(n + 1):
		var a := a0 + span * float(i) / float(n)
		pts[i] = Vector2(cos(a) * r, sin(a) * r * squash)
	var c := ring_color
	c.a = clampf(alpha, 0.0, 1.0)
	draw_polyline(pts, c, width, true)

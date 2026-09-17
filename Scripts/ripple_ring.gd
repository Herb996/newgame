extends Node2D
## ============================================================
## RippleRing — 单个水波纹（池化元素，由 WeatherSystem 统一持有）
##
## 与 combat/fx_ring.gd 同一路子：`_draw()` 画扩张圆环，灰盒阶段够用。
## 差别在两点：
##   1. **播完不 queue_free，而是 hide() 回池**。踩水是按脚步节奏（0.4s）持续
##      触发的消耗品，每圈都新建/销毁节点会在帧里堆出无谓的分配与 RID 抖动；
##      固定池 + 复位复用可以证明「跑两分钟节点数不增长」。
##   2. 双圈：主圈先扩，次圈晚半拍、半径更小 —— 单圈看着像靶子，
##      两圈才有「水面被踩了一下往外荡」的层次。
##
## 为什么不用 GPUParticles2D：波纹要的是「每次脚步恰好一圈、从脚底扩出去」的
## 精确语义，用粒子还得处理发射同步与随机寿命；draw_arc 与项目现有 FX 风格一致。
## 第二阶段若换成 shader ring，只需替换本文件的 _draw，spawn()/池协议不变。
## ============================================================

var radius := 46.0
var duration := 0.55
var ring_color := Color(0.75, 0.89, 1.0, 0.8)

var _t := 0.0
var _active := false
var _seed := 0   # spawn 时定下：碎弧的随机分布在存活期内固定，避免每帧闪烁


## 从池里取出并复位。返回 false = 参数非法（调用方据此跳过本次波纹）。
func spawn(pos: Vector2, p_radius: float, p_duration: float, p_color: Color) -> void:
	global_position = pos
	radius = maxf(p_radius, 4.0)
	duration = maxf(p_duration, 0.05)
	ring_color = p_color
	_t = 0.0
	_seed = randi()
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


## 椭圆碎弧波纹：y 轴压扁成椭圆（贴地感），整圈拆成随机短弧——
## 有虚有实（透明度/线宽逐段抖动）、段间留缝，形成"碎碎的"水面反馈。
func _draw() -> void:
	var k := clampf(_t / duration, 0.0, 1.0)
	var fade := 1.0 - k
	var squash := float(Config.get_value("weather.ripple.ellipse_squash", 0.45))

	# 主圈：从 25% 半径扩到满，线宽随扩张变细（水波外圈能量衰减）
	_draw_frag_ring(radius * (0.25 + 0.75 * k), ring_color.a * fade,
			maxf(1.0, 2.6 * fade), squash, _seed)

	# 次圈：起步晚 30%、最大半径只有主圈的 62%，形成拖尾
	var k2 := clampf((_t - duration * 0.3) / (duration * 0.7), 0.0, 1.0)
	if k2 > 0.0:
		_draw_frag_ring(radius * 0.62 * (0.2 + 0.8 * k2), ring_color.a * (1.0 - k2) * 0.55,
				maxf(0.8, 1.8 * (1.0 - k2)), squash, _seed + 7)


## 把一圈拆成若干短弧段（段长/缝隙/透明度/线宽都随机），按椭圆压扁后画折线。
func _draw_frag_ring(r: float, alpha: float, width: float, squash: float, seed: int) -> void:
	if r < 2.0 or alpha <= 0.01:
		return
	var seg_r: Array = Config.get_value("weather.ripple.frag_seg_rad", [0.25, 0.8])
	var gap_r: Array = Config.get_value("weather.ripple.frag_gap_rad", [0.1, 0.45])
	var jitter := float(Config.get_value("weather.ripple.frag_alpha_jitter", 0.5))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var a := rng.randf_range(0.0, TAU)   # 起始角随机：每圈碎缝位置不同
	var guard := 0
	while guard < 48:
		guard += 1
		var seg := rng.randf_range(float(seg_r[0]), float(seg_r[1]))
		var gap := rng.randf_range(float(gap_r[0]), float(gap_r[1]))
		var a_j := alpha * (1.0 - jitter * rng.randf())          # 有虚有实
		var w_j := width * rng.randf_range(0.7, 1.3)             # 粗细不一
		_draw_arc_ellipse(r, a, a + seg, a_j, w_j, squash)
		a += seg + gap
		if a >= TAU + seg_r[0]:
			break


## 椭圆弧：沿角度采样折线，y 乘 squash 压扁。
func _draw_arc_ellipse(r: float, a0: float, a1: float, alpha: float, width: float, squash: float) -> void:
	var n := maxi(int(r * (a1 - a0) * 0.4), 4)
	var pts := PackedVector2Array()
	pts.resize(n + 1)
	for i in range(n + 1):
		var a := lerpf(a0, a1, float(i) / float(n))
		pts[i] = Vector2(cos(a) * r, sin(a) * r * squash)
	var c := ring_color
	c.a = alpha
	draw_polyline(pts, c, width, true)

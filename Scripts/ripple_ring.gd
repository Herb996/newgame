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


## 从池里取出并复位。返回 false = 参数非法（调用方据此跳过本次波纹）。
func spawn(pos: Vector2, p_radius: float, p_duration: float, p_color: Color) -> void:
	global_position = pos
	radius = maxf(p_radius, 4.0)
	duration = maxf(p_duration, 0.05)
	ring_color = p_color
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


func _draw() -> void:
	var k := clampf(_t / duration, 0.0, 1.0)
	var fade := 1.0 - k

	# 主圈：从 25% 半径扩到满，线宽随扩张变细（水波外圈能量衰减）
	var r1 := radius * (0.25 + 0.75 * k)
	var c1 := ring_color
	c1.a = ring_color.a * fade
	draw_arc(Vector2.ZERO, r1, 0.0, TAU, maxi(int(r1 * 0.6), 16), c1, maxf(1.0, 2.6 * fade), true)

	# 次圈：起步晚 30%、最大半径只有主圈的 62%，形成拖尾
	var k2 := clampf((_t - duration * 0.3) / (duration * 0.7), 0.0, 1.0)
	if k2 > 0.0:
		var r2 := radius * 0.62 * (0.2 + 0.8 * k2)
		var c2 := ring_color
		c2.a = ring_color.a * (1.0 - k2) * 0.55
		draw_arc(Vector2.ZERO, r2, 0.0, TAU, maxi(int(r2 * 0.6), 12), c2, maxf(0.8, 1.8 * (1.0 - k2)), true)

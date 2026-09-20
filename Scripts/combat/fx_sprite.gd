extends Sprite2D
## ============================================================
## FxSprite — 一次性播放的贴图特效（横条图集：帧从左到右排开），播完自毁
##
## 与 combat/fx_ring.gd 同一路子：自己 _process 推进、时间到 queue_free，
## 外部只管生成不管回收。区别只是把"程序画的圆环"换成"美术切的帧图"。
##
## 为什么不写 class_name：见 fx_library.gd 的说明 —— 调用方一律 preload，
## 少一处全局类名就少一处「新 class_name 无头看不见」的坑。
##
## 帧图约定（tools/cut_fx.py 保证）：每格是完整正方形、内容居中，
## 所以**不裁包围盒**，pivot 恒在格中心，逐帧切换不会抖。
## ============================================================

const GROUP := &"fx_sprite"

var frames := 1
var fps := 24.0
var fade_out := 0.08

var _total := 0.0
var _t := 0.0
var _acc := 0.0
var _alpha := 1.0


func _ready() -> void:
	add_to_group(GROUP)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	hframes = maxi(frames, 1)
	frame = 0
	_total = float(maxi(frames, 1)) / maxf(fps, 1.0)
	_alpha = modulate.a


func _process(delta: float) -> void:
	_t += delta
	_acc += delta
	var step := 1.0 / maxf(fps, 1.0)
	while _acc >= step:
		_acc -= step
		if frame < frames - 1:
			frame += 1
	if _t < _total:
		return
	if fade_out <= 0.0:
		queue_free()
		return
	var k := clampf((_t - _total) / fade_out, 0.0, 1.0)
	modulate.a = _alpha * (1.0 - k)
	if k >= 1.0:
		queue_free()

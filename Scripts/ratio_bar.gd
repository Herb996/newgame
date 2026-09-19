extends Control
## ============================================================
## RatioBar — 单条比例尺：把 100% 切成 N 段（每段一种颜色），
## 段宽 ∝ 各自权重；段与段之间有可拖的分界线，拖动时**相邻两段此消彼长**
## （这两段之和不变 → 总长恒 100%）。用于「地形出现比例」这种多段占比调节。
##
## 用法：
##   var bar := RatioBar.new()
##   bar.setup(["草地","荒原","森林","沼泽"], [col0,col1,col2,col3], [3.4,1.05,1.25,0.95])
##   bar.changed.connect(func(vals): ...)   # vals = 新的权重数组（相对值，和不变）
##   add_child(bar)
##
## 数值零硬编码：段数/标签/颜色/权重都由调用方传入；本控件只管交互与绘制。
## ============================================================

signal changed(values: Array)

var _labels: PackedStringArray = PackedStringArray()
var _colors: Array = []          # Array[Color]
var _values: Array = []          # Array[float] 相对权重（内部保持总和不变）

var _bar_h := 34.0
var _grab_px := 12.0             # 命中分界线的像素半径
var _drag := -1                  # 正在拖的分界线索引（0..N-2）
var _hover := -1


func setup(labels: Array, colors: Array, values: Array) -> void:
	_labels = PackedStringArray()
	for l in labels:
		_labels.append(str(l))
	_colors = colors.duplicate()
	_values = []
	for v in values:
		_values.append(float(v))
	custom_minimum_size = Vector2(0, _bar_h + 26)
	mouse_filter = Control.MOUSE_FILTER_STOP
	queue_redraw()


func _total() -> float:
	var t := 0.0
	for v in _values:
		t += float(v)
	return maxf(t, 1e-6)


## 各内部分界线在控件内的 x 像素（累积占比 × 宽）。N 段 → N-1 条分界线。
func _boundaries() -> PackedFloat64Array:
	var xs := PackedFloat64Array()
	var w := size.x
	var t := _total()
	var acc := 0.0
	for i in range(_values.size() - 1):
		acc += float(_values[i]) / t
		xs.append(acc * w)
	return xs


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag = _nearest_boundary(event.position)
			if _drag >= 0:
				_apply_drag(event.position.x)
				accept_event()
		else:
			_drag = -1
	elif event is InputEventMouseMotion:
		if _drag >= 0:
			_apply_drag(event.position.x)
			accept_event()
		else:
			var h := _nearest_boundary(event.position)
			if h != _hover:
				_hover = h
				queue_redraw()


func _nearest_boundary(pos: Vector2) -> int:
	var bs := _boundaries()
	var best := -1
	var bestd := _grab_px
	for i in range(bs.size()):
		var d := absf(pos.x - bs[i])
		if d < bestd:
			bestd = d
			best = i
	return best


## 拖动分界线 i：只重分配段 i 与段 i+1（两者之和不变 → 总和不变）。
func _apply_drag(x: float) -> void:
	var i := _drag
	if i < 0 or i + 1 >= _values.size():
		return
	var w := maxf(size.x, 1.0)
	var t := _total()
	# 前 i 段（0..i-1）累积权重不变
	var left := 0.0
	for k in range(i):
		left += float(_values[k])
	# 段 i + 段 i+1 的合计权重
	var pair := float(_values[i]) + float(_values[i + 1])
	# 目标：让第 i 段右边界落在 x → 前 i+1 段累积 = x/w × t
	var target_left := clampf(x / w, 0.0, 1.0) * t
	var new_i := clampf(target_left - left, 0.0, pair)
	var new_i1 := pair - new_i
	# 给两端留一点最小宽度，避免完全拖成 0 抓不到
	var minw := t * 0.005
	new_i = clampf(new_i, minw, pair - minw)
	new_i1 = pair - new_i
	_values[i] = new_i
	_values[i + 1] = new_i1
	queue_redraw()
	changed.emit(_values.duplicate())


func _draw() -> void:
	var w := size.x
	var h := _bar_h
	var t := _total()
	var x := 0.0
	for i in range(_values.size()):
		var frac := float(_values[i]) / t
		var seg_w := frac * w
		var col: Color = _colors[i] if i < _colors.size() else Color(0.5, 0.5, 0.5)
		var rect := Rect2(x, 0, seg_w, h)
		draw_rect(rect, col)
		draw_rect(rect, Color(0, 0, 0, 0.45), false, 1.0)
		# 段内标签：名字 + 百分比（段太窄就只画百分比）
		var pct := int(round(frac * 100.0))
		var text := "%s %d%%" % [_labels[i] if i < _labels.size() else "", pct]
		if seg_w < 70.0:
			text = "%d%%" % pct
		var fnt := get_theme_default_font()
		var fs := 13
		draw_string(fnt, Vector2(x + 6, h - 10), text, HORIZONTAL_ALIGNMENT_LEFT,
				maxf(seg_w - 12, 0), fs, Color(0.05, 0.05, 0.05, 0.92))
		x += seg_w
	# 分界线把手（白竖条；悬停/拖动时高亮加粗）
	var bs := _boundaries()
	for i in range(bs.size()):
		var active := (i == _drag or i == _hover)
		var c := Color(1, 1, 1, 0.95) if active else Color(1, 1, 1, 0.55)
		draw_line(Vector2(bs[i], -3), Vector2(bs[i], h + 3), c, 4.0 if active else 2.0)

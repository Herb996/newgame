extends Control
## ============================================================
## RatioBar — 单条比例尺：把 100% 切成 N 段（每段一种颜色），段宽 ∝ 权重。
## 条上有两类可拖把手：
##   · 白色分界线（段与段之间）：拖动只在相邻两段间此消彼长，总长恒 100%；
##     每段宽度被夹在自己的 [下限, 上限] 之内。
##   · 每段一对橙色「| |」把手 = 该段占比的下限 / 上限：直接在条上拖来改上下限。
##
## 信号：
##   changed(values)                    权重数组变了（拖白色分界线）
##   bounds_changed(mins, maxs)         上下限百分比数组变了（拖橙色把手）
##
## 数值零硬编码：段数 / 标签 / 颜色 / 权重 / 上下限全由调用方传入；本控件只管交互与绘制。
## ============================================================

signal changed(values: Array)
signal bounds_changed(mins: Array, maxs: Array)

var _labels: PackedStringArray = PackedStringArray()
var _colors: Array = []          # Array[Color]
var _values: Array = []          # Array[float] 相对权重（内部保持总和不变）
var _min_pct: Array = []         # Array[float] 每段下限（百分比 0..100）；空=无约束
var _max_pct: Array = []         # Array[float] 每段上限（百分比 0..100）；空=无约束

var _bar_h := 34.0
var _stick_top := 18.0           # 条顶留白（给上下限百分比文字 + 把手）
var _stick_bot := 8.0
var _grab_px := 10.0             # 命中把手的分界线的像素半径

## 上下限把手的硬拖拽边界（占这段自身宽度的百分比）：把手只能在 [BAND_MIN, BAND_MAX] 里拖，不许拖出。
const BAND_MIN := 10.0
const BAND_MAX := 30.0

enum { K_NONE, K_DIVIDER, K_MIN, K_MAX }
var _drag_kind: int = K_NONE
var _drag_idx: int = -1
var _hover_kind: int = K_NONE
var _hover_idx: int = -1
var _suppress_bounds := false     # 拖白色分界线期间为 true：先隐藏橙色上下限把手，松手后再显示


func setup(labels: Array, colors: Array, values: Array, mins: Array = [], maxs: Array = []) -> void:
	_labels = PackedStringArray()
	for l in labels:
		_labels.append(str(l))
	_colors = colors.duplicate()
	_values = []
	for v in values:
		_values.append(float(v))
	_min_pct = []
	for m in mins:
		_min_pct.append(float(m))
	_max_pct = []
	for m in maxs:
		_max_pct.append(float(m))
	custom_minimum_size = Vector2(0, _stick_top + _bar_h + _stick_bot + 10)
	mouse_filter = Control.MOUSE_FILTER_STOP
	queue_redraw()


func _n() -> int:
	return _values.size()


func _total() -> float:
	var t := 0.0
	for v in _values:
		t += float(v)
	return maxf(t, 1e-6)


func _frac(i: int) -> float:
	return float(_values[i]) / _total()


## 第 i 段左边界占整条的比例（前面各段占比之和）。
func _start_frac(i: int) -> float:
	var s := 0.0
	for k in range(i):
		s += _frac(k)
	return s


func _has_bounds() -> bool:
	return _min_pct.size() == _n() and _max_pct.size() == _n()


## 分界线 i（段 i 与 i+1 之间）的 x 像素。i ∈ 0..N-2。
func _divider_x(i: int) -> float:
	return (_start_frac(i) + _frac(i)) * size.x


## 段 i 的某个上下限值对应的 x 像素：pct = 占「这段自身宽度」的百分比(0..100)，
## 所以把手永远落在 [段左边界, 段右边界] 内，不会跑到相邻地形。
func _handle_x(i: int, pct: float) -> float:
	return (_start_frac(i) + _frac(i) * pct / 100.0) * size.x


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var hit := _nearest(event.position)
			_drag_kind = int(hit[0])
			_drag_idx = int(hit[1])
			if _drag_kind != K_NONE:
				if _drag_kind == K_DIVIDER:
					_suppress_bounds = true
					queue_redraw()
				_apply(event.position.x)
				accept_event()
		else:
			_drag_kind = K_NONE
			_drag_idx = -1
			if _suppress_bounds:
				_suppress_bounds = false
				queue_redraw()
	elif event is InputEventMouseMotion:
		if _drag_kind != K_NONE:
			_apply(event.position.x)
			accept_event()
		else:
			var hit := _nearest(event.position)
			if int(hit[0]) != _hover_kind or int(hit[1]) != _hover_idx:
				_hover_kind = int(hit[0])
				_hover_idx = int(hit[1])
				queue_redraw()


## 命中范围内最近的一个把手，返回 [kind, idx]；无则 [K_NONE, -1]。
## 先扫分界线再扫把手、且都用严格小于，所以同一位置分界线优先于把手。
func _nearest(pos: Vector2) -> Array:
	var best_kind := K_NONE
	var best_idx := -1
	var best_d := _grab_px
	for i in range(_n() - 1):
		var d := absf(pos.x - _divider_x(i))
		if d < best_d:
			best_d = d
			best_kind = K_DIVIDER
			best_idx = i
	if _has_bounds():
		for i in range(_n()):
			var dm := absf(pos.x - _handle_x(i, float(_min_pct[i])))
			if dm < best_d:
				best_d = dm
				best_kind = K_MIN
				best_idx = i
			var dx := absf(pos.x - _handle_x(i, float(_max_pct[i])))
			if dx < best_d:
				best_d = dx
				best_kind = K_MAX
				best_idx = i
	return [best_kind, best_idx]


func _apply(x: float) -> void:
	match _drag_kind:
		K_DIVIDER:
			_drag_divider(_drag_idx, x)
		K_MIN:
			_drag_bound(_drag_idx, x, true)
		K_MAX:
			_drag_bound(_drag_idx, x, false)


## 拖白色分界线 i：只在段 i 与 i+1 间此消彼长（两者之和不变），自由滑动，只留极小下限防 0。
func _drag_divider(i: int, x: float) -> void:
	if i < 0 or i + 1 >= _n():
		return
	var w := maxf(size.x, 1.0)
	var t := _total()
	var left := 0.0
	for k in range(i):
		left += float(_values[k])
	var pair := float(_values[i]) + float(_values[i + 1])
	var target_left := clampf(x / w, 0.0, 1.0) * t
	var floor_w := t * 0.005
	var new_i := clampf(target_left - left, floor_w, pair - floor_w)
	_values[i] = new_i
	_values[i + 1] = pair - new_i
	queue_redraw()
	changed.emit(_values.duplicate())


## 拖橙色把手：改段 i 的下限(is_min)或上限。pct = 把手在这段内部的相对位置
## （占这段自身宽度的百分比），但被硬夹在 [BAND_MIN, BAND_MAX]=10~30 里、拖不出去；
## 再叠 min≤max 次序，保证两把手不交叉。
func _drag_bound(i: int, x: float, is_min: bool) -> void:
	if i < 0 or i >= _n() or not _has_bounds():
		return
	var w := maxf(size.x, 1.0)
	var sf := _start_frac(i)
	var fr := _frac(i)
	if fr <= 1e-6:
		return
	var pct := clampf((clampf(x / w, 0.0, 1.0) - sf) / fr * 100.0, BAND_MIN, BAND_MAX)
	if is_min:
		_min_pct[i] = clampf(pct, BAND_MIN, float(_max_pct[i]))
	else:
		_max_pct[i] = clampf(pct, float(_min_pct[i]), BAND_MAX)
	queue_redraw()
	bounds_changed.emit(_min_pct.duplicate(), _max_pct.duplicate())


func _draw() -> void:
	var w := size.x
	var t := _total()
	var x := 0.0
	for i in range(_n()):
		var frac := float(_values[i]) / t
		var seg_w := frac * w
		var col: Color = _colors[i] if i < _colors.size() else Color(0.5, 0.5, 0.5)
		var rect := Rect2(x, _stick_top, seg_w, _bar_h)
		draw_rect(rect, col)
		draw_rect(rect, Color(0, 0, 0, 0.45), false, 1.0)
		var pct := int(round(frac * 100.0))
		var nm := str(_labels[i]) if i < _labels.size() else ""
		var text := "%s %d%%" % [nm, pct]
		if seg_w < 70.0:
			text = "%d%%" % pct
		draw_string(get_theme_default_font(), Vector2(x, _stick_top + _bar_h / 2.0 + 5), text,
				HORIZONTAL_ALIGNMENT_CENTER, seg_w, 13, Color(0.05, 0.05, 0.05, 0.92))
		x += seg_w
	# 每段的允许区淡带 + 上下限把手（暗铜色，把手外侧标「下限/上限 + 百分比」）；拖分界线期间不画
	if _has_bounds() and not _suppress_bounds:
		var fnt := get_theme_default_font()
		var amber := UiKit.COL_AMBER
		var lbl_col := Color(amber.r, amber.g, amber.b, 0.95)
		for i in range(_n()):
			var mnx := _handle_x(i, float(_min_pct[i]))
			var mxx := _handle_x(i, float(_max_pct[i]))
			draw_rect(Rect2(mnx, _stick_top + _bar_h, mxx - mnx, 3.0), Color(amber.r, amber.g, amber.b, 0.22))
			_draw_stick(mnx, (K_MIN == _drag_kind and _drag_idx == i) or (K_MIN == _hover_kind and _hover_idx == i))
			_draw_stick(mxx, (K_MAX == _drag_kind and _drag_idx == i) or (K_MAX == _hover_kind and _hover_idx == i))
			# 「下限」文字靠这条线左侧(右对齐)、「上限」靠右侧(左对齐)，朝外错开不打架
			draw_string(fnt, Vector2(mnx - 3.0 - 90.0, _stick_top - 6.0), "下限 %d%%" % int(round(float(_min_pct[i]))),
					HORIZONTAL_ALIGNMENT_RIGHT, 90.0, 11, lbl_col)
			draw_string(fnt, Vector2(mxx + 3.0, _stick_top - 6.0), "上限 %d%%" % int(round(float(_max_pct[i]))),
					HORIZONTAL_ALIGNMENT_LEFT, 90.0, 11, lbl_col)
	# 白色分界线（段间，可拖改占比）
	for i in range(_n() - 1):
		var active := (K_DIVIDER == _drag_kind and _drag_idx == i) or (K_DIVIDER == _hover_kind and _hover_idx == i)
		var c := Color(1, 1, 1, 0.95) if active else Color(1, 1, 1, 0.55)
		draw_line(Vector2(_divider_x(i), _stick_top - 3), Vector2(_divider_x(i), _stick_top + _bar_h + 3),
				c, 4.0 if active else 2.0)


## 上下限把手：一根暗铜色细竖线（悬停/拖动时更实），不再画小方块。
func _draw_stick(x: float, active: bool) -> void:
	var amber := UiKit.COL_AMBER
	var a := 0.95 if active else 0.6
	var c := Color(amber.r, amber.g, amber.b, a)
	var y0 := _stick_top - 1.0
	var y1 := _stick_top + _bar_h + 1.0
	draw_line(Vector2(x, y0), Vector2(x, y1), c, 2.0)

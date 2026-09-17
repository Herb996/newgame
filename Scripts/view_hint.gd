extends CanvasLayer
## ============================================================
## ViewHint — 视野提示（右下角）
##
## 滚轮缩放时淡入一行「视野 ×1.12  滚轮缩放」，停下 1.5s 后淡出。
##
## 为什么单独一层、没放进 HUD：
##   HUD 在**基地模式是隐藏的**（main3d.gd 会 hud.visible = false，
##   基地自带仓库/雕像面板），但滚轮缩放在基地与局内都能用，
##   提示必须两种模式都看得见 —— 挂在 HUD 下就等于基地里永远不显示。
##
## 相机通过 "iso_cam" 组找到（进基地/进局都会重建相机，所以每帧校验有效性）。
## 两条渲染线共用本文件：2D 的 camera_controller.gd 与 3D 的 iso_camera_3d.gd
## 都挂同一个组、都实现 zoom_ratio / zoom_hud_idle / zoom_hud_active / zoom_hud_enabled。
## 「要不要显示」问相机自己 —— 两条线的配置项不同（camera.zoom_hud / camera3d.zoom_hud），
## 写死成其中一个会让另一条线的开关失效。
## ============================================================

const CAM_GROUP := &"iso_cam"
const HOLD := 1.5          # 保持时长（秒），与相机侧一致
const FADE_AT := 0.9       # 从第几秒开始淡出

var _label: Label = null
var _cam: Node = null
## 局内底部菜单栏占了最下面 1/5 屏（本提示原本贴底 12px，正好会被压住），
## 高度与菜单栏同源（UiKit.menu_bar_height）。基地模式下菜单栏不显示，
## 这里照样上移 —— 位置保持一致比"有时高有时低"更好预期。
var _lift := 0.0


func _ready() -> void:
	_lift = UiKit.menu_bar_height(get_viewport().get_visible_rect().size.y) \
			if UiKit.menu_bar_enabled() else 0.0
	var l := Label.new()
	l.name = "ZoomHint"
	l.add_theme_font_size_override("font_size", 14)
	l.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	# 右锚点标签必须给足矩形宽度：Label 会按文字撑出最小尺寸，
	# 而矩形宽度为 0 时"撑开"是往锚点外侧长的 —— 文字会被推到屏幕外。
	l.offset_left = -420.0
	l.offset_right = -12.0
	l.offset_top = -56.0 - _lift
	l.offset_bottom = -12.0 - _lift
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	l.add_theme_color_override("font_color", Color(0.92, 0.95, 0.99))
	# 必须带描边：提示压在浅色地板/雪地上时，纯浅色文字几乎看不清
	l.add_theme_constant_override("outline_size", 5)
	l.add_theme_color_override("font_outline_color", Color(0.04, 0.05, 0.08, 0.9))
	l.visible = false
	add_child(l)
	_label = l


func _process(_delta: float) -> void:
	if _label == null:
		return
	if _cam == null or not is_instance_valid(_cam):
		_cam = get_tree().get_first_node_in_group(CAM_GROUP)
	if _cam == null or not is_instance_valid(_cam):
		_label.visible = false
		return
	if not _hud_enabled(_cam):
		_label.visible = false
		return
	if not bool(_cam.zoom_hud_active()):
		_label.visible = false
		return
	_label.text = "视野 ×%.2f   滚轮缩放" % float(_cam.zoom_ratio())
	var idle := float(_cam.zoom_hud_idle())
	_label.modulate = Color(1.0, 1.0, 1.0,
			1.0 if idle < FADE_AT else clampf((HOLD - idle) / (HOLD - FADE_AT), 0.0, 1.0))
	_label.visible = true


## 关掉提示的开关由相机提供：2D 读 camera.zoom_hud，3D 读 camera3d.zoom_hud。
## 相机没实现该方法时（旧版本）默认显示，不算错。
func _hud_enabled(cam: Node) -> bool:
	if cam.has_method("zoom_hud_enabled"):
		return bool(cam.zoom_hud_enabled())
	return true

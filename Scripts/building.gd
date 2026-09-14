extends Area2D
## ============================================================
## Building — 基地建筑（4x4 格 = 64x64 像素）
## 数据由 base_system 按 Data/config.json 的 base.buildings 注入：
##   building_id / display_name / hint（按 E 提示文本）/ color（由 id 映射）
## 玩家靠近时头顶显示提示，按 E 发出 interacted 信号（由 main 路由）。
## ============================================================

signal interacted(building_id: String)

var building_id := ""
var display_name := ""
var hint := ""
var _hint_label: Label
var _e_was_pressed := false  # 边沿检测：按住 E 只触发一次


func _ready() -> void:
	add_to_group("buildings")
	_hint_label = $HintLabel
	_hint_label.visible = false


func setup(id: String, b_name: String, hint_text: String) -> void:
	building_id = id
	display_name = b_name
	hint = hint_text
	$NameLabel.text = b_name
	$Body.color = _color_for(id)


## 建筑配色（03_ART_STYLE_GUIDE.md 色调）
func _color_for(id: String) -> Color:
	match id:
		"warehouse": return Color(0.55, 0.33, 0.16)   # 铜锈
		"statue": return Color(0.82, 0.78, 0.62)      # 淡金/蒸汽白系
		"gate": return Color(0.30, 0.24, 0.19)        # 深棕
		_: return Color(0.5, 0.5, 0.5)


func _physics_process(_delta: float) -> void:
	var player_inside := false
	for body in get_overlapping_bodies():
		if body.is_in_group("player"):
			player_inside = true
			break
	_hint_label.visible = player_inside
	_hint_label.text = hint
	var e_now: bool = Input.is_physical_key_pressed(KEY_E)
	if player_inside and e_now and not _e_was_pressed:
		interacted.emit(building_id)
	_e_was_pressed = e_now

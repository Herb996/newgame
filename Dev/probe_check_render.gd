extends Node
func _ready() -> void:
	var s = preload("res://Scripts/map_render_3d.gd")
	print("[Check] map_render_3d.gd 加载成功：", s)
	print("[Check] 类名：", s.get_class() if s.has_method("get_class") else "n/a")
	get_tree().quit(0)

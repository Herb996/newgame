extends SceneTree
## 探针：直接加载 Decor 贴图验证导入缓存是新是旧
## 新图：tree 90x144 / rock 48x44 / debris 44x37
## 旧图：tree 48x36 / rock 30x22 / debris 26x22

func _init() -> void:
	for f in ["tree_00", "rock_00", "debris_00"]:
		var p := "res://Assets/Art/Sprites/Decor/%s.png" % f
		var t := load(p) as Texture2D
		if t == null:
			print("[ProbeDecor] %s -> LOAD FAIL" % f)
		else:
			print("[ProbeDecor] %s -> %dx%d" % [f, t.get_width(), t.get_height()])
	quit(0)

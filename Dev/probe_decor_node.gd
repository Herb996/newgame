extends Node
## 场景探针：完整跑 generate()，检查 DecorLayer 里 Sprite2D 的纹理尺寸分布
## 用法：godot --headless --path . res://Dev/probe_decor_node.tscn

func _ready() -> void:
	var result := MapGenerator.generate()
	var root: Node2D = result.node
	var layer: Node = root.get_node_or_null("DecorLayer")
	if layer == null:
		print("[ProbeDecorNode] DecorLayer 不存在")
		get_tree().quit(1)
		return
	var seen := {}
	for c in layer.get_children():
		if c is Sprite2D and c.texture != null:
			var key := "%dx%d" % [c.texture.get_width(), c.texture.get_height()]
			seen[key] = int(seen.get(key, 0)) + 1
	print("[ProbeDecorNode] DecorLayer 子节点 ", layer.get_child_count())
	for k in seen:
		print("[ProbeDecorNode] 纹理 %s x %d 个" % [k, seen[k]])
	get_tree().quit(0)

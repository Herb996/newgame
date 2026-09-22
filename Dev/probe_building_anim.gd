extends Node
## ============================================================
## probe_building_anim — 无头验收「基地里的动画建筑真的在切帧」
##
## 采两次样：第二次的 frame 序号必须和第一次不同，否则说明 SpriteFrames
## 建出来了但没播（比如 play 没调 / fps=0 / 被暂停）。无头也能跑 ——
## 动画推进靠 _process，跟渲染驱动无关，--fixed-fps 保证帧间隔稳定。
##
## 用法：python tools/run_godot_headless.py _probe_building_anim.log \
##           Dev/probe_building_anim.tscn --fixed-fps 30 --quit-after 200
## ============================================================

const MAIN_SCENE := "res://Scenes/Main.tscn"


func _ready() -> void:
	# 出厂 config 的 auto_enter_run=true → 进基地立刻被拉进局、建筑被清空
	Config.set_override("debug.auto_enter_run", false)
	var main: Node = load(MAIN_SCENE).instantiate()
	add_child(main)
	await _wait(80)
	_dump("第一次采样")
	await _wait(45)
	_dump("第二次采样（frame 应与上次不同 = 动画在跑）")
	_probe_ghost(main)
	get_tree().quit(0)


## 重摆幽灵走的是 begin_reposition() → PlacementMode.draw_texture_rect()。
## 动画建筑没有 Body.texture，取错就是「右键重摆时幽灵是空的」——查一遍这个接口。
func _probe_ghost(main: Node) -> void:
	var bs := main.get_node_or_null("BaseSystem")
	if bs == null:
		print("[AnimProbe] !! 没找到 BaseSystem")
		return
	for id in ["quarry", "portal"]:
		var opt: Dictionary = bs.call("begin_reposition", id)
		var tex = opt.get("texture")
		var desc := "(null!)"
		if tex != null:
			var at := tex as AtlasTexture
			desc = "%s %s" % [at.atlas.resource_path.get_file() if at != null else tex.resource_path.get_file(),
					str(tex.get_size())]
		print("[AnimProbe] %-10s 重摆幽灵贴图 = %s，锚点数 = %d"
				% [id, desc, (opt.get("anchors", []) as Array).size()])
		bs.call("cancel_reposition", id)


func _dump(tag: String) -> void:
	print("[AnimProbe] === %s ===" % tag)
	for b in get_tree().get_nodes_in_group("buildings"):
		var id := str(b.get("building_id"))
		var anim := b.get_node_or_null("AnimBody") as AnimatedSprite2D
		if anim != null and anim.visible and anim.sprite_frames != null:
			var sf := anim.sprite_frames
			var f0: Texture2D = sf.get_frame_texture("idle", 0)
			print("[AnimProbe] %-10s 动画 frames=%d fps=%.1f frame=%d 播放中=%s 循环=%s 帧尺寸=%s scale=%.3f offset=%s"
					% [id, sf.get_frame_count("idle"), sf.get_animation_speed("idle"),
					   anim.frame, str(anim.is_playing()), str(sf.get_animation_loop("idle")),
					   str(f0.get_size() if f0 != null else Vector2.ZERO),
					   anim.scale.x, str(anim.offset)])
		else:
			var body := b.get_node_or_null("Body") as Sprite2D
			var tex := body.texture.resource_path.get_file() if body != null and body.texture != null else "(null!)"
			print("[AnimProbe] %-10s 静态 %s" % [id, tex])


func _wait(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame

extends Node
## Dev 探针 — 2D 玩家序列帧回归测试（临时，不属于游戏本体）
## 目的：PlayerAnimator 从「单帧」升级为「多帧序列帧」后，验证
##   1) walk 状态真的在按 fps 换贴图（不是只加载了第一帧）；
##   2) 朝向切换生效（down/up/left/right 取到不同帧）；
##   3) 未配帧的状态（attack 等）回退到 idle 帧，并仍然走程序化位移。

const PLAYER_ANIMATOR := preload("res://Scripts/player_animator.gd")


func _ready() -> void:
	# 保险丝：断言失败会中断 _ready，那就没人调 quit，进程会一直挂着
	var fuse := get_tree().create_timer(6.0)
	fuse.timeout.connect(_on_fuse)

	var sprite := Sprite2D.new()
	sprite.name = "Body"
	add_child(sprite)

	var a: RefCounted = PLAYER_ANIMATOR.new(sprite)
	a.load_from_config(Config.get_value("sprites", {}))

	# --- 1) walk 帧推进 ---
	var seen: Array = []
	var t := 0.0
	while t < 0.9:
		a.update(0.05, PLAYER_ANIMATOR.Anim.WALK, Vector2(1, 0))
		var p := ""
		if sprite.texture != null:
			p = sprite.texture.resource_path
		if seen.is_empty() or seen[seen.size() - 1] != p:
			seen.append(p)
		t += 0.05
	print("[ProbeAnim] walk(right) 贴图序列 %d 项：" % seen.size())
	for p in seen:
		print("   ", p)
	assert(seen.size() >= 3, "walk 序列帧没在播（只见到 %d 个贴图）：%s" % [seen.size(), str(seen)])
	assert(sprite.rotation == 0.0, "多帧状态不应再叠加程序化旋转（会和帧动作打架）")

	# --- 2) 朝向切换 ---
	a.update(0.05, PLAYER_ANIMATOR.Anim.WALK, Vector2(0, -1))
	var up_path := sprite.texture.resource_path
	print("[ProbeAnim] 朝上 →", up_path)
	assert(up_path.contains("walk_up"), "朝向切换失败：" + up_path)

	# --- 3) 未配帧状态回退 + 程序化运动 ---
	a.update(0.05, PLAYER_ANIMATOR.Anim.ATTACK, Vector2(1, 0))
	var atk_path := sprite.texture.resource_path
	print("[ProbeAnim] attack（无帧，应回退 idle）→", atk_path, " offset=", sprite.offset)
	assert(atk_path.contains("idle"), "attack 没回退到 idle：" + atk_path)
	assert(sprite.offset != Vector2(0.0, -24.0), "attack 应走程序化位移（前冲），offset 没变")

	print("[ProbeAnim] 验证全部通过：序列帧播放 / 朝向切换 / 缺帧回退均正常")
	get_tree().quit(0)


func _on_fuse() -> void:
	push_error("[ProbeAnim] 超时退出：多半是上面有断言失败中断了 _ready")
	get_tree().quit(2)

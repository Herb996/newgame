extends Node
## ============================================================
## shot_enemy_attack — 实拍：敌人进射程就出手 + 死亡画面
##
## 探针（probe_enemy_attack，56 项全绿）已经用数值证明"射程判定 / 冷却 / 前摇 /
## 掉落 / 死亡结算"都对。但用户报的原话是**观感**问题：「敌人贴到角色身上都不造成伤害」
## 「应该有攻击动作」「预期要有死亡画面」。数值绿不等于画面上真的在打人 ——
## 这张图专门看三件事：
##   1) 一坨敌人贴到身边 → 画面里有人正在挥砍（ATTACK 帧），不是原地罚站
##   2) 玩家血条真的在掉（前摇走完那一下）
##   3) 打死一只之后，画面上有"倒下"的过程（有 dead 帧的兵种播死帧；
##      其余兵种是透明+缩小+下沉的淡出），不是啪一下被抠掉
## 每张图旁边都打印：兵种 id、与玩家的圆心距、在不在射程、_attack_timer、动画状态。
##
## 用法（**必须开窗**，无头是 dummy 驱动、viewport 贴图恒空）：
##   python tools/run_probe.py _shot_enemy_attack.log Dev/shot_enemy_attack.tscn --window
##
## ⚠ 会走一次 _on_launch，开跑备份 user://save.json、收尾原样还原。
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const SAVE_PATH := "user://save.json"
const CROWD := 6            # 贴身围上来几个

var _save_backup := ""
var _save_existed := false
var _n := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()
	Config.set_override("display.window_mode", "windowed")
	Config.set_override("display.resolution", [1280, 720])
	Config.set_override("debug.auto_enter_run", false)
	# 玩家别还手：自动交战会把这坨人秒掉，就没机会看他们挥砍了
	Config.set_override("combat.auto_attack.enabled", false)
	Config.set_override("animals.count", 0)

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	main.call("_on_launch", [{"id": "spearman", "name": "独行"}])
	var waited := 0
	while get_tree().get_nodes_in_group("player").size() < 1 and waited < 400:
		await get_tree().process_frame
		waited += 1
	await _frames(60)

	var p: Node = get_tree().get_first_node_in_group("player")
	if p == null:
		print("[ShotAtk] !! 出击后没有角色")
		_finish(1)
		return
	var enemies: Array = _living_enemies()
	print("[ShotAtk] 场上活敌 %d 个，射程 %.0f px（分离层最小间距 %.0f px）" % [
			enemies.size(), _range_of(enemies), _sep_gap()])
	if enemies.size() < CROWD:
		print("[ShotAtk] !! 敌人不够 %d 个" % CROWD)
		_finish(1)
		return

	# ---- 1) 贴到身边：该出手了 ----
	# 距离取射程的 0.7 倍（而不是分离层顶住的那个间距）：这样"在射程内"这件事
	# 与分离层互不干扰，图里看到的挥砍只归出手判定管。
	var ring := _range_of(enemies) * 0.7
	var crowd: Array = []
	for i in range(CROWD):
		var ang := float(i) * TAU / float(CROWD)
		(enemies[i] as Node2D).global_position = p.global_position \
				+ Vector2(cos(ang), sin(ang)) * ring
		crowd.append(enemies[i])
	# 基线必须在"贴上去之前"取：等第一波挥砍落地之后再读，血已经掉完，
	# 量出来就是"没掉血"的假红灯（第一版就栽在这）。
	var hp_before := int(p.hp)
	await _pframes(4)
	_print_state("出手瞬间 t≈0.07s", crowd, p)
	await _shot(p, "atk_t0")
	await _pframes(6)
	_print_state("前摇中段 t≈0.17s", crowd, p)
	await _shot(p, "atk_t017")

	# ---- 2) 伤害真的落地 ----
	await _pframes(10)
	var hp_after := int(p.hp)
	print("[ShotAtk] 玩家 HP %d → %d（掉了 %d）" % [hp_before, hp_after, hp_before - hp_after])
	if hp_after == hp_before:
		# 六只同时起手，玩家无敌帧（0.4s）会吃掉同波的其余几下 → 再等一整轮冷却
		await _pframes(80)
		hp_after = int(p.hp)
		print("[ShotAtk] 再等 1.3s（第二波）→ HP %d → %d" % [hp_before, hp_after])
	print("[ShotAtk] 掉血 %s —— 用户报的「贴上去不掉血」%s" % [
			"有" if hp_after < hp_before else "无",
			"已修复" if hp_after < hp_before else "仍在复现"])
	_print_state("命中后 t≈0.33s", crowd, p)
	await _shot(p, "atk_hit")

	# ---- 3) 死亡画面：优先挑带 dead 帧的兵种（素材包里目前只有 ep_troll）----
	var with_frames: Array = []
	var plain: Array = []
	for e in _living_enemies():
		if _death_frame_count(e) > 0:
			with_frames.append(e)
		else:
			plain.append(e)
	print("[ShotAtk] 带死亡帧的敌人：%d 只；只有淡出的：%d 只" % [with_frames.size(), plain.size()])
	if with_frames.is_empty():
		print("[ShotAtk] 场上这一局没刷出带死亡帧的兵种 → 只拍淡出那条分支")
	var target: Node = with_frames[0] if not with_frames.is_empty() else (
			plain[0] if not plain.is_empty() else enemies[0])
	(target as Node2D).global_position = p.global_position + Vector2(ring, 0.0)
	await _pframes(2)
	print("[ShotAtk] 死亡对象 = %s，死亡帧 %d 张，dead_fps=%.1f，淡出 %.2fs" % [
			str(target.get("type_id")), _death_frame_count(target),
			float(Config.get_value("enemy.death_fps", 8.0)),
			float(Config.get_value("enemy.death_fade_seconds", 0.45))])
	target.take_damage(99999)
	if _death_frame_count(target) > 0:
		await _pframes(20)          # 0.33s → 第 2~3 张死亡帧
		await _shot(p, "death_frame")
		print("[ShotAtk] 死亡中：贴图已换成 %s" % str(_body_texture_name(target)))
		await _pframes(40)          # 再往后一点，仍在播死帧（10 帧 @8fps = 1.25s）
		await _shot(p, "death_frame2")
	else:
		await _pframes(12)          # 淡出 0.45s 的中段
		await _shot(p, "death_fade")
		print("[ShotAtk] 淡出中：modulate.a=%.2f scale=%s" % [
				_body_modulate_alpha(target), str(_body_scale(target))])
	# 淡出/死帧播完之后必须真的离场（不留尸体挡分离层）
	var gone := 0
	while is_instance_valid(target) and gone < 240:
		await get_tree().physics_frame
		gone += 1
	print("[ShotAtk] 尸体离场用了 %d 帧（%.2fs）→ %s" % [gone, float(gone) / 60.0,
			"已移除" if not is_instance_valid(target) else "仍在场景里（不该）"])
	await _shot(p, "after_death")

	var bad := 0 if hp_after < hp_before else 3
	_finish(bad)


# ------------------------------------------------------------

func _living_enemies() -> Array:
	var out: Array = []
	for e in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e) and not bool(e.get("_dying")):
			out.append(e)
	return out


func _range_of(enemies: Array) -> float:
	if enemies.is_empty():
		return float(Config.get_value("enemy.attack.range_px", 52.0))
	return float(enemies[0].attack_range_px())


func _sep_gap() -> float:
	var rr: Dictionary = Config.get_value("combat.separation.radius_px", {})
	return float(rr.get("enemies", 22.0)) + float(rr.get("player", 20.0))


func _death_frame_count(e: Node) -> int:
	var v = e.get("_death_frames")
	return v.size() if (v is Array) else 0


func _body(e: Node) -> Node:
	return e.get("_body")


func _body_texture_name(e: Node) -> String:
	var b = _body(e)
	if b == null:
		return "?"
	var tex = b.get("texture")
	return str(tex.resource_path.get_file()) if tex != null else "null"


func _body_modulate_alpha(e: Node) -> float:
	var b = _body(e)
	return float(b.modulate.a) if b != null else 1.0


func _body_scale(e: Node) -> Vector2:
	var b = _body(e)
	return (b.scale as Vector2) if b != null else Vector2.ONE


## 逐个敌人报一行：图上"谁在挥、谁没挥"必须能用数字对上
func _print_state(tag: String, list: Array, p: Node) -> void:
	print("[ShotAtk] ---- %s（玩家 HP %d）----" % [tag, int(p.hp)])
	for e in list:
		if not is_instance_valid(e):
			continue
		var d: float = (e as Node2D).global_position.distance_to((p as Node2D).global_position)
		print("[ShotAtk]   %-16s 距离=%5.1f 在射程=%-5s timer=%.2f cd=%.2f 状态=%s" % [
				str(e.get("type_id")), d, str(bool(e.in_attack_range())),
				float(e.get("_attack_timer")), float(e.get("_attack_cooldown")),
				_anim_name(e)])
	var swinging := 0
	for e in list:
		if is_instance_valid(e) and float(e.get("_attack_timer")) > 0.0:
			swinging += 1
	print("[ShotAtk]   → %d / %d 只正在播攻击动作" % [swinging, list.size()])


func _anim_name(e: Node) -> String:
	var v = e.get("_anim_state")
	if v == null:
		return "?"
	return str(PlayerAnimator.Anim.find_key(int(v)))


## 以角色为中心裁 480x480（与 shot_dead_combat 同一套）
func _shot(p: Node, tag: String) -> void:
	_n += 1
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[ShotAtk] !! viewport 贴图为空（忘了 --window？）")
		return
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	var w := src.get_width()
	var h := src.get_height()
	var sp: Sprite2D = p.get_node_or_null("Body")
	var c := Vector2(w * 0.5, h * 0.5)
	if sp != null:
		c = sp.get_global_transform_with_canvas().get_origin()
	var half := 240
	var box := Rect2i(int(c.x) - half, int(c.y) - half, half * 2, half * 2)
	box.position.x = clampi(box.position.x, 0, maxi(w - 8, 0))
	box.position.y = clampi(box.position.y, 0, maxi(h - 8, 0))
	box.size.x = mini(box.size.x, w - box.position.x)
	box.size.y = mini(box.size.y, h - box.position.y)
	var out := Image.create(box.size.x, box.size.y, false, Image.FORMAT_RGBA8)
	out.blit_rect(src, box, Vector2i.ZERO)
	var path := "%s/enemy_attack_%02d_%s.png" % [OUT_DIR, _n, tag]
	var err := out.save_png(path)
	print("[ShotAtk] %s -> %s err=%d" % [tag, path, err])


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _pframes(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame


func _finish(code: int) -> void:
	_restore_save()
	get_tree().quit(code)


func _backup_save() -> void:
	_save_existed = FileAccess.file_exists(SAVE_PATH)
	if _save_existed:
		_save_backup = FileAccess.get_file_as_string(SAVE_PATH)


func _restore_save() -> void:
	if _save_existed:
		var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_save_backup)
			f.close()
	elif FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))

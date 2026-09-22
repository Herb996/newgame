extends Node
## ============================================================
## shot_skills — 实拍：技能在真窗口里到底画出了什么（2026-09-21）
##
## 为什么还要这张：probe_skills 的 96 项断言证明的是**链路与表自洽**（id 解析得出来、
## 冷却会转、状态挂得上、伤害算得对、撤离才写档）。它证明不了"这一帧屏幕上看得见" ——
## tint 把 alpha 乘成 0、FxRing 挂错层被地面盖住、弹道 modulate 写成透明色，
## 探针全是绿的而画面是空的。技能这一层尤其容易全绿却空画，因为它九成的表现
## 就是特效本身。
##
## 十三张图各管一件事（前缀 sk_）：
##   sk_frost_cast     冰霜新星的施法条带（slam_ring 被水系 fx_tint 染成冰蓝）
##   sk_frost_ring     地面上那圈冲击环 —— 范围这一属性的唯一可见形式
##   sk_frost_frozen   冻住的敌人：模型发冰蓝 + 站着不动（halt_ai + speed_mult 0）
##   sk_ember_cast     余烬弹的施法条带（cast_staff 被火系染色）
##   sk_ember_shot     弹道在飞：橙色的箭（与普攻那支白箭一眼分得开）
##   sk_ember_burning  烧起来的敌人：发红 + 血条比命中时短一截（DoT 每 0.5 秒一跳）
##   sk_gear_guard     齿轮护盾：残血时**自动**开盾的那一下（这一段不手动放，
##                     手动那条路 frost/ember 已经验过了，这里要的是自动门槛的画面证据）
##   sk_falling_rocks_cast / _ring   落石：bash_rock 条带 + 140px 那圈，靶子被推开 46px
##   sk_quake_split_cast / _ring     地裂：190px 那圈（半径最大的一招），推开 78px
##   sk_grimoire / sk_grimoire_near   魔法书本体：图标 + 柔光圈，第二张带人当尺寸参照
##
## 判据与 shot_fx 同一条规矩：**不猜时间**，逐帧轮询到"要拍的那样东西真的在场上"
## 才截；没等到就是真没有，写进 _missed 并以退出码 3 收场，不交空白图。
##
## 用法（**必须开窗**，无头是 dummy 驱动、viewport 贴图恒空）：
##   python tools/run_probe.py _shot_skills.log Dev/shot_skills.tscn --window
##
## ⚠ 会走一次 _on_launch，开跑备份 user://save.json、收尾原样还原。
## ⚠ 靶子是把场上真实敌人挪到角色脚边（不造新节点）；魔法书同理挪过来并手动
##   visible=true —— 出图时 --no-fog 关掉了雾的显隐管线，LootNode 在 _ready 里
##   把自己藏了，没人替它点亮。拍的是真节点真贴图，只有位置是摆的。
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const SAVE_PATH := "user://save.json"
## 三招都喂到 Lv3：等级成长在画面上是有读据的（冰霜新星 Lv3 的地面圈比 Lv1 大 16px），
## 顺便证明"注入等级"这条链在真局里也通。
const LEVELS := {"frost_nova": 3, "ember_shot": 3, "gear_guard": 3,
		"falling_rocks": 3, "quake_split": 3}
## 灼烧那张要看到血条掉：靶子血量太高（999999）则 DoT 的 4~12 点根本推不动指针。
## 所以这一段用一只**没被钉高**、但出厂生命 ≥ BURN_MIN_HP 的厚血敌人。
const BURN_MIN_HP := 100.0
## 残血开盾的钉血比例：要低于 gear_guard 的 auto_cast_hp_below（0.55）才叫得动自动那一档
const GUARD_HP_FRAC := 0.4

var _save_backup := ""
var _save_existed := false
var _n := 0
var _player: Node2D = null
var _ss: SkillSystem = null
## 角色钉在哪个世界坐标（镜头稳 = 裁图中心稳），INF = 不钉
var _pin := Vector2.INF
## >0 时每次 _keep_alive 把血量钉成 上限×这个数（护盾那一段要一直残血才叫得动自动）
var _hp_frac := 0.0
var _missed: Array = []
## 为了这一发被挪开的路人：{node, from}，拍完原样放回
var _displaced: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()
	Config.set_override("display.window_mode", "windowed")
	Config.set_override("display.resolution", [1280, 720])
	Config.set_override("debug.auto_enter_run", false)
	Config.set_override("camera.edge_pan_enabled", false)
	Config.set_override("animals.count", 0)

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	main.set("_no_fog", true)
	add_child(main)
	await _frames(30)
	main.call("_on_launch", [{"id": "spearman", "name": "独行"}])
	var waited := 0
	while get_tree().get_nodes_in_group("player").is_empty() and waited < 600:
		await get_tree().process_frame
		waited += 1
	await _frames(60)

	var p = get_tree().get_first_node_in_group("player")
	if p == null or not (p is Node2D):
		print("[ShotSkill] !! 出击后没有角色")
		_finish(1)
		return
	_player = p as Node2D
	_ss = _player.call("skills") as SkillSystem
	_player.call("set_auto_attack", false)      # 普攻别抢戏：这一组图只该有技能特效
	_ss.set_known(LEVELS)
	_ss.reset()
	_pin = _player.global_position
	print("[ShotSkill] 角色就位：%s｜已注入 %s｜视野 %.0f｜地面圈时长 %.2fs" % [
			str(_player.get("character_name")), str(LEVELS),
			float(_player.call("vision_px")),
			SkillSystem.default_val("shock_ring_seconds", 0.5)])

	await _frost_phase()
	await _ember_phase()
	await _guard_phase()
	await _knockback_phase()
	await _grimoire_phase()

	print("[ShotSkill] 共出图 %d 张；缺失 %s" % [_n, "无" if _missed.is_empty() else str(_missed)])
	_finish(0 if _missed.is_empty() else 3)


# ------------------------------------------------------------
# 冰霜新星：aoe_self（施法条带 + 地面圈 + 冻结染色）
# ------------------------------------------------------------
func _frost_phase() -> void:
	var id := "frost_nova"
	var d := SkillSystem.def_of(id)
	var radius := _ss.radius_of(id)
	var targets := _stage_targets(2, radius * 0.5)
	if targets.size() < 2:
		_missed.append("frost_nova（场上凑不到两个靶子）")
		return
	# 靶子一放下立刻手动抢放，中间不 await：自动那一档的扫描间隔是 0.15 秒（≈9 物理帧），
	# 多等几帧它就可能先把这一发放掉，把后面所有等待都推到冷却末尾。
	_ss.reset()
	var cast_now := _ss.cast(id)
	print("[ShotSkill] ---- %s Lv%d（伤害 %.0f，半径 %.0f，冷却 %.2fs，冻结 %.2fs）手动放=%s ----" % [
			id, _ss.level_of(id), _ss.damage_of(id), radius, _ss.cooldown_of(id),
			float(UnitStatus.def_of(str(d.get("status", ""))).get("duration_seconds", 0.0)),
			str(cast_now)])
	var fx := await _wait_fx(str(d.get("fx_cast", "")), 240, _player, 200.0)
	if fx == null:
		_missed.append("frost_nova 施法条带 %s" % str(d.get("fx_cast", "")))
	else:
		print("[ShotSkill]   tint=%s → 实际 modulate=%s" % [str(d.get("element")),
				str((fx as CanvasItem).modulate)])
		await _shot("sk_frost_cast", fx as Node2D)
	var ring := await _wait_ring(radius, 90)
	if ring == null:
		_missed.append("frost_nova 地面冲击环")
	else:
		print("[ShotSkill]   冲击环：配置半径 %.0f，扩散进度 %.0f%%，颜色 %s" % [
				float(ring.get("radius")), 100.0 * float(ring.get("_t")) / maxf(
						0.05, float(ring.get("duration"))), str((ring.get("ring_color") as Color))])
		await _shot("sk_frost_ring", ring as Node2D)
	var frozen: Array = []
	for item in targets:
		var t: Node2D = item["node"]
		if _has_status(t, "frozen"):
			frozen.append(t)
	var first: Node = frozen[0] if not frozen.is_empty() else null
	print("[ShotSkill]   冻住 %d/%d 只；摘要「%s」" % [frozen.size(), targets.size(),
			_status_summary(first)])
	if frozen.is_empty():
		_missed.append("frost_nova 冻结状态")
	else:
		await _shot("sk_frost_frozen", frozen[0] as Node2D)
	_restore_targets(targets)


# ------------------------------------------------------------
# 余烬弹：projectile（自带弹道表 + 灼烧 DoT。命中点的 44px 溅射由探针逐项断言，
# 画面上一圈柔光分不清溅射与命中特效，所以这几张不声称拍到溅射）
# ------------------------------------------------------------
func _ember_phase() -> void:
	var id := "ember_shot"
	var d := SkillSystem.def_of(id)
	var rng := _ss.range_of(id)
	# 靶子放在射程外圈（0.85）：弹道要飞得够久才拍得到 —— 这一发只有 0.3 秒寿命，
	# 贴着人脸等于拍到一支刚出膛就已消失的箭。
	var burn := _staged_burn_target(rng * 0.85)
	if burn == null:
		_missed.append("ember_shot（没有出厂生命 ≥ %d 的敌人可当灼烧靶子）" % int(BURN_MIN_HP))
		return
	_ss.reset()
	var cast_now := _ss.cast(id)
	var pc: Dictionary = d.get("projectile", {})
	print("[ShotSkill] ---- %s Lv%d（伤害 %.0f，射程 %.0f，溅射 %.0f，弹道 modulate=%s）手动放=%s ----" % [
			id, _ss.level_of(id), _ss.damage_of(id), rng,
			SkillSystem.param(id, "aoe_radius_px", 0.0), str(pc.get("modulate", "")),
			str(cast_now)])
	var fx := await _wait_fx(str(d.get("fx_cast", "")), 240, _player, 200.0)
	if fx == null:
		_missed.append("ember_shot 施法条带 %s" % str(d.get("fx_cast", "")))
	else:
		print("[ShotSkill]   tint=%s → 实际 modulate=%s" % [str(d.get("element")),
				str((fx as CanvasItem).modulate)])
		await _shot("sk_ember_cast", fx as Node2D)
	var proj := await _wait_projectile(50.0, 240)
	if proj == null:
		_missed.append("ember_shot 弹道在飞（技能弹道没有专属 id，按 status_id 认）")
	else:
		var spr: CanvasItem = proj.get_node_or_null("Icon") as CanvasItem
		var icon_mod := "-" if spr == null else str(spr.modulate)
		print("[ShotSkill]   弹道：%s，染色 %s，离手 %.0f px" % [proj.get_class(), icon_mod,
				_player.global_position.distance_to(proj.global_position)])
		await _shot("sk_ember_shot", proj)
	var hit := await _wait_status(burn, "burning", 300)
	var hp_now := int(burn.get("hp"))
	print("[ShotSkill]   灼烧：命中后 hp %d / %d，状态摘要「%s」，跳伤间隔 %.1fs × %d 点" % [
			hp_now, int(burn.get("max_hp")), _status_summary(burn),
			float(UnitStatus.def_of("burning").get("tick_interval_seconds", 0.0)),
			int(UnitStatus.def_of("burning").get("damage_per_tick", 0))])
	if not hit:
		_missed.append("ember_shot 灼烧状态没挂上")
	else:
		# 再等一跳：DoT 的可见证据是"血条在继续掉"，只拍到命中那一刀等于没验到跳伤
		var before := hp_now
		var ticked := false
		for _i in range(90):
			await get_tree().physics_frame
			_keep_alive()
			if int(burn.get("hp")) < before:
				ticked = true
				break
		print("[ShotSkill]   一跳之后 hp %d → %d（灼烧真的在持续掉血：%s）" % [
				before, int(burn.get("hp")), str(ticked)])
		if not ticked:
			_missed.append("ember_shot 灼烧没有持续掉血")
		await _shot("sk_ember_burning", burn as Node2D)
	_restore_displaced()


# ------------------------------------------------------------
# 齿轮护盾：buff（**只走自动那一档**，验 auto_cast_hp_below 真的会在屏幕上开盾）
# ------------------------------------------------------------
func _guard_phase() -> void:
	var id := "gear_guard"
	var d := SkillSystem.def_of(id)
	_hp_frac = GUARD_HP_FRAC
	_ss.reset()
	print("[ShotSkill] ---- %s Lv%d（减伤 %.0f%%，持续 %.1fs，残血阈值 %.0f%%，血量钉在 %.0f%%）等它自己开 ----" % [
			id, _ss.level_of(id), SkillSystem.param(id, "damage_reduction") * 100.0,
			float(d.get("buff_duration_seconds", 0.0)),
			float(d.get("auto_cast_hp_below", 0.0)) * 100.0, GUARD_HP_FRAC * 100.0])
	await _frames(2)
	_keep_alive()
	print("[ShotSkill]   自动门槛此刻开不开：%s" % str(_ss.auto_wants(id)))
	var fx := await _wait_fx(str(d.get("fx_cast", "")), 240, _player, 200.0)
	if fx == null:
		_missed.append("gear_guard 自动开盾（%s 没出现）" % str(d.get("fx_cast", "")))
	else:
		await _shot("sk_gear_guard", fx as Node2D)
		print("[ShotSkill]   身上状态：%s｜承伤乘数 %.2f" % [_status_summary(_player),
				_status_mult(_player)])
	_hp_frac = 0.0


# ------------------------------------------------------------
# 土系两招：aoe_self + 击退。这一段要的画面证据不是特效好不好看，而是
# 「真实敌人被 apply_knockback 挪动了」—— 探针里的靶子是自己记的数，这里量的是场上节点。
# 击退在 cast() 那一句里当场改坐标（同步），所以位移必须在同一帧量完，再 await 等条带。
# ------------------------------------------------------------
func _knockback_phase() -> void:
	for raw_id in ["falling_rocks", "quake_split"]:
		var id := str(raw_id)
		var d := SkillSystem.def_of(id)
		var kb := float(d.get("knockback_px", 0.0))
		var radius := _ss.radius_of(id)
		var targets := _stage_targets(2, radius * 0.55)
		if targets.is_empty():
			_missed.append("%s：场上凑不到靶子" % id)
			continue
		var before: Array = []
		for item in targets:
			before.append((item["node"] as Node2D).global_position)
		_ss.reset()
		var cast_now := _ss.cast(id)
		print("[ShotSkill] ---- %s Lv%d（伤害 %.0f，半径 %.0f，冷却 %.2fs，击退 %.0fpx，噪音 %.0f）手动放=%s ----" % [
				id, _ss.level_of(id), _ss.damage_of(id), radius, _ss.cooldown_of(id),
				kb, SkillSystem.param(id, "noise"), str(cast_now)])
		var pushed := 0
		for i in range(targets.size()):
			var t: Node2D = targets[i]["node"]
			var delta: Vector2 = t.global_position - (before[i] as Vector2)
			var outward := (before[i] as Vector2) - _pin
			var along := delta.normalized().dot(outward.normalized()) if delta.length() > 0.01 \
					and outward.length() > 0.01 else 0.0
			if absf(delta.length() - kb) < 1.0 and along > 0.9:
				pushed += 1
			print("[ShotSkill]   %s 被推开 %.1fpx（表里 %.0f），方向偏离 %.0f°，身上「%s」" % [
					str(t.get("type_id")), delta.length(), kb,
					rad_to_deg(acos(clampf(along, -1.0, 1.0))), _status_summary(t)])
		if pushed == 0:
			_missed.append("%s 没把任何人推开" % id)
		var fx := await _wait_fx(str(d.get("fx_cast", "")), 240, _player, radius + 80.0)
		if fx == null:
			_missed.append("%s 施法条带 %s" % [id, str(d.get("fx_cast", ""))])
		else:
			print("[ShotSkill]   tint=%s → 实际 modulate=%s" % [str(d.get("element")),
					str((fx as CanvasItem).modulate)])
			await _shot("sk_%s_cast" % id, fx as Node2D)
		var ring := await _wait_ring(radius, 90)
		if ring == null:
			_missed.append("%s 地面冲击环" % id)
		else:
			await _shot("sk_%s_ring" % id, ring as Node2D)
		_restore_targets(targets)


# ------------------------------------------------------------
# 魔法书：真 LootNode 摆到角色脚边（图标 + 柔光圈 + 人当尺寸参照）
# ------------------------------------------------------------
func _grimoire_phase() -> void:
	var book: Node2D = null
	for n in get_tree().get_nodes_in_group("loot_nodes"):
		if is_instance_valid(n) and bool(n.get("_grimoire")):
			book = n as Node2D
			break
	if book == null:
		_missed.append("场上没有魔法书（loot_system 没生成？nodes_per_run=%d）"
				% int(Config.get_value("skills.grimoire.nodes_per_run", 0)))
		return
	# --no-fog 关掉了雾的实体显隐管线，而 LootNode 在 _ready 里把自己藏了 —— 出图专用补一句。
	book.visible = true
	# 放在拾取圈外（loot.pickup_radius_px 通常 20px），不然下一帧就被吃掉，图就没了
	var stand := float(Config.get_value("loot.pickup_radius_px", 20.0)) + 42.0
	book.global_position = _pin + Vector2(stand, stand * 0.42)
	await _frames(6)
	print("[ShotSkill] ---- 魔法书：%s｜图标 %s｜圈色 %s｜离手 %.0f px（拾取半径 %.0f，故意站在圈外）----" % [
			str(Config.get_value("skills.grimoire.name", "")),
			str(Config.get_value("skills.grimoire.sprite", "")).get_file(),
			str(Config.get_value("skills.grimoire.color", "")),
			book.global_position.distance_to(_pin),
			float(Config.get_value("loot.pickup_radius_px", 20.0))])
	await _shot("sk_grimoire", book, 110)
	await _shot("sk_grimoire_near", book)
	# 顺手验一次"走进圈里当场学会"：把书挪到脚下，让 LootNode 自己的物理帧判定触发
	_ss.set_known({})
	book.global_position = _pin
	await _frames(10)
	print("[ShotSkill]   踩上去之后学会：%s（书还在场上=%s）" % [str(_ss.known),
			str(is_instance_valid(book) and not book.is_queued_for_deletion())])
	if _ss.known.is_empty():
		_missed.append("踩上魔法书没学会任何一招")


# ------------------------------------------------------------
# 工具
# ------------------------------------------------------------

## 把 n 只真实敌人挪到角色四周当靶子（不新建节点：新建的敌人没有 setup 过的贴图与兵种数据）。
## 血量钉高是 shot_fx 那条老规矩 —— 一场拍摄要等上千帧，靶子先被打死就拍不到了。
## 灼烧那一段单独用 _staged_burn_target（它要保留出厂血量，否则血条不会动）。
func _stage_targets(n: int, dist: float) -> Array:
	var out: Array = []
	var ang := 0.0
	for e in get_tree().get_nodes_in_group("enemies"):
		if out.size() >= n:
			break
		if not (e is Node2D) or not is_instance_valid(e) or bool(e.get("_dying")):
			continue
		var t := e as Node2D
		var hp := int(t.get("hp"))
		if hp <= 0:
			continue
		out.append({"node": t, "from": t.global_position,
				"hp0": hp, "max0": int(t.get("max_hp"))})
		t.set("max_hp", 999999)
		t.set("hp", 999999)
		t.global_position = _pin + Vector2(cos(ang), sin(ang) * 0.6) * dist
		ang += TAU / maxf(1.0, float(n))
	return out


func _restore_targets(list: Array) -> void:
	for item in list:
		var t: Node2D = item["node"]
		if not is_instance_valid(t):
			continue
		t.global_position = item["from"] as Vector2
		t.set("max_hp", int(item["max0"]))
		t.set("hp", int(item["hp0"]))


## 灼烧靶子：出厂生命够厚的一只，血**不**钉高 —— 要的就是血条真的往下走。
## 出手方向认的是"这一招射程内最近的那只"（SkillSystem.aim_dir，与普攻的锁无关），
## 所以顺手把比靶子更近的路人挪远一点：上一版冰霜那两只还站在 64px 处，这一发就照着
## 它们飞了，照片里的靶子身上一个状态都没有。
func _staged_burn_target(dist: float) -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for e in get_tree().get_nodes_in_group("enemies"):
		if not (e is Node2D) or not is_instance_valid(e) or bool(e.get("_dying")):
			continue
		var t := e as Node2D
		if float(int(t.get("max_hp"))) < BURN_MIN_HP or int(t.get("hp")) <= 0:
			continue
		var d := t.global_position.distance_to(_pin)
		if d < best_d:
			best_d = d
			best = t
	if best == null:
		return null
	for e in get_tree().get_nodes_in_group("enemies"):
		if not (e is Node2D) or not is_instance_valid(e) or e == best:
			continue
		var p := e as Node2D
		if p.global_position.distance_squared_to(_pin) >= dist * dist:
			continue
		var from := p.global_position
		var away := from - _pin
		_displaced.append({"node": p, "from": from})
		p.global_position = _pin + (Vector2.RIGHT if away.length() < 1.0
				else away.normalized()) * dist * 2.5
	best.set("hp", int(best.get("max_hp")))
	best.global_position = _pin + Vector2(dist, dist * 0.35)
	print("[ShotSkill]   灼烧靶子：%s（HP %d）站到 %.0f px 处；为它挪开路人 %d 只" % [
			str(best.get("type_id")), int(best.get("hp")), dist, _displaced.size()])
	return best


func _restore_displaced() -> void:
	for item in _displaced:
		var p: Node2D = item["node"]
		if is_instance_valid(p):
			p.global_position = item["from"] as Vector2
	_displaced = []


func _statuses_of(node: Node):
	if node == null or not is_instance_valid(node):
		return null
	return node.get("_statuses")


func _has_status(node: Node, id: String) -> bool:
	var st = _statuses_of(node)
	return st != null and bool(st.call("has", id))


## 逐帧等到某只身上挂上某个状态（DoT / 冻结都是"下一帧才挂上"的，别猜）
func _wait_status(node: Node, id: String, max_frames: int) -> bool:
	for _i in range(max_frames):
		if _has_status(node, id):
			return true
		await get_tree().physics_frame
		_keep_alive()
	return _has_status(node, id)


func _status_summary(node: Node) -> String:
	var st = _statuses_of(node)
	return "无" if st == null else str(st.call("summary"))


func _status_mult(node: Node) -> float:
	var st = _statuses_of(node)
	return 1.0 if st == null else float(st.call("damage_taken_mult"))


## 等地面那圈冲击环：按"配置半径"认（噪声波纹也用 FxRing，但半径来自噪音表，撞不上）
func _wait_ring(want_radius: float, max_frames: int) -> Node2D:
	for _i in range(max_frames):
		await get_tree().physics_frame
		_keep_alive()
		var r := _find_ring(want_radius)
		if r == null:
			continue
		var dur := maxf(0.05, float(r.get("duration")))
		if float(r.get("_t")) / dur >= 0.3:
			return r       # 已经扩到三成：这时候圈的最大、最清楚
	print("[ShotSkill] !! 没等到半径 %.0f 的地面冲击环" % want_radius)
	return null


func _find_ring(want_radius: float) -> Node2D:
	var world := _player.get_parent()
	if world == null:
		return null
	for n in world.get_children():
		if not (n is Node2D) or not is_instance_valid(n) or n.is_queued_for_deletion():
			continue
		var r = n.get("radius")
		var c = n.get("ring_color")
		if r is float and c is Color and absf(float(r) - want_radius) <= 1.0:
			return n as Node2D
	return null


## 等那颗在飞的技能弹道。弹道没有组、也没有专属 id，认它身上的 status_id：
## 普攻那支箭这个字段是空的，所以"有 burning"就是技能那一发。
func _wait_projectile(min_travel: float, max_frames: int) -> Node2D:
	for _i in range(max_frames):
		var p := _flying_projectile()
		if p != null and p.global_position.distance_to(_player.global_position) >= min_travel:
			return p
		await get_tree().physics_frame
		_keep_alive()
	print("[ShotSkill] !! 没等到飞行中的技能弹道")
	return null


func _flying_projectile() -> Node2D:
	var world := _player.get_parent()
	if world == null:
		return null
	for n in world.get_children():
		if not (n is Node2D) or not is_instance_valid(n) or n.is_queued_for_deletion():
			continue
		var sid = n.get("_status_id")
		# 必须是"有且是字符串"：get() 对不存在的属性返回 null，而 str(null) 是 "<null>"
		# 不等于空串 —— 不这么挡，敌人和资源点都会被当成弹道。
		if sid is String and sid != "":
			return n as Node2D
	return null


## 拍摄期间角色必须死不了，也要站得住：整组图要跑上千帧，镜头是插值跟角色的，
## 角色半路被打死或者走开了，后一半的裁图中心就落在空地上（shot_fx 踩过同一个坑）。
func _keep_alive() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var frac := 1.0 if _hp_frac <= 0.0 else _hp_frac
	_player.set("hp", maxi(1, int(float(_player.get("max_hp")) * frac)))
	_player.call("stop_moving")
	_player.call("clear_move_target")
	_player.global_position = _pin


## 逐帧轮询场上 fx_sprite，等"要的那条特效"真的出现且播到前段（第 0 帧往往还没张开）。
## 抄自 shot_fx，只留这一张图用得上的部分。
func _wait_fx(id: String, max_frames: int, near: Node2D, radius: float) -> Node:
	var seen := {}
	for _i in range(max_frames):
		await get_tree().physics_frame
		_keep_alive()
		for n in get_tree().get_nodes_in_group(&"fx_sprite"):
			if not is_instance_valid(n) or n.is_queued_for_deletion():
				continue
			var tag := _fx_tag(n)
			seen[tag] = int(seen.get(tag, 0)) + 1
			if tag != id:
				continue
			if near != null and is_instance_valid(near) \
					and (n as Node2D).global_position.distance_to(near.global_position) > radius:
				continue
			var want_frame: int = int(round(float(n.get("frames")) * 0.3))
			if int(n.get("frame")) > want_frame + 2:
				continue
			return n
	print("[ShotSkill] !! %d 帧内没等到「%s」；期间场上出现过的条带 = %s" % [
			max_frames, id, str(seen)])
	return null


func _fx_tag(n: Node) -> String:
	var tex = n.get("texture")
	if tex == null:
		return "?"
	return str((tex as Texture2D).resource_path.get_file().get_basename())


## 以 anchor 为中心裁 half×half 的窗口画面（half 小 = 放大看细节，魔法书那张 40px 图标需要）
func _shot(tag: String, anchor: Node2D = null, half: int = 280) -> void:
	_n += 1
	var at := Vector2.ZERO
	var has_at := false
	if anchor != null and is_instance_valid(anchor):
		at = anchor.global_position
		has_at = true
	# 先确认锚点已经在屏幕上再截：720 高的视口里"离边 300px"那套要求会把重试烧光，
	# 而 0.3 秒的条带等不起重试 —— 只要求 40px 边距，偏一点让下面的裁框自己夹。
	var settled := false
	var c := Vector2.ZERO
	for _s in range(4):
		var vp := get_viewport()
		if vp == null:
			break
		if not has_at:
			settled = true
			break
		c = vp.get_canvas_transform() * at
		var vs := vp.get_visible_rect().size
		if c.x > 40.0 and c.x < vs.x - 40.0 and c.y > 40.0 and c.y < vs.y - 40.0:
			settled = true
			break
		await RenderingServer.frame_post_draw
		_keep_alive()
	if not settled:
		print("[ShotSkill] !! %s 锚点没进画面，硬截" % tag)
	# 一定要先等一张"真的画完并呈现过"的帧再取纹理：viewport 纹理存的是上一张呈现帧，
	# 而 _wait_ring / _wait_fx 走的是 physics_frame（一帧画面能跑好几个物理帧），于是连续
	# 两枪会截到同一张图 —— 落石那批就出现过 ring/cast/ring 三张字节完全一样的假图。
	await RenderingServer.frame_post_draw
	_keep_alive()
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[ShotSkill] !! viewport 贴图为空（忘了 --window？）")
		return
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	var w := src.get_width()
	var h := src.get_height()
	if not has_at:
		c = Vector2(w * 0.5, h * 0.5)
	var box := Rect2i(int(c.x) - half, int(c.y) - half, half * 2, half * 2)
	box.position.x = clampi(box.position.x, 0, maxi(w - 8, 0))
	box.position.y = clampi(box.position.y, 0, maxi(h - 8, 0))
	box.size.x = mini(box.size.x, w - box.position.x)
	box.size.y = mini(box.size.y, h - box.position.y)
	var out := Image.create(box.size.x, box.size.y, false, Image.FORMAT_RGBA8)
	out.blit_rect(src, box, Vector2i.ZERO)
	var path := "%s/%s.png" % [OUT_DIR, tag]
	var err := out.save_png(path)
	print("[ShotSkill] %s -> %s err=%d 裁图框=%s 锚点世界=%s" % [tag, path, err, str(box),
			str(at) if has_at else "-"])


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


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

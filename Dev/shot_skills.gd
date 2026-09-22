extends Node
## ============================================================
## shot_skills — 实拍：技能在真窗口里到底画出了什么（2026-09-21）
##
## 为什么还要这张：probe_skills 的 201 项断言证明的是**链路与表自洽**（id 解析得出来、
## 冷却会转、状态挂得上、伤害算得对、撤离才写档）。它证明不了"这一帧屏幕上看得见" ——
## tint 把 alpha 乘成 0、FxRing 挂错层被地面盖住、弹道 modulate 写成透明色，
## 探针全是绿的而画面是空的。技能这一层尤其容易全绿却空画，因为它九成的表现
## 就是特效本身。
##
## 二十一张图各管一件事（前缀 sk_）：
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
##   sk_holy_cross   圣光十字：hit_holy 落在自己身上，日志里 HP 从 44 涨到 95
##                   （血条被钉在"回完"那一格 —— _keep_alive 每帧钉血，不挪钉子这口血会被抹平）
##   sk_blood_hunger 嗜血：挂着这层时落石打出去的伤害按 25% 回给自己，日志给涨了多少
##   sk_battle_madness 狂战面具：burst_charge 落在自己身上。增伤这件事静帧看不出来，
##                   证据是日志里同一招冰爆的两下伤害（戴前面具打多少、戴了之后打多少）
##   sk_swift_feather 疾风羽：puff_dust 那一团。加速在一张静帧里根本不可见，
##                   所以真正的读数是日志里"在动的那几帧平均多少 px/s"的两次实测与倍率
##                   （只量像素距离会被场地骗：撞一次"受阻即停"，+50% 能实测成 ×2.6）
##   sk_cinder_sparks 火星溅：空中同时三发（扇形摊开，各自带灼烧）。日志给三发之间的
##                   夹角与逐发抽出来的伤害——"一次出手"与"三发"两件事都要看得见
##   sk_leaf_blade   落叶刃：同时两发 + 靶子身上挂上眩晕（日志点名是哪只被钉住）
##   sk_snake_bite   蛇咬：空中那一发（slash_bite 条带 + 米色弹道）。弹道只活十几帧，
##                   轮询的是"有东西在飞"；命中发生在图之后，所以流血挂没挂上要另扫一轮
##   sk_spore_cloud  孢子雾：地上那圈 128px 的雾（spit_web 落在自己身上）。这招是持续物，
##                   轮询的是圈画出来没有；一圈两只靶子全挂上中毒才叫打中了一群人
##   sk_grimoire / sk_grimoire_near   魔法书本体：图标 + 柔光圈，第二张带人当尺寸参照
##
## 判据与 shot_fx 同一条规矩：**不猜时间**，逐帧轮询到"要拍的那样东西真的在场上"
## 才截；没等到就是真没有，写进 _missed 并以退出码 3 收场，不交空白图。
##
## 用法（**必须开窗**，无头是 dummy 驱动、viewport 贴图恒空）：
##   直接开一条重定向到文件的窗口跑，别走 run_probe.py 的管道抓输出 ——
##   同一份脚本经管道连挂两次（600s 超时、进程停在 0.4% CPU 上不前进），
##   下面这条两分半跑完还留下可实时看的日志：
##   Godot_v4.7.2-stable_win64_console.exe --path D:/SteamPunkExtraction \
##       res://Dev/shot_skills.tscn > _shot_skills.log 2>&1
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
## 圣光十字 / 嗜血那一段的钉血比例。要留够余量：Lv3 一口回 51，钉在 0.65（71/110）会
## 直接回满，而"满血"和"没回"在一张静帧里长得一模一样 —— 钉到 0.4（44/110）才看得见涨。
## 自动释放不靠"把血钉在门槛上面"躲开，而是每段只注入本段要用的招 + 钉血到放招之间
## 一个 await 都不给。
const HEAL_HP_FRAC := 0.4

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

	if _sweep_requested():
		await _sweep_all()
		print("[Sweep] 共出图 %d 张；缺失 %s" % [_n, "无" if _missed.is_empty() else str(_missed)])
		_finish(0 if _missed.is_empty() else 3)
		return

	await _frost_phase()
	await _ember_phase()
	await _guard_phase()
	await _knockback_phase()
	await _sustain_phase()
	await _boon_phase()
	await _volley_phase()
	await _toxin_phase()
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
		_missed.append("ember_shot 弹道在飞（按 skill_projectile 分组认）")
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
# 圣光十字（当场回血）+ 嗜血（打人就回血）
# ------------------------------------------------------------
func _sustain_phase() -> void:
	var max_hp := int(_player.get("max_hp"))
	var hd := SkillSystem.def_of("holy_cross")
	# 每一段只注入这一阶段要用的招：holy_cross 的自动门槛是残血 60%，留着它拍嗜血，
	# 它会在那几张图里抢放同一条 hit_holy，照片就分不清那朵白光是谁开的。
	_ss.set_known({"holy_cross": 3})
	# 钉血 → 清零冷却 → 放招，**中间一个 await 都不给**：一插帧自动释放就可能先把
	# 这一发放掉，我读到的 h0 就成了"回完之后"的数。
	_hp_frac = HEAL_HP_FRAC
	_keep_alive()
	_ss.reset()
	var h0 := int(_player.get("hp"))
	var ok_heal := _ss.cast("holy_cross")
	var h1 := int(_player.get("hp"))
	print("[ShotSkill] ---- 圣光十字 Lv%d（回 %.0f 血，冷却 %.2fs，噪音 %.0f，残血 %.0f%% 自己开）----" % [
			_ss.level_of("holy_cross"), _ss.heal_of("holy_cross"),
			_ss.cooldown_of("holy_cross"), SkillSystem.param("holy_cross", "noise"),
			float(hd.get("auto_cast_hp_below", 0.0)) * 100.0])
	print("[ShotSkill]   手动放=%s｜HP %d → %d（涨 %d，上限 %d）" % [
			str(ok_heal), h0, h1, h1 - h0, max_hp])
	if not ok_heal or h1 <= h0:
		_missed.append("holy_cross 没把血回上去")
	else:
		# _keep_alive 每帧把血钉回 _hp_frac，回上去的那一截会被抹平 —— 所以把钉子挪到
		# 回完的位置，照片里的血条就停在"刚被回过"那一格。
		_hp_frac = float(h1) / float(max_hp)
		var hfx := await _wait_fx(str(hd.get("fx_cast", "")), 240, _player, 120.0)
		if hfx == null:
			_missed.append("holy_cross 施法条带 %s" % str(hd.get("fx_cast", "")))
		else:
			await _shot("sk_holy_cross", _player)

	# 嗜血：挂上之后拿落石当"打人"的那一下。这一段普攻是关掉的（见 _ready 那句
	# set_auto_attack(false)），而三个出手点走的是同一句 apply_lifesteal，
	# 图里要的证据是"血条因为自己打出去的伤害涨回去"，用哪条出口不影响它。
	# 先等圣光十字那条 hit_holy 播完：序列帧有 0.3~1.5s 寿命，不等干净的话这张
	# "嗜血"照片里那朵白光其实是上一招的残留，两张图就成了同一张。
	# 放在 set_known 之前：这时候场上只有 holy_cross，而它已经进了冷却，等帧不会放出新东西。
	await _wait_no_fx(_player, 200.0, 240)
	_ss.set_known({"blood_hunger": 3, "falling_rocks": 3})
	_hp_frac = HEAL_HP_FRAC
	_keep_alive()
	var bd := SkillSystem.def_of("blood_hunger")
	_ss.reset()
	var ok_buff := _ss.cast("blood_hunger")
	print("[ShotSkill] ---- 嗜血 Lv%d（吸血 %.0f%%，持续 %.1fs，冷却 %.2fs）挂上=%s｜身上「%s」----" % [
			_ss.level_of("blood_hunger"),
			SkillSystem.param("blood_hunger", "lifesteal") * 100.0,
			float(bd.get("buff_duration_seconds", 0.0)), _ss.cooldown_of("blood_hunger"),
			str(ok_buff), _status_summary(_player)])
	var targets := _stage_targets(2, _ss.radius_of("falling_rocks") * 0.55)
	if targets.size() < 2 or not ok_buff:
		_missed.append("blood_hunger（靶子或增益没齐）")
	else:
		var a0 := int(_player.get("hp"))
		_ss.reset()
		var ok_rocks := _ss.cast("falling_rocks")
		var a1 := int(_player.get("hp"))
		print("[ShotSkill]   落石打出去之后 HP %d → %d（涨 %d，命中 %d 只）" % [
				a0, a1, a1 - a0, targets.size()])
		if not ok_rocks or a1 <= a0:
			_missed.append("blood_hunger 没让落石回出血来")
		else:
			_hp_frac = float(a1) / float(max_hp)
			var bfx := await _wait_fx(str(bd.get("fx_cast", "")), 240, _player, 120.0)
			if bfx == null:
				_missed.append("blood_hunger 施法条带 %s" % str(bd.get("fx_cast", "")))
			else:
				await _shot("sk_blood_hunger", _player)
	_restore_targets(targets)
	_hp_frac = 0.0
	_ss.set_known(LEVELS)


# ------------------------------------------------------------
# 狂战面具（增伤换承伤）+ 疾风羽（只改腿）
# ------------------------------------------------------------
func _boon_phase() -> void:
	var md := SkillSystem.def_of("battle_madness")
	var fd := SkillSystem.def_of("swift_feather")
	# 这一段只注入面具 + 量增伤的那把尺（frost_nova）：疾风羽和圣光十字都留到各自的
	# 小节再挂，否则残血那几张图里会同时开出好几条 hit_holy，照片分不清是谁。
	_hp_frac = 0.0
	# 上一段那两层（齿轮护盾 / 嗜血）还在自己倒数，不清就会混进"身上「…」"的摘要，
	# 并把承伤乘数叠成 0.6×1.15=0.69 —— 读数没错，但照片旁的日志就说不清哪层是谁给的了。
	var st = _statuses_of(_player)
	if st != null:
		st.call("clear")
	_ss.set_known({"battle_madness": 3, "frost_nova": 3})
	_ss.reset()
	var targets := _stage_targets(1, _ss.radius_of("frost_nova") * 0.5)
	if targets.is_empty():
		_missed.append("battle_madness（场上没有可借的靶子）")
	else:
		var t: Node2D = targets[0]["node"]
		# 靶子的血被 _stage_targets 钉到 999999，所以"掉了几点"= 这一发实际打进去几点。
		# 两次出手之间必须等屏幕干净：第一发的 slam_ring 还在播，第二张就成了两张图共用
		# 同一朵白光（圣光十字那一段就栽过一次）。
		var b0 := int(t.get("hp"))
		_ss.reset()
		_ss.cast("frost_nova")
		var d_plain := b0 - int(t.get("hp"))
		await _wait_no_fx(_player, 240.0, 240)
		_ss.reset()
		var ok_mask := _ss.cast("battle_madness")
		print("[ShotSkill] ---- 狂战面具 Lv%d（出手 +%.0f%%，承伤 ×%.2f，持续 %.1fs，冷却 %.2fs，噪音 %.0f，残血 %.0f%% 自己戴）----" % [
				_ss.level_of("battle_madness"),
				SkillSystem.param("battle_madness", "damage_bonus") * 100.0,
				1.0 - float(md.get("damage_reduction", 0.0)),
				float(md.get("buff_duration_seconds", 0.0)) \
						* (1.0 + float(Config.get_value("skills.progression.duration_per_level", 0.0)) * 2.0),
				_ss.cooldown_of("battle_madness"), SkillSystem.param("battle_madness", "noise"),
				float(md.get("auto_cast_hp_below", 0.0)) * 100.0])
		print("[ShotSkill]   戴上=%s｜身上「%s」" % [str(ok_mask), _status_summary(_player)])
		var mfx := await _wait_fx(str(md.get("fx_cast", "")), 240, _player, 120.0)
		if mfx == null:
			_missed.append("battle_madness 施法条带 %s" % str(md.get("fx_cast", "")))
		else:
			await _shot("sk_battle_madness", _player)
		var b1 := int(t.get("hp"))
		_ss.reset()
		_ss.cast("frost_nova")
		var d_masked := b1 - int(t.get("hp"))
		var mult := _status_mult(_player)
		print("[ShotSkill]   同一招冰爆：戴面具前打 %d，戴了之后打 %d（表里 +%.0f%%，承伤乘数读数 %.2f）" % [
				d_plain, d_masked, SkillSystem.param("battle_madness", "damage_bonus") * 100.0, mult])
		if d_plain <= 0 or d_masked <= d_plain:
			_missed.append("battle_madness 没让同一招打出更多伤害（%d → %d）" % [d_plain, d_masked])
	_restore_targets(targets)

	# 疾风羽：加速在一张静帧里是看不出来的（角色画得一模一样，只是脚底下多一团灰）。
	# 所以图只负责"这团灰真的画出来了"，真正的证据是**在动的那几帧里跑多少 px/s** ——
	# 量出来的，不是从乘数读数上抄的。基线那一次放在**挂上之前**跑：清 known 并不会
	# 清掉身上已经挂着的层，反过来排就得干等 4.8 秒。
	# 只量像素距离上一版栽过一次：途中撞到装饰物就"受阻即停"，那一次的距离不是速度
	# （+50% 实测成 ×2.6 就是这一坑）。速度读数只取"在动"的帧，停下只少采样。
	# 精确倍率由探针在纯读数上兜（那里没有地形与路），这里只断 1.3~1.8 这一档。
	if st != null:
		st.call("clear")
	await _wait_no_fx(_player, 240.0, 240)
	var run_plain := await _speed_run("没加速", 24)
	_ss.set_known({"swift_feather": 3})
	_ss.reset()
	var ok_feather := _ss.cast("swift_feather")
	print("[ShotSkill] ---- 疾风羽 Lv%d（移速 +%.0f%%，持续 %.1fs，冷却 %.2fs，噪音 %.0f，auto_cast=%s）挂上=%s｜身上「%s」----" % [
			_ss.level_of("swift_feather"),
			SkillSystem.param("swift_feather", "speed_bonus") * 100.0,
			float(fd.get("buff_duration_seconds", 0.0)) \
					* (1.0 + float(Config.get_value("skills.progression.duration_per_level", 0.0)) * 2.0),
			_ss.cooldown_of("swift_feather"), SkillSystem.param("swift_feather", "noise"),
			str(SkillSystem.flag("swift_feather", "auto_cast", true)), str(ok_feather),
			_status_summary(_player)])
	var ffx := await _wait_fx(str(fd.get("fx_cast", "")), 240, _player, 120.0)
	if ffx != null:
		await _shot("sk_swift_feather", _player)
	else:
		_missed.append("swift_feather 施法条带 %s" % str(fd.get("fx_cast", "")))
	var run_fast := await _speed_run("带着疾风羽", 24)
	var sp_plain := float(run_plain["pxs"])
	var sp_fast := float(run_fast["pxs"])
	var ratio := sp_fast / maxf(sp_plain, 1.0)
	print("[ShotSkill]   24 帧里：没加速跑 %.0f px（%.0f px/s），带疾风羽跑 %.0f px（%.0f px/s）"
			% [float(run_plain["px"]), sp_plain, float(run_fast["px"]), sp_fast])
	print("[ShotSkill]   速度实测 ×%.2f（表里 +%.0f%% = ×%.2f）" % [
			ratio, SkillSystem.param("swift_feather", "speed_bonus") * 100.0,
			1.0 + SkillSystem.param("swift_feather", "speed_bonus")])
	if int(run_plain["n"]) < 6 or int(run_fast["n"]) < 6:
		_missed.append("swift_feather 这两次跑动在动的帧太少（%s / %s 帧），倍率不作数"
				% [str(run_plain["n"]), str(run_fast["n"])])
	elif ratio < 1.3 or ratio > 1.8:
		_missed.append("swift_feather 实测倍率 ×%.2f 对不上表里 +50%%（1.3~1.8 之外）" % ratio)
	_ss.set_known(LEVELS)
	_ss.reset()


## 命令角色真的朝 pin 右侧走一段，量两件事：固定帧数里跑掉多少像素（"他真的动了"），
## 以及**在动的那几帧里**速度读数的平均值（"跑多快"）。然后把他放回钉位。
## 为什么要后者：只量像素会被场地骗 —— 途中撞到装饰物就"受阻即停"，那一次的距离
## 不是速度，于是 +50% 的增益能实测出 ×2.6。取"在动的那些帧"的平均速度就不受这个影响
## （停下 = 少几个采样，不是把剩下的采样改小）。
## 用 physics_frame 逐帧自己跑，而不是 _wait_* 那几个助手：它们每帧都调 _keep_alive，
## 会把人按回原地 —— 那样量出来的距离恒等于 0，看起来像"加速没用"。
func _speed_run(label: String, frames: int) -> Dictionary:
	var p0 := _player.global_position
	var summed := 0.0
	var moving := 0
	_player.call("set_move_target", _pin + Vector2(400.0, 0.0))
	for _i in range(frames):
		await get_tree().physics_frame
		var v: Vector2 = _player.get("velocity")
		if v.length() > 1.0:
			moving += 1
			summed += v.length()
	var got := p0.distance_to(_player.global_position)
	var avg := summed / float(moving) if moving > 0 else 0.0
	_player.call("stop_moving")
	_player.call("clear_move_target")
	_player.global_position = _pin
	print("[ShotSkill]   %s：%d 帧走了 %.0f px，其中 %d 帧在动，在动时 %.0f px/s" % [
			label, frames, got, moving, avg])
	return {"px": got, "pxs": avg, "n": moving}


# ------------------------------------------------------------
# 多重弹幕：火星溅（一次三发）+ 落叶刃（一次两发带眩晕）
# ------------------------------------------------------------
func _volley_phase() -> void:
	var sd := SkillSystem.def_of("cinder_sparks")
	var ld := SkillSystem.def_of("leaf_blade")
	_hp_frac = 0.0
	# 上一段那两层（面具 / 羽毛）与满地特效都可能还没走完：面具那两张图要的是"身上只有
	# battle_madness"，这里同理 —— 弹幕这一张要的是"空中只有我这次放的那几发"。
	var st = _statuses_of(_player)
	if st != null:
		st.call("clear")
	await _wait_no_fx(_player, 240.0, 240)

	# 火星溅：三发同飞的瞬间只有一小段（680 px/s、40~130 px 之间那几帧），
	# 所以轮询条件写的是"场上同时有几发"，而不是"等到第一发飞出去"。
	_ss.set_known({"cinder_sparks": 1})
	_ss.reset()
	var want := int(SkillSystem.param("cinder_sparks", "projectile_count"))
	# 靶子推远 + 等弹道飞出去再截：三发之间 lateral 差 = 离手距离 × sin(半扇角)，
	# 上一次只等 40px（17° 摊开不到 12px）等于把三发拍成一坨，画面证明不了"扇形"。
	var targets := _stage_targets(3, float(sd.get("range_px", 200.0)) * 0.9)
	if targets.size() < 3:
		_missed.append("cinder_sparks（场上凑不出 3 个靶子）")
	else:
		var cast_now := _ss.cast("cinder_sparks")
		print("[ShotSkill] ---- 火星溅 Lv%d（单发伤害 %.0f，%d 发摊开 %.0f°，射程 %.0f，冷却 %.2fs，噪音 %.0f）手动放=%s ----" % [
				_ss.level_of("cinder_sparks"), _ss.damage_of("cinder_sparks"), want,
				SkillSystem.param("cinder_sparks", "spread_deg"),
				_ss.range_of("cinder_sparks"), _ss.cooldown_of("cinder_sparks"),
				SkillSystem.param("cinder_sparks", "noise"), str(cast_now)])
		var shots := await _wait_projectiles(want, 130.0, 240)
		if shots.is_empty():
			_missed.append("cinder_sparks 没等到 %d 发同时在飞（按 skill_projectile 分组认）" % want)
		else:
			# 读数必须在截图**之前**抄：_shot 要等好几帧渲染，弹道在这段时间里会命中并
			# queue_free，事后再 get("dir") 拿到的是 null → 赋给 Vector2 直接脚本报错。
			var read: Array = _shot_reading(shots)
			await _shot("sk_cinder_sparks", _player, 280)
			var parts: Array = []
			for r in read:
				parts.append("%.0f°/伤%d" % [float(r["ang"]), int(r["dmg"])])
			print("[ShotSkill]   空中同时 %d 发（以第一发为 0°）：%s｜表里 %d 发 / 共 %.0f°" % [
					read.size(), ", ".join(PackedStringArray(parts)), want,
					SkillSystem.param("cinder_sparks", "spread_deg")])
			if read.size() != want:
				_missed.append("cinder_sparks 放出 %d 发，与表里 %d 发不符" % [read.size(), want])
	_restore_targets(targets)
	await _wait_no_fx(_player, 240.0, 240)

	# 落叶刃：两发 + 打上的那一下要真的把对面钉住（眩晕 0.8s，画在靶子身上）
	_ss.set_known({"leaf_blade": 1})
	_ss.reset()
	var t2 := _stage_targets(2, float(ld.get("range_px", 200.0)) * 0.9)
	if t2.size() < 2:
		_missed.append("leaf_blade（场上凑不出 2 个靶子）")
	else:
		var n2 := int(SkillSystem.param("leaf_blade", "projectile_count"))
		var cast2 := _ss.cast("leaf_blade")
		print("[ShotSkill] ---- 落叶刃 Lv%d（单发伤害 %.0f，%d 发摊开 %.0f°，带「%s」，冷却 %.2fs，噪音 %.0f）手动放=%s ----" % [
				_ss.level_of("leaf_blade"), _ss.damage_of("leaf_blade"), n2,
				SkillSystem.param("leaf_blade", "spread_deg"), str(ld.get("status", "")),
				_ss.cooldown_of("leaf_blade"), SkillSystem.param("leaf_blade", "noise"),
				str(cast2)])
		var pairs := await _wait_projectiles(n2, 110.0, 240)
		if pairs.is_empty():
			_missed.append("leaf_blade 没等到 %d 发同时在飞" % n2)
		else:
			var read2: Array = _shot_reading(pairs)   # 同样：读数在截图之前抄，见 _shot_reading
			await _shot("sk_leaf_blade", _player, 190)
			var o2: Array = []
			for r in read2:
				o2.append("%.0f°/伤%d" % [float(r["ang"]), int(r["dmg"])])
			print("[ShotSkill]   空中同时 %d 发：%s（表里两发左右各 %.0f°）" % [
					read2.size(), ", ".join(PackedStringArray(o2)),
					SkillSystem.param("leaf_blade", "spread_deg") * 0.5])
		# 眩晕这一条要**再放一次**来验：stun 只有 0.8 秒，而上面那张图要等若干帧渲染，
		# 等完再扫早就过期了 —— 把"拍到两发同飞"与"打上会钉住"押在同一次出手上，
		# 实跑就是图有了、眩晕报没有。第二发不拍图，出手后立刻逐帧扫全场。
		# 而且这一趟只求"打上"：靶子摆到 0.9 射程之外它们是活的、会自己走开，
		# 三次实跑都是"两发飞出去了、全场没有一个眩晕"。所以先把瞄准方向抄下来，
		# 再把两只靶子按半扇角让开、挪到这条线上 70px 处 —— 近到几帧就命中。
		_ss.reset()
		var a3: Vector2 = _ss.aim_dir("leaf_blade")
		var half_fan := deg_to_rad(SkillSystem.param("leaf_blade", "spread_deg") * 0.5)
		for i in range(mini(t2.size(), 2)):
			var tt: Node2D = t2[i]["node"]
			if is_instance_valid(tt):
				tt.global_position = _pin + a3.rotated(half_fan if i == 0 else -half_fan) * 70.0
		var cast3 := _ss.cast("leaf_blade")
		var stunned: Node2D = null
		for _i in range(180):
			await get_tree().physics_frame
			_keep_alive()
			for e in get_tree().get_nodes_in_group("enemies"):
				if e is Node2D and is_instance_valid(e) and _has_status(e as Node, "stun"):
					stunned = e as Node2D
					break
			if stunned != null:
				break
		if stunned == null:
			_missed.append("leaf_blade 第二次出手（手动放=%s）没把任何敌人打出眩晕" % str(cast3))
		else:
			var is_dummy := false
			for item in t2:
				if item["node"] == stunned:
					is_dummy = true
			print("[ShotSkill]   钉住了：%s（%s）｜身上「%s」" % [str(stunned.name),
					"摆的靶子" if is_dummy else "路上乱逛的那只", _status_summary(stunned)])
			_restore_targets(t2)
	_ss.set_known(LEVELS)
	_ss.reset()


# ------------------------------------------------------------
# 中毒 / 流血：蛇咬拍"空中那一发"，孢子雾拍"地上那圈雾"。
# 两段的等法不一样是有理由的：弹道只活十几帧，轮询的是"有东西在飞"；而雾是持续物，
# 轮询的是地面那圈画出来没有。状态读数照旧全部在 await _shot **之前**抄完。
# ------------------------------------------------------------
func _toxin_phase() -> void:
	var bd := SkillSystem.def_of("snake_bite")
	var cd := SkillSystem.def_of("spore_cloud")
	var st = _statuses_of(_player)
	if st != null:
		st.call("clear")
	await _wait_no_fx(_player, 240.0, 240)

	# 蛇咬：靶子必须摆到瞄准线上。900 px/s 的一发从出手到命中只有几帧，
	# 而 _stage_targets 是按圆周撒的、撒到哪算哪 —— 摆偏了就是"拍着一发往别处飞的牙"。
	_ss.set_known({"snake_bite": 1})
	_ss.reset()
	var tb := _stage_targets(1, 70.0)
	if tb.is_empty():
		_missed.append("snake_bite（场上没有活靶子）")
	else:
		var bt: Node2D = tb[0]["node"]
		bt.global_position = _pin + _ss.aim_dir("snake_bite") * 70.0
		var cast_b := _ss.cast("snake_bite")
		print("[ShotSkill] ---- 蛇咬 Lv%d（伤害 %.0f，射程 %.0f，冷却 %.2fs，噪音 %.0f，带「%s」）手动放=%s ----" % [
				_ss.level_of("snake_bite"), _ss.damage_of("snake_bite"),
				_ss.range_of("snake_bite"), _ss.cooldown_of("snake_bite"),
				SkillSystem.param("snake_bite", "noise"), str(bd.get("status", "")),
				str(cast_b)])
		# min_travel 必须明显小于「靶子距离 − 命中半径」（这里 70−14=56）：
		# 弹道一到靶子就 queue_free，门槛设在 56 之外等于永远等不到"在飞的那一发"。
		var fang := await _wait_projectiles(1, 30.0, 240)
		if fang.is_empty():
			_missed.append("snake_bite 没等到在飞的弹道（按 skill_projectile 分组认）")
		else:
			var read: Array = _shot_reading(fang)     # 截图之前抄读数，见 _shot_reading
			await _shot("sk_snake_bite", _player, 200)
			print("[ShotSkill]   空中 1 发：伤 %d" % int(read[0]["dmg"]))
		# 流血挂上没有 —— 单独扫，不押在截图那一帧上（这一发命中得太快，图等到时早跳完了）
		var bled := false
		for _i in range(120):
			await get_tree().physics_frame
			_keep_alive()
			if is_instance_valid(bt) and _has_status(bt, "bleed"):
				bled = true
				break
		if not bled:
			_missed.append("snake_bite 没把流血挂上靶子")
		else:
			print("[ShotSkill]   靶子身上「%s」" % _status_summary(bt))
	_restore_targets(tb)
	await _wait_no_fx(_player, 240.0, 240)

	# 孢子雾：半径 128 的一圈。中毒有 6 秒长尾，不像眩晕那样会等完图就过期，
	# 所以这一段不需要"再放一次"，一次出手两张判据都够用。
	_ss.set_known({"spore_cloud": 1})
	_ss.reset()
	var radius := float(cd.get("radius_px", 128.0))
	var tc := _stage_targets(2, radius * 0.6)
	if tc.size() < 2:
		_missed.append("spore_cloud（场上凑不出 2 个靶子）")
	else:
		var cast_c := _ss.cast("spore_cloud")
		print("[ShotSkill] ---- 孢子雾 Lv%d（伤害 %.0f，半径 %.0f，冷却 %.2fs，噪音 %.0f，带「%s」，自动门槛 %d 人）手动放=%s ----" % [
				_ss.level_of("spore_cloud"), _ss.damage_of("spore_cloud"), radius,
				_ss.cooldown_of("spore_cloud"), SkillSystem.param("spore_cloud", "noise"),
				str(cd.get("status", "")),
				int(SkillSystem.param("spore_cloud", "auto_cast_targets_min")), str(cast_c)])
		var ring := await _wait_ring(radius, 90)
		if ring == null:
			_missed.append("spore_cloud 没等到地面那圈雾")
		else:
			await _shot("sk_spore_cloud", ring as Node2D, int(radius) + 120)
		var poisoned := 0
		for item in tc:
			var tt: Node2D = item["node"]
			if is_instance_valid(tt) and _has_status(tt, "poison"):
				poisoned += 1
		if poisoned < 2:
			_missed.append("spore_cloud 只把中毒挂上了 %d / 2 个靶子" % poisoned)
		else:
			print("[ShotSkill]   雾里 %d 只靶子全挂上了：%s" % [
					poisoned, _status_summary(tc[0]["node"] as Node)])
	_restore_targets(tc)
	_ss.set_known(LEVELS)
	_ss.reset()


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
	# 站在拾取圈外挡不住跑过来的同伴：LootNode 每物理帧自己扫"最近的活人"，
	# 上一次实拍就是在两张图之间被同伴翻掉（日志 [Loot] 独行 翻开魔法书），
	# 节点没了还去读它的 global_position → 整个函数死掉，两张图静默丢掉。
	# 这两帧期间改用它的拾取冷却把书冻住（_physics_process 开头在冷却里直接 return）。
	var freeze := float(Config.get_value("loot.pickup_retry_seconds", 0.5)) * 200.0
	book.set("_retry_cooldown", freeze)
	# 放在拾取圈外（loot.pickup_radius_px 通常 20px），拍完要踩的那一下再挪回脚下
	var stand := float(Config.get_value("loot.pickup_radius_px", 20.0)) + 42.0
	book.global_position = _pin + Vector2(stand, stand * 0.42)
	await _frames(6)
	if not is_instance_valid(book):
		_missed.append("魔法书：摆好位置之后、拍之前就不见了（谁翻的？）")
		return
	print("[ShotSkill] ---- 魔法书：%s｜图标 %s｜圈色 %s｜离手 %.0f px（拾取半径 %.0f，故意站在圈外）----" % [
			str(Config.get_value("skills.grimoire.name", "")),
			str(Config.get_value("skills.grimoire.sprite", "")).get_file(),
			str(Config.get_value("skills.grimoire.color", "")),
			book.global_position.distance_to(_pin),
			float(Config.get_value("loot.pickup_radius_px", 20.0))])
	await _shot("sk_grimoire", book, 110)
	await _shot("sk_grimoire_near", book)
	if not is_instance_valid(book):
		_missed.append("魔法书：两张图之间书不见了（sk_grimoire_near 没拍到）")
		return
	# 顺手验一次"走进圈里当场学会"：解冻 + 挪到脚下，让 LootNode 自己的物理帧判定触发
	book.set("_retry_cooldown", 0.0)
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


## 等那颗在飞的技能弹道。认的是 skill_projectile 分组（见下面 _flying_projectiles）：
## 普攻那支箭不在这个组里，所以两条路的读数互不污染。
func _wait_projectile(min_travel: float, max_frames: int) -> Node2D:
	for _i in range(max_frames):
		var list := _flying_projectiles()
		if not list.is_empty() \
				and (list[0] as Node2D).global_position.distance_to(_player.global_position) >= min_travel:
			return list[0] as Node2D
		await get_tree().physics_frame
		_keep_alive()
	print("[ShotSkill] !! 没等到飞行中的技能弹道")
	return null


## 弹幕用的那一版：等到"至少 want 发同时离手 min_travel px"才返回。
## 空表 = 到点没等够（调用方记进 _missed，不交一张只有一支箭的图冒充三发）。
## 返回的是当时那一批节点的快照：之后它们会命中消失，图就定格在那一刻。
func _wait_projectiles(want: int, min_travel: float, max_frames: int) -> Array:
	var last: Array = []
	for _i in range(max_frames):
		last = _flying_projectiles()
		var enough := last.size() >= want
		if enough:
			for p in last:
				if (p as Node2D).global_position.distance_to(_player.global_position) < min_travel:
					enough = false
					break
		if enough:
			return last
		await get_tree().physics_frame
		_keep_alive()
	print("[ShotSkill] !! 没等到 %d 发同时在飞（最后只数到 %d 发）" % [want, last.size()])
	return []


## 场上所有在飞的技能弹道。单发那版（_wait_projectile）先于多重弹幕存在，只会报一条；
## 弹幕这张图要的是"同屏几支"，所以两条都走这个数组版。
## 认分组不认名字：Godot 强制"兄弟不重名"，多重弹幕第 2 发起会被改名成 SkillProjectile2/3/4；
## 也不认 _status_id：那等于"这招带状态才数得到"，不带控制的弹幕招会整批发不出来。
func _flying_projectiles() -> Array:
	var out: Array = []
	var world := _player.get_parent()
	if world == null:
		return out
	for n in world.get_children():
		if not (n is Node2D) or not is_instance_valid(n) or n.is_queued_for_deletion():
			continue
		if n.is_in_group("skill_projectile"):
			out.append(n as Node2D)
	return out


## 趁弹道还在场上把读数抄成普通值（相对第一发的带符号夹角 + 这一发的伤害）。
## 两段弹幕都调它：截图要等若干帧渲染，弹道会在这期间命中并 queue_free，事后再读就没了。
## 夹角用 atan2(叉积, 点积) 自己算：Vector2.angle_to() 本身就是带符号的，
## 再按叉积补一次符号等于翻两遍（探针那边把对称的三发读成了 -17/-17/0）。
func _shot_reading(shots: Array) -> Array:
	var out: Array = []
	if shots.is_empty():
		return out
	var first: Vector2 = shots[0].get("dir")
	for p in shots:
		var d: Vector2 = p.get("dir")
		out.append({"ang": rad_to_deg(atan2(first.x * d.y - first.y * d.x, first.dot(d))),
				"dmg": int(p.get("damage"))})
	return out


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


## 等"角色附近一条特效都不剩"。两段共用的理由见 _sustain_phase 里那句调用。
func _wait_no_fx(near: Node2D, radius: float, max_frames: int) -> bool:
	var live: Array = []
	for _i in range(max_frames):
		live.clear()
		for n in get_tree().get_nodes_in_group(&"fx_sprite"):
			if not is_instance_valid(n) or n.is_queued_for_deletion():
				continue
			if near != null and is_instance_valid(near) \
					and (n as Node2D).global_position.distance_to(near.global_position) > radius:
				continue
			live.append(_fx_tag(n))
		if live.is_empty():
			return true
		await get_tree().physics_frame
		_keep_alive()
	print("[ShotSkill] !! %d 帧内没等干净，场上还剩 %s" % [max_frames, str(live)])
	return false


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


# ------------------------------------------------------------
# 通用扫描（--sweep）：池里每一招各放一次、各出一张自动构图的图
#
# 为什么要这一条：手工取景那 21 段每段几十行，技能从 21 涨到 100 就是 100 段拍摄
# 代码，铺不动。扫描只问一件事 —— **这一招放出去，场上有没有真的多出东西**：
# 条带、地面圈、在飞的弹道、挂在自身/靶子身上的状态、回的那口血，五样里任一样
# 出现才截（前缀 sw_）。一样都没有 = 这招是空画，记进 _missed 并以退出码 3 收场。
# 构图是机器默认的（范围技按半径外扩 120，其余角色居中 ±200），不做手工取景；
# 观感层面的挑选仍然归那 21 段。
#
# 用法：Godot.exe --path D:/SteamPunkExtraction res://Dev/shot_skills.tscn \
#           -- --sweep                          （全池）
#           -- --sweep --only a,b,c             （只扫本批）
# ------------------------------------------------------------

func _sweep_requested() -> bool:
	return _user_args().has("--sweep")


func _user_args() -> Array:
	var out: Array = []
	for a in OS.get_cmdline_user_args():
		out.append(str(a))
	return out


## --only a,b,c：只扫这批（一批 4-5 招时不必把整池重跑一遍）
func _sweep_only() -> Array:
	var ua := _user_args()
	for i in range(ua.size() - 1):
		if ua[i] == "--only":
			return String(ua[i + 1]).split(",")
	return []


func _sweep_all() -> void:
	var defs: Dictionary = SkillSystem.all_defs()
	var all: Array = []
	for raw in defs.keys():
		all.append(str(raw))
	all.sort()
	var only := _sweep_only()
	var ids: Array = []
	for x in all:
		if only.is_empty() or only.has(x):
			ids.append(x)
	if not only.is_empty() and ids.size() < only.size():
		for want in only:
			if not ids.has(str(want)):
				_missed.append("--only 里的 %s 不在技能表里（打错名？）" % str(want))
	print("[Sweep] 池里 %d 招，本批扫 %d 招%s" % [
			all.size(), ids.size(), "" if only.is_empty() else "（--only）"])
	for id in ids:
		await _sweep_one(str(id))
	_hp_frac = 0.0
	_ss.set_known(LEVELS)
	_ss.reset()


func _sweep_one(id: String) -> void:
	var d := SkillSystem.def_of(id)
	if d.is_empty():
		_missed.append("%s：表里查不到定义" % id)
		return
	var ty := str(d.get("type", ""))
	var st = _statuses_of(_player)
	if st != null:
		st.call("clear")
	# 治疗要有缺口才看得见：钉在四成血，回完的那一口才会留在血量差里（不钉则满血，
	# "回了 51"和"没回"在数值上完全一样 —— 与圣光十字那一段同一个理由）。
	_hp_frac = 0.4
	await _wait_no_fx(_player, 240.0, 240)
	_ss.set_known({id: 1})
	_ss.reset()

	# 靶子：aoe 要圈里有人、projectile 要那一发真打得到人，buff 不需要靶子。
	var want := 2 if ty == "aoe_self" else 1
	var dist := 110.0
	if ty == "aoe_self":
		dist = clampf(_ss.radius_of(id) * 0.55, 60.0, 150.0)
	elif ty == "projectile":
		dist = clampf(_ss.range_of(id) * 0.45, 90.0, 170.0)
	var tg: Array = [] if ty == "buff" else _stage_targets(want, dist)
	if ty != "buff" and tg.size() < want:
		_missed.append("%s：场上摆不出 %d 个靶子" % [id, want])
		_restore_targets(tg)
		return
	if ty == "projectile" and not tg.is_empty():
		# 摆到瞄准线上：_stage_targets 是按圆周撒的，撒偏了就是"拍着一发往别处飞的弹道"，
		# 而且靶子身上永远挂不上状态。
		var aim := _ss.aim_dir(id)
		if aim.length() > 0.01:
			for i in range(tg.size()):
				(tg[i]["node"] as Node2D).global_position = \
						_pin + aim.rotated(deg_to_rad(9.0 * float(i))) * dist
	# 上一招收的账别算到这一招头上：靶子是场上真敌人，状态会跨段残留
	if ty != "buff":
		for item in tg:
			var ts = _statuses_of(item["node"])
			if ts != null:
				ts.call("clear")
	var hp0 := int(_player.get("hp"))
	if not _ss.cast(id):
		_missed.append("%s：cast() 返回 false（冷却没转完 / 宿主挂了招 / 表里 type 不认识）" % id)
		_restore_targets(tg)
		return
	# 血量差必须在下一个 await 之前抄：_keep_alive 每帧把血钉回四成，晚一帧就读成 0。
	var healed := int(_player.get("hp")) - hp0
	# 画得出来的那三样只活十几条帧，等到就立刻截；状态要等弹道飞完才挂上，截完再读。
	var ev: Dictionary = await _sweep_wait_visual(id, d)
	ev["heal"] = healed
	if ev["self"] == "" and _has_status(_player, id):
		ev["self"] = _status_summary(_player)
	var seen := _sweep_seen(ev)
	if seen.is_empty():
		_missed.append("%s：cast 成功但场上五样证据（条带/地面圈/弹道/状态/回血）一样都没有 = 空画" % id)
	else:
		# 地面圈本来就以角色为心，所以锚点一律用角色：拿圈或弹道当锚点的话，
		# 它在 await _shot 等渲染的那几帧里就没了（蛇咬那张踩过）。
		var half := 200
		if ty == "aoe_self":
			half = int(_ss.radius_of(id)) + 120
		await _shot("sw_" + id, _player, half)
		if str(d.get("status", "")) != "" and ev["tgt"] == "":
			ev["tgt"] = await _sweep_read_status(id, d, tg)
		seen = _sweep_seen(ev)
		var measure := "—" if ty == "buff" else (
				"半径 %.0f" % _ss.radius_of(id) if ty == "aoe_self" else "射程 %.0f" % _ss.range_of(id))
		print("[Sweep] %-16s %-6s %-10s 伤 %.0f｜%s｜冷却 %.2fs｜噪音 %.0f｜证据：%s" % [
				id, str(d.get("element", "")), ty, _ss.damage_of(id), measure,
				_ss.cooldown_of(id), SkillSystem.param(id, "noise"), ", ".join(seen)])
	_restore_targets(tg)


## 只轮询"画得出来"的那三样：施法条带、地面那圈、在飞的弹道。
## 一样都不出现 = 这招是空画（tint 把 alpha 乘成 0、挂错层被地面盖住那一类）。
func _sweep_wait_visual(id: String, d: Dictionary) -> Dictionary:
	var ty := str(d.get("type", ""))
	var fx_cast := str(d.get("fx_cast", ""))
	var want_ring := float(_ss.radius_of(id)) if ty == "aoe_self" else 0.0
	var ev := {"fx": "", "ring": 0.0, "shots": 0, "self": "", "tgt": "", "heal": 0}
	for _i in range(90):
		await get_tree().physics_frame
		_keep_alive()
		if ev["fx"] == "" and fx_cast != "":
			for n in get_tree().get_nodes_in_group(&"fx_sprite"):
				if is_instance_valid(n) and not n.is_queued_for_deletion() \
						and _fx_tag(n) == fx_cast:
					ev["fx"] = fx_cast
					break
		if ev["ring"] == 0.0 and want_ring > 0.0 and _find_ring(want_ring) != null:
			ev["ring"] = want_ring
		var shots := _flying_projectiles().size()
		if shots > int(ev["shots"]):
			ev["shots"] = shots
		if str(ev["fx"]) != "" or float(ev["ring"]) > 0.0 or int(ev["shots"]) > 0:
			return ev
	return ev


## 截图之后补读状态：弹道要飞一段才挂得上，而状态一挂就是几秒，图早拍完了。
## 读到就返回，读不到返回空串（扫描不因为一条状态读数而失败——那归探针断言管）。
func _sweep_read_status(id: String, d: Dictionary, tg: Array) -> String:
	var sid := str(d.get("status", ""))
	for _i in range(40):
		for item in tg:
			var t: Node2D = item["node"]
			if is_instance_valid(t) and _has_status(t, sid):
				return _status_summary(t)
		await get_tree().physics_frame
		_keep_alive()
	return ""


## 把证据字典翻成人话；空表 = 这一招什么都没画出来
func _sweep_seen(ev: Dictionary) -> Array:
	var out: Array = []
	if str(ev["fx"]) != "":
		out.append("条带 " + str(ev["fx"]))
	if float(ev["ring"]) > 0.0:
		out.append("地面圈 %.0f" % float(ev["ring"]))
	if int(ev["shots"]) > 0:
		out.append("弹道 %d 发" % int(ev["shots"]))
	if str(ev["self"]) != "":
		out.append("自身「" + str(ev["self"]) + "」")
	if str(ev["tgt"]) != "":
		out.append("靶子「" + str(ev["tgt"]) + "」")
	if int(ev["heal"]) > 0:
		out.append("回血 +%d" % int(ev["heal"]))
	return out

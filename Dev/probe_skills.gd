extends Node2D
## ============================================================
## probe_skills — 技能系统全链路（2026-09-21）
##
## 七段，顺序刻意排成"先纯表、再纯逻辑、最后进场"：
##   A) skills.json 自洽：技能数 = 槽数、热键落在 49..54 且不撞号、每招引用的
##      特效 id / 五行 / 状态 id 全在各自的表里。接线写错在运行时是"静默不放技能"，
##      实拍极难看出来，只能靠这里兜。
##   B) 状态容器（UnitStatus）：冻结停 AI + 速度归零、到期挂免疫期、灼烧按 tick
##      跳血且伤害随层数涨、叠层有上限、增益乘数合成、未知 id 不生效。
##   C) 学习与成长（SkillSystem 纯逻辑，不需要宿主）：槽位上限、重复学习升级、
##      满级后再学不涨、set_known 丢掉表里已删的 id、成长公式三个方向都对。
##   D) 真身进局：冷却、自动释放的门槛（射程内没敌人就不放）、一发落地打到人 +
##      挂上状态 + 计入噪音表、地面圈落一份、冷却一到自动补一发、护盾减伤算术。
##   E) 弹道：索敌口径（射程内最近的那个，与普攻的锁无关）、技能自带 projectile 段、
##      状态随命中传递、aoe_radius_px 溅到第二个、半径外的不打。
##   F) 局内学 → 撤离才永久：只抄活人、一招没学不清空原有技能、_sanitize_skills
##      洗死 id 与越界等级、存盘读档一轮不丢。
##   G) 真拾取：把一本真 LootNode 魔法书丢在脚下，走它自己的物理帧重叠判定 ——
##      学会一招、书当场消失、且它压根不是资源（resource_id 空 → 进不了仓库）。
##
## 【噪音为什么能断言】NoiseSystem 是 autoload，peak_noise 是公开读数；技能那一下
## 走 from_player=true，所以它会真的动起来。
##
## 【假靶子为什么自己造】真敌人的死亡流程要拖血条/掉落/音效一整套，无头里造不干净；
## 而弹道与范围技只需要四个接口（hp / take_damage / apply_status / 位置）。
## 靶子只在同步调用前后待在场上进组，中间一次 await 都不给 —— 否则 UnitSeparation
## 会把它们当成远处的敌人搬回可走格，位置就不是我写的那个了。
##
## ⚠ F 段会改 Meta.roster 并触发 Meta.save_game()（无头里 active_slot==0 →
##   写 user://save.json）。所以开跑先备份存档、收尾原样还原，并且当场断言
##   active_slot 真的是 0 —— 万一以后无头回归也走槽位，那句备份会静默失效。
## ============================================================

const PROJECTILE := "res://Scripts/combat/projectile.gd"
const LOOT_SCENE := "res://Scenes/LootNode.tscn"
const OUT := "user://_probe_skills.txt"
const SAVE_PATH := "user://save.json"
const KEY_MIN := 49        # KEY_1（2026-09-21 用 --script 探针实测：KEY_1=49…KEY_6=54）
const KEY_MAX := 54
const HIT := 40            # 护盾算术那一段用的测试伤害（要大于裸防御才有意义）

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _stage: Node2D = null
var _save_backup := ""
var _save_existed := false


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


## 手动喂帧：无头空转时真实 delta 极小，等一次冷却要跑上千帧，还会被微冻掺和。
func _tick(node: Node, seconds: float, method: StringName) -> void:
	var step := 1.0 / 60.0
	for _i in range(int(ceil(seconds / step))):
		node.call(method, step)


## 假靶子：范围技与弹道的命中对象。hp 归零后 SkillSystem.is_alive 会把它剔出目标表。
class DummyTarget extends Node2D:
	var hp := 100
	var hits := 0
	var status_ids: Array = []
	var kb_dir := Vector2.ZERO
	var kb_dist := 0.0

	func take_damage(amount: int) -> void:
		hits += 1
		hp = maxi(hp - amount, 0)

	func apply_status(id: String, _def_override: Dictionary = {}) -> bool:
		status_ids.append(id)
		return true

	## 与 enemy.gd 同签名：击退这一路要有可断言的对象，光看位置变化分不清
	## 是"被推了 46px"还是"半径本来就把它算进去了"。
	func apply_knockback(impulse: Vector2, dist_px: float = -1.0) -> void:
		if impulse.length() < 1.0:
			return
		kb_dir = impulse.normalized()
		kb_dist = dist_px
		global_position += kb_dir * dist_px


func _dummy_at(pos: Vector2) -> Node2D:
	var d := DummyTarget.new()
	_stage.add_child(d)
	d.global_position = pos
	d.add_to_group("enemies")
	return d


func _kill_dummies() -> void:
	for n in get_tree().get_nodes_in_group("enemies"):
		if n is DummyTarget:
			_stage.remove_child(n)     # 立刻退组：queue_free 要等这一帧结束才生效
			(n as Node).queue_free()


## 只留字典项：配置表里那条给人看的 _comment 是字符串，混进来会把
## `var d: Dictionary = 表[k]` 直接炸掉（SkillSystem.all_defs 同一口径）。
func _dicts_of(raw) -> Dictionary:
	var out := {}
	if raw is Dictionary:
		for k in (raw as Dictionary).keys():
			if (raw as Dictionary)[k] is Dictionary:
				out[k] = (raw as Dictionary)[k]
	return out


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_stage = self
	_backup_save()
	await _frames(2)
	_check(SaveSlots.active_slot == 0,
			"无头跑在默认槽（active_slot=0）→ 备份 user://save.json 才有效")
	_a_table()
	_b_status()
	_c_learn()
	await _d_live()
	_finish()


# ------------------------------------------------------------
# A 段：表自洽
# ------------------------------------------------------------
func _a_table() -> void:
	_say("--- A 段：skills.json 表自洽 ---")
	var defs := SkillSystem.all_defs()
	var slots := int(Config.get_value("skills.slots", 0))
	_check(defs.size() >= slots and slots == 3,
			"技能池 %d 招 ≥ 身上 %d 个槽（池子按批长大，槽数不动）" % [defs.size(), slots])
	_check(bool(Config.get_value("skills.enabled", false)), "skills.enabled 默认开着")

	var effects: Dictionary = Config.get_value("fx.effects", {})
	# elements / statuses 两张表里各有一条 _comment 给人看的字符串 —— 只数真定义
	# （SkillSystem.all_defs() 也是这么筛的，口径要一致）。
	var elements := _dicts_of(Config.get_value("skills.elements", {}))
	var statuses := _dicts_of(Config.get_value("skills.statuses", {}))
	_check(elements.size() == 5, "五行齐全（实得 %d）" % elements.size())
	_check(statuses.has("frozen") and statuses.has("burning"), "冻结 + 灼烧两条状态都在表里")

	var bad: Array = []
	var seen_keys := {}
	for raw_id in defs.keys():
		var id := str(raw_id)
		var d: Dictionary = defs[raw_id]
		if str(d.get("name", "")) == "":
			bad.append("%s 缺 name" % id)
		var el := str(d.get("element", ""))
		if not elements.has(el):
			bad.append("%s 的属性 %s 不在 skills.elements" % [id, el])
		elif not Color(str((elements[el] as Dictionary).get("color", ""))).a > 0.0:
			bad.append("%s 的属性色解析不出" % id)
		var t := str(d.get("type", ""))
		if not ["aoe_self", "projectile", "buff"].has(t):
			bad.append("%s 的 type=%s 不认识" % [id, t])
		if t == "projectile" and not (d.get("projectile", null) is Dictionary):
			bad.append("%s 是 projectile 型却没有 projectile 段" % id)
		var fx_cast := str(d.get("fx_cast", ""))
		if fx_cast == "" or not effects.has(fx_cast):
			bad.append("%s 的 fx_cast=%s 不在 fx.effects" % [id, fx_cast])
		var fx_hit := str(d.get("fx_hit", ""))
		if fx_hit != "" and not effects.has(fx_hit):
			bad.append("%s 的 fx_hit=%s 不在 fx.effects" % [id, fx_hit])
		var st := str(d.get("status", ""))
		if st != "" and not statuses.has(st):
			bad.append("%s 的状态 %s 不在 skills.statuses" % [id, st])
		var k := int(d.get("key", 0))
		if k < KEY_MIN or k > KEY_MAX:
			bad.append("%s 的热键 %d 不在 %d..%d" % [id, k, KEY_MIN, KEY_MAX])
		elif seen_keys.has(k):
			bad.append("%s 的热键 %d 与 %s 撞号" % [id, k, str(seen_keys[k])])
		else:
			seen_keys[k] = id
	_check(bad.is_empty(), "三招的字段全部接得到真表：%s"
			% ["无问题" if bad.is_empty() else str(bad)])

	# 状态定义本身要能用：时长 > 0，颜色解析得出，DoT 类要两个键都有
	var s_bad: Array = []
	for raw_id in statuses.keys():
		var sd: Dictionary = statuses[raw_id]
		if float(sd.get("duration_seconds", 0.0)) <= 0.0:
			s_bad.append("%s duration_seconds<=0" % str(raw_id))
		var col := Color(str(sd.get("color", "#")))
		if str(sd.get("color", "")) == "" or not col.a > 0.0:
			s_bad.append("%s 缺可解析的 color" % str(raw_id))
		if float(sd.get("tick_interval_seconds", 0.0)) > 0.0 \
				and int(sd.get("damage_per_tick", 0)) <= 0:
			s_bad.append("%s 有 tick 却没有每跳伤害" % str(raw_id))
	_check(s_bad.is_empty(), "状态定义可用：%s" % ["无问题" if s_bad.is_empty() else str(s_bad)])

	# 缺省表：脚本里不写死数值 = 代码会读的每个 defaults 键都得真的存在
	var need: Array = ["cooldown_seconds", "noise", "auto_cast", "auto_cast_targets_min",
			"range_px", "shock_ring_seconds", "knockback_px", "damage", "status",
			"crit_chance", "crit_multiplier", "variance"]
	var d_raw = Config.get_value("skills.defaults", {})
	var missing: Array = []
	for k in need:
		if not (d_raw is Dictionary) or not (d_raw as Dictionary).has(str(k)):
			missing.append(str(k))
	_check(missing.is_empty(), "skills.defaults 覆盖了代码会读的全部键：%s"
			% ["无缺" if missing.is_empty() else str(missing)])

	# 魔法书：图标存在（素材没切出来时这条会红，是故意的）
	var g_icon := str(Config.get_value("skills.grimoire.sprite", ""))
	_check(g_icon != "" and ResourceLoader.exists(g_icon), "魔法书图标在位：%s" % g_icon)
	_check(int(Config.get_value("skills.grimoire.nodes_per_run", 0)) > 0,
			"每局至少掉一本魔法书")
	var res = Config.get_value("resources", {})
	_check(res is Dictionary and not (res as Dictionary).has(
			str(Config.get_value("skills.grimoire.resource_id", "grimoire"))),
			"grimoire 没被登记成资源（否则会连累 Meta._prune_unknown_resources）")


# ------------------------------------------------------------
# B 段：状态容器
# ------------------------------------------------------------
func _b_status() -> void:
	_say("--- B 段：状态容器 UnitStatus ---")
	var frozen: Dictionary = UnitStatus.def_of("frozen")
	var burning: Dictionary = UnitStatus.def_of("burning")

	var s := UnitStatus.new()
	_check(s.is_empty() and is_equal_approx(s.speed_mult(), 1.0)
			and is_equal_approx(s.damage_taken_mult(), 1.0)
			and s.visual_tint() == Color(1, 1, 1),
			"空容器：三个乘数都是单位元、染色纯白（旧内容零影响）")
	_check(s.apply("frozen"), "施加冻结成功")
	_check(s.halts_ai() and is_equal_approx(s.speed_mult(), 0.0),
			"冻结 = 停 AI + 速度乘成 0（宿主不必特判）")
	_check(s.visual_tint() != Color(1, 1, 1), "冻结把身上染成冰蓝")
	var dur := float(frozen.get("duration_seconds", 1.0))
	s.tick(dur + 0.01)
	_check(s.is_empty(), "冻结按时长自然到期（%.1fs）" % dur)
	var grace := float(frozen.get("thaw_immunity_seconds", 0.0))
	_check(grace > 0.0 and s.immune_remaining("frozen") > 0.0,
			"到期后挂上 %.1fs 解冻免疫期" % grace)
	_check(not s.apply("frozen"), "免疫期内再冻整个作废（不能连冻到死）")
	s.tick(grace + 0.01)
	_check(s.apply("frozen"), "免疫期过了能再冻")
	s.clear()

	_say("  · 灼烧")
	var b := UnitStatus.new()
	var calls: Array = []
	b.dot_handler = func(amount: int) -> void: calls.append(amount)
	_check(b.apply("burning"), "施加灼烧成功")
	var interval := float(burning.get("tick_interval_seconds", 1.0))
	var dealt := b.tick(float(burning.get("duration_seconds", 0.0)))
	var want_ticks := int(float(burning.get("duration_seconds", 0.0)) / interval)
	_check(calls.size() == want_ticks,
			"灼烧 %.1fs / 每 %.1fs 一跳 = %d 跳（实得 %d）"
			% [float(burning.get("duration_seconds", 0.0)), interval, want_ticks, calls.size()])
	_check(dealt == want_ticks * int(burning.get("damage_per_tick", 0)),
			"一跳 %d 伤 × %d 跳 = 累计 %d"
			% [int(burning.get("damage_per_tick", 0)), want_ticks, dealt])
	_check(b.is_empty(), "灼烧跳完自己结束")

	var c := UnitStatus.new()
	var hits2: Array = []
	c.dot_handler = func(amount: int) -> void: hits2.append(amount)
	for i in range(6):
		c.apply("burning")
	var cap := maxi(1, int(burning.get("max_stacks", 1)))
	_check(c.stacks_of("burning") == cap,
			"灼烧叠到 max_stacks 就顶住（实得 %d 层 / 上限 %d）" % [c.stacks_of("burning"), cap])
	c.tick(interval)
	_check(hits2.size() == 1 and int(hits2[0]) == int(burning.get("damage_per_tick", 0)) * cap,
			"层数真的进每跳伤害（实得 %s）" % str(hits2))

	var m := UnitStatus.new()
	_check(m.apply_modifier("gear_guard", {"damage_mult": 0.6}, 5.0), "挂上运行时合成的减伤增益")
	_check(is_equal_approx(m.damage_taken_mult(), 0.6), "增益期间承伤 ×0.6")
	m.tick(5.01)
	_check(m.is_empty() and is_equal_approx(m.damage_taken_mult(), 1.0), "增益到点自动摘掉")

	UnitStatus.reset_dedupe()
	_check(not m.apply("no_such_status") and m.is_empty(), "未知状态 id 不生效（只警告一次）")


# ------------------------------------------------------------
# C 段：学习与成长（不需要宿主）
# ------------------------------------------------------------
func _c_learn() -> void:
	_say("--- C 段：学习、槽位与成长 ---")
	var max_lv := int(Config.get_value("skills.progression.max_level", 5))
	var ss := SkillSystem.new()
	var first: Dictionary = ss.learn("frost_nova")
	_check(bool(first.get("ok", false)) and str(first.get("action", "")) == "learned",
			"第一本学会 frost_nova")
	for raw_id in SkillSystem.all_defs().keys():
		ss.learn(str(raw_id))
	_check(ss.known.size() == 3 and ss.known.size() <= int(Config.get_value("skills.slots", 3)),
			"学会的招数不超过槽数（实得 %d）" % ss.known.size())
	_check(str(ss.learn("frost_nova").get("action", "")) == "leveled", "重复捡书 = 升级，不是白捡")
	for i in range(max_lv):
		ss.learn("frost_nova")
	_check(int(ss.level_of("frost_nova")) == max_lv, "练到顶 = Lv%d（实得 %d）"
			% [max_lv, ss.level_of("frost_nova")])
	_check(str(ss.learn("frost_nova").get("action", "")) == "maxed", "满级后再学只报 maxed")
	_check(str(ss.learn("no_such_skill").get("action", "")) == "unknown", "不存在的技能学不了")

	# 槽满：把槽数临时压成 2，第三招新的才真的会被拒（3 招 3 槽永远撞不上这条）
	Config.set_override("skills.slots", 2)
	var full := SkillSystem.new()
	_check(bool(full.learn("frost_nova").get("ok", false))
			and bool(full.learn("ember_shot").get("ok", false)), "两个槽都能学上")
	var third: Dictionary = full.learn("gear_guard")
	_check(not bool(third.get("ok", false)) and str(third.get("action", "")) == "slots_full",
			"第三个槽没有 → 新技能被拒（实得 %s）" % str(third.get("action", "")))
	_check(bool(full.learn("frost_nova").get("ok", false)),
			"槽满不影响已有技能继续升级")
	Config.clear_override("skills.slots")

	var pool: Dictionary = {}
	var rolled := SkillSystem.roll_skill(pool)
	_check(SkillSystem.all_defs().has(rolled), "空手时 roll_skill 掷得出表里的 id（%s）" % rolled)
	var rolled2 := SkillSystem.roll_skill({"frost_nova": 1, "ember_shot": 1, "gear_guard": 1}, false)
	_check(SkillSystem.all_defs().has(rolled2), "全学会后仍能掷（升级用的那一条）")

	var t := SkillSystem.new()
	t.set_known({"frost_nova": 2, "no_such_skill": 3, "ember_shot": 0})
	_check(t.known.size() == 1 and int(t.level_of("frost_nova")) == 2,
			"set_known 丢掉表里已删的 id、且不收等级 0（实得 %d 条）" % t.known.size())
	_check(t.skill_at_keycode(int(Config.get_value("skills.list.frost_nova.key", 0))) == "frost_nova",
			"热键码 → 技能 id 认得出来")
	_check(t.skill_at_keycode(99999) == "", "没人绑的键返回空串")

	var g := SkillSystem.new()
	g.set_known({"frost_nova": 1})
	var dmg1 := g.damage_of("frost_nova")
	var cd1 := g.cooldown_of("frost_nova")
	var r1 := g.radius_of("frost_nova")
	_check(g.status_def_of("frost_nova").is_empty(), "1 级不合成状态定义（与出厂表等价）")
	g.set_known({"frost_nova": max_lv})
	_check(g.damage_of("frost_nova") > dmg1,
			"满级伤害高于 1 级（%.1f → %.1f）" % [dmg1, g.damage_of("frost_nova")])
	_check(g.cooldown_of("frost_nova") < cd1,
			"满级冷却短于 1 级（%.1f → %.1f）" % [cd1, g.cooldown_of("frost_nova")])
	_check(g.radius_of("frost_nova") > r1,
			"满级半径大于 1 级（%.1f → %.1f）" % [r1, g.radius_of("frost_nova")])
	_check(not g.status_def_of("frost_nova").is_empty(), "升过级的技能才合成放大后的状态定义")


# ------------------------------------------------------------
# D/E/F 段：进局
# ------------------------------------------------------------
func _d_live() -> void:
	_say("--- D 段：真身进局（门槛 / 冷却 / 自动释放 / 噪音 / 护盾）---")
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	# 走**出击选人**那条真实路径：不选人的话 _squad_characters() 会兜一个
	# uid=0 的临时角色，名册技能注入（main.gd 那句 set_known）就永远测不到。
	Meta.roster = []
	Meta.seeded_ids = []
	Meta.ensure_roster()
	Meta.set_skills(1, {"frost_nova": 2})
	main._selected_units = [Meta.roster[0]]
	main._enter_run()
	await _frames(30)

	var player: Node = get_tree().get_first_node_in_group("player")
	_check(player != null, "局内有角色")
	if player == null:
		return
	var ss := player.call("skills") as SkillSystem
	_check(ss != null and ss.unit == player, "角色身上挂着一份 SkillSystem，且认得宿主")
	_check(int(player.get("roster_uid")) == 1, "这名角色有名册身份（uid=%d）"
			% int(player.get("roster_uid")))
	_check(ss != null and int(ss.level_of("frost_nova")) == 2,
			"名册里带的技能在出击时注入了（frost_nova Lv%d）"
			% (0 if ss == null else ss.level_of("frost_nova")))

	_cast_round(player, ss)
	_shield(player)
	_projectile(ss)
	_knockback(ss)
	await _grimoire_pickup(player, ss)
	_negative(player, ss)
	_persist(player, ss)
	_kill_dummies()
	await _frames(3)


## G：魔法书的真拾取路径 —— 不直调 _teach()，而是把书丢在脚下让 LootNode 自己的
## 物理帧判定去触发（那条 get_overlapping_bodies() 才是玩家实际走的路）。
func _grimoire_pickup(player: Node, ss: SkillSystem) -> void:
	_say("--- G 段：魔法书拾取（学招 + 书消失）---")
	ss.set_known({})
	var book: Node = load(LOOT_SCENE).instantiate()
	player.get_parent().add_child(book)
	book.call("setup_grimoire")
	# 先抄下 resource_id 再放手：拾取一旦发生这本书就 queue_free 了，
	# 等完 6 帧再去读它的属性 = 对已释放实例求值（真崩过一次）。
	var res_id := str(book.get("resource_id"))
	book.global_position = player.global_position
	await _frames(6)
	_check(ss.known.size() == 1, "踩上魔法书就学会一招（实得 %s）" % str(ss.known))
	_check(res_id == "", "魔法书不是资源：resource_id 留空，不会被带进仓库")
	_check(not is_instance_valid(book), "书读完了就从场上消失（不会反复重掷）")


func _cast_round(player: Node, ss: SkillSystem) -> void:
	ss.set_known({"frost_nova": 1})
	ss.reset()
	var radius := ss.radius_of("frost_nova")
	var far = ss.global_pos() + Vector2(radius * 3.0, 0.0)

	# 门槛：射程内没有敌人就不自动放。场上真有真敌人贴着时如实跳过，不假装通过。
	var nearby := ss.hostile_count_in_radius(ss.global_pos(), radius)
	if nearby == 0:
		_check(not ss.auto_wants("frost_nova"), "射程内没敌人 → 自动释放的门槛不开")
	else:
		_say("  (场上已有 %d 个敌人贴着，跳过「无目标不放」这一条)" % nearby)
	_check(ss.can_cast("frost_nova"), "冷却是满的 → 手动抢放不受门槛限制")

	var ring_before := _rings_under(player)
	NoiseSystem.peak_noise = 0.0
	var d := _dummy_at(ss.global_pos() + Vector2(radius * 0.4, 0.0))
	_check(ss.auto_wants("frost_nova"), "射程内出现敌人 → 门槛开")
	_check(ss.cast("frost_nova"), "手动放得出冰霜新星")
	_check(int(d.hits) == 1, "范围内挨了一下（实得 %d 次）" % int(d.hits))
	_check(d.status_ids == ["frozen"], "命中的目标被挂上 frozen（实得 %s）" % str(d.status_ids))
	_check(ss.cooldown_left("frost_nova") > 0.0, "放完立刻进冷却")
	_check(not ss.cast("frost_nova"), "冷却中放不出去（同一帧第二次调用被拒）")
	var want_noise := float(Config.get_value("skills.list.frost_nova.noise", 0.0))
	_check(NoiseSystem.peak_noise >= want_noise * 0.99,
			"技能计入噪音表（peak %.0f ≥ 表值 %.0f）" % [NoiseSystem.peak_noise, want_noise])
	_check(_rings_under(player) == ring_before + 1, "地面圈落了一份（前 %d 后 %d）"
			% [ring_before, _rings_under(player)])
	_kill_dummies()

	# 冷却一到自动补一发：全程只调 tick，不手动 cast。
	# 判据只能看"多打了一下"—— 补完冷却立刻又被填回 9 秒，所以不能断言冷却归零。
	var d2 := _dummy_at(ss.global_pos() + Vector2(radius * 0.4, 0.0))
	var hits_before := int(d2.hits)
	var cd := ss.cooldown_of("frost_nova")
	var step := 1.0 / 60.0
	var frames := 0
	var max_frames := int(ceil(cd / step)) + 60
	while frames < max_frames and int(d2.hits) == hits_before:
		ss.tick(step)
		frames += 1
	_check(int(d2.hits) == hits_before + 1,
			"冷却一到就自动补了一发（%d/%d 帧，命中前 %d 后 %d）"
			% [frames, max_frames, hits_before, int(d2.hits)])
	_check(ss.cooldown_left("frost_nova") > cd - 2.0 * step,
			"自动补完立刻重新进冷却（剩余 %.2f / 满 %.2f）"
			% [ss.cooldown_left("frost_nova"), cd])
	# 射程被观察视野截断：技能可以比普攻打远，但不能隔着黑雾执法
	_check(ss.range_of("frost_nova") <= float(player.call("vision_px")) + 0.01,
			"技能射程不超过观察视野（%.0f ≤ %.0f）"
			% [ss.range_of("frost_nova"), float(player.call("vision_px"))])
	if nearby == 0:
		d2.global_position = far      # 走出半径 → 门槛又关上（证明上面靠的是距离不是运气）
		_check(not ss.auto_wants("frost_nova"), "敌人走出半径 → 门槛又关上")
	_kill_dummies()


func _shield(player: Node) -> void:
	var defense := int(float(player.call("trait_flat", "defense"))) \
			- int(float(player.call("supply_penalty", "defense")))
	if HIT <= defense:
		_say("  (防御 %d ≥ 测试伤害 %d，跳过护盾算术)" % [defense, HIT])
		return
	player.set("_invincible_timer", 0.0)
	player.set("_dodge_invincible", false)
	var hp0 := int(player.hp)
	player.call("take_damage", HIT)
	var plain := hp0 - int(player.hp)
	_check(plain == HIT - defense, "裸值挨 %d 掉 %d（防御 %d）" % [HIT, plain, defense])

	player.set("_invincible_timer", 0.0)
	_check(bool(player.call("apply_buff", "gear_guard", {"damage_mult": 0.5}, 5.0)),
			"护盾挂得上（走 UnitStatus 的运行时合成定义）")
	var hp1 := int(player.hp)
	player.call("take_damage", HIT)
	var shielded := hp1 - int(player.hp)
	_check(shielded == maxi(int(round(HIT * 0.5)) - defense, 0),
			"盾期间同样一刀只掉 %d（先 ×0.5 再扣防御 %d，实得 %d）"
			% [int(round(HIT * 0.5)) - defense, defense, shielded])
	var st := player.get("_statuses") as UnitStatus
	st.tick(5.01)
	_check(st.is_empty() and is_equal_approx(st.damage_taken_mult(), 1.0),
			"盾到点自己没了，承伤回到 ×1")


## E：弹道 —— 技能自带弹道表、命中挂状态、aoe_radius_px 溅到第二个、半径外的不打
func _projectile(ss: SkillSystem) -> void:
	_say("--- E 段：技能弹道（索敌口径 + 灼烧传递 + 溅射）---")
	var d := SkillSystem.def_of("ember_shot")
	var pc: Dictionary = d.get("projectile", {}) as Dictionary
	_check(not pc.is_empty() and str(pc.get("texture", "")) != ""
			and ResourceLoader.exists(str(pc.get("texture", ""))),
			"余烬弹自带一份弹道表，贴图在位")
	var aoe := float(d.get("aoe_radius_px", 0.0))
	var hit_r := float(pc.get("hit_radius_px", 16.0))
	_check(aoe > hit_r, "溅射半径 %.0fpx 大于命中判定 %.0fpx" % [aoe, hit_r])
	_aim_at_nearest(ss)

	var cfg := pc.duplicate(true)
	cfg["status_id"] = str(d.get("status", ""))
	cfg["aoe_radius_px"] = aoe
	cfg["max_distance_px"] = 600.0

	# 甩到地图外：路上只有我自己摆的三个靶子，不会有真敌人掺进来
	var origin := Vector2(6000.0, 6000.0)
	var a := _dummy_at(origin + Vector2(80.0, 0.0))
	var b := _dummy_at(origin + Vector2(80.0, (hit_r + aoe) * 0.5))
	var other := _dummy_at(origin + Vector2(80.0, aoe * 3.0))

	var p: Node2D = load(PROJECTILE).new()
	_stage.add_child(p)
	p.global_position = origin
	p.call("setup", cfg, Vector2.RIGHT, 30, [], 16)
	_tick(p, 0.4, &"_physics_process")
	_check(int(a.hits) == 1, "正面目标中弹（实得 %d 次）" % int(a.hits))
	_check(a.status_ids == ["burning"], "命中把灼烧带给了目标（实得 %s）" % str(a.status_ids))
	_check(int(b.hits) == 1, "溅射半径内的第二个目标也挨了一下（实得 %d 次）" % int(b.hits))
	_check(b.status_ids == ["burning"], "溅射的那一发同样挂上灼烧")
	_check(int(other.hits) == 0, "半径外的目标不受溅射影响（实得 %d 次）" % int(other.hits))
	_kill_dummies()


## 索敌口径：aim_dir 认的是"这一招射程内最近的那个敌人"，不借普攻的锁。
## 期望值由 _nearest_enemy 独立扫一遍算出来，且真实敌人若恰好更近就跟着它走 ——
## 这条测的是"选最近"的规则本身，不是"打中我摆的那颗靶"。
func _aim_at_nearest(ss: SkillSystem) -> void:
	var rng := ss.range_of("ember_shot")
	_check(rng > 0.0, "余烬弹有射程读数（%.0fpx）" % rng)
	var pos := ss.global_pos()
	# 摆在"技能够得着、长枪够不着"那一段：这里普攻的锁是空的，旧实现会朝空地飞
	var target := _dummy_at(pos + Vector2(-rng * 0.6, rng * 0.5))
	var nearest := _nearest_enemy(pos, rng)
	_check(nearest == target, "射程内最近的就是这颗靶（%s）" % str(nearest))
	if nearest == null:
		return
	var want: Vector2 = (nearest.global_position - pos).normalized()
	var got := ss.aim_dir("ember_shot")
	_check(got.dot(want) > 0.999, "aim_dir 朝射程内最近的敌人（夹角 %.1f°）"
			% rad_to_deg(acos(clampf(got.dot(want), -1.0, 1.0))))

	# 关了自动普攻再要一次方向：旧实现此刻 unit.auto_target()=null，整发就偏了
	var player: Node = ss.unit
	var auto_before = player.get("auto_attack_on")
	player.call("set_auto_attack", false)
	var got_off := ss.aim_dir("ember_shot")
	player.call("set_auto_attack", bool(auto_before))
	_check(got_off.dot(want) > 0.999, "自动普攻关掉后索敌不变（夹角 %.1f°）"
			% rad_to_deg(acos(clampf(got_off.dot(want), -1.0, 1.0))))

	_kill_dummies()
	if _nearest_enemy(pos, rng) == null:
		var f = player.get("facing")
		var fb := ss.aim_dir("ember_shot")
		_check(f is Vector2 and fb.dot((f as Vector2).normalized()) > 0.999,
				"射程内没人时退回角色朝向（aim=%s facing=%s）" % [str(fb), str(f)])
	else:
		_say("  .. 场上射程内还有真敌人，空场回退这一条本轮跳过")


## 独立版的"射程内最近"：只看位置与 hp，故意不复用 SkillSystem.nodes_in_radius
## —— 拿被测代码算期望值，等于让它自己给自己判卷。
func _nearest_enemy(pos: Vector2, rng: float) -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for n in get_tree().get_nodes_in_group("enemies"):
		if not (n is Node2D):
			continue
		var hp = (n as Node2D).get("hp")
		if hp != null and float(hp) <= 0.0:
			continue
		var d: float = pos.distance_squared_to((n as Node2D).global_position)
		if d <= rng * rng and d < best_d:
			best_d = d
			best = n as Node2D
	return best


## 击退：aoe_self 段里的 knockback_px 原样传到 apply_knockback；没写这条键的招不推人
func _knockback(ss: SkillSystem) -> void:
	_say("--- 击退：按招覆盖全局 enemy.knockback_px ---")
	var kb_rocks := float(SkillSystem.def_of("falling_rocks").get("knockback_px", 0.0))
	var kb_quake := float(SkillSystem.def_of("quake_split").get("knockback_px", 0.0))
	_check(kb_rocks > 0.0 and kb_quake > kb_rocks,
			"两招土系各带自己的击退距离（%.0f / %.0f px）" % [kb_rocks, kb_quake])
	ss.set_known({"falling_rocks": 1, "quake_split": 1, "frost_nova": 1})
	var pos := ss.global_pos()

	# 摆在正下方 60px：两招的半径（140 / 190）都够得着，推的方向也就唯一
	ss.reset()
	var rocks := _dummy_at(pos + Vector2(0.0, 60.0))
	var rocks_from := rocks.global_position
	_check(ss.cast("falling_rocks"), "落石放出去了")
	_check(is_equal_approx(rocks.kb_dist, kb_rocks),
			"落石把 %.0fpx 原样传了下去（实得 %.0f）" % [kb_rocks, rocks.kb_dist])
	_check(rocks.global_position.distance_to(rocks_from + Vector2(0.0, kb_rocks)) < 0.5,
			"靶子确实被推到正下方 %.0fpx 外（实到 %s）" % [kb_rocks, str(rocks.global_position)])
	_check(rocks.status_ids == ["stun"], "落石顺手挂上眩晕（实得 %s）" % str(rocks.status_ids))
	_kill_dummies()

	ss.reset()
	var quake := _dummy_at(pos + Vector2(0.0, 60.0))
	_check(ss.cast("quake_split"), "地裂放出去了")
	_check(is_equal_approx(quake.kb_dist, kb_quake),
			"同一套代码，地裂推得更远（%.0fpx）" % kb_quake)
	_kill_dummies()

	# 负对照：冰爆段里没写 knockback_px → 取 defaults 的 0 → 一下都不推
	ss.reset()
	var plain := _dummy_at(pos + Vector2(0.0, 60.0))
	var plain_from := plain.global_position
	_check(ss.cast("frost_nova"), "冰爆放出去了")
	_check(int(plain.hits) == 1, "冰爆照样打得到它（击退没把命中也一起关掉）")
	_check(is_equal_approx(plain.kb_dist, 0.0) and plain.global_position == plain_from,
			"没写 knockback_px 的招一格都不推（实得 %.0f）" % plain.kb_dist)
	_kill_dummies()


## 负对照：总开关关掉 = 整条管线摘掉，一个字节都不该动
func _negative(player: Node, ss: SkillSystem) -> void:
	_say("--- 负对照：skills.enabled=false ---")
	ss.set_known({"frost_nova": 1})
	ss.reset()
	var d := _dummy_at(ss.global_pos() + Vector2(30.0, 0.0))
	_check(ss.cast("frost_nova"), "开关开着时先放掉一发，留下冷却读数")
	var hits := int(d.hits)
	var base := ss.cooldown_left("frost_nova")
	_check(base > 0.0, "刚放完确实有冷却（%.2fs）" % base)

	Config.set_override("skills.enabled", false)
	var noise_before := NoiseSystem.peak_noise
	for i in range(60):
		ss.tick(1.0 / 60.0)
	_check(not ss.can_cast("frost_nova"), "关开关后 can_cast=false")
	_check(not ss.cast("frost_nova"), "关开关后 cast 放不出去")
	_check(int(d.hits) == hits, "关开关后 tick 里一次自动释放都没有（多 %d 次）"
			% (int(d.hits) - hits))
	_check(NoiseSystem.peak_noise == noise_before, "关开关后噪音表纹丝不动")
	_check(ss.cooldown_left("frost_nova") == base, "关开关后连冷却都不推进")
	Config.clear_override("skills.enabled")
	ss.reset()
	_check(ss.cast("frost_nova"), "重新打开开关就又能放了")
	_kill_dummies()


## F：局内学 → 撤离才永久
func _persist(player: Node, ss: SkillSystem) -> void:
	_say("--- F 段：撤离才永久 + 存档 round-trip ---")
	Meta.roster = []
	Meta.seeded_ids = []
	Meta.ensure_roster()
	var uid := int(player.get("roster_uid"))
	_check(uid > 0, "场上这名角色有名册身份（uid=%d）" % uid)
	if uid <= 0:
		return
	var max_lv := int(Config.get_value("skills.progression.max_level", 5))

	ss.reset()
	ss.set_known({})
	_check(Meta.skills_of(uid).is_empty(), "开局：名册里这个人一招不会")
	_check(bool(ss.learn("frost_nova").get("ok", false)), "局内学会 frost_nova")

	# 一招没学的人不能把名册里已有的技能清空（否则白打一局反而倒退）
	Meta.set_skills(uid, {"ember_shot": 2})
	var keep := ss.known.duplicate()
	ss.known.clear()
	Meta.bank_skills_from_survivors()
	ss.known = keep
	_check(Meta.skills_of(uid) == {"ember_shot": 2},
			"这局没学新东西 → 名册里已有的技能原样保留（实得 %s）" % str(Meta.skills_of(uid)))

	# 撤离结算：活人身上的 known 抄回名册
	Meta.set_skills(uid, {})
	ss.set_known({"frost_nova": 3, "ember_shot": 1})
	Meta.bank_skills_from_survivors()
	_check(Meta.skills_of(uid) == {"frost_nova": 3, "ember_shot": 1},
			"撤离成功 → 局内学的招进名册（实得 %s）" % str(Meta.skills_of(uid)))

	# 阵亡不写
	var was_dead = player.get("_dead")
	Meta.set_skills(uid, {})
	player.set("_dead", true)
	Meta.bank_skills_from_survivors()
	player.set("_dead", was_dead)
	_check(Meta.skills_of(uid).is_empty(), "阵亡的角色一个字节都不写（死了就是白学）")

	# 清洗：死 id 与越界等级
	Meta.set_skills(uid, {"frost_nova": 1, "no_such_skill": 3, "ember_shot": 99})
	var clean := Meta.skills_of(uid)
	_check(clean.has("frost_nova") and not clean.has("no_such_skill"),
			"_sanitize_skills 丢掉技能表里已删的 id（实得 %s）" % str(clean))
	_check(int(clean.get("ember_shot", 0)) == max_lv,
			"越界等级钳到 max_level（实得 %s）" % str(clean.get("ember_shot", "?")))

	# 读档路径也走同一份清洗 + 存盘读档一轮不丢
	var snapshot := Meta.skills_of(uid)
	Meta.save_game()
	Meta.roster = Meta._sanitize_roster([
		{"uid": uid, "id": str(Meta.unit_by_uid(uid).get("id", "")), "name": "x",
			"skills": {"frost_nova": 99, "ghost": 2}}])
	_check(Meta.skills_of(uid) == {"frost_nova": max_lv},
			"读档清洗同样钳等级、删死 id（实得 %s）" % str(Meta.skills_of(uid)))
	Meta.load_save()
	_check(Meta.skills_of(uid) == snapshot,
			"存盘 → 读档一轮技能表不变（%s → %s）" % [str(snapshot), str(Meta.skills_of(uid))])


func _rings_under(player: Node) -> int:
	var parent := player.get_parent()
	var c := 0
	if parent == null:
		return 0
	for k in parent.get_children():
		var sc = k.get_script()
		if sc != null and str(sc.resource_path).ends_with("fx_ring.gd") \
				and not (k as Node).is_queued_for_deletion():
			c += 1
	return c


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


func _finish() -> void:
	_restore_save()
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for msg in _fails:
		_say("  !! " + msg)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	for l in _lines:
		print(str(l))
	print("[probe_skills] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

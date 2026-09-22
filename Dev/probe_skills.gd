extends Node2D
## ============================================================
## probe_skills — 技能系统全链路（2026-09-21）
##
## 七段，顺序刻意排成"先纯表、再纯逻辑、最后进场"：
##   A) skills.json 自洽：技能数 ≥ 槽数、带热键的招互不撞号且都落在 allowed_keys 里
##      （没写 key 的招只能自动释放）、每招引用的特效 id / 五行 / 状态 id 全在各自的
##      表里。接线写错在运行时是"静默不放技能"，实拍极难看出来，只能靠这里兜。
##   B) 状态容器（UnitStatus）：冻结停 AI + 速度归零、到期挂免疫期、灼烧按 tick
##      跳血且伤害随层数涨、叠层有上限、增益乘数合成、未知 id 不生效。
##   C) 学习与成长（SkillSystem 纯逻辑，不需要宿主）：槽位上限、重复学习升级、
##      满级后再学不涨、set_known 丢掉表里已删的 id、成长公式三个方向都对。
##   D) 真身进局：冷却、自动释放的门槛（射程内没敌人就不放）、一发落地打到人 +
##      挂上状态 + 计入噪音表、地面圈落一份、冷却一到自动补一发、护盾减伤算术、
##      圣光十字当场回血（含过量夹住与满级成长）、嗜血让三个出手点都回血、
##      狂战面具把"增伤"和"更挨打"写在同一层、疾风羽只改腿（第一招 auto_cast=false）、
##      缓滞/定身只拖腿不停 AI（停与晕的分界）、易伤真的让敌人承伤变高（敌方出口）、
##      牵引与击退走同一句 apply_knockback 的两个方向、每招占住的「最」字全池排一次。
##   E) 弹道：索敌口径（射程内最近的那个，与普攻的锁无关）、技能自带 projectile 段、
##      状态随命中传递、aoe_radius_px 溅到第二个、半径外的不打；多重弹幕（一次出手
##      放数发、绕瞄准方向对称摊开、逐发各抽一次伤害、发声与冷却仍按"一次"记）。
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
## 技能弹道的身份分组，与 player.gd 的 SKILL_PROJECTILE_GROUP 是同一个字符串
## （player.gd 没有 class_name，引用不到它的常量，改那边要同时改这里）。
## 计数认分组而不是节点名：多重弹幕一次出手数发同名节点，Godot 会把第 2 发起改名成
## SkillProjectile2/3/4，按名字精确匹配就数少了 —— 这一段最初挂成"实得 0 发"就是这个因。
const SKILL_PROJECTILE_GROUP := "skill_projectile"
const LOOT_SCENE := "res://Scenes/LootNode.tscn"
const OUT := "user://_probe_skills.txt"
const SAVE_PATH := "user://save.json"
const KEY_MIN := 49        # KEY_1（2026-09-21 用 --script 探针实测：KEY_1=49…KEY_9=57）
const KEY_MAX := 57        # 数字键那一段：49..57 = 键盘 1~9。热键的**合法集合**从这一版起
                           # 由 skills.allowed_keys 说了算（A 段断言），这里只留两个端点给
                           # "头九招仍用数字键"那条可读性断言用。
## 写死在脚本里的按键（不是配置项，探针读不到，只能照实列出来）：相机键盘平移 WASD、
## 面板关/交互 E、跑完重开 R。技能键要是撞上它们，表现是"按了没反应"，实拍最难看出来，
## 所以 allowed_keys 必须与这几个不相交（A 段兜）。
const SCRIPT_HELD_KEYS := {65: "A", 68: "D", 87: "W", 83: "S", 69: "E", 82: "R"}
const HIT := 40            # 护盾算术那一段用的测试伤害（要大于裸防御才有意义）
## 伤害的天花板只是**配表防呆**，不是可调项：现有最痛的一招是 26，多写一个零会当场红。
## 真要设计一张 500 伤的招，改的是这条断言而不是配置——这正是它存在的意义。
const DMG_CEIL := 200

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


## buff 型到底做没做事：治疗量、四条乘数里任意一条非零就算。
## 口径跟 _cast_buff 一字不差：damage_reduction 在那边是直接读技能段的（不走 defaults
## 兜底），所以这里也直接读；heal_flat / lifesteal / damage_bonus / speed_bonus 走 param。
func _buff_does_something(id: String, d: Dictionary) -> bool:
	if float(d.get("damage_reduction", 0.0)) != 0.0:
		return true
	if SkillSystem.param(id, "heal_flat") > 0.0:
		return true
	for k in ["lifesteal", "damage_bonus", "speed_bonus"]:
		if not is_zero_approx(SkillSystem.param(id, str(k))):
			return true
	return false


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

	# 热键的合法集合写在配置里（allowed_keys），别的系统用掉的键也全在配置里 ——
	# 探针一条都不写死，改了键位这张嘴就跟着改口径。
	var allowed_raw = Config.get_value("skills.allowed_keys", [])
	var allowed: Array = []
	if allowed_raw is Array:
		for v in allowed_raw:
			allowed.append(int(v))
	_check(allowed.size() > 0,
			"skills.allowed_keys 是一张非空表（实得 %d 个键码）" % allowed.size())
	var reserved := {}
	## 路径是合并后那棵树的真实位置：**域文件名不是前缀**（combat.json 里恰好有个顶层
	## combat 段，看着像前缀其实不是）。曾按 "player.camera.return_key" 去读，四条全部
	## 落到默认值 -1，于是"热键不撞号"这条防线静默漏掉一半。所以逐项断言读得到键码。
	for p in [["combat.input.dodge_key", "冲刺 Space"], ["camera.return_key", "相机回中 F"],
			["survival.eat_key", "进食 H"], ["base.custom_editor.toggle_key", "地面编辑器 B"],
			["debug.stat_panel_key", "数值栏 F9"]]:
		var code := int(Config.get_value(str(p[0]), -1))
		_check(code > 0, "别系统的热键读得到真实键码：%s = %d（%s）" % [str(p[0]), code, str(p[1])])
		reserved[code] = str(p[1])

	var effects: Dictionary = Config.get_value("fx.effects", {})
	# elements / statuses 两张表里各有一条 _comment 给人看的字符串 —— 只数真定义
	# （SkillSystem.all_defs() 也是这么筛的，口径要一致）。
	var elements := _dicts_of(Config.get_value("skills.elements", {}))
	var statuses := _dicts_of(Config.get_value("skills.statuses", {}))
	_check(elements.size() == 5, "五行齐全（实得 %d）" % elements.size())
	_check(statuses.size() >= 3, "状态表非空（实得 %d 条：%s）"
			% [statuses.size(), ", ".join(statuses.keys())])
	# 没人施加的状态行 = 死配置：这条不点名任何 id，表里加一条就自动多查一条。
	var unused: Array = []
	for sid in statuses.keys():
		var claimed := false
		for raw_id in defs.keys():
			if str((defs[raw_id] as Dictionary).get("status", "")) == str(sid):
				claimed = true
				break
		if not claimed:
			unused.append(str(sid))
	_check(unused.is_empty(), "每一条状态都有技能真的挂得上：%s"
			% ["全有人用" if unused.is_empty() else str(unused) + " 无人施加"])

	var bad: Array = []
	var seen_keys := {}
	var keyless := 0
	var el_used := {}
	var ty_used := {}
	for raw_id in defs.keys():
		var id := str(raw_id)
		var d: Dictionary = defs[raw_id]
		if str(d.get("name", "")) == "":
			bad.append("%s 缺 name" % id)
		var el := str(d.get("element", ""))
		el_used[el] = int(el_used.get(el, 0)) + 1
		if not elements.has(el):
			bad.append("%s 的属性 %s 不在 skills.elements" % [id, el])
		elif not Color(str((elements[el] as Dictionary).get("color", ""))).a > 0.0:
			bad.append("%s 的属性色解析不出" % id)
		var t := str(d.get("type", ""))
		ty_used[t] = int(ty_used.get(t, 0)) + 1
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
		# 热键从这一版起是**可选**的：合法键码只有 26 个，池子迟早比键多。
		# 没写 key = 这一招只能自动释放（手动抢放要等"按键绑槽位"那一次改造）。
		var k := int(d.get("key", 0))
		if k == 0:
			keyless += 1
		elif not allowed.has(k):
			bad.append("%s 的热键 %d 不在 skills.allowed_keys" % [id, k])
		elif seen_keys.has(k):
			bad.append("%s 的热键 %d 与 %s 撞号" % [id, k, str(seen_keys[k])])
		else:
			seen_keys[k] = id
		# ---- 数值与结构兜底：配表手滑要在探针里红，不该等实拍 ----
		# 全部按 SkillSystem.param 的口径读（技能段 → skills.defaults 两级回退）：
		# 直接 d.get() 会把"没写 cooldown_seconds、拿默认 8 秒"这种合法写法误判成 0。
		if SkillSystem.param(id, "cooldown_seconds") <= 0.0:
			bad.append("%s 冷却<=0（这招会每 0.15 秒刷一次）" % id)
		if SkillSystem.param(id, "noise") <= 0.0:
			bad.append("%s 噪音<=0（放招不进噪音表 = 潜行玩法静默失效）" % id)
		if float(d.get("drop_weight", 0.0)) <= 0.0:
			bad.append("%s drop_weight<=0（魔法书永远掷不到它）" % id)
		var dmg := SkillSystem.param(id, "damage")
		if dmg < 0.0 or dmg > DMG_CEIL:
			bad.append("%s 伤害 %.0f 不在 0..%d（多半是多写了一个零）" % [id, dmg, DMG_CEIL])
		if t == "aoe_self" and SkillSystem.param(id, "radius_px") <= 0.0:
			bad.append("%s 是范围型却没有 radius_px" % id)
		# 位移两条键互斥：_cast_aoe 里是 if/elif（推优先），所以"又推又拉"不是配出了
		# 一个漩涡 + 冲击波，而是配了一条永远读不到的死数值 —— 那正是本项目最恨的那种写法。
		if SkillSystem.param(id, "knockback_px") > 0.0 \
				and SkillSystem.param(id, "pull_px") > 0.0:
			bad.append("%s 同时写了 knockback_px 与 pull_px（代码里推赢，拉的那条是死数值）" % id)
		if t == "projectile":
			var pdir: Dictionary = d.get("projectile", {})
			var tex := str(pdir.get("texture", ""))
			if tex == "" or not ResourceLoader.exists(tex):
				bad.append("%s 的弹道贴图不在位：%s" % [id, tex])
		if t == "buff" and not _buff_does_something(id, d):
			bad.append("%s 是 buff 型但既没治疗量也没有任何乘数（放了等于没放）" % id)
	_check(bad.is_empty(), "池里每一招的字段与数值全部接得到真表、落得进区间：%s"
			% ["无问题" if bad.is_empty() else str(bad)])
	# 覆盖面：池子越大越怕"整片都是同一种招"——下面这两条只在结构上兜，不规定配比。
	_check(el_used.size() == elements.size(), "五行每一行都有人用：%s" % str(el_used))
	_check(ty_used.size() == 3, "三种 type 各有招：%s" % str(ty_used))
	_check(seen_keys.size() >= slots,
			"带热键的招够填满身上所有槽位：%d 招带键 ≥ %d 槽（没写 key 的 %d 招只能自动释放）"
			% [seen_keys.size(), slots, keyless])

	# 热键白名单自己也要成立：它现在管着"哪些键算合法"，表写坏了不等于崩，
	# 而是某些槽位永远按不动 —— 所以撞号/撞别的系统的键都得在这里红掉。
	var k_bad: Array = []
	var seen_allowed := {}
	for raw_k in allowed:
		var k := int(raw_k)
		if seen_allowed.has(k):
			k_bad.append("白名单里 %d 出现两次" % k)
		else:
			seen_allowed[k] = true
		if SCRIPT_HELD_KEYS.has(k):
			k_bad.append("%d 是脚本里写死的 %s 键" % [k, str(SCRIPT_HELD_KEYS[k])])
		if reserved.has(k):
			k_bad.append("%d 被别的系统用着（%s）" % [k, str(reserved[k])])
	_check(allowed.size() >= seen_keys.size(),
			"allowed_keys 装得下所有带键的招：%d 个键 ≥ %d 招（其余 %d 招只自动释放）"
			% [allowed.size(), seen_keys.size(), keyless])
	_check(k_bad.is_empty(), "白名单不与任何现有按键打架：%s"
			% ["无问题" if k_bad.is_empty() else str(k_bad)])
	var digits_ok := allowed.size() >= KEY_MAX - KEY_MIN + 1
	for i in range(KEY_MIN, KEY_MAX + 1):
		if digits_ok and int(allowed[i - KEY_MIN]) != i:
			digits_ok = false
	_check(digits_ok, "头九个键仍是数字 1~9（%d..%d 原样在前），老招的热键没被挪走"
			% [KEY_MIN, KEY_MAX])

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

	# 状态表按批长大，最容易长出来的东西是"又一条其实和某条一样的状态"：
	# 定身/眩晕、缓滞/冻结 只要数值抄一遍就是两条同一条。这把尺不点名，
	# 把每条除 name/_comment 之外的字段摊成签名两两比 —— 冻结与眩晕本来就该过
	# （时长与解冻免疫期不同），完全同签名才红。
	var dup_bad: Array = []
	var sigs := {}
	for raw_id in statuses.keys():
		var sd: Dictionary = statuses[raw_id]
		var parts: Array = []
		for fk in sd.keys():
			if str(fk) == "name" or str(fk) == "_comment":
				continue
			parts.append("%s=%s" % [str(fk), str(sd[fk])])
		parts.sort()
		var sig := " ".join(parts)
		if sigs.has(sig):
			dup_bad.append("%s 与 %s 除了名字以外逐字段相同" % [str(raw_id), str(sigs[sig])])
		else:
			sigs[sig] = str(raw_id)
	_check(dup_bad.is_empty(), "状态表里没有两条是同一条：%s"
			% ["各自有分工" if dup_bad.is_empty() else str(dup_bad)])

	# 缺省表：脚本里不写死数值 = 代码会读的每个 defaults 键都得真的存在
	var need: Array = ["cooldown_seconds", "noise", "auto_cast", "auto_cast_targets_min",
			"range_px", "shock_ring_seconds", "knockback_px", "damage", "heal_flat",
			"lifesteal", "damage_bonus", "speed_bonus", "projectile_count", "spread_deg",
			"status", "crit_chance", "crit_multiplier", "variance"]
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

	_say("  · 持续伤害状态逐条结算（表里有几条验几条，不点名 id）")
	var dot_raw := _dicts_of(Config.get_value("skills.statuses", {}))
	var dot_n := 0
	for sid in dot_raw.keys():
		var sd: Dictionary = dot_raw[sid]
		var iv := float(sd.get("tick_interval_seconds", 0.0))
		var per := int(sd.get("damage_per_tick", 0))
		if iv <= 0.0 or per <= 0:
			continue      # 不是持续伤害（冻结/眩晕那类只看 speed_mult 与 halt_ai）
		dot_n += 1
		var sdur := float(sd.get("duration_seconds", 0.0))
		var want_ticks := int(sdur / iv)
		var u := UnitStatus.new()
		var calls: Array = []
		u.dot_handler = func(amount: int) -> void: calls.append(amount)
		_check(u.apply(str(sid)), "%s 施加成功" % str(sid))
		var dealt := u.tick(sdur)
		_check(calls.size() == want_ticks,
				"%s %.1fs / 每 %.1fs 一跳 = %d 跳（实得 %d）"
				% [str(sid), sdur, iv, want_ticks, calls.size()])
		_check(dealt == want_ticks * per,
				"%s 一跳 %d 伤 × %d 跳 = 累计 %d（实得 %d）"
				% [str(sid), per, want_ticks, want_ticks * per, dealt])
		_check(u.is_empty(), "%s 跳完自己结束" % str(sid))

		var cap := maxi(1, int(sd.get("max_stacks", 1)))
		var c := UnitStatus.new()
		var hits2: Array = []
		c.dot_handler = func(amount: int) -> void: hits2.append(amount)
		for i in range(cap + 3):
			c.apply(str(sid))
		_check(c.stacks_of(str(sid)) == cap,
				"%s 叠到 max_stacks 就顶住（实得 %d 层 / 上限 %d）"
				% [str(sid), c.stacks_of(str(sid)), cap])
		c.tick(iv)
		_check(hits2.size() == 1 and int(hits2[0]) == per * cap,
				"%s 层数真的进每跳伤害（实得 %s）" % [str(sid), str(hits2)])
	_check(dot_n >= 3,
			"表里 %d 条持续伤害状态全部走完了上面这把尺（少于 3 条说明有状态漏了 tick 字段）" % dot_n)

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
	_say("--- D 段：真身进局（门槛 / 冷却 / 自动释放 / 噪音 / 护盾 / 治疗 / 吸血 / 增伤 / 加速 / 弹幕 / 中毒 / 流血 / 缓滞 / 定身 / 易伤 / 牵引 / 全池最值）---")
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
	_volley(player, ss)
	_knockback(ss)
	_sustain(player, ss)
	_boons(player, ss)
	_toxin(ss)
	_control(ss)
	_extremes(ss)
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


## E 段续：多重弹幕 —— 一次出手放出数发，绕着瞄准方向**对称**摊开，每发自己抽一次伤害。
## 两处口径是这一段踩过的坑，都写死在这里：
##   · 数发数认 skill_projectile **分组**，不认节点名 —— Godot 要求兄弟不重名，
##     第二发起会自动变成 SkillProjectile2/3/4，按名字精确匹配会数成"实得 0 发"；
##   · 只数**这一次出手造出来的**那些（按子节点实例 id 差集），不是事后整片扫 ——
##     场上有 250 个敌人乱逛，自动释放随时替我们放掉一发，混进来就把"三发对称"
##     读成了"两发同侧"。全段一个 await 都不给：这些弹道一帧都没跑就被数完放掉，
##     不会真飞出去打到场上的敌人。
func _volley(player: Node, ss: SkillSystem) -> void:
	_say("--- 多重弹幕：一次出手放数发，扇形对称摊开、逐发抽伤害 ---")
	var parent: Node = player.get_parent()
	var cd := SkillSystem.def_of("cinder_sparks")
	var ld := SkillSystem.def_of("leaf_blade")
	_check(int(SkillSystem.param("cinder_sparks", "projectile_count")) == 3
			and is_equal_approx(SkillSystem.param("cinder_sparks", "spread_deg"), 34.0),
			"火星溅表里写着 3 发 / 一共摊开 34°")
	_check(not cd.has("aoe_radius_px") and not ld.has("aoe_radius_px"),
			"两招弹幕都不写溅射半径：三发各打各的，落点再各炸一次等于把扇面白摊")
	_check(int(SkillSystem.param("ember_shot", "projectile_count")) == 1
			and is_equal_approx(SkillSystem.param("ember_shot", "spread_deg"), 0.0),
			"没写这两个键的老招仍按单发走（defaults 兜住 = 加机制不改老数值）")
	# 计数口径自己也要验：分组漏挂的话，下面每一条"实得 0 发"都会读成"机制没生效"。
	# 此刻场上有什么照实说（普攻那发在另一个来源里，不带这个分组）。
	print("[probe_skills]   进场时场上已有技能弹道 %d 个（自动释放的残留，不参与本段计数）"
			% _skill_projectiles(parent).size())

	# 先验单发那招：改的是发射循环，最怕把没动过的招一起改坏
	ss.set_known({"ember_shot": 1})
	ss.reset()
	var single_aim := ss.aim_dir("ember_shot")
	var pre_one := _cast_gates(ss, player, "ember_shot")
	var e := _cast_count(ss, parent, "ember_shot")
	_check(bool(e["ok"]), "余烬弹出手（projectile_count 缺省 1）%s" % pre_one)
	var one: Array = e["created"]
	_check(one.size() == 1, "这一次出手放出 1 发（实得 %d 发）" % one.size())
	if one.size() == 1:
		var one_dir: Vector2 = one[0].get("dir")
		_check(absf(single_aim.angle_to(one_dir)) < 0.001, "这一发也正对瞄准方向")
	_free_projectiles(one)

	# 火星溅：三发、对称、共用一次冷却与一次发声
	ss.set_known({"cinder_sparks": 1})
	ss.reset()
	var aim := ss.aim_dir("cinder_sparks")
	# 噪音表要先清场：自身噪音要乘「世界噪音增益」，不归零就量不出"一次出手记几笔"
	var world_before := NoiseSystem.world_noise
	NoiseSystem.world_noise = 0.0
	player.set("self_noise", 0.0)
	# 门槛读数要在 cast **之前**抄：cast 一成功就把冷却填上，事后再看永远是"冷却中"。
	var pre := _cast_gates(ss, player, "cinder_sparks")
	var v := _cast_count(ss, parent, "cinder_sparks")
	var want_noise := float(cd.get("noise", 0.0)) \
			* NoiseSystem.player_noise_multiplier(ss.global_pos())
	var got_noise := float(player.get("self_noise"))
	NoiseSystem.world_noise = world_before
	_check(bool(v["ok"]), "火星溅出手：一次 cast，不是三次%s" % pre)
	var shots: Array = v["created"]
	_check(shots.size() == 3, "一次出手放出 3 发（实得 %d 发）" % shots.size())
	_check(got_noise > 0.0 and got_noise < want_noise * 1.5,
			"三发只算一次发声：噪音涨了 %.0f（表值 %.0f，按发记会是 %.0f）"
			% [got_noise, want_noise, want_noise * 3.0])
	if shots.size() == 3:
		var offs := _fan_offsets(shots, aim)
		var worst := 0.0
		for i in 3:
			worst = maxf(worst, absf(offs[i] - [-17.0, 0.0, 17.0][i]))
		_check(worst <= 0.6, "三发绕瞄准方向对称摊开：实测 %s°（期望 −17/0/+17，最大偏差 %.2f°）%s"
				% [_fmt_deg(offs), worst, _dirs_note(shots, aim)])
		var sid_ok := true
		for s in shots:
			if str(s.get("_status_id")) != "burning":
				sid_ok = false
		_check(sid_ok, "三发各自都带着灼烧（多发最容易漏成只有头一发认得状态）")
	_free_projectiles(shots)

	# 逐发抽伤害：把同一招出手几十轮，看有没有哪一轮里三发数字不全一样。
	# 一轮三发全同的概率约 3%，40 轮下来"一次都没出现过不同"是 1e-25 量级 —— 不是碰运气。
	var base := ss.damage_of("cinder_sparks")
	var varc := SkillSystem.param("cinder_sparks", "variance")
	var lo := int(floor(base * (1.0 - varc)))
	var hi := int(ceil(base * (1.0 + varc)))
	var rounds := 0
	var fired := 0
	var varied := 0
	var outside := 0
	var wrong_size := 0
	var blocked := ""
	for _r in range(40):
		ss.reset()
		var round_res := _cast_count(ss, parent, "cinder_sparks")
		if not bool(round_res["ok"]):
			blocked = _cast_gates(ss, player, "cinder_sparks")
			continue
		rounds += 1
		var vals: Array = []
		for s in round_res["created"]:
			var dm := int(s.get("damage"))
			vals.append(dm)
			fired += 1
			if dm < lo or dm > hi:
				outside += 1
		if vals.size() != 3:
			wrong_size += 1
		_free_projectiles(round_res["created"])
		for i in range(1, vals.size()):
			if int(vals[i]) != int(vals[0]):
				varied += 1
				break
	_check(rounds == 40 and fired == rounds * 3 and wrong_size == 0,
			"40 轮出手每轮都放出 3 发（实得 %d 轮 / %d 发，%d 轮不是 3 发）%s"
			% [rounds, fired, wrong_size, blocked])
	_check(outside == 0,
			"每一发的伤害都落在单发面板的方差带里（%.0f±%.0f%% = %d..%d，越界 %d 发）"
			% [base, varc * 100.0, lo, hi, outside])
	_check(varied > 0, "同一轮里三发可以打出不同数字（%d/%d 轮出现了不同）→ 逐发抽，不是抽一个数复制三份"
			% [varied, rounds])

	# 落叶刃：两发、窄扇面、带眩晕 —— 与火星溅的分工是"一定打得到"，不是面杀伤
	ss.set_known({"leaf_blade": 1})
	ss.reset()
	var laim := ss.aim_dir("leaf_blade")
	var pre_leaf := _cast_gates(ss, player, "leaf_blade")
	var lv := _cast_count(ss, parent, "leaf_blade")
	_check(bool(lv["ok"]), "落叶刃出手%s" % pre_leaf)
	var leaves: Array = lv["created"]
	_check(leaves.size() == 2, "落叶刃放出 2 发（实得 %d 发）" % leaves.size())
	if leaves.size() == 2:
		var lo2 := _fan_offsets(leaves, laim)
		_check(absf(lo2[0] + 8.0) <= 0.6 and absf(lo2[1] - 8.0) <= 0.6,
				"两发左右各偏 8°（实测 %s°）= 表里 16° 的一半对称%s"
				% [_fmt_deg(lo2), _dirs_note(leaves, laim)])
		_check(str(leaves[0].get("_status_id")) == "stun"
				and str(leaves[1].get("_status_id")) == "stun",
				"两发都带眩晕（木系配控制：那招要的是打断，不是叠 DoT）")
	_free_projectiles(leaves)
	_check(int(SkillSystem.param("leaf_blade", "cooldown_seconds")) \
			< int(SkillSystem.param("cinder_sparks", "cooldown_seconds")),
			"控制招的冷却比弹幕招短：%s / %s" % [str(ld.get("cooldown_seconds")),
					str(cd.get("cooldown_seconds"))])


## 放一招，并且只交出**这一次出手**新增的技能弹道（按父节点子实例 id 的差集认）。
## 返回 {ok: 是否放出去, created: 这几发, live: 此刻场上总共几个}。
## 为什么不用分组整片扫：见 _volley 头上第二条。
func _cast_count(ss: SkillSystem, parent: Node, id: String) -> Dictionary:
	var before: Array = []
	for c in parent.get_children():
		before.append(c.get_instance_id())
	var ok := ss.cast(id)
	var created: Array = []
	for c in parent.get_children():
		if before.has(c.get_instance_id()) or not c.is_in_group(SKILL_PROJECTILE_GROUP):
			continue
		created.append(c)
	return {"ok": ok, "created": created, "live": _skill_projectiles(parent).size()}
## cast 放不出去时把三道门槛逐个摊开（要在 cast **之前**抄一份，成功之后冷却就自己填上了）。
## 只写"放不出去"的话，下一轮还得重跑一遍才知道卡在哪一道 —— 这一段就反复过两次。
func _cast_gates(ss: SkillSystem, player: Node, id: String) -> String:
	var bits: Array = []
	if not ss.known.has(id):
		bits.append("没学会")
	var left := float(ss._cooldown.get(id, 0.0))
	if left > 0.0:
		bits.append("冷却还剩 %.2fs" % left)
	if player.has_method("is_dead") and bool(player.call("is_dead")):
		bits.append("角色已死")
	if bits.is_empty():
		return ""
	return "（放不出去：%s）" % "、".join(bits)


## 场上还没释放的技能弹道（player.gd 给每一发挂上 skill_projectile 分组）。
## 必须滤掉已排队释放的：queue_free 要到帧末才真摘掉，同一帧里连放两轮会数重。
func _skill_projectiles(parent: Node) -> Array:
	var out: Array = []
	for c in parent.get_children():
		if c.is_in_group(SKILL_PROJECTILE_GROUP) and not c.is_queued_for_deletion():
			out.append(c)
	return out


func _free_projectiles(list: Array) -> void:
	for p in list:
		(p as Node).queue_free()


## 每一发相对瞄准方向偏了多少度（带符号：两翼一正一负），排好序才对着表读。
## 这里自己用 atan2(叉积, 点积) 算，不套 angle_to()：angle_to **本来就是**带符号的
## （atan2 口径），曾以为它无符号又用叉积补了一次符号 = 翻两遍，三发 73°/90°/107°
## 会被读成 -17/-17/0，"对称摊开"这条永远红。引擎语义拿不准时就把公式写出来。
func _fan_offsets(shots: Array, aim: Vector2) -> Array:
	var offs: Array = []
	for s in shots:
		var d: Vector2 = s.get("dir")
		offs.append(rad_to_deg(atan2(aim.x * d.y - aim.y * d.x, aim.dot(d))))
	offs.sort()
	return offs


## 失败时把原始读数摊开：瞄准向量 + 每一发自己的方向（按出手顺序，不排序）。
## 只有"实测偏移"的话，分不清是弹道不对称还是参考方向本身就取错了。
func _dirs_note(shots: Array, aim: Vector2) -> String:
	var parts: Array = []
	for s in shots:
		var d: Vector2 = s.get("dir")
		parts.append("%.0f°" % rad_to_deg(d.angle()))
	return "｜瞄准 %.0f° %s，各发绝对角 %s" % [rad_to_deg(aim.angle()), str(aim), ", ".join(parts)]


func _fmt_deg(offs: Array) -> String:
	var parts: Array = []
	for o in offs:
		parts.append("%.1f" % float(o))
	return ", ".join(PackedStringArray(parts))


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


## 治疗 / 吸血：两条新机制各自的算术，加上"我方三个出手点都认同一句回血"的接线
func _sustain(player: Node, ss: SkillSystem) -> void:
	_say("--- 治疗 / 吸血：圣光十字当场回一口，嗜血让每次出手都回血 ---")
	var hc := SkillSystem.def_of("holy_cross")
	var bh := SkillSystem.def_of("blood_hunger")
	var heal1 := float(hc.get("heal_flat", 0.0))
	var ls := float(bh.get("lifesteal", 0.0))
	_check(heal1 > 0.0 and not hc.has("buff_duration_seconds"),
			"圣光十字是一次性治疗（回 %.0f 血，表里没有时长这一键）" % heal1)
	_check(ls > 0.0 and ls <= 1.0 and float(bh.get("buff_duration_seconds", 0.0)) > 0.0,
			"嗜血是一层有时限的 %.0f%% 吸血" % (ls * 100.0))
	var st := player.get("_statuses") as UnitStatus
	st.clear()
	var max_hp := int(player.max_hp)

	# 治疗走真身。血量钉低 → 放招，两句之间不 await：中间插一帧自动释放就会把
	# 这一口的数读成别的招的。
	ss.set_known({"holy_cross": 1, "blood_hunger": 1, "falling_rocks": 1})
	player.hp = maxi(int(max_hp * 0.3), 1)
	ss.reset()
	var before := int(player.hp)
	_check(ss.cast("holy_cross"), "圣光十字放出去了")
	_check(int(player.hp) - before == int(round(heal1)),
			"1 级回 %d 血（HP %d → %d）" % [int(round(heal1)), before, int(player.hp)])

	player.hp = max_hp - 5
	ss.reset()
	_check(ss.cast("holy_cross"), "只剩 5 点血时再放一次")
	_check(int(player.hp) == max_hp,
			"过量治疗夹满在 %d 而不是溢出（heal() 那一份实现负责夹）" % max_hp)

	# 升级成长单独一档：治疗招升的是"回得更多"，不是借用伤害那条曲线
	var top := int(Config.get_value("skills.progression.max_level", 5))
	ss.set_known({"holy_cross": top})
	ss.reset()          # 上一发的 13 秒冷却还挂着，不清就放不出去
	player.hp = 1
	var want := int(round(ss.heal_of("holy_cross")))
	_check(ss.cast("holy_cross"), "满级圣光十字放出去了")
	_check(int(player.hp) == 1 + want and want > int(round(heal1)),
			"满级回 %d 血（1 级 %d，HP 1 → %d）：成长读的是 progression.heal_per_level"
			% [want, int(round(heal1)), int(player.hp)])

	# 嗜血：挂上之后每次出手回一口，比例从状态容器里读
	st.clear()
	player.hp = 1
	ss.set_known({"blood_hunger": 1})
	ss.reset()
	_check(ss.cast("blood_hunger"), "嗜血放出去了")
	_check(is_equal_approx(st.lifesteal_mult(), ls),
			"身上那层嗜血读出 %.0f%%（实得 %.0f%%）" % [ls * 100.0, st.lifesteal_mult() * 100.0])
	var hp_ls := int(player.hp)
	player.call("apply_lifesteal", 40)
	_check(hp_ls + int(round(40.0 * ls)) == int(player.hp),
			"打出 40 伤害回 %d 血（HP %d → %d，40 × %.0f%%）"
			% [int(round(40.0 * ls)), hp_ls, int(player.hp), ls * 100.0])

	# 范围技那条出口：按打出去的伤害算，不看目标扣完防御实际掉几滴
	var dummy := _dummy_at(ss.global_pos() + Vector2(0.0, 60.0))
	ss.set_known({"falling_rocks": 1})
	ss.reset()
	player.hp = 1
	_check(ss.cast("falling_rocks") and int(player.hp) > 1,
			"范围技那条出口也回血（HP 1 → %d，命中 %d 次）" % [int(player.hp), int(dummy.hits)])
	_kill_dummies()

	# 弹道那条出口：箭身上得带着射手，否则命中时无从回血（伤害仍在出膛那帧算好）
	st.clear()
	player.hp = 1
	var pc: Dictionary = SkillSystem.def_of("ember_shot").get("projectile", {}) as Dictionary
	var cfg := pc.duplicate(true)
	cfg["max_distance_px"] = 200.0
	_check(bool(player.call("fire_skill_projectile", cfg, Vector2.RIGHT, 30)),
			"技能弹道发出去了")
	var proj: Node = null
	for c in player.get_parent().get_children():
		if str(c.name) == "SkillProjectile":
			proj = c       # 取最后一个 = 这一句刚发的那发，前面若有残留也不干扰
	if proj == null:
		_check(false, "弹道没挂在角色的父节点下，接线要看 player.gd::fire_skill_projectile")
	else:
		_check(proj.get("source") == player, "这一发认得射手，命中才回得了血")
		proj.queue_free()      # 同帧收掉：它一帧都没跑，不会误伤场上别的敌人

	# 负对照：没挂嗜血时，打再多也不回一格
	st.clear()
	player.hp = 1
	player.call("apply_lifesteal", 400)
	_check(int(player.hp) == 1, "身上没嗜血这层 → 打出 400 伤害一格都不回")
	player.hp = max_hp


## D 段续：狂战面具（增伤换承伤）+ 疾风羽（只改腿，而且只能玩家自己开）
func _boons(player: Node, ss: SkillSystem) -> void:
	_say("--- 增益：狂战面具拿增伤换承伤，疾风羽只改腿 ---")
	var st := player.get("_statuses") as UnitStatus
	var bm := SkillSystem.def_of("battle_madness")
	var sf := SkillSystem.def_of("swift_feather")
	var bonus := float(bm.get("damage_bonus", 0.0))
	var red := float(bm.get("damage_reduction", 0.0))
	var spd := float(sf.get("speed_bonus", 0.0))
	_check(bonus > 0.0 and red < 0.0 and float(bm.get("buff_duration_seconds", 0.0)) > 0.0,
			"面具是「增伤 + 负减伤」一对：出手 +%.0f%%，承伤 ×%.2f" % [bonus * 100.0, 1.0 - red])
	_check(spd > 0.0 and not sf.has("damage") and not sf.has("heal_flat")
			and not sf.has("lifesteal") and not sf.has("status"),
			"疾风羽表里只有加速：伤害 / 治疗 / 吸血 / 状态一键都没写")
	_check(not SkillSystem.flag("swift_feather", "auto_cast", true),
			"全表第一招 auto_cast=false（跑与不停归玩家判断）")

	# 先量一次"没戴面具挨这一下"，再量戴上的 —— 顺序反了就没有对照，
	# 而"承伤 ×1.15"这种代价只有跟基线比才看得出它真的在扣血。
	st.clear()
	var defense := int(float(player.call("trait_flat", "defense"))) \
			- int(float(player.call("supply_penalty", "defense")))
	player.set("_invincible_timer", 0.0)
	player.set("_dodge_invincible", false)
	player.hp = int(player.max_hp)
	var hp_plain := int(player.hp)
	player.call("take_damage", HIT)
	var plain := hp_plain - int(player.hp)

	# 面具走真身：戴上面霜 + 留一招 frost_nova 当"量增伤的尺"（它 crit/variance 都是 0，
	# 结算就是 floor(面板 × 乘数)，探针里能断到个位数）。
	ss.set_known({"battle_madness": 1, "frost_nova": 1, "swift_feather": 1})
	ss.reset()
	player.hp = int(player.max_hp)
	_check(ss.cast("battle_madness"), "面具戴上了")
	_check(is_equal_approx(st.damage_dealt_mult(), 1.0 + bonus),
			"出手乘数读出 ×%.2f（实得 ×%.2f）" % [1.0 + bonus, st.damage_dealt_mult()])
	_check(is_equal_approx(st.damage_taken_mult(), 1.0 - red),
			"代价在同一层里：承伤 ×%.2f（实得 ×%.2f）" % [1.0 - red, st.damage_taken_mult()])

	if plain > 0:
		player.set("_invincible_timer", 0.0)
		player.set("_dodge_invincible", false)
		player.hp = int(player.max_hp)
		var hp_masked := int(player.hp)
		player.call("take_damage", HIT)
		var paid := hp_masked - int(player.hp)
		_check(paid == maxi(int(round(HIT * (1.0 - red))) - defense, 0) and paid > plain,
				"同样 %d 伤：裸着掉 %d，戴面具掉 %d（先 ×%.2f 再扣防御 %d）"
				% [HIT, plain, paid, 1.0 - red, defense])
	else:
		_say("  (防御 %d ≥ 测试伤害 %d，跳过承伤对照)" % [defense, HIT])

	# 技能那条出口也吃这层增益。不能像早先那样"抽一发比对数"：defaults.variance 是 12%，
	# 18 × 1.4 = 25.2 抽到几都算正常，那条断言其实是碰运气（这次就挂成了 25≠实得）。
	# 换成看**档位**：戴了面具的每一发都落在乘过 ×1.4 的那一档里，而且一档都不碰不乘那一档。
	var panel := ss.damage_of("frost_nova")
	var varc := SkillSystem.param("frost_nova", "variance")
	var plain_hi := int(ceil(panel * (1.0 + varc)))
	var masked_lo := int(floor(panel * (1.0 + bonus) * (1.0 - varc)))
	var masked_hi := int(ceil(panel * (1.0 + bonus) * (1.0 + varc)))
	var seen_lo := 1 << 30
	var seen_hi := -(1 << 30)
	var off_band := 0
	for _r in range(12):
		var got := ss.roll_damage("frost_nova")
		seen_lo = mini(seen_lo, got)
		seen_hi = maxi(seen_hi, got)
		if got < masked_lo or got > masked_hi or got <= plain_hi:
			off_band += 1
	_check(off_band == 0,
			"技能那条出口按 ×%.2f 放大：12 发全在 %d..%d 这一档，一格都没落回原档（≤%d）（实得 %d..%d）"
			% [1.0 + bonus, masked_lo, masked_hi, plain_hi, seen_lo, seen_hi])

	# 普攻那条出口共用同一个乘数（roll_hit_damage 里乘在抽之前）。
	# 武器表要是开了浮动或暴击，两次抽样本来就不同，那就只能断"变大"——
	# 出厂两键都是 0，走的是精确那条。
	var tdm := float(player.call("trait_damage", 100.0))
	var jitter := float(player.call("attack_param", "variance", 0.0)) \
			+ float(player.call("attack_param", "crit_chance", 0.0))
	var melee := int(player.call("roll_hit_damage", 100.0)["damage"])
	if jitter > 0.0:
		_check(melee > int(tdm), "武器开了浮动/暴击，增伤后那一发只断言变大（实得 %d）" % melee)
	else:
		_check(melee == int(tdm * (1.0 + bonus)),
				"普攻那条出口同样吃这层增益（100 基础 → %d，与技能同一个乘数）" % melee)

	# 两层的时长各走各的：面具 5s、羽毛 4s，先摘掉羽毛而面具还在
	_check(ss.cast("swift_feather"), "疾风羽放出去了")
	_check(is_equal_approx(st.speed_mult(), 1.0 + spd),
			"移速乘数读出 ×%.2f（实得 ×%.2f）" % [1.0 + spd, st.speed_mult()])
	_check(is_equal_approx(st.damage_dealt_mult(), 1.0 + bonus),
			"两层增益同时挂在身上，互不覆盖（加速没把增伤挤掉）")
	st.tick(4.01)
	_check(is_equal_approx(st.speed_mult(), 1.0) \
			and is_equal_approx(st.damage_dealt_mult(), 1.0 + bonus),
			"4 秒后羽毛自己掉了，面具还在（同一份表，两条独立倒数）")
	st.tick(1.01)
	_check(st.is_empty() and is_equal_approx(st.damage_dealt_mult(), 1.0) \
			and is_equal_approx(st.damage_taken_mult(), 1.0),
			"面具也到点摘掉，两个乘数一起回 ×1")

	# auto_cast=false 的负对照：血钉到最低、冷却清空、把 tick 喂够一整个扫描周期。
	# 同一批里放 holy_cross 当正对照 —— 不然"没自动开"可能只是自动释放整个坏了。
	st.clear()
	ss.set_known({"swift_feather": 1, "holy_cross": 1})
	ss.reset()
	player.hp = 1
	for _i in range(20):
		ss.tick(0.1)
	_check(ss.cooldown_left("swift_feather") <= 0.0 and not st.has("swift_feather"),
			"auto_cast=false：残血 + 空冷却喂满 2 秒，疾风羽一次都没自己开")
	_check(st.has("holy_cross") or int(player.hp) > 1,
			("同一时刻同一批条件下，圣光十字自己开了（身上「%s」，HP %d）" % [st.summary(), int(player.hp)]))
	st.clear()
	player.hp = int(player.max_hp)


## 中毒 / 流血：两条新 DoT 各自找到自己的投递方式 —— 一记快咬 vs 一团慢雾。
## 这一段真正在守的是**门槛**：auto_cast_targets_min 从写进 defaults 起一直取默认 1，
## 孢子雾是全池第一招把它改成 2 的，所以"一个人的时候不自动放"必须有一条实测 ——
## 否则这条键和没写一样（表值本身也单独断言一句真读到了，不让它静默落回 1）。
func _toxin(ss: SkillSystem) -> void:
	_say("--- 中毒 / 流血：蛇咬单体挂流血，孢子雾群体挂中毒且要两个人才自动放 ---")
	var sb := SkillSystem.def_of("snake_bite")
	var sc := SkillSystem.def_of("spore_cloud")
	_check(str(sb.get("status", "")) == "bleed" and str(sc.get("status", "")) == "poison",
			"两招各带一条新状态（蛇咬→%s / 孢子雾→%s）"
			% [str(sb.get("status", "")), str(sc.get("status", ""))])
	_check(is_equal_approx(SkillSystem.param("spore_cloud", "auto_cast_targets_min"), 2.0),
			"孢子雾的 auto_cast_targets_min 真的读到了 2（没落回 defaults 的 1）")
	_check(SkillSystem.param("snake_bite", "knockback_px") == 0.0,
			"蛇咬一格都不推：把人推开等于把他刚撕开的伤口合上")

	# 全池横向比较：这两招的身份就是「最快手」与「最静」，比较口径取自合并后的表
	var defs := SkillSystem.all_defs()
	var fastest := 1e20
	var fastest_id := ""
	var quietest := 1e20
	var quietest_id := ""
	for raw_id in defs.keys():
		var id := str(raw_id)
		var cd := SkillSystem.param(id, "cooldown_seconds")
		var ns := SkillSystem.param(id, "noise")
		if cd < fastest:
			fastest = cd
			fastest_id = id
		if ns < quietest:
			quietest = ns
			quietest_id = id
	_check(fastest_id == "snake_bite",
			"蛇咬是全池冷却最短的一招（%.1fs，次短的是别人）" % fastest)
	_check(quietest_id == "spore_cloud",
			"孢子雾是全池最静的一招（噪音 %.0f，压在疾风羽 20 之下）" % quietest)

	# 蛇咬：照 E 段那条路子把弹道直接喂给它自己的 setup，命中与状态才有确定的落点
	var pc: Dictionary = sb.get("projectile", {}) as Dictionary
	_check(not pc.is_empty() and ResourceLoader.exists(str(pc.get("texture", ""))),
			"蛇咬自带一份弹道表，贴图在位")
	var cfg := pc.duplicate(true)
	cfg["status_id"] = str(sb.get("status", ""))
	cfg["aoe_radius_px"] = 0.0
	cfg["max_distance_px"] = 600.0
	var origin := Vector2(6000.0, 6000.0)
	var bitten := _dummy_at(origin + Vector2(80.0, 0.0))
	var far_bitten := _dummy_at(origin + Vector2(80.0, 220.0))
	var p: Node2D = load(PROJECTILE).new()
	_stage.add_child(p)
	p.global_position = origin
	p.call("setup", cfg, Vector2.RIGHT, int(SkillSystem.param("snake_bite", "damage")), [], 16)
	_tick(p, 0.4, &"_physics_process")
	_check(int(bitten.hits) == 1, "蛇咬的弹道命中了正面目标（实得 %d 次）" % int(bitten.hits))
	_check(bitten.status_ids == ["bleed"],
			"这一口把流血挂上了（实得 %s）" % str(bitten.status_ids))
	_check(int(far_bitten.hits) == 0, "没有溅射：蛇咬一次只咬一个人（实得 %d 次）"
			% int(far_bitten.hits))
	_kill_dummies()

	# 孢子雾：走真实出手路径 —— 半径内一圈人全挂中毒，门槛按人数开合
	ss.set_known({"spore_cloud": 1})
	ss.reset()
	var r := ss.radius_of("spore_cloud")
	var pos := ss.global_pos()
	var base := ss.hostile_count_in_radius(pos, r)
	var one := _dummy_at(pos + Vector2(r * 0.5, 0.0))
	if base > 0:
		_say("  (半径内本来就有 %d 个真敌人，「一个人不放」这条测不了，只记人数)" % base)
	else:
		_check(not ss.auto_wants("spore_cloud"),
				"半径内只有一个人 → 自动释放不开火（这一招等的是一圈人）")
	var two := _dummy_at(pos + Vector2(0.0, r * 0.5))
	_check(ss.auto_wants("spore_cloud"),
			"凑到两个人（本来 %d 个）→ 门槛开" % base)
	_check(ss.cast("spore_cloud"), "手动抢放不受门槛限制")
	_check(int(one.hits) == 1 and int(two.hits) == 1,
			"雾里两个人各挨了一下（实得 %d / %d 次）" % [int(one.hits), int(two.hits)])
	_check(one.status_ids == ["poison"] and two.status_ids == ["poison"],
			"这一下把中毒挂到了每个人身上（实得 %s / %s）"
			% [str(one.status_ids), str(two.status_ids)])
	_kill_dummies()
	if base == 0:
		_check(not ss.auto_wants("spore_cloud"),
				"人撤空 → 门槛又关上（证明上面靠的是人数不是运气）")
	ss.set_known({})


## 捞一只场上活着的真敌人来量读数（假靶子 DummyTarget 没有 patrol_speed / incoming_damage，
## 而这两句正是"敌方到底读不读状态乘数"的唯一口径）。不新建节点：新建的没 setup 过兵种
## 数据，速度是配置默认值，量出来的数没有意义。
func _real_enemy() -> Node2D:
	for n in get_tree().get_nodes_in_group("enemies"):
		if n is DummyTarget or not (n is Node2D):
			continue
		if not is_instance_valid(n) or not n.has_method("patrol_speed"):
			continue
		if bool(n.get("_dying")) or float(n.get("hp")) <= 0.0:
			continue
		if n.get("_statuses") is UnitStatus:
			return n as Node2D
	return null


## 缓滞 / 定身 / 易伤：三条状态在容器里挨得极近 —— 慢与停同为 speed_mult，差别只是
## 0.55 还是 0；停与晕都让人难受，差别只是 halt_ai 写没写。所以这一段守的是两条容易
## 写串的分界线，外加敌方那两个出口真的乘了状态：乘错地方 = 状态纯装饰，而探针全绿、
## 照片也全对（易伤最初就是这么"上线"的）。
func _control(ss: SkillSystem) -> void:
	_say("--- 缓滞 / 定身 / 易伤：慢≠停、停≠晕、易伤要真的更疼 ---")
	var slow_def := UnitStatus.def_of("slow")
	var root_def := UnitStatus.def_of("root")
	var vuln_def := UnitStatus.def_of("vulnerable")
	_check(not slow_def.is_empty() and not root_def.is_empty() and not vuln_def.is_empty(),
			"三条新状态都在表里（缓滞 / 定身 / 易伤）")
	var sm := float(slow_def.get("speed_mult", 1.0))
	var rm := float(root_def.get("speed_mult", 1.0))
	var vm := float(vuln_def.get("damage_mult", 1.0))
	_check(sm > 0.0 and sm < 1.0, "缓滞配的是「慢一点」（速度 ×%.2f）" % sm)
	_check(rm == 0.0, "定身配的是「停住」（速度 ×%.1f）" % rm)
	_check(vm > 1.0, "易伤配的是「更疼」（承伤 ×%.2f）" % vm)

	var c := UnitStatus.new()
	c.apply("slow")
	_check(is_equal_approx(c.speed_mult(), sm) and not c.halts_ai(),
			"缓滞只拖腿不夺魂：速度 ×%.2f，AI 照跑" % sm)
	c.apply("slow")
	c.apply("slow")
	_check(c.stacks_of("slow") == 1 and is_equal_approx(c.speed_mult(), sm),
			"缓滞叠三次还是 ×%.2f（层数 %d）" % [sm, c.stacks_of("slow")])
	c.clear()

	c.apply("root")
	_check(c.speed_mult() == 0.0, "定身把速度乘成 0")
	_check(not c.halts_ai(), "定身**不**停 AI：他动不了，可他还在打你")
	var stun := UnitStatus.new()
	stun.apply("stun")
	_check(stun.halts_ai(), "眩晕才停 AI（定身与晕这条线没被后来人写串）")
	c.clear()

	c.apply("vulnerable")
	_check(is_equal_approx(c.damage_taken_mult(), vm) and is_equal_approx(c.speed_mult(), 1.0),
			"易伤只改承伤（×%.2f），腿脚一点不受影响" % vm)
	c.clear()

	var e := _real_enemy()
	_check(e != null, "场上捞得到一只活着的真敌人（敌方接线这半段要量它）")
	if e == null:
		return
	var es: UnitStatus = e.get("_statuses")
	es.clear()
	var walk0 := float(e.call("patrol_speed"))
	_check(walk0 > 0.0, "这只敌人本来会走（%.0f px/s）" % walk0)
	e.call("apply_status", "slow")
	var walk1 := float(e.call("patrol_speed"))
	_check(is_equal_approx(walk1, walk0 * sm),
			"缓滞进了敌人的速度出口（%.0f → %.0f px/s）" % [walk0, walk1])
	es.clear()
	e.call("apply_status", "root")
	_check(float(e.call("patrol_speed")) == 0.0, "定身让敌人的巡逻速度归零（同一个出口）")
	_check(not es.halts_ai(), "被定住的那只仍然不摆 AI（与容器口径一致）")
	es.clear()

	# 承伤读的是**同一个实例、同一份血量**下的两次调用，所以它自带的减伤特性（爆裂鼓手
	# 那类）在两边完全抵消，量到的差只可能来自易伤。这里只断言"更疼"、不断言精确倍率：
	# 敌方那条减伤通道带 min_damage 保底，会把乘完的数削平；硬要相等就等于挑一只没特性
	# 的敌人来测 —— 那才是假的普遍成立。
	var dmg0 := int(e.call("incoming_damage", HIT))
	e.call("apply_status", "vulnerable")
	var dmg1 := int(e.call("incoming_damage", HIT))
	_check(dmg0 > 0, "裸着一发 %d 伤敌人吃得下（实承受 %d）" % [HIT, dmg0])
	_check(dmg1 > dmg0,
			"挂了易伤的同一个人更疼（承受 %d → %d，表里写着 ×%.2f）" % [dmg0, dmg1, vm])
	_check(float(dmg1) >= float(dmg0) * vm - 1.0,
			"这一差的量级对得上易伤倍率（不低于 ×%.2f 减一点取整余量）" % vm)
	es.clear()
	var walk_back := float(e.call("patrol_speed"))
	_check(is_equal_approx(walk_back, walk0) and int(e.call("incoming_damage", HIT)) == dmg0,
			"清完状态后这只敌人回到出厂读数（速度 %.0f、承伤 %d）" % [walk_back, dmg0])


## 这一批的五招各占住池子里一个「最」字。横向比较比"这招放得出去"值钱得多：数值通胀、
## 两招悄悄长成同一招，只有把它们放进整张表里排一次才看得见（与中毒那一批同一把尺）。
## 牵引（pull_px）是这一批唯一的新机制，所以除了读数还要量一次真位移与方向。
func _extremes(ss: SkillSystem) -> void:
	_say("--- 陨星坠 / 烈焰风暴 / 深渊漩涡 / 剑阵 / 骨刺：各占一个「最」字 ---")
	var defs := SkillSystem.all_defs()
	var hardest := ""
	var hardest_v := -1.0
	var longest_cd := ""
	var cd_v := -1.0
	var loudest := ""
	var noise_v := -1.0
	var widest := ""
	var rad_v := -1.0
	var shortest_shot := ""
	var shot_v := 1e20
	var pullers: Array = []
	for raw_id in defs.keys():
		var id := str(raw_id)
		var dmg := SkillSystem.param(id, "damage")
		var cd := SkillSystem.param(id, "cooldown_seconds")
		var ns := SkillSystem.param(id, "noise")
		var rad := SkillSystem.param(id, "radius_px")
		var pull := SkillSystem.param(id, "pull_px")
		if dmg > hardest_v:
			hardest_v = dmg
			hardest = id
		if cd > cd_v:
			cd_v = cd
			longest_cd = id
		if ns > noise_v:
			noise_v = ns
			loudest = id
		if rad > rad_v:
			rad_v = rad
			widest = id
		if str((defs[raw_id] as Dictionary).get("type", "")) == "projectile":
			var rng := SkillSystem.param(id, "range_px")
			if rng < shot_v:
				shot_v = rng
				shortest_shot = id
		if pull > 0.0:
			pullers.append(id)
	_check(hardest == "meteor_fall", "陨星坠是全池最痛的一招（%.0f 伤，次高的是别人）" % hardest_v)
	_check(longest_cd == "meteor_fall", "也是全池最难攒的一招（%.0fs 冷却）" % cd_v)
	_check(loudest == "meteor_fall", "还是全池最吵的一招（噪音 %.0f）" % noise_v)
	_check(widest == "ember_storm", "烈焰风暴铺得比谁都开（半径 %.0f，压过地裂）" % rad_v)
	_check(shortest_shot == "bone_spike", "骨刺是弹道里射程最短的一发（%.0f px）" % shot_v)
	_check(pullers == ["abyss_vortex"],
			"全池只有深渊漩涡在往回拉（实得 %s）—— 多一处 pull_px 就得同时改代码里的 if/elif"
			% str(pullers))

	ss.set_known({"abyss_vortex": 1, "meteor_fall": 1})
	var pos := ss.global_pos()
	var pull := SkillSystem.param("abyss_vortex", "pull_px")

	# 摆在半径内侧的正右方：拉的方向于是唯一（正左 = 朝施法者），推的方向也唯一。
	ss.reset()
	var dragged := _dummy_at(pos + Vector2(ss.radius_of("abyss_vortex") * 0.8, 0.0))
	var drag_from := dragged.global_position
	_check(ss.cast("abyss_vortex"), "深渊漩涡放出去了")
	_check(is_equal_approx(dragged.kb_dist, pull),
			"%.0fpx 的牵引原样传了下去（实得 %.0f）" % [pull, dragged.kb_dist])
	_check(dragged.kb_dir == Vector2.LEFT,
			"方向朝施法者，不是推开（实得 %s）" % str(dragged.kb_dir))
	_check(dragged.global_position.distance_to(drag_from + Vector2(-pull, 0.0)) < 0.5,
			"靶子真的被拽近了 %.0fpx（%s → %s）" % [pull, str(drag_from), str(dragged.global_position)])
	_check(dragged.status_ids == ["slow"],
			"拽过来顺手挂上缓滞（实得 %s）" % str(dragged.status_ids))
	_kill_dummies()

	# 同一条 apply_knockback 通道的反方向对照：陨星坠走的是同一句代码、同一个数，
	# 只有 pull/kb 两条键的区别 —— 所以这两招必须量出相反的位移。
	ss.reset()
	var smashed := _dummy_at(pos + Vector2(ss.radius_of("meteor_fall") * 0.8, 0.0))
	var smash_from := smashed.global_position
	var kb := SkillSystem.param("meteor_fall", "knockback_px")
	_check(ss.cast("meteor_fall"), "陨星坠放出去了")
	_check(smashed.kb_dir == Vector2.RIGHT and is_equal_approx(smashed.kb_dist, kb),
			"同一句代码，这一招把人推开 %.0fpx（实得 %s / %.0f）"
			% [kb, str(smashed.kb_dir), smashed.kb_dist])
	_check(smashed.global_position.distance_to(smash_from + Vector2(kb, 0.0)) < 0.5,
			"靶子确实被砸出去 %.0fpx" % kb)
	_check(smashed.status_ids == ["stun"],
			"砸完还钉一下（实得 %s）" % str(smashed.status_ids))
	_kill_dummies()
	ss.set_known({})


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

class_name UnitStatus
extends RefCounted
## ============================================================
## UnitStatus — 单位身上的临时状态容器（冻结 / 灼烧 / 护盾……）
##
## 【为什么是 RefCounted 容器，而不是一个挂在单位下面的节点】
##   状态本质是一份纯数据（id → 剩余时长 + 层数），没有任何要画、要物理参与的东西。
##   做成节点就得给场上每个敌人多 add_child 一次、多进组一次，而绝大多数敌人
##   一辈子一个状态都不沾 —— 白付那份开销。现在它只是 `var _statuses := UnitStatus.new()`，
##   跟着宿主一起释放（RefCounted，无人引用自动 free）。
##
## 【增益和减益走同一个容器】
##   护盾（齿轮护盾的减伤）和冻结/灼烧在结算侧没有区别：都是"一段时间内改几个乘数"。
##   所以只有一条管线：config `skills.statuses` 里的条目是**定义表驱动**（apply(id)），
##   技能自己算出来的增益是**运行时合成定义**（apply_modifier(id, {damage_mult:…}, 时长)）。
##   两者进同一张 _entries，被同一句 tick() 推进 —— 新增一种状态只加配置，不改代码。
##
## 【未知 id 只警告一次】照 EffectLibrary 的规矩：几百只敌人同时踩到同一个错配置时，
##   每帧一条 push_warning 会刷爆日志并真的拖慢帧率。
##
## 【结算顺序有个坑，记在这】敌方调用点必须在 `_dormant` 提前 return **之前** tick：
##   远处解冻中的敌人如果没人替它倒数，剩余时长会永久卡在解冻那一帧。
## ============================================================

static var _missing := {}

## id -> {"def": Dictionary, "remaining": float, "stacks": int, "acc": float}
var _entries: Dictionary = {}
## id -> 免疫期剩余秒数（状态自然结束后才生效，见 thaw_immunity_seconds）
var _immune: Dictionary = {}
## DoT 伤害走哪条通道。空 = 调宿主的 take_damage()（敌人就该这样：跳一下掉血、
## 刷血条、可能打死爆装备）。**我方必须注入 apply_direct_damage** —— 玩家身上
## take_damage 会进硬直并挂 0.4 秒无敌帧，灼烧每 0.5 秒一跳就等于把人锁在硬直里，
## 顺带把敌人的真伤也一起免掉了。伤害本身还是真的，只是换条不进硬直的路。
var dot_handler: Callable = Callable()


# ------------------------------------------------------------
# 施加 / 移除
# ------------------------------------------------------------

## 施加一个状态。def_override 非空时用它当定义（技能按等级放大过的时长走这条），
## 否则按 id 去 config 的 skills.statuses 查出厂定义。返回是否真的施加了。
func apply(id: String, def_override: Dictionary = {}) -> bool:
	var d := def_override if not def_override.is_empty() else def_of(id)
	if d.is_empty():
		if not _missing.has(id):
			_missing[id] = true
			push_warning("[Status] skills.statuses 里没有 \"%s\" 这一条 —— 同类缺失只警告这一次" % id)
		return false
	if float(_immune.get(id, 0.0)) > 0.0:
		return false      # 免疫期内（刚解冻）：这次施加整个作废，不是打个折
	var dur := float(d.get("duration_seconds", 1.0))
	if dur <= 0.0:
		return false
	if _entries.has(id):
		var e: Dictionary = _entries[id]
		# stack = 层数 +1（有上限）；其余（含没写这个键的 refresh）= 只把时长填满。
		# 层数上限取不到就按 1：宁可少叠也不能叠出无上限的 DoT。
		if str(d.get("stack_mode", "refresh")) == "stack":
			e["stacks"] = mini(int(e["stacks"]) + 1, maxi(1, int(d.get("max_stacks", 1))))
		e["def"] = d
		e["remaining"] = dur
		return true
	_entries[id] = {"def": d, "remaining": dur, "stacks": 1, "acc": 0.0}
	return true


## 施加一条运行时合成的增益（技能算出来的 damage_reduction 等），不查配置表。
func apply_modifier(id: String, mods: Dictionary, duration: float) -> bool:
	var d := mods.duplicate()
	d["duration_seconds"] = duration
	return apply(id, d)


func remove(id: String) -> void:
	_entries.erase(id)


func clear() -> void:
	_entries.clear()
	_immune.clear()


# ------------------------------------------------------------
# 查询（宿主每帧读这几个乘数，其余都是探针/HUD 用）
# ------------------------------------------------------------

func has(id: String) -> bool:
	return _entries.has(id)


func is_empty() -> bool:
	return _entries.is_empty()


func ids() -> Array:
	return _entries.keys()


func stacks_of(id: String) -> int:
	var e = _entries.get(id, null)
	return 0 if e == null else int((e as Dictionary)["stacks"])


func remaining_of(id: String) -> float:
	var e = _entries.get(id, null)
	return 0.0 if e == null else float((e as Dictionary)["remaining"])


## 移动速度乘数：各状态相乘。冻结把它乘成 0 —— 于是"冻住"在敌人和我方
## 两套移动代码里都不需要特判，速度天然是零。
func speed_mult() -> float:
	var m := 1.0
	for e in _entries.values():
		m *= float((e as Dictionary)["def"].get("speed_mult", 1.0))
	return m


## 承受伤害乘数（减伤类增益）。护盾 0.6 = 同样一刀只掉六成血。
func damage_taken_mult() -> float:
	var m := 1.0
	for e in _entries.values():
		m *= float((e as Dictionary)["def"].get("damage_mult", 1.0))
	return m


## 打出伤害乘数（狂战那类增益）。与上面那条**故意是两个键**：一张面具可以既让你
## 砍得更痛、又让你更挨得住不了打（增伤 1.4 / 承伤 1.15），合成一个数就表达不了
## "两头都动"，只能表达"要么硬要么脆"。
## 结算点在出手那一侧（player.roll_hit_damage / SkillSystem.roll_damage 各乘一次），
## 不在 take_damage 里 —— 目标自己的减伤仍归目标算。
func damage_dealt_mult() -> float:
	var m := 1.0
	for e in _entries.values():
		m *= float((e as Dictionary)["def"].get("damage_dealt_mult", 1.0))
	return m


## 吸血比例（嗜血那类自我增益）：打出伤害后按这个成数回血。
## 与上面两个乘数的**算法**不同：speed/damage 是"叠乘的系数"，而吸血是"几条来源
## 各回各的、加在一起"—— 两条各 25% 应该回 50%，乘起来反而越叠越少，讲不通。
## 走同一条倒数通道是重点：时长归 UnitStatus 管，宿主那边不用另开一个计时器。
func lifesteal_mult() -> float:
	var sum := 0.0
	for e in _entries.values():
		sum += float((e as Dictionary)["def"].get("lifesteal", 0.0))
	return sum


## 是否有状态要求"整段 AI/输入更新都跳过"。宿主按它走已有的 _hit_stun 那条分支。
func halts_ai() -> bool:
	for e in _entries.values():
		if bool((e as Dictionary)["def"].get("halt_ai", false)):
			return true
	return false


func has_dot() -> bool:
	for e in _entries.values():
		if float((e as Dictionary)["def"].get("tick_interval_seconds", 0.0)) > 0.0:
			return true
	return false


## 状态染色：把身上所有带 color 的状态按各自的 tint_blend 混成一张 modulate
## （没状态 = 纯白，乘上去等于没乘 → 宿主那行代码在旧存档里是完全无感的）。
## 为什么由容器算：敌方和我方共用同一套规矩，而颜色本来就在配置里 ——
## 以后加一种中毒，画面自己就会变，不用两头各写一次 if。
func visual_tint() -> Color:
	var out := Color(1.0, 1.0, 1.0)
	for e in _entries.values():
		var d: Dictionary = e["def"]
		var hex := str(d.get("color", ""))
		var blend := clampf(float(d.get("tint_blend", 0.0)), 0.0, 1.0)
		if hex == "" or blend <= 0.0:
			continue
		out = out.lerp(Color(hex), blend)
	return out


# ------------------------------------------------------------
# 推进
# ------------------------------------------------------------

## 走一秒：所有状态倒数、DoT 按 tick 间隔结算、到点的清掉并挂上免疫期。
## target = 宿主（DoT 直接调它的 take_damage，伤害类型与普攻同一条路，
## 所以敌人的减伤特性、我方无敌帧这些既有规矩对灼烧同样成立）。
## 返回这一帧累计跳出来的伤害（HUD 飘字/探针断言用）。
func tick(delta: float, target: Node = null) -> int:
	var dealt := 0
	var dot := dot_handler
	if not dot.is_valid() and target != null and target.has_method("take_damage"):
		dot = Callable(target, "take_damage")
	if dot.is_valid():
		for e in _entries.values():
			var d: Dictionary = e["def"]
			var interval := float(d.get("tick_interval_seconds", 0.0))
			var per_tick := int(d.get("damage_per_tick", 0))
			if interval <= 0.0 or per_tick <= 0:
				continue
			e["acc"] = float(e["acc"]) + delta
			# 用 while 而不是 if：低帧率或 debug.time_scale 加速时一帧能跨过好几个 tick，
			# 只结算一次等于变相削弱，探针里的总伤害也对不上。
			while float(e["acc"]) >= interval:
				e["acc"] = float(e["acc"]) - interval
				var amount := maxi(1, per_tick * int(e["stacks"]))
				dot.call(amount)
				dealt += amount
	var expired: Array = []
	for id in _entries.keys():
		var e: Dictionary = _entries[id]
		e["remaining"] = float(e["remaining"]) - delta
		if float(e["remaining"]) <= 0.0:
			expired.append(id)
	# 【顺序是有意义的】免疫期先倒数，再处理这一帧的到期 —— 反过来写的话，
	# 到期时刚挂上的那份免疫期会被同一帧的倒数立刻扣掉（一步跨过整个免疫期时
	# 直接归零），"解冻后不能马上再冻"这条就白写了。
	var done: Array = []
	for id in _immune.keys():
		_immune[id] = float(_immune[id]) - delta
		if float(_immune[id]) <= 0.0:
			done.append(id)
	for id in done:
		_immune.erase(id)
	for id in expired:
		var grace := float((( _entries[id] as Dictionary)["def"] as Dictionary)
				.get("thaw_immunity_seconds", 0.0))
		if grace > 0.0:
			_immune[id] = grace
		_entries.erase(id)
	return dealt


## 一行摘要，给日志和探针看：「frozen×1(1.2s) burning×2(3.0s)」
func summary() -> String:
	if _entries.is_empty():
		return "无状态"
	var parts: Array = []
	for id in _entries.keys():
		var e: Dictionary = _entries[id]
		parts.append("%s×%d(%.1fs)" % [str(id), int(e["stacks"]), float(e["remaining"])])
	return " ".join(parts)


## 是否在免疫期内（探针负对照用）
func immune_remaining(id: String) -> float:
	return float(_immune.get(id, 0.0))


static func def_of(id: String) -> Dictionary:
	if id == "":
		return {}
	var all = Config.get_value("skills.statuses", {})
	if not (all is Dictionary):
		return {}
	var d = all.get(id, null)
	return d if d is Dictionary else {}


## 探针用：清掉"只警告一次"的记名，好让负对照重新走一遍告警分支。
static func reset_dedupe() -> void:
	_missing.clear()

class_name SkillSystem
extends RefCounted
## ============================================================
## SkillSystem — 局内技能控制器（每个角色一份）
##
## 【它管什么】学会了哪几招（id → 等级）、每招自己那份冷却、到点自动放、
## 玩家按键抢放。伤害结算与特效都由这里发起，普攻那条路一行都不碰
## （用户 2026-09-21 定：「普攻照旧 + 技能另算」—— 两套独立冷却，不是二选一）。
##
## 【为什么是 RefCounted 而不是节点】与 UnitStatus 同一个理由：它只有一份表要养
## （known / cooldown），没有要画、要物理参与的东西；tick 由宿主的
## _physics_process 顺手带一句，省下每角色一个节点的开销与接线。
##
## 【三种 type，不是一层继承树】aoe_self / projectile / buff 是三段 `_cast_*`
## 分支，读同一张配置表。新技能只要复用这三种之一就零代码改动 —— 这正是首发
## 三招刻意"一种类型一招"的原因：骨架一次跑通，之后加的是数据不是分支。
##
## 【释放是瞬时的】配置里**没有** windup/active/recovery。技能不进攻击状态机，
## 那三个键写出来就是三个没人读的数值（本项目对"配置里有键但代码不读"零容忍）。
## 前摇要真做，得连动画一起排，那是一次美术任务而不是数值任务。
##
## 【射程仍然被观察视野截断】min(技能射程, 视野) —— 和普攻同一条不变式：
## 打不到视野外的东西。技能可以比普攻打得更远，但不能隔着黑雾执法。
## ============================================================

const FX_RING := preload("res://Scripts/combat/fx_ring.gd")

## 自动释放的索敌范围只认敌人（与 combat.auto_attack 同一规矩：见羊不开火）。
const HOSTILE_GROUPS := ["enemies"]
## 落地结算挨谁打谁（与近战挥砍同一套分组：范围技砸到中立生物身上是说不过去的）。
## **必须与 player.gd / projectile.gd 的 DAMAGEABLE_GROUPS 保持一致** ——
## 那两处也各有一份副本，因为 player.gd 没有 class_name，谁都引用不到它的常量。
const DAMAGEABLE_GROUPS := ["enemies", "animals"]

var unit: Node2D = null
## 已学会的技能：id -> 等级（>=1）。没在这张表里的技能，这个角色就是不会。
var known: Dictionary = {}
## id -> 冷却剩余秒（只在"用过一次"之后才有键）
var _cooldown: Dictionary = {}
var _scan := 0.0


func setup(p_unit: Node2D) -> void:
	unit = p_unit


## 换局重置：冷却清空。known 由外部注入或整份换掉（局内学的一切在撤离前都只是暂记）。
func reset() -> void:
	_cooldown.clear()
	_scan = 0.0


static func enabled() -> bool:
	return bool(Config.get_value("skills.enabled", true))


# ------------------------------------------------------------
# 配置表读取（static：探针和 UI 不实例化就能查表）
# ------------------------------------------------------------

## skills.list 整张表。丢掉非字典的项 —— 表里有一条 _comment 给人看的字符串。
static func all_defs() -> Dictionary:
	var raw = Config.get_value("skills.list", {})
	if not (raw is Dictionary):
		return {}
	var out := {}
	for k in (raw as Dictionary).keys():
		if (raw as Dictionary)[k] is Dictionary:
			out[k] = (raw as Dictionary)[k]
	return out


static func def_of(id: String) -> Dictionary:
	var d = all_defs().get(id, null)
	return d if d is Dictionary else {}


## 两级回退：技能段 → skills.defaults → 传进来的兜底值（与 attack_param 同规则）。
static func param(id: String, key: String, fallback: float = 0.0) -> float:
	return _num(def_of(id).get(key, null), default_val(key, fallback))


static func default_val(key: String, fallback: float = 0.0) -> float:
	var d = Config.get_value("skills.defaults", {})
	if d is Dictionary and (d as Dictionary).has(key):
		return float((d as Dictionary)[key])
	return fallback


static func _num(v, fallback: float) -> float:
	if v is bool:
		return 1.0 if bool(v) else 0.0
	if v is int or v is float:
		return float(v)
	return fallback


static func flag(id: String, key: String, fallback: bool) -> bool:
	var raw = def_of(id).get(key, null)
	if raw == null:
		raw = default_val(key, 1.0 if fallback else 0.0)
	return bool(raw)


## 元素配色：五行这一轮**只是身份标识 + 一层染色**（用户定的首发范围，不做克制表）。
## tint 叠在特效自身 modulate 上，所以同一条 slam_ring 换个 tint 就是冰，不用复制素材。
static func fx_tint(d: Dictionary) -> Color:
	var el := str(d.get("element", ""))
	if el == "":
		return Color(1.0, 1.0, 1.0, 1.0)
	var e = Config.get_value("skills.elements." + el, null)
	if not (e is Dictionary):
		push_warning("[Skill] skills.elements 里没有属性 \"%s\"，特效退回原色" % el)
		return Color(1.0, 1.0, 1.0, 1.0)
	return Color(str((e as Dictionary).get("fx_tint", "#ffffff")))


# ------------------------------------------------------------
# 学习与等级
# ------------------------------------------------------------

## 学一招 / 升一级。返回 {"ok": bool, "action": "learned"|"leveled"|"maxed"|"slots_full"|"unknown", "level": int}
## —— 魔法书捡起来要给用户一个交代，到底是"学会了"还是"白捡"，所以不返回裸 bool。
func learn(id: String) -> Dictionary:
	if def_of(id).is_empty():
		push_warning("[Skill] 想学一个不存在的技能：%s" % id)
		return {"ok": false, "action": "unknown", "level": 0}
	var lv := int(known.get(id, 0))
	if lv > 0:
		var max_lv := int(Config.get_value("skills.progression.max_level", 5))
		if not bool(Config.get_value("skills.grimoire.level_up_on_repeat", true)):
			return {"ok": false, "action": "duplicate", "level": lv}
		if lv >= max_lv:
			return {"ok": false, "action": "maxed", "level": lv}
		known[id] = lv + 1
		return {"ok": true, "action": "leveled", "level": lv + 1}
	if known.size() >= maxi(1, int(Config.get_value("skills.slots", 3))):
		return {"ok": false, "action": "slots_full", "level": 0}
	known[id] = 1
	return {"ok": true, "action": "learned", "level": 1}


## 注入名册里带来的技能（main.gd 进局时调，与 player.traits 同一批、同一个时机）。
func set_known(levels: Dictionary) -> void:
	known = {}
	for id in levels.keys():
		if def_of(str(id)).is_empty():
			continue      # 版本改过/删掉的技能：静默丢掉，别让一个死 id 卡住技能栏
		var lv := int(levels[id])
		if lv < 1:
			continue      # 等级 0 = 不会这一招，不能被兜成"会了 Lv1"
		known[str(id)] = lv


func level_of(id: String) -> int:
	return int(known.get(id, 0))


## 等级带来的数值成长（见 skills.progression）。全按"等级 1 = 原值"算，
## 所以一句里最多出现 (lv−1) —— 新学的技能不吃任何隐藏加成。
func _lv_step(id: String) -> float:
	return maxf(0.0, float(level_of(id) - 1))


func damage_of(id: String) -> float:
	return param(id, "damage") \
			* (1.0 + float(Config.get_value("skills.progression.damage_per_level", 0.25)) * _lv_step(id))


func radius_of(id: String) -> float:
	return param(id, "radius_px") \
			+ float(Config.get_value("skills.progression.radius_per_level_px", 0.0)) * _lv_step(id)


func cooldown_of(id: String) -> float:
	var g := 1.0 + float(Config.get_value("skills.progression.cooldown_per_level", -0.08)) * _lv_step(id)
	return param(id, "cooldown_seconds") * maxf(
			float(Config.get_value("skills.progression.min_cooldown_scale", 0.2)), g)


## 技能射程，已按观察视野截断。视野取不到（宿主没这个方法）时按原射程用。
func range_of(id: String) -> float:
	var r := param(id, "range_px")
	if unit != null and unit.has_method("vision_px"):
		r = minf(r, float(unit.call("vision_px")))
	return r


## 施加给目标的状态定义：只在等级会改时长时才合成一份覆盖表，否则交回空表
## 让 UnitStatus 自己去查出厂配置 —— 少一次无意义的字典拷贝，也让"没升级"这条路
## 与配置表逐字节等价（探针里可以直接断言 status_def 为空的场景）。
func status_def_of(id: String) -> Dictionary:
	var sid := str(def_of(id).get("status", ""))
	var base := UnitStatus.def_of(sid)
	if base.is_empty() or _lv_step(id) <= 0.0:
		return {}
	var growth := float(Config.get_value("skills.progression.status_duration_per_level", 0.0))
	if growth <= 0.0:
		return {}
	var o := base.duplicate()
	o["duration_seconds"] = float(base.get("duration_seconds", 1.0)) * (1.0 + growth * _lv_step(id))
	return o


# ------------------------------------------------------------
## 每帧推进：冷却倒数 → 前摇落地 → 自动释放
# ------------------------------------------------------------

func tick(delta: float) -> void:
	if unit == null or not is_instance_valid(unit) or not enabled():
		return
	for id in _cooldown.keys():
		_cooldown[id] = maxf(0.0, float(_cooldown[id]) - delta)
	_scan -= delta
	if _scan > 0.0:
		return
	# 节流与普攻索敌同一个理由：每帧扫一遍场上敌人纯属浪费，0.15 秒的延迟玩家看不出来。
	_scan = float(Config.get_value("skills.auto_scan_seconds", 0.15))
	for id in known.keys():
		if not flag(str(id), "auto_cast", true):
			continue
		if not can_cast(str(id)) or not auto_wants(str(id)):
			continue
		cast(str(id))


## 冷却好了、角色还活着、且这一招在表里 —— 与"有没有目标"无关（那是 auto_wants 的事）。
func can_cast(id: String) -> bool:
	if not enabled() or unit == null or not is_instance_valid(unit):
		return false
	if not known.has(id) or def_of(id).is_empty():
		return false
	if float(_cooldown.get(id, 0.0)) > 0.0:
		return false
	if unit.has_method("is_dead") and bool(unit.call("is_dead")):
		return false
	return true


## 自动释放的额外门槛（手动抢放不看这一条）：范围技要够到敌人、护盾要残血才开。
func auto_wants(id: String) -> bool:
	var d := def_of(id)
	match str(d.get("type", "")):
		"aoe_self":
			return hostile_count_in_radius(global_pos(), radius_of(id)) \
					>= int(param(id, "auto_cast_targets_min", 1.0))
		"projectile":
			return aim_dir(id).length() > 0.01 and hostile_count_in_radius(global_pos(), range_of(id)) \
					>= int(param(id, "auto_cast_targets_min", 1.0))
		"buff":
			var threshold := float(d.get("auto_cast_hp_below", 0.0))
			if threshold <= 0.0:
				return false      # 没写这条 = 不给自己设自动时机，只能手动抢放
			var max_hp := int(unit.get("max_hp"))
			return max_hp > 0 and float(int(unit.get("hp"))) / float(max_hp) <= threshold
	return false


## 主动放一招（手动按键与自动释放都走这里）。返回是否真的放出去了。
func cast(id: String) -> bool:
	if not can_cast(id):
		return false
	var d := def_of(id)
	# 冷却从"按下"这刻开始算，而不是从落地 —— 瞬发技能两者等价，但这条规矩
	# 一旦定下来，以后真要加前摇也不会悄悄变成"冷却被前摇白嫖掉"。
	_cooldown[id] = cooldown_of(id)
	match str(d.get("type", "")):
		"aoe_self":
			_cast_aoe(id, d)
		"projectile":
			_cast_projectile(id, d)
		"buff":
			_cast_buff(id, d)
		_:
			push_warning("[Skill] %s 的 type=\"%s\" 不认识（可选：aoe_self / projectile / buff）"
					% [id, str(d.get("type", ""))])
			return false
	_emit_noise(d)
	return true


func _cast_aoe(id: String, d: Dictionary) -> void:
	var pos := global_pos()
	var parent := _world_parent()
	if parent == null:
		return
	var tint := fx_tint(d)
	var radius := radius_of(id)
	EffectLibrary.spawn(str(d.get("fx_cast", "")), parent, pos, 0.0, tint)
	# 地面那圈既是"打到了哪些人"的读据，也是范围这一属性的唯一可见形式：
	# 半径随等级涨（radius_per_level_px），玩家能直接看出这招升过级。
	var ring: Node2D = FX_RING.new()
	parent.add_child(ring)
	ring.global_position = pos
	ring.setup(radius, float(default_val("shock_ring_seconds", 0.5)), Color(tint.r, tint.g, tint.b, 0.7))
	var sid := str(d.get("status", ""))
	var sdef := status_def_of(id)
	var fx_hit := str(d.get("fx_hit", ""))
	# 击退距离按招走 param：没写这条键 = 0 = 不推，写了就把目标沿「施法者→目标」推开。
	var kb := param(id, "knockback_px")
	var dealt := 0
	for t in nodes_in_radius(get_tree(), pos, radius, DAMAGEABLE_GROUPS):
		var dmg := roll_damage(id)
		if dmg > 0:
			t.call("take_damage", dmg)
			dealt += dmg
		if sid != "" and t.has_method("apply_status"):
			t.call("apply_status", sid, sdef)
		if kb > 0.0 and t.has_method("apply_knockback"):
			var away: Vector2 = (t as Node2D).global_position - pos
			if away.length() > 0.01:
				t.call("apply_knockback", away.normalized(), kb)
		EffectLibrary.spawn(fx_hit, t.get_parent(), (t as Node2D).global_position, 0.0, tint)
	if dealt > 0:
		HitStop.pulse(get_tree(), "on_deal_damage")


func _cast_projectile(id: String, d: Dictionary) -> void:
	var pc = d.get("projectile", null)
	if not (pc is Dictionary) or (pc as Dictionary).is_empty():
		push_warning("[Skill] %s 是 projectile 型却没有 projectile 段，这一发放不出去" % id)
		return
	if unit == null or not unit.has_method("fire_skill_projectile"):
		push_warning("[Skill] 宿主没有 fire_skill_projectile()，技能弹道无法发射")
		return
	# 自带一份弹道表（不复用武器那份），射程按技能自己的 range_px 截断到视野。
	var cfg: Dictionary = (pc as Dictionary).duplicate(true)
	cfg["max_distance_px"] = range_of(id)
	var sid := str(d.get("status", ""))
	if sid != "":
		cfg["status_id"] = sid
		cfg["status_def"] = status_def_of(id)
	cfg["aoe_radius_px"] = float(d.get("aoe_radius_px", 0.0))
	var dir := aim_dir(id)
	var dmg := roll_damage(id)
	unit.call("fire_skill_projectile", cfg, dir, dmg)
	var parent := _world_parent()
	if parent != null:
		EffectLibrary.spawn(str(d.get("fx_cast", "")), parent, global_pos(), dir.angle(), fx_tint(d))


func _cast_buff(id: String, d: Dictionary) -> void:
	if not unit.has_method("apply_buff"):
		push_warning("[Skill] 宿主没有 apply_buff()，增益无处可挂")
		return
	var red := clampf(float(d.get("damage_reduction", 0.0)), 0.0, 0.95)
	var dur := float(d.get("buff_duration_seconds", 0.0)) \
			* (1.0 + float(Config.get_value("skills.progression.duration_per_level", 0.0)) * _lv_step(id))
	if dur <= 0.0:
		push_warning("[Skill] %s 是 buff 型但 buff_duration_seconds<=0" % id)
		return
	# 承伤乘数走状态容器：与冻结/灼烧同一条倒数通道，宿主只要在 take_damage 里乘一次。
	unit.call("apply_buff", id, {"damage_mult": 1.0 - red}, dur)
	var parent := _world_parent()
	if parent != null:
		EffectLibrary.spawn(str(d.get("fx_cast", "")), parent, global_pos(), 0.0, fx_tint(d))


## 一次伤害结算：走通用管线（暴击/浮动），防御由被击方自己扣（敌人那份在 incoming_damage 里）。
func roll_damage(id: String) -> int:
	var base := damage_of(id)
	if base <= 0.0:
		return 0
	var hit := DamagePipeline.roll(base, 0.0,
			param(id, "crit_chance"), param(id, "crit_multiplier", 1.5), param(id, "variance"))
	return int(hit["damage"])


## 出手方向：朝**这一招自己射程内**最近的那个敌人；一个都没有才沿角色朝向（手动那一发）。
## 早先这里是借用普攻的锁（unit.auto_target()），两条都不对：那把锁被武器的有效射程
## 截断（余烬弹 300px，而长枪那 180px 之外的目标根本进不了锁），而且一关自动普攻就整个
## 是 null。合起来就是"门槛按技能射程说该放、真出手却朝空地"—— 实拍里那一发直直飞进了
## 没有人的正下方。索敌口径必须与 auto_wants 同一个：range_of(id) + HOSTILE_GROUPS。
func aim_dir(id: String) -> Vector2:
	var pos := global_pos()
	var best: Node2D = null
	var best_d := INF
	for n in nodes_in_radius(get_tree(), pos, range_of(id), HOSTILE_GROUPS):
		var d: float = pos.distance_squared_to((n as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = n as Node2D
	if best != null:
		var v: Vector2 = best.global_position - pos
		if v.length() > 0.01:
			return v.normalized()
	var f = unit.get("facing")
	return (f as Vector2).normalized() if f is Vector2 and (f as Vector2).length() > 0.0001 \
			else Vector2.RIGHT


func hostile_count_in_radius(center: Vector2, radius: float) -> int:
	return nodes_in_radius(get_tree(), center, radius, HOSTILE_GROUPS).size()


## 单位还算不算"活着"。**不能调 is_dead()** —— 那是 player.gd 才有的方法，
## 敌人没有（它的尸体靠 hp<=0 / _dying 两个字段表达），照直 call 会当场报错。
## 于是这里统一读 hp 这个双方都有的属性；没有 hp 的节点（动物之类）按活着处理。
static func is_alive(n: Node) -> bool:
	if not is_instance_valid(n):
		return false
	var hp = n.get("hp")
	return not (hp is int and int(hp) <= 0)


## 半径内的可指定单位。**纯函数 + 静态**：无头探针不必造施法者，直接喂一棵树就能断言
## "半径改了这一批人、改了等级那一批人"。过滤掉尸体（它们已经不算目标）。
static func nodes_in_radius(tree: SceneTree, center: Vector2, radius: float,
		groups: Array) -> Array:
	var out: Array = []
	if tree == null or radius <= 0.0:
		return out
	var r2 := radius * radius
	for g in groups:
		for n in tree.get_nodes_in_group(StringName(str(g))):
			if not (n is Node2D) or not is_alive(n):
				continue
			if center.distance_squared_to((n as Node2D).global_position) <= r2:
				out.append(n)
	return out


func _emit_noise(d: Dictionary) -> void:
	if unit == null:
		return
	var intensity := float(d.get("noise", default_val("noise", 60.0)))
	if intensity <= 0.0:
		return
	# from_player=true + source_unit：少了后者这次发声会落到"没有归属"的那份读数里，
	# 技能炸完噪音表纹丝不动（emit() 的说明里专门点过这个坑）。
	NoiseSystem.emit(global_pos(), intensity, true, unit)


func global_pos() -> Vector2:
	return unit.global_position if unit != null and is_instance_valid(unit) else Vector2.ZERO


## 特效/弹道挂哪：与宿主同层的世界节点。挂在宿主身上会在角色被清掉时一起消失，
## 而特效寿命比一次施法长（player.fire_projectile 里同一个理由）。
func _world_parent() -> Node:
	if unit == null or not is_instance_valid(unit):
		return null
	return unit.get_parent()


func get_tree() -> SceneTree:
	if unit == null or not is_instance_valid(unit):
		return null
	return unit.get_tree()


# ------------------------------------------------------------
# UI 读视图（菜单栏技能栏 / 魔法书面板）
# ------------------------------------------------------------

func cooldown_left(id: String) -> float:
	return float(_cooldown.get(id, 0.0))


## 0=就绪、1=刚放完。条子直接吃这个数，不自己算时长。
func cooldown_frac(id: String) -> float:
	var total := cooldown_of(id)
	if total <= 0.0:
		return 0.0
	return clampf(cooldown_left(id) / total, 0.0, 1.0)


## 按热键排好序的技能栏数据（槽数上限 = skills.slots，多的不显示）。
func slot_list() -> Array:
	var rows: Array = []
	for id in known.keys():
		var d := def_of(str(id))
		if d.is_empty():
			continue
		var el := str(d.get("element", ""))
		var e = Config.get_value("skills.elements." + el, null)
		rows.append({
			"id": str(id),
			"name": str(d.get("name", id)),
			"element": el,
			"element_name": str((e as Dictionary).get("name", "")) if e is Dictionary else "",
			"color": str((e as Dictionary).get("color", "#ffffff")) if e is Dictionary else "#ffffff",
			"level": int(known[id]),
			"key": int(d.get("key", 0)),
			"ready": cooldown_left(str(id)) <= 0.0,
			"frac": cooldown_frac(str(id)),
		})
	rows.sort_custom(func(a, b): return int(a["key"]) < int(b["key"]))
	var cap := maxi(1, int(Config.get_value("skills.slots", 3)))
	return rows.slice(0, cap)


## 物理键码 → 技能 id（没这一键 / 还没学会则返回空串）。与 dodge_key 同一套读法。
func skill_at_keycode(code: int) -> String:
	if code <= 0:
		return ""
	for id in known.keys():
		if int(def_of(str(id)).get("key", 0)) == code:
			return str(id)
	return ""


## 从一批技能里按 drop_weight 加权抽一本（魔法书掉落用）。
## prefer_unlearned：这个人还没学会的先抽 —— 捡到一本已经满级的书是最差的体验。
static func roll_skill(levels: Dictionary, prefer_unlearned: bool = true) -> String:
	var pool: Array = []
	for id in all_defs().keys():
		if not prefer_unlearned or int(levels.get(id, 0)) <= 0:
			pool.append(id)
	if pool.is_empty():
		for id in all_defs().keys():
			pool.append(id)
	var total := 0.0
	for id in pool:
		total += maxf(0.0, float(param(str(id), "drop_weight", 1.0)))
	if total <= 0.0:
		return str(pool[0])
	var pick := randf() * total
	for id in pool:
		pick -= maxf(0.0, float(param(str(id), "drop_weight", 1.0)))
		if pick <= 0.0:
			return str(id)
	return str(pool[pool.size() - 1])

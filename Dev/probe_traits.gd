extends Node
## ============================================================
## probe_traits — 角色「升级特性」全链路（headless 可跑，纯数据 + 节点属性）
##
## 验三段：
##   A) config progression.traits：8 条、id 齐全、attack_speed 是 pct 其余 flat、per_stack 为正
##   B) 名册数据层：新兵 traits 为空 / 每升 1 级随机 +1 层（层数之和 == 升级数）/
##      _sanitize_traits 洗掉未知与非正 / trait_value = 层数×per_stack / 存盘读档保留
##   C) player 属性落地：拿一个裸装（traits={}）当基线，再拿一个已知层数的对比 ——
##      移速、气血、视野、攻击距离、攻击频率（时序除法）、攻击伤害、投射体速度、防御减免
##
## ⚠ 会改 Meta.roster 并触发 save_game（active_slot==0 → 写 user://save.json），
##   所以开跑备份存档、收尾原样还原。
## ============================================================

const OUT := "user://_probe_traits.txt"
const SAVE_PATH := "user://save.json"
const PLAYER_SCENE := preload("res://Scenes/Player.tscn")

var _lines: Array = []
var _n := 0
var _fails: Array = []
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


func _per_stack(id: String) -> float:
	for t in Config.get_value("progression.traits.list", []):
		if t is Dictionary and str((t as Dictionary).get("id", "")) == id:
			return float((t as Dictionary).get("per_stack", 0.0))
	return 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()
	await _frames(2)

	await _a_config()
	await _b_meta()
	await _c_player()

	_finish()


# ------------------------------------------------------------
# A 段：config
# ------------------------------------------------------------
func _a_config() -> void:
	_say("--- A 段：progression.traits 配置 ---")
	var raw = Config.get_value("progression.traits.list", [])
	_check(raw is Array, "traits.list 是数组")
	var list: Array = raw if raw is Array else []
	_check(list.size() == 8, "共 8 条特性（实得 %d）" % list.size())
	var ids: Array = []
	var units := {}
	var all_pos := true
	for t in list:
		var d: Dictionary = t
		var id := str(d.get("id", ""))
		ids.append(id)
		units[id] = str(d.get("unit", ""))
		if float(d.get("per_stack", 0.0)) <= 0.0:
			all_pos = false
		_check(d.has("name") and id != "", "特性 %s 有 id + name" % id)
	var want := ["attack", "defense", "hp", "move_speed", "vision", "attack_range",
			"attack_speed", "projectile_speed"]
	_check(ids == want, "8 个 id 齐全且顺序正确（实得 %s）" % str(ids))
	_check(str(units.get("attack_speed", "")) == "pct", "attack_speed 是百分比类（实得 %s）"
			% str(units.get("attack_speed", "")))
	var flat_ok := true
	for id in want:
		if id == "attack_speed":
			continue
		if str(units.get(id, "")) != "flat":
			flat_ok = false
	_check(flat_ok, "其余 7 条都是固定值类 flat")
	_check(all_pos, "每条 per_stack 都是正数")


# ------------------------------------------------------------
# B 段：名册数据层
# ------------------------------------------------------------
func _total_stacks(u: Dictionary) -> int:
	var s := 0
	var tr = u.get("traits", {})
	if tr is Dictionary:
		for id in (tr as Dictionary).keys():
			s += int((tr as Dictionary)[id])
	return s


func _b_meta() -> void:
	_say("--- B 段：名册 / 升级掷取 / 清洗 / 存取 ---")
	Meta.roster = []
	Meta.ensure_roster()
	_check(Meta.roster.size() >= 1, "名册初始化有人（%d）" % Meta.roster.size())

	var fresh: Dictionary = Meta.recruit("spearman")
	var fuid := int(fresh.get("uid", 0))
	_check(fresh.get("traits", null) is Dictionary
			and Dictionary(fresh.get("traits", {})).is_empty(),
			"新补招的兵 traits 为空字典")
	_check(Meta.traits_of(fuid).is_empty(), "traits_of(新兵) 返回空")

	# 一次给到恰好升 3 级（Lv0→1→2→3 需要 100+130+169=399）
	var need := Meta.xp_to_next(0) + Meta.xp_to_next(1) + Meta.xp_to_next(2)
	var gained := Meta.add_xp(fuid, need)
	var u := Meta.unit_by_uid(fuid)
	_check(gained == 3 and int(u.get("level", -1)) == 3, "一把经验升 3 级（实得 %d 级）" % gained)
	_check(_total_stacks(u) == 3, "升 3 级 → 特性总层数恰好 3（按层累计，实得 %d）"
			% _total_stacks(u))
	# 每层的 id 都必须是合法特性
	var valid := Meta.trait_ids()
	var only_valid := true
	var tr: Dictionary = u.get("traits", {})
	for id in tr.keys():
		if not valid.has(str(id)):
			only_valid = false
	_check(only_valid, "掷出的特性 id 全部合法（合法集 %s）" % str(valid))

	# 满级不再累积（也不会再掷）
	u["level"] = Meta.max_level()
	u["traits"] = {}
	var g9 := Meta.add_xp(fuid, 99999.0)
	_check(g9 == 0 and _total_stacks(Meta.unit_by_uid(fuid)) == 0,
			"满级后加经验不升级也不掷特性（升 %d 级）" % g9)

	# trait_value = 层数 × per_stack
	_check(is_equal_approx(Meta.trait_value("hp", 4), _per_stack("hp") * 4.0),
			"trait_value(hp,4) = 4×per_stack（%.1f）" % Meta.trait_value("hp", 4))

	# 清洗：未知 id 丢、非正层丢、合法保留
	var cleaned: Dictionary = Meta._sanitize_traits({
		"hp": 3, "attack": 0, "defense": -2, "no_such": 5, "vision": 1
	})
	_check(cleaned == {"hp": 3, "vision": 1}, "traits 清洗后只留合法正层（实得 %s）" % str(cleaned))

	# 存盘读档往返保留 traits：把某人设成有特性，清洗（模拟读档解析）后应原样带回
	var saved := [{"uid": 1, "id": "spearman", "name": "枪手", "level": 5, "xp": 10.0,
			"traits": {"attack": 2, "hp": 3}}]
	var round: Array = Meta._sanitize_roster(saved)
	_check(round.size() == 1
			and Dictionary(round[0].get("traits", {})) == {"attack": 2, "hp": 3},
			"_sanitize_roster 保留 traits（实得 %s）" % str(round[0].get("traits", {})))
	# 读档没带 traits 的老存档 → 回落空字典而非崩溃
	var legacy: Array = Meta._sanitize_roster([{"uid": 1, "id": "spearman", "name": "枪手",
			"level": 2, "xp": 0.0}])
	_check(Dictionary(legacy[0].get("traits", {})).is_empty(),
			"老存档条目无 traits 字段 → 回落空字典不报错")


# ------------------------------------------------------------
# C 段：player 属性落地
# ------------------------------------------------------------
func _make_player(t: Dictionary) -> Node:
	var p: Node = PLAYER_SCENE.instantiate()
	p.set("roster_uid", 0)
	p.set("level", 0)
	p.set("traits", t.duplicate())
	add_child(p)
	# 只喂 _tile_size 给 vision_px 用；不走 setup_navigation —— 空 walls 会让 A* 越界报错。
	p.set("_tile_size", 64)
	return p


func _c_player() -> void:
	_say("--- C 段：player 八项属性落地 ---")
	var base: Node = _make_player({})
	await _frames(2)
	var b_speed: float = base.get("speed")
	var b_maxhp: int = base.get("max_hp")
	var b_vision: float = base.call("vision_px")
	var b_range: float = base.call("attack_range_px")
	var b_windup: float = base.call("attack_param", "windup_seconds", -1.0)
	_check(b_speed > 0.0 and b_maxhp > 0, "基线玩家属性已就绪（speed %.0f / hp %d）"
			% [b_speed, b_maxhp])

	# 已知层数：每条各给一些，attack_speed 给 10 层 = +50% → 时序除以 1.5
	var t := {
		"attack": 2, "defense": 3, "hp": 4, "move_speed": 5,
		"vision": 6, "attack_range": 7, "attack_speed": 10, "projectile_speed": 8
	}
	var pb: Node = _make_player(t)
	await _frames(2)

	_check(is_equal_approx(pb.get("speed"), b_speed + 5.0 * _per_stack("move_speed")),
			"移速 +5 层 = +%.0f（实得 %.1f）" % [5.0 * _per_stack("move_speed"), pb.get("speed")])
	_check(int(pb.get("max_hp")) == b_maxhp + int(4.0 * _per_stack("hp")),
			"气血 +4 层 = +%d（实得 %d）" % [int(4.0 * _per_stack("hp")), int(pb.get("max_hp"))])
	_check(is_equal_approx(pb.call("vision_px"), b_vision + 6.0 * _per_stack("vision")),
			"视野 +6 层 = +%.0f（实得 %.1f）" % [6.0 * _per_stack("vision"), pb.call("vision_px")])
	_check(is_equal_approx(pb.call("attack_range_px"),
			b_range + 7.0 * _per_stack("attack_range")),
			"攻击距离 +7 层 = +%.0f（实得 %.1f）"
			% [7.0 * _per_stack("attack_range"), pb.call("attack_range_px")])

	# 攻击频率：per_stack 是「每层百分点」，三段时序按 (1 + 层数×%/100) 缩短
	var scale := 1.0 + 10.0 * _per_stack("attack_speed") / 100.0
	_check(is_equal_approx(pb.call("attack_param", "windup_seconds", -1.0), b_windup / scale),
			"攻击频率 +10 层（+%.0f%%）→ 前摇 %.3f/%.1f = %.3f（实得 %.3f）"
			% [(scale - 1.0) * 100.0, b_windup, scale, b_windup / scale,
				pb.call("attack_param", "windup_seconds", -1.0)])
	_check(pb.call("attack_param", "windup_seconds", -1.0) < b_windup,
			"高攻击频率确实让前摇变短（更快）")

	# 攻击伤害：trait_damage = 基础 + attack 层
	_check(is_equal_approx(pb.call("trait_damage", 10.0), 10.0 + 2.0 * _per_stack("attack")),
			"攻击 +2 层 → trait_damage(10)=%.1f" % pb.call("trait_damage", 10.0))

	# 投射体速度：只验 trait_flat 叠加（真正生效在 fire_projectile 的 cfg 里）
	_check(is_equal_approx(pb.call("trait_flat", "projectile_speed"),
			8.0 * _per_stack("projectile_speed")),
			"投射体速度 +8 层 = +%.0f" % (8.0 * _per_stack("projectile_speed")))

	# 防御减免：入伤先扣固定值（defense 3 层 = 扣 6）
	pb.set("hp", pb.get("max_hp"))
	var hp0: int = pb.get("max_hp")
	pb.call("take_damage", 30)
	var drop: int = hp0 - int(pb.get("hp"))
	_check(drop == 30 - int(3.0 * _per_stack("defense")),
			"防御 +3 层 → 受 30 伤实扣 %d（期望 %d）"
			% [drop, 30 - int(3.0 * _per_stack("defense"))])

	# 完全挡下：防御层数足够高时，小额伤害被减免到 0 → 不掉血且返回 false
	var tdef := {"defense": 20}
	var shield: Node = _make_player(tdef)
	await _frames(2)
	shield.set("hp", shield.get("max_hp"))
	var ret: bool = shield.call("take_damage", 5)
	_check(ret == false and int(shield.get("hp")) == int(shield.get("max_hp")),
			"高防御把 5 点伤害完全挡下（不掉血、返回 false）")

	# 裸装玩家（临时角色 traits={}）不该有任何加成
	_check(is_equal_approx(base.call("trait_flat", "attack"), 0.0)
			and is_equal_approx(base.call("attack_param", "windup_seconds", -1.0), b_windup),
			"traits={} 的玩家一切加成为 0（旧行为不变）")

	base.queue_free()
	pb.queue_free()
	shield.queue_free()
	await _frames(2)


# ------------------------------------------------------------
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
	print("[probe_traits] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

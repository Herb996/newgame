extends Node
## ============================================================
## probe_level — 角色等级系统（档位配色 + 头顶徽章 + 名册 + 出击面板）
##
## 验八件事（headless 可跑，全是纯数据 + 节点组，不依赖渲染）：
##   A) config 真值：9 级上限、4 档边界 2/5/8/9、经验曲线、徽章参数
##   B) 档位映射：等级 → 档位 id / 档位名（含越界取值）
##   C) 贴图集映射：武器 × 档位 → 精灵集名（12 条 + 未知武器回落）
##   D) **贴图真的在**：4 档 × 3 武器的每一帧都能 ResourceLoader.exists ——
##      这是防「新 PNG 没跑 godot_import.py → load() 静默 null → 角色隐形」的那道闸。
##      同时断言各档帧数与蓝色基线完全一致（防某套配色只生成了一半）。
##   E) 名册数据层：初始 3 人 / 补招命名 / 满编拒招 / 清洗 / 除名
##   F) 经验与升级：曲线取值 / 跨级 / 满级封顶 / 撤离只发存活者
##   G) player 等级视觉：apply_level 换档位贴图（跨档才换）+ 徽章同步
##   H) 出击面板：列名册（名字·等级·档位·经验）+ 补招按钮 + 出击信号带 uid/level
##
## ⚠ 本探针会改 Meta.roster 并触发 Meta.save_game()（active_slot == 0 时写
##   user://save.json）。所以开跑先**备份存档文件**，收尾**原样还原** ——
##   否则跑一次探针就把用户本机存档里的名册洗掉了。
## ============================================================

const OUT := "user://_probe_level.txt"
const SAVE_PATH := "user://save.json"

var _lines: Array = []
var _n := 0
var _fails: Array = []

var _save_backup := ""
var _save_existed := false
var _main: Node = null


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


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # 面板 open() 会 pause 整棵树
	_backup_save()

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	_main = main
	await _frames(30)

	# 名册起步状态 = 出厂那 3 名新兵（先把本地存档带来的状态清掉，保证可复现）
	Meta.roster = []
	Meta.ensure_roster()

	await _a_config()
	await _b_tiers()
	await _c_sprite_map()
	await _d_assets()
	await _e_roster()
	await _f_xp()
	await _g_player(main)
	await _h_panel(main)

	_finish()


# ------------------------------------------------------------
# A 段：config 真值
# ------------------------------------------------------------
func _a_config() -> void:
	_say("--- A 段：config 真值 ---")
	_check(Meta.max_level() == 9, "等级上限 9（实得 %d）" % Meta.max_level())
	var tiers: Array = Config.get_value("progression.tiers", [])
	_check(tiers.size() == 4, "共 4 个档位（实得 %d）" % tiers.size())
	var bounds: Array = []
	for t in tiers:
		bounds.append(int((t as Dictionary).get("max_level", -1)))
	_check(bounds == [2, 5, 8, 9], "档位边界 = [2,5,8,9]（实得 %s）" % str(bounds))
	_check(float(Config.get_value("progression.xp.curve.base", 0.0)) == 100.0,
			"经验曲线 base = 100")
	_check(is_equal_approx(float(Config.get_value("progression.xp.curve.growth", 0.0)), 1.3),
			"经验曲线 growth = 1.3（刻意做成要多局才满）")
	_check(float(Config.get_value("progression.xp.per_extraction", 0.0)) == 100.0,
			"撤离成功经验 = 100/人")
	_check(float(Config.get_value("progression.xp.per_kill", 0.0)) == 0.0,
			"击杀经验 = 0（关掉的）")
	_check(bool(Config.get_value("progression.badge.enabled", false)),
			"徽章默认开启（progression.badge.enabled）")
	_check(float(Config.get_value("progression.badge.orb.center_offset_y", 0.0)) == -34.0,
			"光点轨道中心 center_offset_y = -34（**身体中部**；-56 是头顶，用户要「绕四周飞」）")
	var cols := {}
	for tid in ["blue", "purple", "black", "gold"]:
		var hex := str(Config.get_value("progression.badge.colors.%s" % tid, ""))
		_check(hex != "" and Color(hex).a > 0.0, "档位色 %s 可解析（%s）" % [tid, hex])
		cols[hex] = true
	_check(cols.size() == 4, "四个档位色互不相同（实得 %d 种）" % cols.size())


# ------------------------------------------------------------
# B 段：等级 → 档位
# ------------------------------------------------------------
func _b_tiers() -> void:
	_say("--- B 段：等级 → 档位 ---")
	var cases := {0: "blue", 1: "blue", 2: "blue", 3: "purple", 4: "purple",
			5: "purple", 6: "black", 7: "black", 8: "black", 9: "gold"}
	for lv in cases:
		var got := Meta.tier_id_of_level(int(lv))
		_check(got == str(cases[lv]), "Lv%d → %s（实得 %s）" % [int(lv), cases[lv], got])
	_check(Meta.tier_id_of_level(10) == "gold", "越界 Lv10 → 末档 gold（不崩）")
	_check(Meta.tier_name_of_level(0) == "新兵", "Lv0 档位名 = 新兵")
	_check(Meta.tier_name_of_level(7) == "精锐", "Lv7 档位名 = 精锐")
	_check(Meta.tier_name_of_level(9) == "传奇", "Lv9 档位名 = 传奇")


# ------------------------------------------------------------
# C 段：武器 × 档位 → 精灵集
# ------------------------------------------------------------
var _weapons := ["spear", "bow", "sword"]
var _tier_ids := ["blue", "purple", "black", "gold"]
var _expected := {
	"spear": ["sprites_lancer", "sprites_lancer_purple", "sprites_lancer_black", "sprites_lancer_gold"],
	"bow": ["sprites_archer", "sprites_archer_purple", "sprites_archer_black", "sprites_archer_gold"],
	"sword": ["sprites_ts", "sprites_ts_purple", "sprites_ts_black", "sprites_ts_gold"],
}


func _c_sprite_map() -> void:
	_say("--- C 段：武器 × 档位 → 精灵集 ---")
	var repr_level: Array = [0, 3, 6, 9]    # 各档的代表等级
	for w in _weapons:
		for i in range(_tier_ids.size()):
			var lv: int = int(repr_level[i])
			var got := Meta.unit_sprite_set(w, lv)
			var want: String = _expected[w][i]
			_check(got == want, "%s @ Lv%d → %s（实得 %s）" % [w, lv, want, got])
	# 档位表里没配的武器（强弩已移出名单，但武器/贴图全留着）必须回落到武器自带贴图集，
	# 不能让「没配档位」变成「没贴图」。
	_check(Meta.unit_sprite_set("sniper", 9) == "",
			"未配档位的武器返回空串（sniper @ Lv9），由 player 回落武器自带贴图集")
	_check(str(Config.get_value("combat.weapons.sniper.sprite_set", "")) == "sprites_crossbowman",
			"强弩的武器自带贴图集仍在（sprites_crossbowman）")


# ------------------------------------------------------------
# D 段：贴图真的在（防 import 漏跑）
# ------------------------------------------------------------
## 通用取帧：精灵集里所有非元数据键（数组直接用 / 字典则拼各方向），忽略 view / fps / _注释
func _collect_frames(set_name: String) -> Array:
	var out: Array = []
	var cfg: Dictionary = Config.get_value(set_name, {})
	for key in cfg:
		var k := str(key)
		if k.begins_with("_") or k == "view" or k == "fps":
			continue
		var v = cfg[key]
		if v is Array:
			out.append_array(v)
		elif v is Dictionary:
			for kk in v:
				if v[kk] is Array:
					out.append_array(v[kk])
	return out


func _d_assets() -> void:
	_say("--- D 段：四档贴图是否存在（每帧都查，防 import 漏跑） ---")
	var baseline := {}
	for w in _weapons:
		baseline[w] = _collect_frames(_expected[w][0]).size()   # 蓝色 = 基线
		_check(baseline[w] > 0, "%s 蓝色基线帧数 %d 帧" % [w, baseline[w]])

	var missing := 0
	var checked := 0
	var seen := {}
	for w in _weapons:
		for i in range(_tier_ids.size()):
			var set_name: String = _expected[w][i]
			var frames := _collect_frames(set_name)
			var tier_name: String = _tier_ids[i]
			_check(frames.size() == baseline[w],
					"%s 帧数 %d == 蓝色基线 %d（配色只生成一半会在这里挂）"
					% [set_name, frames.size(), baseline[w]])
			for p in frames:
				var ps := str(p)
				if seen.has(ps):
					continue
				seen[ps] = true
				checked += 1
				if not ResourceLoader.exists(ps):
					missing += 1
					if missing <= 3:
						_say("       缺：%s" % ps)
	_check(missing == 0, "全部帧路径都存在（查 %d 条，缺 %d 条）" % [checked, missing])
	# 抽查各档第一帧真的能 load 出纹理（exists 过但 load 失败 = 文件损坏）
	for w in _weapons:
		for i in range(_tier_ids.size()):
			var frames := _collect_frames(_expected[w][i])
			var tex = load(str(frames[0])) if not frames.is_empty() else null
			_check(tex != null, "%s 首帧可加载为纹理" % _expected[w][i])


# ------------------------------------------------------------
# E 段：名册数据层
# ------------------------------------------------------------
func _e_roster() -> void:
	_say("--- E 段：名册数据层 ---")
	_check(Meta.roster.size() == 3, "出厂名册 3 人（实得 %d）" % Meta.roster.size())
	var ids: Array = []
	var uids: Array = []
	var all_lv0 := true
	for u in Meta.roster:
		ids.append(str(u.get("id", "")))
		uids.append(int(u.get("uid", 0)))
		if int(u.get("level", -1)) != 0 or float(u.get("xp", -1.0)) != 0.0:
			all_lv0 = false
	_check(ids == ["spearman", "archer", "swordsman"],
			"名单顺序 = progression.roster.starting（实得 %s）" % str(ids))
	_check(uids == [1, 2, 3], "uid 从 1 起且唯一（实得 %s）" % str(uids))
	_check(all_lv0, "全员初始 Lv0 / 经验 0")
	_check(str(Meta.roster[0].get("name", "")) == "枪手", "第一人名字 = 枪手（原型名）")

	var u4 := Meta.recruit("archer")
	_check(not u4.is_empty() and int(u4.get("level", -1)) == 0, "补招成功且 0 级")
	_check(str(u4.get("name", "")) == "弓兵2",
			"同兵种第 2 人自动带序号（实得 %s）" % str(u4.get("name", "")))
	_check(int(u4.get("uid", 0)) == 4, "新兵 uid 递增 = 4（实得 %d）" % int(u4.get("uid", 0)))
	_check(Meta.roster.size() == 4, "补招后 4 人")

	var bad := Meta.recruit("no_such_archetype")
	_check(bad.is_empty() and Meta.roster.size() == 4,
			"原型不存在 → 拒绝补招且名册不变（实得 %d 人）" % Meta.roster.size())

	# 补到满编（max_size = 8）
	var cap := int(Config.get_value("progression.roster.max_size", 8))
	while Meta.roster.size() < cap:
		Meta.recruit("spearman")
	_check(Meta.roster.size() == cap, "补到满编 %d 人（实得 %d）" % [cap, Meta.roster.size()])
	_check(Meta.recruit("spearman").is_empty(), "满编后补招被拒")

	# 清洗：残缺 / 原型已删的条目要丢掉，等级封顶、经验不为负、uid 重排
	var cleaned: Array = Meta._sanitize_roster([
		{"id": "no_such", "level": 3},
		{"id": "spearman", "level": 99, "xp": -5.0, "name": "枪手"},
		{"id": "archer", "level": 3, "xp": 20.0, "name": "弓兵", "uid": 77},
		"垃圾",
	])
	_check(cleaned.size() == 2, "清洗后剩 2 条（幽灵原型 / 非字典条目被丢，实得 %d）"
			% cleaned.size())
	if cleaned.size() == 2:
		_check(int(cleaned[0].get("level", -1)) == 9, "等级 99 被截到上限 9（实得 %d）"
				% int(cleaned[0].get("level", -1)))
		_check(float(cleaned[0].get("xp", -1.0)) == 0.0, "负经验被归零")
		_check(int(cleaned[0].get("uid", -1)) == 1 and int(cleaned[1].get("uid", -1)) == 2,
				"uid 重新连续分配（实得 %d / %d）"
				% [int(cleaned[0].get("uid", -1)), int(cleaned[1].get("uid", -1))])

	# 除名（死亡永久）
	var victim := int(Meta.roster[0].get("uid", 0))
	var before := Meta.roster.size()
	Meta.remove_unit(victim)
	_check(Meta.roster.size() == before - 1, "除名后少 1 人（%d → %d）"
			% [before, Meta.roster.size()])
	_check(Meta.unit_by_uid(victim).is_empty(), "被除名的人查不到了")
	Meta.remove_unit(victim)
	_check(Meta.roster.size() == before - 1, "重复除名同一个人不报错、数量不变")
	# 除名后重新可补招
	_check(not Meta.recruit("archer").is_empty(), "空出名额后可以再补招")


# ------------------------------------------------------------
# F 段：经验与升级
# ------------------------------------------------------------
func _f_xp() -> void:
	_say("--- F 段：经验与升级 ---")
	_check(is_equal_approx(Meta.xp_to_next(0), 100.0), "Lv0→1 需 100 经验（实得 %.0f）"
			% Meta.xp_to_next(0))
	_check(is_equal_approx(Meta.xp_to_next(1), 130.0), "Lv1→2 需 130 经验（实得 %.0f）"
			% Meta.xp_to_next(1))
	_check(is_equal_approx(Meta.xp_to_next(2), 169.0), "Lv2→3 需 169 经验（实得 %.0f）"
			% Meta.xp_to_next(2))
	_check(is_equal_approx(Meta.xp_to_next(3), 220.0), "Lv3→4 需 220 经验（实得 %.0f）"
			% Meta.xp_to_next(3))
	_check(is_equal_approx(Meta.xp_to_next(8), 816.0), "Lv8→9 需 816 经验（实得 %.0f）"
			% Meta.xp_to_next(8))
	var curve_rises := true
	for lv in range(0, 9):
		if Meta.xp_to_next(lv + 1) <= Meta.xp_to_next(lv):
			curve_rises = false
	_check(curve_rises, "曲线单调递增（越升越难）")
	var total := 0.0
	for lv in range(0, 9):
		total += Meta.xp_to_next(lv)
	_check(total >= 2500.0 and total <= 4000.0,
			"0→9 累计需 %.0f 经验 ⇒ 约 %.0f 局满级（单局撤离 100）：够难但别变成几百局"
			% [total, total / 100.0])

	var uid := int(Meta.roster[0].get("uid", 0))
	var g1 := Meta.add_xp(uid, 50.0)
	var u := Meta.unit_by_uid(uid)
	_check(g1 == 0 and int(u.get("level", -1)) == 0 and float(u.get("xp", -1.0)) == 50.0,
			"加 50（不足 100）不升级，经验累计到 50（实得 Lv%d / %.0f）"
			% [int(u.get("level", -1)), float(u.get("xp", -1.0))])
	var g2 := Meta.add_xp(uid, 50.0)
	_check(g2 == 1 and int(Meta.unit_by_uid(uid).get("level", -1)) == 1
			and float(Meta.unit_by_uid(uid).get("xp", -1.0)) == 0.0,
			"再加 50 恰好升级且经验清零（升 %d 级）" % g2)
	# Lv1 时一次给 300：先扣 130 升 Lv2（剩 170），再扣 169 升 Lv3（剩 1）
	var g3 := Meta.add_xp(uid, 300.0)
	var u3 := Meta.unit_by_uid(uid)
	_check(g3 == 2 and int(u3.get("level", -1)) == 3 and float(u3.get("xp", -1.0)) == 1.0,
			"一次给够跨两级并保留余数（升 %d 级 → Lv%d，余 %.0f）"
			% [g3, int(u3.get("level", -1)), float(u3.get("xp", -1.0))])

	var uid9 := int(Meta.roster[1].get("uid", 0))
	Meta.roster[1]["level"] = 9
	Meta.roster[1]["xp"] = 0.0
	var g9 := Meta.add_xp(uid9, 99999.0)
	_check(g9 == 0 and float(Meta.unit_by_uid(uid9).get("xp", -1.0)) == 0.0,
			"满级后不再累积经验（升 %d 级、经验 %.0f）"
			% [g9, float(Meta.unit_by_uid(uid9).get("xp", -1.0))])


# ------------------------------------------------------------
# G 段：player 等级视觉
# ------------------------------------------------------------
func _current_set(p: Node) -> String:
	return str(p.call("_sprite_set_for_weapon"))


## 名册里所有人当前经验之和 —— 用来断言「发给了谁、发了几份」
func _roster_xp_total() -> float:
	var t := 0.0
	for u in Meta.roster:
		t += float(u.get("xp", 0.0))
	return t


## 身上此刻贴的是哪张帧 —— 用**贴图路径**而不是纹理对象 id。
## 为什么不用对象 id：① 换帧要等 animator 下一次 update 才落到 Sprite2D，同帧取到的是旧图；
## ② 同一档位播放中帧号本来就在变，对象 id 天然会变，比较它会把"没换皮"和"播到下一帧"
##    混为一谈。路径能直接看出"这套帧属于哪个配色目录"，两种情况都稳。
func _body_tex_path(p: Node) -> String:
	var body: Sprite2D = p.get_node_or_null("Body")
	if body == null or body.texture == null:
		return ""
	return str(body.texture.resource_path)


func _g_player(m: Node) -> void:
	_say("--- G 段：player 档位贴图 + 头顶徽章 ---")
	var uid_third := 0
	# 用名册里第 2 个人（刚被设成 Lv9 的那位不动它，挑第 3 个）进局
	for u in Meta.roster:
		if int(u.get("level", 0)) == 0:
			uid_third = int(u.get("uid", 0))
			break
	_check(uid_third > 0, "挑到一个 0 级队员进局（uid %d）" % uid_third)
	Meta.unit_by_uid(uid_third)["level"] = 0
	m._on_launch([{"id": "spearman", "name": "枪手", "uid": uid_third, "level": 0}])
	await _frames(40)

	var ps := get_tree().get_nodes_in_group("player")
	_check(ps.size() == 1, "进屋后 1 名玩家（实得 %d）" % ps.size())
	if ps.is_empty():
		return
	var p: Node = ps[0]
	_check(int(p.get("roster_uid")) == uid_third,
			"玩家带上了名册身份 roster_uid = %d（实得 %d）"
			% [uid_third, int(p.get("roster_uid"))])
	_check(int(p.get("level")) == 0, "玩家等级 0（实得 %d）" % int(p.get("level")))
	_check(_current_set(p) == "sprites_lancer",
			"Lv0（蓝档）贴图集 = sprites_lancer（实得 %s）" % _current_set(p))

	var badge: Node = p.get_node_or_null("LevelBadge")
	_check(badge != null, "头顶徽章节点存在（Scenes/Player.tscn 的 LevelBadge）")
	if badge == null:
		return
	_check(int(badge.get("level")) == 0 and str(badge.get("tier_id")) == "blue",
			"徽章初始 = Lv0 / blue（实得 Lv%d / %s）"
			% [int(badge.get("level")), str(badge.get("tier_id"))])

	# 跨档：0 → 3（蓝 → 紫）必须**真的把身上的帧换掉**，不只是配置里算对
	var path_blue := _body_tex_path(p)
	_check(path_blue.find("blue_lancer/") >= 0,
			"出场身上贴的是蓝枪兵帧（%s）" % path_blue)
	p.call("apply_level", 3)
	await _frames(2)          # 换帧要等 animator 下一次 update 才落到 Sprite2D 上
	var path_purple := _body_tex_path(p)
	_check(_current_set(p) == "sprites_lancer_purple",
			"Lv3 跨到紫档 → sprites_lancer_purple（实得 %s）" % _current_set(p))
	_check(path_purple.find("purple_lancer/") >= 0,
			"跨档真的把身体换成紫枪兵帧（%s）" % path_purple)
	_check(int(badge.get("level")) == 3 and str(badge.get("tier_id")) == "purple",
			"徽章同步到 Lv3 / purple（实得 Lv%d / %s）"
			% [int(badge.get("level")), str(badge.get("tier_id"))])
	_check(int(p.get("level")) == 3, "player.level 同步为 3（实得 %d）" % int(p.get("level")))

	# 档内：3 → 5（还是紫）不换皮，只动数字
	p.call("apply_level", 5)
	await _frames(2)
	_check(_current_set(p) == "sprites_lancer_purple"
			and _body_tex_path(p).find("purple_lancer/") >= 0,
			"同档内 3→5 仍在紫配色目录（不换皮，只换徽章；实得 %s）" % _body_tex_path(p))
	_check(int(badge.get("level")) == 5, "档内徽章数字跟着变（实得 %d）" % int(badge.get("level")))

	# 再跨两档
	p.call("apply_level", 6)
	await _frames(2)
	_check(_current_set(p) == "sprites_lancer_black"
			and _body_tex_path(p).find("black_lancer/") >= 0,
			"Lv6 跨到黑档 → 换黑枪兵帧（%s）" % _body_tex_path(p))
	p.call("apply_level", 9)
	await _frames(2)
	_check(_current_set(p) == "sprites_lancer_gold"
			and _body_tex_path(p).find("yellow_lancer/") >= 0,
			"Lv9 金档用的是素材包 Yellow 那套（目录名是 yellow 不是 gold，%s）"
			% _body_tex_path(p))
	_check(int(badge.get("level")) == 9, "徽章到位 Lv9（实得 %d）" % int(badge.get("level")))
	p.call("apply_level", 2)
	await _frames(2)
	_check(_current_set(p) == "sprites_lancer"
			and _body_tex_path(p).find("blue_lancer/") >= 0,
			"退回 Lv2（蓝档）→ 身上换回蓝枪兵帧（%s）" % _body_tex_path(p))

	# 档位对任何武器都生效：剑士在 Lv3 应穿紫战士，而不是只对枪兵配色
	p.call("switch_weapon", &"sword")
	p.call("apply_level", 3)
	_check(_current_set(p) == "sprites_ts_purple",
			"换剑士 + Lv3 → sprites_ts_purple（档位对每把武器各自生效，实得 %s）"
			% _current_set(p))
	p.call("switch_weapon", &"bow")
	_check(_current_set(p) == "sprites_archer_purple",
			"换弓兵 + Lv3 → sprites_archer_purple（实得 %s）" % _current_set(p))

	# 撤离结算发经验：只发「名册里、还活着」的人
	Config.set_override("progression.xp.per_extraction", 30.0)
	var uid_live := int(p.get("roster_uid"))
	Meta.unit_by_uid(uid_live)["level"] = 0
	Meta.unit_by_uid(uid_live)["xp"] = 0.0
	Meta.grant_xp_to_survivors()
	_check(float(Meta.unit_by_uid(uid_live).get("xp", -1.0)) == 30.0,
			"撤离成功给存活队员发 30 经验（实得 %.0f）"
			% float(Meta.unit_by_uid(uid_live).get("xp", -1.0)))

	# 再来一个无名册身份的玩家（uid 0）：不该多发一份、也不该冒名加到别人头上
	var xp_before := _roster_xp_total()
	var p2: Node = load("res://Scenes/Player.tscn").instantiate()
	p2.set("roster_uid", 0)
	add_child(p2)
	await _frames(2)
	Meta.grant_xp_to_survivors()
	_check(is_equal_approx(_roster_xp_total(), xp_before + 30.0),
			"场上有无名册身份的玩家时，也只在名册那一位身上加 30（总量 %.0f → %.0f）"
			% [xp_before, _roster_xp_total()])

	# 「已经死了但还没除名」这条边（grant 里的 is_dead 保护）
	var uid_ghost := 0
	for u in Meta.roster:
		if int(u.get("uid", 0)) != uid_live:
			uid_ghost = int(u.get("uid", 0))
			break
	if uid_ghost > 0:
		# 先把场上唯一那个「有身份且活着」的人摘掉，否则他每被 grant 一次就 +30，
		# 会把「已死的不发」这条断言的差值搅浑。
		var uid_saved := int(p.get("roster_uid"))
		p.set("roster_uid", 0)
		Meta.unit_by_uid(uid_ghost)["level"] = 0
		Meta.unit_by_uid(uid_ghost)["xp"] = 0.0
		var p3: Node = load("res://Scenes/Player.tscn").instantiate()
		p3.set("roster_uid", uid_ghost)
		add_child(p3)
		await _frames(2)
		p3.set("_dead", true)          # 只标死、不走 on_death（模拟"还没除名"的瞬间）
		var before_ghost := _roster_xp_total()
		Meta.grant_xp_to_survivors()
		_check(is_equal_approx(_roster_xp_total(), before_ghost),
				"已阵亡的队员不发经验（is_dead 保护，总量 %.0f → %.0f）"
				% [before_ghost, _roster_xp_total()])
		p3.queue_free()
		await _frames(2)
		p.set("roster_uid", uid_saved)   # 恢复身份，后面死亡除名那条要用
	p2.queue_free()
	await _frames(2)
	Config.clear_override("progression.xp.per_extraction")

	# 死亡永久：阵亡即从名册除名
	var uid_die := int(p.get("roster_uid"))
	_check(uid_die > 0 and not Meta.unit_by_uid(uid_die).is_empty(), "临死前他还挂在名册上")
	p.call("on_death")
	await _frames(3)
	_check(Meta.unit_by_uid(uid_die).is_empty(),
			"阵亡后从名册除名（等级与经验一并消失）")
	_check(int(p.get("roster_uid")) == 0, "除名后 roster_uid 归零（防重复除名）")

	# 无名册身份的临时角色不该动名册
	var n_before := Meta.roster.size()
	var tmp: Node = load("res://Scenes/Player.tscn").instantiate()
	tmp.set("roster_uid", 0)
	add_child(tmp)
	await _frames(2)
	tmp.call("on_death")
	await _frames(2)
	_check(Meta.roster.size() == n_before,
			"roster_uid = 0 的临时角色阵亡不影响名册（%d → %d）" % [n_before, Meta.roster.size()])
	tmp.queue_free()


# ------------------------------------------------------------
# H 段：出击面板
# ------------------------------------------------------------
func _row_texts(panel: Node) -> Array:
	var out: Array = []
	var content: Node = panel.get("_content")
	for row in content.get_children():
		for c in row.get_children():
			if c is Label:
				out.append(str((c as Label).text))
	return out


func _h_panel(m: Node) -> void:
	_say("--- H 段：出击面板（名册视图） ---")
	var panel: Node = m.get("character_panel")
	_check(panel != null, "Main 场景里拿到了 CharacterPanel")
	if panel == null:
		return

	# 造一个可预期的名册：3 人，其中一人 Lv3（紫档）
	Meta.roster = []
	Meta.ensure_roster()
	Meta.roster[1]["level"] = 3
	Meta.roster[1]["xp"] = 40.0

	panel.call("open", [])
	await _frames(3)
	var checks: Array = panel.get("_checks")
	_check(checks.size() == 3, "面板列出名册 3 人（实得 %d）" % checks.size())
	var texts := _row_texts(panel)
	var joined := " | ".join(texts)
	_check(joined.find("枪手") >= 0 and joined.find("弓兵") >= 0
			and joined.find("剑士") >= 0, "三行分别显示三个人的名字")
	_check(joined.find("Lv3") >= 0 and joined.find("老兵") >= 0,
			"第二人显示 Lv3 / 老兵档位（档位名来自 progression.tiers）")
	_check(joined.find("经验 40 /") >= 0, "显示当前经验进度（实得含「经验 40」：%s）"
			% ("是" if joined.find("经验 40") >= 0 else "否"))
	_check(joined.find("枪手 · Lv0 新兵") >= 0, "0 级显示为「名字 · Lv0 新兵」")
	var btn: Button = panel.get("_launch_btn")
	_check(btn.text.find("已选 3 名") >= 0, "默认全选，按钮写「已选 3 名」（实得 %s）" % btn.text)

	# 取消勾选一人
	(checks[0]["checkbox"] as CheckBox).button_pressed = false
	await _frames(2)
	_check(btn.text.find("已选 2 名") >= 0, "取消一人后按钮变「已选 2 名」（实得 %s）" % btn.text)

	# 补招按钮：名册 3/8 → 每个兵种一个按钮
	var rrow: Node = panel.get("_recruit_row")
	var recruit_btns: Array = []
	for c in rrow.get_children():
		if c is Button:
			recruit_btns.append(c)
	_check(recruit_btns.size() == 3, "名册不满时给出 3 个补招按钮（实得 %d）"
			% recruit_btns.size())
	var before := Meta.roster.size()
	if not recruit_btns.is_empty():
		(recruit_btns[0] as Button).emit_signal("pressed")
		await _frames(3)
		_check(Meta.roster.size() == before + 1, "点补招后名册 +1（%d → %d）"
				% [before, Meta.roster.size()])
		var after_checks: Array = panel.get("_checks")
		_check(after_checks.size() == before + 1, "面板立刻重画出新兵那一行（%d 行）"
				% after_checks.size())
		var last: Dictionary = after_checks[after_checks.size() - 1]
		_check(bool((last["checkbox"] as CheckBox).button_pressed),
				"新招的人默认带上（已勾选）")

	# 出击信号：条目必须带 uid / level（否则局内还原不出"带的是谁"）
	var got: Array = []
	panel.connect("launch_requested", func(units: Array): got.append_array(units), CONNECT_ONE_SHOT)
	panel.call("_on_launch_pressed")
	await _frames(2)
	_check(got.size() >= 2, "点出击发出 %d 个条目" % got.size())
	if not got.is_empty():
		var e0: Dictionary = got[0]
		_check(int(e0.get("uid", 0)) > 0 and e0.has("level") and e0.has("id"),
				"条目带了 uid/level/id（%s）" % str(e0))
		var with_lv := false
		for e in got:
			if int((e as Dictionary).get("level", 0)) == 3:
				with_lv = true
		_check(with_lv, "Lv3 那位按自己的等级出击（不是兵种共用等级）")

	# 名册满 → 没有补招按钮
	Meta.roster = []
	var cap := int(Config.get_value("progression.roster.max_size", 8))
	for _i in range(cap + 2):
		Meta.recruit("spearman")
	panel.call("open", [])
	await _frames(3)
	var full_btns := 0
	for c in (panel.get("_recruit_row") as Node).get_children():
		if c is Button:
			full_btns += 1
	_check(Meta.roster.size() == cap, "名册补到上限 %d 人（实得 %d）" % [cap, Meta.roster.size()])
	_check(full_btns == 0, "满编时不给补招按钮（实得 %d 个）" % full_btns)
	_check((panel.get("_checks") as Array).size() == cap,
			"面板列出满编 %d 行（实得 %d）" % [cap, (panel.get("_checks") as Array).size()])
	panel.call("close")


# ------------------------------------------------------------
# 存档备份 / 还原 + 收尾
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
	print("[probe_level] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

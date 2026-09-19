extends Node
## ============================================================
## MetaProgression — 自动加载单例（在脚本里用 `Meta` 访问）
## 职责：局外持久层，跨局存在。
##   1. 存档/读档
##   2. 局外资源仓库（撤离成功带回的资源堆在这里）
##   3. 升级购买（两条养成线：survival 生存 / acquisition 获取）
##   4. 把养成加成折算成局内属性，供 RunManager 取用
##
## 存档位置分两种情况（见 Scripts/save_slots.gd）：
##   · 从开始菜单进游戏：`SaveSlots.active_slot > 0`，读写 user://saves/slot_NN.json
##   · 直接跑 Main.tscn（命令行/无头回归）：active_slot == 0，
##     读写旧的单槽 user://save.json —— 行为与加菜单之前**完全一致**。
##
## 数值全部来自 Data/config.json 的 meta_progression 节点，
## 升级费用 = 配置 cost × (当前等级 + 1)，越买越贵。
## ============================================================

## 旧版单槽存档路径。保留是为了让不经过菜单的入口（headless 回归、出图脚本）
## 行为不变 —— 那些入口不该往玩家的真实存档槽里写数据。
const SAVE_PATH := "user://save.json"

## 局外资源仓库，形如 {"scrap": 30, "steam_core": 2}
var bank: Dictionary = {}
## 已购升级等级，形如 {"survival.max_hp": 1}
var upgrade_levels: Dictionary = {}
## 基地建筑位置（每存档槽独立），形如 {"warehouse": [24, 30], ...}
var base_layout: Dictionary = {}
## 名册：跨局持久的**单位实例**（死亡永久，所以等级挂在具体的人身上而不是兵种上）。
## 形如 [{"uid":1, "id":"spearman", "name":"枪手", "level":0, "xp":0.0}]
## —— id 指向 characters.list 里的原型（决定武器/指令集），level/xp 是这个人自己的。
var roster: Array = []

## 出厂名单（progression.roster.starting）里**已经发过的**原型 id。
## 用来区分「这兵种玩家从没有过」和「这个人阵亡后被除名」：
## starting 以后新增原型时只补发一次，不会每次读档把死者拉回来。
var seeded_ids: Array = []


func _ready() -> void:
	load_save()
	print("[Meta] 存档加载完成（%s）：仓库 %s | 升级 %s | 基地 %d 栋 | 名册 %d 人" % [
		("槽 %d" % SaveSlots.active_slot) if SaveSlots.has_active_slot() else "本地默认槽",
		bank, upgrade_levels, base_layout.size(), roster.size()])


# ------------------------------------------------------------
# 存档
# ------------------------------------------------------------

func load_save() -> void:
	bank = {}
	upgrade_levels = {}
	base_layout = {}
	roster = []
	seeded_ids = []
	if SaveSlots.has_active_slot():
		var slot_data: Dictionary = SaveSlots.read_slot(SaveSlots.active_slot)
		if slot_data.is_empty():
			push_warning("[Meta] 槽 %d 读不到内容，按空存档处理" % SaveSlots.active_slot)
			ensure_roster()
			return
		bank = slot_data.get("bank", {})
		upgrade_levels = slot_data.get("upgrades", {})
		base_layout = slot_data.get("base_layout", {})
		roster = _sanitize_roster(slot_data.get("roster", []))
		seeded_ids = _sanitize_seeded(slot_data.get("seeded_ids", []))
		_prune_unknown_resources()
		ensure_roster()
		return
	# --- 无激活槽：旧的单槽路径 ---
	if not FileAccess.file_exists(SAVE_PATH):
		ensure_roster()
		return  # 首次游玩，无存档
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if parsed is Dictionary:
		bank = parsed.get("bank", {})
		upgrade_levels = parsed.get("upgrades", {})
		base_layout = parsed.get("base_layout", {})
		roster = _sanitize_roster(parsed.get("roster", []))
		seeded_ids = _sanitize_seeded(parsed.get("seeded_ids", []))
	else:
		push_warning("[Meta] 存档损坏，已重置。")
	_prune_unknown_resources()
	ensure_roster()


## seeded_ids 清洗：只留字符串、去重（存档手改过 / 半截写入都不能让它变成脏数组）
func _sanitize_seeded(raw) -> Array:
	var out: Array = []
	if raw is Array:
		for id in raw:
			var s := str(id)
			if s != "" and not out.has(s):
				out.append(s)
	return out


## 清理存档里已不存在于 config.resources 的废弃资源
## （如旧版的废铁 scrap / 蒸汽核心 steam_core：它们没有用途、也不该占仓库格子）
func _prune_unknown_resources() -> void:
	var known = Config.get_value("resources", {})
	if not (known is Dictionary) or bank.is_empty():
		return
	var removed: Array = []
	for res in bank.keys():
		if not known.has(res):
			removed.append(res)
	if removed.is_empty():
		return
	for res in removed:
		bank.erase(res)
	print("[Meta] 已清理废弃资源：%s" % ", ".join(removed))
	save_game()


func save_game() -> void:
	if SaveSlots.has_active_slot():
		SaveSlots.write_active(bank, upgrade_levels, base_layout, roster, seeded_ids)
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[Meta] 存档写入失败：%s" % SAVE_PATH)
		return
	f.store_string(JSON.stringify(
			{"bank": bank, "upgrades": upgrade_levels, "base_layout": base_layout,
			 "roster": roster, "seeded_ids": seeded_ids}, "\t"))


## 记录某建筑的新位置（占地左上角格）到本存档槽并落盘。
func set_building_cell(id: String, cell: Vector2i) -> void:
	base_layout[id] = [cell.x, cell.y]
	save_game()


# ------------------------------------------------------------
# 局内加成注入
# ------------------------------------------------------------

## 把所有养成项折算成局内属性，RunManager.start_run() 时取用。
## 返回形如 {"survival.max_hp": 110.0, "acquisition.rare_resource_chance": 0.06}
## （跳过 name/format 等非升级项描述字段）
func get_run_stats() -> Dictionary:
	var stats := {}
	for key in get_upgrade_keys():
		stats[key] = get_stat(key)
	return stats


## 所有升级项的完整键列表（"survival.max_hp" 等），供升级界面遍历
func get_upgrade_keys() -> Array:
	var keys: Array = []
	for line in ["survival", "acquisition"]:
		var line_cfg: Dictionary = Config.get_value("meta_progression.%s" % line, {})
		for key in line_cfg:
			if line_cfg[key] is Dictionary:  # 只有字典才是升级项
				keys.append("%s.%s" % [line, key])
	return keys


## 单项当前数值 = base + per_level × 已升等级
func get_stat(key: String) -> float:
	var base := float(Config.get_value("meta_progression.%s.base" % key, 0))
	var per_level := float(Config.get_value("meta_progression.%s.per_level" % key, 0))
	return base + per_level * get_upgrade_level(key)


func get_upgrade_level(key: String) -> int:
	return int(upgrade_levels.get(key, 0))


# ------------------------------------------------------------
# 升级购买
# ------------------------------------------------------------

## 当前升级费用（随等级上涨），形如 {"scrap": 30, "steam_core": 1}
func get_upgrade_cost(key: String) -> Dictionary:
	var cost_cfg: Dictionary = Config.get_value("meta_progression.%s.cost" % key, {})
	var multiplier := get_upgrade_level(key) + 1
	var cost := {}
	for res in cost_cfg:
		cost[res] = int(cost_cfg[res]) * multiplier
	return cost


## 是否可购买：未满级 且 仓库资源够
func can_afford(key: String) -> bool:
	if get_upgrade_level(key) >= int(Config.get_value("meta_progression.%s.max_level" % key, 0)):
		return false
	for res in get_upgrade_cost(key):
		if int(bank.get(res, 0)) < int(get_upgrade_cost(key)[res]):
			return false
	return true


## 购买升级：扣资源、升等级、立即存档。成功返回 true。
func buy_upgrade(key: String) -> bool:
	if not can_afford(key):
		return false
	for res in get_upgrade_cost(key):
		bank[res] = int(bank.get(res, 0)) - int(get_upgrade_cost(key)[res])
	upgrade_levels[key] = get_upgrade_level(key) + 1
	save_game()
	print("[Meta] 升级 %s → Lv.%d，当前数值 %s" % [key, upgrade_levels[key], get_stat(key)])
	return true


# ------------------------------------------------------------
# 资源结算（仓库规则：storage.max_slots 格，每格一种物品，叠加 ≤ stack_limit）
# ------------------------------------------------------------

## 当前仓库容量（格数，可被 warehouse_capacity 升级提升）
func warehouse_slots() -> int:
	return int(get_stat("survival.warehouse_capacity"))


# ------------------------------------------------------------
# 名册 / 等级（config progression 段，2026-09-17 新增）
#
# 设计要点：**等级挂在具体的人身上，不挂在兵种上** —— 因为死亡是永久的
# （用户原话：「死亡就死亡了，不会复活」）。名册里的每个单位是一个实例：
# id 指向 characters.list 的原型（决定武器/指令集），level/xp 是它自己的。
# 视觉上等级 = 配色分档（一眼）+ 头顶数字（精确），见 progression.tiers/badge。
# ------------------------------------------------------------

func max_level() -> int:
	return int(Config.get_value("progression.max_level", 9))


## 从 characters.list 查原型；查不到返回 {}
func _archetype(archetype_id: String) -> Dictionary:
	if archetype_id == "":
		return {}
	for e in Config.get_value("characters.list", []):
		if e is Dictionary and str(e.get("id", "")) == archetype_id:
			return e
	return {}


## 读档后清洗：丢掉字段残缺或原型已删除的条目（避免面板里出现幽灵单位）
func _sanitize_roster(raw) -> Array:
	var out: Array = []
	if raw is Array:
		for e in raw:
			if not (e is Dictionary):
				continue
			if _archetype(str(e.get("id", ""))).is_empty():
				continue
			out.append({
				"uid": int(e.get("uid", 0)),
				"id": str(e.get("id", "")),
				"name": str(e.get("name", "")),
				"level": clampi(int(e.get("level", 0)), 0, max_level()),
				"xp": maxf(0.0, float(e.get("xp", 0.0))),
				"traits": _sanitize_traits(e.get("traits", {})),
			})
	# uid 撞号会让「谁是谁」彻底乱掉：重新分配一遍
	var uid := 1
	for u in out:
		u["uid"] = uid
		uid += 1
	return out


func _next_uid() -> int:
	var mx := 0
	for u in roster:
		mx = maxi(mx, int(u.get("uid", 0)))
	return mx + 1


## 保证名册可用：
##   · 空名册（首次游玩 / 全员阵亡且允许补招）→ 按 progression.roster.starting 建队
##   · 老档（出厂名单建队之后才给 starting 加新原型）→ 见 _migrate_starting_units
func ensure_roster() -> void:
	var starting = Config.get_value("progression.roster.starting", [])
	if roster.is_empty():
		if starting is Array and not (starting as Array).is_empty():
			for id in starting:
				recruit(str(id))
		else:
			recruit(str(Config.get_value("characters.default", "spearman")))
		if starting is Array:
			seeded_ids = (starting as Array).map(func(id): return str(id))
		if not roster.is_empty():
			var desc := ""
			for u in roster:
				desc += "%s(Lv%d) " % [str(u.get("name", "?")), int(u.get("level", 0))]
			print("[Meta] 名册初始化：%s" % desc.strip_edges())
			save_game()
		return
	_migrate_starting_units(starting)


## 出厂名单迁移：monk（2026-09-18）之前建的名册只有 3 人，新原型不会凭空出现。
## 只补「从来没发过」的那些（seeded_ids 记着发过什么），所以阵亡除名的人不会被拉回来。
func _migrate_starting_units(starting) -> void:
	if not (starting is Array) or (starting as Array).is_empty():
		return
	if seeded_ids.is_empty():
		# 加字段之前建的老档：没有标记可依，就把「现在名册里有人」当作已发过，
		# 只补 starting 里缺的那几个（发过又阵亡的原型不在 starting 之外，不会被拉回）
		for u in roster:
			var id := str(u.get("id", ""))
			if id != "" and not seeded_ids.has(id):
				seeded_ids.append(id)
	var added: Array = []
	for raw in starting:
		var id := str(raw)
		if id in seeded_ids:
			continue
		seeded_ids.append(id)
		if not recruit(id).is_empty():
			added.append(id)
	if added.is_empty():
		return
	save_game()
	print("[Meta] 出厂名单已更新，补招新兵：%s" % ", ".join(added))


## 补招一名 0 级新兵。满编或原型不存在时返回 {}
func recruit(archetype_id: String) -> Dictionary:
	if _archetype(archetype_id).is_empty():
		push_warning("[Meta] 补招失败：原型不存在 %s" % archetype_id)
		return {}
	if roster.size() >= int(Config.get_value("progression.roster.max_size", 8)):
		return {}
	var same := 0
	for u in roster:
		if str(u.get("id", "")) == archetype_id:
			same += 1
	var base_name := str(_archetype(archetype_id).get("name", archetype_id))
	var unit := {
		"uid": _next_uid(),
		"id": archetype_id,
		"name": base_name if same == 0 else "%s%d" % [base_name, same + 1],
		"level": 0,
		"xp": 0.0,
		"traits": {},
	}
	roster.append(unit)
	save_game()
	print("[Meta] 补招新兵：%s（%s，Lv0）" % [unit["name"], archetype_id])
	return unit


## 是否允许免费补招（config progression.roster.recruit_free）
func can_recruit() -> bool:
	return bool(Config.get_value("progression.roster.recruit_free", true))


## 单位阵亡：从名册移除，等级与经验一并消失（死亡永久）
func remove_unit(uid: int) -> void:
	for i in range(roster.size()):
		if int(roster[i].get("uid", 0)) == uid:
			var gone: Dictionary = roster[i]
			roster.remove_at(i)
			save_game()
			print("[Meta] 阵亡除名：%s（Lv%d）—— 等级与经验一并消失"
				% [str(gone.get("name", "?")), int(gone.get("level", 0))])
			return


func unit_by_uid(uid: int) -> Dictionary:
	for u in roster:
		if int(u.get("uid", 0)) == uid:
			return u
	return {}


func level_of(uid: int) -> int:
	return int(unit_by_uid(uid).get("level", 0))


# ------------------------------------------------------------
# 升级特性（config progression.traits.list，2026-09-18 用户定）
#
# 每次升级随机 +1 层某个特性；收益按层累计 —— 等级越高攒的层越多。
# 特性挂在具体的人身上（与 level/xp 同级），存在 roster 单位里：{"attack": 2, ...}。
# 随机用全局 randi()（无头 --seed 可复现），抽取均匀、无权重。
# ------------------------------------------------------------

## 特性定义表（id → 定义字典），从 config progression.traits.list 读一次缓存
var _trait_defs: Dictionary = {}


func trait_defs() -> Dictionary:
	if not _trait_defs.is_empty():
		return _trait_defs
	for t in Config.get_value("progression.traits.list", []):
		if t is Dictionary:
			var id := str(t.get("id", ""))
			if id != "":
				_trait_defs[id] = t
	return _trait_defs


func trait_ids() -> Array:
	return trait_defs().keys()


## 扣减表 → 「攻击-7 移速-10」。属性名与顺序都取 progression.traits 那张表，
## 与出击面板/升级提示同一套叫法。HUD 生存行与背包弹窗共用 —— 各写一份，
## 改 traits 表时必然漏一边（空表时的兜底文案也一样）。
func penalty_line(merged: Dictionary) -> String:
	var out: Array = []
	for id in trait_ids():
		var v := float(merged.get(id, 0.0))
		if v > 0.0:
			var d: Dictionary = trait_defs().get(id, {})
			out.append("%s-%d" % [str(d.get("name", id)), int(round(v))])
	return " ".join(out) if not out.is_empty() else "无属性变化"


## 某特性的层数收益 = 层数 × per_stack（供面板显示用）
func trait_value(id: String, stacks: int) -> float:
	var d: Dictionary = trait_defs().get(id, {})
	return float(d.get("per_stack", 0.0)) * float(stacks)


## 清洗存档里的 traits：只保留已知 id、层数取非负整数
func _sanitize_traits(raw) -> Dictionary:
	var out := {}
	if raw is Dictionary:
		for id in (raw as Dictionary).keys():
			var s := int(raw[id])
			if s > 0 and trait_defs().has(str(id)):
				out[str(id)] = s
	return out


## 升级时随机 +1 层某特性（就地改 u，不单独落盘 —— 调用方 add_xp 会统一 save）
func _roll_trait(u: Dictionary) -> void:
	var ids := trait_ids()
	if ids.is_empty():
		return
	var picked := str(ids[randi() % ids.size()])
	if not (u.get("traits", null) is Dictionary):
		u["traits"] = {}
	var tr: Dictionary = u["traits"]
	tr[picked] = int(tr.get(picked, 0)) + 1


## 取某人的特性层数表（拷贝，防止调用方改到存档内部字典）
func traits_of(uid: int) -> Dictionary:
	return Dictionary(unit_by_uid(uid).get("traits", {})).duplicate()


## 升到下一级所需经验 = round(base × growth^当前等级)
func xp_to_next(level: int) -> float:
	var base := float(Config.get_value("progression.xp.curve.base", 100.0))
	var growth := float(Config.get_value("progression.xp.curve.growth", 1.9))
	return round(base * pow(growth, float(level)))


## 加经验，返回升了几级（满级后经验不再累积）
func add_xp(uid: int, amount: float) -> int:
	var u := unit_by_uid(uid)
	if u.is_empty():
		return 0
	var gained := 0
	var lv := int(u.get("level", 0))
	var xp := float(u.get("xp", 0.0))
	if lv >= max_level():
		return 0
	xp += amount
	while lv < max_level() and xp >= xp_to_next(lv):
		xp -= xp_to_next(lv)
		lv += 1
		gained += 1
		_roll_trait(u)      # 每升 1 级随机 +1 层特性（按层累计，等级越高攒得越多）
	u["level"] = lv
	u["xp"] = xp
	save_game()
	if gained > 0:
		print("[Meta] %s 升级 → Lv%d（档位 %s）"
			% [str(u.get("name", "?")), lv, tier_id_of_level(lv)])
	return gained


## 撤离成功：给**存活**的队员发经验（阵亡的已经除名了，自然拿不到）
func grant_xp_to_survivors() -> void:
	var per := float(Config.get_value("progression.xp.per_extraction", 0.0))
	if per <= 0.0:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for p in tree.get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		var uid := 0
		if "roster_uid" in p:
			uid = int(p.get("roster_uid"))
		if uid == 0:
			continue      # 无名册身份（命令行/无头回归生成的临时角色）不发经验
		if p.has_method("is_dead") and bool(p.call("is_dead")):
			continue      # 阵亡的已经除名，这里再跳过一次更保险
		add_xp(uid, per)


## 等级 → 档位（progression.tiers 里第一条 max_level ≥ 该等级的）。
## 先把等级钳进 [0, max_level]：越界时**向末档收敛**而不是返回 {} ——
## 返回空字典会让调用方回落到"蓝档/新兵"，一个越界的等级反而被显示成最低档，
## 那是比崩溃更难查的错（面板上写着传奇、身上穿着新兵蓝）。
func tier_of_level(level: int) -> Dictionary:
	var lv := clampi(level, 0, max_level())
	for t in Config.get_value("progression.tiers", []):
		if t is Dictionary and lv <= int(t.get("max_level", 0)):
			return t
	return {}


func tier_id_of_level(level: int) -> String:
	var t := tier_of_level(level)
	return str(t.get("id", "blue")) if not t.is_empty() else "blue"


func tier_name_of_level(level: int) -> String:
	var t := tier_of_level(level)
	return str(t.get("name", "")) if not t.is_empty() else ""


## 该武器在该等级下该用哪套贴图集（档位配色）；查不到就回落到武器自带的
func unit_sprite_set(weapon_id: String, level: int) -> String:
	var mapped := str(Config.get_value(
			"progression.sprite_sets.%s.%s" % [tier_id_of_level(level), weapon_id], ""))
	return mapped


## 撤离成功后由 RunManager 调用：战利品入库并存档。
## 规则：已有种类继续叠加（超出 stack_limit 上限截断丢弃）；
## 新种类需有空余格，仓库满则该种类整组丢弃。
func bank_loot(loot: Dictionary) -> void:
	var stack_limit := int(Config.get_value("storage.stack_limit", 1000))
	var slots := warehouse_slots()
	var dropped: Array = []
	for res in loot:
		if not bank.has(res):
			if bank.size() >= slots:
				dropped.append(res)
				continue  # 仓库满，新种类无处安放
			bank[res] = 0
		var space_left: int = stack_limit - int(bank[res])
		var amount_in: int = mini(int(loot[res]), space_left)
		bank[res] = int(bank[res]) + amount_in
		if amount_in < int(loot[res]):
			dropped.append(res)  # 叠加超限，部分丢弃
	save_game()
	if not dropped.is_empty():
		print("[Meta] 仓库入库提示：以下资源超出容量被丢弃/截断：%s" % ", ".join(dropped))

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


func _ready() -> void:
	load_save()
	print("[Meta] 存档加载完成（%s）：仓库 %s | 升级 %s" % [
		("槽 %d" % SaveSlots.active_slot) if SaveSlots.has_active_slot() else "本地默认槽",
		bank, upgrade_levels])


# ------------------------------------------------------------
# 存档
# ------------------------------------------------------------

func load_save() -> void:
	bank = {}
	upgrade_levels = {}
	if SaveSlots.has_active_slot():
		var slot_data: Dictionary = SaveSlots.read_slot(SaveSlots.active_slot)
		if slot_data.is_empty():
			push_warning("[Meta] 槽 %d 读不到内容，按空存档处理" % SaveSlots.active_slot)
			return
		bank = slot_data.get("bank", {})
		upgrade_levels = slot_data.get("upgrades", {})
		_prune_unknown_resources()
		return
	# --- 无激活槽：旧的单槽路径 ---
	if not FileAccess.file_exists(SAVE_PATH):
		return  # 首次游玩，无存档
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if parsed is Dictionary:
		bank = parsed.get("bank", {})
		upgrade_levels = parsed.get("upgrades", {})
	else:
		push_warning("[Meta] 存档损坏，已重置。")
	_prune_unknown_resources()


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
		SaveSlots.write_active(bank, upgrade_levels)
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[Meta] 存档写入失败：%s" % SAVE_PATH)
		return
	f.store_string(JSON.stringify({"bank": bank, "upgrades": upgrade_levels}, "\t"))


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


## 撤离成功后由 RunManager 调用：战利品入库并存档。
## 规则：已有种类继续叠加（超出 1000 上限截断丢弃）；
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

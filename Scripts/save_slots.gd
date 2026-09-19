extends Node
## ============================================================
## SaveSlots — 多存档槽管理（自动加载单例，在脚本里用 `SaveSlots` 访问）
##
## 背景：项目原本只有一个 `user://save.json` 单槽（MetaProgression 直接用），
## 开始菜单要「新建存档 / 历史存档」，就得先有"槽"这个概念。
##
## 布局：
##   user://saves/slot_01.json … slot_NN.json   每槽一个文件，自带元数据
##   user://saves/state.json                    {"migrated":bool,"last_slot":int}
##   user://save.json                           旧版单槽，**保留不动**（见下）
##
## 与旧存档的关系（重要）：旧文件既不删也不改名，只是**复制**一份进 1 号槽
## （只在首次运行做一次，记在 state.json 的 migrated 标志里）。
## 这样：
##   · 玩家从菜单进游戏 → 用槽，进度续得上；
##   · 命令行/无头回归直接跑 Main.tscn（不经过菜单）→ `active_slot` 仍是 0，
##     Meta 继续走旧的单槽路径，**现有工具链行为零变化**。
## 刻意不做"启动时自动激活上次的槽"——那会把无头回归的读写灌进玩家的真实存档。
## ============================================================

const DIR := "user://saves"
const SLOT_FMT := "user://saves/slot_%02d.json"
const STATE_PATH := "user://saves/state.json"
const LEGACY_PATH := "user://save.json"
const SLOT_VERSION := 1

## 当前激活的槽号；0 = 未选中（Meta 走旧的单槽路径）
var active_slot := 0
## 上次游玩过的槽号，**仅**用于列表高亮，不自动激活
var last_slot := 0

var _state: Dictionary = {}


func _ready() -> void:
	_ensure_dir()
	_load_state()
	migrate_legacy()
	# last_slot 只存了个槽号，文件可能已被删（面板删除 / 手工清档），
	# 不校验就会把一个"空槽"在菜单里标成「上次游玩」。这里兜一次。
	if last_slot > 0 and not exists(last_slot):
		last_slot = 0
		_state["last_slot"] = 0
		_save_state()
	print("[SaveSlots] %d 个槽位可用｜上次游玩：%s" % [
		slot_count(), ("槽 %d" % last_slot) if last_slot > 0 else "无"])


# ------------------------------------------------------------
# 基础
# ------------------------------------------------------------

func slot_count() -> int:
	return maxi(1, int(Config.get_value("menu.save_slots", 6)))


func path_for(slot: int) -> String:
	return SLOT_FMT % slot


func exists(slot: int) -> bool:
	return slot >= 1 and slot <= slot_count() and FileAccess.file_exists(path_for(slot))


func has_active_slot() -> bool:
	return active_slot > 0


## 读某槽的完整内容；不存在或损坏时返回 {}
func read_slot(slot: int) -> Dictionary:
	var p := path_for(slot)
	if not FileAccess.file_exists(p):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (parsed is Dictionary):
		push_warning("[SaveSlots] 槽 %d 存档损坏，已忽略：%s" % [slot, p])
		return {}
	return parsed


func write_slot(slot: int, payload: Dictionary) -> bool:
	_ensure_dir()
	var f := FileAccess.open(path_for(slot), FileAccess.WRITE)
	if f == null:
		push_error("[SaveSlots] 槽 %d 写入失败：%s" % [slot, path_for(slot)])
		return false
	f.store_string(JSON.stringify(payload, "\t"))
	return true


func delete_slot(slot: int) -> bool:
	if not exists(slot):
		return false
	var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(path_for(slot)))
	if err != OK:
		push_error("[SaveSlots] 槽 %d 删除失败（err=%d）" % [slot, err])
		return false
	if active_slot == slot:
		active_slot = 0
	if last_slot == slot:
		last_slot = 0
		_state["last_slot"] = 0
		_save_state()
	print("[SaveSlots] 槽 %d 已删除" % slot)
	return true


func rename_slot(slot: int, new_name: String) -> bool:
	var data := read_slot(slot)
	if data.is_empty():
		return false
	data["name"] = new_name
	return write_slot(slot, data)


# ------------------------------------------------------------
# 新建 / 载入 / 激活
# ------------------------------------------------------------

## 新建一个空槽并激活。同名覆盖由调用方（存档面板）负责二次确认。
func create_slot(slot: int, slot_name: String = "") -> bool:
	if slot < 1 or slot > slot_count():
		return false
	var now := int(Time.get_unix_time_from_system())
	var payload := {
		"version": SLOT_VERSION,
		"slot": slot,
		"name": slot_name if slot_name != "" else default_slot_name(slot),
		"created_unix": now,
		"last_played_unix": now,
		"bank": {},
		"upgrades": {},
		"base_layout": {},
		"roster": [],
		"seeded_ids": [],
	}
	if not write_slot(slot, payload):
		return false
	activate(slot)
	print("[SaveSlots] 已新建槽 %d「%s」" % [slot, payload["name"]])
	return true


func default_slot_name(slot: int) -> String:
	return "存档 %d" % slot


## 载入某槽。激活后通知 MetaProgression 重新读取。
func activate(slot: int) -> bool:
	if not exists(slot):
		return false
	active_slot = slot
	_touch_last(slot)
	Meta.load_save()
	return true


## 当前槽的数据（Meta 存档时取用）
func active_payload() -> Dictionary:
	if active_slot <= 0:
		return {}
	return read_slot(active_slot)


## Meta.save_game 走这里：把仓库/升级/**名册**写回当前槽，并刷新时间戳。
## seeded_ids = 出厂名单里已发过的原型（见 Meta._migrate_starting_units），一起持久化。
func write_active(bank: Dictionary, upgrades: Dictionary, base_layout: Dictionary = {},
		roster: Array = [], seeded_ids: Array = []) -> bool:
	if active_slot <= 0:
		return false
	var data := read_slot(active_slot)
	if data.is_empty():
		data = {
			"version": SLOT_VERSION,
			"slot": active_slot,
			"name": default_slot_name(active_slot),
			"created_unix": int(Time.get_unix_time_from_system()),
		}
	data["bank"] = bank
	data["upgrades"] = upgrades
	data["base_layout"] = base_layout
	data["roster"] = roster
	data["seeded_ids"] = seeded_ids
	data["last_played_unix"] = int(Time.get_unix_time_from_system())
	return write_slot(active_slot, data)


# ------------------------------------------------------------
# 列表（供 UI 直接渲染）
# ------------------------------------------------------------

func list_slots() -> Array:
	var out: Array = []
	for i in range(1, slot_count() + 1):
		out.append(slot_info(i))
	return out


func slot_info(slot: int) -> Dictionary:
	var data := read_slot(slot)
	if data.is_empty():
		return {
			"slot": slot, "exists": false, "name": default_slot_name(slot),
			"created": "", "last_played": "", "bank_kinds": 0, "bank_total": 0,
			"upgrade_total": 0, "is_last": false,
		}
	var bank: Dictionary = data.get("bank", {})
	var upgrades: Dictionary = data.get("upgrades", {})
	var bank_total := 0
	for res in bank:
		bank_total += int(bank[res])
	var up_total := 0
	for k in upgrades:
		up_total += int(upgrades[k])
	return {
		"slot": slot,
		"exists": true,
		"name": str(data.get("name", default_slot_name(slot))),
		"created": format_time(int(data.get("created_unix", 0))),
		"last_played": format_time(int(data.get("last_played_unix", 0))),
		"bank_kinds": bank.size(),
		"bank_total": bank_total,
		"upgrade_total": up_total,
		"is_last": slot == last_slot,
	}


func format_time(unix: int) -> String:
	if unix <= 0:
		return "—"
	var d := Time.get_datetime_dict_from_unix_time(unix)
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]


# ------------------------------------------------------------
# 旧版单槽迁移（复制，不删不改名）
# ------------------------------------------------------------

func migrate_legacy() -> void:
	if bool(_state.get("migrated", false)):
		return
	if not FileAccess.file_exists(LEGACY_PATH):
		_state["migrated"] = true
		_save_state()
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(LEGACY_PATH))
	if not (parsed is Dictionary):
		push_warning("[SaveSlots] 旧存档损坏，跳过迁移：%s" % LEGACY_PATH)
		_state["migrated"] = true
		_save_state()
		return
	if exists(1):
		# 1 号槽已存在就不动手，避免覆盖玩家已经玩过的内容
		_state["migrated"] = true
		_save_state()
		return
	var now := int(Time.get_unix_time_from_system())
	var ok := write_slot(1, {
		"version": SLOT_VERSION,
		"slot": 1,
		"name": "存档 1（旧版导入）",
		"created_unix": now,
		"last_played_unix": now,
		"bank": parsed.get("bank", {}),
		"upgrades": parsed.get("upgrades", {}),
		"migrated_from": LEGACY_PATH,
	})
	_state["migrated"] = true
	_save_state()
	if ok:
		print("[SaveSlots] 旧单槽存档已复制到 1 号槽（原文件 %s 保留未动）" % LEGACY_PATH)


# ------------------------------------------------------------
# 内部
# ------------------------------------------------------------

func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(DIR)):
		var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
		if err != OK:
			push_error("[SaveSlots] 存档目录创建失败：%s（err=%d）" % [DIR, err])


func _load_state() -> void:
	if FileAccess.file_exists(STATE_PATH):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(STATE_PATH))
		if parsed is Dictionary:
			_state = parsed
	last_slot = int(_state.get("last_slot", 0))


func _save_state() -> void:
	var f := FileAccess.open(STATE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_state, "\t"))


func _touch_last(slot: int) -> void:
	last_slot = slot
	_state["last_slot"] = slot
	_save_state()

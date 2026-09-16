extends Node
## ============================================================
## ConfigLoader — 自动加载单例（在脚本里用 `Config` 访问）
## 职责：启动时读取 Data/config.json，向全游戏提供数值查询。
##
## 铁律（见 00_GAME_DESIGN.md）：
##   所有数值配置写入 Data/*.json，任何脚本不得硬编码数值。
##   其他脚本一律通过 Config.get_value("路径.键") 取值。
##
## 取值分三层，优先级从高到低：
##   1. `_overrides` —— 代码在本次运行里显式改的（只存内存，退出即忘）。
##      用途：菜单进游戏时临时压掉 `debug.auto_enter_run` 这类开关。
##   2. `_user`      —— 设置菜单里用户改的，落在 `user://settings.json`。
##   3. `_data`      —— Data/config.json 的出厂值。
##
## 为什么要分「用户层」而不是直接改 config.json：
##   导出成 pcx/exe 之后 `res://` 是**只读**的，写不进去；
##   而且开发期改到 src 里的配置会跟版本管理打架。所以出厂值只读，
##   用户改动另存 user://，随时能「恢复默认」。
## ============================================================

const CONFIG_PATH := "res://Data/config.json"
const USER_SETTINGS_PATH := "user://settings.json"

var _data: Dictionary = {}
var _user: Dictionary = {}
var _overrides: Dictionary = {}


func _ready() -> void:
	if not load_config():
		push_error("[Config] 配置加载失败，游戏数值将全部使用默认值！")
	load_user_settings()


## 读取（或重新读取）出厂配置文件
func load_config() -> bool:
	if not FileAccess.file_exists(CONFIG_PATH):
		push_error("[Config] 找不到配置文件：%s" % CONFIG_PATH)
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if not (parsed is Dictionary):
		push_error("[Config] JSON 解析失败，请检查格式：%s" % CONFIG_PATH)
		return false
	_data = parsed
	print("[Config] 配置已加载：地图 %sx%s | 撤离点 %s 个 | 局内 %s 秒" % [
		get_value("map.width"), get_value("map.height"),
		get_value("extraction.count"), get_value("session.time_limit_seconds"),
	])
	return true


## 用点路径取任意配置值，例：
##   Config.get_value("session.time_limit_seconds")        -> 3600
##   Config.get_value("meta_progression.survival.max_hp.base") -> 100
## 缺失时返回 default 并打警告，方便发现 config 漏项。
func get_value(path: String, default = null):
	var hit := _probe(_overrides, path)
	if hit[0]:
		return hit[1]
	hit = _probe(_user, path)
	if hit[0]:
		return hit[1]
	hit = _probe(_data, path)
	if hit[0]:
		return hit[1]
	push_warning("[Config] 缺少配置项 %s，使用默认值：%s" % [path, str(default)])
	return default


## 只取出厂值（忽略用户设置与运行时覆盖）。设置面板里「恢复默认」要拿它。
func get_base_value(path: String, default = null):
	var hit := _probe(_data, path)
	if hit[0]:
		return hit[1]
	return default


## 当前生效值是否来自用户设置（设置面板据此标「已改」）
func has_user_value(path: String) -> bool:
	return _probe(_user, path)[0]


# ------------------------------------------------------------
# 用户层（持久化到 user://settings.json）
# ------------------------------------------------------------

func load_user_settings() -> bool:
	if not FileAccess.file_exists(USER_SETTINGS_PATH):
		return false  # 首次运行，没有用户设置
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(USER_SETTINGS_PATH))
	if not (parsed is Dictionary):
		push_warning("[Config] 用户设置损坏，已忽略：%s" % USER_SETTINGS_PATH)
		return false
	_user = _coerce_ints(parsed)
	print("[Config] 用户设置已加载：%d 项（%s）" % [_leaf_count(_user), USER_SETTINGS_PATH])
	return true


func save_user_settings() -> bool:
	var f := FileAccess.open(USER_SETTINGS_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[Config] 用户设置写入失败：%s" % USER_SETTINGS_PATH)
		return false
	f.store_string(JSON.stringify(_user, "\t"))
	return true


## 写一项用户设置。save_now=false 时只改内存（批量改动最后统一存）。
func set_user_value(path: String, value, save_now: bool = true) -> void:
	_set_path(_user, path, value)
	if save_now:
		save_user_settings()


## 抹掉某项用户设置（回落出厂值）
func clear_user_setting(path: String, save_now: bool = true) -> void:
	_erase_path(_user, path)
	if save_now:
		save_user_settings()


## 清空全部用户设置并落盘（设置面板的「恢复默认」）
func reset_user_settings() -> void:
	_user = {}
	save_user_settings()
	print("[Config] 用户设置已恢复默认")


func user_settings() -> Dictionary:
	return _user


# ------------------------------------------------------------
# 运行时覆盖层（只存内存）
# ------------------------------------------------------------

## 例：从开始菜单进游戏时 `Config.set_override("debug.auto_enter_run", false)`，
## 这样不会顺手改掉 config.json，也不影响命令行回归（它们走另一条路径）。
func set_override(path: String, value) -> void:
	_set_path(_overrides, path, value)


func clear_override(path: String) -> void:
	_erase_path(_overrides, path)


func clear_overrides() -> void:
	_overrides = {}


# ------------------------------------------------------------
# 内部：点路径读写
# ------------------------------------------------------------

## 返回 [是否命中, 值]。用「是否命中」而不是拿 null 当哨兵 ——
## JSON 里 null 是合法值，拿它当"没找到"会把 null 配置项吞掉。
func _probe(root: Dictionary, path: String) -> Array:
	var node: Variant = root
	for key in path.split("."):
		if node is Dictionary and (node as Dictionary).has(key):
			node = (node as Dictionary)[key]
		else:
			return [false, null]
	return [true, node]


func _set_path(root: Dictionary, path: String, value: Variant) -> void:
	var parts := path.split(".")
	var node := root
	for i in range(parts.size() - 1):
		var k := parts[i]
		if not (node.has(k) and node[k] is Dictionary):
			node[k] = {}
		node = node[k]
	node[parts[parts.size() - 1]] = value


func _erase_path(root: Dictionary, path: String) -> void:
	var parts := path.split(".")
	var node := root
	for i in range(parts.size() - 1):
		var k := parts[i]
		if not (node.has(k) and node[k] is Dictionary):
			return
		node = node[k]
	node.erase(parts[parts.size() - 1])


## JSON 没有 int/float 之分，读回来全是 float。
## 而项目里到处是 `var n: int = Config.get_value(...)` 这种强类型赋值 ——
## float 赋给 int 变量在 GDScript 里是**运行时错误**。所以整数值一律还原成 int。
## （反过来的 int→float 是允许的隐式提升，所以这样转是安全的单向操作。）
func _coerce_ints(v: Variant) -> Variant:
	if v is float:
		if absf(v) < 1e15 and is_equal_approx(v, roundf(v)):
			return int(v)
		return v
	if v is Dictionary:
		var out := {}
		for k in (v as Dictionary):
			out[k] = _coerce_ints((v as Dictionary)[k])
		return out
	if v is Array:
		var arr := []
		for item in (v as Array):
			arr.append(_coerce_ints(item))
		return arr
	return v


func _leaf_count(d: Dictionary) -> int:
	var n := 0
	for k in d:
		if d[k] is Dictionary:
			n += _leaf_count(d[k])
		else:
			n += 1
	return n

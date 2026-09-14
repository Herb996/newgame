extends Node
## ============================================================
## ConfigLoader — 自动加载单例（在脚本里用 `Config` 访问）
## 职责：启动时读取 Data/config.json，向全游戏提供数值查询。
##
## 铁律（见 00_MASTER_PROMPT.md）：
##   所有数值配置写入 Data/*.json，任何脚本不得硬编码数值。
##   其他脚本一律通过 Config.get_value("路径.键") 取值。
## ============================================================

const CONFIG_PATH := "res://Data/config.json"

var _data: Dictionary = {}


func _ready() -> void:
	if not load_config():
		push_error("[Config] 配置加载失败，游戏数值将全部使用默认值！")


## 读取（或重新读取）配置文件
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
	var node = _data
	for key in path.split("."):
		if node is Dictionary and node.has(key):
			node = node[key]
		else:
			push_warning("[Config] 缺少配置项 %s，使用默认值：%s" % [path, str(default)])
			return default
	return node

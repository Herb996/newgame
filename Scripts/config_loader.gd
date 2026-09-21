extends Node
## ============================================================
## ConfigLoader — 自动加载单例（在脚本里用 `Config` 访问）
## 职责：启动时读取 Data/config/ 下的域文件，向全游戏提供数值查询。
##
## 铁律（见 DESIGN.md）：
##   所有数值配置写入 Data/config/*.json，任何脚本不得硬编码数值。
##   其他脚本一律通过 Config.get_value("路径.键") 取值。
##
## 取值分三层，优先级从高到低：
##   1. `_overrides` —— 代码在本次运行里显式改的（只存内存，退出即忘）。
##      用途：菜单进游戏时临时压掉 `debug.auto_enter_run` 这类开关。
##   2. `_user`      —— 设置菜单里用户改的，落在 `user://settings.json`。
##   3. `_data`      —— Data/config/ 各域文件合并后的出厂值。
##
## 为什么要分「用户层」而不是直接改出厂配置：
##   导出成 pcx/exe 之后 `res://` 是**只读**的，写不进去；
##   而且开发期改到 src 里的配置会跟版本管理打架。所以出厂值只读，
##   用户改动另存 user://，随时能「恢复默认」。
## ============================================================

## 出厂配置目录：一个功能域一个 .json 文件，按文件名排序逐个加载、
## 顶层段深合并成一棵树（各域文件顶层段互不重叠，合并顺序仅作确定性保障）。
## 加新域 = 往目录里丢一个文件，无需改这里。
const CONFIG_DIR := "res://Data/config"
const USER_SETTINGS_PATH := "user://settings.json"

var _data: Dictionary = {}
var _user: Dictionary = {}
var _overrides: Dictionary = {}


func _ready() -> void:
	if not load_config():
		push_error("[Config] 配置加载失败，游戏数值将全部使用默认值！")
	load_user_settings()


## 读取（或重新读取）出厂配置：Data/config/ 下全部域文件
func load_config() -> bool:
	var dir := DirAccess.open(CONFIG_DIR)
	if dir == null:
		push_error("[Config] 找不到配置目录：%s" % CONFIG_DIR)
		return false
	var names: Array = []
	for n in dir.get_files_at(CONFIG_DIR):
		if n.ends_with(".json"):
			names.append(n)
	if names.is_empty():
		push_error("[Config] 配置目录为空：%s" % CONFIG_DIR)
		return false
	names.sort()
	_data = {}
	for n in names:
		var path: String = CONFIG_DIR + "/" + str(n)
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (parsed is Dictionary):
			push_error("[Config] JSON 解析失败，请检查格式：%s" % path)
			return false
		_deep_merge(_data, parsed)
	print("[Config] 配置已加载（%d 个域文件）：地图 %sx%s | 撤离点 %s 个 | 局内 %s 秒" % [
		names.size(),
		get_value("map.width"), get_value("map.height"),
		get_value("extraction.count"), get_value("session.time_limit_seconds"),
	])
	return true


## 用点路径取任意配置值，例：
##   Config.get_value("session.time_limit_seconds")        -> 3600
##   Config.get_value("meta_progression.survival.max_hp.base") -> 100
## 缺失时返回 default 并打警告，方便发现 config 漏项。
##
## 三层合并规则（优先级 高→低：_overrides > _user > _data）：
##   - 取值路径落到**标量/数组**：取最高优先层的那份（数组整体替换，不逐元素合）。
##   - 取值路径落到**字典**：三层做**深合并**（高层覆盖低层同名键，低层补齐缺失键）。
##     这是 2026-09-17 修的一个严重 bug 的根因 —— 之前某个高层只要“有这条路径”就整棵
##     返回，于是 settings.json 里部分覆盖的 combat.weapons{sword/bow 只写了 damage}
##     会把出厂值里 bow 的 sprite_set/kind/projectile 全部顶掉，
##     导致“选弓手进图却是枪兵近战”。深合并后用户只调自己改的值，其余沿用出厂值。
func get_value(path: String, default = null):
	var ov := _probe(_overrides, path)
	var us := _probe(_user, path)
	var ba := _probe(_data, path)
	var present: Array = []
	if ba[0]:
		present.append(ba[1])
	if us[0]:
		present.append(us[1])
	if ov[0]:
		present.append(ov[1])
	if present.is_empty():
		push_warning("[Config] 缺少配置项 %s，使用默认值：%s" % [path, str(default)])
		return default
	if present.size() == 1:
		return present[0]
	# 多层都有值：全是字典才深合并；否则标量/数组取最高优先层（present 末尾 = override）
	var all_dict := true
	for c in present:
		if not (c is Dictionary):
			all_dict = false
			break
	if all_dict:
		var merged := {}
		for c in present:   # 顺序已是 base → user → override，深合并即 override 胜出
			_deep_merge(merged, c)
		return merged
	return present[present.size() - 1]


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
## 这样不会顺手改掉出厂配置，也不影响命令行回归（它们走另一条路径）。
func set_override(path: String, value) -> void:
	_set_path(_overrides, path, value)


func clear_override(path: String) -> void:
	_erase_path(_overrides, path)


func clear_overrides() -> void:
	_overrides = {}


## 某路径是否被覆盖层改过（局内调试面板据此标「已改」）。
## 注意覆盖层是**按路径造中间字典**的（见 _set_path），所以这里走的是"探到这棵子树的
## 这个位置"，不是"整棵 _overrides 里有没有这个字符串键"。
func has_override(path: String) -> bool:
	return _probe(_overrides, path)[0]


## 覆盖层里的全部叶子路径（"player.speed" 这种点路径）。
## 面板顶部的「全部还原」与「打印本次覆盖项」都读它 —— 覆盖层只存内存，
## 想留下哪个值只能自己抄进 Data/config/，所以先把名单打出来。
func override_paths() -> Array:
	var out: Array = []
	_collect_leaf_paths(_overrides, "", out)
	out.sort()
	return out


func _collect_leaf_paths(d: Dictionary, prefix: String, out: Array) -> void:
	for k in d:
		var p := ("%s.%s" % [prefix, str(k)]) if prefix != "" else str(k)
		var v = d[k]
		if v is Dictionary:
			# 空子树一概跳过：clear_override 只抹叶子，中间那层 {} 会留在覆盖层里，
			# 把它当叶子列出来就等于报了一条「改了但值还是出厂那一整棵」的假改动。
			_collect_leaf_paths(v, p, out)
		else:
			out.append(p)


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


## 深合并：把 from 的键值并入 into（from 同名键胜出；双方都是字典则递归）。
## 仅用于在 get_value 里把 _overrides / _user / _data 三层字典按路径合成“生效值”，
## 避免高层部分子树把低层整棵顶掉（见 get_value 头注释的 2026-09-17 修复说明）。
func _deep_merge(into: Dictionary, from: Dictionary) -> void:
	for k in from:
		var v = from[k]
		if v is Dictionary and into.has(k) and (into[k] is Dictionary):
			# ⚠ 递归前先把 into[k] 换成副本。`into` 顶层是新建的 merged，但它从低层抄来的
			# 每个子字典都是 _data / _user 里的**那一个**（字典是引用语义），在它身上写
			# 就等于改了出厂值 —— clear_override 之后出厂值回不来，「全部还原」与设置面板
			# 的「恢复默认」都会坏在这一点上（2026-09-20 查调试面板时定位）。
			# 只复制被覆盖到的那一支，不复制整棵：hot path 上（_weapons() 每次出手都读）
			# 拷贝成本与被改动的子树大小成正比，而不是与配置大小成正比。
			var sub: Dictionary = (into[k] as Dictionary).duplicate(true)
			into[k] = sub
			_deep_merge(sub, v as Dictionary)
		else:
			into[k] = v


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
	var chain: Array = [root]
	for i in range(parts.size() - 1):
		var k := parts[i]
		if not (node.has(k) and node[k] is Dictionary):
			return
		node = node[k]
		chain.append(node)
	node.erase(parts[parts.size() - 1])
	# 反向剪掉被掏空的中间层：不剪的话 clear_override 之后 _overrides 里留一串 {}，
	# has_override("enemy.attack") 这类祖先查询会误报成"改过"。
	for i in range(chain.size() - 1, 0, -1):
		var child: Dictionary = chain[i]
		if not child.is_empty():
			return
		(chain[i - 1] as Dictionary).erase(parts[i - 1])


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


# ------------------------------------------------------------
# 写回出厂域文件（局内数值调试台的「写入文件」用）
#
# ⚠ 为什么不是「解析 → 改字典 → JSON.stringify 写回去」：
#   Godot 的 JSON.stringify 会把字典的键**按字母排序**（实测 4.7.2）。
#   域文件是按功能顺序手写的，重新序列化一次 = ambience.json 652 行里 640 行改动，
#   而这些文件是 git 跟踪的、另一个会话正在改的。所以这里走**原地替换**：
#   在原文里按点路径定位到那一个值 token 的字符区间，只换这一小截，其余字节不动。
#
# ⚠ 导出成 exe 后 res:// 只读，这里会返回 ok=false + 原因，调用方负责提示。
# ⚠ 只写标量（bool / int / float）。数组下标写成路径段（"map.biome_weights.0"）。
# ------------------------------------------------------------

const BACKUP_ROOT := "res://Backups/config"
const BACKUP_KEEP := 20

## 直接改内存里的出厂层。落盘之后要把文件里的新值同步进 _data，
#  否则「文件已是新值、内存还是旧值」，重出击前看不到效果。
func set_base_value(path: String, value) -> void:
	_set_path(_data, path, value)


## 把一批标量值原地写进某个域文件。edits = [{path, value}]。
## 顺序是：定位 → 拼接 → 校验（能解析 + 回读值对得上）→ 备份 → 落笔。
## 校验不过就整批不写，原文件一个字节都不会变。
## 返回 {ok, error, missing, backup, wrote}。
func write_domain_values(domain: String, edits: Array,
		root: String = CONFIG_DIR, backup_root: String = BACKUP_ROOT) -> Dictionary:
	var file_path := "%s/%s.json" % [root, domain]
	var raw := FileAccess.get_file_as_string(file_path)
	if raw == "":
		return {"ok": false, "error": "读不到域文件（不存在或空）：" + file_path}
	var wanted := {}
	for e in edits:
		wanted[str(e["path"])] = true
	var spans := {}
	if _scan_spans(raw, 0, int(raw.length()), "", wanted, spans) < 0:
		return {"ok": false, "error": "JSON 结构读不懂，不敢动笔：" + file_path}
	var missing: Array = []
	for e in edits:
		if not spans.has(str(e["path"])):
			missing.append(str(e["path"]))
	if not missing.is_empty():
		return {"ok": false, "error": "这些路径在文件里找不到（结构变了？先重跑生成器）：%s" % file_path,
			"missing": missing}
	var jobs: Array = []
	for e in edits:
		var sp: Array = spans[str(e["path"])]
		jobs.append([int(sp[0]), int(sp[1]), _json_literal(e["value"])])
	jobs.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	var out := raw
	for j in jobs:
		out = out.substr(0, int(j[0])) + str(j[2]) + out.substr(int(j[1]))
	var parsed = JSON.parse_string(out)
	if not (parsed is Dictionary):
		return {"ok": false, "error": "改完的文本不是合法 JSON，放弃写入：" + file_path}
	for e in edits:
		var got := _probe(parsed, str(e["path"]))
		if not bool(got[0]) or not _same_scalar(got[1], e["value"]):
			return {"ok": false, "error": "回读校验不一致，放弃写入：%s" % str(e["path"])}
	var stamp := _stamp()
	var backup_dir := "%s/%s" % [backup_root, stamp]
	if DirAccess.make_dir_recursive_absolute(backup_dir) != OK:
		return {"ok": false, "error": "建不了备份目录：" + backup_dir}
	if DirAccess.copy_absolute(file_path, "%s/%s.json" % [backup_dir, domain]) != OK:
		return {"ok": false, "error": "备份失败，放弃写入：" + file_path}
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "文件不可写（导出包里的 res:// 是只读的）：%s" % file_path,
			"backup": backup_dir}
	f.store_string(out)
	f.close()
	_prune_backups(backup_root)
	var wrote: Array = []
	for e in edits:
		wrote.append(str(e["path"]))
	return {"ok": true, "error": "", "missing": [], "backup": backup_dir, "wrote": wrote}


## 备份清单（新的在前）：[{stamp, files}]
func backup_list(backup_root: String = BACKUP_ROOT) -> Array:
	var dir := DirAccess.open(backup_root)
	if dir == null:
		return []
	var names: Array = dir.get_directories_at(backup_root)
	names.sort()
	names.reverse()
	var out: Array = []
	for n in names:
		var sub := DirAccess.open("%s/%s" % [backup_root, str(n)])
		var files: Array = []
		if sub != null:
			for f in sub.get_files_at("%s/%s" % [backup_root, str(n)]):
				files.append(str(f))
		out.append({"stamp": str(n), "files": files})
	return out


## 把某次备份整批拷回去（默认最近一次）。只还原文件，不碰内存层 ——
## 调用方自己决定要不要 load_config() / 清覆盖层。
func restore_backup(stamp: String = "", root: String = CONFIG_DIR, backup_root: String = BACKUP_ROOT) -> Dictionary:
	var list := backup_list(backup_root)
	if list.is_empty():
		return {"ok": false, "error": "还没有任何备份", "stamp": "", "files": []}
	var pick: Dictionary = list[0]
	if stamp != "":
		pick = {}
		for b in list:
			if str(b["stamp"]) == stamp:
				pick = b
				break
		if pick.is_empty():
			return {"ok": false, "error": "没有这个备份：" + stamp, "stamp": "", "files": []}
	var done: Array = []
	for f in (pick["files"] as Array):
		var src := "%s/%s/%s" % [backup_root, str(pick["stamp"]), str(f)]
		if DirAccess.copy_absolute(src, "%s/%s" % [root, str(f)]) != OK:
			return {"ok": false, "error": "还原到一半失败，已恢复：%s；卡在 %s" % [str(done), str(f)],
				"stamp": str(pick["stamp"]), "files": done}
		done.append(str(f))
	return {"ok": true, "error": "", "stamp": str(pick["stamp"]), "files": done}


func _stamp() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d_%02d%02d%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second]


func _prune_backups(backup_root: String = BACKUP_ROOT) -> void:
	var dir := DirAccess.open(backup_root)
	if dir == null:
		return
	var names: Array = dir.get_directories_at(backup_root)
	names.sort()
	while names.size() > BACKUP_KEEP:
		DirAccess.remove_absolute("%s/%s" % [backup_root, str(names.pop_front())])


## 值 -> JSON 字面量。float 要保住小数点：文件里写的是 52.0，回填成 52 会让
#  整份配置的数值类型观感一夜回到解放前（而且 git 会把它算成一次改动）。
func _json_literal(v) -> String:
	if v is bool:
		return "true" if v else "false"
	if v is int:
		return str(v)
	if v is float:
		var s := String.num(v)
		if not ("." in s or "e" in s or "n" in s):
			s += ".0"
		return s
	if v is String:
		return JSON.stringify(v)
	return "null"


## JSON 读回来数字一律是 float，跟写进去的 int 比大小得先跨过这道类型坎。
func _same_scalar(a, b) -> bool:
	if a is bool or b is bool:
		return bool(a) == bool(b)
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	return str(a) == str(b)


const _C_Q := 34          # "
const _C_LB := 91         # [
const _C_RB := 93         # ]
const _C_LC := 123        # {
const _C_RC := 125        # }
const _C_CM := 44         # ,
const _C_CL := 58         # :
const _C_BS := 92         # \
const _C_SP := 32
const _C_TAB := 9
const _C_LF := 10
const _C_CR := 13


## 扫一遍 JSON 原文，把 wanted 里那些点路径对应的**值 token** 区间记进 out。
## 返回读完的游标；任何一处结构对不上就返回 -1（调用方据此放弃写入）。
## 取字符一律走 unicode_at 而不是 String[i]：后者每次都要现造一个单字符 String，
## 四万五千个字符扫一遍就是四万五千次分配。
func _scan_spans(t: String, i: int, n: int, path: String, wanted: Dictionary, out: Dictionary) -> int:
	i = _skip_ws(t, i, n)
	if i >= n:
		return -1
	var c := t.unicode_at(i)
	if c == _C_LC:
		i = _skip_ws(t, i + 1, n)
		if i >= n:
			return -1
		if t.unicode_at(i) == _C_RC:
			return i + 1
		while true:
			i = _skip_ws(t, i, n)
			if i >= n or t.unicode_at(i) != _C_Q:
				return -1
			var k := _read_str(t, i, n)
			if int(k[1]) < 0:
				return -1
			i = _skip_ws(t, int(k[1]), n)
			if i >= n or t.unicode_at(i) != _C_CL:
				return -1
			i = _scan_spans(t, i + 1, n, _child(path, str(k[0])), wanted, out)
			if i < 0:
				return -1
			i = _skip_ws(t, i, n)
			if i >= n:
				return -1
			if t.unicode_at(i) == _C_CM:
				i = _skip_ws(t, i + 1, n)
				continue
			if t.unicode_at(i) == _C_RC:
				return i + 1
			return -1
	if c == _C_LB:
		i = _skip_ws(t, i + 1, n)
		if i >= n:
			return -1
		if t.unicode_at(i) == _C_RB:
			return i + 1
		var idx := 0
		while true:
			i = _scan_spans(t, i, n, _child(path, str(idx)), wanted, out)
			if i < 0:
				return -1
			idx += 1
			i = _skip_ws(t, i, n)
			if i >= n:
				return -1
			if t.unicode_at(i) == _C_CM:
				i = _skip_ws(t, i + 1, n)
				continue
			if t.unicode_at(i) == _C_RB:
				return i + 1
			return -1
	var start := i
	if c == _C_Q:
		var s := _read_str(t, i, n)
		if int(s[1]) < 0:
			return -1
		i = int(s[1])
	else:
		while i < n and t.unicode_at(i) != _C_CM and t.unicode_at(i) != _C_RC and t.unicode_at(i) != _C_RB \
				and t.unicode_at(i) != _C_SP and t.unicode_at(i) != _C_LF and t.unicode_at(i) != _C_CR and t.unicode_at(i) != _C_TAB:
			i += 1
	if wanted.has(path):
		out[path] = [start, i]
	return i


## 从游标 i（必须停在引号上）读一个 JSON 字符串，返回 [内容, 结束游标]；坏了返回 ["", -1]。
func _read_str(t: String, i: int, n: int) -> Array:
	var s := ""
	i += 1
	while i < n:
		var c := t.unicode_at(i)
		if c == _C_Q:
			return [s, i + 1]
		if c == _C_BS:
			i += 1
			if i >= n:
				return ["", -1]
			var e := t.unicode_at(i)
			match e:
				110: s += "\n"
				116: s += "\t"
				114: s += "\r"
				98: s += "\b"
				102: s += "\f"
				117:
					# \uXXXX：不解码的话键名会悄悄变成 "u"，两个不同的键就可能撞成同一个路径
					if i + 4 >= n:
						return ["", -1]
					var code := 0
					for k in range(4):
						var h := _hex(t.unicode_at(i + 1 + k))
						if h < 0:
							return ["", -1]
						code = code * 16 + h
					s += char(code)
					i += 4
				_: s += char(e)
			i += 1
			continue
		s += char(c)
		i += 1
	return ["", -1]


func _hex(c: int) -> int:
	if c >= 48 and c <= 57:
		return c - 48
	if c >= 97 and c <= 102:
		return c - 87
	if c >= 65 and c <= 70:
		return c - 55
	return -1


func _skip_ws(t: String, i: int, n: int) -> int:
	while i < n and (t.unicode_at(i) == _C_SP or t.unicode_at(i) == _C_TAB or t.unicode_at(i) == _C_LF or t.unicode_at(i) == _C_CR):
		i += 1
	return i


func _child(path: String, seg: String) -> String:
	return seg if path == "" else "%s.%s" % [path, seg]

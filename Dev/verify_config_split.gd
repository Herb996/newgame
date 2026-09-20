extends SceneTree
## 配置完整性检查（无头）：逐个解析 Data/config/*.json，并检测「同一个顶层段
## 被两个域文件同时定义」的冲突 —— 那会被加载器静默覆盖，必须当错误报出来。
## 用法：godot --headless --path . --script res://Dev/verify_config_split.gd
## 每次手改域文件后跑一遍，输出 RESULT_OK 即健康。

const DIR := "res://Data/config"


func _init() -> void:
	var dir := DirAccess.open(DIR)
	if dir == null:
		print("FAIL: 打不开目录 ", DIR)
		quit(1)
		return
	var names: Array = []
	for n in dir.get_files_at(DIR):
		if n.ends_with(".json"):
			names.append(n)
	if names.is_empty():
		print("FAIL: 配置目录为空")
		quit(1)
		return
	names.sort()

	var owner: Dictionary = {}     # 顶层段 -> 首次定义它的文件
	var dup: Array = []
	var total := 0
	for n in names:
		var path: String = DIR + "/" + str(n)
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed == null or not (parsed is Dictionary):
			print("FAIL: ", n, " 解析失败（常见原因：段尾逗号多/少）")
			quit(1)
			return
		for k in (parsed as Dictionary):
			total += 1
			if owner.has(k):
				dup.append("%s 同时定义于 %s 和 %s" % [k, owner[k], n])
			else:
				owner[k] = str(n)
		print("  ok ", n)

	if not dup.is_empty():
		for d in dup:
			print("FAIL: 顶层段重复定义 → ", d)
		quit(1)
		return
	print("RESULT_OK  文件数=", names.size(), "  顶层段=", total, "  无重复定义")

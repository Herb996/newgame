extends Node
## ============================================================
## probe_config_write — 「写入文件」这条落盘路子的正确性（headless）
##
## 跑法：python tools/run_probe.py _probe_config_write.log res://Dev/probe_config_write.tscn
##
## 面板改完数值点「写入文件」，要的是三件事同时成立：
##   1. 写进去的就是屏幕上那个值（int 行不会变成 3.0、bool 不会变成 1）
##   2. **除了那一个 token，域文件其余字节一个都不动**
##      —— 这些文件是手写的、按功能排序的、git 跟踪的，另一个会话正在改。
##      JSON.stringify 会把键按字母排序，所以绝不能走「解析后重新序列化」。
##   3. 写坏了能救回来：写之前自动整份备份，「还原备份」能把文件拷回原样
##
## 探针分两段：
##   A 段（全量、只读）：1320 行逐行在原文里定位值 token，并要求
##      「token 文本 reparse 出来的值 == 目录里记的出厂值」。
##      这一条同时钉住了两件事：定位器认得全部结构（含 210 条跨数组的下标路径），
##      以及目录没跟域文件脱节。
##   B 段（写，全在 user:// 副本上）：五类值各写一次，用**深比较**要求
##      「解析后的树只有被改的那几条路径不同」，再要求备份==原文、还原==原文。
##      最后单独跑一次真文件往返（挑一条未接线的行，开局就把原字节存进 user://，
##      收尾无论成败都拷回去），因为「备份能救回来」这件事只有在真 res:// 路径上
##      走一遍才算证过。
## ============================================================

const OUT := "user://_probe_config_write.txt"
const CFG_DIR := "res://Data/config"
const ROOT := "user://_cfgw"
const BK := "user://_cfgw_backup"
const BAD := "user://_cfgw_bad"
const CATALOG := "res://Data/debug_stat_catalog.json"
## 真文件往返只碰这一条：tier 5 = 全工程没有读点，改它不影响任何在场行为
const REAL_PATH := "storage.max_slots"

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _rows: Array = []
var _real_backup := "user://_cfgw_real_backup.json"
var _real_domain := ""
var _real_touched := false


func _say(s: String) -> void:
	_lines.append(s)
	print("[Probe] " + s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	if not ok:
		_fails.append(msg)
	var line := "  %s %s" % ["OK  " if ok else "FAIL", msg]
	_lines.append(line)
	print("[Probe] " + line)


func _near(a: float, b: float, eps: float = 1e-6) -> bool:
	return absf(a - b) <= eps


func _row(path: String) -> Dictionary:
	for r in _rows:
		if str(r.get("path", "")) == path:
			return r
	return {}


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _domains() -> Array:
	var dir := DirAccess.open(CFG_DIR)
	var out: Array = []
	for n in dir.get_files_at(CFG_DIR):
		if str(n).ends_with(".json"):
			out.append(str(n).trim_suffix(".json"))
	out.sort()
	return out


func _wipe(p: String) -> void:
	if DirAccess.dir_exists_absolute(p):
		DirAccess.remove_absolute(p)


func _copy_dir(dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	for d in _domains():
		DirAccess.copy_absolute("%s/%s.json" % [CFG_DIR, d], "%s/%s.json" % [dst, d])


## 解析后的两棵树做深比较，只报告不同的叶子路径
func _diff_paths(a, b, prefix: String, out: Array) -> void:
	if a is Dictionary and b is Dictionary:
		var keys := {}
		for k in a:
			keys[str(k)] = true
		for k in b:
			keys[str(k)] = true
		var ks: Array = keys.keys()
		ks.sort()
		for k in ks:
			var p := ("%s.%s" % [prefix, str(k)]) if prefix != "" else str(k)
			if not (a as Dictionary).has(str(k)):
				out.append(p + " (仅新)")
			elif not (b as Dictionary).has(str(k)):
				out.append(p + " (仅旧)")
			else:
				_diff_paths((a as Dictionary)[str(k)], (b as Dictionary)[str(k)], p, out)
		return
	if a is Array and b is Array:
		var n: int = maxi((a as Array).size(), (b as Array).size())
		for i in range(n):
			var p := "%s.%d" % [prefix, i]
			if i >= (a as Array).size():
				out.append(p + " (仅新)")
			elif i >= (b as Array).size():
				out.append(p + " (仅旧)")
			else:
				_diff_paths((a as Array)[i], (b as Array)[i], p, out)
		return
	var same := false
	if (a is bool) and (b is bool):
		same = bool(a) == bool(b)
	elif (a is float or a is int) and (b is float or b is int):
		same = _near(float(a), float(b), 1e-9)
	else:
		same = str(a) == str(b)
	if not same:
		out.append("%s: %s -> %s" % [prefix, str(a), str(b)])


func _ready() -> void:
	_say("probe_config_write — 原地写回域文件 + 备份可还原")
	var parsed = JSON.parse_string(_read(CATALOG))
	if not (parsed is Dictionary) or not (parsed as Dictionary).has("rows"):
		_say("!! 读不到 %s，先跑 tools/gen_stat_catalog.py" % CATALOG)
		_finish()
		return
	_rows = (parsed as Dictionary)["rows"]
	_say("目录 %d 行" % _rows.size())

	_a_locate_all()
	_b_write_roundtrip()
	_c_reject()
	_d_real_file_loop()
	_finish()


# ------------------------------------------------------------
# A. 全量定位（只读，不碰任何文件）
# ------------------------------------------------------------
func _a_locate_all() -> void:
	_say("— A 全量定位：1320 行都能在原文里找到值 token，且 token == 目录里的出厂值")
	var missing: Array = []
	var mismatch: Array = []
	var bad_file: Array = []
	var no_domain: Array = []
	var checked := 0
	var have := _domains()
	for r in _rows:
		if not have.has(str(r.get("domain", ""))):
			no_domain.append("%s→%s" % [str(r["path"]), str(r.get("domain", ""))])
	_check(no_domain.is_empty(),
		"目录里每一行的域文件都在（缺文件的路径：%s）" % str(no_domain.slice(0, 6)))
	for d in have:
		var raw := _read("%s/%s.json" % [CFG_DIR, d])
		var wanted := {}
		var paths: Array = []
		for r in _rows:
			if str(r.get("domain", "")) == d:
				wanted[str(r["path"])] = true
				paths.append(str(r["path"]))
		if paths.is_empty():
			continue
		var spans := {}
		var rc: int = Config.call("_scan_spans", raw, 0, raw.length(), "", wanted, spans)
		if rc < 0:
			bad_file.append(d)
			continue
		for p in paths:
			if not spans.has(p):
				missing.append("%s:%s" % [d, p])
				continue
			var row := _row(p)
			var sp: Array = spans[p]
			var tok := raw.substr(int(sp[0]), int(sp[1]) - int(sp[0]))
			var back = JSON.parse_string("[" + tok + "]")
			checked += 1
			if back == null or not (back is Array):
				mismatch.append("%s 的 token「%s」不是合法 JSON 值" % [p, tok])
				continue
			var got = (back as Array)[0]
			var fac = row.get("factory", null)
			var ok := false
			if got is bool or fac is bool:
				ok = bool(got) == bool(fac)
			elif (got is float or got is int) and (fac is float or fac is int):
				ok = _near(float(got), float(fac), 1e-9)
			else:
				ok = str(got) == str(fac)
			if not ok:
				mismatch.append("%s 文件里是 %s，目录记的出厂值是 %s" % [p, str(got), str(fac)])
	_check(bad_file.is_empty(), "16 个域文件全部能被扫描器读懂（读不懂的：%s）" % str(bad_file))
	_check(missing.is_empty(), "定位到 %d 个值 token，无一条找不到（缺：%s）" % [checked, str(missing.slice(0, 6))])
	_check(mismatch.is_empty(), "每个 token reparse 出来都等于目录里的出厂值（前几条不符：%s）" % str(mismatch.slice(0, 6)))


# ------------------------------------------------------------
# B. 副本上真写：五类值 + 备份 + 还原
# ------------------------------------------------------------
func _b_write_roundtrip() -> void:
	_say("— B 副本写入：int/float/bool/下标五类各写一次，要求只有目标路径变了")
	_wipe(ROOT)
	_wipe(BK)
	_copy_dir(ROOT)
	var picks := [
		["enemy.attack.range_px", 77.0, "77.0"],
		["combat.attack.active_seconds", 0.13, "0.13"],
		["combat.auto_attack.enabled", false, "false"],
		["player.select_radius_px", 90.0, "90.0"],
		["map.width", 140, "140"],
		["map.biome_weights.0", 0.5, "0.5"],
		["map.biome_weights.2", 0.25, "0.25"],
	]
	var by_domain := {}
	for p in picks:
		var row := _row(str(p[0]))
		if row.is_empty():
			_check(false, "目录里没有 %s（配置结构变了？）" % str(p[0]))
			continue
		var d := str(row["domain"])
		if not by_domain.has(d):
			by_domain[d] = []
		(by_domain[d] as Array).append({"path": str(p[0]), "value": p[1]})
	var written: Array = []
	for d in by_domain.keys():
		var res: Dictionary = Config.write_domain_values(str(d), by_domain[d], ROOT, BK)
		_check(bool(res.get("ok", false)), "写 %s.json：%s" % [str(d), str(res.get("error", ""))])
		if bool(res.get("ok", false)):
			for e in (by_domain[d] as Array):
				written.append(str(e["path"]))
	# 字面量必须原样落在文件里：int 行写成 140.0、bool 行写成 1，都是把配置洗坏
	for p in picks:
		var row2 := _row(str(p[0]))
		if row2.is_empty():
			continue
		var d2 := str(row2["domain"])
		var raw2 := _read("%s/%s.json" % [ROOT, d2])
		var sp2 := {}
		Config.call("_scan_spans", raw2, 0, raw2.length(), "",
			{str(p[0]): true}, sp2)
		var tok := "(找不到)"
		if sp2.has(str(p[0])):
			var s2: Array = sp2[str(p[0])]
			tok = raw2.substr(int(s2[0]), int(s2[1]) - int(s2[0]))
		_check(tok == str(p[2]), "%s 在文件里是 %s（期望 %s）" % [str(p[0]), tok, str(p[2])])
	var want_paths := written.duplicate()
	want_paths.sort()
	var diffs: Array = []
	for d in _domains():
		var old_tree = JSON.parse_string(_read("%s/%s.json" % [CFG_DIR, d]))
		var new_tree = JSON.parse_string(_read("%s/%s.json" % [ROOT, d]))
		if new_tree == null:
			_check(false, "%s.json 写完不是合法 JSON" % d)
			continue
		var local: Array = []
		_diff_paths(old_tree, new_tree, "", local)
		for x in local:
			diffs.append(str(x))
	var clean: Array = []
	for x in diffs:
		clean.append(str(x).split(": ")[0])
	clean.sort()
	_check(clean == want_paths,
		"解析后的树只有这 %d 条路径不同（实际不同：%s）" % [want_paths.size(), str(diffs)])
	var line_churn := 0
	for d in _domains():
		var a := _read("%s/%s.json" % [CFG_DIR, d])
		var b := _read("%s/%s.json" % [ROOT, d])
		if a.count("\n") != b.count("\n"):
			line_churn += 1
	_check(line_churn == 0, "没有一个域文件被改行数（原地替换，不重排不重折行）")

	# 备份内容 == 写入前的原文件
	var bk: Array = Config.call("backup_list", BK)
	_check(not bk.is_empty(), "备份目录里有了 %d 份快照" % bk.size())
	var stamps := {}
	for g in bk:
		for f in (g["files"] as Array):
			stamps[str(f).trim_suffix(".json")] = true
	_check(stamps.has("enemy") and stamps.has("map"),
		"被改过的域文件都各存了一份备份（有：%s）" % str(stamps.keys()))
	for d in by_domain.keys():
		var newest: Dictionary = (bk as Array)[0]
		var cand := "%s/%s/%s.json" % [BK, str(newest["stamp"]), str(d)]
		if not FileAccess.file_exists(cand):
			for g in bk:
				if (g["files"] as Array).has("%s.json" % str(d)):
					cand = "%s/%s/%s.json" % [BK, str(g["stamp"]), str(d)]
					break
		_check(_read(cand) == _read("%s/%s.json" % [CFG_DIR, d]),
			"%s.json 的备份与出厂原文逐字节相同" % d)

	# 还原：把 user:// 副本恢复成 res:// 原样
	var rr: Dictionary = Config.call("restore_backup", "", ROOT, BK)
	_check(bool(rr.get("ok", false)), "还原备份：%s" % str(rr.get("error", "")))
	var residue: Array = []
	for d in _domains():
		if _read("%s/%s.json" % [CFG_DIR, d]) != _read("%s/%s.json" % [ROOT, d]):
			residue.append(d)
	_check(residue.is_empty(), "还原后 16 个副本与原文逐字节相同（仍不同：%s）" % str(residue))


# ------------------------------------------------------------
# C. 该拒的一律拒，且不动笔
# ------------------------------------------------------------
func _c_reject() -> void:
	_say("— C 拒写路径：坏路径 / 坏 JSON 都必须整批不落笔")
	_copy_dir(ROOT)
	var before := _read("%s/map.json" % ROOT)
	var res: Dictionary = Config.write_domain_values("map",
		[{"path": "map.biome_weights.0", "value": 0.9}, {"path": "map.nope.nothere", "value": 1}],
		ROOT, BK)
	_check(not bool(res.get("ok", false)), "有一条路径找不到就整批不写：%s" % str(res.get("error", "")))
	_check((res.get("missing", []) as Array) == ["map.nope.nothere"],
		"missing 里精确列出那一条：%s" % str(res.get("missing", [])))
	_check(_read("%s/map.json" % ROOT) == before, "拒写之后 map.json 字节未变")

	_wipe(BAD)
	DirAccess.make_dir_recursive_absolute(BAD)
	var raw := _read("%s/ui.json" % CFG_DIR)
	# 在中间插一个多余的逗号，制造结构错误
	var broken := raw.replace('"menu_bar": {', '"menu_bar": {,,')
	var f := FileAccess.open("%s/ui.json" % BAD, FileAccess.WRITE)
	f.store_string(broken)
	f.close()
	var res2: Dictionary = Config.write_domain_values("ui",
		[{"path": "menu_bar.height_ratio", "value": 0.3}], BAD, BK)
	_check(not bool(res2.get("ok", false)), "结构读不懂的域文件不敢动笔：%s" % str(res2.get("error", "")))
	_check(_read("%s/ui.json" % BAD) == broken, "读不懂时那个文件也没被改")

	var res3: Dictionary = Config.write_domain_values("nosuchdomain",
		[{"path": "x.y", "value": 1}], ROOT, BK)
	_check(not bool(res3.get("ok", false)), "域文件不存在就报错：%s" % str(res3.get("error", "")))


# ------------------------------------------------------------
# D. 真文件往返：写一次真的，再用面板那条还原路救回来
# ------------------------------------------------------------
func _d_real_file_loop() -> void:
	_say("— D 真文件往返（%s，未接线档，全工程无读点）" % REAL_PATH)
	var row := _row(REAL_PATH)
	if row.is_empty():
		_check(false, "目录里没有 %s，这段跳过" % REAL_PATH)
		return
	_real_domain = str(row["domain"])
	var target := "%s/%s.json" % [CFG_DIR, _real_domain]
	var original := _read(target)
	var f := FileAccess.open(_real_backup, FileAccess.WRITE)
	f.store_string(original)
	f.close()
	var fac = row.get("factory", 0)
	var next_val: Variant = int(fac) + 7 if not (fac is bool) else not bool(fac)
	var res: Dictionary = Config.write_domain_values(_real_domain,
		[{"path": REAL_PATH, "value": next_val}])
	_check(bool(res.get("ok", false)), "写进真文件 %s.json：%s" % [_real_domain, str(res.get("error", ""))])
	if not bool(res.get("ok", false)):
		return
	_real_touched = true
	var after := _read(target)
	_check(after != original, "真文件确实变了")
	_check(after.count("\n") == original.count("\n"), "真文件行数没变")
	Config.load_config()
	var got = Config.get_value(REAL_PATH, null)
	var ok_val := (bool(got) == bool(next_val)) if (got is bool or next_val is bool) \
			else _near(float(got), float(next_val), 1e-9)
	_check(ok_val, "重读配置后 %s = %s（写进去的值真的进了文件）" % [REAL_PATH, str(got)])
	var rr: Dictionary = Config.restore_backup()
	_check(bool(rr.get("ok", false)), "走面板那颗按钮同一条路还原：%s" % str(rr.get("error", "")))
	_check(_read(target) == original, "真文件已回到原样（逐字节）")
	_real_touched = false
	Config.load_config()


func _finish() -> void:
	# 无论前面走到哪一步炸了，真文件都得回到原样
	if _real_touched:
		var src := _read(_real_backup)
		if src != "":
			var f := FileAccess.open("%s/%s.json" % [CFG_DIR, _real_domain], FileAccess.WRITE)
			f.store_string(src)
			f.close()
			_lines.append("  !! 收尾强制还原了 %s.json" % _real_domain)
	_check(not _real_touched, "收尾时真文件不处于「改了一半」状态")
	var total := "合计 %d 项检查，失败 %d 项" % [_n, _fails.size()]
	_lines.append("")
	_lines.append(total)
	for m in _fails:
		_lines.append("  FAIL: " + str(m))
	print("[Probe] " + total)
	var w := FileAccess.open(OUT, FileAccess.WRITE)
	if w != null:
		w.store_string("\n".join(PackedStringArray(_lines)))
		w.close()
	get_tree().quit(0 if _fails.is_empty() else 1)

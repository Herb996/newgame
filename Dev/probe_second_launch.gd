extends Node
## ============================================================
## probe_second_launch — 复现「第二次出击时，主基地场景被带进关卡」
##
## 走的是玩家真实那条链（不是直接调 main 的内部函数）：
##   基地 → 点大门 → 选人面板勾一人 → 「出击」→ 撤离结算 → 按 R 回基地 → 再出击 ×2
##
## 两张网互补，都盯 GameRoot 的直接子节点：
##   1) **实例 id**：每个阶段拍一张 {instance_id → 名字} 快照，问"上一阶段那批
##      实例还有几个挂在树上"。`_clear_game_root()` 用的是 queue_free，隔 30 帧
##      还在场 = 真没清掉。名字靠不住（局内节点多半是引擎自动名 @Area2D@2527，
##      BaseMapRoot 这种名字又是 base_system 手写的，改一处就对不上），id 骗不了人。
##   2) **名字/脚本**：关卡里不该有名字含 Base 的节点，也不该有挂 building.gd 的节点。
##      万一基地内容是被 duplicate() 复制进关卡的，那是一份全新实例，第 1 张网
##      看不见，只有第 2 张能看见。
##
## 顺带盯两处同样会"隔局残留"的症状：相机台数、场上角色数
## （两台相机 / 两张地图叠着，看起来和"基地被拖进来"是同一类）。
##
## 环境不健康（别的脚本报错把 _enter_base/_enter_run 拦腰打断）时**直接作废退出**
## （码 2），不交假账 —— 这一天里它已经骗过我们一次了。
## 加 --window 会另存两张实拍图（基地 / 出击#2），断言之外再用眼睛看一遍。
##
## ⚠ 会写 user://save.json（出击 + 撤离回仓），开跑备份、收尾原样还原。
## ============================================================

const OUT := "user://_probe_second_launch.txt"
const SAVE_PATH := "user://save.json"
## main.gd 里是 `enum Mode { BASE, RUN }`；脚本内部常量在探针侧取不到，照抄一遍。
## 取权威值靠 _main.get("mode")，这里的常数只用来比对。
const M_BASE := 0
const M_RUN := 1

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _save_backup := ""
var _save_existed := false
var _main: Node = null
## 已经收尾过一次（正常结束或环境不健康提前作废）。
## quit() 要到本帧末尾才生效，后面的代码还会接着跑 —— 没有这道闩，
## 一份"作废"报告会紧跟着被第二份"共 0 项断言"覆盖掉。
var _dead := false


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	if _dead:
		return
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()
	# 本探针只看场景归属，不要活物来搅局：敌人会砍人追人、动物会满场跑，
	# 两者都让两次快照之间的节点数自然波动，没法拿来判"残留"。
	Config.set_override("enemy.count", 0)
	Config.set_override("animals.count", 0)
	# config 里 debug.auto_enter_run 是 true：Main._ready() 建完基地会立刻再进一局。
	# 不压掉的话本探针第一站"基地"拍到的其实是关卡，后面每一步都错一格。
	Config.set_override("debug.auto_enter_run", false)

	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child(_main)
	await _frames(30)
	Meta.roster = []
	Meta.seeded_ids = []
	Meta.ensure_roster()

	var root: Node = _main.get_node("GameRoot")

	_say("--- 基地（出击前）---")
	_say("  " + _state_line(root, _tally(root)))
	await _shot("base")
	# 体检：基地必须真的被建起来。_enter_base() 走到一半报错（例如别的脚本解析失败
	# → 某个系统节点没脚本 → Invalid call 把函数打断）时，GameRoot 会是半截场景，
	# 那时候下面所有"残留"断言量的都是这个半截场景，跟用户的 bug 毫无关系。
	# 与其交一份假账，不如交一份"环境不健康"。
	if not _healthy(root, "BaseMapRoot"):
		_say("")
		_say("!! 环境不健康：GameRoot 里没有 BaseMapRoot —— 基地没建完。")
		_say("!! 十有八九是别处的脚本错误把 _enter_base() 拦腰打断了。")
		_say("!! 看本次运行日志里的 SCRIPT ERROR / Parse Error，先修那个再跑本探针。")
		_finish(2)
	var base_ids := _ids(root)
	_check(int(_main.get("mode")) == M_BASE, "开局 mode == BASE")
	_check(not base_ids.is_empty(), "基地里 GameRoot 有节点（实得 %d 个）" % base_ids.size())

	# ---- 出击 #1：点大门 → 选人 → 面板「出击」 ----
	await _sortie()
	var run1_ids := _ids(root)
	var res1: Array = _residue(base_ids, root)
	_say("--- 第 1 次出击 ---")
	_say("  " + _state_line(root, _tally(root)))
	if not _healthy(root, "MapRoot"):
		_say("!! 环境不健康：出击 #1 没生成关卡地图，后面的对比全部作废")
		_finish(2)
	_check(int(_main.get("mode")) == M_RUN, "出击 #1 mode == RUN")
	_check(res1.is_empty(), "出击 #1：基地节点没跟进关卡（残留=%s）" % _fmt_res(res1))
	_check(_no_base_content(root), "出击 #1：关卡里没有基地地板/建筑")
	_check(_count_group("player") == 1, "出击 #1：场上 1 名角色")

	# ---- 一局结束 → 按 R 回基地 ----
	await _back_to_base()
	var stale1: Array = _residue(run1_ids, root)
	var back_ids := _ids(root)
	_say("--- 回基地 ---")
	_say("  " + _state_line(root, _tally(root)))
	_check(int(_main.get("mode")) == M_BASE, "回基地 mode == BASE")
	_check(stale1.is_empty(), "回基地：上一局的节点没留下来（残留=%s）" % _fmt_res(stale1))
	_check(_count_group("player") == 0, "回基地：场上没有角色")

	# ---- 出击 #2：用户报的那一步 ----
	await _sortie()
	var res2: Array = _residue(back_ids, root)
	_say("--- 第 2 次出击（用户报的位置）---")
	_say("  " + _state_line(root, _tally(root)))
	await _shot("launch2")
	_check(int(_main.get("mode")) == M_RUN, "出击 #2 mode == RUN")
	_check(res2.is_empty(), "出击 #2：基地节点没跟进关卡（残留=%s）" % _fmt_res(res2))
	_check(_no_base_content(root), "出击 #2：关卡里没有基地地板/建筑（用户看到的正是它）")
	_check(_count_group("player") == 1, "出击 #2：场上只有 1 名角色")
	_check(_count_group("iso_cam") <= 1,
			"出击 #2：相机只有 1 台（实得 %d）" % _count_group("iso_cam"))
	var run2_count: int = root.get_child_count()

	# ---- 出击 #3：泄漏是"每局多一份"的话，这里最明显 ----
	await _back_to_base()
	var back3 := _ids(root)
	await _sortie()
	var res3: Array = _residue(back3, root)
	_say("--- 第 3 次出击 ---")
	_say("  " + _state_line(root, _tally(root)))
	_check(res3.is_empty(), "出击 #3：同样没有基地残留（残留=%s）" % _fmt_res(res3))
	_check(_no_base_content(root), "出击 #3：关卡里没有基地地板/建筑")
	_check(root.get_child_count() <= run2_count + 2,
			"GameRoot 子节点数没有每局只增不减（出击#2=%d，出击#3=%d）"
			% [run2_count, root.get_child_count()])

	# ---- 出击 #4：重摆没结束就直接出击 ----
	# 唯一一条"基地专有的带贴图节点有机会跟着进关卡"的路径：PlacementMode 是
	# 直接挂在 GameRoot 下的，身上还揣着被重摆建筑的本体纹理。
	# 2026-09-19 之前 _enter_run() 不收尾它 —— 节点被 _clear_game_root() 顺手释放了，
	# 但 main._placement 仍指着那个死节点，_overlay_open() 从此恒真（ESC 退不出去），
	# 而且此后右键任何建筑都不能再重摆（`if _placement != null: return` 永久拒）。
	# 这一步是直接调 main 的路由函数凑出这个状态的：真玩的时候 PlacementMode
	# 吃掉鼠标点击，点不动大门。要防的是"处在这个状态时进局"，不是"能不能用鼠标走到"。
	await _back_to_base()
	var back4 := _ids(root)
	_main.call("_on_reposition_requested", "gate")
	await _frames(3)
	_check(_main.get("_placement") != null, "右键大门建筑 → 进入了重摆模式")
	await _sortie()
	var res4: Array = _residue(back4, root)
	_say("--- 第 4 次出击（重摆中途直接出击）---")
	_say("  " + _state_line(root, _tally(root)))
	_check(_main.get("_placement") == null,
			"进局后重摆模式已收尾（实得 %s）" % str(_main.get("_placement")))
	_check(not _healthy(root, "PlacementMode"), "关卡里没有 PlacementMode 节点")
	_check(not bool(_main.call("_overlay_open")),
			"出击 #4 后 _overlay_open() 是假的（否则 ESC 从此退不出去）")
	_check(res4.is_empty(), "出击 #4：基地节点没跟进关卡（残留=%s）" % _fmt_res(res4))
	_check(_no_base_content(root), "出击 #4：关卡里没有基地地板/建筑")
	_finish(0)


## 走一遍真实出击流程：点传送门 → 面板只勾名册第一人 → 按「出击」。
## 不直接调 main._on_launch —— 面板 open() 会 get_tree().paused = true、
## close() 再放开，这一开一关正属于"用户做过、探针没做"的动作。
## ⚠ 2026-09-20 出击入口换人：走 "portal"（原 "gate" 已降为纯装饰，点它只
##   push_warning，面板根本不会弹 → 这里会 _finish(2) 假报环境坏了）。
func _sortie() -> void:
	_main.call("_on_building_interacted", "portal")
	await _frames(3)
	var panel: Node = _main.get("character_panel")
	if panel == null or not bool(panel.get("visible")):
		_say("!! 点传送门没弹出选人面板，出击流程走不下去")
		_finish(2)
		return
	# 只留第一行：全选会一次生成 4 名角色，节点数一多"谁残留"就淹在噪声里
	var checks: Array = []
	_collect_checks(panel, checks)
	for i in range(checks.size()):
		(checks[i] as CheckBox).button_pressed = i == 0
	panel.call("_on_launch_pressed")
	await _wait_player()


## 一局结束（撤离成功，会往存档槽回仓 + 发经验）→ 按 R 的等价动作回基地。
func _back_to_base() -> void:
	var run: Node = _main.get("run")
	run.call("_end_run", "extracted")
	await _frames(10)
	_main.call("_enter_base")
	await _frames(30)


func _collect_checks(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is CheckBox:
			out.append(c)
		_collect_checks(c, out)


## GameRoot 直接子节点的「种类 → 个数」。
## 有名字的按名字算；没名字的（引擎自动名 @Area2D@2527 这种）按
## 「类名:脚本」归并 —— 否则一次出击能刷出几千条互不相同的自动名，报告没法看，
## 而"谁把几千个节点直接挂在 GameRoot 上"恰恰就是这里要抓的东西。
func _tally(root: Node) -> Dictionary:
	var t := {}
	for c in root.get_children():
		var k := _key_of(c)
		t[k] = int(t.get(k, 0)) + 1
	return t


func _key_of(c: Node) -> String:
	var n := str(c.name)
	if not n.begins_with("@"):
		return n
	var s = c.get_script()
	if s != null:
		return "%s:%s" % [c.get_class(), str(s.resource_path).get_file()]
	return c.get_class()


## GameRoot 直接子节点的 {实例 id → 可读名}。
## 用字典不用数组：下一步要按 id 求集合交集，字典天然去重、查着也便宜。
func _ids(root: Node) -> Dictionary:
	var d := {}
	for c in root.get_children():
		d[c.get_instance_id()] = _key_of(c)
	return d


## prev 那一批实例里，现在还挂在 root 下的有哪些。
## 返回项带上「名字#id」：只有 id 定位不了是谁，只有名字会被自动名糊住。
func _residue(prev: Dictionary, root: Node) -> Array:
	var out: Array = []
	for c in root.get_children():
		var id: int = c.get_instance_id()
		if prev.has(id):
			out.append("%s#%d" % [str(prev[id]), id])
	return out


func _fmt(t: Dictionary) -> String:
	var keys: Array = t.keys()
	keys.sort_custom(func(a, b): return int(t[a]) > int(t[b]))
	var parts := []
	for i in range(mini(12, keys.size())):
		parts.append("%s×%d" % [str(keys[i]), int(t[keys[i]])])
	var total := 0
	for k in keys:
		total += int(t[k])
	return "  ".join(parts) + "｜共 %d 个节点 / %d 类" % [total, keys.size()]


## mode 才是"现在到底是基地还是局内"的权威答案；节点名只是线索。
## 另附地图根节点的直接子节点：基地是 BaseTileMap+建筑，局内是 TileMapLayer+DecorLayer。
func _state_line(root: Node, t: Dictionary) -> String:
	var s := "[mode=%s] %s" % [str(_main.get("mode")), _fmt(t)]
	for c in root.get_children():
		var n := str(c.name)
		if n.contains("MapRoot") or c is TileMapLayer:
			var kids := []
			for k in c.get_children():
				kids.append(_key_of(k))
			s += "\n       %s → %s" % [n, ", ".join(kids)]
	return s


## 截图：节点数说"没残留"，眼睛说有没有。
## 只在 --window 下有内容 —— headless 没有 viewport 纹理，这时如实报一句、
## 不算失败（图是佐证，断言才是判据）。
func _shot(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		_say("  [图] headless 无渲染，%s 处未截图（要图就加 --window 重跑）" % tag)
		return
	await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	if im == null:
		_say("  [图] %s：viewport 贴图为空" % tag)
		return
	var rel := "res://Dev/_shot_second_launch_%s.png" % tag
	var err := im.save_png(rel)
	_say("  [图] %s → %s（%dx%d，err=%d）"
			% [tag, ProjectSettings.globalize_path(rel), im.get_width(), im.get_height(), err])


func _count_group(g: String) -> int:
	return get_tree().get_nodes_in_group(g).size()


## 体检：GameRoot 直接子节点里有没有名字含 marker 的。
## **只用于"场景到底建完没有"**（BaseMapRoot / MapRoot 是 base_system、
## MapGenerator 各自手写的节点名，是硬约定）；判残留一律看实例 id，不看名字。
func _healthy(root: Node, marker: String) -> bool:
	for c in root.get_children():
		if str(c.name).contains(marker):
			return true
	return false


## 关卡里不该有任何"只有基地才有"的东西：基地地板（BaseMapRoot / BaseTileMap）
## 与建筑（building.gd 挂的节点，名字五花八门所以认脚本）。
## 这是第二张网 —— 实例 id 只能抓到"没被释放的节点"，万一基地节点是被
## duplicate() 复制进关卡的，那是一份全新实例，id 比对看不出来，只有名字/脚本看得出来。
func _no_base_content(root: Node) -> bool:
	for c in root.get_children():
		if str(c.name).contains("Base"):
			_say("       ↑ 关卡里出现基地节点：%s" % _key_of(c))
			return false
		var s = c.get_script()
		if s != null and str(s.resource_path).get_file() == "building.gd":
			_say("       ↑ 关卡里出现建筑：%s" % _key_of(c))
			return false
	return true


## 残留清单的简报：泄漏动辄上千个实例，全贴出来报告就没法读了。
## 只点名前 6 个 —— 抓 bug 要的是"是谁"，那一个种类名就够定位到系统。
func _fmt_res(list: Array) -> String:
	if list.is_empty():
		return "无"
	var parts := []
	for i in range(mini(6, list.size())):
		parts.append(str(list[i]))
	var tail := "" if list.size() <= 6 else "…（共 %d 个，已截断）" % list.size()
	return "%s%s" % [", ".join(parts), tail]


## 等角色生成出来并稳定（出击是异步建图的，直接读会看到半截场景）
func _wait_player() -> void:
	var waited := 0
	while _count_group("player") == 0 and waited < 600:
		await get_tree().process_frame
		waited += 1
	await _frames(20)


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


## code：0 = 正常收尾（退出码由断言结果决定）；非 0 = 本次作废（环境问题），
## 回归脚本据此区分"游戏真坏了"和"探针根本没跑成"。
func _finish(code: int = 0) -> void:
	if _dead:
		return
	_dead = true
	_restore_save()
	_say("")
	if code != 0:
		_say("=== 本次作废：环境不健康（退出码 %d），下面 %d 项断言未全跑完 ==="
				% [code, _n])
	else:
		_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for msg in _fails:
		_say("  !! " + msg)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_second_launch] 通过 %d / %d%s"
			% [_n - _fails.size(), _n, "" if code == 0 else "（作废）"])
	get_tree().quit(code if code != 0 else (0 if _fails.is_empty() else 1))

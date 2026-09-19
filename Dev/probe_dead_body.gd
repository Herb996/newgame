extends Node
## ============================================================
## probe_dead_body — 角色阵亡后**人从场上消失，货留在原地**
##
## 用户 2026-09-19 定：「我就要他消失啊」。
## 背包一人一份之后，阵亡是「整包就地撒成一地、队友走近捡回」（§5.11）——
## 掉的是货，不是人。所以本探针量两件事，缺一不可：
##   1) 人必须在淡出之后移出场景（不留尸体）；
##   2) 人已没了之后，那一地货仍在死亡的坐标上（消失不能顺手把货一起带走）。
## 顺带盯住缓存了角色引用的两处 UI（背包弹窗 / 底部菜单栏）：人释放后它们
## 必须自己收起/换人，不能拿一个 freed 实例继续画。
##
## ⚠ 会写 user://save.json（出击/结算），开跑备份、收尾原样还原。
## ⚠ 出击名单故意不带 uid = 没有名册身份的临时角色，打死不动玩家真名册。
## ============================================================

const OUT := "user://_probe_dead_body.txt"
const SAVE_PATH := "user://save.json"

## 淡出 combat.player.death_fade_seconds=0.45s ≈ 27 个物理帧；给到 60 帧还没走
## 就是真没排上移除。超过这个上限才算 FAIL。
const GONE_LIMIT := 60

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _save_backup := ""
var _save_existed := false

var _main: Node = null
var _run: Node = null
var _players: Array = []


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _pframes(n: int) -> void:
	for _i in range(n):
		await get_tree().physics_frame


func _backup_save() -> void:
	_save_existed = FileAccess.file_exists(SAVE_PATH)
	if _save_existed:
		var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
		_save_backup = f.get_as_text() if f != null else ""


func _restore_save() -> void:
	if _save_existed:
		var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_save_backup)


# ------------------------------------------------------------
# 采样与等待
# ------------------------------------------------------------
## 形参故意不写类型：阵亡淡出后拿到的是 **freed** 对象，声明成 Node 会在进函数前
## 就抛 "Invalid type … previously freed"，把整条探针协程打断（探针挂死的真因）。
func _read(p) -> Dictionary:
	var d := {}
	d["valid"] = is_instance_valid(p)
	if not bool(d["valid"]):
		return d
	d["in_tree"] = p.is_inside_tree()
	d["alpha"] = float(p.modulate.a)
	d["group"] = p.is_in_group("player")
	d["pos"] = "%.0f,%.0f" % [p.global_position.x, p.global_position.y]
	return d


func _fmt(d: Dictionary) -> String:
	if not bool(d.get("valid", false)):
		return "节点已失效（不在树里/已释放）"
	return "in_tree=%s alpha=%s group=%s pos=%s" % [
			str(d.get("in_tree")), "%.3f" % float(d.get("alpha", 1.0)),
			str(d.get("group")), str(d.get("pos"))]


## 逐物理帧等到节点真的不在树里；返回需要的帧数，超时返回 -1
func _wait_gone(p, limit: int) -> int:
	for i in range(limit):
		await get_tree().physics_frame
		var d := _read(p)
		if not bool(d.get("valid", false)) or not bool(d.get("in_tree", false)):
			return i
	return -1


func _loot_near(pos: Vector2, r: float) -> int:
	var n := 0
	for q in get_tree().get_nodes_in_group("loot_nodes"):
		if is_instance_valid(q) and float(q.global_position.distance_to(pos)) <= r:
			n += 1
	return n


func _alive_players() -> int:
	var n := 0
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q) and q.is_inside_tree() and not bool(q.is_dead()):
			n += 1
	return n


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()

	# 无头驱动给的视口是退化的 64×64：本探针要量屏幕相关行为，先撑回正常尺寸
	var win: Window = get_tree().root
	if win.size.x < 400 or win.size.y < 400:
		win.size = Vector2i(1280, 720)
		await _frames(2)

	Config.set_override("debug.auto_enter_run", false)
	Config.set_override("enemy.count", 0)
	Config.set_override("animals.count", 0)

	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child(_main)
	await _frames(30)

	_main.call("_on_launch", [{"id": "spearman", "name": "枪手"},
			{"id": "archer", "name": "弓兵"}])
	var waited := 0
	while get_tree().get_nodes_in_group("player").size() < 2 and waited < 400:
		await get_tree().process_frame
		waited += 1
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q) and not bool(q.is_dead()):
			_players.append(q)
	_run = get_tree().get_first_node_in_group("run_manager")

	_say("--- 前置 ---")
	_say("  视口=%s 角色=%d run.state=%s" % [str(get_viewport().get_visible_rect().size),
			_players.size(), str(_run.state) if _run != null else "?"])
	_check(_players.size() == 2, "出击后拿到 2 名角色")
	if _players.size() < 2:
		_finish()
		return

	_say("--- A 段：队友在场时甲阵亡 —— 人消失、货留下、弹窗自己收、本局继续 ---")
	var a: Node = _players[0]
	var b: Node = _players[1]
	# 先把乙挪开：两人出生只差 52px，乙正站在掉物上，0.5s 的拾取重试一到就整包
	# 被他捡走 —— 那样"货还在不在"就测不到了（拾取归属本来就是谁近谁拿）。
	b.global_position = a.global_position + Vector2(420.0, 0.0)
	await _pframes(4)
	a.add_item("wood", 9)
	a.add_item("stone", 7)
	a.add_item("food", 5)
	await _pframes(3)

	# 让弹窗在甲头顶开着再打死他：这是「人没了、UI 还指着人」最容易翻车的一条路
	var popup: Node = get_tree().get_first_node_in_group("inventory_popup")
	_check(popup != null, "背包弹窗存在（右键面板）")
	if popup != null:
		popup.call("open_for", a)
	_check(popup != null and bool(popup.call("is_open")), "弹窗为甲打开着")

	var pos_die: Vector2 = a.global_position
	var loot_before := _loot_near(pos_die, 60.0)
	a.call("take_damage", 999999, Vector2.ZERO)
	_say("  倒下 f0：%s" % _fmt(_read(a)))

	var faded := false
	var gone_frame := -1
	for i in range(GONE_LIMIT):
		await get_tree().physics_frame
		var d := _read(a)
		if not bool(d.get("valid", false)) or not bool(d.get("in_tree", false)):
			gone_frame = i
			break
		if float(d.get("alpha", 1.0)) < 0.99:
			faded = true
	_say("  第 %d 帧人从场上移除（%s）" % [gone_frame, _fmt(_read(a))])
	_check(faded, "消失前先淡出（不是当帧凭空抹掉，看得见谁倒了）")
	_check(gone_frame >= 0 and gone_frame < GONE_LIMIT,
			"阵亡后 %d 个物理帧内人从场上消失（实际 %d）" % [GONE_LIMIT, gone_frame])
	_check(not is_instance_valid(a) or not a.is_inside_tree(), "节点确实不在场景树里")
	_check(_loot_near(pos_die, 60.0) >= loot_before + 3,
			"人没了、货还在死亡的坐标上（掉前 %d → 掉后 %d，3 种资源）" % [
			loot_before, _loot_near(pos_die, 60.0)])
	_check(popup != null and not bool(popup.call("is_open")),
			"人释放后弹窗自己收起（没有指着 freed 实例继续画）")
	_check(_alive_players() == 1, "场上只剩乙一个活人")
	_check(int(_run.state) == int(_run.State.RUNNING), "乙还活着 → 本局继续")
	_check(is_instance_valid(_main), "Main 没被顺手释放")

	_say("--- B 段：最后一名也倒下 → 同样消失，本局照常结算 ---")
	# 乙必须自己带一包：player.drop_inventory() 对空背包是直接 return 的，不给货这条
	# 断言就成了「0 → 0 相等」的空测（上一轮回归那条红就是这么来的，不是掉货坏了）。
	# 甲那三件撒在他自己脚下，离这儿 420px，乙捡不回来，不会串味。
	b.add_item("wood", 4)
	b.add_item("oil", 2)
	await _pframes(3)
	var inv_b: Dictionary = b.get("inventory")
	_check(inv_b.size() == 2, "乙死前身上确实有 2 种货（否则下面这条是空断言）：%s" % str(inv_b))
	var pos_b: Vector2 = b.global_position
	var loot_b_before := _loot_near(pos_b, 60.0)
	b.call("take_damage", 999999, Vector2.ZERO)
	var gone_b := await _wait_gone(b, GONE_LIMIT)
	_say("  乙第 %d 帧消失（%s）" % [gone_b, _fmt(_read(b))])
	_check(gone_b >= 0 and gone_b < GONE_LIMIT,
			"弓兵同样在 %d 帧内消失（实际 %d）—— 不是只对枪兵成立" % [GONE_LIMIT, gone_b])
	_check(_loot_near(pos_b, 60.0) >= loot_b_before + 2,
			"全队阵亡时乙这一包也落在原地（掉前 %d → 掉后 %d，2 种资源）" % [
			loot_b_before, _loot_near(pos_b, 60.0)])
	_check(int(_run.state) != int(_run.State.RUNNING), "run 已结算（state=%s）" % str(_run.state))
	_check(is_instance_valid(_main), "结算期间 Main 完好")

	_say("--- C 段：按 R 回基地 → 世界清空 ---")
	_main.call("_enter_base")
	await _frames(30)
	var in_world := 0
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q) and q.is_inside_tree():
			in_world += 1
	_check(in_world == 0, "回基地后场上角色清空（实得 %d）" % in_world)

	_finish()


func _finish() -> void:
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for f in _fails:
		_say("  !! %s" % str(f))
	_restore_save()
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
	print("\n".join(_lines))
	print("[probe_dead_body] fails=%d -> %s" % [_fails.size(),
			"PASS" if _fails.is_empty() else "FAIL"])
	get_tree().quit(0 if _fails.is_empty() else 1)

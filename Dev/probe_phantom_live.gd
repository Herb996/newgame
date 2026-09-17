extends Node
## ============================================================
## probe_phantom_live — 弓手「幻影分身」在**真实 Main.tscn** 里的端到端冒烟（headless 可跑）
##
## 与 probe_phantom_double 的分工：那个是隔离场景里的逐条单测（自建网格 + 假玩家），
## 这个只回答一个问题 —— 「**真进一局**之后，弓手会不会真的带着幻影到处跑，
## 打它会不会掉血、会不会换位、会不会炸」。所以这里不搭台，直接加载 Main.tscn 走
## 基地 → 出击的完整流程。
##
## 2026-09-17 规格更新后的口径：分身**自己一份血**（= 本体 max_hp 的 20%），
## 打分身不伤本体；血条是**整组按组内最低**显示（所以本体与分身的血条长度永远一致，
## 但两边实际血量是分开的）。
##
## 唯一的环境干预：本机 user://settings.json 把 enemy.count 设成了 0（用户调试用），
## 这里用 Config.set_override 临时顶到 40 让敌人刷得出来（不写盘、不动用户设置）。
##
## 注：真实场景里敌人会跑动，所以验「换位」前要把这对本体/分身暂时冻结
## （set_physics_process(false)），验完恢复。
## ============================================================

const OUT := "user://_probe_phantom_live.txt"
const COUNT := 40

var _lines: Array = []
var _n := 0
var _fails: Array = []


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _ready() -> void:
	Config.set_override("enemy.count", COUNT)
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	main._enter_base()
	await _frames(6)
	main._on_launch([{"id": "archer", "name": "弓兵"}])
	await _frames(60)                 # 敌人 setup + 幻影队列（0.15s/具）都跑完

	_say("=== 实机（Main.tscn）冒烟：弓手幻影分身 ===")
	var all: Array = get_tree().get_nodes_in_group("enemies")
	var owners := 0
	var copies := 0
	var owner_with_copies := 0
	for e in all:
		if not e.has_method("is_phantom"):
			continue
		if bool(e.is_phantom()):
			copies += 1
		elif str(e.feature_id()) == "phantom_double":
			owners += 1
			if e.live_phantoms().size() > 0:
				owner_with_copies += 1

	_say("  场上敌人 %d｜幻影本体 %d｜分身 %d" % [all.size(), owners, copies])
	_check(all.size() > 0, "进局后敌人刷出来了（%d 个）" % all.size())
	_check(owners >= 1, "其中有带「幻影分身」的弓手（%d 只）" % owners)
	_check(copies >= 1, "并且真的召出了分身（%d 具）" % copies)
	_check(owner_with_copies >= 1, "至少一只本体身边有活着的幻影（%d 只）" % owner_with_copies)
	_check(copies <= owners * 8, "分身数不超过「本体数 × 单只上限 8」（%d ≤ %d）"
			% [copies, owners * 8])

	# 挑一只本体，冻结它和它的分身来验「血条同步 + 换位」。
	# 先把小队冻住：不然自动战斗会在断言中途把这只本体打死（视野 640px，敌人会自己走过来）。
	for pl in get_tree().get_nodes_in_group("player"):
		pl.set_physics_process(false)
	# 只挑"恰好 1 具分身"的本体：只有一具时"随机挑一个"必然挑到它，
	# 换位断言才可判定（真配置 count_max=2，可能召出两只）。
	var pick = null
	for e in all:
		if e.has_method("is_phantom") and not bool(e.is_phantom()) \
				and str(e.feature_id()) == "phantom_double" and e.live_phantoms().size() == 1:
			pick = e
			break
	_check(pick != null, "找到一只恰好 1 具分身的本体")
	if pick == null:
		_finish()
		return
	var p = pick.live_phantoms()[0]
	pick.set_physics_process(false)
	p.set_physics_process(false)
	pick.hp = int(pick.max_hp)
	p.hp = int(p.max_hp)
	pick.set("_swap_step", 0)

	var A: Vector2 = pick.global_position
	var B: Vector2 = p.global_position
	var full := int(pick.max_hp)
	# 真配置的 raider 带「分身越多本体越硬」减伤（每具 7.5%），所以只验"确实扣了血"；
	# 台阶用更大伤害跨过去（0.4 倍本体血 ⇒ 减伤后仍稳跨 1 个 20% 台阶）
	pick.take_damage(int(full * 0.4))
	_check(int(pick.hp) < full, "打本体：血量真的扣了（%d/%d）" % [int(pick.hp), full])
	_check(int(pick.hp) >= full - int(full * 0.4),
			"本体挨打被「分身越多越硬」减了伤（实掉 %d，未减伤应为 %d）"
			% [full - int(pick.hp), int(full * 0.4)])
	_check(int(p.max_hp) == maxi(1, int(round(float(full) * 0.2))),
			"分身血量 = 本体 20%%（本体 %d / 分身 %d）" % [full, int(p.max_hp)])
	_check(int(p.hp) == int(p.max_hp),
			"分身仍是满血（独立血：本体掉血不牵动分身的血）")
	_check(is_equal_approx(float(p._hp_bar.ratio()), float(pick._hp_bar.ratio())),
			"两边血条长度一致（整组按最低值显示）")
	_check(bool(p._hp_bar.is_showing()), "分身的血条也亮着")
	_check(pick.global_position.is_equal_approx(B) and p.global_position.is_equal_approx(A),
			"掉过 20%% 台阶后本体与分身**换了位**（实机里也生效）")

	# 打分身 = 只扣分身自己那份血（本体一点不掉）
	var before := int(pick.hp)
	var p_before := int(p.hp)
	p.take_damage(3)
	_check(int(pick.hp) == before, "打分身：本体血量不动（%d）" % int(pick.hp))
	_check(int(p.hp) == p_before - 3, "分身自己掉血（%d → %d）" % [p_before, int(p.hp)])

	pick.set_physics_process(true)
	p.set_physics_process(true)

	# 本体死亡 → 幻影收摊
	pick.take_damage(999999)
	_check(bool(pick.get("_dying")), "本体被打死后进入死亡")
	_check(bool(p.get("_dying")), "它的幻影一起消失（不留孤儿）")
	await _frames(4)

	Config.clear_override("enemy.count")
	_finish()


func _finish() -> void:
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_phantom_live] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

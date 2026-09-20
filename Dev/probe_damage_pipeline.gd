extends Node
## ============================================================
## probe_damage_pipeline — 伤害管线真正接通（2026-09-20）
##
## 起因：DamagePipeline.compute() 的签名一直支持 defense / multipliers / variance，
## 但全项目只有两个调用点，而且都只传第一个参数 —— 于是"暴击 / 浮动 / 减防"三件事
## 是纸面上的蓝图。这次把它们接通：三条玩家攻击路径（近战 / 弹道 / 瞬狙）共用
## `player.roll_hit_damage()`，敌人出手走 `enemy.roll_attack_damage()`，
## 数值全部来自 config（crit_chance / crit_multiplier / variance），出厂值让它们
## 一个数都不变。
##
## 分段：
##   A) 纯函数语义：compute 的减防与保底、roll 的抽样与乘算时机、统计分布。
##      ⚠ 必须在进 Main 之前跑 —— 局内有刷怪/寻路 jitter 也在抽随机数，
##      那时候按固定种子复现不出确定的抽样序列。
##   B) 零改动：三条路径在当前**生效配置**下的结果与接通前逐位相同（这条最值钱，
##      它证明"接线"没有偷偷改平衡）。
##   C) 暴击接线：crit_chance=1.0 时近战 / 弹道 / 瞬狙三条都真的乘上了倍率。
##   D) 回落链：武器表写了 crit_chance 就盖过 combat.attack（与 damage/range_px 同规矩）。
##   E) 敌人侧：出厂 variance=0 恒等裸伤；开浮动后落在区间内且真的在变。
##   F) 边界：防守侧减免没被搬走 —— 玩家防御仍在 take_damage 里扣，
##      敌人结算出的数字与玩家防多少无关（否则就是双重扣防）。
##
## 【期望值一律现算，不写死】B/C/D 三段比的是"接通前后逐位相同"，而"接通前的值"
## 取决于**生效配置** = 基础层 Data/config.json + 用户调参层 user://settings.json。
## 在本机上调试面板早就把剑砍成 24、弓射成 16，写死 25/20 会红得莫名其妙。
## 所以每处都先 `attack_param("damage")` 取实际基础值，再按公式推出期望，
## 并把这些数打进报告里（数值被调过不是 bug，报告要能看出是被调成什么样的）。
##
## 【近战怎么验的】resolve_attack_hit 的判定来自 hitbox.get_overlapping_areas()，
## 所以假目标必须是**真的 Area2D**（带 CollisionShape2D、进 enemies 组），
## 靠真实物理重叠喂给它 —— 重写原生 get_overlapping_areas 是行不通的（GDScript
## 覆盖了它，C++ 侧仍按原生实现返回空数组，实测命中数 0）。probe_auto_combat 的
## D 段早就用同一招打出过真伤害，这里沿用。为了让"两个假目标各中一次"不被附近
## 乱逛的真敌人挤掉 max_targets 个名额，本段临时把 max_targets 抬到 16。
## ============================================================

const OUT := "user://_probe_damage_pipeline.txt"
const WEAPON_SWORD := &"sword"
const WEAPON_BOW := &"bow"
const WEAPON_SNIPER := &"sniper"

var _lines: Array = []
var _fails: Array = []
var _n := 0
var _player: Node = null


## 假目标：**根节点就是 Area2D**（与真实 Enemy.tscn 同一结构），带一个圆形判定，
## 这样才能被玩家的 Hitbox 真实重叠到；同时它记得住挨了几次、每次多少。
## 不带任何反馈方法 —— 命中处的 has_method 守卫本来就是为这种目标写的。
class FakeTarget extends Area2D:
	var taken: Array = []

	func _init() -> void:
		var shape := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = 12.0
		shape.shape = circle
		add_child(shape)

	func take_damage(amount: int) -> void:
		taken.append(amount)

	func total() -> int:
		var s := 0
		for v in taken:
			s += int(v)
		return s


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _ready() -> void:
	_section_a()
	await _enter_run()
	await _section_b()
	await _section_c()
	_section_d()
	await _section_e()
	await _section_f()
	Config.clear_overrides()
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[DmgProbe] 通过 %d / %d" % [_n - _fails.size(), _n])
	print("[DmgProbe] fails=%d -> %s" % [_fails.size(), "PASS" if _fails.is_empty() else "FAIL"])
	get_tree().quit(0 if _fails.is_empty() else 1)


# ------------------------------------------------------------
# A 段：纯函数（进局前，此时全场只有本探针在抽随机数）
# ------------------------------------------------------------
func _section_a() -> void:
	_say("--- A 段：DamagePipeline 纯函数语义 ---")
	_check(DamagePipeline.compute(25.0) == 25, "compute(25) = 25（只传基础伤害 = 原值）")
	_check(DamagePipeline.compute(30.0, 10.0) == 20, "compute(30, 减防10) = 20（defense 形参真的在扣）")
	_check(DamagePipeline.compute(5.0, 10.0) == 0,
			"compute(5, 减防10) = 0（完全挡下是 0 不是 1 点保底）")
	_check(DamagePipeline.compute(25.0, 0.0, [1.5]) == 37, "compute(25 ×1.5) = 37（向下取整）")
	var floored := true
	for _i in range(200):
		if DamagePipeline.compute(1.0, 0.0, [], 0.5) < 1:
			floored = false
	_check(floored, "compute(1, 浮动±50%) 仍是 1 点保底（浮动不吃掉最后一点伤害）")

	# roll：出厂参数（不抽暴击、不浮动）必须与 compute 逐位相同
	var r0 := DamagePipeline.roll(25.0)
	_check(not bool(r0["crit"]) and int(r0["damage"]) == 25, "roll(25) 默认参数 = {25, crit=false}")
	_check(int(DamagePipeline.roll(25.0, 0.0, 1.0, 1.5)["damage"]) == 37, "crit_chance=1 → 25×1.5=37")
	_check(int(DamagePipeline.roll(25.0, 0.0, 1.0, 2.0)["damage"]) == 50, "crit_multiplier 换成 2 → 50")
	_check(int(DamagePipeline.roll(25.0, 0.0, 0.0, 99.0)["damage"]) == 25,
			"crit_chance=0 时倍率再大也不进乘算（抽不中就不乘）")

	# 分布：seed 固定 → 本段可复现；比例只断言宽区间（抽中/没抽中的**值**才是硬断言）
	seed(20260920)
	var crits := 0
	var vals_ok := true
	for _i in range(2000):
		var r := DamagePipeline.roll(25.0, 0.0, 0.25, 1.5)
		var is_crit := bool(r["crit"])
		if is_crit:
			crits += 1
		if int(r["damage"]) != (37 if is_crit else 25):
			vals_ok = false
	_check(crits > 380 and crits < 620, "crit_chance=0.25：2000 抽中 %d 次（期望约 500）" % crits)
	_check(vals_ok, "抽中的每次都是 37、没抽中的每次都是 25（乘算只在抽中那一次进）")

	seed(20260920)
	var seen := {}
	var in_band := true
	for _i in range(500):
		var d := DamagePipeline.compute(50.0, 0.0, [], 0.1)
		seen[d] = true
		if d < 45 or d > 55:
			in_band = false
	_check(in_band, "variance=0.1：500 次全部落在 ±10% 区间内（45..55）")
	_check(seen.size() >= 5, "variance=0.1 真的在浮动（出现过 %d 种不同伤害）" % seen.size())
	_check(DamagePipeline.compute(50.0, 0.0, [], 0.0) == 50, "variance=0 不引入任何抖动")


# ------------------------------------------------------------
func _enter_run() -> void:
	_say("")
	_say("--- 进真实局（Main.tscn）---")
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	for _i in range(150):
		await get_tree().process_frame
	_player = get_tree().get_first_node_in_group("player")
	_check(_player != null, "场景里找到 group=player 的角色")


## 把角色调到"能干净地算一刀"的状态：停自动索敌（免得真打起来掺和计数）、
## 清特性与短缺、换指定武器、清空上一段留下的敌人组假目标。
func _prep(weapon: StringName) -> void:
	Config.set_override("combat.auto_attack.enabled", false)
	_player.traits = {}
	_player.supply_penalties = {}
	_player.switch_weapon(weapon)
	for n in get_tree().get_nodes_in_group("enemies"):
		if n is FakeTarget:
			n.free()


## 管线公式的期望值：先乘、再取整（DamagePipeline.compute 就是这个顺序）。
## 基础值一律从**生效配置**取，所以调参层改了数值这里跟着变，报告不会假红。
func _expected(base: float, mult: float = 1.0) -> int:
	return int(floor(base * mult))


## 等角色回到中立态（idle/move）再手动出手：上一段可能把他留在 attack 里，
## 那样判定帧自己会再 resolve 一次，"每个目标各挨一下"的计数就被弄脏了。
func _settle() -> void:
	for _i in range(120):
		var s: StringName = _player.state_machine.get_state_name()
		if s == &"idle" or s == &"move":
			return
		await get_tree().physics_frame


# ------------------------------------------------------------
# B 段：出厂零改动（接通这件事本身不许动数值）
# ------------------------------------------------------------
func _section_b() -> void:
	_say("")
	_say("--- B 段：出厂配置下三条路径数值不变 ---")
	if _player == null:
		_say("   [跳过] 没拿到玩家")
		return
	_prep(WEAPON_SWORD)
	var atk: Dictionary = Config.get_value("combat.attack", {})
	_check(is_equal_approx(float(atk.get("crit_chance", -1.0)), 0.0),
			"combat.attack.crit_chance 出厂 0")
	_check(is_equal_approx(float(atk.get("variance", -1.0)), 0.0), "combat.attack.variance 出厂 0")
	_check(is_equal_approx(float(atk.get("crit_multiplier", -1.0)), 1.5),
			"combat.attack.crit_multiplier 出厂 1.5（备而不用）")
	# 基础值现取：调参层（user://settings.json）可能早把剑砍成别的数了
	var base: float = _player.attack_param("damage", -1.0)
	_say("   生效基础伤害：剑 %.0f（出厂 %s；与调参层合并后的值，下面的期望都由它推）"
			% [base, str(Config.get_base_value("combat.weapons.sword.damage", "?"))])
	var r: Dictionary = _player.roll_hit_damage(base)
	_check(int(r["damage"]) == _expected(base) and not bool(r["crit"]),
			"剑：roll_hit_damage(%.0f) = %.0f 无暴击（与接通前的 int(trait_damage(base)) 同值，实得 %d）"
			% [base, _expected(base), int(r["damage"])])

	# 特性加成仍在管线**之前**生效（base + 2 层 ×7），管线不会把它冲掉
	_player.traits = {"attack": 2}
	var with_trait: Dictionary = _player.roll_hit_damage(base)
	_check(int(with_trait["damage"]) == _expected(base + 14.0),
			"攻击力特性 2 层（+14）先进基础伤害、再进管线：%.0f（实得 %d）"
			% [base + 14.0, int(with_trait["damage"])])
	_player.traits = {}

	# 物资短缺同理（扣的是基础值，不是结算后的数）
	_player.supply_penalties = {"attack": 4.0}
	var shorted: Dictionary = _player.roll_hit_damage(base)
	_check(int(shorted["damage"]) == _expected(base - 4.0),
			"短缺 -4 攻击：%.0f（实得 %d）" % [base - 4.0, int(shorted["damage"])])
	_player.supply_penalties = {}


# ------------------------------------------------------------
# C 段：暴击接进三条攻击路径
# ------------------------------------------------------------
func _section_c() -> void:
	_say("")
	_say("--- C 段：crit_chance=1 时近战 / 弹道 / 瞬狙三条都吃到 ---")
	if _player == null:
		_say("   [跳过] 没拿到玩家")
		return
	Config.set_override("combat.attack.crit_chance", 1.0)

	# ① 近战：两个假目标摆在剑前，靠**真实 Area2D 重叠**喂给 hitbox
	#    （重写 get_overlapping_areas 是假的：GDScript 覆盖了，C++ 侧照样返回空数组）
	_prep(WEAPON_SWORD)
	await _settle()
	var parent: Node = _player.get_parent()
	_player.facing = Vector2.RIGHT
	var base_sword: float = _player.attack_param("damage", -1.0)
	# 名额抬高：附近乱逛的真敌人也可能压进这一刀的扇形里，
	# 挤掉 max_targets 个名额就会把两个假目标顶出去（那是本段的假红，不是被测代码的错）
	Config.set_override("combat.attack.max_targets", 16)
	var a: FakeTarget = _spawn_target(_player.global_position + Vector2(60, 0))
	var b: FakeTarget = _spawn_target(_player.global_position + Vector2(80, 6))
	# 期间钉住无敌：等重叠登记的这几帧里要是被路过的敌人蹭一下，角色进受击硬直
	# → 攻击状态退出 → end_attack_hit 把判定框关掉，那 0 命中是本段的假红而不是被测代码错
	_player.set_invincible(true)
	_player.begin_attack_hit()
	for _i in range(4):
		await get_tree().physics_frame
	_player.resolve_attack_hit()
	_player.set_invincible(false)
	HitStop.reset()          # 真砍中就真顿了一下，别把后面的等帧节拍拖歪
	Config.clear_override("combat.attack.max_targets")
	_check(a.taken.size() == 1 and int(a.taken[0]) == _expected(base_sword, 1.5),
			"近战命中吃到暴击乘算：%.0f×1.5 = %.0f（实得 %s）"
			% [base_sword, _expected(base_sword, 1.5), str(a.taken)])
	_check(b.taken.size() == 1 and int(b.taken[0]) == _expected(base_sword, 1.5),
			"同一次挥击的第二个目标各自抽一次，也各是 %.0f（实得 %s）"
			% [_expected(base_sword, 1.5), str(b.taken)])

	# ② 弹道：出膛那一帧就结算完，弹道节点身上是算好的整数
	_prep(WEAPON_BOW)
	var base_bow: float = _player.attack_param("damage", -1.0)
	_check(bool(_player.fire_projectile()), "fire_projectile 发射成功")
	var arrow: Node = parent.get_node_or_null("Projectile")
	_check(arrow != null, "父层找到 Projectile 节点")
	if arrow != null:
		_check(int(arrow.damage) == _expected(base_bow, 1.5),
				"弹道出膛即结算：箭上带的是 %.0f（弓生效基础 %.0f ×1.5，实得 %d）"
				% [_expected(base_bow, 1.5), base_bow, int(arrow.damage)])
		arrow.free()

	# ③ 瞬狙：穿透的两只各抽一次（chance=1 ⇒ 都是暴击）
	_prep(WEAPON_SNIPER)
	var base_snipe: float = _player.attack_param("damage", -1.0)
	_player.facing = Vector2.RIGHT
	var muzzle: Vector2 = _player.global_position + Vector2(34, 0)
	var s1: FakeTarget = _spawn_target(muzzle + Vector2(80, 0))
	var s2: FakeTarget = _spawn_target(muzzle + Vector2(140, 2))
	var hits := int(_player.fire_hitscan())
	_check(hits == 2, "瞬狙命中 2 只（pierce=2，实得 %d）" % hits)
	_check(s1.taken.size() == 1 and int(s1.taken[0]) == _expected(base_snipe, 1.5),
			"瞬狙第一只吃暴击：%.0f×1.5 = %.0f（实得 %s）"
			% [base_snipe, _expected(base_snipe, 1.5), str(s1.taken)])
	_check(s2.taken.size() == 1 and int(s2.taken[0]) == _expected(base_snipe, 1.5),
			"穿透第二只同样 %.0f（实得 %s）" % [_expected(base_snipe, 1.5), str(s2.taken)])

	# 独立性：同一个入口连调 200 次，概率 0.5 时两种结果都得出现
	Config.set_override("combat.attack.crit_chance", 0.5)
	_prep(WEAPON_SWORD)
	var crit_seen := 0
	var plain_seen := 0
	for _i in range(200):
		if bool(_player.roll_hit_damage(base_sword)["crit"]):
			crit_seen += 1
		else:
			plain_seen += 1
	_check(crit_seen > 0 and plain_seen > 0,
			"每次命中独立抽样：0.5 连抽 200 次两种都出现过（暴击 %d / 普通 %d）"
			% [crit_seen, plain_seen])


# ------------------------------------------------------------
# D 段：回落链（武器表 > combat.attack 全局）
# ------------------------------------------------------------
func _section_d() -> void:
	_say("")
	_say("--- D 段：武器表写了就盖过全局 ---")
	if _player == null:
		_say("   [跳过] 没拿到玩家")
		return
	# 全局 100% 暴击，弓自己写 0% → 弓回到裸基础值；强弩没写 → 照吃全局暴击
	Config.set_override("combat.attack.crit_chance", 1.0)
	Config.set_override("combat.weapons.bow.crit_chance", 0.0)
	_prep(WEAPON_BOW)
	var d_bow: float = _player.attack_param("damage", -1.0)
	_check(int(_player.roll_hit_damage(d_bow)["damage"]) == _expected(d_bow),
			"弓写了 crit_chance=0 → 盖过全局 1.0，仍是裸伤 %.0f" % _expected(d_bow))
	_prep(WEAPON_SNIPER)
	var d_snipe: float = _player.attack_param("damage", -1.0)
	_check(int(_player.roll_hit_damage(d_snipe)["damage"]) == _expected(d_snipe, 1.5),
			"强弩没写 → 吃全局 1.0 暴击：%.0f×1.5 = %.0f" % [d_snipe, _expected(d_snipe, 1.5)])
	Config.set_override("combat.weapons.sniper.crit_chance", 0.0)
	_check(int(_player.roll_hit_damage(d_snipe)["damage"]) == _expected(d_snipe),
			"强弩补写 0 之后回落到裸伤 %.0f（按武器配是纯配置活）" % _expected(d_snipe))
	Config.clear_override("combat.weapons.bow.crit_chance")
	Config.clear_override("combat.weapons.sniper.crit_chance")
	# 浮动同样能按武器配
	Config.set_override("combat.attack.crit_chance", 0.0)
	Config.set_override("combat.weapons.sword.variance", 0.2)
	_prep(WEAPON_SWORD)
	var d_sword: float = _player.attack_param("damage", -1.0)
	var vals := {}
	for _i in range(120):
		vals[int(_player.roll_hit_damage(d_sword)["damage"])] = true
	_check(vals.size() >= 3, "sword.variance=0.2 生效：以 %.0f 为中心出现 %d 种伤害（%s）"
			% [d_sword, vals.size(), str(vals.keys())])
	Config.clear_override("combat.weapons.sword.variance")


# ------------------------------------------------------------
# E 段：敌人出手
# ------------------------------------------------------------
func _section_e() -> void:
	_say("")
	_say("--- E 段：敌人侧结算走同一条管线 ---")
	var e: Node = _real_enemy()
	_check(e != null, "场上有真敌人（每局刷 enemy.count 只；没有就说明本探针的搭台崩了，不许跳过）")
	if e == null:
		return
	_check(is_equal_approx(float(Config.get_value("enemy.attack.variance", -1.0)), 0.0),
			"enemy.attack.variance 出厂 0")
	var raw := int(e.damage)
	var stable := true
	for _i in range(50):
		if int(e.roll_attack_damage()) != raw:
			stable = false
	_check(stable, "出厂：roll_attack_damage() 恒等于兵种裸伤 %d（与接通前逐位相同）" % raw)

	Config.set_override("enemy.attack.variance", 0.5)
	e.refresh_debug_stats()      # _attack_variance 是 _apply_numeric 里缓存的
	var seen := {}
	var in_band := true
	for _i in range(200):
		var d := int(e.roll_attack_damage())
		seen[d] = true
		if d < int(floor(raw * 0.5)) or d > int(ceil(raw * 1.5)):
			in_band = false
	_check(in_band, "variance=0.5：200 刀全部在 ±50%% 区间内（裸伤 %d）" % raw)
	_check(seen.size() >= 3, "variance=0.5 真的在浮动（%d 种不同伤害：%s）"
			% [seen.size(), str(seen.keys())])
	Config.clear_override("enemy.attack.variance")
	e.refresh_debug_stats()


# ------------------------------------------------------------
# F 段：边界 —— 防守侧减免留在被守的一方
# ------------------------------------------------------------
func _section_f() -> void:
	_say("")
	_say("--- F 段：玩家防御仍由 take_damage 自己扣，敌人结算不掺和 ---")
	if _player == null:
		_say("   [跳过] 没拿到玩家")
		return
	var e: Node = _real_enemy()
	if e == null:
		_check(false, "F 段需要一只真敌人（同 E 段）")
		return
	var naked := int(e.roll_attack_damage())
	_player.traits = {"defense": 4}      # 4 层 × per_stack 5 = 20 点防御
	_check(int(e.roll_attack_damage()) == naked,
			"敌人算出的伤害与玩家防多少无关（叠 20 点防仍是 %d —— 攻击侧不替防守方扣）" % naked)
	var far: Vector2 = _player.global_position
	_player.global_position = e.global_position + Vector2(4000, 0)
	_check(int(e.roll_attack_damage()) == naked,
			"把玩家挪到 4000px 外（这一刀必然挥空）后结算值不变 —— 算式里根本没有'打不打得着'")
	_player.global_position = far
	_player.hp = int(_player.max_hp)
	_player.set_invincible(false)
	_player._invincible_timer = 0.0
	var before := int(_player.hp)
	_player.take_damage(naked, _player.global_position + Vector2(200, 0))
	var lost := before - int(_player.hp)
	_check(lost == maxi(naked - 20, 0),
			"take_damage 才扣防：掉血 %d = 裸伤 %d − 防御 20（下限 0）" % [lost, naked])
	# 上面那发恰好被整个挡下（兵种裸伤只有 10），只证明了下限；再补一发打得穿防御的
	_player._invincible_timer = 0.0
	var before2 := int(_player.hp)
	_player.take_damage(50, _player.global_position + Vector2(200, 0))
	_check(before2 - int(_player.hp) == 30,
			"换一发 50 点：掉血 %d = 50 − 防御 20（扣防是真在减数，不是撞上下限）"
			% (before2 - int(_player.hp)))
	_player.traits = {}
	_say("   注：「被完全挡下时敌人照样进冷却、照样播动作」由 Dev/probe_enemy_attack E 段守着，")
	_say("       这条切分是接线时最容易改坏的地方，所以那边红了这里就不用再判一遍。")


# ------------------------------------------------------------
# 工具
# ------------------------------------------------------------
func _spawn_target(pos: Vector2) -> FakeTarget:
	var t := FakeTarget.new()
	_player.get_parent().add_child(t)
	t.global_position = pos
	t.add_to_group("enemies")
	return t


## 场上第一只**真**敌人（本探针自己塞进 enemies 组的假目标不算）。
func _real_enemy() -> Node:
	for n in get_tree().get_nodes_in_group("enemies"):
		if not (n is FakeTarget) and n.has_method("roll_attack_damage"):
			return n
	return null

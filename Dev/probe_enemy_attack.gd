extends Node
## ============================================================
## probe_enemy_attack — 敌人近战出手 + 掉落 + 死亡画面（headless 可跑）
##
## 起因（2026-09-19 用户报 bug）：「敌人不会攻击，贴到角色身上都不造成伤害」。
## 根因是几何对不上：接触伤害靠 Area2D body_entered（敌人 14 + 玩家 16 = 30px 才触发），
## 而当天上线的分离层把敌人钉在 enemies 22 + player 20 = **42px** 外 —— 永远碰不上。
## 第二层根因：整段写在 `if player.take_damage(...)` 里，玩家挡下/无敌帧时敌人连动作和
## 冷却都不进，看起来就是"贴着我一动不动"。
##
## 用户随后的预期（本探针逐条对应）：
##   1「敌人应该要有攻击距离这个属性，进入攻击距离就开始攻击」
##        → B/C 段：射程数值 + 进射程真的出手 + 射程外不出手
##   2「后面会加入攻击特效，当前应该有攻击动作了」
##        → C/H 段：出手期间 _attack_timer 在跑、动画状态是 ATTACK
##          （没有任何攻击帧的冲撞型兵种 = WALK 兜底，见 H 段）
##   3「死亡会掉落物品，先做会掉落物品的机制」
##        → K 段：掉落全走 config（chance / amount / weights），兵种可用自己的 drop 段覆盖
##   4「看下敌人死亡之后是如何处理的，预期是要有死亡画面」
##        → A/J 段：有 dead 帧的兵种先播死帧再淡出；没死帧的兵种直接淡出；淡结束必须离场
##
## 另守两条"再犯一次就红"的不变量：
##   A 段：enemy.attack.range_px 必须 **大于** 分离层的敌人↔玩家最小间距
##         （= combat.separation.radius_px.enemies + .player）。这次事故就是这两个数没对上。
##   E 段：出手与掉血解耦 —— 玩家完全挡下时，敌人**照样**播动作、照样进冷却。
##
## 跑法：python tools/run_probe.py _probe_enemy_attack.log res://Dev/probe_enemy_attack.tscn
## 注：不加载 Main.tscn，自搭开阔网格 + 独立 EnemySystem（与 phantom 探针同一套搭台）。
##     假玩家每物理帧被钉在敌人旁边固定距离处 —— 不然寻路会把"在不在射程"这个条件漂掉。
## ============================================================

const OUT := "user://_probe_enemy_attack.txt"
const ENEMY_SYS := preload("res://Scripts/enemy_system.gd")
const ENEMY_SCENE := preload("res://Scenes/Enemy.tscn")
const TILE := 64
const FPS := 60.0
const NEAR := 30.0        # "站在射程内"的摆位距离（射程默认 52，留 22px 余量给寻路抖动）

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _walls: Array = []
var _glued: Array = []    # [[follower, target, 距离 px], ...] 见 _physics_process


## 假玩家：只需要 take_damage 这扇门。真实 Player 太重（贴图/状态机/小队/背包）。
## ⚠ 返回值必须照真实 Player 的语义（被完全挡下 = false），E 段就靠它复现当时的 bug。
class FakePlayer extends Area2D:
	var hits := 0
	var hp := 1000
	var blocked := false
	func take_damage(amount: int, _from: Vector2) -> bool:
		hits += 1
		if blocked:
			return false
		hp -= amount
		return true


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _phys(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame


## 被钉住的假玩家每物理帧跟目标保持固定距离。
## 探针是本节点的父节点，父先于子跑 → 同一帧内敌人看到的就是这个新位置。
func _physics_process(_delta: float) -> void:
	for g in _glued:
		if is_instance_valid(g[0]) and is_instance_valid(g[1]):
			(g[0] as Node2D).global_position = (g[1] as Node2D).global_position \
					+ Vector2(float(g[2]), 0.0)


# ------------------------------------------------------------
# 搭台
# ------------------------------------------------------------

func _open_walls(size: int) -> Array:
	var w: Array = []
	for _y in range(size):
		var row: Array = []
		for _x in range(size):
			row.append(false)
		w.append(row)
	return w


## 兵种配置的深拷贝（改它不污染 Config）
func _cfg(id: String) -> Dictionary:
	for t in Config.get_value("enemy_types.types", []):
		if t is Dictionary and str((t as Dictionary).get("id", "")) == id:
			return (t as Dictionary).duplicate(true)
	return {}


## 兵种配置的深拷贝 + 覆盖几个键（测兵种级 drop / 射程时用）
func _cfg_with(id: String, over: Dictionary) -> Dictionary:
	var c := _cfg(id)
	for k in over:
		c[k] = over[k]
	return c


func _world() -> Node2D:
	var w := Node2D.new()
	add_child(w)
	return w


func _make_system(world):
	var sys = ENEMY_SYS.new()
	sys.name = "Sys"
	add_child(sys)
	sys._root = world
	sys._walls = _walls
	sys._tile_size = TILE
	sys._astar = MapGenerator.build_astar(_walls, TILE)
	return sys


func _spawn_at(world: Node2D, pos: Vector2, type_cfg: Dictionary, sys):
	var e = ENEMY_SCENE.instantiate()
	e.position = pos
	world.add_child(e)
	e.setup(_walls, TILE, sys._astar, type_cfg, {}, sys)
	return e


func _add_player(world: Node2D) -> FakePlayer:
	var fp := FakePlayer.new()
	world.add_child(fp)
	fp.add_to_group("player")
	return fp


func _teardown(world: Node2D, sys) -> void:
	_glued.clear()
	if sys != null and is_instance_valid(sys):
		sys._pending.clear()
		sys.queue_free()
	if world != null and is_instance_valid(world):
		world.queue_free()
	await _phys(2)


func _loot_count() -> int:
	return get_tree().get_nodes_in_group("loot_nodes").size()


func _attack_cfg() -> Dictionary:
	return Config.get_value("enemy.attack", {})


func _frames(type_cfg: Dictionary, key: String) -> int:
	var v = type_cfg.get(key, [])
	return v.size() if (v is Array) else 0


func _sec_frames(sec: float) -> int:
	return maxi(1, int(ceil(sec * FPS)))


func _ready() -> void:
	_walls = _open_walls(48)
	NoiseSystem.setup([], TILE)
	NoiseSystem.reset()

	_config_truth()
	await _range_predicate()
	await _swing_cooldown_block()
	await _whiff_and_ram()
	await _per_type_range()
	await _death_and_drop()

	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[EnemyAttackProbe] 通过 %d / %d" % [_n - _fails.size(), _n])
	Config.clear_overrides()
	get_tree().quit(0 if _fails.is_empty() else 1)


# ------------------------------------------------------------
# A) config 真值 + 那条把 bug 藏起来的几何不等式
# ------------------------------------------------------------
func _config_truth() -> void:
	_say("=== A) config 真值 / 几何不变量 ===")
	var atk := _attack_cfg()
	_check(not atk.is_empty(), "config 有 enemy.attack 段")
	var rng := float(atk.get("range_px", 0.0))
	var cd := float(atk.get("cooldown_seconds", 0.0))
	var windup := float(atk.get("windup_seconds", 0.0))
	var min_dur := float(atk.get("min_duration_seconds", 0.0))
	_check(rng > 0.0 and cd > 0.0 and windup > 0.0 and min_dur > 0.0,
			"四个数值键齐且 >0（range=%.0f cd=%.2f windup=%.2f min=%.2f）"
			% [rng, cd, windup, min_dur])
	# 分离层把敌人顶住的那圈 = 两边半径之和。射程必须比它大，否则"进射程"这件事
	# 永远不会发生 —— 这正是 2026-09-19 那个 bug 的全部机制。
	var rr: Dictionary = Config.get_value("combat.separation.radius_px", {})
	var r_enemies := float(rr.get("enemies", 0.0))
	var r_player := float(rr.get("player", 0.0))
	var gap := r_enemies + r_player
	_check(gap > 0.0 and rng > gap,
			"射程 %.0f > 分离层最小间距 %.0f（enemies %.0f + player %.0f）"
			% [rng, gap, r_enemies, r_player])
	# 前摇要落在攻击动作之内，否则"动作播完了伤害才到"，读起来就是空挥
	_check(windup < min_dur, "前摇 %.2fs < 动作保底时长 %.2fs" % [windup, min_dur])
	_check(min_dur <= cd, "动作时长 %.2fs <= 冷却 %.2fs（下一刀不会打断这一刀）" % [min_dur, cd])

	# 素材现状报告：用户预期 2（攻击特效）与 4（死亡画面）都卡在这两份帧表上
	var types: Array = Config.get_value("enemy_types.types", [])
	var with_attack := 0
	var with_dead := 0
	var dead_missing := 0
	for t in types:
		if not (t is Dictionary):
			continue
		var c := t as Dictionary
		if _frames(c, "attack") > 0:
			with_attack += 1
		var dead = c.get("dead", [])
		if dead is Array and not (dead as Array).is_empty():
			with_dead += 1
			for p in (dead as Array):
				if not ResourceLoader.exists(str(p)):
					dead_missing += 1
	_check(types.size() >= 1, "兵种表非空（%d 个）" % types.size())
	_check(with_attack >= 1,
			"%d / %d 个兵种有攻击帧，剩下的靠 WALK 兜底（H 段）" % [with_attack, types.size()])
	_check(with_dead >= 1 and dead_missing == 0,
			"%d 个兵种带死亡帧且贴图全部存在（缺 %d）" % [with_dead, dead_missing])
	_say("  · 只有配了 dead 的兵种会播倒地动画，其余靠淡出（透明+缩小+下沉）")


# ------------------------------------------------------------
# B) 射程判定本身（直调，不受 AI 位移干扰）
# ------------------------------------------------------------
func _range_predicate() -> void:
	_say("=== B) in_attack_range() 判定 ===")
	var world := _world()
	var sys = _make_system(world)
	var e = _spawn_at(world, Vector2(900.0, 900.0), _cfg("ep_troll"), sys)
	var rng: float = e.attack_range_px()
	_check(is_equal_approx(rng, float(_attack_cfg().get("range_px", 0.0))),
			"默认射程取自 config enemy.attack.range_px（%.0f）" % rng)
	_check(not e.in_attack_range(), "场上没有玩家 → 不可出手")

	var fp := _add_player(world)
	fp.global_position = e.global_position + Vector2(NEAR, 0.0)
	_check(e.in_attack_range(), "距离 %.0f < 射程 %.0f → 在射程内" % [NEAR, rng])
	fp.global_position = e.global_position + Vector2(rng, 0.0)
	_check(e.in_attack_range(), "距离恰好 = 射程 → 算在射程内（判据是 <=）")
	fp.global_position = e.global_position + Vector2(rng + 1.0, 0.0)
	_check(not e.in_attack_range(), "超出射程 1px → 不算")
	# 浮点贴边：rng-0.5 这种"刚进射程"的边界必须算，否则射程数值本身不可信
	fp.global_position = e.global_position + Vector2(rng - 0.5, 0.0)
	_check(e.in_attack_range(), "射程内贴边 → 算")

	# 尸体不配打人：打死之后射程判定与出手都要停
	e.take_damage(int(e.max_hp) * 99)
	await _phys(2)
	_check(e._dying, "致死伤害 → _dying")
	var dead_frames: int = e._death_frames.size()
	_check(dead_frames >= 1, "ep_troll 带 %d 帧死亡动画（A 段报告的那份）" % dead_frames)
	await _phys(_sec_frames(float(dead_frames)
			/ maxf(float(Config.get_value("enemy.death_fps", 8.0)), 1.0))
			+ _sec_frames(float(Config.get_value("enemy.death_fade_seconds", 0.45))) + 20)
	_check(not is_instance_valid(e), "死帧 + 淡出播完 → queue_free（不留尸体）")
	await _teardown(world, sys)


# ------------------------------------------------------------
# C+D+E+F) 真实物理帧：进射程就出手 → 前摇 → 冷却 → 挡下仍出手
# ------------------------------------------------------------
func _swing_cooldown_block() -> void:
	_say("=== C/D/E/F) 出手 → 前摇 → 冷却 → 挡下仍出手 ===")
	var world := _world()
	var sys = _make_system(world)
	var troll := _cfg("ep_troll")
	var e = _spawn_at(world, Vector2(900.0, 900.0), troll, sys)
	var fp := _add_player(world)
	_glued.append([fp, e, NEAR])       # 一直站在射程内

	var atk := _attack_cfg()
	var cd := float(atk.get("cooldown_seconds", 1.0))
	var windup := float(atk.get("windup_seconds", 0.18))
	var w := _sec_frames(windup)
	var cd_f := _sec_frames(cd)

	# C：进了射程 → 有动作、有冷却
	await _phys(3)
	_check(e._attack_timer > 0.0, "进射程 3 帧就有攻击动作在播（_attack_timer=%.2f）"
			% float(e._attack_timer))
	_check(e._attack_cooldown > 0.0, "出手同时进冷却（_attack_cooldown=%.2f）"
			% float(e._attack_cooldown))
	_check(e._anim_state == PlayerAnimator.Anim.ATTACK,
			"动画状态 = ATTACK（%d 攻击帧的兵种）" % _frames(troll, "attack"))
	# F：前摇没走完，伤害不该已经结算（"抬手→落到"这段延迟是手感的关键）
	_check(fp.hits == 0, "前摇 %.2fs 内不结算伤害（hits=0）" % windup)

	await _phys(w + 2 - 3)
	_check(fp.hits == 1, "前摇走完 → 命中 1 次（实得 %d）" % int(fp.hits))
	_check(int(fp.hp) == 1000 - int(e.damage), "掉血 = 兵种 damage（%d）" % int(e.damage))

	# D：冷却期内不许连打；冷却走完必须有第二刀
	await _phys(cd_f - w + 2)
	_check(fp.hits == 1, "冷却 %.1fs 内不连打（hits 仍是 1）" % cd)
	await _phys(w + 4)
	_check(fp.hits >= 2, "冷却走完 → 会再出手（hits=%d）" % int(fp.hits))

	# E（核心，负对照）：玩家完全挡下时，动作与冷却**不回收**
	var hits_before := int(fp.hits)
	var hp_before := int(fp.hp)
	fp.blocked = true
	await _phys(cd_f + w + 4)
	_check(int(fp.hits) > hits_before,
			"玩家挡下（take_damage 返回 false）→ 敌人照样出手（hits %d → %d）"
			% [hits_before, int(fp.hits)])
	_check(int(fp.hp) == hp_before, "挡下期间一滴血都不掉")
	_check(e._attack_cooldown > 0.0 or e._attack_timer > 0.0,
			"这一刀照样占用冷却/动作 —— 不会再出现「贴着我一动不动」")

	await _teardown(world, sys)


# ------------------------------------------------------------
# G+H) 挥空不回收 + 无攻击帧兵种的兜底表现
# ------------------------------------------------------------
func _whiff_and_ram() -> void:
	_say("=== G/H) 挥空不回收；无攻击帧兵种 WALK 兜底 ===")
	var world := _world()
	var sys = _make_system(world)
	var e = _spawn_at(world, Vector2(900.0, 900.0), _cfg("ep_troll"), sys)
	var fp := _add_player(world)
	_glued.append([fp, e, NEAR])
	var atk := _attack_cfg()
	var rng: float = e.attack_range_px()
	var w := _sec_frames(float(atk.get("windup_seconds", 0.18)))

	# G：在射程内合法起手，随后玩家甩开 —— 这一刀该挥空，但动作和冷却照旧不回收
	await _phys(2)
	_glued.clear()
	e._attack_timer = 0.0
	e._attack_cooldown = 0.0
	e._start_attack()
	var hits_before := int(fp.hits)
	_glued.append([fp, e, rng + 400.0])   # 拉开：它追得上，但这几帧追不上
	await _phys(w + 4)
	_check(int(fp.hits) == hits_before, "玩家跑出射程 → 这一刀挥空（不掉血）")
	_check(e._attack_cooldown > 0.0, "挥空照样进冷却")
	_check(e._attack_timer > 0.0, "挥空照样把动作播完（_attack_timer=%.2f）"
			% float(e._attack_timer))
	_check(not e.in_attack_range(), "拉开之后确实不在射程（判据本身没骗人）")

	# H：洞穴兽一帧攻击动画都没有（冲撞型）—— 不能因为"没帧可播"就不出手
	_glued.clear()
	var cave := _cfg("ep_cave")
	_check(_frames(cave, "attack") == 0, "ep_cave 确实没有攻击帧")
	var c = _spawn_at(world, Vector2(2200.0, 900.0), cave, sys)
	var fp2 := _add_player(world)
	_glued.append([fp2, c, NEAR])
	await _phys(3)
	var min_dur := float(atk.get("min_duration_seconds", 0.3))
	_check(c._attack_timer > 0.0, "无攻击帧的兵种进了射程也出手")
	_check(c._attack_timer <= min_dur + 0.05,
			"没攻击帧 → 动作时长用 min_duration_seconds 保底（%.2f ≤ %.2f）"
			% [float(c._attack_timer), min_dur])
	_check(c._anim_state == PlayerAnimator.Anim.WALK,
			"无攻击帧时用 WALK 表现冲撞（不是站着不动）")
	await _teardown(world, sys)


# ------------------------------------------------------------
# I) 兵种级射程覆盖（以后的"长矛怪/远程怪"就靠这个键）
# ------------------------------------------------------------
func _per_type_range() -> void:
	_say("=== I) 兵种可覆盖 attack_range_px ===")
	var world := _world()
	var sys = _make_system(world)
	var dflt := float(_attack_cfg().get("range_px", 0.0))
	var e0 = _spawn_at(world, Vector2(700.0, 700.0), _cfg("ep_troll"), sys)
	_check(is_equal_approx(float(e0.attack_range_px()), dflt),
			"没写 attack_range_px → 用全局 %.0f" % dflt)
	var e1 = _spawn_at(world, Vector2(1500.0, 700.0),
			_cfg_with("ep_troll", {"attack_range_px": dflt + 40.0}), sys)
	_check(is_equal_approx(float(e1.attack_range_px()), dflt + 40.0),
			"写了 attack_range_px → 兵种自己说了算（%.0f）" % float(e1.attack_range_px()))
	var fp := _add_player(world)
	var mid := dflt + 20.0
	fp.global_position = e0.global_position + Vector2(mid, 0.0)
	_check(not e0.in_attack_range(), "同一个距离 %.0f：默认射程怪够不到" % mid)
	fp.global_position = e1.global_position + Vector2(mid, 0.0)
	_check(e1.in_attack_range(), "同一个距离 %.0f：长射程怪够得到" % mid)
	await _teardown(world, sys)


# ------------------------------------------------------------
# J+K) 死亡：死帧 → 淡出 → 离场；掉落全走 config
# ------------------------------------------------------------
func _death_and_drop() -> void:
	_say("=== J/K) 死亡画面 + 掉落机制 ===")
	var world := _world()
	var sys = _make_system(world)
	var troll := _cfg("ep_troll")
	var e = _spawn_at(world, Vector2(900.0, 900.0), troll, sys)
	var fp := _add_player(world)
	_glued.append([fp, e, NEAR])
	await _phys(3)
	_check(e._attack_timer > 0.0, "（前置）活着时确实在打人")

	var tex_before = e._body.texture
	var n_dead := _frames(troll, "dead")
	var hits_at_death := int(fp.hits)
	var loot_at_death := _loot_count()
	e.take_damage(int(e.max_hp) * 99)
	_check(e._dying, "致死伤害 → _dying（AI/受伤/出手全部停摆）")
	_check(_loot_count() == loot_at_death + 1,
			"死亡当场结算掉落（全局 enemy.drop.chance=%s）"
			% str((Config.get_value("enemy.drop", {}) as Dictionary).get("chance", "?")))
	e.take_damage(int(e.max_hp) * 99)
	_check(_loot_count() == loot_at_death + 1, "重复结算不会掉第二份")
	await _phys(2)
	_check(is_instance_valid(e), "死亡帧还在播 → 暂时仍在场景里（不是秒删）")
	_check(e._body.texture == e._death_frames[0] and e._body.texture != tex_before,
			"%d 帧死亡动画已上身体（贴图已换 = 玩家看得见「倒下」）" % n_dead)
	await _phys(4)
	_check(int(fp.hits) == hits_at_death, "倒地过程中不再打人（hits 不变）")

	var die_frames := _sec_frames(float(n_dead)
			/ maxf(float(Config.get_value("enemy.death_fps", 8.0)), 1.0)) \
			+ _sec_frames(float(Config.get_value("enemy.death_fade_seconds", 0.45))) + 20
	await _phys(die_frames)
	_check(not is_instance_valid(e), "死帧播完 + 淡出结束 → 离场（等 %d 帧）" % die_frames)

	# 没有 dead 帧的兵种：_die() 直接进淡出，同样必须离场
	var c = _spawn_at(world, Vector2(1600.0, 900.0), _cfg("ep_cave"), sys)
	_check(_frames(_cfg("ep_cave"), "dead") == 0, "ep_cave 无死亡帧 → 走淡出分支")
	c.take_damage(int(c.max_hp) * 99)
	await _phys(3)
	_check(is_instance_valid(c), "淡出期间仍在场景（0.45s 的透明+缩小+下沉）")
	await _phys(_sec_frames(float(Config.get_value("enemy.death_fade_seconds", 0.45))) + 12)
	_check(not is_instance_valid(c), "淡出结束 → 离场")

	# K) 掉落 = 纯 config 驱动，兵种能覆盖全局表（"具体掉落表后面加"的落点）
	var g: Dictionary = Config.get_value("enemy.drop", {})
	_check(float(g.get("chance", 0.0)) > 0.0
			and (g.get("weights", {}) as Dictionary).size() > 0,
			"全局 enemy.drop 有 chance 与 weights（amount %s~%s）"
			% [str(g.get("amount_min", "?")), str(g.get("amount_max", "?"))])
	var before := _loot_count()
	var e_never = _spawn_at(world, Vector2(2200.0, 2200.0),
			_cfg_with("ep_lizard", {"drop": {"chance": 0.0}}), sys)
	e_never.take_damage(99999)
	await _phys(6)
	_check(_loot_count() == before, "兵种 drop.chance=0 → 一只不掉（覆盖口子生效）")

	before = _loot_count()
	var e_fixed = _spawn_at(world, Vector2(2600.0, 2200.0), _cfg_with("ep_lizard", {"drop": {
		"chance": 1.0, "amount_min": 5, "amount_max": 5, "weights": {"gold": 1}}}), sys)
	e_fixed.take_damage(99999)
	await _phys(6)
	var loot: Array = get_tree().get_nodes_in_group("loot_nodes")
	_check(loot.size() == before + 1, "必掉表生效：击杀后地面多 1 个战利品（实得 %d）"
			% (loot.size() - before))
	if loot.size() > before:
		var d = loot[loot.size() - 1]
		_check(str(d.resource_id) == "gold",
				"种类 = 兵种表里写的 gold（实得 %s）" % str(d.resource_id))
		_check(int(d._amount) == 5, "数量 = 兵种表的 amount_min/max（实得 %d）" % int(d._amount))
	await _teardown(world, sys)

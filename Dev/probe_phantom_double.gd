extends Node
## ============================================================
## probe_phantom_double — 弓手「幻影分身」（phantom_double）特性验证（headless 可跑）
##
## 用户 2026-09-17 定的**最终规格**（同日把早先的「共享血池」版本改掉了）：
##   「每个只随机召唤一到两个，召唤的分身只有本体20%的血量，分身不会再召唤分身，
##     本体每隔5秒会再随机召唤1到2个，最多8个分身，分身越多，自身受到伤害越少」
##   ＋「这批角色（本体加召唤）按最低血条展示，不管攻击哪个，显示血条最低的，迷惑玩家」
##
## 逐条对应到断言：
##   随机召唤 1-2 个分身      → B 段：进队列数量落在 [count_min, count_max]，一个一个出来
##   分身只有本体 20% 的血     → B/D 段：分身 max_hp = 本体 max_hp × hp_ratio_of_owner
##   分身不会再召唤分身        → B 段：出齐后队列清空，再等也不会繁殖
##   本体每隔 5 秒补召 1-2 个  → N 段：把间隔 override 到 0.2s 快进，验"会持续补"
##   最多 8 个分身             → N 段：补到 8 具就停，队列也空着
##   分身越多本体受伤越少      → P 段：per_phantom × 活分身数，封顶 max_reduction
##   分身无法造成伤害          → D 段：分身 damage = 0，撞玩家一滴血都不掉（本体照常打）
##   每掉 20% 换一次位         → E 段：80% / 60% / 40% 各换一次，同台阶内重复挨打不换
##   整组按最低血条展示        → D 段：本体+分身算一组，统一显示 min(组内 hp)/本体 max_hp
##                              （分身天生只有 20% 血 ⇒ 场上一有分身，整组条就是残血样）
##
## 另外验：
##   A) config 真值：弓手带 1 个特性；其它兵种特性互不干扰；全局 phantom 段存在
##   C) 一个一个出来（不是一帧冒两个）
##   E2) 没有分身时不换位（台阶照样记账，但不攒着事后连闪）
##   F) 本体死亡 → 分身一起消失（不掉落、不报死亡特性）
##   G) 记账口径：分身不进 _live_split_count() ／不参与数量缩放（对照：特性刷出来的要进）
##   H) 无特性兵种不受影响（但它们也共用血条这个通用件）
##   I) 全局开关：enemy_traits.phantom.enabled / max_live_phantoms
##
## 为什么 headless 能跑：全是数值 + 事件逻辑，不依赖渲染（血条只验内部 ratio/显隐状态，
## 不验像素）。
## 注：本探针不加载 Main.tscn，自己搭最小 A* 网格 + 独立 EnemySystem。
##     **每段用完把 world/sys 拆掉再等 2 帧** —— 幻影分身的计数口径（_live_phantom_count /
##     _pending_phantom_count / _live_split_count / featured_enemy_count）都是扫全局
##     enemies 组 / _pending 队列的，不拆干净会串台。
## 注 2：`_feat1()` 默认带 `"damage_reduction": {}`（空 = 不减伤）——
##     否则「分身越多越硬」会污染换位段（E）里按整数点算的 20% 台阶。
## ============================================================

const OUT := "user://_probe_phantom_double.txt"
const ENEMY_SYS := preload("res://Scripts/enemy_system.gd")
const ENEMY_SCENE := preload("res://Scenes/Enemy.tscn")
const TILE := 64
const FPS := 60.0

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _walls: Array = []


## 假玩家：只为验「近战出手有没有真的打进来」。真实 Player 太重（要贴图/状态机/小队）。
class FakePlayer extends Area2D:
	var hp := 100
	func take_damage(amount: int, _from: Vector2) -> bool:
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


## 等够一次刷怪间隔（外加余量），让队列里排着的幻影真的出生
func _wait_spawn(sec: float) -> void:
	await _phys(int(ceil(maxf(0.0, sec) * FPS)) + 4)


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


## 某个兵种配置的深拷贝（改它不会污染 Config）
func _cfg(id: String) -> Dictionary:
	for t in Config.get_value("enemy_types.types", []):
		if t is Dictionary and str((t as Dictionary).get("id", "")) == id:
			return (t as Dictionary).duplicate(true)
	return {}


## 复制一份兵种配置并换成**单数 trait**（测某个具体特性配置时用）。
## 必须先摘掉 traits 池：代码里池优先于单数 trait，不摘会被整个盖掉。
func _with_feat(base: Dictionary, feat: Dictionary) -> Dictionary:
	var c := base.duplicate(true)
	c.erase("traits")
	c["trait"] = feat
	return c


## 固定「只召 1 具」的特性配置 —— 让绝大多数断言不受"随机 1~2"的干扰。
## damage_reduction 默认给空字典 = 不参与减伤（免得污染换位段的整数台阶）。
func _feat1(extra: Dictionary = {}) -> Dictionary:
	var f := {
		"id": "phantom_double",
		"name": "幻影分身",
		"count_min": 1,
		"count_max": 1,
		"max_phantoms_per_owner": 8,
		"hp_ratio_of_owner": 0.2,
		"resummon_interval_seconds": -1.0,
		"spawn_radius_px": 96.0,
		"spawn_interval_seconds": 0.15,
		"swap_hp_step_ratio": 0.2,
		"drop_from_splits": false,
		"damage_reduction": {},
	}
	for k in extra:
		f[k] = extra[k]
	return f


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


## 段末清理：队列清空 + 释放 world/sys，并等 2 帧让 queue_free 真正落地。
## 不这么做的话下一段的全局计数（幻影数 / 特性怪数）会被上一段的尸体搅浑。
func _teardown(world: Node2D, sys) -> void:
	if sys != null and is_instance_valid(sys):
		sys._pending.clear()
		sys.queue_free()
	if world != null and is_instance_valid(world):
		world.queue_free()
	await _phys(2)


# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------

func _ready() -> void:
	_walls = _open_walls(48)
	NoiseSystem.setup([], TILE)          # 空网格 = 无障碍（本探针不验噪音）
	NoiseSystem.reset()

	var raider := _cfg("raider")

	_config_truth(raider)
	await _summon_and_pool(raider)
	await _one_by_one(raider)
	await _no_damage_and_group_bar(raider)
	await _swap_on_hp_steps(raider)
	await _no_phantom_no_swap(raider)
	await _owner_death(raider)
	await _resummon_until_cap(raider)
	await _swarm_reduction(raider)
	await _accounting(raider)
	await _plain_enemy(raider)
	await _global_switch(raider)

	_finish()


# ------------------------------------------------------------
# A) config 真值
# ------------------------------------------------------------

func _config_truth(raider: Dictionary) -> void:
	_say("=== A) config 真值 ===")
	var pool: Array = raider.get("traits", [])
	_check(pool.size() == 1, "弓手特性池 1 项（实得 %d）" % pool.size())
	if pool.is_empty():
		return
	var f: Dictionary = pool[0]
	_check(str(f.get("id", "")) == "phantom_double",
			"特性 id = phantom_double（实得 %s）" % str(f.get("id", "")))
	_check(str(f.get("name", "")) == "幻影分身",
			"显示名 = 幻影分身（实得 %s）" % str(f.get("name", "")))
	_check(int(f.get("weight", 0)) >= 1, "weight >= 1（实得 %s）" % str(f.get("weight")))
	var lo := int(f.get("count_min", 0))
	var hi := int(f.get("count_max", 0))
	_check(lo == 1 and hi == 2, "随机召唤 1~2 个分身（实得 %d~%d）" % [lo, hi])
	_check(int(f.get("max_phantoms_per_owner", 0)) == 8,
			"单只本体最多 8 具分身（实得 %s）" % str(f.get("max_phantoms_per_owner")))
	_check(is_equal_approx(float(f.get("hp_ratio_of_owner", 0.0)), 0.2),
			"分身血量 = 本体 20%%（实得 %s）" % str(f.get("hp_ratio_of_owner")))
	_check(is_equal_approx(float(f.get("resummon_interval_seconds", 0.0)), 5.0),
			"本体每 5 秒补召一次（实得 %s）" % str(f.get("resummon_interval_seconds")))
	_check(float(f.get("spawn_radius_px", 0.0)) > 0.0,
			"召唤半径 > 0（实得 %s）" % str(f.get("spawn_radius_px")))
	_check(float(f.get("spawn_interval_seconds", 0.0)) > 0.0,
			"有召唤间隔 ⇒ 分身一个一个出来（实得 %s）" % str(f.get("spawn_interval_seconds")))
	_check(is_equal_approx(float(f.get("swap_hp_step_ratio", 0.0)), 0.2),
			"每掉 20%% 血换一次位（实得 %s）" % str(f.get("swap_hp_step_ratio")))
	_check(not bool(f.get("drop_from_splits", true)), "分身不掉落")
	# 分身越多本体越硬
	var dr = f.get("damage_reduction", {})
	_check(dr is Dictionary and not (dr as Dictionary).is_empty(),
			"有 damage_reduction 子段（分身越多本体受伤越少）")
	if dr is Dictionary and not (dr as Dictionary).is_empty():
		_check(float((dr as Dictionary).get("per_phantom", 0.0)) > 0.0, "per_phantom > 0")
		_check(float((dr as Dictionary).get("max_reduction", 0.0)) > 0.0, "max_reduction > 0")

	var sc: Dictionary = Config.get_value("enemy_traits.phantom", {})
	_check(not sc.is_empty(), "有全局 enemy_traits.phantom")
	_check(typeof(sc.get("enabled")) == TYPE_BOOL, "全局开关是布尔键")
	_check(int(sc.get("max_live_phantoms", -1)) > 0,
			"全局兜底 max_live_phantoms > 0（实得 %s）" % str(sc.get("max_live_phantoms")))

	# 别的兵种不受影响
	_check(_cfg("brigand").get("traits", []).is_empty()
			and not _cfg("brigand").has("trait"), "劫掠者仍然没有特性")
	_check(_cfg("cultist").get("traits", []).size() == 1
			and str(_cfg("cultist")["traits"][0].get("id", "")) == "burst_drum",
			"邪术师仍是爆裂鼓手（没被覆盖）")
	_check(_cfg("marauder").get("traits", []).size() == 2, "掠夺者仍是两个特性")


# ------------------------------------------------------------
# B) 召唤 + 记账池 + 分身血量
# ------------------------------------------------------------

func _summon_and_pool(raider: Dictionary) -> void:
	_say("")
	_say("=== B) 随机召唤 1~2 具 + 共享记账池 + 分身 20% 血 ===")
	var world := _world()
	var sys = _make_system(world)
	var o = _spawn_at(world, Vector2(400.0, 400.0), raider, sys)

	_check(str(o.feature_id()) == "phantom_double",
			"弓手必定分到幻影分身（实得 %s）" % str(o.feature_id()))
	_check(not bool(o.is_phantom()), "开局这只是本体，不是分身")
	var queued := int(sys.pending_split_count())
	_check(queued >= 1 and queued <= 2, "召唤 1~2 具进队列（实得 %d）" % queued)

	# 真配置的召唤间隔是 0.15s/具，且 count 可能随机到 2 → 等够两具都出来的时间
	await _wait_spawn(0.45)
	var ph: Array = o.live_phantoms()
	_check(ph.size() == queued,
			"分身出齐（实得 %d / 队列 %d）" % [ph.size(), queued])
	if ph.is_empty():
		await _teardown(world, sys)
		return
	var p = ph[0]
	_check(bool(p.is_phantom()), "分身的 is_phantom() = true")
	_check(str(p.type_id) == "raider", "分身也是弓手（同一兵种配置）")
	_check(p.is_in_group("enemies"), "分身进 enemies 组（玩家能打它）")

	# 分身自己那一份血 = 本体 max_hp × 20%（全局 hp_ratio_of_owner）
	var expect := maxi(1, int(round(float(o.max_hp) * 0.2)))
	_check(int(p.max_hp) == expect,
			"分身血量 = 本体 20%%（本体 %d → 分身 %d，期望 %d）"
			% [int(o.max_hp), int(p.max_hp), expect])
	_check(int(p.hp) == int(p.max_hp), "分身出生满血（%d/%d）" % [int(p.hp), int(p.max_hp)])

	# 池是**同一个 Dictionary 实例**（引用语义）——只用于记账 / 血条广播
	var pool_a: Dictionary = o.phantom_pool()
	var pool_b: Dictionary = p.phantom_pool()
	_check(not pool_a.is_empty() and not pool_b.is_empty(), "本体与分身都有池")
	pool_a["__probe_mark"] = 7
	_check(pool_b.has("__probe_mark"),
			"分身与本体指向**同一个池实例**（改一个另一个看得见）")
	pool_a.erase("__probe_mark")

	# 分身不再召唤：出齐后队列应当已经空了，且不会因为"分身出生"再排东西
	_check(int(sys.pending_split_count()) == 0, "分身出生后队列已清空（分身不再召唤）")
	await _phys(4)
	_check(int(sys.pending_split_count()) == 0 and o.live_phantoms().size() == queued,
			"再等几帧也没有新分身（不会指数繁殖）")

	# 名额：单只本体的 max_phantoms_per_owner 会因为 count_max=2 而远达不到，
	# 这里只验"没超过上限"
	_check(o.live_phantoms().size() <= 8, "分身数不超过单只上限 8")
	await _teardown(world, sys)


# ------------------------------------------------------------
# C) 一个一个出来（不是一帧冒两个）
# ------------------------------------------------------------

func _one_by_one(raider: Dictionary) -> void:
	_say("")
	_say("=== C) 分身是一个一个出来的 ===")
	var world := _world()
	var sys = _make_system(world)
	var cfg2 := _with_feat(raider, _feat1({"count_min": 2, "count_max": 2}))
	var o = _spawn_at(world, Vector2(300.0, 300.0), cfg2, sys)
	_check(int(sys.pending_split_count()) == 2, "固定 2 具进队列（实得 %d）" % int(sys.pending_split_count()))

	await _phys(4)      # ≈0.067s < 0.15s
	_check(int(sys.pending_split_count()) == 2 and o.live_phantoms().size() == 0,
			"不到间隔不出（队列 2、场上 0）")
	await _phys(8)      # ≈0.2s > 0.15s
	_check(int(sys.pending_split_count()) == 1 and o.live_phantoms().size() == 1,
			"第 1 具出来（队列 %d、场上 %d）"
			% [int(sys.pending_split_count()), o.live_phantoms().size()])
	await _phys(10)     # ≈0.37s > 0.30s
	_check(int(sys.pending_split_count()) == 0 and o.live_phantoms().size() == 2,
			"第 2 具随后出来（队列 %d、场上 %d）"
			% [int(sys.pending_split_count()), o.live_phantoms().size()])
	await _teardown(world, sys)


# ------------------------------------------------------------
# D) 分身不造成伤害 + 各自一份血 + 整组按最低血条显示
# ------------------------------------------------------------

func _no_damage_and_group_bar(raider: Dictionary) -> void:
	_say("")
	_say("=== D) 分身不造成伤害 + 独立血 + 整组按最低血条显示 ===")
	var world := _world()
	var sys = _make_system(world)
	var o = _spawn_at(world, Vector2(400.0, 900.0), _with_feat(raider, _feat1()), sys)
	await _wait_spawn(0.15)
	var ph: Array = o.live_phantoms()
	_check(ph.size() == 1, "1 具分身就位（实得 %d）" % ph.size())
	if ph.is_empty():
		await _teardown(world, sys)
		return
	var p = ph[0]
	o.set_physics_process(false)      # 钉住位置/状态，免得巡逻把断言搅乱
	p.set_physics_process(false)

	# ① 近战出手：本体打得到，分身一点都打不到
	# 接触伤害（body_entered）已删 —— 这里改走真实路径 _start_attack() → _deal_attack_damage()。
	# 直接调这两个函数、跳过前摇计时器：本段验的是"谁能造成伤害"，
	# "射程/前摇/冷却的数值对不对"由 Dev/probe_enemy_attack.gd 守。
	var fp := FakePlayer.new()
	world.add_child(fp)
	fp.add_to_group("player")
	fp.global_position = o.global_position + Vector2(o.attack_range_px() - 6.0, 0.0)
	_check(o.in_attack_range(), "玩家在射程内 → 判定为可出手")
	var owner_dmg := int(o.damage)
	o._attack_cooldown = 0.0
	o._start_attack()
	o._deal_attack_damage()
	_check(fp.hp == 100 - owner_dmg, "本体出手 → 掉 %d 血（实得掉 %d）"
			% [owner_dmg, 100 - int(fp.hp)])
	var hp_after_owner := int(fp.hp)
	p._attack_cooldown = 0.0
	p._start_attack()
	p._deal_attack_damage()
	_check(int(fp.hp) == hp_after_owner,
			"分身出手 → 一滴血都不掉（实得掉 %d）" % (hp_after_owner - int(fp.hp)))
	_check(int(p.damage) == 0, "分身的 damage 被清零（实得 %d）" % int(p.damage))

	# ② 打分身 = 只扣分身自己那份血，本体一滴不掉（2026-09-17 从"转嫁本体"改掉）
	var full := int(o.max_hp)
	var share := int(p.max_hp)
	_check(share < full, "分身比本体脆（%d < %d）" % [share, full])
	var owner_before := int(o.hp)
	p.take_damage(2)
	_check(int(p.hp) == share - 2,
			"打分身 → 扣分身自己的血（%d → %d）" % [share, int(p.hp)])
	_check(int(o.hp) == owner_before,
			"本体血量纹丝不动（%d）—— 独立血，不再转嫁" % int(o.hp))

	# ③ 整组按最低血条显示：分身只有 20% 血 ⇒ 连满血本体的条也一起变短
	_check(o.display_hp_ratio() < 0.5,
			"有分身时整组血条被拉到残血区间（%.2f）" % o.display_hp_ratio())
	_check(is_equal_approx(o._hp_bar.ratio(), p._hp_bar.ratio()),
			"本体与分身显示同一条血（%.2f / %.2f）"
			% [float(o._hp_bar.ratio()), float(p._hp_bar.ratio())])
	_check(is_equal_approx(float(o._hp_bar.ratio()), o.display_hp_ratio()),
			"血条长度 = display_hp_ratio()（不是自己的 hp_ratio）")
	_check(is_equal_approx(o.display_hp_ratio(), float(int(p.hp)) / float(full)),
			"整组显示 = 组内最低（分身 %d / 本体 %d）" % [int(p.hp), int(o.hp)])

	# ④ 本体掉血 → 整组条跟着刷新（即使分身没挨打）
	o.take_damage(4)
	_check(int(o.hp) == owner_before - 4,
			"本体挨 4 点 → %d（实得 %d）" % [owner_before - 4, int(o.hp)])
	_check(int(p.hp) == share - 2, "分身血量不受本体影响（仍是 %d）" % int(p.hp))
	_check(bool(o._hp_bar.is_showing()) and bool(p._hp_bar.is_showing()),
			"本体挨打 → 两边血条都亮")

	# ⑤ 分身被打光 → 自己消失，本体照常
	p.take_damage(999)
	_check(bool(p.get("_dying")), "分身血量打光 → 进入消失")
	_check(not bool(o.get("_dying")), "本体照常活着（不会跟着死）")
	_check(o.live_phantoms().is_empty(), "活分身清零")
	o.set_physics_process(false)
	_check(is_equal_approx(o.display_hp_ratio(), o.hp_ratio()),
			"分身没了 → 整组显示回落到本体自己的比例")
	await _teardown(world, sys)


# ------------------------------------------------------------
# E) 每掉 20% 血换一次位
# ------------------------------------------------------------

func _swap_on_hp_steps(raider: Dictionary) -> void:
	_say("")
	_say("=== E) 本体每掉 20%% 血 → 随机和分身互换位置 ===")
	var world := _world()
	var sys = _make_system(world)
	var o = _spawn_at(world, Vector2(500.0, 1500.0), _with_feat(raider, _feat1()), sys)
	await _wait_spawn(0.15)
	var ph: Array = o.live_phantoms()
	_check(ph.size() == 1, "1 具分身就位（实得 %d）" % ph.size())
	if ph.is_empty():
		await _teardown(world, sys)
		return
	var p = ph[0]
	o.set_physics_process(false)
	p.set_physics_process(false)
	var full := int(o.max_hp)
	var step_px := float(full) * 0.2          # 30 血 → 每 6 点一个台阶

	# 钉死两边位置：只有 1 具分身，所以"随机挑一个"必然挑到它
	# 注：本段 feat 的 damage_reduction 为空 ⇒ 本体挨多少就是多少，台阶按整数算得准
	var A := Vector2(1000.0, 1500.0)
	var B := Vector2(1200.0, 1500.0)
	o.global_position = A
	p.global_position = B

	o.take_damage(int(step_px))               # → 80%
	_check(o.global_position.is_equal_approx(B), "掉到 80%% → 本体换到分身的位置")
	_check(p.global_position.is_equal_approx(A), "分身换到本体原来的位置")
	_check(int(o.get("_swap_step")) == 1, "台阶计数 = 1（实得 %d）" % int(o.get("_swap_step")))
	_check(o.get("_home") == o.global_position, "本体的巡逻中心跟着挪（不会走回老窝）")
	_check(p.get("_home") == p.global_position, "分身的巡逻中心跟着挪")

	var now: Vector2 = o.global_position
	o.take_damage(1)                          # 仍未跨过下一个台阶
	_check(o.global_position.is_equal_approx(now), "同一台阶内重复挨打不换位")
	_check(int(o.get("_swap_step")) == 1, "台阶计数不变（实得 %d）" % int(o.get("_swap_step")))

	o.take_damage(int(step_px) - 1)           # → 60%
	_check(o.global_position.is_equal_approx(A), "掉到 60%% → 又换回来")
	_check(p.global_position.is_equal_approx(B), "分身跟着回去")
	_check(int(o.get("_swap_step")) == 2, "台阶计数 = 2（实得 %d）" % int(o.get("_swap_step")))

	o.take_damage(int(step_px))               # → 40%
	_check(int(o.get("_swap_step")) == 3, "台阶计数 = 3（实得 %d）" % int(o.get("_swap_step")))
	o.take_damage(int(step_px))               # → 20%
	_check(int(o.get("_swap_step")) == 4, "台阶计数 = 4（实得 %d）" % int(o.get("_swap_step")))
	_check(o.global_position.is_equal_approx(A) or o.global_position.is_equal_approx(B),
			"换位只在两者之间发生（位置没有跑飞）")
	await _teardown(world, sys)


# ------------------------------------------------------------
# E2) 没有分身时不换位（台阶照样记账，但不攒着事后连闪）
# ------------------------------------------------------------

func _no_phantom_no_swap(raider: Dictionary) -> void:
	_say("")
	_say("=== E2) 没有分身可换时：不换位、台阶照记 ===")
	var world := _world()
	var sys = _make_system(world)
	var cfg0 := _with_feat(raider, _feat1({"count_min": 0, "count_max": 0}))
	var o = _spawn_at(world, Vector2(600.0, 2100.0), cfg0, sys)
	await _phys(6)
	_check(int(sys.pending_split_count()) == 0 and o.live_phantoms().is_empty(),
			"count 0 → 一具分身都不召")
	o.set_physics_process(false)
	var at: Vector2 = o.global_position
	o.take_damage(int(o.max_hp) * 2 / 5)      # 掉 40% → 跨 2 个台阶
	_check(o.global_position.is_equal_approx(at), "没有分身 → 位置原地不动")
	_check(int(o.get("_swap_step")) == 2,
			"台阶照样记账 = 2（实得 %d）—— 之后有分身也不会补闪" % int(o.get("_swap_step")))
	await _teardown(world, sys)


# ------------------------------------------------------------
# F) 本体死亡 → 分身一起消失
# ------------------------------------------------------------

func _owner_death(raider: Dictionary) -> void:
	_say("")
	_say("=== F) 本体倒下 → 幻影一并消失 ===")
	var world := _world()
	var sys = _make_system(world)
	var o = _spawn_at(world, Vector2(700.0, 2700.0), _with_feat(raider, _feat1()), sys)
	await _wait_spawn(0.15)
	var ph: Array = o.live_phantoms()
	_check(ph.size() == 1, "1 具分身就位（实得 %d）" % ph.size())
	if ph.is_empty():
		await _teardown(world, sys)
		return
	var p = ph[0]
	_check(not bool(p.get("_dying")), "分身此刻活着")
	o.take_damage(9999)
	_check(bool(o.get("_dying")), "本体被打死")
	_check(bool(p.get("_dying")), "分身随本体一起进入消失")
	_check(o.live_phantoms().is_empty(), "活着的幻影清零")
	_check(not bool(p._hp_bar.is_showing()), "分身血条随之隐藏")
	await _phys(2)
	await _teardown(world, sys)


# ------------------------------------------------------------
# N) 本体每隔一段时间补召 1~2 具；单只最多 8 具
# ------------------------------------------------------------

func _resummon_until_cap(raider: Dictionary) -> void:
	_say("")
	_say("=== N) 补召节拍 + 单只 8 具上限 ===")
	var world := _world()
	var sys = _make_system(world)
	# 真配置是 5 秒一次，探针里 override 到 0.2s 快进（同一套代码路径，只是数不同）
	var cfg := _with_feat(raider, _feat1({
		"count_min": 2, "count_max": 2,
		"resummon_interval_seconds": 0.2,
		"spawn_interval_seconds": 0.02,
	}))
	var o = _spawn_at(world, Vector2(400.0, 3300.0), cfg, sys)
	await _wait_spawn(0.06)
	_check(o.live_phantoms().size() + int(sys.pending_split_count()) == 2,
			"开局只召 2 具（场上 %d + 队列 %d）"
			% [o.live_phantoms().size(), int(sys.pending_split_count())])

	await _wait_spawn(1.6)                    # 够跑好几轮补召
	var n: int = o.live_phantoms().size()
	_check(n == 8, "补召到单只上限 8 具就停（实得 %d）" % n)
	_check(int(sys.pending_split_count()) == 0, "满了之后队列也空着（不再排队）")
	await _wait_spawn(0.5)
	_check(o.live_phantoms().size() == 8,
			"再等也不再增加（实得 %d）" % o.live_phantoms().size())

	# 名额算法本身：活着的 + 队列里没出生的一起算
	_check(int(sys.phantom_slots_left(o, cfg["trait"])) == 0, "名额已用尽（slots_left = 0）")
	# 杀掉 3 具 → 名额空出来，本体下一拍又会补回来（补召不是"只补一次"）
	var killed := 0
	for i in range(3):
		var alive: Array = o.live_phantoms()
		if alive.is_empty():
			break
		alive[0].take_damage(9999)
		killed += 1
	await _phys(2)
	_check(killed == 3, "打死 3 具分身（实得 %d）" % killed)
	await _wait_spawn(0.6)
	_check(o.live_phantoms().size() == 8,
			"名额空出来后本体补回满额 8 具（实得 %d）" % o.live_phantoms().size())
	await _teardown(world, sys)


# ------------------------------------------------------------
# P) 分身越多，本体受到的伤害越少
# ------------------------------------------------------------

func _swarm_reduction(raider: Dictionary) -> void:
	_say("")
	_say("=== P) 分身越多，本体受到的伤害越少 ===")
	var world := _world()
	var sys = _make_system(world)
	var dr := {"per_phantom": 0.1, "max_reduction": 0.5, "min_damage": 1}

	# 甲：1 具分身 → 减伤 0.1
	var a = _spawn_at(world, Vector2(600.0, 3900.0), _with_feat(raider, _feat1({
		"count_min": 1, "count_max": 1,
		"resummon_interval_seconds": 0.0,
		"spawn_interval_seconds": 0.02,
		"damage_reduction": dr,
	})), sys)
	a.set_physics_process(false)
	_check(is_equal_approx(a.phantom_damage_reduction(), 0.0),
			"还没分身时减伤 0（实得 %.2f）" % a.phantom_damage_reduction())
	_check(a.incoming_damage(10) == 10, "没分身时挨 10 点就是 10 点")
	a.set_physics_process(true)
	await _wait_spawn(0.1)
	_check(a.live_phantoms().size() == 1, "甲就位 1 具（实得 %d）" % a.live_phantoms().size())
	a.set_physics_process(false)
	_check(is_equal_approx(a.phantom_damage_reduction(), 0.1),
			"1 具 × 0.1 = 0.1（实得 %.2f）" % a.phantom_damage_reduction())
	var hp_a := int(a.hp)
	a.take_damage(10)
	_check(hp_a - int(a.hp) == 9, "挨 10 点只掉 9 点（实得 %d）" % (hp_a - int(a.hp)))

	# 乙：6 具分身 → 0.6 但被 max_reduction 0.5 封顶
	var b = _spawn_at(world, Vector2(900.0, 3900.0), _with_feat(raider, _feat1({
		"count_min": 6, "count_max": 6,
		"resummon_interval_seconds": 0.0,
		"spawn_interval_seconds": 0.02,
		"damage_reduction": dr,
	})), sys)
	b.set_physics_process(true)
	await _wait_spawn(0.15)
	_check(b.live_phantoms().size() == 6, "乙就位 6 具（实得 %d）" % b.live_phantoms().size())
	b.set_physics_process(false)
	_check(is_equal_approx(b.phantom_damage_reduction(), 0.5),
			"6 × 0.1 = 0.6 → 封顶 0.5（实得 %.2f）" % b.phantom_damage_reduction())
	var hp_b := int(b.hp)
	b.take_damage(10)
	_check(hp_b - int(b.hp) == 5, "挨 10 点只掉 5 点（实得 %d）" % (hp_b - int(b.hp)))

	# 分身自己不吃这条减伤（只有本体算）
	var phb: Array = b.live_phantoms()
	if not phb.is_empty():
		_check(is_equal_approx(phb[0].phantom_damage_reduction(), 0.0),
				"分身自己不吃这条减伤（实得 %.2f）" % phb[0].phantom_damage_reduction())

	# 1 点保底：伤害再大也扣得掉血（不会无敌）
	var before := int(b.hp)
	b.take_damage(1)
	_check(before - int(b.hp) >= 1, "1 点伤害保底（实得掉 %d）" % (before - int(b.hp)))

	# 分身清空 → 减伤回落
	for m in b.live_phantoms():
		m.take_damage(9999)
	await _phys(4)
	_check(is_equal_approx(b.phantom_damage_reduction(), 0.0),
			"分身清空 → 减伤回落到 0（实得 %.2f）" % b.phantom_damage_reduction())
	await _teardown(world, sys)


# ------------------------------------------------------------
# G) 记账口径：分身不算「特性刷出来的活口」、不参与数量缩放
# ------------------------------------------------------------

func _accounting(raider: Dictionary) -> void:
	_say("")
	_say("=== G) 记账口径（数量缩放 / max_live_split_enemies）===")
	var world := _world()
	var sys = _make_system(world)
	sys._pop_hold = 0.0
	var base_split := int(sys._live_split_count())
	var o = _spawn_at(world, Vector2(800.0, 4400.0), _with_feat(raider, _feat1()), sys)
	sys._pop_hold = 0.0
	var pop0 := int(sys.featured_enemy_count())
	_check(not bool(o.counts_toward_population()),
			"弓手不参与数量缩放（它没写 chance_max）")
	await _wait_spawn(0.15)
	_check(o.live_phantoms().size() == 1, "分身就位")
	_check(int(sys._live_split_count()) == base_split,
			"分身不计入 _live_split_count（%d → %d）—— 不挤占掠夺者的名额"
			% [base_split, int(sys._live_split_count())])
	sys._pop_hold = 0.0
	_check(int(sys.featured_enemy_count()) == pop0,
			"分身也不进特性怪总数（%d → %d）" % [pop0, int(sys.featured_enemy_count())])

	# 对照：真的「特性刷出来的个体」是要计入的
	var fake = ENEMY_SCENE.instantiate()
	world.add_child(fake)
	fake.position = Vector2(850.0, 4400.0)
	fake.setup(_walls, TILE, sys._astar, _cfg("marauder"), {}, sys,
			{"id": "death_split", "stages": []})
	_check(int(sys._live_split_count()) == base_split + 1,
			"对照：特性刷出来的个体**要**计入（%d → %d）"
			% [base_split, int(sys._live_split_count())])
	await _teardown(world, sys)


# ------------------------------------------------------------
# H) 无特性兵种不受影响（但共用血条这个通用件）
# ------------------------------------------------------------

func _plain_enemy(raider: Dictionary) -> void:
	_say("")
	_say("=== H) 无特性兵种不受影响 ===")
	var world := _world()
	var sys = _make_system(world)
	var b = _spawn_at(world, Vector2(900.0, 4900.0), _cfg("brigand"), sys)
	_check(not bool(b.has_feature()), "劫掠者没有特性")
	_check(not bool(b.is_phantom()), "也不是分身")
	_check(int(sys.pending_split_count()) == 0, "不召唤任何东西")
	b.set_physics_process(false)
	var full := int(b.max_hp)
	b.take_damage(5)
	_check(int(b.hp) == full - 5, "挨 5 点就是 5 点（实得掉 %d）" % (full - int(b.hp)))
	_check(bool(b._hp_bar.is_showing()), "普通敌人也用血条（通用件，不是弓手专属）")
	_check(is_equal_approx(float(b._hp_bar.ratio()), b.hp_ratio()),
			"血条长度 = 自己的血量比例")
	await _teardown(world, sys)


# ------------------------------------------------------------
# I) 全局开关
# ------------------------------------------------------------

func _global_switch(raider: Dictionary) -> void:
	_say("")
	_say("=== I) 全局开关 enemy_traits.phantom ===")
	var world := _world()
	var sys = _make_system(world)

	Config.set_override("enemy_traits.phantom.enabled", false)
	_spawn_at(world, Vector2(1000.0, 5400.0), raider, sys)
	_check(int(sys.pending_split_count()) == 0,
			"enabled = false → 弓手照常刷，但不召唤分身（队列 %d）"
			% int(sys.pending_split_count()))
	Config.clear_override("enemy_traits.phantom.enabled")
	var o = _spawn_at(world, Vector2(1100.0, 5400.0), raider, sys)
	_check(int(sys.pending_split_count()) >= 1,
			"还原开关 → 恢复召唤（队列 %d）" % int(sys.pending_split_count()))

	# max_live_phantoms：场上已经有幻影时，新的召唤被压到 0
	await _wait_spawn(0.15)
	var live := int(sys._live_phantom_count())
	_check(live >= 1, "第一只弓手的幻影已经出生（%d 具）" % live)
	Config.set_override("enemy_traits.phantom.max_live_phantoms", live)
	var sys2_before := int(sys.pending_split_count())
	_spawn_at(world, Vector2(1200.0, 5400.0), raider, sys)
	_check(int(sys.pending_split_count()) == sys2_before,
			"达到 max_live_phantoms 上限 → 不再排队（%d → %d）"
			% [sys2_before, int(sys.pending_split_count())])
	Config.clear_override("enemy_traits.phantom.max_live_phantoms")
	_check(o != null, "（占位）本体实例仍在")
	await _teardown(world, sys)


# ------------------------------------------------------------

func _finish() -> void:
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_phantom_double] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

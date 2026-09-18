extends Node
## ============================================================
## probe_cultist_trait — 邪术师「爆裂鼓手」（burst_drum）特性验证（headless 可跑）
##
## 用户 2026-09-17 定：「邪术师，特性是爆裂鼓手，会放大玩家造成的噪音，
## 同时血量越低，受到的伤害越少。」= **一个特性、两个持续效果**（都不是死亡触发）：
##
##   noise_amplify     放大**小队自己**造成的噪音。以发声点为中心、radius_px 为半径，
##                     每个活着的邪术师按距离线性加权贡献 per_enemy 的增幅，多只叠加，
##                     总倍率夹在 enemy_traits.noise_amplify.max_multiplier 之内。
##                     只放大 from_player=true 的发声 —— 敌人自己的呼喊不放大。
##   damage_reduction  血量越低受到的伤害越少：
##                     减伤 = max_reduction × (1 − hp/max_hp)^exponent，
##                     并有 min_damage 点保底 ⇒ 残血也打得死，不会变成无敌怪。
##
## 验的东西：
##   A) config 真值：邪术师带 1 个特性 id=burst_drum；两个子段的键齐全且取值合法；
##      全局封顶存在；其它兵种的特性互不干扰
##   B) 减伤是**纯函数**：满血不减、血越少减越多、单调、永不越过 max_reduction / 永不 100%
##   C) 减伤真的走 take_damage：满血挨满伤害、残血挨得少、残血照样能被打死
##   D) 噪音倍率：无放大器 = 1.0；贴脸 = 1+per；半径一半 ≈ 1+per/2；出半径 = 1.0；
##      多只叠加；超过封顶就被夹住
##   E) 放大只作用于**小队发声**：from_player=false 的呼喊既不动读数、也不增响
##      （用一个旁观敌人实际收到的强度，与"没有放大器时"对账）
##   F) 组登记：只有带该特性的敌人在 noise_amplifiers 组里
##   G) 与掠夺者的数量缩放**解耦**：邪术师不算进 featured_enemy_count
##   H) 没有该特性的兵种（劫掠者）完全不受影响
##   I) 全局开关：enemy_traits.noise_amplify.enabled=false 时放大整体失效
##      （用 Config override 临时改，测完还原 —— 不动磁盘上的 settings）
##
## 为什么 headless 能跑：全是数值 + 事件逻辑，不依赖渲染。
## 注：本探针不加载 Main.tscn，自己搭最小 A* 网格 + 独立 EnemySystem 实例。
##     坐标按段分区（5000+ / 9000+），免得各段的放大器互相串台。
## ============================================================

const OUT := "user://_probe_cultist_trait.txt"
const ENEMY_SYS := preload("res://Scripts/enemy_system.gd")
const ENEMY_SCENE := preload("res://Scenes/Enemy.tscn")
const TILE := 64
const AMP_GROUP := "noise_amplifiers"

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _walls: Array = []


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


# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------

func _ready() -> void:
	_walls = _open_walls(24)
	# 给噪音系统的墙体网格传**空**：本探针的放大器/旁观者都摆在小网格之外的
	# 大坐标上（9000+），传 24×24 网格会让 _has_line_of_sight() 判定越界 → 当成隔墙
	# 减半（实测收到的强度只有理论值的一半）。空网格 = 无障碍，LOS 恒真。
	# 敌人 A* 用的仍是 24×24 那份（见 _make_system）。
	NoiseSystem.setup([], TILE)
	NoiseSystem.reset()

	var cu := _cfg("cultist")
	var br := _cfg("brigand")

	_config_truth(cu)
	await _damage_reduction_pure(cu)
	await _damage_reduction_live(cu)
	await _noise_multiplier(cu)
	await _only_player_noise(cu, br)
	await _group_registration(cu, br)
	await _population_decoupled(cu)
	await _plain_enemy(cu, br)
	await _global_switch(cu)

	_finish()


# ------------------------------------------------------------
# A) config 真值
# ------------------------------------------------------------

func _config_truth(cu: Dictionary) -> void:
	_say("=== A) config 真值 ===")
	var pool: Array = cu.get("traits", [])
	_check(pool.size() == 1, "邪术师特性池 1 项（实得 %d）" % pool.size())
	if pool.is_empty():
		return
	var f: Dictionary = pool[0]
	_check(str(f.get("id", "")) == "burst_drum",
			"特性 id = burst_drum（实得 %s）" % str(f.get("id", "")))
	_check(str(f.get("name", "")) == "爆裂鼓手",
			"显示名 = 爆裂鼓手（实得 %s）" % str(f.get("name", "")))
	_check(int(f.get("weight", 0)) >= 1, "weight >= 1（实得 %s）" % str(f.get("weight")))

	var na: Dictionary = f.get("noise_amplify", {})
	_check(not na.is_empty(), "有 noise_amplify 段")
	_check(float(na.get("radius_px", 0.0)) > 0.0,
			"半径 > 0（实得 %s）" % str(na.get("radius_px")))
	_check(float(na.get("per_enemy", 0.0)) > 0.0,
			"每只增幅 > 0（实得 %s）" % str(na.get("per_enemy")))
	_check(not na.has("max_multiplier"),
			"封顶**不在**特性里（放在 enemy_traits 全局，避免多实例各说各话）")

	var dr: Dictionary = f.get("damage_reduction", {})
	_check(not dr.is_empty(), "有 damage_reduction 段")
	var mr := float(dr.get("max_reduction", 0.0))
	_check(mr > 0.0 and mr < 1.0, "max_reduction 落在 (0,1)（实得 %.2f）——不会无敌" % mr)
	_check(float(dr.get("exponent", 0.0)) > 0.0,
			"exponent > 0（实得 %s）" % str(dr.get("exponent")))
	_check(int(dr.get("min_damage", 0)) >= 1,
			"min_damage >= 1（实得 %s）" % str(dr.get("min_damage")))

	var sc: Dictionary = Config.get_value("enemy_traits.noise_amplify", {})
	_check(not sc.is_empty(), "有全局 enemy_traits.noise_amplify")
	_check(float(sc.get("max_multiplier", 0.0)) >= 1.0,
			"全局封顶 >= 1（实得 %s）" % str(sc.get("max_multiplier")))
	_check(typeof(sc.get("enabled")) == TYPE_BOOL, "全局开关是布尔键")

	# 别的兵种不受影响
	_check(_cfg("brigand").get("traits", []).is_empty()
			and not _cfg("brigand").has("trait"), "劫掠者没有特性")
	# 弓手 2026-09-17 晚加了「幻影分身」——这里要的是"没被爆裂鼓手串台"，不是"没特性"
	var ri: Array = _cfg("raider").get("traits", [])
	_check(ri.size() == 1 and str((ri[0] as Dictionary).get("id", "")) == "phantom_double",
			"弓手带的是自己的幻影分身（没被爆裂鼓手串台）")


# ------------------------------------------------------------
# B) 减伤：纯函数
# ------------------------------------------------------------

func _damage_reduction_pure(cu: Dictionary) -> void:
	_say("")
	_say("=== B) 受击减伤：纯函数（血越少减得越多）===")
	var world := _world()
	var sys = _make_system(world)
	var e = _spawn_at(world, Vector2(120.0, 120.0), cu, sys)

	_check(str(e.feature_id()) == "burst_drum",
			"邪术师必定分到爆裂鼓手（实得 %s）" % str(e.feature_id()))
	var full := int(e.max_hp)

	e.hp = full
	_check(is_equal_approx(float(e.damage_reduction_ratio()), 0.0),
			"满血 → 减伤 0（实得 %.3f）" % float(e.damage_reduction_ratio()))
	_check(int(e.incoming_damage(20)) == 20, "满血挨 20 点 = 掉 20")

	e.hp = int(full / 2)
	var r_half := float(e.damage_reduction_ratio())
	var d_half := int(e.incoming_damage(20))
	_check(r_half > 0.25 and r_half < 0.35,
			"半血 → 减伤约三成（实得 %.3f，配置 max 0.6 的一半）" % r_half)
	_check(d_half >= 13 and d_half <= 15, "半血挨 20 点 ≈ 掉 14（实得 %d）" % d_half)

	e.hp = 1
	var r_low := float(e.damage_reduction_ratio())
	var d_low := int(e.incoming_damage(20))
	_check(r_low > r_half and r_low < 0.6,
			"残血 → 减伤更多但没到 max（实得 %.3f < %.2f）"
			% [r_low, float(_cfg("cultist")["traits"][0]["damage_reduction"]["max_reduction"])])
	_check(d_low >= 7 and d_low <= 9, "残血挨 20 点 ≈ 掉 8（实得 %d）" % d_low)

	# 单调：血量越低，减伤越大（严格递减的伤害）
	var prev := 999
	var mono := true
	var at_full := true
	for hp_v in [full, int(full * 3 / 4), int(full / 2), int(full / 4), 1]:
		e.hp = hp_v
		var d := int(e.incoming_damage(100))
		if hp_v == full and d != 100:
			at_full = false
		if d > prev:
			mono = false
		prev = d
	_check(at_full, "满血不减伤（100 点进来 = 100 点进去）")
	_check(mono, "伤害随血量下降**单调不增**（越残越难磨）")

	# 永不无敌：任何血量下至少 1 点
	var never := true
	var never_max := true
	for hp_v in [full, int(full / 2), 2, 1, 0]:
		e.hp = hp_v
		if int(e.incoming_damage(1)) < 1:
			never = false
		if float(e.damage_reduction_ratio()) >= 1.0:
			never_max = false
	_check(never, "任何血量下至少挨 1 点伤害（有 min_damage 保底）")
	_check(never_max, "减伤比例永远 < 1（不会出现减伤 100% 的无敌怪）")
	await _phys(1)


# ------------------------------------------------------------
# C) 减伤：真的走 take_damage
# ------------------------------------------------------------

func _damage_reduction_live(cu: Dictionary) -> void:
	_say("")
	_say("=== C) 受击减伤：走真实的 take_damage ===")
	var world := _world()
	var sys = _make_system(world)
	var e = _spawn_at(world, Vector2(220.0, 120.0), cu, sys)
	var full := int(e.max_hp)
	_check(int(e.hp) == full, "开局满血 %d" % full)

	e.take_damage(20)
	_check(int(e.hp) == full - 20, "满血挨 20 点 → 掉 20（实得掉 %d）" % (full - int(e.hp)))

	# 残血：1 点伤害进来只掉 1 点（保底），并且还没死
	e.hp = 2
	e.take_damage(1)
	_check(int(e.hp) == 1 and not bool(e.get("_dying")),
			"残血挨 1 点只掉 1 点、且活着（hp=%d）" % int(e.hp))
	# 再来一下就能打死 —— 「减伤」不是「无敌」
	e.take_damage(1)
	_check(bool(e.get("_dying")), "再来 1 点就被打死 —— 残血不是无敌（用户要的是减伤不是免伤）")
	await _phys(2)


# ------------------------------------------------------------
# D) 噪音倍率：纯函数（距离加权 / 叠加 / 封顶）
# ------------------------------------------------------------

func _noise_multiplier(cu: Dictionary) -> void:
	_say("")
	_say("=== D) 噪音放大倍率（按发声点距离加权）===")
	var f: Dictionary = cu["traits"][0]
	var per := float(f["noise_amplify"]["per_enemy"])
	var radius := float(f["noise_amplify"]["radius_px"])
	var cap := float(Config.get_value("enemy_traits.noise_amplify.max_multiplier", 3.0))
	var world := _world()
	var sys = _make_system(world)
	var pos := Vector2(5000.0, 5000.0)

	_check(is_equal_approx(NoiseSystem.player_noise_multiplier(pos), 1.0),
			"场上没有放大器 → 倍率 1.0（原样，不走任何加法）")

	var e0 = _spawn_at(world, pos, cu, sys)
	var want0 := 1.0 + per
	_check(absf(NoiseSystem.player_noise_multiplier(pos) - want0) < 0.001,
			"贴脸一只 → %.2f（期望 %.2f = 1 + per_enemy）"
			% [NoiseSystem.player_noise_multiplier(pos), want0])

	# 多只叠加（另一只放在半径的一半处 → 权重 0.5）
	var e_half = _spawn_at(world, pos + Vector2(radius * 0.5, 0.0), cu, sys)
	var want1 := 1.0 + per + per * 0.5
	var got1 := NoiseSystem.player_noise_multiplier(pos)
	_check(absf(got1 - want1) < 0.02,
			"再加一只在半径处 → %.3f（期望 %.3f = 1 + per + per*0.5）" % [got1, want1])

	# 出半径 → 不贡献（倍率回到只有贴脸那只的值）
	var e_out = _spawn_at(world, pos + Vector2(radius + 40.0, 0.0), cu, sys)
	_check(is_equal_approx(float(e_out.noise_amplify_gain(pos)), 0.0),
			"半径外的邪术师不贡献（gain = 0）")

	# 封顶
	var cx := Vector2(5200.0, 5000.0)
	for _i in range(10):
		_spawn_at(world, cx, cu, sys)
	var got_cap := NoiseSystem.player_noise_multiplier(cx)
	_check(is_equal_approx(got_cap, cap),
			"十只叠一起 → 被夹在封顶 %.1f（实得 %.3f）" % [cap, got_cap])

	# radius_px <= 0 = 关闭
	var off_feat := _with_feat(cu, {
		"id": "burst_drum",
		"noise_amplify": {"radius_px": 0.0, "per_enemy": per},
		"damage_reduction": f["damage_reduction"],
	})
	var w2 := _world()
	var s2 = _make_system(w2)
	var e_off = _spawn_at(w2, Vector2(5300.0, 5300.0), off_feat, s2)
	_check(is_equal_approx(float(e_off.noise_amplify_gain(Vector2(5300.0, 5300.0))), 0.0),
			"radius_px = 0 → 关闭放大（gain = 0）")
	await _phys(1)


# ------------------------------------------------------------
# E) 只放大「小队发声」
# ------------------------------------------------------------

func _only_player_noise(cu: Dictionary, br: Dictionary) -> void:
	_say("")
	_say("=== E) 只放大小队发声（敌人呼喊不受影响）===")
	var world := _world()
	var sys = _make_system(world)
	var at := Vector2(9000.0, 9000.0)
	var base := 120.0

	# 旁观者（劫掠者，无特性）：站在声源 1 格外，用它量"实际传到的强度"
	var listener = _spawn_at(world, at + Vector2(TILE, 0.0), br, sys)
	NoiseSystem.reset()
	NoiseSystem.emit(at, base, false)
	var got_no_amp := float(listener.noise_alertness)
	_check(got_no_amp > 100.0, "旁观者听到了呼喊（%.1f）" % got_no_amp)

	# 在声源上放一只邪术师，同一声呼喊再放一次
	var amplifier = _spawn_at(world, at, cu, sys)
	listener.noise_alertness = 0.0
	NoiseSystem.reset()
	NoiseSystem.emit(at, base, false)
	var got_with_amp := float(listener.noise_alertness)
	_check(absf(got_with_amp - got_no_amp) < 0.5,
			"敌人呼喊**没被放大**：有放大器 %.1f = 没放大器 %.1f"
			% [got_with_amp, got_no_amp])
	_check(is_equal_approx(NoiseSystem.team_self_noise(), 0.0)
			and is_equal_approx(NoiseSystem.world_noise, 0.0),
			"from_player=false 不动菜单栏读数（%.1f / %.1f）"
			% [NoiseSystem.team_self_noise(), NoiseSystem.world_noise])

	# 同样一句，换成小队发声 → 明显更响
	listener.noise_alertness = 0.0
	NoiseSystem.reset()
	NoiseSystem.emit(at, base, true)
	var got_player := float(listener.noise_alertness)
	_check(got_player > got_no_amp + 1.0,
			"换成小队发声 → 传到旁观者的强度被放大（%.1f > %.1f）" % [got_player, got_no_amp])
	var mult := NoiseSystem.player_noise_multiplier(at)
	_check(NoiseSystem.team_self_noise() >= base * mult - 0.5,
			"菜单栏读数用的是**放大后**的值（%.1f，倍率 %.2f）"
			% [NoiseSystem.team_self_noise(), mult])
	_check(amplifier != null, "放大器实例还在（占位断言，保证上面那只是活的）")
	await _phys(2)


# ------------------------------------------------------------
# F) 组登记
# ------------------------------------------------------------

func _group_registration(cu: Dictionary, br: Dictionary) -> void:
	_say("")
	_say("=== F) noise_amplifiers 组登记 ===")
	var world := _world()
	var sys = _make_system(world)
	var c = _spawn_at(world, Vector2(6000.0, 6000.0), cu, sys)
	var b = _spawn_at(world, Vector2(6100.0, 6000.0), br, sys)
	var ma = _spawn_at(world, Vector2(6200.0, 6000.0), _cfg("marauder"), sys)

	_check(c.is_in_group(AMP_GROUP), "邪术师进组（发声时才会被遍历到）")
	_check(not b.is_in_group(AMP_GROUP), "劫掠者不进组")
	_check(not ma.is_in_group(AMP_GROUP), "掠夺者（死亡特性）不进组")

	# 组是「只装放大器」的 —— 遍历成本只跟邪术师数量走
	var in_group := 0
	for n in get_tree().get_nodes_in_group(AMP_GROUP):
		if str(n.get("type_id")) == "cultist":
			in_group += 1
	_check(in_group >= 1, "组里确实有邪术师（%d 只）" % in_group)
	await _phys(1)


# ------------------------------------------------------------
# G) 与掠夺者的数量缩放解耦
# ------------------------------------------------------------

func _population_decoupled(cu: Dictionary) -> void:
	_say("")
	_say("=== G) 邪术师不参与「掠夺者数量缩放」计数 ===")
	var world := _world()
	var sys = _make_system(world)
	sys._pop_hold = 0.0
	var n0 := int(sys.featured_enemy_count())
	var c = _spawn_at(world, Vector2(7000.0, 7000.0), cu, sys)
	sys._pop_hold = 0.0
	var n1 := int(sys.featured_enemy_count())
	_check(n1 == n0, "刷一只邪术师 → 计数不变（%d → %d）" % [n0, n1])
	_check(not bool(c.counts_toward_population()),
			"邪术师声明为「不参与数量缩放」（它没写 chance_max）")

	var m = _spawn_at(world, Vector2(7100.0, 7000.0), _cfg("marauder"), sys)
	sys._pop_hold = 0.0
	var n2 := int(sys.featured_enemy_count())
	_check(n2 == n1 + 1, "掠夺者照样计数（%d → %d）" % [n1, n2])
	_check(bool(m.counts_toward_population()), "掠夺者声明为参与缩放")
	_check(bool(c.has_feature()) and bool(m.has_feature()),
			"has_feature() 对两者都是 true（「有没有特性」与「参不参与缩放」是两件事）")
	await _phys(1)


# ------------------------------------------------------------
# H) 没有该特性的兵种完全不受影响
# ------------------------------------------------------------

func _plain_enemy(cu: Dictionary, br: Dictionary) -> void:
	_say("")
	_say("=== H) 无特性兵种不受影响 ===")
	var world := _world()
	var sys = _make_system(world)
	var e = _spawn_at(world, Vector2(8000.0, 8000.0), br, sys)
	_check(not bool(e.has_feature()), "劫掠者没有特性")
	_check(is_equal_approx(float(e.damage_reduction_ratio()), 0.0), "不减伤")
	_check(int(e.incoming_damage(20)) == 20, "挨 20 点就是 20 点")
	_check(is_equal_approx(float(e.noise_amplify_gain(Vector2(8000.0, 8000.0))), 0.0),
			"不放大噪音")
	_check(not e.is_in_group(AMP_GROUP), "不进放大器组")
	# 满血打满血：伤害与减伤无关
	var full := int(e.max_hp)
	e.take_damage(7)
	_check(int(e.hp) == full - 7, "满血挨 7 点 → 掉 7（实得掉 %d）" % (full - int(e.hp)))
	await _phys(1)


# ------------------------------------------------------------
# I) 全局开关
# ------------------------------------------------------------

func _global_switch(cu: Dictionary) -> void:
	_say("")
	_say("=== I) 全局开关 enemy_traits.noise_amplify.enabled ===")
	var world := _world()
	var sys = _make_system(world)
	var pos := Vector2(9500.0, 9500.0)
	_spawn_at(world, pos, cu, sys)
	var on := NoiseSystem.player_noise_multiplier(pos)
	_check(on > 1.0, "开着的时候倍率 > 1（%.3f）" % on)

	Config.set_override("enemy_traits.noise_amplify.enabled", false)
	var off := NoiseSystem.player_noise_multiplier(pos)
	_check(is_equal_approx(off, 1.0), "关掉 → 倍率回到 1.0（实得 %.3f）" % off)
	NoiseSystem.reset()
	NoiseSystem.emit(pos, 120.0, true)
	_check(is_equal_approx(NoiseSystem.team_self_noise(), 120.0),
			"关掉后发声按原强度记（实得 %.1f）" % NoiseSystem.team_self_noise())

	Config.clear_override("enemy_traits.noise_amplify.enabled")
	var back := NoiseSystem.player_noise_multiplier(pos)
	_check(back > 1.0, "还原 override → 放大回来（%.3f）" % back)
	await _phys(1)


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
	print("[probe_cultist_trait] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

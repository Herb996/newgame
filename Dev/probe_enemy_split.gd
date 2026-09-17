extends Node
## ============================================================
## probe_enemy_split — 掠夺者「死亡特性」验证（headless 可跑）
##
## 掠夺者有一个**特性池** traits[]：每个实例生成时随机分配其中一个，一个角色只有一种特性
## （用户 2026-09-17 定：「死亡一个角色只能有一个特性，随机分配」）；特性刷出来的孩子
## **继承父的那一个**。目前两种：
##
##   death_split 死亡分裂：
##     原始体死亡 → 100% 刷 2 个；这 2 个的**最后一个**死亡时 → 90% 刷 4 个；
##     这 4 个的最后一个死亡时 → 80% 刷 8 个；这 8 个的最后一个死亡时 → 70% 刷 64 个。
##   death_regen 死亡再生：
##     **每次死亡**都独立掷 50%，过了就刷 2 个；这 2 个也有该特性 → 会一直链下去。
##     与分裂的本质区别：不看「最后一个」、不逐代递进。
##
##   两者刷出来的个体都在**死亡原地一个一个**出来，不是一次性冒出来。
##
## 数量缩放（2026-09-17 用户定，防刷爆）：「掠夺者总数量越少，特性初始触发概率越高」，
##   两者上限分别是 100% 与 50%。所以**初始**概率不再写死，而是写成
##   chance_base（场上怪多时）+ chance_max（场上怪少时的上限），实际值随
##   `enemy_traits.population_scaling` 在两者之间线性滑动（见 P 段）。
##
## 验的东西：
##   A) config 真值：特性池 2 个、weight 各 1；分裂 4 代 count 2/4/8/64、
##      第 1 代用 chance_base/chance_max、第 2–4 代仍是固定 chance 0.9/0.8/0.7；
##      再生 count 2 / 概率同样是 base+max；两者的间隔都 > 0
##   B) 原始怪死亡 → 排队 2 个，下一批标记 stage=1 / alive=2
##   C) 「一个一个出来」：间隔没到不放，到点**只放一个**（队列每帧最多 1 个）
##   D) 「最后一个」语义：同批没死完不触发，最后一个死才触发（核心规则）
##   E) 批次是**同一个字典实例**（改一个兄弟看得见），不然计数根本对不上
##   F) 代次递进：下一批 stage+1、alive = 这一批的数量
##   G) 概率没过 → 链到此为止
##   H) stages 用完 → 不再裂（不会无限裂）
##   I) 分裂体默认不掉落（一只裂成 79 个会把地面铺满）
##   J) 没有 death_split 特性的兵种死亡不上报
##   K) max_live_split_enemies 截断生效
##   L) 落点在死亡原地
##   M) 新一局 setup() 会清空上一局残留的队列（否则会刷到已释放的 GameRoot 里）
##   N) 第 4 代 64 个按 config 的 0.1s 间隔完整刷完
##   O) 特性池：随机分配（两边都分得到）/ 一个角色只触发一个特性 / 死亡再生「每次都判」+
##      孩子继承 / 再生体算「特性刷出来的」/ chance=0 不刷
##   P) 数量缩放：阈值与 factor 两端夹紧、单调；上限就是 100% / 50%；只压初始那一代；
##      老写法（只写 chance）不受影响；计数口径只数带特性的敌人；端到端验证判定确实吃到了缩放
##
## 为什么 headless 能跑：全是逻辑（队列 + 计数 + 概率），不依赖渲染。
## 时间轴用 physics_frame 推进 —— 「一个一个放出来」就在 _physics_process 里。
##
## 注：本探针不加载 Main.tscn，自己搭最小 A* 网格 + 独立的 EnemySystem 实例，
## 所以很快、也不受 debug.time_scale 影响（那个只在 main.gd 里设）。
## ============================================================

const OUT := "user://_probe_enemy_split.txt"
const ENEMY_SYS := preload("res://Scripts/enemy_system.gd")
const ENEMY_SCENE := preload("res://Scenes/Enemy.tscn")
const TILE := 64

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


## 真·掠夺者配置的深拷贝（改 trait 不会污染 Config）
func _marauder_cfg() -> Dictionary:
	for t in Config.get_value("enemy_types.types", []):
		if t is Dictionary and str((t as Dictionary).get("id", "")) == "marauder":
			return (t as Dictionary).duplicate(true)
	return {}


## 复制一份兵种配置并换成**单数 trait**（只想测某一个特性时用）。
## 注意必须先把 traits 池摘掉：代码里池**优先于**单数 trait（feature_pool 先看 traits），
## 不摘的话池会把这里设的值整个盖掉 —— 踩过。
func _with_trait(base: Dictionary, feat: Dictionary) -> Dictionary:
	var c := base.duplicate(true)
	c.erase("traits")
	c["trait"] = feat
	return c


## 复制一份兵种配置并把特性池换成给定数组（测「一个角色随机分到一个特性」时用）
func _with_traits(base: Dictionary, feats: Array) -> Dictionary:
	var c := base.duplicate(true)
	c.erase("trait")
	c["traits"] = feats
	return c


func _world() -> Node2D:
	var w := Node2D.new()
	add_child(w)
	return w


## 独立的 EnemySystem：不调 setup()，直接喂成员（省掉开局那 100 个敌人）
func _make_system(world):
	var sys = ENEMY_SYS.new()
	sys.name = "Sys"
	add_child(sys)
	sys._root = world
	sys._walls = _walls
	sys._tile_size = TILE
	sys._astar = MapGenerator.build_astar(_walls, TILE)
	return sys


func _spawn_at(world: Node2D, pos: Vector2, type_cfg: Dictionary, batch: Dictionary, sys):
	var e = ENEMY_SCENE.instantiate()
	e.position = pos
	world.add_child(e)
	e.setup(_walls, TILE, sys._astar, type_cfg, batch, sys)
	return e


## 场上还活着的敌人（排除正在死亡淡出的，否则计数会被"尸体"搅乱）
func _live(world: Node2D) -> Array:
	var out: Array = []
	for c in world.get_children():
		if not c.has_method("take_damage"):
			continue
		if c.is_queued_for_deletion():
			continue
		if bool(c.get("_dying")):
			continue
		out.append(c)
	return out


func _split_ones(world: Node2D) -> Array:
	var out: Array = []
	for e in _live(world):
		if bool(e.call("is_split_spawn")):
			out.append(e)
	return out


## 把队列里所有待刷项的间隔改成 0 → 每物理帧放一个，测试不用等几秒
func _drain_fast(sys) -> void:
	for e in sys._pending:
		e["interval"] = 0.0


# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------

func _ready() -> void:
	_walls = _open_walls(24)
	var ma := _marauder_cfg()

	_say("=== A) config 真值：特性池 traits[] ===")
	var pool: Array = ma.get("traits", [])
	_check(pool.size() == 2, "掠夺者的特性池有 2 个候选（实得 %d）" % pool.size())
	var split_feat: Dictionary = {}
	var regen_feat: Dictionary = {}
	for f in pool:
		if not (f is Dictionary):
			continue
		match str((f as Dictionary).get("id", "")):
			"death_split": split_feat = f
			"death_regen": regen_feat = f
	_check(not split_feat.is_empty(), "池里有 death_split（死亡分裂）")
	_check(not regen_feat.is_empty(), "池里有 death_regen（死亡再生）")
	_check(int(split_feat.get("weight", 0)) == 1 and int(regen_feat.get("weight", 0)) == 1,
			"两个特性 weight 都是 1 → 各 50%%（实得 %s / %s）"
			% [str(split_feat.get("weight")), str(regen_feat.get("weight"))])

	_say("  · death_split")
	var stages: Array = split_feat.get("stages", [])
	_check(stages.size() == 4, "共 4 代（实得 %d）" % stages.size())
	var want_counts := [2, 4, 8, 64]
	# 第 1 代（初始）是**数量缩放**写法（chance_base / chance_max），
	# 第 2–4 代仍是固定 chance —— 用户说的是「特性**初始**触发概率」随数量变。
	# 上限（chance_max）是用户给死的两个数之一，绑死断言；chance_base 是「后面单独调」的量，
	# 只校验它在 (0, 上限) 之间，改它不会把探针改红。
	var want_fixed := [0.0, 0.9, 0.8, 0.7]
	for i in range(mini(stages.size(), 4)):
		var s: Dictionary = stages[i]
		var got_c := int(s.get("count", -1))
		_check(got_c == want_counts[i],
				"第 %d 代 count = %d（实得 %d）" % [i + 1, want_counts[i], got_c])
		if i == 0:
			var s_lo := float(s.get("chance_base", -1.0))
			var s_hi := float(s.get("chance_max", -1.0))
			_check(is_equal_approx(s_hi, 1.0),
					"第 1 代上限 = 100%%（用户给死的「最高 100」）：实得 %.2f" % s_hi)
			_check(s_lo > 0.0 and s_lo < s_hi,
					"第 1 代基础概率落在 (0, 上限) 里（怪多时的值，可自由调）：%.2f" % s_lo)
		else:
			_check(is_equal_approx(float(s.get("chance", -1.0)), want_fixed[i]),
					"第 %d 代仍是固定概率 %.2f（实得 %s）"
					% [i + 1, want_fixed[i], str(s.get("chance"))])
	_check(float(split_feat.get("spawn_interval_seconds", 0.0)) > 0.0,
			"刷出有间隔（一个一个有节奏，不是一次性）：%.2fs"
			% float(split_feat.get("spawn_interval_seconds", 0.0)))

	_say("  · death_regen")
	_check(int(regen_feat.get("count", -1)) == 2,
			"每次刷 2 个（实得 %s）" % str(regen_feat.get("count")))
	var r_hi := float(regen_feat.get("chance_max", -1.0))
	var r_lo := float(regen_feat.get("chance_base", -1.0))
	_check(is_equal_approx(r_hi, 0.5),
			"概率上限 = 50%%（用户给死的「最高 50」）：实得 %.2f" % r_hi)
	_check(r_lo > 0.0 and r_lo < r_hi,
			"基础概率落在 (0, 上限) 里（怪多时的值，可自由调）：%.2f" % r_lo)
	_check(float(regen_feat.get("spawn_interval_seconds", 0.0)) > 0.0,
			"再生也是一个一个出来：%.2fs"
			% float(regen_feat.get("spawn_interval_seconds", 0.0)))

	# drop_from_splits 是「后面单独调」的数值，不绑死具体值：只要求它是 bool 键
	# （两个分支另有 I 段实测；再生体的掉落走同一把开关）
	_check(typeof(split_feat.get("drop_from_splits")) == TYPE_BOOL
			and typeof(regen_feat.get("drop_from_splits")) == TYPE_BOOL,
			"两个特性都带 drop_from_splits 布尔开关（当前 %s / %s）"
			% [str(split_feat.get("drop_from_splits")), str(regen_feat.get("drop_from_splits"))])

	await _main_chain(ma)
	await _chance_fail(ma)
	await _stage_exhausted(ma)
	await _no_drop(ma)
	await _no_trait_ignored(ma)
	await _cap(ma)
	await _setup_clears_queue()
	await _full_64(ma)
	await _feature_pool_tests(ma)
	await _population_scaling_tests(ma)

	_finish()


# ------------------------------------------------------------
# B–F / L) 主链：原始 → 2 →(最后一个)→ 4 →(最后一个)→ 8
# ------------------------------------------------------------

func _main_chain(ma: Dictionary) -> void:
	_say("")
	_say("=== B–F / L) 主链（原始 → 2 → 4 → 8）===")
	var type_cfg := _with_trait(ma, {
		"id": "death_split",
		"stages": [
			{"count": 2, "chance": 1.0},
			{"count": 4, "chance": 1.0},
			{"count": 8, "chance": 1.0},
			{"count": 64, "chance": 1.0},
		],
		"spawn_interval_seconds": 0.5, "scatter_px": 0.0,
		"drop_from_splits": false, "max_live_split_enemies": 0,
	})
	var world := _world()
	var sys = _make_system(world)
	var origin := Vector2(400.0, 400.0)

	var e0 = _spawn_at(world, origin, type_cfg, {}, sys)
	_check(not bool(e0.call("is_split_spawn")), "原始掠夺者不是分裂体")
	_check(_live(world).size() == 1, "场上 1 个原始怪")
	_check(sys.pending_split_count() == 0, "还没死 → 队列是空的")

	e0.take_damage(99999)
	_check(sys.pending_split_count() == 2, "原始怪死亡 → 排队 2 个（实得 %d）"
			% sys.pending_split_count())
	var b1: Dictionary = sys._pending[0]["batch"]
	_check(int(b1.get("stage", -1)) == 1, "下一批 stage = 1（实得 %s）" % str(b1.get("stage")))
	_check(int(b1.get("alive", -1)) == 2, "下一批 alive = 2（实得 %s）" % str(b1.get("alive")))
	_check(sys._pending[0].has("type") and sys._pending[0].has("pos"),
			"队列项带着兵种配置与落点")

	_say("  · C) 「一个一个出来」（间隔 0.5s）")
	await _phys(1)
	_check(_live(world).size() == 0, "过 1 物理帧：间隔没到，一个都还没放出来")
	_check(sys.pending_split_count() == 2, "队列仍是 2")
	await _phys(33)
	_check(_live(world).size() == 1,
			"间隔到点 → 只放出 1 个（实得 %d，不是一次冒出 2 个）" % _live(world).size())
	_check(sys.pending_split_count() == 1, "队列剩 1（一个一个来）")
	await _phys(33)
	_check(_live(world).size() == 2, "第二个也出来了（实得 %d）" % _live(world).size())
	_check(sys.pending_split_count() == 0, "队列空了")

	_say("  · D/E) 「最后一个才触发」+ 共享批次")
	var kids: Array = _live(world)
	_check(kids.size() == 2, "场上 2 个分裂体")
	_check(bool((kids[0] as Node).call("is_split_spawn"))
			and bool((kids[1] as Node).call("is_split_spawn")), "两个都标记为分裂体")
	var s0: Dictionary = kids[0].get("_split")
	var s1: Dictionary = kids[1].get("_split")
	s0["__probe"] = 1
	_check(s1.has("__probe"), "两个分裂体共享**同一个字典实例**（改一个，兄弟看得见）")
	s0.erase("__probe")

	kids[0].take_damage(99999)
	_check(sys.pending_split_count() == 0, "同批只死了 1 个 → 不触发下一代（核心规则）")
	kids[1].take_damage(99999)
	_check(sys.pending_split_count() == 4, "最后一个死亡 → 排队 4 个（实得 %d）"
			% sys.pending_split_count())
	var b2: Dictionary = sys._pending[0]["batch"]
	_check(int(b2.get("stage", -1)) == 2, "再下一批 stage = 2（实得 %s）" % str(b2.get("stage")))
	_check(int(b2.get("alive", -1)) == 4, "再下一批 alive = 4（实得 %s）" % str(b2.get("alive")))

	_drain_fast(sys)
	await _phys(6)
	_check(_live(world).size() == 4, "4 个都放出来了（实得 %d）" % _live(world).size())

	_say("  · F) 再走一代：4 →（最后一个）→ 8")
	var four: Array = _live(world)
	for i in range(3):
		four[i].take_damage(99999)
	_check(sys.pending_split_count() == 0, "4 个里死了 3 个 → 仍不触发")
	four[3].take_damage(99999)
	_check(sys.pending_split_count() == 8, "最后一个死亡 → 排队 8 个（实得 %d）"
			% sys.pending_split_count())
	var b3: Dictionary = sys._pending[0]["batch"]
	_check(int(b3.get("stage", -1)) == 3 and int(b3.get("alive", -1)) == 8,
			"批次 stage = 3 / alive = 8（实得 %s / %s）"
			% [str(b3.get("stage")), str(b3.get("alive"))])

	_say("  · L) 落点在死亡原地")
	_drain_fast(sys)
	await _phys(10)
	var landed: Array = _split_ones(world)
	_check(landed.size() == 8, "场上 8 个分裂体（实得 %d）" % landed.size())
	var far := 0
	for e in landed:
		if (e as Node2D).position.distance_to(origin) > 1.0:
			far += 1
	_check(far == 0, "8 个都落在死亡原地（scatter 0；偏离的 %d 个）" % far)


# ------------------------------------------------------------
# G) 概率没过
# ------------------------------------------------------------

func _chance_fail(ma: Dictionary) -> void:
	_say("")
	_say("=== G) 概率没过就停 ===")
	var type_cfg := _with_trait(ma, {
		"id": "death_split",
		"stages": [
			{"count": 2, "chance": 1.0},
			{"count": 4, "chance": 0.0},
			{"count": 8, "chance": 1.0},
			{"count": 64, "chance": 1.0},
		],
		"spawn_interval_seconds": 0.0, "scatter_px": 0.0,
		"drop_from_splits": false, "max_live_split_enemies": 0,
	})
	var world := _world()
	var sys = _make_system(world)
	var e0 = _spawn_at(world, Vector2(300.0, 300.0), type_cfg, {}, sys)
	e0.take_damage(99999)
	_drain_fast(sys)
	await _phys(4)
	_check(_live(world).size() == 2, "第一代照刷（100%%）：实得 %d" % _live(world).size())
	var two: Array = _live(world)
	two[0].take_damage(99999)
	two[1].take_damage(99999)
	_check(sys.pending_split_count() == 0, "第二代概率 0 → 一个都不刷（实得 %d）"
			% sys.pending_split_count())
	await _phys(4)
	_check(_live(world).size() == 0, "链到此为止，场上没有新东西")


# ------------------------------------------------------------
# H) stages 用完
# ------------------------------------------------------------

func _stage_exhausted(ma: Dictionary) -> void:
	_say("")
	_say("=== H) stages 用完就不再裂 ===")
	var type_cfg := _with_trait(ma, {
		"id": "death_split", "stages": [{"count": 2, "chance": 1.0}],
		"spawn_interval_seconds": 0.0, "scatter_px": 0.0,
		"drop_from_splits": false, "max_live_split_enemies": 0,
	})
	var world := _world()
	var sys = _make_system(world)
	# 直接造一个「已经是最后一代」的分裂体：批次 stage 已越界（stages 只有 1 个）
	var e = _spawn_at(world, Vector2(200.0, 200.0), type_cfg, {"stage": 1, "alive": 1}, sys)
	_check(bool(e.call("is_split_spawn")), "它是分裂体（批次非空）")
	e.take_damage(99999)
	_check(sys.pending_split_count() == 0, "stage 越界 → 不刷（实得 %d）"
			% sys.pending_split_count())
	await _phys(2)


# ------------------------------------------------------------
# I) 分裂体掉落开关（drop_from_splits 的两个分支都要对）
# ------------------------------------------------------------

func _no_drop(ma: Dictionary) -> void:
	_say("")
	_say("=== I) 分裂体掉落开关 drop_from_splits ===")
	var world := _world()
	var sys = _make_system(world)

	# I-1) 关：分裂体死亡不掉
	var off := _with_trait(ma, {
		"id": "death_split", "stages": [{"count": 2, "chance": 1.0}],
		"spawn_interval_seconds": 0.0, "scatter_px": 0.0,
		"drop_from_splits": false, "max_live_split_enemies": 0,
	})
	# stage 越界（9）→ 只验掉落，不刷东西出来
	var e_off = _spawn_at(world, Vector2(250.0, 250.0), off, {"stage": 9, "alive": 1}, sys)
	var before := get_tree().get_nodes_in_group("loot_nodes").size()
	e_off.take_damage(99999)
	await _phys(2)
	var after_off := get_tree().get_nodes_in_group("loot_nodes").size()
	_check(after_off == before, "drop_from_splits=false → 分裂体死亡没掉资源（%d → %d）"
			% [before, after_off])

	# I-2) 开：分裂体死亡照掉。只有 enemy.drop.chance = 1 时才是「必然掉」，
	#      所以 chance < 1 时不做硬断言（那个数值用户会单独调，探针不该被它带红）
	var on := _with_trait(ma, {
		"id": "death_split", "stages": [{"count": 2, "chance": 1.0}],
		"spawn_interval_seconds": 0.0, "scatter_px": 0.0,
		"drop_from_splits": true, "max_live_split_enemies": 0,
	})
	var e_on = _spawn_at(world, Vector2(280.0, 250.0), on, {"stage": 9, "alive": 1}, sys)
	var before_on := get_tree().get_nodes_in_group("loot_nodes").size()
	e_on.take_damage(99999)
	await _phys(2)
	var after_on := get_tree().get_nodes_in_group("loot_nodes").size()
	var chance := float(Config.get_value("enemy.drop.chance", 0.75))
	if chance >= 1.0:
		_check(after_on > before_on,
				"drop_from_splits=true 且 enemy.drop.chance=1 → 分裂体死亡照掉（%d → %d）"
				% [before_on, after_on])
	else:
		_say("  · enemy.drop.chance=%.2f ≠ 1，true 分支是否掉落不唯一 → 跳过硬断言（实得 %d → %d）"
				% [chance, before_on, after_on])


# ------------------------------------------------------------
# J) 没有特性的兵种不上报
# ------------------------------------------------------------

func _no_trait_ignored(_ma: Dictionary) -> void:
	_say("")
	_say("=== J) 其它兵种不受影响 ===")
	var plain: Dictionary = {}
	for t in Config.get_value("enemy_types.types", []):
		if t is Dictionary and str((t as Dictionary).get("id", "")) == "brigand":
			plain = (t as Dictionary).duplicate(true)
	_check(not plain.is_empty(), "取到 brigand 配置")
	_check(not plain.has("trait"), "brigand 没有 trait")
	var world := _world()
	var sys = _make_system(world)
	var e = _spawn_at(world, Vector2(350.0, 350.0), plain, {}, sys)
	e.take_damage(99999)
	_check(sys.pending_split_count() == 0, "普通兵种死亡不排队（实得 %d）"
			% sys.pending_split_count())
	await _phys(2)


# ------------------------------------------------------------
# K) 同屏分裂体上限
# ------------------------------------------------------------

func _global_split_count() -> int:
	var n := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if not e.has_method("is_split_spawn"):
			continue
		if bool(e.get("_dying")):
			continue
		if bool(e.is_split_spawn()):
			n += 1
	return n


## 同屏分裂体上限。注意这个上限是**全局**的（扫 enemies 组所有分裂体），
## 而前面的小节会在别的 world 里留下活着的分裂体，所以这里按「当前全局数 + 3」
## 动态设上限，断言才是确定的 —— 写死 5 会被前面的残留顶成 0。
func _cap(ma: Dictionary) -> void:
	_say("")
	_say("=== K) max_live_split_enemies 截断 ===")
	var type_cfg := _with_trait(ma, {
		"id": "death_split", "stages": [{"count": 64, "chance": 1.0}],
		"spawn_interval_seconds": 0.0, "scatter_px": 0.0,
		"drop_from_splits": false, "max_live_split_enemies": 0,
	})
	var world := _world()
	var sys = _make_system(world)
	# 两个「裂到头」的分裂体先占额度（stage 越界 → 它们自己不会再刷）
	_spawn_at(world, Vector2(100.0, 100.0), type_cfg, {"stage": 9, "alive": 1}, sys)
	_spawn_at(world, Vector2(120.0, 100.0), type_cfg, {"stage": 9, "alive": 1}, sys)
	_check(_split_ones(world).size() == 2, "先占 2 个额度（实得 %d）" % _split_ones(world).size())

	var live := _global_split_count()
	_check(live >= 2, "全局活着的分裂体 = %d（含前面小节留下的）" % live)
	var cap_n := live + 3
	(type_cfg["trait"] as Dictionary)["max_live_split_enemies"] = cap_n

	var killer = _spawn_at(world, Vector2(140.0, 100.0), type_cfg, {"stage": 0, "alive": 1}, sys)
	killer.take_damage(99999)
	_check(sys.pending_split_count() == 3,
			"想刷 64 个，被上限 %d − 已活 %d 截成 3 个（实得 %d）"
			% [cap_n, live, sys.pending_split_count()])
	await _phys(2)


# ------------------------------------------------------------
# M) 新一局清空队列
# ------------------------------------------------------------

func _setup_clears_queue() -> void:
	_say("")
	_say("=== M) 新一局 setup() 清空残留队列 ===")
	var world := _world()
	var sys = _make_system(world)
	sys._pending.append({"pos": Vector2.ZERO, "type": {}, "batch": {}, "interval": 0.0})
	_check(sys.pending_split_count() == 1, "先手工塞 1 条残留")

	# 小图 + 出生点在正中 → 合法格不足的兜底路径（一个都不刷），跑得快
	var walls2 := _open_walls(24)
	var reach: Array = []
	for _y in range(24):
		var row: Array = []
		for _x in range(24):
			row.append(true)
		reach.append(row)
	var world2 := _world()
	var map_data := {
		"walls": walls2, "reachable": reach,
		"tile_size": TILE, "spawn_cell": Vector2i(12, 12),
	}
	sys.setup(world2, map_data)
	_check(sys.pending_split_count() == 0, "setup() 把上一局残留清空了（实得 %d）"
			% sys.pending_split_count())
	_check(sys._root == world2, "setup() 记住了新的 GameRoot")
	# 24×24 的图、出生点在正中：所有格离出生点都不到 20 格 → 合法格 0 个 → 一个都不刷。
	# 顺便把「本机生效的 enemy.count」打出来：它可能被 user://settings.json 覆盖
	# （本机就被设成了 0，所以实机一局刷 0 个敌人是配置如此，不是 bug）。
	_check(_live(world2).size() == 0,
			"小图 + 出生点在正中 → 合法格 0 个，兜底不刷怪（本机生效 enemy.count=%d，实刷 %d 个）"
			% [int(Config.get_value("enemy.count", 100)), _live(world2).size()])


## N) 完整第 4 代：真按 config 的 0.1s 间隔把 64 个刷完（不是把间隔掰成 0）
func _full_64(ma: Dictionary) -> void:
	_say("")
	_say("=== N) 第 4 代完整跑：64 个按 0.1s 间隔一个一个出来 ===")
	var type_cfg := _with_trait(ma, {
		"id": "death_split", "stages": [{"count": 64, "chance": 1.0}],
		"spawn_interval_seconds": 0.1, "scatter_px": 0.0,
		"drop_from_splits": false, "max_live_split_enemies": 0,
	})
	var world := _world()
	var sys = _make_system(world)
	var killer = _spawn_at(world, Vector2(500.0, 500.0), type_cfg, {"stage": 0, "alive": 1}, sys)
	killer.take_damage(99999)
	_check(sys.pending_split_count() == 64, "排队 64 个（实得 %d）" % sys.pending_split_count())

	# 0.1s ≈ 6 物理帧。**别卡在 6 帧上断言**：6 × (1/60) 浮点上略小于 0.1，
	# 那一帧根本不放（踩过），所以取 9 帧 —— 第 7 帧放 1 个，之后还没到下一个。
	await _phys(9)
	var early := _live(world).size()
	_check(early == 1, "0.15s 后只出来 1 个（实得 %d）—— 确实是一个一个来" % early)

	var t0 := Time.get_ticks_msec()
	await _phys(64 * 6 + 60)
	var n := _live(world).size()
	_check(n == 64, "64 个全部出来（实得 %d）" % n)
	_check(sys.pending_split_count() == 0, "队列清空（实得 %d）" % sys.pending_split_count())
	_say("  · 64 个刷完耗时 %d ms（含等待）" % (Time.get_ticks_msec() - t0))


# ------------------------------------------------------------
# O) 特性池：一个角色只有一个特性（随机分配）+ 死亡再生
# ------------------------------------------------------------

func _feature_pool_tests(ma: Dictionary) -> void:
	_say("")
	_say("=== O) 特性池 / 随机分配 / 死亡再生 ===")

	# O-1) 生成时随机分配：直接喂真 config（带 traits 池），不指定 feat
	var world := _world()
	var sys = _make_system(world)
	var tally := {}
	for row in range(8):
		for col in range(10):
			var e = _spawn_at(world,
					Vector2(60.0 + col * 40.0, 60.0 + row * 40.0), ma, {}, sys)
			var fid := str(e.call("feature_id"))
			tally[fid] = int(tally.get(fid, 0)) + 1
	_say("  · 80 个实例的分配统计：%s" % str(tally))
	_check(int(tally.get("death_split", 0)) > 0, "有实例分到 death_split")
	_check(int(tally.get("death_regen", 0)) > 0, "有实例分到 death_regen")
	_check(int(tally.get("", 0)) == 0, "没有实例是「无特性」（掠夺者必带其一）")
	var lo := mini(int(tally.get("death_split", 0)), int(tally.get("death_regen", 0)))
	_check(lo >= 12, "两边都分到不少（少的一边 %d / 80）—— 是真随机，不是独宠一个" % lo)

	# O-2) 一个角色只触发一个特性：两个特性的数量故意不同（2 / 6），
	#      所以每次死亡的队列增量只能是 2 或 6，**绝不可能 8**（= 两个一起算）
	var two := _with_traits(ma, [
		{"id": "death_split", "weight": 1, "stages": [{"count": 2, "chance": 1.0}],
			"spawn_interval_seconds": 0.0, "scatter_px": 0.0,
			"drop_from_splits": false, "max_live_split_enemies": 0},
		{"id": "death_regen", "weight": 1, "count": 6, "chance": 1.0,
			"spawn_interval_seconds": 0.0, "scatter_px": 0.0,
			"drop_from_splits": false, "max_live_split_enemies": 0},
	])
	var w2 := _world()
	var s2 = _make_system(w2)
	var seen := {}
	for i in range(20):
		var e2 = _spawn_at(w2, Vector2(80.0 + i * 20.0, 300.0), two, {}, s2)
		var before_n := s2.pending_split_count()
		e2.take_damage(99999)
		var delta := s2.pending_split_count() - before_n
		seen[delta] = int(seen.get(delta, 0)) + 1
		s2._pending.clear()          # 清掉，不然越堆越多
	_say("  · 20 次死亡各自触发的数量：%s" % str(seen))
	_check(not seen.has(8), "从没出现 8（= 2 + 6）→ 一个角色只触发一个特性")
	var only_expected := true
	for k in seen.keys():
		if int(k) != 2 and int(k) != 6:
			only_expected = false
	_check(only_expected, "增量都落在 {2, 6} 里（实得 %s）" % str(seen))
	_check(seen.size() == 2, "两个特性都被抽到过（实得 %d 种增量）" % seen.size())

	# O-3) 死亡再生：chance=1 必刷，且孩子继承同一个特性
	var regen := _with_trait(ma, {
		"id": "death_regen", "count": 2, "chance": 1.0,
		"spawn_interval_seconds": 0.0, "scatter_px": 0.0,
		"drop_from_splits": false, "max_live_split_enemies": 0,
	})
	var w3 := _world()
	var s3 = _make_system(w3)
	var e3 = _spawn_at(w3, Vector2(400.0, 400.0), regen, {}, s3)
	_check(str(e3.call("feature_id")) == "death_regen", "原始体分配到了 death_regen")
	e3.take_damage(99999)
	_check(s3.pending_split_count() == 2,
			"死一次 → 排队 2 个（实得 %d）" % s3.pending_split_count())
	_drain_fast(s3)
	await _phys(4)
	var kids: Array = _live(w3)
	_check(kids.size() == 2, "2 个再生体出来了（实得 %d）" % kids.size())
	var inherit := true
	for k in kids:
		if str(k.call("feature_id")) != "death_regen":
			inherit = false
	_check(inherit, "两个孩子都继承 death_regen（用户：「这两个也有这个特性」）")
	if kids.size() > 0:
		_check(bool(kids[0].call("is_trait_spawn")),
				"再生体被标记为「特性刷出来的」（drop_from_splits 才对它生效）")

	# O-4) 与死亡分裂的**核心区别**：再生不等最后一个 —— 2 个里只死 1 个就该再刷
	if kids.size() == 2:
		kids[0].take_damage(99999)
		_check(s3.pending_split_count() == 2,
				"2 个里只死了 1 个 → 照样刷 2 个（实得 %d）—— 不像死亡分裂要等最后一个"
				% s3.pending_split_count())

	# O-5) chance=0 → 一个都不刷
	var zero := _with_trait(ma, {
		"id": "death_regen", "count": 2, "chance": 0.0,
		"spawn_interval_seconds": 0.0, "scatter_px": 0.0,
		"drop_from_splits": false, "max_live_split_enemies": 0,
	})
	var w4 := _world()
	var s4 = _make_system(w4)
	var e4 = _spawn_at(w4, Vector2(600.0, 600.0), zero, {}, s4)
	e4.take_damage(99999)
	_check(s4.pending_split_count() == 0,
			"chance=0 → 一个都不刷（实得 %d）" % s4.pending_split_count())
	await _phys(2)


# ------------------------------------------------------------
# P) 数量缩放：场上掠夺者越少 → 特性初始概率越高（上限 = 各自 chance_max）
# ------------------------------------------------------------

func _population_scaling_tests(ma: Dictionary) -> void:
	_say("")
	_say("=== P) 数量缩放（怪少 → 初始概率向各自上限靠） ===")
	var world := _world()
	var sys = _make_system(world)

	# P-1) config 真值
	var sc: Dictionary = Config.get_value("enemy_traits.population_scaling", {})
	_check(not sc.is_empty(), "config 有 enemy_traits.population_scaling")
	_check(bool(sc.get("enabled", false)), "缩放默认开着")
	var full_at := int(sc.get("full_chance_at_or_below", -1))
	var base_at := int(sc.get("base_chance_at_or_above", -1))
	_check(full_at > 0 and base_at > full_at,
			"阈值合理：≤%d 个拉满、≥%d 个回落（实得 %d / %d）"
			% [full_at, base_at, full_at, base_at])

	# P-2) factor 纯函数：两端夹紧 + 中间线性 + 单调
	_check(is_equal_approx(sys.population_factor(0), 1.0), "场上 0 个 → factor 1.0（拉满）")
	_check(is_equal_approx(sys.population_factor(full_at), 1.0),
			"%d 个（正好等于阈值）→ factor 1.0" % full_at)
	_check(is_equal_approx(sys.population_factor(base_at), 0.0),
			"%d 个（正好等于阈值）→ factor 0.0" % base_at)
	_check(is_equal_approx(sys.population_factor(base_at + 500), 0.0),
			"远超阈值 → factor 仍是 0.0（不会变负）")
	var mid := int((full_at + base_at) / 2)
	var f_mid := float(sys.population_factor(mid))
	_check(f_mid > 0.0 and f_mid < 1.0, "%d 个 → factor 落在中间（%.3f）" % [mid, f_mid])
	_check(sys.population_factor(full_at - 1) >= sys.population_factor(mid)
			and sys.population_factor(mid) >= sys.population_factor(base_at - 1),
			"单调：越少 → factor 越高")

	# P-3) 实际概率的上限就是用户给的两个数：分裂 100%、再生 50%
	var split_feat: Dictionary = {}
	var regen_feat: Dictionary = {}
	for f in ma.get("traits", []):
		match str((f as Dictionary).get("id", "")):
			"death_split": split_feat = f
			"death_regen": regen_feat = f
	_check(is_equal_approx(sys.trait_chance(split_feat, 0, 0), 1.0),
			"死亡分裂：场上 0 个 → 初始概率 100%%（实得 %.3f）"
			% sys.trait_chance(split_feat, 0, 0))
	_check(is_equal_approx(sys.trait_chance(regen_feat, 0, 0), 0.5),
			"死亡再生：场上 0 个 → 50%%（实得 %.3f）"
			% sys.trait_chance(regen_feat, 0, 0))
	_check(sys.trait_chance(split_feat, 0, base_at) < sys.trait_chance(split_feat, 0, 0),
			"怪一多概率就往下掉（%d 个时 %.3f < 0 个时 %.3f）"
			% [base_at, sys.trait_chance(split_feat, 0, base_at),
			sys.trait_chance(split_feat, 0, 0)])
	var over := false
	for n in [0, 1, full_at, mid, base_at, base_at * 10]:
		if sys.trait_chance(split_feat, 0, n) > 1.0 or sys.trait_chance(regen_feat, 0, n) > 0.5:
			over = true
	_check(not over, "任何数量下都不越过各自上限（分裂 100% / 再生 50%）")

	# P-4) 只压「初始」那一代：后续代仍按固定 chance
	_check(is_equal_approx(sys.trait_chance(split_feat, 1, 0), 0.9)
			and is_equal_approx(sys.trait_chance(split_feat, 3, 0), 0.7),
			"第 2/4 代不受数量影响，仍固定 0.9 / 0.7（用户说的是「初始」）")

	# P-5) 老写法（只写 chance）完全不受数量影响
	var legacy := {"id": "x", "count": 2, "chance": 0.33}
	_check(is_equal_approx(sys.trait_chance(legacy, 0, 0), 0.33)
			and is_equal_approx(sys.trait_chance(legacy, 0, base_at * 10), 0.33),
			"只写 chance 的特性两头都是 0.33（缩放不碰它，兼容老配置）")

	# P-6) 计数口径：只数「带特性的」，不带特性的兵种不算
	var before_n := sys.featured_enemy_count()
	_spawn_at(world, Vector2(120.0, 120.0), ma, {}, sys)      # 掠夺者：带特性
	var plain := ma.duplicate(true)
	plain.erase("traits")
	plain.erase("trait")
	_spawn_at(world, Vector2(220.0, 120.0), plain, {}, sys)   # 同贴图但无特性
	sys._pop_hold = 0.0                                       # 手动让缓存失效
	var after_n := sys.featured_enemy_count()
	_check(after_n == before_n + 1,
			"只 +1（掠夺者算、无特性兵种不算）：%d → %d" % [before_n, after_n])

	# P-7) 端到端：把计数缓存钉住，就能在同一个场景里分别演「怪少」与「怪多」，
	#      验证判定**真的**走了缩放后的概率（chance_base=0 / chance_max=1 这组合下
	#      怪少必刷、怪多必不刷，没有随机性）
	var swing := _with_trait(ma, {
		"id": "death_split",
		"stages": [{"count": 2, "chance_base": 0.0, "chance_max": 1.0}],
		"spawn_interval_seconds": 0.0, "scatter_px": 0.0,
		"drop_from_splits": false, "max_live_split_enemies": 0,
	})
	var w5 := _world()
	var s5 = _make_system(w5)
	s5._pop_count = 0
	s5._pop_hold = 999.0                 # 钉住「场上一个都没有」
	var a5 = _spawn_at(w5, Vector2(700.0, 200.0), swing, {}, s5)
	a5.take_damage(99999)
	_check(s5.pending_split_count() == 2,
			"怪少 → 概率拉满 → 必刷 2 个（实得 %d）" % s5.pending_split_count())
	s5._pending.clear()
	var b5 = _spawn_at(w5, Vector2(780.0, 200.0), swing, {}, s5)
	s5._pop_count = 9999
	s5._pop_hold = 999.0                 # 钉住「场上全是怪」
	b5.take_damage(99999)
	_check(s5.pending_split_count() == 0,
			"怪多 → 概率掉到 0 → 一个不刷（实得 %d）" % s5.pending_split_count())
	await _phys(2)


func _finish() -> void:
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_enemy_split] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

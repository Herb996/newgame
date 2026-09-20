extends Node
## ============================================================
## EnemySystem — 敌人生成（挂在 Main 下）
## 规则（Data/config/ 的 enemy 节点）：
##   count：一局生成数量（100）
##   min_distance_from_player_cells：距玩家出生点 ≥ 20 格
## 只刷在地板格上，位置不重复（先收集所有合法格再随机抽取）。
## 敌人 AI = 巡逻 + 追击（2026-09-14 用户定）：由 enemy.gd + enemy_*_state 实现，
## 这里负责构建共享 A* 网格并注入给每个敌人（性能关键：只建一次）。
##
## 死亡特性（2026-09-17 用户定，掠夺者；见 notify_death_split / notify_death_regen）：
##   刷完开局那批之后，本系统还兼职「特性刷怪队列」——敌人死亡时上报（带上是哪个特性，
##   一个实例只有一个），这里判定要不要刷、刷几个，把要刷的排进队列，**每帧最多放出一个**，
##   于是刷出来的个体是「在原地一个一个出来」而不是一次性冒出来。
##   death_split 额外用一批共享 Dictionary（引用语义）在兄弟之间传「还剩几个 / 轮到第几代」；
##   death_regen 不需要批次（它每次死亡都独立判）。
##   刷出来的孩子由这里把父的 feat 原样递回 enemy.setup() ⇒ 继承同一个特性。
##   因此 walls / tile_size / astar 必须存成成员，供运行期继续刷怪复用。
##
## 数量缩放（2026-09-17 用户定，防刷爆）：「掠夺者总数量越少，特性初始触发概率越高」。
##   每一个特性可以写 chance_base（怪多时的概率）与 chance_max（怪少时的上限），
##   实际概率 = lerp(chance_base, chance_max, population_factor())；
##   factor 由**场上带特性的活敌人数**（掠夺者本体 + 全部后代）决定，见 population_factor()。
##   没写这两个键的特性/代次仍用固定 chance（老写法不受影响）。
##   想临时关掉缩放：config 的 enemy_traits.population_scaling.enabled = false。
##
## 幻影分身（2026-09-17 用户定，同日改规格；弓手 phantom_double）：
##   与死亡特性并列的**第三种刷怪来源** —— 本体开局召唤 1~2 个分身，之后每
##   resummon_interval_seconds(默认 5s) 再补召 1~2 个（notify_phantom_summon）；
##   上限：单只本体 max_phantoms_per_owner(8) + 全场 max_live_phantoms(兜底)。
##   同样走 _pending 队列一个一个出来（不会一帧冒出两个）。
##   血量：分身**不共享**本体的血（2026-09-17 从「共享血池」改掉）——各自一份
##   = 本体 max_hp × hp_ratio_of_owner(20%)，打光即散；entry["phantom"] 那张共享
##   Dictionary 只用于**记账与整组血条广播**（整组统一显示组内最低血量，见 enemy.gd）。
##   本体倒下时分身一起消失；分身不会再召唤；分身越多本体受到的伤害越少。
##   分身不进 _live_split_count() ／ featured_enemy_count()，
##   所以既不挤占掠夺者的 max_live_split_enemies 名额，也不影响数量缩放。
## ============================================================

const ENEMY_SCENE := preload("res://Scenes/Enemy.tscn")

# 开局刷怪时存下来，运行期（死亡特性继续刷怪）用同一份
var _root: Node2D = null
var _walls: Array = []
var _tile_size: int = 16
var _astar: AStarGrid2D = null

# 特性刷怪队列：每项 {type, pos, batch, feat, scatter, interval}
var _pending: Array = []
var _spawn_gap := 0.0

# 数量缩放的计数缓存（见 featured_enemy_count）：雪崩时每次死亡都扫全场太浪费，
# 缓存 cache_seconds 秒；刷出新个体时立刻让它失效（计数要马上反映出来）。
var _pop_count := 0
var _pop_hold := 0.0


## 由 main.gd 在地图生成后调用，传入 MapGenerator 的结果
func setup(root: Node2D, map_data: Dictionary) -> void:
	var walls: Array = map_data["walls"]
	var reachable: Array = map_data["reachable"]
	var tile_size: int = int(map_data["tile_size"])
	var spawn_cell: Vector2i = map_data["spawn_cell"]
	var map_w: int = walls[0].size()
	var map_h: int = walls.size()

	var count := int(Config.get_value("enemy.count", 100))
	var min_d := float(Config.get_value("enemy.min_distance_from_player_cells", 20))

	# 收集所有"可达地板 + 距出生点足够远"的格子（不可达区域的敌人无意义）
	var candidates: Array = []
	for y in range(map_h):
		for x in range(map_w):
			if walls[y][x] or not reachable[y][x]:
				continue
			if Vector2(x, y).distance_to(Vector2(spawn_cell)) < min_d:
				continue
			candidates.append(Vector2i(x, y))

	if candidates.size() < count:
		push_warning("[Enemy] 合法格不足（%d < %d），只生成 %d 个" % [
			candidates.size(), count, candidates.size()])
		count = candidates.size()

	# A* 网格全体敌人共享：只构建一次（每个敌人各建一次会直接卡死）
	var astar := MapGenerator.build_astar(walls, tile_size)

	# 存成员供运行期（死亡分裂）继续刷怪复用；队列必须清空 —— 上一局残留的条目
	# 指向的是已经释放的 GameRoot，不清会在新局里刷到空气里。
	_root = root
	_walls = walls
	_tile_size = tile_size
	_astar = astar
	_pending.clear()
	_spawn_gap = 0.0
	_pop_count = 0
	_pop_hold = 0.0

	# 把墙体网格注入噪音系统（供隔墙衰减），只注一次
	NoiseSystem.setup(walls, tile_size)

	var types := _type_pool()
	var tally := {}

	# 洗牌抽取，保证不重复
	candidates.shuffle()
	for i in range(count):
		var c: Vector2i = candidates[i]
		var enemy := ENEMY_SCENE.instantiate()
		enemy.position = Vector2(c) * tile_size + Vector2(tile_size * 0.5, tile_size * 0.5)
		root.add_child(enemy)
		# 入树后再注入导航数据，保证 global_position（= 巡逻中心）已正确
		var t: Dictionary = types[randi() % types.size()]
		enemy.setup(walls, tile_size, astar, t, {}, self)
		var tid := str(t.get("id", "?"))
		tally[tid] = int(tally.get(tid, 0)) + 1

	print("[Enemy] 敌人生成完成：%d 个（距出生点 ≥ %.0f 格，AI = 巡逻 + 追击）｜兵种 %s"
			% [count, min_d, str(tally)])


## 按 enemy_types.types[*].weight 展开成抽样池；未配置则回退成"单一匿名类型"，
## 这样 config 里删掉 enemy_types 也不会让敌人变成没有贴图的白方块。
func _type_pool() -> Array:
	var out: Array = []
	for t in Config.get_value("enemy_types.types", []):
		if not (t is Dictionary):
			continue
		var w: int = maxi(1, int((t as Dictionary).get("weight", 1)))
		for _k in range(w):
			out.append(t)
	if out.is_empty():
		out.append({})
	return out


# ------------------------------------------------------------
# 死亡特性（数值全在 Data/config/ 的 enemy_types.types[*].traits[]，见 enemy.gd）
#
# 兵种可以带一个**特性池** traits[]（或旧式单数 trait）：每个实例生成时随机分配其中一个，
# 一个角色只有一种特性；特性刷出来的孩子继承父的那一个。已知两种：
#
#   death_split 死亡分裂：stages[] 按顺序递进（{count, chance}），
#                **同一批的最后一个**死亡时才轮到下一代；stages 用完就停。
#   death_regen 死亡再生：平铺的 count + chance，**每次死亡都独立掷**，不看「最后一个」。
#
# 两者共用：
#   spawn_interval_seconds：相邻两个的间隔（"一个一个出来"，不是一次冒一堆）
#   scatter_px：落点随机半径（0 = 严格原地重叠）
#   drop_from_splits：特性刷出来的个体掉不掉落（默认 false）
#   max_live_split_enemies：同屏（特性刷出来的）数量上限（0 = 不限）
# ------------------------------------------------------------


# ------------------------------------------------------------
# 数量缩放：场上带特性的敌人越少 → 特性触发概率越高（防刷爆）
# ------------------------------------------------------------

## 数量缩放系数：1.0 = 拉满到特性的 chance_max（场上掠夺者很少），
## 0.0 = 只用 chance_base（很多）。中间线性。count < 0 时取当前场上实际数量；
## 探针传一个具体值进来即可当纯函数验（不依赖场面）。
func population_factor(count: int = -1) -> float:
	var sc = Config.get_value("enemy_traits.population_scaling", {})
	if not (sc is Dictionary):
		return 0.0
	var cfg: Dictionary = sc
	if not bool(cfg.get("enabled", true)):
		return 0.0                       # 关掉缩放 = 永远停在基础概率
	var full_at := float(cfg.get("full_chance_at_or_below", 8))
	var base_at := float(cfg.get("base_chance_at_or_above", 40))
	var n := float(count if count >= 0 else featured_enemy_count())
	if base_at <= full_at:
		return 1.0 if n <= full_at else 0.0      # 两个阈值撞一起 → 退化成开关
	return clampf((base_at - n) / (base_at - full_at), 0.0, 1.0)


## 某特性某一代的**实际**触发概率（已经把数量缩放算进去）。判定处一律走它，别直接读 chance。
##   cfg 取值：特性写了 stages[] → 取 stage 那一代（越界 = 0，本来也不会触发）；
##             平铺写法（death_regen 这种没有 stages 的）→ 永远看特性本身。
##   写了 chance_max → 概率在 [chance_base, chance_max] 之间随数量滑动；
##   只写 chance      → 固定概率（老写法，完全不受数量影响）。
func trait_chance(feat: Dictionary, stage: int = 0, count: int = -1) -> float:
	var cfg: Dictionary = feat
	if feat.has("stages"):
		var s := _stage_of(feat, stage)
		if s.is_empty():
			return 0.0
		cfg = s
	if not cfg.has("chance_max"):
		return clampf(float(cfg.get("chance", 1.0)), 0.0, 1.0)
	var lo := clampf(float(cfg.get("chance_base", cfg.get("chance", 1.0))), 0.0, 1.0)
	var hi := clampf(float(cfg.get("chance_max", lo)), 0.0, 1.0)
	return lerpf(lo, maxf(lo, hi), population_factor(count))


## 场上**参与数量缩放**的活敌人数量（= 掠夺者本体 + 它分裂/再生出来的全部后代）。
## 计数口径是 enemy.gd::counts_toward_population()：**写了 chance_max 的特性才数**。
## 所以邪术师的「爆裂鼓手」（与数量无关）不进这个数 —— 否则邪术师一多，
## 掠夺者的分裂概率会被无辜压低（2026-09-17 修）。
## 带缓存（enemy_traits.population_scaling.cache_seconds）：雪崩时每次死亡都扫全场没必要。
func featured_enemy_count() -> int:
	if _pop_hold > 0.0:
		return _pop_count
	_pop_hold = maxf(0.0, float(Config.get_value(
			"enemy_traits.population_scaling.cache_seconds", 0.25)))
	_pop_count = _count_featured()
	return _pop_count


func _count_featured() -> int:
	var n := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if not e.has_method("counts_toward_population"):
			continue
		if bool(e.get("_dying")):
			continue                     # 死亡淡出中的不算活着（含此刻正在上报的这一只）
		if bool(e.counts_toward_population()):
			n += 1
	return n


## 某分裂特性的一代的配置（越界给空字典，调用处当"裂到头了"处理）
func _stage_of(tr: Dictionary, stage: int) -> Dictionary:
	var stages: Array = tr.get("stages", [])
	if stage < 0 or stage >= stages.size():
		return {}
	var s = stages[stage]
	return s if s is Dictionary else {}


## 由 enemy.gd 的 _report_death() 调用：某个分配了 death_split 的敌人死了。
## batch 是「同一批」共享的字典（引用语义，兄弟之间指同一个）：
##   stage = 这一批死后要触发的 stages 下标；alive = 这一批还剩几个活着
## 只有 alive 减到 0（= 用户说的"这 2 个中，最后一个死亡时"）才有资格触发下一代。
## 原始掠夺者没有批次 → 当作"只有 1 个的一批"，stage 从 0 起。
## feat：本实例**分配到的**那个特性（enemy.gd::_feat）。不传时回落兵种的单数 trait，
##       这样老写法（只写 trait、不带 traits 池）与老探针都还能用。
func notify_death_split(pos: Vector2, type_cfg: Dictionary, batch: Dictionary,
		feat: Dictionary = {}) -> void:
	# 注意：trait 在 GDScript 4 是**保留字**，不能拿它当变量名（会报
	# "Expected variable name after var"），所以这类局部变量叫 f（入参叫 feat）。
	var f: Dictionary = feat
	if f.is_empty():
		var tr = type_cfg.get("trait", {})
		f = tr if tr is Dictionary else {}
	if f.is_empty():
		return
	var b := batch
	if b.is_empty():
		b = {"stage": 0, "alive": 1}
	b["alive"] = int(b.get("alive", 1)) - 1
	if int(b["alive"]) > 0:
		return                                  # 这一批还没死完，等最后一个
	var stage := int(b.get("stage", 0))
	var s := _stage_of(f, stage)
	if s.is_empty():
		return                                  # stages 用完了，链到此为止
	var p := trait_chance(f, stage)             # 含数量缩放：怪少 → 概率高
	if randf() > p:
		return                                  # 概率没过
	var count: int = maxi(0, int(s.get("count", 0)))
	var cap := int(f.get("max_live_split_enemies", 0))
	if cap > 0:
		count = mini(count, maxi(0, cap - _live_split_count()))
	if count <= 0:
		return
	# 下一代共用一个新的批次字典：stage +1，alive = 这次真正要刷的数量
	var next_batch := {"stage": stage + 1, "alive": count}
	var entry := {
		"type": type_cfg,
		"pos": pos,
		"batch": next_batch,
		"feat": f,                       # 孩子继承父的特性（同一个 Dictionary）
		"scatter": float(f.get("scatter_px", 0.0)),
		"interval": maxf(0.0, float(f.get("spawn_interval_seconds", 0.1))),
	}
	for _i in range(count):
		_pending.append(entry)
	print("[Enemy] 死亡分裂：第 %d 代 → 排队刷 %d 个「%s」（概率 %.0f%%，场上特性怪 %d，队列共 %d）"
			% [stage + 1, count, str(type_cfg.get("name", type_cfg.get("id", "?"))),
			p * 100.0, featured_enemy_count(), _pending.size()])


## 由 enemy.gd 的 _report_death() 调用：某个分配了 death_regen 的敌人死了。
## 与 death_split 的**本质区别**：不看「最后一个」、不逐代递进 —— **每一次死亡都独立掷**，
## 掷过就按 count 排队刷（用户原话：「每次死亡，50 概率刷新出 2 个，这两个也有这个特性」）。
## 所以它不需要 batch；刷出来的孩子继承同一个 feat（enemy.gd::setup 的 feat 入参），
## 于是会一直链下去，直到概率不过或撞上 max_live_split_enemies。
func notify_death_regen(pos: Vector2, type_cfg: Dictionary, feat: Dictionary = {}) -> void:
	var f: Dictionary = feat
	if f.is_empty():
		var tr = type_cfg.get("trait", {})
		f = tr if tr is Dictionary else {}
	if f.is_empty():
		return
	if randf() > trait_chance(f, 0):            # 含数量缩放：怪少 → 概率高
		return                                  # 概率没过，这条链到此为止
	var count: int = maxi(0, int(f.get("count", 2)))
	var cap := int(f.get("max_live_split_enemies", 0))
	if cap > 0:
		count = mini(count, maxi(0, cap - _live_split_count()))
	if count <= 0:
		return
	var entry := {
		"type": type_cfg,
		"pos": pos,
		"batch": {},                            # 再生没有「同批」语义，永远是空的
		"feat": f,                              # 孩子继承父的特性（同一个 Dictionary）
		"scatter": float(f.get("scatter_px", 0.0)),
		"interval": maxf(0.0, float(f.get("spawn_interval_seconds", 0.1))),
	}
	for _i in range(count):
		_pending.append(entry)
	print("[Enemy] 死亡再生：排队刷 %d 个「%s」（概率 %.0f%%，场上特性怪 %d，队列共 %d）"
			% [count, str(type_cfg.get("name", type_cfg.get("id", "?"))),
			trait_chance(f, 0) * 100.0, featured_enemy_count(), _pending.size()])


## 由 enemy.gd::_summon_phantoms_if_needed() 调用：分到「幻影分身」的弓手一出生，
## 就随机召唤 1~2 个分身；之后本体每 resummon_interval_seconds(默认 5s) 再补召 1~2 个
## （用户原话：「每个只随机召唤一到两个……本体每隔5秒会再随机召唤1到2个，最多8个分身」）。
## 与死亡特性**不同**：这不是死亡触发，本体活着就持续补召（开局一次，之后按节拍再来）。
## 血量：分身**不再共享**本体的血（2026-09-17 改）——各自开一份 = 本体 max_hp × 20%，
## 见 enemy.gd::_setup_phantom；这里的 pool 只用来**记账 + 整组血条广播**。
## 名额：phantom_slots_left()（单只 8 具）与 max_live_phantoms（全场兜底）双重把关。
## 走同一条 _pending 队列 ⇒ 分身也是一个一个出来，不会一帧里噗地冒两个。
func notify_phantom_summon(owner: Node2D, type_cfg: Dictionary, feat: Dictionary,
		pos: Vector2) -> void:
	if owner == null or not is_instance_valid(owner):
		return
	var f: Dictionary = feat
	if f.is_empty():
		return
	var sc = Config.get_value("enemy_traits.phantom", {})
	var pcfg: Dictionary = sc if sc is Dictionary else {}
	if not bool(pcfg.get("enabled", true)):
		return                                  # 全局关掉：弓手照常刷，只是不带分身
	var lo: int = maxi(0, int(f.get("count_min", 1)))
	var hi: int = maxi(lo, int(f.get("count_max", 2)))
	var count := randi_range(lo, hi) if hi > lo else lo
	# 单只本体的名额（活着的 + 队列里没出生的一起算）：8 具满了就不再排。
	# 本体每 resummon_interval_seconds 会再来问一次，所以这里必须把"排队中"也算进去，
	# 不然补召会一帧接一帧地塞队列，把 max_phantoms_per_owner 顶穿。
	count = mini(count, phantom_slots_left(owner, f))
	# 全场硬兜底（enemy_traits.phantom.max_live_phantoms）
	var cap := int(pcfg.get("max_live_phantoms", 0))
	if cap > 0:
		count = mini(count, maxi(0, cap - _live_phantom_count() - _pending_phantom_count()))
	if count <= 0:
		return
	if not owner.has_method("phantom_pool"):
		return
	var pool: Dictionary = owner.phantom_pool()
	if pool.is_empty():
		return
	var entry := {
		"type": type_cfg,
		"pos": pos,
		"batch": {},
		"feat": f,                              # 分身带着同一个特性（但它不会再召唤，见 enemy.gd）
		"phantom": pool,                        # 共享血量池（引用语义）——本体与分身同一个字典
		"scatter": maxf(0.0, float(f.get("spawn_radius_px", 96.0))),
		"snap_open": true,                      # 落点吸附到可走格心（分身掉进墙里就废了）
		"interval": maxf(0.0, float(f.get("spawn_interval_seconds", 0.15))),
	}
	for _i in range(count):
		_pending.append(entry)
	print("[Enemy] 幻影分身：%s 召唤 %d 个分身（队列共 %d）"
			% [str(type_cfg.get("name", type_cfg.get("id", "?"))), count, _pending.size()])


## 当前活着的幻影分身上限计数（enemy_traits.phantom.max_live_phantoms 用）。
## 只在召唤时算一次，不在每帧调用；「正在消失」的不算。
func _live_phantom_count() -> int:
	var n := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if not e.has_method("is_phantom"):
			continue
		if bool(e.get("_dying")):
			continue
		if bool(e.call("is_phantom")):
			n += 1
	return n


## 这只本体还能再召几具分身（0 = 满了，用户定的单只上限 8 具）。
## **活着的 + 队列里还没出生的一起算** —— 否则本体每 5 秒问一次，
## 每次都按"场上还没满"塞队列，最后会冲出上限一大截。
## feat 里没写就看全局段 enemy_traits.phantom.max_phantoms_per_owner；<= 0 = 不限。
func phantom_slots_left(owner: Node2D, feat: Dictionary = {}) -> int:
	if owner == null or not is_instance_valid(owner):
		return 0
	var cap := int(feat.get("max_phantoms_per_owner",
			Config.get_value("enemy_traits.phantom.max_phantoms_per_owner", 8)))
	if cap <= 0:
		return 9999                     # 不限
	var used := _pending_phantom_count(owner)
	if owner.has_method("live_phantoms"):
		used += (owner.call("live_phantoms") as Array).size()
	return maxi(0, cap - used)


## 刷怪队列里还没出生的分身个数（owner 非空 = 只数属于它的那些）。
func _pending_phantom_count(owner = null) -> int:
	var n := 0
	for e in _pending:
		var pool = (e as Dictionary).get("phantom", {})
		if not (pool is Dictionary) or (pool as Dictionary).is_empty():
			continue
		if owner != null and (pool as Dictionary).get("owner", null) != owner:
			continue
		n += 1
	return n


## 分裂体的刷怪节奏：不是一次性 add_child 完，而是每帧最多放出一个。
## 队列头部带着自己的 interval（特性可能各不相同），所以不用去翻 config。
func _physics_process(delta: float) -> void:
	# 数量缩放的计数缓存计时。与队列无关，所以必须放在下面那个提前 return **之前**，
	# 否则队列一空就永远不递减、计数永远不刷新。
	if _pop_hold > 0.0:
		_pop_hold = maxf(0.0, _pop_hold - delta)
	if _pending.is_empty():
		return
	_spawn_gap += delta
	var head: Dictionary = _pending[0]
	if _spawn_gap < float(head.get("interval", 0.1)):
		return
	_spawn_gap = 0.0
	_spawn_one(_pending.pop_front())


## 真正 instantiate 一个分裂体。落点与朝向规则与开局刷怪完全一致，
## 区别只在多带一个 batch（它会继续裂）和可以带散射。
func _spawn_one(entry: Dictionary) -> void:
	if _root == null or not is_instance_valid(_root):
		return
	# 幻影分身：本体若已经倒下，这具就没必要出生了（队列里可能还排着没出来的）
	var pool = entry.get("phantom", {})
	if pool is Dictionary and not (pool as Dictionary).is_empty():
		var own = (pool as Dictionary).get("owner", null)
		if not is_instance_valid(own) or bool(own.get("_dying")):
			return
	var pos: Vector2 = entry.get("pos", Vector2.ZERO)
	var scatter := float(entry.get("scatter", 0.0))
	if scatter > 0.0:
		pos += Vector2.RIGHT.rotated(randf() * TAU) * (randf() * scatter)
	if bool(entry.get("snap_open", false)):
		pos = _snap_open(pos)
	var enemy := ENEMY_SCENE.instantiate()
	enemy.position = pos
	_root.add_child(enemy)
	# 入树后再注入：global_position（= 巡逻中心）此时才等于落点
	enemy.setup(_walls, _tile_size, _astar, entry.get("type", {}),
			entry.get("batch", {}), self, entry.get("feat", {}), pool)
	_pop_hold = 0.0     # 场上刚多了一个特性怪：立刻让计数缓存失效，概率马上跟着往下走


## 落点吸附到最近的可走格心（幻影分身用：掉进墙里/水里的分身等于没有）。
## 找不到可达格就原样返回（宁可站错也不要凭空消失）。
func _snap_open(pos: Vector2) -> Vector2:
	if _walls.is_empty():
		return pos
	var cell := Vector2i(int(pos.x / _tile_size), int(pos.y / _tile_size))
	var open := MapGenerator.nearest_open_cell(_walls, cell, 4)
	if open.x < 0:
		return pos
	return Vector2(open) * float(_tile_size) + Vector2(_tile_size * 0.5, _tile_size * 0.5)


## 当前活着的**特性刷出来的**数量（不含开局刷的原始怪）。
## 注意与 featured_enemy_count() 的区别：那个数的是「所有带特性的」，
## 这个只数后刷出来的 —— max_live_split_enemies 上限卡的是后者，数量缩放看的是前者。
## 只在触发特性时算一次，不在每帧调用。
## 「正在死亡淡出」的不算（包括此刻正在上报的这一只，它马上就要消失了）。
func _live_split_count() -> int:
	var n := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if not e.has_method("is_split_spawn"):
			continue
		if bool(e.get("_dying")):
			continue
		# 幻影分身不算进来：它跟本体共享一条命、也不会继续裂，
		# 数进来只会平白挤占掠夺者的 max_live_split_enemies 名额。
		if e.has_method("is_phantom") and bool(e.call("is_phantom")):
			continue
		if bool(e.is_split_spawn()):
			n += 1
	return n


## 探针用：队列里还排着几个没出来
func pending_split_count() -> int:
	return _pending.size()

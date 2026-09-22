extends Area2D
## ============================================================
## Enemy — 敌人单位（功能组件层 + 巡逻/追击 AI）
##
## 分层（与 player.gd 同构）：
##   · 本文件 = 功能组件层：导航、寻路、感知、移动、受击、近战出手
##   · Scripts/combat/states/enemy_*.gd = 行为决策层（FSM）：决定巡逻还是追击
##
## AI（2026-09-14 用户定：巡逻 + 追击）：
##   Patrol 巡逻 —— 在出生点周围 patrol_radius_cells 内随机选可达点走过去，
##                  到达后停留 patrol_idle_seconds，再选下一个点。
##   Chase  追击 —— 视野（vision_cells）内发现玩家即追，追击速度更快；
##                  脱离视野 lose_sight_seconds 后放弃，回到巡逻。
##
## 视野（2026-09-15 用户定：加墙体遮挡）：
##   can_see_player() = 距离判定 + 视线射线（沿线段按 los_step_cells 采样墙体格）。
##   隔墙看不见；跟丢后不再追玩家实时位置，只走向最后已知位置（last known position）。
##
## 近战出手（2026-09-19 用户定：「敌人应该要有攻击距离这个属性，进入攻击距离就开始攻击」）：
##   中心距 ≤ attack_range_px() 就出手：立刻播攻击动作 + 进冷却，前摇 windup_seconds 之后
##   才结算伤害（玩家跑出射程就是挥空，但动作和冷却不回收）。见 _tick_attack()。
##   **出手与"掉没掉血"是两件事**：早先整段写在 `if player.take_damage(...)` 里面，于是
##   玩家闪避无敌帧 / 防御叠满挡下时，敌人既不播动作也不进冷却，看着就是"贴着我一动不动"。
##   事故记录：再早接触伤害靠 Area2D 的 body_entered（敌人半径 14 + 玩家 16 = 30px 内才触发），
##   而分离层（combat.separation）把敌人钉在 enemies 22 + player 20 = 42px 外 —— 两个半径
##   没对上，全图敌人一刀都打不出来，且探针（直调 take_damage）全绿。
##   这条几何关系由 Dev/probe_enemy_attack.gd 按 config 实算把住，改半径会立刻红。
##
## 掉落（2026-09-15 用户定：击杀掉落）：
##   死亡时按 enemy.drop.chance 概率在原地生成一个 LootNode（复用资源点场景），
##   种类按 enemy.drop.weights 加权随机，数量在 amount_min~amount_max 之间。
##   兵种可在自己的 drop 段里逐键覆盖全局表（_drop_cfg()）—— 用户 2026-09-19 说
##   「先做会掉落物品的机制，具体的后面加」，那个"具体的"就是往 type_cfg.drop 里写表。
##
## 死亡画面（2026-09-19 复查，用户预期「要有死亡画面」）：
##   _die() 先结算（上报特性 / 掉落 / 收血条 / 清幻影），再走两条表现分支：
##     · 兵种有 dead 帧 → _tick_death() 按 enemy.death_fps 一帧帧贴死亡帧，播完才淡出
##       （素材包里目前**只有 ep_troll 有 dead 帧**，其余兵种没有 = 直接进淡出）；
##     · 淡出 _fade_out() = 透明 + 缩小 + 下沉三件事同时做（读起来是"倒下"不是"被抠掉"），
##       时长 enemy.death_fade_seconds，播完 queue_free。
##   全程 _dying=true：AI 停摆、不再受伤、也不再出手（尸体不能打人）。
##
## 死亡特性（2026-09-17 用户定，目前只有掠夺者带）：
##   config 里兵种可以写 traits[]（特性池）或旧式 trait（单个）。**每个实例在生成时
##   按 weight 从池里随机分配一个**——一个角色只有一种特性（用户原话：「死亡一个角色
##   只能有一个特性，随机分配」）；特性刷出来的孩子**继承父的特性**。
##   已知两种：death_split（死亡分裂，同一批的**最后一个**才触发下一代、逐代递进）
##              death_regen（死亡再生，**每次死亡都独立判定**，不看「最后一个」）
##   本文件不认识细节——敌人只负责「我死了 + 我是什么特性」上报，策略全在
##   enemy_system.gd::notify_death_split() / notify_death_regen()。
##
## 非死亡特性（2026-09-17 用户定，邪术师「爆裂鼓手」burst_drum）：
##   不死也能持续生效，所以行为挂在「发声」与「受击」两个既有钩子上：
##     · noise_amplify    —— 放大**小队自己**造成的噪音。光环：按发声点距离线性加权，
##                           见 noise_amplify_gain()；由 noise_system.gd 在 emit() 里
##                           遍历 "noise_amplifiers" 组求和（没邪术师时组为空，零开销）。
##     · damage_reduction —— 血量越低受到的伤害越少，见 incoming_damage()；有 min_damage
##                           保底，残血也会被打死，不会变成无敌。
##
## 幻影分身（2026-09-17 用户定，同日改规格；弓手 phantom_double「幻影分身」）：
##   用户原话：「每个只随机召唤一到两个，召唤的分身只有本体20%的血量，分身不会再召唤分身，
##     本体每隔5秒会再随机召唤1到2个，最多8个分身，分身越多，自身受到伤害越少」
##   ＋「这批角色（本体加召唤）按最低血条展示，不管攻击哪个，显示血条最低的，迷惑玩家」。
##   实现要点（本文件 + enemy_system.gd::notify_phantom_summon）：
##     · 分身 = 同一兵种的普通敌人实例，带 _phantom_pool（与本体**共享同一个 Dictionary**，
##       引用语义；池里 owner 指向本体、members 收全部活分身）。池只用来**记账与广播**，
##       不再是血量权威 —— 那是早先「共享血池」版本的写法，已被用户改掉。
##     · 血量：分身有**自己的一份**（= 本体 max_hp × hp_ratio_of_owner，默认 20%），
##       出生满血、挨打扣自己的、打光就自己消失（vanish_as_phantom），**不**转嫁给本体。
##     · 血条：**整组按组内最低血量显示** —— display_hp_ratio() 取
##       min(本体 hp, 全部分身 hp) ÷ 本体 max_hp；组内谁掉血都 refresh_group_hp_bar() 广播全组。
##       分身天生只有本体 20% 的血 ⇒ 场上有分身时整组血条一直是「残血」的样子，
##       打哪个都是同一条、都像快死了（这就是"迷惑玩家"的核心）。
##     · 分身 `damage = 0` 且 _tick_attack() / _deal_attack_damage() 里分身直接返回 ⇒ 打玩家不掉血。
##     · 本体每跨过一个 swap_hp_step_ratio(20%) 台阶 → _swap_with_random_phantom()
##       随机挑一个活着的分身**交换坐标**（本体/分身各自的巡逻中心也跟着挪，
##       否则本体一步走回原地就露馅了）。
##     · 本体每隔 resummon_interval_seconds(默认 5s) 再补召 1~2 具；
##       名额由 enemy_system.gd 按 max_phantoms_per_owner(8) / max_live_phantoms 把关。
##     · 分身越多本体越硬：phantom_damage_reduction()，见 incoming_damage()。
##     · 本体死亡 → 分身一起消失（vanish_as_phantom()），不报特性、不掉落、不淡出成尸体。
##   血条本体件见 Scripts/enemy_hp_bar.gd（**颜色尺寸本体/分身完全一致** —— 别按 is_phantom 改色）。
##
## 劫掠者（brigand）的 AI（2026-09-17 用户定）：
##   「他的机制就是满地图随机游走，并且遇到同类会一起移动，上限先做到 5 个吧，
##     所以其他怪只在一个固定的范围内移动，受到攻击或者噪音，再移动，劫掠者对声音更敏感」
##   三件事全部**配置驱动**：全局默认在 enemy.ai，兵种用 enemy_types.types[*].ai 按键覆盖
##   （劫掠者三项都覆盖了，其余兵种不写 ai 段 = 老行为）。取值统一走下面这几个访问器，
##   不要在业务代码里直接读 config 的键。
##     · roam.mode = whole_map —— 巡逻时在**整张地图**上随机挑一个可达点走过去
##       （pick_roam_target）；home_radius 是其他兵种的老行为：只在出生点周围
##       patrol_radius_cells 内游荡 —— 即用户说的「其他怪只在一个固定的范围内移动」。
##     · pack（成群）—— 同类靠近到 join_radius_px 内即结伙，之后**跟着群主一起移动**；
##       max_members(5) 是每群硬上限，装满了不再收人。群 = 全群**共享同一个 Dictionary**
##       （引用语义，与幻影分身的池同一套写法）：{"leader": Node2D, "members": Array}。
##       群主负责选目标（全地图游走），成员只跟队形（follow_distance_px 之外才启程）；
##       群主死亡时由同群下一个活着的成员自动接任（_promote_pack_leader）。
##     · noise_sensitivity = 听力倍率（劫掠者 1.8）—— 唯一落点在 noise_system.gd::emit
##       的派发循环：按听者把「等效听力半径」放大，于是听得更远、同距离也更清。
##   「受到攻击也要动」是**所有敌人共用**的规则（不只劫掠者）：玩家造成伤害后由调用方
##   补一句 alert_from_attacker(攻击者位置)，敌人立刻转「调查」朝攻击者走（见 §5.5）。
##   刻意不塞进 take_damage()：那会改签名，且探针里那些「单纯测伤害数值」的假敌人不必跟。
##
## 性能保护（一局 100 个敌人）：
##   1. AStarGrid2D 由 EnemySystem 构建一次，全体敌人共享（绝不每人建网格）
##   2. 追击时按 repath_interval_seconds 节流重算路径，不是每帧重算
##   3. 距玩家超过 ai_active_radius_cells 的敌人进入休眠，完全不跑 AI
##
## 美术（2026-09-15 定：Tiny Swords 免费包）：
##   官方包没有"怪物"，用 4 个阵营/兵种单位当敌人，每人一套 idle/run/attack 帧。
##   表现层复用 PlayerAnimator（它的 parse_spec 支持"四向共用一组帧"的扁平写法），
##   所以敌人与玩家播帧逻辑完全一致，不需要第二套动画代码。
##   官方**没有受击/死亡动画** → 受击靠瞬间泛红，死亡靠缩放淡出（见 take_damage/_die）。
## ============================================================

const DROP_SCENE := preload("res://Scenes/LootNode.tscn")

## 带噪音放大特性（burst_drum）的敌人才进这个组；NoiseSystem 发声时只遍历它。
## 字符串必须与 noise_system.gd 里的同名常量一致（两边都写死，改动请一起改）。
const GROUP_NOISE_AMPLIFIERS := "noise_amplifiers"

## 素材原画朝哪个侧向 → 决定向左走时要不要水平镜像（PlayerAnimator.FLIP_*）。
## 21 个兵种的 idle/walk/attack 全是扁平单侧帧（没有 left/right 两套），所以"朝左"
## 只能镜像出来。逐兵种看过首帧（Dev/shot_enemy_facing.gd 有实拍）后分三类：
##   left = 原画头朝左，镜像规则要反过来，否则它追人会朝右倒着跑；
##   none = 没有"朝向"可言的静态物件（洞口），镜像只会让苔斑跳边。
## 没列在这里的兵种 = 原画朝右（默认）。兵种自己写 `art_facing` 键可覆盖本表。
const ART_FACING := {
	"ep_harpoon_shark": "left",
	"ep_paddle_shark": "left",
	"ep_cave": "none",
}
const ART_FACING_DEFAULT := "right"

var hp := 0
var max_hp := 0
var damage := 10                   # 单发伤害（由类型覆盖）
var speed_mult := 1.0              # 相对 enemy.speed 的速度倍率
var type_id := &""                 # 类型 id（调试/统计用）
var type_name := ""                # 类型中文名（HUD/调试用）
var _last_known := Vector2.ZERO   # 玩家最后被看到的位置（跟丢后走这里）

# --- 近战出手（数值在 _apply_type 里从 enemy.attack 读进来，热路径不反复查 config）---
var _attack_cooldown := 0.0        # 两次出手之间的间隔剩余秒
var _attack_range := 52.0          # 出手距离 px；必须 > 分离层把敌人顶住的那圈（见文件头）
var _attack_cd_seconds := 1.0
var _attack_windup := 0.18         # 前摇：出手后多久结算伤害
var _attack_min_dur := 0.3         # 攻击动作保底时长（无攻击帧的兵种也用得上）
var _attack_variance := 0.0        # 每刀伤害的随机浮动幅度（0.1 = ±10%）；0 = 每刀一个数
var _attack_hit_at := 0.0          # >0 = 这一刀已出手还在前摇，归零时结算（挥空也要走完）
var _fx_attack := ""               # 出手特效 id（_apply_type 里算一次：兵种没写就用
                                   # enemy.attack.fx_attack 那条默认；空串 = 不放）

# --- 表现层 ---
var _body: Sprite2D = null
var _animator: PlayerAnimator = null
var _hp_bar: Node = null           # 头顶血条（enemy_hp_bar.gd）；受伤才显示
var _anim_state := PlayerAnimator.Anim.IDLE
var _facing := Vector2(0.0, 1.0)   # 当前朝向（镜像判定用）。默认朝下 = 旧行为：不翻。
var _flip_mode := 0                # 本兵种的 PlayerAnimator.FLIP_*，_apply_type 里算好
var _attack_timer := 0.0           # >0 表示正在播攻击动作，播完回 idle/walk
var _attack_frames := 0            # 该兵种 attack 帧数（用于按帧率算挥砍时长）
var _attack_fps := 14.0            # 攻击帧率（与 PlayerAnimator.DEFAULT_FPS.attack 一致）
var _hit_flash := 0.0              # 受击泛红剩余秒数（白闪→红 两段的驱动）
var _hit_tween: Tween = null       # 受击 squash/击退回弹动画（命中瞬间重开，连击不打结）
var _hit_stun := 0.0               # 受击微停顿(hitlag)剩余秒，>0 时 AI 让位（敌人"被打愣"）
var _dying := false                # 已进入死亡淡出，不再参与 AI/受伤
var _fading := false               # _fade_out 已执行，防死亡动画结束后再调一次
var _death_frames: Array = []      # 死亡动画帧（Texture2D）；空 = 不播死亡帧，用旧淡出
var _death_elapsed := 0.0          # 死亡动画已播放秒数
var _death_fps := 8.0              # 死亡动画帧率

# --- 死亡特性（判定与派发在 enemy_system.gd）---
var _type_cfg: Dictionary = {}     # 本实例的兵种配置（特性池在它的 traits[] 里）
var _feat: Dictionary = {}         # 本实例**分配到的**那个特性（生成时随机挑，见 pick_feature）
var _from_trait := false           # true = 本实例是特性刷出来的（分裂体/再生体），非开局怪
var _split: Dictionary = {}        # 与同批兄弟**共享同一个字典**（引用语义）；空 = 不是特性刷出来的
var _system: Node = null           # EnemySystem：刷怪交回它统一做；探针可不注入

# --- 幻影分身（phantom_double，2026-09-17）---
# _phantom_pool：本体与全部分身**共享同一个字典**（引用语义）——
#   {"owner": Node2D, "members": Array}。只用于记账与「整组血条广播」。
#   血量各自独立：分身那一份在 _setup_phantom 里按 hp_ratio_of_owner 现开。
var _phantom_pool: Dictionary = {}
var _is_phantom := false           # true = 我是一具分身（不是本体）——分身不再召唤、不掉落、不造成伤害
var _swap_step := 0                # 本体已触发的「掉 20% 血」台阶数（每跨一个台阶，和分身换一次位置）
var _resummon_timer := 0.0         # 本体「每隔 N 秒再补召 1~2 具」的倒计时（只有本体在跑）

# --- 状态层（技能系统，2026-09-21）---
# 冻结 / 灼烧 / 以后任何状态都进这一个容器：一张 id→{剩余,层数} 的表，
# 定义全在 config 的 skills.statuses 里（见 Scripts/combat/unit_status.gd）。
# 没有状态时它是空表，下面那几处乘数都是 1.0 / false —— 等于这些代码不存在。
var _statuses := UnitStatus.new()

# --- 噪音警觉度（DESIGN.md 第二部分 噪音机制）---
var noise_alertness := 0.0
var _noise_source := Vector2.ZERO   # 最后听到的声源位置（调查状态前往这里）

# --- 成群（pack，2026-09-17；劫掠者专属，靠 config 的 ai.pack.enabled 开关）---
# 全群**共享同一个字典**（引用语义）：{"leader": Node2D, "members": Array}。
# 只有 pack.enabled 的兵种才会建群；空字典 = 没成群（绝大多数敌人，零开销）。
var _pack: Dictionary = {}
var _pack_scan_timer := 0.0         # 「找同类结伙」的节流计时
var _follow_timer := 0.0            # 「跟群主」的寻路节流计时
var _ai_cache: Dictionary = {}      # 合并后的 ai 配置缓存（enemy.ai ← 兵种 ai，见 ai_cfg）

# --- 导航（由 EnemySystem 注入） ---
var _walls: Array = []
var _tile_size: int = 16
var _astar: AStarGrid2D = null       # 共享网格，勿在本脚本内重建
var _home := Vector2.ZERO            # 巡逻中心（出生点）

var _path := PackedVector2Array()
var _path_index := 0
var _has_target := false
var _repath_timer := 0.0

var _dormant := false
var _dormant_check := 0.0

var state_machine: StateMachine


func _ready() -> void:
	add_to_group("enemies")
	visible = false  # 初始隐藏，等雾系统第一帧判定
	_body = get_node_or_null("Body") as Sprite2D
	_hp_bar = get_node_or_null("HpBar")
	# 兜底：类型由 setup() 注入，但 _ready 早于 setup，先用全局默认值起手
	max_hp = int(Config.get_value("enemy.max_hp", 40))
	hp = max_hp
	_home = global_position
	_init_state_machine()


func _physics_process(delta: float) -> void:
	if _dying:
		_tick_death(delta)           # 死亡动画推进（播完才淡出）；不跑 AI、不再受伤
		return
	# 状态层必须在下面 `_dormant` 的提前 return **之前**走：远处的敌人解冻中却没人
	# 替它倒数，剩余时长会永久卡在解冻那一帧（下次进视野直接是"永远差一点到期"）。
	# DoT 伤害由容器直接回调本脚本 take_damage()，于是减伤特性、血条刷新照旧生效。
	_statuses.tick(delta, self)
	var frozen := _statuses.halts_ai()
	if _attack_cooldown > 0.0:
		_attack_cooldown -= delta
	if _attack_timer > 0.0:
		_attack_timer -= delta
	if frozen:
		_attack_hit_at = 0.0         # 冻住 = 手里那一刀作废（不是暂停、解冻再补上）
	elif _attack_hit_at > 0.0:
		_attack_hit_at -= delta
		if _attack_hit_at <= 0.0:
			_deal_attack_damage()      # 前摇走完：这一刀落地（或挥空）
	if _hit_flash > 0.0:
		_hit_flash -= delta
	# 幻影分身：本体活着就每隔 resummon_interval_seconds 再补召 1~2 具。
	# 名额把关全在 enemy_system.gd（单只上限 8 + 全场兜底），满了自然召不出来。
	_tick_phantom_resummon(delta)
	# 噪音警觉度随时间衰减（听到动静→去查看→没发现→慢慢放松）
	if noise_alertness > 0.0:
		noise_alertness = maxf(0.0, noise_alertness
				- float(Config.get_value("noise.decay_per_second", 10.0)) * delta)
	# 休眠判定（0.5 秒一次，避免每帧测量距离）
	_dormant_check += delta
	if _dormant_check >= 0.5:
		_dormant_check = 0.0
	_dormant = distance_to_player_cells() > ai_active_radius_cells()
	if _dormant:
		return
	if frozen:
		pass                         # 冻住：整段 AI/导航/出手让位，只留下面的动画与染色照常刷新
	elif _hit_stun > 0.0:
		_hit_stun -= delta           # 受击微停顿：AI/导航让位，但动画与染色照常刷新
	else:
		_tick_pack(delta)          # 成群：找同类结伙 + 成员跟上群主（只有带 pack 的兵种有开销）
		state_machine.physics_update(delta)
		_tick_attack(delta)        # 近战出手：进了射程就挥（见文件头「近战出手」）
	_update_anim(delta)
	# 染色必须在动画器之后：动画器每帧会写 modulate，放前面会被覆盖掉
	_update_alert_visual()


func _init_state_machine() -> void:
	state_machine = StateMachine.new()
	state_machine.name = "StateMachine"
	add_child(state_machine)
	state_machine.setup(self, &"patrol",
			bool(Config.get_value("debug.log_state_transitions", false)))
	state_machine.add_state(EnemyPatrolState.new(self))
	state_machine.add_state(EnemyInvestigateState.new(self))
	state_machine.add_state(EnemyChaseState.new(self))
	state_machine.start()


## 由 EnemySystem 调用：注入地图导航数据（共享 A* 网格）+ 本实例的兵种配置。
## type_cfg 为空时退化为 config 的 enemy.max_hp / enemy.contact_damage 单一敌人类型。
## split_batch：死亡分裂的「同批」共享状态（只有特性刷出来的个体才非空，见 enemy_system.gd）。
## system：EnemySystem 自己；刷怪要在那边做（那边有 walls/tile_size/astar 与刷怪队列）。
## feat：本实例的特性。**留空 = 从兵种的特性池随机分配一个**（开局刷怪就是这个路径）；
##       特性刷出来的孩子由 EnemySystem 把父的特性原样递回来 ⇒ 继承同一个特性。
## phantom：幻影分身的**共享记账池**（见 _setup_phantom）。只有分身非空；留空 = 本体。
func setup(walls: Array, tile_size: int, astar: AStarGrid2D,
		type_cfg: Dictionary = {}, split_batch: Dictionary = {},
		system: Node = null, feat: Dictionary = {}, phantom: Dictionary = {}) -> void:
	_walls = walls
	_tile_size = tile_size
	_astar = astar
	_home = global_position
	_type_cfg = type_cfg
	_ai_cache = {}          # 兵种配置到手 → 合并缓存作废（_ready 里的状态机起手可能已经问过一次）
	_split = split_batch
	_system = system
	_from_trait = not feat.is_empty()
	_feat = feat if _from_trait else pick_feature(type_cfg)
	_apply_type(type_cfg)
	_setup_phantom(phantom)
	_register_feature_groups()
	_ensure_pack()                     # 成群：带 pack 的兵种一出生就自建一个只有自己的群
	_summon_phantoms_if_needed()


## 把「需要被别的系统按组遍历」的特性实例登记进对应的组。
## 目前只有 burst_drum（噪音放大）：NoiseSystem 在玩家每次发声时都要问一遍放大器，
## 挂进组后**没有邪术师时组是空的 → 零开销**（不然每次发声都得扫全场敌人做 has_method）。
func _register_feature_groups() -> void:
	if feature_id() == "burst_drum":
		add_to_group(GROUP_NOISE_AMPLIFIERS)


# ------------------------------------------------------------
# 幻影分身（phantom_double，弓手；详见文件头说明）
# 用户原话：「随机召唤 1-2 个分身，分身无法造成伤害，本体每掉 20% 的血，就会随机
# 和分身互换，迷惑玩家，本体和分身的血条同步改变。」
# ------------------------------------------------------------

## 接住共享记账池（由 EnemySystem 在刷分身时传入本体那一份）。
## 分身：登记进 pool.members，并按 hp_ratio_of_owner 开出**自己那份**血（满血）。
## 本体：自己建一个空池（owner = 自己），等着分身进来，并起手补召计时。
func _setup_phantom(pool: Dictionary) -> void:
	_is_phantom = not pool.is_empty()
	if _is_phantom:
		_phantom_pool = pool
		damage = 0                  # 分身无法造成伤害（_tick_attack 里还会再拦一道）
		var members = _phantom_pool.get("members", null)
		if members is Array:
			members.append(self)
		# 分身只有本体的一小份血（用户定：本体 max_hp 的 20%），出生满血、独立结算。
		var own = _phantom_pool.get("owner", null)
		if is_instance_valid(own):
			var share := float(_feat.get("hp_ratio_of_owner",
					Config.get_value("enemy_traits.phantom.hp_ratio_of_owner", 0.2)))
			max_hp = maxi(1, int(round(float(own.get("max_hp")) * maxf(0.01, share))))
			hp = max_hp
	else:
		_phantom_pool = {"owner": self, "members": []}
		_resummon_timer = _resummon_interval()
	# 刷新整组血条：分身一出生，整组立刻按「组内最低」变成残血的样子
	# （本体身边没分身时 shown 仍是 1.0，不会平白闪一条满血条出来）。
	refresh_group_hp_bar(false)


## 本体「每隔 5 秒再随机召唤 1~2 具」的节拍（用户 2026-09-17 定）。
## 分身不参与（用户明确要求「分身不会再召唤分身」）；间隔 <= 0 视为关闭。
func _tick_phantom_resummon(delta: float) -> void:
	if _is_phantom or feature_id() != "phantom_double":
		return
	var iv := _resummon_interval()
	if iv <= 0.0:
		return
	_resummon_timer -= delta
	if _resummon_timer > 0.0:
		return
	_resummon_timer = iv
	_summon_phantoms_if_needed()


## 补召间隔（秒）。特性里没写就看全局段，默认 5 秒；<= 0 = 不补召。
func _resummon_interval() -> float:
	var v := float(_feat.get("resummon_interval_seconds", -1.0))
	if v < 0.0:
		v = float(Config.get_value("enemy_traits.phantom.resummon_interval_seconds", 5.0))
	return v


## 让 EnemySystem 把分身排进刷怪队列：开局出生走一次，之后由 _tick_phantom_resummon 按节拍再走。
## 分身（_is_phantom）不再召唤 —— 否则会指数繁殖；探针不注入 system 时也不召唤，
## 这样纯逻辑断言可以在没有刷怪队列的场景里跑。
## 名额（单只本体的 8 具上限 / 全场兜底）不在本文件判，统一交给 enemy_system.gd。
func _summon_phantoms_if_needed() -> void:
	if _is_phantom or feature_id() != "phantom_double":
		return
	if _system == null or not is_instance_valid(_system):
		return
	if not _system.has_method("notify_phantom_summon"):
		return
	_system.notify_phantom_summon(self, _type_cfg, _feat, global_position)


## 我是真人还是幻影（探针/HUD/统计用）
func is_phantom() -> bool:
	return _is_phantom


## 本体的共享记账池（分身与本体是**同一个 Dictionary 实例**，引用语义）。
## 注意：它**不是**血量权威 —— 全组血量各自独立，池只用来数人头与广播血条。
func phantom_pool() -> Dictionary:
	return _phantom_pool


## 活着的分身（排除正在消失的）。本体调用；分身调用返回空数组。
func live_phantoms() -> Array:
	var out: Array = []
	if _is_phantom:
		return out
	var members = _phantom_pool.get("members", [])
	if not (members is Array):
		return out
	for m in members:
		if not is_instance_valid(m):
			continue
		if bool(m.get("_dying")):
			continue
		out.append(m)
	return out


func phantom_count() -> int:
	return live_phantoms().size()


## 自己这条血的比例（血条**不**直接用这个 —— 见 display_hp_ratio）。
func hp_ratio() -> float:
	return clampf(float(hp) / float(maxi(1, max_hp)), 0.0, 1.0)


## 血条要显示的比例 —— **「整组按最低血条展示」的落点**（用户 2026-09-17 定：
## 「这批角色（本体加召唤）按最低血条展示，不管攻击哪个，显示血条最低的，迷惑玩家」）。
## 本体与它的全部分身算一组，统一显示「组内最低血量 ÷ 本体 max_hp」。
## 分母恒用本体 max_hp：分身天生只有本体 20% 的血，所以场上一有分身，
## 整组血条就固定落在 20% 以下的「残血」区间 —— 这就是迷惑玩家的地方。
## 分身侧直接问本体要（本体是组里唯一算这个数的人），拿不到就退回自己的比例。
func display_hp_ratio() -> float:
	if _is_phantom:
		var own = _phantom_pool.get("owner", null)
		if is_instance_valid(own) and own.has_method("display_hp_ratio"):
			return float(own.call("display_hp_ratio"))
		return hp_ratio()
	var members = _phantom_pool.get("members", [])
	if not (members is Array) or (members as Array).is_empty():
		return hp_ratio()
	var lowest := hp
	for m in members:
		if not is_instance_valid(m):
			continue
		if bool(m.get("_dying")):
			continue
		lowest = mini(lowest, int(m.get("hp")))
	return clampf(float(lowest) / float(maxi(1, max_hp)), 0.0, 1.0)


## 组内任一成员的血量变了 → 把新比例广播给**整组**并让血条亮起。
## 本体调用：刷自己 + 全部分身；分身调用：转交本体（本体是组里唯一算数的人）。
func refresh_group_hp_bar(force_show := true) -> void:
	if _is_phantom:
		var own = _phantom_pool.get("owner", null)
		if is_instance_valid(own) and own.has_method("refresh_group_hp_bar"):
			own.call("refresh_group_hp_bar", force_show)
			return
		_update_hp_bar(force_show)
		return
	_update_hp_bar(force_show)
	var members = _phantom_pool.get("members", [])
	if not (members is Array):
		return
	for m in members:
		if is_instance_valid(m) and m.has_method("_update_hp_bar"):
			m.call("_update_hp_bar", force_show)




## 刷新头顶血条：比例 + 位置（位置可被 config 调）+ 是否该显示。
## 比例走 display_hp_ratio()（**整组按组内最低血量显示**），不是自己的 hp_ratio ——
## 分身一出生，整组血条就会一起变成「残血」样，这正是幻影分身要的迷惑效果。
## force_show：出生 / 挨打 / 组内血量变动时亮一下。
func _update_hp_bar(force_show := false) -> void:
	if _hp_bar == null or not is_instance_valid(_hp_bar):
		return
	if not bool(Config.get_value("enemy.hp_bar.enabled", true)):
		return
	var shown := display_hp_ratio()
	if _hp_bar.has_method("set_ratio"):
		_hp_bar.call("set_ratio", shown)
		_hp_bar.position = Vector2(0.0, float(Config.get_value("enemy.hp_bar.offset_y", -68.0)))
	if (force_show or shown < 1.0) and _hp_bar.has_method("flash"):
		_hp_bar.call("flash")


func _hide_hp_bar() -> void:
	if _hp_bar != null and is_instance_valid(_hp_bar) and _hp_bar.has_method("hide_bar"):
		_hp_bar.call("hide_bar")


## 本体每跨过一个「掉 swap_hp_step_ratio(默认 20%)」的台阶，就和随机一个分身换一次位置。
## 例：满血 → 掉到 80% 触发第 1 次、60% 第 2 次、40% 第 3 次、20% 第 4 次。
## 用**整数血量**算台阶（`已掉 / (max_hp × 比例)`）而不是浮点血量比：
## 24/30 这种比例在二进制里是 0.19999999999999996，用 hp_ratio() 会 floor 成 0、
## 白白吞掉一次互换（实测踩过）。末尾那个 1e-6 是给整除情形兜底的。
## 一次伤害哪怕跨多个台阶也只换一次（连换多次等于同帧内随机打乱，没有意义）。
func _check_phantom_swap() -> void:
	if _is_phantom:
		return
	var step_ratio := float(_feat.get("swap_hp_step_ratio", 0.2))
	if step_ratio <= 0.0:
		return
	var lost := float(maxi(0, max_hp - hp))
	var step_size := maxf(1.0, float(max_hp) * step_ratio)
	var step := int(floor(lost / step_size + 1e-6))
	if step <= _swap_step:
		return
	_swap_step = step
	if live_phantoms().is_empty():
		return      # 没分身可换：台阶照样记下，不攒着等分身出生后连闪
	_swap_with_random_phantom()


## 本体 ↔ 随机一具分身**交换坐标**。两边的巡逻中心(_home)也跟着换，
## 否则本体一步走回自己的老窝，玩家一眼就看穿了。
func _swap_with_random_phantom() -> void:
	var alive := live_phantoms()
	if alive.is_empty():
		return
	var other = alive[randi() % alive.size()]
	if not is_instance_valid(other):
		return
	var mine := global_position
	var theirs: Vector2 = other.global_position
	global_position = theirs
	other.global_position = mine
	# 巡逻中心与路径都要跟着挪（不然双方都会往原地跑回去）
	_home = global_position
	other._home = other.global_position
	clear_move_target()
	other.clear_move_target()


## 分身消失。两个调用方：① 本体死亡时连带收拾；② 分身自己那 20% 的血被打光。
## 都不上报特性、不掉落、不走"尸体淡出"（身后不留任何结算）。
## 注意：分身消失不改本体血量（血量各自独立），只会让本体的减伤少一档。
func vanish_as_phantom() -> void:
	if _dying:
		return
	_dying = true
	_hide_hp_bar()
	_fade_out()


## 本体死亡 → 所有分身一起消失（用户没明说，但不这样做会剩一堆孤儿幻影满地跑）
func _vanish_phantoms() -> void:
	if _is_phantom:
		return
	var members = _phantom_pool.get("members", [])
	if not (members is Array):
		return
	for m in members:
		if is_instance_valid(m) and m.has_method("vanish_as_phantom"):
			m.vanish_as_phantom()
	members.clear()


## 兵种数值段（**不含** hp=max_hp，也不碰贴图）。
## 拆出来是为了让调试面板改完 `enemy_types.types[*].hp` 这类值后能重算同一套式子 ——
## 面板里重抄一遍"兵种键 → 回落 enemy.max_hp"的顺序，下次改语义必然漏改一边。
## 不在这里写 hp = max_hp：重算数值时把全场怪顺手奶满，是玩家看不懂的副作用
## （出生满血留给 _apply_type）。
func _apply_numeric(type_cfg: Dictionary) -> void:
	if not type_cfg.is_empty():
		type_id = StringName(str(type_cfg.get("id", "")))
		type_name = str(type_cfg.get("name", type_cfg.get("id", "")))
		max_hp = int(type_cfg.get("hp", Config.get_value("enemy.max_hp", 40)))
		damage = int(type_cfg.get("damage", Config.get_value("enemy.contact_damage", 10)))
		speed_mult = float(type_cfg.get("speed_mult", 1.0))
	# 近战出手参数。放在 `if _body == null: return` 之前：没有 Body 的假敌人/无头探针
	# 照样要有射程与冷却，否则它们永远不打人，探针也就测不出东西。
	var atk: Dictionary = Config.get_value("enemy.attack", {})
	_attack_range = float(type_cfg.get("attack_range_px", atk.get("range_px", 52.0)))
	_attack_cd_seconds = float(atk.get("cooldown_seconds", 1.0))
	_attack_windup = float(atk.get("windup_seconds", 0.18))
	_attack_min_dur = float(atk.get("min_duration_seconds", 0.3))
	# 伤害浮动同样是全局档（不像 range_px 能按兵种覆盖）：250 只怪各调一个浮动区间
	# 只会让"这只打得疼"变成读不出原因的噪声。
	_attack_variance = float(atk.get("variance", 0.0))
	# 出手特效：兵种写了专属 id 用专属的，写空串（或没写）都回落到 enemy.attack.fx_attack。
	# 与上面几项一样放在 _body 判空之前：无 Body 的假敌人/探针也要能读到。
	var type_fx := str(type_cfg.get("fx_attack", ""))
	_fx_attack = type_fx if type_fx != "" else str(atk.get("fx_attack", ""))


## 套用兵种：属性 + 帧序列 + 脚底偏移。所有数值都能在 config 的 enemy_types 里调。
func _apply_type(type_cfg: Dictionary) -> void:
	_apply_numeric(type_cfg)
	hp = max_hp
	# 镜像模式算在这里而不是下面的 Body 分支里：无 Body 的假敌人/无头探针也要能读到。
	_flip_mode = resolve_flip_mode(type_cfg)

	if _body == null:
		return
	# 帧序列：enemy_types 里直接写成 idle/walk/attack 三段扁平数组，
	# 与 sprites_ts 同一套写法，PlayerAnimator.parse_spec 直接吃得下。
	var view := {
		"offset_y": float(type_cfg.get("offset_y", Config.get_value("enemy_types.offset_y", -40.0))),
		"scale": float(type_cfg.get("scale", Config.get_value("enemy_types.scale", 1.0))),
		"pixel_unit": float(type_cfg.get("pixel_unit",
				Config.get_value("enemy_types.pixel_unit", 6.0))),
	}
	var view_cfg := {
		"sprite_scale": view["scale"],
		"sprite_offset_y": view["offset_y"],
		"sprite_pixel_unit": view["pixel_unit"],
		"sprite_flip_h": _flip_mode,
	}
	# 用 PlayerAnimator.Anim 的名字约定做键：idle / walk / attack
	var spec := {}
	for key in ["idle", "walk", "attack", "dead"]:
		if type_cfg.has(key):
			spec[key] = type_cfg[key]
	spec["fps"] = type_cfg.get("fps", {})
	# 攻击帧数 + 帧率：用于按真实帧数算挥砍时长，让整套挥砍完整播完
	# （否则固定 0.35s 只播约 5 帧，挥砍刚起手就停）。无 attack 帧的冲撞型兵种 = 0。
	_attack_frames = 0
	if type_cfg.has("attack"):
		_attack_frames = int(type_cfg["attack"].size())
	var _fps_d: Dictionary = type_cfg.get("fps", {})
	_attack_fps = float(_fps_d.get("attack", 14.0))
	# 死亡动画帧单独存一份，死亡时由 _tick_death 手动推进（不依赖动画器的
	# "帧数 > 1 才算动画"判断：单帧死亡帧也能正确显示，且不会回退到 idle 帧）。
	_death_frames = []
	_death_fps = float(type_cfg.get("dead_fps", Config.get_value("enemy.death_fps", 8.0)))
	if type_cfg.has("dead"):
		for p in type_cfg["dead"]:
			if ResourceLoader.exists(p):
				var tex = load(p)
				if tex != null:
					_death_frames.append(tex)
	_animator = PlayerAnimator.new(_body)
	_animator.load_from_config(spec, view_cfg, "")   # 空 label = 不打印（100 个会刷屏）


## 调试面板改完数值后的原地重算（见 Scripts/debug_stat_panel.gd）。
## `_ai_cache` 必须一起作废：它是"定稿后不再读 config"的合并缓存（见 ai_cfg 头注释），
## 不作废的话面板拖 `enemy.ai.*` 的滑块会一动不动，看起来像面板坏了。
## 血上限变了 → 自动回满（与 player.gd::refresh_debug_stats 同一条用户约定）。
func refresh_debug_stats() -> void:
	var old_max := max_hp
	_apply_numeric(_type_cfg)
	_ai_cache = {}
	if max_hp != old_max:
		hp = max_hp
	else:
		hp = mini(hp, max_hp)


## 本兵种的镜像模式：兵种 art_facing 键 → ART_FACING 表 → 默认朝右。
## 全局开关 `enemy.flip_h_with_facing`（出厂默认 true）：读整棵 enemy 子树再 Dictionary.get，
## 不要写成 Config.get_value("enemy.flip_h_with_facing") —— 键没进 config 会每只怪刷一条
## "[Config] 缺少配置项"，一局 100 只就把日志淹了。
func resolve_flip_mode(type_cfg: Dictionary) -> int:
	var e_cfg: Dictionary = Config.get_value("enemy", {})
	if not bool(e_cfg.get("flip_h_with_facing", true)):
		return PlayerAnimator.FLIP_NONE
	var key := str(type_cfg.get("art_facing",
			ART_FACING.get(str(type_cfg.get("id", "")), ART_FACING_DEFAULT)))
	return PlayerAnimator.flip_mode_of(key)


## 当前朝向（镜像判定用的那个向量）。探针与实拍读它。
func facing() -> Vector2:
	return _facing


## 直接指定朝向（只给探针/实拍用；游戏内由 follow_path / _start_attack 驱动）
func set_facing(dir: Vector2) -> void:
	if dir.length_squared() > 0.000001:
		_facing = dir.normalized()


# ------------------------------------------------------------
# 感知
# ------------------------------------------------------------

## 最近的一名存活玩家。小队模式下感知/追击/休眠距离都按最近者算；
## 全队覆灭后返回 null（AI 自然停摆，等待超时结算）。
func _get_player() -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		if p.has_method("is_dead") and bool(p.is_dead()):
			continue
		var d: float = global_position.distance_squared_to((p as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = p
	return best


## 与玩家的距离（单位：格）
func distance_to_player_cells() -> float:
	var p := _get_player()
	if p == null:
		return INF
	return global_position.distance_to(p.global_position) / float(_tile_size)


## 视野内是否能看到玩家 = 距离判定 + 墙体遮挡（隔墙看不见）
func can_see_player() -> bool:
	var p := _get_player()
	if p == null:
		return false
	if p.has_method("is_dead") and bool(p.is_dead()):
		return false
	var vision_px := float(Config.get_value("enemy.vision_cells", 10)) * float(_tile_size)
	if global_position.distance_to(p.global_position) > vision_px:
		return false
	if not bool(Config.get_value("enemy.vision_blocked_by_walls", true)):
		return true
	return has_line_of_sight(global_position, p.global_position)


## 视线检测：沿两点连线按 los_step_cells（格）采样，命中任一墙格即被遮挡。
## 不做物理射线（100 个敌人每帧 physics raycast 太贵），网格采样足够且廉价。
func has_line_of_sight(from: Vector2, to: Vector2) -> bool:
	if _walls.is_empty():
		return true
	var step_px := float(Config.get_value("enemy.los_step_cells", 0.35)) * float(_tile_size)
	var steps := int(from.distance_to(to) / maxf(step_px, 1.0)) + 1
	for i in range(1, steps):
		var cell := _cell_of(from.lerp(to, float(i) / float(steps)))
		if not _in_bounds(cell):
			return false
		if _walls[cell.y][cell.x]:
			return false   # 中间隔着墙 → 看不见
	return true


## 记住玩家当前位置（追击中看到玩家时每帧刷新）
func remember_player_position() -> void:
	var p := _get_player()
	if p != null:
		_last_known = p.global_position


# ------------------------------------------------------------
# 噪音感知（DESIGN.md 第二部分 噪音机制）
# ------------------------------------------------------------

## 听到一次噪音：累加警觉度并记录声源（阈值驱动状态切换在 enemy_*_state 里）
func hear_noise(source_pos: Vector2, intensity: float) -> void:
	noise_alertness = minf(noise_alertness + intensity,
			float(Config.get_value("noise.max_alertness", 150.0)))
	_noise_source = source_pos


## 被玩家打中 → 记住**打我的那个人在哪**，立刻朝那边去。
## 用户 2026-09-17 定的规则：「其他怪只在一个固定的范围内移动，受到攻击或者噪音，再移动」
## —— 所以「挨打」和「听见」在系统里走同一条路：涨警觉度 → 过阈值 → 转「调查」走向声源。
## 攻击者位置只能由调用方给（近战 = 玩家位置、箭 = 出膛点），
## 因此这是个**独立入口**，而不是塞进 take_damage() 的签名：探针里那些只测伤害数值的
## 假敌人（自定义 take_damage）不必跟着改签名。全部敌人通用，不只劫掠者。
## 强度取 noise.sources.hurt（写 0 = 关掉这条反应）。
func alert_from_attacker(from_pos: Vector2) -> void:
	if _dying or from_pos == Vector2.ZERO:
		return
	var gain := float(Config.get_value("noise.sources.hurt", 0.0))
	if gain <= 0.0:
		return
	_noise_source = from_pos
	noise_alertness = minf(noise_alertness + gain,
			float(Config.get_value("noise.max_alertness", 150.0)))


## 调查目标位置（最后听到的声源）
func noise_source() -> Vector2:
	return _noise_source


## 写入调查目标（追击跟丢时把最后已知位置当作声源，让调查状态走向它）
func set_noise_source(pos: Vector2) -> void:
	_noise_source = pos


## 玩家最后被看到的位置（供 chase 跟丢后使用）
func last_known_position() -> Vector2:
	return _last_known


## 走向噪音声源（与 repath_to_last_known 同构，但目标来自听力）
func repath_to_noise_source() -> void:
	if _noise_source == Vector2.ZERO:
		return
	if not _set_path_to(_noise_source):
		clear_move_target()


## 表现层每帧推进：把 FSM/移动状态翻译成动画状态。
## ATTACK 优先级最高（近战出手时播放一段时间），其次是"有路径在走"→ walk，否则 idle。
func _update_anim(delta: float) -> void:
	if _animator == null:
		return
	var st := PlayerAnimator.Anim.IDLE
	if _attack_timer > 0.0:
		# 没有攻击帧的冲撞型兵种（洞穴兽/野猪）用 walk 表现"攻击"，避免静止不动
		st = PlayerAnimator.Anim.ATTACK if _attack_frames > 0 else PlayerAnimator.Anim.WALK
	elif _has_target and not _path.is_empty():
		st = PlayerAnimator.Anim.WALK
	_anim_state = st
	# 素材是单侧帧（21 个兵种全如此），所以传进来的朝向只起两个作用：
	# ① 水平镜像补出"朝左"（见 PlayerAnimator.FLIP_* 与 ART_FACING 表）；
	# ② 无帧状态的程序化位移方向。上下朝向不做处理——素材没有正/背面。
	_animator.update(delta, st, _facing)


## 受击视觉反馈：白闪 → 泛红回落（官方包没有受击帧，只能靠 modulate 闪一下）。
## **不再做警觉染色**（2026-09-19 用户反馈：Enemy Pack 彩色素材被警觉红整只盖成红色，
## 素材原色全无）——敌人看见玩家这件事靠行为本身（转身追击）传达，不再染身体。
## 调用时机必须在 _update_anim 之后 —— 动画器每帧都会写 modulate。
func _update_alert_visual() -> void:
	if _body == null or _dying:
		return                        # 死亡淡出由 tween 独占 modulate
	var tint := Color(1.0, 1.0, 1.0)  # 常态 = 原色，不染
	if _hit_flash > 0.0:
		var full := maxf(float(Config.get_value("enemy.hit_flash_seconds", 0.22)), 0.01)
		var r := clampf(_hit_flash / full, 0.0, 1.0)   # 1=刚命中 → 0=结束
		if r > 0.5:
			# 命中头帧：白闪（modulate 乘法可超 1 提亮，比纯红更"啪"一下）
			tint = tint.lerp(Color(1.9, 1.9, 1.9), (r - 0.5) / 0.5)
		else:
			# 后段：泛红回落
			tint = tint.lerp(Color(1.0, 0.28, 0.22), r / 0.5)
	# 状态染色乘在最后：冻住发冰蓝、烧起来发红，颜色全在 config 的 skills.statuses 里。
	# 没挂状态时 visual_tint() 返回纯白，这一句等于不存在。
	_body.modulate = tint * _statuses.visual_tint()


# ------------------------------------------------------------
# AI 参数（兵种级「怎么走」的开关：游走范围 / 听力 / 成群）
# 全局默认写在 config 的 enemy.ai，兵种用 enemy_types.types[*].ai 按键覆盖
# （劫掠者三项都覆盖了；不写 ai 段的兵种 = 老行为）。见文件头「劫掠者」段。
# 合并只做一次（_ai_cache，setup 后第一次访问时算），热点路径不重复读 config。
# ------------------------------------------------------------

## 合并后的 AI 配置：enemy.ai（全局默认）← 兵种 ai（按键覆盖，两个子树各自浅合并一层）。
## **只在拿到兵种配置之后才缓存**：_ready() 早于 setup()，而 _ready 里的状态机起手就会
## 问一次 roam.mode（patrol.enter → pick_patrol_target）——那时 _type_cfg 还是空的，
## 若把那次结果缓存下来，后面真正注入兵种配置也永远读不到（2026-09-17 踩过，全兵种都退回默认）。
func ai_cfg() -> Dictionary:
	if not _ai_cache.is_empty():
		return _ai_cache
	var base = Config.get_value("enemy.ai", {})
	var merged: Dictionary = (base as Dictionary).duplicate(true) if base is Dictionary else {}
	var over = _type_cfg.get("ai", {})
	if over is Dictionary:
		for k in over:
			var v = over[k]
			if v is Dictionary and merged.get(k) is Dictionary:
				var sub: Dictionary = merged[k]
				for kk in v:
					sub[kk] = v[kk]
			else:
				merged[k] = v
	if not _type_cfg.is_empty():
		_ai_cache = merged         # 兵种配置在手，结果才算定稿
	return merged


func _ai_sub(key: String) -> Dictionary:
	var v = ai_cfg().get(key, {})
	return v if v is Dictionary else {}


## 游走范围策略："whole_map"（满地图随机游走，劫掠者）| "home_radius"（出生点周围，默认）
func roam_mode() -> String:
	return str(_ai_sub("roam").get("mode", "home_radius"))


## 听力倍率（>1 = 听得更远也更清）。劫掠者「对声音更敏感」就是它。
## **真正的使用点在 noise_system.gd::emit 的派发循环**（按听者放大等效听力半径），
## 本函数只负责把配置读出来 —— 全工程只有那一个消费点，改口径只改一处。
func noise_sensitivity() -> float:
	return maxf(0.01, float(ai_cfg().get("noise_sensitivity", 1.0)))


## AI 活跃半径（格）：超过它的敌人整帧不跑 AI（性能保护，见文件头）。
## 兵种可用 ai.roam.active_radius_cells 单独放宽：劫掠者要「满地图游走」，
## 全局那 32 格（=512px）会把它圈在玩家附近，所以给它放宽到 48 格。
## 不写 / 写 0 = 沿用全局 enemy.ai_active_radius_cells。
func ai_active_radius_cells() -> float:
	var v := float(_ai_sub("roam").get("active_radius_cells", 0.0))
	if v > 0.0:
		return v
	return float(Config.get_value("enemy.ai_active_radius_cells", 32.0))


# ------------------------------------------------------------
# 成群（pack）：同类相遇后一起移动，每群上限 max_members（默认 5）
#
# 用户原话：「遇到同类会一起移动，上限先做到 5 个」。
# 结构 = 全群**共享同一个 Dictionary**（引用语义，与幻影分身的池同一套写法）：
#   {"leader": Node2D, "members": Array}   —— members 含群主自己。
# 语义是「后来者加入先到者的群」（活物世界里的自然顺序），不是两群对等合并；
# 于是每群的规模单调逼近 max_members，且**永远不会超**（cap 是硬闸）。
# 分工：群主选目标（按 roam 模式满地图游走），成员只跟队形（follow_pack_leader）。
# ------------------------------------------------------------

func pack_enabled() -> bool:
	return bool(_ai_sub("pack").get("enabled", false))


func pack_max_members() -> int:
	return maxi(1, int(_ai_sub("pack").get("max_members", 5)))


func pack_join_radius_px() -> float:
	return maxf(0.0, float(_ai_sub("pack").get("join_radius_px", 160.0)))


func pack_follow_distance_px() -> float:
	return maxf(0.0, float(_ai_sub("pack").get("follow_distance_px", 48.0)))


func pack_scan_interval() -> float:
	return maxf(0.05, float(_ai_sub("pack").get("scan_interval_seconds", 1.0)))


func pack_repath_interval() -> float:
	return maxf(0.05, float(_ai_sub("pack").get("repath_interval_seconds",
			Config.get_value("enemy.repath_interval_seconds", 0.4))))


## 全群共享的那个字典（同群两边是**同一个实例**）。探针/统计用；空 = 没成群。
func pack_dict() -> Dictionary:
	return _pack


## 本群活着的成员（含群主）：尸体、正在淡出的、以及已释放的都会被过滤掉。
func pack_members() -> Array:
	var out: Array = []
	var members = _pack.get("members", null)
	if not (members is Array):
		return out
	for m in members:
		if not is_instance_valid(m):
			continue
		if bool(m.get("_dying")):
			continue
		out.append(m)
	return out


func pack_size() -> int:
	return pack_members().size()


## 群主（负责选目标、满地图游走的那只）。群主死了就**就地**推举一个继承者
## （懒惰修复：在读取处补一次，省得为"群主阵亡"到处埋钩子）。
func pack_leader() -> Node2D:
	if _pack.is_empty():
		return null
	var l = _pack.get("leader", null)
	if l != null and is_instance_valid(l) and not bool(l.get("_dying")):
		return l
	_promote_pack_leader(pack_members())
	l = _pack.get("leader", null)
	if l != null and is_instance_valid(l) and not bool(l.get("_dying")):
		return l
	return null


func is_pack_leader() -> bool:
	return bool(pack_leader() == self)


## 我是不是「跟着别人走」的成员（成群、群里不止我一个、且群主不是我）。
## 巡逻状态靠它决定：自己选目标（群主）还是跟队形（成员）。
func is_pack_follower() -> bool:
	if _dying or not pack_enabled() or _pack.is_empty():
		return false
	var l := pack_leader()
	return l != null and l != self


## 建一个只有自己的群（群主 = 自己）。已经在群里就什么都不做。
## setup() 里调一次 ⇒ 带 pack 的兵种一出生就「有群」，不需要等第一次扫描。
func _ensure_pack() -> void:
	if not pack_enabled() or not _pack.is_empty():
		return
	_pack = {"leader": self, "members": [self]}


## 加入某一群。会先把「我」从原来的群里摘出去（原群群主若是我 → 先移交给别人）。
func attach_to_pack(pack: Dictionary) -> void:
	if pack.is_empty() or pack == _pack:
		return
	_leave_pack()
	_pack = pack
	var members = pack.get("members", null)
	if members is Array and not (members as Array).has(self):
		(members as Array).append(self)
	_follow_timer = 0.0
	clear_move_target()          # 换群了：旧队形作废，下一帧按新群主重新寻路


## 把另一只同类收进**我的**群（后来者加入先到者）。返回是否真的收下了。
## 满了 / 对方无效 / 已在本群 → 一律拒绝（cap 就是在这里兜住的）。
func absorb_into_pack(other: Node2D) -> bool:
	if other == null or not is_instance_valid(other) or other == self:
		return false
	if not other.has_method("attach_to_pack"):
		return false
	_ensure_pack()
	if pack_members().size() + 1 > pack_max_members():
		return false             # 满了：不再收人（用户定的「上限先做到 5 个」）
	other.call("attach_to_pack", _pack)
	return true


## 退出当前群（投靠别的群 / 死亡时调用）。我是群主就先移交，然后清空自己那份。
func _leave_pack() -> void:
	if _pack.is_empty():
		return
	var members = _pack.get("members", null)
	if not (members is Array):
		_pack = {}
		return
	var arr: Array = members
	var was_leader: bool = _pack.get("leader", null) == self
	arr.erase(self)
	if was_leader:
		_promote_pack_leader(arr)
	_pack = {}


## 群主没了 → 由 arr 里第一只活着的接管（members 顺序 = 入群先后，先到者优先）。
## 全群覆灭就把 leader 置空（之后各自 _leave_pack 时那份字典也会被丢掉）。
func _promote_pack_leader(arr: Array) -> void:
	if _pack.is_empty():
		return
	var next: Node2D = null
	for m in arr:
		if not is_instance_valid(m):
			continue
		if bool(m.get("_dying")):
			continue
		next = m
		break
	_pack["leader"] = next


## 成群守护：定期找附近的同类结伙（跟随逻辑在巡逻状态里，见 follow_pack_leader）。
## 每帧都会被调，但内部按 scan_interval_seconds 节流；不带 pack 的兵种第一句就返回。
func _tick_pack(delta: float) -> void:
	if _dying or not pack_enabled():
		return
	if _pack.is_empty():
		_ensure_pack()
	_pack_scan_timer += delta
	if _pack_scan_timer < pack_scan_interval():
		return
	_pack_scan_timer = 0.0
	_try_join_nearby_pack()


## 「遇到同类会一起移动」的落点：找**最近的同类**（同 type_id、同样带 pack、非分身、
## 没在淡出），只要它那个群**不小于我的、且还装得下我**，我就投奔它。
## 「不小于」这条是必需的：不加的话，一个小群里的人会为了再找一个落单的而退出旧群，
## 于是小群之间互相拆伙、群主每秒换一次（实测 6 只聚在一起只会晃出 4+2 而不是 5+1）。
## 只投奔更大的群 ⇒ 群规模单调往上走，收敛到 5 就停。
## 节流跑（默认 1 秒一次）：这是 O(全场敌人数) 的扫描，不能每帧做。
func _try_join_nearby_pack() -> void:
	var radius := pack_join_radius_px()
	if radius <= 0.0:
		return
	var best: Node2D = null
	var best_d := INF
	for e in get_tree().get_nodes_in_group("enemies"):
		if e == self or not is_instance_valid(e):
			continue
		var n := e as Node2D
		if n == null or not n.has_method("pack_enabled"):
			continue
		if not bool(n.call("pack_enabled")):
			continue
		if bool(n.get("_dying")) or bool(n.call("is_phantom")):
			continue
		if str(n.get("type_id")) != str(type_id):
			continue                                  # 只跟**同类**结伙
		if n.call("pack_dict") == _pack:
			continue                                  # 已经是一伙的
		var theirs := int(n.call("pack_size"))
		if theirs < pack_size():
			continue                                  # 只投奔**不小于**自己的群
		if theirs + 1 > int(n.call("pack_max_members")):
			continue                                  # 那群装不下我（cap 在这里兜住）
		var d := global_position.distance_to(n.global_position)
		if d > radius:
			continue
		if d < best_d:
			best_d = d
			best = n
	if best != null:
		best.call("absorb_into_pack", self)


## 跟队形（成员在巡逻状态下每帧调用）：与群主保持在 follow_distance_px 之内。
## 返回 true = 已经就位（站着待命，不用动）；false = 正在赶路。
## 群主自己不跟（返回 false），照常 pick_patrol_target 去满地图游走。
func follow_pack_leader() -> bool:
	if not is_pack_follower():
		return false
	var l := pack_leader()
	if l == null:
		return false
	if global_position.distance_to(l.global_position) <= pack_follow_distance_px():
		if has_move_target():
			clear_move_target()
		return true
	_follow_timer += get_physics_process_delta_time()
	if _follow_timer >= pack_repath_interval() or not has_move_target():
		_follow_timer = 0.0
		if not _set_path_to(l.global_position):
			clear_move_target()
	follow_path(patrol_speed())
	return false


# ------------------------------------------------------------
# 移动（功能层：只管沿路径推进，不管为什么走）
# ------------------------------------------------------------

func has_move_target() -> bool:
	return _has_target


func clear_move_target() -> void:
	_has_target = false
	_path = PackedVector2Array()
	_path_index = 0


## 巡逻速度。**状态乘数只在这一个出口乘一次**：chase_speed() 从它派生，
## 于是冻结（speed_mult=0）一处生效、全场景停下，不必在每个状态里各判一次"我冻住了吗"。
func patrol_speed() -> float:
	return float(Config.get_value("enemy.speed", 90)) * speed_mult * _statuses.speed_mult()


func chase_speed() -> float:
	return patrol_speed() * float(Config.get_value("enemy.chase_speed_multiplier", 1.35))


## 沿缓存路径推进；到达终点返回 true。Area2D 无 move_and_slide，直接推进坐标。
func follow_path(speed: float) -> bool:
	if not _has_target or _path.is_empty() or _path_index >= _path.size():
		return true
	var delta := get_physics_process_delta_time()
	var waypoint := _path[_path_index]
	var dir := waypoint - global_position
	if dir.length() < 4.0:
		_path_index += 1
		return _path_index >= _path.size()
	# 朝向跟着实际挪动的方向走。巡逻/调查/追击/成群跟随全都经由此处，
	# 所以这里更新一次就够，不必在每个状态里各写一遍。
	var step := dir.normalized()
	_facing = step
	global_position += step * speed * delta
	return false


## 巡逻：选下一个要走过去的点。两路（按兵种的 ai.roam.mode）：
##   home_radius（默认，大多数敌人）= 出生点周围那一小片 —— 用户说的「其他怪只在
##     一个固定的范围内移动」；
##   whole_map（劫掠者）= 整张地图任意可走格 —— 「满地图随机游走」。
## 两者都只在**没动静**时用：听到噪音/挨了打会立刻转调查（见 hear_noise / alert_from_attacker）。
func pick_patrol_target() -> void:
	if roam_mode() == "whole_map":
		pick_roam_target()
		return
	pick_home_radius_target()


## 满地图随机游走：在整张地图上随机挑一个可走格走过去。
## min_target_distance_px 保证新目标离当前位置足够远 —— 否则会挑到脚边几格，
## 表现就是"原地小幅抖动"而不是"游走"（walk 动画一直在播但看不出在挪地方）。
## max_target_distance_px > 0 可以把范围再收回来（默认 0 = 不限）。
## 挑不到（地图没注入 / 起手被围）就退回出生点附近的老行为，绝不空转。
func pick_roam_target() -> void:
	var cfg := _ai_sub("roam")
	var attempts := maxi(1, int(cfg.get("sample_attempts", 24)))
	var min_d := maxf(0.0, float(cfg.get("min_target_distance_px", 320.0)))
	var max_d := maxf(0.0, float(cfg.get("max_target_distance_px", 0.0)))
	var half := float(_tile_size) * 0.5
	for _i in range(attempts):
		var cell := _random_open_cell()
		if cell.x < 0:
			break
		var pos := Vector2(float(cell.x) * _tile_size + half, float(cell.y) * _tile_size + half)
		var d := global_position.distance_to(pos)
		if d < min_d:
			continue
		if max_d > 0.0 and d > max_d:
			continue
		if _set_path_to(pos):
			return
	pick_home_radius_target()


## 老行为（也是绝大多数敌人的行为）：在出生点附近随机选一个可达点（矩形范围）。
func pick_home_radius_target() -> void:
	var radius := float(_ai_sub("roam").get("patrol_radius_cells",
			Config.get_value("enemy.patrol_radius_cells", 6)))
	for _attempt in range(8):
		var offset := Vector2(randf_range(-radius, radius), randf_range(-radius, radius))
		if _set_path_to(_home + offset * float(_tile_size)):
			return
	clear_move_target()   # 周围选不到点（被墙包围）就原地待着


## 随机取一个**可走格**（最多试 16 次，避免在石头/树密的地方死磕）。
## 地图没注入 / 整张图都被墙填满时返回 (-1,-1)，由调用方兜底。
func _random_open_cell() -> Vector2i:
	var h: int = _walls.size()
	if h == 0:
		return Vector2i(-1, -1)
	var w: int = _walls[0].size()
	if w <= 0:
		return Vector2i(-1, -1)
	for _i in range(16):
		var c := Vector2i(randi_range(0, w - 1), randi_range(0, h - 1))
		if not _walls[c.y][c.x]:
			return c
	return Vector2i(-1, -1)


## 追击：把路径指向玩家当前位置
func repath_to_player() -> void:
	var p := _get_player()
	if p == null:
		return
	if not _set_path_to(p.global_position):
		clear_move_target()


## 跟丢后：走向最后已知位置（不再读玩家实时坐标，避免隔墙"透视追踪"）
func repath_to_last_known() -> void:
	if _last_known == Vector2.ZERO:
		return
	if not _set_path_to(_last_known):
		clear_move_target()


## 追击路径节流重算（避免每帧 A*）
func tick_repath(delta: float) -> void:
	_repath_timer += delta
	if _repath_timer >= float(Config.get_value("enemy.repath_interval_seconds", 0.4)):
		_repath_timer = 0.0
		repath_to_player()


## 计算到目标点的路径（共享网格 + 格心换算）；不可达返回 false
func _set_path_to(target: Vector2) -> bool:
	if _astar == null:
		return false
	var from := _cell_of(global_position)
	var to := _cell_of(target)
	if not _in_bounds(from) or not _in_bounds(to):
		return false
	# 与玩家同一套兜底：被击退推进树/石格后也要能自己走出来，
	# 否则敌人会永久卡在障碍格里（A* 对 solid 起点一律返回空路径）。
	var r: int = int(Config.get_value("nav.unstick_radius_cells", 4))
	from = MapGenerator.nearest_open_cell(_walls, from, r)
	to = MapGenerator.nearest_open_cell(_walls, to, r)
	if from.x < 0 or to.x < 0:
		return false
	var ids := _astar.get_id_path(from, to)
	if ids.is_empty():
		return false
	_path = MapGenerator.ids_to_centers(ids, _tile_size)
	_path_index = 1 if _path.size() >= 2 else 0
	_has_target = true
	return true


func _cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(int(pos.x / _tile_size), int(pos.y / _tile_size))


func _in_bounds(cell: Vector2i) -> bool:
	var h: int = _walls.size()
	if h == 0:
		return false
	var w: int = _walls[0].size()
	return cell.x >= 0 and cell.y >= 0 and cell.x < w and cell.y < h


# ------------------------------------------------------------
# 战斗
# ------------------------------------------------------------

## 施加一个状态（技能系统调用；id 见 config 的 skills.statuses，定义在 unit_status.gd）。
## 方法名就是软约定：AoE/弹道那边只用 `has_method("apply_status")` 探测，不认具体类型，
## 所以中立动物、以后的新单位接同一个方法就能吃冻结与灼烧，不用改技能代码。
## 已死/正在淡出的不吃状态（否则会在尸体上挂出一份永远播不完的状态表）。
func apply_status(id: String, def_override: Dictionary = {}) -> bool:
	if hp <= 0 or _dying:
		return false
	return _statuses.apply(id, def_override)


## 受到玩家攻击伤害（由 Player.resolve_attack_hit / 技能效果调用）
func take_damage(amount: int) -> void:
	if hp <= 0 or _dying:
		return
	# 【幻影分身】分身有**自己的一份血**（= 本体 max_hp 的 20%，见 _setup_phantom），
	# 扣的是自己的；打光就自己消失（vanish_as_phantom），**不**把伤害转嫁给本体。
	# 但血条是**整组按组内最低血量**显示的 ⇒ 打分身也会让全组的条一起动，
	# 玩家看到的永远是"这群人快死了"的同一条血 —— 这就是迷惑点。
	if _is_phantom:
		_hit_flash = float(Config.get_value("enemy.hit_flash_seconds", 0.18))
		hp = maxi(0, hp - maxi(1, amount))
		refresh_group_hp_bar()      # 整组血条跟着刷新（组内最低值可能变了）
		if hp <= 0:
			vanish_as_phantom()     # 分身就这一小份血，打光即散，不走本体的死亡结算
		return
	hp -= incoming_damage(amount)      # 特性减伤（爆裂鼓手 / 幻影分身）都在这句里算
	_hit_flash = float(Config.get_value("enemy.hit_flash_seconds", 0.18))
	refresh_group_hp_bar()             # 挨打才显示血条；整组一起按最低值显示
	if hp <= 0:
		_die()
		return
	_check_phantom_swap()              # 每掉 20% 血，随机和一具分身交换位置


# ------------------------------------------------------------
# 特性：受击减伤（burst_drum「爆裂鼓手」的后一半）
# 血量越低，受到的伤害越少 —— 越到残血越难磨死，逼玩家靠爆发而不是慢慢耗。
# ------------------------------------------------------------

## 实际承受的伤害 = 原始伤害 × (1 − 减伤比例)，并有 min_damage 点保底。
## 没带减伤子段的敌人（绝大多数）原样返回 —— 等于这两段代码不存在。
## 两条通道依次相乘：① 爆裂鼓手（血越少越难打，有 min_damage 保底）
##                    ② 幻影分身（场上分身越多越难打，1 点保底）
## 一个实例只有一个特性，实际只会命中其中一条；两条并列是为了将来能叠加。
func incoming_damage(amount: int) -> int:
	var out := amount
	var red := damage_reduction_ratio()
	if red > 0.0:
		out = maxi(_dr_min_damage(), int(round(float(out) * (1.0 - red))))
	var pred := phantom_damage_reduction()
	if pred > 0.0:
		out = maxi(1, int(round(float(out) * (1.0 - pred))))
	return out


## 当前血量下的减伤比例（0 = 不减伤）。**纯计算**，探针改 hp 后直接调用即可。
## 公式：max_reduction × (1 − hp/max_hp)^exponent —— 满血 0，血越少越接近 max_reduction，
## 但永远 < 1（再配 min_damage 保底 ⇒ 残血也打得死，不会出现无敌怪）。
func damage_reduction_ratio() -> float:
	var cfg := _sub_feat("damage_reduction")
	if cfg.is_empty():
		return 0.0
	var ratio := clampf(float(hp) / float(maxi(1, max_hp)), 0.0, 1.0)
	var red := float(cfg.get("max_reduction", 0.0)) * pow(1.0 - ratio, maxf(0.05, float(cfg.get("exponent", 1.0))))
	return clampf(red, 0.0, 0.999)


func _dr_min_damage() -> int:
	var cfg := _sub_feat("damage_reduction")
	if cfg.is_empty():
		return 1
	return maxi(1, int(cfg.get("min_damage", 1)))


## 幻影分身：「分身越多，自身受到伤害越少」（用户 2026-09-17 定）。
## 公式：per_phantom × 场上活分身数，封顶 max_reduction；另有 1 点保底伤害（不会无敌）。
## 分身被打光就没了 ⇒ 想少挨减伤，玩家得先把分身清干净（这正是这条的设计意图）。
## 只有本体吃这条减伤（分身自己不算），**纯计算**，探针直接调用即可。
func phantom_damage_reduction() -> float:
	if _is_phantom or feature_id() != "phantom_double":
		return 0.0
	var cfg := _sub_feat("damage_reduction")
	if cfg.is_empty():
		return 0.0
	var n := phantom_count()
	if n <= 0:
		return 0.0
	return clampf(float(n) * float(cfg.get("per_phantom", 0.0)),
			0.0, float(cfg.get("max_reduction", 0.0)))


# ------------------------------------------------------------
# 特性：噪音放大（burst_drum「爆裂鼓手」的前一半）
# 小队的动静在它身边被"鼓"放大 —— 逼玩家要么先点掉它，要么用不出声的手段。
# ------------------------------------------------------------

## 本实例对「发声点 at」贡献的噪音增幅（0 = 不贡献）。**纯计算**，供探针直接调用。
## noise_system.gd 在玩家发声时遍历 "noise_amplifiers" 组求和就是这个（见 emit）。
## 距离线性加权：贴着 = per_enemy 全量，到 radius_px 边缘 = 0。
## radius_px ≤ 0 视为关闭（想全图生效就把半径设得比地图大）。
func noise_amplify_gain(at: Vector2) -> float:
	if _dying:
		return 0.0                      # 正在消失的尸体不再鼓噪
	var cfg := _sub_feat("noise_amplify")
	if cfg.is_empty():
		return 0.0
	var radius := float(cfg.get("radius_px", 0.0))
	if radius <= 0.0:
		return 0.0
	var d := global_position.distance_to(at)
	if d >= radius:
		return 0.0
	return maxf(0.0, float(cfg.get("per_enemy", 0.0))) * (1.0 - d / radius)


## 本实例特性里的某个子配置段（没这个特性 / 没这一段 → 空字典）。
## 「一个实例只有一个特性」，所以直接看 _feat 就够。
func _sub_feat(key: String) -> Dictionary:
	var sub = _feat.get(key, {})
	return sub if sub is Dictionary else {}


## 死亡结算：上报死亡分裂 → 按概率掉落资源 → 淡出 → 移除自身。
## 不再"瞬间消失"：淡出期间 _dying=true，AI、受伤、近战出手全部停摆，
## 敌人不会在倒下动画里还能打人，也不会被重复结算掉落。
func _die() -> void:
	if _dying:
		return
	_dying = true
	_leave_pack()            # 退出成群：我是群主就把位置让给同群下一个活着的
	_report_death()          # 先上报：判定越早，刷出来的个体出来得越干脆
	_spawn_drop()
	_hide_hp_bar()
	_vanish_phantoms()       # 本体倒下 → 幻影一并消失（分身自己不会单独死）
	# 有死亡动画帧 → 先播死亡帧，播完再淡出；否则直接淡出（旧行为）。
	# 这里**不** set_physics_process(false)：死亡动画靠 _physics_process 里的
	# _tick_death 推进，淡出内部才会关物理。
	if _death_frames.is_empty():
		_fade_out()
	else:
		_death_elapsed = 0.0
		if _body != null:
			_body.modulate = Color.WHITE    # 死亡帧以原色显示，不被警觉染色盖住


## 死亡特性上报：把「我死了 + 我是哪个特性」交回 EnemySystem，由它决定刷不刷、刷几个。
## **一个实例只带一个特性**（生成时随机分配），所以这里按 id 分派，两个特性不会同时触发。
## 概率 / 数量 / 一个一个出来的节奏全不在这（见 enemy_system.gd::notify_death_*）。
func _report_death() -> void:
	if _system == null or not is_instance_valid(_system):
		return
	match str(_feat.get("id", "")):
		"death_split":
			_system.notify_death_split(global_position, _type_cfg, _split, _feat)
		"death_regen":
			_system.notify_death_regen(global_position, _type_cfg, _feat)
		_:
			pass     # 没特性的兵种（绝大多数）走这里


## 本实例分配到的特性（没特性 = 空字典）
func _trait_cfg() -> Dictionary:
	return _feat


## 本实例的特性 id（"" = 无特性）。探针 / 调试用。
func feature_id() -> String:
	return str(_feat.get("id", ""))


## 本实例有没有特性（任何特性都算，包括与数量无关的「爆裂鼓手」）。
func has_feature() -> bool:
	return not _feat.is_empty()


## 本实例的特性是否参与「数量缩放」（enemy_traits.population_scaling）的计数。
## 判据：特性自己（或它的某一代）写了 chance_max ⇒ 它会随数量滑动，才该被数。
## 于是「掠夺者越少 → 概率越高」的口径只数掠夺者系；
## **与数量无关的特性（如邪术师的爆裂鼓手）不会把计数搅浑**（2026-09-17 修）。
func counts_toward_population() -> bool:
	if _feat.is_empty():
		return false
	var stages = _feat.get("stages", null)
	if stages is Array:
		for s in stages:
			if s is Dictionary and (s as Dictionary).has("chance_max"):
				return true
		return false                       # 有 stages 但没一代带缩放 → 不参与
	return _feat.has("chance_max")


## 从兵种的特性池里**随机分配一个**（按 traits[*].weight 加权）。
## 没写 traits[] 时回落单数 trait（旧写法）；都没有 → 空字典 = 无特性。
## 这就是「一个角色只能有一个特性，随机分配」的落点：调一次定终身，之后不再变。
func pick_feature(type_cfg: Dictionary) -> Dictionary:
	var pool := feature_pool(type_cfg)
	if pool.is_empty():
		return {}
	return pool[randi() % pool.size()]


## 兵种的候选特性展开成抽样池：traits[] 按各自 weight 展开；没有 traits[] 但写了
## 单数 trait 时，把那个 trait 当成「只有一个候选」的池（向后兼容旧 config）。
func feature_pool(type_cfg: Dictionary) -> Array:
	var out: Array = []
	var arr = type_cfg.get("traits", [])
	if arr is Array:
		for f in arr:
			if not (f is Dictionary):
				continue
			var w: int = maxi(1, int((f as Dictionary).get("weight", 1)))
			for _k in range(w):
				out.append(f)
	if out.is_empty():
		var one = type_cfg.get("trait", {})
		if one is Dictionary and not (one as Dictionary).is_empty():
			out.append(one)
	return out


## 是否是「特性刷出来的个体」（开局刷的原始怪 = false）。这些默认不掉落，见 _spawn_drop。
## 判据是"生成时是否由 EnemySystem 递回了特性"；另外把"带批次"也算进来，
## 这样老探针直接塞 split_batch 造的分裂体依旧被认。
func is_split_spawn() -> bool:
	return _from_trait or not _split.is_empty()


## 同上，语义更准的名字（再生体也叫 is_split_spawn() 有点误导）。EnemySystem 两个都能用。
func is_trait_spawn() -> bool:
	return is_split_spawn()


## 死亡动画推进：手动把 _death_frames 一张张贴到 _body（不依赖动画器），
## 按 _death_fps 走，播完最后一帧即触发 _fade_out()。无头/无 Body 时直接淡出。
func _tick_death(delta: float) -> void:
	var n := _death_frames.size()
	if n == 0:
		_fade_out()
		return
	_death_elapsed += delta
	var idx := mini(int(_death_elapsed * _death_fps), n - 1)
	if _body != null:
		var tex = _death_frames[idx]
		if tex != null and _body.texture != tex:
			_body.texture = tex
	var dur := float(n) / _death_fps
	if _death_elapsed >= dur:
		_fade_out()


## 死亡淡出：同时做 透明 / 缩小 / 下沉，读起来像"倒下了"而不是"被抠掉"。
## 时长取 0，或没有 Body 节点时，直接释放（无头跑测试更干净）。
func _fade_out() -> void:
	var dur := float(Config.get_value("enemy.death_fade_seconds", 0.45))
	if _fading:
		return
	if _body == null or dur <= 0.0:
		queue_free()
		return
	# 受击回弹可能还在跑（它写 _body.position），会和下面的"下沉"抢同一个属性
	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()
	set_physics_process(false)     # 停止一切逻辑，只留 tween
	var tween := create_tween().set_parallel(true)
	tween.tween_property(_body, "modulate", Color(0.45, 0.45, 0.45, 0.0), dur)
	tween.tween_property(_body, "scale", _body.scale * 0.7, dur)
	tween.tween_property(_body, "position:y", _body.position.y + 12.0, dur)
	tween.chain().tween_callback(queue_free)


## 掉落配置 = 全局 enemy.drop 打底，兵种自己的 drop 段按键覆盖。
## 现在还没有兵种写 drop 段（行为与之前完全一致），但"某种怪必掉某种货"这种具体掉落表
## 以后只改 config 就够了，不用回来改代码。
func _drop_cfg() -> Dictionary:
	var out: Dictionary = (Config.get_value("enemy.drop", {}) as Dictionary).duplicate(true)
	var own = _type_cfg.get("drop", null)
	if own is Dictionary:
		for k in (own as Dictionary):
			out[k] = (own as Dictionary)[k]
	return out


## 掉落：在原地生成一个资源点（复用 LootNode 场景，玩家走近自动拾取）
func _spawn_drop() -> void:
	# 幻影分身不掉落：它连独立个体都不算（随本体消失），掉一地资源等于白送
	if _is_phantom:
		return
	# 分裂体默认不掉落：一只掠夺者能裂成 1+2+4+8+64 个，逐个掉落会把地面直接铺满
	# （要开就改 config 的 trait.drop_from_splits）
	if is_split_spawn() and not bool(_trait_cfg().get("drop_from_splits", false)):
		return
	var drop := _drop_cfg()
	if randf() > float(drop.get("chance", 0.75)):
		return
	var res_id := _pick_drop_resource(drop)
	if res_id.is_empty():
		return
	var amount: int = int(drop.get("amount_min", 2))
	var amount_max: int = int(drop.get("amount_max", 6))
	if amount_max > amount:
		amount = randi_range(amount, amount_max)
	var parent := get_parent()
	if parent == null:
		return
	var node := DROP_SCENE.instantiate()
	parent.add_child(node)
	node.global_position = global_position
	node.setup(res_id, amount, 0.8)   # 比地图资源点略小，便于区分
	print("[Combat] 敌人被击杀，掉落 %s x%d" % [
		str(Config.get_value("resources.%s.name" % res_id, res_id)), amount])


## 按 drop.weights 加权随机抽一种资源；未配置则退回 resources 稀有度权重
func _pick_drop_resource(drop: Dictionary) -> String:
	var weights = drop.get("weights", {})
	if not (weights is Dictionary) or (weights as Dictionary).is_empty():
		weights = {}
		for res in Config.get_value("resources", {}):
			weights[res] = 3 if str(Config.get_value("resources.%s.rarity" % res,
					"common")) == "common" else 1
	var pool: Array = []
	for res in weights:
		for i in range(int(weights[res])):
			pool.append(res)
	if pool.is_empty():
		return ""
	return str(pool[randi() % pool.size()])


## 受击视觉反馈（程序化，不依赖官方受击帧）：白闪 + 挤压回弹 + 视觉击退。
## 全部作用在视觉子节点 _body（modulate / scale / position），不碰根节点 global_position，
## 因此绝不和导航/碰撞打架、不会穿墙 —— 帧切换由 _update_anim 负责，它不写 scale/position，
## 故这里的 squash/击退不会被每帧覆盖。
## 由攻击结算点命中后调用（不进 take_damage 签名，保持探针里「只测伤害数值」的假敌人兼容）。
## from_pos = 攻击者位置（箭出膛点 / 玩家位置），用来算「敌人被推离攻击者」的方向。
func play_hit_fx(from_pos: Vector2) -> void:
	if _dying or _body == null:
		return
	# 命中泛红计时（_physics_process 每帧 decay，_update_alert_visual 据此做白闪→红）
	_hit_flash = float(Config.get_value("enemy.hit_flash_seconds", 0.22))
	# 方向：从攻击者指向本体的单位向量（敌人被推离攻击者）
	var dir := Vector2.ZERO
	if from_pos != Vector2.ZERO:
		var d := global_position - from_pos
		if d.length_squared() > 1.0:
			dir = d.normalized()
	var kb := float(Config.get_value("enemy.hit_knockback_px", 14.0))
	var squash := float(Config.get_value("enemy.hit_squash_amount", 0.18))
	# 重开上一次的回弹动画（连击不打结）
	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()
	_hit_tween = create_tween()
	# 挤压：横向压扁、纵向拉长（被打中的"肉感"），再弹性回弹。
	# 走动画器的 scale_mul 通道而**不是**直接 tween _body.scale：动画器每个物理帧都
	# 会按兵种自己的 scale 重写 _body.scale，直接写会被它盖掉 —— 结果就是 scale≠1 的
	# 兵种（troll 0.5 / minotaur 0.6 / turtle 0.6 / bear 0.75）几乎看不到挤压。
	if _animator != null:
		var from_mul := Vector2(1.0 - squash, 1.0 + squash)
		_animator.set_scale_mul(from_mul)
		_hit_tween.tween_method(_set_squash_mul, from_mul, Vector2.ONE, 0.16) \
				.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	# 视觉击退：_body 局部位置从 0 推到 dir*kb，再弹性回弹 0（纯视觉，不碰碰撞体）
	if dir != Vector2.ZERO and kb > 0.0:
		_body.position = dir * kb
		_hit_tween.tween_property(_body, "position", Vector2.ZERO, 0.20) \
				.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	# 受击微停顿（hitlag）：让 AI/导航短暂让位，敌人「被打愣」一下
	var stun := float(Config.get_value("enemy.hit_stun_seconds", 0.0))
	if stun > 0.0:
		_hit_stun = maxf(_hit_stun, stun)


## 挤压倍数回调：只写动画器的 scale_mul，由它在每帧把倍数乘进 _body.scale。
func _set_squash_mul(v: Vector2) -> void:
	if _animator != null:
		_animator.set_scale_mul(v)


## 被击退。dist_px<0 = 用全局 enemy.knockback_px（普攻那一路的旧行为，一字不变）；
## 技能段里写了 knockback_px 的（落石 / 地裂）按各自那份数推 —— 于是「这招推得动、
## 那招推不动」是配置差异，不是代码里多开一条分叉。
func apply_knockback(impulse: Vector2, dist_px: float = -1.0) -> void:
	if impulse.length() < 1.0:
		return
	var d := dist_px if dist_px > 0.0 else float(Config.get_value("enemy.knockback_px", 8.0))
	global_position += impulse.normalized() * d


## 出手距离（探针和 AI 都用这个数，不要在别处再算一遍）
func attack_range_px() -> float:
	return _attack_range


## 玩家是否已进入本敌人的近战射程 —— 「进了射程就出手」的唯一判据
func in_attack_range() -> bool:
	var p := _get_player()
	if p == null:
		return false
	return global_position.distance_to(p.global_position) <= _attack_range


## 每物理帧问一次：能不能出手。
## 动作/冷却正在跑 → 不出手；被 AI 判定为休眠或刚被打愣（上层不会走到这里）也不出手。
## 【幻影分身】分身不能造成伤害（用户明确要求）——"打了半天没掉血"就是要让玩家
## 立刻看出这只不是真身，别改成能打。
func _tick_attack(_delta: float) -> void:
	if _is_phantom or _dying:
		return
	if _attack_timer > 0.0 or _attack_cooldown > 0.0:
		return
	if not in_attack_range():
		return
	_start_attack()


## 出手：一次性把「动作时长 + 冷却 + 前摇」三件事全部记好，之后不再改。
## 关键设计：出手必然进冷却、必然播动作，和"这一刀砍没砍到"无关 ——
## 早期把两件事写在 `if body.take_damage(...)` 里，所以玩家防御叠满或有无敌帧时
## 敌人既不播动作也不进冷却，看上去就是"敌人根本不会攻击"。
func _start_attack() -> void:
	# 出手瞬间把朝向锁成"指向玩家"。追击状态进了射程就会停下不再挪，
	# 而 _facing 只在 follow_path 里更新 —— 不锁的话这一刀会朝最后一次
	# 挪动的方向挥，玩家绕到身后就是明显对着空气砍。
	var p := _get_player()
	if p != null:
		set_facing(p.global_position - global_position)
	# 出手弧光：与挥砍动作同帧，和"砍没砍到"无关（理由同上面那三件事）。
	# 250 只敌人同时挥也不会刷爆 —— EffectLibrary 按 fx.max_simultaneous 直接不生成。
	if _fx_attack != "" and p != null:
		EffectLibrary.spawn(_fx_attack, get_parent(),
				global_position + _facing * _attack_range * 0.6, _facing.angle())
	# 按攻击帧数算挥砍时长（帧数/帧率），让整套挥砍完整播完；无攻击帧的兵种用保底时长。
	_attack_timer = maxf(_attack_min_dur, _attack_frames / maxf(_attack_fps, 1.0))
	_attack_cooldown = _attack_cd_seconds
	_attack_hit_at = _attack_windup


## 这一刀落地的伤害。走 DamagePipeline（与玩家三条攻击路径同一条算式），
## 目前只用到「随机浮动」那一档，`enemy.attack.variance` 出厂 0 ⇒ 与旧写法逐位相同。
## 刻意不给敌人配暴击：玩家侧没有"敌人暴击"的语义，凭空冒出来的大数字只是噪声。
## 玩家的防御也**不在这里**扣（谁防守谁知道，见 Scripts/combat/damage_pipeline.gd 头注释）。
func roll_attack_damage() -> int:
	return DamagePipeline.compute(float(damage), 0.0, [], _attack_variance)


## 前摇结束：这一刀落地。玩家已经跑出射程就是挥空（动作和冷却照旧不回收）。
## 这里刻意**不发噪音**：250 个敌人同时挥砍会把噪音系统刷爆，波及范围毫无意义。
func _deal_attack_damage() -> void:
	if _dying or _is_phantom:
		return
	var p := _get_player()
	if p == null or not p.has_method("take_damage"):
		return
	if global_position.distance_to(p.global_position) > _attack_range:
		return
	p.take_damage(roll_attack_damage(), global_position)

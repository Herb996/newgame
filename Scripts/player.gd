extends CharacterBody2D
## ============================================================
## Player — 玩家（功能组件层）
##
## 分层（见 DESIGN.md 核心架构原则）：
##   · 本文件 = 功能组件层：只提供能力（移动/寻路/战斗/选中），不含行为决策
##   · Scripts/combat/state_machine.gd + states/ = 行为决策层：决定何时动、何时打
##   状态机通过下列公开接口驱动本组件，二者解耦：
##     has_move_target() / set_move_target() / clear_move_target()
##     follow_path() / stop_moving()
##     aim_at_mouse() / begin_attack_hit() / resolve_attack_hit() / end_attack_hit()
##     take_damage() / set_invincible() / start_dodge_cooldown() / on_death()
##     push_input() / consume_input() / can_dodge()
##
## 寻路：MapGenerator.build_astar 缓存在 setup_navigation 构建一次。
## 性能：只在「换目标 / 跨格 / 卡住」时重算路径，其余帧沿缓存路径走。
## ============================================================

const FX_RING := preload("res://Scripts/combat/fx_ring.gd")
const PROJECTILE := preload("res://Scripts/combat/projectile.gd")

## 玩家能打到的目标分组：敌人 + 中立生物（羊，打死掉食物）。
## 集中成一张表，避免"普攻只认 enemies、技能也只认 enemies"这种漏改。
## 注意：projectile.gd 里有一份同名副本（player.gd 没有 class_name，对方引用不到），
## 改这里时两处都要动。
const DAMAGEABLE_GROUPS := ["enemies", "animals"]

## 武器表里不是武器 id 的键（说明性字段），遍历时跳过。
const WEAPON_META_KEYS := ["_comment"]

var speed := 0.0
var selected := false

# --- 战斗属性 ---
var hp := 0
var max_hp := 0
var facing := Vector2.RIGHT
var _dead := false
var _dodge_invincible := false       # 冲刺无敌帧
var _invincible_timer := 0.0         # 受击后短暂无敌
var _dodge_cooldown := 0.0
var _input_buffer: Array = []        # 输入缓冲：[{action, age}]
var _hit_targets: Dictionary = {}    # 同一次挥击已命中的目标（去重）
var _run: Node = null

# --- 自动战斗：观察视野 / 攻击距离 / 当前锁定目标 ---
# 锁定目标由 _update_auto_target() 节流刷新（默认 0.15s 一次），
# 状态机只在 idle / move 里读 auto_target() 决定是否起手，不每帧遍历全组。
var _auto_target: Node2D = null
var _scan_timer := 0.0

# --- 局内指令（菜单栏下发的指挥状态，2026-09-17）---
# 这些字段全由 Scripts/menu_bar.gd 的指令面板读写；玩家自己不动它们，
# 所以「谁在指挥」只有一处真相：玩家实例上的这几个开关。
var auto_attack_on := true                       # 自动攻击开关（出厂默认 = combat.auto_attack.enabled）
var target_stance: StringName = &"nearest"       # 索敌策略：nearest（最近）/ strongest（最强）
var designated_target: Node2D = null             # 「指定攻击」锁定的目标（死后/跑出射程自动解除）
var command_set := "combat"                      # 指令集 id（config characters.list[].command_set）
var _arm_mode: StringName = &""                  # 待点选模式：designate（点敌人）/ patrol_set（点地面）
var _patrol_points: PackedVector2Array = PackedVector2Array()
var _patrol_active := false
var _patrol_index := 0
var _patrol_wait := 0.0

# --- 当前武器（config: combat.weapons.<id>）---
# 空 = 不启用武器表，一切走 combat.attack 全局值（改造前的行为）。
var current_weapon: StringName = &""

# --- 大门选角注入（main.gd 在 add_child 前设置）---
# character_name：HUD/日志显示名；initial_weapon：本角色初始武器 id（combat.weapons 键），
# 空则回落 config 的 player.weapon（命令行 / 无头回归路径没有选人面板，走回落）。
var character_name := ""
var initial_weapon := ""

# --- 名册身份 / 等级（main.gd 在 add_child 前设置；config progression 段）---
# roster_uid：本实例对应 Meta.roster 里的哪个**人**（0 = 无名册身份 ——
#   命令行、无头回归、直接跑 Main.tscn 这些路径不经过选人面板，也就没有名册身份：
#   它们不发经验、死亡也不除名，行为与加等级系统之前完全一致）。
# level：这个**人**的等级，不是兵种的 —— 死亡永久，所以等级必须挂在实例上。
var roster_uid: int = 0
var level: int = 0
# 升级特性层数表：{"attack": 2, "hp": 1, ...}（main.gd 在 add_child 前注入，
# 来自 Meta.traits_of(roster_uid)）。临时角色（命令行/无头回归）为空 → 一切加成归零。
var traits: Dictionary = {}
# 头顶等级徽章（Scenes/Player.tscn 的 LevelBadge 节点，见 unit_level_badge.gd）
var _badge: Node = null


# --- 自身噪音（noise.self；2026-09-18 起两路噪音互相喂养，这是「每人一份」那一路）---
# 出声时由 NoiseSystem.add_player_noise 灌进来（**已乘过世界噪音的增益**）；
# 每帧由 NoiseSystem._process 统一做两件事：线性快衰减、按比例喂给世界噪音。
# 为什么不在本文件里自己衰减：那样这条路就要同时依赖各自的 delta 与团队的 world 值，
# 一旦有人 pending 移除（死锁/换图）就会各走一半。集中在一处衰减，才好保持一致。
# 头顶光球（unit_level_badge.gd）读它来决定飘动与明灭的快慢 —— 越吵飞得越急。
var self_noise: float = 0.0

# 导航数据：由 main.gd 注入
var _walls: Array = []
var _tile_size: int = 16
var _astar: AStarGrid2D              # 缓存网格（每张地图构建一次）
# 地形速度系数网格（宽×高，每格 0.05~4.0）：雪原 <1、水格再取更小者。
# 空数组 = 全地形 1.0（基地就是这种，平地无减速）。
var _speed_mult: Array = []

var _final_target := Vector2.ZERO    # 用户点击的最终目标点
var _has_target := false

# 路径缓存
var _cached_path := PackedVector2Array()
var _path_index := 0                        # 当前追踪的路点下标（只前进，不回头）
var _path_cell := Vector2i(-9999, -9999)   # 上次计算路径时玩家所在格
var _stall_frames := 0                      # 连续被挡住的帧数（卡住检测）
const STALL_REPATH_FRAMES := 20             # 卡住约 1/3 秒后强制重算路径
## 连续"重算路径但仍然没挪动"的次数上限。
## 为什么必须有：一旦物理碰撞和寻路网格不一致（例如瓦片碰撞偏半格），
## 从同一个格子重算出来的路径第一步方向完全一样 —— 重算 N 次也是撞同一堵墙。
## 没有预算兜底的话，角色会顶着墙原地站到天荒地老，而且状态机还认为自己"在移动"
## （表现就是：点地面没反应、人物原地踏步）。到上限就干脆放弃这条目标，
## 让玩家重新点一次，并且打一条 warning 方便定位是地图哪一格有问题。
const STALL_GIVE_UP_REPATHS := 5
var _stall_repaths := 0                     # 连续无效重算次数（走动了就清零）
const WAYPOINT_REACH_DIST := 4.0            # 距路点小于此值视为已通过该路点

var state_machine: StateMachine

@onready var _select_area: Area2D = $SelectArea
@onready var _select_icon: Node2D = $SelectIcon
@onready var _sprite: Sprite2D = $Body
@onready var hitbox: Area2D = $Hitbox
var _path_line: Line2D
var _patrol_line: Line2D   # 巡逻路线（闭环折线，仅选中时可见）

# 表现层动画状态机（4 向精灵方向切换 + 程序化动画），详见 player_animator.gd
var _animator: PlayerAnimator

# 枪械挂点贴图（武器表 rifle 段有配置才存在；无枪武器自动回收）
var _rifle: Sprite2D = null



## FSM 当前状态名 → 动画状态（供 PlayerAnimator 使用）
func _current_anim() -> int:
	if state_machine == null or state_machine.current_state == null:
		return PlayerAnimator.Anim.IDLE
	match state_machine.current_state.name:
		&"dead": return PlayerAnimator.Anim.DEAD
		&"hitstun": return PlayerAnimator.Anim.HIT
		&"attack": return PlayerAnimator.Anim.ATTACK
		&"dodge": return PlayerAnimator.Anim.DODGE
		&"move": return PlayerAnimator.Anim.WALK
		_: return PlayerAnimator.Anim.IDLE


## 表现层公共查询：当前动画状态。
## 3D 视觉层（PlayerVisual3D）靠它复用同一套 FSM 判定，避免两套状态逻辑各说各话。
func current_anim() -> int:
	return _current_anim()


func _ready() -> void:
	add_to_group("player")
	z_index = 1
	# 自动攻击的出厂开关 = config 全局值；之后由菜单栏的开关单独控制本角色
	auto_attack_on = bool(Config.get_value("combat.auto_attack.enabled", true))
	_animator = PlayerAnimator.new(_sprite)
	# 武器要先解析：武器可以强制指定贴图集（弓必须用弓手素材 —— 拉弓动作只存在于
	# Archer，拿枪兵素材去射箭是画不出来的）。武器没指定才回落到 player.sprite_set。
	_resolve_initial_weapon()
	# 帧序列来自哪个节点：武器优先，其次 player.sprite_set
	# （"sprites" = 旧程序化四向帧，"sprites_ts" = Tiny Swords 官方单位帧，
	#  "sprites_lancer" = 8 向枪兵，"sprites_archer" = 弓手）。
	# 切美术只改 config，不动代码。
	var set_name := _sprite_set_for_weapon()
	var sprite_cfg: Dictionary = Config.get_value(set_name, {})
	if sprite_cfg.is_empty():
		push_warning("[Player] 精灵集为空：%s，回退 sprites" % set_name)
		sprite_cfg = Config.get_value("sprites", {})
	_animator.load_from_config(sprite_cfg, _view_cfg_for(sprite_cfg))
	facing = Vector2(0, 1)   # 出生默认朝下方（标准俯视）
	speed = float(Config.get_value("player.speed", 160.0)) + trait_flat("move_speed")
	var select_radius := float(Config.get_value("player.select_radius_px", 16.0))
	(_select_area.get_node("CollisionShape2D").shape as CircleShape2D).radius = select_radius
	# 选中标记用**暖色**：头顶那颗等级光点是蓝白系，两个蓝色悬浮物挤在一起
	# 会分不清哪个是「选中」哪个是「等级」（实拍连拍验出来的，见 unit_level_badge.gd）。
	var sel_color := Color(str(Config.get_value("player.selected_color", "#FFC14D")))
	_select_icon.icon_color = sel_color
	_select_icon.visible = false
	_select_area.input_event.connect(_on_select_area_input)
	_path_line = Line2D.new()
	_path_line.width = 2.0
	_path_line.default_color = Color(1.0, 0.9, 0.3, 0.8)
	_path_line.z_index = 100
	_path_line.visible = false
	add_child(_path_line)
	# 巡逻路线：世界坐标折线（与本节点同变换，直接给世界坐标即可）
	_patrol_line = Line2D.new()
	_patrol_line.width = 2.0
	_patrol_line.default_color = Color(0.42, 0.86, 1.0, 0.85)
	_patrol_line.z_index = 100
	_patrol_line.visible = false
	add_child(_patrol_line)
	_init_combat()
	_setup_rifle()
	_setup_level_badge()
	_init_state_machine()


## 枪械挂点：武器表 rifle 段（texture/offset_px/scale）。
## 为什么用挂点而不是换精灵集：免费包没有任何「持枪」动作帧，换精灵集无图可换；
## 挂点跟着 facing 旋转即可，角色动画（含 Lancer 8 向）原样保留。
## offset = 抓握点（机匣）锚在 offset_px 指的位置，旋转围绕握把转才自然。
func _setup_rifle() -> void:
	var rc = weapon_data().get("rifle", null)
	if not (rc is Dictionary) or (rc as Dictionary).is_empty():
		if _rifle != null and is_instance_valid(_rifle):
			_rifle.queue_free()
		_rifle = null
		return
	var cfg: Dictionary = rc
	var tex_path := str(cfg.get("texture", ""))
	if tex_path == "" or not ResourceLoader.exists(tex_path):
		push_warning("[Weapon] 枪械贴图缺失：%s（贴图文件要先跑 godot_import.py）" % tex_path)
		return
	if _rifle == null:
		_rifle = Sprite2D.new()
		_rifle.name = "Rifle"
		_rifle.centered = false
		add_child(_rifle)
	_rifle.texture = load(tex_path)
	var off: Array = cfg.get("offset_px", [8.0, -20.0])
	_rifle.position = Vector2(float(off[0]), float(off[1]))
	_rifle.offset = Vector2(-22, -15)   # 抓握点 = 机匣中心（画布 72x24）
	_rifle.scale = Vector2.ONE * float(cfg.get("scale", 1.0))
	_rifle.z_index = 2                  # 画在角色身体之上


## 头顶等级徽章：节点在 Scenes/Player.tscn 里（LevelBadge），这里只把当前等级灌进去。
## 为什么徽章要独立成节点而不是烘进贴图：等级是**运行时**属性（升级发生在局外结算），
## 烘进贴图意味着 9 级 × 3 角色 = 27 套帧，且每次调数值都要重出图。
func _setup_level_badge() -> void:
	_badge = get_node_or_null("LevelBadge")
	if _badge == null or not _badge.has_method("refresh"):
		_badge = null
		return
	_badge.call("refresh", level, Meta.tier_id_of_level(level))


## 设定这个人的等级（0~progression.max_level）。
## 跨档位时**换整套贴图**（蓝新兵 → 紫老兵 → 黑精锐 → 金传奇），档位内只换徽章数字。
## 换贴图要重载帧序列，所以档位没变就绝不重载 —— 否则每次结算都白重建一次。
func apply_level(lv: int) -> void:
	var clamped := clampi(lv, 0, Meta.max_level())
	if clamped == level:
		_ensure_badge_synced()
		return
	var tier_changed := Meta.tier_id_of_level(clamped) != Meta.tier_id_of_level(level)
	level = clamped
	_ensure_badge_synced()
	if tier_changed:
		_reload_animator()
		print("[Level] %s 进入 %s 档（Lv%d）→ 贴图集 %s"
				% [character_name, Meta.tier_name_of_level(level), level,
					_sprite_set_for_weapon()])


func _ensure_badge_synced() -> void:
	if _badge == null or not is_instance_valid(_badge):
		_badge = get_node_or_null("LevelBadge")
	if _badge != null and _badge.has_method("refresh"):
		_badge.call("refresh", level, Meta.tier_id_of_level(level))


## 发声记账。`amount` 是**已经乘过世界噪音增益**的量（增益的算法只在
## NoiseSystem.self_gain_from_world 写了这一份），这里不再二次加工 ——
## 否则「这里再按世界噪音放大一次」会让调参完全失控（指数上的指数）。
func add_self_noise(amount: float) -> void:
	var smax := maxf(1.0, float(Config.get_value("noise.self.max", 300.0)))
	self_noise = clampf(self_noise + maxf(0.0, amount), 0.0, smax)


## 开局清零（NoiseSystem.reset 会遍历 player 组调它）
func clear_self_noise() -> void:
	self_noise = 0.0


func _process(_delta: float) -> void:
	if _rifle != null and is_instance_valid(_rifle):
		_rifle.rotation = facing.angle()
		_rifle.flip_v = facing.x < 0.0   # 朝左持枪不倒持


## 画布参数（缩放 / 脚底偏移 / 程序化位移单位）是**按画布尺寸算出来的**，
## 而各精灵集的画布并不一样（sprites 48px、sprites_ts 192px、sprites_lancer 320px），
## 所以优先取精灵集自带的 view，缺了才回退 player 段的全局值。
## 不这么做的话，在设置里切换贴图集会让角色突然变大变小、或者浮空 / 陷地。
func _view_cfg_for(sprite_cfg: Dictionary) -> Dictionary:
	var view: Dictionary = (Config.get_value("player", {}) as Dictionary).duplicate()
	var own = sprite_cfg.get("view", null)
	if own is Dictionary:
		for k in own:
			view[k] = own[k]
	return view


# ------------------------------------------------------------
# 行为决策层：有限状态机
# ------------------------------------------------------------

func _init_state_machine() -> void:
	state_machine = StateMachine.new()
	state_machine.name = "StateMachine"
	add_child(state_machine)
	state_machine.setup(self, &"idle",
			bool(Config.get_value("debug.log_state_transitions", false)))
	state_machine.add_state(PlayerIdleState.new(self))
	state_machine.add_state(PlayerMoveState.new(self))
	state_machine.add_state(PlayerAttackState.new(self))
	state_machine.add_state(PlayerHitStunState.new(self))
	state_machine.add_state(PlayerDodgeState.new(self))
	state_machine.add_state(PlayerDeadState.new(self))
	state_machine.start()


func _physics_process(delta: float) -> void:
	_tick_combat_timers(delta)
	# 自动战斗：刷新锁定目标（内部节流）。状态机只用结果，不自己遍历场景组。
	_update_auto_target(delta)
	# 行为决策交给状态机，本组件只提供能力
	state_machine.physics_update(delta)
	# 巡逻排在状态机之后：状态机这一帧把「到达」处理掉（清目标 → 回 idle），
	# 这里立刻下令走下一个巡逻点，idle 下一帧看到有移动目标就自动转 move。
	_tick_patrol(delta)
	if _animator != null:
		_animator.update(delta, _current_anim(), facing)


func _unhandled_input(event: InputEvent) -> void:
	if get_tree().paused or _dead:
		return
	# 小队 RTS 指挥：攻击/闪避/移动指令只发给当前选中的那名角色，
	# 未选中的角色不受键鼠影响（各自继续执行状态机里的既有行为）。
	if not selected:
		return
	# 攻击已改为全自动（2026-09-17）：不再有手动攻击键/攻击鼠标键，
	# 只要敌人进入「观察视野 ∩ 攻击距离」就自动起手，这里只留冲刺键。
	var dodge_key := int(Config.get_value("combat.input.dodge_key", 32))     # Space
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == dodge_key:
			push_input(&"dodge")
			return
		# ESC：先用来「退出待点选模式」（指定攻击 / 巡逻设点），
		# 没有待点选状态时才放行给 Main（那边才轮到退出游戏）。
		if event.is_action("ui_cancel") and _arm_mode != &"":
			_arm_mode = &""
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseButton and event.pressed:
		# 右键 = 取消当前指令（RTS 惯例）。左键「选择 / 框选 / 空地下令」已交给
		# SelectionController：它区分点击 vs 拖拽，并把指令同时下达给所有选中单位。
		if event.button_index == MOUSE_BUTTON_RIGHT:
			cancel_commands()
			return
	state_machine.handle_input(event)


# ------------------------------------------------------------
# 菜单栏指令（指挥层：菜单栏发指令，本组件执行）
# ------------------------------------------------------------

## 下一条左键指令。世界点击（地图上）与菜单栏小地图点击都走这里，
## 所以「点小地图移动」和「在地图上点」行为完全一致，待点选模式也通用。
func command_click(world_pos: Vector2) -> void:
	if _dead:
		return
	match _arm_mode:
		&"designate":
			# 指定攻击：点中敌人即锁定（之后只要它还在「视野 ∩ 射程」内就优先打它）；
			# 点空处 = 放弃这次指定，回到自动索敌。
			var t := _enemy_near(world_pos, designate_pick_radius_px())
			designated_target = t
			_arm_mode = &""
			return
		&"patrol_set":
			# 巡逻设点：每点一次地面加一个巡逻点（可在小地图上点）
			_patrol_points.append(world_pos)
			_patrol_index = 0
			return
	set_move_target(world_pos)


## 自动攻击开关（菜单栏「自动攻击」按钮）
func set_auto_attack(value: bool) -> void:
	auto_attack_on = value
	if not value:
		_auto_target = null


## 索敌策略：nearest（最近）/ strongest（最强）。见 _pick_by_stance()。
func set_target_stance(stance: StringName) -> void:
	target_stance = stance if stance == &"strongest" else &"nearest"


## 进入「指定攻击」待点选模式（再点一次同一个按钮可取消）
func arm_designate() -> bool:
	_arm_mode = &"" if _arm_mode == &"designate" else &"designate"
	return _arm_mode == &"designate"


## 进入「巡逻设点」模式
func begin_patrol_setup() -> void:
	_arm_mode = &"patrol_set"
	_patrol_active = false
	_patrol_points = PackedVector2Array()
	_patrol_index = 0


## 按已设的点开始巡逻（无点返回 false，避免空巡逻把角色钉在原地）
func start_patrol() -> bool:
	if _patrol_points.is_empty():
		return false
	_patrol_active = true
	_arm_mode = &""
	_patrol_index = 0
	_patrol_wait = 0.0
	return true


func stop_patrol() -> void:
	_patrol_active = false
	if _arm_mode == &"patrol_set":
		_arm_mode = &""
	stop_moving()


## 巡逻状态："" 无 / "setting" 设点中 / "active" 巡逻中（菜单栏据此换按钮文字）
func patrol_state() -> StringName:
	if _patrol_active:
		return &"active"
	if _arm_mode == &"patrol_set":
		return &"setting"
	return &""


func patrol_point_count() -> int:
	return _patrol_points.size()


func patrol_points() -> PackedVector2Array:
	return _patrol_points


## 待点选模式（"" / designate / patrol_set）；菜单栏用它高亮按钮
func arm_mode() -> StringName:
	return _arm_mode


## 取消当前指令：解除指定目标、停巡逻、清巡逻点、停下脚步（菜单栏「取消指令」按钮）。
## 不动「自动攻击」与「索敌策略」—— 那两个是持续偏好，不是一次性指令。
func cancel_commands() -> void:
	_arm_mode = &""
	designated_target = null
	_patrol_active = false
	_patrol_points = PackedVector2Array()
	_patrol_index = 0
	stop_moving()


## 巡逻推进：走完一个点、停顿 patrol_wait_seconds，再走向下一个（循环）。
## 只在「当前没有移动目标」时下令，所以不会打断玩家手动点的移动、也不会和攻击抢方向。
## 注意 _patrol_index 是**下令时就自增**的：某一段被攻击打断后不会原地重走同一个点，
## 而是继续往下走（环形路线，迟早绕回来）。
func _tick_patrol(delta: float) -> void:
	if _patrol_active and not _patrol_points.is_empty() and not _dead:
		if not has_move_target():
			_patrol_wait -= delta
			if _patrol_wait <= 0.0:
				set_move_target(_patrol_points[_patrol_index])
				_patrol_index = (_patrol_index + 1) % _patrol_points.size()
				_patrol_wait = float(Config.get_value("menu_bar.patrol_wait_seconds", 0.6))
	# 巡逻路线可视化：把路线画在屏幕上（选中时可见），否则玩家看不出巡逻在跑
	_update_patrol_line()


## 巡逻路线可视化（复用移动路径那条 Line2D 的兄弟节点；只有选中时才画）
func _update_patrol_line() -> void:
	if _patrol_line == null:
		return
	var show := selected and _patrol_points.size() >= 1 and _patrol_active
	_patrol_line.visible = show
	if not show:
		return
	var pts := PackedVector2Array(_patrol_points)
	pts.append(_patrol_points[0])   # 闭环
	_patrol_line.points = pts


## 「指定攻击」点选半径（像素）：在菜单栏点敌人时容错用，不是判定射程
func designate_pick_radius_px() -> float:
	return float(Config.get_value("menu_bar.designate_pick_radius_px", 96.0))


# ------------------------------------------------------------
# 功能组件层：武器（近战 / 远程由武器表分型）
# ------------------------------------------------------------

## 武器总表（config: combat.weapons）。缺失或写错类型 → 整套退化成改造前的单一行为。
func _weapons() -> Dictionary:
	var t = Config.get_value("combat.weapons", {})
	return t if t is Dictionary else {}


## 所有可用武器 id（保持 config 里的书写顺序，跳过 _comment 之类的说明键）
func weapon_ids() -> Array:
	var out: Array = []
	var table := _weapons()
	for k in table.keys():
		var key := str(k)
		if WEAPON_META_KEYS.has(key) or key.begins_with("_"):
			continue
		var v = table[k]
		if v is Dictionary and not (v as Dictionary).is_empty():
			out.append(key)
	return out


## 指定武器（省略 = 当前武器）的配置字典；查不到返回空字典
func weapon_data(id: StringName = &"") -> Dictionary:
	var wid := str(id)
	if wid == "":
		wid = str(current_weapon)
	if wid == "":
		return {}
	var v = _weapons().get(wid, null)
	return v if v is Dictionary else {}


## 当前武器的分型："melee" = 原来的扇形 Hitbox；"ranged" = 判定帧发射弹道
func attack_kind() -> String:
	return str(weapon_data().get("kind", "melee"))


## 按武器覆盖 combat.attack 的同名键；武器没写该键就回落到全局值。
## 这条回退链是「不填 weapons 也完全保持旧行为」的保证。
## 攻击频率特性：三段时序（前摇/判定/后摇）统一除以 (1+累计%)，越多越快。
func attack_param(key: String, fallback: float) -> float:
	var w := weapon_data()
	var v: float = float(w[key]) if w.has(key) \
			else float(Config.get_value("combat.attack." + key, fallback))
	if key == "windup_seconds" or key == "active_seconds" or key == "recovery_seconds":
		var scale := _trait_cadence_scale()
		if scale > 1.0:
			v /= scale
	return v


## 当前武器的挥击噪音；武器没写就回落到 noise.sources.attack
func attack_noise() -> float:
	var w := weapon_data()
	if w.has("noise"):
		return float(w["noise"])
	return float(Config.get_value("noise.sources.attack", 120.0))


## ------------------------------------------------------------
## 升级特性加成（config progression.traits；层数 × per_stack）
##
## traits 由 main.gd 注入（Meta.traits_of），临时角色为空 → 所有加成 0。
## per_stack 全是整数「单位」：flat 类（攻击/防御/气血/移速/视野/攻击距离/投射体速度）
## 直接当点数相加；pct 类（攻击频率）的 per_stack 是「每层百分点」，走
## attack_param 的时序除法（见 _trait_cadence_scale）。
## ------------------------------------------------------------

## 某特性定义（id → 配置项），从 Meta 的表读
func _trait_def(id: String) -> Dictionary:
	return Meta.trait_defs().get(id, {})


## 某特性的数值 = 层数 × per_stack（flat 是点数，pct 是百分点）
func trait_flat(id: String) -> float:
	return float(traits.get(id, 0)) * float(_trait_def(id).get("per_stack", 0.0))


## 攻击频率的时序缩放：累计 +X% → 前摇/判定/后摇除以 (1 + X/100)，越多越快
func _trait_cadence_scale() -> float:
	return 1.0 + trait_flat("attack_speed") / 100.0


## 攻击伤害叠加特性后的最终基础伤害（近战/弹道/瞬狙三条路径共用）
func trait_damage(base: float) -> float:
	return base + trait_flat("attack")


## ------------------------------------------------------------
## 观察视野 / 攻击距离 —— 自动战斗的两个核心属性（2026-09-17 起）
##
## 观察视野 vision_px：**能看见多远**（player.vision_radius_cells × 格宽）。
##   只有视野内的目标才会被自动索敌选中；视野外的敌人不参与任何攻击判定，
##   所以"看不见的敌人"永远不会被自动攻击打到。
## 攻击距离 attack_range_px：**武器打得到多远**——近战取 range_px，
##   远程取弹道射程 projectile.max_distance_px，瞬狙取射线射程 hitscan.max_distance_px。
## 有效攻击距离 = min(攻击距离, 观察视野)：
##   设计上观察视野预期大于攻击距离（先发现、再等它进入射程才开打），
##   但不管数值怎么配，实际射程一律被观察视野截断 —— 杜绝"打到看不见的目标"。
## ------------------------------------------------------------

## 观察视野（像素）；含视野特性加成
func vision_px() -> float:
	return float(Config.get_value("player.vision_radius_cells", 10)) * float(_tile_size) \
			+ trait_flat("vision")


## 武器自身的攻击距离（像素）；含攻击距离特性加成
func attack_range_px() -> float:
	var w := weapon_data()
	match attack_kind():
		"ranged":
			var pc = w.get("projectile", null)
			if pc is Dictionary:
				return float((pc as Dictionary).get("max_distance_px",
						attack_param("range_px", 120.0))) + trait_flat("attack_range")
		"hitscan":
			var hc = w.get("hitscan", null)
			if hc is Dictionary:
				return float((hc as Dictionary).get("max_distance_px",
						attack_param("range_px", 120.0))) + trait_flat("attack_range")
	return attack_param("range_px", 120.0) + trait_flat("attack_range")


## 有效攻击距离：攻击距离与观察视野取小者
func effective_attack_range_px() -> float:
	return minf(attack_range_px(), vision_px())


## 自动索敌（节流刷新）：视野内、且进入有效攻击距离的最近敌对目标；没有则 null。
## 只认 enemies 组 —— 中立生物（animals）不自动打，避免队友见羊就开火。
## 三层优先级（2026-09-17 加菜单栏指令后）：
##   1. 自动攻击开关关掉（菜单栏按钮）→ 永不锁定；
##   2. 有「指定攻击」目标且它仍在有效射程内 → 只打它（focus fire）；
##   3. 否则按索敌策略（最近 / 最强）在射程内挑一个。
func auto_target() -> Node2D:
	return _auto_target


func _update_auto_target(delta: float) -> void:
	if _dead or not auto_attack_on \
			or not bool(Config.get_value("combat.auto_attack.enabled", true)):
		_auto_target = null
		return
	_scan_timer -= delta
	# 已锁定的目标仍然"够得着"时不必重扫；一旦死亡/被回收/跑出有效射程就立刻重扫。
	# 距离必须在这里复核：只判 is_dead 的话，目标跑远了锁定还挂着，
	# 会表现为"对着空气空挥"（状态机不停进 attack，但永远打不到）。
	if _scan_timer > 0.0 and _auto_target != null and is_instance_valid(_auto_target) \
			and not _target_lost(_auto_target) and _within_reach(_auto_target):
		return
	_scan_timer = float(Config.get_value("combat.auto_attack.scan_interval_seconds", 0.15))
	# 指定目标优先（同样受「观察视野 ∩ 攻击距离」约束：跑出射程就解除指定）
	if designated_target != null:
		if not _target_lost(designated_target) and _within_reach(designated_target):
			_auto_target = designated_target
			return
		designated_target = null
	_auto_target = _pick_by_stance()


## 目标是否在有效攻击距离内
func _within_reach(t: Node2D) -> bool:
	return global_position.distance_to(t.global_position) <= effective_attack_range_px()


## 按当前索敌策略挑目标（只考虑射程内的）。
##   nearest   → 距离最近（早发现早开打，默认）
##   strongest → 「最强」= 生命上限高 + 打得疼的优先（先拆掉威胁最大的那个）。
##               评分相同的（比如 4 个劫掠者）退化成「较近者优先」，不会来回跳。
func _pick_by_stance() -> Node2D:
	var reach := effective_attack_range_px()
	var best: Node2D = null
	var best_score := -INF
	var best_dist := INF
	for n in get_tree().get_nodes_in_group(&"enemies"):
		if not is_instance_valid(n) or not (n is Node2D):
			continue
		var tgt := n as Node2D
		if _target_lost(tgt):
			continue
		var d := global_position.distance_to(tgt.global_position)
		if d > reach:
			continue
		var score := -d if target_stance != &"strongest" else _threat_score(tgt)
		if score > best_score or (is_equal_approx(score, best_score) and d < best_dist):
			best_score = score
			best_dist = d
			best = tgt
	return best


## 「最强」评分：生命上限 + 一半的接触伤害。取不到字段时给个中庸值（假目标/中立单位）。
static func _threat_score(t: Node) -> float:
	var mh = t.get("max_hp")
	var hp = t.get("hp")
	var dmg = t.get("damage")
	var s := 20.0
	if mh != null:
		s = float(mh)
	elif hp != null:
		s = float(hp)
	if dmg != null:
		s += float(dmg) * 0.5
	return s


## 距 pos 最近的可打敌人（限定半径）；「指定攻击」点选用。
func _enemy_near(pos: Vector2, radius: float) -> Node2D:
	var best: Node2D = null
	var best_d := radius
	for n in get_tree().get_nodes_in_group(&"enemies"):
		if not is_instance_valid(n) or not (n is Node2D):
			continue
		var tgt := n as Node2D
		if _target_lost(tgt):
			continue
		var d := pos.distance_to(tgt.global_position)
		if d <= best_d:
			best_d = d
			best = tgt
	return best


## 目标是否已不能打（已死或被回收）。敌人/动物都暴露 is_dead()，没有该方法就当活着。
static func _target_lost(t: Node) -> bool:
	if t == null or not is_instance_valid(t):
		return true
	if t.has_method("is_dead"):
		return bool(t.call("is_dead"))
	return false


## 朝当前锁定目标转向（攻击状态进入时调用）；没有目标就保持原朝向，不乱甩枪口。
func aim_at_auto_target() -> void:
	var t := _auto_target
	if t == null or not is_instance_valid(t):
		return
	var to := t.global_position - global_position
	if to.length() > 1.0:
		facing = to.normalized()


## 该武器该用哪套贴图集。优先级（2026-09-17 加等级后）：
##   1. 等级档位配色 —— progression.sprite_sets.<档位>.<武器>（同一个人升级就换配色）
##   2. 武器自带的 sprite_set —— 档位表没配到这把武器时用（如已移出名单的强弩）
##   3. config player.sprite_set —— 武器没指定贴图集时的全局回落
## 为什么不直接把档位写进武器表：档位是**等级**的函数、武器是**兵种**的函数，
## 两者正交；写进武器表就得为每把武器复制 4 份、加一档要改所有武器。
func _sprite_set_for_weapon() -> String:
	var tiered := Meta.unit_sprite_set(str(current_weapon), level)
	if tiered != "":
		return tiered
	var s := str(weapon_data().get("sprite_set", ""))
	if s != "":
		return s
	return str(Config.get_value("player.sprite_set", "sprites"))


## 进局时按「大门选角注入的 initial_weapon → config 的 player.weapon」顺序选武器；
## 都为空/非法则保持"无武器"并告警。
func _resolve_initial_weapon() -> void:
	var want := initial_weapon
	if want == "":
		want = str(Config.get_value("player.weapon", ""))
	if want == "":
		return
	if weapon_ids().has(want):
		current_weapon = StringName(want)
	else:
		push_warning("[Weapon] player.weapon=%s 不在武器表 %s 中，忽略并退回全局 combat.attack"
				% [want, str(weapon_ids())])


## 换武器：切贴图集 + 重设判定框半径。返回是否成功（id 不存在则不动）。
func switch_weapon(id: StringName) -> bool:
	if not weapon_ids().has(str(id)):
		push_warning("[Weapon] 未知武器：%s（可选 %s）" % [str(id), str(weapon_ids())])
		return false
	if str(id) == str(current_weapon):
		return true
	current_weapon = id
	_reload_animator()
	_apply_hitbox_radius()
	_setup_rifle()
	print("[Weapon] 切换武器 -> %s（%s）贴图集=%s"
			% [str(weapon_data().get("name", id)), attack_kind(), _sprite_set_for_weapon()])
	return true


## 按当前武器重新装载帧序列。
## 之所以能"运行时换集"：PlayerAnimator.load_from_config() 内部本来就 clear + reload，
## 换精灵集是它的内置行为，引擎层零改动（做 Lancer 时验证过）。
func _reload_animator() -> void:
	if _animator == null:
		return
	var set_name := _sprite_set_for_weapon()
	var sprite_cfg: Dictionary = Config.get_value(set_name, {})
	if sprite_cfg.is_empty():
		push_warning("[Weapon] 精灵集为空：%s，保持当前贴图" % set_name)
		return
	_animator.load_from_config(sprite_cfg, _view_cfg_for(sprite_cfg))


## 判定框半径跟着武器走，且**必须能重复调用**。
## _init_combat() 里的半径只设一次，换武器不重设的话判定框还是旧武器的
## —— 远程武器这里给 0（它的判定在弹道上，不在玩家身上）。
## 近战半径取**有效**攻击距离（被观察视野截断）：框多大就能打到多远，
## 所以半径必须同样受限，否则会出现"判定框够到、但视野根本看不见"的目标。
func _apply_hitbox_radius() -> void:
	if hitbox == null:
		return
	var shape := hitbox.get_node("CollisionShape2D").shape as CircleShape2D
	if shape == null:
		return
	# 远程/瞬狙仍然给 0：它们的判定在弹道或射线上，玩家身上不该挂判定框。
	# （不能直接用 effective_attack_range_px()，那会把弓/强弩的射程变成一个
	#  巨大却无用的 Area2D，语义错了还可能误伤别处的重叠查询。）
	if attack_kind() != "melee":
		shape.radius = 0.0
		return
	shape.radius = maxf(effective_attack_range_px(), 0.0)


func _init_combat() -> void:
	max_hp = int(Config.get_value("combat.player.max_hp", 100))
	# 局外养成进局内：雕像买的"生命上限"直接决定本局 max_hp
	# （2026-09-14 用户确认，见 04_OPEN_QUESTIONS 已回答第 12 条）
	var meta_hp := int(Meta.get_stat("survival.max_hp"))
	if meta_hp > 0:
		max_hp = meta_hp
	# 气血特性：在养成之后再加一层固定值（层数 × per_stack）
	max_hp += int(trait_flat("hp"))
	hp = max_hp
	print("[Combat] 本局生命上限 %d（含局外养成/升级特性）" % max_hp)
	_run = get_tree().get_first_node_in_group("run_manager")
	if hitbox != null:
		hitbox.monitoring = false   # 只在判定帧窗口开启
		hitbox.monitorable = false
		_apply_hitbox_radius()      # 半径由当前武器决定（可换武器时重设）


func _tick_combat_timers(delta: float) -> void:
	if _invincible_timer > 0.0:
		_invincible_timer -= delta
	if _dodge_cooldown > 0.0:
		_dodge_cooldown -= delta
	# 输入缓冲：超时的指令自然过期
	var life := float(Config.get_value("combat.input.buffer_seconds", 0.25))
	for i in range(_input_buffer.size() - 1, -1, -1):
		var entry: Dictionary = _input_buffer[i]
		entry["age"] = float(entry["age"]) + delta
		if float(entry["age"]) > life:
			_input_buffer.remove_at(i)


## 输入缓冲：按下即入队（蓝图 2.1：提升操作响应；技能在资源/冷却不足时自动重试。注意：已移除攻击连招派生链——本作非动作游戏，攻击为离散动作）
func push_input(action: StringName) -> void:
	_input_buffer.append({"action": action, "age": 0.0})


## 取出一条匹配的缓冲指令（取到即移除）；没有则返回 false
func consume_input(action: StringName) -> bool:
	for i in range(_input_buffer.size() - 1, -1, -1):
		if _input_buffer[i]["action"] == action:
			_input_buffer.remove_at(i)
			return true
	return false


## 缓冲里是否有某条指令（只看不取，用于"条件不满足时保留指令"）
func has_input(action: StringName) -> bool:
	for entry in _input_buffer:
		if entry["action"] == action:
			return true
	return false


## 场上所有可受伤目标（敌人 + 中立生物），已滤掉失效实例
func _damageable_nodes() -> Array:
	var out: Array = []
	for g in DAMAGEABLE_GROUPS:
		for n in get_tree().get_nodes_in_group(g):
			if is_instance_valid(n):
				out.append(n)
	return out


func can_dodge() -> bool:
	return (not _dead) and _dodge_cooldown <= 0.0


func start_dodge_cooldown() -> void:
	_dodge_cooldown = float(Config.get_value("combat.dodge.cooldown_seconds", 0.8))


func is_dead() -> bool:
	return _dead


func is_invincible() -> bool:
	return _dodge_invincible or _invincible_timer > 0.0


func set_invincible(value: bool) -> void:
	_dodge_invincible = value


## 朝鼠标方向（攻击 / 冲刺的朝向）
func aim_at_mouse() -> void:
	var to_mouse := get_global_mouse_position() - global_position
	if to_mouse.length() > 1.0:
		facing = to_mouse.normalized()


## 开启攻击判定（进入判定帧时调用）
func begin_attack_hit() -> void:
	_hit_targets.clear()
	if hitbox != null:
		hitbox.monitoring = true


## 关闭攻击判定（离开判定帧 / 离开攻击状态时调用）
func end_attack_hit() -> void:
	if hitbox != null:
		hitbox.monitoring = false
	_hit_targets.clear()


## 判定帧内调用：对 Hitbox 覆盖到的敌人结算伤害（同一目标只命中一次）
## 仅近战武器使用；远程武器的判定在弹道节点里，所以这里直接返回。
func resolve_attack_hit() -> void:
	if hitbox == null or attack_kind() != "melee":
		return
	var max_targets := int(attack_param("max_targets", 3.0))
	var base_damage := trait_damage(attack_param("damage", 25.0))
	var half_arc := deg_to_rad(attack_param("arc_degrees", 200.0)) * 0.5
	var hits := 0
	for area in hitbox.get_overlapping_areas():
		if hits >= max_targets:
			break
		if not _is_damageable(area):
			continue
		if _hit_targets.has(area):
			continue
		var to_enemy := area.global_position - global_position
		if to_enemy.length() > 1.0:
			var delta_angle := absf(wrapf(to_enemy.angle() - facing.angle(), -PI, PI))
			if delta_angle > half_arc:
				continue
		_hit_targets[area] = true
		hits += 1
		var dmg := DamagePipeline.compute(base_damage)
		area.take_damage(dmg)
		# 「受到攻击也要动」（用户 2026-09-17）：把攻击者位置告诉它，它自己转调查朝我走来。
		# 用 has_method 而不是硬调：命中目标可能是动物（另一个脚本），它没有这个方法。
		if area.has_method("alert_from_attacker"):
			area.call("alert_from_attacker", global_position)
		print("[Combat] 命中 %s，造成 %d 伤害" % [area.name, dmg])


## 发射一枚弹道（远程武器进入判定帧时调用）。返回是否真的发射了。
##
## 挂到玩家的父节点而不是玩家自己身上：箭的寿命比一次挥击长，挂在玩家下面
## 一旦玩家被清掉（换局/死亡回收）会跟着消失；挂同层则与敌人同一容器，层级关系也更自然。
## 顺序必须是「先 add_child 再设 global_position」—— 没入树时 global_position 不生效。
func fire_projectile() -> bool:
	var pc = weapon_data().get("projectile", null)
	if not (pc is Dictionary) or (pc as Dictionary).is_empty():
		push_warning("[Weapon] %s 是远程武器但没有 projectile 配置段"
				% str(weapon_data().get("name", current_weapon)))
		return false
	var parent := get_parent()
	if parent == null:
		return false
	# 射程按"有效攻击距离"截断（≤ 观察视野）：箭飞不出视野范围，
	# 与自动索敌的射程判定用同一个数，避免"锁定得到但箭够不着"或反过来。
	var cfg: Dictionary = (pc as Dictionary).duplicate()
	cfg["max_distance_px"] = effective_attack_range_px()
	# 投射体速度特性：直接叠在弹速上（箭/子弹飞得更快，射程已按有效攻击距离截断）
	cfg["speed"] = float(cfg.get("speed", 900.0)) + trait_flat("projectile_speed")
	var p := PROJECTILE.new()
	p.name = "Projectile"
	parent.add_child(p)
	p.global_position = global_position + facing * float(cfg.get("muzzle_offset_px", 22.0))
	p.setup(cfg, facing, int(trait_damage(attack_param("damage", 20.0))), _walls, _tile_size)
	return true


## 瞬狙（kind = hitscan）：判定帧瞬间沿瞄准线结算，不产生飞行弹道。
## 返回命中数。链路：
##   1. 射线 = 枪口 → 枪口 + facing * max_distance_px；
##   2. first_wall_point 截断到第一个墙点（子弹打不穿墙）；
##   3. targets_on_segment 按沿线先后取前 pierce 个（穿透）；
##   4. 每个目标走 DamagePipeline（与近战/箭同一条减伤管线）；
##   5. 表现 = Line2D 曳光（淡出自毁）+ 命中点 fx_ring。
## 全部判定都是纯数据（无物理查询），无头探针可逐项断言。
func fire_hitscan() -> int:
	var hc = weapon_data().get("hitscan", null)
	if not (hc is Dictionary) or (hc as Dictionary).is_empty():
		push_warning("[Weapon] %s 是瞬狙武器但没有 hitscan 配置段"
				% str(weapon_data().get("name", current_weapon)))
		return 0
	var cfg: Dictionary = hc
	var parent := get_parent()
	if parent == null:
		return 0

	var from := global_position + facing * float(cfg.get("muzzle_offset_px", 34.0))
	# 射线长度同样按"有效攻击距离"截断（≤ 观察视野）：
	# 强弩表上 900px 比 10 格视野（640px）远，实际最远只能打到看得见的地方。
	var max_dist := minf(float(cfg.get("max_distance_px", 900.0)), effective_attack_range_px())
	var far := from + facing * max_dist
	# 墙截断：撞墙的点就是弹道终点（曳光也画到这里，视觉与判定一致）
	var wall_hit = PROJECTILE.first_wall_point(_walls, _tile_size, from, far)
	var to: Vector2 = wall_hit if wall_hit != null else far

	var pierce := int(cfg.get("pierce", 1))
	var radius := float(cfg.get("hit_radius_px", 18.0))
	var targets := PROJECTILE.targets_on_segment(from, to, radius, _damageable_nodes())
	if pierce < targets.size():
		targets = targets.slice(0, pierce)

	var base_damage := trait_damage(attack_param("damage", 25.0))
	for t in targets:
		var dmg := DamagePipeline.compute(base_damage)
		t.take_damage(dmg)
		# 「受到攻击也要动」：挨了瞬狙的敌人会朝枪口方向来（远处点名不再毫无反应）
		if t.has_method("alert_from_attacker"):
			t.call("alert_from_attacker", global_position)
		print("[Combat] 狙击命中 %s，造成 %d 伤害" % [t.name, dmg])

	_spawn_tracer(from, to, cfg)
	if wall_hit != null or not targets.is_empty():
		var impact: Vector2 = to if (wall_hit != null or targets.is_empty()) \
				else (targets[-1] as Node2D).global_position
		_spawn_ring_at(impact, float(cfg.get("impact_radius", 26.0)),
				Color(str(cfg.get("impact_color", "#ff9a3d"))))
	return targets.size()


## 曳光：Line2D 从枪口到终点，按 tracer_fade_seconds 淡出后自毁。
## 挂玩家父层（与弹道同容器），寿命短，不随玩家移动。
func _spawn_tracer(from: Vector2, to: Vector2, cfg: Dictionary) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var line := Line2D.new()
	line.name = "SniperTracer"
	line.width = float(cfg.get("tracer_width", 2.5))
	line.default_color = Color(str(cfg.get("tracer_color", "#ffd873")))
	line.z_index = 40
	line.antialiased = true
	parent.add_child(line)
	line.global_position = from
	line.add_point(Vector2.ZERO)
	line.add_point(to - from)
	var fade := maxf(float(cfg.get("tracer_fade_seconds", 0.18)), 0.05)
	var tw := line.create_tween()
	tw.tween_property(line, "modulate:a", 0.0, fade)
	tw.tween_callback(line.queue_free)


## 冲击环（复用 fx_ring），但**挂在世界层并定位到任意点**——
## 冲击波圆环挂在世界上（全局坐标），狙击命中点在远处也要能定位。
func _spawn_ring_at(pos: Vector2, radius: float, color: Color) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var ring: Node2D = FX_RING.new()
	ring.setup(radius, 0.35, color)
	parent.add_child(ring)
	ring.global_position = pos


## 是否是可受伤目标（敌人 / 中立生物）
static func _is_damageable(node: Node) -> bool:
	for g in DAMAGEABLE_GROUPS:
		if node.is_in_group(g):
			return true
	return false


## 受到伤害（无敌帧可免疫）；返回是否真的吃到伤害
func take_damage(amount: int, source_pos: Vector2 = Vector2.ZERO) -> bool:
	if _dead or is_invincible():
		return false
	# 防御特性：入伤先扣固定减免，扣到 0 就是完全挡下（不掉血、不进硬直）
	var mitigated := maxi(amount - int(trait_flat("defense")), 0)
	if mitigated <= 0:
		return false
	hp = maxi(hp - mitigated, 0)
	_invincible_timer = float(Config.get_value("combat.player.invincible_after_hit_seconds", 0.4))
	var knockback := Vector2.ZERO
	if source_pos != Vector2.ZERO:
		knockback = (global_position - source_pos).normalized() \
				* float(Config.get_value("combat.player.knockback_speed", 140.0))
	print("[Combat] 玩家受到 %d 伤害（减免 %d），剩余 HP %d/%d" % [mitigated, amount - mitigated, hp, max_hp])
	if hp <= 0:
		state_machine.force_transition(&"dead")
		return true
	state_machine.force_transition(&"hitstun", {"knockback": knockback})
	return true


## 回血（食物系统用）；返回实际回复量
func heal(amount: int) -> int:
	if _dead or amount <= 0:
		return 0
	var before := hp
	hp = mini(hp + amount, max_hp)
	return hp - before


## 直接扣血（饥饿等非战斗来源）：不进硬直、不击退、不吃无敌帧；归零即死亡
func apply_direct_damage(amount: int) -> void:
	if _dead or amount <= 0:
		return
	hp = maxi(hp - amount, 0)
	print("[Combat] 玩家损失 %d 生命（非战斗来源），剩余 HP %d/%d" % [amount, hp, max_hp])
	if hp <= 0:
		state_machine.force_transition(&"dead")


## 死亡结算：小队模式下只要还有队友存活本局就继续（全队倒下才算失败）。
## 死者若正被指挥，控制权自动移交给第一名存活队友。
func on_death() -> void:
	if _dead:
		return
	_dead = true
	# 死亡永久（用户 2026-09-17 定）：立刻从名册除名 —— 等级与经验随人一起消失。
	# roster_uid == 0 是「没有名册身份」的临时角色（命令行 / 无头回归 / auto_enter_run），
	# 它们从来没进过名册，自然也不该被除名（否则会误删同名条目）。
	if roster_uid > 0:
		Meta.remove_unit(roster_uid)
		roster_uid = 0
	stop_moving()
	velocity = Vector2.ZERO
	move_and_slide()
	if selected:
		for p in get_tree().get_nodes_in_group("player"):
			if p != self and is_instance_valid(p) and not bool(p.is_dead()):
				p.select()
				break
	for p in get_tree().get_nodes_in_group("player"):
		if p != self and is_instance_valid(p) and not bool(p.is_dead()):
			print("[Combat] %s 倒下，队友仍在，本局继续（背包全队共享）" % character_name)
			return
	if _run == null:
		_run = get_tree().get_first_node_in_group("run_manager")
	if _run != null:
		_run.player_died()


# ------------------------------------------------------------
# 功能组件层：移动能力（供状态调用，与状态机解耦）
# ------------------------------------------------------------

func has_move_target() -> bool:
	return _has_target


func set_move_target(pos: Vector2) -> void:
	_final_target = pos
	_has_target = true
	_clear_path_cache()


func clear_move_target() -> void:
	_has_target = false
	_clear_path_cache()
	_path_line.visible = false


## 立即停止移动（Idle / 攻击 / 受击等状态进入时调用）
func stop_moving() -> void:
	velocity = Vector2.ZERO
	move_and_slide()
	_has_target = false
	_clear_path_cache()
	_path_line.visible = false


## 沿缓存路径走一格（Move 状态每帧调用）
func follow_path() -> void:
	if not _has_target or _astar == null:
		stop_moving()
		return

	var old_pos := global_position
	var my_cell := _cell_of(global_position)
	# 目标格先吸附一次：3D 里点地面是用射线打 y=0 平面，点中树/石头是家常便饭，
	# 直接拿原始格去查 A* 会因为"终点 solid"拿到空路径，表现为点了没反应。
	var end_cell := _goal_cell(_cell_of(_final_target))
	if end_cell.x < 0:
		# 目标格连同邻域全是障碍（比如点了密林正中央）→ 放弃，避免每帧无效重算
		velocity = Vector2.ZERO
		move_and_slide()
		clear_move_target()
		return

	# 已进入目标所在格 → 视为到达。
	# （不用"距点击点 <6px"判定：路径终点是格心，点击格边缘时会永远差几像素、抖动）
	if my_cell == end_cell:
		velocity = Vector2.ZERO
		move_and_slide()
		clear_move_target()
		return

	# 只在必要时重算路径：进入新格子 / 缓存为空 / 连续被挡住
	var need_repath := _cached_path.is_empty() or my_cell != _path_cell \
			or _stall_frames >= STALL_REPATH_FRAMES
	if need_repath:
		# 因为"卡住"才重算 → 累计无效重算次数，超预算就放弃目标。
		if _stall_frames >= STALL_REPATH_FRAMES:
			_stall_repaths += 1
			if _stall_repaths > STALL_GIVE_UP_REPATHS:
				push_warning("[Player] 连续 %d 次重算路径仍无法前进，放弃移动目标（位置 %s）"
						% [_stall_repaths, str(global_position)])
				velocity = Vector2.ZERO
				move_and_slide()
				clear_move_target()
				return
		_path_cell = my_cell
		_stall_frames = 0
		_cached_path = _query_path(my_cell, end_cell)
		if _cached_path.is_empty():
			# 目标不可达（墙内/图外/卡进墙）：放弃目标，避免每帧无效重算
			velocity = Vector2.ZERO
			move_and_slide()
			clear_move_target()
			return
		# path[0] 是当前格心（可能已在身后），从 index=1 开始追踪，否则会回拉抖动
		_path_index = 1 if _cached_path.size() >= 2 else 0
		_path_line.points = _cached_path
		_path_line.visible = selected

	# 推进路点：已通过的跳过（只前进，不回头）
	while _path_index < _cached_path.size() \
			and global_position.distance_to(_cached_path[_path_index]) < WAYPOINT_REACH_DIST:
		_path_index += 1

	var dir := Vector2.ZERO
	if _path_index < _cached_path.size():
		dir = _cached_path[_path_index] - global_position
		# 移动时面朝前进方向（攻击/冲刺朝向的兜底）
		if dir.length() > 1.0:
			facing = dir.normalized()

	var no_dir := dir.length() < 1.0
	if no_dir:
		velocity = Vector2.ZERO
	else:
		# 地形减速：雪原（biome.speed）与河水（river.slow）都落在这张表里。
		velocity = dir.normalized() * speed * terrain_speed_at(my_cell)
	move_and_slide()

	# 卡住检测：本想移动却几乎没挪动（被墙/实体挡住）→ 计数触发重算。
	# no_dir（路点已走完却没进入目标格）也要计入：那种情况速度本来就是 0，
	# 旧版只判 `velocity.length() > 0`，计数器会被清零、永远不触发重算 → 硬死锁。
	if (no_dir or velocity.length() > 0.0) and global_position.distance_to(old_pos) < 0.2:
		_stall_frames += 1
	else:
		_stall_frames = 0
		_stall_repaths = 0        # 真的挪动了 → 之前的无效重算记录作废


# ------------------------------------------------------------
# 导航 / 寻路
# ------------------------------------------------------------

## walls：通行阻挡网格；tile_size：格宽（像素）
## speed_mult：可选的地形速度系数网格（与 walls 同尺寸）。不传 = 全 1.0。
##             MapGenerator.generate() 的 result["speed_mult"] 直接传进来即可。
func setup_navigation(walls: Array, tile_size: int, speed_mult: Array = []) -> void:
	_walls = walls
	_tile_size = tile_size
	_speed_mult = speed_mult
	# A* 网格只在这里构建一次（O(宽×高)，切图级频率）
	_astar = MapGenerator.build_astar(walls, tile_size)
	_has_target = false
	_clear_path_cache()


func _clear_path_cache() -> void:
	_cached_path = PackedVector2Array()
	_path_index = 0
	_path_cell = Vector2i(-9999, -9999)
	_stall_frames = 0
	_stall_repaths = 0


func _cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(int(pos.x / _tile_size), int(pos.y / _tile_size))


## 该格的地形速度系数（1.0 = 正常）。越界或无速度表都返回 1.0。
## 供 follow_path 与调试/探针复用：雪原 0.62、河水取 map.river.slow。
func terrain_speed_at(cell: Vector2i) -> float:
	if _speed_mult.is_empty():
		return 1.0
	if cell.y < 0 or cell.y >= _speed_mult.size():
		return 1.0
	var row: Array = _speed_mult[cell.y]
	if cell.x < 0 or cell.x >= row.size():
		return 1.0
	return clampf(float(row[cell.x]), 0.05, 4.0)


## 当前所站格的速度系数（HUD/调试显示用）
func current_terrain_speed() -> float:
	return terrain_speed_at(_cell_of(global_position))


func _in_bounds(cell: Vector2i) -> bool:
	var h: int = _walls.size()
	if h == 0:
		return false
	var w: int = _walls[0].size()
	return cell.x >= 0 and cell.y >= 0 and cell.x < w and cell.y < h


## 查询路径（起点=玩家所在格，终点=目标格）。不可达返回空数组。
## 不用 get_point_path：它返回格子左上角（偏半格），路径会贴墙角导致卡死；
## 用 get_id_path 拿格子坐标，再用 MapGenerator.ids_to_centers 换算格心。
##
## 【2026-09-15 修「人物卡到树里」】两端都先吸附到最近的可通行格。
## 旧版只要起点或终点是 solid 就返回空 —— 玩家一旦被击退/冲刺推进树格，
## 起点永远是 solid，之后无论怎么点都走不动，就是"卡死在里面"。
func _query_path(from_cell: Vector2i, to_cell: Vector2i) -> PackedVector2Array:
	if _astar == null or not _in_bounds(from_cell) or not _in_bounds(to_cell):
		return PackedVector2Array()
	var start_cell := _nearest_open_cell(from_cell, _unstick_radius())
	var goal_cell := _nearest_open_cell(to_cell, _snap_radius())
	if start_cell.x < 0 or goal_cell.x < 0:
		return PackedVector2Array()
	return MapGenerator.ids_to_centers(_astar.get_id_path(start_cell, goal_cell), _tile_size)


## 目标格吸附：点在树/石头上时改走旁边最近的可走格（而不是原地不动）
func _goal_cell(cell: Vector2i) -> Vector2i:
	return _nearest_open_cell(cell, _snap_radius())


## 以 cell 为中心按环向外找最近的可通行格（含自身）；找不到返回 (-1,-1)。
## 实现放在 MapGenerator，敌人寻路用的是同一份（避免两套逻辑各说各话）。
func _nearest_open_cell(cell: Vector2i, radius: int) -> Vector2i:
	return MapGenerator.nearest_open_cell(_walls, cell, radius)


## 点击目标落在障碍格时的搜索半径（格）
func _snap_radius() -> int:
	return maxi(1, int(Config.get_value("nav.snap_radius_cells", 3)))


## 玩家已经身处障碍格时的脱困搜索半径（格）
func _unstick_radius() -> int:
	return maxi(1, int(Config.get_value("nav.unstick_radius_cells", 4)))


# ------------------------------------------------------------
# 选中交互
# ------------------------------------------------------------

func _on_select_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		select()   # 点角色 = 排他单选并指挥它（RTS 惯例，不做"点一下取消"）


func _set_selected(value: bool) -> void:
	# 纯标志位 + 视觉：不再 stop_moving、也不做互斥。
	# 「同一时刻选中谁」由 select()/SelectionController 统一编排。
	# 旧版这里 deselect 会 stop_moving()，导致「点选别的角色 → 当前角色停下」，
	# 正是要修的 bug：取消选中只是摘掉光环，绝不该打断该单位正在执行的移动/攻击。
	selected = value
	_select_icon.visible = value
	if value and _badge != null and is_instance_valid(_badge) and _badge.has_method("notify_selected"):
		_badge.call("notify_selected")
	_path_line.visible = value and not _cached_path.is_empty()


## 排他单选：点角色 / 死亡移交控制权 / 开局默认选中都走这里 —— 清掉其他只留自己。
func select() -> void:
	for p in get_tree().get_nodes_in_group("player"):
		if p != self and p.has_method("deselect"):
			p.deselect()
	_set_selected(true)


## 框选入口：把自己并入当前选择集，不清除别人（多选用）。
func select_keep_others() -> void:
	_set_selected(true)


## 取消选中（只动自己；是否连带清其它单位由调用方决定）
func deselect() -> void:
	_set_selected(false)

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

# --- 当前武器（config: combat.weapons.<id>）---
# 空 = 不启用武器表，一切走 combat.attack 全局值（改造前的行为）。
var current_weapon: StringName = &""

# --- 大门选角注入（main.gd 在 add_child 前设置）---
# character_name：HUD/日志显示名；initial_weapon：本角色初始武器 id（combat.weapons 键），
# 空则回落 config 的 player.weapon（命令行 / 无头回归路径没有选人面板，走回落）。
var character_name := ""
var initial_weapon := ""


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
	speed = float(Config.get_value("player.speed", 160.0))
	var select_radius := float(Config.get_value("player.select_radius_px", 16.0))
	(_select_area.get_node("CollisionShape2D").shape as CircleShape2D).radius = select_radius
	var sel_color := Color(str(Config.get_value("player.selected_color", "#4fc3f7")))
	_select_icon.icon_color = sel_color
	_select_icon.visible = false
	_select_area.input_event.connect(_on_select_area_input)
	_path_line = Line2D.new()
	_path_line.width = 2.0
	_path_line.default_color = Color(1.0, 0.9, 0.3, 0.8)
	_path_line.z_index = 100
	_path_line.visible = false
	add_child(_path_line)
	_init_combat()
	_setup_rifle()
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
	# 行为决策交给状态机，本组件只提供能力
	state_machine.physics_update(delta)
	if _animator != null:
		_animator.update(delta, _current_anim(), facing)


func _unhandled_input(event: InputEvent) -> void:
	if get_tree().paused or _dead:
		return
	# 小队 RTS 指挥：攻击/闪避/移动指令只发给当前选中的那名角色，
	# 未选中的角色不受键鼠影响（各自继续执行状态机里的既有行为）。
	if not selected:
		return
	var attack_button := int(Config.get_value("combat.input.attack_mouse_button", 2))
	var attack_key := int(Config.get_value("combat.input.attack_key", 74))   # J
	var dodge_key := int(Config.get_value("combat.input.dodge_key", 32))     # Space
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == attack_button:
		push_input(&"attack")
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == attack_key:
			push_input(&"attack")
			return
		if event.physical_keycode == dodge_key:
			push_input(&"dodge")
			return
	state_machine.handle_input(event)
	if not selected:
		return
	if not (event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT):
		return
	set_move_target(get_global_mouse_position())


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
func attack_param(key: String, fallback: float) -> float:
	var w := weapon_data()
	if w.has(key):
		return float(w[key])
	return float(Config.get_value("combat.attack." + key, fallback))


## 当前武器的挥击噪音；武器没写就回落到 noise.sources.attack
func attack_noise() -> float:
	var w := weapon_data()
	if w.has("noise"):
		return float(w["noise"])
	return float(Config.get_value("noise.sources.attack", 120.0))


## 该武器该用哪套贴图集；空字符串 = 跟随 player.sprite_set
func _sprite_set_for_weapon() -> String:
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
func _apply_hitbox_radius() -> void:
	if hitbox == null:
		return
	var shape := hitbox.get_node("CollisionShape2D").shape as CircleShape2D
	if shape == null:
		return
	shape.radius = maxf(attack_param("range_px", 30.0), 0.0)


func _init_combat() -> void:
	max_hp = int(Config.get_value("combat.player.max_hp", 100))
	# 局外养成进局内：雕像买的"生命上限"直接决定本局 max_hp
	# （2026-09-14 用户确认，见 04_OPEN_QUESTIONS 已回答第 12 条）
	var meta_hp := int(Meta.get_stat("survival.max_hp"))
	if meta_hp > 0:
		max_hp = meta_hp
	hp = max_hp
	print("[Combat] 本局生命上限 %d（含局外养成）" % max_hp)
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
	var base_damage := attack_param("damage", 25.0)
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
	var cfg: Dictionary = pc
	var p := PROJECTILE.new()
	p.name = "Projectile"
	parent.add_child(p)
	p.global_position = global_position + facing * float(cfg.get("muzzle_offset_px", 22.0))
	p.setup(cfg, facing, int(attack_param("damage", 20.0)), _walls, _tile_size)
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
	var far := from + facing * float(cfg.get("max_distance_px", 900.0))
	# 墙截断：撞墙的点就是弹道终点（曳光也画到这里，视觉与判定一致）
	var wall_hit = PROJECTILE.first_wall_point(_walls, _tile_size, from, far)
	var to: Vector2 = wall_hit if wall_hit != null else far

	var pierce := int(cfg.get("pierce", 1))
	var radius := float(cfg.get("hit_radius_px", 18.0))
	var targets := PROJECTILE.targets_on_segment(from, to, radius, _damageable_nodes())
	if pierce < targets.size():
		targets = targets.slice(0, pierce)

	var base_damage := attack_param("damage", 25.0)
	for t in targets:
		var dmg := DamagePipeline.compute(base_damage)
		t.take_damage(dmg)
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
	hp = maxi(hp - amount, 0)
	_invincible_timer = float(Config.get_value("combat.player.invincible_after_hit_seconds", 0.4))
	var knockback := Vector2.ZERO
	if source_pos != Vector2.ZERO:
		knockback = (global_position - source_pos).normalized() \
				* float(Config.get_value("combat.player.knockback_speed", 140.0))
	print("[Combat] 玩家受到 %d 伤害，剩余 HP %d/%d" % [amount, hp, max_hp])
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
		_set_selected(true)   # 点角色 = 选中指挥它（RTS 惯例，不再做"点一下取消"）


func _set_selected(value: bool) -> void:
	selected = value
	_select_icon.visible = value
	if value:
		# 小队互斥：同一时刻只有一名角色被选中，后点的顶掉先前的
		for p in get_tree().get_nodes_in_group("player"):
			if p != self and p.has_method("deselect"):
				p.deselect()
	else:
		stop_moving()
	_path_line.visible = value and not _cached_path.is_empty()


## 供 main / 死亡移交控制权时选中本角色
func select() -> void:
	_set_selected(true)


## 取消选中（小队互斥由 _set_selected(true) 触发）
func deselect() -> void:
	_set_selected(false)

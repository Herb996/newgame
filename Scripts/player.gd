extends CharacterBody2D
## ============================================================
## Player — 玩家（功能组件层）
##
## 分层（见 06_FIGHT.md 核心架构原则）：
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

# --- 体力（技能资源，蓝图 Phase 2 资源循环） ---
var stamina := 0.0
var max_stamina := 0.0
var _stamina_regen_delay := 0.0      # 消耗后的回复延迟

# --- 增益：齿轮护盾限时减伤 ---
var guard_reduction := 0.0           # 0~0.9，当前减伤比例
var guard_remaining := 0.0           # 剩余时长（秒）

# 导航数据：由 main.gd 注入
var _walls: Array = []
var _tile_size: int = 16
var _astar: AStarGrid2D              # 缓存网格（每张地图构建一次）

var _final_target := Vector2.ZERO    # 用户点击的最终目标点
var _has_target := false

# 路径缓存
var _cached_path := PackedVector2Array()
var _path_index := 0                        # 当前追踪的路点下标（只前进，不回头）
var _path_cell := Vector2i(-9999, -9999)   # 上次计算路径时玩家所在格
var _stall_frames := 0                      # 连续被挡住的帧数（卡住检测）
const STALL_REPATH_FRAMES := 20             # 卡住约 1/3 秒后强制重算路径
const WAYPOINT_REACH_DIST := 4.0            # 距路点小于此值视为已通过该路点

var state_machine: StateMachine
var skill_system: SkillSystem

@onready var _select_area: Area2D = $SelectArea
@onready var _select_icon: Node2D = $SelectIcon
@onready var _sprite: Sprite2D = $Body
@onready var hitbox: Area2D = $Hitbox
var _path_line: Line2D

# 表现层动画状态机（4 向精灵方向切换 + 程序化动画），详见 player_animator.gd
var _animator: PlayerAnimator



## FSM 当前状态名 → 动画状态（供 PlayerAnimator 使用）
func _current_anim() -> int:
	if state_machine == null or state_machine.current_state == null:
		return PlayerAnimator.Anim.IDLE
	match state_machine.current_state.name:
		&"dead": return PlayerAnimator.Anim.DEAD
		&"hitstun": return PlayerAnimator.Anim.HIT
		&"attack": return PlayerAnimator.Anim.ATTACK
		&"dodge": return PlayerAnimator.Anim.DODGE
		&"skill": return PlayerAnimator.Anim.ATTACK
		&"move": return PlayerAnimator.Anim.WALK
		_: return PlayerAnimator.Anim.IDLE


func _ready() -> void:
	add_to_group("player")
	z_index = 1
	_animator = PlayerAnimator.new(_sprite)
	_animator.load_from_config(Config.get_value("sprites", {}))
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
	_init_state_machine()


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
	state_machine.add_state(PlayerSkillState.new(self))
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
		var skill_id := _skill_id_for_key(event.physical_keycode)
		if skill_id != &"":
			push_input(StringName("skill_%s" % str(skill_id)))
			return
	state_machine.handle_input(event)
	if not selected:
		return
	if not (event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT):
		return
	set_move_target(get_global_mouse_position())


# ------------------------------------------------------------
# 功能组件层：战斗能力
# ------------------------------------------------------------

func _init_combat() -> void:
	max_hp = int(Config.get_value("combat.player.max_hp", 100))
	# 局外养成进局内：雕像买的"生命上限"直接决定本局 max_hp
	# （2026-09-14 用户确认，见 04_OPEN_QUESTIONS 已回答第 12 条）
	var meta_hp := int(Meta.get_stat("survival.max_hp"))
	if meta_hp > 0:
		max_hp = meta_hp
	hp = max_hp
	print("[Combat] 本局生命上限 %d（含局外养成）" % max_hp)
	max_stamina = float(Config.get_value("combat.stamina.max", 100.0))
	stamina = max_stamina
	_run = get_tree().get_first_node_in_group("run_manager")
	_init_skill_system()
	if hitbox != null:
		var radius := float(Config.get_value("combat.attack.range_px", 30.0))
		(hitbox.get_node("CollisionShape2D").shape as CircleShape2D).radius = radius
		hitbox.monitoring = false   # 只在判定帧窗口开启
		hitbox.monitorable = false


## 技能系统：从 config 装配技能表，之后由 SkillSystem 自己做冷却 tick 与释放校验
func _init_skill_system() -> void:
	skill_system = SkillSystem.new()
	skill_system.name = "SkillSystem"
	add_child(skill_system)
	skill_system.setup(self)


func _tick_combat_timers(delta: float) -> void:
	if _invincible_timer > 0.0:
		_invincible_timer -= delta
	if _dodge_cooldown > 0.0:
		_dodge_cooldown -= delta
	# 体力：消耗后停 regen_delay 秒再回复（资源循环：消耗 → 延迟 → 缓慢回满）
	if _stamina_regen_delay > 0.0:
		_stamina_regen_delay -= delta
	elif stamina < max_stamina:
		stamina = minf(stamina
				+ float(Config.get_value("combat.stamina.regen_per_second", 16.0)) * delta,
				max_stamina)
	# 护盾增益计时
	if guard_remaining > 0.0:
		guard_remaining -= delta
		if guard_remaining <= 0.0:
			guard_remaining = 0.0
			guard_reduction = 0.0
			print("[Skill] 齿轮护盾结束")
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


## 缓冲里最早的一条技能指令（返回技能 id；没有返回空）
func next_skill_input() -> StringName:
	if skill_system == null:
		return &""
	for sid in skill_system.ids():
		if has_input(StringName("skill_%s" % str(sid))):
			return sid
	return &""


## 尝试释放缓冲里最早的一条技能指令；成功（已切到 skill 状态）返回 true
## 资源不足/冷却中时保留指令，下一帧继续尝试，直到缓冲过期
func try_cast_buffered_skill() -> bool:
	var sid := next_skill_input()
	if sid == &"":
		return false
	if not skill_system.try_cast(sid):
		return false
	consume_input(StringName("skill_%s" % str(sid)))
	return true


## 按键码 → 技能 id（键位写在 config 的 combat.skills.<id>.key）
func _skill_id_for_key(keycode: int) -> StringName:
	if skill_system == null or keycode <= 0:
		return &""
	for sid in skill_system.ids():
		if int(skill_system.get_skill(sid).data.get("key", 0)) == keycode:
			return sid
	return &""


# --- 体力（技能资源） ---

func spend_stamina(cost: int) -> void:
	stamina = maxf(stamina - float(cost), 0.0)
	_stamina_regen_delay = float(Config.get_value("combat.stamina.regen_delay_seconds", 0.8))


# --- 增益 ---

## 齿轮护盾：限时减伤（reduction 0~1，duration 秒）
func apply_guard(reduction: float, duration: float) -> void:
	guard_reduction = clampf(reduction, 0.0, 0.9)
	guard_remaining = duration
	print("[Skill] 齿轮护盾：减伤 %.0f%%，持续 %.1f 秒" % [guard_reduction * 100.0, duration])


# --- 技能效果（功能组件层，供 PlayerSkillState 调用） ---

## 圆形范围伤害 + 击退（蒸汽爆发）。
## 直接遍历 enemies 组按距离判定：100 个敌人量级，比物理查询更省。
func skill_aoe_hit(radius: float, damage: int, knockback_speed: float) -> void:
	var hits := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e):
			continue
		var to_enemy: Vector2 = e.global_position - global_position
		if to_enemy.length() > radius:
			continue
		e.take_damage(damage)
		if e.has_method("apply_knockback"):
			e.apply_knockback(to_enemy.normalized() * knockback_speed)
		hits += 1
	print("[Skill] 范围命中 %d 个目标，每个 %d 伤害" % [hits, damage])


## 突进沿途伤害（钩爪突进）：同一目标只命中一次，去重表由调用方持有
func skill_dash_hit(radius: float, damage: int, hit_targets: Dictionary) -> void:
	for e in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e) or hit_targets.has(e):
			continue
		if e.global_position.distance_to(global_position) > radius:
			continue
		hit_targets[e] = true
		e.take_damage(damage)


## 生成冲击波圆环（灰盒视觉反馈，播完自毁）
func spawn_impact_ring(radius: float, color: Color) -> void:
	var ring: Node2D = FX_RING.new()
	ring.setup(radius, 0.35, color)
	add_child(ring)


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
func resolve_attack_hit() -> void:
	if hitbox == null:
		return
	var max_targets := int(Config.get_value("combat.attack.max_targets", 3))
	var base_damage := float(Config.get_value("combat.attack.damage", 25.0))
	var half_arc := deg_to_rad(float(Config.get_value("combat.attack.arc_degrees", 200.0))) * 0.5
	var hits := 0
	for area in hitbox.get_overlapping_areas():
		if hits >= max_targets:
			break
		if not area.is_in_group("enemies"):
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
		print("[Combat] 命中敌人，造成 %d 伤害" % dmg)


## 受到伤害（无敌帧可免疫）；返回是否真的吃到伤害
func take_damage(amount: int, source_pos: Vector2 = Vector2.ZERO) -> bool:
	if _dead or is_invincible():
		return false
	# 护盾减伤（齿轮护盾）：按比例削减后取整
	var final_damage := amount
	if guard_remaining > 0.0 and guard_reduction > 0.0:
		final_damage = int(round(float(amount) * (1.0 - guard_reduction)))
	hp = maxi(hp - final_damage, 0)
	_invincible_timer = float(Config.get_value("combat.player.invincible_after_hit_seconds", 0.4))
	var knockback := Vector2.ZERO
	if source_pos != Vector2.ZERO:
		knockback = (global_position - source_pos).normalized() \
				* float(Config.get_value("combat.player.knockback_speed", 140.0))
	if final_damage != amount:
		print("[Combat] 玩家受到 %d 伤害（护盾减伤后 %d），剩余 HP %d/%d" % [
			amount, final_damage, hp, max_hp])
	else:
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


## 死亡结算：通知 RunManager（本局资源全丢）
func on_death() -> void:
	if _dead:
		return
	_dead = true
	stop_moving()
	velocity = Vector2.ZERO
	move_and_slide()
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
	var end_cell := _cell_of(_final_target)

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

	if dir.length() < 1.0:
		velocity = Vector2.ZERO
	else:
		velocity = dir.normalized() * speed
	move_and_slide()

	# 卡住检测：本想移动却几乎没挪动（被墙/实体挡住）→ 计数触发重算
	if velocity.length() > 0.0 and global_position.distance_to(old_pos) < 0.2:
		_stall_frames += 1
	else:
		_stall_frames = 0


# ------------------------------------------------------------
# 导航 / 寻路
# ------------------------------------------------------------

func setup_navigation(walls: Array, tile_size: int) -> void:
	_walls = walls
	_tile_size = tile_size
	# A* 网格只在这里构建一次（O(宽×高)，切图级频率）
	_astar = MapGenerator.build_astar(walls, tile_size)
	_has_target = false
	_clear_path_cache()


func _clear_path_cache() -> void:
	_cached_path = PackedVector2Array()
	_path_index = 0
	_path_cell = Vector2i(-9999, -9999)
	_stall_frames = 0


func _cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(int(pos.x / _tile_size), int(pos.y / _tile_size))


func _in_bounds(cell: Vector2i) -> bool:
	var h: int = _walls.size()
	if h == 0:
		return false
	var w: int = _walls[0].size()
	return cell.x >= 0 and cell.y >= 0 and cell.x < w and cell.y < h


## 查询路径（起点=玩家所在格，终点=目标格）。不可达返回空数组。
## 不用 get_point_path：它返回格子左上角（偏半格），路径会贴墙角导致卡死；
## 用 get_id_path 拿格子坐标，再用 MapGenerator.ids_to_centers 换算格心。
func _query_path(from_cell: Vector2i, to_cell: Vector2i) -> PackedVector2Array:
	if _astar == null or not _in_bounds(from_cell) or not _in_bounds(to_cell):
		return PackedVector2Array()
	if _walls[from_cell.y][from_cell.x] or _walls[to_cell.y][to_cell.x]:
		return PackedVector2Array()
	return MapGenerator.ids_to_centers(_astar.get_id_path(from_cell, to_cell), _tile_size)


# ------------------------------------------------------------
# 选中交互
# ------------------------------------------------------------

func _on_select_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_set_selected(not selected)


func _set_selected(value: bool) -> void:
	selected = value
	_select_icon.visible = value
	if not value:
		stop_moving()
	_path_line.visible = value and not _cached_path.is_empty()

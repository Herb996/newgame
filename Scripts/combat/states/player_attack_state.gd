class_name PlayerAttackState
extends State
## ============================================================
## PlayerAttackState — 攻击状态（蓝图 Phase 1：单次轻攻击）
## 生命周期：PreCast 前摇 → Cast 判定帧 → PostCast 后摇
##   windup   前摇：不能移动、不能取消（可被受击 HitStun 打断）
##   active   判定帧：开启 Hitbox，逐帧结算命中（内部去重，同一次挥击只打一次）
##   recovery 后摇：固定时长，结束即回 Idle（本作非动作游戏，不接后摇取消/连招）
## 移动：整个攻击期间速度归零（本作偏策略，不做攻击位移）
##
## 【近战 / 远程分型】2026-09-16 加入：动作列表与时长改由**当前武器**决定
## （actor.attack_param），判定帧往哪走按 actor.attack_kind() 分岔：
##   melee   → begin_attack_hit() + 逐帧 resolve_attack_hit()（原行为，一字未改）
##   ranged  → fire_projectile() 发射一次，不碰 Hitbox（箭会飞）
##   hitscan → fire_hitscan() 瞬间结算 + 曳光（狙击枪：判定与出枪同帧）
## 武器没写某一项时 attack_param 会自动回落到 combat.attack，所以不配武器表 = 老行为。
## ============================================================

enum Phase { WINDUP, ACTIVE, RECOVERY }

var _phase: int = Phase.WINDUP
var _timer := 0.0


func _init(p_actor: Node = null) -> void:
	super(&"attack", p_actor)


func enter(_msg: Dictionary = {}) -> void:
	actor.stop_moving()
	actor.aim_at_mouse()          # 朝鼠标方向挥击 / 射击
	_phase = Phase.WINDUP
	_timer = 0.0


func exit() -> void:
	actor.end_attack_hit()        # 兜底：任何原因离开都关闭判定框（远程下本就是关的）
	# 丢弃缓冲攻击输入：攻击离散、不连招（已移除连招派生链）
	actor.consume_input(&"attack")


func physics_update(delta: float) -> void:
	# 必须显式写类型：actor 声明为 Node，attack_param 是「不安全调用」返回 Variant，
	# 用 := 推断会直接 Parse Error（Cannot infer the type）。
	var windup: float = actor.attack_param("windup_seconds", 0.12)
	var active: float = actor.attack_param("active_seconds", 0.08)
	var recovery: float = actor.attack_param("recovery_seconds", 0.2)
	var kind: String = actor.attack_kind()
	var hit_once: bool = kind != "melee"    # ranged / hitscan 都只在判定帧开工一次

	_timer += delta
	actor.velocity = Vector2.ZERO
	actor.move_and_slide()

	match _phase:
		Phase.WINDUP:
			if _timer >= windup:
				_phase = Phase.ACTIVE
				_timer = 0.0
				if kind == "ranged":
					# 拉弓 8 帧的放箭点：进入判定帧的那一瞬发射一次，之后不再发
					actor.fire_projectile()
				elif kind == "hitscan":
					# 瞬狙：判定与出枪同帧，命中数只影响日志/表现
					actor.fire_hitscan()
				else:
					actor.begin_attack_hit()
				# 出招发声：惊动附近敌人（DESIGN.md 第二部分 噪音机制）
				# 取武器自己的噪音值 —— 弓比剑安静、狙击枪震天响，潜行时的可利用差异
				NoiseSystem.emit(actor.global_position, actor.attack_noise())
		Phase.ACTIVE:
			if not hit_once:
				actor.resolve_attack_hit()   # 判定帧内每帧结算（内部按目标去重）
			if _timer >= active:
				_phase = Phase.RECOVERY
				_timer = 0.0
				if not hit_once:
					actor.end_attack_hit()
		Phase.RECOVERY:
			# 本作非动作游戏：攻击为离散动作，后摇结束直接回 Idle；
			# 缓冲里的攻击输入在 exit() 丢弃，避免刚结束又立刻起一击（已移除连招派生链）
			if _timer >= recovery:
				request_transition(&"idle")

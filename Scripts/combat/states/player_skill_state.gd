class_name PlayerSkillState
extends State
## ============================================================
## PlayerSkillState — 技能释放状态（06_FIGHT.md 蓝图 2.3）
##
## 生命周期三段式（全部时长读 config 的 combat.skills.<id>）：
##   WINDUP   前摇：定身、朝鼠标；可被 HitStun 打断（打断不退资源）
##   ACTIVE   生效：按技能类型不同（AOE 一次性 / DASH 逐帧 / BUFF 一次性）
##   RECOVERY 后摇：定身，结束后回 Idle
##
## 状态只决定"什么时候生效"，效果本身调用 player.gd 功能层的接口，
## 保持"行为决策层 与 功能组件层"解耦。
## ============================================================

enum Phase { WINDUP, ACTIVE, RECOVERY }

var _phase: int = Phase.WINDUP
var _timer := 0.0
var _skill: Skill = null
var _dash_hits: Dictionary = {}   # 突进沿途已命中的目标（去重）


func _init(p_actor: Node = null) -> void:
	super(&"skill", p_actor)


func enter(msg: Dictionary = {}) -> void:
	actor.stop_moving()
	actor.aim_at_mouse()
	_skill = actor.skill_system.get_skill(msg.get("skill_id", &""))
	_phase = Phase.WINDUP
	_timer = 0.0
	_dash_hits.clear()
	if _skill == null:
		push_warning("[Skill] 进入技能状态但没拿到有效技能，退回 Idle")
		request_transition(&"idle")


func exit() -> void:
	actor.velocity = Vector2.ZERO
	actor.move_and_slide()


func physics_update(delta: float) -> void:
	if _skill == null:
		request_transition(&"idle")
		return
	_timer += delta
	match _phase:
		Phase.WINDUP:
			actor.velocity = Vector2.ZERO
			actor.move_and_slide()
			if _timer >= _skill.num("windup_seconds", 0.1):
				_phase = Phase.ACTIVE
				_timer = 0.0
				_on_cast_begin()
		Phase.ACTIVE:
			_update_active()
			if _timer >= _skill.num("active_seconds", 0.2):
				_phase = Phase.RECOVERY
				_timer = 0.0
		Phase.RECOVERY:
			actor.velocity = Vector2.ZERO
			actor.move_and_slide()
			if _timer >= _skill.num("recovery_seconds", 0.2):
				request_transition(&"idle")


## 进入 Cast 阶段：一次性效果在这里结算，并打印日志便于编辑器验证
func _on_cast_begin() -> void:
	match _skill.type():
		Skill.Type.AOE_SELF:
			var radius := _skill.num("radius_px", 60.0)
			actor.skill_aoe_hit(radius, _skill.int_value("damage", 20),
					_skill.num("knockback_speed", 180.0))
			actor.spawn_impact_ring(radius, Color(0.87, 0.74, 0.36, 0.9))
		Skill.Type.BUFF:
			actor.apply_guard(_skill.num("damage_reduction", 0.5),
					_skill.num("buff_duration_seconds", 2.5))
		Skill.Type.DASH:
			pass    # 突进位移在 ACTIVE 期间逐帧推进
	print("[Skill] 生效：%s" % _skill.display_name())


## ACTIVE 期间每帧：只有 DASH 类型需要持续推进
func _update_active() -> void:
	if _skill.type() == Skill.Type.DASH:
		actor.velocity = actor.facing * _skill.num("dash_speed", 800.0)
		actor.move_and_slide()
		actor.skill_dash_hit(_skill.num("hit_radius_px", 24.0),
				_skill.int_value("damage", 20), _dash_hits)
	else:
		actor.velocity = Vector2.ZERO
		actor.move_and_slide()

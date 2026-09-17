class_name PlayerDodgeState
extends State
## ============================================================
## PlayerDodgeState — 冲刺 / 闪避（含无敌帧 i-frames）
## 对应 DESIGN.md 手感清单第 1 项"冲刺短暂无敌"。
## 进入：朝鼠标方向冲刺（速度 × combat.dodge.speed_multiplier），期间无敌。
## 退出：关闭无敌 + 进入冷却（combat.dodge.cooldown_seconds）。
## 硬直/攻击期间不可冲刺（由 Player.can_dodge 判定）。
## ============================================================

var _timer := 0.0
var _dir := Vector2.ZERO


func _init(p_actor: Node = null) -> void:
	super(&"dodge", p_actor)


func enter(_msg: Dictionary = {}) -> void:
	actor.stop_moving()
	actor.aim_at_mouse()
	_dir = actor.facing
	_timer = 0.0
	if bool(Config.get_value("combat.dodge.invincible", true)):
		actor.set_invincible(true)
	# 冲刺发声：比走路更响（DESIGN.md 第二部分 噪音机制）
	# from_player=true → 计入菜单栏「当前/累积噪音」读数
	NoiseSystem.emit(actor.global_position,
			float(Config.get_value("noise.sources.dodge", 28.0)), true)


func exit() -> void:
	actor.set_invincible(false)
	actor.start_dodge_cooldown()


func physics_update(delta: float) -> void:
	var duration := float(Config.get_value("combat.dodge.duration_seconds", 0.22))
	var multiplier := float(Config.get_value("combat.dodge.speed_multiplier", 3.0))
	_timer += delta
	actor.velocity = _dir * actor.speed * multiplier
	actor.move_and_slide()
	if _timer >= duration:
		request_transition(&"idle")

extends Node
## ============================================================
## probe_auto_combat — 「观察视野 / 攻击距离」双属性 + 自动战斗验证（headless 可跑）
##
## 验五件事：
##   A) 两个属性算得对：观察视野 = vision_radius_cells × 格宽；
##      攻击距离按武器分型取（近战 range_px / 远程弹道 max_distance_px）；
##      有效攻击距离 = min(攻击距离, 观察视野)；近战判定框半径 = 有效距离。
##   B) 视野外（700px > 视野 640px）的敌人不锁定、不攻击。
##   C) 视野内但够不着（300px > 剑的 120px）不锁定、**不追击**（原地不动）。
##   D) 进入攻击距离（90px）自动锁定 → 自动进 attack 状态 → 真的打出伤害。
##   E) 弹射程临时顶到 900px 也比视野远：有效射程截断到 640px，
##      视野外的目标不再被锁定，箭身上带的射程就是截断后的那个数。
##
## 为什么 headless 能跑：判定全是纯数据（位置距离 + 节点组），不依赖渲染。
## ============================================================

const OUT := "user://_probe_auto_combat.txt"

## 假敌人：带 take_damage / is_dead，加入 enemies 组，供自动索敌与结算使用。
## 根节点必须是 **Area2D 本身**（不是 Node2D 挂子 Area2D）—— 真实 Enemy.tscn 就是
## Area2D 根节点，近战判定 hitbox.get_overlapping_areas() 返回的是"这个节点"，
## 而 _is_damageable() 检查的也是**该节点**是否在 enemies 组；子节点 Area2D 不在组里，
## 会表现为"进得了 attack 状态但永远打不出伤害"（实测踩过）。
class FakeTarget extends Area2D:
	var hp := 100.0
	func _init() -> void:
		var shape := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = 12.0
		shape.shape = circle
		add_child(shape)
	func take_damage(amount: int) -> void:
		hp -= float(amount)
	func is_dead() -> bool:
		return hp <= 0.0


var _lines: Array = []
var _n := 0
var _fails: Array = []


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _ready() -> void:
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	main._on_launch([{"id": "swordsman", "name": "剑士"}])   # 剑：攻击距离 120px
	await _frames(40)

	var players := get_tree().get_nodes_in_group("player")
	_check(players.size() >= 1, "进局后找到玩家（共 %d 名）" % players.size())
	if players.is_empty():
		_finish()
		return
	var p: Node = players[0]

	_say("--- A 段：观察视野 / 攻击距离 / 有效射程 ---")
	var vision: float = p.vision_px()
	var rng: float = p.attack_range_px()
	var eff: float = p.effective_attack_range_px()
	_check(is_equal_approx(vision, 640.0), "观察视野 = 10 格 × 64 = 640px（实得 %.0f）" % vision)
	_check(is_equal_approx(rng, 120.0), "剑士攻击距离 = 120px（实得 %.0f）" % rng)
	_check(is_equal_approx(eff, 120.0), "有效攻击距离 = min(120, 640) = 120px（实得 %.0f）" % eff)
	var radius: float = -1.0
	if p.hitbox != null:
		var shape = p.hitbox.get_node("CollisionShape2D").shape
		if shape != null:
			radius = float(shape.radius)
	_check(is_equal_approx(radius, 120.0), "近战判定框半径 = 有效攻击距离 120（实得 %.0f）" % radius)

	# 假敌人挂到玩家的父节点（与真实敌人同层）
	var parent := p.get_parent()
	var t := FakeTarget.new()
	t.name = "FakeTarget"
	parent.add_child(t)
	t.add_to_group(&"enemies")

	_say("--- B 段：视野外（700px）不锁定 ---")
	t.global_position = p.global_position + Vector2(700.0, 0.0)
	await _frames(20)
	_check(p.auto_target() == null, "700px（> 视野 640px）的敌人不被锁定")

	_say("--- C 段：视野内但够不着（300px）不锁定、不追击 ---")
	var pos_before: Vector2 = p.global_position
	t.global_position = p.global_position + Vector2(300.0, 0.0)
	await _frames(20)
	_check(p.auto_target() == null, "300px（视野内但 > 攻击距离 120px）不锁定")
	_check(p.global_position.distance_to(pos_before) < 8.0,
			"够不着时原地不动、不自动追击（位移 %.1fpx）"
			% p.global_position.distance_to(pos_before))
	var st: StringName = p.state_machine.get_state_name()
	_check(st != &"attack", "够不着时不起手（当前状态 = %s）" % str(st))

	_say("--- D 段：进入攻击距离（90px）自动开打 ---")
	t.global_position = p.global_position + Vector2(90.0, 0.0)
	await _frames(20)
	_check(p.auto_target() != null, "90px（< 攻击距离 120px）锁定目标")
	var saw_attack := false
	for _i in range(40):
		if p.state_machine.get_state_name() == &"attack":
			saw_attack = true
			break
		await get_tree().process_frame
	_check(saw_attack, "自动进入 attack 状态（无需任何输入，最终状态 = %s）"
			% str(p.state_machine.get_state_name()))
	await _frames(60)
	_check(t.hp < 100.0, "自动攻击真的打出伤害（目标 hp = %.0f/100）" % t.hp)

	_say("--- E 段：武器射程超出视野时被截断 ---")
	p.switch_weapon(&"bow")
	await _frames(5)
	# 弹射程临时顶到 900（> 视野 640）：模拟"武器比眼睛远"的那种配置
	Config.set_override("combat.weapons.bow.projectile.max_distance_px", 900.0)
	var rng2: float = p.attack_range_px()
	var eff2: float = p.effective_attack_range_px()
	_check(is_equal_approx(rng2, 900.0), "弓表上弹射程 = 900px（实得 %.0f）" % rng2)
	_check(is_equal_approx(eff2, 640.0), "有效射程被观察视野截断到 640px（实得 %.0f）" % eff2)
	p.set("facing", Vector2.RIGHT)
	t.global_position = p.global_position + Vector2(800.0, 0.0)
	await _frames(15)   # 索敌是节流的（scan_interval_seconds），等它把旧锁定刷掉
	_check(p.auto_target() == null, "800px 的目标在视野外：自动索敌不选它")
	# 箭自己飞多远 = 截断后的那个数，所以"配置上打得着、画面上看不见"不会发生
	_check(bool(p.fire_projectile()), "fire_projectile 发射成功")
	var arrow: Node = p.get_parent().get_node_or_null("Projectile")
	_check(arrow != null, "父层找到 Projectile 节点")
	if arrow != null:
		_check(is_equal_approx(float(arrow.get("max_distance")), eff2),
				"箭的射程 = 有效攻击距离 %.0f（实得 %.0f）"
				% [eff2, float(arrow.get("max_distance"))])
		arrow.free()
	Config.clear_override("combat.weapons.bow.projectile.max_distance_px")

	_finish()


func _finish() -> void:
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_auto_combat] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

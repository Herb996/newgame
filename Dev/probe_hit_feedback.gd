extends Node
## ============================================================
## probe_hit_feedback — 「受击手感三件套」的验证探针（headless 可跑）
##
## 验四件事：
##   A) config 结构：hit_stop 两档 / dodge_cancel_* / hit_direction_* 键齐且取值合理
##      （项目铁律：数值只住 config，代码里全是回落默认值 —— 键漏了不会报错，只会
##       静悄悄用默认，所以这里必须逐个点名）
##   B) HitStop：pulse 真的把 Engine.time_scale 压下去、窗口过后自动弹回、
##      冷却内第二发不叠加、enabled=false / seconds=0 时完全不碰全局时间
##   C) 受击方向指示：真实局内有这一层；玩家挨一发 → 收到一条上报；
##      没有攻击者坐标就不该报；同屏条数封顶；到 fade 时长后自己清空
##   D) 冲刺取消硬直：提前量满了之后 dodge 吃掉硬直；关开关则只能熬完整段
##
## D 段开头把 hit_stop 关掉：微冻会让物理帧节拍变慢，按帧数算的等待会失真，
## 两件事分开验才判得准（不是"顺便"一起开着的）。
## 红楔画出来长什么样无头看不出来 → 另用 debug.force_player_hit 开窗口截图。
## ============================================================

const OUT := "user://_probe_hit_feedback.txt"

var _lines: Array = []
var _fails: Array = []
var _n := 0
var _player: Node = null


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _ready() -> void:
	_section_a()
	await _section_b()
	await _enter_run()
	await _section_c()
	await _section_d()
	HitStop.reset()
	Config.clear_overrides()
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[HitFbProbe] 通过 %d / %d" % [_n - _fails.size(), _n])
	print("[HitFbProbe] fails=%d -> %s" % [_fails.size(), "PASS" if _fails.is_empty() else "FAIL"])
	get_tree().quit(0 if _fails.is_empty() else 1)


# ------------------------------------------------------------
func _section_a() -> void:
	_say("--- A 段：config 结构 ---")
	var hs: Dictionary = Config.get_value("combat.hit_stop", {})
	_check(not hs.is_empty(), "存在 combat.hit_stop 段")
	_check(bool(hs.get("enabled", false)), "hit_stop.enabled 默认开着")
	var cd := float(hs.get("cooldown_seconds", 0.0))
	_check(cd > 0.0, "cooldown_seconds>0（连发不逐发叠加，实得 %.3f）" % cd)
	for kind in ["on_deal_damage", "on_receive_damage"]:
		var one: Dictionary = hs.get(kind, {})
		var sec := float(one.get("seconds", 0.0))
		var ts := float(one.get("time_scale", 0.0))
		_check(sec > 0.0 and sec < 0.2, "%s.seconds 在 (0, 0.2) 内（实得 %.3f）" % [kind, sec])
		_check(ts > 0.0 and ts < 1.0, "%s.time_scale 在 (0, 1) 内（实得 %.3f）" % [kind, ts])
	_check(float(hs.get("on_receive_damage", {}).get("seconds", 0.0)) \
			>= float(hs.get("on_deal_damage", {}).get("seconds", 0.0)),
			"挨打停得 ≥ 打人（『我被打中』要更贵）")

	var p: Dictionary = Config.get_value("combat.player", {})
	for k in ["dodge_cancel_enabled", "dodge_cancel_after_seconds", "hit_direction_enabled",
			"hit_direction_radius_px", "hit_direction_band_px", "hit_direction_arc_degrees",
			"hit_direction_fade_seconds", "hit_direction_peak_alpha", "hit_direction_color",
			"hit_direction_max_marks", "hit_direction_segments"]:
		_check(p.has(k), "combat.player 有 %s" % k)
	var after := float(p.get("dodge_cancel_after_seconds", -1.0))
	var stun := float(p.get("hitstun_seconds", 0.0))
	_check(after > 0.0 and after < stun,
			"取消提前量在 (0, hitstun_seconds=%.3f) 内（实得 %.3f）" % [stun, after])
	var peak := float(p.get("hit_direction_peak_alpha", 0.0))
	_check(peak > 0.0 and peak <= 1.0, "峰值 alpha 在 (0,1]（实得 %.2f）" % peak)
	var col := str(p.get("hit_direction_color", ""))
	_check(col.is_valid_html_color(), "hit_direction_color 是合法 #rrggbb（实得 %s）" % col)
	_check(float(p.get("hit_direction_radius_px", 0.0)) > float(p.get("hit_direction_band_px", 0.0)),
			"半径 > 环带厚度（否则楔会退化到屏幕中心一块）")


# ------------------------------------------------------------
## 真实秒等待：冻结期间 Engine.time_scale ≠1，普通 await 会被自己拖慢。
func _wait_real(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout


func _section_b() -> void:
	_say("")
	_say("--- B 段：HitStop 冻结 / 弹回 / 不叠加 ---")
	HitStop.reset()
	_check(is_equal_approx(Engine.time_scale, 1.0), "reset 后 Engine.time_scale = 1")
	HitStop.pulse(get_tree(), "on_deal_damage")
	var frozen := Engine.time_scale
	_check(frozen < 1.0, "pulse 后时间被压慢（实得 %.3f）" % frozen)
	_check(is_equal_approx(frozen,
			float(Config.get_value("combat.hit_stop.on_deal_damage.time_scale", 0.0))),
			"压到的倍率就是 config 里的 time_scale")
	HitStop.pulse(get_tree(), "on_receive_damage")
	_check(is_equal_approx(Engine.time_scale, frozen), "冷却内第二发不改变冻结强度（不叠加）")
	await _wait_real(0.5)
	_check(is_equal_approx(Engine.time_scale, 1.0),
			"窗口过后自动弹回 1（实得 %.3f）" % Engine.time_scale)

	Config.set_override("combat.hit_stop.enabled", false)
	HitStop.pulse(get_tree(), "on_deal_damage")
	_check(is_equal_approx(Engine.time_scale, 1.0), "enabled=false 时完全不碰全局时间")
	Config.clear_override("combat.hit_stop.enabled")

	Config.set_override("combat.hit_stop.on_deal_damage", {"seconds": 0.0, "time_scale": 0.5})
	HitStop.pulse(get_tree(), "on_deal_damage")
	_check(is_equal_approx(Engine.time_scale, 1.0), "seconds=0 视作关掉这一档，不动时间")
	Config.clear_override("combat.hit_stop.on_deal_damage")
	HitStop.reset()


# ------------------------------------------------------------
func _enter_run() -> void:
	_say("")
	_say("--- 进真实局（Main.tscn）---")
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	for _i in range(150):
		await get_tree().process_frame
	_player = get_tree().get_first_node_in_group("player")
	_check(_player != null, "场景里有 group=player 的角色")


func _indicator() -> Node:
	return get_tree().get_first_node_in_group("hit_direction_indicator")


## 让角色回到"能挨打"的状态：满血、无敌帧与冲刺冷却清零、输入缓冲清空。
## 必须先等回中立态：上一段测试可能把角色留在 dodge，而 dodge 期间
## _dodge_invincible=true → take_damage 直接被吞，断言会"因为没挨打"而假通过。
func _arm_for_hit() -> void:
	for _i in range(300):
		var s := _state_of()
		if s == "idle" or s == "move":
			break
		await get_tree().physics_frame
	_player.set_invincible(false)
	_player.hp = int(_player.max_hp)
	_player._invincible_timer = 0.0
	_player._dodge_cooldown = 0.0
	_player._input_buffer.clear()


func _state_of() -> String:
	return "" if _player == null else str(_player.state_machine.get_state_name())


# ------------------------------------------------------------
func _section_c() -> void:
	_say("")
	_say("--- C 段：受击方向指示 ---")
	if _player == null:
		_say("   [跳过] 没拿到玩家")
		return
	var ind := _indicator()
	_check(ind != null, "HUD 下挂着 HitDirectionIndicator（组 hit_direction_indicator）")
	if ind == null:
		return
	_check(bool(ind.visible), "指示层默认可见")
	_check(str(ind.get_parent().name) == "HUD", "指示层挂在 HUD 下（回基地随 HUD 一起收）")
	_check(ind.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"指示层不吃鼠标（否则局内点不了地）")

	# 真路径：挨一发 → take_damage 自己上报
	# 顺序要紧：先等回中立态（里面在过帧），再清空、再当场补一发 ——
	# 清空和断言之间不能夹帧，否则敌人路过蹭一下就把计数弄脏了。
	await _arm_for_hit()
	ind._marks.clear()
	var landed := bool(_player.take_damage(5, _player.global_position + Vector2(200.0, 0.0)))
	_check(landed, "这一发确实吃到了（否则下面的上报断言是空的）")
	_check(int(ind._marks.size()) == 1, "take_damage 上报了一条（实得 %d）" % ind._marks.size())

	# 无来源：既没方向可画，也不该占一条
	await _arm_for_hit()
	ind._marks.clear()
	var landed_nosrc := bool(_player.take_damage(5, Vector2.ZERO))
	_check(landed_nosrc, "没有攻击者坐标也照样掉血（只是没方向可报）")
	_check(int(ind._marks.size()) == 0, "攻击者坐标 = ZERO 时不报方向（实得 %d）" % ind._marks.size())
	ind.report_hit(_player.global_position, _player.global_position)
	_check(int(ind._marks.size()) == 0, "攻击者与自身重合（算不出方向）时也不报")

	# 上限：max_marks 条封顶，挤掉最老的
	var cap := int(Config.get_value("combat.player.hit_direction_max_marks", 4))
	for i in range(cap + 3):
		ind.report_hit(_player.global_position, _player.global_position + Vector2(0.0, float(30 + i * 40)))
	_check(int(ind._marks.size()) == cap, "同屏条数封顶 max_marks=%d（实得 %d）" % [
		cap, ind._marks.size()])

	# 淡出：等过 fade 时长自己清空。这一等是一秒多，真实局里敌人足够蹭一下
	# → 把无敌帧钉住（take_damage 会直接拒绝，连上报都不会有），只留淡出这一件事。
	var fade := float(Config.get_value("combat.player.hit_direction_fade_seconds", 0.7))
	_player._invincible_timer = 999.0
	await _wait_real(fade + 0.35)
	_player._invincible_timer = 0.0
	_check(bool(ind._marks.is_empty()), "到 fade_seconds=%.3f 后全部淡掉（实剩 %d）" % [
		fade, ind._marks.size()])

	# 总开关关掉：新建一层不该可见、也不收上报
	Config.set_override("combat.player.hit_direction_enabled", false)
	var fresh: Control = load("res://Scripts/hit_direction_indicator.gd").new()
	add_child(fresh)
	await get_tree().process_frame
	fresh.report_hit(_player.global_position, _player.global_position + Vector2(120.0, 0.0))
	_check(bool(fresh._marks.is_empty()) and not bool(fresh.visible),
			"hit_direction_enabled=false → 不可见也不收上报")
	fresh.queue_free()
	Config.clear_override("combat.player.hit_direction_enabled")


# ------------------------------------------------------------
func _section_d() -> void:
	_say("")
	_say("--- D 段：冲刺取消硬直 ---")
	if _player == null:
		_say("   [跳过] 没拿到玩家")
		return
	# 本段只验取消硬直：微冻会拖慢物理帧节拍，等帧数的判断会失真 → 先关掉
	HitStop.reset()
	Config.set_override("combat.hit_stop.enabled", false)
	var cancel_after := float(Config.get_value("combat.player.dodge_cancel_after_seconds", 0.08))
	var stun := float(Config.get_value("combat.player.hitstun_seconds", 0.25))

	# 1) 开着：提前量之内不认，满了之后取消
	await _arm_for_hit()
	var landed_d := bool(_player.take_damage(5, _player.global_position + Vector2(100.0, 0.0)))
	_check(landed_d, "D 段这一发确实吃到了")
	_check(_state_of() == "hitstun", "挨一发后进硬直（实得 %s）" % _state_of())
	if _state_of() != "hitstun":
		_say("   [跳过] 没进硬直，后面的取消判定无从测起")
		Config.clear_override("combat.hit_stop.enabled")
		Config.clear_override("combat.player.dodge_cancel_enabled")
		return
	var stun_state = _player.state_machine.current_state
	# 取消发生的那一帧 _timer 就冻在 stun_state 上了（换状态后不再累加），
	# 所以拿它跟 cancel_after 比才是"早不早"的判据；只看状态名会把
	# 「刚好在够钟那一帧取消」误判成提前。
	var too_early := false
	var guard := 0
	while guard < 400 and _state_of() == "hitstun" and float(stun_state._timer) < cancel_after:
		_player.push_input(&"dodge")
		await get_tree().physics_frame
		guard += 1
		if _state_of() == "dodge" and float(stun_state._timer) < cancel_after:
			too_early = true
	_check(not too_early, "提前量 %.2fs 之内不认取消（取消时 _timer=%.3f）" % [
		cancel_after, float(stun_state._timer)])

	# 取消也可能就在上面那个循环的最后一帧里发生的，所以初值先看现状
	var cancelled := _state_of() == "dodge"
	guard = 0
	while not cancelled and guard < 400 and _state_of() == "hitstun":
		_player.push_input(&"dodge")
		await get_tree().physics_frame
		guard += 1
		if _state_of() == "dodge":
			cancelled = true
	_check(cancelled, "提前量满了后，缓冲里的冲刺把硬直取消（实得 %s）" % _state_of())
	_check(float(stun_state._timer) < stun,
			"取消确实早于硬直走完（_timer=%.3f < %.3f）" % [float(stun_state._timer), stun])

	# 2) 关掉开关：同一发只能熬完整段硬直，中途绝不进 dodge
	Config.set_override("combat.player.dodge_cancel_enabled", false)
	await _arm_for_hit()
	var landed_off := bool(_player.take_damage(5, _player.global_position + Vector2(100.0, 0.0)))
	_check(landed_off, "关掉开关后这一发照样吃到")
	_check(_state_of() == "hitstun", "关开关后照样进硬直（实得 %s）" % _state_of())
	var stun_off = _player.state_machine.current_state
	var dodged := false
	guard = 0
	while guard < 400 and _state_of() == "hitstun":
		_player.push_input(&"dodge")
		await get_tree().physics_frame
		guard += 1
		if _state_of() == "dodge":
			dodged = true
			break
	_check(not dodged, "dodge_cancel_enabled=false 时硬直期间绝不进 dodge（老行为）")
	_check(_state_of() != "hitstun", "硬直最终自己走完（实得 %s）" % _state_of())
	Config.clear_override("combat.player.dodge_cancel_enabled")
	Config.clear_override("combat.hit_stop.enabled")
	_say("   （收尾状态 %s，关开关那一段硬直走满 %.3fs）" % [_state_of(), float(stun_off._timer)])

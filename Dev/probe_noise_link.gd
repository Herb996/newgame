extends Node
## ============================================================
## probe_noise_link — 两路噪音的耦合 + 等级淡光跟着自身噪音提速（2026-09-18）
##
## 用户定的规则，逐条翻译成不变量：
##   ① 「第一个是角色自身噪音，第二个是世界累计噪音」
##      → 自身噪音**每人一份**（player.self_noise），菜单第 1 行取全队最大值（B 段）
##   ② 「自身噪音会累加世界噪音」        → 每帧按比例灌给 world，**不从自身扣**（D 段）
##   ③ 「世界噪音增加，自身噪音加得更快」→ 新发声按 self_gain_from_world 放大（E 段）
##   ④ 「两个都会慢慢降下去，自身快，世界慢」→ 线性 vs 比例衰减的速率差（C 段）
##   ⑤ 「光球根据第一个来，噪音越大移动和闪烁越快」→ 时间轴倍速（G/H 段）
##
## ⚠ ②+③ 是**正反馈**（互相喂养），靠两边各自的 hard cap 兜住。F 段用长时间数值
##   曝打守这条：不允许 NaN / Inf、不允许越过 max。调 link.world_to_self_gain 之前
##   请先跑这一关 —— 放心结构上不会发散，但会让「吵起来就再也压不下去」。
##
## ⚠ NoiseSystem 全程**手动步进**（先 set_process(false) + 光球也 set_process(false)）：
##   headless 真实帧率不确定，自动跑验不了「1 秒衰减 90 点」这种时间语义。
## ⚠ 走了一次 `_on_launch`（需要名册）→ 会写存档，所以开跑备份 `user://save.json`、
##   收尾原样还原。
## ============================================================

const OUT := "user://_probe_noise_link.txt"
const SAVE_PATH := "user://save.json"
const DT := 0.05

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _main: Node = null
var _players: Array = []
var _badge: Node = null
var _save_backup := ""
var _save_existed := false


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


## 手动步进 NoiseSystem（已关掉它的自动 _process）
func _tick(steps: int, dt := DT) -> void:
	for _i in range(steps):
		NoiseSystem.call("_process", dt)


## 把两路噪音都按到 0（world / 每个角色 / 没归属那份）
func _silence() -> void:
	NoiseSystem.reset()
	for p in _players:
		p.set("self_noise", 0.0)
	NoiseSystem.world_noise = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	_main = main
	await _frames(30)

	# 进局（要两个人——「自身噪音是每人一份」这条得有对照才能验）
	var uids: Array = []
	Meta.ensure_roster()
	for u in Meta.roster:
		var ui: int = int(u.get("uid", 0))
		if ui > 0:
			uids.append(ui)
			if uids.size() >= 2:
				break
	var units: Array = []
	for i in range(uids.size()):
		units.append({"id": "spearman", "name": "枪手%d" % i,
				"uid": int(uids[i]), "level": 0})
	_main.call("_on_launch", units)
	await _frames(40)
	# ⚠ **必须 await**：这个函数内部有 await，不 await 调用的话它的后半段
	# （含 await 之后的 `_badge = ...`）会被整个丢弃、永不恢复 ——
	# 症状就是「明明进了局、后面却到处是 null」，而且不报任何错。
	await _collect_players()

	await _a_config()
	await _b_per_unit()
	await _c_decay_rates()
	await _d_self_feeds_world()
	await _e_world_feeds_self()
	await _f_bounded()
	await _g_badge_speed()
	await _h_no_reverse()
	await _i_menu_readout()
	await _j_reset()
	await _k_wiring()
	_finish()


func _collect_players() -> void:
	_players = get_tree().get_nodes_in_group("player")
	for p in _players:
		p.set("auto_attack_on", false)
		if p.has_method("cancel_commands"):
			p.call("cancel_commands")
	await _frames(3)
	NoiseSystem.set_process(false)      # 之后全程手动步进，读数才可预测
	if not _players.is_empty():
		var kids: Array = []
		for c in (_players[0] as Node).get_children():
			kids.append((c as Node).name)
		_say("  [diag] 0 号角色 %s 的子节点：%s"
				% [str((_players[0] as Node).name), str(kids)])
		_badge = (_players[0] as Node).get_node_or_null("LevelBadge")
		if _badge != null:
			_badge.set_process(false)
			_badge.set("noise_override", -1.0)


# ------------------------------------------------------------
# A 段：config 真值 + 两条速率的确有关系（自身快 / 世界慢）
# ------------------------------------------------------------
func _a_config() -> void:
	_say("--- A 段：两路噪音的配置真值 ---")
	var sdec := float(Config.get_value("noise.self.decay_per_second", 0.0))
	var smax := float(Config.get_value("noise.self.max", 0.0))
	_check(sdec > 0.0 and smax > 0.0,
			"自身噪音：每秒衰减 %.0f 点、上限 %.0f" % [sdec, smax])
	var wr := float(Config.get_value("noise.world.decay_ratio_per_second", 0.0))
	var wref := float(Config.get_value("noise.world.reference", 0.0))
	var wmax := float(Config.get_value("noise.world.max", 0.0))
	_check(wr > 0.0 and wref > 0.0 and wmax >= wref,
			"世界噪音：每秒掉自身 %.0f%%、参考 %.0f、上限 %.0f" % [wr * 100.0, wref, wmax])
	var transfer := float(Config.get_value("noise.link.self_to_world_per_second", -1.0))
	var gain := float(Config.get_value("noise.link.world_to_self_gain", -1.0))
	_check(transfer > 0.0, "自身满格时每秒喂给世界 %.0f 点（link 存在）" % transfer)
	_check(gain > 0.0, "世界到参考值时自身额外 +%.0f%% 增幅（link 存在）" % (gain * 100.0))
	# 「自身快、世界慢」必须体现在配置层面，不只是实现里 —— 这条断言让改数值的人当场看到
	var self_zero := smax / sdec                 # 自身从满格归零的秒数
	var world_half := log(2.0) / maxf(wr, 1e-6)  # 世界掉一半的秒数
	_check(self_zero < world_half,
			"自身确实比世界降得快：满格归零 %.1fs < 世界半衰 %.1fs（差 %.1f 倍）"
			% [self_zero, world_half, world_half / maxf(self_zero, 1e-6)])
	# 旧字段（一眼看上去很像的兄弟）必须已经清掉，否则改了半天改错地方
	_check(Config.get_value("noise.display.decay_per_second", null) == null,
			"旧的 noise.display.decay_per_second 已移除（现已归属 noise.self）")
	_check(Config.get_value("noise.display.accumulated_reference", null) == null,
			"旧的 noise.display.accumulated_reference 已移除（现已归属 noise.world）")


# ------------------------------------------------------------
# B 段：自身噪音是**每人一份**，菜单第 1 行取全队最大值
# ------------------------------------------------------------
func _b_per_unit() -> void:
	_say("--- B 段：自身噪音挂在角色身上（不是全队共享一个数）---")
	_check(_players.size() >= 1, "局内有角色（%d 名）" % _players.size())
	if _players.is_empty():
		return
	_silence()
	var a = _players[0]
	a.set("self_noise", 0.0)
	NoiseSystem.emit(a.global_position, 120.0, true, a)
	_check(absf(float(a.get("self_noise")) - 120.0) < 0.01,
			"发声记到**这个角色**头上（120，实得 %.1f）" % float(a.get("self_noise")))
	_check(is_equal_approx(NoiseSystem.team_self_noise(), 120.0),
			"全队读数 = 最大值（实得 %.1f）" % NoiseSystem.team_self_noise())
	if _players.size() >= 2:
		var b = _players[1]
		b.set("self_noise", 0.0)
		_check(is_equal_approx(float(b.get("self_noise")), 0.0),
				"同伴没跟着涨 —— 各自各的一份（%.1f）" % float(b.get("self_noise")))
		NoiseSystem.emit(b.global_position, 40.0, true, b)
		_check(absf(float(a.get("self_noise")) - 120.0) < 0.01
				and absf(float(b.get("self_noise")) - 40.0) < 0.01,
				"同伴发声后两人的数互不影响（%.1f / %.1f）"
				% [float(a.get("self_noise")), float(b.get("self_noise"))])
		_check(is_equal_approx(NoiseSystem.team_self_noise(), 120.0),
				"读数取的是最大的那个（120，不是 40 也不是 160）")
	# 上限是硬约束：超大声也不会把自身顶穿
	_silence()
	var lim := float(Config.get_value("noise.self.max", 300.0))
	a.set("self_noise", 0.0)
	NoiseSystem.emit(a.global_position, 9999.0, true, a)
	_check(absf(float(a.get("self_noise")) - lim) < 0.01,
			"自身噪音有硬上限 %.0f（灌 9999 也只到 %.1f）" % [lim, float(a.get("self_noise"))])
	_silence()


# ------------------------------------------------------------
# C 段：衰减速率 —— 自身快、世界慢
# ------------------------------------------------------------
func _c_decay_rates() -> void:
	_say("--- C 段：两个都在降，但自身明显更快 ---")
	_silence()
	if _players.is_empty():
		return
	var a = _players[0]
	# 自身：把它按到 100，看 1 秒后剩多少（线性衰减，理论剩 10）
	a.set("self_noise", 100.0)
	NoiseSystem.world_noise = 0.0
	_tick(20)          # 20 × 0.05 = 1 秒
	var left := float(a.get("self_noise"))
	_check(left < 20.0, "自身噪音 1 秒从 100 掉到 %.1f（几乎没了）" % left)
	_check(left >= 0.0, "自身噪音不会变负（%.1f）" % left)
	# 世界：把人都清干净，单独看它的衰减
	_silence()
	NoiseSystem.world_noise = 100.0
	_tick(20)
	var wleft := NoiseSystem.world_noise
	_check(wleft > 80.0 and wleft < 100.0,
			"世界噪音 1 秒只掉了一点点（100 → %.1f）" % wleft)
	_check(wleft < 100.0, "世界噪音确实在衰减（不是不动）")
	# 量级对比：同样 1 秒，自身掉了 90%，世界掉不到 10%
	_check((1.0 - left / 100.0) > (1.0 - wleft / 100.0) * 5.0,
			"自身降速 > 世界降速 × 5（%.0f%% vs %.1f%%）"
			% [(1.0 - left / 100.0) * 100.0, (1.0 - wleft / 100.0) * 100.0])
	_silence()


# ------------------------------------------------------------
# D 段：自身 → 世界（累加，且**不从自身扣**）
# ------------------------------------------------------------
func _d_self_feeds_world() -> void:
	_say("--- D 段：自身噪音喂高世界噪音 ---")
	_silence()
	if _players.is_empty():
		return
	var a = _players[0]
	var smax := float(Config.get_value("noise.self.max", 300.0))
	var per_sec := float(Config.get_value("noise.link.self_to_world_per_second", 360.0))
	a.set("self_noise", smax)
	var before := float(a.get("self_noise"))
	_tick(20)          # 1 秒
	var after := float(a.get("self_noise"))
	_check(NoiseSystem.world_noise > per_sec * 0.7,
			"自身满格 1 秒 → 世界涨到 %.1f（约 %0.f/秒）"
			% [NoiseSystem.world_noise, per_sec])
	_check(after < before,
			"自身同时按自己的速率衰减（%.1f → %.1f）—— 喂世界是累加，不是转账" % [before, after])
	_check(after > before - smax, "还没被扣到负（%.1f）" % after)
	# 安静时世界不涨
	_silence()
	NoiseSystem.world_noise = 500.0
	_tick(20)
	_check(NoiseSystem.world_noise < 500.0,
			"全员安静时世界不涨反降（500 → %.1f）" % NoiseSystem.world_noise)
	_silence()


# ------------------------------------------------------------
# E 段：世界 → 自身（同样的动作，世界越吵涨得越多）
# ------------------------------------------------------------
func _e_world_feeds_self() -> void:
	_say("--- E 段：世界噪音抬高时，同样的发声自身涨得更多 ---")
	_silence()
	if _players.is_empty():
		return
	var a = _players[0]
	var wref := float(Config.get_value("noise.world.reference", 2000.0))
	var gain := float(Config.get_value("noise.link.world_to_self_gain", 1.2))

	a.set("self_noise", 0.0)
	NoiseSystem.world_noise = 0.0
	NoiseSystem.emit(a.global_position, 100.0, true, a)
	var quiet := float(a.get("self_noise"))
	_check(absf(quiet - 100.0) < 0.01, "世界安静时，发声 100 → 自身 %.1f" % quiet)

	_silence()
	NoiseSystem.world_noise = wref
	a.set("self_noise", 0.0)
	NoiseSystem.emit(a.global_position, 100.0, true, a)
	var loud := float(a.get("self_noise"))
	var want := 100.0 * (1.0 + gain)
	_check(absf(loud - want) < 0.5,
			"世界到参考值 %.0f 时，同一声成了 %.1f（应为 %.1f）" % [wref, loud, want])
	_check(loud > quiet * 1.5, "差距够明显（%.1f vs %.1f）—— 这就是「越吵越难压」" % [loud, quiet])

	# 超过参考值也不再加成（ clamp 到 1.0 的那一段是拷贝值的行为边界）
	_silence()
	NoiseSystem.world_noise = float(Config.get_value("noise.world.max", 4000.0))
	a.set("self_noise", 0.0)
	NoiseSystem.emit(a.global_position, 100.0, true, a)
	_check(absf(float(a.get("self_noise")) - want) < 0.5,
			"世界超过参考值后增益封顶（实得 %.1f）" % float(a.get("self_noise")))
	_silence()


# ------------------------------------------------------------
# F 段：正反馈不许发散（数值曝打）
# ------------------------------------------------------------
func _f_bounded() -> void:
	_say("--- F 段：正反馈有界 —— 一直吵 30 秒也不越界 ---")
	_silence()
	if _players.is_empty():
		return
	var a = _players[0]
	var smax := float(Config.get_value("noise.self.max", 300.0))
	var wmax := float(Config.get_value("noise.world.max", 4000.0))
	# 每 0.05 秒打一拳（120）—— 这是比实战狠得多的输入
	for i in range(600):
		NoiseSystem.emit(a.global_position, 120.0, true, a)
		_tick(1)
	var s1 := float(a.get("self_noise"))
	var w1 := NoiseSystem.world_noise
	_check(s1 <= smax + 0.01 and s1 >= 0.0, "自身噪音停在 %.1f ≤ 上限 %.0f" % [s1, smax])
	_check(w1 <= wmax + 0.01 and w1 >= 0.0, "世界噪音停在 %.1f ≤ 上限 %.0f" % [w1, wmax])
	_check(is_finite(s1) and is_finite(w1), "两个都是有限数（没有 NaN / Inf）")
	_check(w1 > 0.0, "世界确实被喂起来了（%.1f）" % w1)
	# 停手之后：自身先掉干净，世界还在慢慢退
	var before_w := NoiseSystem.world_noise
	_tick(120)        # 6 秒
	var s2 := float(a.get("self_noise"))
	var w2 := NoiseSystem.world_noise
	_check(s2 < s1, "停手 6 秒：自身已回落（%.1f → %.1f）" % [s1, s2])
	_check(s2 < 1.0, "自身基本归零（%.2f）—— 降得快" % s2)
	_check(w2 < before_w and w2 > before_w * 0.4,
			"世界慢得多：%.1f → %.1f（还留着大半个水位）" % [before_w, w2])
	_silence()


# ------------------------------------------------------------
# G 段：光球按**自身噪音**（不是世界噪音）提速
# ------------------------------------------------------------
func _g_badge_speed() -> void:
	_say("--- G 段：等级淡光跟着自己的噪音变快 ---")
	_check(_badge != null, "拿到 0 号角色的 LevelBadge 节点")
	if _badge == null:
		return
	# ⚠ `Config.get_value` 返回 Variant，`var x :=` 推不出类型 → Parse Error →
	# 探针整个不加载 → headless 进程永不退出（老坑）。显式类型。
	var raw = Config.get_value("progression.badge.noise_link", {})
	var lnk: Dictionary = raw if raw is Dictionary else {}
	_check(lnk.size() > 0 and bool(lnk.get("enabled", false)),
			"progression.badge.noise_link 已开启")
	var refv := float(Config.get_value("progression.badge.noise_link.reference", 0.0))
	var mx := float(Config.get_value(
			"progression.badge.noise_link.max_speed_multiplier", 0.0))
	_check(refv > 0.0 and mx > 1.0, "参考 %0.f → 顶格 %.1f 倍速" % [refv, mx])

	_badge.set("noise_override", 0.0)
	var sp0 := float(_badge.call("noise_speed"))
	_badge.set("noise_override", 60.0)
	var sp60 := float(_badge.call("noise_speed"))
	_badge.set("noise_override", 120.0)
	var sp120 := float(_badge.call("noise_speed"))
	_badge.set("noise_override", refv)
	var spf := float(_badge.call("noise_speed"))
	_check(is_equal_approx(sp0, 1.0), "完全安静 = 1 倍速（实得 %.3f）" % sp0)
	_check(absf(spf - mx) < 0.01, "自身噪音到参考值 = 顶格 %.1f 倍（实得 %.2f）" % [mx, spf])
	_check(sp0 < sp60 and sp60 < sp120 and sp120 < spf,
			"越吵越快且单调（%.2f < %.2f < %.2f < %.2f）" % [sp0, sp60, sp120, spf])
	_check(sp60 < 1.5,
			"小噪音（60，脚步都不到两倍）几乎不提速（%.2f）—— 不然会被呼吸拽着抖" % sp60)

	# 时间的推进真的被放大了：同样的墙钟时间，_t 走得更远
	_badge.set("_t", 0.0)
	_badge.set("noise_override", 0.0)
	for _i in range(20):
		_badge.call("_process", 0.05)
	var calm_t := float(_badge.get("_t"))
	_badge.set("_t", 0.0)
	_badge.set("noise_override", float(Config.get_value("noise.self.max", 300.0)))
	for _i in range(20):
		_badge.call("_process", 0.05)
	var loud_t := float(_badge.get("_t"))
	_check(absf(calm_t - 1.0) < 0.001, "安静时 1 秒推进 %.3f 个相位秒" % calm_t)
	_check(loud_t > calm_t * 2.5, "吵起来同一秒推进 %.3f（是安静时的 %.1f 倍）"
			% [loud_t, loud_t / maxf(calm_t, 1e-6)])

	# 「根据第一个来」= 光球读的是所属角色的自身噪音，不是世界噪音
	_silence()
	var a = _players[0]
	_badge.set("noise_override", -1.0)
	a.set("self_noise", 0.0)
	var read_quiet := float(_badge.call("owner_self_noise"))
	a.set("self_noise", 150.0)
	var read_loud := float(_badge.call("owner_self_noise"))
	_check(is_equal_approx(read_quiet, 0.0) and absf(read_loud - 150.0) < 0.01,
			"读的是**自己那个角色**的自身噪音（%.0f → %.0f）" % [read_quiet, read_loud])
	NoiseSystem.world_noise = 3000.0
	_check(absf(float(_badge.call("owner_self_noise")) - 150.0) < 0.01,
			"世界噪音再高也不直接改动光球（只看自己那一份）")
	_silence()
	_badge.set("noise_override", 0.0)


# ------------------------------------------------------------
# H 段：3 倍速下光点仍然不倒转（ω 恒 > 0）
# ------------------------------------------------------------
func _h_no_reverse() -> void:
	_say("--- H 段：提速后光点仍然单向绕、不掉头 ---")
	if _badge == null:
		return
	# ⚠ `noise_override` 替代的是**自身噪音读数**（不是速度倍数）——
	# 想注入顶格速度要传 ≥ reference 的噪音量，传 3.0 等于只给了 3 点噪音，几乎 1 倍速。
	var full_noise := maxf(
			float(Config.get_value("progression.badge.noise_link.reference", 240.0)),
			float(Config.get_value("noise.self.max", 300.0)))
	_badge.set("noise_override", full_noise)
	_badge.set("_t", 0.0)
	var prev := float(_badge.call("orbit_angle"))
	var min_d := 99999.0
	var max_d := 0.0
	for i in range(400):
		_badge.call("_process", 0.05)
		var now := float(_badge.call("orbit_angle"))
		var d := now - prev
		min_d = minf(min_d, d)
		max_d = maxf(max_d, d)
		prev = now
	_check(min_d > 0.0, "顶格速度下角速度恒为正（最小步 Δ=%.4f）—— 不会原地掉头" % min_d)
	_check(max_d / maxf(min_d, 1e-6) > 3.0,
			"快慢差异仍然存在（最快 %.4f / 最慢 %.4f = %.1f 倍）"
			% [max_d, min_d, max_d / maxf(min_d, 1e-6)])

	# 安静时的同采样对照：整体上确实更慢
	_badge.set("noise_override", 0.0)
	_badge.set("_t", 0.0)
	prev = float(_badge.call("orbit_angle"))
	var calm_max := 0.0
	for i in range(400):
		_badge.call("_process", 0.05)
		var now := float(_badge.call("orbit_angle"))
		calm_max = maxf(calm_max, now - prev)
		prev = now
	_check(max_d > calm_max * 2.0,
			"同一段时间内，吵时绕得确实更远（%.4f vs %.4f）" % [max_d, calm_max])
	_badge.set("noise_override", 0.0)


# ------------------------------------------------------------
# I 段：菜单右下那两行读的是这两路
# ------------------------------------------------------------
func _i_menu_readout() -> void:
	_say("--- I 段：菜单右下的两条读数 ---")
	var menus := get_tree().get_nodes_in_group("menu_bar")
	_check(not menus.is_empty(), "局内拿到菜单栏节点")
	if menus.is_empty() or _players.is_empty():
		return
	var menu = menus[0]
	_silence()
	var a = _players[0]
	a.set("self_noise", 120.0)
	NoiseSystem.world_noise = 900.0
	menu.call("_refresh_noise", 0.016)
	var smax := float(Config.get_value("noise.self.max", 300.0))
	var wref := float(Config.get_value("noise.world.reference", 2000.0))
	_check(absf(float(menu.get("_cur_bar").get("max_value")) - smax) < 0.01,
			"第 1 行条的量程 = 自身噪音上限 %.0f（实得 %.0f）"
			% [smax, float(menu.get("_cur_bar").get("max_value"))])
	_check(absf(float(menu.get("_acc_bar").get("max_value")) - wref) < 0.01,
			"第 2 行条的量程 = 世界噪音参考 %.0f（实得 %.0f）"
			% [wref, float(menu.get("_acc_bar").get("max_value"))])
	_check(str(menu.get("_cur_value").get("text")) == "120",
			"第 1 行显示的正是角色自身噪音（实得「%s」）" % str(menu.get("_cur_value").get("text")))
	_check(str(menu.get("_acc_value").get("text")) == "900",
			"第 2 行显示的正是世界噪音（实得「%s」）" % str(menu.get("_acc_value").get("text")))
	_check(float(menu.get("_cur_bar").get("value")) > 0.0
			and float(menu.get("_acc_bar").get("value")) > 0.0,
			"两条都有长度（%.0f / %.0f）"
			% [float(menu.get("_cur_bar").get("value")),
				float(menu.get("_acc_bar").get("value"))])
	_silence()


# ------------------------------------------------------------
# J 段：开新一局要把两路连同每人身上的都清干净
# ------------------------------------------------------------
func _j_reset() -> void:
	_say("--- J 段：reset 清两路 ---")
	if _players.is_empty():
		return
	for p in _players:
		p.set("self_noise", 200.0)
	NoiseSystem.world_noise = 1500.0
	NoiseSystem.emit(Vector2.ZERO, 80.0, true)     # 顺带制造一份「没归属」的
	_check(NoiseSystem.ambient_self_noise() > 0.0,
			"没传 unit 的发声落到没有归属那份（%.1f）" % NoiseSystem.ambient_self_noise())
	NoiseSystem.reset()
	var all_zero := true
	for p in _players:
		if not is_equal_approx(float(p.get("self_noise")), 0.0):
			all_zero = false
	_check(all_zero, "每个角色的自身噪音都归 0")
	_check(is_equal_approx(NoiseSystem.world_noise, 0.0)
			and is_equal_approx(NoiseSystem.ambient_self_noise(), 0.0),
			"世界噪音与没归属那份也归 0")


# ------------------------------------------------------------
# K 段：三个发声点确实把 actor 传进来了
# ------------------------------------------------------------
func _k_wiring() -> void:
	_say("--- K 段：发声调用点传了 source_unit ---")
	# 这条是源码级的：新加一个发声点却忘了传 actor，声音就会掉进「没归属」那份，
	# 表现为「菜单有读数、但每个角色的光球都没反应」。运行时很难发现，所以在源码层守。
	var files := {
		"走": "res://Scripts/combat/states/player_move_state.gd",
		"闪避": "res://Scripts/combat/states/player_dodge_state.gd",
		"攻击": "res://Scripts/combat/states/player_attack_state.gd",
	}
	for label in files:
		var path: String = str(files[label])
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			_check(false, "%s：打不开 %s" % [label, path])
			continue
		var src := f.get_as_text()
		f.close()
		var ok := false
		var lines: Array = src.split("\n")
		for i in range(lines.size()):
			var head: String = lines[i]
			if head.find("NoiseSystem.emit") < 0:
				continue
			# emit(...) 常常被折成两行（`(\n\t\t\t..., true, actor)`），
			# 只看单行会漏判 —— 往下凑三行把参数补全再找 actor。
			var blob: String = head
			for j in range(1, 4):
				if i + j < lines.size():
					blob += " " + lines[i + j]
			if blob.find("true") >= 0 and blob.find("actor") >= 0:
				ok = true
				break
		_check(ok, "%s 的发声点把 actor 传给了 emit（source_unit）" % label)


# ------------------------------------------------------------
# 存档备份 / 还原 + 收尾
# ------------------------------------------------------------
func _backup_save() -> void:
	_save_existed = FileAccess.file_exists(SAVE_PATH)
	if _save_existed:
		_save_backup = FileAccess.get_file_as_string(SAVE_PATH)


func _restore_save() -> void:
	if _save_existed:
		var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_save_backup)
			f.close()
	elif FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))


func _finish() -> void:
	_restore_save()
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for msg in _fails:
		_say("  !! " + msg)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_noise_link] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

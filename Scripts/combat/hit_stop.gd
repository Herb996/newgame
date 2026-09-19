class_name HitStop
extends RefCounted
## ============================================================
## HitStop — 命中微冻（hitstop / 打铁顿帧）
##
## 命中那一瞬把 Engine.time_scale 压到接近 0、几十毫秒后弹回。白闪、挤压、击退、
## 雨丝全部一起顿住，才读得出"这一拳确实打到了东西"；只靠染色做不出这个重量。
##
## 为什么敢动全局时间：本项目里 Engine.time_scale 只有这一处写。局内加速走的
## 是 debug.time_scale，那是倒计时自己的乘数（见 run_manager.gd），两者别混。
##
## 恢复必须用 ignore_time_scale 的定时器：0.045s 的窗口若按被压慢后的时间轴走，
## 真实要等 0.75s 才弹回，等于自己把自己钉死。process_always=true 则保证背包/
## 雕像面板把树暂停时也能弹回来（暂停 ≠ 一直冻着）。
## ============================================================

static var _busy_until_usec := 0
static var _gen := 0


## 来一发微冻。kind = "on_deal_damage"（我方打出伤害）/ "on_receive_damage"（我方挨打）。
## 冷却之内直接忽略：连发武器逐发叠加会把画面钉住不动。
static func pulse(tree: SceneTree, kind: String) -> void:
	if tree == null or not bool(Config.get_value("combat.hit_stop.enabled", true)):
		return
	var cfg: Dictionary = Config.get_value("combat.hit_stop." + kind, {})
	var seconds := float(cfg.get("seconds", 0.0))
	var target_scale := float(cfg.get("time_scale", 1.0))
	if seconds <= 0.0 or target_scale <= 0.0 or target_scale >= 1.0:
		return
	var now := Time.get_ticks_usec()
	if now < _busy_until_usec:
		return
	var cooldown := float(Config.get_value("combat.hit_stop.cooldown_seconds", 0.1))
	_busy_until_usec = now + int((seconds + cooldown) * 1000000.0)
	Engine.time_scale = target_scale
	_gen += 1
	# 第 4 参 ignore_time_scale：冻结时长要用真实秒，不能用被压慢后的游戏秒
	var timer := tree.create_timer(seconds, true, false, true)
	timer.timeout.connect(_on_window_expired.bind(_gen))


## 窗口到点。带代号：期间又打过一发（或调过 reset）就让旧的这次作废，
## 否则一次命中的迟到恢复会把另一次还没走完的冻结提前解除。
static func _on_window_expired(gen: int) -> void:
	if gen == _gen:
		reset()


## 立刻恢复。切模式（进局 / 回基地）时调，别把半截冻结带进下一个场景。
static func reset() -> void:
	_gen += 1
	Engine.time_scale = 1.0

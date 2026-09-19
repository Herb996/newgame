extends Node
## ============================================================
## probe_step_audio — 踩水音「播完就该停」+ 只有移动会发脚步
##
## 用户 2026-09-19 报：踩水的音效会一直在，要求改成移动时才有。
## 根因是合成的：weather_system._pack_wav() 给**所有**程序化采样都钉了
## AudioStreamWAV.LOOP_FORWARD —— 雨底该循环（它做过首尾交叉淡化），但 0.18 秒的
## 踩水音/干脚步声也被做成无限循环，于是走一步响一次、从此停不下来。
## 触发侧本来就对：只有 PlayerMoveState 每 0.4s 发一次脚步（站住即 idle，不发）。
##
## 三段：
##   A) 循环标志（机制层，headless 就能量）：脚步 = 不循环，雨底 = 仍循环
##   B) 真播一次会自己停（要真实音频驱动 → **必须 --window** 跑；无头是 Dummy
##      驱动，playing 恒假，这条在无头里只会假绿，所以直接跳过并说明）
##   C) 触发面守卫：on_wet_step / on_dry_step 的调用点只许在移动状态脚本里
##
## 不动存档、不进出击，纯只读。
## ============================================================

const OUT := "user://_probe_step_audio.txt"
const WEATHER := preload("res://Scripts/weather_system.gd")
## 定义这两个方法的文件本身不算调用点
const DEF_FILE := "res://Scripts/weather_system.gd"

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _master_idx := -1
var _master_db := 0.0
var _pool: Array = []
var _any_playing := false
var _edge_count := 0


func _any_playing_now() -> bool:
	for p in _pool:
		if p != null and bool(p.playing):
			return true
	return false


## 每 0.05 秒采一次"池子里有没有在播"，数上升沿 = 这段时间真响了几次。
## 入口先按当前状态对齐：不然会把"已经响着的那一次"重复计成一次新起播。
func _count_edges(seconds: float) -> int:
	var ticks := maxi(1, int(seconds / 0.05))
	_any_playing = _any_playing_now()
	for _i in range(ticks):
		await get_tree().create_timer(0.05).timeout
		var now := _any_playing_now()
		if now and not _any_playing:
			_edge_count += 1
		_any_playing = now
	return _edge_count


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


func _seconds(wav: AudioStreamWAV) -> float:
	return float(wav.data.size()) / 2.0 / float(wav.mix_rate)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# B 段要 --window 跑才有真实音频驱动；先把窗口钉成小的，别抢用户的全屏
	Config.set_override("display.window_mode", "windowed")
	Config.set_override("display.resolution", [900, 600])
	await _frames(2)

	_say("--- A 段：合成采样的循环标志 ---")
	var step: AudioStreamWAV = WEATHER._gen_step_wav()
	var dry: AudioStreamWAV = WEATHER._gen_dry_step_wav()
	var rain: AudioStreamWAV = WEATHER._gen_rain_wav()
	_say("  踩水 %.3fs loop=%d ｜干脚步 %.3fs loop=%d ｜雨底 %.3fs loop=%d" % [
			_seconds(step), step.loop_mode, _seconds(dry), dry.loop_mode,
			_seconds(rain), rain.loop_mode])
	_check(step.loop_mode == AudioStreamWAV.LOOP_DISABLED,
			"踩水音不循环（loop_mode=%d）—— 旧值 LOOP_FORWARD 就是「响个不停」" % step.loop_mode)
	_check(dry.loop_mode == AudioStreamWAV.LOOP_DISABLED, "干脚步声同样不循环")
	_check(rain.loop_mode == AudioStreamWAV.LOOP_FORWARD,
			"雨底仍然循环（背景音别跟着改坏，loop_mode=%d）" % rain.loop_mode)
	var want_step := float(Config.get_value("weather.audio.step_duration_s", 0.18))
	var want_dry := float(Config.get_value("weather.audio.step_dry_duration_s", 0.10))
	_check(absf(_seconds(step) - want_step) < 0.01,
			"踩水音长度 == config step_duration_s（实测 %.3f / 期望 %.3f）" % [
			_seconds(step), want_step])
	_check(absf(_seconds(dry) - want_dry) < 0.01,
			"干脚步长度 == config step_dry_duration_s（实测 %.3f / 期望 %.3f）" % [
			_seconds(dry), want_dry])

	var w := Node.new()
	w.name = "WeatherAudioProbe"
	w.set_script(WEATHER)
	add_child(w)
	w._active = true   # on_wet_step 的开关；不 setup 地图，只测声音这一路
	var pool: Array = w._step_players
	_check(pool.size() == int(Config.get_value("weather.step.players", 3)),
			"踩水音播放器池已建出（%d 个）" % pool.size())
	if not pool.is_empty():
		var s: AudioStreamWAV = pool[0].stream
		_check(s != null and s.loop_mode == AudioStreamWAV.LOOP_DISABLED,
				"播放器挂的那份 stream 也是不循环的（loop_mode=%d）" % (
				s.loop_mode if s != null else -1))

	_say("--- B 段：真播一次之后会不会自己停 ---")
	var driver := str(AudioServer.get_driver_name())
	if driver == "Dummy":
		_say("  跳过：无头跑的是 Dummy 音频驱动，playing 恒假，量不出「停不停」")
		_say("  → 本段要开窗跑（Dev/probe_step_audio.tscn --window）")
	else:
		_say("  音频驱动=%s" % driver)
		# 本进程静音：开窗只为拿真实音频驱动，别在用户桌面上真放踩水声。
		# playing 与音量无关，静音不影响这段测量。
		_master_idx = AudioServer.get_bus_index("Master")
		if _master_idx >= 0:
			_master_db = float(AudioServer.get_bus_volume_db(_master_idx))
			AudioServer.set_bus_volume_db(_master_idx, -80.0)
		_pool = pool
		var pos := Vector2(400.0, 400.0)
		# 尺子是"有没有在播"的上升沿，不是 stream_finished 信号：那个信号实测在
		# 窗口跑里一次都没发过，拿它断言等于用不确定的东西当尺子。
		_any_playing = false
		w.on_wet_step(pos)
		_check(_any_playing_now(), "踩水音确实开播了（有播放器 playing）")
		var e1 := await _count_edges(1.0)
		_check(e1 == 0, "一秒后全部自己停了（又起播 %d 次）—— 旧行为这里恒 >0" % e1)
		# 再走三步（每步间隔 0.5s ≫ 0.18s 采样）：每步都该"响一下然后自己停"
		var played_steps := 0
		for _i in range(3):
			w.on_wet_step(pos)
			var started := _any_playing_now()
			await get_tree().create_timer(0.5).timeout
			if started and not _any_playing_now():
				played_steps += 1
		_check(played_steps == 3,
				"连续踩水每步都响一下然后停（三步里达标 %d 步）" % played_steps)
		# 站住 2 秒：没有任何播放器又起来
		var quiet := true
		for _i in range(40):
			await get_tree().create_timer(0.05).timeout
			if _any_playing_now():
				quiet = false
		_check(quiet, "站住 2 秒期间再没有声音起来（持续轮询 40 次）")
		_check(not _any_playing_now(), "站住时池子里没有在播的播放器")

	_say("--- C 段：脚步只在移动状态发 ---")
	var callers: Array = []
	for path in _gd_files("res://Scripts"):
		if path == DEF_FILE:
			continue
		var txt := FileAccess.get_file_as_string(path)
		if txt.contains("on_wet_step(") or txt.contains("on_dry_step("):
			callers.append(path.replace("res://", ""))
	_say("  调用点：%s" % (" + ".join(callers) if not callers.is_empty() else "无"))
	_check(callers.size() == 1 and str(callers[0]) == "Scripts/combat/states/player_move_state.gd",
			"on_wet_step/on_dry_step 只有 PlayerMoveState 调用（站住即不响）")

	_finish()


func _gd_files(root_path: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(root_path)
	if d == null:
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		var sub := "%s/%s" % [root_path, f]
		if d.current_is_dir():
			out.append_array(_gd_files(sub))
		elif f.ends_with(".gd"):
			out.append(sub)
		f = d.get_next()
	d.list_dir_end()
	return out


func _finish() -> void:
	if _master_idx >= 0:
		AudioServer.set_bus_volume_db(_master_idx, _master_db)
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for f in _fails:
		_say("  !! %s" % str(f))
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
	print("\n".join(_lines))
	print("[probe_step_audio] fails=%d -> %s" % [_fails.size(),
			"PASS" if _fails.is_empty() else "FAIL"])
	get_tree().quit(0 if _fails.is_empty() else 1)

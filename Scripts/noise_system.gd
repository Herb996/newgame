extends Node
## ============================================================
## NoiseSystem — 噪音系统（DESIGN.md 第二部分 噪音机制）
##
## 全局噪音广播中心（autoload，见 project.godot）。
##   NoiseSystem.emit(source_pos, intensity, from_player := false, source_unit := null)
##     —— 一次噪音事件：向所有敌人按「距离衰减 + 墙体遮挡」派发，并在声源处
##        生成世界空间的扩散圆环（视觉反馈，让玩家知道"我刚才弄出动静了"）。
##        from_player=true 表示这是小队自己弄出的动静，**source_unit 传发声的那个
##        player**（该角色的 self_noise 因此上涨 —— 等级光球与菜单第 1 行读的就是它）。
## 敌人接收后累加 noise_alertness，再由各自 FSM 的阈值决定行为
## （疑惑 / 调查 / 狂暴），完全符合设计稿推荐的「累加阈值 + 状态机」方案。
##
## 设计取舍（对照设计稿逐条）：
##   · 绝不用物理 Area2D 模拟扩散——100 个敌人同时发声会瞬间爆性能。
##     改成「事件广播 + 直接遍历 enemies 组」，噪音事件频次很低（攻击/冲刺/脚步），开销可忽略。
##   · 衰减 = 距离线性衰减 + 隔墙减半；视线用网格采样（与 enemy.has_line_of_sight 同源），
##     绝不做每帧物理射线（100 敌人射线太贵）。
##   · 墙体衰减需要地图墙体网格：由 EnemySystem.setup 在地图生成后注入（setup()）。
##
## 【局内菜单栏右下那两条噪音】2026-09-18 重做成**互相喂养的两路**（用户定）：
##   self_noise  角色自身噪音（**每个角色一份**，存在 player.self_noise）
##               —— 我此刻有多吵。菜单第 1 行显示**全队最大值**；等级光球读自己那份。
##   world_noise 世界累计噪音（**全局一份**）—— 这张地图的紧张度水位。菜单第 2 行。
## 两条互相喂养，构成正反馈：
##   ① 自身 → 世界：自身噪音在**每帧**按比例灌给世界（feed_world），**不从自身扣**
##      （是「累加」不是「转移」——发声的那个人自己也还是那么吵）。
##   ② 世界 → 自身：世界噪音越高，新发声计入自身的量越大（self_gain_from_world，
##      世界到 reference 时 gain = 1 + link.world_to_self_gain）。
## 于是「一处吵起来 → 全场变紧张 → 下一声更难压下去」，且两者衰减快慢不同：
##   自身用**线性**衰减（每秒固定掉点）→ 小动静几秒归零（读作「快」）；
##   世界用**比例**衰减（每秒掉自身 ×ratio）→ 有稳态、尾巴拖得长（读作「慢」）。
##   为什么世界不用线性：线性的稳态不存在——「输入率 > 衰减」就一路涨到爆表、
##   「输入率 < 衰减」就一路归零，读数是开关不是水位；比例衰减才有平衡点与长尾。
## ⚠ **两条都 hard cap**（noise.self.max / noise.world.max）→ 正反馈**不会发散**，
##   写坏了最多是「永远顶格」，不会出现 NaN / Infinity。探针数值校验见 probe_noise_link。
## ⚠ 只统计小队自己发出的声音（emit 的 from_player / source_unit）：敌人发现玩家时的
##   呼喊（enemy_chase_state）不算 —— 否则玩家会看到「我没动但噪音爆表」这种误读。
## ⚠ 这两个值纯展示用，不参与判定：敌人听到的仍然是衰减后的瞬时强度。
## ⚠ 探针 / 命令行直接 `emit(pos, x, true)` 却没传 source_unit 时，走 `_ambient_self`
##   （一份**没有归属**的自身噪音），保证「发声了就该有读数」这条旧断言仍然成立。
##
## 【爆裂鼓手放大，2026-09-17】邪术师特性 burst_drum 会在**小队**发声时把强度乘一个倍率
## （player_noise_multiplier：按发声点与各邪术师的距离加权、多只叠加、全局封顶）。
## 放大发生在「算读数」与「派发给敌人」**之前**，所以菜单栏读数、光圈大小、
## 敌人实际听到的强度，全部都是放大后的值 —— 一条链路，没有第二个真相。
##
## 【听者耳朵倍率，2026-09-17】上面那个是「声源更响」（全局），这里是「耳朵更灵」（按兵种）：
## 派发循环里按听者把**等效听力半径**乘上 enemy.gd::noise_sensitivity()（劫掠者 1.8，
## 用户定的「对声音更敏感」）。普通敌人是 1.0，与旧行为完全一致。
## 两者互不干扰：一个改 intensity，一个改 radius。
## ============================================================

const FX_RING := preload("res://Scripts/combat/fx_ring.gd")

## 带「噪音放大」特性的敌人所在的组（由 enemy.gd::_register_feature_groups 挂）。
## 字符串两边都写死，必须一致；改了请一起改。
const GROUP_AMPLIFIERS := "noise_amplifiers"

var _walls: Array = []
var _tile_size: int = 16
var _map_ready := false
var _last_ring_time := -999.0

# --- 菜单栏右下那两条噪音（见文件头）---
var world_noise := 0.0          # 世界累计噪音（全局一份，慢衰减）
var peak_noise := 0.0           # 本局峰值（按自身噪音计，统计用）
## 没有归属的自身噪音：只在「发了声却不知道是谁发的」时用到（探针直接 emit、
## 命令行路径）。正常游戏里发声一定带 source_unit，这份恒为 0。
var _ambient_self := 0.0


## 开新一局：清空两路读数 + 所有角色的自身噪音。由 main._enter_run 调用。
## ⚠ 这里**顺便**遍历 player 组清 self_noise：换成「每个 player 自己监听 reset」
## 的话，谁负责订阅、谁先于谁 add_child 又是一摊事 —— 一处生效胜过两处约定。
func reset() -> void:
	world_noise = 0.0
	peak_noise = 0.0
	_ambient_self = 0.0
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and p.has_method("clear_self_noise"):
			p.call("clear_self_noise")


func _process(delta: float) -> void:
	var dec := maxf(0.0, float(Config.get_value("noise.self.decay_per_second", 90.0)))
	var smax := maxf(1.0, float(Config.get_value("noise.self.max", 300.0)))
	var wr := clampf(float(Config.get_value("noise.world.decay_ratio_per_second", 0.06)),
			0.0, 20.0)
	var wmax := maxf(1.0, float(Config.get_value("noise.world.max", 4000.0)))
	var transfer := maxf(0.0, float(Config.get_value(
			"noise.link.self_to_world_per_second", 360.0)))
	# ① 世界噪音衰减（**先衰再喂**，顺序不影响稳态，只是让「同时发生」的读数略低一点点）
	world_noise *= maxf(0.0, 1.0 - wr * delta)
	# ② 每个角色：自身噪音喂世界 + 自身线性衰减
	var feed := 0.0
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		var raw = p.get("self_noise")
		if raw == null:
			continue
		var s := float(raw)
		if s <= 0.0:
			continue
		feed += s / smax * transfer * delta
		p.set("self_noise", maxf(0.0, s - dec * delta))
	if _ambient_self > 0.0:
		feed += _ambient_self / smax * transfer * delta
		_ambient_self = maxf(0.0, _ambient_self - dec * delta)
	world_noise = clampf(world_noise + feed, 0.0, wmax)


## 新一次发声计入**自身噪音**的量（已经乘过世界噪音的增益）。
## `who` 为空 / 不带 add_self_noise → 落到没有归属的 `_ambient_self`。
func add_player_noise(intensity: float, who: Node = null) -> void:
	var add := intensity * self_gain_from_world()
	var smax := maxf(1.0, float(Config.get_value("noise.self.max", 300.0)))
	if who != null and is_instance_valid(who) and who.has_method("add_self_noise"):
		who.call("add_self_noise", add)
		return
	# 没归属的那份自己按同一套 cap 累加（探针/命令行路径）
	_ambient_self = clampf(_ambient_self + add, 0.0, smax)


## ② 世界 → 自身的增益：世界噪音越高，同样一下发声自身涨得越多。
## world 到 reference 时封顶为 1 + link.world_to_self_gain（之后不再加成，故必有界）。
func self_gain_from_world() -> float:
	var g := maxf(0.0, float(Config.get_value("noise.link.world_to_self_gain", 1.2)))
	var wref := maxf(1.0, float(Config.get_value("noise.world.reference", 2000.0)))
	return 1.0 + g * clampf(world_noise / wref, 0.0, 1.0)


## 未归属的自身噪音（探针 / 命令行路径用；正常游戏恒为 0）
func ambient_self_noise() -> float:
	return _ambient_self


## 小队当前的**自身噪音** = 全队最大值（「我有多吵」看最吵的那个；
## 光球是每人各读各的，本方法只给菜单第 1 行和档位判定用）。
func team_self_noise() -> float:
	var best := _ambient_self
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		var raw = p.get("self_noise")
		if raw == null:
			continue
		best = maxf(best, float(raw))
	return best


## 当前噪音档位（菜单第 1 行的文字与配色）：{"name", "color", "index"}。
## 档位表来自 noise.display.levels（按 min 从高往低匹配第一个命中的）。
## 表为空/缺配置时回落到单档「安静」，保证菜单栏永远有东西显示。
func noise_level() -> Dictionary:
	var levels: Array = Config.get_value("noise.display.levels", [])
	var best := {"name": "安静", "color": Color(0.48, 0.78, 0.42), "index": 0}
	var best_min := -1.0
	var cur := team_self_noise()
	for i in range(levels.size()):
		var lv = levels[i]
		if not (lv is Dictionary):
			continue
		var m := float((lv as Dictionary).get("min", 0.0))
		if cur >= m and m >= best_min:
			best_min = m
			best = {
				"name": str((lv as Dictionary).get("name", "")),
				"color": Color(str((lv as Dictionary).get("color", "#7bc86c"))),
				"index": i,
			}
	return best


## 世界噪音占参考值的比例（0~1，第 2 行条形长度用）。参考值 = noise.world.reference。
## ⚠ 与 opacity / 任何逻辑无关，只是一条给眼睛看的刻度。
func world_ratio() -> float:
	var ref := maxf(1.0, float(Config.get_value("noise.world.reference", 2000.0)))
	return clampf(world_noise / ref, 0.0, 1.0)


## 自身噪音占上限的比例（0~1，第 1 行条形长度用）。
func self_ratio() -> float:
	var smax := maxf(1.0, float(Config.get_value("noise.self.max", 300.0)))
	return clampf(team_self_noise() / smax, 0.0, 1.0)


## 把一股噪音灌进世界噪音。**接口与每帧灌注同源**（都在 `_process` 里按玩家组的
## self_noise 算，这里给探针 / 一次性事件用）；同样不扣任何人自身的量。
func feed_world(amount_world: float) -> void:
	var wmax := maxf(1.0, float(Config.get_value("noise.world.max", 4000.0)))
	world_noise = clampf(world_noise + amount_world, 0.0, wmax)


## 当前被惊动的敌人数量（警觉度 ≥ noise.thresholds.investigate 的敌人数）。
## 只读不写；菜单栏按 noise.display.alert_watch_interval_seconds 节流调用。
func alerted_enemy_count() -> int:
	var inv := float(Config.get_value("noise.thresholds.investigate", 30.0))
	var n := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e):
			continue
		var a = e.get("noise_alertness")
		if a != null and float(a) >= inv:
			n += 1
	return n


## 由 EnemySystem.setup 在地图生成后注入墙体网格（供噪音的隔墙衰减使用）
func setup(walls: Array, tile_size: int) -> void:
	_walls = walls
	_tile_size = tile_size
	_map_ready = true


# ------------------------------------------------------------
# 玩家噪音放大（特性 burst_drum「爆裂鼓手」，数值在 config 的
# enemy_types.types[cultist].traits[0].noise_amplify）
# ------------------------------------------------------------

## 小队发一次声时，实际强度要乘的倍率 = clamp(1 + Σ 各放大器增幅, 1, 全局封顶)。
## 「放大器」= 场上带该特性的活敌人（按发声点距离线性加权，见 enemy.gd::noise_amplify_gain）。
## 组为空（场上没有邪术师）直接返回 1.0 —— 不走任何遍历，老玩法零开销。
## 倍率上限读 enemy_traits.noise_amplify.max_multiplier；enabled=false 可整体关掉。
func player_noise_multiplier(at: Vector2) -> float:
	var sc = Config.get_value("enemy_traits.noise_amplify", {})
	if not (sc is Dictionary):
		return 1.0
	var cfg: Dictionary = sc
	if not bool(cfg.get("enabled", true)):
		return 1.0
	var mult := 1.0
	for e in get_tree().get_nodes_in_group(GROUP_AMPLIFIERS):
		if not is_instance_valid(e):
			continue
		if e.has_method("noise_amplify_gain"):
			mult += float(e.noise_amplify_gain(at))
	return clampf(mult, 1.0, maxf(1.0, float(cfg.get("max_multiplier", 3.0))))


## 发出一次噪音。intensity = 基础强度（config.noise.sources 的取值，如攻击=120）。
## 会自动向所有听力范围内的敌人派发（带衰减），并生成视觉圆环。
## from_player = true 时这次发声计入**该角色的自身噪音**（默认 false：敌人呼喊不算。
## 三个玩家侧调用点 走/闪避/攻击 都传 true，并且要把 actor 作为 source_unit 一起传进来
## —— 少了就只能落到 `_ambient_self` 那份没归属的读数里）。
func emit(source_pos: Vector2, intensity: float, from_player := false,
		source_unit: Node = null) -> void:
	if from_player:
		# 「爆裂鼓手」：附近有邪术师时，小队的动静被放大（读数也按放大后的算，
		# 玩家能直接看到噪音表飙起来）。敌人自己的呼喊不走这条分支，不会被放大。
		intensity *= player_noise_multiplier(source_pos)
		add_player_noise(intensity, source_unit)
		peak_noise = maxf(peak_noise, intensity)
	# 视觉圆环仅在大噪音时出现，避免脚步等轻噪音形成高频光圈
	var ring_min_intensity := float(Config.get_value("noise.ring_min_intensity", 35.0))
	if intensity >= ring_min_intensity:
		_spawn_ring(source_pos, intensity)
	var hear_radius := float(Config.get_value("noise.hear_radius_cells", 16)) * float(_tile_size)
	var min_notice := float(Config.get_value("noise.min_notice", 4.0))
	for e in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e):
			continue
		# 【耳朵倍率】兵种级的听力修正（enemy.gd::noise_sensitivity，劫掠者 1.8 更敏感）。
		# 放大的是**这只敌人的等效听力半径**，于是同一距离衰减更小、超出普通半径的远处
		# 也还够得着 —— 一处改动同时给出「听得更远 + 同距离更清楚」。
		# 普通敌人 sens=1.0，与旧行为逐位一致（旧式子就是 radius=hear_radius）。
		var sens := 1.0
		if e.has_method("noise_sensitivity"):
			sens = maxf(0.01, float(e.call("noise_sensitivity")))
		var radius := hear_radius * sens
		var d := source_pos.distance_to(e.global_position)
		if d > radius:
			continue
		# 距离衰减：近处几乎全强度，远处线性趋近 0
		var att := 1.0 - (d / maxf(radius, 1.0))
		# 墙体遮挡：隔墙减半（未注入地图时跳过，避免误判全通透）
		if _map_ready and not _has_line_of_sight(source_pos, e.global_position):
			att *= float(Config.get_value("noise.wall_attenuation", 0.5))
		var received := intensity * att
		if received >= min_notice and e.has_method("hear_noise"):
			e.hear_noise(source_pos, received)


## 在声源处生成一圈扩散圆环；半径 = 实际可听范围（received == min_notice 处），
## 这样玩家能直观看到"这声响传了多远"。
func _spawn_ring(pos: Vector2, intensity: float) -> void:
	# 全局限频：即便多次大噪音叠加，也限制光圈最小间隔，防止堆叠刺眼
	var now := Time.get_ticks_msec() / 1000.0
	var min_interval := float(Config.get_value("noise.ring_min_interval_seconds", 0.15))
	if now - _last_ring_time < min_interval:
		return
	_last_ring_time = now
	var ring: Node2D = FX_RING.new()
	var hear_radius := float(Config.get_value("noise.hear_radius_cells", 16)) * float(_tile_size)
	var min_notice := float(Config.get_value("noise.min_notice", 4.0))
	var radius := hear_radius * (1.0 - min_notice / maxf(intensity, min_notice))
	var dur := float(Config.get_value("noise.ring_duration_seconds", 0.7))
	var col := Color(str(Config.get_value("noise.ring_color", "#ffd54f")))
	col.a = float(Config.get_value("noise.ring_alpha", 0.35))
	ring.setup(radius, dur, col)
	var parent := get_tree().current_scene
	if parent != null:
		var world := parent.get_node_or_null("GameRoot")
		if world != null:
			parent = world
		parent.add_child(ring)
		ring.global_position = pos


## 视线检测：沿两点连线按 los_step_cells（格）采样墙体格，命中即被遮挡。
## 与 enemy.has_line_of_sight 同源逻辑——噪音系统不挂在敌人身上，需要独立持有一份。
func _has_line_of_sight(from: Vector2, to: Vector2) -> bool:
	if _walls.is_empty():
		return true
	var step_px := float(Config.get_value("enemy.los_step_cells", 0.35)) * float(_tile_size)
	var steps := int(from.distance_to(to) / maxf(step_px, 1.0)) + 1
	for i in range(1, steps):
		var cell := _cell_of(from.lerp(to, float(i) / float(steps)))
		if not _in_bounds(cell) or _walls[cell.y][cell.x]:
			return false
	return true


func _cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(int(pos.x / _tile_size), int(pos.y / _tile_size))


func _in_bounds(cell: Vector2i) -> bool:
	var h: int = _walls.size()
	if h == 0:
		return false
	var w: int = _walls[0].size()
	return cell.x >= 0 and cell.y >= 0 and cell.x < w and cell.y < h

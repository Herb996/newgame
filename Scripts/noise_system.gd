extends Node
## ============================================================
## NoiseSystem — 噪音系统（06_FIGHT.md 第 8 节「噪音机制」）
##
## 全局噪音广播中心（autoload，见 project.godot）。
##   NoiseSystem.emit(source_pos, intensity)
##     —— 一次噪音事件：向所有敌人按「距离衰减 + 墙体遮挡」派发，并在声源处
##        生成世界空间的扩散圆环（视觉反馈，让玩家知道"我刚才弄出动静了"）。
## 敌人接收后累加 noise_alertness，再由各自 FSM 的阈值决定行为
## （疑惑 / 调查 / 狂暴），完全符合设计稿推荐的「累加阈值 + 状态机」方案。
##
## 设计取舍（对照设计稿逐条）：
##   · 绝不用物理 Area2D 模拟扩散——100 个敌人同时发声会瞬间爆性能。
##     改成「事件广播 + 直接遍历 enemies 组」，噪音事件频次很低（攻击/冲刺/脚步），开销可忽略。
##   · 衰减 = 距离线性衰减 + 隔墙减半；视线用网格采样（与 enemy.has_line_of_sight 同源），
##     绝不做每帧物理射线（100 敌人射线太贵）。
##   · 墙体衰减需要地图墙体网格：由 EnemySystem.setup 在地图生成后注入（setup()）。
## ============================================================

const FX_RING := preload("res://Scripts/combat/fx_ring.gd")

var _walls: Array = []
var _tile_size: int = 16
var _map_ready := false


## 由 EnemySystem.setup 在地图生成后注入墙体网格（供噪音的隔墙衰减使用）
func setup(walls: Array, tile_size: int) -> void:
	_walls = walls
	_tile_size = tile_size
	_map_ready = true


## 发出一次噪音。intensity = 基础强度（config.noise.sources 的取值，如攻击=55）。
## 会自动向所有听力范围内的敌人派发（带衰减），并生成视觉圆环。
func emit(source_pos: Vector2, intensity: float) -> void:
	_spawn_ring(source_pos, intensity)
	var hear_radius := float(Config.get_value("noise.hear_radius_cells", 16)) * float(_tile_size)
	var min_notice := float(Config.get_value("noise.min_notice", 4.0))
	for e in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e):
			continue
		var d := source_pos.distance_to(e.global_position)
		if d > hear_radius:
			continue
		# 距离衰减：近处几乎全强度，远处线性趋近 0
		var att := 1.0 - (d / hear_radius)
		# 墙体遮挡：隔墙减半（未注入地图时跳过，避免误判全通透）
		if _map_ready and not _has_line_of_sight(source_pos, e.global_position):
			att *= float(Config.get_value("noise.wall_attenuation", 0.5))
		var received := intensity * att
		if received >= min_notice and e.has_method("hear_noise"):
			e.hear_noise(source_pos, received)


## 在声源处生成一圈扩散圆环；半径 = 实际可听范围（received == min_notice 处），
## 这样玩家能直观看到"这声响传了多远"。
func _spawn_ring(pos: Vector2, intensity: float) -> void:
	var ring: Node2D = FX_RING.new()
	var hear_radius := float(Config.get_value("noise.hear_radius_cells", 16)) * float(_tile_size)
	var min_notice := float(Config.get_value("noise.min_notice", 4.0))
	var radius := hear_radius * (1.0 - min_notice / maxf(intensity, min_notice))
	var dur := float(Config.get_value("noise.ring_duration_seconds", 0.7))
	var col := Color(str(Config.get_value("noise.ring_color", "#ffd54f")))
	col.a = 0.85
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

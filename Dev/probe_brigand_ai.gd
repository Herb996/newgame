extends Node
## ============================================================
## probe_brigand_ai — 劫掠者（brigand）的 AI +「挨打也会动」验证（headless 可跑）
##
## 用户 2026-09-17 定：
##   「最后做劫掠者，他的机制就是满地图随机游走，并且遇到同类会一起移动，上限先做到 5 个吧，
##     所以其他怪只在一个固定的范围内移动，受到攻击或者噪音，再移动，劫掠者对声音更敏感」
##
## 逐条对应到断言：
##   满地图随机游走         → C：30 次选点的目标散布在整张地图上、且都 ≥ min_target_distance_px
##   （对照）其他怪固定范围  → C：弓手 20 次选点全落在出生点 ±patrol_radius_cells 内
##   遇到同类一起移动       → D：靠近即结伙；E：成员跟队形、群主挪窝成员跟着挪
##   上限 5 个              → E2：第 6 只被拒；D：随机结伙也不会超过 5
##   受攻击再移动           → H：alert_from_attacker 涨警觉度 → 转调查 → 真的朝攻击者走过去
##   对声音更敏感           → I：同样距离，劫掠者听得到而普通兵种听不到；同距离也更"响"
## 另外验：
##   A) config 真值（全局 enemy.ai + 劫掠者覆盖 + 其它兵种没有 ai 段）
##   B) 合并口径：兵种按键覆盖，缺的键继承全局；兵种覆盖不污染全局
##   F) 群主死亡 → 同群下一个活着的自动接任
##   G) 只跟同类：弓手没有 pack，靠过去也不会被收
##
## 为什么 headless 能跑：全是数值 + A* 网格判定，不依赖渲染。
## 注：敌人距玩家超过 ai_active_radius_cells 会休眠、整帧不跑 AI（性能保护），
##     所以探针必须放一个**假玩家**在场景里，否则状态机根本不动。
## 注 2：本探针不加载 Main.tscn，自己搭最小 A* 网格 + 独立 EnemySystem（同 probe_enemy_split）。
## ============================================================

const OUT := "user://_probe_brigand_ai.txt"
const ENEMY_SYS := preload("res://Scripts/enemy_system.gd")
const ENEMY_SCENE := preload("res://Scenes/Enemy.tscn")
const TILE := 64
const MAP_CELLS := 96                       # 96 × 64 = 6144px 见方的一张空地图
const PLAYER_POS := Vector2(3072.0, 3072.0)

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _walls: Array = []


## 假玩家：只为让敌人别进休眠（AI 活跃半径是按"离玩家多远"判的）。
## 真实 Player 太重（要贴图/状态机/小队），而且本探针不验玩家的任何行为。
class FakePlayer extends Area2D:
	var hp := 100
	func take_damage(amount: int, _from: Vector2) -> bool:
		hp -= amount
		return true


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _phys(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame


# ------------------------------------------------------------
# 搭台
# ------------------------------------------------------------

func _open_walls(size: int) -> Array:
	var w: Array = []
	for _y in range(size):
		var row: Array = []
		for _x in range(size):
			row.append(false)
		w.append(row)
	return w


## 某个兵种配置的深拷贝（改它不会污染 Config）
func _cfg(id: String) -> Dictionary:
	for t in Config.get_value("enemy_types.types", []):
		if t is Dictionary and str((t as Dictionary).get("id", "")) == id:
			return (t as Dictionary).duplicate(true)
	return {}


## 安全取子字典：拿不到就返回空字典（探针里到处都要读 config 的嵌套段）
func _sub(d, key: String) -> Dictionary:
	if d is Dictionary and (d as Dictionary).get(key) is Dictionary:
		return (d as Dictionary)[key]
	return {}


func _world() -> Node2D:
	var w := Node2D.new()
	add_child(w)
	return w


func _make_system(world) -> Node:
	var sys = ENEMY_SYS.new()
	sys.name = "Sys"
	add_child(sys)
	sys._root = world
	sys._walls = _walls
	sys._tile_size = TILE
	sys._astar = MapGenerator.build_astar(_walls, TILE)
	return sys


func _spawn_at(world: Node2D, pos: Vector2, type_cfg: Dictionary, sys):
	var e = ENEMY_SCENE.instantiate()
	e.position = pos
	world.add_child(e)
	e.setup(_walls, TILE, sys._astar, type_cfg, {}, sys)
	return e


## 段末清理：队列清空 + 释放 world/sys，并等 2 帧让 queue_free 真正落地。
## 不拆干净的话下一段的「全场扫描」（结伙时遍历 enemies 组）会看到上一段的尸体。
func _teardown(world: Node2D, sys) -> void:
	if sys != null and is_instance_valid(sys):
		sys._pending.clear()
		sys.queue_free()
	if world != null and is_instance_valid(world):
		world.queue_free()
	await _phys(2)


## 目标点（路径终点；没有路径时返回 ZERO）
func _path_end(e) -> Vector2:
	var p = e.get("_path")
	if p is PackedVector2Array and (p as PackedVector2Array).size() > 0:
		return (p as PackedVector2Array)[(p as PackedVector2Array).size() - 1]
	return Vector2.ZERO


# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------

func _ready() -> void:
	_walls = _open_walls(MAP_CELLS)
	NoiseSystem.setup([], TILE)          # 空网格 = 无障碍（听力段要算干净的衰减）
	NoiseSystem.reset()
	# 本机 settings.json 会把 enemy.speed 调成 120（还改过活跃半径）：探针按固定值跑，
	# 免得"走多少帧能追上"这类断言依赖用户本机的设置。
	Config.set_override("enemy.speed", 360)
	var fp := FakePlayer.new()
	fp.name = "FakePlayer"
	fp.add_to_group("player")
	add_child(fp)
	fp.global_position = PLAYER_POS

	var brigand := _cfg("brigand")
	var raider := _cfg("raider")

	_sec_config(brigand, raider)
	await _sec_merge(brigand, raider)
	await _sec_roam(brigand, raider)
	await _sec_pack_join(brigand)
	await _sec_pack_cap(brigand)
	await _sec_pack_follow(brigand)
	await _sec_leader_death(brigand)
	await _sec_same_kind_only(brigand, raider)
	await _sec_hit_reaction(raider)
	await _sec_hearing(brigand, raider)

	_finish()


# ------------------------------------------------------------
# A) config 真值
# ------------------------------------------------------------

func _sec_config(brigand: Dictionary, raider: Dictionary) -> void:
	_say("=== A) config 真值 ===")
	var gd = Config.get_value("enemy.ai", {})
	_check(gd is Dictionary and not (gd as Dictionary).is_empty(), "全局 enemy.ai 存在")
	var gdd: Dictionary = gd if gd is Dictionary else {}
	_check(str(_sub(gdd, "roam").get("mode", "")) == "home_radius",
			"全局默认 roam.mode = home_radius（默认所有怪只在一个固定范围内移动）")
	_check(is_equal_approx(float(gdd.get("noise_sensitivity", 0.0)), 1.0),
			"全局默认 noise_sensitivity = %.2f" % float(gdd.get("noise_sensitivity", -1.0)))
	_check(not bool(_sub(gdd, "pack").get("enabled", true)),
			"全局默认 pack.enabled = false（只有劫掠者成群）")
	_check(int(_sub(gdd, "pack").get("max_members", 0)) == 5, "全局默认每群上限 = 5")

	var bai := _sub(brigand, "ai")
	_check(str(_sub(bai, "roam").get("mode", "")) == "whole_map",
			"劫掠者覆盖 roam.mode = whole_map（实得 %s）" % str(_sub(bai, "roam").get("mode", "")))
	_check(float(bai.get("noise_sensitivity", 0.0)) > 1.0,
			"劫掠者 noise_sensitivity = %.2f（>1 = 对声音更敏感）"
			% float(bai.get("noise_sensitivity", 0.0)))
	_check(bool(_sub(bai, "pack").get("enabled", false)), "劫掠者 pack.enabled = true")
	_check(int(_sub(bai, "pack").get("max_members", 0)) == 5,
			"劫掠者每群上限 = 5（用户定的「上限先做到 5 个」）")
	_check(not raider.has("ai"), "弓手没有 ai 段 → 行为完全不变")
	for t in Config.get_value("enemy_types.types", []):
		if not (t is Dictionary):
			continue
		var id := str((t as Dictionary).get("id", ""))
		if id == "brigand":
			continue
		_check(not (t as Dictionary).has("ai"), "%s 没有 ai 段（沿用全局默认）" % id)
	_check(is_equal_approx(float(Config.get_value("noise.sources.hurt", 0.0)), 100.0),
			"noise.sources.hurt = 100（挨打时自己涨的警觉度）")


# ------------------------------------------------------------
# B) 合并口径：兵种按键覆盖，缺的键继承全局；兵种覆盖不污染全局
# ------------------------------------------------------------

func _sec_merge(brigand: Dictionary, raider: Dictionary) -> void:
	_say("=== B) 兵种 ai 与全局默认的合并 ===")
	var world := _world()
	var sys = _make_system(world)
	# 一只带 ai 段的劫掠者：三项都是兵种自己的值
	var b = _spawn_at(world, PLAYER_POS + Vector2(900.0, 0.0), brigand, sys)
	_check(b.roam_mode() == "whole_map", "劫掠者 roam_mode() = whole_map")
	_check(is_equal_approx(b.noise_sensitivity(), 1.8),
			"劫掠者 noise_sensitivity() = %.2f" % b.noise_sensitivity())
	_check(b.pack_enabled() and b.pack_max_members() == 5,
			"劫掠者 pack 开、上限 5")

	# 一只没 ai 段的弓手：三项全走全局默认
	var r = _spawn_at(world, PLAYER_POS + Vector2(-900.0, 0.0), raider, sys)
	_check(r.roam_mode() == "home_radius", "弓手 roam_mode() = home_radius")
	_check(is_equal_approx(r.noise_sensitivity(), 1.0),
			"弓手 noise_sensitivity() = %.2f" % r.noise_sensitivity())
	_check(not r.pack_enabled(), "弓手 pack 关")

	# 自制一份「只覆盖 roam.mode」的兵种配置 → 其余键必须继承全局
	var partial := raider.duplicate(true)
	partial["ai"] = {"roam": {"mode": "whole_map"}}
	var p = _spawn_at(world, PLAYER_POS + Vector2(0.0, 900.0), partial, sys)
	_check(p.roam_mode() == "whole_map", "只写 roam.mode 也能生效（按键覆盖）")
	_check(is_equal_approx(p.noise_sensitivity(), 1.0), "没写的 noise_sensitivity 继承全局 1.0")
	_check(not p.pack_enabled(), "没写的 pack 继承全局：关")
	_check(is_equal_approx(float(Config.get_value("enemy.ai.noise_sensitivity", 0.0)), 1.0),
			"兵种覆盖没有把全局值改掉（全局仍是 1.0）")
	await _teardown(world, sys)


# ------------------------------------------------------------
# C) 满地图随机游走 vs 固定范围
# ------------------------------------------------------------

func _sec_roam(brigand: Dictionary, raider: Dictionary) -> void:
	_say("=== C) 满地图随机游走（劫掠者） vs 固定范围（其他怪） ===")
	var world := _world()
	var sys = _make_system(world)
	var b = _spawn_at(world, PLAYER_POS, brigand, sys)
	var r = _spawn_at(world, PLAYER_POS + Vector2(300.0, 0.0), raider, sys)
	b.set_physics_process(false)          # 只验"选点"，不让状态机插进来换掉路径
	r.set_physics_process(false)

	_check(b.roam_mode() == "whole_map", "劫掠者 roam.mode = whole_map")
	_check(r.roam_mode() == "home_radius", "弓手 roam.mode = home_radius")
	_check(is_equal_approx(b.ai_active_radius_cells(), 48.0),
			"劫掠者的 AI 活跃半径放宽到 48 格（否则会被 32 格的休眠圈住，走不远）")
	_check(is_equal_approx(r.ai_active_radius_cells(),
			float(Config.get_value("enemy.ai_active_radius_cells", 32.0))),
			"弓手沿用全局活跃半径 32 格")

	var min_d := float(_sub(_sub(brigand, "ai"), "roam").get("min_target_distance_px", 0.0))
	_check(min_d > 0.0, "min_target_distance_px = %.0f（避免挑到脚边原地抖）" % min_d)
	var samples := 30
	var bad := 0
	var sum_d := 0.0
	var max_d := 0.0
	for _i in range(samples):
		b.clear_move_target()
		b.pick_patrol_target()
		if not b.has_move_target():
			bad += 1
			continue
		var dst := _path_end(b).distance_to(PLAYER_POS)
		sum_d += dst
		max_d = maxf(max_d, dst)
		if dst < min_d - 1.0:
			bad += 1
	_check(bad == 0,
			"%d 次选点：全部可达、且都 ≥ %.0fpx（异常 %d 次）" % [samples, min_d, bad])
	var mean_d := sum_d / float(samples)
	_check(mean_d > 1200.0, "%d 次目标的平均距离 %.0fpx（满地图散开）" % [samples, mean_d])
	_check(max_d > 2000.0,
			"最远一次目标 %.0fpx（对照：出生点周围 6 格只有 %dpx）"
			% [max_d, int(6.0 * TILE)])

	# 对照：弓手 20 次选点必须全在出生点 ±patrol_radius_cells 内
	var rad_cells := float(Config.get_value("enemy.ai.roam.patrol_radius_cells", 6.0))
	# 老实现是在【方形】范围里取点，斜角最远 = 边长 × √2；再加半格取整误差
	var bound := rad_cells * float(TILE) * sqrt(2.0) + float(TILE) * 0.75
	var out_of_bound := 0
	for _i in range(20):
		r.clear_move_target()
		r.pick_patrol_target()
		if not r.has_move_target():
			out_of_bound += 1
			continue
		if _path_end(r).distance_to(r.global_position) > bound:
			out_of_bound += 1
	_check(out_of_bound == 0,
			"对照：弓手 20 次选点全在出生点 %.0fpx 内（越界 %d 次）" % [bound, out_of_bound])
	await _teardown(world, sys)


# ------------------------------------------------------------
# D) 遇到同类结伙（随机收敛）
# ------------------------------------------------------------

func _sec_pack_join(brigand: Dictionary) -> void:
	_say("=== D) 遇到同类会一起移动（结伙） ===")
	var cfg := brigand.duplicate(true)
	# 把扫描节流压到 0（探针手动驱动，不等帧），只验"相遇 → 结伙"这件事
	_sub(cfg, "ai")["pack"]["scan_interval_seconds"] = 0.0
	var world := _world()
	var sys = _make_system(world)
	var arr: Array = []
	for i in range(6):
		var e = _spawn_at(world, Vector2(3000.0 + float(i) * 100.0, 3000.0), cfg, sys)
		e.set_physics_process(false)
		arr.append(e)
	_check(arr[0].pack_size() == 1, "一出生就是「只有自己的群」（群主 = 自己）")
	# 手动驱动 20 轮扫描（等价于 _physics_process 里的 _tick_pack）
	for _round in range(20):
		for e in arr:
			e._pack_scan_timer = 999.0
			e._tick_pack(0.6)
	var max_size := 0
	var seen: Array = []            # 不同群的个数（字典实例两两比较，不能用字典当 key）
	for e in arr:
		max_size = maxi(max_size, int(e.pack_size()))
		var pd = e.pack_dict()
		var found := false
		for s in seen:
			if s == pd:
				found = true
				break
		if not found:
			seen.append(pd)
	_check(max_size >= 2, "靠近的同类结成一伙了（最大群 %d 只）" % max_size)
	_check(max_size <= 5, "任何一群都没超过上限 5（最大 %d 只）" % max_size)
	_check(seen.size() < arr.size(), "6 只里至少有两只同群（%d 个不同的群）" % seen.size())
	await _teardown(world, sys)


# ------------------------------------------------------------
# E2) 上限硬闸：第 6 只必须被拒
# ------------------------------------------------------------

func _sec_pack_cap(brigand: Dictionary) -> void:
	_say("=== E2) 每群上限 5（硬闸） ===")
	var world := _world()
	var sys = _make_system(world)
	var g: Array = []
	for i in range(6):
		g.append(_spawn_at(world, Vector2(3000.0 + float(i) * 40.0, 1000.0), brigand, sys))
	for i in range(1, 5):
		_check(bool(g[0].absorb_into_pack(g[i])), "第 %d 只加入群主（群内 %d 只）"
				% [i + 1, int(g[0].pack_size())])
	_check(int(g[0].pack_size()) == 5, "群满 5 只（实得 %d）" % int(g[0].pack_size()))
	_check(not bool(g[0].absorb_into_pack(g[5])), "第 6 只被拒（上限 5）")
	_check(int(g[5].pack_size()) == 1, "被拒的那只仍自成一群（实得 %d）" % int(g[5].pack_size()))
	_check(g[0].pack_dict() == g[4].pack_dict(), "同群两边共享**同一个字典实例**")
	_check(g[0].is_pack_leader() and not g[4].is_pack_leader(), "群主是第 1 只，第 5 只不是群主")
	_check(not g[0].is_pack_follower() and g[4].is_pack_follower(),
			"群主自己不是跟随者，第 5 只是跟随者")
	await _teardown(world, sys)


# ------------------------------------------------------------
# E) 成员跟队形：群主挪窝，成员跟着挪
# ------------------------------------------------------------

func _sec_pack_follow(brigand: Dictionary) -> void:
	_say("=== E) 成员跟着群主一起移动 ===")
	var world := _world()
	var sys = _make_system(world)
	# 距假玩家 900px（> 视野 640px，不会转追击），同时在 48 格活跃半径内
	var base := PLAYER_POS + Vector2(900.0, 0.0)
	var lead = _spawn_at(world, base, brigand, sys)
	var foll = _spawn_at(world, base + Vector2(400.0, 0.0), brigand, sys)
	lead.set_physics_process(false)        # 群主先钉住，单独看成员的行为
	foll.set_physics_process(false)
	_check(bool(lead.absorb_into_pack(foll)), "成员加入群主")
	_check(foll.is_pack_follower() and not lead.is_pack_follower(),
			"成员 = 跟随者；群主自己不是跟随者")

	var keep: float = lead.pack_follow_distance_px()
	var d0: float = foll.global_position.distance_to(lead.global_position)
	foll.set_physics_process(true)         # 只让成员动
	await _phys(4)
	_say("    （现场）状态=%s 群内=%d 我是群主=%s 是跟随者=%s astar=%s 休眠=%s 队形=%.0f 重算=%.2f"
			% [str(foll.state_machine.current_state.name), int(foll.pack_size()),
			str(foll.is_pack_leader()), str(foll.is_pack_follower()),
			str(foll._astar != null), str(bool(foll.get("_dormant"))),
			foll.pack_follow_distance_px(), foll.pack_repath_interval()])
	_check(foll.has_move_target(), "离群主 %.0fpx（> 队形 %.0fpx）→ 起程追赶" % [d0, keep])
	await _phys(100)
	var d1: float = foll.global_position.distance_to(lead.global_position)
	_check(d1 < d0 - 200.0, "走了一趟：与群主的距离 %.0fpx → %.0fpx" % [d0, d1])
	_check(d1 <= keep + 40.0, "跟到位后停在队形里（%.0fpx ≤ %.0fpx）" % [d1, keep + 40.0])
	await _phys(10)
	_check(not foll.has_move_target(), "跟到位后待命，不再自己选目标")
	var before: float = foll.global_position.distance_to(lead.global_position)
	_check(before <= keep + 40.0, "待命期间仍在队形内（%.0fpx）" % before)

	# 群主挪窝（这里直接搬位置，等价于它在满地图游走） → 成员重新起程
	lead.global_position += Vector2(0.0, 900.0)
	await _phys(6)
	_check(foll.has_move_target(), "群主挪了 900px → 成员重新起程")
	await _phys(40)
	var d2: float = foll.global_position.distance_to(lead.global_position)
	_check(d2 < 900.0 - 150.0, "成员朝新位置追过去了（还剩 %.0fpx）" % d2)
	await _teardown(world, sys)


# ------------------------------------------------------------
# F) 群主死亡 → 同群下一个接任
# ------------------------------------------------------------

func _sec_leader_death(brigand: Dictionary) -> void:
	_say("=== F) 群主死亡 → 接任 ===")
	var world := _world()
	var sys = _make_system(world)
	var a = _spawn_at(world, Vector2(1200.0, 1200.0), brigand, sys)
	var b = _spawn_at(world, Vector2(1300.0, 1200.0), brigand, sys)
	var c = _spawn_at(world, Vector2(1400.0, 1200.0), brigand, sys)
	for e in [a, b, c]:
		e.set_physics_process(false)
	_check(a.absorb_into_pack(b) and a.absorb_into_pack(c), "三只结成一伙")
	_check(a.pack_leader() == a and a.pack_size() == 3, "群主 A，群内 3 只")
	a.take_damage(99999)                   # 打死群主（走 _die → _leave_pack → 移交）
	_check(bool(a.get("_dying")), "群主已进入死亡结算")
	_check(b.pack_size() == 2, "群内剩 2 只（实得 %d）" % int(b.pack_size()))
	_check(b.pack_leader() == b, "按入群先后，B 接任群主")
	_check(c.pack_leader() == b, "C 也认 B 做群主（全群共用同一份字典）")
	await _teardown(world, sys)


# ------------------------------------------------------------
# G) 只跟同类：别的兵种没有 pack，靠过来也不会被收
# ------------------------------------------------------------

func _sec_same_kind_only(brigand: Dictionary, raider: Dictionary) -> void:
	_say("=== G) 只跟同类结伙 ===")
	var cfg := brigand.duplicate(true)
	_sub(cfg, "ai")["pack"]["scan_interval_seconds"] = 0.0
	var world := _world()
	var sys = _make_system(world)
	var b = _spawn_at(world, Vector2(3000.0, 3000.0), cfg, sys)
	var r = _spawn_at(world, Vector2(3080.0, 3000.0), raider, sys)
	b.set_physics_process(false)
	r.set_physics_process(false)
	_check(not r.pack_enabled() and r.pack_size() == 0, "弓手没有群（pack_dict 为空）")
	for _round in range(10):
		b._pack_scan_timer = 999.0
		b._tick_pack(0.6)
	_check(int(b.pack_size()) == 1, "旁边的弓手不算同类，劫掠者仍独自一群（实得 %d）"
			% int(b.pack_size()))
	await _teardown(world, sys)


# ------------------------------------------------------------
# H) 受到攻击 → 朝攻击者走（所有敌人通用）
# ------------------------------------------------------------

func _sec_hit_reaction(raider: Dictionary) -> void:
	_say("=== H) 受到攻击 → 朝攻击者移动 ===")
	var world := _world()
	var sys = _make_system(world)
	var e = _spawn_at(world, PLAYER_POS + Vector2(900.0, 0.0), raider, sys)
	_check(not e.can_see_player(), "起手看不见玩家（900px > 视野 640px）")
	_check(int(e.noise_alertness) == 0, "起手警觉度 0")
	e.alert_from_attacker(PLAYER_POS)
	_check(int(e.noise_alertness) == 100,
			"挨了一下 → 警觉度 = hurt(100)（实得 %d）" % int(e.noise_alertness))
	_check(e.noise_source().is_equal_approx(PLAYER_POS), "记住了攻击者的位置")
	var keep_alert := float(e.noise_alertness)
	e.alert_from_attacker(Vector2.ZERO)
	_check(is_equal_approx(float(e.noise_alertness), keep_alert),
			"传零向量 = 无效调用，不改警觉度")

	await _phys(4)
	_check(e.state_machine.current_state.name == &"investigate",
			"过阈值 → 转「调查」（实得 %s）" % str(e.state_machine.current_state.name))
	_check(e.has_move_target(), "并且真的开始寻路")
	var to_src := _path_end(e).distance_to(PLAYER_POS)
	_check(to_src < float(TILE) * 1.5, "路径终点就是攻击者所在（差 %.0fpx）" % to_src)
	var d0: float = e.global_position.distance_to(PLAYER_POS)
	await _phys(40)
	var d1: float = e.global_position.distance_to(PLAYER_POS)
	_check(d1 < d0 - 100.0, "朝攻击者走过去了：%.0fpx → %.0fpx" % [d0, d1])

	# 关掉这条反应（config 写 0）→ 挨打不动
	Config.set_override("noise.sources.hurt", 0)
	var e2 = _spawn_at(world, PLAYER_POS + Vector2(0.0, 900.0), raider, sys)
	e2.alert_from_attacker(PLAYER_POS)
	_check(int(e2.noise_alertness) == 0, "noise.sources.hurt = 0 → 挨打不再有反应")
	Config.clear_override("noise.sources.hurt")
	await _teardown(world, sys)


# ------------------------------------------------------------
# I) 对声音更敏感（劫掠者）
# ------------------------------------------------------------

func _sec_hearing(brigand: Dictionary, raider: Dictionary) -> void:
	_say("=== I) 劫掠者「对声音更敏感」 ===")
	var world := _world()
	var sys = _make_system(world)
	var hear_px := float(Config.get_value("noise.hear_radius_cells", 16.0)) * float(TILE)
	var sens := float(_sub(brigand, "ai").get("noise_sensitivity", 1.0))
	_check(is_equal_approx(hear_px, 1024.0), "普通听力半径 = %dpx" % int(hear_px))
	var far_d := hear_px * 1.2                       # 超出普通听力半径，但在劫掠者半径内

	# ① 远处：普通兵种听不到，劫掠者听得到
	var src := Vector2(2000.0, 2000.0)
	var r1 = _spawn_at(world, src + Vector2(far_d, 0.0), raider, sys)
	var b1 = _spawn_at(world, src + Vector2(-far_d, 0.0), brigand, sys)
	r1.set_physics_process(false)
	b1.set_physics_process(false)
	NoiseSystem.emit(src, 120.0)
	_check(int(r1.noise_alertness) == 0,
			"距声源 %.0fpx：普通兵种**听不到**（实得 %.1f）" % [far_d, float(r1.noise_alertness)])
	_check(float(b1.noise_alertness) > 0.0,
			"同距离：劫掠者**听得到**（实得 %.1f）" % float(b1.noise_alertness))
	r1.noise_alertness = 0.0
	b1.noise_alertness = 0.0

	# ② 同一距离：劫掠者听到的强度明显更高（衰减按放大的半径算）
	var mid_d := 512.0
	var r2 = _spawn_at(world, Vector2(2000.0, 3000.0) + Vector2(mid_d, 0.0), raider, sys)
	var b2 = _spawn_at(world, Vector2(2000.0, 3000.0) + Vector2(-mid_d, 0.0), brigand, sys)
	r2.set_physics_process(false)
	b2.set_physics_process(false)
	NoiseSystem.emit(Vector2(2000.0, 3000.0), 120.0)
	var exp_r := 120.0 * (1.0 - mid_d / hear_px)            # = 60（与旧公式一致）
	var exp_b := 120.0 * (1.0 - mid_d / (hear_px * sens))
	_check(is_equal_approx(float(r2.noise_alertness), 60.0),
			"普通兵种的收信强度仍是旧公式 %.1f（实得 %.2f）"
			% [exp_r, float(r2.noise_alertness)])
	_check(absf(float(b2.noise_alertness) - exp_b) < 1.5,
			"劫掠者的收信强度按放大半径算（期望 %.1f，实得 %.2f）"
			% [exp_b, float(b2.noise_alertness)])
	_check(float(b2.noise_alertness) > float(r2.noise_alertness) * 1.3,
			"同一距离，劫掠者听得更清：%.1f vs %.1f"
			% [float(b2.noise_alertness), float(r2.noise_alertness)])
	await _teardown(world, sys)


# ------------------------------------------------------------

func _finish() -> void:
	Config.clear_override("enemy.speed")
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_brigand_ai] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

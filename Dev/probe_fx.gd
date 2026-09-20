extends Node2D
## ============================================================
## probe_fx — 特效库 + 三级引用（2026-09-20）
##
## 守的是「配置驱动的特效管线」这一整条链，而不是某个角色的表现：
##   A) 库表自洽：fx.effects 每条都指得到真实贴图，且**贴图宽度 == frames×128**。
##      这条最值钱 —— 改了 frames 却忘了重切图，hframes 会把半格当一帧画，
##      探针当场抓住（素材由 tools/cut_fx.py 切：CELL 64 × ZOOM 2 = 128）。
##   B) 生成器行为：位置/朝向/缩放/层级照配置落位；additive 走 CanvasItemMaterial
##      （4.7 的 CanvasItem **没有** blend_mode，这是实测踩出来的）；播完自行
##      queue_free；空 id / 未知 id / fx.enabled=false 一律 null；上限硬生效。
##   C) 我方引用：武器写了 fx_attack 才出弧光，没写就不出（弓没有挥砍动作，
##      空串在这里是正确结果）；受击星芒从 combat.attack.fx_hit 回落。
##   D) 敌人 + 弹道：兵种专属 id → 空串回落到 enemy.attack.fx_attack；弹道收尾
##      的特效挂在**父节点**上（挂自己身上会同帧消失 = 一帧都看不见）。
##   E) 总开关：fx.enabled=false 时全场零生成（性能兜底 = 整条管线可摘）。
##
## 【一处刻意没断言】player.resolve_attack_hit() 里「砍中才出星芒」那一句验证不了
## —— 命中依赖 Area2D 真实重叠（hitbox.get_overlapping_areas()），无头伪造不出
## 物理服务器。所以只断言 fx_hit_id() 解析正确 + 该 id 建得出节点；调用点交给实拍图。
##
## 【计数为什么按父节点局部数】进局后场上有真敌人在挥砍，全局组计数会被它们掺和。
## 所有「刚才是不是多生成了一个」的判据都只数**生成者的父节点的直接子节点**。
##
## 顺序刻意分两段：A/B 在没有 Main 场景时跑（组里干净），C/D/E 才进局。
## ============================================================

const FX_DIR := "res://Assets/Art/Sprites/FX"
const CELL_PX := 128          # tools/cut_fx.py：CELL 64 × ZOOM 2
const PROJECTILE := "res://Scripts/combat/projectile.gd"
const ENEMY_SCRIPT := "res://Scripts/enemy.gd"
const OUT := "user://_probe_fx.txt"

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _stage: Node2D = null


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


func _fx_count() -> int:
	return EffectLibrary.active_count(get_tree())


## 只数某个父节点名下的特效 —— 进局后别处的敌人也在生成，全局数会假失败
func _fx_under(parent: Node) -> int:
	var c := 0
	for k in parent.get_children():
		if k.is_in_group(&"fx_sprite") and not k.is_queued_for_deletion():
			c += 1
	return c


## 手动把一帧帧喂进去。无头空转时真实 delta 极小，等寿命要跑上千帧，
## 还会被微冻（Engine.time_scale）掺和；直接调进程函数才是确定的。
func _tick(node: Node, seconds: float, method: StringName) -> void:
	var step := 1.0 / 60.0
	for _i in range(int(ceil(seconds / step))):
		node.call(method, step)


func _ready() -> void:
	# 测试台就是探针自己（场景根是 Node2D）。**不能**在这里 new 一个节点再
	# root.add_child()：此刻整棵树还在跑 NOTIFICATION_READY，root 处于「busy setting
	# up children」，那次 add_child 会**静默失败**，之后所有特效都生在树外 ——
	# 表现为 _ready/_process 一次没跑、hframes 还是 1、组计数永远 0（第一版就栽在这）。
	_stage = self
	await _frames(2)
	_check(_stage.is_inside_tree() and _stage.is_node_ready(), "测试台（探针自身）已入树并 ready")
	await _table()
	await _spawn_behaviour()
	await _live_run()
	_finish()


# ------------------------------------------------------------
# A：库表自洽
# ------------------------------------------------------------
func _table() -> void:
	var effects: Dictionary = Config.get_value("fx.effects", {})
	_check(effects.size() == 27, "fx.effects 有 27 条（实得 %d）" % effects.size())
	var bad_tex: Array = []
	var bad_geom: Array = []
	for id in effects.keys():
		var d: Dictionary = effects[id]
		var path := str(d.get("texture", ""))
		if path == "" or not ResourceLoader.exists(path):
			bad_tex.append("%s → %s" % [str(id), path])
			continue
		var frames := int(d.get("frames", 0))
		var fps := float(d.get("fps", 0.0))
		if frames < 2 or fps <= 0.0:
			bad_geom.append("%s frames/fps=%d/%s" % [str(id), frames, str(fps)])
			continue
		var tex: Texture2D = load(path)
		if tex == null:
			bad_geom.append("%s 贴图加载不出来" % str(id))
			continue
		# 帧数必须等于条带宽度除以格宽：hframes 靠它切帧，错了就把半格当一帧画
		if tex.get_width() != frames * CELL_PX or tex.get_height() != CELL_PX:
			bad_geom.append("%s %dx%d ≠ %d帧×%d" %
					[str(id), tex.get_width(), tex.get_height(), frames, CELL_PX])
	_check(bad_tex.is_empty(),
			"每条 texture 都存在：%s" % ["全通过" if bad_tex.is_empty() else str(bad_tex)])
	_check(bad_geom.is_empty(),
			"贴图尺寸 == frames×%d：%s" % [CELL_PX,
			"全通过" if bad_geom.is_empty() else str(bad_geom)])

	# 表里每一条都要**真建得出节点**：第二批 20 条只写了配置，没被任何实拍路径覆盖之前，
	# "存在且尺寸对" 不等于 "生成器认得它"。逐条 spawn 一次，顺手核对 hframes。
	var bad_spawn: Array = []
	# queue_free 是延迟的：循环里这 27 个都还算「在场」，不放宽上限后半截会被
	# max_simultaneous 直接拒生成，看起来像表坏了。上限本身由 B 段单独守。
	Config.set_override("fx.max_simultaneous", 64)
	for id in effects.keys():
		var s: Node2D = EffectLibrary.spawn(str(id), _stage, Vector2.ZERO)
		if s == null:
			bad_spawn.append(str(id))
		elif s.hframes != int((effects[id] as Dictionary)["frames"]):
			bad_spawn.append("%s hframes=%d" % [str(id), s.hframes])
		else:
			_tick(s, float(s.frames) / float(s.fps) + float(s.fade_out) + 0.05, &"_process")
		if s != null:
			s.queue_free()
	Config.clear_override("fx.max_simultaneous")
	await get_tree().process_frame
	_check(bad_spawn.is_empty(),
			"表里 %d 条逐条生成通过：%s" % [effects.size(),
			"全通过" if bad_spawn.is_empty() else str(bad_spawn)])
	_say("  条目：" + ", ".join(effects.keys()) + "（素材目录 " + FX_DIR + "）")


# ------------------------------------------------------------
# B：生成器行为
# ------------------------------------------------------------
func _spawn_behaviour() -> void:
	_check(_fx_count() == 0, "起始场上没有特效节点")

	# 三种「不生成」
	_check(EffectLibrary.spawn("", _stage, Vector2.ZERO) == null, "空 id → 不生成")
	_check(EffectLibrary.spawn("no_such_effect", _stage, Vector2.ZERO) == null,
			"未知 id → 不生成（同类只警告一次，不刷屏）")
	Config.set_override("fx.enabled", false)
	_check(EffectLibrary.spawn("slash_sword", _stage, Vector2.ZERO) == null,
			"fx.enabled=false → 不生成")
	Config.clear_override("fx.enabled")
	_check(_fx_count() == 0, "上面三种情况一个节点都没建出来")

	# 正常生成：配置项逐项落到节点上
	var d: Dictionary = Config.get_value("fx.effects.cast_staff", {})
	var at := Vector2(333.0, -77.0)
	var rot := 0.7
	var s: Node2D = EffectLibrary.spawn("cast_staff", _stage, at, rot)
	_check(s != null, "cast_staff 建得出节点")
	if s == null:
		return
	_check(s.is_in_group(&"fx_sprite"), "节点进了 fx_sprite 组（上限计数靠它）")
	# 贴图必须**真的挂在节点上**：第一版 spawn 只用 load 结果当"存不存在"的闸门，
	# 于是每个特效都是透明 Sprite2D —— hframes/z_index/自毁全绿，画面上什么都没有。
	# 这条是那次教训的守卫，别退回去。
	var got_tex: Texture2D = s.texture
	_check(got_tex != null
			and str(got_tex.resource_path) == str(d.get("texture", "")),
			"节点真的带上了配置里那张条带贴图（漏挂 = 画面全空）")
	_check(got_tex != null and got_tex.get_width() == int(d["frames"]) * CELL_PX
			and got_tex.get_height() == CELL_PX,
			"挂上的贴图与 hframes 切得开（%d×%d）"
			% [got_tex.get_width() if got_tex != null else 0,
				got_tex.get_height() if got_tex != null else 0])
	_check(s.hframes == int(d["frames"]), "hframes == 配置 frames（%d）" % s.hframes)
	_check(is_equal_approx(s.global_position.x, at.x)
			and is_equal_approx(s.global_position.y, at.y),
			"落位到传入坐标（%s）" % str(s.global_position))
	_check(is_equal_approx(s.rotation,
			rot + float(d.get("rot_degrees", 0.0)) * PI / 180.0),
			"朝向 = 传入角度 + 配置微调")
	_check(is_equal_approx(s.scale.x, float(d["scale"])), "缩放吃到配置（%.2f）" % s.scale.x)
	_check(s.z_index == int(d["z_index"]), "绘制层级吃到配置（%d）" % s.z_index)
	_check(s.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "像素图不过滤（NEAREST）")
	_check(s.material is CanvasItemMaterial
			and (s.material as CanvasItemMaterial).blend_mode
			== CanvasItemMaterial.BLEND_MODE_ADD,
			"additive 条目挂 CanvasItemMaterial 的 ADD（CanvasItem 本身没有 blend_mode）")
	var p: Node2D = EffectLibrary.spawn("puff_dust", _stage, Vector2.ZERO)
	_check(p != null and p.material == null, "additive=false 的条目不挂材质")
	# 顺手把它跑到寿终：留着会污染后面「组计数归零」和「上限=3」两条判据
	_tick(p, float(p.frames) / float(p.fps) + float(p.fade_out) + 0.1, &"_process")
	_check(p.is_queued_for_deletion(), "非 additive 条目同样会自行回收")
	p.queue_free()
	await _frames(2)

	# 播完自行消失
	var life := float(s.frames) / float(s.fps) + float(s.fade_out)
	_tick(s, life * 0.5, &"_process")
	_check(s.frame > 0 and s.frame < s.frames,
			"半程时停在中间帧（%d/%d）" % [s.frame, s.frames])
	_check(not s.is_queued_for_deletion(), "半程时还活着")
	_tick(s, life * 0.6, &"_process")
	_check(s.frame == s.frames - 1, "播到最后一帧停住（%d）" % s.frame)
	_check(s.is_queued_for_deletion(), "寿命到了自己排队删除")
	await _frames(3)
	_check(_fx_count() == 0, "特效全部回收，组计数归零")

	# 并发上限：只数「这一批调用返没返回节点」，不去猜场上有什么
	Config.set_override("fx.max_simultaneous", 3)
	var born := 0
	for i in range(8):
		if EffectLibrary.spawn("spark_hit", _stage, Vector2(i * 8.0, 0.0)) != null:
			born += 1
	Config.clear_override("fx.max_simultaneous")
	_check(born == 3, "fx.max_simultaneous=3 → 8 次调用只生成 3 个（实得 %d）" % born)
	for n in get_tree().get_nodes_in_group(&"fx_sprite"):
		(n as Node).queue_free()
	await _frames(3)
	_check(_fx_count() == 0, "清场后组内无残留")


# ------------------------------------------------------------
# C + D + E：进局后的三级引用
# ------------------------------------------------------------
func _live_run() -> void:
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	main._enter_run()
	await _frames(30)

	var player: Node = get_tree().get_first_node_in_group("player")
	_check(player != null, "局内有角色")
	if player != null:
		_weapons(player)
	_enemies()
	_projectile()
	if player != null:
		_global_off(player)
	await _frames(2)


## 武器 → 出手弧光。武器没写 fx_attack 就不出：弓本就没有挥砍动作。
func _weapons(player: Node) -> void:
	var expect := {"sword": "slash_sword", "spear": "thrust_spear",
			"staff": "cast_staff", "bow": ""}
	for wid in expect.keys():
		player.set("current_weapon", StringName(wid))
		var got := str(player.call("fx_attack_id"))
		_check(got == str(expect[wid]),
				"%s 出手弧光 =「%s」（实得「%s」）" % [wid, str(expect[wid]), got])
	player.set("current_weapon", &"sword")
	_check(str(player.call("fx_attack_id")) == "slash_sword",
			"切回 sword 后弧光仍是 slash_sword（回落链没串台）")

	## 命中星芒：第二批给三把近战各写了自己的 fx_hit，弓**故意不写**
	## （它没有近战判定帧，命中特效挂在弹道的 fx_impact 上），
	## 所以它才是「回落到 combat.attack.fx_hit」这条链的活样本。
	var expect_hit := {"sword": "hit_sword", "spear": "hit_pierce",
			"staff": "hit_holy", "bow": "spark_hit"}
	for wid in expect_hit.keys():
		player.set("current_weapon", StringName(wid))
		var got := str(player.call("fx_hit_id"))
		_check(got == str(expect_hit[wid]),
				"%s 命中特效 =「%s」（实得「%s」）" % [wid, str(expect_hit[wid]), got])
	player.set("current_weapon", &"sword")

	# 弧光落在「朝向前方半个射程」，朝向跟 facing —— 武器与特效唯一的几何耦合
	var p0: Vector2 = player.get("global_position")
	var facing: Vector2 = player.get("facing")
	var host: Node = player.get_parent()
	var before := _fx_under(host)
	var arc: Node2D = player.call("spawn_attack_fx")
	_check(arc != null and _fx_under(host) == before + 1, "近战真的建出了弧光节点")
	if arc != null:
		var want := p0 + facing * float(player.call("attack_param", "range_px", 120.0)) * 0.5
		_check(arc.global_position.distance_to(want) < 1.0,
				"弧光在朝向前方半个射程处（偏差 %.2f）" % arc.global_position.distance_to(want))
		_check(is_equal_approx(arc.rotation, facing.angle()), "弧光朝向 = facing")
		arc.queue_free()


func _enemies() -> void:
	var types: Array = Config.get_value("enemy_types.types", [])
	var by_id := {}
	for t in types:
		by_id[str((t as Dictionary).get("id", ""))] = t
	var default_fx := str(Config.get_value("enemy.attack.fx_attack", ""))
	_check(default_fx == "slash_claw", "敌人通用出手特效默认 slash_claw")

	## 兵种专属优先，写空串（或压根没这个键）才回落到通用值。
	## 临时实例调 _apply_numeric 就够：那一段刻意写在 `if _body == null: return`
	## 之前，无 Body 也算得出来 —— 这正是探针能跑的前提。
	## 第二批之后 21 个兵种全都有专属 id，所以这里改成**全覆盖**：
	## 接线写错（拼错 id）在运行时是「静默不出特效」，实拍很难发现，靠这里兜。
	var expect := {
		"ep_bear": "slash_claw", "ep_cave": "bash_rock", "ep_lizard": "slash_tail",
		"ep_snake": "slash_bite", "ep_spider": "spit_web", "ep_turtle": "slam_ring",
		"ep_hex_shaman": "cast_hex", "ep_pig": "burst_charge", "ep_pig_rider": "slash_sabre",
		"ep_spear_goblin": "thrust_spear", "ep_torch_goblin": "spark_arrow",
		"ep_bomb_fish": "splash_bomb", "ep_harpoon_shark": "thrust_harpoon",
		"ep_paddle_shark": "sweep_fin", "ep_gnoll": "slash_rend", "ep_gnome": "shred_bolt",
		"ep_minotaur": "slash_claw", "ep_panda": "slam_paw", "ep_skull": "spike_bone",
		"ep_thief": "slash_shadow", "ep_troll": "slash_claw",
	}
	var effects: Dictionary = Config.get_value("fx.effects", {})
	var unknown: Array = []
	for tid in expect.keys():
		if not effects.has(str(expect[tid])):
			unknown.append("%s → %s" % [tid, str(expect[tid])])
	_check(unknown.is_empty(),
			"21 个兵种接的 id 全在 fx.effects 表里：%s"
			% ["全通过" if unknown.is_empty() else str(unknown)])

	for tid in expect.keys():
		var cfg = by_id.get(tid, null)
		if cfg == null:
			_check(false, "config 里有兵种 %s" % tid)
			continue
		var e: Node = load(ENEMY_SCRIPT).new()
		_stage.add_child(e)
		e.call("_apply_numeric", cfg)
		var got := str(e.get("_fx_attack"))
		_check(got == str(expect[tid]),
				"%s 出手特效 = %s（实得 %s）" % [tid, str(expect[tid]), got])
		e.queue_free()

	# 回落链还得活着：现在没有兵种留空，所以拿一份真配置抹掉 fx_attack 来验。
	var probe_cfg: Dictionary = (by_id.get("ep_bear", {}) as Dictionary).duplicate(true)
	probe_cfg.erase("fx_attack")
	if not probe_cfg.is_empty():
		var e2: Node = load(ENEMY_SCRIPT).new()
		_stage.add_child(e2)
		e2.call("_apply_numeric", probe_cfg)
		_check(str(e2.get("_fx_attack")) == default_fx,
				"兵种不写 fx_attack → 回落到 enemy.attack.fx_attack（实得 %s）"
				% str(e2.get("_fx_attack")))
		e2.queue_free()
	await _frames(3)

	var live: Array = []
	for n in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(n) and str(n.get("_fx_attack")) != "":
			live.append(n)
	if live.is_empty():
		_say("  (场上没有可读兵种特效的敌人，跳过 _start_attack 生成断言)")
		return
	var e0: Node = live[0]
	var host: Node = e0.get_parent()
	var base := _fx_under(host)
	e0.call("_start_attack")
	_check(_fx_under(host) == base + 1,
			"敌人出手那一帧生成 1 个弧光（前 %d 后 %d）" % [base, _fx_under(host)])
	for k in host.get_children():
		if k.is_in_group(&"fx_sprite"):
			(k as Node).queue_free()


## 弹道： setup 收下命中/落空两种 id；飞满射程时把落空特效挂在**父节点**上。
func _projectile() -> void:
	var cfg: Dictionary = Config.get_value("combat.weapons.bow.projectile", {})
	_check(str(cfg.get("fx_impact", "")) == "hit_arrow"
			and str(cfg.get("fx_miss", "")) == "puff_dust",
			"弓的弹道配置带了命中/落空两种特效")
	var p: Node2D = load(PROJECTILE).new()
	_stage.add_child(p)
	p.global_position = Vector2(4000.0, 4000.0)     # 甩到地图外，路上不会有任何目标
	p.call("setup", cfg, Vector2.RIGHT, 20, [], 16)
	_check(str(p.get("_fx_impact")) == "hit_arrow"
			and str(p.get("_fx_miss")) == "puff_dust",
			"setup 把两种特效 id 收到了弹道上")
	var base := _fx_under(_stage)
	_tick(p, float(cfg.get("max_distance_px", 640.0)) / float(cfg.get("speed", 900.0)) + 0.2,
			&"_physics_process")
	_check(_fx_under(_stage) == base + 1,
			"射程耗尽 → 落点出特效（前 %d 后 %d）" % [base, _fx_under(_stage)])
	var last: Node = null
	for k in _stage.get_children():
		if k.is_in_group(&"fx_sprite") and k != p:
			last = k
	_check(last != null and int((last as Sprite2D).hframes)
			== int(Config.get_value("fx.effects.puff_dust.frames", -1)),
			"落点特效用的就是 puff_dust 那条配置")
	# 关键：弹道本身已经排队删除，特效必须还活着（挂自己身上会跟着一起没了）
	_check(p.is_queued_for_deletion() and last != null and not last.is_queued_for_deletion(),
			"弹道消失后特效独立存活")


func _global_off(player: Node) -> void:
	Config.set_override("fx.enabled", false)
	var base := _fx_count()
	for wid in ["sword", "spear", "staff"]:
		player.set("current_weapon", StringName(wid))
		player.call("spawn_attack_fx")
	for id in ["spark_hit", "slash_claw", "cast_hex", "puff_dust"]:
		EffectLibrary.spawn(id, _stage, Vector2.ZERO)
	_check(_fx_count() == base, "fx.enabled=false → 一次都没生成")
	Config.clear_override("fx.enabled")
	for n in get_tree().get_nodes_in_group(&"fx_sprite"):
		(n as Node).queue_free()


func _finish() -> void:
	_say("")
	_say("通过 %d / %d" % [_n - _fails.size(), _n])
	for f in _fails:
		_say("  FAIL: " + str(f))
	var fa := FileAccess.open(OUT, FileAccess.WRITE)
	if fa != null:
		fa.store_string("\n".join(_lines))
	for l in _lines:
		print(str(l))
	print("[FxProbe] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

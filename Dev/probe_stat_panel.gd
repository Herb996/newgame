extends Node
## ============================================================
## probe_stat_panel — 局内右侧「数值调试」栏：改完到底生没生效（headless）
##
## 跑法：python tools/run_probe.py _probe_stat_panel.log res://Dev/probe_stat_panel.tscn
##
## 这块面板的全部卖点就是"立即"两个字，而"立即"在本项目里其实是三种完全不同的东西
## （见 debug_stat_panel.gd 文件头）：
##   A 每次现算  → 改配置下一帧就是新值，**不需要**任何通知
##   B 开局缓存  → 必须走各单位脚本的 refresh_debug_stats()，面板负责通知
##   C 生成期    → 本局看不到，只有 ↺ 标记这一个承诺
## 探针就按这三类逐条钉死。特别注意 A 与 B 要**成对**断言：
## B 类若哪天变成"不通知也生效"（说明有人把它改成现算了），面板上的 ↻ 标记就是错的；
## A 类若哪天变成"不通知就不生效"（说明有人加了缓存），玩家就会调了数值看不到变化。
##
## 面板的私有方法一律用 call() 打：_panel 声明成 CanvasLayer 才能读 .visible，
## 而静态类型下 Node/CanvasLayer 里没写的方法直接点出来是编译错误。
##
## ⚠ 会写 user://save.json（出击），开跑备份、收尾原样还原。
## ⚠ 兵种表（enemy_types.types / animal_types.types）改的是**内存里那份 _data**，
##   断言的基线必须在开跑前按**值**快照，拿引用当基线就是拿改动后的自己比自己。
## ============================================================

const OUT := "user://_probe_stat_panel.txt"
const SAVE_PATH := "user://save.json"
const ENEMY_SCENE := preload("res://Scenes/Enemy.tscn")
const ENEMY_TABLE := "enemy_types.types"
const ANIMAL_TABLE := "animal_types.types"
const F9 := 4194340        # KEY_F9 的物理键码；config 的 debug.stat_panel_key 就该存这个

var _lines: Array = []
var _n := 0
var _fails: Array = []

var _save_backup := ""
var _save_existed := false

var _main: Node = null
var _panel: CanvasLayer = null
var _p = null            # 真实 Player（故意不写类型：下面要按名字取成员/方法）
var _e = null            # 真实 Enemy
var _a = null            # 真实 Animal
var _orig: Dictionary = {}
## 出厂标量基线（点路径 -> 值）：验「改完再还原」之后 _data 本身仍是原值
var _orig_base: Dictionary = {}
## 开跑前的 user://settings.json 快照（整棵序列化）：面板只准写内存层
var _user_json := ""
var _tile := 64


func _say(s: String) -> void:
	_lines.append(s)
	print("[Probe] " + s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	if not ok:
		_fails.append(msg)
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	print("[Probe]   %s %s" % ["OK  " if ok else "FAIL", msg])


func _near(a: float, b: float, eps: float = 0.01) -> bool:
	return absf(a - b) <= eps


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


## 等某一组成员出现（刷怪是渐进的，不能假设出击当帧就有敌人）
func _wait_group(g: String, want: int, guard: int = 600) -> Array:
	var out: Array = []
	for _i in range(guard):
		await get_tree().process_frame
		out.clear()
		for q in get_tree().get_nodes_in_group(g):
			if is_instance_valid(q):
				out.append(q)
		if out.size() >= want:
			return out
	return out


func _live_player() -> Node:
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q) and not bool(q.call("is_dead")):
			return q
	return null


# ------------------------------------------------------------
# 兵种表工具
# ------------------------------------------------------------

func _arr(path: String) -> Array:
	var v = Config.get_value(path, [])
	return v if v is Array else []


func _type_index(table: String, id: String) -> int:
	var arr := _arr(table)
	for i in range(arr.size()):
		if arr[i] is Dictionary and str((arr[i] as Dictionary).get("id", "")) == id:
			return i
	return -1


func _elem(table: String, i: int) -> Dictionary:
	var arr := _arr(table)
	if i < 0 or i >= arr.size() or not (arr[i] is Dictionary):
		return {}
	return arr[i] as Dictionary


## 快照出厂值（取的是**当前**值，所以必须在任何面板改动之前调用）
func _snap(table: String, i: int, keys: Array) -> void:
	var el := _elem(table, i)
	for k in keys:
		_orig["%s#%d.%s" % [table, i, str(k)]] = el.get(str(k), null)


func _snap_ok(table: String, i: int, keys: Array) -> bool:
	var el := _elem(table, i)
	for k in keys:
		var want = _orig["%s#%d.%s" % [table, i, str(k)]]
		var got = el.get(str(k), null)
		if typeof(want) == TYPE_FLOAT or typeof(got) == TYPE_FLOAT:
			if not _near(float(want), float(got)):
				return false
		elif want != got:
			return false
	return true


func _spec_path(path: String) -> Dictionary:
	return {"label": "探针项", "path": path}


func _spec_table(table: String, i: int, key: String) -> Dictionary:
	return {"label": "探针项", "table": table, "index": i, "key": key}


## 走面板的写入口（而不是自己 set_override）：这样连"写完自动通知在场单位"一起验了
func _panel_write(spec: Dictionary, v: float) -> void:
	_panel.call("_write", spec, v)


func _panel_read(spec: Dictionary, d) -> Variant:
	return _panel.call("_read", spec, d)


# ------------------------------------------------------------

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()
	_user_json = JSON.stringify(Config.user_settings())

	# 探针自己负责出击：压掉「启动即进局」，免得白生成一张图、场上多一名抢断言的默认角色
	Config.set_override("debug.auto_enter_run", false)
	# 刷怪数量压到能验事的量级（这一项本身就是 ↺ 类：出击时才读，所以必须在进局前改）
	Config.set_override("enemy.count", 6)
	Config.set_override("animals.count", 3)
	# 敌人真会围殴：无敌帧拉到天上，后面所有断言才不会因为角色中途阵亡失去对象。
	# （这同时是 A 类的一个例子 —— 现读现算，不需要任何重算钩子。）
	Config.set_override("combat.player.invincible_after_hit_seconds", 9999.0)

	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child(_main)
	await _frames(30)

	_panel = get_tree().get_first_node_in_group("debug_stat_panel")
	_say("--- S1 挂载 / 快捷键 / 布局 ---")
	_check(_panel != null, "面板随 Main 自动挂上（debug 包闸门通过）")
	if _panel == null:
		_say("!! 面板没挂上，后面全部跳过")
		_finish()
		return

	_main.call("_on_launch", [{"id": "spearman", "name": "枪手"}])
	var waited := 0
	while _live_player() == null and waited < 600:
		await get_tree().process_frame
		waited += 1
	_p = _live_player()
	_check(_p != null, "出击成功，拿到真实角色")
	if _p != null:
		_tile = int(_p.get("_tile_size"))
	# 出厂基线：必须在任何面板改动之前取（get_base_value 读的就是 _data 那棵树本身）
	_orig_base = {
		"enemy.attack.cooldown_seconds": Config.get_base_value("enemy.attack.cooldown_seconds", 1.0),
		"combat.attack.range_px": Config.get_base_value("combat.attack.range_px", 120.0),
	}
	if _p != null:
		var wid0 := str(_p.get("current_weapon"))
		if wid0 != "":
			_orig_base["weapon_damage"] = Config.get_base_value(
					"combat.weapons.%s.damage" % wid0, 26)

	var enemies := await _wait_group("enemies", 1)
	var animals := await _wait_group("animals", 1)
	_e = enemies[0] if not enemies.is_empty() else null
	_a = animals[0] if not animals.is_empty() else null
	_check(_e != null, "场上有真实敌人（面板的敌人段有对象）")
	_check(_a != null, "场上有真实中立生物（面板的生物段有对象）")
	if _e != null:
		_snap(ENEMY_TABLE, _type_index(ENEMY_TABLE, str(_e.get("type_id"))),
				["hp", "damage", "speed_mult", "attack_range_px"])
	if _a != null:
		_snap(ANIMAL_TABLE, _type_index(ANIMAL_TABLE, str(_a.get("type_id"))), ["hp"])

	await _s1_hotkey()
	if _p != null:
		await _s2_live(_p)
		await _s3_cached_player(_p)
	if _e != null:
		await _s4_cached_enemy(_e)
	if _a != null:
		await _s5_cached_animal(_a)
	await _s6_dirty_and_users()
	await _s7_readout()
	await _s8_restore()
	await _s9_shot()
	_finish()


# ------------------------------------------------------------
# S9 窗口实拍（只在真窗口下跑：headless 截出来是 64x64）
# ------------------------------------------------------------

func _s9_shot() -> void:
	if DisplayServer.get_name() == "headless":
		_say("--- S9 窗口实拍：headless 跳过（改用 --window 跑本探针）---")
		return
	var docks := get_tree().get_nodes_in_group("debug_dock")
	if docks.is_empty():
		return
	var dock: Control = docks[0] as Control
	var vp := get_viewport().get_visible_rect().size
	var bar := float(UiKit.menu_bar_height(vp.y))
	var r := dock.get_global_rect()
	_say("--- S9 窗口实拍：视口 %s｜栏 %s｜菜单栏顶 %f ---" % [str(vp), str(r), vp.y - bar])
	if not _panel.visible:
		_panel.call("toggle")
	# 改两项再拍：让"已改"的琥珀色与 ↻ 标记出现在同一张图里
	if _p != null:
		_panel_write(_spec_path("player.speed"), 300.0)
	if _e != null:
		var i := _type_index(ENEMY_TABLE, String(_e.get("type_id")))
		if i >= 0:
			_panel_write(_spec_table(ENEMY_TABLE, i, "hp"), 200.0)
	# 滚回顶部：动态节点名是 @ScrollContainer@2663 这种，按名字 find_child 找不到，
	# 从 _list 往上认父。
	var lst: Node = _panel.get("_list")
	if lst != null and (lst.get_parent() as ScrollContainer) != null:
		(lst.get_parent() as ScrollContainer).scroll_vertical = 0
	for i in range(6):
		await RenderingServer.frame_post_draw
	var dir := "C:/Users/Administrator/WorkBuddy/2026-09-20-stat-panel"
	DirAccess.make_dir_recursive_absolute(dir)
	var img := get_viewport().get_texture().get_image()
	var p := dir + "/stat_panel_run.png"
	_check(img.save_png(p) == OK, "局内实拍已存：%s（%s）" % [p, str(img.get_size())])
	_panel.call("_reset_everything")
	for i in range(3):
		await RenderingServer.frame_post_draw


# ------------------------------------------------------------
# S1 开关与几何
# ------------------------------------------------------------

func _s1_hotkey() -> void:
	_check(int(_panel.call("toggle_key")) == F9,
			"快捷键 = F9（物理键码 %d，出厂 %s）" % [F9,
			str(Config.get_value("debug.stat_panel_key", -1))])
	_check(not _panel.visible, "出厂默认关着（不干扰正常游玩）")
	var ev := InputEventKey.new()
	ev.physical_keycode = F9
	ev.pressed = true
	_panel.call("_input", ev)
	_check(_panel.visible, "按一次 F9 → 面板打开（_build 跑通）")
	_panel.call("_input", ev)
	_check(not _panel.visible, "再按一次 F9 → 关闭")
	_panel.call("toggle")
	await _frames(4)

	var docks := get_tree().get_nodes_in_group("debug_dock")
	_check(docks.size() == 1, "栏体在 debug_dock 组里（camera_controller 据此豁免边缘滚屏）")
	if docks.size() == 0:
		return
	var dock: Control = docks[0] as Control
	_check(dock.mouse_filter == Control.MOUSE_FILTER_STOP,
			"栏体 mouse_filter=STOP（在栏里拖滑块不会顺手给世界下移动令）")
	var vp := get_viewport().get_visible_rect().size
	# ⚠ 面板脚本的常量在 4.7 里读不到（GDScript 没有 constant_definitions），
	# 所以这条宽度写死在探针里：改了 DOCK_W 没同步这里 → 直接报红，逼两边对齐。
	var w := 272.0    # 见上一行注释：与面板 DOCK_W 手动对齐
	var rect := dock.get_combined_minimum_size()
	_check(rect.x <= w + 2.0,
			"栏体最小宽度 %f ≤ DOCK_W %f（超了就会被内容撑出右锚，栏越画越宽）" % [rect.x, w])
	if rect.x > w + 2.0:
		for l in _widest(dock, 6):
			_say("  ·· 撑宽者：" + str(l))
	var g := dock.get_global_rect()
	# headless 下视口只有 64x64：绝对位置量不出真机布局，别把"量不到"当成"量错了"
	if vp.x < 400.0 or vp.y < 300.0:
		_say("  ·· 视口 %s 不是真实尺寸，跳过绝对位置断言（窗口实拍另测）" % str(vp))
		return
	var bar := float(UiKit.menu_bar_height(vp.y))
	_check(_near(g.end.x, vp.x - 6.0, 1.0),
			"贴右缘：栏右 %f = 视口宽 %f - 6" % [g.end.x, vp.x])
	_check(_near(g.size.x, w, 2.0), "栏宽 %f = DOCK_W %f" % [g.size.x, w])
	_check(g.position.y >= 0.0 and g.position.x > 0.0, "整块在视口内：%s" % str(g))
	_check(g.end.y <= vp.y - bar + 1.0,
			"不压住常驻菜单栏：栏底 %f ≤ 菜单栏顶 %f（视口高 %f，菜单高 %f）" \
					% [g.end.y, vp.y - bar, vp.y, bar])


## 找出把容器撑宽的前 n 个后代（按最小宽度排）—— 栏宽不对时靠这个点名，别猜
func _widest(root: Node, n: int) -> Array:
	var rows: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n1 = stack.pop_back()
		for c in (n1 as Node).get_children():
			stack.append(c)
			if c is Control:
				var ms: Vector2 = (c as Control).get_combined_minimum_size()
				rows.append({"w": ms.x, "path": _short_path(c), "hint": _what(c)})
	rows.sort_custom(func(a, b): return float(a["w"]) > float(b["w"]))
	var out: Array = []
	for i in range(mini(n, rows.size())):
		out.append("%6.0fpx %s %s" % [float(rows[i]["w"]), str(rows[i]["path"]),
				str(rows[i]["hint"])])
	return out


func _short_path(c: Node) -> String:
	var parts: Array = []
	var n: Node = c
	while n != null and n.name != "":
		parts.push_front(n.name)
		n = n.get_parent()
	return "/".join(parts)


func _what(c: Control) -> String:
	if c is Label:
		return "Label「%s」" % str((c as Label).text).left(24)
	if c is Button:
		return "Button「%s」" % str((c as Button).text).left(24)
	if c is SpinBox:
		return "SpinBox"
	return c.get_class()


# ------------------------------------------------------------
# S2 A 类：现算 —— 改配置**不通知**也立刻生效
# ------------------------------------------------------------

func _s2_live(p) -> void:
	_say("--- S2 A 类（每次现算，不需要通知）---")
	var w: Dictionary = p.call("weapon_data")
	var wid := str(p.get("current_weapon"))
	var dmg_path := "combat.attack.damage"
	if wid != "" and w.has("damage"):
		dmg_path = "combat.weapons.%s.damage" % wid
	var before_dmg := float(p.call("attack_param", "damage", 25.0))
	Config.set_override(dmg_path, 999)
	_check(_near(float(p.call("attack_param", "damage", 25.0)), 999.0),
			"伤害 %f → 999 立刻生效（路径 %s，全程没调用任何重算）" % [before_dmg, dmg_path])
	_check(_near(float(p.call("trait_damage", 100.0)),
			100.0 + float(p.call("trait_flat", "attack")) - float(p.call("supply_penalty", "attack"))),
			"trait_damage 走的是现算链（基础值跟着配置走）")
	Config.clear_override(dmg_path)
	_check(_near(float(p.call("attack_param", "damage", 25.0)), before_dmg, 0.02),
			"清掉覆盖 → 伤害回到 %f（现算类没有残留）" % before_dmg)

	var ts := float(_tile)
	var before_vis := float(p.call("vision_px"))
	Config.set_override("player.vision_radius_cells", 3)
	var want_vis := 3.0 * ts + float(p.call("trait_flat", "vision")) \
			- float(p.call("supply_penalty", "vision"))
	_check(_near(float(p.call("vision_px")), want_vis),
			"视野 %f → %f（3 格 × %d px）立刻生效" % [before_vis, want_vis, int(ts)])
	Config.clear_override("player.vision_radius_cells")

	if _e != null:
		var spd_path := "enemy.speed"
		var mult := float(_e.get("speed_mult"))
		Config.set_override(spd_path, 700)
		_check(_near(float(_e.call("patrol_speed")), 700.0 * mult),
				"敌人游速现算：patrol_speed() = 700 × 兵种倍率 %f" % mult)
		Config.clear_override(spd_path)
	# ↺ 生成期的实证：数量只在进局前读一次，所以场上敌人永远不超过出击前覆盖的 6
	_check(get_tree().get_nodes_in_group("enemies").size() <= 6,
			"刷怪数量 = 出击前覆盖的 6（本局没再读配置：↺ 类只能重出击）")


# ------------------------------------------------------------
# S3 B 类（玩家）：开局缓存 —— 不通知就不生效，通知了就生效
# ------------------------------------------------------------

func _s3_cached_player(p) -> void:
	_say("--- S3 B 类：玩家缓存项 ---")
	# 先证明它真的是缓存：裸改配置、不通知 → 成员纹丝不动
	Config.set_override("player.speed", 333)
	_check(not _near(float(p.get("speed")), 333.0),
			"移速确实是开局缓存：裸改配置后 p.speed 仍是 %f（面板因此标 ↻）" % float(p.get("speed")))
	_panel.call("refresh_live_units")
	_check(_near(float(p.get("speed")), 333.0),
			"refresh_live_units() → 在场角色移速重算成 333")
	Config.clear_override("player.speed")

	# 走面板写入口：改完应当"同一次调用里"就已是新值
	var spec := _spec_path("player.speed")
	_panel_write(spec, 111.0)
	_check(_near(float(p.get("speed")), 111.0), "面板改移速 111 → 当场 p.speed=111")
	_check(_near(float(_panel_read(spec, 0.0)), 111.0), "面板读回同一条路径也是 111")
	_panel.call("_reset_one", spec)
	_check(_near(float(p.get("speed")), float(Config.get_value("player.speed", 640.0)), 0.5),
			"单行还原 → 移速回到本机生效值 %f（出厂 640 会被 settings.json 盖住）" \
					% float(Config.get_value("player.speed", 640.0)))

	# 生命上限：出厂那条会被养成那条**整个顶替**（compute_max_hp 的语义），面板两行都列
	var meta_stat := float(Meta.get_stat("survival.max_hp"))
	Config.set_override("combat.player.max_hp", 555)
	_panel.call("refresh_live_units")
	if meta_stat > 0.0:
		_check(not _near(float(p.get("max_hp")), 555.0),
				"已知坑：养成值 %f>0 顶替出厂 max_hp → 调 combat.player.max_hp 不动血上限" % meta_stat)
	else:
		_check(_near(float(p.get("max_hp")), 555.0), "养成未启用 → 出厂 max_hp 直接生效")
	Config.clear_override("combat.player.max_hp")

	var spec_hp := _spec_path("meta_progression.survival.max_hp.base")
	var bonus := int(round(float(p.call("trait_flat", "hp"))))
	# 养成值 = base + per_level × 已购等级：面板改的是 base，已买的那几级照样保留
	var grown := int(round(float(Config.get_value("meta_progression.survival.max_hp.per_level", 0.0)) \
			* float(Meta.get_upgrade_level("survival.max_hp"))))
	p.set("hp", 1)
	_panel_write(spec_hp, 555.0)
	_check(int(p.get("max_hp")) == 555 + grown + bonus,
			"面板改「生命上限 养成」base=555 → max_hp=%d（=555+已购等级 %d+气血特性 %d）" \
					% [int(p.get("max_hp")), grown, bonus])
	_check(int(p.get("hp")) == int(p.get("max_hp")),
			"上限变了 → 当前血量自动回满（用户 2026-09-20 定）：HP %d/%d" \
					% [int(p.get("hp")), int(p.get("max_hp"))])
	# 上限没变时不白送血：手动把血灌到超过上限，重算只夹住
	p.set("hp", 99999)
	_panel_write(spec_hp, 555.0)
	_check(int(p.get("hp")) == int(p.get("max_hp")),
			"上限没变 → 只夹溢出、不额外回血（HP %d ≤ %d）" % [int(p.get("hp")), int(p.get("max_hp"))])
	_panel.call("_reset_one", spec_hp)
	_check(int(p.get("max_hp")) == int(meta_stat) + bonus,
			"还原「生命上限 养成」→ max_hp 回到 %d" % int(p.get("max_hp")))

	# 近战判定圆：半径是写进 CollisionShape 的缓存，必须重算
	var rng_spec := _spec_path("combat.attack.range_px")
	var wid := str(p.get("current_weapon"))
	var w: Dictionary = p.call("weapon_data")
	var range_path := "combat.attack.range_px"
	if wid != "" and w.has("range_px"):
		range_path = "combat.weapons.%s.range_px" % wid
	rng_spec = _spec_path(range_path)
	_panel_write(rng_spec, 400.0)
	var hb: Node = p.get("hitbox")
	if hb != null and String(p.call("attack_kind")) == "melee":
		var shape: Shape2D = hb.get_node("CollisionShape2D").get("shape")
		var want_r := minf(400.0 + float(p.call("_range_bonus")), float(p.call("vision_px")))
		_check(_near(float(shape.get("radius")), want_r, 0.5),
				"近战判定圆半径跟着射程重算：%f = min(射程 400, 视野 %f)" % [
				float(shape.get("radius")), float(p.call("vision_px"))])
	else:
		_say("  ·· 当前武器非近战或无 hitbox，跳过判定圆断言")
	_panel.call("_reset_one", rng_spec)


# ------------------------------------------------------------
# S4 B 类（敌人）：兵种数值 + AI 缓存 + 新生成的怪
# ------------------------------------------------------------

func _s4_cached_enemy(e) -> void:
	_say("--- S4 B 类：敌人 ---")
	var tid := String(e.get("type_id"))
	var idx := _type_index(ENEMY_TABLE, tid)
	_check(idx >= 0, "敌人兵种 %s 在 %s 里找得到（索引 %d）" % [tid, ENEMY_TABLE, idx])
	if idx < 0:
		return

	# 兵种表走"直接改共用的那个字典"：在场怪 + 之后新刷的怪都读同一份
	var hp_spec := _spec_table(ENEMY_TABLE, idx, "hp")
	_panel_write(hp_spec, 321.0)
	_check(int(e.get("max_hp")) == 321, "改兵种 hp 321 → 在场敌人 max_hp 当场变 321")
	_check(int(e.get("hp")) == 321, "敌人同样遵守「上限变了就回满」")
	var shared := _elem(ENEMY_TABLE, idx)
	_check(int(shared.get("hp", 0)) == 321, "改的是类型字典本身（EnemySystem 抽样池与 _type_cfg 共用引用）")

	# 生成期那一面：用**同一份**兵种字典现造一只怪，出生就该是新数值
	var fresh = ENEMY_SCENE.instantiate()
	(e.get_parent() as Node2D).add_child(fresh)
	fresh.call("setup", e.get("_walls"), _tile, e.get("_astar"), shared, {}, e.get("_system"))
	_check(int(fresh.get("max_hp")) == 321,
			"新刷的怪按新兵种数值出生（max_hp=%d，无需通知）" % int(fresh.get("max_hp")))
	fresh.queue_free()

	var cd_spec := _spec_path("enemy.attack.cooldown_seconds")
	_panel_write(cd_spec, 0.25)
	_check(_near(float(e.get("_attack_cd_seconds")), 0.25),
			"敌人出手冷却 ↻：0.25s 当场写进成员")
	_panel.call("_reset_one", cd_spec)

	# _ai_cache 是"拿到兵种配置后定稿一次"的合并缓存 —— 面板必须作废它
	var sens_path := "enemy.ai.noise_sensitivity"
	var before_sens := float(e.call("noise_sensitivity"))
	Config.set_override(sens_path, 5.0)
	_check(_near(float(e.call("noise_sensitivity")), before_sens),
			"听力倍率确实被 _ai_cache 挡住：不重算就仍是 %f（↻ 标记不是装饰）" % before_sens)
	_panel.call("refresh_live_units")
	_check(_near(float(e.call("noise_sensitivity")), 5.0),
			"refresh_debug_stats 作废 _ai_cache → 读到 5.0")
	Config.clear_override(sens_path)
	_panel.call("refresh_live_units")
	_check(_near(float(e.call("noise_sensitivity")), before_sens),
			"清掉覆盖后回到 %f" % before_sens)

	# 兵种射程（有的兵种没写这个键 → 只验写了的，否则断言的是回落链）
	if shared.has("attack_range_px"):
		var rspec := _spec_table(ENEMY_TABLE, idx, "attack_range_px")
		_panel_write(rspec, 99.0)
		_check(_near(float(e.get("_attack_range")), 99.0), "兵种射程 ↻：99px 当场生效")
		_panel.call("_reset_one", rspec)
	else:
		_say("  ·· 兵种 %s 没写 attack_range_px，射程行本轮不验（走全局回落）" % tid)


# ------------------------------------------------------------
# S5 B 类（生物）
# ------------------------------------------------------------

func _s5_cached_animal(a) -> void:
	_say("--- S5 B 类：中立生物 ---")
	var idx := _type_index(ANIMAL_TABLE, String(a.get("type_id")))
	_check(idx >= 0, "生物兵种在 %s 里找得到" % ANIMAL_TABLE)
	if idx < 0:
		return
	a.set("hp", 1)
	var spec := _spec_table(ANIMAL_TABLE, idx, "hp")
	_panel_write(spec, 77.0)
	_check(int(a.get("max_hp")) == 77 and int(a.get("hp")) == 77,
			"羊 hp 77 → 当场 max_hp/HP 都是 77（生物缓存的只有 max_hp）")
	_panel.call("_reset_one", spec)
	_check(int(a.get("max_hp")) == int(_orig["%s#%d.hp" % [ANIMAL_TABLE, idx]]),
			"还原 → 羊回到出厂 hp %d" % int(a.get("max_hp")))
	# 羊身上没有 damage / _attack_range：面板的汇总读数必须按成员存在与否拼
	_panel.call("_refresh_live")


# ------------------------------------------------------------
# S6 脏标记：面板绝不能碰持久层
# ------------------------------------------------------------

func _s6_dirty_and_users() -> void:
	_say("--- S6 覆盖层归属 ---")
	_panel_write(_spec_path("player.speed"), 222.0)
	var spec_hp := _spec_path("meta_progression.survival.max_hp.base")
	_panel_write(spec_hp, 300.0)
	_check(bool(Config.has_override("player.speed")), "has_override 认得点路径")
	var paths: Array = Config.override_paths()
	_check(paths.has("player.speed") and paths.has("meta_progression.survival.max_hp.base"),
			"override_paths() 列出全部改动：%s" % str(paths))
	_check(JSON.stringify(Config.user_settings()) == _user_json,
			"面板没动用户层：settings.json 那棵树一个字节都没变（写的是内存覆盖层）")
	_check(bool(_panel.call("_is_dirty", _spec_path("player.speed"))),
			"_is_dirty：覆盖层项标「已改」")
	var hp_idx := _type_index(ENEMY_TABLE, String(_e.get("type_id"))) if _e != null else -1
	if hp_idx >= 0:
		var ts := _spec_table(ENEMY_TABLE, hp_idx, "hp")
		_panel_write(ts, 411.0)
		_check(bool(_panel.call("_is_dirty", ts)), "_is_dirty：兵种表项按快照认「已改」")
		_panel.call("_reset_one", ts)
		_check(not bool(_panel.call("_is_dirty", ts)), "单行还原后不再标脏")
	var st: Label = _panel.get("_status")
	var st_txt := "(没有状态条)" if st == null else str(st.text)
	_check(st != null and st_txt.find("已改") == 0, "顶部状态条在计数：%s" % st_txt)
	_panel.call("_print_changes")


# ------------------------------------------------------------
# S7 在场读数（这段跑在 _process 里，一崩就是整段空白）
# ------------------------------------------------------------

func _s7_readout() -> void:
	_say("--- S7 在场单位读数 ---")
	_panel.call("_refresh_live")
	await _frames(2)
	var labels: Array = _panel.get("_live_labels")
	_check(labels.size() >= 3, "读数行建出来了（%d 行）" % labels.size())
	var text := ""
	for l in labels:
		text += str((l as Label).text) + "\n"
	_check(text.contains("HP") and text.contains("伤"),
			"角色行有 HP 与伤害拆解：%s" % text.replace("\n", " / "))
	# 折行护栏：第一次实拍就是肉眼才发现"射程 52"被劈到下一行 —— 那种事断言全绿也会发生
	var tall: Array = []
	for l in labels:
		var lb := l as Label
		if lb == null or not lb.visible:
			continue
		var r := lb.get_global_rect()
		if r.size.y > 22.0:
			tall.append("%.0fpx高「%s」" % [r.size.y, lb.text.left(20)])
	_check(tall.is_empty(), "没有一条读数被折成两行（折行 = 文案比栏宽长）：%s" % str(tall))
	if _e != null:
		_check(text.contains("敌"), "敌人按兵种汇总了一行")
	if _a != null:
		_check(text.contains("兽"), "生物按兵种汇总了一行（羊没有 damage/射程，靠成员存在判断拼）")
	# 折叠/重建整棵行表别炸
	_panel.call("_rebuild_rows")
	_check(_panel.get("_list") != null, "整表重建后行容器仍在")
	var all := get_tree().get_nodes_in_group("debug_dock")
	_check(all.size() == 1, "重建没有留下第二块栏体（旧节点是 queue_free，不当帧计数）")


# ------------------------------------------------------------
# S8 全部还原
# ------------------------------------------------------------

func _s8_restore() -> void:
	_say("--- S8 全部还原 ---")
	_panel.call("_reset_everything")
	await _frames(2)
	_check(Config.override_paths().is_empty(), "覆盖层清空：%s" % str(Config.override_paths()))
	_check((_panel.get("_type_edits") as Dictionary).is_empty(), "兵种表快照表清空")
	if _e != null:
		var idx := _type_index(ENEMY_TABLE, String(_e.get("type_id")))
		_check(_snap_ok(ENEMY_TABLE, idx, ["hp", "damage", "speed_mult", "attack_range_px"]),
				"敌人兵种表逐键回到出厂值")
		_check(int(_e.get("max_hp")) == int(_orig["%s#%d.hp" % [ENEMY_TABLE, idx]]),
				"在场敌人跟着还原成 %d" % int(_e.get("max_hp")))
	if _a != null:
		var aidx := _type_index(ANIMAL_TABLE, String(_a.get("type_id")))
		_check(_snap_ok(ANIMAL_TABLE, aidx, ["hp"]), "生物兵种表回到出厂值")
	if _p != null:
		# 还原只回退**覆盖层**：本机用户设置（settings.json）里的值本来就该赢，
		# 面板不许越过它 —— 期望值因此是"生效值"而不是 Data/config.json 的出厂值。
		_check(_near(float(_p.get("speed")), float(Config.get_value("player.speed", 640.0)), 0.5),
				"角色移速回到本机生效值 %f（出厂 640，用户层可覆盖）" \
						% float(Config.get_value("player.speed", 640.0)))
		_check(int(_p.get("max_hp")) >= 1, "角色仍有合法血上限：%d" % int(_p.get("max_hp")))
	_check(JSON.stringify(Config.user_settings()) == _user_json,
			"整场调试没写用户层：settings.json 树未变")
	_check(not Config.override_paths().has("enemy.attack"),
			"clear_override 剪掉了被掏空的中间字典（否则「已改 N 项」会虚报）")
	# 出厂层必须一个字都没动：三层深合并曾经把高层的值直接写回 _data 的子字典
	# （子字典是引用），那样 clear_override 也救不回出厂值 —— 「全部还原」就成了假话。
	for key in _orig_base.keys():
		var k := str(key)
		var path := k
		if k == "weapon_damage":
			if _p == null:
				continue
			path = "combat.weapons.%s.damage" % str(_p.get("current_weapon"))
		_check(float(Config.get_base_value(path, 0.0)) == float(_orig_base[key]),
				"出厂层没被写脏：%s 仍是 %s" % [path, str(_orig_base[key])])
	# _reset_everything 把探针自己的开跑覆盖也清了 → 补回来，免得收尾被敌人围殴
	Config.set_override("combat.player.invincible_after_hit_seconds", 9999.0)


# ------------------------------------------------------------
# 存档备份 / 收尾
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
			return
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))


func _finish() -> void:
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	Config.clear_overrides()
	_restore_save()
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[Probe] 写出 %s" % OUT)
	get_tree().quit(0 if _fails.is_empty() else 1)

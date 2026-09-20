extends Node
## ============================================================
## shot_fx — 实拍：每个角色出手时画面上到底有没有特效（2026-09-20）
##
## 探针（probe_fx）证明的是**链路与配置自洽**：id 解析对、节点建得出、贴图尺寸
## 对得上、播完会自毁。它证明不了"这一帧在屏幕上看得见" —— 层级被地面盖住、
## 加性混合在无头下看不出、弧光偏出画面，探针全是绿的而画面是空的。
## 这张图专门补这一段（也是 probe_fx 唯一没断言的那句：近战命中才出的星芒，
## 依赖 Area2D 真实重叠，无头伪造不出来，只能在真窗口里看到）。
##
## 判据写法：**不猜时间**，逐帧轮询场上 fx_sprite 组，等"想要的那条特效"真的
## 存在、并且条带播到中段（第 0 帧往往还没张开）才截。所以图里没有 = 真没有，
## 而不是截早了。
##
## 拍四把武器 + 十八个敌人兵种（第二批后每个兵种都有专属特效）：
##   sword/spear/staff → 各自的出手弧光 + 各自的命中星芒（fx_hit）
##   bow               → 弹道命中点（projectile.fx_impact）
##   ENEMY_SHOTS       → 兵种专属出手特效
##
## 用法（**必须开窗**，无头是 dummy 驱动、viewport 贴图恒空）：
##   python tools/run_probe.py _shot_fx.log Dev/shot_fx.tscn --window
##
## ⚠ 会走一次 _on_launch，开跑备份 user://save.json、收尾原样还原。
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const SAVE_PATH := "user://save.json"
const WEAPONS := ["sword", "spear", "staff", "bow"]
## 要拍的兵种出手。第二批之后 21 个兵种全都有专属 id，这里列 18 条不同的形状
## （牛头人/巨魔故意共用熊的爪痕，是同一张条带，不必再拍一遍）
const ENEMY_SHOTS := [
	"ep_spear_goblin", "ep_hex_shaman", "ep_bear",
	"ep_snake", "ep_spider", "ep_turtle", "ep_pig", "ep_pig_rider",
	"ep_bomb_fish", "ep_harpoon_shark", "ep_paddle_shark", "ep_gnoll",
	"ep_gnome", "ep_panda", "ep_skull", "ep_thief", "ep_lizard", "ep_cave",
]

var _save_backup := ""
var _save_existed := false
var _n := 0
var _player: Node = null
## 裁图中心跟谁：我方那几张跟角色，敌人那几张必须跟**出手的那只**，
## 否则图正中被玩家占着，敌人和它的弧光挤在边上看不清。
var _focus: Node2D = null
## 非 INF 时把角色钉在这个世界坐标上（敌方阶段用），让镜头稳住不动
var _pin := Vector2.INF
var _missed: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()
	Config.set_override("display.window_mode", "windowed")
	Config.set_override("display.resolution", [1280, 720])
	Config.set_override("debug.auto_enter_run", false)
	Config.set_override("camera.edge_pan_enabled", false)
	Config.set_override("animals.count", 0)

	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	main.set("_no_fog", true)          # 雾层 z=5 会把地面压黑，特效本来就该拍本体
	add_child(main)
	await _frames(30)
	main.call("_on_launch", [{"id": "spearman", "name": "独行"}])
	var waited := 0
	while get_tree().get_nodes_in_group("player").is_empty() and waited < 600:
		await get_tree().process_frame
		waited += 1
	await _frames(60)

	_player = get_tree().get_first_node_in_group("player")
	if _player == null:
		print("[ShotFx] !! 出击后没有角色")
		_finish(1)
		return
	var pool := _pick_pool()
	if pool.is_empty():
		print("[ShotFx] !! 场上没有可当靶子的敌人")
		_finish(1)
		return
	print("[ShotFx] 靶子池：%s" % str(pool.keys()))

	await _weapons_phase(pool)
	await _enemies_phase(pool)

	print("[ShotFx] 共出图 %d 张；缺失 %s" % [_n, "无" if _missed.is_empty() else str(_missed)])
	_finish(0 if _missed.is_empty() else 3)


# ------------------------------------------------------------
# 我方：五把武器
# ------------------------------------------------------------
func _weapons_phase(pool: Dictionary) -> void:
	# 自检先打一遍：特效不出 = 整组图作废，所以先证明"库开着、id 解析得到、
	# 直接调一次生成得出来"，再看实战那一帧有没有出现。
	var direct: Node2D = _player.call("spawn_attack_fx")
	print("[ShotFx] 自检 enabled=%s has(slash_sword)=%s id=%s 直接生成=%s" % [
			str(EffectLibrary.enabled()), str(EffectLibrary.has("slash_sword")),
			str(_player.call("fx_attack_id")), str(direct != null)])
	if direct != null:
		direct.queue_free()
	for wid in WEAPONS:
		if not is_instance_valid(_player):
			print("[ShotFx] !! 角色已离场，停止拍摄")
			return
		_keep_alive()
		if not bool(_player.call("switch_weapon", StringName(wid))):
			_missed.append("%s（武器切换失败）" % wid)
			continue
		_player.set_auto_attack(true)
		_focus = _player as Node2D
		var kind := str(_player.call("attack_kind"))
		var arc := str(Config.get_value("combat.weapons.%s.fx_attack" % wid, ""))
		var target: Node2D = _fresh_target(pool, "ep_bear")
		if target == null:
			_missed.append("%s（没有靶子）" % wid)
			continue
		# 远程靶子站近一点：命中点要在裁图里（射程 640 的 0.45 = 288px 已经出框）
		var frac := 0.55 if kind == "melee" else 0.28
		_stand_in_front(target, frac)
		await _frames(12)                  # 让索敌锁定、起手跑到判定帧
		print("[ShotFx] ---- %s（%s，射程 %.0f）----" % [wid, kind,
				float(_player.call("effective_attack_range_px"))])
		if arc != "":
			var a := await _wait_fx(arc, 240, _player as Node2D)
			if a == null:
				_missed.append("%s 出手弧光 %s" % [wid, arc])
			else:
				print("[ShotFx]   弧光 %s：帧 %d/%d，位置 %s，朝向 %.2f" % [arc,
						int(a.get("frame")), int(a.get("frames")),
						str((a as Node2D).global_position), (a as Node2D).rotation])
				await _shot("fx_%s" % wid, a as Node2D)
		else:
			print("[ShotFx]   %s 无出手弧光（远程，命中才出特效）" % wid)
		# 命中那一记：三把近战各有自己的 fx_hit（没写才回落到 combat.attack.fx_hit），
		# 弓是弹道命中点的 projectile.fx_impact
		var spark := str(Config.get_value("combat.weapons.%s.fx_hit" % wid, ""))
		if spark == "":
			spark = str(Config.get_value("combat.attack.fx_hit", ""))
		if wid == "bow":
			spark = str(Config.get_value(
					"combat.weapons.bow.projectile.fx_impact", ""))
		var h := await _wait_fx(spark, 300, target)
		if h == null:
			_missed.append("%s 命中特效 %s" % [wid, spark])
		else:
			print("[ShotFx]   命中 %s：帧 %d/%d，位置 %s" % [spark,
					int(h.get("frame")), int(h.get("frames")),
					str((h as Node2D).global_position)])
			await _shot("fx_%s_hit" % wid, h as Node2D)


# ------------------------------------------------------------
# 敌方：挑几个写了专属特效的兵种
# ------------------------------------------------------------
func _enemies_phase(pool: Dictionary) -> void:
	_player.set_auto_attack(false)        # 玩家别还手，否则靶子还没出手就被打死
	# 玩家身上还挂着上一阶段（自动普攻追靶子）的移动指令 —— 不清掉的话整段敌方拍摄
	# 期间角色一直往西溜，镜头插值跟在后面，敌人出手那一下早就在画面外了。
	_player.call("stop_moving")
	_player.call("clear_move_target")
	_pin = (_player as Node2D).global_position
	for tid in ENEMY_SHOTS:
		var got: Node = null
		var fx_id := ""
		for attempt in 2:              # 兵种不出手是随机的：一只 420 帧不挥砍就换一只再来
			var e: Node2D = _live_in(pool, tid)
			if e == null:
				print("[ShotFx]   场上没有活的 %s，跳过" % tid)
				break
			_focus = e
			fx_id = str(e.get("_fx_attack"))
			if fx_id == "":
				_missed.append("%s 没解析出兵种特效" % tid)
				break
			# 贴到它自己射程的 0.7 倍处：进射程即出手，与分离层互不干扰
			e.global_position = _player.global_position + Vector2(
					float(e.call("attack_range_px")) * 0.7, 0.0)
			e.set("hp", 999999)
			await _frames(10)
			if attempt == 0:
				print("[ShotFx] ---- %s（兵种特效 %s，射程 %.0f）----" % [tid, fx_id,
						float(e.call("attack_range_px"))])
			# near 传**玩家**不是那只敌人：镜头跟着玩家，特效离玩家一远就根本不在
			# 画面上（ep_bear 那张投影到 x=-393，裁出来只能是一片草地）。兵种进
			# 射程才出手，所以"离玩家一臂之内"本身就是"它砍的这一下"。
			# 半径按该兵种自己的射程算：第一批全是 52px 的近战，写死 140 够用；
			# 射程远的兵种出手点落在 射程×0.7 + 射程×0.6 处，140 会把正主筛掉。
			var rng := float(e.call("attack_range_px"))
			got = await _wait_fx(fx_id, 420, _player as Node2D, maxf(140.0, rng * 1.6))
			if got != null:
				break
		if got == null:
			if fx_id != "":
				_missed.append("%s 出手特效 %s" % [tid, fx_id])
			continue
		print("[ShotFx]   出手 %s：帧 %d/%d，位置 %s，朝向 %.2f" % [fx_id,
				int(got.get("frame")), int(got.get("frames")),
				str((got as Node2D).global_position), (got as Node2D).rotation])
		await _shot("fx_enemy_%s" % tid, got as Node2D)


# ------------------------------------------------------------
# 工具
# ------------------------------------------------------------

## 场上每个兵种留一只当靶子（够拍就行），其余全部挪出场外 —— 不然 250 只一起
## 挥砍，裁出来的 480x480 里全是别人的弧光，分不清谁是谁。
func _pick_pool() -> Dictionary:
	var pool := {}
	for e in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e) or bool(e.get("_dying")):
			continue
		var tid := str(e.get("type_id"))
		if not pool.has(tid):
			pool[tid] = e
	# 只把要当靶子的几只登记进池子。**其余敌人一律不动**：把 249 只挪到 12000px 外
	# 会被刷怪系统的离场判定直接回收，池子里的对象半路变成已释放实例（第一版就崩在这）。
	# 不当靶子的本来就散在全图，离玩家远 → 不出手，也就不会在裁出来的小图里抢戏。
	var out := {}
	for t in ENEMY_SHOTS:
		if pool.has(t):
			out[t] = pool[t]
	if not out.has("ep_bear"):
		for e in get_tree().get_nodes_in_group("enemies"):
			if is_instance_valid(e) and not out.values().has(e):
				out["ep_bear"] = e
				break
	for e in out.values():
		e.set("max_hp", 999999)
		e.set("hp", 999999)
	return out


func _fresh_target(pool: Dictionary, prefer: String) -> Node2D:
	var t = pool.get(prefer, null)
	if t == null or not is_instance_valid(t):
		for k in pool.keys():
			if is_instance_valid(pool[k]):
				return pool[k]
		return null
	return t


## 靶子站到玩家正右方射程的 frac 处：朝向恒为 +X，弧光朝右，画面最好认
func _stand_in_front(t: Node2D, frac: float) -> void:
	var r: float = float(_player.call("effective_attack_range_px")) * frac
	t.global_position = _player.global_position + Vector2(maxf(r, 30.0), 0.0)
	t.set("hp", 999999)


## 拍摄期间角色必须死不了：一屏特效要等上千帧，被打死一次整组图就断在半路。
## 顺带把位置钉住：只在 _enemies_phase 开头 stop_moving 一次是不够的 —— 整段里
## 角色一直在往西溜，镜头插值落后，裁图中心从 x=509 一路漂到 x=-77（后一半直接出框）。
## 钉在 _pin 上，镜头就稳了；_pin 为 INF 表示不钉（我方阶段要追着靶子打，不能钉）。
func _keep_alive() -> void:
	if not is_instance_valid(_player):
		return
	_player.set("hp", int(_player.get("max_hp")))
	if _pin != Vector2.INF:
		_player.call("stop_moving")
		_player.call("clear_move_target")
		(_player as Node2D).global_position = _pin


## 池子里那只代表可能已经死了/被回收 —— 现场从 enemies 组里另找一只同兵种的
func _live_in(pool: Dictionary, tid: String) -> Node2D:
	var e = pool.get(tid, null)
	if e != null and is_instance_valid(e) and not bool(e.get("_dying")):
		return e
	for n in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(n) or str(n.get("type_id")) != tid:
			continue
		if bool(n.get("_dying")):
			continue
		n.set("max_hp", 999999)
		n.set("hp", 999999)
		pool[tid] = n
		return n
	return null


## 场上该 id 的一个活特效节点（自检用）
func _fx_last(id: String) -> Node:
	for n in get_tree().get_nodes_in_group(&"fx_sprite"):
		if is_instance_valid(n) and _fx_tag(n) == id:
			return n
	return null


func _fx_tag(n: Node) -> String:
	var tex = n.get("texture")
	if tex == null:
		return "?"
	return str((tex as Texture2D).resource_path.get_file().get_basename())


## 逐帧等"想要的特效真的在屏幕上"，并且播到条带中段才返回。
## 返回 null = 超时都没出现 —— 这才是真缺失，不是截早了。
func _wait_fx(id: String, max_frames: int, near: Node2D = null, radius: float = 140.0) -> Node:
	var seen := {}          # 轮询期间场上真实出现过的特效条带名 → 次数
	for _i in range(max_frames):
		await get_tree().physics_frame
		_keep_alive()       # 一场拍摄要等上千帧，不每帧奶一口的话角色先被打死了
		for n in get_tree().get_nodes_in_group(&"fx_sprite"):
			if not is_instance_valid(n) or n.is_queued_for_deletion():
				continue
			var tag := _fx_tag(n)
			seen[tag] = int(seen.get(tag, 0)) + 1
			if tag != id:
				continue
			# 只认"出手那只身上的"那条：全图几百只都在挥砍，按条带名匹配会抓到
			# 地图另一头的一记，裁图中心跟着它飞到空地上（ep_bear 那张全空就是这么来的）。
			if near != null and is_instance_valid(near) \
					and (n as Node2D).global_position.distance_to(near.global_position) > radius:
				continue
			# 22%% 而不是 30%%：条带里"形状最完整"的那几张全在最前段（月牙弧第 3 帧、
			# 星芒第 3 帧张得最开），到第 5~7 帧已经卷成一团星尘。截在中段=拍到收尾。
			var want_frame: int = int(round(float(n.get("frames")) * 0.22))
			# 只接受"还在可读窗口里"的那条。上一版只卡下限，于是抓到过一条已经播到
			# 13/14 帧的 cast_staff —— 图上交出来是一片淡尾影，等于没拍到。
			if int(n.get("frame")) > want_frame + 2:
				continue
			var g := 0
			var ok := false
			while g < 60:
				if not is_instance_valid(n) or n.is_queued_for_deletion():
					break
				var f := int(n.get("frame"))
				if f > want_frame + 2:
					break               # 等过头了，这条作废，继续扫下一条
				if f >= want_frame:
					ok = true
					break
				await get_tree().physics_frame
				_keep_alive()
				g += 1
			if ok:
				return n
	print("[ShotFx] !! %d 帧内没等到「%s」；期间场上出现过的条带 = %s" % [
			max_frames, id, str(seen)])
	return null


## 以「刚等到的那条特效」为中心裁 560x560
func _shot(tag: String, anchor: Node2D = null) -> void:
	_n += 1
	var a: Node2D = anchor
	if a == null and _focus != null and is_instance_valid(_focus):
		a = _focus
	## 先把锚点的世界坐标**抄成数**，之后一律用这个数，不再碰节点。
	## 第二批的条带只有 7~12 帧（0.3 秒不到），等镜头那十几帧里它早就 queue_free
	## 完了。上一版在 await 之后还写 `a is CanvasItem` —— 对已释放实例求值是脚本
	## 错误，整个 _shot 静默中断，18 张里丢了 14 张，而日志上只看得到"出手"那一行。
	var at := Vector2.ZERO
	var has_at := false
	if a != null and is_instance_valid(a):
		at = (a as Node2D).global_position
		has_at = true
	# 先等镜头把锚点送到画面里再截：整组图要跑上千帧，角色这期间一直在往西走，
	# 镜头是插值跟的，截早了锚点投影还在画面外（ep_bear 那张 x=-186 就是这么来的）。
	# 只要求"在屏幕上"（40px 边距），不要求"离边 300px"：720 高的视口里后者只剩
	# 120px 的可用横带，于是常把 12 次重试全烧光 —— 0.2 秒过去，第二批那些 7~14 帧
	# 的短条带早播完了，交出来一张收尾残影（fx_sword_hit 那张就是这么废的）。
	# 锚点偏一点不要紧：下面的裁图框自己会夹到画面内。
	# 先判后等：上一版每轮开头无条件 await，于是最省也要多烧 1~4 帧。第二批的条带
	# 只有 9 帧 / 0.21 秒（hit_sword），等完再看画面早已是收尾残影——日志写着抓到
	# 第 4 帧，实际截到的是第 8 帧。常态（锚点本来就在屏内）必须当帧就截。
	var settled := false
	var c := Vector2.ZERO
	for _s in range(4):
		var vp := get_viewport()
		if vp == null:
			break
		if not has_at:
			settled = true
			break
		c = vp.get_canvas_transform() * at
		var vs := vp.get_visible_rect().size
		if c.x > 40.0 and c.x < vs.x - 40.0 and c.y > 40.0 and c.y < vs.y - 40.0:
			settled = true
			break
		await RenderingServer.frame_post_draw
		_keep_alive()
	if not settled:
		print("[ShotFx] !! %s 锚点迟迟没进画面，硬截" % tag)
	var im := get_viewport().get_texture().get_image()
	if im == null:
		print("[ShotFx] !! viewport 贴图为空（忘了 --window？）")
		return
	var src := im.duplicate() as Image
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	var w := src.get_width()
	var h := src.get_height()
	# 裁图中心跟**刚等到的那条特效**，不跟角色：敌人那几张里出手的兵种没有叫 Body
	# 的子节点，跟角色 = 落回画面正中 = 敌人和它的弧光全在框外。
	if not has_at:
		c = Vector2(w * 0.5, h * 0.5)
	var half := 280
	var box := Rect2i(int(c.x) - half, int(c.y) - half, half * 2, half * 2)
	box.position.x = clampi(box.position.x, 0, maxi(w - 8, 0))
	box.position.y = clampi(box.position.y, 0, maxi(h - 8, 0))
	box.size.x = mini(box.size.x, w - box.position.x)
	box.size.y = mini(box.size.y, h - box.position.y)
	var out := Image.create(box.size.x, box.size.y, false, Image.FORMAT_RGBA8)
	out.blit_rect(src, box, Vector2i.ZERO)
	var path := "%s/%s.png" % [OUT_DIR, tag]
	var err := out.save_png(path)
	var live: Array = []
	for n in get_tree().get_nodes_in_group(&"fx_sprite"):
		if is_instance_valid(n):
			live.append("%s#%d" % [_fx_tag(n), int(n.get("frame"))])
	print("[ShotFx] %s -> %s err=%d 裁图心=(%.0f,%.0f) 锚点世界=%s 场上特效=%s" % [
			tag, path, err, c.x, c.y, str(at) if has_at else "-", str(live)])


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _finish(code: int) -> void:
	_restore_save()
	get_tree().quit(code)


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

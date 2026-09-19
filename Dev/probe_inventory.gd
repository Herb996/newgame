extends Node
## ============================================================
## probe_inventory — 背包「一人一份」全套验收
##
## 2026-09-19 用户定：每个角色一个背包，右键人物 → 他头顶弹出，底部菜单栏同步。
## 三条配套规则同样是用户定的：物资**各吃各的**、拾取归**走进范围的那个人**、
## 阵亡**当场撒成一地**。这里逐条验死，防止以后改回去还没人发现。
##
## 验九段（headless 可跑）：
##   A) 一人一本：甲加东西不动乙的账；全队总账 = 各人相加
##   B) 容量按人：甲满格拒收新种类，乙照样收；已有种类照旧无限叠加
##   C) 各吃各的：同一轮消耗甲扣到、乙扣不到 → 只有乙掉属性
##   D) 补上立刻还原：乙捡到食物当帧恢复，甲全程不受牵连
##   E) 拾取归属：范围内两人 → 最近的那个拿；只有一人够得着 → 他拿；
##      满包拒收 → 资源点留在原地，腾出格子后自动重试成功
##   F) 右键弹窗：开 / 直接换人 / 再点收起 / 点面板不穿透 / ESC 收起 /
##      空地右键返回 false（不抢 Player 的「右键=取消指令」）/
##      面板夹在视口与菜单栏之间、始终在头顶、跟着人走
##   G) 菜单栏同步：弹窗开着 → 明细行点名「背包（弓兵）」；关了回到被指挥的人
##   H) 阵亡撒地：包清空 + 原地长出资源点 + 队友走上去捡得回 + 本局继续 + 弹窗自动收起
##   I) 结算归属：全队倒下 died 分文不入仓（东西留在地上）；撤离才把各人背包合并入库
##
## ⚠ 会写 user://save.json（出击/撤离入库），开跑备份、收尾原样还原。
## ⚠ 出击名单故意不带 uid：那是「没有名册身份」的临时角色（player.on_death 里
##   写明 roster_uid==0 不做除名），探针里把人打死不会动玩家的真名册。
## ============================================================

const OUT := "user://_probe_inventory.txt"
const SAVE_PATH := "user://save.json"
const LOOT_SCENE := "res://Scenes/LootNode.tscn"

var _lines: Array = []
var _n := 0
var _fails: Array = []

var _save_backup := ""
var _save_existed := false

var _main: Node = null
var _surv: Node = null
var _run: Node = null
var _hud: Node = null
var _menu: Node = null
var _popup: Control = null
var _world: Node = null
var _players: Array = []

var _sig_hits := 0        # inventory_changed 触发次数（信号该按人各发一次）


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


func _pframes(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame


## 等 player 组成员稳定（连续 15 帧不变）后返回存活角色列表
func _settle_players() -> Array:
	var prev: Dictionary = {}
	var stable := 0
	for _guard in range(400):
		await get_tree().process_frame
		var cur := {}
		for q in get_tree().get_nodes_in_group("player"):
			cur[q.get_instance_id()] = q
		if cur == prev:
			stable += 1
			if stable >= 15:
				break
		else:
			stable = 0
			prev = cur
	var out: Array = []
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q) and not bool(q.is_dead()):
			out.append(q)
	return out


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()

	# 探针自己负责出击：把「启动即进局」压掉，免得先白生成一张图、
	# 场上还多出一名抢断言的默认角色
	Config.set_override("debug.auto_enter_run", false)
	# 关刷怪：本探针要等几十个 tick + 上百帧，有敌人会在断言中途把角色打死
	Config.set_override("enemy.count", 0)

	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child(_main)
	await _frames(30)

	# 双人出击（甲=枪手，乙=弓兵）：一人一份背包这件事，单人根本验不出来
	_main.call("_on_launch", [{"id": "spearman", "name": "枪手"},
			{"id": "archer", "name": "弓兵"}])
	var waited := 0
	while get_tree().get_nodes_in_group("player").size() < 2 and waited < 400:
		await get_tree().process_frame
		waited += 1
	_players = await _settle_players()
	_run = get_tree().get_first_node_in_group("run_manager")
	_surv = get_tree().get_first_node_in_group("survival_system")
	_menu = get_tree().get_first_node_in_group("menu_bar")
	_popup = get_tree().get_first_node_in_group("inventory_popup")
	_hud = _main.get_node_or_null("HUD")
	if not _players.is_empty():
		_world = _players[0].get_parent()

	_say("--- 前置 ---")
	_check(_players.size() == 2, "出击后拿到 %d 名存活角色（一人一份背包的前提）"
			% _players.size())
	_check(_run != null and int(_run.state) == int(_run.State.RUNNING), "RunManager 在 RUNNING")
	_check(_surv != null, "场景里有 SurvivalSystem")
	_check(_popup != null, "HUD 建出了背包弹窗（group inventory_popup）")
	_check(_menu != null and _hud != null, "找得到菜单栏与 HUD（同步展示的两处）")
	if _players.size() < 2 or _run == null or _surv == null or _popup == null:
		_finish()
		return

	_clear_hostiles()
	# 自动 tick 会让断言飘：倒计时顶到跑不完，全部由探针手动驱动
	_surv.set("next_meal_in", 9999.0)
	_players[0].inventory_changed.connect(_on_inv_changed)
	_players[1].inventory_changed.connect(_on_inv_changed)

	await _a_ownership()
	await _b_capacity()
	await _c_each_eats_own()
	await _d_recover()
	await _e_pickup_owner()
	await _f_popup()
	await _g_menu_bar_sync()
	await _h_death_drops()
	await _i_settlement()

	_finish()


func _on_inv_changed() -> void:
	_sig_hits += 1


# ------------------------------------------------------------
# A) 一人一本
# ------------------------------------------------------------
func _a_ownership() -> void:
	_say("--- A 段：每人一份，互不干扰 ---")
	_reset()
	var a: Node = _players[0]
	var b: Node = _players[1]
	_sig_hits = 0

	_check(bool(a.add_item("wood", 5)), "甲往自己背包放木头成功")
	_check(int(a.item_count("wood")) == 5, "甲身上 wood=5")
	_check(int(b.item_count("wood")) == 0, "乙身上 wood=0：甲的账没串到乙头上")
	_check(bool(b.inventory.is_empty()), "乙的背包仍然是空的（不是共享同一本）")
	b.add_item("stone", 7)
	_check(int(a.item_count("wood")) == 5 and int(a.item_count("stone")) == 0,
			"乙加石头不动甲（甲 %s）" % str(a.inventory))
	var total: Dictionary = _run.total_loot()
	_check(int(total.get("wood", 0)) == 5 and int(total.get("stone", 0)) == 7,
			"全队总账 = 各人相加（%s）" % str(total))
	_check(_sig_hits == 2, "inventory_changed 按人各发一次（实得 %d 次）" % _sig_hits)


# ------------------------------------------------------------
# B) 容量按人
# ------------------------------------------------------------
func _b_capacity() -> void:
	_say("--- B 段：格子按人算 ---")
	_reset()
	var a: Node = _players[0]
	var b: Node = _players[1]
	var saved = _run.player_stats.get("survival.backpack_capacity", null)
	_run.player_stats["survival.backpack_capacity"] = 2      # 局外养成那条注入路径

	_check(int(a.backpack_capacity()) == 2 and int(b.backpack_capacity()) == 2,
			"两人各享 2 格（甲 %d / 乙 %d）" % [a.backpack_capacity(), b.backpack_capacity()])
	_check(bool(a.add_item("wood", 1)) and bool(a.add_item("stone", 1)), "甲收满 2 种")
	_check(not bool(a.add_item("iron", 1)), "第 3 种被拒：甲格子已满")
	_check(bool(a.add_item("wood", 9)), "已有种类照样叠加（满格不挡叠数量）")
	_check(int(a.item_count("wood")) == 10, "叠加后 wood=10（实得 %d）" % a.item_count("wood"))
	_check(b.inventory.is_empty() and bool(b.add_item("iron", 1)),
			"同一种铁，乙空包收得进 —— 满不满是各人的事")
	if saved == null:
		_run.player_stats.erase("survival.backpack_capacity")
	else:
		_run.player_stats["survival.backpack_capacity"] = saved
	var back := int(saved) if saved != null \
			else int(Config.get_value("meta_progression.survival.backpack_capacity.base", 10))
	_check(int(a.backpack_capacity()) == back,
			"容量恢复原值 %d（实得 %d，缺配置时回落养成 base）" % [back, a.backpack_capacity()])
	_check(bool(a.add_item("oil", 1)), "恢复后甲能收第 3 种")


# ------------------------------------------------------------
# C) 各吃各的
# ------------------------------------------------------------
func _c_each_eats_own() -> void:
	_say("--- C 段：每分钟消耗各吃各的 ---")
	_reset()
	var a: Node = _players[0]
	var b: Node = _players[1]
	var e: Dictionary = (_surv._supplies()[0] as Dictionary)
	var id := str(e.get("id", ""))
	var need := int(e.get("per_meal", 1))
	var want: Dictionary = e.get("shortage_debuff", {})

	a.add_item(id, need + 3)     # 甲有存货，乙两手空空
	_check(bool(_surv.shortages.is_empty()), "消耗前无人短缺")
	var a_dmg := float(a.trait_damage(100.0))
	var a_speed := float(a.speed)
	var b_dmg := float(b.trait_damage(100.0))
	var b_speed := float(b.speed)

	_surv._consume_tick()

	_check(int(a.item_count(id)) == need + 2, "甲从**自己**包里扣走 %d 份（剩 %d）"
			% [need, a.item_count(id)])
	_check(_surv.shortage_ids(a).is_empty(), "甲不缺（shortage_ids(甲)=%s）"
			% str(_surv.shortage_ids(a)))
	_check(bool(_surv.shortage_ids(b).has(id)), "乙缺 %s（shortage_ids(乙)=%s）"
			% [id, str(_surv.shortage_ids(b))])
	_check(bool(_surv.is_short(b)) and not bool(_surv.is_short(a)),
			"is_short 只认乙：甲 %s / 乙 %s" % [str(_surv.is_short(a)), str(_surv.is_short(b))])
	_check(bool(_surv.starving), "有人缺 → 全队级 starving=true（HUD 标红靠它）")
	_check((a.supply_penalties as Dictionary).is_empty(),
			"甲的扣减表是空的（实得 %s）—— 队友饿不着他" % str(a.supply_penalties))
	_check(not (b.supply_penalties as Dictionary).is_empty(),
			"乙拿到扣减表：%s" % str(b.supply_penalties))
	var merged_ok := true
	for k in want.keys():
		if int(round(float(b.supply_penalties.get(k, 0)))) != int(round(float(want[k]))):
			merged_ok = false
	_check(merged_ok, "乙的扣减 = 配置 shortage_debuff（期望 %s）" % str(want))
	_check(is_equal_approx(b_dmg - float(want.get("attack", 0)), float(b.trait_damage(100.0))),
			"乙攻击真的下降：%f → %f" % [b_dmg, float(b.trait_damage(100.0))])
	_check(is_equal_approx(b_speed - float(want.get("move_speed", 0)), float(b.speed)),
			"乙移速真的下降：%f → %f" % [b_speed, float(b.speed)])
	_check(is_equal_approx(a_dmg, float(a.trait_damage(100.0)))
			and is_equal_approx(a_speed, float(a.speed)),
			"甲的攻击/移速纹丝不动（%f / %f）" % [a.trait_damage(100.0), a.speed])
	var names: Array = _surv.hungry_names()
	_check(names.size() == 1 and str(names[0]) == str(b.character_name),
			"点名只点乙：%s" % str(names))
	_check(str(_surv.merged_penalties()) == str(_surv.penalties_for(b)),
			"全队合并表 = 乙那一张（只有他缺）：%s" % str(_surv.merged_penalties()))
	_check(Meta.penalty_line(_surv.penalties_for(b)) != "无属性变化",
			"文案表给得出人话：%s" % Meta.penalty_line(_surv.penalties_for(b)))


# ------------------------------------------------------------
# D) 补上立刻还原（按人）
# ------------------------------------------------------------
func _d_recover() -> void:
	_say("--- D 段：乙补上货立刻还原 ---")
	var b: Node = _players[1]
	var e: Dictionary = (_surv._supplies()[0] as Dictionary)
	var id := str(e.get("id", ""))
	var want: Dictionary = e.get("shortage_debuff", {})
	_check(not (b.supply_penalties as Dictionary).is_empty(), "接 C 段：乙还在短缺")
	var weak_dmg := float(b.trait_damage(100.0))

	# 只等帧，不手动 tick —— 证明「不用等下一个一分钟」
	b.add_item(id, int(e.get("per_meal", 1)))
	await _frames(4)
	_check(_surv.shortage_ids(b).is_empty(), "乙的短缺解除（实得 %s）"
			% str(_surv.shortage_ids(b)))
	_check((b.supply_penalties as Dictionary).is_empty(),
			"乙的扣减表清空（实得 %s）" % str(b.supply_penalties))
	_check(float(b.trait_damage(100.0)) > weak_dmg
			and is_equal_approx(float(b.trait_damage(100.0)) - float(want.get("attack", 0)),
					weak_dmg),
			"乙攻击回到 C 段之前的水位：%f → %f" % [weak_dmg, float(b.trait_damage(100.0))])
	_check(not bool(_surv.starving), "两人都够了 → starving=false")
	_check(_surv.shortages.is_empty(), "shortages 整体清空")


# ------------------------------------------------------------
# E) 拾取归属：走进范围的那个人
# ------------------------------------------------------------
func _e_pickup_owner() -> void:
	_say("--- E 段：拾取归属 ---")
	_reset()
	var a: Node = _players[0]
	var b: Node = _players[1]
	var radius := float(Config.get_value("loot.pickup_radius_px", 20.0))
	_say("       拾取半径 %f px，两人相距 %f px"
			% [radius, float(a.global_position.distance_to(b.global_position))])

	# E1：两人都压得住同一个资源点 → 最近的那个拿
	var mid: Vector2 = b.global_position \
			+ (a.global_position - b.global_position).normalized() * 3.0
	var node := _spawn_loot(mid, "wood", 4)
	var d_a: float = float(mid.distance_to(a.global_position))
	var d_b: float = float(mid.distance_to(b.global_position))
	_check(d_a <= radius and d_b <= radius,
			"资源点同时够到两人（甲 %f / 乙 %f）" % [d_a, d_b])
	_check(d_b < d_a, "乙更近（%f < %f）" % [d_b, d_a])
	_check(await _wait_gone(node, 90), "够近的乙把它拿走了（资源点消失）")
	_check(int(b.item_count("wood")) == 4, "木头进的是**乙**的包（乙 %d / 甲 %d）"
			% [b.item_count("wood"), a.item_count("wood")])
	_check(int(a.item_count("wood")) == 0, "甲一格没得：归属唯一，不会见者有份")

	# E2：把乙支开到范围外 → 只有甲够得着
	var dir: Vector2 = (b.global_position - a.global_position).normalized()
	b.global_position = a.global_position + dir * (radius * 1.6)
	await _frames(2)
	var far: float = float(a.global_position.distance_to(b.global_position))
	_check(far > radius, "乙被挪到 %f px 外（> 半径 %f）" % [far, radius])
	var node2 := _spawn_loot(a.global_position, "stone", 6)
	_check(await _wait_gone(node2, 90), "只有甲够得着 → 甲拾取成功")
	_check(int(a.item_count("stone")) == 6 and int(b.item_count("stone")) == 0,
			"石头只进甲的包（甲 %d / 乙 %d）" % [a.item_count("stone"), b.item_count("stone")])

	# E3：甲格子满 → 拒收，资源点留在原地；腾出格子后自动重试
	var saved = _run.player_stats.get("survival.backpack_capacity", null)
	_run.player_stats["survival.backpack_capacity"] = maxi(a.inventory.size(), 1)
	_check(not bool(a.add_item("iron", 1)), "甲格子已满 → 新种类收不下")
	var node3 := _spawn_loot(a.global_position + Vector2(4.0, 0.0), "gold", 3)
	await _pframes(25)
	_check(is_instance_valid(node3), "拒收后资源点没被吞掉（还在地上）")
	_check(int(a.item_count("gold")) == 0, "满包期间甲身上没有金")
	if saved == null:
		_run.player_stats.erase("survival.backpack_capacity")
	else:
		_run.player_stats["survival.backpack_capacity"] = saved
	_check(await _wait_gone(node3, 120),
			"腾出格子后 %ss 冷却自动重试 → 捡起来了"
			% str(Config.get_value("loot.pickup_retry_seconds", 0.5)))
	_check(int(a.item_count("gold")) == 3, "重试成功后金进了甲的包")


# ------------------------------------------------------------
# F) 右键弹窗
# ------------------------------------------------------------
func _f_popup() -> void:
	_say("--- F 段：右键角色 → 头顶弹窗 ---")
	_reset()
	var a: Node = _players[0]
	var b: Node = _players[1]
	a.add_item("wood", 20)
	a.add_item("food", 5)
	b.add_item("stone", 9)
	# 跑一轮消耗：甲有存货照样扣走 1 份，乙空手 → 只有乙短缺。
	# 弹窗的红字必须只挂在缺的那个人身上 —— 这是"各吃各的"在界面上的落点。
	_surv._consume_tick()
	await _frames(2)
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var bar := float(UiKit.menu_bar_height(vp.y)) if UiKit.menu_bar_enabled() else 0.0
	_say("       视口 %sx%s，菜单栏高 %d px"
			% [str(int(vp.x)), str(int(vp.y)), int(bar)])
	# 无头视口是 64x64 —— 比面板还小，夹取会把人钉在左上角，位置类断言毫无意义。
	# 这种条目只在真窗口（--window 那一次跑）里验；无头那次只验行为。
	var real_viewport: bool = vp.x > 700.0 and vp.y > 700.0
	if not real_viewport:
		_say("       视口太小 → 跳过位置/夹取类断言（同探针 --window 再跑一次覆盖）")

	_check(not bool(_popup.is_open()), "开局没弹（默认不打扰画面）")
	_rmb(_screen(a.global_position))
	await _frames(3)
	_check(bool(_popup.is_open()), "右键甲 → 弹窗打开")
	_check(_popup.get("unit") == a, "弹窗认的人就是甲")
	var rect: Rect2 = _popup.call("panel_rect")
	var title: Label = _popup.get("_title")
	_check(str(title.text).find("枪手") >= 0, "标题写着「枪手的背包」（实得 %s）" % title.text)
	_check(rect.size.x > 40.0 and rect.size.y > 30.0,
			"面板有实际尺寸 %dx%d" % [int(rect.size.x), int(rect.size.y)])
	var a_screen: Vector2 = _screen(a.global_position)
	if real_viewport:
		_check(rect.position.x >= 0.0 and rect.position.y >= 0.0
				and rect.end.x <= vp.x + 1.0,
				"面板没糊出视口（%s / 视口宽 %d）" % [str(rect), int(vp.x)])
		_check(rect.end.y <= vp.y - bar + 1.0,
				"面板不被底部菜单栏压住（底 %f vs 栏顶 %f）" % [rect.end.y, vp.y - bar])
	_check(rect.end.y <= a_screen.y + 1.0,
			"面板整体在甲头顶之上（底 %f vs 人 %f）" % [rect.end.y, a_screen.y])
	var warn: Label = _popup.get("_warn")
	var rows: VBoxContainer = _popup.get("_rows")
	_check(int(rows.get_child_count()) == 2, "甲两格货 → 面板两行（木头 / 食物，实得 %d 行）"
			% rows.get_child_count())
	_check(not bool(warn.visible), "甲有食物 → 他面板上没有短缺红字（warn=%s）" % str(warn.text))

	# 直接换人：不用先关
	_rmb(_screen(b.global_position))
	await _frames(3)
	_check(_popup.get("unit") == b, "右键乙 → 一步换人")
	_check(int(rows.get_child_count()) == 1, "乙只有石头 → 一行（实得 %d 行）"
			% rows.get_child_count())
	var rect_b: Rect2 = _popup.call("panel_rect")
	var warn_b := str(warn.text)
	_check(bool(warn.visible) and warn_b.find("短缺") >= 0 and warn_b.find("食物") >= 0,
			"乙缺食物 → 红字点名缺什么：%s" % warn_b)
	_check(warn_b.find("攻击") >= 0 and warn_b.find("移速") >= 0,
			"红字顺带说清降了哪几条属性：%s" % warn_b)
	_check(warn_b.find("不会死") >= 0, "红字承诺「补上即恢复，不会死」")

	# 点面板自己身上：既不收起，也不穿透成移动令。
	# 点左上角而不是中心 —— 面板是钉在头顶的，中心离人近，可能撞进选中半径里变成"点了自己"。
	_rmb(rect_b.position + Vector2(3.0, 3.0))
	_check(bool(_popup.is_open()) and _popup.get("unit") == b, "点在自己面板上 → 保持打开")
	# 再点乙本人：收起
	_rmb(_screen(b.global_position))
	_check(not bool(_popup.is_open()), "再右键同一个人 → 收起（开关手感）")

	# 关着时点空地：必须返回 false，别把 Player 的「右键=取消指令」抢走
	var empty: Vector2 = _screen(a.global_position + Vector2(1200.0, 1200.0))
	_check(not bool(_popup.call("right_click_at", empty)),
			"没弹窗时右键空地返回 false → 取消指令照旧")
	_rmb(_screen(b.global_position))
	await _frames(2)
	_check(bool(_popup.is_open()), "重新弹出（下面验点空地收起）")
	_check(bool(_popup.call("right_click_at", empty)), "开着时右键空地返回 true（这一下是收弹窗）")
	_check(not bool(_popup.is_open()), "空地右键把弹窗收起了")

	# ESC 收起
	_rmb(_screen(a.global_position))
	await _frames(2)
	_check(bool(_popup.is_open()), "ESC 前还开着")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	_popup.call("_input", esc)
	_check(not bool(_popup.is_open()), "ESC 收起弹窗")

	# 跟着人走（位置类：只在真窗口里量）
	_rmb(_screen(a.global_position))
	await _frames(3)
	var before: Rect2 = _popup.call("panel_rect")
	var full_h := int(before.size.y)
	a.global_position += Vector2(70.0, 40.0)
	await _frames(20)      # 相机会跟过去，等它稳一稳再量
	var after: Rect2 = _popup.call("panel_rect")
	if real_viewport:
		_check(not after.position.is_equal_approx(before.position),
				"人动了面板跟着动（%s → %s）" % [str(before.position), str(after.position)])
		var a2: Vector2 = _screen(a.global_position)
		_check(absf(after.get_center().x - a2.x) <= after.size.x
				and after.end.y <= a2.y + 1.0,
				"移动后仍然钉在头顶（面板中心 %f vs 人 %f）" % [after.get_center().x, a2.x])

	# 满包 → 空包：旧行必须先摘出容器再释放，否则本帧仍算进最小尺寸，
	# reset_size() 会把两块白边留在面板上（踩过）。
	a.inventory = {}
	await _frames(3)
	var empty_rect: Rect2 = _popup.call("panel_rect")
	_check(int(empty_rect.size.y) < full_h,
			"清空后面板缩回去（%d → %d px，不留白边）" % [full_h, int(empty_rect.size.y)])
	_check(int(rows.get_child_count()) == 1
			and str(rows.get_child(0).get("text")).find("空的") >= 0,
			"空包给的是引导文案而不是空白")
	_rmb(_screen(b.global_position))
	await _frames(2)


# ------------------------------------------------------------
# G) 菜单栏同步
# ------------------------------------------------------------
func _g_menu_bar_sync() -> void:
	_say("--- G 段：底部菜单栏同步 ---")
	var a: Node = _players[0]
	var b: Node = _players[1]
	_popup.call("open_for", b)
	await _frames(5)
	var line := str(_menu.call("bag_line_text"))
	_say("       菜单栏：「%s」" % line)
	_check(line.find("弓兵") >= 0, "弹窗看的是乙 → 菜单栏点名「背包（弓兵）」")
	_check(line.find("9") >= 0 and line.find(str(Config.get_value("resources.stone.name",
			"石头"))) >= 0, "明细行里有乙的石头 x9")
	_check(line.find("木头") < 0, "明细行不串到甲身上的木头")
	_popup.call("close_bag")
	await _frames(5)
	var line2 := str(_menu.call("bag_line_text"))
	_check(line2.find("弓兵") < 0, "弹窗一收，菜单栏回到被指挥的人（%s）" % line2)

	var bag: Label = _hud.get("_bag_label")
	_check(str(bag.text).find("枪手") >= 0 and str(bag.text).find("弓兵") >= 0,
			"HUD 左下背包行列出每个人占几格：%s" % bag.text)
	var surv: Label = _hud.get("_survival_label")
	_check(str(surv.text).find("每人各扣一份") >= 0,
			"HUD 生存栏讲明「每人各扣一份」：%s" % surv.text)


# ------------------------------------------------------------
# H) 阵亡撒地
# ------------------------------------------------------------
func _h_death_drops() -> void:
	_say("--- H 段：阵亡当场撒成一地 ---")
	_reset()
	if _players.size() < 2:
		_check(false, "前置：H 段需要两名存活角色（实得 %d）" % _players.size())
		return
	var a: Node = _players[0]
	var b: Node = _players[1]
	a.add_item("wood", 12)
	a.add_item("iron", 3)
	_popup.call("open_for", a)
	# 乙得站远点：他若在场 80px 内，掉物会在同一帧被他捡光，"撒了两包"就数不到了
	var away := float(Config.get_value("loot.pickup_radius_px", 20.0)) * 1.8
	b.global_position = a.global_position + Vector2(away, 0.0)
	await _frames(3)
	var nodes_before := _loot_count()
	_say("       甲倒下前背包 %s，场上资源点 %d 个（乙已退到 %d px 外）"
			% [str(a.inventory), nodes_before, int(away)])

	a.call("on_death")
	# 锚点要在撒包那一刻同步取：on_death 里先 move_and_slide()（卡进装饰碰撞会被顶开）
	# 再按当时的 global_position 撒包；晚几个帧再读，尸体可能又被物理挪走了
	var corpse: Vector2 = a.global_position
	await _frames(5)

	_check(bool(a.inventory.is_empty()), "甲的背包已清空（东西不随人消失）")
	var nodes_after := _loot_count()
	_check(nodes_after == nodes_before + 2,
			"每种资源各撒成一个资源点：%d → %d" % [nodes_before, nodes_after])
	var spread := float(Config.get_value("loot.drop_spread_px", 22.0))
	var near := 0
	for q in get_tree().get_nodes_in_group("loot_nodes"):
		if is_instance_valid(q) and float(q.global_position.distance_to(corpse)) <= spread + 1.0:
			near += 1
	_check(near == 2, "两个掉物都贴着尸体（半径 %f px 内实得 %d 个）" % [spread, near])
	_check(not bool(_popup.is_open()), "人没了 → 弹窗自动收起")
	_check(int(_run.state) == int(_run.State.RUNNING), "乙还活着 → 本局继续")

	# 队友走上去捡得回
	var drop: Node = null
	for q in get_tree().get_nodes_in_group("loot_nodes"):
		if is_instance_valid(q) and str(q.get("resource_id")) == "wood" \
				and float(q.global_position.distance_to(corpse)) <= spread + 1.0:
			drop = q
			break
	_check(drop != null, "找得到甲撒下的那包木头")
	if drop != null:
		b.global_position = drop.global_position
		_check(await _wait_gone(drop, 90), "乙走上去把队友掉的木头捡回来了")
		_check(int(b.item_count("wood")) == 12, "捡回来的数量分毫不差（实得 %d）"
				% b.item_count("wood"))

	# 死人不再参与消耗：再 tick 一轮，短缺只会记在乙头上
	_reset()
	_surv._consume_tick()
	_check(not bool(_surv.shortages.has(int(a.get_instance_id()))),
			"倒下的甲不再被记短缺（shortages=%s）" % str(_surv.shortages))
	_check(_surv._alive_players().size() == 1, "存活名单只剩乙（实得 %d 人）"
			% _surv._alive_players().size())
	var hp: Label = _hud.get("_hp_label")
	_check(str(hp.text).find("倒下") >= 0, "HUD 血条标出倒下的人：%s" % hp.text)


# ------------------------------------------------------------
# I) 结算归属
# ------------------------------------------------------------
func _i_settlement() -> void:
	_say("--- I 段：死亡局不入库 / 撤离才入库 ---")
	_reset()
	_check(_players.size() == 1, "接 H 段：场上只剩最后一名存活角色（实得 %d）" % _players.size())
	if _players.is_empty():
		return
	var b: Node = _players[0]
	_check(bool(b.add_item("oil", 8)), "乙背上 8 桶油（死亡局要丢的就是它）")
	var bank_before: Dictionary = Meta.bank.duplicate(true)
	b.call("on_death")
	var grave: Vector2 = b.global_position      # 撒包那一刻的坐标，等帧就不准了
	await _frames(6)
	_check(int(_run.state) != int(_run.State.RUNNING), "全队倒下 → 本局结束")
	_check(str(Meta.bank) == str(bank_before), "死亡局分文不入仓（仓库仍 %s）" % str(Meta.bank))
	_check(bool(b.inventory.is_empty()), "乙倒下时包已清空")
	var spread := float(Config.get_value("loot.drop_spread_px", 22.0))
	var oil_near := 0
	for q in get_tree().get_nodes_in_group("loot_nodes"):
		if is_instance_valid(q) and str(q.get("resource_id")) == "oil" \
				and float(q.global_position.distance_to(grave)) <= spread + 1.0:
			oil_near += 1
	_check(oil_near == 1, "那 8 桶油留在尸体旁边（附近 oil 掉物 %d 个）—— 全丢但不是回仓库" % oil_near)

	# 第二次出击验撤离入库：不带 uid 的默认单人，跑完不影响名册
	_main.call("_on_launch", [])
	var p2: Array = await _settle_players()
	_run = get_tree().get_first_node_in_group("run_manager")
	_surv = get_tree().get_first_node_in_group("survival_system")
	_menu = get_tree().get_first_node_in_group("menu_bar")
	_popup = get_tree().get_first_node_in_group("inventory_popup")
	_players = p2
	_say("       第二次出击后存活角色 %d 名" % p2.size())
	_check(p2.size() == 1, "重开一局能进局（1 名角色）")
	if p2.is_empty() or _run == null:
		return
	_surv.set("next_meal_in", 9999.0)
	var c: Node = p2[0]
	c.add_item("wood", 7)
	c.add_item("food", 3)
	var carried: Dictionary = _run.total_loot()
	var bank2: Dictionary = Meta.bank.duplicate(true)
	_run.call("extract")
	await _frames(4)
	var ok_wood: bool = int(Meta.bank.get("wood", 0)) - int(bank2.get("wood", 0)) \
			== int(carried.get("wood", 0))
	var ok_food: bool = int(Meta.bank.get("food", 0)) - int(bank2.get("food", 0)) \
			== int(carried.get("food", 0))
	_check(int(_run.state) != int(_run.State.RUNNING), "撤离后本局结束")
	_check(ok_wood and ok_food,
			"撤离入库 = 各人背包合并（应为 %s，仓库实增 wood %d / food %d）" % [str(carried),
					int(Meta.bank.get("wood", 0)) - int(bank2.get("wood", 0)),
					int(Meta.bank.get("food", 0)) - int(bank2.get("food", 0))])


# ------------------------------------------------------------
# 工具
# ------------------------------------------------------------

## 世界坐标 → 视口屏幕坐标（与弹窗内部换算同源）
func _screen(world: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform() * world


## 模拟一次右键（走 _input，顺带验输入接线；不靠 Area2D 拾取，无头也能跑）
func _rmb(screen: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.position = screen
	ev.global_position = screen
	ev.pressed = true
	_popup.call("_input", ev)


func _spawn_loot(world: Vector2, res_id: String, amount: int) -> Node:
	var node: Node = load(LOOT_SCENE).instantiate()
	_world.add_child(node)
	node.setup(res_id, amount, 1.0)
	node.global_position = world
	return node


## 等资源点被拾走（queue_free 后实例失效）
func _wait_gone(node: Node, max_frames: int) -> bool:
	for _i in range(max_frames):
		await get_tree().physics_frame
		if not is_instance_valid(node):
			return true
	return false


func _loot_count() -> int:
	var n := 0
	for q in get_tree().get_nodes_in_group("loot_nodes"):
		if is_instance_valid(q):
			n += 1
	return n


func _reset() -> void:
	## 回到「无人短缺 + 空背包」的干净起点，倒计时跑不完
	_surv.shortages = {}
	_surv.set("_starve_timer", 0.0)
	_surv.set("_eat_cooldown", 0.0)
	_surv.set("next_meal_in", 9999.0)
	_surv._sync_starving()
	_clear_bags()
	_players = []
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q) and not bool(q.is_dead()):
			_players.append(q)
	for p in _players:
		if int(p.hp) < int(p.max_hp):
			p.hp = int(p.max_hp)


## 清空全场背包（含上一局撒在地上的资源点），避免段落之间互相污染
func _clear_bags() -> void:
	for q in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(q):
			q.inventory = {}
	_run._unassigned_loot = {}
	for q in get_tree().get_nodes_in_group("loot_nodes"):
		if is_instance_valid(q):
			q.queue_free()


func _clear_hostiles() -> void:
	var n := 0
	for g in ["enemies", "animals"]:
		for e in get_tree().get_nodes_in_group(g):
			if is_instance_valid(e):
				e.queue_free()
				n += 1
	_say("       已清场敌对 AI %d 个（探针期间不受战斗干扰）" % n)


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
	print("[probe_inventory] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

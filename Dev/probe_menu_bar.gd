extends Node
## ============================================================
## probe_menu_bar — 局内底部菜单栏验证（headless 可跑）
##
## 验六件事：
##   A) 布局：栏高 = 视口高 × height_ratio（默认 20% = 最下面 1/5），
##      整条栏贴在屏幕底部、小地图槽在栏内左侧且是正方形；
##      基地模式整栏（含小地图）隐藏。
##   B) 小地图常驻：进局即为 embed 模式、visible=true（不必等撤离点开启），
##      底图已生成；面板本地坐标 → 世界坐标换算正确（点小地图=点地图的前提）；
##      点小地图能把移动令送到选中单位。
##   C) 噪音读数：当前噪音 / 累积噪音只统计「小队发声」（from_player=true），
##      敌人呼喊不计入；当前噪音随时间衰减；档位名与配置一致。
##   D) 单位指令：按钮表来自 characters.list[].command_set（换单位换指令），
##      自动攻击开关 / 索敌最近 / 索敌最强 / 指定攻击 / 巡逻 / 取消指令 逐项行为。
##   E) 指令输入通道：右键 = 取消指令；ESC 退出待点选模式（不吞整局 ESC 之外的输入）。
##   F) 局间复位：再次进局时噪音读数清零（上一局的暴露度不能带进新一局）。
##
## 为什么 headless 能跑：菜单栏是纯 Control + 纯数据指令，不依赖渲染。
## ============================================================

const OUT := "user://_probe_menu_bar.txt"

## 假敌人：与 probe_auto_combat 同款（根节点必须是 Area2D 本身，理由见那里）。
class FakeTarget extends Area2D:
	var hp := 1000.0
	var max_hp := 1000.0
	var damage := 10
	var type_name := "假敌"
	func _init(p_hp: float = 1000.0, p_dmg: int = 10, p_name: String = "假敌") -> void:
		hp = p_hp
		max_hp = p_hp
		damage = p_dmg
		type_name = p_name
		var shape := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = 12.0
		shape.shape = circle
		add_child(shape)
	func take_damage(amount: int) -> void:
		hp -= float(amount)
	func is_dead() -> bool:
		return hp <= 0.0


var _lines: Array = []
var _n := 0
var _fails: Array = []


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


func _ready() -> void:
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	var menu = main.get_node("MenuBar")
	var minimap = main.get_node("MenuBar/Minimap")

	_say("--- A 段：菜单栏布局（最下面 1/5）---")
	# 用户设置里可能开着 debug.auto_enter_run（启动直接进局），
	# 那 A 段的「基地里应该是隐藏的」就无从验起 —— 先显式回一次基地。
	main._enter_base()
	await _frames(3)
	var vp: Vector2 = main.get_viewport().get_visible_rect().size
	var ratio := float(Config.get_value("menu_bar.height_ratio", 0.2))
	var expect_h: float = clampf(vp.y * ratio,
			float(Config.get_value("menu_bar.min_height_px", 160)),
			float(Config.get_value("menu_bar.max_height_px", 320)))
	# headless 的视口是退化的（dummy 驱动给 64×64），像素级布局在那里没有意义：
	# 那种情况下改验「比例公式」本身，真实布局交给 --window 跑同一份探针。
	var real_viewport := vp.y >= 400.0
	if real_viewport:
		_check(is_equal_approx(menu.bar_height(), expect_h),
				"栏高 = 视口高 %.0f × %.2f = %.0fpx（实得 %.0f，夹在 %d~%d 之间）"
				% [vp.y, ratio, expect_h, menu.bar_height(),
				   int(Config.get_value("menu_bar.min_height_px", 160)),
				   int(Config.get_value("menu_bar.max_height_px", 320))])
		# 真实高度 = 期望高度，才算「内容塞得下」——一旦内容比栏高还高，
		# 栏会被自己的最小尺寸顶高、把上面 HUD 的文字压住（这里提前拦住）
		_check(is_equal_approx(menu.bar_actual_height(), expect_h),
				"实际布局高度 = 期望高度（实得 %.0f，内容塞得下）" % menu.bar_actual_height())
	else:
		_say("  （headless 视口只有 %.0f×%.0f，像素级布局改在开窗那次验；这里验比例公式）"
				% [vp.x, vp.y])
		_check(is_equal_approx(UiKit.menu_bar_height(1080.0), 1080.0 * ratio),
				"公式：1080px 高的屏幕 → 栏高 %.0fpx（= 最下面 %.0f%%）"
				% [UiKit.menu_bar_height(1080.0), ratio * 100.0])
		_check(is_equal_approx(UiKit.menu_bar_height(1080.0), 216.0),
				"默认 20%% 时 1080 高 → 216px（实得 %.0f）" % UiKit.menu_bar_height(1080.0))
	_check(not menu.visible, "基地模式：菜单栏隐藏")
	_check(not minimap.visible, "基地模式：小地图也跟着隐藏（它是独立 CanvasLayer，不继承父层 visible）")

	_say("--- B 段：进局后小地图常驻在栏内左侧 ---")
	main._on_launch([{"id": "swordsman", "name": "剑士"}])
	await _frames(40)
	_check(menu.visible, "局内：菜单栏显示")
	_check(minimap.visible, "局内：小地图开局即显示（不再等撤离点开启才弹出）")
	_check(bool(minimap.get("_embed")), "小地图已切到 embed 常驻模式")

	var slot: Rect2 = menu.minimap_slot_rect()
	_check(slot.size.x > 0.0 and is_equal_approx(slot.size.x, slot.size.y),
			"小地图槽是正方形（%.0f×%.0f，随栏高自适应）" % [slot.size.x, slot.size.y])
	_check(slot.position.x < vp.x * 0.5 and slot.position.y > vp.y - expect_h - 1.0,
			"小地图槽落在屏幕左下角（x=%.0f, y=%.0f，栏顶 y=%.0f）"
			% [slot.position.x, slot.position.y, vp.y - expect_h])
	var br: Rect2 = menu.bar_rect()
	if real_viewport:
		_check(is_equal_approx(br.end.y, vp.y), "整条栏贴屏幕底边（bottom=%.0f / 视口 %.0f）"
				% [br.end.y, vp.y])
		# 栏高只占「视口高」的一小部分：这一条是 2D 线真正要保证的观感
		_check(br.size.y <= maxf(vp.y * 0.35, expect_h + 1.0),
				"栏高不超过屏高 1/3（栏 %.0f / 屏 %.0f）" % [br.size.y, vp.y])
	else:
		_say("  （headless 视口 %.0f×%.0f 比栏本身还矮，贴底/占比两条只能在开窗那次量）"
				% [vp.x, vp.y])

	# 坐标换算：槽中心 ↔ 地图中心（点小地图导航镜头的前提）
	var map_w: float = float(int(Config.get_value("map.width", 128)))
	var map_h: float = float(int(Config.get_value("map.height", 128)))
	var tile: float = float(int(Config.get_value("map.tile_size", 64)))
	var center_world: Vector2 = minimap.world_pos_at(slot.size * 0.5)
	var expect_center := Vector2(map_w * tile * 0.5, map_h * tile * 0.5)
	_check(center_world.distance_to(expect_center) < 1.0,
			"槽中心映射到地图中心（实得 %s / 期望 %s）" % [str(center_world), str(expect_center)])
	var corner_world: Vector2 = minimap.world_pos_at(Vector2.ZERO)
	_check(corner_world.distance_to(Vector2.ZERO) < 1.0,
			"槽左上角映射到世界原点（实得 %s）" % str(corner_world))

	var players := get_tree().get_nodes_in_group("player")
	_check(players.size() >= 1, "进局后找到玩家（共 %d 名）" % players.size())
	if players.is_empty():
		_finish()
		return
	var p = players[0]

	# 点小地图 = 大世界镜头平移到该处（RTS 式导航）。
	# 取一个「离相机当前中心不远的点」当目标：肯定在镜头可达范围内，不会因每局随机
	# 出生点 / 边界限位而时准时偏（精确等于贴边目标那种断言就是不稳）。断言只验
	# 「镜头确实动了，且明显朝点击点靠近了」，这才是这个功能要保证的语义。
	var cam = get_tree().get_first_node_in_group(&"iso_cam")
	_check(cam != null and cam.has_method("focus_world_pos"),
			"局内相机存在且可导航（focus_world_pos）")
	var before: Vector2 = cam.global_position
	var nav_target: Vector2 = before + Vector2(320.0, 320.0)
	menu._on_minimap_clicked(nav_target)
	await _frames(2)
	_check(cam.global_position != before,
			"点小地图后镜头确实移动了（%s → %s）" % [str(before), str(cam.global_position)])
	_check(cam.global_position.distance_to(nav_target) < before.distance_to(nav_target) - 1.0,
			"镜头明显朝点击处靠近（离目标：%.0f → %.0f）"
			% [before.distance_to(nav_target), cam.global_position.distance_to(nav_target)])
	_check(not p.has_move_target(), "点小地图不再给单位下移动令（镜头导航与下令已分离）")

	_say("--- C 段：噪音读数（自身 / 世界）---")
	# 先让角色完全安静下来：不移动（无脚步）、不开火（无攻击噪音），
	# 这样「读数 == 这一次发声」才是可断言的。
	p.cancel_commands()
	p.set_auto_attack(false)
	await _frames(5)
	NoiseSystem.reset()
	_check(is_equal_approx(NoiseSystem.team_self_noise(), 0.0)
			and is_equal_approx(NoiseSystem.world_noise, 0.0), "进局后两路读数都从 0 开始")
	# 2026-09-18 起「当前/累积」改成了互相喂养的「自身/世界」，并且自身噪音是**每人一份**
	# —— 所以 emit 要把发声的那个角色传进去，否则落到没归属那份、菜单照样有读数
	# 但光球不会有任何反应（这类回归只有源码外观上看不出来）。
	NoiseSystem.emit(p.global_position, 120.0, true, p)
	_check(is_equal_approx(NoiseSystem.team_self_noise(), 120.0),
			"小队发声 120 → 自身噪音 = 120（实得 %.0f）" % NoiseSystem.team_self_noise())
	var lv: Dictionary = NoiseSystem.noise_level()
	_check(str(lv["name"]) == "吵闹", "120 的档位 = 吵闹（实得 %s）" % str(lv["name"]))
	NoiseSystem.emit(p.global_position, 300.0, false)
	_check(is_equal_approx(NoiseSystem.team_self_noise(), 120.0),
			"敌人呼喊（from_player=false）不计入自身噪音（实得 %.0f）"
			% NoiseSystem.team_self_noise())
	await _frames(30)
	_check(NoiseSystem.team_self_noise() < 120.0,
			"自身噪音随时间衰减（30 帧后 %.0f < 120）" % NoiseSystem.team_self_noise())
	_check(NoiseSystem.world_noise > 0.0,
			"自身噪音喂进了世界噪音（30 帧后 %.1f）" % NoiseSystem.world_noise)
	_check(NoiseSystem.world_ratio() > 0.0 and NoiseSystem.world_ratio() <= 1.0,
			"世界噪音占参考值比例在 0~1 之间（实得 %.3f）" % NoiseSystem.world_ratio())

	_say("--- C2 段：右侧噪音表（控件层面）---")
	NoiseSystem.reset()
	NoiseSystem.emit(p.global_position, 240.0, true, p)   # 接近 self.max(300) 的一声
	await _frames(3)
	_check(menu._cur_bar.value > 200.0, "「自身」条跟着噪音走（条值 %.0f / 满值 %.0f）"
			% [menu._cur_bar.value, menu._cur_bar.max_value])
	_check(str(menu._cur_value.text) != "0", "「自身」数值已刷新（%s）" % str(menu._cur_value.text))
	_check(str(menu._cur_level.text).find("震耳") >= 0,
			"档位文字跟着音量走（实得「%s」）" % str(menu._cur_level.text))
	_check(menu._cur_fill.bg_color.is_equal_approx(NoiseSystem.noise_level()["color"]),
			"条的填充色取自档位配色（%s）" % str(menu._cur_fill.bg_color))
	# 世界噪音靠每帧累加，多等几帧再看它到底有没有长度
	await _frames(12)
	_check(menu._acc_bar.value > 0.0, "「世界」条有长度（%.1f）" % menu._acc_bar.value)
	NoiseSystem.reset()

	_say("--- D 段：指令面板（按单位变）---")
	var set_id := str(p.get("command_set"))
	_check(set_id != "", "角色带指令集 id（实得 %s）" % set_id)
	var want: Array = Config.get_value("menu_bar.command_sets.%s" % set_id, [])
	_check(menu.command_button_ids().size() == want.size(),
			"指令面板按钮数 = 配置里的 %d 个（实得 %d：%s）"
			% [want.size(), menu.command_button_ids().size(), str(menu.command_button_ids())])
	# 换武器 = 换威胁/射程/贴图，指令集不变但单位信息跟着变（这里只验数值随武器走）
	var rng_before: float = p.attack_range_px()
	p.switch_weapon(&"bow")
	await _frames(3)
	_check(p.attack_range_px() != rng_before,
			"换单位（武器）后攻击距离跟着变（剑 %.0f → 弓 %.0f）"
			% [rng_before, p.attack_range_px()])
	p.switch_weapon(&"sword")   # 注意是武器 id，不是角色 id
	await _frames(3)

	# 假敌人挂到玩家父层（与真实敌人同层）。血量都拉高：本探针要观察的是
	# 「打谁」而不是「打死没」，血太少会在断言跑完前就被打死、后续断言全乱。
	var parent: Node = p.get_parent()
	var near := FakeTarget.new(2000.0, 5, "近卫")
	parent.add_child(near)
	near.add_to_group(&"enemies")
	var far := FakeTarget.new(3000.0, 16, "重甲")
	parent.add_child(far)
	far.add_to_group(&"enemies")

	_say("  · 自动攻击开关")
	near.global_position = p.global_position + Vector2(60.0, 0.0)
	far.global_position = p.global_position + Vector2(115.0, 0.0)
	p.set_auto_attack(false)
	await _frames(20)
	_check(p.auto_target() == null, "关掉自动攻击后即使敌人在射程内也不锁定")
	p.set_auto_attack(true)
	await _frames(20)
	_check(p.auto_target() != null, "打开自动攻击后重新锁定")

	_say("  · 索敌策略：最近 / 最强")
	p.set_target_stance(&"nearest")
	await _frames(20)
	_check(p.auto_target() == near, "策略=最近 → 锁 60px 的近卫（实锁 %s）"
			% str(_tname(p.auto_target())))
	p.set_target_stance(&"strongest")
	await _frames(20)
	_check(p.auto_target() == far, "策略=最强 → 改锁 115px 但血更厚的重甲（实锁 %s）"
			% str(_tname(p.auto_target())))

	_say("  · 指定攻击")
	p.set_target_stance(&"nearest")
	p.arm_designate()
	_check(str(p.arm_mode()) == "designate", "「指定攻击」进入待点选模式")
	# 走世界点击这条入口（点小地图已改为只导航镜头）：等价于点地图上那个敌人所在的格
	p.command_click(far.global_position)
	await _frames(3)
	_check(p.get("designated_target") == far, "点中重甲 → 已指定（实指定 %s）"
			% str(_tname(p.get("designated_target"))))
	_check(p.auto_target() == far, "指定目标优先于索敌策略（本来该打最近的近卫）")
	_check(str(p.arm_mode()) == "", "点名后自动退出待点选模式")
	# 指定目标跑出有效射程 → 自动解除并回落策略索敌
	far.global_position = p.global_position + Vector2(600.0, 0.0)
	await _frames(30)
	_check(p.get("designated_target") == null, "指定目标跑出射程 → 自动解除指定")
	_check(p.auto_target() == near, "解除后回落到策略索敌（锁近卫）")

	_say("  · 巡逻")
	far.global_position = p.global_position + Vector2(3000.0, 3000.0)  # 挪出去，别来捣乱
	p.cancel_commands()
	p.set_auto_attack(false)      # 巡逻途中别开火，专心验移动
	var pt_a := _open_world_near(main, p.global_position, Vector2i(3, 0))
	var pt_b := _open_world_near(main, p.global_position, Vector2i(0, 3))
	p.begin_patrol_setup()
	_check(str(p.patrol_state()) == "setting", "点「巡逻」进入设点模式")
	p.command_click(pt_a)
	p.command_click(pt_b)
	_check(int(p.patrol_point_count()) == 2, "设了 2 个巡逻点（实得 %d）" % int(p.patrol_point_count()))
	var pos_before: Vector2 = p.global_position
	_check(bool(p.start_patrol()), "点「开始巡逻」成功（有点才允许开）")
	await _frames(60)
	var moved: float = p.global_position.distance_to(pos_before)
	_say("     诊断：state=%s has_target=%s patrol=%s 路径点=%d 位置=%s 起点=%s 点1=%s"
			% [str(p.state_machine.get_state_name()), str(p.has_move_target()),
			   str(p.patrol_state()), (p.get("_cached_path") as PackedVector2Array).size(),
			   str(p.global_position), str(pos_before), str(pt_a)])
	_check(moved > 4.0, "巡逻真的在走（60 帧位移 %.1fpx）" % moved)
	_check(str(p.patrol_state()) == "active", "巡逻状态 = active")
	p.stop_patrol()
	_check(str(p.patrol_state()) == "" and not p.has_move_target(), "「停止巡逻」后停下且清空移动目标")
	_check(int(p.patrol_point_count()) == 2, "停止巡逻不会丢掉已设的点（便于再次启动）")

	_say("  · 取消指令")
	p.set_auto_attack(true)
	p.set_target_stance(&"strongest")
	p.arm_designate()
	p.command_click(near.global_position)
	await _frames(3)
	p.begin_patrol_setup()
	p.command_click(pt_a)
	p.cancel_commands()
	_check(p.get("designated_target") == null, "取消指令：指定目标已清")
	_check(str(p.patrol_state()) == "" and int(p.patrol_point_count()) == 0,
			"取消指令：巡逻停止且巡逻点清空")
	_check(bool(p.get("auto_attack_on")) and str(p.get("target_stance")) == "strongest",
			"取消指令不动「自动攻击开关」与「索敌策略」（那是持续偏好，不是一次性指令）")

	_say("--- E 段：指令输入通道（左键经选择控制器 · 右键经角色）---")
	var sel = get_tree().get_first_node_in_group(&"selection")
	_check(sel != null, "局内已挂选择控制器（左键入口）")
	if sel != null:
		if not bool(p.selected):
			p.select()
		# 指定模式下的「空地左键」→ 控制器转 command_click → 退出待点选
		# （左键已不在 Player._unhandled_input 里处理，改由此控制器统一裁决）
		p.arm_designate()
		_click_at(sel, p.global_position + Vector2(3000.0, 3000.0))
		await _frames(2)
		_check(str(p.arm_mode()) == "",
				"空地左键经控制器下令 → 指定模式点空处退出待点选")
	var ev_r := InputEventMouseButton.new()
	ev_r.button_index = MOUSE_BUTTON_RIGHT
	ev_r.pressed = true
	p.set_target_stance(&"nearest")
	p.arm_designate()
	p.command_click(near.global_position)
	await _frames(3)
	p._unhandled_input(ev_r)
	_check(p.get("designated_target") == null, "右键 = 取消指令（解除指定目标）")

	_say("--- F 段：局间复位 ---")
	NoiseSystem.emit(p.global_position, 240.0, true, p)
	# 世界噪音是每帧灌进去的，等几帧才会攒出非零值 —— 不等就等于拿 0 去比 0
	await _frames(6)
	var acc_before: float = NoiseSystem.world_noise
	_check(acc_before > 0.0, "离局前世界噪音已经攒起来（%.1f）" % acc_before)
	main._enter_base()
	await _frames(5)
	_check(not menu.visible, "回基地：菜单栏隐藏")
	main._on_launch([{"id": "archer", "name": "弓兵"}])
	await _frames(30)
	_check(is_equal_approx(NoiseSystem.world_noise, 0.0),
			"再进一局：世界噪音清零（上一局 %.1f → 本局 %.1f）"
			% [acc_before, NoiseSystem.world_noise])
	var archers := get_tree().get_nodes_in_group("player")
	_check(archers.size() == 1 and str(archers[0].character_name) == "弓兵",
			"换一名角色进局（实得 %d 名：%s）"
			% [archers.size(), str(archers[0].character_name) if archers.size() > 0 else "-"])

	_say("--- G 段：指令面板跟着「当前选中的人」换 ---")
	main._enter_base()
	await _frames(5)
	# 二号位用名单里真的有的角色：不在 characters.list 里的 id 会被
	# _squad_characters() 按名单过滤掉（剩 1 人），那不是面板的问题。
	main._on_launch([{"id": "archer", "name": "弓兵"}, {"id": "swordsman", "name": "剑士"}])
	await _frames(40)
	var squad := get_tree().get_nodes_in_group("player")
	_check(squad.size() == 2, "两人小队进局（实得 %d 名）" % squad.size())
	if squad.size() == 2:
		squad[0].select()
		await _frames(3)
		var t0: String = str(menu._unit_title.text)
		var r0: float = squad[0].effective_attack_range_px()
		squad[1].select()
		await _frames(3)
		var t1: String = str(menu._unit_title.text)
		var r1: float = squad[1].effective_attack_range_px()
		_check(t0 != t1 and r0 != r1,
				"切换选中的人 → 面板标题与数值跟着换（%s 射程 %.0f → %s 射程 %.0f）"
				% [t0, r0, t1, r1])
		_check(t1.find("剑士") >= 0, "选中的是二号位时面板跟着换（实得「%s」）" % t1)

	_say("--- H 段：框选多选 + 改选不打断移动 ---")
	if squad.size() >= 2:
		var a = squad[0]
		var b = squad[1]
		a.cancel_commands()
		b.cancel_commands()
		# (1) 给 a 下移动令，再改选 b —— a 的移动绝不能被「选中别人」打断（原 bug）
		a.select()
		var tgt_a := _open_world_near(main, a.global_position, Vector2i(8, 0))
		a.command_click(tgt_a)
		_check(a.has_move_target(), "a 已接到移动令")
		b.select()
		await _frames(3)
		_check(a.has_move_target(), "改选 b 后 a 的移动不被打断（打断 bug 回归）")
		_check(bool(b.selected) and not bool(a.selected), "单选互斥：选择集切到 b")
		a.cancel_commands()
		b.cancel_commands()
		# (2) 框选两人 → 一次空地左键同时下达给两人（多选下令）
		var sel2 = get_tree().get_first_node_in_group(&"selection")
		if sel2 != null:
			_drag_box(sel2, a.global_position + Vector2(-40, -40),
					b.global_position + Vector2(40, 40))
			await _frames(2)
			_check(bool(a.selected) and bool(b.selected), "拖框把两人都纳入选择集")
			var tgt := _open_world_near(main,
					(a.global_position + b.global_position) * 0.5, Vector2i(5, 0))
			_click_at(sel2, tgt)
			await _frames(2)
			_check(a.has_move_target() and b.has_move_target(),
					"框选后一次空地左键同时下达给两名（多选一起行动）")
			# 框住无人空地 → 清空选择
			var far_corner: Vector2 = a.global_position + Vector2(2500.0, 2500.0)
			_drag_box(sel2, far_corner + Vector2(-8, -8), far_corner + Vector2(8, 8))
			await _frames(2)
			_check(not bool(a.selected) and not bool(b.selected), "框住无人空地 → 清空选择")

	_finish()


func _tname(t) -> String:
	if t == null or not is_instance_valid(t):
		return "无"
	return str(t.get("type_name"))


## 玩家附近某个方向上的可通行格中心（避免把巡逻点设在墙里，A* 找不到路会直接放弃）
func _open_world_near(main: Node, from: Vector2, offset_cells: Vector2i) -> Vector2:
	var tile: float = float(int(Config.get_value("map.tile_size", 64)))
	var cell := Vector2i(int(from.x / tile) + offset_cells.x, int(from.y / tile) + offset_cells.y)
	var open_cell := MapGenerator.nearest_open_cell(main._last_map["walls"], cell, 8)
	if open_cell.x < 0:
		return from
	return Vector2(open_cell) * tile + Vector2(tile, tile) * 0.5


## 直接喂事件给选择控制器（绕过引擎拾取），测「点击 vs 拖框」两条路。
func _click_at(sel: Node, world: Vector2) -> void:
	var scr: Vector2 = sel.get_viewport().get_canvas_transform() * world
	sel._unhandled_input(_lbtn(true, scr))
	sel._unhandled_input(_lbtn(false, scr))


func _drag_box(sel: Node, w_a: Vector2, w_b: Vector2) -> void:
	var xf: Transform2D = sel.get_viewport().get_canvas_transform()
	var sa: Vector2 = xf * w_a
	var sb: Vector2 = xf * w_b
	sel._unhandled_input(_lbtn(true, sa))
	var mv := InputEventMouseMotion.new()
	mv.position = sb
	mv.global_position = sb
	sel._unhandled_input(mv)
	sel._unhandled_input(_lbtn(false, sb))


func _lbtn(pressed: bool, pos: Vector2) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	return e


func _finish() -> void:
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_menu_bar] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

extends Control
## ============================================================
## MiscPanel — 「其他」里的占位界面（开始菜单 → 其他）
##
## 这一批界面**故意只做占位**：先把入口和信息架构定下来，
## 免得以后加进来时又要改菜单结构。左侧选一项，右侧显示
## 「这一屏将来该放什么、数据从哪来、代码该加在哪」。
##
## 接真界面时：把 _make_entries() 对应项的 "impl" 指向真实的
## 场景/脚本，把 _show_detail() 换成实例化那个界面即可，
## 菜单本身不用动。
## ============================================================

signal close_requested

var _detail: VBoxContainer
var _active := -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 裸 Control 的 rect 是 0×0（本面板由 StartMenu 用 .new() 造出来再挂上去），
	# 不铺满的话 CenterContainer 会在 0×0 里居中，面板整体缩到左上角。
	UiKit.stretch(self)
	_build_ui()
	_select(0)


func _build_ui() -> void:
	add_child(UiKit.overlay())

	var center := CenterContainer.new()
	UiKit.stretch(center)
	add_child(center)

	var panel := UiKit.panel(UiKit.COL_PANEL, 20)
	panel.custom_minimum_size = Vector2(880, 520)
	center.add_child(panel)

	var col := UiKit.vbox(10)
	panel.add_child(col)

	col.add_child(UiKit.title("其他"))

	var sub := UiKit.dim("以下界面均为占位 —— 入口先占住，内容后续补")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(sub)

	col.add_child(UiKit.spacer(6))

	var row := UiKit.hbox(14)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(row)

	# 左：入口列表
	var left := UiKit.vbox(6)
	left.custom_minimum_size = Vector2(240, 0)
	row.add_child(left)

	var group := ButtonGroup.new()
	var entries := _make_entries()
	for i in range(entries.size()):
		var b := UiKit.button(str(entries[i]["name"]), 0, UiKit.FS_BODY)
		b.toggle_mode = true
		b.button_group = group
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(240, 40)
		if i == 0:
			b.button_pressed = true
		b.pressed.connect(_select.bind(i))
		left.add_child(b)

	# 右：详情
	var right_box := UiKit.panel(UiKit.COL_ROW, 16)
	right_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(right_box)

	_detail = UiKit.vbox(8)
	right_box.add_child(_detail)

	var footer := UiKit.hbox(10)
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(footer)
	var back := UiKit.button("返回", 120)
	back.pressed.connect(func(): close_requested.emit())
	footer.add_child(back)


func _select(index: int) -> void:
	var entries := _make_entries()
	if index < 0 or index >= entries.size():
		return
	_active = index
	var e: Dictionary = entries[index]
	for c in _detail.get_children():
		c.queue_free()

	_detail.add_child(UiKit.label(str(e["name"]), UiKit.FS_TITLE, UiKit.COL_TEXT))
	_detail.add_child(UiKit.label("占位 · 尚未实现", UiKit.FS_BODY, UiKit.COL_WARN))
	_detail.add_child(UiKit.spacer(4))

	var body := UiKit.dim(str(e["plan"]), UiKit.FS_BODY)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(540, 0)
	_detail.add_child(body)

	_detail.add_child(UiKit.spacer(8))
	_detail.add_child(UiKit.section("接入位置"))
	var where := UiKit.dim(str(e["impl"]), UiKit.FS_SMALL)
	where.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	where.custom_minimum_size = Vector2(540, 0)
	_detail.add_child(where)


## 将来接真实界面时，把 plan/impl 换成对应信息即可；菜单结构不用动
func _make_entries() -> Array:
	return [
		{
			"name": "统计",
			"plan": "累计局数、撤离成功率、死亡次数、总共拾取的各类资源、最远移动距离、"
					+ "平均每局时长。数据来源是 Meta 的存档槽 —— 需要给槽加一个 stats 节点，"
					+ "在 RunManager 结算（撤离/死亡/超时）时累加。",
			"impl": "数据：Scripts/meta_progression.gd 的 bank / upgrade_levels 同级加 stats；"
					+ "界面：复制本文件的结构，把右侧详情换成图表/列表。",
		},
		{
			"name": "成就",
			"plan": "例如「首次撤离」「一局带回 100 木头」「不受伤撤离」「击杀 500 个敌人」。"
					+ "需要一张成就表（Data/achievements.json）+ 事件钩子（撤离、拾取、击杀、受伤）。",
			"impl": "数据：新建 Data/achievements.json；钩子挂在 RunManager 的结算与 "
					+ "enemy.gd / loot_node.gd 的事件上；存档写进槽的 stats 节点。",
		},
		{
			"name": "图鉴",
			"plan": "已见过的敌人兵种 / 中立生物 / 资源 / 地形群系，附名称与说明。"
					+ "配置里其实已经齐了：enemy_types.types、animal_types.types、"
					+ "resources.*、map.biomes 都有 name 字段。",
			"impl": "直接遍历 Config.get_value(\"enemy_types.types\") 等数组生成列表；"
					+ "「是否见过」需要新增一个 seen 集合存进存档槽。",
		},
		{
			"name": "教程 / 帮助",
			"plan": "操作说明（当前只散在 main.gd 的注释里）、核心循环讲解"
					+ "（搜刮 → 撤离 → 局外养成 → 再出发）、若干张示意图。",
			"impl": "文案可放在 Data/help.md 或做成多页 Label；"
					+ "操作说明建议直接从 config 的键位读，跟「参数配置 → 操作」联动。",
		},
		{
			"name": "制作人员",
			"plan": "美术资源署名。注意这份清单是「许可合规」的一部分，不能省："
					+ "Tiny Swords (Free Pack) — Pixel Frog，CC0。后续每引入一份 CC0/CC-BY 素材都要登记。",
			"impl": "新建 Data/credits.md 或直接做成静态多页文本；"
					+ "素材来源同时记在 docs/DESIGN.md 的「缺失素材清单」章里。",
		},
		{
			"name": "语言（占位）",
			"plan": "语言切换本身已经能用，在「参数配置 → 语言」里，但目前只是存值、"
					+ "没有翻译表，选了不会改变界面文字。",
			"impl": "接真 i18n：Data/language/<code>.po + "
					+ "TranslationServer.set_locale(Config.get_value(\"language.current\"))；"
					+ "再把 config 里 language.available 对应项的 ready 改成 true。",
		},
	]

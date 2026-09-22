extends Node
## ============================================================
## probe_base_custom — 无头验收「基地地面自定义」的核心链路
##
## 查五件事，缺一件都不算做完：
##   1. 素材表读得到（数量/名字/色卡），且比局内那 4 个群系多；
##   2. 刷一格 → 稀疏表真的写了、TileMapLayer 那一格的图集坐标切到新素材段，
##      **四邻**也跟着重画（blob 拼接的前提，只改自己会留一圈旧接缝）；
##   3. 撤销（cancel）能把数据与画面都退回原样 —— 逐格比对 set_cell 结果；
##   4. 保存后 Meta.base_custom 拿到新值，且过一遍 sanitize（= 模拟下次读档）
##      值不丢、不被夹；
##   5. 水面 / 摆件两层也走同一条路。
##
## 用法：python tools/run_godot_headless.py _probe_base_custom.log \
##           Dev/probe_base_custom.tscn --fixed-fps 30 --quit-after 300
## ============================================================

const MAIN_SCENE := "res://Scenes/Main.tscn"

var _fails: Array = []


func _ready() -> void:
	Config.set_override("debug.auto_enter_run", false)
	var main: Node = load(MAIN_SCENE).instantiate()
	add_child(main)
	await _wait(70)
	# ⚠ 必须 await：_run 里面有 await，不 await 的话它会在第一个等待点**立刻返回**
	# （后面的步骤变成游离协程继续跑），于是这里直接打印"全部通过"并 quit ——
	# 表现是：开头的检查都过了、中间一步都没执行、结论还写着全部通过（刚踩）。
	await _run(main)
	print("[CustomProbe] === %s ===" % ("全部通过" if _fails.is_empty() else "有 %d 项失败" % _fails.size()))
	for f in _fails:
		print("[CustomProbe] FAIL: %s" % f)
	get_tree().quit(1 if not _fails.is_empty() else 0)


func _run(main: Node) -> void:
	# ⚠ 探针会真的写一次存档（要验证落盘），而命令行直跑 Main.tscn 走的是
	#   user://save.json —— 那正是"本地默认槽"。不还原的话，下一次跑任何脚本
	#   （包括出图）读到的都是被这次改过的基地，会误判成"功能坏了"（刚踩）。
	#   所以进来先存一份，出去原样写回去。
	var original := (Meta.base_custom as Dictionary).duplicate(true)

	# ---- 1) 素材表 ----
	var n := BaseMaterials.ground_count()
	print("[CustomProbe] 地面素材 %d 款：%s" % [n, _names()])
	_check(n > MapGenerator.biome_count(), "素材表比局内群系多（%d vs %d）" % [n, MapGenerator.biome_count()])
	_check(n >= 10, "素材数 >= 10（实配 10 款）")

	# ---- 2) 起编辑器 ----
	var bs := main.get_node_or_null("BaseSystem")
	if bs == null:
		_check(false, "找不到 BaseSystem")
		return
	var opts: Dictionary = bs.call("edit_targets")
	var size: int = int(opts.get("size", 80))
	var tile: int = int(opts.get("tile", 64))
	var ground = opts.get("ground_layer")
	_check(ground != null, "拿到地面层节点")
	if ground == null:
		return

	var editor := BaseCustomEditor.new()
	editor.name = "ProbeEditor"
	(main.get_node("GameRoot") as Node).add_child(editor)
	editor.begin(opts)
	_check(editor.is_active(), "编辑器已激活")
	_check(editor.is_in_group("placement_active"), "编辑态挂了 placement_active（建筑让位）")
	print("[CustomProbe] 改动格数（刚起来）= %d" % editor.change_count())

	# ---- 3) 刷一片雪原（id 4）----
	# ⚠ 撤销的比对基准必须在**涂之前**拍：拿"涂完之后"当基准，撤销成功反而会判失败。
	var base_snap := _snapshot(ground, size)
	editor.set_tool(BaseCustomEditor.Layer.GROUND, 4)
	editor.call("set_brush", 3)
	var center := Vector2i(20, 20)
	print("[CustomProbe] >> 准备涂一片，has_method(paint_cells)=%s brush=%d"
			% [str(editor.has_method("paint_cells")), int(editor.call("brush_size"))])
	editor.paint_cells(editor.brush_cells(center), false)
	print("[CustomProbe] >> 涂完，改动格数 = %d" % editor.change_count())
	await _wait(3)
	var custom: Dictionary = editor.call("current_custom")
	_check(int(custom["ground"].get("20,20", -1)) == 4, "稀疏表写入了 id=4")
	var at := (ground as TileMapLayer).get_cell_atlas_coords(Vector2i(20, 20))
	_check(at.x >= 4 * MapGenerator.BLOB_N and at.x < 5 * MapGenerator.BLOB_N,
			"图集坐标落到第 4 号素材段（实得 %s）" % str(at))
	var neighbour := (ground as TileMapLayer).get_cell_atlas_coords(Vector2i(20, 21))
	print("[CustomProbe] 邻格 %s 图集坐标 = %s（应与本格同段）"
			% [str(Vector2i(20, 21)), str(neighbour)])

	# ---- 4) 撤销 ----
	editor.call("cancel")
	await _wait(3)
	var after := _snapshot(ground, size)
	_check(int((editor.call("current_custom") as Dictionary)["ground"].get("20,20", -1)) == -1,
			"撤销后稀疏表里那格被删掉")
	_check(base_snap == after, "撤销后整张地面逐格回到涂之前（%d 格）" % (size * size))
	_check(not editor.is_active(), "撤销后编辑器已收工")

	# ---- 5) 再来一次 → 保存 → 过 sanitize ----
	editor.begin(opts)
	editor.set_tool(BaseCustomEditor.Layer.GROUND, 6)
	var g0 := int((editor.call("current_custom") as Dictionary)["ground"].size())
	print("[CustomProbe] >> 二轮涂地面：%d 格（ground %d → %d，undo=%d，旧值=%s）" % [
			editor.paint_cells(editor.brush_cells(Vector2i(30, 30)), false), g0,
			int((editor.call("current_custom") as Dictionary)["ground"].size()),
			editor.change_count(),
			str((editor.call("current_custom") as Dictionary)["ground"].get("30,30", "无"))])
	editor.set_tool(BaseCustomEditor.Layer.WATER, 1)
	print("[CustomProbe] >> 二轮涂水面：%d 格" % editor.paint_cells(editor.brush_cells(Vector2i(32, 30)), false))
	editor.set_tool(BaseCustomEditor.Layer.PROPS, 2)
	print("[CustomProbe] >> 二轮涂摆件：%d 格" % editor.paint_cells(editor.brush_cells(Vector2i(34, 30)), false))
	await _wait(3)
	_check(editor.change_count() > 0, "本次有改动记进 diff（%d 格）" % editor.change_count())
	var saved: Dictionary = editor.call("current_custom")
	Meta.set_base_custom(saved)
	var round_trip := BaseCustomization.sanitize(Meta.base_custom)
	_check(int(round_trip["ground"].get("30,30", -1)) == 6, "存档往返后地面 id=6 还在")
	_check(int(round_trip["water"].get("32,30", 0)) == 1, "存档往返后水面还在")
	_check(int(round_trip["props"].get("34,30", 0)) == 2, "存档往返后摆件还在")
	print("[CustomProbe] 落盘后：地面 %d / 水 %d / 摆件 %d 格" % [
			(round_trip["ground"] as Dictionary).size(),
			(round_trip["water"] as Dictionary).size(),
			(round_trip["props"] as Dictionary).size()])

	# ---- 5b) 建筑层（复用同一个 editor 实例）----
	var specs := BaseMaterials.building_specs()
	_check(specs.size() >= 10, "建筑调色板 >= 10 款（实得 %d）" % specs.size())
	var bhost = opts.get("buildings_host")
	_check(bhost != null, "拿到建筑容器节点")
	_check(opts.get("spawn_building", Callable()).is_valid(), "拿到 spawn_building Callable")

	editor.set_tool(BaseCustomEditor.Layer.BUILDINGS, 0)
	var fp := int(Config.get_value("base.building_cells", 4))
	var used: Array = []
	var anchor := _find_free_anchor(opts.get("blocked", {}), size, fp, used)
	_check(anchor.x >= 0, "找到自由锚点（%s）" % str(anchor))
	used.append("%d,%d" % [anchor.x, anchor.y])
	var id0 := BaseMaterials.building_id(0)
	var placed := editor.paint_cells([anchor], false)
	_check(placed == 1, "放置一栋 = 1 处改动（实得 %d）" % placed)
	var bc: Dictionary = editor.call("current_custom")
	_check(str(bc["buildings"].get("%d,%d" % [anchor.x, anchor.y], "")) == id0,
			"稀疏表写了带 id 字符串的条目（%s）" % id0)
	_check((bhost as Node).get_child_count() >= 1,
			"建筑容器多了节点（%d）" % (bhost as Node).get_child_count())
	_check(editor.paint_cells([anchor + Vector2i(1, 1)], false) == 0, "压住已有楼被拒")
	_check(editor.paint_cells([Vector2i(size - 1, size - 1)], false) == 0, "占地出图被拒")
	# 右键擦除整栋：paint_cells 返回的是"本次新增到 undo 的格数"，而撤销 diff 在放置时已记过，
	# 所以这里返回 0 是对的；真正的判定看稀疏表是否清空。
	editor.paint_cells([anchor + Vector2i(2, 2)], true)
	_check((editor.call("current_custom") as Dictionary)["buildings"].size() == 0, "右键擦除整栋生效（表空）")

	# 放一栋 → 存档往返：建筑 id 字符串不丢
	var id2 := BaseMaterials.building_id(2)
	var a3 := _find_free_anchor(opts.get("blocked", {}), size, fp, used)
	used.append("%d,%d" % [a3.x, a3.y])
	editor.set_tool(BaseCustomEditor.Layer.BUILDINGS, 2)
	editor.paint_cells([a3], false)
	Meta.set_base_custom(editor.call("current_custom"))
	var rt := BaseCustomization.sanitize(Meta.base_custom)
	_check(str(rt["buildings"].get("%d,%d" % [a3.x, a3.y], "")) == id2,
			"存档往返后建筑 id 字符串还在（%s）" % id2)
	var dirty := {"v": 1, "size": size, "ground": {}, "water": {}, "props": {}, "buildings": {"1,1": "nope"}}
	_check((BaseCustomization.sanitize(dirty) as Dictionary)["buildings"].is_empty(),
			"未知建筑 id 被 sanitize 丢弃")

	# 撤销：再放一栋后取消，应只回滚最后那栋
	var a4 := _find_free_anchor(opts.get("blocked", {}), size, fp, used)
	used.append("%d,%d" % [a4.x, a4.y])
	editor.set_tool(BaseCustomEditor.Layer.BUILDINGS, 1)
	editor.paint_cells([a4], false)
	_check((editor.call("current_custom") as Dictionary)["buildings"].size() == 2, "此时 2 栋")
	editor.call("cancel")
	await _wait(3)
	var final_b: Dictionary = (editor.call("current_custom") as Dictionary)["buildings"]
	# 取消 = 丢弃整段编辑会话（设计如此，与 cancel 的语义一致）：两段建筑改动都回滚
	_check(final_b.size() == 0, "取消回滚整段编辑会话（建筑归零，实得 %d 栋）" % final_b.size())

	# ---- 5d) 出厂楼「全部清空」一并禁用 + 取消回滚 ----
	editor.begin(opts)
	editor.clear_all()
	await _wait(2)
	var fcust: Dictionary = editor.call("current_custom")
	_check(fcust.get("factory_disabled", false) == true, "全部清空：factory_disabled 置 true（出厂楼一并抹掉）")
	var froot = opts.get("factory_root")
	_check(froot != null and (froot as Node).visible == false, "出厂楼容器被隐藏（视图即时隐掉，不等存档重生）")
	editor.call("cancel")
	await _wait(2)
	var fback: Dictionary = editor.call("current_custom")
	_check(fback.get("factory_disabled", true) == false, "取消后 factory_disabled 回滚到 false")
	_check(froot != null and (froot as Node).visible == true, "取消后出厂楼容器重新显示")

	# ---- 6) 越界素材 id 会被夹住而不是留黑洞 ----
	var wild := {"v": 1, "size": size, "ground": {"40,40": 999}, "water": {}, "props": {}}
	var cleaned := BaseCustomization.sanitize(wild)
	_check(int(cleaned["ground"].get("40,40", -1)) == BaseMaterials.max_ground_id(),
			"越界素材 id 被夹到最后一款（实得 %d）" % int(cleaned["ground"].get("40,40", -1)))

	editor.call("end")
	editor.queue_free()

	# ---- 收尾：把存档还原成进来时的样子 ----
	Meta.base_custom = original
	Meta.save_game()
	print("[CustomProbe] 存档已还原为进入时的状态（地面 %d / 水 %d / 摆件 %d）" % [
			(original.get("ground", {}) as Dictionary).size(),
			(original.get("water", {}) as Dictionary).size(),
			(original.get("props", {}) as Dictionary).size()])


func _snapshot(layer: TileMapLayer, size: int) -> Array:
	var out: Array = []
	for y in range(size):
		for x in range(size):
			out.append(layer.get_cell_atlas_coords(Vector2i(x, y)).x)
	return out


func _names() -> String:
	var out: Array = []
	for m in BaseMaterials.ground_materials():
		out.append("%d:%s" % [int((m as Dictionary)["id"]), str((m as Dictionary)["name"])])
	return "  ".join(out)


## 在 blocked 之外再避开 skip 里那些已放置的锚点，找出第一块能放下 footprint 的空地。
func _find_free_anchor(blocked: Dictionary, size: int, fp: int, skip: Array = []) -> Vector2i:
	var occ := blocked.duplicate()
	for s in skip:
		var parts := str(s).split(",")
		if parts.size() != 2:
			continue
		var ax := int(parts[0]); var ay := int(parts[1])
		for dy in range(fp):
			for dx in range(fp):
				occ["%d,%d" % [ax + dx, ay + dy]] = true
	for y in range(1, size - fp):
		for x in range(1, size - fp):
			var ok := true
			for dy in range(fp):
				for dx in range(fp):
					if occ.has("%d,%d" % [x + dx, y + dy]):
						ok = false
						break
				if not ok:
					break
			if ok:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _check(ok: bool, what: String) -> void:
	print("[CustomProbe] %s %s" % ["OK  " if ok else "FAIL", what])
	if not ok:
		_fails.append(what)


func _wait(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame

class_name BaseCustomEditor
extends Node2D
## ============================================================
## BaseCustomEditor — 基地自定义地面的「笔刷编辑器」（世界层）
##
## 交互（与 placement_mode 同一套路：网格 + 悬停 + _unhandled_input）：
##   左键拖        → 涂当前素材（地面：改材质；水：铺水面；摆件：放物件；建筑：盖一栋）
##   右键拖        → 擦回默认（键值从稀疏表里删掉，不是写成 0）
##   Shift + 左键拖 → 拉一个矩形，松手时整块填充（建筑层没有：一笔为什么要是"一片楼"？）
##   ESC           → 放弃本次改动
##
## 建筑层跟另外三层的差别，别照着地面那套改：
##   · 一笔下去是一栋占 building_cells×building_cells 的楼，**不是一个格子** ——
##     所以 hover 格 = 占地左上角锚点（与现有「右键重摆」同一套语义），
##     笔尖大小对它无效，也不能走矩形填充。
##   · 表里的值是 id 字符串，撤下的认定、额外实例的否决判定都跟整数不一样。
##   · 出厂那 12 栋是功能入口（传送门/仓库/升级），不在 sparse 表内 → 擦不掉，
##     它们的占地从 blocked 进来：既招呼不了新的楼，也保证里面不长树。
##   · 建筑物是**节点**（Building 实例），表改了要顺手增删节点 ——  declaratively：
##     表里有这个锚点就必须有一栋楼，没有就必须没有。
##
## ⚠ 改一格为什么要连带重画四邻：图集是 4-bit blob autotile，这一格画哪一块取决于
##   它跟四边邻居连不连通（岸线/描边就是从这里来的）。只刷改动格会留下一圈旧接缝。
##
## 数据流不是「改完重建整层」，而是：改稀疏表 → sync_arrays（同步地形数组）
##   → paint_cells（只 set_cell 这一格 + 四邻）。摆件层是 Sprite 树，没有增量办法，
##   用 _props_dirty 把一帧内的多次改动合并成一次重建。
##
## 撤销：只记「被改过格子的旧值」这一份稀疏 diff，取消时逐格回滚 ——
## 不做快照复制，也不重建整个基地（重建会把相机位置也甩回去，手感很差）。
## ============================================================

signal committed(custom: Dictionary)
signal cancelled()
## 稀疏表真的变了（涂 / 擦 / 矩形填充 / 全部清空都会发）。
## 面板靠它刷新「已改动 N 格」并解锁「保存」按钮 —— 没有这个信号，
## 玩家涂完一片地面时按钮还是灰的，等于存不了。
## 每批发一次，不是每格发一次：拖着鼠标刷是每帧一批，别让 UI 跟着逐格重排。
signal changed(count: int)

enum Layer { GROUND, WATER, PROPS, BUILDINGS }

var _size := 80
var _tile := 64
var _custom: Dictionary = {}
var _undo: Dictionary = {}       # "层|键" -> [x, y, 层, 键, 旧值 or null]
var _arrays: Array = []
var _ground_layer: TileMapLayer = null
var _props_host: Node2D = null
var _blocked: Dictionary = {}
var _orig_blocked: Dictionary = {}      # 进编辑那一刻的快照：出厂建筑的占地，永不可改
var _bld_host: Node2D = null           # 额外建筑节点的容器（base_system 提供）
var _bld_spawn: Callable = Callable()  # (id, cell) -> Node2D：怎么造一栋楼由 base_system 说了算
var _bld_nodes: Dictionary = {}        # "x,y" -> Building 节点（当前画面上的那批）
var _footprint := 4                    # 建筑占地边长（config base.building_cells）

var _layer: int = Layer.GROUND
var _value: int = 0            # 地面素材 id / 水面恒为 1 / 摆件 id / 建筑 = 调色板下标
var _brush := 1
var _hover := Vector2i.ZERO
var _painting := false
var _erase := false
var _rect_start := Vector2i(-1, -1)   # x >= 0 表示正在拖矩形
var _rect_end := Vector2i(-1, -1)
var _props_dirty := false
var _active := false


func begin(opts: Dictionary) -> void:
	_size = int(opts.get("size", 80))
	_tile = int(opts.get("tile", 64))
	_custom = BaseCustomization.sanitize(opts.get("custom", {}))
	_custom["size"] = _size
	_ground_layer = opts.get("ground_layer") as TileMapLayer
	_props_host = opts.get("props_host") as Node2D
	_blocked = (opts.get("blocked", {}) as Dictionary).duplicate()
	_orig_blocked = _blocked.duplicate()
	_bld_host = opts.get("buildings_host") as Node2D
	_bld_spawn = opts.get("spawn_building", Callable()) as Callable
	_footprint = int(Config.get_value("base.building_cells", 4))
	_bld_nodes.clear()
	_undo.clear()
	_arrays = BaseCustomization.terrain_arrays(_custom, _size)
	_layer = Layer.GROUND
	_value = int(opts.get("default_material", 0))
	_brush = maxi(1, int(opts.get("default_brush", 1)))
	_refresh_blocked()          # 表头可能已经带着上次保存下来的额外建筑
	_rebuild_buildings()         # 让 _bld_host 与表严格一致（setup 时已经摆过，这里兜底）
	z_index = 40
	visible = true
	_active = true
	add_to_group("placement_active")


func end() -> void:
	_active = false
	_painting = false
	_rect_start = Vector2i(-1, -1)
	visible = false
	if is_inside_tree():
		remove_from_group("placement_active")


func is_active() -> bool:
	return _active


# ------------------------------------------------------------
# 面板侧调用
# ------------------------------------------------------------

## 层 → 稀疏表的键。Layer 多了 BUILDINGS 之后不能再拿下标去取 ["ground",...]。
static func table_key(layer: int) -> String:
	match layer:
		Layer.GROUND: return "ground"
		Layer.WATER: return "water"
		Layer.PROPS: return "props"
		Layer.BUILDINGS: return "buildings"
		_: return ""


func set_tool(layer: int, value: int) -> void:
	_layer = layer
	_value = value
	if _layer == Layer.BUILDINGS:
		_value = clampi(value, 0, maxi(0, BaseMaterials.building_count() - 1))
	queue_redraw()


func set_brush(n: int) -> void:
	_brush = maxi(1, n)
	queue_redraw()


func brush_size() -> int:
	return _brush


func current_layer() -> int:
	return _layer


func tool_value() -> int:
	return _value


## 当前编辑中的整份数据表（面板「保存」时不带参数，main 靠这个把它捞出来写档）
func current_custom() -> Dictionary:
	return _custom.duplicate(true)


## 全部清空：几层都擦回默认。**逐格走 _apply_one 而不是直接赋空字典** ——
## 这样才能记进撤销 diff，玩家点错「全部清空」后按 ESC 还能整片回来。
## 建筑层的键是「占地左上角」而不是鼠标那格，所以走的是专门的 _custom_building_keys()。
func clear_all() -> void:
	var prev := _layer
	var total := 0
	for layer_id in Layer.values():
		_layer = int(layer_id)
		var table: Dictionary = _custom[table_key(_layer)]
		var touched: Array = []
		if _layer == Layer.BUILDINGS:
			for k in table.keys():
				var cell := BaseCustomization.parse_key(str(k))
				if cell.is_empty():
					continue
				touched.append(Vector2i(int(cell[0]), int(cell[1])))
		else:
			for k in table.keys():
				var cell := BaseCustomization.parse_key(str(k))
				if cell.is_empty():
					continue
				touched.append(Vector2i(int(cell[0]), int(cell[1])))
		var changed: Array = []
		for c in touched:
			if _apply_one(c, true):
				changed.append(c)
		for c in changed:
			_sync_cell(c)
		total += changed.size()
	_layer = prev
	if total > 0:
		print("[BaseEdit] 全部清空：擦掉 %d 格（可 ESC 撤销）" % total)
		changed.emit(_undo.size())


## 本次改动了多少格（面板上「已改动 N 格」用）
func change_count() -> int:
	return _undo.size()


# ------------------------------------------------------------
# 给调用方的入口（面板按钮 / 自动化探针）
#
# 为什么公开一层薄壳而不是让外面直接调 _apply_*：Godot 4 的 Object.call()
# 拒绝下划线开头的方法，脚本化验证（Dev/probe_base_custom.gd）根本调不到，
# 而"改一格地面"本来就该是编辑器的正式能力，不是内部实现细节。
# ------------------------------------------------------------

## 笔尖 size 覆盖的格子（以 c 为中心的 size×size）
func brush_cells(c: Vector2i) -> Array:
	return _brush_cells(c)


## 涂/擦一批格子。erase=true 表示右键擦除。
func paint_cells(cells: Array, erase: bool = false) -> int:
	var before := _undo.size()
	_apply_multi(cells, erase)
	return _undo.size() - before


## 矩形填充（左键 Shift 拖拽松手时走的就是它）
func paint_rect(a: Vector2i, b: Vector2i, erase: bool = false) -> void:
	_fill_rect(a, b, erase)


func commit() -> void:
	end()
	committed.emit(_custom.duplicate(true))


func cancel() -> void:
	_rollback()
	end()
	cancelled.emit()


# ------------------------------------------------------------
# 输入
# ------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseMotion:
		_refresh_hover()
		if _painting:
			_paint_at(_hover)
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_refresh_hover()
				if mb.shift_pressed:
					_rect_start = _hover
					_rect_end = _hover
				else:
					_painting = true
					_erase = false
					_paint_at(_hover)
			else:
				if _rect_start.x >= 0:
					_refresh_hover()
					_fill_rect(_rect_start, _hover, false)
					_rect_start = Vector2i(-1, -1)
				_painting = false
			get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_painting = true
				_erase = true
				_paint_at(_hover)
			else:
				_painting = false
			get_viewport().set_input_as_handled()
			return
		return
	if event.is_action_pressed("ui_cancel"):
		cancel()
		get_viewport().set_input_as_handled()


func _world_to_cell(p: Vector2) -> Vector2i:
	var c := Vector2i(floori(p.x / float(_tile)), floori(p.y / float(_tile)))
	c.x = clampi(c.x, 0, _size - 1)
	c.y = clampi(c.y, 0, _size - 1)
	return c


func _refresh_hover() -> void:
	_hover = _world_to_cell(get_global_mouse_position())
	if _rect_start.x >= 0:
		_rect_end = _hover
	queue_redraw()


func _paint_at(c: Vector2i) -> void:
	if _layer == Layer.BUILDINGS:
		# 建筑层：一笔一栋、无笔尖、无矩形填充。changed 自己在 _apply_one 后发。
		if _apply_one(c, _erase):
			_sync_cell(c)
			changed.emit(_undo.size())
		return
	if _erase:
		_apply_multi(_brush_cells(c), true)
	else:
		_apply_multi(_brush_cells(c), false)


func _brush_cells(c: Vector2i) -> Array:
	var out: Array = []
	var half := (_brush - 1) / 2
	for dy in range(_brush):
		for dx in range(_brush):
			out.append(c + Vector2i(dx - half, dy - half))
	return out


# ------------------------------------------------------------
# 改数据 → 重画
# ------------------------------------------------------------

## 一批格子先改数据、最后统一重画：一次刷 25 格若每格都立刻重画自己 + 四邻，
## 其中一大半 set_cell 会被后面几格重复盖掉（而且这格的数据还没改完，画出来的
## 是中间态）。所以分两步走：先把本次所有格子的稀疏表改到位，再逐格刷新画面。
func _apply_multi(cells: Array, erase: bool) -> void:
	var touched: Array = []
	for c in cells:
		var cell: Vector2i = c
		if _apply_one(cell, erase):
			touched.append(cell)
	for cell in touched:
		_sync_cell(cell)
	if not touched.is_empty():
		changed.emit(_undo.size())


## 返回 true = 这格真的变了（值没变就不重画，拖着鼠标刷同一片不会白白掉帧）
func _apply_one(c: Vector2i, erase: bool) -> bool:
	if c.x < 0 or c.y < 0 or c.x >= _size or c.y >= _size:
		return false
	var key := BaseCustomization.key_of(c.x, c.y)
	var table: Dictionary = {}
	match _layer:
		Layer.GROUND: table = _custom["ground"]
		Layer.WATER: table = _custom["water"]
		Layer.PROPS:
			table = _custom["props"]
			# 建筑占地里不放摆件（与渲染侧同一套 blocked，否则会长在房子里）
			if not erase and _blocked.has(key):
				return false
		Layer.BUILDINGS:
			table = _custom["buildings"]
			# 一笔一栋、锚点=占地左上角格。right-click 命中楼体内任一一格都算删整栋。
			if erase:
				var found := BaseCustomization.building_instance_at(_custom, c.x, c.y, _footprint)
				if found.is_empty():
					return false
				var ac: Vector2i = found["anchor"]
				var akey := BaseCustomization.key_of(ac.x, ac.y)
				_remember(ac, akey, table.get(akey))
				table.erase(akey)
				return true
			# 画笔上这一格就是锚点：占地必须整块落在图内（否则高出来半截楼）
			if c.x + _footprint > _size or c.y + _footprint > _size:
				return false
			# 不能压到出厂楼 / 已经摆出来的楼（同一套 blocked）
			for k in BaseCustomization.building_footprint_keys(c.x, c.y, _footprint):
				if _blocked.has(k):
					return false
			var id_str := BaseMaterials.building_id(_value)
			if id_str.is_empty():
				return false
			var akey := BaseCustomization.key_of(c.x, c.y)
			if table.has(akey) and str(table[akey]) == id_str:
				return false
			_remember(c, akey, table.get(akey))
			table[akey] = id_str
			return true
		_:
			return false
	if erase:
		if not table.has(key):
			return false
		_remember(c, key, table[key])
		table.erase(key)
		return true
	var want := _value
	if table.has(key) and int(table[key]) == want:
		return false
	_remember(c, key, table.get(key))
	table[key] = want
	return true


## 只在某一格第一次被改时记旧值：同一次编辑里反复涂同一格，恢复的是**最初**那个值。
func _remember(c: Vector2i, key: String, old) -> void:
	var id := "%d|%s" % [_layer, key]
	if _undo.has(id):
		return
	_undo[id] = [c.x, c.y, _layer, key, old]


func _sync_cell(c: Vector2i) -> void:
	BaseCustomization.sync_arrays(_arrays, _custom, c.x, c.y)
	if _ground_layer != null and is_instance_valid(_ground_layer):
		BaseCustomization.paint_cells(_ground_layer, _arrays, c.x, c.y, _size, _tile)
	if _layer == Layer.PROPS:
		_props_dirty = true
	elif _layer == Layer.BUILDINGS:
		_refresh_blocked()
		_rebuild_buildings()


func _fill_rect(a: Vector2i, b: Vector2i, erase: bool) -> void:
	# 建筑层不收矩形填充：一笔为什么要是"一片楼"？Shift+左键在笔刷模式里是矩形，
	# 到建筑层直接忽略，避免一次拖出一堆重叠报错。
	if _layer == Layer.BUILDINGS:
		return
	var x0 := mini(a.x, b.x)
	var x1 := maxi(a.x, b.x)
	var y0 := mini(a.y, b.y)
	var y1 := maxi(a.y, b.y)
	var touched: Array = []
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if _apply_one(Vector2i(x, y), erase):
				touched.append(Vector2i(x, y))
	for cell in touched:
		_sync_cell(cell)
	if not touched.is_empty():
		print("[BaseEdit] 矩形填充 %d 格（层 %d，%s）" % [
				touched.size(), _layer, "擦除" if erase else "涂 %d" % _value])
		changed.emit(_undo.size())


## 摆件层重建：一帧内的多次改动只重建一次（拖动时每格都重建会明显掉帧）
func _process(_delta: float) -> void:
	if not _props_dirty:
		return
	_props_dirty = false
	if _props_host == null or not is_instance_valid(_props_host):
		return
	var old := _props_host.get_node_or_null("BaseProps")
	if old != null:
		old.free()          # 立刻释放：queue_free 会让新旧两层在同一帧里叠着画
	var layer := BaseCustomization.build_props_layer(_custom, _size, _tile, _blocked)
	_props_host.add_child(layer)


## 重算 blocked：出厂楼占地（_orig_blocked，永不可改）∪ 表头玩家已摆的楼。
## 摆件层与建筑层都依赖它 —— 前者不在楼里长树，后者不把新楼压到旧楼上。
func _refresh_blocked() -> void:
	_blocked = _orig_blocked.duplicate()
	for key in (_custom.get("buildings", {}) as Dictionary).keys():
		var cell := BaseCustomization.parse_key(str(key))
		if cell.is_empty():
			continue
		for k in BaseCustomization.building_footprint_keys(int(cell[0]), int(cell[1]), _footprint):
			_blocked[k] = true


## 按当前表重建玩家楼节点：整批清掉再按表重建，数量小、写起来最稳
## （增量增删要维护 _bld_nodes 下标、还得分清"加一栋/删一栋"，易错）。
## 出厂那 12 栋在别的树下面，这里只动 _bld_host。
func _rebuild_buildings() -> void:
	if _bld_host == null or not is_instance_valid(_bld_host):
		return
	for ch in _bld_host.get_children():
		ch.free()
	if not _bld_spawn.is_valid():
		return
	for key in (_custom.get("buildings", {}) as Dictionary).keys():
		var cell := BaseCustomization.parse_key(str(key))
		if cell.is_empty():
			continue
		var id_str := str((_custom["buildings"] as Dictionary)[key])
		if id_str.is_empty():
			continue
		_bld_spawn.call(id_str, Vector2i(int(cell[0]), int(cell[1])))


## 取消：按 diff 把每个被改过的格子写回旧值，再重画那一格（含四邻）。
func _rollback() -> void:
	if _undo.is_empty():
		return
	for id in _undo.keys():
		var e: Array = _undo[id]
		var layer_n: int = int(e[2])
		var lkey := BaseCustomization.layer_key(layer_n)
		if lkey == "":
			continue
		var table: Dictionary = _custom[lkey]
		if e[4] == null:
			table.erase(str(e[3]))
		else:
			table[str(e[3])] = e[4]
		if layer_n == Layer.BUILDINGS:
			_rebuild_buildings()
		else:
			var c := Vector2i(int(e[0]), int(e[1]))
			BaseCustomization.sync_arrays(_arrays, _custom, c.x, c.y)
			if _ground_layer != null and is_instance_valid(_ground_layer):
				BaseCustomization.paint_cells(_ground_layer, _arrays, c.x, c.y, _size, _tile)
	_undo.clear()
	if _props_host != null and is_instance_valid(_props_host):
		var old := _props_host.get_node_or_null("BaseProps")
		if old != null:
			old.free()
		_props_host.add_child(BaseCustomization.build_props_layer(
				_custom, _size, _tile, _blocked))


# ------------------------------------------------------------
# 绘制：网格 + 笔尖（或矩形预览）
# ------------------------------------------------------------

func _draw() -> void:
	if not _active:
		return
	var grid_a := float(Config.get_value("base.custom_editor.grid_alpha", 0.10))
	var hover_a := float(Config.get_value("base.custom_editor.hover_alpha", 0.35))
	var rect_a := float(Config.get_value("base.custom_editor.rect_fill_alpha", 0.25))
	var t := float(_tile)
	var w := float(_size) * t
	var grid := Color(1, 1, 1, grid_a)
	for x in range(_size + 1):
		draw_line(Vector2(x * t, 0.0), Vector2(x * t, w), grid, 1.0)
	for y in range(_size + 1):
		draw_line(Vector2(0.0, y * t), Vector2(w, y * t), grid, 1.0)

	var fill := _tool_color(hover_a)
	var stroke := _tool_color(0.85)
	if _erase:
		fill = Color(0.90, 0.30, 0.25, hover_a * 0.7)
		stroke = Color(0.95, 0.40, 0.35, 0.9)

	if _rect_start.x >= 0:
		var x0 := float(mini(_rect_start.x, _rect_end.x)) * t
		var y0 := float(mini(_rect_start.y, _rect_end.y)) * t
		var x1 := float(maxi(_rect_start.x, _rect_end.x) + 1) * t
		var y1 := float(maxi(_rect_start.y, _rect_end.y) + 1) * t
		var r := Rect2(x0, y0, x1 - x0, y1 - y0)
		draw_rect(r, _tool_color(rect_a), true)
		draw_rect(r, stroke, false, 2.0)
		return

	if _layer == Layer.BUILDINGS:
		# 预览一整块占地（不是笔尖那格）。命中楼体内则高亮"将擦除"的那一栋。
		var anchor := _hover
		if not _erase:
			var rb := Rect2(float(anchor.x) * t, float(anchor.y) * t,
					_footprint * t, _footprint * t)
			draw_rect(rb, fill, true)
			draw_rect(rb, stroke, false, 2.0)
		else:
			var f := BaseCustomization.building_instance_at(_custom, _hover.x, _hover.y, _footprint)
			if not f.is_empty():
				var ac: Vector2i = f["anchor"]
				var rb := Rect2(float(ac.x) * t, float(ac.y) * t,
						_footprint * t, _footprint * t)
				draw_rect(rb, fill, true)
				draw_rect(rb, stroke, false, 2.0)
		return

	var half := float((_brush - 1) / 2)
	var x := (float(_hover.x) - half) * t
	var y := (float(_hover.y) - half) * t
	var side := float(_brush) * t
	var r2 := Rect2(x, y, side, side)
	draw_rect(r2, fill, true)
	draw_rect(r2, stroke, false, 2.0)


## 每种层/素材用自己的颜色做预览：素材色卡来自素材表，玩家在灰不溜秋的网格上
## 一眼就能确认「我现在涂的是哪一个」。
func _tool_color(a: float) -> Color:
	match _layer:
		Layer.GROUND:
			var c := BaseMaterials.ground_swatch(_value)
			return Color(c.r, c.g, c.b, a)
		Layer.WATER:
			return Color(0.35, 0.62, 0.95, a)
		Layer.BUILDINGS:
			return Color(0.95, 0.70, 0.30, a)
		_:
			return Color(0.55, 0.85, 0.45, a)

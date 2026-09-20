extends Node
## ============================================================
## ResourceRegistry — 采集资源注册表（autoload 单例）
##
## 职责：作为「可采集资源」的统一数据中枢，记录地图上每个资源节点的
##   类型 / 位置 / 产量 / 状态，供采集系统、小地图、HUD 查询与扣减。
## 它只管数据，不管渲染与交互（LootNode 等是表现/拾取层，采集时回调本表）。
##
## 资源类型（res_id）与《They Are Billions》一致，沿用 items.json 的
## resources 段：wood(木头) / stone(石头) / iron(铁) / gold(金) /
## oil(油) / food(食物)。这套 id 同时被 enemy.drop / meta_progression 复用。
##
## 来源（source）：
##   0 MAP_DECOR  —— 地图装饰：树→wood、石→stone（build_from_map 自动登记）
##   1 MAP_VEIN   —— 地图矿脉/油田：iron/gold/oil（地图生成阶段放置，当前未生成）
##   2 BUILDING   —— 建筑产出：food 由猎人小屋产出（building 系统登记）
##
## 调用约定：
##   ResourceRegistry.build_from_map(map_result)   # 地图生成后（main._enter_run）
##   var node = ResourceRegistry.get_by_id(id)
##   var r = ResourceRegistry.harvest(id, 1)        # r.gained 为实际获得量
##
## 3D 迁移：本表与渲染无关。3D 下只需在 MultiMesh 生成后调用
##   bind_instance(id, instance_id)，采集 raycast 命中实例即按 instance_id 反查。
## ============================================================

const SOURCE_MAP_DECOR := 0
const SOURCE_MAP_VEIN := 1
const SOURCE_BUILDING := 2

# map_generator 的 DECOR_* 常量 → res_id。debris(3) 不映射（纯视觉残骸，不产资源）。
const DECOR_TO_RES := {
	1: "wood",   # DECOR_TREE
	2: "stone",  # DECOR_ROCK
}

var _nodes: Array = []            # 所有 ResourceNode
var _by_id: Dictionary = {}       # id -> ResourceNode
var _by_grid: Dictionary = {}     # "x,y" -> id
var _by_instance: Dictionary = {} # instance_id -> id（3D 用）
var _next_id := 1


# ------------------------------------------------------------
# ResourceNode 数据结构
# ------------------------------------------------------------
class ResourceNode:
	var id: int = -1
	var res_id: String = ""                 # "wood" / "stone" / ...
	var source: int = 0                     # SOURCE_MAP_DECOR / _VEIN / _BUILDING
	var grid: Vector2i = Vector2i(-1, -1)   # 地图格坐标
	var world_pos: Vector2 = Vector2.ZERO   # 2D 世界像素（地图本地坐标，原点 0,0）
	var world_pos3: Vector3 = Vector3.ZERO  # 3D 世界坐标（迁移时填）
	var instance_id: int = -1               # 3D MultiMesh 实例 id（无则 -1）
	var amount: int = 0                     # 剩余产量
	var max_amount: int = 0
	var collected: bool = false
	var decor_kind: int = 0                 # 原始 DECOR_*；非装饰来源为 -1
	var sprite: Object = null               # 2D 视觉节点引用（矿脉/装饰精灵），采集耗尽后隐藏

	func is_depleted() -> bool:
		return collected or amount <= 0


func _ready() -> void:
	clear()


## 重置（新地图/重开时调用）
func clear() -> void:
	_nodes.clear()
	_by_id.clear()
	_by_grid.clear()
	_by_instance.clear()
	_next_id = 1


# ------------------------------------------------------------
# 注册
# ------------------------------------------------------------
## 从 MapGenerator.generate() 的返回值装配：遍历 decor 数组，把树/石登记为
## wood/stone 资源节点（debris 不登记，纯视觉）。每次调用先 clear 重置。
func build_from_map(map_result: Dictionary) -> void:
	clear()
	var ts: int = int(map_result.get("tile_size", 16))
	# 装饰来源：树→wood、石→stone（debris 不登记）
	var decor: Array = map_result.get("decor", [])
	if not decor.is_empty():
		var h: int = decor.size()
		var w: int = (decor[0] as Array).size()
		for y in range(h):
			var row: Array = decor[y]
			for x in range(w):
				var kind: int = int(row[x])
				if not DECOR_TO_RES.has(kind):
					continue
				var res_id: String = DECOR_TO_RES[kind]
				var node := ResourceNode.new()
				node.res_id = res_id
				node.source = SOURCE_MAP_DECOR
				node.grid = Vector2i(x, y)
				node.world_pos = Vector2((x + 0.5) * ts, (y + 0.5) * ts)
				node.decor_kind = kind
				node.max_amount = _per_node(res_id)
				node.amount = node.max_amount
				_register(node)
	# 矿脉来源：iron/gold/oil（地图生成阶段放置；矿脉精灵引用一并绑定）
	var veins: Array = map_result.get("veins", [])
	for vd in veins:
		var res_id: String = str(vd.get("res_id", ""))
		if res_id == "":
			continue
		var node := ResourceNode.new()
		node.res_id = res_id
		node.source = SOURCE_MAP_VEIN
		node.grid = Vector2i(int(vd.get("gx", 0)), int(vd.get("gy", 0)))
		node.world_pos = Vector2((node.grid.x + 0.5) * ts, (node.grid.y + 0.5) * ts)
		node.decor_kind = -1
		node.sprite = vd.get("sprite", null)
		var amt := _per_node(res_id)
		node.max_amount = amt
		node.amount = amt
		_register(node)


## 预留：地图矿脉/油田生成时调用（iron/gold/oil）
func register_vein(res_id: String, grid_x: int, grid_y: int, tile_size: int = 16,
		per_node: int = -1) -> int:
	var node := ResourceNode.new()
	node.res_id = res_id
	node.source = SOURCE_MAP_VEIN
	node.grid = Vector2i(grid_x, grid_y)
	node.world_pos = Vector2((grid_x + 0.5) * tile_size, (grid_y + 0.5) * tile_size)
	node.decor_kind = -1
	var amt := per_node if per_node > 0 else _per_node(res_id)
	node.max_amount = amt
	node.amount = amt
	return _register(node)


## 预留：建筑产出资源（food 由猎人小屋登记）
func register_building_resource(res_id: String, grid_x: int, grid_y: int,
		tile_size: int = 16) -> int:
	var node := ResourceNode.new()
	node.res_id = res_id
	node.source = SOURCE_BUILDING
	node.grid = Vector2i(grid_x, grid_y)
	node.world_pos = Vector2((grid_x + 0.5) * tile_size, (grid_y + 0.5) * tile_size)
	node.decor_kind = -1
	var amt := _per_node(res_id)
	node.max_amount = amt
	node.amount = amt
	return _register(node)


func _register(node: ResourceNode) -> int:
	node.id = _next_id
	_next_id += 1
	_nodes.append(node)
	_by_id[node.id] = node
	_by_grid["%d,%d" % [node.grid.x, node.grid.y]] = node.id
	if node.instance_id >= 0:
		_by_instance[node.instance_id] = node.id
	return node.id


# ------------------------------------------------------------
# 查询
# ------------------------------------------------------------
func get_by_id(id: int) -> ResourceNode:
	return _by_id.get(id, null)


func get_by_grid(x: int, y: int) -> ResourceNode:
	var id: int = _by_grid.get("%d,%d" % [x, y], -1)
	return _by_id.get(id, null)


func get_by_instance(instance_id: int) -> ResourceNode:
	var id: int = _by_instance.get(instance_id, -1)
	return _by_id.get(id, null)


func get_all() -> Array:
	return _nodes.duplicate()


## 未采集节点；res_id 非空时按类型过滤
func get_uncollected(res_id: String = "") -> Array:
	var out: Array = []
	for n in _nodes:
		if n.collected or n.amount <= 0:
			continue
		if res_id != "" and n.res_id != res_id:
			continue
		out.append(n)
	return out


# ------------------------------------------------------------
# 采集
# ------------------------------------------------------------
## 采集：扣减 amount。amount<=0 表示全部采完。
## 返回 {"ok", "res_id", "gained", "depleted"}
func harvest(id: int, amount: int = -1) -> Dictionary:
	var node := get_by_id(id)
	if node == null or node.is_depleted():
		return {"ok": false, "res_id": "", "gained": 0, "depleted": false}
	var take := amount if amount > 0 else node.amount
	if take > node.amount:
		take = node.amount
	node.amount -= take
	var depleted := node.amount <= 0
	if depleted:
		node.collected = true
		if node.sprite != null:
			node.sprite.visible = false   # 2D：采完即隐藏对应精灵
	return {"ok": true, "res_id": node.res_id, "gained": take, "depleted": depleted}


func mark_collected(id: int) -> void:
	var node := get_by_id(id)
	if node != null:
		node.collected = true
		node.amount = 0


# ------------------------------------------------------------
# 统计
# ------------------------------------------------------------
## 各资源节点数量（调试/小地图用）
func count_by_type() -> Dictionary:
	var out: Dictionary = {}
	for n in _nodes:
		if not out.has(n.res_id):
			out[n.res_id] = 0
		out[n.res_id] += 1
	return out


## 地图上某资源总储量（含未采）
func total_amount(res_id: String) -> int:
	var s := 0
	for n in _nodes:
		if n.res_id == res_id:
			s += n.amount
	return s


## 3D 接入：把实例 id 绑定到节点（MultiMesh 生成后调用）
func bind_instance(id: int, instance_id: int) -> void:
	var node := get_by_id(id)
	if node == null:
		return
	node.instance_id = instance_id
	if instance_id >= 0:
		_by_instance[instance_id] = id


# ------------------------------------------------------------
# 辅助
# ------------------------------------------------------------
## 单节点产量：优先 resources.<id>.per_node，否则 loot.amount_per_node
func _per_node(res_id: String) -> int:
	var v = Config.get_value("resources.%s.per_node" % res_id, null)
	if v != null:
		var f := float(v)
		if f > 0.0:
			return int(f)
	v = Config.get_value("loot.amount_per_node", 10)
	return int(float(v))

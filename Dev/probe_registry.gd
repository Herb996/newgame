extends Node
## 地图 + 资源注册表验证探针（回归用）
## 运行：Godot --headless --path . Dev/probe_registry.tscn
##
## 覆盖：
##   A 群系：4 种（草地/荒原/森林/雪原）都出现，且草地占比最大（权重 3.4 → 大部分平地）
##   B 装饰：树/石/残骸/裂缝/河水 计数与配置相符（裂缝/河水 > 0）
##   C 矿脉：iron/gold/oil 全部生成，且**只落在限定群系**（荒原）
##   D 地形减速：雪原格 speed<1、水格 speed≤river.slow、普通格 ==1
##   E 注册表：build_from_map → harvest 扣减 → get_by_grid 反查 → 总储量一致
##
## 用 _check 收集失败而不是 assert：assert 会中断 _ready 导致进程不退出。

var _fails: Array = []
var _checks := 0


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("[Probe] OK   %s" % msg)
	else:
		_fails.append(msg)
		print("[Probe] FAIL %s" % msg)


func _ready() -> void:
	var result: Dictionary = MapGenerator.generate()
	ResourceRegistry.build_from_map(result)

	_probe_biomes(result)
	_probe_decor(result)
	_probe_veins(result)
	_probe_speed(result)
	_probe_registry()

	print("[Probe] ==== 共 %d 项断言，失败 %d 项 ====" % [_checks, _fails.size()])
	for m in _fails:
		print("[Probe] !! %s" % m)
	get_tree().quit(0 if _fails.is_empty() else 1)


# ------------------------------------------------------------ A 群系
func _probe_biomes(result: Dictionary) -> void:
	var biome: Array = result["biome"]
	var w: int = biome[0].size()
	var h: int = biome.size()
	var n: int = MapGenerator.biome_count()
	var tally: Array = []
	tally.resize(n)
	for i in range(n):
		tally[i] = 0
	for y in range(h):
		for x in range(w):
			var b: int = int(biome[y][x])
			if b >= 0 and b < n:
				tally[b] = int(tally[b]) + 1

	var names: Array = []
	for i in range(n):
		names.append(str(MapGenerator.biome_name(i)))
	print("[Probe] 群系分布：%s" % str(
			_pairs(names, tally)))

	_check(n == 4, "群系数 = 4（草地/荒原/森林/雪原），实际 %d" % n)
	for i in range(n):
		_check(int(tally[i]) > 0, "群系 %d「%s」有格数 %d（应 > 0）"
				% [i, names[i], int(tally[i])])
	# 草地权重 3.4 是最大的 → 格数最多（"大部分平地"）
	var max_i := 0
	for i in range(n):
		if int(tally[i]) > int(tally[max_i]):
			max_i = i
	_check(max_i == 0, "格数最多的群系是「%s」(id=%d，%d 格)；期望草地(id=0)"
			% [names[max_i], max_i, int(tally[max_i])])

	# 权重边界：单调递增、末项 = 1.0
	var edges: Array = MapGenerator.biome_weight_edges()
	var mono := true
	for i in range(1, edges.size()):
		if float(edges[i]) <= float(edges[i - 1]):
			mono = false
	_check(edges.size() == n and mono and absf(float(edges[edges.size() - 1]) - 1.0) < 1e-6,
			"权重边界单调递增且末项=1.0：%s" % str(edges))
	_check(float(edges[0]) > 0.4,
			"草地独占噪声区间 %.3f（应 > 0.4，即大部分平地）" % float(edges[0]))

	# 面积占比 == 权重占比（分位数边界的意义所在；固定阈值做不到这点）
	var wsum := 0.0
	for i in range(n):
		wsum += MapGenerator.biome_weight(i)
	var total_cells: float = float(w * h)
	for i in range(n):
		var want: float = MapGenerator.biome_weight(i) / wsum
		var got: float = float(tally[i]) / total_cells
		_check(absf(got - want) < 0.05,
				"群系 %d「%s」面积占比 %.1f%%（权重期望 %.1f%%，容差 5pp）"
				% [i, names[i], got * 100.0, want * 100.0])


# ------------------------------------------------------------ B 装饰
func _probe_decor(result: Dictionary) -> void:
	var decor: Array = result["decor"]
	var w: int = decor[0].size()
	var h: int = decor.size()
	var tally := {
		MapGenerator.DECOR_TREE: 0,
		MapGenerator.DECOR_ROCK: 0,
		MapGenerator.DECOR_DEBRIS: 0,
		MapGenerator.DECOR_CRACK: 0,
		MapGenerator.DECOR_WATER: 0,
	}
	for y in range(h):
		for x in range(w):
			var k: int = int(decor[y][x])
			if tally.has(k):
				tally[k] = int(tally[k]) + 1
	print("[Probe] 装饰物：树 %d / 石 %d / 残骸 %d / 裂缝 %d / 河水 %d" % [
		int(tally[MapGenerator.DECOR_TREE]), int(tally[MapGenerator.DECOR_ROCK]),
		int(tally[MapGenerator.DECOR_DEBRIS]), int(tally[MapGenerator.DECOR_CRACK]),
		int(tally[MapGenerator.DECOR_WATER])])

	for k in [MapGenerator.DECOR_TREE, MapGenerator.DECOR_ROCK,
			MapGenerator.DECOR_DEBRIS, MapGenerator.DECOR_CRACK,
			MapGenerator.DECOR_WATER]:
		_check(int(tally[k]) > 0, "装饰 kind=%d 数量 %d（应 > 0）" % [k, int(tally[k])])

	# 裂缝/河水必须**不阻挡通行**：有这些装饰的格 walls 必须为 false
	var walls: Array = result["walls"]
	var water_blocked := 0
	var crack_blocked := 0
	for y in range(h):
		for x in range(w):
			var k: int = int(decor[y][x])
			if k == MapGenerator.DECOR_WATER and walls[y][x]:
				water_blocked += 1
			elif k == MapGenerator.DECOR_CRACK and walls[y][x]:
				crack_blocked += 1
	_check(water_blocked == 0, "河水不阻挡通行（被阻挡的格数 %d，应 0）" % water_blocked)
	_check(crack_blocked == 0, "裂缝不阻挡通行（被阻挡的格数 %d，应 0）" % crack_blocked)


# ------------------------------------------------------------ C 矿脉
func _probe_veins(result: Dictionary) -> void:
	var veins: Array = result.get("veins", [])
	var biome: Array = result["biome"]
	var by_res: Dictionary = {}
	var out_of_biome := 0
	var allowed: Array = [1]          # config veins 限定 biome 1（荒原）
	for vd in veins:
		var rid: String = str(vd.get("res_id", ""))
		by_res[rid] = int(by_res.get(rid, 0)) + 1
		var b: int = int(biome[int(vd["gy"])][int(vd["gx"])])
		if not allowed.has(b):
			out_of_biome += 1
	print("[Probe] 矿脉：%s" % str(by_res))
	for rid in ["iron", "gold", "oil"]:
		_check(int(by_res.get(rid, 0)) > 0, "%s 矿脉节点数 %d（应 > 0）"
				% [rid, int(by_res.get(rid, 0))])
	_check(out_of_biome == 0,
			"矿脉只落在限定群系（越界 %d 个，应 0）" % out_of_biome)


# ------------------------------------------------------------ D 减速
func _probe_speed(result: Dictionary) -> void:
	var sm: Array = result.get("speed_mult", [])
	_check(not sm.is_empty(), "result 含 speed_mult 网格")
	if sm.is_empty():
		return
	var biome: Array = result["biome"]
	var decor: Array = result["decor"]
	var w: int = sm[0].size()
	var h: int = sm.size()
	var river_slow := float(result.get("river_slow", 0.72))

	var snow_n := 0
	var snow_bad := 0
	var water_n := 0
	var water_bad := 0
	var plain_n := 0
	var plain_bad := 0
	for y in range(h):
		for x in range(w):
			var sp := float(sm[y][x])
			var is_water: bool = int(decor[y][x]) == MapGenerator.DECOR_WATER
			var b: int = int(biome[y][x])
			if is_water:
				water_n += 1
				if sp > river_slow + 1e-6:
					water_bad += 1
			elif b == 3:                       # 雪原
				snow_n += 1
				if sp >= 1.0:
					snow_bad += 1
			elif b == 0 and int(decor[y][x]) == MapGenerator.DECOR_NONE:
				plain_n += 1
				if absf(sp - 1.0) > 1e-6:
					plain_bad += 1

	_check(snow_n > 0 and snow_bad == 0,
			"雪原格 %d 全部 <1.0（异常 %d）" % [snow_n, snow_bad])
	_check(water_n > 0 and water_bad == 0,
			"河水格 %d 全部 ≤ %.2f（异常 %d）" % [water_n, river_slow, water_bad])
	_check(plain_n > 0 and plain_bad == 0,
			"草地空格 %d 全部 ==1.0（异常 %d）" % [plain_n, plain_bad])

	var snow_sp := float(MapGenerator.biome_speed(3))
	_check(snow_sp < 1.0, "配置里雪原 speed = %.2f（应 < 1.0）" % snow_sp)


# ------------------------------------------------------------ E 注册表
func _probe_registry() -> void:
	var counts: Dictionary = ResourceRegistry.count_by_type()
	print("[Probe] 资源节点分类：%s" % str(counts))

	var wood_n: int = int(counts.get("wood", 0))
	var stone_n: int = int(counts.get("stone", 0))
	_check(wood_n > 0, "wood 节点数 %d（应 > 0）" % wood_n)
	_check(stone_n > 0, "stone 节点数 %d（应 > 0）" % stone_n)

	var woods: Array = ResourceRegistry.get_uncollected("wood")
	_check(not woods.is_empty(), "有未采集的 wood 节点")
	if woods.is_empty():
		return
	var first: Variant = woods[0]
	var before: int = first.amount
	var r: Dictionary = ResourceRegistry.harvest(first.id, 1)
	_check(bool(r.get("ok", false)) and int(r.get("gained", 0)) == 1, "harvest 返回 ok")
	_check(first.amount == before - 1, "harvest 后 amount %d → %d" % [before, first.amount])

	var g: Vector2i = first.grid
	var bygrid = ResourceRegistry.get_by_grid(g.x, g.y)
	_check(bygrid != null and bygrid.id == first.id,
			"get_by_grid(%d,%d) 反查到 id=%d" % [g.x, g.y, first.id])

	var total_wood := int(ResourceRegistry.total_amount("wood"))
	print("[Probe] 总储量 wood=%d stone=%d" % [
		total_wood, int(ResourceRegistry.total_amount("stone"))])
	_check(total_wood > 0, "wood 总储量 %d（应 > 0）" % total_wood)


func _pairs(names: Array, tally: Array) -> String:
	var parts := PackedStringArray()
	for i in range(names.size()):
		parts.append("%s=%d" % [names[i], int(tally[i])])
	return " / ".join(parts)

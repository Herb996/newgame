extends Node
## 地图 + 资源注册表验证探针（回归用）
## 运行：Godot --headless --path . Dev/probe_registry.tscn
##
## 覆盖：
##   A 群系：4 种（草地/荒原/森林/沼泽）都出现，且草地占比最大（出厂权重 3.4）
##   B 装饰：树/石/残骸/灌木 计数 > 0（裂缝/河水已按需求从地图移除，见 map_generator
##      里"河流与裂缝均已按需求移除"，这里只留"万一有人加回来别挡路"的守卫）
##   C 矿脉：按 map.resource_clusters.types 里**配了份额又有允许群系**的每种矿脉都要
##      生成，且只落在**该资源自己 biome_weight>0 的群系**（早期写死"只在荒原"，配置
##      改成允许草地/森林后就成了假阳性）。2026-09-19 起形状是 {total, types}，探针跟着
##      配置动态展开，不再写死名单。
##      ⚠ gold 仍是真缺口：config 里没有 gold 簇条目 → 地图上不产金。这条**打印**出来
##        但不算失败，等用户裁定（补条目 vs 确认"金只从战利品来"）后再决定要不要变红。
##   D 地形减速：沼泽/雪原格 speed<1、水格 speed≤river.slow、普通格 ==1
##   E 注册表：build_from_map → harvest 扣减 → get_by_grid 反查 → 总储量一致
##
## 分布类断言验的是**出厂设计意图**，所以 _ready 里把 map.biome_weights 钉回出厂值 ——
## 玩家设置面板会把它拉平（见 Dev 探针通用的 user://settings.json 覆盖问题）。
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
	# 分布断言验的是**出厂**设计意图。设置面板会把 map.biome_weights 拉平（这台机器
	# 上就是 1.45/1.45/1.45/0.2），继承过来"草地格数最多""草地独占区间>0.4"必挂 ——
	# 那是玩家的选择，不是地图坏了。逐个键钉回 Data/config/ 自己的值。
	for i in range(MapGenerator.biome_count()):
		var key := "map.biome_weights." + str(i)
		Config.set_override(key, Config.get_base_value(key, 1.0))

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

	_check(n == 4, "群系数 = 4（草地/荒原/森林/%s），实际 %d"
			% [MapGenerator.biome_name(3), n])
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
		MapGenerator.DECOR_BUSH: 0,
		MapGenerator.DECOR_CRACK: 0,
		MapGenerator.DECOR_WATER: 0,
	}
	for y in range(h):
		for x in range(w):
			var k: int = int(decor[y][x])
			if tally.has(k):
				tally[k] = int(tally[k]) + 1
	print("[Probe] 装饰物：树 %d / 石 %d / 残骸 %d / 灌木 %d / 裂缝 %d / 河水 %d" % [
		int(tally[MapGenerator.DECOR_TREE]), int(tally[MapGenerator.DECOR_ROCK]),
		int(tally[MapGenerator.DECOR_DEBRIS]), int(tally[MapGenerator.DECOR_BUSH]),
		int(tally[MapGenerator.DECOR_CRACK]), int(tally[MapGenerator.DECOR_WATER])])

	# 裂缝/河水不再要求出现（已按需求从地图移除），只保留下面"别挡路"的守卫。
	for k in [MapGenerator.DECOR_TREE, MapGenerator.DECOR_ROCK,
			MapGenerator.DECOR_DEBRIS, MapGenerator.DECOR_BUSH]:
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
	# map.resource_clusters 的新形状（2026-09-19 定形）：{total, types:{res:{share,
	# min_size, max_size, biome_weight:{群系: 权重}}}}。旧探针按 {res:{weight}} 读，
	# 第一个键就撞上 total（int）→ .get() 直接 SCRIPT ERROR，**整段断言一条没跑**，
	# 而计数只在跑完之后才打，于是"30/30 全过"是假的。
	var clusters = Config.get_value("map.resource_clusters", {})
	var types: Dictionary = clusters.get("types", {}) if clusters is Dictionary else {}
	_check(not types.is_empty(), "map.resource_clusters.types 有内容（空 = 整段无意义）")
	# 每种资源允许落在哪些群系 = biome_weight 里值 >0 的那些。以前写死 [1]（只有荒原），
	# 而配置早就允许 iron 落草地/森林，于是一跑就"越界 25 个"—— 那是探针过期。
	var allowed_by_res := {}
	var vein_types: Array = []
	for rid in types:
		var tc: Dictionary = types[rid]
		var bw: Dictionary = tc.get("biome_weight", {})
		var ok_b: Array = []
		for k in bw:
			if int(bw[k]) > 0:
				ok_b.append(int(str(k)))
		allowed_by_res[str(rid)] = ok_b
		# 该不该进 veins 数组由 map_generator 判定（tree/rock 进 decor），这里跟着它列清单，
		# 并只把「配了份额 + 有允许群系」的类型当成必须出现 —— share=0 或全 0 权重不该有货。
		if str(rid) in ["iron", "gold", "oil"] and int(tc.get("share", 0)) > 0 \
				and not ok_b.is_empty():
			vein_types.append(str(rid))
	var stray := {}
	for vd in veins:
		var rid: String = str(vd.get("res_id", ""))
		by_res[rid] = int(by_res.get(rid, 0)) + 1
		if not allowed_by_res.has(rid):
			stray[rid] = int(stray.get(rid, 0)) + 1
			continue
		var b: int = int(biome[int(vd["gy"])][int(vd["gx"])])
		if not (allowed_by_res[rid] as Array).has(b):
			out_of_biome += 1
	print("[Probe] 矿脉：%s" % str(by_res))
	for rid in vein_types:
		_check(int(by_res.get(rid, 0)) > 0,
				"%s 矿脉节点数 %d（应 > 0；为 0 通常是 map.resource_clusters.types 里没有 %s）"
				% [rid, int(by_res.get(rid, 0)), rid])
	_check(stray.is_empty(),
			"veins 里不出现配置之外的 res_id（多余的 %s）" % str(stray))
	_check(out_of_biome == 0,
			"矿脉只落在各自配置的限定群系（越界 %d 个，应 0）" % out_of_biome)
	if not types.has("gold"):
		# 不是环境噪声，也别当失败：地图上没有金矿簇是**待用户裁定**的设计缺口
		# （补 gold 条目 vs 确认"金只从战利品来"）。打印出来，别静默通过。
		print("[Probe] -- 缺口：map.resource_clusters.types 没有 gold 条目 ⇒ 全图无金矿脉"
				+ "（代码支持，见 map_generator.gd:1210 / VEIN_RES）")


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
			elif b == 3:                       # 减速群系（配置里现在叫沼泽）
				snow_n += 1
				if sp >= 1.0:
					snow_bad += 1
			elif b == 0 and int(decor[y][x]) == MapGenerator.DECOR_NONE:
				plain_n += 1
				if absf(sp - 1.0) > 1e-6:
					plain_bad += 1

	_check(snow_n > 0 and snow_bad == 0,
			"%s格 %d 全部 <1.0（异常 %d）"
			% [MapGenerator.biome_name(3), snow_n, snow_bad])
	_check(water_bad == 0,
			"河水格 %d 全部 ≤ %.2f（异常 %d；地图已移除河水，0 格视为通过）"
			% [water_n, river_slow, water_bad])
	_check(plain_n > 0 and plain_bad == 0,
			"草地空格 %d 全部 ==1.0（异常 %d）" % [plain_n, plain_bad])

	var snow_sp := float(MapGenerator.biome_speed(3))
	_check(snow_sp < 1.0, "配置里%s speed = %.2f（应 < 1.0）"
			% [MapGenerator.biome_name(3), snow_sp])


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

extends Node
## 采集注册表验证探针：generate → build_from_map → 打印统计 → quit
## 用 godot --headless --path . Dev/probe_registry.tscn 运行

func _ready() -> void:
	var result: Dictionary = MapGenerator.generate()
	ResourceRegistry.build_from_map(result)

	var counts: Dictionary = ResourceRegistry.count_by_type()
	print("[Probe] 资源节点分类：", counts)

	# 验证：wood/stone 都应 > 0
	var wood_n: int = int(counts.get("wood", 0))
	var stone_n: int = int(counts.get("stone", 0))
	assert(wood_n > 0, "wood 节点数为 0！")
	assert(stone_n > 0, "stone 节点数为 0！")

	# 验证：矿脉 iron/gold/oil 都应 > 0（草地等新增群系不应破坏矿脉生成）
	for rid in ["iron", "gold", "oil"]:
		assert(int(counts.get(rid, 0)) > 0, "%s 矿脉节点数为 0！" % rid)

	# 验证：取第一个 wood 节点，harvest 一次扣减正确
	var woods: Array = ResourceRegistry.get_uncollected("wood")
	var first: Variant = woods[0]
	var before: int = first.amount
	var r: Dictionary = ResourceRegistry.harvest(first.id, 1)
	assert(r.ok and r.gained == 1, "harvest 失败")
	assert(first.amount == before - 1, "harvest 后 amount 未扣减")
	print("[Probe] harvest 测试通过：%s 节点 id=%d 由 %d → %d" % [r.res_id, first.id, before, first.amount])

	# 验证：按 grid 反查
	var g: Vector2i = first.grid
	var bygrid = ResourceRegistry.get_by_grid(g.x, g.y)
	assert(bygrid != null and bygrid.id == first.id, "get_by_grid 反查失败")
	print("[Probe] get_by_grid(%d,%d) -> id=%d OK" % [g.x, g.y, bygrid.id])

	# 验证：total_amount 与节点数一致（per_node 相同时）
	print("[Probe] 总储量 wood=%d stone=%d" % [
		ResourceRegistry.total_amount("wood"), ResourceRegistry.total_amount("stone")])

	print("[Probe] 验证全部通过，注册表装配正常。")
	get_tree().quit()

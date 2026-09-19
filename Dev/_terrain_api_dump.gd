extends Node
## 一次性（用完即删）：两件事
##  1) TileSet 的枚举成员名与整数值（TerrainSetMode / TerrainExtrasNeighborhoodBits）
##  2) TileData 的 peering bit **整数 ↔ 方向名** 标定：
##     TileData 没注册枚举（class_get_enum_list 返回空），但编辑器插件暴露了
##     `terrains_peering_bit/top_side` 这类伪属性 ⇒ 逐个写进去、再按 0..7 读回来，
##     看哪个整数被改，就把方向钉死。

const BIT_NAMES := ["top_left_corner", "top_side", "top_right_corner", "right_side",
		"bottom_right_corner", "bottom_side", "bottom_left_corner", "left_side"]

func _ready() -> void:
	print("TileSet 枚举列表 raw = ", ClassDB.class_get_enum_list("TileSet", false))
	for en in ClassDB.class_get_enum_list("TileSet", false):
		var names: Array = ClassDB.class_get_enum_constants("TileSet", str(en))
		var parts: Array = []
		for n in names:
			parts.append("%s=%d" % [str(n), ClassDB.class_get_integer_constant("TileSet", str(n))])
		print("   ", str(en), " : ", ", ".join(parts))
	print("TileData 枚举列表 raw = ", ClassDB.class_get_enum_list("TileData", false))

	var ts := TileSet.new()
	ts.add_terrain_set(0)
	for i in range(3):
		ts.add_terrain(0, i)
	ts.set_terrain_set_mode(0, _mode_int("TERRAIN_MODE_MATCH_CORNERS_AND_SIDES"))
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(Image.create(64, 64, false, Image.FORMAT_RGBA8))
	src.texture_region_size = Vector2i(64, 64)
	ts.add_source(src, 0)
	src.create_tile(Vector2i(0, 0))
	var td := src.get_tile_data(Vector2i(0, 0), 0)
	td.set("terrain_set", 0)
	td.set("terrain", 0)

	print("\n-- 整数 0..7 的合法性（8 位模式，即角+边）--")
	var legal: Array = []
	for b in range(8):
		if td.is_valid_terrain_peering_bit(b):
			legal.append(b)
	print("   合法整数 = ", legal)

	print("\n-- 标定：写 terrains_peering_bit/<名字> = 地形2，再看哪个整数变 2 --")
	for nm in BIT_NAMES:
		for b in range(8):
			td.set_terrain_peering_bit(b, 0)
		var prop: String = "terrains_peering_bit/" + str(nm)
		if not _has_prop(td, prop):
			print("   %-20s 属性不存在" % nm)
			continue
		td.set(prop, 2)
		var changed: Array = []
		for b in range(8):
			if td.get_terrain_peering_bit(b) == 2:
				changed.append(b)
		print("   %-20s -> 整数 %s" % [nm, str(changed)])
	get_tree().quit()


func _has_prop(o: Object, pname: String) -> bool:
	for p in o.get_property_list():
		if str(p.get("name", "")) == pname:
			return true
	return false


func _mode_int(const_name: String) -> int:
	return ClassDB.class_get_integer_constant("TileSet", const_name)

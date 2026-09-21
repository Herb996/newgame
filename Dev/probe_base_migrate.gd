extends Node
## ============================================================
## probe_base_migrate — 基地扩图（64→80）的两条存档迁移自检（headless 可跑）
##
## 覆盖：
##   1. BaseCustomization.pad_default_layout_band —— 只补外圈新格子，
##      玩家在老区域改过的格子必须一格不动（否则扩图会把玩家的地面抹掉）。
##   2. Meta._load_base_layout —— config base.layout_version 涨版时丢掉老档的
##      重摆位置（否则每个老档都停在旧 64 网格的构图上，看不到新布局）。
## 两条都是"全绿也可能画面是歪的"那类逻辑，所以另外配了 shot_base_grid 实拍。
## ============================================================

var _fails := 0


func _ready() -> void:
	_test_band_pad()
	_test_layout_version()
	if _fails > 0:
		print("[Migrate] FAIL = %d" % _fails)
		get_tree().quit(1)
		return
	print("[Migrate] 全部通过")
	get_tree().quit(0)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   %s" % what)
	else:
		_fails += 1
		print("  FAIL %s" % what)


func _test_band_pad() -> void:
	print("[Migrate] --- pad_default_layout_band ---")
	Config.set_override("base.default_layout", {
		"ground": [
			{"biome": 2, "rect": [0, 0, 4, 4]},        # 老区域：玩家在这里改过
			{"biome": 1, "rect": [70, 70, 8, 8]},      # 新区域：只有 80 地图才铺得到
		],
		"water": [],
		"props": [],
	})
	var custom := {"v": 1, "size": 64,
			"ground": {"5,5": 1}, "water": {}, "props": {}}
	var padded := BaseCustomization.pad_default_layout_band(custom, 64, 80)
	var g: Dictionary = padded["ground"]
	_check(g.get("5,5") == 1, "玩家改过的老格子 (5,5) 原样保留")
	_check(g.get("0,0") == null, "老区域一格不补（玩家可能改过，只有外圈才铺出厂布置）")
	_check(g.get("70,70") == 1, "外圈新格子 (70,70) 补铺成功")
	_check(g.get("77,77") == 1, "外圈新格子右下角补铺成功")
	_check(int(padded.get("size", 0)) == 64, "pad 不改 size（由调用方决定记成新值）")
	_check(BaseCustomization.pad_default_layout_band(custom, 80, 80) != null,
			"new_size <= old_size 时直接返回不炸")
	_check((BaseCustomization.pad_default_layout_band(custom, 80, 80)["ground"] as Dictionary)
			.get("70,70") == null, "缩图不补铺（外圈格子不会被凭空写出来）")
	Config.clear_override("base.default_layout")


func _test_layout_version() -> void:
	print("[Migrate] --- Meta._load_base_layout ---")
	var keep := {"warehouse": [12, 29]}
	var got_old: Dictionary = Meta.call("_load_base_layout",
			{"base_layout": keep, "base_layout_version": 1})
	_check(got_old.is_empty(), "存档版本落后 → 丢弃重摆位置，按新出厂网格重排")
	var got_new: Dictionary = Meta.call("_load_base_layout",
			{"base_layout": keep, "base_layout_version": 2})
	_check(got_new == keep, "版本已对齐 → 玩家重摆位置原样保留")
	var got_none: Dictionary = Meta.call("_load_base_layout", {"base_layout": keep})
	_check(got_none.is_empty(), "老档没记版本（按 v1 认）→ 丢弃")
	var got_junk: Dictionary = Meta.call("_load_base_layout",
			{"base_layout": "不是字典", "base_layout_version": 99})
	_check(got_junk.is_empty(), "base_layout 被手改成非字典 → 当空表，不崩")
	_check(Meta.base_layout_version == 2, "读档后把版本号顶到 config 要求值再落盘")


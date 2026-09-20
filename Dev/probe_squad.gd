extends Node
## ============================================================
## probe_squad — 复现「基地大门选不同角色 → 进局后各人武器/贴图集正确」
##
## 复现路径：main._on_launch([枪手/弓兵/剑士/僧侣])
##   → 检查每个 player 实例的 current_weapon / _sprite_set_for_weapon / 首帧
## 结论写 user://_probe_squad.txt，同时打印到 stdout。
## ============================================================

const OUT := "user://_probe_squad.txt"

# 预期：角色显示名 -> (武器, 贴图集)
const EXPECT := {
	"枪手": ["spear", "sprites_lancer"],
	"弓兵": ["bow", "sprites_archer"],
	"剑士": ["sword", "sprites_ts"],
	"僧侣": ["staff", "sprites_monk"],
}

var _lines: Array = []


func _say(s: String) -> void:
	_lines.append(s)
	print(s)


func _ready() -> void:
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	for _i in range(30):
		await get_tree().process_frame

	# 复现大门选角出击：名单里四个人全上
	main._on_launch([{"id": "spearman", "name": "枪手"},
			{"id": "archer", "name": "弓兵"},
			{"id": "swordsman", "name": "剑士"},
			{"id": "monk", "name": "僧侣"}])

	for _i in range(40):
		await get_tree().process_frame

	var players := get_tree().get_nodes_in_group("player")
	_say("=== 进局小队共 %d 名 ===" % players.size())
	var all_ok := true
	var sets := []
	for p in players:
		var set_name: String = p._sprite_set_for_weapon()
		sets.append(set_name)
		var tex0: String = ""
		if p._animator != null:
			var fr = p._animator._frames.get(&"idle", {}).get(PlayerAnimator.DIR_DOWN, [])
			if fr is Array and not fr.is_empty() and fr[0] != null:
				tex0 = (fr[0] as Texture2D).resource_path
		var exp_arr: Array = EXPECT.get(str(p.character_name), [])
		var ok_weapon: bool = (exp_arr.size() >= 1 and str(p.current_weapon) == exp_arr[0])
		var ok_set: bool = (exp_arr.size() >= 2 and set_name == exp_arr[1])
		var ok: bool = ok_weapon and ok_set
		all_ok = all_ok and ok
		_say("  角色=%-8s weapon=%-7s sprite_set=%-14s 首帧=%s  预期武器=%s 预期贴图=%s"
				% [str(p.character_name), str(p.current_weapon), set_name, tex0,
				"OK" if ok_weapon else "FAIL", "OK" if ok_set else "FAIL"])

	_say("")
	_say("断言：全部角色武器与贴图集命中预期 = %s" % str(all_ok))
	_say("      贴图集清单：%s" % " / ".join(sets))

	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	get_tree().quit()

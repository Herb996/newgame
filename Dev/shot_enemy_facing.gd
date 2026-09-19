extends Node
## ============================================================
## shot_enemy_facing — 实拍：敌人朝左/朝右的水平镜像（**必须开窗跑**）
##
## 配合 probe_enemy_facing 的断言看画面。四行对照，一眼能验三件事：
##   ① 素材朝右的 4 个兵种 + 玩家在左 → 必须镜像（否则就是"倒着跑"）
##   ② 同一批 + 玩家在右 → 必须翻回原画
##   ③④ 两只鲨鱼（原画头朝左）→ 规则整个反过来：朝左**不**翻、朝右才翻
## 一刀切的 `if dir.x < 0: flip` 会把 ③ 那行翻反，这正是 ART_FACING 表存在的理由。
##
## 与探针同一套搭台（开阔网格 + 独立 EnemySystem + 假玩家），不加载 Main.tscn：
## 这里要的是"能看清朝向"，不是完整关卡。生产代码一行没改。
##
## 用法：python tools/run_probe.py _shot_enemy_facing.log res://Dev/shot_enemy_facing.tscn --window
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const ENEMY_SYS := preload("res://Scripts/enemy_system.gd")
const ENEMY_SCENE := preload("res://Scenes/Enemy.tscn")
const TILE := 64
## 整排布局往右挪这么多格：地图格坐标从 (0,0) 起算，A* 对越界目标一律寻不到路，
## 玩家放在负 x 上会让敌人 repath 失败、退回随机巡逻（拍出来就是"该朝左的还在朝右"）。
const X0 := 10
const SIDE_TYPES := ["ep_bear", "ep_spear_goblin", "ep_minotaur", "ep_gnoll"]
const SHARK_TYPES := ["ep_harpoon_shark", "ep_paddle_shark"]

var _lines: Array = []
var _n := 0
var _bad := 0
var _walls: Array = []


## 假玩家：只当"朝哪追"的锚点
class FakePlayer extends Area2D:
	func take_damage(_amount: int, _from: Vector2) -> bool:
		return true


func _ready() -> void:
	Config.set_override("display.window_mode", "windowed")
	# 追得太快会一头撞到玩家然后站住（站住就不再更新朝向），压低速度只为拍朝向
	Config.set_override("enemy.speed", 70.0)
	_walls = _open_walls(64)
	NoiseSystem.setup([], TILE)
	NoiseSystem.reset()

	var world: Node2D = Node2D.new()
	world.name = "World"
	add_child(world)
	var sys = _make_system(world)

	var bg: ColorRect = ColorRect.new()
	bg.color = Color(0.30, 0.44, 0.22)
	bg.offset_left = -14 * TILE
	bg.offset_top = -8 * TILE
	bg.offset_right = 64 * TILE
	bg.offset_bottom = 64 * TILE
	bg.z_index = -100
	world.add_child(bg)

	var rows := [
		{"y": 2, "side": -1, "types": SIDE_TYPES, "art": "right",
			"label": "① 素材朝右的兵种 · 玩家在左 → 应当镜像"},
		{"y": 12, "side": 1, "types": SIDE_TYPES, "art": "right",
			"label": "② 同一批 · 玩家在右 → 应当翻回原画"},
		{"y": 22, "side": -1, "types": SHARK_TYPES, "art": "left",
			"label": "③ 鲨鱼（原画头朝左）· 玩家在左 → 不该镜像"},
		{"y": 32, "side": 1, "types": SHARK_TYPES, "art": "left",
			"label": "④ 鲨鱼 · 玩家在右 → 反而要镜像"},
	]
	var spawned: Array = []      # [[enemy, body, 原画侧向, 兵种 id], ...]
	for row in rows:
		var ry: float = float(int(row["y"]) * TILE)
		var side := int(row["side"])
		var types: Array = row["types"]
		var cx := float(X0 + types.size() - 1) * float(TILE)   # 行中心（相邻两只差 2 格）
		var fp := _add_player(world)
		fp.global_position = Vector2(cx + side * 6.0 * TILE, ry)
		_mark(world, Vector2(cx + side * 6.0 * TILE, ry), "玩家")
		for i in range(types.size()):
			var e = _spawn(world, Vector2(float(X0 + i * 2) * TILE, ry),
					_cfg(str(types[i])), sys)
			e.visible = true      # 敌人默认隐藏，等雾系统放行；这里没有雾系统
			spawned.append([e, e._body, str(row["art"]), str(types[i])])
		_label(world, Vector2(float(X0 - 9) * TILE, ry - 2.2 * TILE), str(row["label"]))

	# 1 格标尺，给个尺寸参照
	var ruler: Line2D = Line2D.new()
	ruler.width = 2.0
	ruler.closed = true
	ruler.default_color = Color(1, 1, 1, 0.85)
	ruler.points = PackedVector2Array([Vector2(0, 0), Vector2(TILE, 0),
			Vector2(TILE, -TILE), Vector2(0, -TILE)])
	ruler.position = Vector2(float(X0 - 9) * TILE, float(int(rows[0]["y"]) * TILE))
	ruler.z_index = 200
	world.add_child(ruler)

	var cam: Camera2D = Camera2D.new()
	cam.name = "ShotCam"
	world.add_child(cam)
	cam.make_current()

	var all := Rect2()
	var first := true
	for s in spawned:
		var r := _rect_of(s[1] as Sprite2D)
		all = r if first else all.merge(r)
		first = false
	var focus := Rect2(all.position - Vector2(11 * TILE, 3 * TILE),
			all.size + Vector2(22 * TILE, 6 * TILE))
	_frame(cam, focus)

	await _frames(90)           # 让 AI 从 patrol 转 chase 并真的挪起来
	await _report(spawned, "开局 90 物理帧后")
	await _shot("rows", focus)

	# 特写：① 行（朝右素材 → 应当镜像）与 ③ 行（鲨鱼 → 不该镜像）并排比对
	var c1 := Rect2(float(X0 - 1) * TILE, 0.5 * TILE, 6.0 * TILE, 4.0 * TILE)
	_frame(cam, c1)
	await _frames(20)
	await _shot("close_side", c1)
	var c2 := Rect2(float(X0 - 1) * TILE, 20.5 * TILE, 4.0 * TILE, 4.0 * TILE)
	_frame(cam, c2)
	await _frames(20)
	await _shot("close_shark", c2)

	print("[EnemyFacingShot] %s" % "\n".join(_lines))
	print("[EnemyFacingShot] 朝向不符预期 %d 只；共 %d 张图 -> %s" % [_bad, _n, OUT_DIR])
	get_tree().quit(0 if _bad == 0 else 1)


# ------------------------------------------------------------
# 搭台 / 工具
# ------------------------------------------------------------

func _open_walls(size: int) -> Array:
	var w: Array = []
	for _y in range(size):
		var row: Array = []
		for _x in range(size):
			row.append(false)
		w.append(row)
	return w


func _cfg(id: String) -> Dictionary:
	for t in Config.get_value("enemy_types.types", []):
		if t is Dictionary and str((t as Dictionary).get("id", "")) == id:
			return (t as Dictionary).duplicate(true)
	return {}


func _make_system(world: Node2D):
	var sys = ENEMY_SYS.new()
	sys.name = "Sys"
	add_child(sys)
	sys._root = world
	sys._walls = _walls
	sys._tile_size = TILE
	sys._astar = MapGenerator.build_astar(_walls, TILE)
	return sys


func _spawn(world: Node2D, pos: Vector2, type_cfg: Dictionary, sys):
	var e = ENEMY_SCENE.instantiate()
	e.position = pos
	world.add_child(e)
	e.setup(_walls, TILE, sys._astar, type_cfg, {}, sys)
	return e


func _add_player(world: Node2D) -> FakePlayer:
	var fp := FakePlayer.new()
	world.add_child(fp)
	fp.add_to_group("player")
	return fp


func _label(world: Node2D, at: Vector2, text: String) -> void:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.position = at
	lbl.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 4)
	world.add_child(lbl)


func _mark(world: Node2D, at: Vector2, text: String) -> void:
	var dot: Line2D = Line2D.new()
	dot.width = 3.0
	dot.closed = true
	dot.default_color = Color(0.2, 0.6, 1.0, 0.9)
	dot.points = PackedVector2Array([Vector2(-14, -14), Vector2(14, -14),
			Vector2(14, 14), Vector2(-14, 14)])
	dot.position = at
	world.add_child(dot)
	_label(world, at + Vector2(-24, 16), text)


## Node2D 没有 get_global_rect()（那是 Control 的）→ 自己按贴图 × 缩放算
func _rect_of(sp: Sprite2D) -> Rect2:
	var sz: Vector2 = sp.texture.get_size() * sp.global_scale
	return Rect2(sp.global_position - sz * 0.5, sz)


## 取景：把世界矩形塞进当前窗口（zoom_at_cursor 那条坑不适用于自建相机）
func _frame(cam: Camera2D, r: Rect2) -> void:
	var vs: Vector2 = get_viewport().get_visible_rect().size
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	var z: float = minf(vs.x / r.size.x, vs.y / r.size.y)
	cam.zoom = Vector2(z, z)
	cam.global_position = r.get_center()


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame


## 逐只核对：镜像结果是否符合"原画侧向 × 当前朝向"（图要配得上数）
func _report(spawned: Array, when: String) -> void:
	_lines.append("--- %s ---" % when)
	for s in spawned:
		var e = s[0]
		if not is_instance_valid(e):
			_lines.append("  !! %s 已不在场" % s[3])
			_bad += 1
			continue
		var f: Vector2 = e.facing()
		var body: Sprite2D = s[1]
		var art := str(s[2])
		var want := false
		if art == "right":
			want = f.x < 0.0
		elif art == "left":
			want = f.x > 0.0
		var held_only := absf(f.x) < PlayerAnimator.FLIP_DEADZONE_X
		var ok := true
		if held_only:
			ok = true          # 死区内保持上一次，本就不该有确定答案
		else:
			ok = body.flip_h == want
		if not ok:
			_bad += 1
		_lines.append("  %s %s(朝%s) facing.x=%+.2f flip_h=%s 预期=%s%s" % [
				"OK  " if ok else "!!  ", s[3], art, f.x, str(body.flip_h), str(want),
				"（死区保持）" if held_only else ""])


func _shot(tag: String, focus: Rect2) -> void:
	_n += 1
	await RenderingServer.frame_post_draw
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam != null:
		print("[EnemyFacingShot]   相机 pos=%s zoom=%.2f（焦点中心 %s）" % [
				str(cam.global_position), cam.zoom.x, str(focus.get_center())])
	var im: Image = get_viewport().get_texture().get_image()
	if im == null:
		print("[EnemyFacingShot] !! viewport 贴图为空（忘了 --window？）")
		return
	var path := "%s/enemy_facing_%02d_%s.png" % [OUT_DIR, _n, tag]
	print("[EnemyFacingShot] %s -> %s err=%d" % [tag, path, im.save_png(path)])

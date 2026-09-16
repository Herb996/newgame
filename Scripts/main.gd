extends Node
## ============================================================
## Main — 顶层装配节点（基地/局内双模式）
## Mode.BASE：局外基地（64x64 平地+仓库/雕像/大门），开局先进基地
## Mode.RUN ：进局（原 _start_play_session 逻辑）
## 切换：大门按 E → 进局；局结束（撤离/死亡/超时）按 R → 回基地
## debug.smoke_test = true → 跑三大件自检（Phase 0 遗留）
##
## 操作：左键点击玩家选中 → 左键点击地面自动寻路移动；WASD/方向键平移相机；F 回到玩家；E 交互建筑；R 局结束返回基地；ESC 退出。
## 测试技巧：debug.time_scale 可加速局内倒计时，玩家速度不变。
## ============================================================

const PLAYER_SCENE := preload("res://Scenes/Player.tscn")
const CAMERA_SCRIPT := preload("res://Scripts/camera_controller.gd")
const SOAK_PROBE := preload("res://Scripts/soak_probe.gd")

enum Mode { BASE, RUN }

var mode: int = Mode.BASE

# --- 命令行出图（见 _handle_cli / _process）---
var _capture_path := ""            # --capture2d，非空 = 进局后截图到该路径再退出
var _capture_delay := 3.0          # --capture-delay，进局后等多少秒再截
var _capture_left := -1.0          # 倒计时，<0 = 未启用
var _no_fog := false               # --no-fog，出图时关掉迷雾以便看清地图本体
var _dump_atlas := ""              # --dump-atlas，把运行时图集另存 PNG（查地形贴图问题用）
var _dump_biome := ""              # --dump-biome，把群系 id 画成色块图（看群系分布）
var _dump_zoom := 1                # --zoom N，上面两张诊断图的放大倍数（小图看不清时用）
var _no_macro := false             # --no-macro，关掉宏观明暗层（二分"叠加层 vs 地形"用）
var _soak_seconds := 0.0           # --soak N，跑 N 秒行为验证（移动不卡住/死亡消失）后退出
var _soak_kill_ratio := 0.3        # --soak-kill-ratio F，探针在中途击杀多大比例的单位
var _soak_trace := false           # --soak-trace，探针逐次采样打印玩家状态（排查用）
## --weapon <id>，进局后强制把玩家换成指定武器（截图 / 手动验证用，不改 config）。
var _weapon_override := ""
## --seed 的落地值。优先级**高于** config 里的 map.force_seed ——
## 那个固定种子是给日常开发复现用的，而命令行 --seed 是给"换几张图验证"用的，
## 若被 config 覆盖，就会得到"每次都同一张图"的假结论（验证过：3 个不同 seed 出的
## 可达格数/掉落基线完全一样，正是因为 force_seed 在 _enter_run 里又 seed 了一次）。
var _seed_override := 0
var _last_map: Dictionary = {}     # 最近一次生成的地图结果（供 SoakProbe 取 walls/reachable）

@onready var run: Node = $RunManager
@onready var game_root: Node2D = $GameRoot
@onready var extraction_system: Node = $ExtractionSystem
@onready var enemy_system: Node = $EnemySystem
@onready var loot_system: Node = $LootSystem
@onready var animal_system: Node = $AnimalSystem
@onready var fog_system: Node = $FogSystem
@onready var minimap: CanvasLayer = $Minimap
@onready var hud: CanvasLayer = $HUD
@onready var base_system: Node = $BaseSystem
@onready var warehouse_panel: CanvasLayer = $WarehousePanel
@onready var statue_panel: CanvasLayer = $StatuePanel


func _ready() -> void:
	base_system.building_interacted.connect(_on_building_interacted)
	if Config.get_value("debug.smoke_test", false):
		_smoke_test()
		return
	# 出图/回归入口：优先走命令行参数（不碰 config，跑完不会留下脏配置）。
	# 用法：godot --path . -- --preview-map D:/out.png [--seed N] [--cells N] [--scale F]
	if _handle_cli():
		return
	# 兼容旧入口：config 里写死输出路径（工具链历史遗留，保留以免旧脚本失效）
	if Config.get_value("debug.map_preview", "") != "":
		_render_map_preview()
		return
	_enter_base()
	# headless 回归测试用：跳过基地直接进局（配合 --quit-after 跑若干帧看日志）
	if Config.get_value("debug.auto_enter_run", false):
		_enter_run()


## 解析 `--` 之后的用户参数。返回值 = "已接管本次启动"（调用方应直接 return）。
##
## 为什么要有这条通道：老做法是「临时改写 Data/config.json → 跑 Godot → 还原」，
## 一旦中途崩在写完之后，工程就留着一份被改过的配置，下次跑会莫名其妙固定种子。
## 走命令行参数就没有这个问题：config 全程只读。
func _handle_cli() -> bool:
	var argv := OS.get_cmdline_user_args()
	if argv.is_empty():
		return false
	var preview := ""
	var cells := 0
	var scale := 0.0
	var seed_override := 0
	var i := 0
	while i < argv.size():
		var a := argv[i]
		match a:
			"--preview-map":
				i += 1
				preview = argv[i] if i < argv.size() else ""
			"--cells":
				i += 1
				cells = int(argv[i]) if i < argv.size() else 0
			"--scale":
				i += 1
				scale = float(argv[i]) if i < argv.size() else 0.0
			"--seed":
				i += 1
				seed_override = int(argv[i]) if i < argv.size() else 0
			"--capture2d":
				i += 1
				_capture_path = argv[i] if i < argv.size() else ""
			"--capture-delay":
				i += 1
				_capture_delay = float(argv[i]) if i < argv.size() else 3.0
			"--no-fog":
				# 关雾：迷雾层 z_index=5 会盖住地形，截图时地面看着是"一片黑"，
				# 但那是雾不是地形。要单独看地图本体就必须能关掉它。
				_no_fog = true
			"--no-macro":
				_no_macro = true
				MapGenerator.disable_macro = true
			"--dump-atlas":
				i += 1
				_dump_atlas = argv[i] if i < argv.size() else ""
			"--dump-biome":
				i += 1
				_dump_biome = argv[i] if i < argv.size() else ""
			"--zoom":
				i += 1
				_dump_zoom = maxi(1, int(argv[i])) if i < argv.size() else 1
			"--soak":
				# 行为验证：跑 N 秒模拟，断言"移动不卡住 / 死亡会消失"。
				# 用法：godot --path . --headless --fixed-fps 60 res://Scenes/Main.tscn -- --soak 30
				i += 1
				_soak_seconds = float(argv[i]) if i < argv.size() else 30.0
			"--soak-kill-ratio":
				i += 1
				_soak_kill_ratio = float(argv[i]) if i < argv.size() else 0.3
			"--soak-trace":
				# 逐次采样打印玩家状态/位置，用于把"卡住"归因到具体状态
				_soak_trace = true
			"--weapon":
				# 强制换武器（sword / bow）。走命令行而不是改 config，
				# 与 --seed 同样的理由：config 全程只读，中途崩了也不会留脏配置。
				i += 1
				_weapon_override = argv[i] if i < argv.size() else ""
		i += 1
	if seed_override != 0:
		_seed_override = seed_override
	if _soak_seconds > 0.0:
		# 探针要看清单位本身，迷雾只会挡视线（不影响逻辑），直接关掉
		_no_fog = true
		# 种子的施加交给 _enter_run（它要压过 config 的 map.force_seed）
		_enter_run()
		var probe: Node = SOAK_PROBE.new()
		probe.name = "SoakProbe"
		add_child(probe)
		probe.trace = _soak_trace
		probe.start(_last_map, run, _soak_seconds, _soak_kill_ratio)
		return true
	if _dump_atlas != "":
		_dump_atlas_png()
		return true
	if _dump_biome != "":
		_dump_biome_png()
		return true
	if _capture_path != "" and preview == "":
		# 2D 实测截图：需要真实渲染（不能 --headless），进局后等画面稳定再截图
		_capture_left = _capture_delay
		_enter_base()
		_enter_run()
		return true
	# 只给了 --no-fog（没给出图路径）时走到这里：返回 false，让 _ready 继续走
	# 正常的"进基地 → 进局"流程，_enter_run 里会按 _no_fog 关掉迷雾。
	if preview == "":
		return false
	if seed_override != 0:
		seed(seed_override)
	# 不指定就画满整张图：只画一半的预览图会让人误判"地图就这么大"
	if cells <= 0:
		cells = int(Config.get_value("map.width", 128))
	if scale <= 0.0:
		scale = float(Config.get_value("debug.map_preview_scale", 0.125))
	var result := _generate_valid_map()
	var img := MapGenerator.build_preview(result, cells)
	if scale != 1.0:
		img.resize(maxi(1, int(img.get_width() * scale)),
				maxi(1, int(img.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
	var err := img.save_png(preview)
	print("[Map] 预览已输出：%s（%dx%d，scale=%.3f，err=%d）" % [preview,
			img.get_width(), img.get_height(), scale, err])
	_free_map_node(result)
	get_tree().quit()
	return true


## 把运行时组装的图集另存为 PNG（--dump-atlas）。
##
## 为什么需要它：图集不是磁盘上现成的文件，而是运行时按 64px 从官方 4x4 blob
## 区块重采样拼出来、又叠了群系 tint 的产物。当"进游戏看到的颜色不对"时，
## 根因可能是①源图本身、②tint 乘错、③图集切格/取样错——只看场景截图分不清。
## 把图集单独导出来，三种情况一眼可辨（图集正确 ⇒ 问题在 TileSet 取样）。
func _dump_atlas_png() -> void:
	var ts: int = int(Config.get_value("map.tile_size", 64))
	var img: Image = MapGenerator._build_atlas_image(ts)
	if _dump_zoom > 1:
		img.resize(img.get_width() * _dump_zoom, img.get_height() * _dump_zoom,
				Image.INTERPOLATE_NEAREST)
	var err := img.save_png(_dump_atlas)
	print("[Map] 图集已输出：%s（%dx%d，tile=%d，列数=%d，zoom=%d，err=%d）"
			% [_dump_atlas, img.get_width(), img.get_height(), ts,
			   MapGenerator.atlas_cols(), _dump_zoom, err])
	get_tree().quit()


## 把群系 id 画成色块图（--dump-biome）。
##
## 用途：截图里"这块青绿色到底是水面还是沼泽"这类问题，靠肉眼猜群系配色极易猜错
## （水面与沼泽撞色正是之前踩过的坑）。直接把 biome/terrain 网格导成图，
## 再对照日志里的群系名，定位群系分布就没有歧义了。
func _dump_biome_png() -> void:
	var result := _generate_valid_map()
	var biome: Array = result["biome"]
	var terrain: Array = result["terrain"]
	# 诊断路径不会把地图挂进场景树，用完必须手动释放：否则退出时会刷一屏
	# "RID allocations were leaked at exit"（不影响游戏，但会把真正的报错淹掉）。
	_free_map_node(result)
	var h: int = biome.size()
	if h == 0:
		print("[Map] 群系图为空")
		get_tree().quit()
		return
	var w: int = (biome[0] as Array).size()
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	# 调色板固定，顺序对应 config 里 map.biomes 的顺序（日志会打印图例）
	var palette := [
		Color(0.42, 0.62, 0.24),   # 0 草地 = 亮绿
		Color(0.58, 0.45, 0.22),   # 1 荒原 = 土黄
		Color(0.10, 0.34, 0.20),   # 2 森林 = 深绿
		Color(0.78, 0.72, 0.16),   # 3 沼泽 = 黄
		Color(0.62, 0.24, 0.62),   # 4+ = 品红（提醒：加群系了，调色板该扩）
	]
	var water := Color(0.24, 0.60, 0.64)   # 不可通行（水面）= 青
	var unk := Color(0.95, 0.10, 0.10)     # 越界色 = 红（出现即说明 id 越界）
	for y in range(h):
		for x in range(w):
			var c := water
			if not bool(terrain[y][x]):
				var b := int(biome[y][x])
				c = palette[b] if b >= 0 and b < palette.size() else unk
			img.set_pixel(x, y, c)
	if _dump_zoom > 1:
		img.resize(w * _dump_zoom, h * _dump_zoom, Image.INTERPOLATE_NEAREST)
	var err := img.save_png(_dump_biome)
	print("[Map] 群系图已输出：%s（%dx%d，zoom=%d，err=%d）"
			% [_dump_biome, img.get_width(), img.get_height(), _dump_zoom, err])
	for i in range(MapGenerator.biome_count()):
		print("[Map]   色块 %d = %s" % [i, MapGenerator.biome_name(i)])
	print("[Map]   青 = 水面（不可通行）；红 = 群系 id 越界调色板（说明加了群系但没扩调色板）")
	if MapGenerator.biome_count() > palette.size():
		push_warning("[Map] 群系数 %d 超过诊断调色板 %d 色，色块图会显示越界红"
				% [MapGenerator.biome_count(), palette.size()])
	get_tree().quit()


## 释放"只出图、不进局"路径生成的地图节点。
##
## 这些路径（--preview-map / --dump-biome）拿到 result 后只取数据出图，
## 从不把 result.node 挂进场景树，于是它一直是"游离节点"。直接 quit() 的话
## Godot 会在退出时刷一屏
##   ERROR: N RID allocations of type 'P11GodotBody2D' were leaked at exit
## 这类噪音——它们不是真 bug，但会把日志里真正的报错淹掉（回归验证时要看的就是日志）。
## 所以统一在这里显式释放：挂进树的不动（由场景树管），没挂的手动 free。
func _free_map_node(result: Dictionary) -> void:
	var n: Node = result.get("node")
	if n != null and is_instance_valid(n) and n.get_parent() == null:
		n.free()


## 生成一张局内地图并输出为 PNG，用于不开编辑器检查地形/装饰效果。
## 直接用像素合成（MapGenerator.build_preview），不依赖渲染驱动，
## 因此无头环境（dummy 驱动）也能出图。
func _render_map_preview() -> void:
	var out_path: String = str(Config.get_value("debug.map_preview", ""))
	var result := _generate_valid_map()
	var cells: int = int(Config.get_value("debug.map_preview_cells", 40))
	var img := MapGenerator.build_preview(result, cells)
	var err := img.save_png(out_path)
	print("[Map] 预览已输出：%s（%dx%d，err=%d）" % [out_path, img.get_width(),
			img.get_height(), err])
	_free_map_node(result)
	get_tree().quit()


## 抓一帧当前画面存成 PNG 后退出（--capture2d）。
## 必须等 frame_post_draw：_process 里直接 get_image() 拿到的是上一帧、
## 有时甚至还没开始渲染，截出来是纯黑。
func _capture_now() -> void:
	_capture_left = -1.0
	await RenderingServer.frame_post_draw
	var tex := get_viewport().get_texture()
	if tex == null:
		push_error("[Shot] 拿不到 viewport 贴图（是不是用了 --headless？无头没有渲染输出）")
		get_tree().quit(1)
		return
	var img := tex.get_image()
	if img == null:
		push_error("[Shot] viewport 图像为空")
		get_tree().quit(1)
		return
	var err := img.save_png(_capture_path)
	print("[Shot] 截图已输出：%s（%dx%d，err=%d）" % [_capture_path,
			img.get_width(), img.get_height(), err])
	get_tree().quit()


func _process(delta: float) -> void:
	if _capture_left >= 0.0:
		_capture_left -= delta
		if _capture_left < 0.0:
			_capture_now()
	if Input.is_action_just_pressed("ui_cancel"):
		get_tree().quit()
	# 局结束后按 R 回基地（局内运行中无效）
	if Input.is_physical_key_pressed(KEY_R) and mode == Mode.RUN \
			and run.state == run.State.ENDED:
		_enter_base()


# ------------------------------------------------------------
# 模式切换
# ------------------------------------------------------------

func _clear_game_root() -> void:
	for c in game_root.get_children():
		c.queue_free()


## 进入局外基地
func _enter_base() -> void:
	mode = Mode.BASE
	hud.visible = false
	fog_system.deactivate()
	get_tree().paused = false
	warehouse_panel.close()
	statue_panel.close()
	_clear_game_root()
	var spawn: Vector2 = base_system.setup(game_root)
	var tile_size: int = int(Config.get_value("map.tile_size", 16))
	var base_size: int = int(Config.get_value("base.map_size", 64))
	# 基地 walls：外圈 1 圈墙，内部全是地板（除了墙没有障碍物）
	var base_walls: Array = []
	for y in range(base_size):
		var row: Array = []
		row.resize(base_size)
		for x in range(base_size):
			row[x] = (x == 0 or y == 0 or x == base_size - 1 or y == base_size - 1)
		base_walls.append(row)
	var player: CharacterBody2D = PLAYER_SCENE.instantiate()
	player.position = spawn
	player.setup_navigation(base_walls, tile_size)
	game_root.add_child(player)
	# 独立相机
	var cam := Camera2D.new()
	cam.set_script(CAMERA_SCRIPT)
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 8.0
	game_root.add_child(cam)
	cam.make_current()
	cam.setup(Vector2i(base_size * tile_size, base_size * tile_size), player)


## 进入一局
func _enter_run() -> void:
	mode = Mode.RUN
	hud.visible = true
	get_tree().paused = false
	_clear_game_root()
	run.start_run()
	# 固定种子只给开发/对比用（0 = 每局随机）。**只 seed 一次**，
	# 这样可达率不达标重试时仍会换图，不会卡在同一张（与 main3d.gd 同规则）。
	# 命令行 --seed 优先：它存在的意义就是"换几张图验证"，被 config 的固定种子压掉
	# 就完全失效了（会误以为在测多张图，其实每次都是同一张）。
	var forced_seed := int(Config.get_value("map.force_seed", 0))
	if _seed_override != 0:
		forced_seed = _seed_override
	if forced_seed != 0:
		seed(forced_seed)
	var result := _generate_valid_map()
	_last_map = result
	game_root.add_child(result.node)
	# 采集资源注册表：把地图上的树/石登记进 ResourceRegistry（供采集/小地图/HUD 查询）
	ResourceRegistry.build_from_map(result)
	print("[ResourceRegistry] 已登记资源节点：", ResourceRegistry.count_by_type())
	var player: CharacterBody2D = PLAYER_SCENE.instantiate()
	player.position = result.spawn
	player.setup_navigation(result.walls, int(Config.get_value("map.tile_size", 16)))
	game_root.add_child(player)
	# --weapon 覆盖必须放在 add_child 之后：_ready() 里已经按 config 的 player.weapon
	# 装好默认武器与贴图集，这里再切一次即可（switch_weapon 会重载帧序列 + 重设判定框）。
	if _weapon_override != "":
		player.switch_weapon(StringName(_weapon_override))
	# 独立相机：局内地图尺寸 = width × height × tile_size
	var cam := Camera2D.new()
	cam.set_script(CAMERA_SCRIPT)
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 8.0
	game_root.add_child(cam)
	cam.make_current()
	var map_size := Vector2(
		float(int(Config.get_value("map.width", 128))) * float(int(Config.get_value("map.tile_size", 16))),
		float(int(Config.get_value("map.height", 128))) * float(int(Config.get_value("map.tile_size", 16))),
	)
	cam.setup(map_size, player)
	extraction_system.setup(game_root, result)
	enemy_system.setup(game_root, result)
	animal_system.setup(game_root, result)
	loot_system.setup(game_root, result)
	fog_system.setup(game_root, result)
	if _no_fog:
		fog_system.disable()
	minimap.setup(result)


## 建筑交互路由（base_system 转发）
func _on_building_interacted(building_id: String) -> void:
	match building_id:
		"gate":
			_enter_run()
		"warehouse":
			warehouse_panel.open()
			base_system.reset_interaction(building_id)
		"statue":
			statue_panel.open()
			base_system.reset_interaction(building_id)
		_:
			push_warning("[Main] 未知建筑：%s" % building_id)
			base_system.reset_interaction(building_id)


# ------------------------------------------------------------
# 地图生成（含连通性校验）
# ------------------------------------------------------------

## 生成地图并校验连通性：可达地板占比低于 map.min_reachable_ratio
## （说明出生点被围死或图太碎）时换种子重新生成，最多 max_regen_attempts 次。
## 全部失败则使用最后一张（撤离点/敌人仍只刷在可达格内，保底可玩）。
func _generate_valid_map() -> Dictionary:
	var min_ratio := float(Config.get_value("map.min_reachable_ratio", 0.3))
	var max_attempts := int(Config.get_value("map.max_regen_attempts", 10))
	var result: Dictionary = {}
	for attempt in range(1, max_attempts + 1):
		result = MapGenerator.generate()
		if float(result.reachable_ratio) >= min_ratio:
			return result
		print("[Map] 第 %d/%d 次生成可达率仅 %.0f%%（需 ≥%.0f%%），换种子重试" % [
			attempt, max_attempts, float(result.reachable_ratio) * 100.0, min_ratio * 100.0])
		result.node.free()
	push_warning("[Map] 连续 %d 次未达到可达率标准，使用最后一张地图" % max_attempts)
	return result


## ============================================================
## 烟雾测试（Phase 0 遗留，debug.smoke_test=true 时启用）
## ============================================================

func _smoke_test() -> void:
	print("=== SteamPunk Extraction — 框架自检开始 ===")
	# --- 1. 正常局：搜刮 → 撤离成功 ---
	run.start_run()
	run.add_loot("scrap", 30)
	run.add_loot("steam_core", 2)
	run.extract()
	print("[自检] 1. 撤离局后仓库：", Meta.bank)
	assert(Meta.bank.get("scrap", 0) >= 30, "撤离资源未入库！")

	# --- 2. 局外升级 ---
	var bought: bool = Meta.buy_upgrade("survival.max_hp")
	print("[自检] 2. 升级 max_hp 成功：", bought, "，当前生命上限：", Meta.get_stat("survival.max_hp"))
	assert(bought, "资源足够却升级失败！")

	# --- 3. 死亡局：搜刮 → 死亡 → 全丢 ---
	var scrap_before := int(Meta.bank.get("scrap", 0))
	run.start_run()
	run.add_loot("scrap", 99)
	run.player_died()
	print("[自检] 3. 死亡局后仓库：", Meta.bank)
	assert(int(Meta.bank.get("scrap", 0)) == scrap_before, "死亡局资源不应入库！")

	# --- 4. 超时局（下一帧触发） ---
	run.start_run()
	run.time_remaining = 0.01
	print("[自检] 4. 已启动超时测试局，等待下一帧触发…")

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

enum Mode { BASE, RUN }

var mode: int = Mode.BASE

@onready var run: Node = $RunManager
@onready var game_root: Node2D = $GameRoot
@onready var extraction_system: Node = $ExtractionSystem
@onready var enemy_system: Node = $EnemySystem
@onready var loot_system: Node = $LootSystem
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
	# 地图预览：无头渲染局内地图到 PNG 后退出（debug.map_preview = 输出绝对路径）
	if Config.get_value("debug.map_preview", "") != "":
		_render_map_preview()
		return
	_enter_base()
	# headless 回归测试用：跳过基地直接进局（配合 --quit-after 跑若干帧看日志）
	if Config.get_value("debug.auto_enter_run", false):
		_enter_run()


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
	get_tree().quit()


func _process(_delta: float) -> void:
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
	var result := _generate_valid_map()
	game_root.add_child(result.node)
	var player: CharacterBody2D = PLAYER_SCENE.instantiate()
	player.position = result.spawn
	player.setup_navigation(result.walls, int(Config.get_value("map.tile_size", 16)))
	game_root.add_child(player)
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
	loot_system.setup(game_root, result)
	fog_system.setup(game_root, result)
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

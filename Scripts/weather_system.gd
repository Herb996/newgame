extends Node
## ============================================================
## WeatherSystem — 局内雨天效果（全部阶段：雨滴 / 积水 / 波纹 / 倒影 / 折射色散）
##
## 挂在 Main 下（Scenes/Main.tscn），生命周期与 FogSystem 完全对齐：
##   _enter_run()  → setup(game_root, map_result)   每局重建全部雨天节点
##   _enter_base() → deactivate()                    停雨、清引用
## 挂进 game_root 的世界节点（雨/积水/双 SubViewport）会随 main._clear_game_root()
## 自动销毁；WeatherSystem 本体与它名下的音频播放器持久存活，故 deactivate 里要
## 显式 stop 雨声、并把 puddle 的 ViewportTexture 参数换回占位图防 stale 采样。
##
## 数值全部来自 Data/config.json 的 weather 节（项目铁律：脚本零硬编码）。
## 踩水触发节奏复用 noise.footstep_interval_seconds（见 player_move_state.gd）。
##
## 渲染管线（阶段二三）：
##   - _ripple_vp：波纹 SubViewport（半分辨率、透明底）。RippleRing 池改挂在这里，
##     波纹按 (r=亮度基, g=色散量) 编码进纹理，由 puddle shader 采样做提亮+色散。
##   - _refl_vp：倒影 SubViewport（半分辨率、透明底）。内容 = 天空渐变 ColorRect +
##     按贴图分组的 MultiMesh2D（静态装饰倒影）。相机 zoom.y 取负实现垂直镜像。
##   - puddle.gdshader：SCREEN_TEXTURE 折射 + reflection_tex 倒影 + ripple_tex 色散。
## ============================================================

const RIPPLE_SCRIPT := preload("res://Scripts/ripple_ring.gd")
const PUDDLE_SHADER := preload("res://Shaders/puddle.gdshader")

# ---------- 运行时状态 ----------
var _active := false
var _tile_size := 64
var _map_w := 0
var _map_h := 0
var _water_cells: Array = []      # bool[y][x]：逻辑查询用，与 shader mask 同源

var _root: Node2D = null          # game_root
var _rain_anchor: Node2D = null
var _rain: GPUParticles2D = null
var _splash: GPUParticles2D = null
var _puddle: ColorRect = null
var _ripple_root_world: Node2D = null   # 波纹 SubViewport 内容根
var _ripples: Array = []

# 阶段二三：两个离屏 SubViewport（半分辨率）
var _refl_vp: SubViewport = null
var _ripple_vp: SubViewport = null
var _refl_cam: Camera2D = null
var _ripple_cam: Camera2D = null
var _refl_root: Node2D = null
var _sky_rect: ColorRect = null
var _refl_meshes: Array = []          # 每贴图一组 MultiMesh2D
var _placeholder_tex: ImageTexture = null   # deactivate 换掉 ViewportTexture 防 stale

# 音频播放器挂在 self（持久节点），不随切图销毁
var _rain_player: AudioStreamPlayer = null
var _step_players: Array = []
var _step_idx := 0
var _step_wav: AudioStreamWAV = null
var _dry_players: Array = []
var _dry_idx := 0
var _dry_wav: AudioStreamWAV = null

# 缓存 _process 每帧要用的 config 值（避免热路径反复点路径查表）
var _margin := 160.0
var _rain_lifetime := 0.5

# 积水统计（日志用，区分两类来源，避免误以为浅滩会自动有水）
var _puddle_noise_cells := 0
var _puddle_shallow_cells := 0


func _ready() -> void:
	add_to_group("weather_system")
	_build_audio()   # 合成占位音 + 建播放器（与地图无关，只做一次）


# ============================================================
# 对外接口
# ============================================================

## 由 main._enter_run() 在 fog_system.setup() 之后调用。
func setup(root: Node2D, map_data: Dictionary) -> void:
	deactivate()   # 幂等：先清掉上一局残留（正常情况下已被 _clear_game_root 清掉）
	if not bool(Config.get_value("weather.enabled", true)):
		return
	_active = true
	_root = root
	_tile_size = int(map_data.get("tile_size", 64))

	_build_water_grid(map_data)
	_build_puddle(map_data)
	_build_rain(root)
	_build_ripples(root)
	_play_rain()

	var total := _map_w * _map_h
	print("[Weather] 积水 %d 格（占比 %.1f%%，目标 %.1f%%）= 噪声水洼 %d + 浅滩 %d" % [
		_water_count(),
		100.0 * float(_water_count()) / float(maxi(total, 1)),
		100.0 * float(Config.get_value("weather.puddle.floor_ratio", 0.10)),
		_puddle_noise_cells, _puddle_shallow_cells,
	])


## 由 main._enter_base() 调用。世界节点已随 _clear_game_root 销毁，这里停音 + 断引用。
func deactivate() -> void:
	_active = false
	if _rain_player != null:
		_rain_player.stop()
	_rain_anchor = null
	_rain = null
	_splash = null
	_puddle = null
	_ripple_root_world = null
	_ripples = []
	_water_cells = []
	_root = null


## 退出场景树（进程结束/切主场景）：播放器若仍在播，其内部 AudioStreamPlaybackWAV
## 会持有 stream 不释放 → ObjectDB 报泄漏。这里统一 stop + 断 stream 引用。
## deactivate() 只处理"回基地"路径的停雨，覆盖不到"局内直接退出"，故单独兜底。
func _exit_tree() -> void:
	if _rain_player != null:
		_rain_player.stop()
		_rain_player.stream = null
	for p in _step_players:
		if p != null:
			p.stop()
			p.stream = null
	_step_players = []
	_step_wav = null


## 该世界坐标是否踩在积水上（浅滩 ∪ 水洼）。供 player_move_state 每脚步 tick 查询。
func is_water_at(world_pos: Vector2) -> bool:
	if not _active or _water_cells.is_empty():
		return false
	var cx := int(world_pos.x / _tile_size)
	var cy := int(world_pos.y / _tile_size)
	if cx < 0 or cy < 0 or cy >= _water_cells.size():
		return false
	var row: Array = _water_cells[cy]
	if cx >= row.size():
		return false
	return bool(row[cx])


## 踩水事件：出波纹 + 播 2D 踩水音。调用者不区分（玩家/将来敌人动物都走这里）。
func on_water_step(world_pos: Vector2) -> void:
	if not _active:
		return
	var r := _get_free_ripple()
	if r != null:
		r.spawn(world_pos,
				float(Config.get_value("weather.ripple.radius_px", 46.0)),
				float(Config.get_value("weather.ripple.duration_s", 0.55)),
				_ripple_color())
	var p := _get_free_step_player()
	if p != null:
		p.global_position = world_pos
		p.play()


## 干地脚步（雨天）：出小一圈的湿痕波纹，让整片地面看着"被雨淋湿"。
## 不播踩水音、不产生暴露噪音变化（噪音由调用方照常发）。
func on_dry_step(world_pos: Vector2) -> void:
	if not _active:
		return
	var r := _get_free_ripple()
	if r != null:
		var c := Color.from_string(str(Config.get_value("weather.ripple.color", "#bfe3ff")), Color(0.75, 0.89, 1.0))
		c.a = float(Config.get_value("weather.ripple.dry_alpha", 0.35))
		r.spawn(world_pos,
				float(Config.get_value("weather.ripple.dry_radius_px", 22.0)),
				float(Config.get_value("weather.ripple.dry_duration_s", 0.4)),
				c)


# ============================================================
# 积水网格：噪声水洼 ∪ DECOR_WATER 浅滩 → _water_cells + shader mask
# ============================================================

func _build_water_grid(map_data: Dictionary) -> void:
	var walls: Array = map_data["walls"]
	var decor: Array = map_data["decor"]
	_map_w = (walls[0] as Array).size()
	_map_h = walls.size()
	var spawn_cell: Vector2i = map_data.get("spawn_cell", Vector2i(_map_w / 2, _map_h / 2))

	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_SIMPLEX
	fn.frequency = float(Config.get_value("weather.puddle.noise_frequency", 0.045))
	# 种子走 _enter_run 的 seed 链（那里已 seed(forced_seed)），故 --seed 可复现。
	fn.seed = randi()

	var ratio := clampf(float(Config.get_value("weather.puddle.floor_ratio", 0.10)), 0.0, 0.9)

	# 先收集所有地板格的噪声值，用分位数定阈值 → 水洼占比精确命中 ratio
	# （与 map_generator._biome_quantile_edges 同一思路：simplex 近似钟形，固定阈值会失衡）。
	var samples: Array = []
	for y in range(_map_h):
		for x in range(_map_w):
			if not bool(walls[y][x]):
				samples.append(fn.get_noise_2d(float(x), float(y)))
	samples.sort()
	var thr := 1e9
	if not samples.is_empty():
		var cut := clampi(int(float(samples.size()) * (1.0 - ratio)), 0, samples.size() - 1)
		thr = float(samples[cut])

	var mask: Array = []
	for y in range(_map_h):
		var row: Array = []
		row.resize(_map_w)
		mask.append(row)

	# 噪声水洼（仅地板格）
	_puddle_noise_cells = 0
	for y in range(_map_h):
		for x in range(_map_w):
			var w := false
			if not bool(walls[y][x]) and fn.get_noise_2d(float(x), float(y)) >= thr:
				w = true
			mask[y][x] = w
			if w:
				_puddle_noise_cells += 1

	# 并入浅滩（当前恒 0 格，河流已移除；保留并集为将来恢复零改动接上）
	_puddle_shallow_cells = 0
	for y in range(_map_h):
		for x in range(_map_w):
			if int(decor[y][x]) == MapGenerator.DECOR_WATER:
				if not bool(mask[y][x]):
					_puddle_shallow_cells += 1
				mask[y][x] = true

	# 出生点周围强制无水（玩家不该一出生就站水里）
	var clear_r := int(Config.get_value("weather.puddle.clear_spawn_radius_cells", 4))
	for y in range(maxi(0, spawn_cell.y - clear_r), mini(_map_h, spawn_cell.y + clear_r + 1)):
		for x in range(maxi(0, spawn_cell.x - clear_r), mini(_map_w, spawn_cell.x + clear_r + 1)):
			mask[y][x] = false

	# 多数投票平滑：消单格椒盐，让水洼成团。墙格始终为 0。
	var iters := int(Config.get_value("weather.puddle.smooth_iterations", 2))
	for _it in range(iters):
		mask = _majority_pass(mask, walls)

	_water_cells = mask


## 一轮 8 邻多数投票（≥5 判水）。墙格强制 0。
func _majority_pass(mask: Array, walls: Array) -> Array:
	var out: Array = []
	for y in range(_map_h):
		var row: Array = []
		row.resize(_map_w)
		out.append(row)
	for y in range(_map_h):
		for x in range(_map_w):
			if bool(walls[y][x]):
				out[y][x] = false
				continue
			var n := 0
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var yy := y + dy
					var xx := x + dx
					if yy >= 0 and yy < _map_h and xx >= 0 and xx < _map_w and bool(mask[yy][xx]):
						n += 1
			out[y][x] = n >= 5
	return out


func _water_count() -> int:
	var c := 0
	for row in _water_cells:
		for v in row:
			if bool(v):
				c += 1
	return c


# ============================================================
# 积水渲染：单个覆盖全图的 ColorRect + puddle.gdshader
# ============================================================

func _build_puddle(map_data: Dictionary) -> void:
	var map_root: Node2D = map_data["node"]
	if map_root == null:
		return

	var img := Image.create(_map_w, _map_h, false, Image.FORMAT_R8)
	for y in range(_map_h):
		for x in range(_map_w):
			img.set_pixel(x, y, Color8(255 if bool(_water_cells[y][x]) else 0, 0, 0, 255))
	var mask_tex := ImageTexture.create_from_image(img)

	var rect := ColorRect.new()
	rect.name = "PuddleLayer"
	rect.position = Vector2.ZERO
	rect.size = Vector2(float(_map_w * _tile_size), float(_map_h * _tile_size))
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 全屏 Control 必须忽略鼠标，否则吃掉局内点击/选中
	# 形状全来自 shader，宿主纹理只是 1×1 白点；ColorRect 的 visibility_rect 自动按 size 算，
	# 不像 Sprite2D 那样会被 1×1 纹理裁掉整层。
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	var mat := ShaderMaterial.new()
	mat.shader = PUDDLE_SHADER
	var col: Color = Color.from_string(str(Config.get_value("weather.puddle.color", "#3f6f8f")), Color(0.25, 0.44, 0.56))
	col.a = float(Config.get_value("weather.puddle.alpha", 0.42))
	var scroll: Array = Config.get_value("weather.puddle.scroll_cells_per_s", [0.5, 0.9])
	mat.set_shader_parameter("cell_mask", mask_tex)
	mat.set_shader_parameter("mask_size", Vector2(_map_w, _map_h))
	mat.set_shader_parameter("tile_px", float(_tile_size))
	mat.set_shader_parameter("world_origin", rect.position)
	mat.set_shader_parameter("water_color", col)
	mat.set_shader_parameter("noise_scale", float(Config.get_value("weather.puddle.noise_scale", 0.10)))
	mat.set_shader_parameter("scroll_dir", Vector2(float(scroll[0]), float(scroll[1])))
	mat.set_shader_parameter("wobble", float(Config.get_value("weather.puddle.wobble", 0.65)))
	mat.set_shader_parameter("edge_soft", float(Config.get_value("weather.puddle.edge_soft", 0.30)))
	mat.set_shader_parameter("shimmer", float(Config.get_value("weather.puddle.shimmer", 0.08)))
	rect.material = mat

	map_root.add_child(rect)
	# 插到地形层之后、DecorLayer 之前：水在树/石之下（不淹树），并受 MacroLight 统一压暗。
	map_root.move_child(rect, 1)
	_puddle = rect


# ============================================================
# 雨滴 + 飞溅：RainAnchor 跟相机 + 两个 local_coords=false 的发射器
# ============================================================

func _build_rain(root: Node2D) -> void:
	var rain_z := int(Config.get_value("weather.rain.z", 6))
	_rain_lifetime = float(Config.get_value("weather.rain.lifetime_s", 0.5))
	_margin = float(Config.get_value("weather.rain.emission_margin_px", 160.0))
	var fall: Array = Config.get_value("weather.rain.fall_speed_px", [900.0, 1300.0])

	_rain_anchor = Node2D.new()
	_rain_anchor.name = "RainAnchor"
	_rain_anchor.z_index = rain_z
	root.add_child(_rain_anchor)

	# 主雨丝
	_rain = GPUParticles2D.new()
	_rain.name = "RainStreaks"
	_rain.texture = _make_streak_tex()
	_rain.local_coords = false          # 关键：世界空间模拟，anchor 移动不拖着已有雨滴瞬移
	_rain.lifetime = _rain_lifetime
	_rain.preprocess = _rain_lifetime   # 开局即铺满，不必等雨下进来
	_rain.amount = int(Config.get_value("weather.rain.amount", 700))
	_rain.process_material = _make_rain_mat(fall)
	_rain.emitting = true
	_rain_anchor.add_child(_rain)

	# 落地飞溅（独立发射器，非 sub-emitter）
	var sp: Dictionary = Config.get_value("weather.rain.splash", {})
	_splash = GPUParticles2D.new()
	_splash.name = "RainSplash"
	_splash.texture = _make_dot_tex()
	_splash.local_coords = false
	_splash.lifetime = float(sp.get("lifetime_s", 0.22))
	_splash.amount = int(Config.get_value("weather.rain.splash_amount", 140))
	_splash.process_material = _make_splash_mat(sp)
	_splash.z_index = 1                 # 相对 anchor：雨丝 6、飞溅 7
	_splash.emitting = true
	_rain_anchor.add_child(_splash)


func _make_rain_mat(fall: Array) -> ParticleProcessMaterial:
	# Godot 4 已统一粒子材质：GPUParticles2D 用的就是 ParticleProcessMaterial（无 2D 专版）。
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = Vector3(800, 600, 0)   # _process 每帧按 zoom 重算
	# 雨滴用「初速度沿倾斜方向 + 零重力」表达匀速下落带风：
	# direction 会被引擎归一化，取 (wind, fall_mid) 的合成方向，速率取 fall，
	# 于是垂直分量≈fall、水平分量≈wind_x。gravity 留零（雨本就匀速）。
	var wind_x := float(Config.get_value("weather.rain.wind_x_px", -60.0))
	var fall_mid := (float(fall[0]) + float(fall[1])) * 0.5
	m.direction = Vector3(wind_x, fall_mid, 0.0)
	m.spread = 0.0
	m.initial_velocity_min = float(fall[0])
	m.initial_velocity_max = float(fall[1])
	m.gravity = Vector3.ZERO
	# lifetime 在 GPUParticles2D 节点上设（material 只有 lifetime_randomness）
	m.lifetime_randomness = 0.3
	var st: Dictionary = Config.get_value("weather.rain.streak", {})
	var rc := Color.from_string(str(st.get("color", "#a8c4e0")), Color(0.66, 0.77, 0.88))
	rc.a = float(st.get("alpha", 0.55))
	m.color = rc
	return m


func _make_splash_mat(sp: Dictionary) -> ParticleProcessMaterial:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = Vector3(700, 300, 0)
	m.direction = Vector3(0, -1, 0)          # 上抛
	m.spread = 55.0
	var spd: Array = sp.get("speed_px", [40.0, 110.0])
	m.initial_velocity_min = float(spd[0])
	m.initial_velocity_max = float(spd[1])
	# 飞溅靠重力回落：gravity 方向朝下（+y），长度即加速度 px/s²
	m.gravity = Vector3(0, float(sp.get("gravity_px", 1800.0)), 0)
	m.lifetime_randomness = 0.4
	var sc := Color.from_string(str(sp.get("color", "#cfe6ff")), Color(0.81, 0.9, 1.0))
	sc.a = float(sp.get("alpha", 0.7))
	m.color = sc
	return m


## 雨丝贴图：竖向 alpha 两端淡、中间亮（sin 包络），像拉长的水线。
func _make_streak_tex() -> ImageTexture:
	var st: Dictionary = Config.get_value("weather.rain.streak", {})
	var w := maxi(1, int(st.get("width_px", 3)))
	var h := maxi(2, int(st.get("length_px", 26)))
	var c := Color.from_string(str(st.get("color", "#a8c4e0")), Color(0.66, 0.77, 0.88))
	var a := float(st.get("alpha", 0.55))
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		var prof := sin(float(y) / float(maxi(h - 1, 1)) * PI)
		for x in range(w):
			img.set_pixel(x, y, Color(c.r, c.g, c.b, a * prof))
	return ImageTexture.create_from_image(img)


## 飞溅圆点贴图：软边小圆。
func _make_dot_tex() -> ImageTexture:
	var sp: Dictionary = Config.get_value("weather.rain.splash", {})
	var s := maxi(2, int(sp.get("size_px", 4.0)))
	var c := Color.from_string(str(sp.get("color", "#cfe6ff")), Color(0.81, 0.9, 1.0))
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var ctr := float(s - 1) * 0.5
	var rad := float(s) * 0.5
	for y in range(s):
		for x in range(s):
			var d := Vector2(float(x) - ctr, float(y) - ctr).length() / rad
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, c.a * a))
	return ImageTexture.create_from_image(img)


func _process(_delta: float) -> void:
	if not _active or _rain_anchor == null or not is_instance_valid(_rain_anchor):
		return
	var cam := get_viewport().get_camera_2d()
	if cam == null or not is_instance_valid(cam):
		return
	# anchor 对齐相机中心；local_coords=false 使已存在粒子留在原地，只有新发射的跟着走。
	_rain_anchor.global_position = cam.global_position
	var vp := get_viewport().get_visible_rect().size
	var z := maxf(cam.zoom.x, 0.05)
	var half := vp / z * 0.5 + Vector2(_margin, _margin)
	# 发射框只覆盖视口+margin（不再额外加下落行程）：preprocess=lifetime 已让首帧
	# 铺满整框，再加行程只会把同量粒子摊到更大体积里 → 雨看着稀稀拉拉（截图实测）。
	_rain.process_material.emission_box_extents = Vector3(half.x, half.y, 0)
	if _splash != null and is_instance_valid(_splash):
		_splash.process_material.emission_box_extents = Vector3(half.x * 0.9, half.y * 0.5, 0)


# ============================================================
# 踩水波纹对象池
# ============================================================

func _build_ripples(root: Node2D) -> void:
	_ripple_root_world = Node2D.new()
	_ripple_root_world.name = "RippleLayer"
	# 晚于地图根添加 → 同 z 下画在积水之上；玩家 z=1 仍在波纹之上。
	root.add_child(_ripple_root_world)
	var n := int(Config.get_value("weather.ripple.pool_size", 16))
	for _i in range(n):
		var r := RIPPLE_SCRIPT.new()
		r.visible = false
		_ripple_root_world.add_child(r)
		_ripples.append(r)


func _get_free_ripple() -> Node2D:
	for r in _ripples:
		if r != null and is_instance_valid(r) and r.is_free():
			return r
	return null


func _ripple_color() -> Color:
	var c := Color.from_string(str(Config.get_value("weather.ripple.color", "#bfe3ff")), Color(0.75, 0.89, 1.0))
	c.a = float(Config.get_value("weather.ripple.alpha", 0.8))
	return c


# ============================================================
# 程序合成占位音（项目无音频素材）：预生成 AudioStreamWAV，走引擎原生无缝循环
# ============================================================

func _build_audio() -> void:
	var sfx_bus := _sfx_bus_name()

	_rain_player = AudioStreamPlayer.new()
	_rain_player.name = "RainLoop"
	_rain_player.bus = sfx_bus
	_rain_player.volume_db = float(Config.get_value("weather.audio.rain_volume_db", -16.0))
	_rain_player.stream = _gen_rain_wav()
	add_child(_rain_player)

	_step_wav = _gen_step_wav()
	var step_db := float(Config.get_value("weather.step.volume_db", -10.0))
	var max_d := float(Config.get_value("weather.step.max_distance_px", 900.0))
	var pc := maxi(1, int(Config.get_value("weather.step.players", 3)))
	for _i in range(pc):
		var p := AudioStreamPlayer2D.new()
		p.bus = sfx_bus
		p.volume_db = step_db
		p.max_distance = max_d
		p.stream = _step_wav
		add_child(p)
		_step_players.append(p)


func _sfx_bus_name() -> String:
	# SFX 总线由 DisplaySettings._ensure_bus() 在 autoload 阶段建好；取不到回落 Master(0)。
	var idx := AudioServer.get_bus_index("SFX")
	return AudioServer.get_bus_name(idx) if idx >= 0 else "Master"


func _play_rain() -> void:
	if _rain_player != null and not _rain_player.playing:
		_rain_player.play()


func _get_free_step_player() -> AudioStreamPlayer2D:
	# 轮转优先：先找没在播的，全忙则复用最旧的一个（踩水音短，重叠可接受）。
	for i in range(_step_players.size()):
		var idx := (_step_idx + i) % _step_players.size()
		var p: AudioStreamPlayer2D = _step_players[idx]
		if p != null and not p.playing:
			_step_idx = (idx + 1) % _step_players.size()
			return p
	if _step_players.is_empty():
		return null
	var p0: AudioStreamPlayer2D = _step_players[_step_idx]
	_step_idx = (_step_idx + 1) % _step_players.size()
	return p0


## 雨声循环：白噪声 → 一阶低通 + 一阶高通塑形 → gust 慢调幅 → 混入稀疏嘀嗒 → 首尾交叉淡化。
static func _gen_rain_wav() -> AudioStreamWAV:
	var seconds := float(Config.get_value("weather.audio.rain_loop_seconds", 4.0))
	var rate := int(Config.get_value("weather.audio.sample_rate", 22050))
	var low_hz := float(Config.get_value("weather.audio.rain_lowpass_hz", 1400.0))
	var high_hz := float(Config.get_value("weather.audio.rain_highpass_hz", 180.0))
	var gust_depth := float(Config.get_value("weather.audio.gust_depth", 0.35))
	var drips := int(Config.get_value("weather.audio.drip_count", 6))

	var n := int(seconds * float(rate))
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5A1E   # 固定种子：占位音每次启动一致，避免循环点抖动

	var a_lp := 1.0 - exp(-TAU * low_hz / float(rate))
	var a_hp := exp(-TAU * high_hz / float(rate))
	var lp := 0.0
	var hp_prev := 0.0
	var lp_prev := 0.0
	# gust 用几个不同频率的慢正弦叠加（近似随机起伏，且天然首尾连续）
	for i in range(n):
		var t := float(i) / float(n)
		var white := rng.randf_range(-1.0, 1.0)
		lp += a_lp * (white - lp)
		var hp := a_hp * (hp_prev + lp - lp_prev)
		hp_prev = hp
		lp_prev = lp
		var gust := 0.5 + 0.5 * (0.6 * sin(t * TAU * 2.0) + 0.4 * sin(t * TAU * 5.0 + 1.3))
		var env := 1.0 - gust_depth + gust_depth * gust
		buf[i] = hp * env * 0.35

	# 稀疏嘀嗒瞬态（下滑正弦 + 指数衰减），混进雨底
	for d in range(drips):
		var pos := int(rng.randf_range(0.0, float(n - int(rate * 0.08))))
		var f0 := rng.randf_range(1200.0, 2600.0)
		var ph := 0.0
		for k in range(int(rate * 0.05)):
			var tt := float(k) / float(rate)
			ph += TAU * f0 * (1.0 - 0.6 * tt / 0.05) / float(rate)
			buf[pos + k] += sin(ph) * exp(-tt * 60.0) * 0.25

	_crossfade_loop(buf)
	return _pack_wav(buf, rate)


## 踩水音：短噪声包络（指数衰减）× 中心频率下滑 + 下滑正弦「啾」，模拟脚离水面。
static func _gen_step_wav() -> AudioStreamWAV:
	var dur := float(Config.get_value("weather.audio.step_duration_s", 0.18))
	var rate := int(Config.get_value("weather.audio.sample_rate", 22050))
	var n := int(dur * float(rate))
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x3C77
	var a_lp := 1.0 - exp(-TAU * 1800.0 / float(rate))
	var lp := 0.0
	var ph := 0.0
	for i in range(n):
		var t := float(i) / float(rate)
		var env := exp(-t * 26.0)
		lp += a_lp * (rng.randf_range(-1.0, 1.0) - lp)
		var f := lerpf(850.0, 220.0, t / dur)
		ph += TAU * f / float(rate)
		buf[i] = (lp * 0.7 + sin(ph) * 0.3) * env * 0.6
	return _pack_wav(buf, rate)


## 首尾交叉淡化：把尾部混进头部，使 LOOP_FORWARD 接缝无爆点。
static func _crossfade_loop(buf: PackedFloat32Array) -> void:
	var n := buf.size()
	var xf := mini(n / 4, int(22050 * 0.25))
	if xf <= 0:
		return
	for i in range(xf):
		var w := float(i) / float(xf)
		buf[i] = lerpf(buf[n - xf + i], buf[i], w)


static func _pack_wav(buf: PackedFloat32Array, rate: int) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.stereo = false
	w.mix_rate = rate
	var bytes := PackedByteArray()
	bytes.resize(buf.size() * 2)
	for i in range(buf.size()):
		bytes.encode_s16(i * 2, int(clampf(buf[i], -1.0, 1.0) * 32767.0))
	w.data = bytes
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = buf.size()
	return w

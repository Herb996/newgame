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
##   - _refl_vp：倒影 SubViewport（半分辨率、透明底）。内容 = 天空渐变 Sprite2D +
##     按贴图分组的 MultiMesh2D（静态装饰倒影）。倒影实例在 CPU 侧绕各自底边
##     垂直镜像挂到脚下（真倒挂），视口正立渲染，水在哪倒影就在哪。
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
var _sky_rect: Sprite2D = null
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
	# 2×2 白占位图：deactivate 时把 puddle 的 ViewportTexture 参数换回它，
	# 防止子视口销毁后 shader 仍采样 stale 纹理报错。
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	_placeholder_tex = ImageTexture.create_from_image(img)
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
	_build_viewports(root)
	_build_puddle(map_data)
	_build_reflection(map_data)
	_build_ripples()
	_build_rain(root)
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
	_refl_vp = null
	_ripple_vp = null
	_refl_cam = null
	_ripple_cam = null
	_refl_root = null
	_sky_rect = null
	_refl_meshes = []
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
	for p in _dry_players:
		if p != null:
			p.stop()
			p.stream = null
	_dry_players = []
	_dry_wav = null


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
				_ripple_color(float(Config.get_value("weather.ripple.alpha", 0.8))))
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
		r.spawn(world_pos,
				float(Config.get_value("weather.ripple.dry_radius_px", 30.0)),
				float(Config.get_value("weather.ripple.dry_duration_s", 0.6)),
				_ripple_color(float(Config.get_value("weather.ripple.dry_alpha", 0.55))))
	var p := _get_free_dry_player()
	if p != null:
		p.global_position = world_pos
		p.play()


# ============================================================
# 双离屏 SubViewport（半分辨率）：倒影 / 波纹
# 都挂在 game_root 下，随 _clear_game_root() 自动销毁。
# ============================================================

func _build_viewports(root: Node2D) -> void:
	var scale := float(Config.get_value("weather.viewports.scale", 0.5))
	var vp := get_viewport().get_visible_rect().size
	var sub := Vector2i(maxi(1, int(vp.x * scale)), maxi(1, int(vp.y * scale)))

	# 倒影视口：内容根 + 相机（正 zoom 渲染；垂直镜像由 puddle shader 采样翻 V 实现）
	_refl_vp = _make_sub_vp(sub, "ReflectionViewport")
	root.add_child(_refl_vp)
	_refl_root = Node2D.new()
	_refl_root.name = "ReflectionRoot"
	_refl_vp.add_child(_refl_root)
	_refl_cam = Camera2D.new()
	_refl_cam.name = "ReflCam"
	_refl_root.add_child(_refl_cam)
	_refl_cam.make_current()   # 只影响所属 SubViewport 的当前相机，不抢主视口

	# 波纹视口：RippleRing 池挂在世界坐标内容根下，spawn 协议不变
	_ripple_vp = _make_sub_vp(sub, "RippleViewport")
	root.add_child(_ripple_vp)
	_ripple_root_world = Node2D.new()
	_ripple_root_world.name = "RippleLayer"
	_ripple_vp.add_child(_ripple_root_world)
	_ripple_cam = Camera2D.new()
	_ripple_cam.name = "RippleCam"
	_ripple_root_world.add_child(_ripple_cam)
	_ripple_cam.make_current()

	print("[Weather] 子视口建好 %dx%d ×2（scale=%.2f）" % [sub.x, sub.y, scale])


func _make_sub_vp(size: Vector2i, vp_name: String) -> SubViewport:
	var v := SubViewport.new()
	v.name = vp_name
	v.size = size
	v.transparent_bg = true   # 透明底：天空渐变由视口内节点自绘，缺省不污染成黑/灰
	v.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	v.gui_disable_input = true
	return v


## 每帧把主相机位姿同步到两个子视口相机：
## - zoom = 主相机 zoom × scale（半分辨率视口显示同一世界区域，SCREEN_UV 与贴图 UV 逐点对应）
## - 倒影视口 zoom.y 取负 → 内容绕视口水平中线垂直镜像（相机一行实现翻转）
func _sync_viewports() -> void:
	if _refl_vp == null or _ripple_vp == null:
		return
	var cam := get_viewport().get_camera_2d()
	if cam == null or not is_instance_valid(cam):
		return
	var vp := get_viewport().get_visible_rect().size
	var scale := float(Config.get_value("weather.viewports.scale", 0.5))
	var sub_px := Vector2i(maxi(1, int(vp.x * scale)), maxi(1, int(vp.y * scale)))
	if _refl_vp.size != sub_px:
		_refl_vp.size = sub_px      # 窗口缩放自愈
		_ripple_vp.size = sub_px
	var z := maxf(cam.zoom.x, 0.05)
	var zs := z * scale
	_refl_cam.global_position = cam.global_position
	# 正 zoom 正立渲染：镜像已在 _build_reflection 的实例变换里完成（绕各装饰底边翻转）。
	_refl_cam.zoom = Vector2(zs, zs)
	_ripple_cam.global_position = cam.global_position
	_ripple_cam.zoom = Vector2(zs, zs)
	if _sky_rect != null and is_instance_valid(_sky_rect):
		var vis := vp / z   # 可见世界区域（与 RainAnchor 同款算法）
		_sky_rect.position = cam.global_position - vis * 0.5
		_sky_rect.scale = vis / 64.0   # GradientTexture2D 默认 64px


# ============================================================
# 倒影内容：天空渐变底 + 按贴图分组的 MultiMesh2D 批量静态装饰
# 倒影 = 每个装饰绕自身底边垂直镜像的副本（CPU 侧翻转实例变换，真倒挂），
# 视口正立渲染，puddle shader 直接按 SCREEN_UV 采样即逐点对齐。
# ============================================================

func _build_reflection(map_data: Dictionary) -> void:
	if _refl_root == null:
		return

	# 天空渐变底：先添加 → 垫在所有倒影之下。Sprite2D 拉伸 64px 渐变贴图，
	# _sync_viewports 每帧按可见世界区域同步位置/缩放。
	var gtex := GradientTexture2D.new()
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	grad.colors = PackedColorArray([
		Color.from_string(str(Config.get_value("weather.reflection.sky_top_color", "#3c4c60")), Color(0.24, 0.30, 0.38)),
		Color.from_string(str(Config.get_value("weather.reflection.sky_bottom_color", "#6d8ba6")), Color(0.43, 0.55, 0.65)),
	])
	gtex.gradient = grad
	gtex.fill_from = Vector2(0, 0)
	gtex.fill_to = Vector2(0, 1)   # 垂直渐变：世界坐标顶部深、底部浅
	_sky_rect = Sprite2D.new()
	_sky_rect.name = "SkyGradient"
	_sky_rect.texture = gtex
	_sky_rect.centered = false
	_refl_root.add_child(_sky_rect)

	# 收集带 refl 标记的装饰（map_generator 侧 set_meta），按贴图分组
	var map_root: Node2D = map_data["node"]
	var decor: Node2D = map_root.get_node_or_null("DecorLayer") if map_root != null else null
	if decor == null:
		return
	var frags: Array = Config.get_value("weather.reflection.exclude_path_fragments", ["crack"])
	var groups := {}   # texture -> Array[Sprite2D]
	var total := 0
	for c in decor.get_children():
		var sp := c as Sprite2D
		if sp == null or not sp.has_meta("refl") or sp.texture == null:
			continue
		var skip := false
		for f in frags:
			if str(f) != "" and sp.texture.resource_path.contains(str(f)):
				skip = true   # 剔除贴地裂缝类（双保险：meta 本就不会打给它们）
				break
		if skip:
			continue
		if not groups.has(sp.texture):
			groups[sp.texture] = []
		groups[sp.texture].append(sp)
		total += 1

	# 每组一个 MultiMesh2D：静态装饰 setup 建一次，不每帧更新
	for tex in groups:
		var sprites: Array = groups[tex]
		var ts := Vector2((tex as Texture2D).get_size())
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_colors = true   # 本引擎版本无 color_format 枚举，布尔开关；必须先于 instance_count
		var quad := QuadMesh.new()
		quad.size = ts
		mm.mesh = quad
		mm.instance_count = sprites.size()
		for i in range(sprites.size()):
			var s: Sprite2D = sprites[i]
			# 倒影 = 绕自身底边（脚线）垂直镜像的副本：
			# 世界矩形 [P, P+S]，P = position + offset*scale，S = tex_size*scale；
			# 底边 y_b = P.y + S.y，镜像后矩形占 [P.y+S.y, P.y+2S.y]（正挂脚下），
			# 中心 y = P.y + 1.5*S.y。basis.y 取负 → quad 内容上下翻转（真倒挂）；
			# basis.x 延续 flip_h 的水平镜像。倒影直接挂在物体脚下的水里，位置永远正确。
			var p0 := s.position + s.offset * s.scale
			var sx := s.scale.x * (-1.0 if s.flip_h else 1.0)
			var origin := Vector2(p0.x + ts.x * s.scale.x * 0.5, p0.y + ts.y * s.scale.y * 1.5)
			mm.set_instance_transform_2d(i, Transform2D(Vector2(sx, 0.0), Vector2(0.0, -s.scale.y), origin))
			mm.set_instance_color(i, s.modulate)   # 烘焙群系色调/亮度抖动
		var mm2d := MultiMeshInstance2D.new()
		mm2d.multimesh = mm
		mm2d.texture = tex
		_refl_root.add_child(mm2d)
		_refl_meshes.append(mm2d)

	print("[Weather] 倒影 MultiMesh %d 组 / %d 个装饰" % [_refl_meshes.size(), total])


# ============================================================
# 积水网格：噪声水洼 ∪ DECOR_WATER 浅滩 → _water_cells + shader mask
# ============================================================

func _build_water_grid(map_data: Dictionary) -> void:
	var walls: Array = map_data["walls"]
	var decor: Array = map_data["decor"]
	var biome: Array = map_data.get("biome", [])
	_map_w = (walls[0] as Array).size()
	_map_h = walls.size()
	var spawn_cell: Vector2i = map_data.get("spawn_cell", Vector2i(_map_w / 2, _map_h / 2))

	# 积水只允许出现在指定群系（默认草地0/森林2）的地板格上
	var allowed_raw: Array = Config.get_value("weather.puddle.allowed_biomes", [0, 2])
	var eligible: Array = []
	for y in range(_map_h):
		var erow: Array = []
		erow.resize(_map_w)
		for x in range(_map_w):
			var ok := not bool(walls[y][x])
			if ok and not biome.is_empty():
				var bid := int(biome[y][x])
				var inb := false
				for a in allowed_raw:
					if int(a) == bid:
						inb = true
						break
				ok = inb
			erow[x] = ok
		eligible.append(erow)

	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_SIMPLEX
	fn.frequency = float(Config.get_value("weather.puddle.noise_frequency", 0.045))
	# 种子走 _enter_run 的 seed 链（那里已 seed(forced_seed)），故 --seed 可复现。
	fn.seed = randi()

	var ratio := clampf(float(Config.get_value("weather.puddle.floor_ratio", 0.10)), 0.0, 0.9)

	# 分位数阈值只在"可选格(草地/森林地板)"里统计 → floor_ratio 是"占这些格的比例"，
	# 保证部分地面有水、且精确命中占比（simplex 近似钟形，固定阈值会失衡）。
	var samples: Array = []
	for y in range(_map_h):
		for x in range(_map_w):
			if bool(eligible[y][x]):
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

	# 噪声水洼（仅可选格）
	_puddle_noise_cells = 0
	for y in range(_map_h):
		for x in range(_map_w):
			var w := false
			if bool(eligible[y][x]) and fn.get_noise_2d(float(x), float(y)) >= thr:
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
	# 平滑可能把水漫到非草地/森林格（或墙），最后再与 eligible 求交收回。
	for y in range(_map_h):
		for x in range(_map_w):
			if not bool(eligible[y][x]):
				mask[y][x] = false

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

	var img := Image.create(_map_w, _map_h, false, Image.FORMAT_RGBA8)
	for y in range(_map_h):
		for x in range(_map_w):
			img.set_pixel(x, y, Color(1, 1, 1, 1) if bool(_water_cells[y][x]) else Color(0, 0, 0, 0))
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
	# ---- 阶段二：倒影 / 折射 / 波纹 ----
	# 两张视口纹理与 SCREEN_UV 逐点对应（半分辨率视口渲染同一世界区域）。
	mat.set_shader_parameter("reflection_tex",
			_refl_vp.get_texture() if _refl_vp != null else _placeholder_tex)
	mat.set_shader_parameter("ripple_tex",
			_ripple_vp.get_texture() if _ripple_vp != null else _placeholder_tex)
	mat.set_shader_parameter("reflection_alpha", float(Config.get_value("weather.reflection.alpha", 0.55)))
	mat.set_shader_parameter("wobble_scale", float(Config.get_value("weather.reflection.wobble_scale", 0.12)))
	mat.set_shader_parameter("wobble_speed", float(Config.get_value("weather.reflection.wobble_speed", 0.8)))
	mat.set_shader_parameter("wobble_strength", float(Config.get_value("weather.reflection.wobble_strength", 0.012)))
	mat.set_shader_parameter("dispersion", float(Config.get_value("weather.reflection.dispersion", 0.015)))
	mat.set_shader_parameter("refraction_strength", float(Config.get_value("weather.refraction.strength", 0.008)))
	mat.set_shader_parameter("reflection_blend", float(Config.get_value("weather.puddle.reflection_blend", 0.65)))
	mat.set_shader_parameter("ripple_glow", float(Config.get_value("weather.ripple.glow", 0.35)))
	mat.set_shader_parameter("ripple_tint",
			Color.from_string(str(Config.get_value("weather.ripple.color", "#bfe3ff")), Color(0.75, 0.89, 1.0)))
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
	_sync_viewports()


# ============================================================
# 踩水波纹对象池
# ============================================================

func _build_ripples() -> void:
	if _ripple_root_world == null:
		return
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


## 波纹颜色 = 通道编码（puddle shader 拆通道用）：
## r=亮度基（提亮水面），g/b=色散量（偏移 UV）。单圈一次绘制即完成通道拆分。
func _ripple_color(alpha: float) -> Color:
	var disp := float(Config.get_value("weather.ripple.disp_channel", 0.5))
	return Color(
		float(Config.get_value("weather.ripple.base_channel", 0.85)),
		disp, disp,
		alpha)


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

	# 干脚步池：与踩水音同构但音色区分（低通截止/时长/音量全部走 config）。
	_dry_wav = _gen_dry_step_wav()
	var dry_db := float(Config.get_value("weather.step.dry_volume_db", -14.0))
	for _i in range(pc):
		var p := AudioStreamPlayer2D.new()
		p.bus = sfx_bus
		p.volume_db = dry_db
		p.max_distance = max_d
		p.stream = _dry_wav
		add_child(p)
		_dry_players.append(p)


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


func _get_free_dry_player() -> AudioStreamPlayer2D:
	# 与踩水音池同款轮转策略：优先空闲，全忙复用最旧。
	for i in range(_dry_players.size()):
		var idx := (_dry_idx + i) % _dry_players.size()
		var p: AudioStreamPlayer2D = _dry_players[idx]
		if p != null and not p.playing:
			_dry_idx = (idx + 1) % _dry_players.size()
			return p
	if _dry_players.is_empty():
		return null
	var p0: AudioStreamPlayer2D = _dry_players[_dry_idx]
	_dry_idx = (_dry_idx + 1) % _dry_players.size()
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


## 干脚步：900Hz 低通噪声脆响（短促闷响）+ 弱低频体感。
## 刻意与踩水音区分：干地闷而脆，踩水亮而溅（高频 + 下滑「啾」）。
static func _gen_dry_step_wav() -> AudioStreamWAV:
	var dur := float(Config.get_value("weather.audio.step_dry_duration_s", 0.10))
	var rate := int(Config.get_value("weather.audio.sample_rate", 22050))
	var low_hz := float(Config.get_value("weather.audio.step_dry_lowpass_hz", 900.0))
	var n := int(dur * float(rate))
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xD212   # 固定种子：每次启动音色一致
	var a_lp := 1.0 - exp(-TAU * low_hz / float(rate))
	var lp := 0.0
	var ph := 0.0
	for i in range(n):
		var t := float(i) / float(rate)
		var env := exp(-t * 42.0)   # 比 wet 的 26 更陡：干脚步更短促
		lp += a_lp * (rng.randf_range(-1.0, 1.0) - lp)
		var f := lerpf(240.0, 120.0, t / dur)   # 弱低频体感，模拟脚底闷响
		ph += TAU * f / float(rate)
		buf[i] = (lp * 0.85 + sin(ph) * 0.15) * env * 0.55
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

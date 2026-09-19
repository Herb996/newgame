extends Node
## ============================================================
## WeatherSystem — 局内雨天效果（雨滴 / 雨湿地面 / 踩水波纹）
##
## 命名说明（用户 2026-09-19 指出"我没让弄湿地啊"）：项目只有草地/森林/荒原/沼泽
## 四个群系，**没有"湿地"这一种**。本文件的"雨湿地面"= 下雨把草地/森林的地面打湿，
## 是天气状态、不是地形类别，故配置段与节点都叫 rain_ground / RainGroundLayer。
##
## 挂在 Main 下（Scenes/Main.tscn），生命周期与 FogSystem 完全对齐：
##   _enter_run()  → setup(game_root, map_result)   每局重建全部雨天节点
##   _enter_base() → deactivate()                    停雨、清引用
## 挂进 game_root 的世界节点（雨/雨湿地面/波纹视口）会随 main._clear_game_root()
## 自动销毁；WeatherSystem 本体与它名下的音频播放器持久存活，故 deactivate 里要
## 显式 stop 雨声、并把雨湿地面层的 ViewportTexture 参数换回占位图防 stale 采样。
##
## 数值全部来自 Data/config.json 的 weather 节（项目铁律：脚本零硬编码）。
## 踩水触发节奏复用 noise.footstep_interval_seconds（见 player_move_state.gd）。
##
## 2026-09-19 按用户裁定整段重做：**取消"水洼"概念**。只要下雨，草地/森林的
## 地面整体是湿的，踩哪都出波纹；荒原/沼泽不湿。于是删掉
##   - 噪声水洼生成（floor_ratio 分位数阈值 / 出生点无水圈）
##   - 倒影通道（天空渐变 SubViewport；物件倒影此前已按需求裁掉）
##   - 折射色散（屏幕纹理扭曲）
## 雨湿地面层只做"压暗 + 偏冷 + 斑驳反光"，波纹合成通路保持原样。
##
## 同日第二轮裁定：**湿脚印通路整体删除**（用户："把脚印去掉吧，太丑了"）。
## 干草地上凭空一串深色椭圆只会读成脏点/落叶，地面本身不够有读感时更是如此。
## 于是 wet_footprint.gd、_prints 池、weather.footprint 配置段一并移除，
## 踩水的反馈全部回到波纹一条通道上（椭圆 + 只画部分弧段）。
##
## 渲染管线：
##   - _wet_layer：覆盖全图的 ColorRect + rain_ground.gdshader，湿度场掩码
##     （CPU 按群系烘焙 + 模糊）线性插值 + 域扭曲 → 干湿边界是揉弯的软带。
##   - _ripple_vp：波纹 SubViewport（半分辨率、透明底）。RippleRing 池挂在这里，
##     波纹按 (r=亮度基, g=晃动量) 编码进纹理，由雨湿地面 shader 采样做提亮+扰动。
## ============================================================

const RIPPLE_SCRIPT := preload("res://Scripts/ripple_ring.gd")
const WET_SHADER := preload("res://Shaders/rain_ground.gdshader")
const RAIN_OVERLAY_SHADER := preload("res://Shaders/rain_overlay.gdshader")

# ---------- 运行时状态 ----------
var _active := false
var _tile_size := 64
var _map_w := 0
var _map_h := 0
var _wet_field: Array = []        # float[y][x] 连续湿度场 0..1（烘焙成 shader 掩码）
var _wet_cells: Array = []        # bool[y][x]：逻辑查询用，与掩码同源
var _wet_count := 0

var _root: Node2D = null          # game_root
var _rain_anchor: Node2D = null
var _rain_layers: Array = []      # [{node, mat, wind_factor, phase, extents_k}] 远/中/近三层
var _splash: GPUParticles2D = null
var _overlay: ColorRect = null    # 屏幕雨幕（DEV LOG.02 步骤 6）
var _overlay_layer: CanvasLayer = null
var _elapsed := 0.0               # 阵风包络的相位时钟
var _fade_tween: Tween = null     # 进局雨幕淡入（见 _fade_in_rain）
var _wet_layer: ColorRect = null
var _ripple_root_world: Node2D = null   # 波纹 SubViewport 内容根
var _ripples: Array = []

# 离屏 SubViewport（半分辨率）：只留波纹通道
var _ripple_vp: SubViewport = null
var _ripple_cam: Camera2D = null
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
var _wind_x := -320.0
var _gust_amp := 0.5
var _gust_period := 7.0


func _ready() -> void:
	add_to_group("weather_system")
	# 2×2 白占位图：deactivate 时把湿地层的 ViewportTexture 参数换回它，
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

	_build_wet_mask(map_data)
	_build_viewports(root)
	_build_wet_layer(map_data)
	_build_ripples()
	_build_rain(root)
	_play_rain()
	_fade_in_rain()

	var total := _map_w * _map_h
	print("[Weather] 雨湿地面 %d 格（占全图 %.1f%%）＝群系 %s，半径 %d 格 × %d 轮模糊" % [
		_wet_count,
		100.0 * float(_wet_count) / float(maxi(total, 1)),
		str(Config.get_value("weather.rain_ground.allowed_biomes", [0, 2])),
		int(Config.get_value("weather.rain_ground.boundary_blur", 2)),
		int(Config.get_value("weather.rain_ground.boundary_passes", 3)),
	])


## 由 main._enter_base() 调用。世界节点已随 _clear_game_root 销毁，这里停音 + 断引用。
func deactivate() -> void:
	_active = false
	if _rain_player != null:
		_rain_player.stop()
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null
	_rain_anchor = null
	_rain_layers = []
	_splash = null
	_overlay = null
	_overlay_layer = null
	_elapsed = 0.0
	_wet_layer = null
	_ripple_root_world = null
	_ripples = []
	_ripple_vp = null
	_ripple_cam = null
	_wet_field = []
	_wet_cells = []
	_wet_count = 0
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


## 该世界坐标是否踩在湿地上（草地/森林）。供 player_move_state 每脚步 tick 查询。
## 为什么是邻域查询而不是单格硬判定：屏幕上的湿地是 wet_mask 经线性插值 + 域扭曲
## （最多 edge_warp 格）后的软边轮廓，而 _wet_cells 是整格布尔——两者在干湿交界处
## 本来就错开近一格，单格判定会让"视觉上明显站在湿地里"的脚步不出波纹。
## 容差由 weather.rain_ground.step_wet_radius_cells 控制（0=退回单格硬判定）。
func is_wet_at(world_pos: Vector2) -> bool:
	if not _active or _wet_cells.is_empty():
		return false
	var cx := int(world_pos.x / _tile_size)
	var cy := int(world_pos.y / _tile_size)
	if cx < 0 or cy < 0 or cx >= _map_w or cy >= _wet_cells.size():
		return false
	var r := int(Config.get_value("weather.rain_ground.step_wet_radius_cells", 1))
	for y in range(maxi(0, cy - r), mini(_map_h, cy + r + 1)):
		var row: Array = _wet_cells[y]
		for x in range(maxi(0, cx - r), mini(_map_w, cx + r + 1)):
			if bool(row[x]):
				return true
	return false


## 湿地脚步事件：出波纹 + 播踩水音。调用者不区分（玩家/将来敌人动物都走这里）。
func on_wet_step(world_pos: Vector2) -> void:
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


## 干地脚步（雨天）：只播闷响，**不出波纹**。波纹是水面专属：它经湿地层合成，
## 在荒原/沼泽上要么完全不显示、要么显示成一圈白线（用户反馈"地面波纹丑爆"的来源）。
## 不产生暴露噪音变化（噪音由调用方照常发）。
func on_dry_step(world_pos: Vector2) -> void:
	if not _active:
		return
	var p := _get_free_dry_player()
	if p != null:
		p.global_position = world_pos
		p.play()


# ============================================================
# 离屏 SubViewport（半分辨率）：波纹通道
# 挂在 game_root 下，随 _clear_game_root() 自动销毁。
# 为什么波纹要走离屏视口而不是直接画在世界里：波纹要**被湿地层门控**（离开湿地
# 范围就不能显示成地上一圈白线），必须由湿地 shader 采样后按覆盖度合成。
# ============================================================

func _build_viewports(root: Node2D) -> void:
	var scale := float(Config.get_value("weather.viewports.scale", 0.5))
	var vp := get_viewport().get_visible_rect().size
	var sub := Vector2i(maxi(1, int(vp.x * scale)), maxi(1, int(vp.y * scale)))

	# 波纹视口：RippleRing 池挂在世界坐标内容根下，spawn 协议不变
	_ripple_vp = _make_sub_vp(sub, "RippleViewport")
	root.add_child(_ripple_vp)
	_ripple_root_world = Node2D.new()
	_ripple_root_world.name = "RippleLayer"
	_ripple_vp.add_child(_ripple_root_world)
	_ripple_cam = Camera2D.new()
	_ripple_cam.name = "RippleCam"
	_ripple_root_world.add_child(_ripple_cam)
	_ripple_cam.make_current()   # 只影响所属 SubViewport 的当前相机，不抢主视口

	print("[Weather] 波纹子视口建好 %dx%d（scale=%.2f）" % [sub.x, sub.y, scale])


func _make_sub_vp(size: Vector2i, vp_name: String) -> SubViewport:
	var v := SubViewport.new()
	v.name = vp_name
	v.size = size
	v.transparent_bg = true   # 透明底：缺省不污染成黑/灰
	v.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	v.gui_disable_input = true
	return v


## 每帧把主相机位姿同步到波纹子视口相机：
## zoom = 主相机 zoom × scale（半分辨率视口显示同一世界区域，SCREEN_UV 与贴图 UV
## 逐点对应），所以湿地 shader 直接按 SCREEN_UV 采样即与屏幕对齐。
func _sync_viewports() -> void:
	if _ripple_vp == null:
		return
	var cam := get_viewport().get_camera_2d()
	if cam == null or not is_instance_valid(cam):
		return
	var vp := get_viewport().get_visible_rect().size
	var scale := float(Config.get_value("weather.viewports.scale", 0.5))
	var sub_px := Vector2i(maxi(1, int(vp.x * scale)), maxi(1, int(vp.y * scale)))
	if _ripple_vp.size != sub_px:
		_ripple_vp.size = sub_px      # 窗口缩放自愈
	var z := maxf(cam.zoom.x, 0.05)
	var zs := z * scale
	_ripple_cam.global_position = cam.global_position
	_ripple_cam.zoom = Vector2(zs, zs)


# ============================================================
# 湿度场：群系地板 → 连续湿度 0..1 → _wet_field（shader 掩码）+ _wet_cells（逻辑判定）
#
# 旧版这里是"噪声水洼"：FastNoiseLite + 分位数阈值切出 floor_ratio 比例的孤立水格，
# 再叠 DECOR_WATER 浅滩、出生点无水圈。用户裁定水洼概念整体作废——下雨时草地/森林
# 的地面就是湿的，不需要"找到一洼水才踩得出波纹"。故噪声、阈值、浅滩、出生点圈
# 全部删除，湿度只由群系决定。
# ============================================================

func _build_wet_mask(map_data: Dictionary) -> void:
	var walls: Array = map_data["walls"]
	var biome: Array = map_data.get("biome", [])
	_map_w = (walls[0] as Array).size()
	_map_h = walls.size()

	# 湿地只允许出现在指定群系（默认草地0/森林2）的地板格上。
	# 注意 config 里 JSON 数字解析成 float，必须逐条 int 比较（Array.has(0) 恒 false）。
	var allowed_raw: Array = Config.get_value("weather.rain_ground.allowed_biomes", [0, 2])
	var field: Array = []
	for y in range(_map_h):
		var row: Array = []
		row.resize(_map_w)
		for x in range(_map_w):
			var v := 0.0
			if not bool(walls[y][x]) and not biome.is_empty():
				var bid := int(biome[y][x])
				for a in allowed_raw:
					if int(a) == bid:
						v = 1.0
						break
			row[x] = v
		field.append(row)

	# 多轮均值模糊（半径 boundary_blur 格，横纵各一趟）把整格 0/1 揉成多格宽的软
	# 过渡带：干湿边界由连续场给出，shader 再叠一层域扭曲就完全看不出格网。
	# 顺序很关键（旧水洼版踩过反例：先切阈值再平滑会把水成片吃掉）——这里先模糊
	# 再切逻辑阈值，切多少就是多少。
	var passes := maxi(0, int(Config.get_value("weather.rain_ground.boundary_passes", 3)))
	var radius := maxi(1, int(Config.get_value("weather.rain_ground.boundary_blur", 2)))
	for _i in range(passes):
		field = _blur_field(field, radius)

	# 水面剔出湿地（用户 2026-09-19："水面剔出去"）。上面那几轮模糊会把岸上草地的场值
	# 渗到水面格里，于是整片湖被压暗、再打上冷调水光，看着像水面浮了一层沫子。
	# 水面格＝不可通行格：TileMap 对 terrain=1 的格一律铺 water_bg，而 walls ⊇ terrain
	# （walls 还多包含树/石），所以按 walls 清零就把真水面全剔干净了。
	# 视觉场和逻辑判定必须同源切：只清一边就会出现"看着是干的、踩上去却出波纹"的错位。
	var excl_water := bool(Config.get_value("weather.rain_ground.exclude_water_cells", true))
	if excl_water:
		for y in range(_map_h):
			for x in range(_map_w):
				if bool(walls[y][x]):
					field[y][x] = 0.0
	_wet_field = field

	var thr := clampf(float(Config.get_value("weather.rain_ground.wet_threshold", 0.5)), 0.01, 0.99)
	_wet_cells = []
	_wet_count = 0
	for y in range(_map_h):
		var crow: Array = []
		crow.resize(_map_w)
		for x in range(_map_w):
			var w := float(field[y][x]) >= thr
			crow[x] = w
			if w:
				_wet_count += 1
		_wet_cells.append(crow)


## 一轮可分离均值模糊（横纵各一趟 box，半径 r 格）。越界按边重复（clampi），
## 地图外缘不会被拉出一圈假干带。box×3 ≈ 高斯，够用且比二项式核少一层算术。
func _blur_field(field: Array, r: int) -> Array:
	var w := 2 * r + 1
	var tmp: Array = []
	for y in range(_map_h):
		var row: Array = []
		row.resize(_map_w)
		for x in range(_map_w):
			var s := 0.0
			for i in range(w):
				s += float(field[y][clampi(x + i - r, 0, _map_w - 1)])
			row[x] = s / float(w)
		tmp.append(row)
	var out: Array = []
	for y in range(_map_h):
		var row: Array = []
		row.resize(_map_w)
		for x in range(_map_w):
			var s := 0.0
			for i in range(w):
				s += float(tmp[clampi(y + i - r, 0, _map_h - 1)][x])
			row[x] = s / float(w)
		out.append(row)
	return out


# ============================================================
# 湿地渲染：单个覆盖全图的 ColorRect + rain_ground.gdshader
# ============================================================

func _build_wet_layer(map_data: Dictionary) -> void:
	var map_root: Node2D = map_data.get("node")
	if map_root == null:
		return

	# 湿度场烘焙成掩码纹理。用 FORMAT_RF（32 位浮点单通道）而不是 R8：8 位单通道图
	# 到底按不按 sRGB 解码，各后端/版本说法不一，猜错等于把整条 0..1 软场悄悄重映射，
	# 于是"看着是湿地"的边界与 is_wet_at 的 0.5 阈值错开。浮点图恒为线性，写多少读多少。
	var img := Image.create(_map_w, _map_h, false, Image.FORMAT_RF)
	for y in range(_map_h):
		for x in range(_map_w):
			var v := clampf(float(_wet_field[y][x]), 0.0, 1.0)
			img.set_pixel(x, y, Color(v, 0.0, 0.0, 1.0))
	var mask_tex := ImageTexture.create_from_image(img)

	var rect := ColorRect.new()
	rect.name = "RainGroundLayer"
	rect.position = Vector2.ZERO
	rect.size = Vector2(float(_map_w * _tile_size), float(_map_h * _tile_size))
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 全屏 Control 必须忽略鼠标，否则吃掉局内点击/选中
	# 形状全来自 shader，宿主纹理只是 1×1 白点；ColorRect 的 visibility_rect 自动按 size 算，
	# 不像 Sprite2D 那样会被 1×1 纹理裁掉整层。
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	var mat := ShaderMaterial.new()
	mat.shader = WET_SHADER
	var scroll: Array = Config.get_value("weather.rain_ground.scroll_cells_per_s", [0.0, 0.0])
	mat.set_shader_parameter("wet_mask", mask_tex)
	mat.set_shader_parameter("mask_size", Vector2(_map_w, _map_h))
	mat.set_shader_parameter("darkness", float(Config.get_value("weather.rain_ground.darkness", 0.3)))
	mat.set_shader_parameter("tint_color",
			Color.from_string(str(Config.get_value("weather.rain_ground.tint_color", "#9dc0dc")), Color(0.62, 0.75, 0.86)))
	mat.set_shader_parameter("tint_amount", float(Config.get_value("weather.rain_ground.tint_amount", 0.3)))
	mat.set_shader_parameter("sheen", float(Config.get_value("weather.rain_ground.sheen", 0.05)))
	# 斑驳水光（用户："地面看不出湿"）：亮斑/暗斑成对，数值全在 config.mottle_* 里。
	var mstr: Array = Config.get_value("weather.rain_ground.mottle_stretch", [0.8, 1.4])
	var mspd: Array = Config.get_value("weather.rain_ground.mottle_speed", [0.0, 0.0])
	mat.set_shader_parameter("mottle_amount", float(Config.get_value("weather.rain_ground.mottle_amount", 1.0)))
	mat.set_shader_parameter("mottle_scale", float(Config.get_value("weather.rain_ground.mottle_scale", 2.2)))
	mat.set_shader_parameter("mottle_stretch", Vector2(float(mstr[0]), float(mstr[1])))
	mat.set_shader_parameter("mottle_speed", Vector2(float(mspd[0]), float(mspd[1])))
	mat.set_shader_parameter("mottle_threshold", float(Config.get_value("weather.rain_ground.mottle_threshold", 0.74)))
	mat.set_shader_parameter("mottle_soft", float(Config.get_value("weather.rain_ground.mottle_soft", 0.06)))
	mat.set_shader_parameter("mottle_gain", float(Config.get_value("weather.rain_ground.mottle_gain", 0.35)))
	mat.set_shader_parameter("mottle_dark", float(Config.get_value("weather.rain_ground.mottle_dark", 0.12)))
	mat.set_shader_parameter("mottle_color",
			Color.from_string(str(Config.get_value("weather.rain_ground.mottle_color", "#7fa8cc")),
					Color(0.498, 0.659, 0.80)))
	mat.set_shader_parameter("wet_alpha", float(Config.get_value("weather.rain_ground.alpha", 0.9)))
	mat.set_shader_parameter("noise_scale", float(Config.get_value("weather.rain_ground.noise_scale", 0.06)))
	mat.set_shader_parameter("scroll_dir", Vector2(float(scroll[0]), float(scroll[1])))
	mat.set_shader_parameter("edge_soft", float(Config.get_value("weather.rain_ground.edge_soft", 0.45)))
	mat.set_shader_parameter("edge_warp", float(Config.get_value("weather.rain_ground.edge_warp", 0.9)))
	mat.set_shader_parameter("edge_warp_scale", float(Config.get_value("weather.rain_ground.edge_warp_scale", 0.16)))
	mat.set_shader_parameter("ripple_tex",
			_ripple_vp.get_texture() if _ripple_vp != null else _placeholder_tex)
	mat.set_shader_parameter("ripple_glow", float(Config.get_value("weather.ripple.glow", 0.35)))
	mat.set_shader_parameter("ripple_tint",
			Color.from_string(str(Config.get_value("weather.ripple.color", "#bfe3ff")), Color(0.75, 0.89, 1.0)))
	mat.set_shader_parameter("ripple_wiggle", float(Config.get_value("weather.rain_ground.ripple_wiggle", 0.003)))
	rect.material = mat

	map_root.add_child(rect)
	# 插到地形层之后、DecorLayer 之前：湿地贴在草地上（不淹树），并受 MacroLight 统一压暗。
	map_root.move_child(rect, 1)
	_wet_layer = rect


# ============================================================
# 雨：RainAnchor 跟相机 + 三层景深发射器（远/中/近）+ 地面飞溅 + 屏幕雨幕
# 全部 local_coords=false：anchor 平移只影响新发射的雨滴，已有雨滴留在原地
# ============================================================

func _build_rain(root: Node2D) -> void:
	_margin = float(Config.get_value("weather.rain.emission_margin_px", 160.0))
	_wind_x = float(Config.get_value("weather.rain.wind_x_px", -320.0))
	var gust: Dictionary = Config.get_value("weather.rain.gust", {})
	_gust_amp = clampf(float(gust.get("amplitude", 0.5)), 0.0, 1.5)
	_gust_period = maxf(float(gust.get("period_s", 7.0)), 0.5)

	_rain_anchor = Node2D.new()
	_rain_anchor.name = "RainAnchor"
	_rain_anchor.z_index = int(Config.get_value("weather.rain.anchor_z", 6))
	root.add_child(_rain_anchor)

	var tex := _make_streak_tex()
	var add_mat: CanvasItemMaterial = null
	if bool(Config.get_value("weather.rain.blend_add", true)):
		# 参考片段里的 material.BlendMode 是 Godot 3 的 ParticlesMaterial；
		# 4.x 的 ParticleProcessMaterial 没有 blend_mode，2D 粒子叠加要挂在节点的
		# CanvasItemMaterial 上（否则雨丝是普通 alpha 混合，密处不成亮带）。
		add_mat = CanvasItemMaterial.new()
		add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	for L in Config.get_value("weather.rain.layers", []):
		if not (L is Dictionary):
			continue
		var d: Dictionary = L
		var g := GPUParticles2D.new()
		g.name = str(d.get("name", "RainLayer"))
		g.texture = tex
		g.local_coords = false
		var life := float(d.get("lifetime_s", 0.7))
		g.lifetime = life
		g.preprocess = life            # 参考步骤 2：preprocess == lifetime → 开局即铺满
		g.amount = int(d.get("amount", 200))
		g.z_index = int(d.get("z", 0))
		var m := _make_rain_mat(d)
		g.process_material = m
		if add_mat != null:
			g.material = add_mat
		g.emitting = true
		_rain_anchor.add_child(g)
		_rain_layers.append({"node": g, "mat": m,
				"wind_factor": float(d.get("wind_factor", 1.0)),
				"phase": float(d.get("gust_phase", 0.0)),
				"extents_k": float(d.get("extents_k", 1.0))})

	# 落地飞溅（独立发射器，非 sub-emitter）
	var sp: Dictionary = Config.get_value("weather.rain.splash", {})
	_splash = GPUParticles2D.new()
	_splash.name = "RainSplash"
	_splash.texture = _make_dot_tex()
	_splash.local_coords = false
	_splash.lifetime = float(sp.get("lifetime_s", 0.35))
	_splash.preprocess = float(sp.get("lifetime_s", 0.35))
	_splash.amount = int(Config.get_value("weather.rain.splash_amount", 140))
	_splash.process_material = _make_splash_mat(sp)
	if add_mat != null:
		_splash.material = add_mat
	_splash.z_index = int(Config.get_value("weather.rain.splash_z", 3))
	_splash.emitting = true
	_rain_anchor.add_child(_splash)

	_build_rain_overlay(root)


## 单层雨丝材质。参考 DEV LOG.02 步骤 1/3：下落用 +y 初速度，风偏用 gravity.x
## （所以雨是**越下越斜**的加速偏移，不是固定倾角；配合下面的阵风包络会周期摆动）。
func _make_rain_mat(d: Dictionary) -> ParticleProcessMaterial:
	# Godot 4 已统一粒子材质：GPUParticles2D 用的就是 ParticleProcessMaterial（无 2D 专版）。
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = Vector3(800, 600, 0)   # _process 每帧按 zoom 重算
	m.direction = Vector3(0, 1, 0)
	m.spread = float(d.get("spread_deg", 6.0))
	var spd: Array = d.get("speed_px", [1050.0, 1350.0])
	m.initial_velocity_min = float(spd[0])
	m.initial_velocity_max = float(spd[1])
	m.gravity = Vector3.ZERO                        # _process 每帧按阵风写入
	var sc: Array = d.get("scale", [1.0, 1.0])
	# 4.3 起 scale_amount_min/max 改名 scale_min/max（仍是 float，赋 Vector3 直接编译失败）。
	m.scale_min = float(sc[0])
	m.scale_max = float(sc[1])
	# lifetime 在 GPUParticles2D 节点上设（material 只有 lifetime_randomness）
	m.lifetime_randomness = 0.3
	var st: Dictionary = Config.get_value("weather.rain.streak", {})
	var rc := Color.from_string(str(st.get("color", "#a8c4e0")), Color(0.66, 0.77, 0.88))
	rc.a = float(d.get("alpha", st.get("alpha", 0.55)))
	m.color = rc
	return m


## 屏幕雨幕（参考步骤 6）：全屏 ColorRect + 压暗 + 朝雨幕蓝灰 mix。
## 挂在独立 CanvasLayer（默认 1，与 HUD 同层但在其之前）→ 不跟随相机缩放，也不被
## 湿地层的 SCREEN_TEXTURE 采样到（它画在湿地之后）。
func _build_rain_overlay(root: Node2D) -> void:
	var ov: Dictionary = Config.get_value("weather.rain.overlay", {})
	if not bool(ov.get("enabled", true)):
		return
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "RainOverlayLayer"
	_overlay_layer.layer = int(ov.get("layer", 1))
	root.add_child(_overlay_layer)

	_overlay = ColorRect.new()
	_overlay.name = "RainCurtain"
	# 全屏锚定：窗口缩放自动跟随，不需要每帧量视口尺寸。
	_overlay.anchor_right = 1.0
	_overlay.anchor_bottom = 1.0
	# Control 默认吃鼠标；雨幕在 HUD 之下仍会挡住世界点击，必须显式忽略。
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = RAIN_OVERLAY_SHADER
	var c := Color.from_string(str(ov.get("color", "#8fb0cc")), Color(0.56, 0.69, 0.80))
	c.a = 1.0
	mat.set_shader_parameter("tint", c)
	mat.set_shader_parameter("opacity", float(ov.get("opacity", 0.15)))
	mat.set_shader_parameter("darken", float(ov.get("darken", 0.9)))
	mat.set_shader_parameter("vertical_bias", float(ov.get("vertical_bias", 0.35)))
	_overlay.material = mat
	_overlay.modulate.a = 0.0
	_overlay_layer.add_child(_overlay)


## 进局淡入（参考"天气切换用 Tween 平滑过渡"）：雨滴与雨幕并行从透明爬到满。
## _fade_tween 必须在 deactivate() 里 kill：WeatherSystem 是 Main 场景常驻节点，
## 切回基地后 Tween 仍在跑，而 RainAnchor/雨幕已随 _clear_game_root 释放。
func _fade_in_rain() -> void:
	var dur := float(Config.get_value("weather.rain.fade_in_s", 1.2))
	if dur <= 0.0:
		return
	var targets: Array = []
	if _rain_anchor != null:
		_rain_anchor.modulate.a = 0.0
		targets.append(_rain_anchor)
	if _overlay != null:
		_overlay.modulate.a = 0.0
		targets.append(_overlay)
	if targets.is_empty():
		return
	_fade_tween = create_tween()
	_fade_tween.set_parallel(true)
	for t in targets:
		var tw := _fade_tween.tween_property(t, "modulate:a", 1.0, dur)
		tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


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


func _process(delta: float) -> void:
	if not _active or _rain_anchor == null or not is_instance_valid(_rain_anchor):
		return
	var cam := get_viewport().get_camera_2d()
	if cam == null or not is_instance_valid(cam):
		return
	# anchor 对齐相机中心；local_coords=false 使已存在粒子留在原地，只有新发射的跟着走。
	_rain_anchor.global_position = cam.global_position
	_elapsed += delta
	var vp := get_viewport().get_visible_rect().size
	var z := maxf(cam.zoom.x, 0.05)
	var half := vp / z * 0.5 + Vector2(_margin, _margin)
	# 发射框只覆盖视口+margin（不再额外加下落行程）：preprocess=lifetime 已让首帧
	# 铺满整框，再加行程只会把同量粒子摊到更大体积里 → 雨看着稀稀拉拉（截图实测）。
	for rec in _rain_layers:
		var m: ParticleProcessMaterial = rec["mat"]
		var k := float(rec["extents_k"])
		m.emission_box_extents = Vector3(half.x * k, half.y * k, 0)
		# 风偏 = gravity.x：同一阵风包络按各层 wind_factor/phase 错开，近处摆得多、远处摆得少
		var gust := 1.0 + _gust_amp * sin((_elapsed / _gust_period + float(rec["phase"])) * TAU)
		m.gravity = Vector3(_wind_x * float(rec["wind_factor"]) * gust, 0.0, 0.0)
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


## 波纹颜色 = 通道编码（湿地 shader 拆通道用）：
## r=亮度基（提亮湿面），g/b=晃动量（波纹处让反光额外抖动）。单圈一次绘制即完成拆分。
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
	return _pack_wav(buf, rate, true)   # 雨底 = 背景循环（接缝已交叉淡化）


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


## loop=true 只给背景音（雨底这类首尾交叉淡化过的采样）。脚步/踩水是一次性采样，
## 循环会在 0.18s 后从头再来 —— 听着就是"音效一直在"（用户 2026-09-19 报）。
static func _pack_wav(buf: PackedFloat32Array, rate: int, loop: bool = false) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.stereo = false
	w.mix_rate = rate
	var bytes := PackedByteArray()
	bytes.resize(buf.size() * 2)
	for i in range(buf.size()):
		bytes.encode_s16(i * 2, int(clampf(buf[i], -1.0, 1.0) * 32767.0))
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = buf.size()
	return w

extends Node
## ============================================================
## probe_water_step — 踩水效果「会不会被触发 + 波纹长不长出来」（headless，纯数据）
##
## 背景：用户裁定的方案 3 把"水洼"概念删掉了——下雨时草地/森林地面整片是湿的，
## 踩哪都出波纹。中途加过的"湿脚印累积"同日即被否掉（"太丑了"），通路已删，
## 所以本探针只测：湿地覆盖对不对、边界判定准不准、波纹有没有真的占池。
##
## 六段断言：
##   A) 雨湿地面覆盖：湿格只落在 allowed_biomes 上（模糊漫出去的窄条另计），且占这些格的绝大多数
##   B) 开局可见：出生点就在湿地里（或很近），玩家第一步就该看到湿地质感
##   C) 触发判定：单格硬判定 vs 邻域判定（step_wet_radius_cells）命中率 + 边界/越界用例
##   D) 踩水事件：on_wet_step 占用一条波纹、落在脚步坐标、半径寿命来自 config，
##      并按 config 掷出碎片弧段；on_dry_step 什么都不产
##   E) 雨湿地面层装配：全图 ColorRect + rain_ground shader，插在 MapRoot 地形之后、装饰之前
##   F) 雨本身：DEV LOG.02 的三层雨 + 屏幕雨幕确实装配出来了（RainFar/RainMid/RainNear、
##      preprocess==lifetime、世界空间、叠加混合、雨幕不吃鼠标）
## ============================================================

const OUT := "user://_probe_water_step.txt"
const WEATHER := preload("res://Scripts/weather_system.gd")
const MAP_SEED := 7

var _lines: Array = []
var _n := 0
var _fails: Array = []


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _ready() -> void:
	await get_tree().process_frame
	seed(MAP_SEED)
	var map_data: Dictionary = MapGenerator.generate()

	var w := Node.new()
	w.name = "WeatherProbeHost"
	w.set_script(WEATHER)
	add_child(w)
	if not w.has_method("setup"):
		# weather_system.gd 编译失败时 setup 不存在：必须在这里收尾 quit，
		# 否则 _ready 直接报错退出、进程永远不结束，跑探针的外层只能等超时。
		_check(false, "weather_system.gd 编译通过（setup 方法缺失）")
		_report()
		return
	var root := Node2D.new()
	add_child(root)
	w.setup(root, map_data)

	var walls: Array = map_data["walls"]
	var biome: Array = map_data.get("biome", [])
	var spawn: Vector2i = map_data.get("spawn_cell", Vector2i(64, 128))
	var mw: int = w._map_w
	var mh: int = w._map_h
	var ts := float(w._tile_size)
	_say("地图 %dx%d  出生格=(%d,%d)" % [mw, mh, spawn.x, spawn.y])

	# ---------- A) 雨湿地面覆盖 ----------
	# config 里 JSON 数字解析成 float，Array.has(0) 会判 false → 必须先归一成 int 再比
	var allowed: Array = []
	for a in Config.get_value("weather.rain_ground.allowed_biomes", [0, 2]):
		allowed.append(int(a))
	var eligible := 0
	var wet := 0
	var bad_biome := 0
	for y in range(mh):
		for x in range(mw):
			var is_wet: bool = bool(w._wet_cells[y][x])
			if is_wet:
				wet += 1
				if not allowed.has(int(biome[y][x])):
					bad_biome += 1
			if not bool(walls[y][x]) and allowed.has(int(biome[y][x])):
				eligible += 1
	_say("可选格(草地+森林地板)=%d  湿格=%d  覆盖率 %.1f%%" % [
		eligible, wet, 100.0 * wet / maxf(1.0, float(eligible))])
	_check(wet > 0, "地图上确实有湿地")
	# 边界模糊会把湿度漫过 allowed_biomes，夹在草地中间的窄荒原条也会算湿。这是故意的：
	# 那片地面在 shader 里同样被画成湿地，若逻辑上判干，玩家踩上去没反应＝"看着能踩不能踩"。
	# 所以只要求漏出去的这一小圈不占大头。
	_say("非 allowed_biomes 的湿格（模糊漫过去的窄条）= %d，占湿格 %.1f%%" % [
		bad_biome, 100.0 * bad_biome / maxf(1.0, float(wet))])
	_check(float(bad_biome) <= float(wet) * 0.05,
			"漫出 allowed_biomes=%s 的湿格 ≤ 湿格总数的 5%%（实测 %d / %d）" % [
			str(allowed), bad_biome, wet])
	# 覆盖率不该太低：模糊只吃掉边界一圈，内部仍是满湿
	_check(float(wet) >= float(eligible) * 0.7, "湿地覆盖 ≥ 可选格的 70%%（实测 %.1f%%）" % (
		100.0 * wet / maxf(1.0, float(eligible))))

	# ---------- A1b) 水面不沾湿（用户 2026-09-19："水面剔出去"）----------
	# 不可通行格在本项目铺的就是 water_bg 水面贴图。边界模糊会把岸上草地的湿度渗到
	# 水面格里，shader 于是把整片湖压暗 + 打上冷调水光＝"水面浮了一层沫子"。
	# 视觉场和逻辑判定都要查：只清一边就会出现"看着干/踩上去出波纹"的错位。
	var water_cells := 0
	var leak_field := 0
	var leak_cells := 0
	for y in range(mh):
		for x in range(mw):
			if bool(walls[y][x]):
				water_cells += 1
				if float(w._wet_field[y][x]) > 0.0:
					leak_field += 1
				if bool(w._wet_cells[y][x]):
					leak_cells += 1
	_say("水面格=%d  场值非零=%d  逻辑判湿=%d" % [water_cells, leak_field, leak_cells])
	_check(water_cells > 0, "地图上有水面格可测")
	_check(leak_field == 0, "水面格的湿度场一颗都不带（实测漏 %d）" % leak_field)
	_check(leak_cells == 0, "水面格的逻辑判定全干（实测漏 %d）" % leak_cells)

	# ---------- A2) 湿度场是连续的 ----------
	# 掩码一纹理对应一格：_wet_field 若只剩 0/1，shader 侧无论怎么插值都揉不出过渡带，
	# 干湿边界必然露出 64px 格网台阶（看起来就是一块块方形水洼，正是本方案要消掉的东西）。
	var graded := 0
	var fmin := 1.0
	var fmax := 0.0
	for y in range(mh):
		for x in range(mw):
			var fv := float(w._wet_field[y][x])
			if fv > 0.02 and fv < 0.98:
				graded += 1
			fmin = minf(fmin, fv)
			fmax = maxf(fmax, fv)
	_say("湿度场：过渡格(0.02<v<0.98)=%d  值域 %.2f..%.2f" % [graded, fmin, fmax])
	_check(graded > 0, "边界模糊真的产出了连续过渡格")
	_check(float(graded) >= float(wet) * 0.02,
			"过渡格成规模（实测 %d 个 / 湿格 %d 个）" % [graded, wet])

	# ---------- B) 出生点就踩在湿地边上 ----------
	var dist := _bfs_to_wet(w, walls, spawn)
	_say("出生格 → 最近湿格 BFS 距离 = %s 步" % str(dist))
	_check(dist >= 0, "从出生点能找到湿地（找不到 = 玩家开局永远看不到踩水效果）")
	_check(dist <= 20, "湿地在出生点 20 步以内（草地/森林连片，本就该贴着出生点）")

	# ---------- C) 触发判定：单格 vs 邻域 ----------
	var r := int(Config.get_value("weather.rain_ground.step_wet_radius_cells", 1))
	var hit_exact := 0
	var hit_near := 0
	var floor_cells := 0
	for y in range(2, mh - 2):
		for x in range(2, mw - 2):
			if bool(walls[y][x]):
				continue
			floor_cells += 1
			if bool(w._wet_cells[y][x]):
				hit_exact += 1
			if _near_wet(w, x, y, r):
				hit_near += 1
	_say("地板格=%d  单格命中=%d(%.1f%%)  邻域r=%d命中=%d(%.1f%%)" % [
		floor_cells, hit_exact, 100.0 * hit_exact / maxf(1.0, float(floor_cells)),
		r, hit_near, 100.0 * hit_near / maxf(1.0, float(floor_cells))])
	_check(hit_near >= hit_exact,
			"邻域判定命中率不低于单格硬判定（r=%d：%d vs %d）" % [r, hit_near, hit_exact])

	var wet_cell := _find_wet_cell(w, mw, mh)
	_check(wet_cell.x >= 0, "找到一个湿格用于定点判定 (%d,%d)" % [wet_cell.x, wet_cell.y])
	if wet_cell.x >= 0:
		var center := Vector2((wet_cell.x + 0.5) * ts, (wet_cell.y + 0.5) * ts)
		_check(w.is_wet_at(center), "湿格中心 is_wet_at 为真")
	var far := _find_dry_cell(w, walls, r + 2)
	if far.x >= 0:
		_check(not w.is_wet_at(Vector2((far.x + 0.5) * ts, (far.y + 0.5) * ts)),
				"离湿地 (r+%d) 格以上的干地不误判 (%d,%d)" % [2, far.x, far.y])
	else:
		_say("（全图找不到离湿地 r+2 格以上的干地 → 干地误判用例跳过）")
	_check(not w.is_wet_at(Vector2(-9999.0, -9999.0)), "越界坐标安全返回 false")

	# ---------- D) 踩水事件：碎片椭圆波纹 ----------
	var pool := int(Config.get_value("weather.ripple.pool_size", 16))
	_check(w._ripples.size() == pool, "波纹池建好 %d 条" % pool)
	if wet_cell.x >= 0:
		var p := Vector2((wet_cell.x + 0.5) * ts, (wet_cell.y + 0.5) * ts)
		for x in w._ripples:
			x._retire()
		w.on_wet_step(p)
		var live: Array = []
		for x in w._ripples:
			if not x.is_free():
				live.append(x)
		_check(live.size() == 1, "一次踩水占用一条波纹（实际占用 %d）" % live.size())
		var a0s: Array = []
		if live.size() == 1:
			var rip: Node2D = live[0]
			_check(absf(rip.global_position.x - p.x) < 0.01 and absf(rip.global_position.y - p.y) < 0.01,
					"波纹生成在脚步坐标上")
			_check(absf(rip.radius - float(Config.get_value("weather.ripple.radius_px", 62.0))) < 0.01,
					"展开半径来自 config（%.1f px）" % rip.radius)
			_check(absf(rip.duration - float(Config.get_value("weather.ripple.duration_s", 0.6))) < 0.01,
					"寿命来自 config（%.2f s）" % rip.duration)
			_check(rip.visible, "波纹可见（不可见＝踩水等于没做）")
			# 形状：贴地椭圆 + 只显示部分图案（碎片弧）——两条都是用户明确裁定的
			var sq := float(Config.get_value("weather.ripple.ellipse_squash", 0.45))
			_check(sq > 0.0 and sq < 1.0, "椭圆压扁系数在 (0,1)（实测 %.2f）" % sq)
			var want_n := maxi(2, int(Config.get_value("weather.ripple.fragments", 5)))
			_check(rip.frags.size() == want_n, "每次踩水掷出 %d 段碎片弧（实际 %d）" % [want_n, rip.frags.size()])
			var total_span := 0.0
			var rmuls := {}
			for f in rip.frags:
				var span := float(f["span"])
				total_span += span
				a0s.append(float(f["a0"]))
				rmuls[float(f["rmul"])] = true
				_check(span > 0.0 and span < TAU, "单段是部分弧不是整圈（%.1f°）" % rad_to_deg(span))
				_check(float(f["alpha"]) > 0.0, "碎片亮度非零")
			_check(total_span < TAU,
					"碎片合计只占 %.0f°＜360°（必然留缺口）" % rad_to_deg(total_span))
			_check(rmuls.size() >= 2,
					"各碎片半径倍率不同（%d 种）→ 不共圆，读不成白色虚线靶子" % rmuls.size())
			var sorted := a0s.duplicate()
			sorted.sort()
			var min_gap := TAU
			for i in range(sorted.size()):
				var g: float = float(sorted[(i + 1) % sorted.size()]) - float(sorted[i])
				if i == sorted.size() - 1:
					g += TAU
				min_gap = minf(min_gap, g)
			_check(min_gap > 0.01, "各碎片角度彼此分开（最近间隔 %.1f°）" % rad_to_deg(min_gap))
			# 图案每次都重掷：固定模板会让连续几步看起来是同一个贴纸
			var again: Array = []
			for f in rip.call("_roll_frags"):
				again.append(float(f["a0"]))
			_check(str(again) != str(a0s), "重掷一次碎片角度就变了（每次踩水图案不同）")
		# 干地脚步：什么都不该产（先把上一湿的东西清干净，否则测的是残留）
		for x in w._ripples:
			x._retire()
		w.on_dry_step(p)
		_check(_busy_ripples(w) == 0, "干地脚步不出波纹")
		# 连续两脚：池化复用下各占一条
		w.on_wet_step(p)
		w.on_wet_step(p + Vector2(40, 0))
		_check(_busy_ripples(w) == 2, "连续两脚出两条波纹（实际 %d）" % _busy_ripples(w))
		for x in w._ripples:
			x._retire()
		_check(_busy_ripples(w) == 0 and w._ripples.size() == pool,
				"波纹播完全部回池、池子不扩容（节点数不增长）")
	else:
		_say("（找不到内部湿格 → 踩水事件用例跳过）")

	# ---------- E) 雨湿地面层装配 ----------
	_check(w._wet_layer != null and w._wet_layer is ColorRect, "雨湿地面层 = 覆盖全图的 ColorRect")
	if w._wet_layer != null:
		var rect: ColorRect = w._wet_layer
		_check(rect.mouse_filter == Control.MOUSE_FILTER_IGNORE, "雨湿地面层不吃鼠标（否则局内点不动）")
		_check(absf(rect.size.x - float(mw * int(ts))) < 1.0 and absf(rect.size.y - float(mh * int(ts))) < 1.0,
				"雨湿地面层尺寸 == 地图格数 × tile（%s）" % str(rect.size))
		_check(rect.material is ShaderMaterial
				and (rect.material as ShaderMaterial).shader.resource_path
						== "res://Shaders/rain_ground.gdshader",
				"雨湿地面层挂 rain_ground.gdshader")
		# 斑驳水光（用户："地面看不出湿"）：值要真的从 config 灌进 shader，
		# 且**亮斑与暗斑必须成对**——只有 gain 没有 dark 会读成一块块油渍。
		if rect.material is ShaderMaterial:
			var sm: ShaderMaterial = rect.material
			var g := float(sm.get_shader_parameter("mottle_gain"))
			var d := float(sm.get_shader_parameter("mottle_dark"))
			var st: Vector2 = sm.get_shader_parameter("mottle_stretch")
			_check(float(sm.get_shader_parameter("mottle_amount")) > 0.0, "斑驳水光开着")
			_check(g > 0.0 and d > 0.0, "亮斑 %.2f / 暗斑 %.2f 成对（缺一边就读成油渍）" % [g, d])
			_check(absf(g - float(Config.get_value("weather.rain_ground.mottle_gain", 0.0))) < 0.001,
					"亮斑增益来自 config（%.2f）" % g)
			_check(st.x > 0.0 and st.y > st.x,
					"各向异性方向没写反：x 低频 y 高频 → 横向条带（%s）" % str(st))
			# 明暗与亮斑必须**钉在格子上**：这两个流速非零就是"一层水膜从草地上飘过去"
			# （用户 2026-09-19："水的那个图层会飘"）。会动的只该有踩水波纹。
			var sd: Vector2 = sm.get_shader_parameter("scroll_dir")
			var ms: Vector2 = sm.get_shader_parameter("mottle_speed")
			_check(sd == Vector2.ZERO and ms == Vector2.ZERO,
					"湿地明暗与水光都不滚动（scroll_dir=%s mottle_speed=%s）" % [str(sd), str(ms)])
			var thr := float(sm.get_shader_parameter("mottle_threshold"))
			var soft := float(sm.get_shader_parameter("mottle_soft"))
			_check(thr > soft and thr < 1.0,
					"阈值 %.2f 两侧留得下过渡带 %.2f（否则亮斑恒满或恒空）" % [thr, soft])
		var mr: Node2D = map_data.get("node")
		if mr != null:
			_check(rect.get_index() == 1, "雨湿地面层排在 MapRoot 子序 1（地形之后、装饰之前）")
	_check(w._ripple_vp != null, "波纹子视口已建")

	# ---------- F) 三层雨 + 雨幕装配（DEV LOG.02） ----------
	var layers_cfg: Array = Config.get_value("weather.rain.layers", [])
	_check(w._rain_layers.size() == layers_cfg.size(),
			"雨滴层数 == config.weather.rain.layers 条数（%d）" % layers_cfg.size())
	var got_names: Array = []
	var total_amount := 0
	for rec in w._rain_layers:
		var g: GPUParticles2D = rec["node"]
		got_names.append(str(g.name))
		total_amount += g.amount
		_check(absf(g.preprocess - g.lifetime) < 0.001, "%s：preprocess == lifetime（参考步骤 2）" % g.name)
		_check(not g.local_coords, "%s：世界空间模拟，镜头平移不拖雨滴" % g.name)
		_check(g.material is CanvasItemMaterial, "%s：叠加混合材质已挂上" % g.name)
	_check(str(got_names) == str(["RainFar", "RainMid", "RainNear"]),
			"节点结构 = RainFar/RainMid/RainNear（实得 %s）" % str(got_names))
	_check(total_amount >= 400 and total_amount <= 900,
			"同屏总滴数 %d 在参考区间 400-800 附近" % total_amount)
	_check(w._overlay != null and (w._overlay as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"屏幕雨幕已建且不吃鼠标")
	_report()


func _busy_ripples(w: Node) -> int:
	var n := 0
	for r in w._ripples:
		if r != null and is_instance_valid(r) and not r.is_free():
			n += 1
	return n


## 从出生格在可行走地板上 BFS，返回到最近湿格的步数；找不到返回 -1。
func _bfs_to_wet(w: Node, walls: Array, from: Vector2i) -> int:
	var mw := int(w._map_w)
	var mh := int(w._map_h)
	var seen := {}
	var q: Array = [from]
	seen[from] = 0
	var head := 0
	while head < q.size():
		var c: Vector2i = q[head]
		head += 1
		var d: int = seen[c]
		if bool(w._wet_cells[c.y][c.x]):
			return d
		for dd in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + dd
			if n.x < 0 or n.y < 0 or n.x >= mw or n.y >= mh:
				continue
			if seen.has(n) or bool(walls[n.y][n.x]):
				continue
			seen[n] = d + 1
			q.append(n)
	return -1


func _near_wet(w: Node, cx: int, cy: int, r: int) -> bool:
	var mw := int(w._map_w)
	var mh := int(w._map_h)
	for y in range(maxi(0, cy - r), mini(mh, cy + r + 1)):
		for x in range(maxi(0, cx - r), mini(mw, cx + r + 1)):
			if bool(w._wet_cells[y][x]):
				return true
	return false


## 找一个湿地**内部**格（连续场 ≥0.9）用于定点用例：边缘格场值还在过渡带上，
## 拿它测定点判定会时灵时不灵。
func _find_wet_cell(w: Node, mw: int, mh: int) -> Vector2i:
	for y in range(2, mh - 2):
		for x in range(2, mw - 2):
			if bool(w._wet_cells[y][x]) and float(w._wet_field[y][x]) >= 0.9:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


## 找一个四周 r 格内都没有湿地的地板格（找不到返回 -1，用例自行跳过）。
func _find_dry_cell(w: Node, walls: Array, r: int) -> Vector2i:
	var mw := int(w._map_w)
	var mh := int(w._map_h)
	for y in range(r + 1, mh - r - 1, 3):
		for x in range(r + 1, mw - r - 1, 3):
			if bool(walls[y][x]):
				continue
			if not _near_wet(w, x, y, r):
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _report() -> void:
	_say("")
	_say("通过 %d / %d" % [_n - _fails.size(), _n])
	for f in _fails:
		_say("  !! " + f)
	var text := "\n".join(_lines)
	var fa := FileAccess.open(OUT, FileAccess.WRITE)
	if fa != null:
		fa.store_string(text)
		fa.close()
	for s in _lines:
		if s.contains("OK  ") or s.contains("FAIL") or s.contains("通过"):
			print("[WaterProbe] " + s)
	print("[WaterProbe] fails=%d -> %s" % [_fails.size(), "PASS" if _fails.is_empty() else "FAIL"])
	get_tree().quit(0 if _fails.is_empty() else 1)

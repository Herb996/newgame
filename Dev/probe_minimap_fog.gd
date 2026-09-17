extends Node
## ============================================================
## probe_minimap_fog — 小地图同步战争迷雾（headless 可跑）
##
## 验六件事：
##   A) 遮罩是 RGBA8 且两通道互为补：.r = 已探索、.a = 未探索
##      （一张图两个消费者：主地图着色器读 .r 做羽化，小地图读 .a 当黑遮罩）
##   B) 遮罩像素与 _explored 字典**逐格一致**（全图扫描）—— 保证「一个真相源」
##      没有漂移，也就是小地图不会出现「主图亮了、小地图还是黑的」这种鬼影
##   C) 揭一格 → 该格像素那一帧就变透明（小地图侧没有额外同步代码，靠的是同一张图）
##   D) 纹理生命周期：局内非 null；回基地 / deactivate 后为 null；--no-fog(disable) 后为 null
##   E) 小地图拿到的是**同一张**纹理（同一 instance id，不是拷贝），
##      且与地形底图同尺寸（尺寸不一致 = 缩放错位，逐格对齐就没了）
##   F) 绘制层顺序：雾必须夹在 extraction 与 squad 之间。顺序写错不会报错、
##      只会让未探索处的撤离点照样亮着 —— 这种错只能靠断言钉住
##
## 为什么 headless 能跑：全是数据断言（Image 像素 + 常量数组），不依赖渲染管线。
## 「真的画上去了」由 E（同源同尺寸）+ F（顺序）共同保证，不需要读回像素。
## ============================================================

const OUT := "user://_probe_minimap_fog.txt"

## 期望的绘制层顺序（与小地图的 RENDER_LAYERS 逐项比对）
const EXPECT_LAYERS := ["terrain", "extraction", "fog", "squad"]

var _lines: Array = []
var _n := 0
var _fails: Array = []

var _main: Node = null
var _fog: Node = null
var _mm: Node = null

var _save_backup := ""
var _save_existed := false


func _say(s: String) -> void:
	_lines.append(s)


func _check(ok: bool, msg: String) -> void:
	_n += 1
	_lines.append("  %s %s" % ["OK  " if ok else "FAIL", msg])
	if not ok:
		_fails.append(msg)


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


## 未探索 = (0,0,0,1)；已探索 = (1,1,1,0)。用阈值判而不是精确比，免得踩浮点。
func _is_dark(c: Color) -> bool:
	return c.a > 0.5 and c.r < 0.5


func _is_clear(c: Color) -> bool:
	return c.a < 0.5 and c.r > 0.5


func _script_const(obj: Object, key: String, fallback):
	if obj == null:
		return fallback
	var scr: GDScript = obj.get_script()
	if scr == null:
		return fallback
	var m: Dictionary = scr.get_script_constant_map()
	return m.get(key, fallback)


func _ready() -> void:
	_backup_save()
	_main = load("res://Scenes/Main.tscn").instantiate()
	add_child(_main)
	await _frames(30)
	_main.call("_on_launch", [{"id": "swordsman", "name": "剑士"}])
	await _frames(40)

	_fog = _main.get("fog_system")
	var mms := get_tree().get_nodes_in_group("minimap")
	_mm = mms[0] if not mms.is_empty() else null

	_check(_fog != null and _mm != null, "拿到 FogSystem 与小地图（%s / %s）"
			% [str(_fog != null), str(_mm != null)])
	if _fog == null or _mm == null:
		_finish()
		return

	var mask: Image = _fog.get("_mask")
	var map_w := int(_fog.get("map_w"))
	var map_h := int(_fog.get("map_h"))

	# ------------------------------------------------------------
	_say("--- A 段：遮罩格式与双通道语义 ---")
	_check(mask != null, "取到探索遮罩 Image")
	if mask == null:
		_finish()
		return
	_check(mask.get_format() == Image.FORMAT_RGBA8,
			"遮罩格式 = RGBA8（实得 %d）" % mask.get_format())
	_check(mask.get_width() == map_w and mask.get_height() == map_h,
			"遮罩尺寸 = 地图格数 %d×%d（实得 %d×%d）"
			% [map_w, map_h, mask.get_width(), mask.get_height()])
	_check(int(_fog.call("explored_cells")) > 0,
			"出生点周围已揭开 %d 格" % int(_fog.call("explored_cells")))

	# 出生点那格必然已探索
	var players := get_tree().get_nodes_in_group("player")
	_check(not players.is_empty(), "进局后找到玩家（共 %d 名）" % players.size())
	var spawn_ok := false
	if not players.is_empty():
		var pp: Node2D = players[0]
		var gx := Vector2i(floori(pp.position.x / 64.0), floori(pp.position.y / 64.0))
		spawn_ok = _is_clear(mask.get_pixelv(gx))
		_check(spawn_ok, "出生格像素 = 已探索(透明)（实得 %s）" % str(mask.get_pixelv(gx)))

	# ------------------------------------------------------------
	_say("--- B 段：全图逐格一致性（一个真相源）---")
	var dark_when_unknown := 0     # 字典说未探索、像素也是黑的
	var clear_when_known := 0      # 字典说已探索、像素也是透的
	var mismatch := 0
	for y in range(map_h):
		for x in range(map_w):
			var c := Vector2i(x, y)
			var known: bool = bool(_fog.call("is_explored_cell", c))
			var px := mask.get_pixelv(c)
			if known and _is_clear(px):
				clear_when_known += 1
			elif (not known) and _is_dark(px):
				dark_when_unknown += 1
			else:
				mismatch += 1
	_check(mismatch == 0,
			"全图 %d 格：像素与探索字典零漂移（已探索 %d、未探索 %d、不一致 %d）"
			% [map_w * map_h, clear_when_known, dark_when_unknown, mismatch])
	_check(clear_when_known > 0 and dark_when_unknown > 0,
			"两侧样本都非空（已探索 %d、未探索 %d）" % [clear_when_known, dark_when_unknown])

	# 两通道互为补：r + a == 1（抽样，全图太慢且上面已证明同步）
	var complement_ok := true
	for y in range(0, map_h, 7):
		for x in range(0, map_w, 7):
			var pxc := mask.get_pixelv(Vector2i(x, y))
			if absf(pxc.r + pxc.a - 1.0) > 0.01:
				complement_ok = false
	_check(complement_ok, "抽样校验 r + a = 1（两个通道互为补，同一次写入同时喂两边）")

	_check(not bool(_fog.call("is_explored_cell", Vector2i(-1, -1))),
			"越界格算未探索（(-1,-1) → false）")
	_check(not bool(_fog.call("is_explored_cell", Vector2i(map_w, map_h))),
			"越界格算未探索（(w,h) → false）")

	# ------------------------------------------------------------
	_say("--- C 段：揭一格 → 该格像素当帧变透明 ---")
	# 挑一个远离出生点的未探索格，人工揭它
	var far := Vector2i(int(map_w / 2), int(map_h / 2))
	var tries := 0
	while bool(_fog.call("is_explored_cell", far)) and tries < 50:
		far = Vector2i(2 + tries * 3 % maxi(map_w - 4, 1), 2 + tries * 5 % maxi(map_h - 4, 1))
		tries += 1
	_check(not bool(_fog.call("is_explored_cell", far)), "找到一个未探索格 %s 用于揭格" % str(far))
	var before := mask.get_pixelv(far)
	_check(_is_dark(before), "揭之前该格像素是黑的（实得 %s）" % str(before))
	_fog.call("_reveal_around", Vector2(float(far.x) * 64.0 + 32.0, float(far.y) * 64.0 + 32.0))
	await _frames(2)
	var after := mask.get_pixelv(far)
	_check(_is_clear(after), "揭之后该格像素变透明（实得 %s）" % str(after))
	_check(bool(_fog.call("is_explored_cell", far)), "字典同步记下该格已探索")

	# ------------------------------------------------------------
	_say("--- D 段：纹理生命周期 ---")
	var tex: ImageTexture = _fog.call("minimap_fog_texture")
	_check(tex != null, "局内 minimap_fog_texture() 非 null")
	_check(tex != null and tex.get_width() == map_w and tex.get_height() == map_h,
			"纹理尺寸 = 地形底图尺寸 %d×%d（小地图据此逐格对齐）" % [map_w, map_h])

	# ------------------------------------------------------------
	_say("--- E 段：小地图拿到的是同一张纹理 + 绘制层顺序 ---")
	var mm_tex: ImageTexture = _mm.call("fog_texture")
	_check(mm_tex != null, "小地图已挂上迷雾纹理（set_fog_texture 被调到）")
	_check(mm_tex == tex, "小地图纹理与 fog 的**同一个对象**（instance id %s vs %s）"
			% [str(mm_tex.get_instance_id() if mm_tex != null else -1),
			   str(tex.get_instance_id() if tex != null else -1)])

	var terrain = _mm.get("_terrain_tex")
	_check(terrain != null, "小地图地形底图存在")
	_check(terrain != null and mm_tex != null
			and terrain.get_width() == mm_tex.get_width()
			and terrain.get_height() == mm_tex.get_height(),
			"迷雾纹理与地形底图**同尺寸**（尺寸不同 = 缩放错位，逐格对齐就没了）")

	var layers: Array = _script_const(_mm, "RENDER_LAYERS", [])
	_check(layers == EXPECT_LAYERS,
			"绘制层顺序 = %s（实得 %s）" % [str(EXPECT_LAYERS), str(layers)])
	if layers.size() == EXPECT_LAYERS.size():
		var i_ext: int = layers.find("extraction")
		var i_fog: int = layers.find("fog")
		var i_sq: int = layers.find("squad")
		_check(i_fog > i_ext and i_fog < i_sq,
				"雾夹在撤离点与小队之间（extraction %d < fog %d < squad %d）"
				% [i_ext, i_fog, i_sq])
		_check(i_fog >= 0, "fog 层确实在顺序表里（写漏了就不会画）")

	# 摘掉再挂回来
	_mm.call("set_fog_texture", null)
	_check(_mm.call("fog_texture") == null, "set_fog_texture(null) 后小地图不叠雾")
	_mm.call("set_fog_texture", tex)
	_check(_mm.call("fog_texture") == tex, "可以再挂回来（基地往返 / 换局靠这个）")

	# ------------------------------------------------------------
	_say("--- F 段：回基地摘雾、再进局重挂（且是新的那张）---")
	var old_id: int = tex.get_instance_id()
	_main.call("_enter_base")
	await _frames(10)
	_check(_mm.call("fog_texture") == null,
			"回基地：小地图遮罩被摘掉（不留上一局的数据）")
	_check(_fog.call("minimap_fog_texture") == null,
			"回基地：fog 停止供雾（deactivate 后返回 null）")

	_main.call("_on_launch", [{"id": "swordsman", "name": "剑士"}])
	await _frames(40)
	var tex2: ImageTexture = _mm.call("fog_texture")
	_check(tex2 != null, "再进局：小地图重新挂上迷雾纹理")
	_check(tex2 != null and tex2.get_instance_id() != old_id,
			"是**新建**的遮罩而非沿用旧对象（%s vs %s）"
			% [str(tex2.get_instance_id() if tex2 != null else -1), str(old_id)])
	var fog_now: ImageTexture = _fog.call("minimap_fog_texture")
	_check(tex2 == fog_now, "重新挂上的就是当前这一局的遮罩（同源）")

	# ------------------------------------------------------------
	_say("--- G 段：--no-fog 语义（关雾时小地图不能独自黑）---")
	_fog.call("disable")
	_check(_fog.call("minimap_fog_texture") == null,
			"disable() 后 fog 不再供雾（--no-fog 出图路径）")
	_main.call("_sync_minimap_fog")
	_check(_mm.call("fog_texture") == null,
			"同步后小地图也不叠雾 —— 否则主图没雾、小地图一片黑")

	_finish()


func _backup_save() -> void:
	var p := "user://save.json"
	_save_existed = FileAccess.file_exists(p)
	if _save_existed:
		_save_backup = FileAccess.get_file_as_string(p)


func _restore_save() -> void:
	var p := "user://save.json"
	if _save_existed:
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f != null:
			f.store_string(_save_backup)
			f.close()
	elif FileAccess.file_exists(p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _finish() -> void:
	_restore_save()
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for m in _fails:
		_say("  !! " + m)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_minimap_fog] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

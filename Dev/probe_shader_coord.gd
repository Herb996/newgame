extends Node2D
## ============================================================
## VertProbe — 一次性验证（**不属于游戏本体，验证完就删**）
##
## 背景：群系边界混合上一版把权重"每格量化成一档"烘进图集，结果是一块一块的补丁，
## 被用户否掉（见 memory/steampunk-biome-blend.md）。要做回效果图那种**格内连续**的
## 网点，shader 必须在每个片元上知道"我落在地图哪个像素"。上一版我**没验证就当
## TileMapLayer 的 VERTEX 是格坐标**，才翻的车。这一轮先把它证明掉。
##
## 上一轮实测已定论（test 0 会复核，别轻信结论）：
##   · `UV` 是**图集 UV**，跨相同瓦片逐块重复 → 拿不到格坐标。
##   · `VERTEX` 是**帧缓冲屏幕像素**：挪图层节点它不动，改相机位姿/缩放它也不动。
##   · 屏幕像素值直进直出、8bit 读回残差 0.5px → 2D 帧缓冲没做线性↔sRGB 转换，
##     数据纹理（R8）能按位精确读，不会被色彩管理糊掉。
## 于是可用做法只剩一条 —— 把相机位姿当 uniform 传进来，自己还原地图坐标：
##
##     地图像素 c = cam_pos + (VERTEX - 视口/2) / zoom - layer_origin
##
##   C   zoom=1 下逐像素精确（网点掩码 == CPU 独立算出的期望）
##   C2  zoom=2 + 相机偏心 + 图层挪位 下仍然精确；并和"不做还原"的对照组拉开数量级
##   D   相机走 8 世界像素 → 掩码在屏幕上走 16 像素（锁在地图上，不游动）
##   E   图层节点挪 64 → 掩码跟着挪 64（钉在图层上，不是钉在世界原点）
##
## 用法（**必须开窗**，无头是 dummy 驱动、viewport 贴图恒空）：
##   python tools/run_probe.py _vert_probe.log Dev/probe_shader_coord.tscn --window
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"

const TS := 64              # 瓦片边长（和游戏里 SRC_TILE 一致）
const DITHER := 8           # Bayer 边长，必须整除 TS
const CELLS_X := 6
const CELLS_Y := 4
const WIN := Vector2i(640, 480)

## 把 VERTEX 编码进 R/G（除以 512），B 通道塞图集 UV.x 当反证素材。
const CODE_COORDS := """
shader_type canvas_item;

void fragment() {
	float sx = clamp(VERTEX.x / 512.0, 0.0, 1.0);
	float sy = clamp(VERTEX.y / 512.0, 0.0, 1.0);
	COLOR = vec4(sx, sy, clamp(UV.x, 0.0, 1.0), 1.0);
}
"""

## 网点掩码：屏幕像素 → 地图像素 → 按 8×8 一块查权重、按 mod(c,8) 查 Bayer 相位。
## 亮就画红、不亮就 discard 露出绿底，这样"镂空"本身也是可断言的。
const CODE_DITHER := """
shader_type canvas_item;

uniform sampler2D weight_tex : filter_nearest;
uniform sampler2D bayer_tex : filter_nearest;
uniform vec2 weight_size;
uniform vec2 cam_pos;
uniform vec2 cam_zoom;
uniform vec2 vp_size;
uniform vec2 layer_origin;
uniform float period = 8.0;

void fragment() {
	vec2 c = cam_pos + (VERTEX - vp_size * 0.5) / cam_zoom - layer_origin;
	vec2 sub = floor(c / period);
	if (sub.x >= 0.0 && sub.y >= 0.0 && sub.x < weight_size.x && sub.y < weight_size.y) {
		float w = texture(weight_tex, (sub + vec2(0.5)) / weight_size).r;
		vec2 ph = floor(mod(c, period));
		float b = texture(bayer_tex, (ph + vec2(0.5)) / period).r;
		if (w >= b) {
			COLOR = vec4(1.0, 0.0, 0.0, 1.0);
		} else {
			discard;
		}
	} else {
		discard;
	}
}
"""

var _pass := 0
var _fail := 0
var _layer: TileMapLayer
var _cam: Camera2D
var _bg: ColorRect
var _coord_mat: ShaderMaterial
var _dither_mat: ShaderMaterial
var _wbytes: PackedByteArray
var _bbytes: PackedByteArray
var _wtex_w := 0
var _wtex_h := 0


func _ok(msg: String) -> void:
	_pass += 1
	print("[VertProbe] ok   %s" % msg)


func _bad(msg: String) -> void:
	_fail += 1
	print("[VertProbe] FAIL %s" % msg)


func _check(what: String, cond: bool, detail := "") -> void:
	if cond:
		_ok(what + ((" | " + detail) if detail != "" else ""))
	else:
		_bad(what + ((" | " + detail) if detail != "" else ""))


func _ready() -> void:
	print("[VertProbe] === TileMapLayer shader 坐标还原公式验证 ===")
	_setup()
	await _frames(6)
	await _test_vertex_is_screen_px()
	await _test_dither_at_zoom1()
	await _test_dither_with_camera_transform()
	await _test_mask_locked_to_map_on_pan()
	await _test_mask_follows_layer_offset()
	print("[VertProbe] 通过 %d / %d" % [_pass, _pass + _fail])
	for i in range(3):
		await RenderingServer.frame_post_draw
	get_tree().quit(0 if _fail == 0 else 1)


func _setup() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	# 固定 640×480：断言里"屏幕像素 ↔ 世界像素"的换算按这个尺寸算；
	# 放任窗口大小会随 --resolution / 工程设置漂。
	DisplayServer.window_set_size(WIN)

	_bg = ColorRect.new()
	_bg.color = Color(0.0, 1.0, 0.0)
	_bg.size = Vector2(4096, 4096)
	_bg.z_index = -10
	add_child(_bg)

	# 图集：1 块纯白瓦片，只为让 TileMapLayer 真的画东西
	var img := Image.create(TS, TS, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(TS, TS)
	src.create_tile(Vector2i(0, 0))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TS, TS)
	ts.add_source(src, 0)

	_layer = TileMapLayer.new()
	_layer.tile_set = ts
	_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_layer)
	for cy in range(CELLS_Y):
		for cx in range(CELLS_X):
			_layer.set_cell(Vector2i(cx, cy), 0, Vector2i(0, 0))

	_cam = Camera2D.new()
	add_child(_cam)
	_cam.make_current()

	_coord_mat = ShaderMaterial.new()
	_coord_mat.shader = _make_shader(CODE_COORDS)

	# 权重场：每格 8×8 texel（=网点粒度）。刻意做成**逐 texel 剧变**的哈希：
	# 任何取错 texel / 错一个 texel 的实现都会在像素上露出来。斜坡不行 —— 太温和，
	# 相机挪满一格时掩码几乎不动，D 就分不出"锁世界"和"锁屏幕"。
	_wtex_w = CELLS_X * DITHER
	_wtex_h = CELLS_Y * DITHER
	var wi := Image.create(_wtex_w, _wtex_h, false, Image.FORMAT_R8)
	_wbytes = PackedByteArray()
	_wbytes.resize(_wtex_w * _wtex_h)
	for j in range(_wtex_h):
		for i in range(_wtex_w):
			var v: int = (i * 97 + j * 41 + ((i * j) % 7) * 23) % 249 + 3
			_wbytes[j * _wtex_w + i] = v
			wi.set_pixel(i, j, Color.from_rgba8(v, 0, 0, 255))
	var bay: Array = MapGenerator._bayer(DITHER)
	_bbytes = PackedByteArray()
	_bbytes.resize(DITHER * DITHER)
	var bi := Image.create(DITHER, DITHER, false, Image.FORMAT_R8)
	for y in range(DITHER):
		for x in range(DITHER):
			var v2: int = int(round(255.0 * (float(int(bay[y][x])) + 0.5) / 64.0))
			_bbytes[y * DITHER + x] = v2
			bi.set_pixel(x, y, Color.from_rgba8(v2, 0, 0, 255))

	_dither_mat = ShaderMaterial.new()
	_dither_mat.shader = _make_shader(CODE_DITHER)
	_dither_mat.set_shader_parameter("weight_tex", ImageTexture.create_from_image(wi))
	_dither_mat.set_shader_parameter("bayer_tex", ImageTexture.create_from_image(bi))
	_dither_mat.set_shader_parameter("weight_size", Vector2(_wtex_w, _wtex_h))
	_dither_mat.set_shader_parameter("period", float(DITHER))


static func _make_shader(code: String) -> Shader:
	var sh := Shader.new()
	sh.code = code
	return sh


## ---------- 0：VERTEX 到底是什么（特征化，复核结论） ----------
func _test_vertex_is_screen_px() -> void:
	_place(Vector2.ZERO, _vp_half(), Vector2.ONE)
	_layer.material = _coord_mat
	var a := await _fit_screen("screen_z1_node0.png")
	_check("0 基线：zoom=1/节点=0 时 VERTEX = 屏幕像素",
			absf(a.ax - 1.0) < 0.03 and absf(a.ay - 1.0) < 0.03
			and absf(a.bx) < 4.0 and absf(a.by) < 4.0 and float(a.span) > 100.0,
			"slope=(%.4f,%.4f) off=(%.1f,%.1f) res=%.2f" % [a.ax, a.ay, a.bx, a.by, a.res])
	_place(Vector2(128, 64), _vp_half(), Vector2.ONE)
	var b := await _fit_screen("screen_z1_node128.png", Vector2i(128, 64))
	_check("0 反证：VERTEX 不跟图层节点走（所以还原式必须自己减 layer_origin）",
			absf(b.bx - a.bx) < 6.0 and absf(b.by - a.by) < 6.0,
			"off 差=(%.1f,%.1f) 若非 0 则它已含节点变换" % [b.bx - a.bx, b.by - a.by])
	_place(Vector2.ZERO, Vector2(192, 128), Vector2(2, 2))
	var z := await _fit_screen("screen_z2_cam192.png")
	_check("0 反证：VERTEX 不跟相机走（所以还原式必须自己除 zoom、加 cam_pos）",
			absf(z.ax - 1.0) < 0.03 and absf(z.ay - 1.0) < 0.03,
			"slope=(%.4f,%.4f) 仍为 1 → 纯屏幕坐标" % [z.ax, z.ay])
	_check("0 反证：UV 是图集坐标（跨瓦片重复 → 拿不到格坐标）",
			absf(a.img.get_pixelv(Vector2i(10, 10)).b
					- a.img.get_pixelv(Vector2i(10 + TS, 10)).b) < 0.004)


## ---------- C：zoom=1 下逐像素精确 ----------
func _test_dither_at_zoom1() -> void:
	_place(Vector2.ZERO, _vp_half(), Vector2.ONE)
	var m := await _shot_mask("mask_C.png")
	var r := _compare_mask(m, Vector2.ZERO, _vp_half(), Vector2.ONE, false)
	_check("C 还原式在 zoom=1 下逐像素精确", int(r["bad"]) == 0 and int(r["n"]) > 20000,
			"mismatch=%d / %d  first=%s" % [r["bad"], r["n"], r["first"]])


## ---------- C2：zoom=2 + 相机偏心 + 图层挪位 ----------
func _test_dither_with_camera_transform() -> void:
	var origin := Vector2(96, 32)
	var cam := Vector2(210, 150)
	var zoom := Vector2(2, 2)
	_place(origin, cam, zoom)
	var m := await _shot_mask("mask_C2.png")
	var r := _compare_mask(m, origin, cam, zoom, false)
	_check("C2 还原式在 zoom=2/偏心/图层偏移下仍逐像素精确",
			float(r["frac"]) < 0.02 and int(r["n"]) > 20000,
			"mismatch=%d / %d (%.3f%%) first=%s" % [r["bad"], r["n"], float(r["frac"]) * 100.0, r["first"]])
	# 对照组：故意**不**做还原（把屏幕像素当世界像素）。误差必须是数量级级别的大，
	# 否则上面那条"精确"可能只是掩码太平淡、根本测不出差别。
	var naive := _compare_mask(m, Vector2.ZERO, Vector2.ZERO, Vector2.ONE, true)
	_check("C2 对照组：不还原时误差大一个数量级（证明还原确实在起作用）",
			float(naive["frac"]) > 0.05
			and float(naive["frac"]) > 5.0 * maxf(float(r["frac"]), 0.0001),
			"naive=%.1f%% vs fixed=%.2f%%" % [float(naive["frac"]) * 100.0, float(r["frac"]) * 100.0])


## ---------- D：相机平移时网点锁在地图上 ----------
func _test_mask_locked_to_map_on_pan() -> void:
	_place(Vector2.ZERO, Vector2(192, 128), Vector2(2, 2))
	var a := await _shot_mask("mask_D1.png")
	_cam.position += Vector2(8, 0)          # 相机沿 x 走 8 个**世界**像素
	_dither_mat.set_shader_parameter("cam_pos", _cam.position)
	var b := await _shot_mask("mask_D2.png")
	var shifted := _masks_agree(a, b, int(round(8.0 * _cam.zoom.x)))
	var unmoved := _masks_agree(a, b, 0)
	_check("D 相机走 8 世界像素 → 掩码在屏幕上走 16 像素（锁在地图上，不游动）",
			shifted and not unmoved,
			"shift16=%s shift0=%s（shift0 必须 false，否则网点钉在屏幕上）" % [shifted, unmoved])


## ---------- E：图层节点挪位时网点跟着挪 ----------
func _test_mask_follows_layer_offset() -> void:
	_place(Vector2.ZERO, _vp_half(), Vector2.ONE)
	var a := await _shot_mask("mask_E0.png")
	_place(Vector2(64, 0), _vp_half(), Vector2.ONE)
	var b := await _shot_mask("mask_E64.png")
	# 两图都有瓦片的交集：a 覆盖屏幕 0..384，b 覆盖 64..448 → x ∈ [72, 376]
	var ok := _masks_agree(a, b, -64, Vector2i(72, 8), Vector2i(376, 248))
	var unmoved := _masks_agree(a, b, 0, Vector2i(72, 8), Vector2i(376, 248))
	_check("E 图层节点挪 64 → 掩码跟着挪 64（网点钉在图层上，不是钉在世界原点）",
			ok and not unmoved, "shift64=%s shift0=%s" % [ok, unmoved])
	_place(Vector2.ZERO, _vp_half(), Vector2.ONE)


## ---------- 采集 / 比对 ----------
func _place(origin: Vector2, cam: Vector2, zoom: Vector2) -> void:
	_layer.position = origin
	_cam.zoom = zoom
	_cam.position = cam
	# 真实项目里这三样每帧由相机推；这里手动喂，验证公式本身
	_dither_mat.set_shader_parameter("cam_pos", cam)
	_dither_mat.set_shader_parameter("cam_zoom", zoom)
	_dither_mat.set_shader_parameter("vp_size", _vp_half() * 2.0)
	_dither_mat.set_shader_parameter("layer_origin", origin)


func _vp_half() -> Vector2:
	return Vector2(get_window().size) * 0.5


func _shot_mask(fname: String) -> Image:
	_layer.material = _dither_mat
	for i in range(4):
		await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	var err := im.save_png(OUT_DIR + "/" + fname)
	if absf(float(im.get_width()) - _vp_half().x * 2.0) > 1.0:
		print("[VertProbe] !! 视口 %s != 窗口 %s，屏幕/世界换算要加缩放项" % [
				str(im.get_size()), str(get_window().size)])
	print("[VertProbe] 截图 %s (%dx%d) err=%d" % [fname, im.get_width(), im.get_height(), err])
	return im


## 逐像素比对：屏幕 s → 世界 c = cam + (s - vp/2)/zoom - origin → CPU 独立算掩码。
## naive=true 时故意令 c = s（不还原）当对照。
func _compare_mask(im: Image, origin: Vector2, cam: Vector2, zoom: Vector2,
		naive: bool) -> Dictionary:
	var bad := 0
	var n := 0
	var first := ""
	var half := _vp_half()
	for sy in range(im.get_height()):
		for sx in range(im.get_width()):
			var cx: float = float(sx) if naive \
					else cam.x + (float(sx) - half.x) / zoom.x - origin.x
			var cy: float = float(sy) if naive \
					else cam.y + (float(sy) - half.y) / zoom.y - origin.y
			var sub_x := int(floor(cx / float(DITHER)))
			var sub_y := int(floor(cy / float(DITHER)))
			if sub_x < 0 or sub_y < 0 or sub_x >= _wtex_w or sub_y >= _wtex_h:
				continue
			n += 1
			var w: int = int(_wbytes[sub_y * _wtex_w + sub_x])
			var ph_x := int(floor(posmod(cx, float(DITHER))))
			var ph_y := int(floor(posmod(cy, float(DITHER))))
			var b: int = int(_bbytes[ph_y * DITHER + ph_x])
			var want_lit := w >= b
			if (im.get_pixelv(Vector2i(sx, sy)).r > 0.5) != want_lit:
				bad += 1
				if first == "":
					first = "px(%d,%d) c=(%.1f,%.1f) w=%d b=%d want=%s" % [
							sx, sy, cx, cy, w, b, want_lit]
	return {"bad": bad, "n": n, "frac": float(bad) / float(maxi(n, 1)), "first": first}


## 两张掩码图整体水平偏移 d 个屏幕像素后是否一致（只比 lo..hi 这块两边都有瓦片的区域）
func _masks_agree(a: Image, b: Image, d: int,
		lo := Vector2i(8, 8), hi := Vector2i(-1, -1)) -> bool:
	var x1: int = mini(a.get_width(), a.get_width() + hi.x) if hi.x < 0 else mini(a.get_width(), hi.x)
	var y1: int = mini(a.get_height(), a.get_height() + hi.y) if hi.y < 0 else mini(a.get_height(), hi.y)
	var mismatches := 0
	var total := 0
	for y in range(lo.y, y1):
		for x in range(lo.x, x1):
			var xa: int = x + d
			if xa < 0 or xa >= a.get_width():
				continue
			total += 1
			if (a.get_pixelv(Vector2i(xa, y)).r > 0.5) != (b.get_pixelv(Vector2i(x, y)).r > 0.5):
				mismatches += 1
	var frac := float(mismatches) / float(maxi(total, 1))
	print("[VertProbe]   _masks_agree d=%d → %.3f%% (%d/%d)" % [d, frac * 100.0, mismatches, total])
	return total > 20000 and frac < 0.01


func _fit_screen(fname: String, off := Vector2i.ZERO) -> Dictionary:
	for i in range(4):
		await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	var err := im.save_png(OUT_DIR + "/" + fname)
	# 采样必须落在**真有瓦片**的像素上：节点挪了就得跟着挪，否则读到底色（无 shader）
	var p0 := _dec(im, off + Vector2i(20, 15))
	var p1 := _dec(im, off + Vector2i(280, 185))
	var p2 := _dec(im, off + Vector2i(140, 100))
	var ax: float = (p1.x - p0.x) / 260.0
	var ay: float = (p1.y - p0.y) / 170.0
	var bx: float = p0.x - float(off.x + 20) * ax
	var by: float = p0.y - float(off.y + 15) * ay
	var res: float = maxf(absf(p2.x - (ax * float(off.x + 140) + bx)),
			absf(p2.y - (ay * float(off.y + 100) + by)))
	var span: float = p1.x - p0.x
	print("[VertProbe] 截图 %s (%dx%d) err=%d slope=(%.4f,%.4f) off=(%.1f,%.1f) res=%.2f span=%.0f%s" % [
			fname, im.get_width(), im.get_height(), err, ax, ay, bx, by, res, span,
			"  ← 退化：shader 没生效会退回瓦片本色(纯白)→解码恒 512" if span < 100.0 else ""])
	return {"ax": ax, "ay": ay, "bx": bx, "by": by, "res": res, "span": span, "img": im}


## 把 R/G 通道解码回像素坐标（编码时除以 512）
func _dec(im: Image, at: Vector2i) -> Vector2:
	var c := im.get_pixelv(at)
	return Vector2(c.r * 512.0, c.g * 512.0)


func _frames(n: int) -> void:
	for i in range(n):
		await RenderingServer.frame_post_draw

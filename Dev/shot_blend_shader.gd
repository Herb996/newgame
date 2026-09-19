extends Node2D
## ============================================================
## BlendShaderShot — 一次性验证（**不属于游戏本体，验证完给用户看图用**）
##
## 上一轮 Dev/probe_shader_coord 已经把坐标证明掉了（9/9）：
##   TileMapLayer 的 `VERTEX` 是屏幕像素，不跟节点/相机走；`UV` 是图集 UV。
##   可用公式：局部坐标 = get_viewport_transform().affine_inverse() 作用在 VERTEX 上
##   （再按 帧缓冲/视口 缩放修正）→ 逐像素精确，zoom=2/偏心/图层偏移 0 处不符。
##
## 这一轮把那条公式真的拿去做**效果图**：用真地图、真图集、真装饰/光照层，
## 只差"混合怎么做"这一件事，三种做法各出一张同机位同裁切的图，摆在一起给用户看：
##   A 关（原状：边界是 1 格硬跳）
##   B 旧的每格一档（就是他嫌丑的那版 quilt）
##   C 新的逐像素连续（权重纹理 = 每格 1 texel 的 R8，**线性过滤**双线性插值出
##     连续占比 f，再和 8×8 Bayer 比 → 和当初批准的 mock_biome_v6.px_bayer 同构）
##
## 用法（**必须开窗**）：
##   python tools/run_probe.py _blend_shader_shot.log Dev/shot_blend_shader.tscn --window
## ============================================================

const OUT_DIR := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"
const MAP_SEED := 20260919
const WIN := Vector2i(1280, 800)
const CROP := 448             # 裁切边长（世界像素），围绕选中的边界点
const DITHER := 8
const BLOB_INTERIOR := 5   # blob_row(1,1)*4 + blob_col(1,1)：四向全通的实心块

## 与 probe_shader_coord 完全同一套坐标还原 + 网点判定，只多了"采样权重纹理"这一路。
const CODE := """
shader_type canvas_item;

uniform sampler2D weight_tex : filter_linear, repeat_disable;
uniform sampler2D bayer_tex : filter_nearest;
uniform vec2 coord_scale;
uniform vec2 coord_origin;
uniform vec2 weight_size;
uniform float period = 8.0;
uniform float tile_size = 64.0;

void fragment() {
	// VERTEX 是帧缓冲像素 → 仿射还原成地图像素（Dev/probe_shader_coord 证过 0 处不符）
	vec2 c = VERTEX * coord_scale + coord_origin;
	// 每格 1 texel、texel 中心落在格中心 → 双线性插值出格内连续的占比 f
	vec2 g = (c / tile_size + vec2(0.5)) / weight_size;
	float f = texture(weight_tex, g).r;
	float b = texture(bayer_tex, (floor(mod(c, period)) + vec2(0.5)) / period).r;
	if (f >= b) {
		COLOR = texture(TEXTURE, UV);
	} else {
		discard;
	}
}
"""

## 真·渐变：同一块 blob 的对面群系配色，按连续权重**淡入**。
## 五个群系图集是同一套美术的换色版（逐像素结构 100% 一致），所以两层叠加
## 不会出现图案重影，只有颜色在过渡 —— 这才是"渐变"，网点版是在拿噪声冒充它。
const CODE_GRAD := """
shader_type canvas_item;

uniform sampler2D weight_tex : filter_linear, repeat_disable;
uniform vec2 coord_scale;
uniform vec2 coord_origin;
uniform vec2 weight_size;
uniform float tile_size = 64.0;
uniform float gain = 1.0;

void fragment() {
	vec2 c = VERTEX * coord_scale + coord_origin;
	vec2 g = (c / tile_size + vec2(0.5)) / weight_size;
	float f = clamp(texture(weight_tex, g).r * gain, 0.0, 1.0);
	COLOR = texture(TEXTURE, UV);
	COLOR.a *= f;
}
"""

## 等值线版：把"次主导占比"场按 f=0.5 收一条边界出来。
## 这张场是**每格 1 texel + 线性过滤**，等价于双网格的"角点决定外观"：
## 双线性插值场的 0.5 等值线天然切角、圆角，不再是 64px 台阶。
## soft=1 → 退化成上一轮的纯渐变；soft 越小边越利落、转角照样是圆的。
const CODE_ISO := """
shader_type canvas_item;

uniform sampler2D weight_tex : filter_linear, repeat_disable;
uniform vec2 coord_scale;
uniform vec2 coord_origin;
uniform vec2 weight_size;
uniform float tile_size = 64.0;
uniform float soft = 0.12;

void fragment() {
	vec2 c = VERTEX * coord_scale + coord_origin;
	vec2 g = (c / tile_size + vec2(0.5)) / weight_size;
	float f = texture(weight_tex, g).r;
	COLOR = texture(TEXTURE, UV);
	COLOR.a *= clamp((f - 0.5) / max(soft, 0.001) + 0.5, 0.0, 1.0);
}
"""

## 第二张参考图（199x217，草地/水面）量出来的三条硬指标，和第一张完全不同：
##   1) 过渡**很宽**：10%–90% 色带中位 30px / 图宽 199px = **15%**，79% 的边
##      宽度 ≥10px，只有 7.7% 是利线 —— 也就是说它根本没有"边界"，只有场。
##   2) 过渡**不对称**：色带从 d=-18（草侧）一直爬到 d=+10（水侧），
##      50% 点不在中线，而在偏水侧 8px 处。
##   3) 中点**不是线性插值**：实测中位色 rgb(94,144,122)，直线 lerp 中点
##      rgb(104,155,121) —— 实际偏冷偏暗约 31% 的量程。
## 换算成尺度无关量：参考图边界波长 ≈138px、色带 30px → **色带 = 0.22 × 波长**。
## 这一条直接锁死了两个旋钮的联动关系：ramp_px ≈ 0.22 / biome_noise_frequency。
## 之前 r=5+edge_px=11 之所以怎么调都不对，是因为它在拿一个像素级羽化去贴一个
## 场级渐变 —— 差了 30 倍。
## CODE_PAINT 因此把宽度定义在**世界像素**上（跟缩放走，不跟屏幕走），
## 并给出 skew（50% 点偏移）和 gamma（中点偏冷偏暗）两个独立旋钮。
const CODE_PAINT := """
shader_type canvas_item;

uniform sampler2D weight_tex : filter_linear, repeat_disable;
uniform vec2 coord_scale;
uniform vec2 coord_origin;
uniform vec2 weight_size;
uniform float tile_size = 64.0;
uniform float ramp_px = 120.0;
uniform float skew = 0.0;
uniform float gamma = 1.0;

void fragment() {
	vec2 c = VERTEX * coord_scale + coord_origin;
	vec2 g = (c / tile_size + vec2(0.5)) / weight_size;
	float f = texture(weight_tex, g).r;
	// fwidth 是"每个帧缓冲像素的 df"；除以 coord_scale 换成"每个世界像素的 df"，
	// 于是 ramp_px 是实打实的世界宽度，拉远时色带会跟着地图一起缩。
	float w = max(fwidth(f) * ramp_px / max(coord_scale.x, 1e-4), 1e-5);
	float mid = clamp(0.5 + skew * w, 0.02, 0.98);
	float lo = w * (0.5 + skew);  // 50% 点往下走 lo 到达全透明侧
	float hi = w * (0.5 - skew);  // 往上走 hi 到达全不透明侧
	float a = f < mid ? (mid - f) / max(lo, 1e-5) : (f - mid) / max(hi, 1e-5);
	a = clamp(a, 0.0, 1.0);
	a = 1.0 - pow(1.0 - a, gamma);
	COLOR = texture(TEXTURE, UV);
	COLOR.a *= a;
}
"""

## 实拍图暴露了下一个瓶颈：色带宽度对了以后，剩下的方块感**全部来自权重场本身**
## —— 它是一格一 texel、双线性插值，等值线必然是 64px 网格上的折线（看 P_ref 那张
## 的直角台阶）。参考图的手指状内嵌尺度只有 20–70px，比一格还小。
## 所以把 CODE_ORGANIC 的 domain warp 和 CODE_PAINT 的世界像素色带合并：
## 先用世界噪声把**采样点**挪走（单位=格，amp 0.6 就是 38px），再按世界像素开羽化。
## warp 的噪声频率 wfreq 用"每格"计，0.9 → 周期约 1.1 格 = 70px，正好是内嵌尺度。
const CODE_WARP := """
shader_type canvas_item;

uniform sampler2D weight_tex : filter_linear, repeat_disable;
uniform vec2 coord_scale;
uniform vec2 coord_origin;
uniform vec2 weight_size;
uniform float tile_size = 64.0;
uniform float ramp_px = 120.0;
uniform float skew = 0.0;
uniform float gamma = 1.0;
uniform float amp = 0.6;
uniform float wfreq = 0.9;

float h21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vn(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x),
			mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		s += a * vn(p);
		p *= 2.03;
		a *= 0.5;
	}
	return s / 0.875;
}

void fragment() {
	vec2 c = VERTEX * coord_scale + coord_origin;
	vec2 cell = c / tile_size + vec2(0.5);
	float n1 = fbm(cell * wfreq + vec2(0.0, 13.7)) - 0.5;
	float n2 = fbm(cell * wfreq + vec2(91.3, 5.1)) - 0.5;
	vec2 wc = cell + vec2(n1, n2) * 2.0 * amp;
	float f = texture(weight_tex, wc / weight_size).r;
	float w = max(fwidth(f) * ramp_px / max(coord_scale.x, 1e-4), 1e-5);
	float mid = clamp(0.5 + skew * w, 0.02, 0.98);
	float lo = w * (0.5 + skew);
	float hi = w * (0.5 - skew);
	float a = f < mid ? (mid - f) / max(lo, 1e-5) : (f - mid) / max(hi, 1e-5);
	a = clamp(a, 0.0, 1.0);
	a = 1.0 - pow(1.0 - a, gamma);
	COLOR = texture(TEXTURE, UV);
	COLOR.a *= a;
}
"""

## 等值线 + **像素宽度**的边沿：把"形状有多圆"和"颜色过渡有多宽"解耦。
## CODE_ISO 的 soft 是场单位，模糊半径一大边就跟着变糊，两个旋钮拧不到一起。
## 这里用 fwidth(f) 把羽化换算成屏幕像素：edge_px=1 是一条 AA 利线，
## 想要渐变就加大它 —— 而曲线的圆润度完全交给 CPU 侧的模糊半径。
const CODE_EDGE := """
shader_type canvas_item;

uniform sampler2D weight_tex : filter_linear, repeat_disable;
uniform vec2 coord_scale;
uniform vec2 coord_origin;
uniform vec2 weight_size;
uniform float tile_size = 64.0;
uniform float edge_px = 2.0;

void fragment() {
	vec2 c = VERTEX * coord_scale + coord_origin;
	vec2 g = (c / tile_size + vec2(0.5)) / weight_size;
	float f = texture(weight_tex, g).r;
	// f 对屏幕像素的变化率 → 要 edge_px 个像素宽的过渡，场值就要走 df*edge_px
	float w = max(fwidth(f) * edge_px, 1e-5);
	COLOR = texture(TEXTURE, UV);
	COLOR.a *= clamp((f - 0.5) / w + 0.5, 0.0, 1.0);
}
"""

## 参考图（手绘水彩式沙/草交界）给的三条硬指标：过渡宽度**逐处变化 8 倍**
## （中位 4px、p90 14px、最宽 35px，图宽才 169px）、边界逐行漂移 mean|dx|=7px
## （不是"平滑"而是"毛"）、边界带里有 14 个 4–40px 的孤立小岛。
## 前三版全错在把这三件事当成了同一个旋钮：等宽羽化 = 一条"第三种地形"的色带。
## 这里形状不来自"模糊后的格网"（那必然带 64px 台阶），而来自**世界坐标里的噪声**：
##   1) domain warp：拿噪声偏移权重场的采样点 → 边界自己弯，且和格子对齐无关
##   2) 第二路噪声插值 soft_lo..soft_hi → 过渡宽度逐处不同
##   3) 第三路噪声在边界带里抬 alpha → 孤立小岛
const CODE_ORGANIC := """
shader_type canvas_item;

uniform sampler2D weight_tex : filter_linear, repeat_disable;
uniform vec2 coord_scale;
uniform vec2 coord_origin;
uniform vec2 weight_size;
uniform float tile_size = 64.0;
uniform float amp = 1.2;
uniform float freq = 0.45;
uniform float vamp = 0.6;
uniform float vfreq = 0.3;
uniform float soft_lo = 0.03;
uniform float soft_hi = 0.35;
uniform float island = 0.45;

float h21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vn(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x),
			mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		s += a * vn(p);
		p *= 2.03;
		a *= 0.5;
	}
	return s / 0.875;
}

void fragment() {
	vec2 c = VERTEX * coord_scale + coord_origin;
	vec2 cell = c / tile_size + vec2(0.5);
	float n1 = fbm(cell * freq + vec2(0.0, 13.7)) - 0.5;
	float n2 = fbm(cell * freq + vec2(91.3, 5.1)) - 0.5;
	float f0 = texture(weight_tex, (cell + vec2(n1, n2) * amp * 2.0) / weight_size).r;
	// 值噪声只在"混合带"里生效（带外 f0 恰好是 0 或 1，加噪会把整张图撒满斑点）。
	// 带内则凭空长出新的等值线 → 海湾、半岛、孤立岛，这是位置扭曲做不到的。
	float gate = clamp(f0 * 8.0, 0.0, 1.0) * clamp((1.0 - f0) * 8.0, 0.0, 1.0);
	float nv = fbm(cell * vfreq + vec2(17.0, 63.0)) - 0.5;
	float f = clamp(f0 + nv * 2.0 * vamp * gate, 0.0, 1.0);
	float sw = mix(soft_lo, soft_hi, clamp(fbm(cell * freq * 0.6 + vec2(37.0, 71.0)), 0.0, 1.0));
	float a = clamp((f - 0.5) / max(sw * 2.0, 0.001) + 0.5, 0.0, 1.0);
	float sp = fbm(cell * 1.25 + vec2(11.0, 57.0));
	float fringe = clamp(1.0 - abs(f - 0.22) * 2.6, 0.0, 1.0);
	a = clamp(a + island * smoothstep(0.68, 0.80, sp) * fringe, 0.0, 1.0);
	COLOR = texture(TEXTURE, UV);
	COLOR.a *= a;
}
"""

var _map_root: Node2D
var _terrain: Array
var _biome: Array
var _tile_size := 64
var _cells: Dictionary = {}
var _w := 0
var _h := 0
var _blend: TileMapLayer
var _mat: ShaderMaterial
var _mat_grad: ShaderMaterial
var _mat_iso: ShaderMaterial
var _mat_edge: ShaderMaterial
var _mat_org: ShaderMaterial
var _mat_paint: ShaderMaterial
var _mat_warp: ShaderMaterial
var _wtex: ImageTexture
var _focus := Vector2.ZERO
var _cam: Camera2D
var _bfreq := 0.04
var _tint_str := 1.0
var _tag := ""


static func _arg_float(flag: String, dflt: float) -> float:
	var ua := OS.get_cmdline_user_args()
	for i in range(ua.size()):
		if String(ua[i]) == flag and i + 1 < ua.size():
			return float(String(ua[i + 1]))
	return dflt


## 板色间距才是这一轮的真瓶颈：实测四个群系板色两两 RGB 距离**中位 66、最小 42**
## （草地 vs 荒原几乎同色），而参考图是 111 / 190。端点只差 66 的话，色带一宽，
## 中间调就把两端糊成一片 —— 这就是「脏泥」的机理，跟混合方式无关。
## 好消息：`map.biomes[i].tint` 本来就是逐群系 RGB 乘子，且在 `_build_atlas_image`
## 里同时作用于地形和装饰 modulate —— 拉色距是个配置活，不用重画美术。
## tint = 目标板色 / 图集实测均值（只取 blob 区、只算不透明像素）：
##   color1 (141.5,173.1, 91.1) → (150,185, 60) 亮黄绿
##   color4 (125.4,148.0, 97.0) → (195,130, 55) 暖赭
##   color3 ( 97.5,162.7,103.1) → ( 55,100, 50) 暗绿
##   color5 ( 88.0,147.8,136.6) → (118,108,158) 冷板岩（水瓦是 (71,171,169)，差 121，不撞）
const TINT_TARGET := [
		[1.060, 1.069, 0.659],
		[1.555, 0.878, 0.567],
		[0.564, 0.615, 0.485],
		[1.341, 0.731, 1.157],
]


func _apply_biome_tints(strength: float) -> void:
	var raw = Config.get_value("map.biomes", null)
	if raw == null or not (raw is Array):
		print("[BlendShot] 读不到 map.biomes，跳过改色")
		return
	var out: Array = []
	for i in range((raw as Array).size()):
		var e: Dictionary = ((raw as Array)[i] as Dictionary).duplicate(true)
		var cur: Array = e.get("tint", [1.0, 1.0, 1.0])
		if i < TINT_TARGET.size():
			var nxt: Array = []
			for ch in range(3):
				nxt.append(lerpf(float(cur[ch]), float(TINT_TARGET[i][ch]), strength))
			e["tint"] = nxt
			print("[BlendShot] 群系 %s tint %s → %s" % [
					str(e.get("name", i)), str(cur), str(nxt)])
		out.append(e)
	# MapGenerator._biomes() 有 static 缓存，必须在第一次 generate 之前覆盖
	Config.set_override("map.biomes", out)


func _ready() -> void:
	print("[BlendShot] === 逐像素连续混合 · 实拍对比 ===")
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(WIN)
	# 旧图层版不要（我自己建三层对照），但混合层用的权重场仍走 MapGenerator
	Config.set_override("map.biome_blend.enabled", false)
	# 群系噪声频率：出厂 0.008 是"每格"采样 → 周期 125 格，比整张图还大，
	# 群系只能退化成几条笔直的大色带。用 --biome-freq 换一版看形状差异。
	_bfreq = _arg_float("--biome-freq", 0.04)
	_tint_str = _arg_float("--tint-strength", 1.0)
	_tag = "f%s_t%s" % [str(_bfreq).replace(".", ""), str(_tint_str).replace(".", "")]
	Config.set_override("map.biome_noise_frequency", _bfreq)
	print("[BlendShot] 群系噪声频率 = %.3f /格（周期 %.0f 格）" % [_bfreq, 1.0 / _bfreq])
	_apply_biome_tints(_tint_str)
	seed(MAP_SEED)          # 和 Dev/probe_biome_blend 同一颗种子，图可复现
	var t0 := Time.get_ticks_msec()
	var res: Dictionary = MapGenerator.generate()
	_map_root = res["node"]
	_terrain = res["terrain"]
	_biome = res["biome"]
	_tile_size = int(res["tile_size"])
	_h = _biome.size()
	_w = _biome[0].size()
	add_child(_map_root)
	print("[BlendShot] 地图 %dx%d 格，生成 %d ms" % [_w, _h, Time.get_ticks_msec() - t0])

	_cam = Camera2D.new()
	add_child(_cam)
	_cam.make_current()

	_focus = _pick_border_cell()
	print("[BlendShot] 取景中心格 %s → 世界 %s" % [str(_focus / _tile_size), str(_focus)])

	_build_layer_and_material()
	_build_old_layer()
	await _frames(8)
	await _shooting_pass()
	print("[BlendShot] 完成，图在 %s" % OUT_DIR)
	get_tree().quit(0)


## 选一条"长而直"的群系边界：统计每格周围 12 格内的异群系可走格数量，取最多者。
func _pick_border_cell() -> Vector2:
	var best := Vector2(64 * _tile_size, 64 * _tile_size)
	var best_n := -1
	for y in range(4, _h - 4, 2):
		for x in range(4, _w - 4, 2):
			if bool(_terrain[y][x]):
				continue
			var own: int = int(_biome[y][x])
			var n := 0
			for dy in range(-6, 7):
				for dx in range(-6, 7):
					var yy: int = y + dy
					var xx: int = x + dx
					if yy < 0 or xx < 0 or yy >= _h or xx >= _w or bool(_terrain[yy][xx]):
						continue
					if int(_biome[yy][xx]) != own:
						n += 1
			if n > best_n:
				best_n = n
				best = Vector2(x * _tile_size + _tile_size * 0.5, y * _tile_size + _tile_size * 0.5)
	print("[BlendShot] 边界密度 %d/169" % best_n)
	return best


func _build_layer_and_material() -> void:
	# B 对照层要用的旧档位表（含 lv 量化），原样留着
	_cells = MapGenerator._build_blend_cells(_biome, _terrain, _w, _h, 1)

	var bay: Array = MapGenerator._bayer(DITHER)
	var bi := Image.create(DITHER, DITHER, false, Image.FORMAT_R8)
	for y in range(DITHER):
		for x in range(DITHER):
			bi.set_pixel(x, y, Color.from_rgba8(
					int(round(255.0 * (float(int(bay[y][x])) + 0.5) / 64.0)), 0, 0, 255))

	# 两份材质共用同一张权重纹理、同一套坐标还原，只差"镂空"还是"淡入"
	_mat_grad = ShaderMaterial.new()
	_mat_grad.shader = _make_shader(CODE_GRAD)
	_mat_grad.set_shader_parameter("weight_size", Vector2(_w, _h))
	_mat_grad.set_shader_parameter("tile_size", float(_tile_size))
	_mat_iso = ShaderMaterial.new()
	_mat_iso.shader = _make_shader(CODE_ISO)
	_mat_iso.set_shader_parameter("weight_size", Vector2(_w, _h))
	_mat_iso.set_shader_parameter("tile_size", float(_tile_size))
	_mat_edge = ShaderMaterial.new()
	_mat_edge.shader = _make_shader(CODE_EDGE)
	_mat_edge.set_shader_parameter("weight_size", Vector2(_w, _h))
	_mat_edge.set_shader_parameter("tile_size", float(_tile_size))
	_mat_org = ShaderMaterial.new()
	_mat_org.shader = _make_shader(CODE_ORGANIC)
	_mat_org.set_shader_parameter("weight_size", Vector2(_w, _h))
	_mat_org.set_shader_parameter("tile_size", float(_tile_size))
	_mat_paint = ShaderMaterial.new()
	_mat_paint.shader = _make_shader(CODE_PAINT)
	_mat_paint.set_shader_parameter("weight_size", Vector2(_w, _h))
	_mat_paint.set_shader_parameter("tile_size", float(_tile_size))
	_mat_warp = ShaderMaterial.new()
	_mat_warp.shader = _make_shader(CODE_WARP)
	_mat_warp.set_shader_parameter("weight_size", Vector2(_w, _h))
	_mat_warp.set_shader_parameter("tile_size", float(_tile_size))
	_mat = ShaderMaterial.new()
	_mat.shader = _make_shader(CODE)
	_mat.set_shader_parameter("bayer_tex", ImageTexture.create_from_image(bi))
	_mat.set_shader_parameter("weight_size", Vector2(_w, _h))
	_mat.set_shader_parameter("tile_size", float(_tile_size))
	_mat.set_shader_parameter("period", float(DITHER))

	# 复用主图层那份图集：混合格只要指向"次主导群系的同一块 blob"即可，
	# 于是**不再需要 7 档网点图集**。
	_blend = TileMapLayer.new()
	_blend.name = "BiomeBlendShaderLayer"
	_blend.tile_set = _find_terrain_layer().tile_set
	_blend.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_map_root.add_child(_blend)
	_map_root.move_child(_blend, 1)   # 夹在 terrain 与 decor 之间
	_blend.material = _mat_grad


## 按给定带宽重建连续场 + 铺瓦，并把新权重纹理同时喂给三份材质。
## interior=true 时混合格一律用**内部实心块**（blob 5，实测 4096/4096 全不透明）：
## 本格自己的 blob 带着崖壁描边和透明角，淡入后会漏出一条暗线、还会把 64px
## 台阶从瓦片轮廓上重新带回来。用实心块才能让形状完全由 alpha 等值线说了算。
func _setup_blend(radius: int, interior := false, dilate := 1) -> void:
	var t0 := Time.get_ticks_msec()
	# 连续场**不量化、不砍 lv==0**，再往外扩一圈 8 邻格。
	# 扩圈是必需的：双线性插值会把 w>0 的格"渗"到相邻的 w==0 格里，
	# 那里没有瓦片的话渗出去的那半格就被硬生生切平 → 边界又变回 64px 台阶。
	var field := _continuous_field(radius)
	var band: Array = field.keys()
	var place: Dictionary = {}
	for pos in band:
		place[pos] = {"alt": int(field[pos]["alt"]), "k": int(field[pos]["k"])}
	for pos in band:
		for dy in range(-dilate, dilate + 1):
			for dx in range(-dilate, dilate + 1):
				var np := Vector2i(pos.x + dx, pos.y + dy)
				if np.x < 0 or np.y < 0 or np.x >= _w or np.y >= _h:
					continue
				if place.has(np) or bool(_terrain[np.y][np.x]):
					continue
				place[np] = {"alt": int(field[pos]["alt"]),
						"k": MapGenerator.blob_index(_terrain, np.x, np.y)}

	var wi := Image.create(_w, _h, false, Image.FORMAT_R8)
	for pos in field:
		var e: Dictionary = field[pos]
		wi.set_pixel(pos.x, pos.y, Color.from_rgba8(
				int(clampf(float(e["w"]) * 255.0, 0.0, 255.0)), 0, 0, 255))
	_wtex = ImageTexture.create_from_image(wi)
	for m in [_mat, _mat_grad, _mat_iso, _mat_edge, _mat_org, _mat_paint, _mat_warp]:
		m.set_shader_parameter("weight_tex", _wtex)

	_blend.clear()
	for pos in place:
		var e2: Dictionary = place[pos]
		var k: int = BLOB_INTERIOR if interior else int(e2["k"])
		_blend.set_cell(pos, 0, Vector2i(int(e2["alt"]) * MapGenerator.BLOB_N + k, 0))
	print("[BlendShot] r=%d：权重格 %d / 铺瓦格 %d，耗时 %d ms" % [
			radius, field.size(), place.size(), Time.get_ticks_msec() - t0])


## 与 MapGenerator._build_blend_cells 同一套算法，但**不做 1..7 档量化、不砍 lv==0**：
## 每个"邻域里有别的群系"的可走格 → {alt:次主导群系, w:连续占比, k:本格 blob}。
func _continuous_field(radius: int) -> Dictionary:
	var nb: int = MapGenerator.biome_count()
	var fields: Array = []
	for b in range(nb):
		var ind: Array = []
		for y in range(_h):
			var row := PackedFloat32Array()
			row.resize(_w)
			for x in range(_w):
				row[x] = 1.0 if (not bool(_terrain[y][x]) and int(_biome[y][x]) == b) else 0.0
			ind.append(row)
		fields.append(MapGenerator._box_blur(ind, radius, _w, _h))
	var out := {}
	for y in range(_h):
		for x in range(_w):
			if bool(_terrain[y][x]):
				continue
			var own: int = int(_biome[y][x])
			var alt: int = -1
			var alt_w := 0.0
			for b in range(nb):
				if b != own and float(fields[b][y][x]) > alt_w:
					alt_w = float(fields[b][y][x])
					alt = b
			var denom: float = float(fields[own][y][x]) + alt_w
			if alt < 0 or denom <= 0.0:
				continue
			out[Vector2i(x, y)] = {"alt": alt, "w": alt_w / denom,
					"k": MapGenerator.blob_index(_terrain, x, y)}
	return out


func _find_terrain_layer() -> TileMapLayer:
	for c in _map_root.get_children():
		if c is TileMapLayer:
			return c as TileMapLayer
	return null


static func _make_shader(code: String) -> Shader:
	var sh := Shader.new()
	sh.code = code
	return sh


## 每帧把相机姿态喂给 shader（真并入项目时也是这一步，代价 = 2 个 uniform）。
## 关系式来自 Dev/probe_shader_coord：
##   世界 = 屏心 + (VERTEX/内容缩放 - 视口一半)/zoom - 图层原点
func _process(_dt: float) -> void:
	if _blend == null or _mat == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var fb := Vector2(get_window().size)
	var sc := fb / vp if vp.x > 0.0 and vp.y > 0.0 else Vector2.ONE
	var z := _cam.zoom
	var scl := Vector2(1.0 / (sc.x * z.x), 1.0 / (sc.y * z.y))
	var org := _cam.get_screen_center_position() - _blend.global_position - vp * 0.5 / z
	for m in [_mat, _mat_grad, _mat_iso, _mat_edge, _mat_org, _mat_paint, _mat_warp]:
		if m == null:
			continue
		m.set_shader_parameter("coord_scale", scl)
		m.set_shader_parameter("coord_origin", org)


func _shooting_pass() -> void:
	# 第二张参考图给的是一条**耦合关系**，不是两个独立旋钮：
	#   色带宽度 ≈ 0.22 × 边界波长，而波长 = tile_size / biome_noise_frequency。
	# 带宽对上之后剩下的方块感来自权重场本身（一格一 texel，等值线必然贴着 64px 网格），
	# 所以这一批扫 domain warp 的幅度，看能不能把等值线从格网上摘下来。
	_blend.material = _mat_warp
	var wave: float = float(_tile_size) / _bfreq
	var ramp: float = _arg_float("--ramp", 0.22 * wave)
	var wf: float = _arg_float("--wfreq", 0.9)
	var radius: int = int(clampf(float(ceili(ramp / float(_tile_size)) + 1), 2.0, 14.0))
	print("[BlendShot] 波长 %.0f 世界px → 色带 %.0f px（0.22×波长），wfreq %.2f /格，CPU 模糊 %d 格" % [
			wave, ramp, wf, radius])
	_setup_blend(radius, true, 3)
	_mat_warp.set_shader_parameter("ramp_px", ramp)
	_mat_warp.set_shader_parameter("wfreq", wf)
	_mat_warp.set_shader_parameter("skew", 0.0)
	_mat_warp.set_shader_parameter("gamma", 1.0)
	await _grab("W_off_z1_%s.png" % _tag, Vector2.ONE, false)
	for amp: float in [0.0, 0.35, 0.7, 1.2]:
		_mat_warp.set_shader_parameter("amp", amp)
		_blend.visible = true
		var nm := "a" + str(amp).replace(".", "")
		await _grab("W_%s_z1_%s.png" % [nm, _tag], Vector2.ONE)
	# 负对照：同样的场，色带压回 6px 利线 —— 证明"宽"才是起作用的那个变量
	_mat_warp.set_shader_parameter("amp", 0.7)
	_mat_warp.set_shader_parameter("ramp_px", 6.0)
	await _grab("W_thin_z1_%s.png" % _tag, Vector2.ONE)
	_mat_warp.set_shader_parameter("ramp_px", ramp)
	# 拉远一档，看色带是否跟着世界尺度缩（世界像素定义 vs 屏幕像素定义的分水岭）
	await _grab("W_a07_z035_%s.png" % _tag, Vector2(0.35, 0.35))
	_blend.visible = false
	await _grab_old("W_old_z1_%s.png" % _tag, Vector2.ONE)


var _old_layer: TileMapLayer = null


## 旧版（每格一档 + 7 档网点图集）：走 map_generator 自己的构造函数建一层，
## 只为同机位对照。`_atlas_img` 是静态的，上面 generate() 已经填好了。
func _build_old_layer() -> void:
	var t0 := Time.get_ticks_msec()
	_old_layer = TileMapLayer.new()
	_old_layer.name = "BiomeBlendLayerOld"
	_old_layer.tile_set = MapGenerator._build_blend_tileset(_tile_size, DITHER)
	_old_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	for pos in _cells:
		var e: Dictionary = _cells[pos]
		_old_layer.set_cell(pos, 0, MapGenerator.blend_atlas_pos(
				int(e["alt"]), int(e["k"]), int(e["lv"])))
	_old_layer.visible = false
	_map_root.add_child(_old_layer)
	_map_root.move_child(_old_layer, 1)
	print("[BlendShot] 旧版对照层：%d 格，网点图集重建 %d ms" % [_cells.size(), Time.get_ticks_msec() - t0])


func _grab_old(fname: String, zoom: Vector2) -> void:
	_old_layer.visible = true
	await _shot(fname, zoom)
	_old_layer.visible = false


func _grab(fname: String, zoom: Vector2, show_blend := true, pan := Vector2.ZERO) -> void:
	_blend.visible = show_blend
	await _shot(fname, zoom, pan)


func _shot(fname: String, zoom: Vector2, pan := Vector2.ZERO) -> void:
	_cam.zoom = zoom
	_cam.position = _focus + pan
	for i in range(5):
		await RenderingServer.frame_post_draw
	var im := get_viewport().get_texture().get_image()
	var err := im.save_png(OUT_DIR + "/" + fname)
	print("[BlendShot] %s (%dx%d) zoom=%.1f pan=%s err=%d" % [
			fname, im.get_width(), im.get_height(), zoom.x, str(pan), err])


func _frames(n: int) -> void:
	for i in range(n):
		await RenderingServer.frame_post_draw

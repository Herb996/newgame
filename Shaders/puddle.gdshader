shader_type canvas_item;

// ============================================================
// puddle.gdshader — 局内积水基底（WeatherSystem 生成，见 Scripts/weather_system.gd）
//
// 宿主是一个覆盖全图的 ColorRect（尺寸 = 地图格数 × tile_px，位置 = 地图原点）。
// 选 ColorRect 而不是 Sprite2D：它的 VERTEX 天然就是像素坐标、visibility_rect
// 自动按 size 算；换成 1×1 纹理的 Sprite2D 会被默认 visibility_rect 整层裁掉，
// 症状是「积水完全不显示」，白折腾。
//
// 形状全部由 shader 生成，宿主纹理是 1×1 白点，零美术资产依赖。
// 四步走（对应用户方案的积水基底设计）：
//   ① step 裁切   —— cell_mask 非水格整片 discard，积水轮廓严格贴格
//   ② 内缩一层    —— 8 邻取样近似「腐蚀 1 格」，得到水体内部
//   ③ 边缘虚化    —— 边缘带（水格但非内部）的 alpha 由随 TIME 滚动的 fbm 决定
//   ④ 微光 shimmer —— 第二阶段把这一段换成 screen_texture 采样即得折射扰动，
//                     uniform 与接口都不用动
//
// 数值来源：Data/config.json 的 weather.puddle（脚本侧统一 set_shader_parameter）。
// ============================================================

// R 通道 = 该格是否积水（0/255）。尺寸 = 地图格数，由 CPU 侧烘焙，
// 与逻辑查询用的 _water_cells 同源，保证「看着有水」和「踩上去有水」不漂移。
// filter_linear：把格级 0/1 掩码插值成**连续覆盖场** —— 这是边缘不方块的关键。
// 若用 nearest，alpha 在格边界硬跳，积水看起来就是一堆半透明方块（首版截图实测）。
uniform sampler2D cell_mask : filter_linear;
uniform vec2 mask_size = vec2(128.0, 128.0);   // 地图格数
uniform float tile_px = 64.0;                   // 一格多少世界像素
uniform vec2 world_origin = vec2(0.0, 0.0);     // 宿主全局位置（补偿父级偏移）

uniform vec4 water_color : source_color = vec4(0.25, 0.44, 0.56, 0.42);
uniform float noise_scale = 0.10;               // 边缘噪声频率（按格坐标）
uniform vec2 scroll_dir = vec2(0.5, 0.9);       // 滚动速度（格/秒）
uniform float wobble = 0.65;                     // 噪声啃噬边缘的幅度 0..1
uniform float edge_soft = 0.30;                  // 虚化带宽（越窄边缘越硬）
uniform float shimmer = 0.08;                    // 水面微光强度

// ---------- 值噪声（零资产：hash + 双线性插值，两级 fbm 足够做边缘）----------
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	// 平滑插值权重，避免格点处出现菱形棱线
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm2(vec2 p) {
	return 0.65 * vnoise(p) + 0.35 * vnoise(p * 2.07 + vec2(19.19, 7.33));
}

void fragment() {
	// 世界像素 → 连续格坐标。宿主无旋转/缩放，故 VERTEX + 宿主原点 == 世界坐标。
	vec2 cell = (VERTEX + world_origin) / tile_px;
	vec2 cuv = cell / mask_size;
	if (cuv.x < 0.0 || cuv.x > 1.0 || cuv.y < 0.0 || cuv.y > 1.0) {
		discard;
	}

	// ① step 硬裁切：本格（格心取样，linear 在 texel 中心即该 texel 值）无水就丢弃。
	//    保证积水严格落在"逻辑水格"内，与 is_water_at 的查询结果一致 —— 不会出现
	//    "看着有水踩上去没水"或反之。
	float cellval = texture(cell_mask, (floor(cell) + 0.5) / mask_size).r;
	if (cellval < 0.5) {
		discard;
	}

	// ② 连续覆盖场：在**未 floor 的格坐标**上取样。linear 过滤把格级 0/1 掩码插值成
	//    0..1 的软场 —— 水格中心≈1、靠非水邻格的一侧边缘≈0.5，于是每个水格自然 dome
	//    出软边，成片积水的轮廓是圆的而不是阶梯方块。这是消除"半透明方块感"的关键。
	float m = texture(cell_mask, cuv).r;

	// ③ 内缩一层：8 邻全为水才算「内部」（core）。边缘带（水格但贴非水）留给噪声啃噬。
	//    本格格心 = fc+0.5；邻格格心 = fc+0.5+邻格偏移。偏移取 ±1（texel 整数倍）。
	vec2 cc = floor(cell) + 0.5;
	vec2 o = vec2(1.0, 1.0) / mask_size;
	float inset = cellval;
	inset *= texture(cell_mask, (cc + vec2(-o.x, -o.y))).r;   // 左上
	inset *= texture(cell_mask, (cc + vec2( 0.0, -o.y))).r;   // 上
	inset *= texture(cell_mask, (cc + vec2( o.x, -o.y))).r;   // 右上
	inset *= texture(cell_mask, (cc + vec2(-o.x,  0.0))).r;   // 左
	inset *= texture(cell_mask, (cc + vec2( o.x,  0.0))).r;   // 右
	inset *= texture(cell_mask, (cc + vec2(-o.x,  o.y))).r;   // 左下
	inset *= texture(cell_mask, (cc + vec2( 0.0,  o.y))).r;   // 下
	inset *= texture(cell_mask, (cc + vec2( o.x,  o.y))).r;   // 右下
	float core = smoothstep(0.9, 1.0, inset);
	float edge = clamp(1.0 - core, 0.0, 1.0);

	// ④ 滚动噪声边缘虚化：边缘带的 alpha 被随 TIME 流动的 fbm 啃噬（wobble 控制幅度）
	float n = fbm2(cell * noise_scale + TIME * scroll_dir);
	float gate = smoothstep(0.5 - edge_soft, 0.5 + edge_soft, mix(0.5, n, clamp(wobble, 0.0, 1.0)));
	// 覆盖场 m 提供软轮廓，(core + edge*gate) 让边缘随噪声参差；两者相乘
	float a = m * (core + edge * gate) * water_color.a;

	// ⑤ 微光：反向滚动的高频 fbm 做亮暗（第二阶段换成 screen_texture 采样即得折射）
	float s = fbm2(cell * noise_scale * 3.0 - TIME * scroll_dir * 1.7);
	vec3 rgb = water_color.rgb * (1.0 + shimmer * (s - 0.5) * 2.0);

	COLOR = vec4(rgb, clamp(a, 0.0, 1.0));
}

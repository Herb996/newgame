shader_type canvas_item;

// ============================================================
// puddle.gdshader — 局内积水（WeatherSystem 生成，见 Scripts/weather_system.gd）
//
// 宿主是一个覆盖全图的 ColorRect（尺寸 = 地图格数 × tile_px，位置 = 地图原点）。
// 选 ColorRect 而不是 Sprite2D：它的 VERTEX 天然就是像素坐标、visibility_rect
// 自动按 size 算；换成 1×1 纹理的 Sprite2D 会被默认 visibility_rect 整层裁掉，
// 症状是「积水完全不显示」，白折腾。
//
// 形状全部由 shader 生成，宿主纹理是 1×1 白点，零美术资产依赖。
// 五步走：
//   ① step 裁切   —— cell_mask 非水格整片 discard，积水轮廓严格贴格
//   ② 内缩一层    —— 8 邻取样近似「腐蚀 1 格」，得到水体内部
//   ③ 边缘虚化    —— 边缘带的 alpha 由随 TIME 滚动的 fbm 决定
//   ⑤ 倒影合成    —— 半分辨率倒影视口纹理（天空渐变 + MultiMesh 树/石倒影），
//                     红绿蓝图散采样 + 噪波晃动 + 噪波灰度调反射强度
//   ⑥ 折射/波纹   —— hint_screen_texture 屏幕内容按噪波偏移采样（折射扭曲），
//                     波纹视口纹理通道拆分（r=亮度基提亮，g=色散量驱动色散）
//
// 性能铁律：所有重采样（screen_tex / reflection_tex / ripple_tex）都在
// cellval < 0.5 discard **之后** —— 本层覆盖全图 8192×8192，顺序错了全图每像素付代价。
//
// 数值来源：Data/config.json 的 weather.puddle / reflection / refraction / ripple
//（脚本侧统一 set_shader_parameter，脚本零硬编码）。
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

// ---------- 阶段二：倒影 / 折射 / 波纹 ----------
// 屏幕纹理：Godot 4 canvas_item 需显式声明 hint_screen_texture 后采样（非内置 SCREEN_TEXTURE）。
// 已知偏差：puddle 绘制在 DecorLayer 之前，屏上只有地形层 —— 折射底不含树/石，可接受。
uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
// 倒影视口纹理（半分辨率 SubViewport，相机负 zoom.y 垂直镜像；UV 与 SCREEN_UV 逐点对应）。
// repeat_disable 防 ±off 色散偏移出界回绕。
uniform sampler2D reflection_tex : filter_linear, repeat_disable;
// 波纹视口纹理：r=亮度基（提亮），g=色散量（驱动色散偏移）。
uniform sampler2D ripple_tex : filter_linear, repeat_disable;
uniform float reflection_alpha = 0.55;    // 反射基准强度（噪波灰度再调制）
uniform float wobble_scale = 0.12;        // 扰动噪声频率
uniform float wobble_speed = 0.8;         // 扰动滚动速度
uniform float wobble_strength = 0.012;    // 扰动 UV 偏移幅度
uniform float dispersion = 0.015;         // 波纹处红/绿蓝通道分离幅度
uniform float refraction_strength = 0.008;// 折射对屏幕采样的偏移幅度
uniform float reflection_blend = 0.65;    // 倒影合成结果与水色的混合比
uniform float ripple_glow = 0.35;         // 波纹亮度增益
uniform vec4 ripple_tint : source_color = vec4(0.75, 0.89, 1.0, 1.0);

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

	// ========== ⑤⑥ 倒影 / 折射 / 波纹（全部重采样都在 discard 之后）==========
	vec2 suv = SCREEN_UV;
	float t = TIME;

	// 噪波扰动场：双通道错相滚动 —— 驱动倒影晃动与折射扭曲的公共源
	vec2 wob = vec2(vnoise(cell * wobble_scale + vec2(0.0, t * wobble_speed)),
			vnoise(cell * wobble_scale + vec2(9.17, t * wobble_speed * 0.7)));
	wob = (wob - 0.5) * wobble_strength * 4.0;

	// 波纹通道拆分：r=亮度基、g=色散量（weather_system._ripple_color 编码）
	vec2 rp = texture(ripple_tex, suv).rg;

	// 倒影实例已在 CPU 侧绕各自底边镜像挂好（_build_reflection），视口正立渲染，
	// 这里按 SCREEN_UV 直接采样即与屏幕逐点对齐 —— 水在哪，倒影就在哪。
	// 色散：波纹越强红/绿蓝分离越大；wob 提供基础晃动
	vec2 off = normalize(vec2(0.35, 0.85) + wob * 0.2) * (rp.g * 2.0 - 1.0) * dispersion + wob;
	vec3 refl;
	refl.r = texture(reflection_tex, suv + off).r;    // 红通道 +off
	refl.gb = texture(reflection_tex, suv - off).gb;  // 绿蓝 −off

	// 反射强度：噪波灰度调制 —— 水波起伏处倒影更亮（模拟波面把天光聚过来）
	float refl_a = clamp(reflection_alpha * (0.5 + 0.5 * fbm2(cell * noise_scale + t * scroll_dir)), 0.0, 1.0);

	// 折射：屏幕已绘制内容按噪波偏移采样，水下地形随波扭动
	vec3 refr = texture(screen_tex, suv + wob * refraction_strength).rgb;

	// 合成：折射底 → 混倒影 → 加波纹提亮 → 与水色调和
	vec3 rgb = mix(refr, refl, refl_a);
	rgb += rp.r * ripple_glow * ripple_tint.rgb;
	rgb = mix(water_color.rgb, rgb, reflection_blend);

	COLOR = vec4(rgb, clamp(a, 0.0, 1.0));
}

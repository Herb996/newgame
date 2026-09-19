shader_type canvas_item;

// ============================================================
// rain_ground.gdshader — 局内「雨湿地面」层（WeatherSystem 生成，见 Scripts/weather_system.gd）
//
// 命名：这**不是第 5 个群系**。项目只有草地/森林/荒原/沼泽四种，本层画的是
// "被雨打湿的草地/森林地板"这个天气状态，雨停就该整片消失。
//
// 取代旧的 puddle.gdshader。用户裁定（2026-09-19）：**没有"水洼"这个概念**——
// 下雨时草地/森林整片地面都是湿的，踩上去就出波纹；荒原/沼泽本就不积水。
// 所以这里不再画"一块水面"：不折射、不倒影、不水色，只做三件事
//   ① 湿度场采样 —— wet_mask 是 CPU 侧按群系烘焙并模糊过的连续 0..1 场，
//                    linear 插值 + 域扭曲 → 干湿边界是一条揉弯的软带而非格网阶梯
//   ② 湿面外观 —— 把底下的地形内容**压暗 + 偏冷 + 轻微反光斑驳**
//   ③ 波纹合成 —— 波纹视口纹理按覆盖度门控提亮（唯一保留的水反馈）
//
// 宿主是覆盖全图的 ColorRect（尺寸 = 地图格数 × tile_px，位置 = 地图原点）。
// 选 ColorRect 而不是 Sprite2D：visibility_rect 自动按 size 算；1×1 纹理的 Sprite2D
// 会被默认 visibility_rect 整层裁成"什么都不显示"。
//
// 格坐标一律由 **UV** 推出，不用 VERTEX：宿主矩形按定义就是整张地图，故 UV 的
// 0..1 精确等于掩码的 0..mask_size，与画布变换和 VERTEX 在各宿主下的语义无关。
// 这层必须与地形严格同源对齐——一旦错位，就成"一层独立的水膜盖在地图上"，
// 镜头一动就像在飘（用户 2026-09-19 报的现象）。
//
// 性能铁律：屏幕采样与波纹采样都在 `m < 0.02 → discard` **之后** —— 本层覆盖全图
// 8192×16384，顺序错了就是全图每像素一次屏幕读回。discard 之前只剩域扭曲那 2 次
// vnoise（它改的是采样坐标，必须在读掩码之前，挪后就揉不出形状了）。
//
// 注意：canvas_item 的 fragment() 里**不能写 return**（4.x 编译失败 → 整层变白块）。
// ============================================================

// R 通道 = 该格湿度（连续 0..1，场外为 0）。尺寸 = 地图格数，与逻辑查询用的
// _wet_cells 同源，保证"看着是湿地"和"踩上去出波纹"不漂移。
uniform sampler2D wet_mask : filter_linear;
uniform vec2 mask_size = vec2(128.0, 256.0);    // 地图格数 = 掩码尺寸

uniform float darkness = 0.12;          // 湿地压暗幅度（0..1）
uniform vec4 tint_color : source_color = vec4(0.62, 0.76, 0.86, 1.0);
uniform float tint_amount = 0.18;       // 偏冷强度
uniform float sheen = 0.10;             // 湿面反光的斑驳亮度
uniform float noise_scale = 0.06;       // 斑驳噪声频率（按格坐标）
uniform vec2 scroll_dir = vec2(0.0, 0.0);   // 流速（格/秒）——非零会把明暗从地面上拖过去
uniform float wet_alpha = 0.9;          // 满湿处的层不透明度
uniform float edge_soft = 0.45;         // 覆盖场爬到满 alpha 的宽度
uniform float edge_warp = 0.9;          // 干湿边界揉弯幅度（单位：格）
uniform float edge_warp_scale = 0.16;   // 揉弯噪声频率（每格）

// ---- ④ 斑驳水光（用户："地面看不出湿"）：亮斑与暗斑成对的碎光条带 ----
// 频率别退回 0.1 量级：斑幅 3~9 格＝屏上 150~300px 的软团，读成雾团/云影而不是水光。
uniform float mottle_amount = 1.0;              // 0=整层关闭（截图二分用）
uniform float mottle_scale = 2.2;               // 斑带噪声频率（每格）
uniform vec2 mottle_stretch = vec2(0.8, 1.4);   // 各向异性：x 低频=横拉长，y 高频=条带窄
uniform vec2 mottle_speed = vec2(0.0, 0.0);   // 水光流速（格/秒）：0＝亮斑钉在地面上
uniform float mottle_threshold = 0.74;          // 亮/暗分界的场值
uniform float mottle_soft = 0.06;               // 两侧过渡宽度
uniform float mottle_gain = 0.35;               // 亮斑把草色换成天光的混合强度（0..1）
uniform float mottle_dark = 0.12;               // 配对暗斑压暗量
// 亮斑色要**深一档的蓝**，不是近白：#cce6f5 + gain 0.5 放大看是一堆粉笔团/棉絮。
uniform vec3 mottle_color : source_color = vec3(0.498, 0.659, 0.80);

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
// 波纹视口纹理：r=亮度基（提亮），g=色散量（此处只做波纹处的额外晃动幅度）。
uniform sampler2D ripple_tex : filter_linear, repeat_disable;
uniform float ripple_glow = 1.0;
uniform vec4 ripple_tint : source_color = vec4(0.62, 0.82, 0.91, 1.0);
uniform float ripple_wiggle = 0.003;    // 波纹让湿地反光偏移的量级（屏幕 UV）

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
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

// 掩码手动双线性插值。掩码只有一格一纹素（128×256），一旦被最近邻取样的，
// 干湿边界就会露出 64px 的格网台阶。uniform 上虽写了 filter_linear，但最终
// 取值还受宿主 texture_filter / 项目默认值 / 驱动对 RF 浮点图的支持三层影响，
// 都不由我们保证。于是自己按纹素中心取 4 抽头再插——任何过滤模式下结果一致
// （线性采样在纹素中心处权重恰好全落在该纹素上）。
float wet_at(vec2 cuv) {
	vec2 tc = clamp(cuv, vec2(0.0), vec2(1.0)) * mask_size - vec2(0.5);
	vec2 g = floor(tc);
	vec2 fr = tc - g;
	vec2 lo = max(g, vec2(0.0));
	vec2 hi = min(g + vec2(1.0), mask_size);
	float x0 = (lo.x + 0.5) / mask_size.x;
	float x1 = (hi.x + 0.5) / mask_size.x;
	float y0 = (lo.y + 0.5) / mask_size.y;
	float y1 = (hi.y + 0.5) / mask_size.y;
	float a = mix(texture(wet_mask, vec2(x0, y0)).r, texture(wet_mask, vec2(x1, y0)).r, fr.x);
	float b = mix(texture(wet_mask, vec2(x0, y1)).r, texture(wet_mask, vec2(x1, y1)).r, fr.x);
	return mix(a, b, fr.y);
}

void fragment() {
	// 宿主矩形 ≡ 地图矩形，故 UV 直接就是归一化格坐标；乘 mask_size 得连续格坐标。
	vec2 cell = UV * mask_size;

	// ① 连续湿度场。掩码已经是 CPU 模糊过的软场，但仍按格存储 → 直接用 linear 插值
	//    会得到沿格轴线的直边界。用静态低频噪声把采样点最多挪 edge_warp 格，整条
	//    过渡带随之揉弯，弯曲尺度由 edge_warp_scale 决定，与格网彻底解耦。
	//    静态（不含 TIME）是有意的：干湿边界应当固定，会动的只有反光斑驳。
	vec2 warp_uv = (vec2(vnoise(cell * edge_warp_scale),
			vnoise(cell * edge_warp_scale + vec2(31.7, 11.3))) - 0.5) * (2.0 * edge_warp / mask_size);
	float m = wet_at(UV + warp_uv);

	// ② 干地整片 discard（荒原/沼泽/室内不留这一层）。
	if (m < 0.02) {
		discard;
	}

	// ③ 覆盖度：edge_soft 控制从干到湿爬多快；斑驳噪声调制边缘，
	//    使干湿过渡不是等值线而是被啃过的毛边。
	float n = fbm2(cell * noise_scale + TIME * scroll_dir);
	float gnaw = mix(1.0, 0.35 + 1.3 * n, 0.6 * (1.0 - m));
	float cov = smoothstep(0.0, clamp(edge_soft, 0.05, 1.0), m * gnaw);

	// ---- 以下重采样全在 discard 之后 ----
	vec2 suv = SCREEN_UV;
	vec2 rp = texture(ripple_tex, suv).rg;

	// 反光晃动：湿地表面的偏移量由噪声给出，波纹经过处（rp.g=色散量）额外晃动。
	vec2 wob = (vec2(vnoise(cell * noise_scale * 1.7 + vec2(0.0, TIME * scroll_dir.y)),
			vnoise(cell * noise_scale * 1.7 + vec2(9.17, TIME * scroll_dir.x * 0.7))) - 0.5);
	wob *= ripple_wiggle * (0.3 + rp.g * 3.0);
	vec3 base = texture(screen_tex, suv + wob).rgb;

	// ④ 斑驳水光场：两层噪声（粗条带 + 细碎光）混合后按阈值劈成**亮斑/暗斑一对**。
	//    成对是关键——只加亮斑会糊成一块块奶白膜（读成油渍/雪堆），亮旁边紧贴着
	//    一条暗边才有"水膜反着天光、地面起伏"的立体读法。各向异性拉伸（x 低频、
	//    y 高频）把等方噪声拉成横向条带：等方频率在这里只会均匀糊掉，看不出"水"。
	vec2 mc = cell * mottle_scale * mottle_stretch;
	float mb = fbm2(mc + TIME * mottle_speed);
	float mf = fbm2(mc * 2.9 + TIME * mottle_speed * 2.3 + vec2(37.1, 5.7));
	float mfield = mb * 0.74 + mf * 0.26;
	float glint = smoothstep(mottle_threshold, mottle_threshold + mottle_soft, mfield)
			* mottle_amount * cov;
	float shade = (1.0 - smoothstep(mottle_threshold - mottle_soft, mottle_threshold, mfield))
			* mottle_amount * cov;

	// 湿地外观 = 原地形压暗 → 混入冷色 → 叠一层缓慢滚动的斑驳反光
	vec3 wet = base * (1.0 - darkness * cov);
	wet = mix(wet, wet * tint_color.rgb, clamp(tint_amount * cov, 0.0, 1.0));
	wet *= 1.0 - mottle_dark * shade;
	// 亮斑**不是**往草地上加白：橄榄绿 + 白 = 更亮的橄榄绿，读成苔藓斑（实测就是这样）。
	// 湿面反的是整片阴天，所以亮斑要把草色**换成**冷调天光。乘本地亮度是为了让树荫下
	// 的湿地也跟着暗——否则反光会穿过阴影自己发光。
	float luma = dot(base, vec3(0.299, 0.587, 0.114));
	wet = mix(wet, mottle_color * (0.45 + 0.75 * luma), clamp(mottle_gain * glint, 0.0, 1.0));
	wet += sheen * (n - 0.5) * 2.0 * cov;
	// 波纹亮度按 cov 门控：浅湿边缘的环应当跟着淡出，否则会显示成
	// "干草地上画了个白圈"（用户反馈的丑感来源）。
	wet += rp.r * ripple_glow * ripple_tint.rgb * cov;

	COLOR = vec4(wet, clamp(cov * wet_alpha, 0.0, 1.0));
}

extends Node2D
## ============================================================
## UnitLevelBadge — 绕角色飞的一缕淡光（等级显示，2026-09-18 三次改版）
##
## 演变史（前两版都被判「丑」，根因逐次挖深）：
##   ① 「半透明黑圈 + 白数字」→ 违和：矢量字压像素画、尺寸随 zoom 变、形态像工牌。
##   ② 「绕角色漂移的卡通糖果球」→ 仍丑：**画成了实体**。细描边定形 + 球冠亮面
##      + 底部薄影，越是「画得完整」越像一颗真球挂在人身上。
##   ③ 本版：**删掉一切轮廓**。光不该有边界，只该是几层同心柔光从内到外化开
##      （`glow.layers`：外大而极淡、内小而亮），颜色朝白推淡、整体压在半透明。
##      于是它不再是一个「东西」，而是点在角色身边忽明忽暗飘着的一缕光。
##      每层是**软边光斑**（运行时生成的径向渐变贴图，见 `_ensure_glow_tex`），
##      不是实心圆 —— 实心圆叠起来放大能数出一圈圈同心环、像个靶子（实拍抓出来的）。
##
## 四条行为约定（照用户的四条原话走）：
##   ① **时隐时现** —— `pulse_visibility()` 把两条**不同周期**的正弦叠加，明暗节奏
##      因此不规律（不是呼吸灯那种匀速明灭）。clamp 到 [0,1] 后两端都有平台，
##      即真的会完全隐没、也真的会完全显现。`pulse_power > 1` 让暗的时间更长。
##   ② **时快时慢** —— `orbit_angle()` 的角速度 = spin_speed + 两条正弦的导数，
##      快慢交替（ω ∈ [0.40, 2.00]，差 5 倍）。⚠ **约束：两条 sway 项之和必须 <
##      spin_speed**，否则 ω 变负 → 光点原地掉头，看着像故障。探针 K 段数值微分守它。
##   ③ **颜色尽量淡** —— `glow_color()` 把档位色朝白 lerp `tint_white`，再乘 `max_alpha`
##      （<1 才有「虚」的质感）。档位区分度因此变弱 —— 这是刻意的取舍：谁是我方靠
##      选中框 / 小地图点（恒阵营蓝），档位靠身上甲色，光点只管「这人在哪」。
##   ④ **绕着角色四周飞** —— `center_offset_y` 落在**身体中部**（不再是头顶 -56），
##      `orbit_y_scale` 接近 1 让纵向跨度够大：光点会掠过头顶、腰侧、腿边。
##   ⑤ **越吵飞得越急**（2026-09-18 追加）：`noise_speed()` 读**所属角色**的自身噪音
##      （noise.self，菜单右下第 1 行），把**整条时间轴**乘一个 1~3 倍的系数 ——
##      移动、明灭、报数的频率一起变快，且相位连续看不出是被调快了。
##
## 保留的旧机制（都有探针守着，别顺手删）：
##   `screen_fixed` 屏幕恒定尺寸（1/zoom）、`far_fade` 视野拉远淡出、
##   `flash` 每 5~9s 闪一次报数字（点选 / 升级立刻闪）。**flash 期间可见度强制拉满**
##   —— 否则光点正好处在「隐」的时刻，闪了也白闪。
##
## ⚠ 数字只画 0~9（progression.max_level）。
## ⚠ 每帧 `queue_redraw`（光在动）→ `enabled=false` 时必须 `set_process(false)`。
## ⚠ 无头探针里 `get_camera_2d()` 可能返回 null → `_zoom` 回落 1.0，也要能工作。
## ============================================================

const GLOW_TEX_SIZE := 48             # 光斑贴图边长（够用即可，肉眼分不出更大的）

var level: int = 0
var tier_id: String = "blue"

# --- 轨道（progression.badge.orb）---
var _enabled: bool = true
var _radius: float = 7.0              # 光核半径（**屏幕**像素）
var _screen_fixed: bool = true
var _orbit_r_lo: float = 20.0
var _orbit_r_hi: float = 31.0
var _orbit_y_scale: float = 0.85
var _spin: float = 1.2
var _sway: float = 0.5
var _sway_hz: float = 0.13
var _sway2: float = 0.2
var _sway_hz2: float = 0.31
var _wobble: float = 3.0
# --- 淡光外观（progression.badge.orb.glow）---
var _tint_white: float = 0.55
var _max_alpha: float = 0.8
var _core_whiten: float = 0.5
var _falloff: float = 2.2             # 光斑贴图的径向衰减指数
var _layers: Array = []               # [[半径比例, 不透明度比例], ...] —— 从外到内
var _pulse_p := Vector2(3.4, 2.1)     # 时隐时现的两条周期（秒）
var _pulse_power: float = 1.5
var _min_scale: float = 0.75
# --- 闪烁报数（progression.badge.flash）---
var _flash_interval := Vector2(5.0, 9.0)
var _first_delay: float = 1.5
var _flash_scale: float = 2.0
var _rise: float = 0.15
var _hold: float = 0.7
var _fade: float = 0.35
var _text_size: float = 14.0
var _text_outline := Color("#2B2A3A")
var _on_select: bool = true
var _on_level_up: bool = true
# --- 视野（progression.badge.far_fade）---
var _fade_start_zoom: float = 0.95
var _fade_end_zoom: float = 0.7
var _radius_max_world: float = 10.0   # 兜底：极端视野下的**世界**半径上限
# --- 跟着自身噪音提速（progression.badge.noise_link，2026-09-18）---
var _link_on: bool = true
var _link_ref: float = 240.0
var _link_max: float = 3.0
var _link_curve: float = 1.4
var _link_boost_flash: bool = true

# --- 运行时 ---
var _t: float = 0.0                   # 相位（累计秒）
var _phase: float = 0.0               # 本单位的随机相位（多个单位错开，不会齐刷刷明灭）
var _flash_t: float = -1.0            # <0 = 没在闪；否则 = 已闪时长
var _next_flash: float = 0.0          # 距下次自动闪的秒数
var _zoom: float = 1.0
var _alpha: float = 1.0               # 视野淡出系数（**不含** glow.max_alpha 与明灭）
## 光斑贴图（白，中心 alpha=1 → 边缘 0）。**static**：全场光点共用一张、只生成一次
## （48×48 = 2304 次 set_pixel），小队 4 人也只花一次。`_glow_tex_falloff` 记着它
## 是按哪个 falloff 生成的，配置改了自动重做。
static var _glow_tex: ImageTexture = null
static var _glow_tex_falloff: float = -1.0
## 探针钩子：>0 时替代真实相机 zoom（headless 里往往没有 Camera2D，读不到倍率，
## 而「屏幕恒定尺寸 / 缩远淡出」全靠 zoom）。设了记得还原成 0.0。
var zoom_override: float = 0.0
## 探针钩子：>= 0 时替代「所属角色的自身噪音」（headless 里没法真让角色攻一次击
## 来攒够一段噪音，注入一个读数就能验「噪音越大越快」这条联动）。默认 -1 = 读真的。
var noise_override: float = -1.0


func _ready() -> void:
	z_index = 6          # 盖住角色（z=1）和雾（z=5），别被雾吃掉了
	# 光斑必须插值采样：NEAREST（像素画那套）会把软边切成硬块，白做。
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_phase = randf() * TAU
	_apply_cfg()
	_flash_t = -1.0
	_next_flash = _first_delay * randf_range(0.8, 1.2)   # 谁先闪也别整齐划一
	set_process(_enabled)


func _apply_cfg() -> void:
	_enabled = bool(Config.get_value("progression.badge.enabled", true))
	_radius = maxf(1.0, float(Config.get_value("progression.badge.orb.radius_px", 7.0)))
	_screen_fixed = bool(Config.get_value("progression.badge.orb.screen_fixed", true))
	var oy: float = float(Config.get_value("progression.badge.orb.center_offset_y", -32.0))
	var rx: Array = Config.get_value("progression.badge.orb.orbit_radius_px", [20.0, 31.0])
	_orbit_r_lo = maxf(0.0, float(rx[0])) if rx.size() > 0 else 20.0
	_orbit_r_hi = maxf(_orbit_r_lo, float(rx[1])) if rx.size() > 1 else _orbit_r_lo
	_orbit_y_scale = clampf(
			float(Config.get_value("progression.badge.orb.orbit_y_scale", 0.85)), 0.0, 1.0)
	_spin = maxf(0.0, float(Config.get_value("progression.badge.orb.spin_speed", 1.2)))
	_sway = maxf(0.0, float(Config.get_value("progression.badge.orb.speed_sway", 0.5)))
	_sway_hz = maxf(0.0, float(Config.get_value("progression.badge.orb.speed_sway_hz", 0.13)))
	_sway2 = maxf(0.0, float(Config.get_value("progression.badge.orb.speed_sway2", 0.2)))
	_sway_hz2 = maxf(0.0, float(Config.get_value("progression.badge.orb.speed_sway_hz2", 0.31)))
	_wobble = maxf(0.0, float(Config.get_value("progression.badge.orb.wobble_px", 3.0)))
	_tint_white = clampf(
			float(Config.get_value("progression.badge.orb.glow.tint_white", 0.55)), 0.0, 1.0)
	_max_alpha = clampf(
			float(Config.get_value("progression.badge.orb.glow.max_alpha", 0.8)), 0.05, 1.0)
	_core_whiten = clampf(
			float(Config.get_value("progression.badge.orb.glow.core_whiten", 0.5)), 0.0, 1.0)
	_falloff = clampf(
			float(Config.get_value("progression.badge.orb.glow.falloff", 2.2)), 0.2, 8.0)
	_layers = _parse_layers(Config.get_value("progression.badge.orb.glow.layers", []))
	var ps: Array = Config.get_value("progression.badge.orb.glow.pulse_seconds", [3.4, 2.1])
	var p0: float = maxf(0.2, float(ps[0])) if ps.size() > 0 else 3.4
	var p1: float = maxf(0.2, float(ps[1])) if ps.size() > 1 else 2.1
	_pulse_p = Vector2(p0, p1)
	_pulse_power = maxf(0.1, float(Config.get_value("progression.badge.orb.glow.pulse_power", 1.5)))
	_min_scale = clampf(
			float(Config.get_value("progression.badge.orb.glow.min_scale", 0.75)), 0.05, 1.0)
	var iv: Array = Config.get_value("progression.badge.flash.interval", [5.0, 9.0])
	var lo: float = maxf(0.2, float(iv[0])) if iv.size() > 0 else 5.0
	var hi: float = maxf(lo, float(iv[1])) if iv.size() > 1 else lo
	_flash_interval = Vector2(lo, hi)
	_first_delay = maxf(0.0, float(Config.get_value("progression.badge.flash.first_delay", 1.5)))
	_flash_scale = maxf(1.0, float(Config.get_value("progression.badge.flash.scale", 2.0)))
	_rise = maxf(0.01, float(Config.get_value("progression.badge.flash.rise", 0.15)))
	_hold = maxf(0.0, float(Config.get_value("progression.badge.flash.hold", 0.7)))
	_fade = maxf(0.0, float(Config.get_value("progression.badge.flash.fade", 0.35)))
	_text_size = maxf(6.0, float(Config.get_value("progression.badge.flash.text_size", 14.0)))
	_text_outline = Color(str(Config.get_value(
			"progression.badge.flash.text_outline_color", "#2B2A3A")))
	_on_select = bool(Config.get_value("progression.badge.flash.on_select", true))
	_on_level_up = bool(Config.get_value("progression.badge.flash.on_level_up", true))
	_fade_start_zoom = float(Config.get_value("progression.badge.far_fade.start_zoom", 0.95))
	_fade_end_zoom = float(Config.get_value("progression.badge.far_fade.end_zoom", 0.7))
	_link_on = bool(Config.get_value("progression.badge.noise_link.enabled", true))
	_link_ref = maxf(1.0, float(Config.get_value(
			"progression.badge.noise_link.reference", 240.0)))
	_link_max = maxf(1.0, float(Config.get_value(
			"progression.badge.noise_link.max_speed_multiplier", 3.0)))
	_link_curve = maxf(0.05, float(Config.get_value(
			"progression.badge.noise_link.curve", 1.4)))
	_link_boost_flash = bool(Config.get_value(
			"progression.badge.noise_link.boost_flash", true))
	# 世界半径上限（最后一道保险）：极端视野下别让光点长得比轨道还大、糊满角色。
	# ⚠ 别收到 `_orbit_r_lo * 0.5` 这种量级 —— 那样在 zoom 0.8 这种**正常视野**就会撞上限，
	# 把「屏幕恒定尺寸」这条更重要的观感特性打掉（探针 F 段抓到过一次）。
	# 再说极端视野本来就有 far_fade 兜着（zoom < end_zoom 时 alpha = 0，根本不画）。
	_radius_max_world = maxf(_radius, _orbit_r_hi)
	position = Vector2(0.0, oy)          # 节点原点 = 轨道中心（角色身体中部）
	_ensure_glow_tex()
	set_process(_enabled)


## 造那张径向渐变光斑贴图（白色，中心不透明 → 边缘完全透明）。
## `falloff` 越大大中心越集中、边缘散得越快。**不做实心圆** ——
## 实心圆叠起来每层边界都是硬边，放大能数出一圈圈同心环（像靶子）。
func _ensure_glow_tex() -> void:
	if _glow_tex != null and absf(_glow_tex_falloff - _falloff) < 0.001:
		return
	var n := GLOW_TEX_SIZE
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var cc := float(n) * 0.5
	for y in range(n):
		for x in range(n):
			var d := Vector2(float(x) + 0.5 - cc, float(y) + 0.5 - cc).length() / cc
			var av := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, pow(av, _falloff)))
	_glow_tex = ImageTexture.create_from_image(img)
	_glow_tex_falloff = _falloff


## layers 解析：`[[ratio, alpha], ...]`。ratio 限 (0, 2]（允许 > 1：光晕比光核大）、
## alpha 限 [0,1]。**不排序、不补层** —— 写反了（ratio 递增 / alpha 递减）要能被探针
## 抓到，别悄悄修正。
func _parse_layers(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for it in v:
			if it is Array and (it as Array).size() >= 2:
				out.append([
					clampf(float(it[0]), 0.02, 2.0),
					clampf(float(it[1]), 0.0, 1.0),
				])
	if out.is_empty():
		# 配置缺失时的兜底（保持和 config 默认一致，免得静默变成一团实心）
		out = [[1.35, 0.10], [1.0, 0.16], [0.68, 0.3], [0.4, 0.9]]
	return out


## 由 player 在等级 / 档位变化时调用。等级真的变了才闪（首次 setup 传 0 级不会闪）。
func refresh(lv: int, tier: String) -> void:
	var v: int = clampi(lv, 0, 9)
	var changed := v != level
	level = v
	tier_id = tier if tier != "" else "blue"
	_apply_cfg()
	if changed and _on_level_up:
		flash()
	queue_redraw()


## 让光点立刻闪一次（报出等级）。归零计时器，免得刚闪完又自动闪。
func flash() -> void:
	if not _enabled:
		return
	_flash_t = 0.0
	_schedule_next()


## player 点选本角色时调用 —— 这是「不常驻数字」的补偿：想知道就能立刻知道。
func notify_selected() -> void:
	if _on_select:
		flash()


func is_flashing() -> bool:
	return _flash_t >= 0.0


## 视野淡出系数（0~1）。探针 F 段测「缩远淡出」读的就是它。
func view_alpha() -> float:
	return _alpha


## 最终绘制不透明度（0~1）= 视野淡出 × glow 上限 × 当前明灭。
func current_alpha() -> float:
	return _alpha * _max_alpha * visibility()


func _schedule_next() -> void:
	_next_flash = randf_range(_flash_interval.x, _flash_interval.y)


func _flash_total() -> float:
	return _rise + _hold + _fade


## 闪烁强度 0~1（升 → 满 → 降），胀大与数字显隐都读它。
func _flash_amount() -> float:
	if _flash_t < 0.0:
		return 0.0
	var t := _flash_t
	if t < _rise:
		return t / _rise
	t -= _rise
	if t < _hold:
		return 1.0
	t -= _hold
	if t < _fade:
		return 1.0 - t / _fade
	return 0.0


func _process(delta: float) -> void:
	var sp := noise_speed()
	# 【整条时间轴 × sp】而不是分别给每条曲线各自乘频率。
	# orbit_angle / pulse_visibility / wobble 全读同一个 `_t`，所以 `-=加速` 是**相位连续**
	# 的：不会有哪一帧突然跳到新相位。分别乘则三者会互相错位、表现为光点「抖一下」。
	_t += delta * sp
	_update_view()
	if _flash_t >= 0.0:
		# ⚠ 单次时长**不跟着加速**：那 1.2 秒是为了让球心的数字能被读出来，
		# 压到 0.4 秒就是「一闪而过」，等于没报。加速只体现在**多久闪一次**上。
		_flash_t += delta
		if _flash_t >= _flash_total():
			_flash_t = -1.0
			_schedule_next()
	else:
		_next_flash -= delta * (sp if _link_boost_flash else 1.0)
		if _next_flash <= 0.0:
			flash()
	queue_redraw()


# ------------------------------------------------------------
# 跟着自身噪音提速（noise.self → 移动越快 / 闪得越勤）
# ------------------------------------------------------------

## 自己这个角色的**自身噪音**（noise.self）。光点在 `Scenes/Player.tscn` 里是 Player 的
## 直接子节点，取 `get_parent()` 最直接；组筛查只是给手工搭出来的 Dev 场景（展示场景里
## 光球挂在裸 Node2D 下）一条回落，不会误抓到别人。
func owner_self_noise() -> float:
	if noise_override >= 0.0:
		return noise_override           # 探针钩子：headless 里没法真去攻一次击
	var p := get_parent()
	if p == null:
		return 0.0
	var raw = p.get("self_noise")
	return float(raw) if raw != null else 0.0


## 时间轴倍速 1~max倍（value 1.0 = 完全安静，无心 reactors）。
## `curve > 1` → 小噪音（脚步 22）几乎不提速，只有真吵起来（120+）才明显；
## 写成线性（curve = 1）的话，光点会被呼吸般的脚步声拽得一跳一跳，很烦躁。
func noise_speed() -> float:
	if not _link_on:
		return 1.0
	var n := clampf(owner_self_noise() / _link_ref, 0.0, 1.0)
	return 1.0 + (_link_max - 1.0) * pow(n, _link_curve)


## 取相机 zoom 算「屏幕恒定尺寸」和「缩远淡出」。无头 / 没相机时按 1.0 处理。
## `zoom_override > 0` 时优先用它（探针注入，headless 里读不到相机）。
func _update_view() -> void:
	var z := zoom_override
	if z <= 0.0:
		var cam := get_viewport().get_camera_2d()
		z = cam.zoom.x if cam != null else 1.0
	_zoom = z if z > 0.0001 else 1.0
	if _fade_start_zoom > _fade_end_zoom:
		_alpha = clampf(
				(_zoom - _fade_end_zoom) / (_fade_start_zoom - _fade_end_zoom), 0.0, 1.0)
	else:
		_alpha = 1.0


# ------------------------------------------------------------
# 飞舞：角度（时快时慢）+ 轨道偏移
# ------------------------------------------------------------

## 当前角度 = 匀速自转 + 两层正弦摆动。**导数就是角速度**：
##   ω(t) = spin + sway·2π·hz·cos(2π·hz·t + φ) + sway2·2π·hz2·cos(...)
## 两条频率不整除 → 快慢节奏本身也不规律。约束见文件头 ②。
func orbit_angle() -> float:
	var a := _t * _spin + _phase
	a += _sway * sin(TAU * _sway_hz * _t + _phase * 1.7)
	a += _sway2 * sin(TAU * _sway_hz2 * _t + _phase * 0.6)
	return a


## 光点相对轨道中心的偏移。**有界**：|offset| <= orbit_r_hi + wobble·√2（探针 C 段守它）。
func _orbit_offset() -> Vector2:
	var breathe := 0.5 + 0.5 * sin(_t * 0.37 + _phase * 1.7)
	var r := lerpf(_orbit_r_lo, _orbit_r_hi, breathe)
	var ang := orbit_angle()
	var o := Vector2(cos(ang) * r, sin(ang) * r * _orbit_y_scale)
	o += Vector2(sin(_t * 1.13 + _phase * 2.0), cos(_t * 1.71 + _phase)) * _wobble
	return o


# ------------------------------------------------------------
# 时隐时现
# ------------------------------------------------------------

## 明灭曲线 0~1。两条**不同周期**的正弦叠加 → 节奏不规律（不是呼吸灯）。
## 偏移量最大 0.62+0.28 = 0.90 > 0.5，所以 clamp 后**两端都有平台**：
## 真的会完全隐没（0）、也真的会完全显现（1）。
func pulse_visibility() -> float:
	var u := 0.5
	u += 0.62 * sin(TAU * _t / _pulse_p.x + _phase * 2.3)
	u += 0.28 * sin(TAU * _t / _pulse_p.y + _phase * 1.1)
	return pow(clampf(u, 0.0, 1.0), _pulse_power)


## 实际可见度 = max(明灭, 闪烁)。flash 期间拉满，否则光点恰在「隐」刻就白闪了。
func visibility() -> float:
	return maxf(pulse_visibility(), _flash_amount())


## 档位色朝白推淡（「颜色尽量淡」）。不带 alpha —— alpha 由 max_alpha 与明灭乘出来。
func glow_color() -> Color:
	return _tier_color().lerp(Color(1.0, 1.0, 1.0, 1.0), _tint_white)


## 那张光斑贴图。`_glow_tex` 是 **static**，外部 `get()` 读不到 static 变量，
## 所以开一个实例方法给探针 / 展示场景用。
func glow_texture() -> ImageTexture:
	return _glow_tex


## 当前该画的光核半径（**世界**单位）。公式只写这一份，_draw 也读它。
## 探针据此断言「屏幕恒定尺寸」：`drawn_radius_world() * zoom` 应恒等于 orb.radius_px
## （只有撞到 `_radius_max_world` 兜底上限时才退让）。
func drawn_radius_world() -> float:
	var inv := (1.0 / _zoom) if _screen_fixed else 1.0
	return minf(_radius * inv, _radius_max_world)


func _tier_color() -> Color:
	return Color(str(Config.get_value("progression.badge.colors.%s" % tier_id, "#378ADD")))


func _draw() -> void:
	if not _enabled:
		return
	var vis := visibility()
	var a := current_alpha()
	if a <= 0.003:
		return
	var inv := (1.0 / _zoom) if _screen_fixed else 1.0
	var rr := drawn_radius_world()
	var fat := _flash_amount()
	var c := _orbit_offset()
	var col := glow_color()
	# 大小跟着明灭走：亮时饱满、暗时收缩（像凑近又退远，而不是单纯调透明度）
	var r := rr * lerpf(_min_scale, 1.0, vis) * (1.0 + (_flash_scale - 1.0) * fat)
	# 同心柔光：外大而极淡、内小而亮。**一层描边都不画** ——
	# 有轮廓就成了物体，那就又回到「一颗球挂在人身上」的老路上（前两版的病根）。
	for layer in _layers:
		var ratio := float(layer[0])
		var la := float(layer[1])
		if la <= 0.001:
			continue
		# 越靠内核越白：光核该是暖白的，光晕才是档位色
		var lc := col.lerp(Color(1.0, 1.0, 1.0, 1.0), (1.0 - ratio) * _core_whiten)
		_draw_glow(c, maxf(0.5, r * ratio), Color(lc.r, lc.g, lc.b, a * la))
	if fat > 0.0:
		_draw_number(c, fat, a, inv)


## 画一枚软边光斑：把径向渐变贴图按 `rad` 缩放铺在 `c` 上，用 `tint` 染色。
## 一次性铺满一层而不是 `draw_circle` —— 后者的硬边会在多层叠加时暴露成同心环。
func _draw_glow(c: Vector2, rad: float, tint: Color) -> void:
	if tint.a <= 0.002:
		return
	draw_texture_rect(_glow_tex,
			Rect2(c - Vector2(rad, rad), Vector2(rad * 2.0, rad * 2.0)), false, tint)


## 光心的数字：深色描边 + 白填充（`draw_string_outline`），字号随光点一起胀大。
func _draw_number(c: Vector2, fat: float, a: float, inv: float) -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var s := str(level)
	var fs := int(round(_text_size * inv * (0.65 + 0.35 * fat)))
	if fs < 6:
		return
	var sz := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var pos := c + Vector2(-sz.x * 0.5, sz.y * 0.36)   # draw_string 原点是基线，往下偏一点
	var ow := int(maxf(1.0, round(2.0 * inv)))
	draw_string_outline(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ow,
			Color(_text_outline.r, _text_outline.g, _text_outline.b, a * fat))
	draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
			Color(1.0, 1.0, 1.0, a * fat))

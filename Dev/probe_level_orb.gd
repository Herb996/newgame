extends Node
## ============================================================
## probe_level_orb — 等级淡光（`Scripts/unit_level_badge.gd`，2026-09-18 三次改版）
##
## 形态演变：黑底圈+白数字 → 卡通糖果球 → **一缕绕角色飞的淡光**（当前）。
## 前两版的病根都是「画成了实体」（有轮廓、有亮面），本版删掉一切轮廓。
## 本探针守住新形态的几条不变量：
##   A) config 真值：光核半径 / screen_fixed / 轨道区间 / 闪烁区间 / 淡出区间 / 四档色
##   B) 节点接线：LevelBadge 在、节点原点 = 轨道中心、z_index = 6、公开接口齐全
##   C) **轨道有界**：采样 600 个时刻，光点永远落在 orbit_hi + wobble 之内，
##      且横向真的绕到两侧 —— 守的是「随机飞舞 ≠ 每帧 randf 飘走 / 抖成筛子」
##   D) 闪烁状态机：rise 升 → hold 满 → fade 降，到期收尾并重排下一次
##   E) 自动闪烁在 interval 内真的会发生（不是只有手动 flash 才有）
##   F) **屏幕恒定尺寸**：drawn_radius_world() × zoom 恒等于 radius_px；
##      极远视野撞世界上限时退让；far_fade 区间内亮度系数线性淡出、越界即 0
##   G) 事件联动：点选闪 / 升级闪 / 等级没变不闪 / 两个开关都能关掉
##   H) enabled=false 时停 _process（光点每帧 queue_redraw，不能空转）
##   I) **淡光长相**：「没有轮廓」是它的定义 —— 配置里不许再出现 orb.look
##      （描边/亮面/薄影，前两版的病根）；柔光层 ratio 递减 + alpha 递增；
##      颜色被朝白推淡（饱和度降）；max_alpha < 1（「虚」的质感）
##   J) **时隐时现**：明灭曲线采到底（min≈0 真的会隐、max≈1 真的会现、中间态是渐变），
##      且 flash 期间可见度被强制拉满（不会「闪在隐没里」）
##   K) **时快时慢**：角速度数值微分 —— 恒 > 0（绝不倒转，否则光点原地掉头像故障）
##      且 max/min 够大；并校验配置层面的数学前提「sway 项之和 < spin_speed」
##   L) **绕着四周飞**：轨道中心落在身体中部（不再是头顶）、实测纵向跨度够大、不钻地
##
## ⚠ 全程**手动步进** `_process(delta)`（先 `set_process(false)`）：headless 的真实帧率
##   不确定，等真实帧数验不了「闪 1.2 秒」这种时间语义。
## ⚠ `zoom_override` 是给本探针用的注入口（headless 里常没有 Camera2D），用完还原 0.0。
## ⚠ 会走一次 `_on_launch`（需要局内的 player），若名册为空 `ensure_roster()` 会写存档
##   → 开跑备份 `user://save.json`、收尾原样还原。
## ============================================================

const OUT := "user://_probe_level_orb.txt"
const SAVE_PATH := "user://save.json"

var _lines: Array = []
var _n := 0
var _fails: Array = []
var _main: Node = null
var _p: Node = null
var _badge: Node = null
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


## 手动按固定 delta 推进 total 秒，返回「处于闪烁中」的步数
func _step(badge: Node, total: float, delta := 0.05) -> int:
	var hits := 0
	var t := 0.0
	while t < total:
		badge.call("_process", delta)
		if bool(badge.call("is_flashing")):
			hits += 1
		t += delta
	return hits


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()
	var main: Node = load("res://Scenes/Main.tscn").instantiate()
	add_child(main)
	_main = main
	await _frames(30)
	await _a_config()
	await _b_node()
	if _badge == null:
		_finish()
		return
	await _c_orbit()
	await _d_flash()
	await _e_auto()
	await _f_scale_fade()
	await _g_events()
	await _h_disabled()
	await _i_look()
	await _j_pulse()
	await _k_speed()
	await _l_around()
	_finish()


# ------------------------------------------------------------
# A 段：config 真值
# ------------------------------------------------------------
func _a_config() -> void:
	_say("--- A 段：config 真值（progression.badge）---")
	_check(bool(Config.get_value("progression.badge.enabled", false)), "光点默认开启")
	_check(absf(float(Config.get_value("progression.badge.orb.radius_px", 0.0)) - 11.0) < 0.001,
			"光核半径 11（**屏幕像素**，不随视野变）")
	_check(bool(Config.get_value("progression.badge.orb.screen_fixed", false)),
			"screen_fixed = true")
	var orb: Array = Config.get_value("progression.badge.orb.orbit_radius_px", [])
	_check(orb.size() == 2 and float(orb[0]) > 0.0 and float(orb[0]) < float(orb[1]),
			"轨道半径区间合法（%s）" % str(orb))
	var iv: Array = Config.get_value("progression.badge.flash.interval", [])
	_check(iv.size() == 2 and float(iv[0]) > 0.2 and float(iv[0]) <= float(iv[1]),
			"闪烁间隔区间合法（%s）—— 太密会变成一直闪" % str(iv))
	var s_z := float(Config.get_value("progression.badge.far_fade.start_zoom", 0.0))
	var e_z := float(Config.get_value("progression.badge.far_fade.end_zoom", 9.0))
	_check(s_z > e_z and e_z > 0.0, "淡出区间 start %.2f > end %.2f > 0" % [s_z, e_z])
	var cols := {}
	for tid in ["blue", "purple", "black", "gold"]:
		var hex := str(Config.get_value("progression.badge.colors.%s" % tid, ""))
		_check(hex != "" and Color(hex).a > 0.0, "档位主色 %s 可解析（%s）" % [tid, hex])
		cols[hex] = true
	_check(cols.size() == 4,
			"四档色互不相同（出击面板色块也读同一份配置，实得 %d 种）" % cols.size())


# ------------------------------------------------------------
# B 段：节点接线
# ------------------------------------------------------------
func _b_node() -> void:
	_say("--- B 段：节点接线 ---")
	var uid := 0
	Meta.ensure_roster()
	for u in Meta.roster:
		uid = int(u.get("uid", 0))
		if uid > 0:
			break
	_check(uid > 0, "名册里有可进局的队员（uid %d）" % uid)
	if uid <= 0:
		uid = 1
	_main.call("_on_launch", [{"id": "spearman", "name": "枪手", "uid": uid, "level": 0}])
	await _frames(40)
	var ps := get_tree().get_nodes_in_group("player")
	_check(ps.size() >= 1, "局内有玩家（实得 %d）" % ps.size())
	if ps.is_empty():
		return
	_p = ps[0]
	_badge = _p.get_node_or_null("LevelBadge")
	_check(_badge != null, "等级淡光节点存在（Scenes/Player.tscn 的 LevelBadge）")
	if _badge == null:
		return
	_badge.set_process(false)          # 之后全程手动步进
	_check(int(_badge.get("z_index")) == 6, "z_index = 6（盖住角色 z=1 与雾 z=5）")
	var oy := float(Config.get_value("progression.badge.orb.center_offset_y", 0.0))
	_check(absf(_badge.position.y - oy) < 0.01,
			"节点原点 = 轨道中心（y=%.1f，实得 %.1f）" % [oy, _badge.position.y])
	for m in ["refresh", "flash", "notify_selected", "is_flashing", "current_alpha",
			"view_alpha", "visibility", "pulse_visibility", "orbit_angle", "glow_color",
			"_orbit_offset", "drawn_radius_world"]:
		_check(_badge.has_method(str(m)), "方法 %s 在" % str(m))
	for pr in ["level", "tier_id", "zoom_override"]:
		_check(_badge.get(str(pr)) != null, "属性 %s 在" % str(pr))


# ------------------------------------------------------------
# C 段：轨道有界
# ------------------------------------------------------------
func _c_orbit() -> void:
	_say("--- C 段：轨道有界（光点永不飘走、也不钻进身体）---")
	var orb: Array = Config.get_value("progression.badge.orb.orbit_radius_px", [20.0, 31.0])
	var r_lo := float(orb[0])
	var r_hi := float(orb[1])
	var wob := float(Config.get_value("progression.badge.orb.wobble_px", 3.0))
	var ys := float(Config.get_value("progression.badge.orb.orbit_y_scale", 0.85))
	# 轨道是**椭圆**（竖直半径 = 水平 × ys），所以模长的上下界要按椭圆算：
	# 最大 = 水平半径 + wobble 的对角分量；最小 = 竖直半径 − wobble 的对角分量。
	var lim_hi := r_hi + wob * sqrt(2.0) + 0.01
	var lim_lo := r_lo * minf(1.0, ys) - wob * sqrt(2.0) - 0.01
	var min_len := 99999.0
	var max_len := 0.0
	var min_x := 99999.0
	var max_x := -99999.0
	var min_y := 99999.0
	var max_y := -99999.0
	for i in range(600):
		_badge.set("_t", float(i) * 0.05)
		var o: Vector2 = _badge.call("_orbit_offset")
		var l: float = o.length()
		max_len = maxf(max_len, l)
		min_len = minf(min_len, l)
		min_x = minf(min_x, o.x)
		max_x = maxf(max_x, o.x)
		min_y = minf(min_y, o.y)
		max_y = maxf(max_y, o.y)
	_check(max_len <= lim_hi,
			"600 个时刻：光点偏移全部 <= %.1f px（实测最大 %.2f）—— 围绕，绝不飘走"
			% [lim_hi, max_len])
	_check(min_len >= lim_lo,
			"最近也 >= %.1f px（实测 %.2f）—— 椭圆竖直半径 %.1f 的几何下界"
			% [lim_lo, min_len, r_lo * ys])
	_check(min_x < -r_lo * 0.6 and max_x > r_lo * 0.6,
			"横向真的绕到两侧 —— x ∈ [%.1f, %.1f]" % [min_x, max_x])
	_check(min_y < 0.0 and max_y > 0.0, "纵向也跨过中心 —— y ∈ [%.1f, %.1f]" % [min_y, max_y])
	var ph := float(_badge.get("_phase"))
	_check(ph >= 0.0 and ph < TAU, "相位随机落在 [0, 2π)（实得 %.2f，多单位不会同步飞）" % ph)


# ------------------------------------------------------------
# D 段：闪烁状态机
# ------------------------------------------------------------
func _d_flash() -> void:
	_say("--- D 段：闪烁状态机 ---")
	var rise := float(Config.get_value("progression.badge.flash.rise", 0.15))
	var hold := float(Config.get_value("progression.badge.flash.hold", 0.7))
	var fade := float(Config.get_value("progression.badge.flash.fade", 0.35))
	_badge.set("_flash_t", -1.0)
	_check(not bool(_badge.call("is_flashing")), "静止时不在闪")
	_check(absf(float(_badge.call("_flash_amount"))) < 0.001, "静止时强度 = 0")
	_badge.call("flash")
	_check(bool(_badge.call("is_flashing")), "flash() 立刻进入闪烁")
	var cases := [
		[0.0, 0.0], [rise * 0.5, 0.5], [rise, 1.0], [rise + hold * 0.5, 1.0],
		[rise + hold + fade * 0.5, 0.5],
	]
	for c in cases:
		_badge.set("_flash_t", float(c[0]))
		var got := float(_badge.call("_flash_amount"))
		_check(absf(got - float(c[1])) < 0.03,
				"t=%.2fs 强度 %.2f（期望 %.2f）" % [float(c[0]), got, float(c[1])])
	# next_flash 归零 → 下一帧自动闪，且立刻重排下一次
	_badge.set("_flash_t", -1.0)
	_badge.set("_next_flash", 0.0)
	var hits := _step(_badge, 0.1)
	_check(hits > 0, "next_flash 归零 → 自动闪（%d 步在闪）" % hits)
	_check(float(_badge.get("_next_flash")) > 0.0,
			"闪的同时重排了下次（%.2f s）" % float(_badge.get("_next_flash")))
	# 到期自动收尾
	var total := rise + hold + fade
	_step(_badge, total + 0.3)
	_check(not bool(_badge.call("is_flashing")), "%.2fs 后闪烁自动结束" % total)
	_check(float(_badge.get("_next_flash")) > 0.0, "结束后又排了下一次")


# ------------------------------------------------------------
# E 段：自动闪烁
# ------------------------------------------------------------
func _e_auto() -> void:
	_say("--- E 段：自动闪烁的节奏（不是只有手动 flash 才有）---")
	var iv: Array = Config.get_value("progression.badge.flash.interval", [5.0, 9.0])
	var total := float(Config.get_value("progression.badge.flash.rise", 0.15)) \
			+ float(Config.get_value("progression.badge.flash.hold", 0.7)) \
			+ float(Config.get_value("progression.badge.flash.fade", 0.35))
	# 连续推进 45 秒，记录每次「开始闪」的时刻（D 段收尾时已排好下一次）
	var step := 0.05
	var t := 0.0
	var prev := false
	var starts: Array = []
	while t < 45.0:
		_badge.call("_process", step)
		var now := bool(_badge.call("is_flashing"))
		if now and not prev:
			starts.append(t)
		prev = now
		t += step
	_check(starts.size() >= 3,
			"45 秒里自动闪了 %d 次（间隔配置 %.0f~%.0f s，期望 4~7 次）"
			% [starts.size(), float(iv[0]), float(iv[1])])
	# 相邻两次「开始闪」的间隔 = 上一次闪烁总时长 + 随机 interval
	var gaps: Array = []
	var ok_gap := true
	for i in range(1, starts.size()):
		var gap: float = float(starts[i]) - float(starts[i - 1])
		gaps.append(snappedf(gap, 0.1))
		if gap < total + float(iv[0]) - 0.15 or gap > total + float(iv[1]) + 0.15:
			ok_gap = false
	_check(ok_gap,
			"相邻间隔都 = 闪烁时长 %.2fs + interval[%.0f,%.0f]（实测 %s）"
			% [total, float(iv[0]), float(iv[1]), str(gaps)])
	_badge.set("_flash_t", -1.0)


# ------------------------------------------------------------
# F 段：屏幕恒定尺寸 + 缩远淡出
# ------------------------------------------------------------
func _f_scale_fade() -> void:
	_say("--- F 段：屏幕恒定尺寸 + 缩远淡出 ---")
	var base := float(Config.get_value("progression.badge.orb.radius_px", 7.0))
	for z in [0.8, 1.0, 1.5, 2.0, 3.0]:
		_badge.set("zoom_override", float(z))
		_badge.call("_update_view")
		var r := float(_badge.call("drawn_radius_world"))
		_check(absf(r * float(z) - base) < 0.03,
				"zoom %.1f：世界半径 %.2f → 屏幕半径 %.2f ≈ %.1f（恒定）"
				% [float(z), r, r * float(z), base])
	var orb: Array = Config.get_value("progression.badge.orb.orbit_radius_px", [24.0, 36.0])
	# 世界上限 = max(光核半径, 轨道半径上限) —— 和实现里的 `_radius_max_world` 同一条公式，
	# 别在这里各写一份（否则调大 radius_px 就会假失败）。
	# ⚠ 这个上限**只在极端视野**才该生效：收到 `orbit_lo * 0.5` 那种量级的话，
	# zoom 0.8 这种正常视野就会撞上限，把上面那条「屏幕恒定尺寸」打断。
	var cap := maxf(base, float(orb[1]))
	_badge.set("zoom_override", 0.05)
	_badge.call("_update_view")
	var r_far := float(_badge.call("drawn_radius_world"))
	_check(r_far <= cap + 0.01,
			"极远视野（zoom 0.05）：半径被钳到世界上限 %.1f（实得 %.2f，不至于糊满角色）"
			% [cap, r_far])
	var s_z := float(Config.get_value("progression.badge.far_fade.start_zoom", 0.95))
	var e_z := float(Config.get_value("progression.badge.far_fade.end_zoom", 0.7))
	var probes := [
		[s_z + 0.2, 1.0], [(s_z + e_z) * 0.5, 0.5], [e_z, 0.0], [e_z - 0.2, 0.0],
	]
	for pr in probes:
		_badge.set("zoom_override", float(pr[0]))
		_badge.call("_update_view")
		# 读 view_alpha()（**视野淡出系数**本身）—— current_alpha() 还乘了
		# glow.max_alpha 与明灭曲线，那两个有自己的段在测，混在一起就测不准。
		var a := float(_badge.call("view_alpha"))
		_check(absf(a - float(pr[1])) < 0.03,
				"zoom %.2f → 视野系数 %.2f（期望 %.2f）" % [float(pr[0]), a, float(pr[1])])
	_badge.set("zoom_override", 0.0)      # 交还真实相机
	_badge.call("_update_view")
	# 还原后 _zoom 由真实相机决定（值取决于场景相机，不断言具体数值）；
	# 真没相机（纯无头）时实现回落 1.0 —— 总之必须是合法正数。
	_check(float(_badge.get("_zoom")) > 0.0001,
			"还原注入后 _zoom 由真实相机决定（实得 %.2f）" % float(_badge.get("_zoom")))
	var mx := float(Config.get_value("progression.badge.orb.glow.max_alpha", 1.0))
	_check(float(_badge.call("view_alpha")) >= 0.0
			and float(_badge.call("current_alpha")) <= mx + 0.001,
			"最终不透明度恒被 max_alpha（%.2f）压住" % mx)


# ------------------------------------------------------------
# G 段：事件联动
# ------------------------------------------------------------
func _g_events() -> void:
	_say("--- G 段：事件联动（点选 / 升级 / 开关）---")
	_badge.set("_flash_t", -1.0)
	_p.call("_set_selected", true)
	_check(bool(_badge.call("is_flashing")),
			"点选角色 → 光点立刻闪（不常驻数字的补偿手段）")
	_badge.set("_flash_t", -1.0)
	_p.call("apply_level", 3)
	_check(bool(_badge.call("is_flashing")), "升级（0 → 3）→ 闪")
	_badge.set("_flash_t", -1.0)
	_p.call("apply_level", 3)
	_check(not bool(_badge.call("is_flashing")), "等级没变 → 不闪（否则每次结算都白闪）")
	_badge.set("_flash_t", -1.0)
	_p.call("apply_level", 5)
	_check(bool(_badge.call("is_flashing")), "档内升级（3 → 5）也闪")
	_check(int(_badge.get("level")) == 5 and str(_badge.get("tier_id")) == "purple",
			"光点同步到 Lv5 / purple（实得 Lv%d / %s）"
			% [int(_badge.get("level")), str(_badge.get("tier_id"))])
	Config.set_override("progression.badge.flash.on_select", false)
	_badge.call("_apply_cfg")
	_badge.set("_flash_t", -1.0)
	_badge.call("notify_selected")
	_check(not bool(_badge.call("is_flashing")), "on_select=false → 点选不再闪")
	Config.clear_override("progression.badge.flash.on_select")
	_badge.call("_apply_cfg")
	Config.set_override("progression.badge.flash.on_level_up", false)
	_badge.call("_apply_cfg")
	_badge.set("_flash_t", -1.0)
	_p.call("apply_level", 6)
	_check(not bool(_badge.call("is_flashing")), "on_level_up=false → 升级不再闪")
	Config.clear_override("progression.badge.flash.on_level_up")
	_badge.call("_apply_cfg")


# ------------------------------------------------------------
# H 段：enabled 开关
# ------------------------------------------------------------
func _h_disabled() -> void:
	_say("--- H 段：enabled 开关 ---")
	_badge.set_process(true)
	Config.set_override("progression.badge.enabled", false)
	_badge.call("_apply_cfg")
	_check(not _badge.is_processing(),
			"enabled=false → 停 _process（每帧重绘的光点不能空转）")
	Config.clear_override("progression.badge.enabled")
	_badge.call("_apply_cfg")
	_check(_badge.is_processing(), "开回来 → _process 恢复")
	_badge.set_process(false)


# ------------------------------------------------------------
# I 段：淡光长相（2026-09-18 三次改版 —— 光没有轮廓）
# ------------------------------------------------------------
func _i_look() -> void:
	_say("--- I 段：淡光长相（删掉一切轮廓）---")
	var old_look: Variant = Config.get_value("progression.badge.orb.look", null)
	_check(old_look == null,
			"旧的 orb.look（描边 / 亮面 / 薄影）已从配置移除 —— 有轮廓就成了物体，正是前两版丑的病根")
	var layers: Array = Config.get_value("progression.badge.orb.glow.layers", [])
	_check(layers.size() >= 3,
			"柔光层数 %d >= 3（层太少化不开，会看出一圈硬边）" % layers.size())
	var ok_shape := true
	var ok_order := true
	var last_r := 2.0
	var last_a := -1.0
	for it in layers:
		if not (it is Array) or (it as Array).size() < 2:
			ok_shape = false
			continue
		var ratio := float(it[0])
		var al := float(it[1])
		if ratio > last_r + 0.001 or al < last_a - 0.001:
			ok_order = false
		last_r = ratio
		last_a = al
	_check(ok_shape, "每层都是 [半径比例, 不透明度比例] 两元组")
	_check(ok_order and last_r > 0.0 and last_a > 0.0,
			"层序合法：半径比例递减、不透明度递增（写反会变成一圈实心靶子）—— %s" % str(layers))
	var mx := float(Config.get_value("progression.badge.orb.glow.max_alpha", 1.0))
	_check(mx > 0.3 and mx < 1.0,
			"max_alpha = %.2f（< 1 才有「虚」的质感，> 0.3 才看得见）" % mx)
	var fo := float(Config.get_value("progression.badge.orb.glow.falloff", 0.0))
	_check(fo >= 0.5 and fo <= 6.0,
			"falloff = %.2f（0.5~6：太大光斑缩成一粒硬点，太小边缘糊成一片灰）" % fo)
	var gt: ImageTexture = _badge.call("glow_texture")
	_check(gt != null and gt.get_width() >= 16,
			"径向渐变光斑贴图已生成（%dx%d，软边 —— 不是实心圆，实心圆叠起来放大能数出同心环）"
			% [gt.get_width() if gt != null else -1, gt.get_height() if gt != null else -1])
	var tw := float(Config.get_value("progression.badge.orb.glow.tint_white", 0.0))
	_check(tw >= 0.2 and tw <= 1.0,
			"tint_white = %.2f —— 档位色朝白推淡（用户的「颜色尽量淡」）" % tw)
	for tid in ["blue", "purple", "black", "gold"]:
		var raw := Color(str(Config.get_value("progression.badge.colors.%s" % tid, "#000000")))
		_badge.set("tier_id", tid)
		var g: Color = _badge.call("glow_color")
		_check(g.s < raw.s - 0.02 and g.v >= raw.v - 0.001,
				"档位 %s：淡化后饱和度 %.2f → %.2f（更淡）且不再变暗" % [tid, raw.s, g.s])
	_badge.set("tier_id", "blue")
	_check(absf(float(_badge.get("_radius"))
			- float(Config.get_value("progression.badge.orb.radius_px", 0.0))) < 0.001,
			"光核半径与配置一致（%.1f）" % float(_badge.get("_radius")))


# ------------------------------------------------------------
# J 段：时隐时现
# ------------------------------------------------------------
func _j_pulse() -> void:
	_say("--- J 段：时隐时现（明灭曲线真的要走到两端）---")
	var ps: Array = Config.get_value("progression.badge.orb.glow.pulse_seconds", [])
	_check(ps.size() == 2 and float(ps[0]) > 0.0 and float(ps[1]) > 0.0,
			"两条脉冲周期合法（%s）" % str(ps))
	_check(absf(float(ps[0]) - float(ps[1])) > 0.2,
			"两条周期不相等（%.1f / %.1f）—— 相等就退化成规整的呼吸灯"
			% [float(ps[0]), float(ps[1])])
	var pw := float(Config.get_value("progression.badge.orb.glow.pulse_power", 0.0))
	_check(pw >= 1.0, "pulse_power %.2f >= 1（暗的时间不短于亮的，整体偏淡）" % pw)
	var v_min := 2.0
	var v_max := -1.0
	var mid := 0
	var n := 0
	for i in range(1201):                       # 24 秒，覆盖两条周期各若干轮
		_badge.set("_t", float(i) * 0.02)
		var v := float(_badge.call("pulse_visibility"))
		v_min = minf(v_min, v)
		v_max = maxf(v_max, v)
		if v > 0.2 and v < 0.8:
			mid += 1
		n += 1
	_check(v_min < 0.02,
			"明灭探到 %.3f ≈ 0 —— **真的会完全隐没**（不是一直淡淡挂着）" % v_min)
	_check(v_max > 0.98, "明灭探到 %.3f ≈ 1 —— 也真的会完全显现" % v_max)
	_check(float(mid) / float(n) > 0.15,
			"中间态占 %.0f%% —— 是渐变，不是硬开关" % (100.0 * float(mid) / float(n)))
	var msc := float(_badge.get("_min_scale"))
	_check(msc < 1.0, "min_scale %.2f < 1 —— 暗时收缩，有「凑近 / 退远」的体积感" % msc)
	# flash 期间可见度必须被拉满，否则光点恰在「隐」刻就白闪了
	var rise := float(Config.get_value("progression.badge.flash.rise", 0.15))
	_badge.call("flash")
	_badge.set("_flash_t", rise + 0.05)         # 推进到满强度
	var v_flash := float(_badge.call("visibility"))
	_check(v_flash >= 0.999,
			"flash 满强度时可见度被强制拉满（%.3f）—— 不会「闪在隐没里」" % v_flash)
	_badge.set("_flash_t", -1.0)


# ------------------------------------------------------------
# K 段：时快时慢
# ------------------------------------------------------------
func _k_speed() -> void:
	_say("--- K 段：时快时慢（角速度真的在变，且绝不倒转）---")
	# 配置层面的数学前提：ω(t) 的两条摆动项之和必须小于匀速项
	var spin := float(Config.get_value("progression.badge.orb.spin_speed", 0.0))
	var sway_sum := 0.0
	var pair := [["speed_sway", "speed_sway_hz"], ["speed_sway2", "speed_sway_hz2"]]
	for k in pair:
		var amp := float(Config.get_value("progression.badge.orb.%s" % k[0], 0.0))
		var hz := float(Config.get_value("progression.badge.orb.%s" % k[1], 0.0))
		sway_sum += amp * TAU * hz
	_check(spin > 0.0, "spin_speed %.2f > 0" % spin)
	_check(sway_sum < spin,
			"数学前提：两条 sway 项之和 %.2f < spin %.2f —— ω 恒正的充分条件"
			% [sway_sum, spin])
	# 实测：对角度做数值微分求瞬时角速度
	var dt := 0.02
	_badge.set("_t", 0.0)
	var prev := float(_badge.call("orbit_angle"))
	var w_min := 99999.0
	var w_max := -99999.0
	for i in range(1, 1201):                    # 24 秒
		_badge.set("_t", float(i) * dt)
		var cur := float(_badge.call("orbit_angle"))
		var w := (cur - prev) / dt
		w_min = minf(w_min, w)
		w_max = maxf(w_max, w)
		prev = cur
	_check(w_min > 0.0,
			"实测角速度恒为正（最小 %.2f rad/s）—— 绝不倒转，否则光点原地掉头像故障" % w_min)
	_check(w_min < spin * 0.9,
			"实测确实慢过（%.2f < 匀速 %.2f）—— 「时慢」成立" % [w_min, spin])
	_check(w_max > spin * 1.15,
			"实测确实快过（%.2f > 匀速 %.2f）—— 「时快」成立" % [w_max, spin])
	_check(w_max / maxf(w_min, 0.0001) > 1.5,
			"快慢差 %.1f 倍（ω ∈ [%.2f, %.2f]）—— 肉眼看得出来在变" % [w_max / w_min, w_min, w_max])


# ------------------------------------------------------------
# L 段：绕着角色四周飞（不是只在头顶）
# ------------------------------------------------------------
func _l_around() -> void:
	_say("--- L 段：绕着角色四周飞（不是只在头顶）---")
	var oy := float(Config.get_value("progression.badge.orb.center_offset_y", 0.0))
	var orb: Array = Config.get_value("progression.badge.orb.orbit_radius_px", [0.0, 0.0])
	var r_hi := float(orb[1])
	var ys := float(Config.get_value("progression.badge.orb.orbit_y_scale", 0.0))
	var wob := float(Config.get_value("progression.badge.orb.wobble_px", 0.0))
	var span := r_hi * ys
	var diag := wob * sqrt(2.0)
	_check(oy > -45.0,
			"轨道中心 y = %.0f（旧值 -56 是**头顶**）—— 已下移到身体中部" % oy)
	_check(ys >= 0.7,
			"orbit_y_scale %.2f >= 0.7 —— 纵向跨度够大，不再是贴着头顶的扁椭圆" % ys)
	_check(span >= 20.0,
			"纵向半幅 %.1f px >= 20 —— 明显上下掠（头顶 ↔ 腰腿）" % span)
	var top := oy - span - diag
	var bot := oy + span + diag
	_check(top < -45.0, "最高点 y = %.1f 会掠过角色头顶（< -45）" % top)
	_check(bot < 6.0, "最低点 y = %.1f 不会钻到地面以下（< 6）" % bot)
	# 实测走位：光点在**世界空间**里纵向到底走了多远
	var lo := 99999.0
	var hi := -99999.0
	for i in range(900):
		_badge.set("_t", float(i) * 0.033)
		var o: Vector2 = _badge.call("_orbit_offset")
		lo = minf(lo, o.y)
		hi = maxf(hi, o.y)
	_check(hi - lo >= 40.0,
			"900 个时刻实测：纵向走位跨度 %.1f px（>= 40 才算真的「绕」，而不是原地晃）"
			% (hi - lo))


# ------------------------------------------------------------
# 存档备份 / 还原 + 收尾
# ------------------------------------------------------------
func _backup_save() -> void:
	_save_existed = FileAccess.file_exists(SAVE_PATH)
	if _save_existed:
		_save_backup = FileAccess.get_file_as_string(SAVE_PATH)


func _restore_save() -> void:
	if _save_existed:
		var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_save_backup)
			f.close()
	elif FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))


func _finish() -> void:
	_restore_save()
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for msg in _fails:
		_say("  !! " + msg)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
		f.close()
	print("[probe_level_orb] 通过 %d / %d" % [_n - _fails.size(), _n])
	get_tree().quit(0 if _fails.is_empty() else 1)

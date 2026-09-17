extends Node2D
## ============================================================
## shot_orb_showcase — 等级淡光的「长相 + 明灭」实拍验证场景（Dev 专用，非游戏内容）
##
## 为什么要它：光点四档颜色要靠等级才出现（blue 0-2 / purple 3-5 / black 6-8 /
## gold 9），正常开一局只能看到 0 级那点蓝光 —— 想看全四档得打满 9 级。
## 本场景把四档并排画出来：上一行放大看构造，下一行是**游戏里的真实大小**，
## 且同一档位画三个**不同明灭时刻**的光点围着角色剪影 —— 这是本次改版的核心
## （时隐时现 + 绕着角色四周飞，见 Scripts/unit_level_badge.gd 文件头）。
##
## 用法（**必须开窗**，不能加 --headless —— 无头是 dummy 渲染驱动，viewport 贴图永远空白）：
##   godot --path <项目根> --resolution 900x430 res://Dev/shot_orb_showcase.tscn
## 出图写到 OUT 常量指的那个绝对路径（Godot 允许 save_png 写绝对路径）。
##
## ⚠ 置 `_orbit_r_lo/_orbit_r_hi/_wobble = 0` 把光点钉在节点原点（否则它在轨道上飘，
##   排版对不齐）；同时放开 `_radius_max_world`，不然放大展示用的大光点会被钳回去。
## ⚠ `refresh()` 内部会 `_apply_cfg()` 覆盖半径**和位置**，所以顺序必须是 refresh → 再 set。
## ⚠ `_phase` 是随机的 → 可见度跟着随机；展示要可复现就必须**显式钉住** `_phase / _t`。
## ⚠ 展示文字只用 ASCII：`ThemeDB.fallback_font` 不含中日韩字形，中文会画成空框。
## ============================================================

const OUT := "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42/orb_showcase.png"

## [档位 id, 展示等级, 标签]
const TIERS := [
	["blue", 0, "blue / Lv0"],
	["purple", 4, "purple / Lv4"],
	["black", 7, "black / Lv7"],
	["gold", 9, "gold / Lv9"],
]

const BG := Color("#86C15C")        # 草地色（Tiny Swords 的草）
const BG_DARK := Color("#79B052")
const INK := Color("#2F3A21")
const CAP := Color("#EDF5E1")

const BIG_R := 26.0                 # 放大展示用半径
const SMALL_R := 11.0               # 游戏里的真实屏幕半径（= config orb.radius_px）

## 三个明灭时刻（相对角色剪影的位置 + 目标可见度）：
## 亮时在左侧、中等在右上、将隐在脚下 —— 顺带把「绕着角色四周飞」也画出来。
const MOMENTS := [
	[Vector2(-42.0, -38.0), 1.0],
	[Vector2(40.0, -50.0), 0.45],
	[Vector2(8.0, 22.0), 0.06],
]


func _ready() -> void:
	var w := get_viewport_rect().size.x
	var col := w / 4.0
	for i in range(TIERS.size()):
		var t: Array = TIERS[i]
		var cx: float = col * (float(i) + 0.5)
		# ① 放大：看清构造（只有同心柔光，**没有描边**）
		_make_badge(str(t[0]), int(t[1]), Vector2(cx, 116.0), BIG_R, -1.0, 1.0)
		# ② 真实大小 + 角色参照：三个明灭时刻围着一个单位
		var foot := Vector2(cx, 306.0)
		for m in MOMENTS:
			_make_badge(str(t[0]), int(t[1]), foot + (m[0] as Vector2),
					SMALL_R, -1.0, float(m[1]))
	queue_redraw()
	for _i in range(8):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img == null:
		print("[Showcase] !! viewport 贴图为空（是不是加了 --headless？）")
		get_tree().quit(1)
		return
	img.save_png(OUT)
	print("[Showcase] saved %s  %dx%d" % [OUT, img.get_width(), img.get_height()])
	get_tree().quit(0)


## 造一个钉在指定位置、指定明灭时刻的光点。vis < 0 表示不闪（纯明灭态）。
func _make_badge(tier: String, lv: int, pos: Vector2, radius: float,
		flash_t: float, vis: float) -> Node2D:
	var b: Node2D = Node2D.new()
	b.set_script(load("res://Scripts/unit_level_badge.gd"))
	add_child(b)
	b.call("refresh", lv, tier)      # 先走正常配置流程（会自动 _apply_cfg）
	b.set_process(false)             # 冻结，别让它飘走 / 明灭变了
	# ⚠ 位置必须在 refresh **之后**设：_apply_cfg() 末尾有一句
	# `position = Vector2(0, orb.center_offset_y)`（真实游戏里轨道中心跟着角色走），
	# 先设会被它冲掉 —— 全部光点堆到 (0, -32) 也就是同一处，排版全乱。
	b.position = pos
	b.set("_orbit_r_lo", 0.0)
	b.set("_orbit_r_hi", 0.0)
	b.set("_wobble", 0.0)
	b.set("_radius", radius)
	b.set("_radius_max_world", radius * 4.0)
	b.set("_phase", 0.0)             # 固定相位 → 可见度可复现
	b.set("_t", _t_for_visibility(vis))
	b.set("_flash_t", flash_t)       # -1 = 不闪；0.4 落在 hold 里 → fat = 1
	b.call("_update_view")
	b.queue_redraw()
	return b


## 反查：找到使 pulse_visibility() 最接近 target 的 _t（_phase = 0）。
## 展示场景要"想画多亮就多亮"，不能靠碰运气 —— 脉冲参数改了这里自动跟上。
func _t_for_visibility(target: float) -> float:
	var p0 := float(Config.get_value("progression.badge.orb.glow.pulse_seconds", [3.4, 2.1])[0])
	var p1 := float(Config.get_value("progression.badge.orb.glow.pulse_seconds", [3.4, 2.1])[1])
	var pw := float(Config.get_value("progression.badge.orb.glow.pulse_power", 1.5))
	var best := 0.0
	var best_d := 999.0
	var t := 0.0
	while t < 20.0:
		var u := 0.5 + 0.62 * sin(TAU * t / p0) + 0.28 * sin(TAU * t / p1)
		var v: float = pow(clampf(u, 0.0, 1.0), pw)
		var d: float = absf(v - target)
		if d < best_d:
			best_d = d
			best = t
		t += 0.005
	return best


func _draw() -> void:
	var w := get_viewport_rect().size.x
	var h := get_viewport_rect().size.y
	var col := w / 4.0
	draw_rect(Rect2(0.0, 0.0, w, h), BG)
	draw_rect(Rect2(0.0, 0.0, w, 46.0), BG_DARK)
	draw_rect(Rect2(0.0, 356.0, w, h - 356.0), BG_DARK)
	var font := ThemeDB.fallback_font
	if font != null:
		draw_string(font, Vector2(14.0, 30.0), "Level glow - soft light, no outline",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 15, CAP)
		draw_string(font, Vector2(14.0, 382.0),
				"top = 2.4x zoom-in (soft radial glow only, no outline)   bottom = real size (r=11px): three pulse moments around a unit - bright / mid / fading",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, CAP)
	for i in range(TIERS.size()):
		var t: Array = TIERS[i]
		var cx: float = col * (float(i) + 0.5)
		if i > 0:
			draw_rect(Rect2(col * float(i), 54.0, 1.0, 292.0),
					Color(0.15, 0.2, 0.1, 0.22))
		if font != null:
			draw_string(font, Vector2(cx - 44.0, 76.0), str(t[2]),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 14, INK)
		_draw_pawn(Vector2(cx, 306.0), font)


## 角色参照：约 56px 高的剪影（Tiny Swords 单位在 zoom=1 时的屏幕高度量级）
func _draw_pawn(foot: Vector2, font: Font) -> void:
	draw_rect(Rect2(foot.x - 9.0, foot.y - 12.0, 7.0, 12.0), INK)
	draw_rect(Rect2(foot.x + 2.0, foot.y - 12.0, 7.0, 12.0), INK)
	draw_rect(Rect2(foot.x - 12.0, foot.y - 38.0, 24.0, 26.0), INK)
	draw_rect(Rect2(foot.x - 8.0, foot.y - 56.0, 16.0, 18.0), INK)
	if font != null:
		draw_string(font, Vector2(foot.x - 20.0, foot.y + 16.0), "unit",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK)

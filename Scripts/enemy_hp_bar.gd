extends Node2D
## ============================================================
## EnemyHpBar — 敌人头顶血条（2026-09-17 新增）
##
## 为什么会有这个文件：弓手特性「幻影分身」要求「本体和分身的血条同步改变」，
## 而项目此前**根本没有敌人血条** —— 敌人血量只出现在菜单栏的
## 「指定攻击 → 目标（HP x/y）」与 HUD 的小队血量文字里。要让「同步」被玩家
## 看见，先得有一条看得见的血条，于是补上这个通用件（所有敌人共用，不是分身专属）。
##
## 显示规则（照抄常规做法，避免 100 个敌人常驻血条的画面噪音）：
##   · 满血且没被碰过        → 不画（_draw 直接 return，零绘制开销）
##   · 挨过一次伤害          → 显示 show_seconds 秒，然后自动隐去
##   · 任何时刻的血量变化    → 重新计时（追击中会一直是可见的）
##
## 【幻影分身的关键约束】本体与分身的血条**颜色 / 尺寸 / 位置完全一致**，
## 这是刻意的：分身靠「看不出哪个是真身」来迷惑玩家（见 enemy.gd::_sync_phantoms）。
## 所以这里**不要**按 is_phantom() 换颜色 —— 那会一秒破功。
##
## 绘制用 _draw 自绘两个 draw_rect，不额外占节点、不进 GUI 管线。
## ============================================================

var _ratio := 1.0            # 当前血量比例 0~1
var _show := 0.0             # 剩余可见秒数（<=0 = 不画）
var _w := 28.0
var _h := 4.0
var _bg := Color(0.0, 0.0, 0.0, 0.55)
var _fill := Color("#e04a3c")
var _full_color := Color("#e04a3c")   # 满血色（可配置）
var _low_color := Color("#ffd54f")    # 残血色（可配置）


func _ready() -> void:
	set_process(false)          # 不显示时完全不跑 _process
	_reload_cfg()
	queue_redraw()


## 从 config 读外观参数（enemy.hp_bar.*）。由 enemy.gd 在 setup 时也会调一次，
## 保证跟随用户改的 settings.json（探针改 override 后重新 setup 也能生效）。
func _reload_cfg() -> void:
	_w = maxf(4.0, float(Config.get_value("enemy.hp_bar.width_px", 28.0)))
	_h = maxf(1.0, float(Config.get_value("enemy.hp_bar.height_px", 4.0)))
	_bg = Color(str(Config.get_value("enemy.hp_bar.bg_color", "#0000008c")))
	_full_color = Color(str(Config.get_value("enemy.hp_bar.color", "#e04a3c")))
	_low_color = Color(str(Config.get_value("enemy.hp_bar.low_color", "#ffd54f")))
	_fill = _full_color


## 设置血量比例并刷新（不改变可见性 —— 可见性由 flash/hide_bar 管）
func set_ratio(r: float) -> void:
	var v := clampf(r, 0.0, 1.0)
	if is_equal_approx(v, _ratio):
		_ratio = v
		if _show > 0.0:
			queue_redraw()
		return
	_ratio = v
	if _show > 0.0:
		queue_redraw()


## 显示血条 seconds 秒（seconds <= 0 时取 config 的 enemy.hp_bar.show_seconds）
func flash(seconds := -1.0) -> void:
	var dur := seconds
	if dur <= 0.0:
		dur = maxf(0.05, float(Config.get_value("enemy.hp_bar.show_seconds", 3.0)))
	_show = maxf(_show, dur)
	set_process(true)
	queue_redraw()


## 立刻隐藏（死亡淡出 / 消失时调用）
func hide_bar() -> void:
	_show = 0.0
	set_process(false)
	queue_redraw()


func ratio() -> float:
	return _ratio


func is_showing() -> bool:
	return _show > 0.0


func _process(delta: float) -> void:
	if _show <= 0.0:
		set_process(false)
		return
	_show = maxf(0.0, _show - delta)
	if _show <= 0.0:
		set_process(false)
	queue_redraw()          # 4 个矩形的重绘；只有"最近挨过打"的敌人在跑


## 底条 + 填充条（+ 残血换色）。坐标以本节点为原点，左右居中、向上生长。
func _draw() -> void:
	if _show <= 0.0:
		return
	var w := _w
	var h := _h
	var x := -w * 0.5
	draw_rect(Rect2(x - 1.0, -1.0, w + 2.0, h + 2.0), Color(0.0, 0.0, 0.0, _bg.a), true)
	draw_rect(Rect2(x, 0.0, w, h), _bg, true)
	if _ratio <= 0.0:
		return
	var col := _full_color.lerp(_low_color, clampf(1.0 - _ratio, 0.0, 1.0))
	draw_rect(Rect2(x, 0.0, w * _ratio, h), col, true)

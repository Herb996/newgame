extends Node
## ============================================================
## probe_menu_hover — 主菜单选项**悬停不再弹介绍**
##
## 用户 2026-09-19：「鼠标移到选项的时候，会有一个介绍，把那个去掉」。
## 那句话是 UiKit.menu_button 的 hint → Control.tooltip_text，靠引擎自绘。
## 现在 entries 表已经删掉介绍列、menu_button 也没有提示位了。
##
## 但"去掉一样东西"最容易顺手去掉别的东西：本探针同时钉住菜单**没坏** ——
## 五个按钮还在、文字对、图标还在、点击回调还连着。
##
## 只实例化 StartMenu，不点任何按钮（退出游戏那一下会真 quit）。
## ============================================================

const OUT := "user://_probe_menu_hover.txt"
const WANT := ["新建存档", "历史存档", "参数配置", "其他", "退出游戏"]

var _lines: Array = []
var _n := 0
var _fails: Array = []


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


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	await _frames(2)
	Config.set_override("debug.auto_enter_run", false)

	var menu: Node = load("res://Scenes/StartMenu.tscn").instantiate()
	add_child(menu)
	await _frames(10)

	var found := {}
	var tips := 0
	var ctrls := 0
	for b in _all_controls(menu):
		ctrls += 1
		if str(b.tooltip_text) != "":
			tips += 1
		if b is Button and WANT.has(str((b as Button).text)):
			found[str((b as Button).text)] = b
	_say("--- A 段：悬停介绍已撤掉 ---")
	_say("  菜单里 Control 共 %d 个，带 tooltip_text 的 %d 个" % [ctrls, tips])
	_check(found.size() == WANT.size(), "五个主按钮都还在（实得 %d）" % found.size())
	_check(tips == 0, "整个菜单树里没有任何悬停提示（带 tooltip 的节点 %d 个）" % tips)
	for txt in WANT:
		var b: Button = found.get(txt, null)
		if b == null:
			_check(false, "「%s」存在" % txt)
			continue
		_check(str(b.tooltip_text) == "", "「%s」悬停无介绍（tooltip_text=%s）" % [
				txt, str(b.tooltip_text)])
		# 通知走一遍引擎的悬停路径，确认没有别处代码在悬停时把提示塞回来
		b.notification(Control.NOTIFICATION_MOUSE_ENTER)
		_check(str(b.tooltip_text) == "", "「%s」模拟悬停之后仍然没有提示" % txt)

	_say("--- B 段：撤介绍没把菜单撤坏 ---")
	for txt in WANT:
		var b: Button = found.get(txt, null)
		if b == null:
			continue
		_check(b.icon != null, "「%s」图标仍在（改表列序最容易把这个错位）" % txt)
		_check(int(b.size_flags_horizontal) == int(Control.SIZE_SHRINK_CENTER),
				"「%s」仍居中对齐（宽度没被撑开）" % txt)
		if txt != "退出游戏":
			_check(b.pressed.get_connections().size() >= 1, "「%s」点击回调仍连着" % txt)
	_check(int(found["新建存档"].get_index()) < int(found["退出游戏"].get_index()),
			"按钮顺序未变（新建存档 在 退出游戏 之前）")

	_finish()


## 所有节点都往下递归（CanvasLayer 不是 Control，只按 Control 递归会漏掉面板层），
## 但只收集 Control
func _all_controls(node: Node, out: Array = []) -> Array:
	for c in node.get_children():
		if c is Control:
			out.append(c)
		_all_controls(c, out)
	return out


func _finish() -> void:
	_say("")
	_say("=== 共 %d 项断言，失败 %d 项 ===" % [_n, _fails.size()])
	for f in _fails:
		_say("  !! %s" % str(f))
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\n")
	print("\n".join(_lines))
	print("[probe_menu_hover] fails=%d -> %s" % [_fails.size(),
			"PASS" if _fails.is_empty() else "FAIL"])
	get_tree().quit(0 if _fails.is_empty() else 1)

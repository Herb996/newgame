class_name EffectLibrary
extends RefCounted
## ============================================================
## EffectLibrary — 特效库：按 id 从 fx.effects 配置表生成一次性贴图动画
##
## 【为什么做成"库 + id"而不是把贴图路径写死在角色代码里】（2026-09-20 用户定：
## 「可以做成解耦的吗，方便其他角色使用」）
##   · 表里一条 = 一个特效，谁用谁写 id，加角色不改代码；
##   · 引用点分三层，各自独立可缺省：
##       - 我方出手：combat.weapons.<武器>.fx_attack
##       - 我方命中：combat.weapons.<武器>.projectile.fx_impact
##       - 敌人出手：enemy_types.types[].fx_attack
##     三层都只是"一个字符串"，指向同一张 fx.effects 表 —— 剑士和巨魔用同一条
##     slash 弧只是 modulate 换个色，不用复制素材。
##
## 【全部静态 + static var 缓存】照 combat/hit_stop.gd 的样子写：本项目已验证
## 静态函数里读 Config、用 static var 都没问题。
##
## 【未知 id 只警告一次】250 只敌人同时缺配置时，每帧一条 push_warning 会把日志
## 刷爆并且真的拖慢帧率，所以 _missing 记名后不再重复。
##
## 【节流 fx.max_simultaneous】场上 fx_sprite 组达到上限就直接不生成（不排队、
## 不替换）：特效少画一个是审美问题，卡成幻灯片是功能问题。设 0 = 不限。
## ============================================================

const FX_SPRITE := preload("res://Scripts/combat/fx_sprite.gd")

static var _missing := {}
static var _textures := {}
static var _add_mat: Material = null


static func enabled() -> bool:
	return bool(Config.get_value("fx.enabled", true))


static func def_of(id: String) -> Dictionary:
	if id == "":
		return {}
	var all = Config.get_value("fx.effects", {})
	if not (all is Dictionary):
		return {}
	var d = all.get(id, null)
	return d if d is Dictionary else {}


static func has(id: String) -> bool:
	return not def_of(id).is_empty()


static func active_count(tree: SceneTree) -> int:
	if tree == null:
		return 0
	return tree.get_nodes_in_group(&"fx_sprite").size()


## 生成一个特效。parent = 挂哪（一般与单位同层的世界节点，特效寿命比单位长）；
## rot = 弧度，跟随出手方向；tint = 叠在配置 modulate 上的一层额外染色。
## 返回生成的节点（null = 没生成：总开关关着 / id 空 / 表里没这条 / 纹理缺失 / 已达上限）。
static func spawn(id: String, parent: Node, pos: Vector2,
		rot := 0.0, tint := Color(1.0, 1.0, 1.0, 1.0)) -> Node2D:
	if parent == null or not is_instance_valid(parent) or not enabled():
		return null
	var d := def_of(id)
	if d.is_empty():
		if id != "" and not _missing.has(id):
			_missing[id] = true
			push_warning("[Fx] fx.effects 里没有 \"%s\" 这一条 —— 同类缺失只警告这一次" % id)
		return null
	var cap := int(Config.get_value("fx.max_simultaneous", 48))
	if cap > 0 and active_count(parent.get_tree()) >= cap:
		return null
	var tex := _texture(str(d.get("texture", "")))
	if tex == null:
		return null
	var s: Node2D = FX_SPRITE.new()
	# 上面那个 tex 不只是一个"存不存在"的闸门：必须挂到节点上。漏了这一行，特效就是个
	# 透明 Sprite2D —— 数值断言全绿，画面上什么都没有（实拍那张图才抓得到）。
	s.texture = tex
	s.frames = int(d.get("frames", 1))
	s.fps = float(d.get("fps", 24.0))
	s.fade_out = float(d.get("fade_out", 0.08))
	if bool(d.get("additive", false)):
		# Godot 4.7 的 CanvasItem **没有** blend_mode 属性（拿 --dump-extension-api 查过，
		# CanvasItem./Material./RenderingServer. 三种写法全是 Parse Error）：
		# 2D 混合模式在 CanvasItemMaterial 上，得给节点挂一份 material。
		# 共享一份而不是每次 new：250 朵星芒各带一个材质会白白打断合批。
		s.material = _add_material()
	var sc := float(d.get("scale", 1.0))
	s.scale = Vector2(sc, sc)
	s.rotation = rot + float(d.get("rot_degrees", 0.0)) * PI / 180.0
	var off = d.get("offset_px", [0.0, 0.0])
	if off is Array and (off as Array).size() >= 2:
		s.offset = Vector2(float((off as Array)[0]), float((off as Array)[1]))
	s.modulate = Color(str(d.get("modulate", "#ffffff"))) * tint
	s.z_index = int(d.get("z_index", 60))
	parent.add_child(s)
	s.global_position = pos
	return s


static func _add_material() -> Material:
	if _add_mat == null:
		var m := CanvasItemMaterial.new()
		m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		_add_mat = m
	return _add_mat


static func _texture(path: String) -> Texture2D:
	if path == "":
		return null
	if _textures.has(path):
		return _textures[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		var res = load(path)
		if res is Texture2D:
			tex = res
	if tex == null and not _missing.has(path):
		_missing[path] = true
		push_warning("[Fx] 特效贴图取不到：%s —— 同一路径只警告这一次" % path)
	_textures[path] = tex
	return tex


## 探针用：把"只警告一次"的记名清掉，好让负对照重新走一遍告警分支。
static func reset_dedupe() -> void:
	_missing.clear()

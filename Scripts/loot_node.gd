extends Area2D
## ============================================================
## LootNode — 资源点（地图生成点 / 敌人掉落物 共用）
## 美术：Assets/Art/Sprites/Items/item_*.png（Tiny Swords 官方道具图，
##   路径在 config 的 resources.<id>.sprite），脚下垫一圈资源色柔光表示"可拾取"。
## 玩家移动到拾取范围内自动拾取：默认获得 loot.amount_per_node（10）单位，
## 敌人掉落物通过 setup(res_id, amount, scale) 指定更小的数量与体积。
## 归属（2026-09-19 起）：范围内**离它最近的那个活人**拿，直接进他自己那份背包
## （player.add_item）。他的格子满 → 拾取失败返回 false，资源点留在原地，
## 短暂冷却后自动重试（玩家离开再回来也会再试）。
## 角色阵亡时整包也是撒成这个场景（见 player.drop_inventory），队友走过来捡回去。
## 显隐由 fog_system 控制（与敌人一致的组机制，组: loot_nodes）。
## ============================================================

const RING_SEGMENTS := 24     # 拾取提示圈用几边形近似圆

var resource_id := ""
var _amount := 10
var _retry_cooldown := 0.0   # 拾取失败后的重试冷却（秒）
var _run: Node


func _ready() -> void:
	add_to_group("loot_nodes")
	visible = false  # 初始隐藏，等雾系统判定（未探索区域不可见）


## amount_override > 0 时用它（敌人掉落物），否则用 loot.amount_per_node
## visual_scale < 1 时整体缩小，便于区分"掉落物"与"地图资源点"
func setup(res_id: String, amount_override: int = -1, visual_scale: float = 1.0) -> void:
	resource_id = res_id
	_amount = amount_override if amount_override > 0 \
			else int(Config.get_value("loot.amount_per_node", 10))
	if visual_scale < 1.0:
		scale = Vector2(visual_scale, visual_scale)
	var color := Color(str(Config.get_value("resources.%s.color" % res_id, "#ffffff")))
	_apply_icon(res_id)
	_apply_ring(color)
	var radius := float(Config.get_value("loot.pickup_radius_px", 20.0))
	($CollisionShape2D.shape as CircleShape2D).radius = radius


## 图标：用官方道具图（resources.<id>.sprite）。不同道具源图尺寸不一
## （石头 64、金锭 128），统一按 loot.icon_px 归一化，保证地上大小一致。
## 图缺失时保留一圈资源色圆点兜底，绝不出现"看不见的资源点"。
func _apply_icon(res_id: String) -> void:
	var body := get_node_or_null("Body") as Sprite2D
	if body == null:
		return
	var path := str(Config.get_value("resources.%s.sprite" % res_id, ""))
	if path == "" or not ResourceLoader.exists(path):
		push_warning("[Loot] 资源图标缺失：%s -> %s" % [res_id, path])
		return
	body.texture = load(path)
	var icon_px := float(Config.get_value("loot.icon_px", 44.0))
	var tex_size := body.texture.get_size()
	var longest := maxf(tex_size.x, tex_size.y)
	if longest > 0.0:
		var k := icon_px / longest
		body.scale = Vector2(k, k)
	# 略微抬高，让图标"浮"在柔光之上而不是被压在圈里
	body.offset = Vector2(0.0, -icon_px * 0.35)


## 拾取提示圈：以 loot.ring_radius_px 为半径的多边形柔光。
## 以前这个半径是写死在场景里的常量、config 里的 ring_radius_px 根本没人读；
## 这里改成代码按配置生成，改数值立刻生效。
func _apply_ring(color: Color) -> void:
	var ring := get_node_or_null("Body2") as Polygon2D
	if ring == null:
		return
	var r := float(Config.get_value("loot.ring_radius_px", 26.0))
	var pts := PackedVector2Array()
	for i in range(RING_SEGMENTS):
		var a := TAU * float(i) / float(RING_SEGMENTS)
		pts.append(Vector2(cos(a), sin(a) * 0.55) * r)   # 压扁成椭圆，贴合俯视地面
	ring.polygon = pts
	ring.color = Color(color.r, color.g, color.b, 0.32)


func _physics_process(delta: float) -> void:
	if _retry_cooldown > 0.0:
		_retry_cooldown -= delta
		return
	if _run == null:
		_run = get_tree().get_first_node_in_group("run_manager")
	var t := _nearest_living_carrier()
	if t == null:
		return      # 范围内没有活人（压上来的全是尸体也算没有）：等活人过来
	if _run != null and _run.state != _run.State.RUNNING:
		return      # 本局已结算，地上的东西不再进包
	if t.add_item(resource_id, _amount):
		if _run != null:
			_run.loot_pickup_feedback(t, resource_id, _amount)
		queue_free()  # 拾取成功，资源点消失
	else:
		# 背包格满等原因拾取失败：0.5 秒后自动重试
		_retry_cooldown = float(Config.get_value("loot.pickup_retry_seconds", 0.5))


## 拾取归属（用户 2026-09-19 定）：压住这个资源点的角色里，**离它最近的那个活人**拿走。
## 为什么要挑：小队 2~4 人挤在一起时 get_overlapping_bodies() 一次给好几个，
## 按节点顺序发就会变成"先出生的那个永远通吃"，谁走到跟前谁拿到才讲得通。
func _nearest_living_carrier() -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for body in get_overlapping_bodies():
		if not (body is Node2D) or not body.is_in_group("player"):
			continue
		if body.has_method("is_dead") and bool(body.is_dead()):
			continue
		var d: float = global_position.distance_squared_to(body.global_position)
		if d < best_d:
			best_d = d
			best = body
	return best

extends Area2D
## ============================================================
## LootNode — 资源点（地图生成点 / 敌人掉落物 共用）
## 每个资源点绑定一种资源（颜色占位，正式素材待生成）。
## 玩家移动到拾取范围内自动拾取：默认获得 loot.amount_per_node（10）单位，
## 敌人掉落物通过 setup(res_id, amount, scale) 指定更小的数量与体积。
## 资源点消失。背包格满时拾取失败（RunManager.add_loot 返回 false），
## 短暂冷却后自动重试（玩家离开再回来也会再试）。
## 显隐由 fog_system 控制（与敌人一致的组机制，组: loot_nodes）。
## ============================================================

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
	$Body.color = color
	$Body2.color = Color(color.r, color.g, color.b, 0.4)  # 外圈淡色提示范围
	var radius := float(Config.get_value("loot.pickup_radius_px", 20.0))
	($CollisionShape2D.shape as CircleShape2D).radius = radius


func _physics_process(delta: float) -> void:
	if _retry_cooldown > 0.0:
		_retry_cooldown -= delta
		return
	if _run == null:
		_run = get_tree().get_first_node_in_group("run_manager")
	for body in get_overlapping_bodies():
		if body.is_in_group("player"):
			if _run != null and _run.add_loot(resource_id, _amount):
				_run.loot_pickup_feedback(resource_id, _amount)
				queue_free()  # 拾取成功，资源点消失
			else:
				# 背包格满等原因拾取失败：0.5 秒后自动重试
				_retry_cooldown = float(Config.get_value("loot.pickup_retry_seconds", 0.5))
			break

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

## 捡了书却没学会的几种原因（HUD 没有 toast 接口，只能落到日志里）
const TEACH_FAIL := {
	"slots_full": "技能槽已满",
	"maxed": "这招已经练到顶",
	"duplicate": "这招捡过重复的书",
	"unknown": "书上的字谁也看不懂",
}

var resource_id := ""
var _amount := 10
var _retry_cooldown := 0.0   # 拾取失败后的重试冷却（秒）
## true = 这是一本魔法书：踩上去学一招而不是进背包。
## resource_id 保持空 —— grimoire 不是资源，绝不能进仓库（Meta._prune_unknown_resources
## 会把不在 resources 表里的键当脏数据删掉，所以它压根没被登记成资源）。
var _grimoire := false
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
	_fit_sprite(get_node_or_null("Body") as Sprite2D,
			str(Config.get_value("resources.%s.sprite" % res_id, "")),
			float(Config.get_value("loot.icon_px", 44.0)), res_id)
	_apply_ring(color)
	_arm_pickup()


## 魔法书（2026-09-21 起，见 skills.grimoire）：外观自成一套，拾取走 _teach 不进背包。
## 图缺失时同样退回一圈资源色柔光 —— 地上的书看不见比没掉落更糟。
func setup_grimoire() -> void:
	_grimoire = true
	var g := "skills.grimoire."
	_fit_sprite(get_node_or_null("Body") as Sprite2D,
			str(Config.get_value(g + "sprite", "")),
			float(Config.get_value(g + "icon_px", 40.0)),
			str(Config.get_value(g + "name", "魔法书")))
	_apply_ring(Color(str(Config.get_value(g + "color", "#c8a2ff"))))
	_arm_pickup()


## 拾取判定范围：资源点与魔法书必须一模一样，否则"能看书不能捡钱"这种怪事会出现。
func _arm_pickup() -> void:
	var radius := float(Config.get_value("loot.pickup_radius_px", 20.0))
	($CollisionShape2D.shape as CircleShape2D).radius = radius


## 图标：用官方道具图。不同道具源图尺寸不一（石头 64、金锭 128），
## 统一按 icon_px 归一化，保证地上大小一致；图缺失时保留柔光环兜底。
func _fit_sprite(body: Sprite2D, path: String, icon_px: float, label: String) -> void:
	if body == null:
		return
	if path == "" or not ResourceLoader.exists(path):
		push_warning("[Loot] 图标缺失：%s -> %s" % [label, path])
		return
	body.texture = load(path)
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
	if _grimoire:
		_teach(t)
		return
	if t.add_item(resource_id, _amount):
		if _run != null:
			_run.loot_pickup_feedback(t, resource_id, _amount)
		queue_free()  # 拾取成功，资源点消失
	else:
		# 背包格满等原因拾取失败：0.5 秒后自动重试
		_retry_cooldown = float(Config.get_value("loot.pickup_retry_seconds", 0.5))


## 捡书 = 当场学一招（2026-09-21 用户定：局内掉落、撤离才永久）。
## 【为什么掷点在拾取而不在掉落】掉落时还不知道谁会捡起来 —— 每个人的已学列表
## 不同，"优先没学过的"这句必须按拾取者的 known 来算。
## 【为什么无论结果都销毁】留在地上的书会每个重试间隔再掷一次，玩家站着不动就
## 看到技能等级自己往上涨；槽满那种更是永远捡不起来，等于地上摆了个死循环。
## 学不上也要说清楚为什么，别让人以为书是凭空消失的。
func _teach(carrier: Node2D) -> void:
	var ss := carrier.call("skills") as SkillSystem
	var mode := str(Config.get_value("skills.grimoire.roll_mode", "random_prefer_unlearned"))
	var id := SkillSystem.roll_skill(ss.known, mode == "random_prefer_unlearned")
	var r: Dictionary = carrier.learn_skill(id)
	var skill_name := str(SkillSystem.def_of(id).get("name", id))
	var who := str(carrier.character_name)
	if who == "":
		who = "角色"
	if bool(r.get("ok", false)):
		print("[Loot] %s 翻开魔法书 → 学会 %s（Lv%d）" % [who, skill_name, int(r.get("level", 1))])
	else:
		print("[Loot] %s 翻开魔法书：%s —— %s，书化成光没了" % [
				who, skill_name, TEACH_FAIL.get(str(r.get("action", "")), "学不上")])
	queue_free()


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

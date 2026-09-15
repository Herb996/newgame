class_name SkillSystem
extends Node
## ============================================================
## SkillSystem — 技能系统（02_TECH_BUILD.md 第二部分 技能系统）
##
## 职责：从 config 装配技能表 → 冷却 tick → 资源校验（体力）→ 交给 FSM 释放。
## 事件驱动：释放成功/被拒都发信号，UI 与音效只监听信号，不轮询。
##
## 本系统不实现任何具体效果（伤害/位移/增益），只负责"能不能放"：
## 生效逻辑在 PlayerSkillState，具体效果在 player.gd 功能层。
## 挂在 Player 下（与 StateMachine 同级）。
## ============================================================

## 释放成功（skill_id）
signal skill_cast(skill_id: StringName)
## 释放被拒（skill_id, 原因：冷却中 / 体力不足）
signal skill_rejected(skill_id: StringName, reason: String)

var actor: Node = null

var _skills: Dictionary = {}          # StringName -> Skill
var _order: Array[StringName] = []    # 保持 config 里的书写顺序（决定技能栏序号）


func setup(host: Node) -> void:
	actor = host
	_load_from_config()


func _physics_process(delta: float) -> void:
	for sid in _order:
		_skills[sid].tick(delta)


# --- 装配 ---

func _load_from_config() -> void:
	var raw = Config.get_value("combat.skills", {})
	if not (raw is Dictionary):
		push_error("[Skill] config 的 combat.skills 不是字典，技能系统未装载")
		return
	var names: Array[String] = []
	for key in raw.keys():
		var sid := StringName(str(key))
		var sk := Skill.new(sid, raw[key])
		_skills[sid] = sk
		_order.append(sid)
		names.append(sk.display_name())
	print("[Skill] 技能装载完成：%d 个 —— %s" % [_order.size(), " / ".join(names)])


# --- 查询 ---

func ids() -> Array[StringName]:
	return _order.duplicate()


func get_skill(skill_id: StringName) -> Skill:
	return _skills.get(skill_id)


## 校验 + 释放：成功返回 true（已切到 skill 状态）
func try_cast(skill_id: StringName) -> bool:
	if actor == null:
		return false
	var sk := get_skill(skill_id)
	if sk == null:
		push_warning("[Skill] 未登记的技能：%s" % skill_id)
		return false
	if not sk.is_ready():
		skill_rejected.emit(skill_id, "冷却中")
		print("[Skill] %s 冷却中（剩余 %.1fs）" % [sk.display_name(), sk.cooldown_remaining])
		return false
	var cost := sk.stamina_cost()
	if float(actor.stamina) < float(cost):
		skill_rejected.emit(skill_id, "体力不足")
		print("[Skill] %s 体力不足（需 %d，剩 %d）" % [
			sk.display_name(), cost, int(actor.stamina)])
		return false
	# 释放即扣资源并起冷却：被打断也照扣，避免"前摇取消白嫖"
	actor.spend_stamina(cost)
	sk.start_cooldown()
	actor.state_machine.force_transition(&"skill", {"skill_id": skill_id})
	skill_cast.emit(skill_id)
	print("[Skill] 释放 %s（体力 -%d）" % [sk.display_name(), cost])
	return true

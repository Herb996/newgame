class_name Skill
extends RefCounted
## ============================================================
## Skill — 单个技能的数据 + 运行时状态（02_TECH_BUILD.md 第二部分 技能系统）
##
## 生命周期（由 PlayerSkillState 驱动）：
##   PreCast 前摇 → Cast 生效 → PostCast 后摇 → Cooldown 冷却
##
## 数据与逻辑分离（蓝图核心原则 2）：本类只持有 config 里的一块字典，
## 不含任何硬编码数值；改数值只改 Data/config.json 的 combat.skills.<id>。
## ============================================================

## 技能类型：决定 Cast（生效）阶段做什么
##   AOE_SELF —— 以自身为中心的圆形范围伤害（含击退）
##   DASH     —— 朝 facing 方向突进，沿途命中（每个目标只命中一次）
##   BUFF     —— 给自己挂增益（当前用于齿轮护盾：限时减伤）
enum Type { AOE_SELF, DASH, BUFF }

## 技能 id（对应 config 的键名，也是输入缓冲里的 action 后缀）
var id: StringName = &""
## config 里 combat.skills.<id> 的原始字典
var data: Dictionary = {}
## 剩余冷却（秒）；<= 0 表示可释放
var cooldown_remaining: float = 0.0


func _init(p_id: StringName, p_data: Dictionary) -> void:
	id = p_id
	data = p_data


# --- 数值读取（缺项时用默认值并告警，方便发现 config 漏项） ---

func num(key: String, default: float) -> float:
	return float(data.get(key, default))


func int_value(key: String, default: int) -> int:
	return int(data.get(key, default))


func display_name() -> String:
	return str(data.get("name", id))


func type() -> int:
	match str(data.get("type", "aoe_self")):
		"dash":
			return Type.DASH
		"buff":
			return Type.BUFF
		_:
			return Type.AOE_SELF


func stamina_cost() -> int:
	return int_value("stamina_cost", 0)


func cooldown_seconds() -> float:
	return num("cooldown_seconds", 0.0)


# --- 生命周期：冷却 ---

func is_ready() -> bool:
	return cooldown_remaining <= 0.0


func tick(delta: float) -> void:
	if cooldown_remaining > 0.0:
		cooldown_remaining = maxf(cooldown_remaining - delta, 0.0)


func start_cooldown() -> void:
	cooldown_remaining = cooldown_seconds()


## 剩余冷却比例 0~1（HUD 显示用）
func cooldown_ratio() -> float:
	var cd := cooldown_seconds()
	if cd <= 0.0:
		return 0.0
	return clampf(cooldown_remaining / cd, 0.0, 1.0)

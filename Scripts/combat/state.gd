class_name State
extends RefCounted
## ============================================================
## State — 状态基类（对应 06_FIGHT.md 蓝图的 IState 接口）
##
## 生命周期：enter(msg) → physics_update(delta) → exit()
##
## 事件驱动原则：状态之间不互相直接调用。需要切换状态时只发
## signal transition_requested，由 StateMachine 统一在 update 之后
## 应用（延迟切换），杜绝同帧多次切换导致的死锁/状态闪烁。
##
## 子类只需重写 enter / exit / physics_update / handle_input。
## 通过 actor 访问角色功能组件层的公开接口（移动、攻击、受击…），
## 状态机本身不关心这些功能的实现 —— 即"移动逻辑与状态机解耦"。
## ============================================================

## 请求切换到指定状态（由 StateMachine 接管执行）
signal transition_requested(to_state: StringName)

var name: StringName = &""     # 状态名（唯一键，如 &"idle" / &"move"）
var actor: Node = null         # 状态归属角色（玩家 / 敌人）
var machine: Node = null       # 所属状态机（需要读上下文时使用）


func _init(p_name: StringName = &"", p_actor: Node = null) -> void:
	name = p_name
	actor = p_actor


## 进入状态时调用；msg 为可选的过渡参数（如切换原因、目标点）
func enter(_msg: Dictionary = {}) -> void:
	pass


## 离开状态时调用（清理：取消计时器、复位动画参数等）
func exit() -> void:
	pass


## 每个物理帧执行（频率与角色 _physics_process 一致）
func physics_update(_delta: float) -> void:
	pass


## 输入事件（由角色转发；用于攻击/闪避等需要输入的状态）
func handle_input(_event: InputEvent) -> void:
	pass


## 请求切换状态（子类统一走这里，不直接操作状态机）
func request_transition(to_state: StringName) -> void:
	transition_requested.emit(to_state)

class_name StateMachine
extends Node
## ============================================================
## StateMachine — 有限状态机（DESIGN.md 第二部分 角色控制与 FSM）
##
## 职责：持有并驱动状态，处理状态切换请求。本身不含任何玩法逻辑。
##
## 关键设计：
## 1. 延迟切换：状态内调用 request_transition 只记录 pending，
##    在 physics_update 结束之后统一应用 —— 避免"攻击取消逻辑死锁"。
## 2. 同状态不重入：切换到与当前相同的状态直接忽略。
## 3. 由宿主角色驱动（player/enemy 调 physics_update），
##    自己不开启 _physics_process，保证与角色同一节拍、顺序可控。
##
## 用法：
##   var sm := StateMachine.new()
##   add_child(sm)
##   sm.setup(self, &"idle", Config.get_value("debug.log_state_transitions", false))
##   sm.add_state(PlayerIdleState.new(self))
##   sm.add_state(PlayerMoveState.new(self))
##   sm.start()
##   # 在角色的 _physics_process 里： sm.physics_update(delta)
## ============================================================

## 状态切换完成信号（供 UI/日志/音效监听）
signal state_changed(from_state: StringName, to_state: StringName)

var current_state: State = null
var initial_state: StringName = &"idle"
var log_transitions: bool = false
## 归属角色：注册状态时自动下发到各 State.actor
var actor_host: Node = null

var _states: Dictionary = {}
var _pending_transition: StringName = &""
var _pending_msg: Dictionary = {}


## 初始化：host=归属角色，p_initial=起始状态名，p_log=是否打印切换日志
func setup(host: Node, p_initial: StringName, p_log: bool = false) -> void:
	actor_host = host
	initial_state = p_initial
	log_transitions = p_log


## 注册状态（同名覆盖）
func add_state(state: State) -> void:
	if state == null:
		push_error("[FSM] 注册了空状态")
		return
	state.machine = self
	if state.actor == null:
		state.actor = actor_host
	var handler := Callable(self, "_on_transition_requested")
	if not state.transition_requested.is_connected(handler):
		state.transition_requested.connect(handler)
	_states[state.name] = state


## 启动：进入初始状态
func start(msg: Dictionary = {}) -> void:
	if not _states.has(initial_state):
		push_error("[FSM] 初始状态未注册：%s" % initial_state)
		return
	_transition_to(initial_state, msg)


## 每帧驱动（由宿主调用）
func physics_update(delta: float) -> void:
	if current_state == null:
		return
	current_state.physics_update(delta)
	_apply_pending_transition()


## 输入转发（由宿主 _unhandled_input 调用）
func handle_input(event: InputEvent) -> void:
	if current_state != null:
		current_state.handle_input(event)


## 强制切状态（外部系统用，如受击/死亡：sm.force_transition(&"hitstun")）
func force_transition(to_state: StringName, msg: Dictionary = {}) -> void:
	if _states.has(to_state):
		_transition_to(to_state, msg)
	else:
		push_warning("[FSM] 未注册的状态：%s" % to_state)


func get_state_name() -> StringName:
	return &"" if current_state == null else current_state.name


func _on_transition_requested(to_state: StringName) -> void:
	if not _states.has(to_state):
		push_warning("[FSM] 请求切换到未注册状态：%s" % to_state)
		return
	# 只记录，不立即切换（延迟到本帧 update 结束）
	_pending_transition = to_state


func _apply_pending_transition() -> void:
	if _pending_transition == &"":
		return
	var to_state := _pending_transition
	var msg := _pending_msg
	_pending_transition = &""
	_pending_msg = {}
	if current_state != null and current_state.name == to_state:
		return  # 同状态不重入
	_transition_to(to_state, msg)


func _transition_to(to_state: StringName, msg: Dictionary = {}) -> void:
	var next: State = _states.get(to_state)
	if next == null:
		push_error("[FSM] 无法切换到未注册状态：%s" % to_state)
		return
	var from_state := &"" if current_state == null else current_state.name
	if current_state != null:
		current_state.exit()
	current_state = next
	current_state.enter(msg)
	if log_transitions:
		print("[FSM] %s → %s" % [from_state, to_state])
	state_changed.emit(from_state, to_state)

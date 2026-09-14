请阅读下面战斗系统开发蓝图。现在，我们从 Phase 1: 基础原型 开始。请先为我设计并编写 角色控制与有限状态机（FSM） 的C#代码框架。要求：支持状态切换，包含Idle和Move状态，移动逻辑与状态机解耦。

AI辅助游戏战斗系统开发蓝图 (Battle System Blueprint)

1\. 核心架构原则 (Core Architecture Principles)

分层架构 (Layered Architecture)：严格划分为功能组件层（移动、动画、碰撞）、策略层（技能、Buff、AI行为）和行为决策层（状态机、输入处理、网络同步）。

数据与逻辑分离 (Data-Logic Separation)：战斗数值、技能配置、AI参数必须抽取为独立的数据资产（如ScriptableObject/JSON）。代码仅负责读取数据并执行逻辑，禁止硬编码数值。

事件驱动 (Event-Driven)：各系统间通过事件总线（Event Bus）或委托（Delegates）通信，避免组件间的强耦合。

服务器权威 (Server-Authoritative)：所有伤害计算、状态变更、命中判定必须在服务端执行，客户端仅负责输入发送与表现插值。

2\. 核心模块开发清单 (Core Modules Checklist)

2.1 角色控制与状态机 (Character Controller \& FSM)

有限状态机 (FSM)：实现 IState 接口（Enter, Execute, Exit）。必须包含的状态：Idle, Move, Attack, HitStun, Dodge, Dead。

输入缓冲 (Input Buffer)：实现按键缓存队列，支持连招派生与取消后摇（Cancel Window）。

Root Motion / 物理控制：明确移动是由动画根骨骼驱动还是代码直接修改Transform/Velocity。

2.2 伤害与判定系统 (Damage \& Hit Detection)

碰撞检测 (Hit Detection)：明确近战使用Hitbox（Trigger/Collider），范围攻击使用Overlap检测。

伤害结算管线 (Damage Pipeline)：采用修饰器模式（Modifier Pattern）。公式示例：FinalDmg = (BaseDmg \* Multipliers - Defense) \* RandomVariance。

受击反馈 (Hit Feedback)：实现顿帧（Hit Stop）、受击位移（Knockback）、屏幕震动与音效触发的钩子函数。

2.3 技能系统 (Skill System)

技能生命周期：PreCast (前摇) -> Cast (生效) -> PostCast (后摇) -> Cooldown (冷却)。

资源校验：释放前检查 MP/Stamina 是否充足，CD是否转好。

动画事件绑定：通过Animation Event触发伤害判定窗口的开启与关闭。

2.4 敌人AI系统 (Enemy AI)

感知系统 (Perception)：实现视觉锥（FOV）或听觉范围检测。

行为树/GOAP (Behavior Tree)：定义巡逻(Patrol)、追击(Chase)、攻击(Attack)、撤退(Retreat)的优先级与条件。

3\. 分阶段执行指令 (Phased Execution Instructions)

Phase 1: 基础原型 (Greybox Prototype)

目标：验证核心手感与操作延迟。

任务：

实现无动画占位符（胶囊体）的八向移动与冲刺。

实现单次轻攻击，包含明确的前摇、判定帧、后摇。

实现基础受击硬直与简单的血量扣减。

验收标准：输入响应延迟 < 3帧，攻击取消逻辑无死锁。

Phase 2: 核心机制扩展 (Core Mechanics)

目标：建立战斗策略循环。

任务：

接入完整的技能系统，支持至少3个不同机制的技能。

实现资源（体力/法力）的消耗与恢复循环。

加入闪避/格挡机制及无敌帧（i-frames）逻辑。

Phase 3: AI与内容填充 (AI \& Content)

目标：提供可交互的战斗对象。

任务：

实现基础敌人AI，能根据距离切换巡逻与攻击状态。

配置3种不同攻击模式的敌人。

完善UI（血条、技能CD指示器）。

Phase 4: 表现与打磨 (Juice \& Polish)

目标：提升打击感与视听反馈。

任务：

接入真实动画资产，配置BlendTree与动画事件。

实现顿帧、粒子特效、受击材质闪烁。

性能优化：使用对象池（Object Pool）管理子弹与特效，避免运行时GC。

4\. AI输出约束 (AI Output Constraints)

代码规范：使用C#（Unity）或C++（UE），遵循SOLID原则，关键逻辑必须添加中文注释。

避免硬编码：所有数值必须通过 \[SerializeField] 或配置类暴露。

性能意识：禁止在 Update() 中使用 GetComponent、Find 或频繁分配内存（如 new 关键字）。

分步交付：每次只输出一个模块的代码，并附带测试方法（如何在编辑器中验证该模块）。



战斗系统模块设计文档：仇恨与噪音感知系统

1\. 系统定位与核心原则

系统定位：本模块负责处理AI的“目标选择”与“感知响应”逻辑。它是连接玩家行为（输入/战斗）与AI状态机（FSM）的桥梁。

设计原则：

数据驱动：仇恨阈值、噪音衰减曲线等参数必须独立配置，禁止硬编码。

信号驱动：系统仅监听全局事件（如伤害事件、音频事件），不主动轮询玩家状态。

正交解耦：仇恨（数值维度）与噪音（空间维度）作为两个独立的输入源，最终汇入同一个“目标评估器”进行综合计算。

2\. 仇恨产生与累积机制设计

仇恨系统采用加权累加模型。AI内部维护一个动态更新的“目标仇恨列表（Threat Table）”。

2.1 仇恨产生源 (Threat Sources)

直接伤害 (Direct Damage)：

规则：仇恨增量 = 伤害数值 × 伤害仇恨倍率。

特性：即时生效，通常具有最高的基础权重。

噪音刺激 (Noise Stimulus)：

规则：仇恨增量 = 噪音基础音量 × 噪音仇恨倍率 × 距离衰减系数。

特性：空间感知型。衰减系数由“声源坐标”与“AI坐标”的欧氏距离决定。

强制指令 (Taunt/Override)：

规则：直接将目标的仇恨值设为 当前最高仇恨值 × 强制覆盖倍率，或直接标记为“最高优先级”。

特性：无视常规累加逻辑，用于坦克职业或特殊机制。

2.2 仇恨累积与衰减

持续累积：只要目标在AI的感知范围内且持续产生上述行为，仇恨值单调递增。

记忆衰减（可选）：当目标脱离感知范围或停止产生仇恨行为时，仇恨值随时间按指数曲线衰减，直至归零并从列表中移除。

3\. 仇恨转移与锁定逻辑 (Target Evaluation)

AI在状态机的决策节点（如每帧或固定Tick）执行目标评估，遵循以下优先级与阈值规则：

3.1 目标锁定规则

初始锁定：当仇恨列表从空变为非空时，直接锁定当前最高仇恨目标，FSM切换至“追击/警戒”状态。

持续锁定：若当前目标的仇恨值依然为最高，保持锁定状态不变。

3.2 仇恨转移（OT）阈值机制

为防止AI目标频繁闪烁，引入转移阈值（Hysteresis）：

近战阈值：当潜在新目标的仇恨值 > 当前锁定目标仇恨值 × 近战转移倍率（如1.1）时，触发目标转移。

远程阈值：当潜在新目标的仇恨值 > 当前锁定目标仇恨值 × 远程转移倍率（如1.3）时，触发目标转移。

强制转移：若新目标带有“强制指令”标签，无视上述阈值，立即转移。

4\. 噪音与仇恨的融合评估模型

当AI同时接收到“视觉/伤害仇恨”与“听觉/噪音仇恨”时，采用综合评分模型（Composite Scoring）：

4.1 评分公式

最终目标权重 = (伤害仇恨 × 伤害权重) + (噪音仇恨 × 噪音权重) + 视觉确认加成

4.2 状态联动

纯噪音触发：若仅有噪音仇恨而无伤害仇恨，AI进入“警戒/调查（Alert/Investigate）”状态，移动至噪音源坐标。

视觉确认：在“调查”状态下，若AI的视觉锥捕捉到产生噪音的目标，自动将“视觉确认加成”加入评分，并无缝切换至“攻击（Aggressive）”状态。

调查失败：若AI到达噪音源坐标且在超时时间内未获得视觉确认，清除该噪音仇恨，返回“巡逻（Patrol）”状态。

5\. 系统输入输出接口规范 (API Contract)

输入接口（监听全局信号）：

OnEntityDamaged(target, damageAmount)

OnNoiseEmitted(source, volume, worldPosition)

输出接口（供状态机读取）：

GetCurrentTarget() -> 返回当前锁定的实体Transform/ID。

GetTargetState() -> 返回当前目标的感知状态（如：None, Alert, Confirmed）。



## 实现进度（2026-09-14）

**Phase 1 基础原型 — 已完成（FSM + 攻击 + 受击硬直 + 冲刺 + 伤害管线）**

已确认（见 04_OPEN_QUESTIONS.md 第 8/9/10 条）：用 **GDScript** 实现；保留鼠标点击寻路，
FSM 包裹而非替换；分模块交付。

代码位置：

| 文件 | 职责 |
| :--- | :--- |
| `Scripts/combat/state.gd` | IState 基类：enter / physics_update / exit / handle_input + `transition_requested` 信号 |
| `Scripts/combat/state_machine.gd` | 状态机：注册状态、每帧驱动、**延迟切换**（避免攻击取消死锁）、同状态不重入、外部 `force_transition` |
| `Scripts/combat/states/player_idle_state.gd` | Idle：进入即停；检测有移动目标 → 请求切 Move |
| `Scripts/combat/states/player_move_state.gd` | Move：调 `follow_path()`；目标消失 → 请求切 Idle |
| `Scripts/player.gd` | 功能组件层：暴露 `has_move_target() / set_move_target() / clear_move_target() / follow_path() / stop_moving()` |

解耦：移动实现（A* 寻路、路点推进、卡住重算）全部在 `player.gd`，状态机只调接口、不感知实现。

| `Scripts/combat/damage_pipeline.gd` | 伤害管线（修饰器模式）：FinalDmg = (Base × Πmultipliers − Defense) × Variance |
| `Scripts/combat/states/player_attack_state.gd` | Attack：前摇 → 判定帧 → 后摇，后摇末段可取消接击 |
| `Scripts/combat/states/player_hitstun_state.gd` | HitStun：硬直 + 击退衰减位移 |
| `Scripts/combat/states/player_dodge_state.gd` | Dodge：朝鼠标冲刺，期间无敌帧，退出进冷却 |
| `Scripts/combat/states/player_dead_state.gd` | Dead：进入即 RunManager.player_died() |
| `Scripts/player.gd` | 功能组件层：移动 + 战斗能力（HP/Hitbox/输入缓冲/无敌帧/死亡） |
| `Scripts/enemy.gd` + `Scenes/Enemy.tscn` | 敌人：HP、可被攻击击杀、接触伤害（根节点改 Area2D） |
| `Scenes/Player.tscn` | 新增 Hitbox（Area2D，仅在判定帧开启 monitoring） |

数值全部在 `Data/config.json` 的 `combat` / `enemy` 节点（前摇/判定/后摇/伤害/距离/扇形角度、
硬直时长、无敌时长、冲刺时长与倍率与冷却、输入缓冲时长、按键码）。

编辑器验证方法：

1. F5 进基地 → 大门进局。
2. 状态切换日志：`[FSM] idle → move / → attack / → hitstun / → dodge`（开关 `debug.log_state_transitions`）。
3. 攻击：右键或 J，日志 `[Combat] 命中敌人，造成 25 伤害`；敌人 HP 40 → 两刀击杀消失。
4. 受击：走到敌人身上，HUD 左下角 HP 掉 10，日志 `[Combat] 玩家受到 10 伤害…`，
   人物被击退并硬直约 0.25 秒（此时移动/攻击无效）。
5. 冲刺：空格，人物朝鼠标方向快速位移；冲刺中撞敌人不掉血（无敌帧 i-frames）。
6. 死亡：HP 归零 → 中央结算"你死了"，按 R 回基地。

**Phase 2 核心机制扩展 — 模块一已完成：技能系统 + 资源（体力）循环**

| 文件 | 职责 |
| :--- | :--- |
| `Scripts/combat/skill.gd` | 技能数据 + 冷却（数值全读 config，不含硬编码） |
| `Scripts/combat/skill_system.gd` | 装配技能表 / 体力与冷却校验 / 释放（挂 Player 下，发 `skill_cast`、`skill_rejected` 信号） |
| `Scripts/combat/states/player_skill_state.gd` | 技能三段式：前摇 → 生效 → 后摇（按 type 分派 AOE / DASH / BUFF） |
| `Scripts/combat/fx_ring.gd` | 冲击波圆环（灰盒特效，播完自毁） |
| `Scripts/player.gd` | 功能层新增：体力（消耗/延迟回复）、护盾减伤、圆形 AOE 伤害、突进沿途伤害、1/2/3 按键路由 |
| `Data/config.json` | `combat.stamina`（100 上限 / 16 每秒 / 0.8 秒回复延迟）+ `combat.skills`（三技能全部数值） |

三个技能（AI 暂定，待用户追认，见 04 待回答第 1 条）：
1 蒸汽爆发（AOE + 击退）｜2 钩爪突进（位移穿刺）｜3 齿轮护盾（限时减伤）。
释放即扣体力并起冷却（被打断也照扣）；体力/冷却不足时指令留在输入缓冲里自动重试。

**Phase 3 基础敌人 AI — 已完成（巡逻 + 追击，2026-09-14 用户定）**

| 文件 | 职责 |
| :--- | :--- |
| `Scripts/enemy.gd` | 功能层：感知（视野/距离）、共享 A* 寻路、路径推进、休眠开关、接触伤害 |
| `Scripts/combat/states/enemy_patrol_state.gd` | 巡逻：出生点附近随机游走 + 到达停留 |
| `Scripts/combat/states/enemy_chase_state.gd` | 追击：跟丢计时 + 节流重算路径 |

验证方法（编辑器 / headless）：

1. 靠近敌人到 10 格内 → 日志 `[FSM] patrol → chase`，敌人开始追你（速度 ×1.35，仍慢于玩家 160）。
2. 跑远脱离视野 3 秒 → `[FSM] chase → patrol`。
3. 按 1：人物周围泛起黄色冲击波圆环，附近敌人掉 30 血并被击退，日志 `[Skill] 范围命中 N 个目标`。
4. 按 2：朝鼠标方向突进，沿途敌人各吃 20 伤害（同一目标只吃一次）。
5. 按 3：日志 `[Skill] 齿轮护盾：减伤 60%…`，此时被敌人碰到只掉 4 血（10 → 4）。
6. 底部 HUD：体力条随消耗/回复变化，技能栏显示 CD 倒计时。
7. headless 回归：`debug.auto_enter_run = true` + `--headless --quit --quit-after 900`，
   可看到地图生成、100 敌人、资源点、拾取、饥饿扣血日志，且无 SCRIPT ERROR。

**补充（2026-09-15 用户定）：敌人视野墙体遮挡 + 击杀掉落已实现**

* can\_see\_player() = 距离 + 视线采样（0.35 格步长），隔墙看不见；跟丢只走最后已知位置
* 击杀按 enemy.drop.chance（75%）原地掉 LootNode，种类加权随机、数量 2~6
* 自检（临时脚本已删）：隔墙可见=false、同侧可见=true、40 次击杀掉落 29 次（≈75%）、数量全在区间内

下一步（Phase 2 剩余 + Phase 4 表现）：连招派生链（输入缓冲扩展）、
顿帧 Hit Stop / 屏幕震动 / 伤害飘字 / 搜刮时减速（手感清单）。


## 8.噪音机制（2026-09-15 已实装，设计稿见下文）

实现要点（与 02 第 10 节、config 的 noise 节点一致）：

* 全局广播中心 `NoiseSystem`（autoload，project.godot 注册）：`NoiseSystem.emit(世界坐标, 强度)`。
* 派发：遍历 enemies 组，按 `距离线性衰减 ×（隔墙 0.5）` 派发，低于 min\_notice 忽略。
* 敌人：累加 `noise_alertness`，三档阈值驱动行为——
  suspicious(15) 转黄原地留意 / investigate(30) 转橙前往声源（enemy\_investigate\_state）/
  combat(70) 用追击速度（狂暴）；每帧 decay\_per\_second(10) 衰减回巡逻。
* 敌人咆哮联动：进入 Chase 时 emit 咆哮(160)，惊动附近同伴（警报扩散）。
* 视觉：声源处生成扩散圆环（半径=实际可听范围）+ 敌人本体按状态染色。
* 触发点：玩家攻击(120)/蒸汽爆发(90)/钩爪突进(60)/齿轮护盾(45)/冲刺(40)/脚步(22) 均在对应状态里 emit。

**性能取舍（对照设计稿第 2 点）**：用「事件广播 + 直接遍历 enemies 组」替代物理 Area2D 扩散，
噪音事件频次很低（动作触发），100 敌人并发也不会爆；视野/噪音遮挡统一用网格采样而非每帧射线。

设计稿（原始草案，保留供参考）：

1\. 噪音产生有哪些方式？

1\. 噪音产生有哪些方式？

在 Godot 中，噪音的产生可以非常灵活，主要分为以下三类：

动作触发（人物/怪物攻击）：通过监听动画帧或输入事件触发。例如，在 AnimationPlayer 的攻击动画中，利用“方法调用轨道（Method Track）”在挥砍命中或开枪的瞬间，调用一个 emit\_noise() 函数。

状态触发（怪物呐喊）：可以利用 AI 状态机（如 AnimationTree 或行为树）。当怪物进入“警戒”或“狂暴”状态时，触发特定的咆哮声，同时向系统广播一个噪音事件。

环境与建筑触发：例如伐木场在 \_process 中每隔几秒产生一个持续的噪音信号，或者玩家踩到碎玻璃（通过 Area2D 碰撞检测）触发一次性噪音。

2\. 噪音如何表现？是否有性能瓶颈？

绝对不要用物理碰撞体（如圆形 Area2D）来模拟噪音扩散，100个敌人同时产生噪音会导致严重的物理计算性能瓶颈。

小地图 UI 展示（CanvasItem 绘制）

如果你不想用 Shader，可以在小地图的 Control 节点下，动态生成简单的 TextureRect（圆形图标），配合 Tween 节点实现放大并淡出（Alpha 1.0 -> 0.0）的动画效果。由于只有 100 个左右的敌人，同时存在的噪音事件通常不会超过几十个，使用 Tween 动态生成/销毁 UI 节点对 Godot 来说毫无压力。

3\. 噪音如何降低？

在 Godot 中，降低噪音（掩蔽/衰减）可以通过以下机制实现：

环境掩蔽（白噪音区）：在地图的瀑布或暴雨区域放置一个 Area2D。当玩家或怪物进入该区域时，触发 body\_entered 信号，在代码中将当前产生的噪音强度乘以一个衰减系数（如 0.2），或者直接在 UI 上屏蔽该区域的噪音显示。

物理遮挡（射线检测）：在发出噪音时，向目标方向发射一条 RayCast2D。如果射线在到达目标前碰到了“墙壁”碰撞层，则判定噪音被阻挡，目标接收到的噪音强度减半。

音频层面的降噪（Low-pass Filter）：利用 Godot 的音频总线（Audio Bus），在 SFX 总线上挂载 AudioEffectLowPassFilter。当角色处于“掩蔽区”时，通过代码动态调低滤波器的 cutoff 频率，让声音听起来发闷，配合视觉上的降噪，增强沉浸感。

4\. 敌人听到噪音的反馈：累加还是直接寻找？

对于只有 100 个敌人的精英局，强烈建议采用“累加阈值 + 状态机”的设计，而不是直接瞬移寻路：

累加机制：给每个敌人设置一个 noise\_alertness（噪音警觉度）变量。远处的枪声可能只增加 10 点，而近处的爆炸增加 80 点。

阈值触发：当 noise\_alertness < 50 时，敌人原地转头看向声源（疑惑状态）；当 > 50 时，触发“前往声源搜索”的逻辑；当 > 100 时，进入“狂暴/战斗”状态。

衰减机制：在 \_process 中，如果没有新的噪音，noise\_alertness 会随时间缓慢下降。这能完美模拟“听到动静 -> 走过去看看 -> 没发现人 -> 慢慢放松”的真实 AI 逻辑。

5\. 是否还有其它的参考设计？

动态寻路权重（NavigationServer）：这是 RTS 游戏的神技。当某处产生巨大噪音时，通过 Godot 的 NavigationServer 动态修改该区域导航网格（NavigationMesh）的 travel\_cost（通行代价）。敌人不需要写复杂的逻辑，它们会自动像水流一样，沿着低代价的路径涌向噪音源。

程序化噪音地形（Perlin Noise）：结合你之前提到的想法，可以用 FastNoise2 等插件生成地图的“声学材质”。例如，柏林噪音值低的区域生成草地（吸音），噪音值高的区域生成金属废墟（扩音），让地图本身成为噪音玩法的核心。

AI 语音动态生成（CosyVoice3）：既然敌人只有 100 个，你可以将 AI 语音合成（如阿里开源的 CosyVoice3）作为本地 Web 服务接入 Godot。让怪物根据当前的“警觉度”动态生成不同情绪的叫声（如低语、怒吼），这比播放预制音效高级得多。




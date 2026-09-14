# 02\_SYSTEM\_SPEC.md — 系统规格

## 1\. 地图生成

* 尺寸：原型阶段 128x128（最终值待定，方向为大地图 + 60 分钟局内节奏）
* 生成方式：FastNoiseLite 噪声生成地形（阈值以上=墙），中心 5x5 强制出生区
* 边界：地图四周强制 1 圈外墙（与基地一致），玩家不可能跑出地图范围
* 连通性保障（已实现）：生成后从出生点洪水填充得出可达区域；
可达地板占比 < map.min\_reachable\_ratio（30%）时换种子重新生成（最多 max\_regen\_attempts=10 次）；
撤离点与敌人只刷在可达格内 → 出生点与每个撤离点之间必然走通
* 导航网格（已实现）：基于 walls 网格为每个地板格生成可通行多边形，挂载 NavigationRegion2D；
玩家点击地面时调用 NavigationServer2D.map\_get\_path 自动避墙寻路
* 资源点：随机放置，密度可配置（已实现，见第 2 节；同样只刷可达格）
* 撤离点：由 ExtractionSystem 调度（见第 4 节时间轴）
* 敌人：由 EnemySystem 生成（见第 6 节）

## 2\. 搜刮系统（已实现）

* 交互方式：自动拾取——玩家移动进入拾取半径（loot.pickup\_radius\_px，默认 20px）即自动获得 10 单位（loot.amount\_per\_node），资源点消失；背包格满时拾取失败，冷却 loot.pickup\_retry\_seconds（0.5 秒）后自动重试
* 资源点生成（loot 节点）：占可达地板格的 density（5%）比例，只刷可达格；每个点随机绑定一种资源（按 rarity 加权：common 3 / rare 1）
* 资源种类（resources 节点）：木头/石头/铁/金币/石油/食物，各带名称、稀有度、价值、占位颜色
* 局内背包：每种物品占 1 格；物品种类数 ≤ backpack\_capacity（默认 10，局外升级）；格满时新种类拾取失败（资源点保留），已有种类可继续叠加
* HUD 左下角常驻背包栏（种类数/容量 + 明细）
* 食物用途（2026-09-14 用户定：食物是战斗资源）：局内每 60 秒自动消耗 1 个；
  背包无食物则进入饥饿状态，每 30 秒扣 5 血；按 H 主动吃 1 个回 25 血（冷却 1 秒）。
  实现在 survival_system.gd，数值在 config 的 survival 节点（详见第 9 节）
* 资源点显隐由雾系统控制（视野内才可见，同敌人规则）
* 仓库入库规则（storage 节点）：撤离成功自动入库；默认 20 格（warehouse\_capacity 可升级 +5/级），每种物品叠加上限 1000，超出截断丢弃、仓库满则新种类整组丢弃（日志提示）

## 3\. 限时系统

* 局内倒计时 60 分钟（session.time\_limit\_seconds = 3600），HUD 顶部常驻显示
* debug.time\_scale 可加速倒计时用于测试（只加速计时，不加速玩家）
* 时间到 → 判定超时失败（与死亡同罚：全部丢失）

## 4\. 撤离系统（已实现）

* 时间轴（extraction 节点，全部可配置）：

  * 30 分钟：随机开启 3 个撤离点
  * 45 / 55 分钟：各随机关闭 1 个；最后一个开放至超时
* 选址：只刷在地板格，距出生点 ≥ min\_distance\_from\_spawn\_cells，彼此 ≥ min\_distance\_between\_points\_cells；采样失败过多自动放宽
* 关闭顺序：撤离点生成时即洗牌预定（不是到点才随机）；到点按预定顺序关闭
* 关闭保护：轮到关闭的点若玩家正在圈内，改关预定顺序中的下一个；全部都有玩家在场则本轮作废
* 小地图（extraction.minimap 节点）：

  * 撤离点开启时（30 分钟）左上角弹出，按比例呈现全图地形，显示 duration\_seconds（60 秒）后消失
  * 每次关闭前 warn\_before\_close\_seconds（60 秒）再次弹出，并将即将关闭的撤离点标为警示橙圈闪烁
  * 玩家=绿点（实时位置）、开放撤离点=白点；尺寸 size\_px 可配置
* 撤离方式：进入圆形触发区域站够 extraction\_hold\_seconds（3 秒），离开重置
* 撤离进度弧有脉冲动画（手感清单 ✓）
* 成功/失败分支接入 RunManager（extract / player\_died / timeout）

## 5\. 局外养成与基地（已实现）

* 存档系统：user://save.json（资源仓库 bank + 升级等级）
* 基地（base 节点）：64x64 固定平地+外圈墙；建筑每栋 4x4 格，布局手工配置（cell=左上角格）
* 建筑（靠近按 E 交互，按住不重复触发）：

  * 仓库（warehouse）：查看资源库存面板
  * 雕像（statue）：局外升级面板——两条线（生存/获取），显示名称/等级/当前值/费用，按钮购买即时生效并存档
  * 出发大门（gate）：按 E 进入一局
* 流程：启动进基地 → 大门进局 → 撤离/死亡/超时结算（按 R 回基地）→ 雕像升级 → 再进局
* 面板打开时游戏暂停（process\_mode=ALWAYS 保持面板可交互）
* 升级项配置：meta\_progression.\*.{name, format, base, per\_level, max\_level, cost}；费用=cost×(当前等级+1)

## 6\. 敌人与视野（已实现）

* 敌人生成（enemy 节点）：每局 count（100）个；只刷在地板格；距玩家出生点 ≥ min\_distance\_from\_player\_cells（20 格）；位置不重复（合法格洗牌抽取）
* 敌人 AI（2026-09-14 用户定：巡逻 + 追击，已实现）：
  * Patrol 巡逻：在出生点周围 patrol\_radius\_cells（6 格）内随机选可达点走过去，到达后停留 patrol\_idle\_seconds（1.5 秒）
  * Chase 追击：视野 vision\_cells（10 格）内发现玩家即追，速度 × chase\_speed\_multiplier（1.35，仍略慢于玩家 160）；脱离视野 lose\_sight\_seconds（3 秒）后放弃，回巡逻
  * 复用 combat/state\_machine.gd：enemy\_patrol\_state / enemy\_chase\_state；移动与感知在 enemy.gd 功能层
  * 性能（100 个敌人）：A\* 网格由 EnemySystem 构建一次、全体共享；追击路径按 repath\_interval\_seconds（0.4 秒）节流重算；距玩家 > ai\_active\_radius\_cells（32 格）的敌人休眠，完全不跑 AI
* 视野墙体遮挡（2026-09-15 用户定"加"）：
  * can\_see\_player() = 距离判定 + 视线采样：沿两点连线按 enemy.los\_step\_cells（0.35 格）采样墙格，命中任一墙即判定被遮挡（不用物理射线，100 个敌人每帧 raycast 太贵）
  * 跟丢后不再读玩家实时坐标：只走向**最后已知位置**（last known position，看到玩家时每帧刷新），走到后原地搜索，直到 lose\_sight\_seconds 满才放弃回巡逻
  * 总开关 enemy.vision\_blocked\_by\_walls（true），关掉即退回纯距离判定
* 击杀掉落（2026-09-15 用户定"要掉落"）：敌人 HP 归零时按 enemy.drop.chance（75%）在原地生成一个 LootNode（复用资源点场景，缩放 0.8 与地图资源点区分）；种类按 enemy.drop.weights 加权随机（木/石/食 3、铁 2、金/油 1），数量 amount\_min~amount\_max（2~6，低于地图点的 10）
* 战斗原型属性（Phase 1 临时设定，待追认见 04 待回答第 11 条）：

  * 敌人有 HP（enemy.max\_hp=40），归零即消失（并按上述规则掉落）
  * 玩家碰到敌人 → 承受接触伤害（enemy.contact\_damage=10），每敌人独立冷却
    （enemy.contact\_cooldown\_seconds=1.0）
  * 根节点由 Node2D 改为 Area2D：既可被玩家 Hitbox 检测，也能检测玩家进入
* 战争迷雾（player.vision\_radius\_cells = 10 格）：

  * 未探索区域：黑色遮罩
  * 已探索区域：永久揭开（探索记忆保留）
  * 敌人只在玩家当前视野半径内显示，视野外隐藏（与探索记忆无关）
  * 遮罩层 z\_index 最高，撤离点在未探索区域同样不可见

## 7\. 战斗系统（Phase 1 原型已实现，见 06\_FIGHT.md）

* FSM 状态：Idle / Move / Attack / HitStun / Dodge / Dead（Scripts/combat）
* 攻击三段式：前摇 windup → 判定帧 active（开 Hitbox 结算）→ 后摇 recovery，
  后摇末段有 cancel\_window，输入缓冲里的攻击可取消后摇直接接下一击
* 攻击判定：Hitbox（Area2D，半径 combat.attack.range\_px），扇形角度
  combat.attack.arc\_degrees，单次挥击每目标只命中一次，最多 max\_targets 个
* 伤害管线：DamagePipeline（修饰器模式），
  FinalDmg = (Base × Πmultipliers − Defense) × RandomVariance
* 受击：HitStun 硬直 + 击退位移衰减 + 受击后短暂无敌
  （combat.player.invincible\_after\_hit\_seconds）
* 冲刺：Dodge 朝鼠标方向位移，期间无敌帧（i-frames），退出进冷却
* 死亡：HP 归零 → Dead 状态 → RunManager.player\_died()（本局资源全丢）
* 生命上限来源：进局时取局外养成结果 Meta.get\_stat("survival.max\_hp")（2026-09-14 用户确认），
  config 的 combat.player.max\_hp 仅作兜底默认值
* 技能系统（Phase 2 模块一，已实现）：PreCast 前摇 → Cast 生效 → PostCast 后摇 → Cooldown，
  释放即扣体力并起冷却（被打断也照扣）；三个技能在 config 的 combat.skills 节点：
  | 键 | 技能 | 机制 | 消耗 / CD |
  | :--- | :--- | :--- | :--- |
  | 1 | 蒸汽爆发 | 自身圆形 AOE（72px）+ 击退 | 25 体力 / 4 秒 |
  | 2 | 钩爪突进 | 朝鼠标方向突进，沿途穿刺（每目标一次） | 20 体力 / 5 秒 |
  | 3 | 齿轮护盾 | 2.5 秒内减伤 60% | 30 体力 / 8 秒 |
* 体力（Stamina）：上限 100，消耗后延迟 0.8 秒再以 16/秒 回复；
  释放前校验，不足则失败（指令保留在输入缓冲里，冷却/体力恢复后自动重试）
* 操作：鼠标右键 / J = 攻击，空格 = 冲刺，左键 = 移动目标，1 / 2 / 3 = 技能，H = 吃食物

## 8\. 手感清单（AI 实现约束）

* \[x] 冲刺短暂无敌
* \[ ] 伤害飘字
* \[ ] 命中停顿
* \[ ] 屏幕震动
* \[ ] 搜刮时角色减速
* \[x] 撤离进度条脉冲动画



## 9\. 生存系统（食物，已实现）

* 自动进食：局内每 meal\_interval\_seconds（60 秒）消耗 food\_per\_meal（1）个食物；
  时间走局内时间轴（乘 debug.time\_scale，与倒计时/撤离点同步）
* 饥饿：自动进食时背包没食物 → 进入饥饿状态，每 starvation\_interval\_seconds（30 秒）
  扣 starvation\_damage（5）血（直接扣血，不进受击硬直、不击退）
* 主动进食：按 H（survival.eat\_key）消耗 1 个食物回 heal\_per\_food（25）血，
  冷却 eat\_cooldown\_seconds（1 秒）；满血或无食物时不消耗
* HUD：左下角常驻"食物 xN + 下次进食倒计时"，饥饿时标红提示
* 实现：survival\_system.gd（挂 Main 下，组 survival\_system），
  通过 RunManager.consume\_loot() 扣背包、Player.heal() / Player.apply\_direct\_damage() 改血量

## 10\. 数值配置

所有数值统一放 Data/config.json，禁止硬编码。


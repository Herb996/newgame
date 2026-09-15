# 05_PROJECT_STRUCTURE.md — 项目结构与架构

> 本文件描述代码骨架的组织方式。改动目录结构或新增顶层系统时，更新本文件。

## 目录总览

```
SteamPunkExtraction/
├── *.md                        设计文档层（决定"做什么"）
├── Data/
│   └── config.json             全部游戏数值（铁律：脚本里禁止硬编码数值）
├── project.godot               Godot 项目入口
├── Scripts/
│   ├── config_loader.gd        总管家①：数值配置读取（autoload: Config）
│   ├── meta_progression.gd     总管家②：局外养成+存档（autoload: Meta）
│   ├── noise_system.gd         噪音系统（autoload: NoiseSystem，全局噪音广播+距离/墙体衰减+视觉圆环）
│   ├── run_manager.gd          总管家③：一局的生命周期（挂在 Main 下）
│   ├── main.gd                 顶层装配脚本（开局→生成地图→出生玩家→撤离调度）
│   ├── map_generator.gd        程序化地图生成（噪声地形+墙体碰撞+占位瓦片+洪水填充可达性分析+导航网格，返回 walls/reachable/占比）
│   ├── combat/                  战斗层（06_FIGHT.md 蓝图，用户确认用 GDScript 实现）
│   │   ├── state.gd             IState 基类（enter/physics_update/exit + 切换请求信号）
│   │   ├── state_machine.gd     有限状态机（注册/驱动/延迟切换/同状态不重入）
│   │   ├── damage_pipeline.gd   伤害结算管线（修饰器模式：Base×Π−Defense×Variance）
│   │   ├── skill.gd             技能数据与冷却（数据全读 config，不含硬编码数值）
│   │   ├── skill_system.gd      技能装配 / 体力与冷却校验 / 释放（发信号，挂在 Player 下）
│   │   ├── fx_ring.gd           冲击波圆环（灰盒特效，播完自毁）
│   │   └── states/              玩家：idle / move / attack / hitstun / dodge / skill / dead
│   │                            敌人：patrol / investigate / chase
│   ├── player.gd                玩家功能组件（点击选中+寻路移动+体力+技能效果，对外暴露接口供 FSM 调用，组: player）
│   ├── camera_controller.gd    独立相机控制器（WASD/方向键平移 + F 回到玩家，边界限制，挂载到 GameRoot）
│   ├── extraction_system.gd    撤离点调度（时间轴开启/关闭+预定关闭顺序+小地图触发）
│   ├── extraction_point.gd     撤离点本体（触发区域+站N秒+进度弧脉冲，组: extraction_points）
│   ├── enemy_system.gd         敌人生成（数量/距离可配置，地板采样不重复）
│   ├── enemy.gd                敌人功能层（感知/寻路/移动/受击/接触伤害/击杀掉落/噪音警觉度与听觉；AI=巡逻+调查+追击，视野含墙体遮挡，组: enemies）
│   ├── loot_system.gd          资源点生成（密度可配，可达格采样，稀有度加权绑定资源）
│   ├── loot_node.gd            资源点本体（色块占位+进入拾取半径自动拾取；setup 可指定数量与缩放，敌人掉落物复用本场景，组: loot_nodes）
│   ├── fog_system.gd           战争迷雾（黑幕+探索记忆+敌人/资源点视野内显隐）
│   ├── minimap.gd              左上角小地图（全图比例地形+玩家绿点+撤离点白点，限时弹出，组: minimap）
│   ├── base_system.gd          局外基地（64x64 平地+建筑布局，建筑交互信号转发）
│   ├── building.gd             基地建筑本体（4x4 色块+名称+按 E 交互，组: buildings）
│   ├── warehouse_panel.gd      仓库面板（资源库存展示，暂停时打开）
│   ├── statue_panel.gd         雕像升级面板（两线养成 UI，购买即时生效）
│   ├── survival_system.gd      局内生存（食物自动消耗/饥饿掉血/按 H 进食回血，组: survival_system）
│   └── hud.gd                  局内 HUD（倒计时+阶段提示+体力条+技能栏+生存栏+结算面板）
├── Scenes/
│   ├── Main.tscn               顶层装配场景（RunManager + GameRoot + 各系统 + HUD/Minimap/两面板）
│   ├── Player.tscn             玩家（CharacterBody2D + 相机跟随）
│   ├── ExtractionPoint.tscn    撤离点（Area2D + 圆形触发区域）
│   ├── Enemy.tscn              敌人（Area2D + 警示红占位图形，可被攻击/可造成接触伤害）
│   ├── LootNode.tscn           资源点（Area2D + 资源色块 + 拾取提示）
│   └── Building.tscn           基地建筑（Area2D + 色块 + 名称/提示标签）
└── Assets/
    ├── Art/                    美术素材（按 03_ART_STYLE_GUIDE.md 生成）
    │   ├── Source3D/           3D 源模型（GLB/OBJ + viewer.html 预览，2.5D 出图源）
    │   ├── Raw/                AI 生成的原始大图（1024²，出图中间产物，不进引擎）
    │   └── Sprites/Player/     玩家四向待机基准帧（48×48，规格见 03）
    └── Audio/                  音效
```

## 三大总管家

| 单例/节点 | 访问名 | 职责 | 生命周期 |
| :--- | :--- | :--- | :--- |
| config_loader.gd | `Config` | 读 Data/config.json，`Config.get_value("map.width")` 取任意数值 | 游戏全程 |
| meta_progression.gd | `Meta` | 存档（user://save.json）、资源仓库、升级购买、`get_run_stats()` 折算局内加成 | 游戏全程（跨局持久） |
| run_manager.gd | Main 子节点 | 一局状态机 IDLE→RUNNING→ENDED；倒计时；结算（extracted/died/timeout） | 单局 |

## 系统接入方式

后续每个系统只对接总管家的公共接口，不自己开倒计时/写结算：

| 系统 | 接入接口 |
| :--- | :--- |
| 搜刮系统 | `RunManager.add_loot(resource_id, amount)` |
| 撤离系统 | 站够 N 秒后调 `RunManager.extract()`（N = session.extraction_hold_seconds） |
| 战斗系统 | `player.state_machine.force_transition(&"hitstun")`（外部强制切状态）；玩家死亡时调 `RunManager.player_died()` |
| 局外基地 UI | `Meta.bank` / `Meta.buy_upgrade(key)` / `Meta.get_stat(key)` / `Meta.get_upgrade_cost(key)` |
| 技能系统 | `player.skill_system.try_cast(skill_id)`（校验体力+冷却 → 切 skill 状态；失败发 `skill_rejected`） |
| 生存系统 | `RunManager.consume_loot("food", n)` / `Player.heal()` / `Player.apply_direct_damage()` |
| 一切数值 | `Config.get_value("点路径", 默认值)` |

## 撤离点时间轴（已实现）

60 分钟一局四阶段：0-30 搜刮期无撤离点 → 30 分钟开 3 个 → 45/55 分钟各随机关闭 1 个 → 最后一个开放至超时。
调度在 extraction_system.gd，全部数值在 config.json 的 `extraction` 节点（count / spawn_at_minutes / close_one_at_minutes / 距离约束 / trigger_radius）。

## 搭建进度（对应步骤 1-4）

- [x] 步骤 1：项目骨架 + config 读取（三大总管家就位）
- [x] 步骤 2：玩家 + 地图 + 相机（128x128 噪声地形，点击选中+点击地面寻路移动，占位瓦片为纯色块，正式素材待生成）
- [x] 步骤 3：撤离闭环（撤离点调度+交互+HUD 倒计时/结算）
- [x] 敌人与视野：100 个敌人（距玩家≥20格）+ 战争迷雾（视野10格、未探索黑屏、敌人视野外隐藏）
- [x] 步骤 4：局外基地（64x64 平地+仓库/雕像/大门，按 E 交互；大门进局、R 回基地、升级购买闭环）
- [x] 战斗系统 Phase 1 基础原型（完成）：FSM 六状态（idle/move/attack/hitstun/dodge/dead）+ 延迟切换；
      攻击三段式（前摇/判定帧/后摇 + 取消后摇接击）、Hitbox 扇形判定、DamagePipeline 伤害管线、
      受击硬直+击退+受击无敌、冲刺无敌帧、HP 归零 → RunManager.player_died()。
      移动与战斗实现都在 player.gd 功能层，状态机只调公开接口（解耦）。
- [x] 战斗系统 Phase 2 模块一：技能系统（skill.gd / skill_system.gd / player_skill_state.gd）
      三个技能（1 蒸汽爆发 AOE / 2 钩爪突进 / 3 齿轮护盾）+ 体力消耗回复循环 + 冷却 + HUD 技能栏
- [x] 敌人 AI：巡逻 + 追击（enemy_patrol_state / enemy_chase_state；共享 A* 网格、
      路径节流重算、远距离休眠三项性能保护）
- [x] 食物/饥饿系统（survival_system.gd）：每 60 秒自动吃 1 个，断粮持续掉血，按 H 吃 1 个回 25 血
- [x] 局外养成进局内：max_hp 取 Meta.get_stat("survival.max_hp")；旧存档废弃资源自动清理
- [x] 敌人视野墙体遮挡（2026-09-15）：视线采样 + 跟丢走最后已知位置，不再透视追踪
- [x] 地图结构升级 Phase 1（2026-09-15）：4 生物群系分区（低频噪声）+ 植被成簇
      （成簇噪声让树成林而非均匀撒点）+ 密度提升 + 每株装饰随机缩放/翻转/亮度
- [x] 地形美术 Phase 2（2026-09-15）：AI 无缝纹理采样成 4 群系瓦片图集（地板 12 变体 /
      墙体 6 变体 + 墙顶受光派生）+ AI 原画抠图装饰物；map_generator 三层渲染
      （地形 / 装饰 / 雾）。贴图缺失或未导入时自动回退程序化逐像素绘制。
      装饰物按群系偏色（荒原枯黄 / 锈泽湿绿 / 石原冷灰），消除克隆感
- [x] 敌人击杀掉落（2026-09-15）：75% 概率原地掉 LootNode，数量 2~6
- [x] 技能组追认（2026-09-15 用户"先用着"）：三技能沿用，数值全在 config 的 combat.skills
- [x] 噪音机制（2026-09-15 已实装）：NoiseSystem 全局广播 + 距离/墙体衰减 + 敌人三档警觉度
      （suspicious/investigate/combat）+ enemy_investigate_state 调查状态 + 衰减 + 敌人咆哮警报扩散
      + 视觉反馈（声源圆环 + 敌人染色），玩家攻击/冲刺/技能/脚步均发声；数值全在 config 的 noise 节点
- [x] 地图观感调优 A 档（2026-09-15 二轮）：群系边界抖动 + 交界渗透（消除像素台阶）、
      biome_spread 修正群系分布失衡（原中间两段吃掉近九成面积）、图集色调分级
      （对比 → 去饱和 → 群系色调；铁律：主要动明度、色相只做轻偏移）、宏观明暗乘法混合层、
      装饰落地投影。参数全在 config 的 map.grade / map.macro_light / map.biome_border_* /
      map.biome_edge_blend / map.decor.shadow。详见 03 文档「观感调优」一节
- [ ] 地图观感调优 B 档（待做）：相机斜俯视（Y 压缩伪等距）、瓦片 16→32、墙体立体化
      （顶面亮 + 正面暗）、光照层（CanvasModulate + PointLight2D + 暗角）、装饰 y_sort 遮挡
      （注：其中"相机斜俯视 + 立体墙 + 光照"已由 3D 双轨制整体解决，见下一条）
- [x] 渲染范式切换：2D → 3D 双轨制（2026-09-15，用户选定路线 2）。**逻辑全留在 2D
      （LogicRoot, visible=false），渲染换成 3D（World3D）**；唯一入口 = `Scenes/Main3D.tscn`
      （`main.gd` / `Main.tscn` / `camera_controller.gd` / `fog_system.gd` 已删，
      `select_icon.gd` 保留 —— `Player.tscn` 的 `$SelectIcon` 引用它）。
      3D 模块：`map_render_3d`（地板 Texture2DArray 群系软混合 / 墙 MultiMesh / 装饰 GLB /
      矿脉）、`base_render_3d`、`entity_visual_3d`（敌人/资源点/撤离点/建筑）、
      `fog_3d`（战争迷雾，常驻跨局复用）、`player_visual_3d`（HD-2D 序列帧公告板）、
      `iso_camera_3d`（正交等距 + 滚轮平滑缩放/光标锚点）、`view_hint`（视野提示）。
      坐标桥接：3D 世界单位 = 2D 像素 / tile_size（**1 格 = 1 单位**），3D (x,z) ↔ 2D (x,y)。
- [x] 修「人物卡到树里」（2026-09-15，用户报障）。三个根因，全部修掉：
      ① **视觉穿模**：树模型矮胖（宽高比 0.73），旧版按"高度等比"缩放，6.5 高时
      冠幅横跨 5.3~6.3 格而只阻挡 1 格 → 站在邻格就被整棵树吞掉。改为**高度与
      水平占地分开控制**（config `map3d.model_height` / `map3d.model_footprint`，
      树 4.0 高 / 冠幅 ≤1.5 格，半径 0.75 < 邻格距离 1.0）。
      ② **物理与寻路不一致**：树/石格在 `walls` 里是障碍（参与 A* 与连通性），
      但渲染成地板瓦片 → TileSet 没有碰撞体，冲刺（速度×3 持续 0.22s ≈ 6.6 格）
      和击退能把玩家推进树格。新增 `map_generator._build_decor_collision()` 生成
      `DecorCollision` 静态碰撞（一个 StaticBody2D 挂 N 个整格 shape），开关
      `map.decor_collision.enabled`。
      ③ **硬卡死**：`_query_path` 只要起点或终点是 solid 就返回空路径 → 玩家进了
      树格后无论怎么点都走不动。改为**两端先吸附到最近可走格**
      （`MapGenerator.nearest_open_cell()`，玩家脱困 `nav.unstick_radius_cells=4`、
      点击吸附 `nav.snap_radius_cells=3`），敌人 `_set_path_to` 用同一份实现。
      回归探针 `Dev/probe_stuck`（7 断言，含"身处阻挡格能走出""点树能走"），全绿。
- [ ] 后续：手感清单四项（伤害飘字 / 命中停顿 Hit Stop / 屏幕震动 / 搜刮时减速）、
      连招派生链（输入缓冲扩展）、4 向精灵的方向切换与动画状态机（当前只接了 down 向静态帧）

## 当前操作

启动进入基地（64x64 平地，中央出生）：左键点击玩家选中（显示青色选中圈）→ 左键点击地面，玩家自动寻路走到该点；再次点击玩家取消选中。WASD/方向键平移屏幕（相机独立），按 F 回到玩家位置。
- 仓库（左侧铜锈色）：走到旁边按 E 查看资源库存
- 雕像（右侧淡金色）：走到旁边按 E 打开升级面板，点按钮购买（资源不足自动禁用）
- 出发大门（下方深棕色）：走到旁边按 E 进入一局
- 面板打开时游戏暂停，按 E 或 ESC 关闭
进局后：出生时周围 10 格亮（已探索）其余黑屏；敌人（警示红五边形）与资源点（六色色块）仅视野内显示；
敌人在各自出生点附近巡逻（6 格内随机游走），玩家进入其视野（10 格）会转为追击（速度 ×1.35，仍慢于玩家），
**视野受墙体遮挡**（隔墙看不见；被墙挡住后敌人只走向最后看到你的位置，不再透视追踪），
脱离视野 3 秒后放弃回巡逻；击杀敌人有 75% 概率原地掉落 2~6 单位资源（比地图资源点小一圈，走进即拾取）；
距玩家 32 格以外的敌人休眠不跑 AI（性能保护）；玩家走进资源点拾取范围（20px）自动拾取 10 单位（HUD 左下角背包栏实时显示）；HUD 顶部倒计时+阶段提示、左下角 HP 显示；小地图在 30 分钟弹出 60 秒、44/54 分钟（关闭前 1 分钟）再弹 60 秒（橙圈=即将关闭的点）。
战斗操作：鼠标右键 或 J = 攻击（朝鼠标方向，前摇→判定→后摇，后摇末段可接下一击）；空格 = 冲刺（朝鼠标方向，期间无敌，带冷却）；左键 = 指定移动目标；**1 = 蒸汽爆发**（自身圆形 AOE + 击退）、**2 = 钩爪突进**（朝鼠标位移并穿刺沿途敌人）、**3 = 齿轮护盾**（2.5 秒减伤 60%）。技能消耗体力（上限 100，消耗后延迟 0.8 秒按 16/秒 回复），体力或冷却不足时指令会暂存在输入缓冲里自动重试。碰到敌人会掉血并进入受击硬直，HP 归零即死亡结算。
生存操作：局内每 60 秒自动吃掉 1 个食物；**H = 主动吃 1 个食物回 25 血**（冷却 1 秒）；背包没食物会进入饥饿状态，每 30 秒扣 5 血（HUD 左下角标红提示）。
底部 HUD：中间体力条 + 技能栏（序号/名称/消耗/冷却），左下角 HP + 食物与下次进食倒计时 + 背包栏。
局结束（撤离成功/死亡/超时）：中央结算，按 R 返回基地；撤离带回的资源自动入仓库（20 格/每种 1000 叠加，超限丢弃并日志提示），仓库面板可查看格子占用。
测试技巧：debug.time_scale 当前为 20（加速局内倒计时，玩家速度不变）；用大门反复进出可快速验证多局状态重置。
debug.smoke_test = true 可回到 Phase 0 的三大件自检。

## 运行方式

用 Godot 4.x 打开 D:\SteamPunkExtraction（选择 project.godot），按 F5 运行。
预期：进入基地平地，白色小人可移动，看到仓库/雕像/大门三栋建筑（头顶有名称）。
输出面板日志：[Config] → [Meta] → [Base] 基地就绪 →（进局后）[Run] → [Map] → [Enemy] → [Loot] 资源点生成完成 →（拾取时）[Run] 拾取 xx x10 →（30 分钟时）[Extraction] 撤离点已开启。

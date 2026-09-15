# 02_TECH_BUILD.md — 架构、战斗实现与待办

> 本文件由原 05_PROJECT_STRUCTURE / 06_FIGHT / 07_TODO / noise.md 合并而成（2026-09-15 文档整合）。
> 设计与系统规格见 `00_GAME_DESIGN.md`；美术规范见 `01_ART_GUIDE.md`。

---

# 第一部分 · 架构

## 架构主线（拍过板的，别推翻）

* **唯一入口 = `Scenes/Main3D.tscn`**（`project.godot` 主场景，2026-09-15 用户确认"3D 唯一"）。
  BASE↔RUN 双模式：F5 → 3D 基地（无雾）→ 大门按 E → 3D 局内（有雾）→ 局结束按 R 回基地。
* **3D 双轨制：逻辑留 2D、渲染换 3D**。逻辑跑在 `LogicRoot`(Node2D, `visible=false`)，渲染在 `World3D`。
  坐标桥接：**3D 世界单位 = 2D 像素 ÷ `map.tile_size`**；3D `(x, z)` ↔ 2D `(x, y)`。
* **群系数据驱动**：加雪原等新地形只改 `config.json` 的 `map.biomes`，GDScript 零改动。
  图集列数随群系数 N 自动缩放（地板 N×12 / 墙 N×6 / 墙顶 N×6）。
* **地面着色**：`Texture2DArray` + 主导/次主导 id/权重数据贴图（R=id0, G=w0, B=id1, A=w1），
  不受 4 通道限制，支持任意 N 群系。
* **角色走 HD-2D 序列帧**（2D `Sprite2D` 与 3D `AnimatedSprite3D` **共用**一份 `config sprites`
  与 `player.gd.current_anim()`）。状态判定只写一份，否则两套必然漂移。
* **`Scripts/select_icon.gd` 不能删** —— `Player.tscn` 的 `$SelectIcon` 引用它。
* 2D 入口层已删除：`Scenes/Main.tscn`、`main.gd`、`camera_controller.gd`、`fog_system.gd`。
* 导航：2D 逻辑层的 AStarGrid2D / NavigationRegion2D 仍在用（3D 版敌人共享网格是否已迁移，
  见 00 文档「待回答」第 34 条）。

## Autoload（project.godot 实测）

| 单例 | 脚本 | 职责 |
| :--- | :--- | :--- |
| `Config` | config_loader.gd | 读 Data/config.json，`Config.get_value("map.width")` 取任意数值 |
| `Meta` | meta_progression.gd | 存档（user://save.json）、资源仓库、升级购买、`get_run_stats()` 折算局内加成 |
| `NoiseSystem` | noise_system.gd | 全局噪音广播 + 距离/墙体衰减 + 视觉圆环 |
| `ResourceRegistry` | resource_registry.gd | 地图实体注册表（树/石/矿脉登记；`harvest()` 尚无调用点） |

`run_manager.gd`（总管家③）挂 Main 下：一局状态机 IDLE→RUNNING→ENDED；倒计时；
结算（extracted / died / timeout）。

## 系统接入方式

后续每个系统只对接总管家的公共接口，不自己开倒计时/写结算：

| 系统 | 接入接口 |
| :--- | :--- |
| 搜刮系统 | `RunManager.add_loot(resource_id, amount)` |
| 撤离系统 | 站够 N 秒后调 `RunManager.extract()`（N = session.extraction_hold_seconds） |
| 战斗系统 | `player.state_machine.force_transition(&"hitstun")`；玩家死亡调 `RunManager.player_died()` |
| 局外基地 UI | `Meta.bank` / `Meta.buy_upgrade(key)` / `Meta.get_stat(key)` / `Meta.get_upgrade_cost(key)` |
| 技能系统 | `player.skill_system.try_cast(skill_id)`（校验体力+冷却 → 切 skill 状态；失败发 `skill_rejected`） |
| 生存系统 | `RunManager.consume_loot("food", n)` / `Player.heal()` / `Player.apply_direct_damage()` |
| 噪音 | `NoiseSystem.emit(世界坐标, 强度)`；敌人 `hear_noise()` |
| 一切数值 | `Config.get_value("点路径", 默认值)` |

## 目录总览（2026-09-15 与代码核实）

```
SteamPunkExtraction/
├── *.md                        设计文档层（00 设计 / 01 美术 / 02 本文件）
├── Data/config.json            全部游戏数值（铁律：脚本里禁止硬编码数值）
├── project.godot               主场景 Scenes/Main3D.tscn，渲染 gl_compatibility
├── Scripts/
│   ├── config_loader.gd        autoload: Config
│   ├── meta_progression.gd     autoload: Meta
│   ├── noise_system.gd         autoload: NoiseSystem
│   ├── resource_registry.gd    autoload: ResourceRegistry（树/石/矿脉注册表）
│   ├── main3d.gd               3D 顶层装配（BASE↔RUN 双模式）
│   ├── run_manager.gd          一局生命周期（挂 Main 下）
│   ├── map_generator.gd        程序化地图生成（噪声+群系+河流/裂缝带+洪水填充+A* 网格+2D 渲染回退）
│   ├── map_render_3d.gd        3D 地形渲染（Texture2DArray 地面 + MultiMesh 贴地特征）
│   ├── base_render_3d.gd       3D 基地渲染
│   ├── entity_visual_3d.gd     实体占位视觉（棱柱/发光球/圆环/BoxMesh）
│   ├── player_visual_3d.gd     玩家 3D 视觉（AnimatedSprite3D billboard + 脚底锚点 + 软投影）
│   ├── player_animator.gd      HD-2D 序列帧驱动（2D/3D 共用）
│   ├── fog_3d.gd               3D 战争迷雾
│   ├── iso_camera_3d.gd        3D 斜俯视相机（滚轮缩放：平滑+光标锚点+对称步进+自适应限位）
│   ├── view_hint.gd            视角提示
│   ├── player.gd               玩家功能组件（点击寻路+战斗+体力+技能，组: player）
│   ├── select_icon.gd          选中圈（Player.tscn 引用，勿删）
│   ├── extraction_system.gd    撤离点调度（时间轴+预定关闭顺序+小地图触发）
│   ├── extraction_point.gd     撤离点本体（触发区域+站N秒+进度弧脉冲）
│   ├── enemy_system.gd         敌人生成（数量/距离可配，共享 A* 网格）
│   ├── enemy.gd                敌人功能层（感知/寻路/受击/接触伤害/掉落/噪音警觉度）
│   ├── loot_system.gd          资源点生成（密度可配，稀有度加权）
│   ├── loot_node.gd            资源点本体（自动拾取；敌人掉落复用本场景）
│   ├── fog_system 已删（3D 用 fog_3d.gd）
│   ├── minimap.gd              小地图（限时弹出，玩家绿点/撤离点白点）
│   ├── base_system.gd          局外基地（64x64 平地+建筑布局）
│   ├── building.gd             基地建筑本体（按 E 交互）
│   ├── warehouse_panel.gd      仓库面板
│   ├── statue_panel.gd         雕像升级面板
│   ├── survival_system.gd      局内生存（食物/饥饿/H 进食）
│   ├── hud.gd                  局内 HUD（倒计时+体力+技能栏+生存栏+结算）
│   └── combat/                 战斗层（GDScript 实现，见第二部分）
│       ├── state.gd / state_machine.gd        IState 基类 + FSM（延迟切换/同状态不重入/force_transition）
│       ├── damage_pipeline.gd                 伤害管线（Base×Π−Defense×Variance）
│       ├── skill.gd / skill_system.gd         技能数据+冷却 / 装配+校验+释放
│       ├── fx_ring.gd                         冲击波圆环（现为 2D _draw，3D 错位待修，见 3.A）
│       └── states/                            玩家 idle/move/attack/hitstun/dodge/skill/dead
│                                              敌人 patrol/investigate/chase
├── Scenes/
│   ├── Main3D.tscn             唯一入口
│   ├── Player.tscn / Enemy.tscn / LootNode.tscn
│   ├── ExtractionPoint.tscn / Building.tscn
├── Dev/                        回归探针组（probe_registry / probe_terrain_map /
│                               probe_player_anim / probe_zoom / probe_map3d_full / probe_render）
├── tools/                      build_tile_atlas.py / make_decor_sprites_final.py /
│                               gen_player_frames.py / gen_ground_3d.py / run_godot_headless.py
├── images/                     敌人原画 40 张（约 150MB，不进版本库）
└── Assets/
    ├── Art/                    美术素材（规格见 01_ART_GUIDE.md）
    │   ├── Source3D/ · Raw/    出图源材料（.gdignore）
    │   ├── Sprites/Player/     玩家序列帧
    │   ├── Terrain3D/          3D 地面纹理（ground_snow.png 等）
    │   └── Tiles/              atlas_floor.png / atlas_wall.png
    └── Audio/                  音效（目前空目录）
```

---

# 第二部分 · 战斗系统实现（原 06_FIGHT.md）

## 蓝图核心原则（参考，已按 GDScript 落地）

* 分层架构：功能组件层（移动/动画/碰撞）→ 策略层（技能/Buff/AI）→ 行为决策层（FSM/输入）。
* 数据与逻辑分离：战斗数值全在 config.json，禁止硬编码。
* 事件驱动：系统间信号通信，避免强耦合。
* ~~服务器权威~~：单机游戏，不适用。
* ~~C#/C++~~：已确认用 GDScript（决策日志第 7 条）。
* 连招派生链已取消——本作非动作游戏，攻击为离散动作。

## 实现进度

**Phase 1 基础原型 — 已完成**（FSM + 攻击 + 受击硬直 + 冲刺 + 伤害管线）

| 文件 | 职责 |
| :--- | :--- |
| `combat/state.gd` | IState 基类：enter / physics_update / exit / handle_input + `transition_requested` 信号 |
| `combat/state_machine.gd` | 状态机：注册、每帧驱动、**延迟切换**（避免攻击取消死锁）、同状态不重入、`force_transition` |
| `combat/states/player_idle_state.gd` | Idle：进入即停；有移动目标 → 请求切 Move |
| `combat/states/player_move_state.gd` | Move：调 `follow_path()`；目标消失 → 请求切 Idle |
| `combat/damage_pipeline.gd` | 修饰器模式：FinalDmg = (Base × Πmultipliers − Defense) × Variance |
| `combat/states/player_attack_state.gd` | Attack：前摇 → 判定帧 → 后摇，后摇末段可取消接击 |
| `combat/states/player_hitstun_state.gd` | HitStun：硬直 + 击退衰减位移 |
| `combat/states/player_dodge_state.gd` | Dodge：朝鼠标冲刺，期间无敌帧，退出进冷却 |
| `combat/states/player_dead_state.gd` | Dead：进入即 RunManager.player_died() |
| `player.gd` | 功能层：移动 + 战斗能力（HP/Hitbox/输入缓冲/无敌帧/死亡），状态机只调接口不感知实现 |
| `enemy.gd` + `Scenes/Enemy.tscn` | 敌人：HP、可击杀、接触伤害（根节点 Area2D） |

数值全在 `Data/config.json` 的 `combat` / `enemy` 节点。

**Phase 2 模块一 — 技能系统 + 体力循环（已完成）**

| 文件 | 职责 |
| :--- | :--- |
| `combat/skill.gd` | 技能数据 + 冷却（全读 config） |
| `combat/skill_system.gd` | 装配 / 体力与冷却校验 / 释放（发 `skill_cast`、`skill_rejected`） |
| `combat/states/player_skill_state.gd` | 三段式：前摇 → 生效 → 后摇（按 type 分派 AOE / DASH / BUFF） |
| `combat/fx_ring.gd` | 冲击波圆环（灰盒） |

三技能：1 蒸汽爆发（AOE+击退）｜2 钩爪突进（位移穿刺）｜3 齿轮护盾（限时减伤）。
释放即扣体力起冷却（被打断照扣）；体力/冷却不足留在输入缓冲自动重试。

**Phase 3 敌人 AI — 已完成**（巡逻 + 调查 + 追击；共享 A*、节流重算、远距休眠；
墙体视线遮挡 + 最后已知位置；击杀掉落 75%）

**噪音机制 — 已实装（2026-09-15）**，规则与数值见 00_GAME_DESIGN.md 3.10。要点：
事件广播 + 遍历 enemies 组（替代物理 Area2D 扩散）；距离线性衰减 × 隔墙 0.5；
网格采样视线（与视野同源），绝不做每帧射线；三档阈值 suspicious(15)/investigate(30)/combat(70)；
衰减 10/秒；咆哮警报扩散；声源圆环 + 敌人染色。

### 噪音原始设计稿（存档参考，已实装部分以上文为准）

* 噪音产生：动作触发（动画帧/输入事件调 emit_noise）/ 状态触发（AI 咆哮）/ 环境触发（伐木场周期噪音、踩碎玻璃）。
* 表现：不要用物理碰撞体模拟扩散（100 敌人爆性能）；小地图用 TextureRect + Tween 放大淡出。
* 降低：环境掩蔽（白噪音区 Area2D 衰减系数）、物理遮挡（隔墙减半）、音频低通滤波（SFX 总线 LowPass）。
* 反馈模型：累加阈值 + 状态机（优于直接寻路）——noise_alertness 累加、阈值分档、无新噪音时缓慢衰减，
  模拟"听到动静→去看→没发现→放松"。
* 未做的参考项：NavigationServer 动态 travel_cost（RTS 神技）、程序化声学地形（草地吸音/金属扩音）、
  AI 语音动态生成（CosyVoice3 本地服务按警觉度合成低语/怒吼）。

### 编辑器验证方法（回归用）

1. F5 进基地 → 大门进局；状态切换日志 `[FSM] idle → move / → attack / …`（开关 `debug.log_state_transitions`）。
2. 攻击：右键或 J，`[Combat] 命中敌人，造成 25 伤害`；敌人 HP 40 → 两刀击杀消失。
3. 受击：撞敌人掉 10 血 + 击退硬直约 0.25 秒；冲刺中撞敌人不掉血（无敌帧）。
4. 技能：1 黄环 AOE 30 伤+击退；2 突进沿途各吃 20；3 护盾期碰伤 10→4。
5. 视野遮挡自检（历史）：隔墙可见=false、同侧可见=true、40 次击杀掉落 29 次（≈75%）。
6. headless 回归：`debug.auto_enter_run = true` + `--headless --quit --quit-after 900`，
   看地图生成/100 敌人/拾取/饥饿日志，无 SCRIPT ERROR。

---

# 第三部分 · 待办与交接（原 07_TODO.md）

> 状态基线（2026-09-15）：**项目可运行、回归全绿**（flow_test 47/47、probe_registry 35/35）。

## A. 先做这几件事

1. **`debug.time_scale` 仍是 20.0，正式玩前改成 1.0**（局内倒计时/生存计时 ×20，不影响移速）。
   `map.force_seed` 已还原 0、`debug.map_preview` 已还原 ""。
2. 推送由用户自己操作（`SteamPunk_Update.bat`）。⚠️ `images/` 约 150MB **不进版本库**（已拍板，加 .gitignore）。
3. 🔴 **阻塞 bug：人物卡进树/石头**（根因已定位，未修）：
   物理层与寻路层不一致——`map_generator.gd` 把树/石写进 `walls`（A* 绕开），
   但 `_build_tileset()` 只给墙瓦片加碰撞，装饰 Sprite2D 无碰撞体，`move_and_slide()` 直接穿过。
   **推荐修法 A**：加一层纯物理 `BlockerLayer` TileMapLayer（全透明整格碰撞瓦片），
   对 `walls[y][x]==true && terrain[y][x]==false` 的格 set_cell；visible=false 不影响物理。
   验收：探针确认玩家最终位置不落在任何 walls 格内。

## B. 进行中：地形调参（河水/裂缝过头）

实测（种子 20260915）：河水占地板 43%、裂缝 28%，树被饿死（182 vs 应有 ~860）。

* **河水**：`river.width_cells` 1.3 → **建议 0.30~0.45**，只留 1~2 条朝向（河道应稀、长、蜿蜒）。
* **裂缝**：`width_cells` 0.75 < 1 格退化成麻点 → **至少 ~0.9**；`frequency` 0.075 → **0.018~0.03**
  （缝要长；视觉细靠贴图暗纹，不靠带宽压到 1 格以下）。
* `orientation` 每项是采样域 2×2 线性变换 `[a,b,c,d]`（各向异性拉长等值线成河/缝，否则闭合水塘）；
  两组朝向改成明显不同角度避免网格感。
* 修好带宽后树会自己回来，届时复查森林密度与荒原矿脉数量。
* 看效果**要看图不看数字**：
  `"$GODOT" --headless --path D:/SteamPunkExtraction Dev/probe_terrain_map.tscn`
  → `Dev/terrain_stats.png`（群系）/ `terrain_decor.png`（装饰与带子）；
  全图俯视设 `debug.map_preview` + `map_preview_cells=128` 跑主场景。
* 调试期固定 `map.force_seed` 才能对比。

**待确认**（已同步 00 文档待回答）：「木头」要不要独立装饰类型（倒木/树桩 DECOR_LOG）；
雪原减速 0.62 是否更低。

## C. 素材：敌人原画接入（`images/`，40 张/10 组）

单角色单姿势（非序列帧），3136×1344，带背景色差 + 右下角「即梦 AI」水印。
10 组：贵族1（蒸汽贵族）、丧失1/2（机械僵尸/骨偶）、机械1-4（铜甲兵/双龙/蛮牛）、南巨（霸王龙 BOSS）、青眼白龙1/2。

三步管线（每步有现成脚本可抄）：
1. 抠背景+去水印 → `Assets/Art/Sprites/Enemy/`（水印右下角固定，先裁再抠）。
2. 派生 4 向 idle+walk 序列帧 → 照 `tools/gen_player_frames.py`（分层抠腿、2px 整数倍位移）。
   原画只有正面/侧姿：要么补画/ AI 补背面侧面，要么退一步先 billboard 单向跑通（已拍板最终 4 向）。
3. 接进 3D → 照 `player_visual_3d.gd` 复制 `enemy_visual_3d.gd`（AnimatedSprite3D + billboard +
   脚底锚点 + 软投影），替换 `entity_visual_3d.gd` 棱柱占位。

**建议先只做 1~2 个**（机械1 铜甲士兵 + 贵族1 精英），管线跑通再批量。

## D. 功能缺口

### A 类 · 逻辑在跑、3D 里看不见（补视觉，性价比最高）

| 项 | 现状 | 要做的事 |
|---|---|---|
| 噪音环/技能 AOE 环 | `fx_ring.gd` 是 2D `_draw()`；`noise_system._spawn_ring()` 找 GameRoot 节点，Main3D 没有 → fallback 用像素坐标画，3D 里完全错位 | 改 3D 表现：TorusMesh/PlaneMesh + 自发光材质，世界坐标。**听觉逻辑本身正常**，只是玩家看不到反馈 |
| 采集交互 | `ResourceRegistry.harvest()` 全项目零调用 | 3D 射线命中树/矿脉 → registry → harvest() → 隐藏精灵（资源点 loot_node 自动拾取是另一条链路，已通） |
| 玩家 attack/dodge/hit/dead 无帧 | 走程序化形变 | 补 4 状态序列帧（扩展 gen_player_frames.py） |

### B 类 · 完全没做

* POI / 巢穴 / 水域结构（00 文档 3.1 已定方向）
* 敌人 / 资源点 / 撤离点 / 建筑真模型（现为棱柱/发光球/圆环/BoxMesh 占位）
* 音效（`Assets/Audio/` 空目录，全程无声）
* 基地地板/墙体正式美术（现 `wall_plate.png` 临时顶）
* 小地图资源/敌人/噪音标记（现只画撤离点）

### C 类 · 素材阻塞

* `Assets/Art/Sprites/{Enemy,Loot,Building}`、`Art/UI` 全空
* `Art/Models/` 只有 debris/rock/tree 三个 GLB
* `Source3D/player_character.glb` 纯静态网格（无骨骼/动画）——角色走 HD-2D 序列帧的原因

### 新拍板待排期（2026-09-15/16 问答，见 00 文档）

* **携带系统**（进局带初始装备/物资）+ **安全箱**（道具解锁）+ **保底初始装**（基地补发）
* **积分货币**（杀怪+生存获得；死亡低分入账、撤离翻倍；用于升级）
* **「失物怪」死亡回收（暂不排期）**：RunManager 结算时把未带出的背包+装备存进存档（per-死亡记录），
  后续对局由 EnemySystem 刷一只特殊怪背负；**每损失 N% HP 随机掉落一份遗失物**（复用掉落物管线），
  击败掉全部剩余——不必击杀。不需要局快照序列化。实现要点：Enemy.take_damage 里挂
  "血量跨阈值掉落"钩子 + 怪身上维护"剩余遗失物清单"。细则见 00 文档待回答 48
* **下蹲/静走状态**（前期潜行节奏的核心操作，降脚步噪音）
* 武器/护甲/暴击、投掷物引怪、远程敌人、机械vs丧尸阵营互殴（谁近打谁）、
  动态难度（怪死后剩余增强，**有上限**）
* 天气系统（局内动态切换、影响噪音、道具改天气）、采集玩法（harvest 接入口 + 自动采集建筑）、
  多档位存档、中英文 UI + 设置菜单、Steam 成就 + 云存档（与多档位结构需预留）
* 撤离点受击打断重置、每点只用一次（当前实现未做一次性消耗，需核实）
* 中长期大方向（先出设计稿再排期）：**抓宠撤离**（可控单位）、**RTS 发育/地形改造**

### 已闭环（别重复做）

局外成长 Meta（雕像升级/仓库/RunManager 注入/撤离入库/存档）、小地图、战争迷雾、撤离流程、
HUD（血量·体力·技能·生存·背包）、BASE↔RUN 双模式、滚轮缩放（平滑+光标锚点+对称步进+自适应限位）。

---

# 第四部分 · 环境备忘与工作方式

## 命令

```bash
GODOT="C:/Users/Administrator/Downloads/Godot_v4.7.2-stable_win64_console.exe"

# 纯逻辑验证（快，无渲染）
"$GODOT" --headless --path D:/SteamPunkExtraction Dev/probe_registry.tscn
"$GODOT" --headless --path D:/SteamPunkExtraction Dev/probe_terrain_map.tscn

# 新增素材后必须导入，否则 ResourceLoader.exists() 为 false
"$GODOT" --headless --path D:/SteamPunkExtraction --import

# 出图/截图：必须去掉 --headless（dummy 驱动 frame_post_draw 永不触发）
"$GODOT" --path D:/SteamPunkExtraction --resolution 1600x900 Scenes/Main3D.tscn

# 非侵入截帧（不改游戏代码；按项目视口尺寸录制，--resolution 不生效）
"$GODOT" --path D:/SteamPunkExtraction --write-movie <out>/f.png --fixed-fps 6 --quit-after 48 <scene>
```

## 调试开关（`Data/config.json` 的 `debug` 段）

| 键 | 作用 |
|---|---|
| main3d_start | `"base"`(默认) / `"run"` —— 跳过基地直接进局内 |
| flow_test | 端到端主流程自检（47 项断言，真按键注入 E、真跑 BASE→RUN→BASE→RUN） |
| smoke_test / auto_enter_run | 旧开关，仍可用 |
| main3d_capture / _delay / _frames | 自动截图；`_frames > 1` 连拍成序列帧 |
| map_preview / map_preview_cells | 出全图俯视预览 PNG |
| time_scale | 局内计时倍率（**正式玩前调回 1.0**） |
| log_state_transitions | FSM 切换日志 |

## 会反复踩的坑（血泪清单）

1. **`--headless` 出不了图** —— dummy 驱动，frame_post_draw 不触发。截图必须开窗口。
2. **渲染后端 gl_compatibility → SSAO 不可用**（Forward+ 专有）；雾 / glow / ACES 可用。
3. **JSON 数字一律解析成 float**。`[3.0].has(3)` 返回 false。凡 config 数组 include/相等比较两侧先 `int()`。
4. **Vector3i / Vector3 第二个槽是 y**，格坐标必须写 `Vector3i(x, 0, z)`（塞错会把实例压到一条边）。
5. **ArrayMesh / Texture2DArray 是 RefCounted，不能 free()**，交 GC。
6. **GDScript 不支持 `\` 行续接符和列表推导式**；缩进必须严格 tab。
7. **同一作用域不能重复 var 同名变量**——Godot 只报 "parser error" 不给行号。
   排查：建 probe_parse.gd 只写 `const MG = preload("res://Scripts/xxx.gd")` 逼出真实错误。
8. **Label 定位**：只改 offset_bottom 不会移动顶对齐 Label；按底边定位要同时给 offset_top +
   `vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM`。右锚点 Label 必须给足矩形宽度。
9. **断言 UI 真的画出来用 `is_visible_in_tree()`**，不能只看 `visible`（祖先隐藏时 visible 仍 true）。
10. **SPRITE_SCALE = 0.5**：48×48 画布显示 24×24；序列帧位移必须 2px 整数倍（1px 是亚像素看不见）。
11. **PlaneMesh 默认 orientation = FACE_Y（水平）**，别再转 X 轴 90° 会立成墙。
12. **⚠️ 编辑期间不要让 Godot 编辑器开着**——出过事故：编辑器退出时把旧缓冲写回，
    丢了 1700+ 行。恢复用 `git checkout HEAD -- <文件>`。开工前 `git status` + 看关键文件 mtime。

## 工作方式约定

* 推送由用户自己操作（`SteamPunk_Update.bat`），不要代为 push。
* 不要在一个消息里对同一文件并行发多个 Edit——会基于旧快照互相覆盖。改多处用一次性精确文本替换。
* 本机 bash coreutils 时好时坏，cmd.exe 被拦截。文件操作用 Python（os/shutil），别用 rm/cp。
* `map_generator.gd` 是 CRLF，`config.json` / `map_render_3d.gd` 是 LF——Python 原地改注意
  `newline=` 参数，否则整文件换行被改写（diff 炸锅）。

## 当前操作速查（键位）

基地：左键点玩家选中 → 点地面寻路移动；WASD/方向键平移相机，F 回玩家；
仓库/雕像/大门旁按 E 交互；面板打开时暂停，E/ESC 关闭。
局内：左键=移动目标，右键/J=攻击，空格=冲刺，1/2/3=技能，H=吃食物，E=交互，R=回基地。
局结束（撤离/死亡/超时）：中央结算，按 R 回基地；撤离带回资源自动入库。

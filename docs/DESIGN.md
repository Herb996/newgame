# SteamPunk Extraction — 总设计文档

> 单一设计文档，按 7 个维度组织：**0 设计思路 / 1 美术系统 / 2 流程系统 / 3 操作系统 / 4 数值系统 / 5 机制系统 / 6 音频系统**。
> 引擎 Godot 4.7 + GDScript；**当前实况为纯 2D 卡通奇幻「拾荒撤离」**，美术基于 Tiny Swords (Free Pack, Pixel Frog, CC0)。
> **本文以 `Data/config.json` 与 2D 运行线代码为准**（`main.gd` / `player.gd` / `enemy.gd` / `combat/` …）。`*3d.gd` / `Main3D.tscn` 为未接入主菜单的实验轨，本文只在必要处标注。
> 重写于 2026-09-16，逐条与代码/磁盘核对；**「⚠ 死配置 / 已定义未接线」**清单集中在 §4.8 与 §5.9，属当前真实状态，非笔误。

---

## 0. 设计思路（风格 / 技术 / 规范）

### 0.1 风格定位
- 俯视 2D 撤离冒险：进局 → 限时搜刮 → 撤离点开放 → 带资源撤离；**死亡 / 超时则本局携带资源全失**（硬核塔科夫向惩罚）。
- 世界观为「昔日王国遗迹上的拾荒」卡通奇幻；**与蒸汽朋克无关**。`menu.title` 已改为卡通奇幻口吻「王国废墟：拾荒撤离」。仍带 SteamPunk 字样的只剩英文副标题 `menu.subtitle`（`SteamPunk Extraction`）与工程名 `config/name`（`SteamPunkExtraction`，改名会牵动存档/路径，暂不动）；数据资源键 `oil`（对应内部 `steam`/`oil`/`gear` 命名）保留不动以兼容存档 —— 属命名/兼容残留，非主题。

### 0.2 技术基线
| 项 | 值 |
|---|---|
| 引擎 | Godot 4.7（`config/features` 标 GL Compatibility，`project.godot` 渲染器配 `forward_plus`）|
| 语言 | GDScript，纯脚本，**无外部运行时依赖** |
| 运行线 | **2D**：主场景 `Node2D`（`Main.tscn` → `main.gd`）；3D 轨仅存于仓库，不接入菜单 |
| 美术 | Tiny Swords Free Pack，64px 格，Nearest 采样（像素锐利） |
| 入口 | `project.godot: run/main_scene = StartMenu.tscn`；`menu.game_scene = res://Scenes/Main.tscn` |
| Autoload 顺序 | `Config → SaveSlots → DisplaySettings → Meta → NoiseSystem → ResourceRegistry`（`SaveSlots` 夹在 `Config` 与 `Meta` 之间：`Meta.load` 需先问有无激活槽）|
| 地图 | 运行时按 `config.json` 程序生成，128×128 格 × 64px = 8192×8192 px |
| 存档 | `user://saves/slot_NN.json`（6 槽）+ `user://saves/state.json`（记 last_slot/migrated）；用户设置 `user://settings.json` |

### 0.3 提前定死的规范
- **配置驱动、两处真相分离（三层优先级）**：`_overrides(内存) > _user(user://settings.json) > _data(Data/config.json)`（`config_loader.gd`）。出厂数值全在 `Data/config.json`；玩家在设置面板改的落**用户层**，**绝不回写 `Data/config.json`**（res:// 导出后只读，且会与版本管理打架）。「恢复默认」＝删用户层键回落出厂值。
- **键位存物理键码**（`event.physical_keycode` / `is_physical_key_pressed`）：捕获端与消费端一致，非 QWERTY 布局不错位。
- **调试既在 config 也有 `--` 参数（并存分工，非二选一）**：`debug.*` 是真实出厂开关（当前 `auto_enter_run=true`、`time_scale=20`、`log_state_transitions=false`）；`--` 参数是额外的「出图/诊断/回归专用只读通道」（`--seed` / `--preview-map` / `--capture2d` / `--soak*` / `--weapon` / `--no-fog` / `--no-macro` / `--menu-*`），动机是「不改 config 避免留脏配置」。优先级：`--seed` 压过 `map.force_seed`；`debug.smoke_test` 在 CLI 处理前判；CLI 接管成功则不进基地。
- **资源管线**：新增 PNG 后跑 `python tools/godot_import.py`；新增 `class_name` 后跑 `--headless --import`（全局类名缓存不重扫不认，否则 `load()` 静默返回 null）。回归用 `tools/run_godot_headless.py` / `run_regression.py`。
- **已废弃 / 删除**：技能系统（2026-09-16 删，代码 + config + UI 全删，`combat/skill*.gd` 已移除）；3D 双轨（不作为可玩线）。

---

## 1. 美术系统

### 1.1 美术基线与规格
- 来源 **Tiny Swords (Free Pack, CC0)**（原始包在 `images/Tiny Swords (Free Pack)/`，仅作派生来源，未直接进游戏），64px 格、Nearest 采样。
- 角色画布：**Warrior / Archer 192²**，**Lancer 320²**（长枪需更宽格），羊 128²。
- 脚底基准（实测，改锚点照此；`sprite_offset_y` 已写入 config）：

| 单位 | 画布 | 脚底 y | `offset_y` | `pixel_unit` | `scale` |
|---|---|---|---|---|---|
| blue_warrior (`sprites_ts`) | 192² | 137 | −41 | 10 | 0.6 |
| blue_archer (`sprites_archer`) | 192² | 136 | −40 | 10 | 0.6 |
| blue_lancer (`sprites_lancer`，**玩家当前用**) | 320² | 198 | −38 | 10 | 0.6 |
| enemy pawn/archer/monk | 192² | ~135 | −38~−40 | 6 | 1.0 |
| sheep | 128² | 84 | −20 | 4 | 1.0 |

> 玩家四兵种（warrior/archer/lancer/monk）`scale` 统一为 **0.6**、`pixel_unit` 统一 **10**：Tiny Swords 各兵种身体原生像素一致，只有枪兵画布更大（320，容长枪），故战士/弓兵若按 1.0 会明显比枪手大一圈；对齐到 0.6 后小队角色体型一致（脚底仍由 `offset_y` 公式自动锚定，不随 scale 漂）。

- 方向覆盖：**仅 Lancer 有真 8 向**（Attack/Defence 五向 + 左右镜像）；Warrior/Archer/Pawn 单向 + 水平镜像；Archer 有完整 Shoot 动作（免费包唯一自带拉弓帧）。

### 1.2 玩家与单位的真实贴图集（config 驱动）
- 玩家可选出击 **4 名**角色（config `characters.list`）：**枪手**=长枪（`spear` → `sprites_lancer` 8 向枪兵）、**弓兵**=弓（`bow` → `sprites_archer` 弓兵）、**剑士**=剑（`sword` → `sprites_ts` 战士）、**僧侣**=法杖（`staff` → `sprites_monk` 僧侣，2026-09-18 加入）。各武器已锁定自己的贴图集，未指定才回落 `player.sprite_set`。
  > **强弩（`sniper`）已于 2026-09-17 从出击名单移除**（用户原话：「强弩准备废弃了，风格不统一，太丑了」）—— 它用的是即梦 AI 立绘 `blue_crossbowman/`，与另外三人（Tiny Swords 原生素材）画风割裂。**武器配置块、精灵集、贴图、探针、`fire_hitscan()` 代码全部保留**，`characters.list` 里插回一条即可复活；敌人没有任何一种用这套贴图，故移除不影响敌人。
  > **僧侣（`monk`）2026-09-18 加入**：Tiny Swords Monk，五档配色齐全（Blue/Purple/Black/Yellow → 玩家档位，Red 已是敌人邪术师）。**官方没画 Attack 帧**（只有 Idle 6 / Run 4 / Heal 11 / Heal_Effect 11），沿用敌人 cultist 的先例 —— **Heal 帧就是攻击动作**（切出 `attack1_*` 与 `heal_*` 同像素两份命名，heal_fx_* 特效层不进动作序列）。本轮边界=「只加外观、能选能打」：新增 `combat.weapons.staff` **复用现成 melee 判定**（一行 combat 代码没改），数值定位=低伤(18)低噪(60，全场最安静)中距(140)近战；治疗机制是后续独立任务。**不在 `roster.starting` 出厂名册里**，走出击面板「补招新兵」获取（补招按钮遍历 characters.list 自动生成）。验收：`Dev/shot_monk_inrun.tscn` 开窗实拍（四人列队 / 四档配色 / Heal 施法当攻击动作），逐帧 `exists()` 断言 120 项全过。
- **每个角色有 4 套档位配色**（2026-09-17 加等级系统）：同一套 Tiny Swords 骨架、只换颜色，帧数完全一致。放在 `Units/{blue,purple,black,yellow}_{lancer,archer,warrior}/`，由 `tools/slice_{lancer,archer,warrior}.py <Faction>` 生成（`Faction` = `Blue`/`Purple`/`Black`/`Yellow`，对应素材包 `images/Tiny Swords (Free Pack)/Units/<Faction> Units/`）。档位 → 配色的映射在 `progression.tiers` + `progression.sprite_sets`，见 §5.10。**红色永远留给敌人**，玩家档位不许占用红色系。
- 现存贴图集（`Assets/Art/Sprites/`）：`PlayerTS/warrior_*`（192²，72 帧，历史/备用）、`Player/*`（48²，旧）、`PlayerHD/*`（512²，HD 备用）、`Units/blue_warrior|blue_lancer|blue_archer`（TS 单位）。
- 敌人/中立（`Units/`）：`red_pawn`(idle8·run6·attack4) / `red_archer`(idle6·run4·**attack8**) / `red_monk`(idle6·run4·attack11) / `yellow_pawn`(idle8·run6·attack4) / `sheep`(idle6·run4·graze12)。

### 1.3 当前已就位素材（磁盘实测）
| 类别 | 文件 | 规格 | 状态 |
|---|---|---|---|
| 地表 blob 图集 | `Tiles/TS/tilemap_color1..5.png` | 576×384，64px，4×4 blob autotile（草/荒/林/沼…）| 已有 |
| 3D 地面范式（第二套） | `Assets/Art/Terrain3D/ground_{grass,forest,marsh,rock,snow,waste}.png` + `wall_plate.png` | 1024² | 已有，与 TS blob **两套并存待拍板** |
| 薄条程序图集 | `Tiles/atlas_wall.png` / `atlas_floor.png` | 384×16 / 768×16 | 已有 |
| 水面 | `water_bg.png`(64²) / `water_foam.png`(3072×192=48×3,24帧) | — | 已有；**foam 未接线** |
| 装饰 | `Decor/tree_00..15 / rock_00..03 / stump_00..03 / bush_00..15 / pebble_00..15 / debris_*` | — | 已有 |
| 矿脉露头 | `Decor/ore_gold_00..05+gold_stone_00..03`(128²) / `ore_iron_00..02` / `ore_oil_00` | 128² | 金矿真；**铁=金矿染灰、油=程序糊紫黑斑（占位）** |
| 道具图标 | `Items/item_wood/stone/iron/gold/oil/food/arrow/scrap.png` | 64²(gold 128²) | 已有；**item_oil 画风突兀=程序占位** |
| 投射物 / 武器 | `Projectiles/arrow.png`(64²) | — | 已有；弩已画进 `blue_crossbowman` 角色帧（无独立武器贴图）；近战/弓无独立武器贴图 |
| 建筑 | `Buildings/house_large(128×192)/monastery(192×320)/castle(320×256)/archery/barracks/enemy_barracks/house_small/tower/shadow` | — | 已有；基地三建筑借用 TS 原图 |
| UI | `Assets/Art/UI/` | 仅 `.gitkeep` | **空，无任何 png** |

> **无死亡 / 受击专用帧**：全项目 Units 目录无 `dead_*` / `hit_*` 文件，改由程序化顶替（见 §5）。

### 1.4 需要的素材（按优先级，源自 `docs/asset_checklist.json` + 磁盘核对）
> 内部资源名（`oil`/`gear` 等）不变，只换视觉包装。

**P0 — 现在是占位、优先补**
- 铁矿脉露头（形状/色泽异于金矿，当前染灰易认错）｜油泉/魔法油潭（当前程序糊）｜油桶道具（`item_oil` 画风统一）。
- 死亡动画（玩家 + 4 敌 + 羊，各 6~8 帧，脚底 y 对齐 §1.1）｜受击/硬直帧（各 3~4 帧）｜四向行走帧（idle+walk 四向，左右镜像）。
- 水波 `water_foam` 接线 + 浅滩涉水层 + 深水 blob 岸线（当前水硬边纯色）。
- 真·怪物（骷髅兵/巨蛛/森林巨魔/精英怪，各 idle/run/attack）—— **当前 4 兵种全用人形士兵顶替、且仅正面 billboard**（`asset_checklist` A-19）。

**P1 — 画面缺一口气**
- 群系过渡 blob 瓦片（`t_blend`）｜桥/渡口/踏脚石｜奇幻废墟道具（断柱/符文石/雕像/营火/断剑/墓碑/水晶）｜基地建筑卡通化提质｜撤离点美术（现 `_draw` 圆环顶替 → 传送门/法阵）。

**P2 — UI 与打磨**
- 资源/状态图标（32²：木/石/铁/金/油/食物/HP/背包，当前纯文字或色点）｜技能图标遗留位｜小地图图例（玩家三角/敌人红点/撤离星标/矿脉点）｜基地地板墙体正式美术。

### 1.5 接入位置速查
| 补什么 | 放哪 | 还要改 |
|---|---|---|
| 矿脉 / 装饰 | `Assets/Art/Sprites/Decor/` | `map_generator.gd` 的 `ORE_PATH_LISTS` / `DECOR_PATH_LISTS` |
| 道具图标 | `Assets/Art/Sprites/Items/` | config `resources.<id>.sprite` |
| 单位帧 | `Assets/Art/Sprites/Units/<unit>/` | config `sprites_*` / `enemy_types.types[*]` / `animal_types.types[*]` |
| 角色档位配色 | `Assets/Art/Sprites/Units/{blue,purple,black,yellow}_{lancer,archer,warrior}/` | `tools/slice_{lancer,archer,warrior}.py <Blue\|Purple\|Black\|Yellow>`；config `progression.sprite_sets`（§5.10）|
| 建筑 | `Assets/Art/Sprites/Buildings/` | config `base.buildings[*].sprite` |
| 地形 / 水面 | `Assets/Art/Tiles/TS/` | config `map.biomes[*].tileset`、`map_generator.gd::TERRAIN_DIR` |

放完图必跑 `python tools/godot_import.py`，再 `tools/run_godot_headless.py` 回归。

---

## 2. 流程系统

### 2.1 安装 / 启动
- Godot 4.7 打开 `project.godot` 即跑，纯 GDScript 无外部依赖。`run/main_scene = StartMenu.tscn`。
- 无头 / 截图需显式给场景路径 `res://Scenes/Main.tscn`（否则默认进菜单）。

### 2.2 游戏菜单（StartMenu，`start_menu.gd`）
- 标题「王国废墟：拾荒撤离」+ 副标 `SteamPunk Extraction` + 版本行「开发版 · Tiny Swords 2D 线」。
- 入口非「开始游戏」按钮，而是**新建存档 / 历史存档** → 打开 6 槽面板（`slot_panel.gd`）→ 选槽 `SaveSlots.activate()` → `launch_requested` → 切场景到 `menu.game_scene`（Main.tscn）。
- `menu.enter_base_from_menu = true`：点开始后**先落主基地**（运行时把 `debug.auto_enter_run` 覆盖为 false，绕过 config 出厂的 true）。`ESC` 返回上一级 / 关子面板。
- 设置改动**先暂存**，点面板右下「确认应用」才写 `user://settings.json` 并生效；返回则丢弃未确认改动。

### 2.3 存档槽（`save_slots.gd` / `meta_progression.gd`）
- 6 槽 `user://saves/slot_%02d.json`；`user://saves/state.json` 记 last_slot / migrated。
- 旧单槽 `user://save.json` 首次**复制**进 1 号槽（不删旧档）。无激活槽（命令行直跑 Main.tscn）时 Meta 仍读写旧单槽。

- 槽内除 `bank` / `upgrades` / `base_layout` 外还有 **`roster`（名册）**：跨局持久的单位实例列表 `[{uid,id,name,level,xp}]`。等级挂在**具体的人**身上而不是兵种上 —— 因为死亡永久（见 §5.10）。

### 2.4 主基地（Base，`base_system.gd`，含于 `Main.tscn`）
- 64×64 **整片草地**（`base.map_size`；已去掉外圈挡边墙，四周边框与内部统一，基地无角色不需挡边）；建筑 **4×4 格**（`base.building_cells`）。**8 栋建筑**（2026-09-18 全量换上 Tiny Swords Blue Buildings 素材 `blue_*.png`，功能只做原有的 3 个，其余纯展示待接功能）：

| 建筑 | 默认 cell | sprite | 左键交互 |
|---|---|---|---|
| warehouse 仓库 | [24,30] | `blue_house1.png` | 打开仓库面板（只读展示 `Meta.bank`：种类数 / 仓库格数 / 叠加上限）|
| statue 修道院 | [36,30] | `blue_monastery.png` | 打开升级面板（`meta_progression` 生存/搜刮两组升级，即时生效并存档）|
| gate 出发大门 | [30,42] | `blue_castle.png` | 打开选人面板 →「出击」进局 |
| archery 箭术场 | [22,22] | `blue_archery.png` | 无（纯展示，点击 push_warning）|
| barracks 兵营 | [38,22] | `blue_barracks.png` | 无 |
| tower 瞭望塔 | [46,30] | `blue_tower.png` | 无 |
| house2 民居 | [20,38] | `blue_house2.png` | 无 |
| house3 民居 | [40,38] | `blue_house3.png` | 无 |

- **建筑渲染全自动**：`building.gd` 按贴图尺寸等比缩放进 4×4 格框（屋顶可向上探出 1.4 倍）、脚底对齐占地底边，缺图保底一块 id 配色方块不消失。新素材不覆盖旧图（`blue_` 前缀），旧 `castle/monastery/house_*` 仍被 3D 层 / 兜底引用。**新建筑 id 不在存档 `Meta.base_layout` 里 → 直接用配置 cell**；重摆过位置的旧建筑仍按存档摆放。
- **实拍坑**：出厂 config `debug.auto_enter_run = true`（headless 回归用），开窗实拍基地必须先 `Config.set_override("debug.auto_enter_run", false)` 再 instantiate Main —— 否则进基地立刻被拉进局、`game_root` 被清空（建筑 0 栋、满屏黑局内）。验证场景 `Dev/shot_base_buildings.tscn`（顺带打印 8 栋运行时清单 + 贴图路径）。

- **交互 = 鼠标左键点建筑本体**（基地无玩家角色；`building.gd` Area2D `input_event`）。面板打开时 `get_tree().paused=true`；`E` 或 `ESC` 关闭。
- **右键建筑 = 重摆位置**：进入 `placement_mode.gd`（可复用组件）→ 铺瓦片网格、把该建筑 footprint 能放的左上角锚点覆盖区标**绿**、半透明幽灵跟随光标 → 左键点绿格落位、ESC/右键取消。落位后 `base_system.apply_reposition` → `Meta.set_building_cell` 写进**当前存档槽**（`base_layout`，每存档一套布局，覆盖 config 默认；合法锚点须留 1 格外圈墙且不与其它建筑重叠）。此组件后续进图放东西可复用。
- **换模式必须收尾重摆**（2026-09-19）：`_enter_base()` 一直是 `_end_placement()` 开头的，`_enter_run()` 漏了 —— 而重摆中途也能出击（点大门走建筑交互，不经过放置模式的取消流程）。`PlacementMode` 挂在 `game_root` 下，`_clear_game_root()` 把它连带释放，但 `main._placement` 仍指着那个已死节点且**非 null**：`_overlay_open()` 从此恒真（ESC 退不出去），此后右键任何建筑也再也不肯进重摆（`if _placement != null: return` 永久拒）。现在两边都调，守卫见 `Dev/probe_second_launch.tscn` 的「出击 #4」。整条链路（基地 → 出击 → 撤离 → 再出击，共 4 次出击，23 项）由该探针守住：**双判据** = ①出击前记下 `GameRoot` 全部子节点的实例 id，回来逐一对残留；②按名字/挂载脚本判定"这是基地的东西"（`*Base*` / `building.gd`）—— 单看 id 会漏掉每局新建的同名节点，单看名字会把正常的 `Camera2D` 误报成残留。另验 `GameRoot` 子节点数逐局不增、相机恒 1 台。⚠ 它开头带**环境体检**：`GameRoot` 缺 `BaseMapRoot`/`MapRoot` 说明别处的脚本错误把 `_enter_base()/_enter_run()` 拦腰打断了，这时退出码 2（作废）而不是报一堆假失败。
- **进基地默认最远视角**：`base.fit_camera_on_enter=true` 时 `_enter_base` 用整片基地尺寸调 `camera_controller.frame_world_rect()` → 相机落到最远档并居中，一眼看全基地与所有建筑。
- 局外养成写入当前存档槽，影响下局 `max_hp` / **每人**背包容量（一人一份，§5.11）/ 仓库容量。

### 2.5 局内游戏（RUN）
- 随机地图（当前 `map.force_seed=20260915` 固定，便于测试）+ 敌人 100 + 中立羊 60 + 资源点 + 撤离点 3 + 2D 战争迷雾。
- 倒计时 `session.time_limit_seconds = 3600`（1 小时）；每帧扣 `delta × debug.time_scale`（当前 ×20 测试加速），≤0 → `timeout`。
- 撤离点时间线：`spawn_at_minutes=30` 刷满 3 个 → `close_one_at_minutes=[45,55]` 各关 1 个 → **最后 1 个保持开放直到超时**（超时＝死亡）。轮到的点若玩家站圈内则改关下一个，全有人则本轮作废。
- 单局循环：搜刮 → 撤离点开放 → 站圈保持 → 携带资源撤离；死亡 / 超时则本局携带资源全失。⚠ **掉一个角色 ≠ 他身上那份立刻没**：阵亡者整包就地撒成一地，队友走近还能捡回来（§5.11）—— 真正全丢的是**场上没活人**那一刻（局终 `died`）与 `timeout`。
- **底部菜单栏**（占屏高 1/5，`menu_bar.gd`，仅局内）：左＝小地图（常驻，开局就有）、中＝当前选中单位的指令面板（含**背包明细行**，右键弹窗开着就跟着显示同一个人）、右＝噪音读数（当前 / 累积 / 被惊动数）。详见 §3.5 与 §5.11。

### 2.6 结束 / 结算 / 退出（`run_manager.gd` / `hud.gd`）
- 三结局：撤离 `extract()`→"extracted"（**仅此结局 `bank_loot` 入库** + `Meta.grant_xp_to_survivors()` 给存活队员发经验，见 §5.10）；死亡 `player_died()`→"died"；超时→"timeout"（后两者携带资源全丢）。统一发 `run_ended`。
- 结算面板文案「按 R 返回基地 · ESC 退出」。`R` 仅当 `mode==RUN && state==ENDED` 时 `_enter_base()`。`ESC`(`ui_cancel`) 的退出改到 `main._unhandled_input` 且**仅当没有任何覆盖层打开时**（仓库/雕像/选人面板或放置模式都关着）才 `get_tree().quit()`；有面板时 ESC 交给面板自身关闭（否则会因"输入先于 _process、面板同帧 unpause"而误退出）。选人面板另有「放弃 · 返回基地」按钮。关窗亦可退出。

---

## 3. 操作系统

### 3.1 键位（默认，设置面板「操作」页可改；键码存物理键）
| 操作 | 默认 | 键源（config 键 = 值）| 生效时机 |
|---|---|---|---|
| 选中 / 移动 | 左键点玩家选中 → 左键点地面寻路 | `player.select_radius_px=64`, `path_arrive_threshold_px=24` | 即时 |
| 点小地图下令 | 左键点菜单栏小地图（= 点地图，同一个 `command_click`）| — | 即时 |
| 查看背包 | **右键点在角色身上**（命中半径同 `player.select_radius_px=64`）→ 头顶弹出**他这一份**背包（只读），菜单栏同步显示同一人 | — | 即时（详见 §5.11）|
| 取消指令 | 右键点在**空地/敌人身上**（解除指定目标 + 停巡逻 + 停下）| — | 即时 |
| 退出待点选 | `ESC`（仅「指定攻击 / 巡逻设点」进行中；无待点选时 ESC 才是退出游戏）| `ui_cancel` | 即时（⚠ 背包弹窗开着时这一次 ESC **只收弹窗**，不外泄成取消/退出）|
| 相机平移 | `WASD` / 方向键 | `camera.pan_speed=1600` | 相机 `_ready`（下局）|
| ~~普通攻击~~ | **已移除**：2026-09-17 起战斗全自动，无攻击键 | `combat.auto_attack.enabled=true` | 即时 |
| 闪避 | `空格` | `dodge_key=32` | 即时 |
| 进食 | `H` | `survival.eat_key=72` | 即时 |
| 相机回玩家 | `F` | `camera.return_key=70` | 相机 `_ready`（下局）|
| 交互建筑 | 物理 `E`（**硬编码**，不可重映射）| — | 即时 |
| 缩放 | 滚轮 / 触控板捏合，以光标为锚 0.35×–3.0× | `camera.zoom_*` | 相机 `_ready` |
| 边缘滚屏 | 鼠标贴窗口边（需窗口有焦点，`ignore_ui`；常驻底部菜单栏不挡）| `camera.edge_pan_*` | 相机 `_ready` |
| 局结束返回 | `R`（仅结算面板）| — | 即时 |
| 退出 | `ESC`（仅无面板/放置时）| `ui_cancel` | 即时 |

- 输入缓冲 `combat.input.buffer_seconds=0.25`：闪避等输入可预输入（按下入队，超 0.25s 丢弃）。攻击已无键位，不入缓冲。
- **自动战斗**（详见 §5.1）：角色自动索敌开打，只打「观察视野 ∩ 攻击距离」内的敌人，够不着的**不追击、原地不动**；小队全员（含未选中成员）都自动战斗，玩家只需指挥走位。

### 3.2 交互判定
- **建筑**：Area2D 碰撞矩形触发（宽 = `building_cells × tile × 0.86`），进入按物理 `E`。⚠ `base.interact_radius_cells=4.5` 在 2D 线**无消费点**（仅 `entity_visual_3d.gd` 用），不据此调 2D 交互范围。
- **资源点 / 掉落物**：走近 `loot.pickup_radius_px=80` 自动拾取入背包 —— 一人一份背包，所以**由压住它的角色里最近的那个活人**拿走；他的格子满（新种类）则失败并 `pickup_retry_seconds=0.5` 后重试。详见 §5.11。
- **撤离点**：站入 `extraction.trigger_radius=96` 保持 `session.extraction_hold_seconds=3` → 撤离；离开或点关闭则进度清零。
- **敌人**：身体接触造成伤害（`enemy.contact_cooldown_seconds=1.0`）。
- **菜单栏**：整条栏是 `mouse_filter=STOP` 的 Control —— 压在它上面的鼠标事件不会穿到世界（不会误下移动令），按钮/小地图各自接自己的点击。底部边缘滚屏：`camera_controller.edge_pan_active()` 已把常驻菜单栏（group `menu_bar`）从"悬停 UI 即停止滚屏"的规则里**豁免**，所以贴底边的向下滚屏照常可用（只有真正贴到最底 `edge_pan_margin` 才触发方向，栏中部按钮在其之上不会误滚）；仓库/雕像等**模态面板**仍会挡住滚屏。

### 3.3 设置面板（8 页，表驱动，`settings_panel.gd`）
- 页签：**画面 / 性能 / 音频 / 玩法 / 资源 / 操作 / 语言 / 调试**。
- **「资源」页**：上半「地形出现比例」= 四群系面积权重 `map.biome_weights.0~3`（草地/荒原/森林/沼泽，越大越占地方）；下半「地图资源成簇」= `tree/rock/iron/oil` 各自的 `count`（每群系簇数）+ 四群系 `weight`（最小聚合格数兼总量比例）。均下次生成地图生效。
- **「性能」页（降配提速）**：暴露此前未进面板、但被 2D 代码消费的降配杠杆——`enemy.ai_active_radius_cells`（休眠半径，每帧读取即生效）、`enemy.los_step_cells`（视线采样步长，即生效）、`player.vision_radius_cells`（迷雾揭示半径，下次进局）、`map.decor.shadow`（装饰投影，下次生成地图）；并给 **「性能优先」/「恢复均衡」一键预设**（`_PERF_BUNDLE`：一次性把 `decor.shadow/density`、`macro_light/grade.enabled`、`vision_radius`、`ai_active_radius`、`los_step`、`enemy.count`、`animals.count`、`loot.density`、`max_fps` 写入**用户层**，恢复均衡逐项清除回落出厂）。其余降配项散在「玩法」（资源点密度/敌人中立数量/装饰密度）与「画面」（明暗/调色/帧率上限/垂直同步）。
- **暂存 + 确认生效**：面板内所有编辑先进内存暂存（`_pending_set`/`_pending_clear`），**点右下「确认应用」才批量落盘 `user://settings.json` 并 `DisplaySettings.apply_all()`**（`display.*`/`audio.*` 即时作用，其余项下次进局 / 生成地图读到）；未确认前不写盘、不生效。每行右上有「默认」把该项暂存回出厂值。
- **界面形态**：全屏铺满（外层 Margin 留 28px）；每行标签左对齐、控件右对齐（两边对齐）；底部「确认应用」主按钮（无改动时禁用）+「N 处未确认」计数；「返回」若有未确认改动会弹二次确认再丢弃。
- 可改键 = 「操作」页 3 键（闪避 / 进食 / 相机回玩家），攻击无键位；底层写用户层嵌套 JSON（如 `{"combat":{"input":{"dodge_key":…}}}`），与 config 同构。「玩法」页新增 **自动战斗开关** `combat.auto_attack.enabled`、**观察视野** `player.vision_radius_cells`、**索敌间隔** `combat.auto_attack.scan_interval_seconds`。
- 语言页**非真 i18n**：选择存 `language.current`，但无翻译表，界面仍中文（`available` 仅 `zh_CN` ready，`zh_TW/en/ja` 未 ready）。

### 3.4 调试开关（真相：config + `--` 并存，见 §0.3）
- config `debug.*`（当前出厂）：`auto_enter_run=true`（菜单进游戏时被覆盖为 false）、`time_scale=20.0`、`log_state_transitions=false`、`smoke_test/flow_test=false`、`map_preview=""`(配 `map_preview_cells=128`/`_scale=0.125`)、`main3d_*`（仅 3D 线消费）。`time_scale` / `log_state_transitions` / `auto_enter_run` 亦挂设置面板「调试」页可改。
- CLI：`--seed`（压 `map.force_seed`）/ `--preview-map` / `--capture2d` / `--dump-atlas` / `--dump-biome` / `--zoom` / `--soak*` / `--weapon bow|sword|sniper` / `--no-fog` / `--no-macro` / `--menu-*`。

### 3.5 局内菜单栏（`menu_bar.gd` + `minimap.gd`，仅局内，占屏高 1/5）
- **高度**：`menu_bar.height_ratio=0.2` × 视口高，夹在 `min_height_px 160` ~ `max_height_px 320`；公式只写一份（`UiKit.menu_bar_height()`），HUD 的背包/血量/生存三行与右下角视野提示**按同一公式上移让位**，否则会被栏压住。`menu_bar.enabled=false` 时既不铺栏也不让位。
- **左槽 · 小地图**：`Minimap` 是 `Main` 下的独立 CanvasLayer（挂在 MenuBar 下，`layer=3`），由菜单栏把面板钉到左槽矩形（正方形，边长 = 栏高 − 2×内边距）。`set_embed_mode(true)` 后**常驻**（不再等撤离点开启才弹出）；撤离点开启 / 关闭前 60s 仍会调 `show_for()`，此时只是把边框与将关闭的点**闪烁高亮**，不再控制显隐。画（**绘制顺序即分层**，写在 `RENDER_LAYERS = [terrain, extraction, fog, squad]` 这个常量里，探针直接断言）：地形底图（地板暗棕 / 墙暗铜锈）→ 资源点（烘焙进底图，一次性）→ 撤离点白点 → **迷雾层**（未探索区纯黑，与主地图同一张遮罩，见 §5.6）→ 小队绿点。迷雾夹在撤离点与小队之间 = 「未探索处的撤离点/资源点自动被盖住，自己人永远看得见」——**靠叠放顺序实现，不查任何探索状态**：资源点已烘焙进底图天然被盖，撤离点画在雾下自然看不见。顺序错了不会报错、只会让迷雾形同虚设，所以单独拆出 `_draw_terrain/_draw_extraction/_draw_fog/_draw_squad` 四层并按 `RENDER_LAYERS` 分派，改前先读 `minimap.gd` 文件头。`texture_filter=NEAREST`（128 格底图放大到 200px，最近邻才看得清；雾层因此是硬边像素块，与像素风底图一致，小地图这边刻意不做羽化）。
- **中槽 · 指令面板（随选中单位变）**：由 `characters.list[].command_set` 查 `menu_bar.command_sets.<id>` 得到按钮表 —— **换单位就换整套指令**；加非战斗单位（工程/采集）只需在 config 里加一个指令集并在 `_button_defs()` 补按钮，布局代码不用动。当前 3 名角色都是战斗单位，共用 `combat`：

| 按钮 | 行为 | 挂在角色上的状态 |
|---|---|---|
| 自动攻击：开/关 | 关掉后本角色不再索敌开火（仍可下移动/巡逻令）| `player.auto_attack_on` |
| 索敌·最近 | 射程内挑最近的（默认）| `player.target_stance = &"nearest"` |
| 索敌·最强 | 挑 `max_hp + damage×0.5` 最高者（先拆威胁大的）| `&"strongest"` |
| 指定攻击 | 点一下进入待选 → 再点一个敌人 = 锁定它（死后/跑出射程自动解除，回落策略索敌）| `player.designated_target` |
| 巡逻 | 三态：空 → 设点（点地面/小地图加点）→「开始巡逻(N 点)」→ 跑环形路线 →「停止巡逻」| `_patrol_points`/`_patrol_active` |
| 取消指令 | 解除指定 + 停巡逻 + 清巡逻点 + 停下脚步（**不动**自动攻击开关与索敌策略 —— 那是持续偏好）| — |

  - 面板纵向顺序：**单位名 + 武器** → **属性行**（`HP / 观察视野 / 武器射程 / 有效射程 / 武器噪音`）→ **背包明细行** → 指令按钮行 → **指令状态行**（`自动索敌中 → 劫掠者` / `指定攻击 → 重甲 (HP 3000/3000)` / `巡逻设点中：2 个点` …）→ 一行提示。背包明细行是**当前查看那个人**自己那份（右键弹窗开着就跟着显示弹窗的人，行首写成 `背包（剑士）`），详见 §5.11。
  - 目标选取优先级：`指定目标（仍在射程内）` → `按索敌策略挑`；两者都受「观察视野 ∩ 有效攻击距离」约束（§5.8）。
  - 巡逻路线用 `Line2D` 闭环画在世界里（仅选中时可见）；`_patrol_index` **下令时就自增**，某段被攻击打断不会原地重走同一个点。
- **右槽 · 噪音显示**（2026-09-18 改）：**第 1 行 `自身`**＝角色自身噪音（每人一份，显示全队最大值，条按 `self.max 300` 归一）+ 档位名/配色；**第 2 行 `世界`**＝世界累计噪音（全局一份，条按 `world.reference 2000` 归一）；标题右上角 `被惊动 N`（警觉度 ≥ `thresholds.investigate` 的敌人数，0.25s 刷新一次）。两路互相喂养（自身喂高世界、世界让自身涨得更快），详见 **§5.2.1**；数据源见 §5.2。


---

## 4. 数值系统（全部数值，源 `Data/config.json`）

### 4.1 玩家（`player` / `combat.player`）
| 键 | 值 | 说明 |
|---|---|---|
| `player.speed` | 640 px/s | 移动 |
| `combat.player.max_hp` | 100 | 基础生命（含雕像升级）|
| `player.vision_radius_cells` | 10 格（=640px @tile64）| **观察视野**（自动战斗的索敌半径，同时是迷雾揭示半径）|
| `combat.player.hitstun_seconds` | 0.25 | 受击硬直 |
| `combat.player.invincible_after_hit_seconds` | 0.4 | 受击后无敌 |
| `combat.player.knockback_speed` | 560 | 击退 |
| `player.sprite_scale / offset_y / pixel_unit` | 0.6 / −38 / 10 | lancer 显示参数 |

### 4.2 武器（`combat.weapons`）
| 武器 | kind | 伤害 | 射程/范围 | windup/active/recovery | 噪音 |
|---|---|---|---|---|---|
| 剑 `sword` | melee | 25 | 120px / 200° / 3 目标 | 0.12 / 0.08 / 0.20 | 120 |
| 长枪 `spear` | melee | 26 | 180px / 120° / 2 目标 | 0.12 / 0.08 / 0.20 | 110 |
| 弓 `bow` | ranged | 20 | 弹速 900 / 最大 640px / 1 目标 | 0.30 / 0.06 / 0.18 | 70 |
| 强弩 `sniper` | hitscan | 90 | 最大 900px / 穿透 2 / 2 目标 | 0.55 / 0.04 / 0.90 | 240 |

**攻击距离 vs 观察视野（两个独立属性，2026-09-17 起）**
| 武器 | 表上攻击距离 | 观察视野 | **有效攻击距离** = min(两者) |
|---|---|---|---|
| 剑 / 长枪 | 120 / 180px | 640px | 120 / 180px（不受限）|
| 弓 | 640px | 640px | 640px |
| 强弩 | 900px | 640px | **640px**（射程被视野截断，打不到看不见的地方）|

- 攻击距离按武器分型取：近战 = `range_px`，远程 = `projectile.max_distance_px`，瞬狙 = `hitscan.max_distance_px`（代码 `player.attack_range_px()`）。
- 设计上**观察视野应大于攻击距离**（先发现、再等目标进入射程）；即便配反了也不会打到视野外——有效射程一律取较小值。

- 通用兜底 `combat.attack`：dmg25 / 120px / 200° / 3 目标 / windup0.12 active0.08 recovery0.2 / `cancel_window 0.08`（武器表缺项回落；武器表空＝退回单武器行为）。
- 弓箭矢（`bow.projectile`）：`speed 900`、`max_distance 640`、`hit_radius 16`、`muzzle_offset 22`、texture `arrow.png`。
- 强弩（`sniper.hitscan`）：`max_distance 900`、`hit_radius 18`、`pierce 2`、`muzzle 34`、`tracer_width 2.5`(#ffd873, fade 0.18)、`impact_radius 26`(#ff9a3d)；角色帧 `blue_crossbowman/`（弩已烘焙进帧，2026-09-17 弃用挂点）。
- 闪避 `combat.dodge`：`duration 0.22` / `speed×3.0` / 无敌 / `cooldown 0.8`。

### 4.3 敌人与中立生物
| 键 | 值 |
|---|---|
| `enemy.count` | 100（距玩家 ≥20 格生成）|
| `enemy.max_hp` / `contact_damage` / `contact_cooldown` | 40 / 10 / 1.0s |
| `enemy.speed` / `chase_speed_multiplier` | 360 / ×1.35 |
| `enemy.knockback_px` | 32 |
| `enemy.vision_cells` / `blocked_by_walls` / `los_step` | 10 / true / 0.35 |
| `enemy.lose_sight_seconds` | 3.0 |
| `enemy.ai_active_radius_cells` | 32（外则休眠，见 §5.1）|
| `enemy.patrol_radius_cells` / `patrol_idle` / `repath_interval` | 6 / 1.5s / 0.4s |
| `enemy.ai` | **敌人 AI 的全局默认（2026-09-17 新增）**：`roam.mode` `home_radius`（只在出生点周围晃）、`roam.patrol_radius_cells` 6、`roam.min_target_distance_px` 320、`roam.sample_attempts` 24、`noise_sensitivity` 1.0、`pack.enabled` **false** / `max_members` 5 / `join_radius_px` 160 / `follow_distance_px` 48 / `scan_interval_seconds` 1.0 / `repath_interval_seconds` 0.4。兵种写 `enemy_types.types[*].ai` **按键覆盖**（不写 = 全走这里）；劫掠者覆盖了 `roam.mode=whole_map` / `roam.active_radius_cells=48` / `noise_sensitivity=1.8` / `pack.enabled=true`，见 §5.5 |
| `enemy.hit_flash_seconds` / `death_fade_seconds` | 0.18 / 0.45 |
| `enemy.hp_bar` | **敌人头顶血条（2026-09-17 新增）**：`enabled` true、28×4px、`offset_y` −68、`show_seconds` 3.0（满血且没挨过打 → 不画，挨一次伤亮 3 秒）、`color` `#e04a3c` / `low_color` `#ffd54f` / `bg_color` `#0000008c`。**本体与分身颜色尺寸完全一致**，并且整组（本体+分身）按「组内最低血量」显示同一条（见 §5.5 幻影分身）|
| `enemy.drop` | chance **1.0**（2026-09-17 起调试期统一拉满，待单独调；旧值 0.75），amount 2–6，权重 wood3/stone3/iron2/food3/gold1/oil1（落地为地上 LootNode，走近自动拾取）|
| `animals.count` | 60（距玩家 ≥10 格；`wander 10`/`flee 6` 格；`speed 240`；`flee×1.6`）|
| `animals.hp` | 12 |
| `animals.drop` | chance **1.0**（同上，调试期拉满；旧值 0.9），food 1–3（地面 LootNode）|

**敌人类型（`enemy_types.types`，按 `weight` 概率抽取，有放回）**
| id | 阵营/兵种 | weight | hp | damage | speed_mult | 特性 |
|---|---|---|---|---|---|---|
| brigand 劫掠者 | red/pawn | 4 | 40 | 10 | 1.0 | **满地图游走 + 成群**（不在特性池里，是常驻的 `ai` 段：整张地图随机游走、同类相遇即结伙一起走、每群上限 5、听力 ×1.8，§5.5）|
| raider 弓手 | red/archer | 3 | 30 | 8 | 1.15 | **幻影分身**（召 1–2 具只带本体 20% 血的分身，每 5 秒再补召、单只最多 8 具；分身越多本体越硬；整组按最低血条显示；本体每掉 20% 血随机互换位置，§5.5）|
| cultist 邪术师 | red/monk | 2 | 55 | 14 | 0.85 | **爆裂鼓手**（放大玩家噪音 + 残血减伤，§5.5）|
| marauder 掠夺者 | yellow/pawn | 2 | 70 | 16 | 1.0 | **死亡分裂 / 死亡再生**（二选一，随机，§5.5）|

> ⚠ raider 用弓手外观与 attack 帧，但**代码不发弹道**——所有敌人均近战接触伤害（见 §5.5）。
> 特性的通用写法（2026-09-17 扩成**池**）：兵种配置里的 `traits` 数组，每项 `id` 决定行为、`weight` 决定抽中率；
> **每个实例在生成时随机分配池里的一个**——一个角色只有一种特性；仍兼容旧的单数 `trait`（当作只有一个候选的池）。
> 敌人本身只负责「上报死亡 + 我是哪个特性」，策略与刷怪都在 `enemy_system.gd`，加新特性不用动 enemy.gd。
> **特性触发概率随场上掠夺者总数缩放**（越少越高，两者上限 100% / 50%）——配在顶层 `enemy_traits.population_scaling`，细则见 §5.5。
> 特性分三类：**死亡特性**（分裂 / 再生，死亡时由 `_die()` 上报、`enemy_system.gd` 判定）、**持续特性**（爆裂鼓手，挂在「受击」与「发声」两个既有钩子上，存活期间一直生效）、**召唤特性**（幻影分身，本体开局就召、之后按节拍补召，分身有自己一份血、整组共用一条「最低血量」血条）。
> 共同点：一个实例只有一种特性、生成时随机分配，特性刷出来的孩子继承父的那一个。加新的**死亡**特性不用动 `enemy.gd`；加新的**持续**特性要在它挂的那个钩子上补一处；加新的**召唤**特性要补一个 `notify_*` 队列入口（队列与「一个一个出来」是通用的，见 §5.5）。

### 4.4 噪音（`noise`）
| 键 | 值 |
|---|---|
| `hear_radius_cells` / `min_notice` | 16 / 4 |
| `wall_attenuation` / `decay_per_second` | 0.5 / 10 |
| `max_alertness` | 150 |
| `footstep_interval_seconds` | 0.4 |
| `thresholds.suspicious / investigate / combat` | 15 / 30 / 70 |
| `sources` | walk 22 / dodge 40 / attack 120 / shout 160 / **hurt 100**（挨打时该敌人自己涨的警觉度，2026-09-17 新增，见 §5.1）/ ~~sniper_shot 240（死配置）~~ |
| `ring` | duration 0.7s，color #ffd54f，alpha 0.35，min_intensity 35，min_interval 0.15 |
| `self.decay_per_second` / `self.max` | 90 / 300 —— **角色自身噪音**（每人一份）：线性快衰减，硬上限 |
| `world.decay_ratio_per_second` / `reference` / `max` | 0.06 / 2000 / 4000 —— **世界累计噪音**（全局一份）：比例慢衰减（时间常数 ≈17s） |
| `link.self_to_world_per_second` / `world_to_self_gain` | 360 / 1.2 —— 自身满格时每秒喂给世界的点数；世界到参考值时发声的额外增幅。两者构成正反馈，靠上面两组 cap 兜底，**详见 §5.2.1** |
| `display.alert_watch_interval_seconds` | 0.25（「被惊动 N」计数刷新周期） |
| `display.levels` | 安静 min0 `#7bc86c` / 轻响 min45 `#d8c34a` / 吵闹 min120 `#e08a3c` / 震耳 min200 `#d8452f`（按**自身噪音**取最大 min ≤ 值的档，给菜单第 1 行用） |
| `enemy_traits.noise_amplify` | `enabled` true、`max_multiplier` 3.0（**不在 `noise` 段**：它是邪术师特性「爆裂鼓手」的全局封顶，见 §5.5）|
| `enemy_traits.phantom` | `enabled` true、`max_live_phantoms` 16、`max_phantoms_per_owner` 8（**也不在 `noise` 段**：弓手特性「幻影分身」的全局开关 + 全场幻影硬兜底 + 单只本体上限，见 §5.5）|

### 4.5 地图与资源
- 地图 128×128，tile 64；`force_seed=20260915`（固定测试）；`noise_freq 0.03 / threshold 0.25`；`biome_freq 0.008`、`border_freq 0.08`、`spread 1.35`、`edge_blend 0.45`。
- **群系聚合/去飞地**（`map_generator.gd` 后处理）：`biome_smooth_iterations=3`（3×3 多数投票，同类聚团）→ `biome_remove_islands=true` + `biome_min_region_cells=40`（把不接边缘、被别的群系包住且 <40 格的孤立碎块并入周围主导群系；≥40 格的大块保留，避免整片群系被吃掉）。效果：每个群系成几大块、可互相接壤、但无“一个地形包含另一个”。
- 可达性兜底：`cluster_freq 0.05 / threshold 0.5`、`min_reachable_ratio 0.3`、`max_regen_attempts 10`。
- **群系**（`map.biomes` 存 tileset/speed/floor/tint 等；**面积权重已迁到 `map.biome_weights`**，唯一真相源、设置面板「资源」页可调）：id0 草地 w3.4（`color1`）、id1 荒原 w1.05（`color4`，铁/油主要聚在此）、id2 森林 w1.25（`color3`）、id3 沼泽 w0.95（`color5`，`speed 0.62`，暖色 tint）。占比 ≈ 权重/Σ ≈ 草51%/荒16%/林19%/沼14%。
- **河流：已彻底删除**。`_place_water` 及全部辅助函数（`_pick_water_start`/`_grow_river`/`_grow_lake`/`_water_ok`/`_enforce_water_sizes`）与 `generate()` 里的调用均已移除，`map.river` 只剩 `slow`（涉水减速系数，供 `speed_mult` 兜底，无水源时不触发）。`DECOR_WATER` 类型与水面渲染仍保留，但已无任何逻辑生成水格 → 地图无水。
- **裂缝：已删除**（`map.crack.enabled=false`，`generate()` 不再调用裂缝绘制）。
- 观感：`grade.enabled=false`（对比 1.12/饱和 0.92 待启用）；`macro_light.enabled=true`（freq 0.013 strength 0.1）；`decor.density 1.05`、`clear_spawn 3` 格、`shadow=true`、`decor_collision.enabled=true`；`nav.snap_radius 3 / unstick 4`。
- **地图资源成簇**（`map.resource_clusters`，替代旧 `map.veins`）：`tree/rock/iron/oil` 四种，每种给 `count`（每个 weight>0 群系放几簇）+ `weight{0草/1荒/2林/3沼}`（**同时是最小聚合格数与该资源在各群系的总量比例**，0=不出）。`_place_clustered_resources` 对每群系放 `count` 个 4 邻相连簇、每簇 `size=weight`，凑不够 size 整簇丢弃。树/石写进 `decor`（`DECOR_TREE/ROCK`，阻挡）；铁/油追加进 `veins`（`{res_id,gx,gy}`，非阻挡、可采集）。默认：树 18×{草3,荒1,林6}、石 12×{草2,荒6,林2}、铁 6×{草1,荒8,林1}、油 5×{草1,荒1,林1}，沼泽均 0 → 实测 树180/石120/矿脉75(铁60+油15)，比例即 weight 比。
- **灌木/碎石**：仍按 `map.decor.density` + 群系 `bush/pebble` 概率逐格点缀撒（不参与上面的成簇比例）。**金币不再作为地图矿脉**（仅可能从 loot 拾取/敌人掉落获得）。
- **资源**（`resources`）：

| id | 稀有度 | 价值 | per_node | 采集秒 | 颜色 |
|---|---|---|---|---|---|
| wood 木 | common | 1 | 20 | 2.5 | #8a6a3f |
| stone 石 | common | 1 | 20 | 2.5 | #9a9aa0 |
| iron 铁 | common | 2 | 30 | 4.0 | #bfc8d4 |
| gold 金 | rare | 10 | 15 | 5.0 | #d9b13b |
| oil 石油 | rare | 8 | 40 | 6.0 | #2a2a30 |
| food 食物 | common | 1 | 10 | 3.0 | #5da04e |

- 撒点 `loot.density 0.05`，每点拾取 `loot.amount_per_node 10`，`pickup_radius 80`，种类按 rarity 加权 **common3 / rare1**。

### 4.6 撤离 / 生存 / 局外养成
- 撤离：`count 3`、`spawn_at 30min`、`close [45,55]min`、`trigger_radius 96`、`hold 3s`、`min_dist_spawn 24`/`between 28`；小地图揭示 `minimap.duration 60s`、关点前 `warn 60s`、`size 220px`。
- 生存：`meal_interval 60s` 逐项耗 `survival.supplies`（当前只有 food，每次 1 份）——**2026-09-19 起逐个角色各吃各的**，从**他自己那份**背包扣，短缺也只记在缺的那个人名下；短缺 → 按 `shortage_debuff` 降属性（补上立刻还原），并 `starvation 5 伤害 / 30s` 但血量封在 `starvation_hp_floor 1`（**永不耗死人**）；主动进食 `heal_per_food 25`、`eat_cooldown 1.0`、键 `H(72)`。详见 §5.7 与 §5.11。
- **局外养成（Meta，费用 = `cost × (等级+1)`，逐项资源乘）**：

| 升级项 | 组 | base | per_level | max | 单次 cost | 运行时 |
|---|---|---|---|---|---|---|
| max_hp 生命上限 | survival | 100 | +10 | 5 | 铁 30 | ✅ 生效 |
| backpack_capacity 背包容量 | survival | 10 | +2 | 5 | 木 25 + 金 1 | ✅ 生效（**每人各自**占格上限，非全队分摊，§5.11）|
| warehouse_capacity 仓库容量 | survival | 20 | +5 | 5 | 石 40 + 金 2 | ✅ 生效（撤离入库格数）|
| extraction_speed 撤离速度 | survival | 1.0 | +0.05 | 5 | 木 20 + 金 1 | ⚠ **未接线（买了无效）** |
| resource_find_chance 资源发现率 | acquisition | 0.5 | +0.03 | 5 | 石 25 + 金 1 | ⚠ **未接线** |
| rare_resource_chance 稀有资源率 | acquisition | 0.05 | +0.01 | 5 | 油 30 + 金 2 | ⚠ **未接线** |

- **角色等级 / 名册（`progression` 段，2026-09-17）**：`max_level 9`、`xp.curve {base 100, growth 1.3}`、`per_extraction 100`、`per_kill 0`、`tiers` 边界 `2/5/8/9`、`roster.max_size 8`、`roster.recruit_free true`。等级视觉 = **绕角色飞的一缕淡光**（2026-09-18 三版迭代）：`orb {radius_px 11 屏幕像素, screen_fixed, center_offset_y -34, orbit_radius_px [24,36], orbit_y_scale 0.85, spin_speed 1.2, speed_sway 0.5 + speed_sway_hz 0.13, speed_sway2 0.2 + speed_sway_hz2 0.31, wobble_px 3}`、`orb.glow {tint_white 0.55, max_alpha 0.9, core_whiten 0.5, falloff 1.7, layers [[1.3,0.14],[0.95,0.24],[0.62,0.44],[0.34,1.0]], pulse_seconds [3.4,2.1], pulse_power 1.15, min_scale 0.72}`、`flash {interval [5,9], first_delay 1.5, scale 2.0, rise/hold/fade 0.15/0.7/0.35, text_size 14, text_outline_color #2B2A3A}`、`far_fade {0.95 → 0.70}`、`noise_link {reference 240, max_speed_multiplier 3.0, curve 1.4, boost_flash true}`（光球跟着**角色自身噪音**提速，见 §5.2.1）、`colors` 四档主色已提亮。语义、档位配色映射与踩坑见 **§5.10**。

### 4.7 相机 / 显示 / 音频
- 相机：`pan_speed 1600`、`return_key F(70)`；`zoom 0.35–3.0`（`step 0.12 / smooth 14 / at_cursor true / invert false / fit_bounds true / hud true`）；`edge_pan enabled margin 24 / speed×1.0 / ignore_ui true`。
- 显示：`windowed` / 1920×1080 / `vsync enabled` / `max_fps 0` / `stretch disabled · keep`。
- 音频：`master 1.0 / music 0.8 / sfx 0.9 / mute false`（见 §6）。

### 4.8 背包 / 仓库 / 数值归属厘清（易错）
- **背包（局内携带）**：2026-09-19 起**一人一份**（`player.inventory`），不再有全队公共池。每人的格数上限 = `meta_progression.survival.backpack_capacity`（base 10 + 升级），含义是**每人各自享有这么多格**，不是全队分摊；规则**每种占 1 格、已有种类无限叠加**，**不吃 `storage.*`**。总账视图在 `RunManager.total_loot()`，机制与弹窗见 **§5.11**。
- **仓库（Meta.bank，局外）**：格数 = `Meta.warehouse_slots()` = `warehouse_capacity`（base 20 + 升级）；单种叠加截断 = `storage.stack_limit=1000`。
- ⚠ **`storage.max_slots=20` 在代码零消费**（旧注释误称管仓库格，实际失效）；仓库格数以 `warehouse_capacity` 为准。

### 4.9 局内菜单栏（`menu_bar`）
| 键 | 值 | 说明 |
|---|---|---|
| `enabled` | true | 关掉则既不铺栏、也不让位（设置面板「画面」页可改） |
| `height_ratio` | 0.2 | × 视口高；设置面板范围 0.12~0.3 |
| `min_height_px` / `max_height_px` | 160 / 320 | 夹紧上下限（`UiKit.menu_bar_height()` 唯一公式） |
| `padding_px` | 8 | 栏内边距；小地图槽边长 = 栏高 − 2×此值 |
| `noise_slot_px` | 300 | 右槽（噪音表）固定宽 |
| `patrol_wait_seconds` | 0.6 | 巡逻到点后停留时长 |
| `designate_pick_radius_px` | 96.0 | 「指定攻击」点选敌人时的命中半径 |
| `default_command_set` | combat | 角色没写 `command_set` 时的回落 |
| `command_sets.combat` | auto_attack / stance_nearest / stance_strongest / attack_designated / patrol / cancel | 按钮 id 列表；按钮长相与行为写在 `menu_bar.gd::_button_defs()` |
| `minimap.show_resources` | true | 是否把资源点烘焙进小地图底图 |
| `minimap.resource_colors` | wood/stone/iron/gold/oil/food 各一色 | 资源点配色 |

- 单位与指令集的绑定在 `characters.list[].command_set`（当前 4 名角色全是 `combat`，强弩 2026-09-17 已移出名单）。加新单位类型（工程/采集）＝ config 加指令集 + `_button_defs()` 补按钮，布局代码不动。

---

## 5. 机制系统

### 5.1 仇恨 / 敌人 AI 状态机（`enemy.gd` + `combat/states/enemy_*`）
- **仅 3 态**：`patrol` / `investigate` / `chase`。**无 idle/attack 状态**——「攻击」＝接触伤害瞬间置 `_attack_timer`（≈0.35s）驱动挥击帧，非 FSM 节点。
- 转换：`patrol→chase`＝`can_see_player()`；`patrol→investigate`＝`alertness ≥ investigate(30)`；`investigate→chase`＝看见玩家，或 `alertness ≥ combat(70)` 用追击速度「狂暴」；`investigate→patrol`＝`alertness < suspicious(15)` 放弃。⚠ suspicious/combat 不产生独立状态，只作 tint 与速度/放弃下限。config 实际阈值 15/30/70（代码硬编码回退 20/50/100 已被覆盖）。
- `can_see_player`：距离 `vision_cells(10) × tile(64) ≈ 640px`；墙遮挡沿线段按 `los_step 0.35` 采样墙格；玩家死亡看不见。
- 跟丢：`chase` 累计看不到 > `lose_sight_seconds(3.0)` → 把最后已知位置当声源，`alertness ≥ 30` 进 investigate 否则回 patrol（不透视实时追）。
- **休眠**：距玩家 > `ai_active_radius(32)` 格 → `_dormant`，不跑 FSM/动画/tint（但警觉衰减在休眠判定前，远处仍会掉警戒）。该半径可按兵种覆盖（`ai.roam.active_radius_cells`，劫掠者 48）。
- **「其他怪只在一个固定的范围内移动」（2026-09-17 用户定，逐字落实）**：默认所有敌人 `ai.roam.mode = home_radius` —— `patrol` 只在本兵种 `ai.roam.patrol_radius_cells(6)` 的**方形**范围里选点（斜角最远 = 6×√2 格 ≈ 543px）。只有**听到噪音**或**挨了打**才会离开这一片。劫掠者是唯一例外（`whole_map`，见 §5.5）。
- **挨打也会动（2026-09-17，所有敌人通用）**：玩家造成伤害后，三个调用点（近战 `player.resolve_attack_hit`、箭 `combat/projectile.gd`、强弩 `player.fire_hitscan`）各补一句 `alert_from_attacker(攻击者位置)` ⇒ 该敌人 `noise_alertness += noise.sources.hurt(100)` 并把攻击者位置记为声源，下一帧就转 `investigate` 朝攻击者走（近战 = 玩家位置、箭 = **出膛点**，用命中点等于让它原地不动）。刻意**不塞进 `take_damage()` 签名**：那会逼探针里所有假敌人跟着改。`noise.sources.hurt = 0` 可整条关掉。
- **成群（`ai.pack`，2026-09-17，目前只有劫掠者开）**：同 `type_id` 的敌人靠近到 `join_radius_px(176)` 内即结伙，全群**共享同一个字典** `{leader, members}`（引用语义）。**群主**按 `roam` 模式选目标；**成员**只跟队形（距群主 > `follow_distance_px(48)` 才启程，每 `repath_interval 0.4s` 重算路径）。每群硬上限 `max_members(5)`；个体只投奔**不小于自己**的群（否则小群互相拆伙、群主每秒换人）；群主死亡 → 同群下一个活着的自动接任（`_promote_pack_leader`，在读取处懒惰修复、不埋钩子）。
- 追击速度 = `speed(360) × speed_mult(兵种) × chase_mult(1.35)`；最快 raider≈559 < 玩家 640，可风筝。接触伤害按兵种 `damage`，成功则 `contact_cooldown 1.0`。

### 5.2 噪音机制（`noise_system.gd` + `combat/fx_ring.gd`）
- `emit(pos, intensity)`：① `intensity ≥ ring_min_intensity(35)` 才画环；② 遍历 `enemies` 组，`d > hear_radius(16×tile)` 跳过；③ 距离线性衰减 `att = 1 − d/hear_radius`；④ 隔墙 `att ×= wall_attenuation(0.5)`（独立 LOS 采样）；⑤ `received = intensity × att`，`≥ min_notice(4)` 才 `e.hear_noise()`。
- `hear_noise`：`noise_alertness += received`（上限 `max_alertness 150`），记声源位驱动 §5.1 FSM。`decay_per_second(10)` 由**每敌人** `_physics_process` 每帧扣。
- 源触发点：`walk 22`＝`player_move_state`（每 `footstep_interval 0.4` 一次）；`dodge 40`＝`player_dodge_state`；`attack 120`＝近战出招（先取武器 `noise`：剑120/弓70/狙240，无武器回落）；`shout 160`＝**敌人进入 chase 时广播**（惊动附近，非玩家）；`sniper_shot 240`＝**死配置**（狙击走武器 noise 240）。
- ring 半径 = `hear_radius × (1 − min_notice/intensity)`，扩散+淡出描边圆。
- **菜单栏右下那两条噪音（2026-09-18 重做成互相喂养的两路，详见 §5.2.1）**：第 1 行＝**角色自身噪音**（每人一份，显示全队最大值），第 2 行＝**世界累计噪音**（全局一份）。旧的「当前 / 累积」已废弃 —— 累积原来是只增不减的总账，看不出「这一局到底紧张到什么程度」。
- **爆裂鼓手放大（2026-09-17，邪术师特性 `burst_drum`）**：`emit()` 在 `from_player=true` 分支里、**记读数与派发之前**乘一次倍率 `player_noise_multiplier(source_pos)`，于是**读数、光圈大小、敌人实际听到的强度全是放大后的值**（一条链路，没有第二个真相）。
  - 倍率 = `clamp(1 + Σ 各放大器增幅, 1, enemy_traits.noise_amplify.max_multiplier 3.0)`；单个放大器增幅 = `per_enemy × (1 − d/radius_px)`（按**发声点**距离线性衰减，超出 `radius_px 480` 不贡献）。
  - 放大器 = 场上带该特性的活敌人，挂在 `noise_amplifiers` 组里 —— **组为空时直接返回 1.0，不做任何遍历**（没有邪术师的老局面零开销）。
  - `from_player=false`（敌人 `shout`）**不走**这条分支：呼喊不会被放大，读数也不受影响。
- **耳朵倍率（2026-09-17，按听者）**：派发循环里按**每只敌人**把等效听力半径乘上 `enemy.gd::noise_sensitivity()`（劫掠者 1.8，就是用户要的「劫掠者对声音更敏感」）⇒ 表现为**听得更远 + 同距离听到的强度更高**（`radius = hear_radius × sens`，`att = 1 − d/radius`，超出普通半径的远处也还够得着）。普通兵种 `sens = 1.0`，与旧公式**逐位一致**（旧式子就是 `radius = hear_radius`）。
  - 与「爆裂鼓手」的区别：那个改的是 `intensity`（声源更响、全局、只在 `from_player`）；这个改的是 `radius`（耳朵更灵、按兵种、对所有声源都生效）。两者互不干扰。
  - 光圈（ring）半径仍按**基础** `hear_radius` 画 —— 它表示「这声响能传多远」，不随听者变。

### 5.2.1 两路噪音：自身 ⇄ 世界（2026-09-18 用户定）

**一句话**：每个角色的吵闹会抬高整张地图的紧张度，而紧张的水位反过来让下一声更难压下去。

| | 自身噪音 `self_noise` | 世界噪音 `world_noise` |
|---|---|---|
| 归属 | **每个角色一份**（`player.self_noise`） | **全局一份** |
| 读法 | 我此刻有多吵 | 这局暴露了多少（地图的紧张水位） |
| 菜单 | 第 1 行，取**全队最大值** | 第 2 行 |
| 增长 | 发声事件 +（`intensity × gain`） | 每帧由所有人的自身噪音灌入 |
| 衰减 | **线性** `−90/秒` | **比例** `× (1 − 0.06·dt)` |
| 上限 | `noise.self.max 300` | `noise.world.max 4000` |

- **两条 feeding**：
  - ① 自身 → 世界：`_process` 里每个角色 `world += 360 × (self / 300) × dt`，**不从自身扣**（是累加不是转账 —— 发声的人自己也还是那么吵）。
  - ② 世界 → 自身：`self_gain_from_world() = 1 + 1.2 × clamp(world / 2000, 0, 1)`，新发声据此放大。世界到参考值时，同样一剑从 +120 变成 **+264**。
- **为什么世界用比例衰减、自身用线性**：线性的稳态不存在 —— 「输入率 > 衰减」就一路涨到爆表，「输入率 < 衰减」就一路归零，读数是**开关**不是水位；比例衰减才有平衡点，且退场时先快后拖（时间常数 1/0.06 ≈ 17 秒），正好是「慢慢降下去」的手感。自身要的是「说完就没事了」，用线性才能在小动静上真的归零（脚步 22 → 0.25 秒清空）。
- **⚠ 这是正反馈**：两边都有 hard cap → **结构上不会发散**（探针 F 段每 0.05 秒发一拳连打 30 秒验证：自身停在 295.5、世界停在 4000，无 NaN/Inf）。但把 `link.world_to_self_gain` 调大，会让「吵起来就再也压不下去」—— 这是手感问题，不是崩溃问题，调之前请先跑 F 段。
- **⚠ 发声必须带 `source_unit`**：`emit(pos, x, true, actor)`。忘了传 actor 的话这一声会掉进「没归属」那份 `_ambient_self`：菜单照样有读数、但每个角色的光球都没反应 —— 运行时看不出来，所以 `probe_noise_link` K 段在源码层守着三个调用点。
- **等级光球跟着走**（用户原话「光球根据第一个来」）：`unit_level_badge.noise_speed()` 读**自己那个角色**的自身噪音，`_t += delta × speed` —— 给**整条时间轴**乘一个倍数，而不是分别改每条曲线的频率：后者会让摆动 / 明灭 / 抖动各自的相位错位，加速那一下光点会「抖」；乘同一个 `_t` 则相位连续，看不出是被调快了，只会觉得它更躁动。
  - 用途和实际 feel：`reference 240`（强弩一发即顶格）、`max_speed_multiplier 3.0`、`curve 1.4` ⇒ 脚步 22 只到 1.05 倍（几乎无感，否则会被呼吸般的脚步声拽得一跳一跳）、剑击 120 → 1.76 倍、持续激战 → 3 倍。
  - **单次闪烁时长不跟着缩**：那 1.2 秒是为了让球心的数字能被读出来，压到 0.4 秒就是「一闪而过」，等于没报。加速只体现在**多久闪一次**（`_next_flash -= delta × speed`）。
  - 3 倍速下 ω 仍恒 > 0（`speed_sway` 之和 < `spin_speed` 这条约束是等比缩放不变的），所以光点不会原地掉头。

**验证**：`Dev/probe_noise_link.tscn`（60 项）—— 配置真值与「自身更快」的速率差 / 自身噪音挂在个人身上（两人互不影响）/ 两条衰减速率对比 / 自身喂世界且自身照常衰减 / 世界抬增益且超参考值封顶 / **正反馈有界（数值曝打）** / 光球倍速单调且只读自己那份 / 顶格速度下 ω 恒正 / 菜单两行的量程与数值链路 / reset 清干净 / 三个发声点都传了 actor。

### 5.3 撤离机制（`extraction_system.gd` / `extraction_point.gd`）
- 30min 随机刷 3 点（限可达格 + `min_dist` 约束）；洗牌预定关闭顺序；45/55 各关 1；最后 1 点保持到超时。轮到点若有人站圈内则改关下一个（全有人本轮作废）。
- 站 `trigger_radius 96` 圈 → `hold_progress += delta`，达 `hold 3s` 触发 `RunManager.extract()`；离开或点关闭清零。elapsed 按 `time_limit − remaining` 计，故 `time_scale` 同步加速整条时间线。

### 5.4 掉落机制
- 敌人死亡（`enemy.gd _spawn_drop`）：`randf > chance(1.0)` 则不掉；按 `drop.weights` 加权选种类，`randi_range(2,6)` 数量，生成**地面 LootNode**（视觉 ×0.8 区别地图资源点），走近 `pickup_radius 80` 才自动进背包 —— 2026-09-19 起背包**一人一份**，所以「进谁的包」有明确规则：**压住这个点的角色里最近的那个活人**（`loot_node.gd::_nearest_living_carrier()`，详见 §5.11）。
- 羊死亡：`chance 1.0` 掉 food 1–3（地面 LootNode）。
- ⚠ **调试期统一拉满（2026-09-17 用户要求「掉落都先改到 1，后面单独调」）**：`enemy.drop.chance` / `animals.drop.chance` 均为 `1.0`，掠夺者 `trait.drop_from_splits` 也为 `true`。⇒ 现在**每只敌人/羊必掉**，掠夺者分裂体也掉（一窝 79 只 × 2–6 个，地面会被铺满，注意性能）。这两个数值后续由用户单独调，改动点都在 `Data/config.json`。
- 资源点：按 `loot.density(0.05)` 撒于可达地板，每点 `amount_per_node 10`；新种类且**那个人的**背包满则拾取失败、资源点留在原地并 `pickup_retry 0.5` 后重试（下一帧换个还没满的人也可能拿走）。
- **角色阵亡 = 整包就地撒成一地**：走的正是上面这条 LootNode 路（`player.drop_inventory()`），故队友走近能捡回，见 §5.11。

### 5.5 怪物特性
- **全部近战接触伤害**，4 兵种强度递进（§4.3）；无远程、无技能系统（已删）。
- 受击＝瞬时泛红（`hit_flash 0.18`，tint lerp 红）；死亡＝tween 并行「淡出 + 缩 ×0.7 + 下沉」（`death_fade 0.45`），**无专用帧**。
- **平衡缺口（真实）**：玩家远程（弓弹道 640px、狙 hitscan 900px 穿透 2）可风筝；但敌人视野 ≈640px ≈ 弓射程，贴边对射窗口窄。全员近战 ⇒ 远程无威胁。若走全员远程需补**远程敌人 / 掩体 / 弹速压制**。

#### 死亡特性（`marauder` 掠夺者专属，2026-09-17 用户定）

掠夺者有一个**特性池** `enemy_types.types[marauder].traits[]`：每个实例在生成时随机分配池里的一个 ——
**一个角色只有一种特性**（用户原话：「死亡一个角色只能有一个特性，随机分配」），特性刷出来的
孩子**继承父的那一个**。目前两个候选，`weight` 各 1（各 50%）：

| id | 规则 | 关键数值 |
|---|---|---|
| `death_split` 死亡分裂 | 原始体死亡 → `stages[0]`；这一批的**最后一个**死亡时才轮到 `stages[1]`，逐代递进，`stages` 用完就停 | `stages[i].count` = 2/4/8/64；**初始概率受数量缩放**（`chance_base` 0.45 → `chance_max` 1.0），第 2–4 代固定 `chance` = 0.9/0.8/0.7 |
| `death_regen` 死亡再生 | **每一次死亡都独立掷**（不看「最后一个」、不逐代递进）：过了就刷 `count` 个，孩子继承同一特性 → 会一直链下去 | `count` = 2；概率同样受数量缩放（`chance_base` 0.15 → `chance_max` 0.5），每次死亡都按当前值掷 |

两者共用的键：

| 键 | 当前值 | 说明 |
|---|---|---|
| `weight` | 1 / 1 | 生成时被抽中的权重（两个各 50%）|
| `spawn_interval_seconds` | 0.1 | 相邻两个的间隔（「一个一个出来」）|
| `scatter_px` | 0.0 | 落点随机半径，0 = 严格重叠在死亡点 |
| `drop_from_splits` | **true** | 特性刷出来的个体掉不掉落（2026-09-17 调试期已开）|
| `max_live_split_enemies` | 0 | 同屏（特性刷出来的）数量上限，0 = 不限 |

- **分裂的「最后一个」怎么实现**：同一批的分裂体**共享同一个 `Dictionary`**（引用语义）当计数器（`stage` = 这一批死后要触发的下标，`alive` = 还剩几个活着）。谁死都只减 1，**减到 0** 的那个才是「最后一个」，由它触发下一代。原始怪没有批次，视作「只有 1 个的一批」。
- **再生与分裂的核心区别**：再生**不建批次**，每次死亡都掷一次骰 —— 所以 2 个再生体里**随便死哪一个**都会再触发，而不是等最后一个死完。
- **「一个一个出来」**：死亡时不直接 `add_child`，而是把 N 个条目推进 `EnemySystem._pending` 队列，`_physics_process` 里**每帧最多放出一个**（两者共用这个节奏）。
- **掉落**：`drop_from_splits` 管所有特性刷出来的个体，**当前 `true`（掉）**。原本默认 `false`，是因为一只掠夺者理论可裂成 1+2+4+8+64 = 79 个、逐个掉落会把地面铺满；2026-09-17 用户要求调试期把所有掉落概率统一拉满，故敌人 / 羊 / 特性个体三处现在都是「必掉」。
- **数值**：刷出来的个体**保留原型全部数值**（HP 70 / 伤害 16 / 移速 ×1.0）——刻意按原型来的，不是没调；要弱化就按代次给 `stages[i]` 加数值覆盖字段。

**数量缩放**（2026-09-17 用户定：「掠夺者总数量越少，特性初始触发概率越高」，两者上限分别是 **100%** 与 **50%**）

配置在顶层 `enemy_traits.population_scaling`（跨特性共用，不只管掠夺者）：

| 键 | 当前值 | 说明 |
|---|---|---|
| `enabled` | true | 关掉 = 概率永远停在 `chance_base`，不随数量变 |
| `full_chance_at_or_below` | 8 | 场上带特性的敌人 ≤ 此值 → factor = 1（拿到各自 `chance_max`）|
| `base_chance_at_or_above` | 40 | ≥ 此值 → factor = 0（回落 `chance_base`）|
| `cache_seconds` | 0.25 | 计数的缓存时长（雪崩时不必每次死亡都扫全场）|

- **算法**：`factor = clamp((base_at − n) / (base_at − full_at), 0, 1)`，`实际概率 = lerp(chance_base, chance_max, factor)`；两个阈值相等时退化成开关。
- **统计口径 `n`**：场上**参与数量缩放的**活敌人 = 掠夺者本体 + 它分裂/再生出来的全部后代（正在死亡淡出的不算）。判据在 `enemy.gd::counts_toward_population()`：**特性自己（或它的某一代）写了 `chance_max` 才算参与**，所以与数量无关的特性（邪术师的爆裂鼓手）不会被数进来 —— 2026-09-17 修，否则场上邪术师一多就会无辜压低掠夺者的概率。不带特性的兵种（劫掠者/弓手）同样不参与。实现在 `EnemySystem.featured_enemy_count()` → `_count_featured()`。
- **只压「初始」那一代**：用户说的是「特性**初始**触发概率」，所以只有 `stages[0]` 与 `death_regen` 的那个概率写成 `chance_base` / `chance_max`；分裂的第 2–4 代仍是固定 `chance`（0.9/0.8/0.7）。要连后面几代一起压，给 `stages[1..3]` 也加这两个键即可 —— `trait_chance()` 对**每一代**都支持。
- **老写法完全不受影响**：只写 `chance` 的特性/代次不走缩放（`trait_chance()` 发现没有 `chance_max` 就直接返回 `chance`），所以既有的临时测试配置（探针里那些 `chance: 1.0` 的）行为不变。
- **判定统一走 `EnemySystem.trait_chance(feat, stage)`**：任何地方都别再直接读 `chance`，否则会绕过缩放。
- **副作用（刻意要的）**：这给掠夺者加了个**软上限** —— 数量涨起来后概率自动回落，分裂初始一代 2×0.45 = 0.9 < 1（期望收缩），不会无限膨胀；数量少时又拉回 100%，不会「杀绝了就不再长」。硬上限 `max_live_split_enemies` 仍可另设。

**代码分工**（加新特性照这个来）：`enemy.gd::_die()` → `_report_death()` 上报「我死了 + 我是哪个特性（`_feat`）」；概率、数量、排队、实例化全在 `enemy_system.gd::notify_death_split()` / `notify_death_regen()` / `_spawn_one()`。分配特性在 `enemy.gd::pick_feature()`（按 `traits[*].weight` 加权抽一个）。

**七个坑**（都踩过）：
1. **`trait` 是 GDScript 4 保留字**，不能当变量名 —— `var trait = ...` 会报 `Expected variable name after var`。代码里叫 `feat`，函数内局部变量叫 `f`。
2. `_live_split_count()` 是**全局**的（扫 `enemies` 组里所有特性刷出来的个体，排除正在淡出的），不是「本 World 的」——写探针时按当前全局数动态设上限，写死会被别处的残留顶掉。
3. `EnemySystem.setup()` 必须 `_pending.clear()`：上一局的队列条目指向**已释放的 GameRoot**，不清会在新局往空气里刷怪。
4. **`traits` 池优先于单数 `trait`**（`feature_pool()` 先看池、池非空就不再理会单数）——写「只带某一个特性」的测试配置时必须先把 `traits` 摘掉，否则池会把设的单数值整个盖掉（探针 `_with_trait()` 里 `erase("traits")` 就是为这个）。
5. **数量缩放的计数缓存计时 `_pop_hold` 必须在 `_physics_process` 的提前 `return` 之前递减** —— 那函数开头是 `if _pending.is_empty(): return`，放在后面的话刷怪队列一空就永远不递减，计数会永远卡在旧值，缩放等于死掉。
6. **三个口径别混**：`featured_enemy_count()` 数「**参与数量缩放的**」（判据 `counts_toward_population()` = 特性能写 `chance_max` 的才算，含开局刷的原始掠夺者）；`_live_split_count()` 只数「特性**刷出来的**」（给 `max_live_split_enemies` 硬上限用）；`has_feature()` 只回答「有没有特性」（含爆裂鼓手这种与数量无关的）。用一个去顶另一个，调出来的手感就是错的。
7. **探针给 `NoiseSystem.setup()` 传的墙体网格必须覆盖声源坐标** —— 传 24×24 的网格却把发声点摆到 (9000, 9000)，`_has_line_of_sight()` 会因格子越界判成「隔墙」而把强度减半（实测只有理论值的一半）。探针坐标在大网格之外时给噪音系统传**空**网格（= 无障碍，LOS 恒真）。

**验证**：`Dev/probe_enemy_split.tscn` **99 项**（A 特性池真值 / B 排队与批次 / C 一个一个出来 / D 最后一个才触发 / E 批次共享同一实例 / F 代次递进 / G 概率没过 / H stages 用完 / I 掉落开关两分支 / J 其它兵种不受影响 / K 上限截断 / L 原地落点 / M 新局清队列 / N 第 4 代 64 个完整跑 / O 随机分配 + 一个角色只触发一个特性 + 再生每次都判 + 孩子继承 / P 数量缩放：阈值与 factor 两端夹紧且单调、上限就是 100%/50%、只压初始那代、老写法不受影响、计数口径只数带特性的、端到端钉住计数缓存证明判定真的吃到了缩放）。注：A 段不断言 `drop_from_splits` 与 `chance_base` 的具体值（都属「后面单独调」的数值），只校验上限与布尔键，两个分支的实际行为由 I / P 段实测。

#### 爆裂鼓手（`cultist` 邪术师专属，2026-09-17 用户定）

用户原话：「邪术师，特性是爆裂鼓手，会放大玩家造成的噪音，同时血量越低，受到的伤害越少。」
= **一个特性、两个持续效果**（都不是死亡触发），配在 `enemy_types.types[cultist].traits[0]`：

| 子段 | 效果 | 当前数值 |
|---|---|---|
| `noise_amplify` | 放大**小队自己**造成的噪音（光环，按发声点距离加权）| `radius_px` 480、`per_enemy` 0.5；封顶在顶层 `enemy_traits.noise_amplify.max_multiplier` = 3.0 |
| `damage_reduction` | 血量越低受到的伤害越少 | `max_reduction` 0.6、`exponent` 1.0、`min_damage` 1 |

- **噪音放大怎么算**：总倍率 = `clamp(1 + Σ 各放大器增幅, 1, 3.0)`，单个增幅 = `per_enemy × (1 − d/radius_px)`（d = 该邪术师到**发声点**的距离；出半径不贡献）。贴着放是 1.5 倍，两只贴近 2.0 倍，叠加超过封顶就夹住。倍率乘在 `emit()` 的 `from_player=true` 分支上，**在记读数与派发之前** ⇒ 菜单栏读数、光圈大小、敌人听到的强度全是放大后的值（见 §5.2）。
- **为什么用组**：放大器挂在 `noise_amplifiers` 组（`enemy.gd::_register_feature_groups()`），`NoiseSystem.player_noise_multiplier()` 只遍历这个组 —— **场上一只邪术师都没有时组是空的，等于零开销**，不必每次发声都扫全场敌人。
- **敌人呼喊不放大**：`from_player=false`（`shout`）不走那条分支，呼喊不会被放大器叠加、也不会自我引爆。
- **减伤怎么算**：`减伤 = max_reduction × (1 − hp/max_hp)^exponent`，`实际伤害 = max(min_damage, round(原始伤害 × (1 − 减伤)))`。满血不减、血越少减越多、**单调不增**（越残越难磨），但减伤永远 < 1 且有 1 点保底 ⇒ **残血也打得死，不是无敌怪**（用户要的是减伤，不是免伤）。实现在 `enemy.gd::take_damage()` → `incoming_damage()` / `damage_reduction_ratio()`。
- **55 HP 的实际手感**：半血挨 20 点掉 14（减伤 0.305），残血挨 20 点掉 8（减伤 0.589）。等效血量比表面值高一截，逼玩家用爆发而不是慢慢磨。
- **全局开关**：`enemy_traits.noise_amplify.enabled = false` 可整体关掉放大（平衡/调试用）；单实例关掉则把 `radius_px` 设为 0；想全图生效就把半径设得比地图大。

**代码分工**（持续特性照这个来）：效果挂在**既有钩子**上 —— 发声走 `noise_system.gd::emit()`，受击走 `enemy.gd::take_damage()`，两处都只是「读特性的子段 → 算一个系数」。特性的分配与继承仍走 `pick_feature()`，与死亡特性共用同一套。

**验证**：`Dev/probe_cultist_trait.tscn` **63 项**（A config 真值 / B 减伤纯函数：满血 0、半血三成、残血接近上限、单调不增、永不无敌 / C 真走 `take_damage`：满血挨满、残血只掉 1 点、再来一下就被打死 / D 倍率：无放大器 1.0、贴脸 1.5、半径处按 0.5 权重叠加、出半径 0、十只夹在封顶 3.0、`radius_px=0` 关闭 / E 只放大小队发声：旁观者收到的强度有无放大器完全相同、`from_player=false` 不动读数、换成小队发声立刻变响 / F 只有邪术师进 `noise_amplifiers` 组 / G 邪术师不进数量缩放计数、掠夺者照进 / H 无特性兵种完全不受影响 / I 全局开关能整体关掉并还原）。

#### 幻影分身（`raider` 弓手专属，2026-09-17 用户定，同日改规格）

用户原话（最终版）：「每个只随机召唤一到两个，召唤的分身只有本体20%的血量，分身不会再召唤分身，本体每隔5秒会再随机召唤1到2个，最多8个分身，分身越多，自身受到伤害越少」＋「这批角色（本体加召唤）按最低血条展示，不管攻击哪个，显示血条最低的，迷惑玩家」。
配在 `enemy_types.types[raider].traits[0]`：

| 键 | 值 | 说明 |
|---|---|---|
| `count_min` / `count_max` | 1 / 2 | 开局随机召 1~2 具（`randi_range`）；之后每次补召也按这个区间 |
| `max_phantoms_per_owner` | 8 | **单只本体的硬上限**（活着的 + 队列里没出生的一起算，见 `enemy_system.gd::phantom_slots_left()`）|
| `hp_ratio_of_owner` | 0.2 | 分身自己那份血 = 本体 `max_hp` × 20%（出生满血）|
| `resummon_interval_seconds` | 5.0 | 本体每隔 5 秒再随机召 1~2 具（`_tick_phantom_resummon`）；<= 0 = 不补召 |
| `spawn_radius_px` | 96 | 分身落在本体周围这个半径内（落点吸附到可走格心，掉墙里的分身等于没有）|
| `spawn_interval_seconds` | 0.15 | 走 `_pending` 队列 ⇒ **一具一具出来**，不在一帧里噗地冒两个 |
| `swap_hp_step_ratio` | 0.2 | 本体每掉 20% 血，随机和一具活分身**交换坐标**（80/60/40/20% 各一次，最多 4 次）|
| `damage_reduction` | `per_phantom` 0.075 / `max_reduction` 0.6 / `min_damage` 1 | **分身越多，本体受到的伤害越少**（8 具正好到 0.6 封顶；1 点保底 ⇒ 不会无敌）|
| `drop_from_splits` | false | 分身不掉落（它不算独立个体）|
| 全局 `enemy_traits.phantom` | `enabled` true、`max_live_phantoms` 16、`max_phantoms_per_owner` 8 | 一键关掉召唤 / **全场幻影硬兜底**（真正决定"同屏能看到几具幻影"的就是它；0 = 不限）|

- **血量各自独立**（2026-09-17 从早先的「共享血池」改掉）：分身有自己的一份 = 本体 `max_hp` × 20%，挨打扣自己的、打光就自己消失（`vanish_as_phantom()`），**不**把伤害转嫁给本体。`_phantom_pool` 那张共享 Dictionary 仍在，但只剩**记账 + 血条广播**两个用途。
- **血条：整组按组内最低血量显示** —— `display_hp_ratio()` = `min(本体 hp, 全部分身 hp) ÷ 本体 max_hp`。分母恒用**本体**的 `max_hp`，而分身天生只有 20% 的血 ⇒ 只要场上有分身，整组血条就固定落在 20% 以下的「残血」区间，**打哪个都是同一条、都像快死了**（这就是本特性迷惑玩家的核心）。组内谁掉血都走 `refresh_group_hp_bar()` 广播全组。**别按 `is_phantom()` 给分身换血条颜色/尺寸**，会一秒破功。
- **分身无法造成伤害**：分身 `damage = 0`，且 `_on_body_entered` 里接触伤害直接 return（撞上玩家一滴血不掉、也不播挥击动作）。这是用户明确要的效果 —— 玩家发现「这只打我不疼」就知道是假的。
- **换位**：本体每跨过一个 `swap_hp_step_ratio` 台阶 → `_swap_with_random_phantom()` 随机挑一具活分身交换 `global_position`，**双方的巡逻中心 `_home` 也跟着挪**（不然本体一步走回老窝就露馅）。台阶用**整数血量**算（`已掉 / (max_hp × 比例)`）—— 24/30 这种比例在二进制里是 0.19999999999999996，用 `hp_ratio()` 会 floor 成 0、白白吞掉一次互换（实测踩过）。没分身可换时台阶照样记账，不攒着事后连闪；一次伤害跨多个台阶也只换一次（同帧连换等于随机打乱）。
- **血条本体件**：`Scripts/enemy_hp_bar.gd`（项目此前**根本没有敌人血条**，是为这条特性补的通用件，所有敌人共用）+ `enemy.hp_bar` 配置，规则是「满血不画、挨打亮 3 秒」。
- **分身也泛红**：分身受击时自己也 `_hit_flash`，否则「我打的那只没红、旁边那只红了」当场穿帮。
- **分身不召唤分身**（`_is_phantom` 熔断）：否则指数繁殖。
- **本体死亡 → 幻影一并消失**（`vanish_as_phantom()`：不上报特性、不掉落、不走尸体淡出）。
- **记账口径**：分身不进 `_live_split_count()`（不挤占掠夺者的 `max_live_split_enemies` 名额），也不进 `featured_enemy_count()`（弓手没写 `chance_max` → `counts_toward_population()` 为 false → 不参与数量缩放）。
- **代码分工**：`enemy.gd`（`_setup_phantom` / `display_hp_ratio` / `refresh_group_hp_bar` / `_tick_phantom_resummon` / `_resummon_interval` / `_summon_phantoms_if_needed` / `_check_phantom_swap` / `_swap_with_random_phantom` / `phantom_damage_reduction` / `_vanish_phantoms` / `is_phantom()`）+ `enemy_system.gd::notify_phantom_summon()`（数量 / 名额 / 落点 / 队列，与死亡特性共用 `_pending`）+ `enemy_hp_bar.gd`。

**验证**：`Dev/probe_phantom_double.tscn` **114 项**（A config 真值 / B 随机召 1~2 具 + 共享记账池是同一实例 + 分身血量 = 20% + 分身不再召唤 / C 一具一具出来 / D 分身撞玩家一滴血不掉、打分身只扣分身自己、整组血条 = 组内最低、分身打光即散 / E 每掉 20% 换一次位、同台阶内不换、巡逻中心跟着挪 / E2 没分身时不换位但台阶照记 / F 本体死 → 幻影一起消失 / N 补召节拍到 8 具封顶、名额空了又会补回 / P 分身越多本体越硬、封顶、1 点保底、清空后回落 / G 分身不进两个计数、对照「特性刷出来的」要进 / H 无特性兵种不受影响但共用血条 / I 全局开关与全场上限）。
另有 `Dev/probe_phantom_live.tscn` **17 项**：真实 `Main.tscn` 走一遍「基地 → 出击」，验弓手真的带着幻影出生、打本体掉血且被分身减伤、打分身不伤本体、两边血条一致、换位生效、本体死后幻影收摊（临时 override `enemy.count`，绕开本机 `settings.json` 里被设成 0 的那项）。

#### 劫掠者的 AI：满地图游走 + 成群（`brigand`，2026-09-17 用户定）

用户原话：「最后做劫掠者，他的机制就是满地图随机游走，并且遇到同类会一起移动，上限先做到 5 个吧，所以其他怪只在一个固定的范围内移动，受到攻击或者噪音，再移动，劫掠者对声音更敏感。」

**注意它不在特性池里**：特性是「生成时按 weight 随机分配一个、一个实例只有一种」；而这几条是劫掠者**每只都有**的常驻行为，所以配在 `enemy_types.types[brigand].ai`（按键覆盖全局 `enemy.ai`），不走 `traits`。

| 键（`brigand.ai`） | 值 | 说明 |
|---|---|---|
| `roam.mode` | `whole_map` | 巡逻时在**整张地图**上随机挑可走格（其余兵种 `home_radius` = 出生点周围 6 格见方）|
| `roam.active_radius_cells` | 48 | 放宽休眠半径（全局 32）—— 否则它走不出玩家附近，谈不上「满地图」|
| `roam.min_target_distance_px` | 400 | 新目标至少这么远，避免抽到脚边几格、变成「原地抖」|
| `roam.sample_attempts` | 24 | 每次最多抽 24 个候选格；全不可达就退回出生点附近的老行为（不空转）|
| `noise_sensitivity` | 1.8 | 听力倍率：等效听力半径 ×1.8（1024px → 1843px），同距离收到的强度也更高 |
| `pack.enabled` / `max_members` | true / **5** | 成群开关 + **每群硬上限**（用户定的「上限先做到 5 个」）|
| `pack.join_radius_px` | 176 | 同类靠到这么近就结伙 |
| `pack.follow_distance_px` | 48 | 成员离群主超过这个距离才启程，否则原地待命 |

- **满地图怎么走**：`pick_patrol_target()` 按 `roam_mode()` 分两路；`whole_map` 走 `pick_roam_target()` —— `_random_open_cell()` 抽一个可走格 → 距离够远 → `_set_path_to()` 铺整条 A* 路径。仍然只在**没有噪音、没挨打**时游荡；一有动静就转调查（与别的怪同一条状态链）。
- **成群怎么合**：`_tick_pack()`（每帧被调、内部按 `scan_interval_seconds` 节流）→ `_try_join_nearby_pack()` 找**最近的同类**，只要它那个群**不小于自己的、且还装得下我**就投奔过去（`absorb_into_pack` → `attach_to_pack`）。「不小于」这条是必需的：不加的话，小群里的人会为了再找一个落单的而退出旧群，6 只聚在一起只会来回晃出 4+2 而不是 5+1（实测踩过）。群结构 = `{"leader": Node2D, "members": Array}`，**全群共享同一个 Dictionary 实例**。
- **分工**：群主按 `roam` 模式满地图游走；成员在 `EnemyPatrolState` 里只做一件事 —— `follow_pack_leader()`。「一起移动」= 群主铺目标 + 成员跟队形。
- **群主阵亡**：`_die()` 里先 `_leave_pack()`；如果死的是群主，`_promote_pack_leader()` 把位置让给 `members` 里第一个活着的（顺序 = 入群先后）。
- **代码位置**：`enemy.gd`（`ai_cfg` / `ai_*` 访问器 / `pack_*` / `_tick_pack` / `pick_roam_target` / `alert_from_attacker` / `follow_pack_leader`）+ `enemy_patrol_state.gd`（跟随者分支）+ `noise_system.gd::emit`（耳朵倍率）+ 三个攻击调用点（`player.gd` ×2、`projectile.gd`）。
- ⚠ **踩过的坑**：`ai_cfg()` 的合并结果**不能无条件缓存** —— `_ready()` 早于 `setup()`，而 `_ready` 里的状态机起手就会问一次 `roam.mode`，那时 `_type_cfg` 还是空的；把那次结果缓存下来会让**所有兵种**的 ai 覆盖失效（表现为劫掠者也成了 home_radius / 1.0 听力 / 不成群）。修法：`setup()` 里清缓存 + 只在 `_type_cfg` 非空时才写缓存。

**验证**：`Dev/probe_brigand_ai.tscn` **80 项**（A config 真值 / B 兵种按键覆盖 + 不污染全局 / C 满地图 vs 固定范围（30 次选点的均值、最远距离、可达性）/ D 靠近结伙 / E2 第 6 只被拒 / E 群主挪窝成员跟着挪 / F 群主阵亡接任 / G 只跟同类 / H 挨打 → 转调查 → 朝攻击者走 / I 听力：远到普通怪听不见而劫掠者听得见、同距离更清，且普通怪收信强度与旧公式逐位一致）。
另有 `Dev/probe_brigand_live.tscn` **16 项**：真实 `Main.tscn` 94 只敌（劫掠者 37）—— 满地图目标 24/24 都 ≥400px、最远 8272px（跨半张图），弓手仍只在出生点附近 12/12，6 只聚一起并成 5+1 群且没有任何一群超过 5，最后让没被干预的劫掠者自己跑 240 帧、5/5 都真的挪了地方（防止 A* 在真地图上把它卡死）。

### 5.6 视野 / 迷雾（2D `fog_system.gd`）
- **软边羽化**：不再用逐格 `TileMapLayer`（硬边、曾出现"黑点"）。改为「每格 1 像素的探索遮罩 `Image`(**RGBA8**) → `ImageTexture`」+ 覆盖全图的 `Sprite2D`（`z_index=5`）跑 canvas_item 着色器：对遮罩做 5×5 高斯模糊 + `smoothstep` → 揭示圈边缘平滑羽化。
- **为何用 Sprite2D 而非 ColorRect**：ColorRect 是 Control，会进 GUI 输入层，全屏覆盖即便 `mouse_filter=IGNORE` 也可能吃掉局内 RTS 的点击/选中（表现为"选不中角色、操作不了"）；Sprite2D 是 CanvasItem，完全不参与输入。
- 羽化宽度 `fog.feather_cells`（格，默认 2，0=硬边）。探索记忆仍永久（只增不减）；CPU 仅在探索到新格时 `_mask_tex.update(_mask)` 每帧至多一次，**模糊在 GPU 做**（不逐像素算，避免卡顿）。每帧按 `player.vision_radius_cells(10)` 揭圆。
- 实体显隐不变：世界坐标 `distance_to(player) ≤ vision_px`，相机缩放不影响逻辑视野；`VISION_GROUPS = enemies / animals / loot_nodes` 仅视野内可见。
- **小地图同步（2026-09-17）**：遮罩是 RGBA8，**两个通道各管一件事** —— `.r` = 已探索(1/0) 给主地图着色器做羽化、`.a` = 未探索(1/0) 给小地图当黑色遮罩；已探索 `(1,1,1,0)`、未探索 `(0,0,0,1)` 互为补。**同一张图、同一份真相**：揭一格就写这一个像素，小地图侧**零同步代码**（它是纯消费者，拿到的是同一个 `ImageTexture`，不是拷贝，见 §3.5）。局外（基地）与 `--no-fog` 时 `minimap_fog_texture()` 返回 `null`，小地图整层跳过 —— 这条「同生共死」避免 `--no-fog` 出图变成「主图没雾、小地图一片黑」。
- 探针 `Dev/probe_minimap_fog.tscn` **34 项**：遮罩格式 / 双通道互补、**全图 16384 格逐格校验像素与探索字典零漂移**、揭一格当帧变透明、纹理生命周期（局内非 null / 回基地 / disable 后 null）、小地图与 fog 持有**同一个纹理对象**、与地形底图同尺寸、绘制层顺序（雾夹在 extraction 与 squad 之间）。
- 3D 版 `fog_3d.gd` 是等距地面 + shader 软边遮罩，与 2D 逻辑独立（不接入线）。

### 5.7 生存 / 物资消耗（`survival_system.gd`，2026-09-18 通用物资表 → 2026-09-19 **各吃各的**）
- **每分钟逐项消耗**：`survival.meal_interval 60s`（走局内时间轴 × `debug.time_scale`）到点，遍历**存活角色**，每人按 `survival.supplies` 列表逐项从**他自己那份背包**扣 `per_meal`（`player.take_item`；背包一人一份的来由见 §5.11）。加一种物资 = 配置里加一行，代码不动；列表清空 = 整套机制关闭。
- **短缺只降属性，不致死，而且只降他一个人的**：某人某项**没扣到** → 记进 `shortages`（形状 `{角色实例 id: {物资 id: true}}` —— 按实例不按名字，同名队友得各算各的，人离场那格自然作废），把**他自己**各短缺项的 `shortage_debuff` 相加合并成一张表（`penalties_for(p)`），只推给他本人的 `Player.supply_penalties` 并调 `refresh_supply_stats()`。多种物资同时缺同一属性 → 点数相加（各扣各的，不取最大）；队友缺不缺、缺几种，与他的属性无关。可写的键 = `WIRED_STATS`（`attack` / `defense` / `move_speed` / `vision` / `attack_range` / `attack_speed` / `projectile_speed`，与 `progression.traits` 同一套 id 与单位）；写了没接线的键（如 `hp`：缩上限要牵动已有血量与血条，故意不支持）`_ready` 里 `push_warning` 喊出来。七条读点全在 `player.gd`：`trait_damage` / `_compute_speed` / `take_damage` 的减免 / `vision_px` / `_range_bonus` / `_trait_cadence_scale` / 弹速。
- **补上立刻全额还原**：`_refresh_shortages()` 每帧看**他自己**的存量 `item_count(id) ≥ per_meal` 就把该项从他名下抹掉（不等下一个 tick），整人不再短缺就连同那格一起删；扣减不进存档。
- **触发点 = 消耗失败，不是「背包空」**：开局背包本来就没东西，用「上一次 tick 没扣到」当短缺成立的条件，才留得出第一分钟的宽限。
- **饥饿掉血保留但封底**：仍每 `starvation_interval_seconds 30` 掉 `starvation_damage 5` 血（`apply_direct_damage(5, floor)` —— 不走硬直/击退/无敌帧），但**只掉短缺那几个人的血**（背包够的人不该替队友挨饿），且血量不低于 `survival.starvation_hp_floor 1`；**最后一滴只能由敌人补刀**（战斗伤害不吃这条下限）。
- 按 `H` 主动进食仍是**食物专属**，吃的是**目标角色自己包里**的那一份：非满血且他有食物才扣 1 份 `heal(25)`，进 `eat_cooldown 1.0`；满血/无食物/冷却中失败。`eat(who)` 省略 `who` = 当前被指挥的角色。
- HUD（`hud.gd::_refresh_survival`）逐项列**全队总账**存量与「下次消耗 Ns」，短缺时把人名写进「短缺：枪手、弓兵」（`hungry_names()`）并标红降了哪几条属性 + 「补上即恢复，不会死」；单个人的短缺明细在头顶背包弹窗里（§5.11）。
- **验证**：`Dev/probe_supplies.tscn` **39 项**（A 配置结构自洽 / B 逐项扣、各吃各的（甲扣不到、乙够） / C 攻击力·移速真的按表下降，未配的射程·视野一动不动，未注入的新角色不受影响，**且掉属性的只有缺的那个** / D 补货后只等帧不等 tick 就还原 / E 饥饿 6 次停在封底且 `is_dead()` 为假、敌人 500 伤害照样打死 / F override 加第二种物资（油）不改代码即生效且扣减相加 / G 进食回血吃自己包里的、满血拒绝）。已登记进 `tools/run_regression.py`。

### 5.8 战斗判定（`player.gd` + `combat/`）

**自动战斗（2026-09-17 起，取代手动攻击键）**
- 两个属性：**观察视野** `player.vision_radius_cells`（格）× `map.tile_size` = `player.vision_px()`；**攻击距离** = `player.attack_range_px()`（按武器分型取）。
- **有效攻击距离 = min(攻击距离, 观察视野)** —— 强弩表上 900px 超过 10 格视野（640px），实际只打到 640px。
- 索敌：`_update_auto_target()` 每 `combat.auto_attack.scan_interval_seconds=0.15` 扫一次 `enemies` 组，取「视野内 ∩ 有效攻击距离内」最近的敌人；**够不着的不追击、原地不动**（角色不会自己跑过去）。
- 起手：**只有 idle 状态**在 `auto_target() != null` 时转 `attack`；**move 状态不索敌**（2026-09-19 改，见下）。起手朝向锁定目标（`aim_at_auto_target()`）；打完回到 idle（若还有移动指令则回 move 继续赶路）。连打节奏由武器时长决定，无额外冷却。
- **玩家的移动指令优先于自动战斗**（2026-09-19，用户报「点十几下之后控制不了」）：以前 `attack/hitstun/dodge/idle` 进状态一律 `stop_moving()`，等于每次起手都把玩家刚点的那一下抹掉；再加上 move 状态自己也会让位给索敌，结果是"点了地 → 半路开打一停 → 指令没了 → 再点也没反应"。现在拆成两条：`stop_moving()` 只在**玩家主动取消 / 死亡**时调用，被打断改用 `halt_in_place()`（只停脚、留指令）；move 状态不再被索敌抢走，要打断得先有新指令。守卫：`Dev/probe_click_move.tscn`（连点 16 次，逐条判定"未受理 / 原地卡死 / 中途丢指令 / 预算内没走到"）。
- 小队**全员**自动战斗（不只被选中的那个）；只锁 `enemies` 组，中立生物（羊）不会自动开火。
- 目标死亡 / 被回收 / 跑出有效射程 → 立刻重扫换目标（只判 `is_dead` 会导致"对空气空挥"，已按距离复核）。
- 开关：`combat.auto_attack.enabled`（设置面板「玩法」页，默认开）。关掉后完全不开火。
- 近战判定框半径 = 有效攻击距离；远程 / 瞬狙为 0（判定在弹道或射线上，玩家身上不挂框）。

**指令层（菜单栏 → 角色，架在自动战斗之上）**
- 目标选取优先级：**指定目标（仍在有效射程内）→ 按索敌策略挑**；两者都受「观察视野 ∩ 有效攻击距离」约束，够不着的指定目标**自动解除**（`_update_auto_target` 里 `designated_target` 先过 `_within_reach` 复核）。
- `player.auto_attack_on`：本角色总开关，关掉只停索敌开火，**不拦移动/巡逻令**（与全局 `combat.auto_attack.enabled` 是两回事，全局关掉时谁都不打）。
- `player.target_stance`：`nearest` / `strongest`；strongest 威胁评分 = `max_hp + damage × 0.5`。
- `designated_target`：菜单栏「指定攻击」点选（`designate_pick_radius_px 96` 内取最近敌人）；目标死亡/回收/出射程即自动回落策略索敌。
- 巡逻：`_patrol_points` 环形路线，`_patrol_active` 时朝 `_patrol_index` 的下一点走；到点＝移动目标被清空（`has_move_target()` 转 false，由移动状态自己判到达），停 `patrol_wait_seconds 0.6` 再取下一个。`_patrol_index` **下令时就自增**，被打断不会原地重走同一点。路线用 `Line2D` 闭环画世界（仅选中可见），`cancel_commands()` 清点停走。
- 输入：左键 = `command_click(世界坐标)`（待点选时＝点敌/点地，否则＝移动/路由到小地图）；右键 = `cancel_commands()`；ESC = 仅退出待点选模式（**不再吞整局 ESC**）。

**三种分型的判定**
- **melee**（`player_attack_state` + `resolve_attack_hit`）：WINDUP→ACTIVE→RECOVERY；ACTIVE 每帧取 Hitbox `get_overlapping_areas()`，`arc 200°`(半角 100° 过滤)、`max_targets 3` 去重、`range 120`=Hitbox 半径；伤害经 `DamagePipeline.compute`（当前无暴击/减伤/浮动≈原值）。
- **ranged**（`fire_projectile` + `combat/projectile.gd`）：ACTIVE 进入瞬间发一次；命中＝点到本帧飞行线段最近距 ≤ `hit_radius 16`（防穿透与步长无关），撞墙按 ≤ 半格采样，命中优先于撞墙。
- **hitscan**（`fire_hitscan`，出枪同帧）：射线枪口→+facing×`900`；`first_wall_point` 半格采样截断到首墙；沿线取前 `pierce 2` 个；每个 `DamagePipeline`；Line2D 曳光 + 命中点 fx_ring。
- `combat.attack` 与 `combat.weapons.*` 回退：先查当前武器字典，缺键回落 `combat.attack`；`kind` 缺省 melee。
- `input.buffer 0.25`：闪避等输入预输入入队，idle/move 态 consume（攻击已无键位）。

### 5.10 角色等级 / 名册（`progression` 段，2026-09-17 用户定）

**玩法规则**：最多 **9 级**、初始 **0 级**、升级难（要多局才满）；**死亡永久** —— 单位阵亡即从名册除名，等级与经验一并消失（复活功能以后再加）。

**核心决定：等级挂在「人」身上，不挂在兵种上。** 因为死亡永久，同一个兵种可以有两个人、各自等级不同，死一个就少一个。所以：
- 持久层是 **`Meta.roster`**（写进存档槽的 `roster` 键）：`[{uid, id, name, level, xp}]`；
  `id` 是指向 `characters.list` 兵种原型的外键（决定武器 / 指令集 / 描述），`level`/`xp` 是个人的。
- 出击面板（`character_select_panel.gd`）列的是**名册里的人**，不是兵种原型；出击信号带 `uid`+`level`，`main._squad_characters()` 把它和原型合并后注入每个玩家实例（`player.roster_uid` / `player.level`）。
- `player.on_death()` 里 `Meta.remove_unit(roster_uid)`；`run_manager._end_run("extracted")` 里 `Meta.grant_xp_to_survivors()`（只发活着的、有名册身份的）。
- `roster_uid == 0` = **无名册身份**（命令行 / 无头回归 / `auto_enter_run` 直跑 Main.tscn）：不发经验、死亡不除名，行为与加等级之前完全一致。

**视觉 = 方案三（用户 2026-09-17 选定）：配色管档位、数字管精确等级。**

| 档位 id | 等级 | 档位名 | 配色（素材包阵营）| 光点基色 |
|---|---|---|---|---|
| `blue` | 0–2 | 新兵 | Blue | `#4FA8F0` |
| `purple` | 3–5 | 老兵 | Purple | `#A98CFF` |
| `black` | 6–8 | 精锐 | Black | `#C9D2E0`（银灰）|
| `gold` | 9 | 传奇 | **Yellow** | `#FFC53D` |

> 基色 2026-09-18 **整体提亮**（旧值 `#378ADD`/`#7F77DD`/`#5F5E5A`/`#EF9F27`）：压到屏幕上显脏，精锐档那颗灰黑更是"太深"的最大来源。精锐改**银灰** —— 与 6–8 级角色的 Black 阵营甲同属黑白灰一族（银就是黑甲的提亮版），档位语义不丢。出击面板色块读同一份配置，跟着一起变。
> 注意这里只是**基色**：光点实际绘制时会朝白 lerp `glow.tint_white`(0.55)，所以**看到的比这些色值淡得多**（蓝档饱和度 0.67 → 0.29），档位区分度也相应变弱 —— 这是"颜色尽量淡"的代价，刻意的：谁是我方靠选中框/小地图点（恒阵营蓝），档位靠身上甲色。

- 配色映射在 `progression.sprite_sets.<档位>.<武器>` → 精灵集名；`player._sprite_set_for_weapon()` 顺序：**档位配色 → 武器自带 `sprite_set` → `player.sprite_set`**。加档位只改 config，不动武器表（档位是等级的、武器是兵种的，两者正交）。
- **等级淡光**（`unit_level_badge.gd`，挂在 `Scenes/Player.tscn` 的 `LevelBadge` 节点）：UI 层 `_draw` 自绘、**不烘进贴图**（9 级 × 3 角色 = 27 套帧，且改数值要重出图）。档位变了才换整套贴图（`apply_level()` 里判 `tier_changed`），档内只换数字。
- **三次改版，每次都是用户判「丑」，病根逐次挖深**：
  1. 「半透明黑圈 + 白数字」→ 违和。三个根因：数字用 `ThemeDB.fallback_font`（矢量抗锯齿字）压在 Tiny Swords 像素小人头上，两种画风硬拼；世界空间固定尺寸，缩到 0.35 倍糊成一点、拉到 3 倍变成压在头顶的大黑圈；「半透明黑底 + 白字」是 UI 提示牌的语言，挂在角色身上像别了个工牌。
  2. 「卡通糖果球」（细描边定形 + 上部球冠亮面 + 底部薄影 + 高光点，`_cap_polygon()` 画球冠）→ **仍然丑：画成了实体**。越是「画得完整」越像一颗真球挂在人身上；首版那圈暗边大环只是把「深色从面收成线」，换汤不换药。
  3. **本版：删掉一切轮廓。** 光不该有边界 —— 现在是几层**同心软边光斑**从内到外化开（外大而极淡当光晕、内小而亮当光核），颜色朝白推淡。它不再是一个「东西」，而是角色身边忽明忽暗飘着的一缕光。**每层是运行时生成的径向渐变贴图**（`_ensure_glow_tex()`，48×48、static 全场共用一张），不是 `draw_circle` 的实心圆 —— 实心圆叠起来放大能数出一圈圈同心环，像个靶子（实拍抓出来的）。
- **四条行为约定**（用户原话：时隐时现 / 时快时慢 / 颜色尽量淡 / 在角色四周飞）：
  - **时隐时现** —— `pulse_visibility()` 把两条**不同周期**（`pulse_seconds` 3.4 / 2.1，不整除）的正弦叠加，明暗节奏因此不规律（不是呼吸灯那种匀速明灭）。clamp 到 [0,1] 后**两端都有平台**：真的会完全隐没（探针测到 0.000）、也真的会完全显现（1.000）。`pulse_power 1.15 > 1` 让暗的时间不短于亮的；`min_scale 0.72` 让暗时收缩，有「凑近 / 退远」的体积感。
  - **时快时慢** —— `orbit_angle()` 的角速度 ω(t) = `spin_speed` + 两条正弦的导数，实测 ω ∈ [0.42, 2.00]，**差 4.7 倍**。⚠ **硬约束：两条 sway 项之和（amp × 2π × hz）必须 < spin_speed**（当前 0.80 < 1.20），否则 ω 变负 → 光点原地掉头，看着像故障不像飘。探针 K 段用数值微分守这条，并校验配置层面的数学前提。
  - **颜色尽量淡** —— `glow_color()` 把档位基色朝白 lerp `tint_white`(0.55)，再乘 `max_alpha 0.9`（<1 才有「虚」的质感）。
  - **绕着角色四周飞** —— `center_offset_y` 落在**身体中部**（-34，旧值 -56 是头顶），`orbit_y_scale 0.85` 让纵向跨度够大：实测光点会掠过头顶（-68.8）到脚边（+0.8），纵向走位跨度约 50 px。
- **「飞舞」是有界的伪随机**：角度自转 + 轨道半径缓慢呼吸 + 正弦抖动，光点永远落在 `orbit_radius_px` 上限 + `wobble_px` 之内（探针 C 段 600 点采样断言）。真随机（每帧 `randf`）会抖成筛子、还会飘走或被角色挡住。
- **屏幕恒定尺寸 + 缩远淡出**：`orb.screen_fixed` → 绘制尺寸乘 `1/zoom`，任何视野下一样大（`drawn_radius_world() × zoom ≡ radius_px`，探针 F 段）。`far_fade` 在 zoom 0.95 → 0.70 线性淡出：看全图时不出光点，省得远景糊成一片。
  > ⚠ 世界半径兜底上限 `_radius_max_world = max(radius_px, orbit_r_hi)`，**别收到 `orbit_r_lo × 0.5` 那种量级** —— 那样 zoom 0.8 这种正常视野就会撞上限，把「屏幕恒定尺寸」这条更重要的观感特性打掉（探针 F 段抓到过）。极端视野本来就有 far_fade 兜着。
- **数字不常驻 → 想知道就点一下**：平时不显示数字，每隔 `flash.interval`（5~9s 随机）闪一次；闪的那 1.2s 里光点胀大 2.0 倍、光心亮出卡通数字（深色描边 + 白填充）。`player._set_selected(true)` 调 `notify_selected()` 让光点立刻闪一次（`flash.on_select`）；升级也闪（`flash.on_level_up`，等级没变不闪）。**flash 期间可见度被强制拉满** —— 否则光点正好处在「隐」的时刻，闪了也白闪。
- **选中标记改用暖色**（`player.selected_color`：`#4fc3f7` → `#FFC14D`）：等级光点是蓝白系，两个蓝色悬浮物挤在一起会分不清哪个是「选中」哪个是「等级」（连拍实拍时看出来的）。
- 探针钩子 `zoom_override`（headless 常没有 Camera2D，读不到倍率）、`drawn_radius_world()`、`view_alpha()`、`glow_texture()` 专供 `probe_level_orb` 断言，正常游戏流程不碰。
- **恒定蓝色锚点**：体色一旦承载等级，「谁是我方」就不能靠体色判断了 —— 选中框 / 小地图点 / 面板色块沿用阵营蓝。

**经验**：`progression.xp`，升到下一级需 `round(base × growth^当前等级)`，现 `base 100 / growth 1.3` → 升级线 100/130/169/220/286/371/483/627/816，**累计约 3200 ⇒ 单局撤离 100，约 32 局满级**（"难但有尽头"）。`per_kill = 0`（关掉的）。
> ⚠ 曲线是**指数**的，别按"每级 +100"估总量：`growth 1.9` 时满级要 **357 局**（首版就是这个数，注释还错写成"约 7000 经验"）。调这个值前先算一遍 `Σ100·g^n (n=0..8) ÷ 100`。

**面板上的「补招新兵」**：`progression.roster.recruit_free = true`、`max_size 8`。没有复活功能时，全员阵亡会让玩家彻底没得玩，所以名册不满就给补招按钮（每次 Lv0 新兵）。

**踩过的坑**：
1. **档位 id 与素材包阵营名不是一回事**：`gold` 档用的是素材包 `Yellow Units/`，切出来是 `yellow_*` 目录。首版配置按档位 id 拼了 `gold_lancer/` → load() 静默 null → 升到 9 级角色消失。`probe_level` D 段逐帧 `ResourceLoader.exists()` 就是为了兜这种错。
2. **`tier_of_level` 越界必须钳到末档**（`clampi(lv, 0, max_level)`）：返回空字典会让调用方回落"蓝档/新兵"，表现为"面板写着传奇、身上穿着新兵蓝"。
3. **`player.level` 必须在 `add_child` 之前设**：`player._ready()` 里就按 level 选贴图集，晚一步会先套蓝甲再被换掉（闪一帧）。
4. 探针里量"身上贴的是哪套帧"要用 **`Body.texture.resource_path`**，不要用纹理对象 id：换帧要等 animator 下一次 `update()` 才落到 Sprite2D（同帧取到旧图），而同档位播放中帧号本来就在变（对象 id 天然会变）。

**验证**：`Dev/probe_level.tscn`（164 项：配置真值 / 档位映射 / 武器×档位映射 / 四档每帧都存在 / 名册数据层 / 经验曲线与升级 / 撤离发经验 / player 换档贴图与等级显示 / 死亡除名 / 出击面板）；等级淡光另有 **`Dev/probe_level_orb.tscn`（104 项：光点配置真值 / 节点接线 / 轨道有界 600 点采样 / 闪烁状态机三段 / 自动闪烁节奏落在 interval 内 / 屏幕恒定尺寸与缩远淡出 / 点选与升级联动 / enabled 开关停 process / **I 淡光长相**（旧的 `orb.look` 必须已从配置移除、柔光层 ratio 递减 + alpha 递增、贴图已生成、四档色淡化后饱和度降）/ **J 时隐时现**（明灭采到底 min≈0 且 max≈1、中间态占比够高、flash 强制拉满）/ **K 时快时慢**（ω 数值微分恒正 + max/min > 1.5 + 配置层面「sway 和 < spin」的数学前提）/ **L 绕着四周飞**（中心不在头顶、纵向跨度够大、不钻地）** —— 它全程**手动步进 `_process(delta)`**（先 `set_process(false)`），因为 headless 的真实帧率不确定，等真实帧数验不了"闪 1.2 秒"这类时间语义。两个探针都会改 `Meta.roster` / 触发存档写入，所以**开跑先备份 `user://save.json`、收尾原样还原**。
**视觉改动必须开窗实拍 + 放大看**（`--headless` 是 dummy 渲染驱动，viewport 贴图永远空白、截出来纯黑）：
- `Dev/shot_orb_showcase.tscn` —— 四档并排：上面放大看构造，下面**真实大小**下同一档位画三个**不同明灭时刻**的光点、围着一个角色剪影（正常开一局只可能看到 0 级那点蓝光，想验四档得打满 9 级）。⚠ `_phase` 是随机的 → 可见度跟着随机，所以展示场景会**显式钉住 `_phase / _t`**（`_t_for_visibility()` 反查一个能得到目标可见度的时刻），否则排版不可复现。
- `Dev/shot_orb_motion.tscn` —— **局内连拍** 12 帧（间隔 0.45s ≈ 5.4s，正好一圈）拼成网格，验证「绕飞 + 明灭」。⚠ **不能靠 shot2d.py 连跑几次拼图**：`_phase = randf()` 每次启动都不同，跨进程拼出来的「轨迹」是假的 —— 必须在同一进程里沿同一条时间线连拍。它每帧还会打印 `zoom / view_alpha / vis / cur_a / t / offset / r_world`，这类「局内看不见它」的问题只有把这些摊开才能定位。
- 单帧真实局内仍走 `tools/shot2d.py`。

### 5.11 背包（一人一份，2026-09-19 用户定）
旧版是「全队共用一本公共背包」，现在**一个角色一份**，三条配套规则也都是用户定的：物资**各吃各的**、拾取归**走进范围的那个人**、**阵亡当场撒成一地**。

- **记账位置**：`player.inventory`（`Dictionary{资源 id → 数量}`），配 `add_item()` / `take_item()` / `item_count()` / `backpack_capacity()`。格数上限的**数值来源与旧版一字不差**（局外养成注入的 `player_stats["survival.backpack_capacity"]`，缺配置回落 `meta_progression.survival.backpack_capacity.base 10`），变的只是单位：一本 → 一人一本。格子规则也没变：**一种资源占 1 格、已有种类无限叠加**；新种类且格子已满 → `add_item()` 返回 false；`take_item()` 把某项扣到 0 就立刻释放那一格。
- **RunManager 不再自己记账**（`run_manager.gd`）：只留三样 —— `total_loot()` 全队总账（HUD「背包」栏与撤离入库都读它）、`carrier()` 第一名存活角色、`backpack_capacity()`。`add_loot()` 保留但语义是**把东西交给第一名存活角色**（给 `main.gd` 自检与 `--walk-test` 那类"凭空塞东西"的调试路径用），不是"放进公共池"；场上没活人时才挂进 `_unassigned_loot`（正常局内恒空，别拿它当第二本背包）。
- **拾取归属 = 范围内最近的那个活人**（`loot_node.gd::_nearest_living_carrier()`）：资源点 Area2D 半径 = `loot.pickup_radius_px 80`，`_physics_process` 在**压住它的角色**里挑离得最近的那个，由**他** `add_item()`。为什么要挑：小队 2~4 人挤一起时 `get_overlapping_bodies()` 一次给好几个，按节点顺序发会变成"先出生的那个永远通吃"。拒收（格子满）→ 资源点留在原地、`loot.pickup_retry_seconds 0.5` 后自动重试；本局已结算则不再进包。
- **消耗与短缺按人算**：见 §5.7 —— 到点逐个角色从**他自己那份**扣 `per_meal`，扣不到只记在他名下、只掉他自己的属性。
- **阵亡 = 整包就地撒成一地**（`player.drop_inventory()`，由 `on_death()` 调）：每种资源变成一个 `LootNode`（视觉 ×0.8 与敌人掉落同路），绕尸体均匀撒开一圈 —— 半径 `loot.drop_spread_px`（代码默认 22px），十来种叠在同一像素会糊成一坨、也分不清掉了什么。**不随人消失、也不凭空回仓库：想留东西就得有人活着把它捡回来。** 只有阵亡走这条路 —— 撤离按 `total_loot()` 入库、超时本来就全丢（探针 I 段守的就是这三条不串门）。
- **右键角色 → 头顶弹窗**（`inventory_popup.gd`，由 HUD 创建、挂在 HUD 这个 CanvasLayer 下，group `inventory_popup`）：
  - **只读**面板 —— 只解决「看清楚谁身上有什么、他缺什么」；没有丢弃/转移按钮，搬运只有上面那两条路（走进范围 / 阵亡撒地）。
  - **触发点在弹窗自己的 `_input()`**，不是 player 的 `SelectArea.input_event`：右键那一下本来归 `player._unhandled_input` 的「右键 = 取消指令」管，两条规则会抢同一次点击；`Node._input` 跑在所有 `_unhandled_input` 之前，命中就 `set_input_as_handled()`，外面的规则根本看不到这一下。附带好处：无头探针没法伪造 Area2D 拾取，却可以直接调 `right_click_at(screen)`。面板内部点击也吃掉，不外泄成移动令；ESC 这次只收弹窗。
  - 命中判定用 `player.select_radius_px`，**先把屏幕点换算到世界再比** → 缩放/平移自动跟手。`right_click_at()` 的四种落点：点**另一个**角色＝换人、点**同一个**人＝开关切换、点**空白**＝收起（⚠ 这一下同样被吃掉，不会顺手触发"右键 = 取消指令"）、没弹窗时点空白＝返回 false 走老规矩。
  - 位置：头顶 `inventory_popup.head_offset_px`（44 **世界**像素，`_follow()` 里 × zoom 落到屏幕）横向居中，夹在视口内（`viewport_margin_px` 8），**并且不让开底部菜单栏**（让位公式与 HUD 同源 `UiKit.menu_bar_height`）。面板最小宽 `min_width_px` 210；资源行图标 20×20（`EXPAND_IGNORE_SIZE` + `TEXTURE_FILTER_NEAREST` —— 默认的 `KEEP_SIZE` 会拿源图尺寸当最小尺寸，每行高度跟着各资源源图大小不一）。内容指纹 `_sig` 不变就不重排节点，`_panel.reset_size()` 保证内容变了就重算最小尺寸、栏高不被顶高。
  - ⚠ `inventory_popup.*` 三个键与 `loot.drop_spread_px` **目前只写在代码默认值里**，`Data/config.json` 还没有对应项（那文件另有会话在改）→ 运行时按 missing-key 规则各刷一条 `[Config] 缺少配置项` 警告。行为不受影响，补键是收尾项。
  - 短缺红字：`短缺 食物 → 攻击-7 移速-10（补上即恢复，不会死）`，取自 `survival_system.shortage_ids(p)` / `penalties_for(p)` —— **只挂在缺的那个人身上**，这是「各吃各的」在界面上的落点。
- **菜单栏同步**（`menu_bar.gd::_inspected_player()`）：弹窗开着 → 明细行显示**弹窗那个人**、行首写成 `背包（剑士）`；没开 → 显示正被指挥的那个。⚠ **只影响这一行**：上面的单位信息与下面的指令按钮始终归被指挥的角色，否则就成了"按钮打在甲身上、明细显示乙"两处状态各说各话。`bag_line_text()` 是探针断言同步的读点。
- **HUD 左下角背包栏**（`hud.gd`）：`背包 全队 N 种：<总账明细>` + 各人占几格 `剑士 3/10格`，数字全来自 `total_loot()` 与各自的 `inventory.size()`。
- **验证**：`Dev/probe_inventory.tscn` headless **103 项** / 开窗 **107 项**（A 每人一份互不干扰 / B 格子按人算（满格只满自己）/ C 同一轮消耗甲扣不到、乙扣到 → 只有乙掉属性 / D 乙补上货当帧还原、甲照旧 / E 拾取归属给范围内最近那个人、够不到的人一分不得、满包拒收后腾格子自动重试 / F 右键 → 头顶弹窗（含点空白与 ESC 收起、换人、位置钉在头顶）/ G 底部菜单栏与弹窗显示同一个人 / H 阵亡当场撒成一地且能被队友捡回 / I 死亡与超时局不入库、只有撤离入库）。已登记进 `tools/run_regression.py`（`_r_inventory.log`）。UI 部分另按 §5.10 末「视觉改动必须开窗实拍 + 放大看」的口径复查：`panel_rect()`（= `_panel.get_global_rect()`）量位置，开窗截图看排版 —— 断言全绿也可能画面是歪的。

### 5.9 已定义未接线 / 失效清单（当前真实状态）
| 对象 | 状态 | 说明 |
|---|---|---|
| `meta_progression.extraction_speed` | ⚠ 可购买无效果 | 撤离 hold 固定 `session.extraction_hold_seconds`，不受养成加速 |
| `meta_progression.resource_find_chance` | ⚠ 可购买无效果 | 资源点撒量/种类由固定 `loot.density` 与 rarity 权重决定，不读该值 |
| `meta_progression.rare_resource_chance` | ⚠ 可购买无效果 | 同上，掉落权重走 `enemy.drop.weights`/`animals.drop` |
| `storage.max_slots` | ⚠ 零消费 | 仓库格数实由 `warehouse_capacity` 决定（§4.8）|
| `base.interact_radius_cells` | ⚠ 仅 3D 层 | 2D 交互用 Area2D 碰撞矩形 |
| `noise.sources.sniper_shot` | ⚠ 死配置 | 狙击音走武器 `noise 240` |

---

## 6. 音频系统

### 6.1 现状（真实）
- **零音频素材 + 零播放逻辑**：`Assets/Audio/` 仅 `.gitkeep`；全项目无 `.ogg/.mp3/.opus`，无 `AudioStreamPlayer` / `.play()` / 音频加载代码。
- 仅有 `Assets/Audio` 之外的游离草稿 `_mv/{f,g,h,n}.wav` + 抽帧图（Godot 已导入为 `AudioStreamWAV` 但**无任何引用**，属 MV 草稿，非游戏资源）。
- **总线脚手架已就位**：`display_settings.gd _ensure_bus()` 在应用音量时按需 `AudioServer.add_bus()` 动态创建 `Music`/`SFX`（send→Master）；`project.godot` 无 `default_bus_layout`，config `audio` 段注释明确「暂无资源、总线按需创建」。

### 6.2 配置（`audio`，设置面板「音频」页 `live` 即时生效）
| 键 | 值 | 作用 |
|---|---|---|
| `audio.master` | 1.0 | 主音量（Master 总线）|
| `audio.music` | 0.8 | 音乐总线（按需建）|
| `audio.sfx` | 0.9 | 音效总线（按需建）|
| `audio.mute` | false | 一键静音（不动三滑块）|

### 6.3 计划接入
- **BGM**：菜单 / 基地 / 局内各一曲（卡通奇幻基调）。
- **SFX**：攻击、受击、拾取、撤离成功、敌人咆哮（对应 `shout` 噪音 160，逻辑已接、缺音源）。
- 接入方式：`AudioStreamPlayer` + 对应 Music/SFX 总线；当前无实现，属待补内容。

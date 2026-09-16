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
| blue_warrior (`sprites_ts`) | 192² | 137 | −41 | 6 | 1.0 |
| blue_archer (`sprites_archer`) | 192² | 136 | −40 | 6 | 1.0 |
| blue_lancer (`sprites_lancer`，**玩家当前用**) | 320² | 198 | −38 | 10 | 0.6 |
| enemy pawn/archer/monk | 192² | ~135 | −38~−40 | 6 | 1.0 |
| sheep | 128² | 84 | −20 | 4 | 1.0 |

- 方向覆盖：**仅 Lancer 有真 8 向**（Attack/Defence 五向 + 左右镜像）；Warrior/Archer/Pawn 单向 + 水平镜像；Archer 有完整 Shoot 动作（免费包唯一自带拉弓帧）。

### 1.2 玩家与单位的真实贴图集（config 驱动）
- `player.sprite_set = sprites_lancer` → 玩家默认拿剑 = **blue_lancer**。武器可覆盖贴图集：`combat.weapons.bow.sprite_set = sprites_archer`（拿弓切弓手帧）；武器未指定则回落 `player.sprite_set`。
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
| 投射物 / 武器 | `Projectiles/arrow.png`(64²) / `Weapons/sniper_rifle.png`(72²程序像素画) | — | 已有；近战/弓无独立武器贴图 |
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

### 2.4 主基地（Base，`base_system.gd`，含于 `Main.tscn`）
- 64×64 平地（`base.map_size`），外圈 1 格墙；建筑 **4×4 格**（`base.building_cells`）。三栋建筑（`base.buildings`，按物理 `E` 交互）：

| 建筑 | cell | sprite | 交互 |
|---|---|---|---|
| warehouse 仓库 | [24,30] | `house_large.png` | 打开仓库面板（只读展示 `Meta.bank`：种类数 / 仓库格数 / 叠加上限）|
| statue 雕像 | [36,30] | `monastery.png` | 打开升级面板（`meta_progression` 生存/搜刮两组升级，即时生效并存档）|
| gate 出发大门 | [30,42] | `castle.png` | `_enter_run` 进局 |

- 面板打开时 `get_tree().paused=true`；`E` 或 `ESC` 关闭。局外养成写入当前存档槽，影响下局 `max_hp` / 背包 / 仓库容量。

### 2.5 局内游戏（RUN）
- 随机地图（当前 `map.force_seed=20260915` 固定，便于测试）+ 敌人 100 + 中立羊 60 + 资源点 + 撤离点 3 + 2D 战争迷雾。
- 倒计时 `session.time_limit_seconds = 3600`（1 小时）；每帧扣 `delta × debug.time_scale`（当前 ×20 测试加速），≤0 → `timeout`。
- 撤离点时间线：`spawn_at_minutes=30` 刷满 3 个 → `close_one_at_minutes=[45,55]` 各关 1 个 → **最后 1 个保持开放直到超时**（超时＝死亡）。轮到的点若玩家站圈内则改关下一个，全有人则本轮作废。
- 单局循环：搜刮 → 撤离点开放 → 站圈保持 → 携带资源撤离；死亡 / 超时则本局携带资源全失。

### 2.6 结束 / 结算 / 退出（`run_manager.gd` / `hud.gd`）
- 三结局：撤离 `extract()`→"extracted"（**仅此结局 `bank_loot` 入库**）；死亡 `player_died()`→"died"；超时→"timeout"（后两者携带资源全丢）。统一发 `run_ended`。
- 结算面板文案「按 R 返回基地 · ESC 退出」。`R` 仅当 `mode==RUN && state==ENDED` 时 `_enter_base()`；`ESC`(`ui_cancel`) **任何时候直接 `get_tree().quit()` 退出程序**（非回菜单）；关窗亦可退出。

---

## 3. 操作系统

### 3.1 键位（默认，设置面板「操作」页可改；键码存物理键）
| 操作 | 默认 | 键源（config 键 = 值）| 生效时机 |
|---|---|---|---|
| 选中 / 移动 | 左键点玩家选中 → 左键点地面寻路 | `player.select_radius_px=64`, `path_arrive_threshold_px=24` | 即时 |
| 相机平移 | `WASD` / 方向键 | `camera.pan_speed=1600` | 相机 `_ready`（下局）|
| 普通攻击 | 鼠标右键 **或** `J` | `attack_mouse_button=2`, `combat.input.attack_key=74` | 即时 |
| 闪避 | `空格` | `dodge_key=32` | 即时 |
| 进食 | `H` | `survival.eat_key=72` | 即时 |
| 相机回玩家 | `F` | `camera.return_key=70` | 相机 `_ready`（下局）|
| 交互建筑 | 物理 `E`（**硬编码**，不可重映射）| — | 即时 |
| 缩放 | 滚轮 / 触控板捏合，以光标为锚 0.35×–3.0× | `camera.zoom_*` | 相机 `_ready` |
| 边缘滚屏 | 鼠标贴窗口边（需窗口有焦点，`ignore_ui`）| `camera.edge_pan_*` | 相机 `_ready` |
| 局结束返回 | `R`（仅结算面板）| — | 即时 |
| 退出 | `ESC`（全局 quit）| `ui_cancel` | 即时 |

- 输入缓冲 `combat.input.buffer_seconds=0.25`：攻击 / 闪避可预输入（按下入队，超 0.25s 丢弃）。

### 3.2 交互判定
- **建筑**：Area2D 碰撞矩形触发（宽 = `building_cells × tile × 0.86`），进入按物理 `E`。⚠ `base.interact_radius_cells=4.5` 在 2D 线**无消费点**（仅 `entity_visual_3d.gd` 用），不据此调 2D 交互范围。
- **资源点 / 掉落物**：走近 `loot.pickup_radius_px=80` 自动拾取入背包；背包（新种类）满则失败并 `pickup_retry_seconds=0.5` 后重试。
- **撤离点**：站入 `extraction.trigger_radius=96` 保持 `session.extraction_hold_seconds=3` → 撤离；离开或点关闭则进度清零。
- **敌人**：身体接触造成伤害（`enemy.contact_cooldown_seconds=1.0`）。

### 3.3 设置面板（8 页，表驱动，`settings_panel.gd`）
- 页签：**画面 / 性能 / 音频 / 玩法 / 资源 / 操作 / 语言 / 调试**。
- **「资源」页**：上半「地形出现比例」= 四群系面积权重 `map.biome_weights.0~3`（草地/荒原/森林/沼泽，越大越占地方）；下半「地图资源成簇」= `tree/rock/iron/oil` 各自的 `count`（每群系簇数）+ 四群系 `weight`（最小聚合格数兼总量比例）。均下次生成地图生效。
- **「性能」页（降配提速）**：暴露此前未进面板、但被 2D 代码消费的降配杠杆——`enemy.ai_active_radius_cells`（休眠半径，每帧读取即生效）、`enemy.los_step_cells`（视线采样步长，即生效）、`player.vision_radius_cells`（迷雾揭示半径，下次进局）、`map.decor.shadow`（装饰投影，下次生成地图）；并给 **「性能优先」/「恢复均衡」一键预设**（`_PERF_BUNDLE`：一次性把 `decor.shadow/density`、`macro_light/grade.enabled`、`vision_radius`、`ai_active_radius`、`los_step`、`enemy.count`、`animals.count`、`loot.density`、`max_fps` 写入**用户层**，恢复均衡逐项清除回落出厂）。其余降配项散在「玩法」（资源点密度/敌人中立数量/装饰密度）与「画面」（明暗/调色/帧率上限/垂直同步）。
- **暂存 + 确认生效**：面板内所有编辑先进内存暂存（`_pending_set`/`_pending_clear`），**点右下「确认应用」才批量落盘 `user://settings.json` 并 `DisplaySettings.apply_all()`**（`display.*`/`audio.*` 即时作用，其余项下次进局 / 生成地图读到）；未确认前不写盘、不生效。每行右上有「默认」把该项暂存回出厂值。
- **界面形态**：全屏铺满（外层 Margin 留 28px）；每行标签左对齐、控件右对齐（两边对齐）；底部「确认应用」主按钮（无改动时禁用）+「N 处未确认」计数；「返回」若有未确认改动会弹二次确认再丢弃。
- 可改键 = 「操作」页 4 键 + 1 鼠标键；底层写用户层嵌套 JSON（如 `{"combat":{"input":{"attack_key":…}}}`），与 config 同构。
- 语言页**非真 i18n**：选择存 `language.current`，但无翻译表，界面仍中文（`available` 仅 `zh_CN` ready，`zh_TW/en/ja` 未 ready）。

### 3.4 调试开关（真相：config + `--` 并存，见 §0.3）
- config `debug.*`（当前出厂）：`auto_enter_run=true`（菜单进游戏时被覆盖为 false）、`time_scale=20.0`、`log_state_transitions=false`、`smoke_test/flow_test=false`、`map_preview=""`(配 `map_preview_cells=128`/`_scale=0.125`)、`main3d_*`（仅 3D 线消费）。`time_scale` / `log_state_transitions` / `auto_enter_run` 亦挂设置面板「调试」页可改。
- CLI：`--seed`（压 `map.force_seed`）/ `--preview-map` / `--capture2d` / `--dump-atlas` / `--dump-biome` / `--zoom` / `--soak*` / `--weapon bow|sword|sniper` / `--no-fog` / `--no-macro` / `--menu-*`。

---

## 4. 数值系统（全部数值，源 `Data/config.json`）

### 4.1 玩家（`player` / `combat.player`）
| 键 | 值 | 说明 |
|---|---|---|
| `player.speed` | 640 px/s | 移动 |
| `combat.player.max_hp` | 100 | 基础生命（含雕像升级）|
| `player.vision_radius_cells` | 10 | 视野 / 迷雾揭示半径 |
| `combat.player.hitstun_seconds` | 0.25 | 受击硬直 |
| `combat.player.invincible_after_hit_seconds` | 0.4 | 受击后无敌 |
| `combat.player.knockback_speed` | 560 | 击退 |
| `player.sprite_scale / offset_y / pixel_unit` | 0.6 / −38 / 10 | lancer 显示参数 |

### 4.2 武器（`combat.weapons`）
| 武器 | kind | 伤害 | 射程/范围 | windup/active/recovery | 噪音 |
|---|---|---|---|---|---|
| 剑 `sword` | melee | 25 | 120px / 200° / 3 目标 | 0.12 / 0.08 / 0.20 | 120 |
| 弓 `bow` | ranged | 20 | 弹速 900 / 最大 640px / 1 目标 | 0.30 / 0.06 / 0.18 | 70 |
| 狙击 `sniper` | hitscan | 90 | 最大 900px / 穿透 2 / 2 目标 | 0.55 / 0.04 / 0.90 | 240 |

- 通用兜底 `combat.attack`：dmg25 / 120px / 200° / 3 目标 / windup0.12 active0.08 recovery0.2 / `cancel_window 0.08`（武器表缺项回落；武器表空＝退回单武器行为）。
- 弓箭矢（`bow.projectile`）：`speed 900`、`max_distance 640`、`hit_radius 16`、`muzzle_offset 22`、texture `arrow.png`。
- 狙（`sniper.hitscan`）：`max_distance 900`、`hit_radius 18`、`pierce 2`、`muzzle 34`、`tracer_width 2.5`(#ffd873, fade 0.18)、`impact_radius 26`(#ff9a3d)；枪贴图 `sniper_rifle.png` offset[8,−20]。
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
| `enemy.hit_flash_seconds` / `death_fade_seconds` | 0.18 / 0.45 |
| `enemy.drop` | chance 0.75，amount 2–6，权重 wood3/stone3/iron2/food3/gold1/oil1（落地为地上 LootNode，走近自动拾取）|
| `animals.count` | 60（距玩家 ≥10 格；`wander 10`/`flee 6` 格；`speed 240`；`flee×1.6`）|
| `animals.hp` | 12 |
| `animals.drop` | chance 0.9，food 1–3（地面 LootNode）|

**敌人类型（`enemy_types.types`，按 `weight` 概率抽取，有放回）**
| id | 阵营/兵种 | weight | hp | damage | speed_mult |
|---|---|---|---|---|---|
| brigand 劫掠者 | red/pawn | 4 | 40 | 10 | 1.0 |
| raider 弓手 | red/archer | 3 | 30 | 8 | 1.15 |
| cultist 邪术师 | red/monk | 2 | 55 | 14 | 0.85 |
| marauder 掠夺者 | yellow/pawn | 2 | 70 | 16 | 1.0 |

> ⚠ raider 用弓手外观与 attack 帧，但**代码不发弹道**——所有敌人均近战接触伤害（见 §5.5）。

### 4.4 噪音（`noise`）
| 键 | 值 |
|---|---|
| `hear_radius_cells` / `min_notice` | 16 / 4 |
| `wall_attenuation` / `decay_per_second` | 0.5 / 10 |
| `max_alertness` | 150 |
| `footstep_interval_seconds` | 0.4 |
| `thresholds.suspicious / investigate / combat` | 15 / 30 / 70 |
| `sources` | walk 22 / dodge 40 / attack 120 / shout 160 / ~~sniper_shot 240（死配置）~~ |
| `ring` | duration 0.7s，color #ffd54f，alpha 0.35，min_intensity 35，min_interval 0.15 |

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
- 生存：`meal_interval 60s`（耗 `food_per_meal 1`）；`starvation 5 伤害 / 30s`；主动进食 `heal_per_food 25`、`eat_cooldown 1.0`、键 `H(72)`。
- **局外养成（Meta，费用 = `cost × (等级+1)`，逐项资源乘）**：

| 升级项 | 组 | base | per_level | max | 单次 cost | 运行时 |
|---|---|---|---|---|---|---|
| max_hp 生命上限 | survival | 100 | +10 | 5 | 铁 30 | ✅ 生效 |
| backpack_capacity 背包容量 | survival | 10 | +2 | 5 | 木 25 + 金 1 | ✅ 生效（种类格数）|
| warehouse_capacity 仓库容量 | survival | 20 | +5 | 5 | 石 40 + 金 2 | ✅ 生效（撤离入库格数）|
| extraction_speed 撤离速度 | survival | 1.0 | +0.05 | 5 | 木 20 + 金 1 | ⚠ **未接线（买了无效）** |
| resource_find_chance 资源发现率 | acquisition | 0.5 | +0.03 | 5 | 石 25 + 金 1 | ⚠ **未接线** |
| rare_resource_chance 稀有资源率 | acquisition | 0.05 | +0.01 | 5 | 油 30 + 金 2 | ⚠ **未接线** |

### 4.7 相机 / 显示 / 音频
- 相机：`pan_speed 1600`、`return_key F(70)`；`zoom 0.35–3.0`（`step 0.12 / smooth 14 / at_cursor true / invert false / fit_bounds true / hud true`）；`edge_pan enabled margin 24 / speed×1.0 / ignore_ui true`。
- 显示：`windowed` / 1920×1080 / `vsync enabled` / `max_fps 0` / `stretch disabled · keep`。
- 音频：`master 1.0 / music 0.8 / sfx 0.9 / mute false`（见 §6）。

### 4.8 背包 / 仓库 / 数值归属厘清（易错）
- **背包（局内携带）**：容量 = `meta_progression.survival.backpack_capacity`（base 10 + 升级），规则**每种占 1 格、已有种类无限叠加**，**不吃 `storage.*`**。
- **仓库（Meta.bank，局外）**：格数 = `Meta.warehouse_slots()` = `warehouse_capacity`（base 20 + 升级）；单种叠加截断 = `storage.stack_limit=1000`。
- ⚠ **`storage.max_slots=20` 在代码零消费**（旧注释误称管仓库格，实际失效）；仓库格数以 `warehouse_capacity` 为准。

---

## 5. 机制系统

### 5.1 仇恨 / 敌人 AI 状态机（`enemy.gd` + `combat/states/enemy_*`）
- **仅 3 态**：`patrol` / `investigate` / `chase`。**无 idle/attack 状态**——「攻击」＝接触伤害瞬间置 `_attack_timer`（≈0.35s）驱动挥击帧，非 FSM 节点。
- 转换：`patrol→chase`＝`can_see_player()`；`patrol→investigate`＝`alertness ≥ investigate(30)`；`investigate→chase`＝看见玩家，或 `alertness ≥ combat(70)` 用追击速度「狂暴」；`investigate→patrol`＝`alertness < suspicious(15)` 放弃。⚠ suspicious/combat 不产生独立状态，只作 tint 与速度/放弃下限。config 实际阈值 15/30/70（代码硬编码回退 20/50/100 已被覆盖）。
- `can_see_player`：距离 `vision_cells(10) × tile(64) ≈ 640px`；墙遮挡沿线段按 `los_step 0.35` 采样墙格；玩家死亡看不见。
- 跟丢：`chase` 累计看不到 > `lose_sight_seconds(3.0)` → 把最后已知位置当声源，`alertness ≥ 30` 进 investigate 否则回 patrol（不透视实时追）。
- **休眠**：距玩家 > `ai_active_radius(32)` 格 → `_dormant`，不跑 FSM/动画/tint（但警觉衰减在休眠判定前，远处仍会掉警戒）。
- 追击速度 = `speed(360) × speed_mult(兵种) × chase_mult(1.35)`；最快 raider≈559 < 玩家 640，可风筝。接触伤害按兵种 `damage`，成功则 `contact_cooldown 1.0`。

### 5.2 噪音机制（`noise_system.gd` + `combat/fx_ring.gd`）
- `emit(pos, intensity)`：① `intensity ≥ ring_min_intensity(35)` 才画环；② 遍历 `enemies` 组，`d > hear_radius(16×tile)` 跳过；③ 距离线性衰减 `att = 1 − d/hear_radius`；④ 隔墙 `att ×= wall_attenuation(0.5)`（独立 LOS 采样）；⑤ `received = intensity × att`，`≥ min_notice(4)` 才 `e.hear_noise()`。
- `hear_noise`：`noise_alertness += received`（上限 `max_alertness 150`），记声源位驱动 §5.1 FSM。`decay_per_second(10)` 由**每敌人** `_physics_process` 每帧扣。
- 源触发点：`walk 22`＝`player_move_state`（每 `footstep_interval 0.4` 一次）；`dodge 40`＝`player_dodge_state`；`attack 120`＝近战出招（先取武器 `noise`：剑120/弓70/狙240，无武器回落）；`shout 160`＝**敌人进入 chase 时广播**（惊动附近，非玩家）；`sniper_shot 240`＝**死配置**（狙击走武器 noise 240）。
- ring 半径 = `hear_radius × (1 − min_notice/intensity)`，扩散+淡出描边圆。

### 5.3 撤离机制（`extraction_system.gd` / `extraction_point.gd`）
- 30min 随机刷 3 点（限可达格 + `min_dist` 约束）；洗牌预定关闭顺序；45/55 各关 1；最后 1 点保持到超时。轮到点若有人站圈内则改关下一个（全有人本轮作废）。
- 站 `trigger_radius 96` 圈 → `hold_progress += delta`，达 `hold 3s` 触发 `RunManager.extract()`；离开或点关闭清零。elapsed 按 `time_limit − remaining` 计，故 `time_scale` 同步加速整条时间线。

### 5.4 掉落机制
- 敌人死亡（`enemy.gd _spawn_drop`）：`randf > chance(0.75)` 则不掉；按 `drop.weights` 加权选种类，`randi_range(2,6)` 数量，生成**地面 LootNode**（视觉 ×0.8 区别地图资源点），走近 `pickup_radius 80` 才自动进背包。
- 羊死亡：`chance 0.9` 掉 food 1–3（地面 LootNode）。
- 资源点：按 `loot.density(0.05)` 撒于可达地板，每点 `amount_per_node 10`；新种类且背包满则拾取失败并 `pickup_retry 0.5` 后重试。

### 5.5 怪物特性
- **全部近战接触伤害**，4 兵种强度递进（§4.3）；无远程、无技能系统（已删）。
- 受击＝瞬时泛红（`hit_flash 0.18`，tint lerp 红）；死亡＝tween 并行「淡出 + 缩 ×0.7 + 下沉」（`death_fade 0.45`），**无专用帧**。
- **平衡缺口（真实）**：玩家远程（弓弹道 640px、狙 hitscan 900px 穿透 2）可风筝；但敌人视野 ≈640px ≈ 弓射程，贴边对射窗口窄。全员近战 ⇒ 远程无威胁。若走全员远程需补**远程敌人 / 掩体 / 弹速压制**。

### 5.6 视野 / 迷雾（2D `fog_system.gd`）
- 用 `TileMapLayer` 盖全图不透明黑瓦，已探索格永久移除（记忆只增不减）；每帧按 `player.vision_radius_cells(10)` 揭圆。
- 显隐用世界坐标 `distance_to(player) ≤ vision_px`，**相机缩放不影响逻辑视野**。`VISION_GROUPS = enemies / animals / loot_nodes` 仅视野内可见（`_ready` 初始 `visible=false`）。
- 3D 版 `fog_3d.gd` 是等距地面 + shader 软边遮罩，与 2D 逻辑独立（不接入线）。

### 5.7 生存（`survival_system.gd`）
- 每 `meal_interval 60s`（走局内时间轴 × time_scale）自动耗 1 食物；无食物 → `starving`，每 `30s` `apply_direct_damage(5)`（**不走硬直/击退/无敌帧**，归零即死）。
- 按 `H` 主动进食：非满血且背包有食物才扣 1 食物 `heal(25)`，进 `eat_cooldown 1.0`；满血/无食物/冷却中失败。

### 5.8 战斗判定（`player.gd` + `combat/`）
- **melee**（`player_attack_state` + `resolve_attack_hit`）：WINDUP→ACTIVE→RECOVERY；ACTIVE 每帧取 Hitbox `get_overlapping_areas()`，`arc 200°`(半角 100° 过滤)、`max_targets 3` 去重、`range 120`=Hitbox 半径；伤害经 `DamagePipeline.compute`（当前无暴击/减伤/浮动≈原值）。
- **ranged**（`fire_projectile` + `combat/projectile.gd`）：ACTIVE 进入瞬间发一次；命中＝点到本帧飞行线段最近距 ≤ `hit_radius 16`（防穿透与步长无关），撞墙按 ≤ 半格采样，命中优先于撞墙。
- **hitscan**（`fire_hitscan`，出枪同帧）：射线枪口→+facing×`900`；`first_wall_point` 半格采样截断到首墙；沿线取前 `pierce 2` 个；每个 `DamagePipeline`；Line2D 曳光 + 命中点 fx_ring。
- `combat.attack` 与 `combat.weapons.*` 回退：先查当前武器字典，缺键回落 `combat.attack`；`kind` 缺省 melee。
- `input.buffer 0.25`：攻击/闪避预输入入队，idle/move 态 consume。

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

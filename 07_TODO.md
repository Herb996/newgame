# 07_TODO.md — 未完成清单（交接）

> 生成时间：2026-09-15
> 状态：**项目可运行、回归全绿**（`flow_test` 47/47、`probe_registry` 35/35）。
> 本文件只记录「还没做完 / 做歪了 / 需要你拍板」的事，已完成的不重复。

---

## 0. 先做这三件事（5 分钟）

### 0.1 临时调试开关（已完成 2/3）

| 文件 | 键 | 状态 |
|---|---|---|
| `Data/config.json` | `map.force_seed` | ✅ 已还原为 `0`（每局随机） |
| `Data/config.json` | `debug.map_preview` | ✅ 已还原为 `""` |
| `Data/config.json` | `debug.time_scale` | ❌ **仍是 `20.0`，需你改成 `1.0`** |

`time_scale = 20` 会把**局内倒计时与生存计时加速 20 倍**（60 分钟的局 3 分钟跑完），只影响倒计时、不影响移速。这个值**在我接手前就是这样**，不是本轮引入的 —— 但正式玩之前一定要调回 `1.0`。

### 0.2 废弃探针（已完成）

`Dev/` 现在是干净的回归探针组：

| 保留 | 用途 |
|---|---|
| `probe_registry.gd/.tscn` | 地图 + 注册表 + 矿脉 + 群系权重（35 项断言） |
| `probe_terrain_map.gd/.tscn` | 群系/装饰统计 + 两张俯视图 |
| `probe_player_anim.gd/.tscn` | 序列帧播放/朝向/缺帧回退 |
| `probe_zoom.gd/.tscn` · `probe_zoom_shot.gd/.tscn` | 滚轮缩放断言 / 开窗实拍 |
| `probe_map3d_full.gd/.tscn` | 5 群系时代 3D 全景出图（注：内部 `GROUND_TEX` 现为 4 群系） |
| `probe_render.gd/.tscn` · `probe_biome_weights.png` | 早期渲染/权重检查 |

已删：`probe_parse.*`、`probe_check_render.*`、`probe_map3d.*`、`probe_map3d_v2.*`、`probe_map3d_v1_old.png`（均已被取代）。
本轮地形证据图已放进 `Dev/`：`terrain_stats.png`（群系）、`terrain_decor.png`（装饰与带子）、`terrain_map2d.png`（2048² 全图俯视）。

### 0.3 推送

按你的习惯由你自己来（`SteamPunk_Update.bat`）。待推送改动：

- **新增**：`Scripts/base_render_3d.gd`、`Scripts/entity_visual_3d.gd`、`Scripts/fog_3d.gd`、`Scripts/view_hint.gd`、`tools/gen_ground_3d.py`、`tools/run_godot_headless.py`、`Assets/Art/Terrain3D/ground_snow.png(.import)`、`images/`
- **修改**：`Data/config.json`、`project.godot`、`Scenes/Main3D.tscn`、`Scripts/{main3d,map_generator,map_render_3d,player,hud,iso_camera_3d}.gd`、`Assets/Art/Tiles/{atlas_floor,atlas_wall}.png`
- **删除**：`Scenes/Main.tscn`、`Scripts/{main,camera_controller,fog_system}.gd`(+.uid) —— 2D 入口层

⚠️ **`images/` 约 150 MB**，推之前确认要不要进版本库（或加进 `.gitignore`）。

---

## 1. 🔴 阻塞 bug：人物会卡到树里面（根因已定位）

**现象**：玩家能走进树/石头的格子里，视觉上「卡在树里」。

**根因（已读代码确认，不是猜测）**——**物理层与寻路层不一致**：

| 层 | 树的处理 | 结果 |
|---|---|---|
| 逻辑（A\*） | `map_generator.gd:416` 树/石 → `walls[y][x] = true` | ✅ 寻路会绕开 |
| 物理（碰撞） | `_build_tileset()` 只给**墙瓦片**加碰撞多边形（`atlas_wall_start() .. atlas_cols()`），树/石是 `DecorLayer` 里的裸 `Sprite2D`，**没有任何碰撞体** | ❌ `move_and_slide()` 直接穿过去 |

玩家一旦走进树格，A\* 后续从「寻路认为不可走」的格出发，会停在边缘反复试探 → 表现为「卡住」。

**修法（三选一，推荐 A）**：

**A. 加一层纯物理的遮罩 Layer（改动最小、最贴合现有架构）**
在 `map_generator.gd` 里，除现有的 `TileMapLayer` 外再加一个 `TileMapLayer`（如 `BlockerLayer`），它的 `TileSet` 只含**一张透明但有整格碰撞**的瓦片；生成时对每个 `walls[y][x] == true` 且 `terrain[y][x] == false` 的格（即树/石格）`set_cell`。这样视觉不动、物理补齐。
> 注意别让它渲染出东西 —— 用全透明瓦片，或把该层 `visible = false`（物理不受 visible 影响）。

**B. 改 `_build_tileset()`**：给树/石也预留一组「透明碰撞瓦片」列，渲染走地板瓦片、碰撞走那一列 —— 但 `set_cell` 一格只能有一个图块，做不到「渲染/碰撞分开」，所以要配合 A。

**C. 在 `player.gd` 里手写格碰撞**：`move_and_slide()` 之前按 `_walls` 做一次圆-格检测并提前停下。快，但绕开了物理引擎，后续加击退/推挤/敌人碰撞时会互相打架。

**验收**：写个探针，把玩家 `set_move_target()` 指到某个树格旁边，确认最终 `global_position` 不在任何 `walls == true` 的格内。

---

## 2. 🟡 进行中：地形改造（草地 / 荒原 / 森林 / 雪原 + 河流 / 裂缝）

**需求原文**：地图地形有草地（大部分平地）、荒原（多石头/铁矿/金矿）、森林（树的密度很大）、雪原（基本是雪，雪会降低移速）；装饰物：石头/木头/裂缝/河水/铁矿/金矿/油田。

### 2.1 已做完（结构层面，可复用）

- **群系数据驱动 + 权重分段**：`map.biomes[i].weight` 决定面积占比。用**噪声分位数**而不是固定阈值定边界（`_biome_quantile_edges()`）——因为 simplex 噪声近似钟形分布，固定阈值会让「中间」的群系吃掉远超权重的面积。现在实测占比与权重**精确吻合**：
  ```
  权重 3.4 : 1.05 : 1.25 : 0.95  →  实际 51.2% : 15.7% : 18.7% : 14.4%
  ```
- **地形速度网格**：`result["speed_mult"]`（宽×高），`player.setup_navigation(walls, tile_size, speed_mult)` → `player.terrain_speed_at(cell)`。雪原 0.62、水格取 `min(群系速度, river.slow)`。**已接通**，`follow_path()` 里每帧按所在格乘速度。
- **通用地表特征带绘制器** `_paint_band(kind, prefix, ...)`：河水与裂缝共用。核心是**除以噪声梯度**（`d = |n| / |∇n|`）得到「到零等值线的近似格距」，于是**带子等宽**，不再出现早期那种 30×27 格的巨大水洼。
- **`_paint_band` 已前置到装饰放置之前** —— 必须先生成带，树才会自动避开；反过来的话一棵树落在河道正中就把河截断了。
- **装饰密度修正**：旧的 `if veg_noise <= 0.10: continue` 是一道**硬闸门**，会在 config 密度之上再乘掉约 0.2（实测森林 `tree: 0.330` 只落 9%）。已改成**均值≈1 的乘性调制** `veg_mul = clamp(1 + n*contrast, 0.05, 1.95)`，现在 config 里的值 = 目标密度。
- **裂缝/河水贴图**：`_make_crack()` 32×32 四向贯通（暗纹从四条边中点接入 → 带子拐弯时相邻格纹路接得上）；`_make_water()` 64×64 **整数周期正弦**保证无缝平铺。
- **3D 侧**：`map_render_3d._build_flat_decor()` 用 `MultiMesh` + `PlaneMesh` 铺贴地特征；地面纹理/亮度改数据驱动（`config.map.biomes[i].ground_3d` / `ground_tune`）。
- **素材**：`ground_snow.png` 已生成并导入；图集已按 N=4 重跑（地板 768 = 4×12、墙 384 = 4×6）。
- **顺手修掉一个会直接炸的 bug**：`_build_flat_decor` 里 `Basis(RIGHT, -90°)` 会把水平贴片**立成一面墙**。已用探针确认 `PlaneMesh` 默认 `orientation = FACE_Y`、AABB `(1, 0, 1)` 本来就水平，那句旋转已删。

### 2.2 ❌ 没做完：**带子太宽 / 频率太高，水淹了整张图**

实测（`probe_terrain_map`，种子 20260915）：
```
群系分布：草地 8393, 荒原 2576, 森林 3061, 雪原 2354      ← 这部分是对的
装饰物：  树 182 / 石头 101 / 残骸 84 / 裂缝 3471 / 河水 5434
地板 12533 格，其中 河水 = 43%、裂缝 = 28%                 ← 明显过头
```

看 `terrain_decor.png`（青色=水、黑=裂缝）就是一张**青色马赛克**，不是「一条河」。

**两个独立问题**：

1. **河水太宽**。`crack/river.width_cells` 的单位是**格**，当前 `river.width_cells = 1.3` + 两个交叉朝向 → 两条 2.6 格宽的带子横竖铺满 → 覆盖 1/3。
   → **建议调到 `0.30 ~ 0.45`**，并且只留 1~2 条朝向（河道应该稀、长、蜿蜒）。

2. **裂缝频率过高导致退化成麻点**。`crack.frequency = 0.075` 意味着带子走两三格就拐一次；而 `width_cells = 0.75` **小于 1 格**——带宽比格子还细时，格子只能被「偶尔命中」，所以画出来是一片散点而不是一条缝。
   → **带宽至少 ~0.9（连续带的最小值就是 1 格），频率降到 `0.018 ~ 0.03`** 让每条缝跑得长。想要视觉上细，靠**贴图透明度的暗纹细**，不要靠把带宽压到 1 格以下。

3. **连带后果**：带子占了 ~33% 的格，装饰循环跳过这些格 → 树/石被饿死（实测树 182，按密度应有 ~860）。
   **修好带宽后树会自己回来**，但那时要重新确认森林密度是否过密。

**调参入口**（都在 `Data/config.json`，改完不用动代码）：
```jsonc
"map": {
  "river": { "enabled": true, "frequency": 0.045, "width_cells": 1.3, "jitter": 0.010,
             "slow": 0.72, "min_dist_from_spawn_cells": 8,
             "orientation": [[0.40,-0.22,0.0,1.0], [1.0,0.0,0.22,0.40]],
             "biome_scale": [1.0, 0.70, 1.25, 0.0] },     // 每群系的带宽倍率，雪原 0 = 无水
  "crack": { "enabled": true, "frequency": 0.075, "width_cells": 0.75, "jitter": 0.006,
             "min_dist_from_spawn_cells": 3,
             "orientation": [[0.55,-0.18,0.18,1.0], [1.0,0.18,-0.18,0.55]],
             "biome_scale": [0.9, 1.6, 0.55, 1.0] }        // 荒原 1.6 = 裂缝最多
}
```
- `orientation` 每项是采样域的 **2×2 线性变换 `[a,b,c,d]`**（`u = a·x + b·y`，`v = c·x + d·y`）。给 2 个数按对角阵理解（纯拉伸）。对噪声做各向异性变换，等值线才会被拉长成**河/缝**；不变换就会闭合成**水塘**。
- 建议把两条朝向改成**明显不同角度**（现在两组接近横竖正交，容易出网格感）。

**怎么看效果**（不要只看数字，要看图）：
```bash
# 1) 出统计 + 两张 512×512 俯视图
"<Godot>" --headless --path D:/SteamPunkExtraction Dev/probe_terrain_map.tscn
#    → terrain_stats.png（群系）/ terrain_decor.png（装饰与带子）
# 2) 出 2048×2048 全图俯视（走 MapGenerator.build_preview 通道）
#    设 debug.map_preview 为输出路径、debug.map_preview_cells = 128，然后跑主场景
```
> 调试期请固定 `map.force_seed`，否则每局换图没法对比。

### 2.3 待确认
- **「木头」还算不算一种装饰？** 需求写「装饰物：石头/木头/裂缝/河水/铁矿/金矿/油田」，但「木头」目前**没有独立装饰类型** —— 木头只作为 `loot_node` 的**资源点颜色占位**存在（`resources.wood.color`）。如果要在森林里加倒木/树桩，需要新增 `DECOR_LOG`（照 `DECOR_ROCK` 复制一份，程序化出图 + 阻塞通行）。
- **雪原的「减速」数值**：现定 `0.62`。要不要更低（更像深雪）？
- **荒原的矿脉**：`veins` 已限定 `biomes: [1]`（荒原）出 iron/gold/oil。但**河水把荒原淹掉了 16%**，矿脉点位会被带子挤掉一批 —— 修好带宽后需复查矿脉数量。

---

## 3. 🟡 素材：你新放进来的敌人原画（`images/`）

**40 张 / 10 组 / 约 150 MB**，单张 ≈ 3136×1344，**单角色单姿势**（不是序列帧），带大片背景色差 + 右下角「即梦 AI」水印。

| 文件夹 | 内容（看缩略图判断） |
|---|---|
| `贵族1` | 蒸汽朋克贵族：礼帽 + 黄铜面具 + 机械手臂 + 喷气手杖 |
| `丧失1` | 骷髅机械僵尸：蜡烛头 + 锈甲 + 蒸汽管 |
| `丧失2` | 骨头玩偶：白裙骨架、爪手 |
| `机械1` | 铜甲士兵：步枪 + 黄铜护目镜 |
| `机械2` | 青铜/翡翠机械龙（双翼、胸口红核） |
| `机械3` | 翡翠机械龙（红核、更偏龙兽） |
| `机械4` | 重型机械蛮牛：巨锤 + 红核 |
| `南巨` | 机械霸王龙（BOSS 向） |
| `青眼白龙1` | 白龙坐姿（幻想向） |
| `青眼白龙2` | 白龙头部特写 |

**用它要做的三步**（每步都有现成脚本可照抄）：
1. **抠背景 + 去水印** → `Assets/Art/Sprites/Enemy/`（技能 `ai-game-art-pipeline` 第七节有抠图流程；水印在右下角固定位置，可先裁掉再抠）
2. **派生 4 向 idle + walk 序列帧** → 照 `tools/gen_player_frames.py` 的做法（分层抠腿 → 2px 整数倍位移）。⚠️ 这 40 张都是**正面/侧面单一姿势**，不是 4 向，所以「4 向」需要**你补画或用 AI 补**背面/侧面，或者退一步：**敌人只用 1 向（billboard 不随朝向变）**
3. **接进 3D** → 照 `Scripts/player_visual_3d.gd` 复制一份 `enemy_visual_3d.gd`（`AnimatedSprite3D` + billboard + 脚底锚点 + 地面软投影），替换 `entity_visual_3d.gd` 里的棱柱占位

**建议先只做 1~2 个**（比如 `机械1` 铜甲士兵 + `贵族1` 当精英），把管线跑通再批量。

---

## 4. 剩余功能清单

### A 类 · 逻辑在跑、3D 里看不见（补视觉即可，性价比最高）

| 项 | 现状 | 要做的事 |
|---|---|---|
| **噪音环 / 技能 AOE 环** | `combat/fx_ring.gd` 是 **2D `Node2D._draw()`**（`z_index=50`）；`noise_system._spawn_ring()` 找 `GameRoot` 节点，**Main3D 里没有这个节点**（那是 2D 版 main.gd 的结构），于是 fallback 挂到 Main3D 根下用**像素坐标**画 → 3D 画面里位置完全错位 | 改成 3D 表现：圆环用 `TorusMesh`/`PlaneMesh` + 自发光材质，位置用世界坐标。**敌人听觉逻辑本身是正常的**，只是玩家看不到「我弄出动静了」的反馈 |
| **采集交互** | `ResourceRegistry.harvest()` **全项目零调用点**（只有 `resource_registry.gd` 里的定义）。树 182 / 石 101 / 矿脉 34 都登记进了注册表，**但没有任何采集入口** | 3D 射线命中树/矿脉 → 查 registry → `harvest()` → 隐藏精灵。**别混淆**：资源点（`loot_node`）是另一条链路，Area2D 自动拾取（走进半径就捡），**这条已通** |
| **玩家 attack/dodge/hit/dead 无帧** | 走程序化形变（挥击前冲 / 拉伸 / 抖动 / 倾倒） | 补 4 个状态的序列帧（照 `gen_player_frames.py` 扩展） |

### B 类 · 完全没做

- **POI / 巢穴 / 水域**：无任何脚本、无配置段
- **敌人 / 资源点 / 撤离点 / 建筑的真模型**：现为 `entity_visual_3d.gd` 的 Prism（棱柱）/ 发光球 / 圆环 / BoxMesh 占位
- **音效**：`Assets/Audio/` 是**空目录**，全程无声
- **基地地板/墙体的正式美术**：现用 `wall_plate.png` 临时顶
- **小地图资源标记**：现在只画撤离点

### C 类 · 素材阻塞（没料，做不了）

- `Assets/Art/Sprites/{Enemy,Loot,Building}`、`Art/UI` 全空
- `Assets/Art/Models/` 只有 `debris / rock / tree` 三个 GLB（无角色以外任何实体模型）
- `Assets/Art/Source3D/player_character.glb` 是**纯静态网格**（`skins: 0`、`animations: []`），做不了骨骼动画 —— 这也是角色走 HD-2D 序列帧的原因

### 已闭环（别重复做）
局外成长 `Meta`（雕像买升级 / 仓库看库存 / `RunManager` 注入局内属性 / 撤离入库 / `user://save.json` 存档）、小地图、战争迷雾、撤离流程、HUD（血量·体力·技能·生存·背包）、BASE↔RUN 双模式状态机、滚轮缩放（平滑 + 光标锚点 + 对称步进 + 地图自适应限位）。

---

## 5. 环境备忘（下次开工直接用）

### 命令
```bash
GODOT="C:/Users/Administrator/Downloads/Godot_v4.7.2-stable_win64_console.exe"

# 纯逻辑验证（快，无渲染）
"$GODOT" --headless --path D:/SteamPunkExtraction Dev/probe_registry.tscn
"$GODOT" --headless --path D:/SteamPunkExtraction Dev/probe_terrain_map.tscn

# 新增素材后必须让 Godot 导入，否则 ResourceLoader.exists() 为 false
"$GODOT" --headless --path D:/SteamPunkExtraction --import

# 要出图 / 截图：必须去掉 --headless（headless 是 dummy 渲染驱动，frame_post_draw 永不触发）
"$GODOT" --path D:/SteamPunkExtraction --resolution 1600x900 Scenes/Main3D.tscn

# 非侵入截帧（不改游戏代码）
"$GODOT" --path D:/SteamPunkExtraction --write-movie <out>/f.png --fixed-fps 6 --quit-after 48 <scene>
```

### 调试开关（`Data/config.json` 的 `debug` 段）
| 键 | 作用 |
|---|---|
| `main3d_start` | `"base"`(默认) / `"run"` —— 跳过基地直接进局内 |
| `flow_test` | 端到端主流程自检（47 项断言，真按键注入 E、真跑 BASE→RUN→BASE→RUN） |
| `smoke_test` / `auto_enter_run` | 旧开关，仍可用 |
| `main3d_capture` / `_delay` / `_frames` | 自动截图；`_frames > 1` 时连拍成序列帧 |
| `map_preview` / `map_preview_cells` | 出全图俯视预览 PNG |

### 会反复踩的坑（血泪）
1. **`--headless` 出不了图** —— dummy 驱动，`frame_post_draw` 不触发。截图必须开窗口。
2. **渲染后端是 `gl_compatibility`** → **SSAO 不可用**（Forward+ 专有）；雾 / glow / ACES 可用。
3. **JSON 数字一律解析成 `float`**。`[3.0].has(3)` 返回 **false**。凡「config 数组 include / 相等比较」两侧都要先 `int()`。
4. **`Vector3i` / `Vector3` 第二个槽是 y**，格坐标必须写 `Vector3i(x, 0, z)`（塞错会把所有实例压到一条边）。
5. **`ArrayMesh` / `Texture2DArray` 是 RefCounted，不能 `free()`**，交 GC。
6. **GDScript 不支持 `\` 行续接符，也不支持列表推导式**；缩进必须严格用 tab。
7. **同一作用域不能重复 `var` 同名变量** —— 我在 `_paint_band` 里把矩阵分量和「距离」都叫 `d`，直接解析失败，而且 Godot 只报 "parser error" **不给行号**。排查办法：建一个 `probe_parse.gd` 只写 `const MG = preload("res://Scripts/xxx.gd")`，能把真实错误逼出来。
8. **Label 定位**：只改 `offset_bottom` 不会把**顶对齐**的 Label 往上移，只会把矩形压扁、文字仍停在 preset 的 `offset_top` 上（多个标签会叠字）。要按「距底边 N px」定位必须同时给 `offset_top` 并设 `vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM`。
9. **右锚点 Label 必须给足矩形宽度**，否则文字被往锚点外侧撑、推出屏幕。
10. **断言 UI 真的画出来了要用 `is_visible_in_tree()`，不能只看 `visible`** —— 祖先（CanvasLayer / 父 Control）被隐藏时，控件自身 `visible` 仍是 `true`。
11. **`SPRITE_SCALE = 0.5`**：48×48 是 2 倍超采样画布，游戏里只显示 24×24。**序列帧位移必须取 2px 的整数倍**，1px 在屏幕上只有 0.5px（亚像素，看不见）。
12. **`--write-movie` 按项目视口尺寸录制**（传 `--resolution` 不生效）。
13. **`PlaneMesh` 默认 `orientation = FACE_Y`**（水平），别再转 X 轴 90° 会立成墙。
14. **⚠️ 编辑期间不要让 Godot 编辑器开着** —— 出过一次事故：编辑器持有旧缓冲，退出时把 `map_generator.gd` / `player.gd` / `Player.tscn` 写回成远古版本（少了 1700+ 行），游戏直接跑不起来。恢复用 `git checkout HEAD -- <文件>`。**开工前先 `git status` + 看关键文件 mtime**。

### 工作方式约定
- **推送由用户自己操作**（`SteamPunk_Update.bat`），不要代为 push。
- **不要在一个消息里对同一文件并行发多个 Edit** —— 会基于旧快照互相覆盖。改多处用「一次性精确文本替换」。
- 本机 bash 的 coreutils（`ls`/`head`/`grep`/`wc`）**时好时坏**，`cmd.exe` 被安全策略拦截。文件操作用 Python（`os`/`shutil`），别用 `rm`/`cp`。
- `map_generator.gd` 是 **CRLF**，`config.json` / `map_render_3d.gd` 是 **LF** —— 用 Python 原地改时注意 `newline=` 参数，否则整个文件的换行会被改写（diff 炸锅）。

---

## 6. 架构主线（拍过板的，别推翻）

- **唯一入口 = `Scenes/Main3D.tscn`**（`project.godot` 主场景）。BASE↔RUN 双模式：F5 → 3D 基地（无雾）→ 大门按 E → 3D 局内（有雾）→ 局结束按 R 回基地。
- **3D 双轨制：逻辑留 2D、渲染换 3D**。逻辑跑在 `LogicRoot`(Node2D, `visible=false`)，渲染在 `World3D`。坐标桥接：**3D 世界单位 = 2D 像素 ÷ `map.tile_size`**；3D `(x, z)` ↔ 2D `(x, y)`。
- **群系数据驱动**：加雪原等新地形只改 `config.json` 的 `map.biomes`，GDScript 零改动。图集列数随 N 自动缩放（地板 N×12 / 墙 N×6 / 墙顶 N×6）。
- **地面着色**：`Texture2DArray` + 主导/次主导 id/权重数据贴图（R=id0, G=w0, B=id1, A=w1），不受 4 通道限制，支持任意 N 群系。
- **角色走 HD-2D 序列帧**（2D `Sprite2D` 与 3D `AnimatedSprite3D` **共用**一份 `config sprites` 与 `player.gd.current_anim()`）。状态判定只写一份，否则两套必然漂移。
- **`Scripts/select_icon.gd` 不能删** —— `Player.tscn` 的 `$SelectIcon` 引用它。

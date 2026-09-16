# 缺失素材清单与 AI 生成提示词

> 2026-09-16 整理。美术基线 = **Tiny Swords (Free Pack)**（Pixel Frog，CC0）。
> 免费包能覆盖"地形 / 树石灌木 / 中立羊 / 4 个阵营兵种 / 道具图标 / 建筑"，
> 覆盖不到的部分在下面逐条列出，附可直接投喂出图工具的英文提示词。
>
> 每条的 **「现状」** 说明当前是怎么顶着的 —— 顶得住的先用着，不急着补；
> 标 **P0** 的是"能明显看出是占位/会误导玩家"的，建议优先补。

---

## 零、本轮（2026-09-16）修掉的两个"看着像缺素材、其实是代码 bug"的坑

这两条都表现为"画面脏"，很容易误判成美术不够用，所以记在这里防止改回去。

### 0.1 进游戏地面变成"深底 + 每格一小块色斑"

**根因**：`TileSetAtlasSource.texture_region_size` 的默认值是 **16×16**，
它**不会**跟着 `TileSet.tile_size` 走。官方素材是 64px 格，没显式设置时图集按
16px 去切 64px 的瓦片，`set_cell` 取到的是"某瓦片左上角 16px 的一小块"再被拉成整格。

**为什么特别难查**：`MapGenerator.build_preview()` 走的是 `blit_rect` 直拼、
按 64px 正确切片，所以**预览图完全正常**，只有进游戏才坏 —— 于是很容易得出
"预览好看、游戏全黑，一定是雾/光照的问题"这种错误结论。

**修法**：`map_generator.gd::_build_tileset()` 里
`src.texture_region_size = Vector2i(tile_size, tile_size)`。

### 0.2 水面出现规则条纹（周期 32px）

见下面 P0.5 第 7 条的说明：`_shallow_water` 的逐像素正弦波纹。

### 定位这类问题的工具（本轮新增）

`map_generator` 的图集是**运行时拼**的，磁盘上没有对应文件；群系分布也只存在于
日志文字里。所以本轮补了三个命令行开关（都走 `--` 用户参数，**不改 `config.json`**）：

```bash
# 把运行时图集导成 PNG：判断"颜色不对"是源图 / tint / 切格哪一环
python tools/dump_diag.py --atlas --zoom 2

# 把群系 id 导成色块图 + 打印图例：一眼看出某块地是水还是沼泽
python tools/dump_diag.py --biome --zoom 2

# 关掉整图叠加的宏观明暗层（MacroLight）：二分"叠加层 vs 地形本身"
python tools/shot2d.py _x.png --no-fog --no-macro
```

`tools/shot2d.py` 另有 `--no-fog`（迷雾层 z_index=5 会盖住地形，截图时地面看着
一片黑，但那是雾不是地形）。

---

## 一、已就位（不需要再出图）

| 类别 | 文件 | 规格 |
|---|---|---|
| 地形图集 | `Assets/Art/Tiles/TS/tilemap_color1..5.png` | 576×384，64px 格，4×4 blob autotile |
| 水面（底色） | `Assets/Art/Tiles/TS/water_bg.png` | 64×64 可平铺，**实测是单色纯平**（只有 1 种像素 71,171,169,255，行/列均值波动都是 0） |
| 水面（浪花） | `Assets/Art/Tiles/TS/water_foam.png` | 3072×192 = 48×3 格（64px）；有效帧在奇数格，row1 厚浪花 / row2 细浪线，共 24 帧动画。**尚未接线**，见 P0.5 第 7 条 |
| 装饰 | `tree_00..15`(192×256)、`rock_00..03`(64×64)、`stump_00..03`、`bush_00..15`(128×128)、`pebble_00..15`(64×64) | 见 `tools/build_ts_assets.py` |
| 道具图标 | `item_wood/stone/iron/scrap/gold/food/arrow.png` | 64×64（gold 128×128） |
| 单位 | `blue_warrior`(idle8/run6/attack1 4/attack2 4/guard6)、`red_pawn`、`red_archer`、`red_monk`、`yellow_pawn` | 192×192 |
| 中立生物 | `sheep`（idle6/run4/grass12） | 128×128 |
| 建筑 | `house_small/large`、`tower`、`castle`、`monastery`、`barracks`、`archery`、`enemy_barracks`、`shadow` | 128~320 px |

单位脚底基准（已实测，改锚点请照这个来）：

| 单位 | 画布 | 脚底 y | `offset_y` |
|---|---|---|---|
| blue_warrior | 192×192 | 137 | −41 |
| red_archer | 192×192 | 136 | −40 |
| red_monk | 192×192 | 134 | −38 |
| red_pawn / yellow_pawn | 192×192 | 135 | −39 |
| sheep | 128×128 | 84 | −20 |

复核命令：`python tools/probe_unit_feet.py`

---

## 二、P0 —— 现在明显是占位

### 1. 铁矿脉露头

**现状**：官方免费包只给了金矿（`Gold Stone 1..6`）。铁矿是把金矿**去色染灰蓝**派生的
（`tools/build_ts_assets.py::tint_metal`），形状和金矿一模一样，玩家会认错。

**需要**：3 张 128×128，形状与金矿明显不同的铁矿石堆（更碎、棱角更硬、暗铁灰带锈）。

```
Top-down 2D game asset, iron ore outcrop, 3 variations in a row,
128x128 each frame, crisp pixel art, 4-bit style matching Tiny Swords free pack,
dark grey hematite rocks with rust-orange patches, angular broken facets,
small pebbles scattered at the base, transparent background, no outline blur,
consistent top-left light source, game-ready sprite sheet
```

### 2. 油田 / 沥青渗漏点

**现状**：官方无此素材，当前是脚本用椭圆渐变糊出来的黑紫色圆斑（`make_oil_pool()`），
近看就是一块模糊的紫黑，跟"手绘像素"完全不是一种质感。

**需要**：1～3 张 128×128，油潭 + 金属井口/泵机的蒸汽朋克油井。

```
Top-down 2D game asset, steampunk oil seep, 128x128,
crisp pixel art matching Tiny Swords free pack style,
dark glossy petroleum pool with purple-green iridescent sheen,
a small rusted brass pump head and a bent pipe sticking out of the oil,
transparent background, game-ready sprite, top-left light source
```

### 3. 油桶道具

**现状**：`item_oil.png` 是程序化画的（深色桶 + 反光），放在一堆手绘道具里很突兀。

**需要**：1 张 64×64，与 `item_wood/stone/iron` 同一套画风的油桶。

```
Top-down 2D game item icon, steampunk oil barrel, 64x64,
crisp pixel art matching Tiny Swords free pack item icons,
brass-banded dark metal barrel with a drip of black oil, slight isometric hint,
transparent background, centered, game-ready
```
（出图后替换 `Assets/Art/Sprites/Items/item_oil.png`，config 不用改。）

### 4. 死亡动画（玩家 + 4 种敌人 + 羊）

**现状**：官方免费包**只有 idle / run / attack / guard**，没有任何倒地帧。
当前死亡靠"缩小 + 淡出 + 下沉"的 tween 顶着（`enemy.gd::_fade_out`）——
能读成"倒下了"，但反复看会觉得所有单位死法一模一样。

**需要**：每条一套 6～8 帧的倒地序列。画布必须与本体一致
（兵种 192×192、羊 128×128），**脚底 y 与上表严格一致**，否则倒地时会上下跳。

```
Sprite sheet, top-down 2D game character death animation, 8 frames in a horizontal row,
192x192 per frame, {CHARACTER}, pixel art in the exact style of Tiny Swords free pack,
{CHARACTER} collapses forward onto the ground, helmet drops, final frame lying flat,
feet stay at the same y position across all frames, transparent background,
consistent top-left light source, no motion blur
```

把 `{CHARACTER}` 依次换成：
`a blue-armored medieval soldier with sword and round shield` /
`a small red-hooded peasant with a knife` /
`a red-hooded archer with a bow` /
`a red-robed monk with healing staff` /
`a yellow-hooded peasant with a knife` /
`a white fluffy sheep`

落地后：放进 `Assets/Art/Sprites/Units/<unit>/dead_00..07.png`，
再把 config 里的 `dead` 数组填上路径即可（`enemy_types.types[*]` / `sprites_ts`）。

### 5. 受击 / 硬直动画

**现状**：官方没有受击帧，当前用"瞬间泛红 0.18 秒"顶（`enemy.hit_flash_seconds`）。
100 个敌人同屏时反馈偏弱，打了不知道有没有打中。

**需要**：每条 3～4 帧的后仰/踉跄。

```
Sprite sheet, top-down 2D game character hit reaction, 4 frames in a horizontal row,
192x192 per frame, {CHARACTER}, pixel art in the exact style of Tiny Swords free pack,
character flinches backward and recoils from an impact, one frame slightly staggered,
feet stay at the same y position across all frames, transparent background,
consistent top-left light source
```

### 6. 四向行走帧

**现状**：官方单位是**正面单朝向**，四个方向共用同一组帧
（`Data/config.json` 的 `sprites_ts` 就是这么写的，见 `player_animator.gd::parse_spec`
的"写法 B：扁平数组 = 四向共用"）。后果是角色往上走和往下走长得一样。

**需要**：至少给 4 向各一套 idle + walk（左/右可以靠水平翻转省一半）。

```
Sprite sheet, top-down 2D game character walk cycle facing {DIRECTION}, 6 frames,
192x192 per frame, {CHARACTER}, pixel art in the exact style of Tiny Swords free pack,
feet stay at the same y position, transparent background, top-left light source
```

`{DIRECTION}` ∈ `up` / `down` / `left` / `right`。
出图后 config 改用"写法 A：按方向分组"的嵌套字典即可，代码不用动。

---

## 三、P1 —— 画面缺一口气，但能玩

### 7. 浅滩 / 河岸过渡瓦片（**P0.5，强烈建议**）

**现状**：`DECOR_WATER`（可涉水的河水）是拿 `water_bg.png` **整体提亮**派生的
（`map_generator.gd::_shallow_water`）。于是"能走的水"和"不能走的水"只差一个亮度，
而且两者都是**纯色无纹理**。

> **2026-09-16 已修**：`_shallow_water` 原实现在每格 64px 内叠了
> `sin(x / width * TAU * 2.0)`（**两整周期**正弦亮带）想冒充波纹。因为每格图案
> 完全相同，全图水面的条纹跨格严丝合缝，连成一整片"印刷网纹"（实测周期 32px、
> 亮度在 86↔117 间摆动），看着像贴图坏了。现已改为**整片恒定提亮**（k=0.30），
> 河面连成一整片、无格子缝。**不要再改回逐像素波纹** —— 波纹该由动画水面瓦片做。

**已有但未接的素材**：`Assets/Art/Tiles/TS/water_foam.png`（3072×192）。
实测布局 = **48 列 × 3 行**，每格 64×64：

| 行 | 内容 |
|---|---|
| row0 | 基本全空（非透明 ≤5%），是分隔留白 |
| row1 | **厚浪花**：奇数格 83~98% 非透明，偶数格为空 |
| row2 | **细浪线**：奇数格 7~23% 非透明，偶数格为空 |

也就是说它是**24 帧的逐帧动画**（奇数格才是有效帧，偶数格是间隔），
**不是** 16 组邻接 blob——它能给"贴着陆地的那圈水格"叠一层会动的浪，视觉上
把硬直角岸线糊开，但**替代不了一套真正的浅滩 blob 瓦片**。

**落地方式**（两选一）：
- 便宜方案：在 `map_generator` 里找出「四邻中有陆地的水格」，每格叠一个
  `AnimatedSprite2D`（`SpriteFrames` 从 `water_foam.png` 的 row1 / row2 奇数格切
  24 帧），`z_index` 压在地形之上、装饰之下。
- 彻底方案：出一套真 blob 浅滩瓦片（下面的提示词），照 `biome_tileset` 那套接。

**需要**：一套 64×64 的浅滩瓦片（blob 16 组合），带岸边过渡。

```
Tilemap for a 2D top-down game, shallow river water tileset, 64x64 tiles,
4x4 blob autotile layout covering 16 neighbor combinations,
crisp pixel art matching Tiny Swords free pack water,
translucent turquoise shallow water with visible sandy riverbed and light caustics,
clear soft shoreline transition to grass on every edge, transparent corners,
seamlessly tileable in the interior
```

### 8. 不可通行深水的岸线瓦片

**现状**：不可通行地形 = 官方 `water_bg.png`，一张 **64×64 纯色**，没有任何边缘过渡。
所以地图上一片水是"啪"地切在陆地旁边的硬直角。全图预览能看得很清楚。

**需要**：深水 blob 集（16 组合），外缘带暗色水线。

```
Tilemap for a 2D top-down game, deep impassable ocean water tileset, 64x64 tiles,
4x4 blob autotile layout covering 16 neighbor combinations,
crisp pixel art matching Tiny Swords free pack water,
deep teal water, darker abyssal center, thin dark foam line along the shore edge,
seamlessly tileable in the interior, transparent outside the tile
```

### 9. 桥 / 渡口 / 浅滩通路装饰

**现状**：河水是按噪声画出的蜿蜒带（`map.river`），经常横穿整张图。
玩家能涉水过（`map.river.slow = 0.72`），但没有"过河点"这种视觉引导。

**需要**：木桥 / 石桥 / 浅滩踏脚石，各 1 张。

```
Top-down 2D game asset, wooden plank bridge over a river, 192x64,
crisp pixel art matching Tiny Swords free pack, mossy planks with brass nail heads,
transparent background, game-ready sprite
```

### 10. 蒸汽朋克场景道具（最缺的一类）

**现状**：地图装饰只有树 / 石 / 灌木 / 碎石 —— 全是**自然物**。
但游戏世界观是**蒸汽朋克提取射击**（`00_GAME_DESIGN.md`），
现在野外看不出任何"工业废墟"的味道，这是最大的风格缺口。

**需要**（每样 1～3 个变体，64×64 或 128×128）：破损管道、阀门、齿轮堆、
锅炉残骸、木箱、铁桶、矿车、铁轨段、铆钉钢板、灯柱、铁丝网、栅栏、
废墟地基、煤堆、扳手零件。

```
Top-down 2D game prop, steampunk industrial ruins set, {N} separate props in one sheet,
each prop 64x64, crisp pixel art matching Tiny Swords free pack style,
brass and rusted iron, {PROP_LIST}, transparent background,
consistent top-left light source, game-ready, no text
```

`{PROP_LIST}` 一次出一批，例如：
`a leaking pipe elbow, a brass valve wheel, a pile of rusty gears, a broken boiler,
a wooden crate with metal corners, a riveted steel plate, a bent rail segment,
a broken mine cart, a gas lamp post`

### 11. 蒸汽朋克建筑

**现状**：基地三栋建筑直接借用了中世纪素材 ——
仓库 = `house_large.png`（茅草屋顶农舍）、升级雕像 = `monastery.png`（修道院）、
出发大门 = `castle.png`（石砌城堡）。进局入口是个**中世纪城堡**，跟蒸汽朋克对不上。

**需要**：仓库/工坊、中央机械雕像、出发大门各 1 张（192×256 ~ 320×320）。

```
Top-down 2D game building, {BUILDING}, pixel art in the exact style of Tiny Swords free pack,
{COLORS}, transparent background, consistent top-left light source, game-ready
```

- 仓库/工坊：`a steampunk warehouse with brass pipes, smokestacks and a riveted iron door,
  dark brick and copper-green trim`
- 中央雕像：`a tall bronze mechanical monument on a stone pedestal, a giant gear with a
  central eye-like gauge, steam vents at the base, weathered copper and brass`
- 出发大门：`a massive industrial gatehouse with twin smokestacks, iron portcullis,
  pressure gauges, soot-stained dark metal and copper pipes`

### 12. 撤离点美术

**现状**：`extraction_point.gd` 用 `_draw()` 画圆环 + 进度弧，纯几何图形。
读得懂，但和场景美术不在一个次元。

**需要**：1 张地面停机坪 / 信号灯柱，64×64 ~ 192×192。

```
Top-down 2D game asset, steampunk extraction landing pad, 192x192,
crisp pixel art matching Tiny Swords free pack,
round riveted iron platform with glowing amber gauge lights and a small antenna mast,
transparent background, game-ready sprite, top-left light source
```

### 13. 敌人美术（真正的"怪物"）

**现状**：官方免费包没有怪物，现在是拿 4 个阵营的**士兵**当敌人
（劫掠者 = red_pawn、弓手 = red_archer、邪术师 = red_monk、掠夺者 = yellow_pawn）。
好处是动画齐全，坏处是玩家分不清"这是敌人还是 NPC"。

**需要**：2～3 种明显的非人形敌人（机械蜘蛛、蒸汽僵尸、发条猎犬），
各带 idle / run / attack。

```
Sprite sheet, top-down 2D game monster, {MONSTER}, 192x192 per frame,
horizontal rows: idle 8 frames, run 6 frames, attack 4 frames,
crisp pixel art matching Tiny Swords free pack, steampunk design,
{MONSTER_DESC}, transparent background, consistent top-left light source
```

- 机械蜘蛛：`clockwork spider with brass legs, a glowing pressure-gauge eye, venting steam`
- 蒸汽僵尸：`shambling soot-covered factory worker zombie, one arm replaced by a piston`
- 发条猎犬：`wind-up brass hound, exposed gears in its ribcage, glowing orange furnace mouth`

---

## 四、P2 —— UI 与打磨

### 14. 技能图标 ×3

**现状**：`hud.gd` 的技能条只有文字（"1 蒸汽爆发(25体力)就绪"）。
`combat/skills/` 里有 3 个技能：蒸汽爆发 / 钩爪突进 / 齿轮护盾。

**需要**：3 张 64×64 图标。

```
Set of 3 game skill icons on a single sheet, 64x64 each,
crisp pixel art matching Tiny Swords free pack UI style,
brass frame with dark iron center,
1) a burst of white steam from a pipe, 2) a grappling hook and chain,
3) a glowing gear shield, transparent background, no text
```

### 15. 资源与状态 UI 图标

**现状**：HUD 只用文字 + 颜色显示资源（`食物 x0 / 木头 x20`）。
地上道具已经有 64×64 手绘图标了，但 UI 尺寸需要单独一套（小尺寸下要重画轮廓）。

**需要**：32×32 的木/石/铁/金/油/食物/废料，以及 HP / 体力 / 背包 三个状态图标。

```
Game UI icon set, 32x32 each, crisp pixel art matching Tiny Swords free pack UI,
brass frame, 3/4 view, items: log, stone chunk, iron ingot, gold ingot, oil can,
bread, scrap metal, plus heart, lightning bolt, and backpack icons,
single sheet, transparent background, no text
```

### 16. 小地图图例

**现状**：`minimap.gd` 用纯色点区分玩家/敌人/撤离点/资源点。

**需要**：8×8 ~ 12×12 的小图标（玩家三角、敌人红点、撤离点星标、矿脉点）。

```
Minimap icon set for a 2D game, 12x12 each, crisp pixel art,
white player triangle, red enemy dot, amber extraction star, yellow ore diamond,
semi-transparent dark background, single sheet, no text
```

---

## 五、出图后的接入位置（速查）

| 补什么 | 放哪 | 还要改什么 |
|---|---|---|
| 矿脉 / 装饰 | `Assets/Art/Sprites/Decor/` | `map_generator.gd` 的 `ORE_PATH_LISTS` / `DECOR_PATH_LISTS` |
| 道具图标 | `Assets/Art/Sprites/Items/` | config `resources.<id>.sprite` |
| 单位帧 | `Assets/Art/Sprites/Units/<unit>/` | config `sprites_ts` / `enemy_types` / `animal_types` |
| 建筑 | `Assets/Art/Sprites/Buildings/` | config `base.buildings[*].sprite` |
| 地形 / 水面 | `Assets/Art/Tiles/TS/` | config `map.biomes[*].tileset`、`map_generator.gd::TERRAIN_DIR` |

**放完图必须跑一次导入**，否则 Godot 找不到贴图（`load()` 会静默返回 null，
日志里只留一条"贴图缺失"警告，很容易漏）：

```bash
python tools/godot_import.py
```

然后回归验证：

```bash
python tools/run_godot_headless.py _check.log res://Scenes/Main.tscn --quit-after 60
python tools/preview_map.py _map_full.png --scale 0.125     # 全图
python tools/shot2d.py _live2d.png --delay 2.5              # 局内实拍（开窗口）
```

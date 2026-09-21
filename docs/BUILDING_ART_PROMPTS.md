# 主基地新建筑 · 生图 prompt 包（v2）

给 7 栋新建筑用。**v1 翻过车**，v2 每一条都有实测数字背书。

---

## 一、v1 为什么跑偏（拿那张圆顶残迹对账）

参照物就是你给的 `建筑/Castle/Castle_2.png` —— 实测它和项目里的
`Assets/Art/Sprites/Buildings/blue_castle.png` **md5 完全相同**。也就是说项目现有 12 张
`blue_*` 就是 Tiny Swords 原图：风格目标早就躺在仓库里，不需要"逼近"，需要"对齐"。

| 指标 | 真图 Castle_2 | 即梦 v1 出图 | 判定 |
|---|---|---|---|
| **平涂色数**（占 ≥1% 面积的量化色） | **14 色覆盖 98% 像素** | 21 色只覆盖 **58%**，剩下 42% 散在上百个过渡色里 | ✗ "画风不对"最能量化的一条：真图是平涂色块，出图是厚涂渐变 |
| 明度 V（p10/中位/p90） | 0.18 / **0.61** / 0.82 | 0.14 / 0.53 / **0.93** | ✗ 中间调偏暗 + 高光过曝 |
| 饱和 S（中位/p90） | **0.45** / 0.57 | 0.36 / **1.00** | ✗ 整体发灰，却又有荧光蓝/荧光绿的爆点 |
| 钴蓝/青 色族占比 | `#4090a0`+`#60b0b0` ≈ **16.5%** | 几乎没有（只剩灰蓝） | ✗ TS 的招牌色丢了 |
| 描边 | 统一深蓝黑 `#161c2e`，占 **10%** 像素，等宽 | 疏密不均，暗部糊成纯黑 | ✗ |
| 画布占比 | 横向 **0.97**、纵向 0.81、非透明覆盖 0.61 | 非透明覆盖 **0.49** | ✗ 主体太小、白边太匀 |
| 地台 | **无**，脚下只有一小片烘焙接触阴影 | 一整块 2:1 等距鹅卵石地板 | ✗ 最致命，进游戏就是一块对不上的色板 |

**v1 prompt 自己写错的四处**（不全是模型的锅）：

1. `about 50 degrees` + `the roof reads as a broad ellipse-ish plane` —— 这句实际在**教模型画等距地台**。
   TS 的机位是"从上方约 60° 俯视"，看得见屋顶顶面和城墙步道，但**地面永远不画出来**。
2. `no cast shadow, no contact shadow` —— 错了。真图脚下**有**一小片去饱和暗青 `#204040`
   的接触阴影。禁掉之后模型要么什么都不画（建筑像悬浮），要么自己发明一块地板。
3. `Whole object fully visible with clear margin` —— 这句让模型把主体缩小、四周留匀白边，
   而 TS 的构图是**脚贴画布底边、白边全堆在头顶**（Castle_2 的 bbox 是 y 41~249 / 256）。
4. `rubble scattered on a cobbled floor`、`a low cobblestone ring around the base` 这类
   "鹅卵石"字样出现在主体描述里 —— 等于一边禁止一边点名要。v2 已全部改成"散落几块石头"。

---

## 二、铁律 0：必须喂参考图，光靠文字到不了

v1 已经证明：文字写满 200 词，模型仍然回到"通用等距手游建筑"的先验上。
**唯一可靠的杠杆是把真 TS 图当风格参考喂进去。** 项目里就有现成的，任选 2~3 张：

```
D:\SteamPunkExtraction\Assets\Art\Sprites\Buildings\blue_castle.png     (320×256 宽体)
D:\SteamPunkExtraction\Assets\Art\Sprites\Buildings\blue_monastery.png  (192×320 高体)
D:\SteamPunkExtraction\Assets\Art\Sprites\Buildings\blue_tower.png      (128×256 细长)
D:\SteamPunkExtraction\Assets\Art\Sprites\Buildings\blue_archery.png    (192×256)
D:\SteamPunkExtraction\Assets\Art\Sprites\Buildings\blue_farm.png       (320×299 矮宽)
```

另外 `Dev/tmp_refs/style_ref/` 下我拉了同一素材的 4 个队伍换色版（`Castle_2/3/4/5.png` =
蓝/紫/红/黄），**要蓝的那张**。喂换色版会把模型带偏到紫/红屋顶上。

即梦设置：**参考图模式选「风格参考」**（不是"主体参考/构图参考"），权重拉高（0.7 以上），
1:1 出图。回来后**先看三件事再谈细节**：① 脚下有没有地板 ② 是不是平涂大色块 ③ 有没有那抹钴蓝。

---

## 二·五、即梦实操版（短中文，直接复制）

⚠ 上面那份英文 STYLE BLOCK **不适合即梦**：STYLE + SUBJECT 合计 **2623 字符 / 362 词**，
即梦提示框吃不下，模型会抓住"圆顶/塌墙/石拱门/苔藓"这类具体名词，把风格词全部稀释掉，
然后回到默认的写实先验（实测已经翻过一次：出图是照片级石头材质 + 景深虚化 + 鹅卵石地面）。
英文长块只留给支持长提示 + 多图参考的工具（Nano Banana / Seedream 4 多图模式之类）。

在即梦里分三个框填：

**正向提示词**（约 120 字，末尾换成当次那栋的主体短句）
```
卡通游戏建筑精灵图，Tiny Swords 美术风格：扁平平涂大色块，统一深蓝黑粗描边，每个面只有
亮/中/暗三种色阶且硬边过渡，无渐变无材质纹理无噪点；高俯视 3/4 视角，能清楚看到屋顶顶面；
不画地面，建筑脚底只有一小片软阴影；纯白背景，主体贴住画面底边、撑满宽度；钴蓝瓦加暖木黄
加暖石灰配色，中高饱和。主体：
```

**负面提示词**（即梦有独立负面框，务必填上，别塞进正向）
```
写实，照片，3D 渲染，材质贴图，景深，背景虚化，地面，石板路，鹅卵石，地台，草地，底座，
十字架，宗教符号，文字，字母，水印，logo，边框，渐变，噪点，厚涂，细节堆砌
```

**参考图**：`blue_castle.png` + `blue_monastery.png`，模式选 **「风格参考」**，权重 0.7 以上。
比例 1:1，模型挑带「卡通 / 3D 卡通 / 插画」预设的那个，别用默认写实档。

7 条主体短句（接在正向末尾，一次出一张）：

| 文件 | 主体短句 |
|---|---|
| `blacksmith` | 小铁匠铺，矮石屋配短烟囱，烟囱飘一团圆滚滚的烟，一侧斜木棚，门前铁砧和木水桶 |
| `cemetery` | 小墓园，低石围墙带铁门，里面三四块圆顶灰墓碑，一座石拱墓罩，角落一尊带翼石像，两块歪斜木墓碑 |
| `treehouse` | 树屋营地，一棵大圆冠树，树冠里嵌一间圆锥茅草顶木屋，绳梯和圆窗，树下一顶帐篷和一圈篝火 |
| `fountain` | 村中喷泉，双层圆石盆盛青蓝色水，中间细柱顶一尊小雕像，两道水弧落进盆里，旁边两丛灌木几块散石 |
| `dragon_altar` | 龙形祭坛，圆形石台顶刻红色符文圈，三头卡通龙绕着石台探头，两面竖条纹幡旗和几只陶罐 |
| `statue_pillar` | 纪念雕像柱，高方石基座一侧带台阶，顶上一尊戴冠人物雕像高举一盏灯 |
| `ruin_dome` | 圆顶废墟，矮石圆顶一侧塌开，一孔长满苔藓的石拱门还立着，顶部是断柱形饰（不要十字），脚边一堆乱石 |

---

## 三、共享 STYLE BLOCK（英文长版，只用于支持长提示 + 多图参考的工具）

```
STYLE — a Tiny Swords mobile-RTS building sprite, matching the attached reference images
exactly in line weight, palette and camera. Flat hand-painted cartoon, chunky rounded
inflated shapes. One uniform thick dark-navy outline #161c2e traces the whole silhouette and
every separate part. Cel shading only: exactly 3 flat tones per surface (light / mid / shadow)
with hard edges between them. The whole sprite uses AT MOST 14 flat colours and those colours
cover at least 98% of its pixels — no gradients, no brush texture, no dithering, no
ambient-occlusion smudges, no painterly blending.
Closed palette, use only: cobalt teal #4090a0 with light #60b0b0 and dark #304848 (roof
tiles, trim, banners); slate blue #405080 (shaded stone); warm timber #d09060 and dark wood
#907060; straw #e0d0a0; warm grey stone #b0a090 with light #d8d890; near-black navy #101020
for outlines and deep crevices. Mid-tone brightness: median value 0.61, darkest 0.18,
highlights capped at 0.82, never blown to white. Saturation: median 0.45, maximum 0.65 — no
neon, no acid green, no glowing cyan.
CAMERA: high 3/4 view looking DOWN at the building from about 60 degrees above the ground, so
top surfaces of roofs, wall-walks and basins are clearly visible. This is NOT isometric 2:1
and NOT a side elevation: the base of the building reads as a shallow wide ellipse and the
ground plane is never drawn.
COMPOSITION: the building's feet sit ON the bottom edge of the frame with only ~3% empty below
them; the object fills 95-100% of the frame width and about 80% of its height, with all
leftover space collected as headroom at the top. Do not shrink it, do not leave an even margin
on all four sides.
GROUND CONTACT: the only ground element allowed is a small soft desaturated dark-teal #204040
shadow puddle hugging the very bottom of the building.
BACKGROUND: flat uniform pure white, nothing else in frame.
NEGATIVE: no floor plate, no cobblestone or tiled paving, no base platform, no grass patch,
no dirt mound, no floating island, no long cast shadow, no horizon, no scenery, no text, no
letters, no numbers, no watermark, no logo, no border, no frame, no photorealism, no 3D
render, no smooth gradients.
```

## 四、7 个主体段（接在 STYLE BLOCK 后面，一次出一张）

| 文件名 | 建筑 | 建议画布 | 参考剪影 | 基地槽位 |
|---|---|---|---|---|
| `blacksmith.png` | 铁匠铺/工坊 | 1024×1024 | `Dev/tmp_refs/cut/ref3_13.png` | [38,45] |
| `cemetery.png` | 墓园 | 1024×1024 | `Dev/tmp_refs/cut/ref3_08.png` | [64,45] |
| `treehouse.png` | 树屋营地 | 1024×1024 | `Dev/tmp_refs/cut/ref3_00.png` | [12,57] |
| `fountain.png` | 喷泉广场 | 1024×1024 | `Dev/tmp_refs/cut/ref3_10.png` | [51,33] |
| `dragon_altar.png` | 龙形祭坛 | 1024×1024 | `Dev/tmp_refs/cut/ref3_12.png` | [25,57] |
| `statue_pillar.png` | 雕像柱 | 1024×1536 | `Dev/tmp_refs/cut/ref3_09.png` 右侧那根 | [38,57] |
| `ruin_dome.png` | 圆顶残迹 | 1024×1024 | `Dev/tmp_refs/cut/ref3_11.png` | [51,57] |

### 1 blacksmith 铁匠铺
```
SUBJECT: a small blacksmith forge — squat stone hut with a short chimney puffing one round
cartoon smoke cloud, a wooden lean-to awning on one side, an anvil and a wooden water barrel
standing in front, a rack of tools on the wall. Compact, roughly square silhouette, slightly
taller than wide.
```

### 2 cemetery 墓园
```
SUBJECT: a small cemetery — a low stone boundary wall with an iron gate, three or four
rounded-top grey gravestones inside, one stone arch canopy over a grave, a winged statue in a
corner, two crooked wooden crosses, a few moss tufts and loose stones among the graves. Low,
wide silhouette, cute-melancholic, NOT horror, NOT gore. The wall's own bottom edge is the
silhouette bottom: no paving floor, no cobblestone yard — the graves stand on nothing but the
small contact shadow.
```

### 3 treehouse 树屋营地
```
SUBJECT: a treehouse camp — one big rounded-canopy tree with a wooden hut and a conical thatch
roof built into its crown, a rope ladder and a round window, a small second pole watch
platform, two beige camping tents and a ringed campfire at the base, a target board. Tall,
irregular, leafy silhouette. Leaf green in exactly 3 flat tones, trunk #907060, hut timber
#d09060, tents straw #e0d0a0, one cobalt teal #4090a0 flag.
```

### 4 fountain 喷泉
```
SUBJECT: a village fountain — a round two-tier stone basin holding flat teal-coloured water, a
slim central pillar topped with a small statue, two short water arcs pouring into the basin,
two small bushes and a few loose stones beside it. Low, wide, symmetric silhouette. The basin
is the bottom of the object: no surrounding paved ring, no tiled floor. Water is flat cobalt
teal #4090a0 with one lighter tone #60b0b0, never glowing cyan.
```

### 5 dragon_altar 龙形祭坛
```
SUBJECT: a dragon shrine — a round stone altar with a red rune circle painted on its flat top,
three cartoon dragon heads on curving necks rising around it (one per side, friendly and
stylised, not scary), two tall striped offering banners and clay pots at the base, broken stone
benches around the rim. Medium height, radial silhouette. Dusty mauve scales in 3 flat tones,
brick red runes, straw #e0d0a0 banners. Playful ancient-shrine mood, NOT horror.
```

### 6 statue_pillar 雕像柱
```
SUBJECT: a monument — a tall square stone pedestal with steps on one side, topped by a cartoon
statue of a crowned figure raising a lantern, two bushes at the base. Tall, narrow, strongly
vertical silhouette. One cobalt teal #4090a0 banner, warm gold #e0d0a0 lantern.
```

### 7 ruin_dome 圆顶残迹
```
SUBJECT: an ancient ruin — a low broken stone dome with one wall collapsed outward, a mossy
archway still standing, a small broken stone finial on top (NOT a cross, NOT any real-world
religious symbol), rubble and a few loose stones piled at the base, ivy tufts. Low, wide,
crumbly silhouette. Peaceful ruin-of-a-fallen-kingdom mood, NOT horror. The rubble pile is the
bottom of the object: no cobbled floor, no paving, no platform.
```

---

## 五、交付方式与验收

7 张图丢进 `Dev/tmp_refs/incoming/`（已建好），文件名按上表，然后跟我说"图好了"。

我会先跑**量化验收**（`Dev/tmp_refs/ts_style_spec.py` 换个路径就能用），逐项和真图对：
平涂色数 ≤14 且覆盖 ≥98%、V 中位 0.55~0.70、V p90 ≤0.86、S 中位 0.40~0.55、S p90 ≤0.70、
青蓝色族占比 ≥8%、脚下无地台。不达标的退回并说明差在哪条，不硬塞进游戏。

过了之后：抠白底 → 裁画布 → 塞进真实基地出实拍图给你看 → **你点头才动 `Data/config/run.json`**。

⚠ 即梦右下角有水印，出图务必裁掉或走无水印导出；另外这批图的授权要能商用 ——
项目现有素材全是 CC0，来源不明的图别提交进 `Assets/`（放 `Dev/tmp_refs/` 随便）。

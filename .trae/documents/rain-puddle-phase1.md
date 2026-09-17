# 局内地图雨天效果 — 第一阶段(雨滴 / 积水 / 踩水波纹)

## Context

你想在**局内探索地图**(通过基地大门进局的 `Mode.RUN` 场景,不是局外基地)加上雨天氛围:下落雨滴+落地飞溅、地面噪波积水的 step 裁切与边缘虚化、角色踩水时生成波纹并切换水声。你给的五步方案里,**倒影(MultiMesh+SubViewport)与折射扰动(屏幕纹理采样)作为第二阶段**,本次先落地 1+2+3 并验证性能与观感。

开工前需先纠正一处前提:**本仓库是纯 GDScript 项目**(全仓无 `.cs`/`.csproj`,50+ 个 `.gd` 脚本,`project.godot` features 标 `4.7`),不是"Godot 4.5.1 + C#"。已确认按 GDScript 实现——粒子、Shader、SubViewport、MultiMesh 在 GDScript 下能力完全等价,第二阶段也不受影响。

另一处现状:**项目里没有任何音频文件**(`Assets/Audio` 只有 `.gitkeep`),也没有任何 `AudioStreamPlayer` 播放代码。已确认音效用**运行时程序合成**的占位音,接口留好,以后有正式素材直接替换。

还有一处会影响预期:`map_generator.gd` 的 `DECOR_WATER`(河水浅滩)在当前版本**恒为 0 格**——河流已按需求移除,`_paint_band()` 是无调用点的死代码。所以积水不能只靠浅滩格,必须新增噪声水洼;掩码仍按"浅滩 ∪ 水洼"并集构建,将来恢复河流零改动接上。

预期产出:进局即下雨、地面有成片积水、走过积水有波纹和水声;`weather.enabled=false` 一键回退;同 `--seed` 截图可复现。

## 现有层级与挂载点(决定新层放哪)

`_enter_run()`([main.gd](file:///d:/SteamPunkExtraction/Scripts/main.gd#L379-L444)):`_clear_game_root()` → `MapGenerator.generate()` → `game_root.add_child(result.node)` → 玩家(z=1)→ Camera2D → 各系统 `setup(game_root, result)` → `fog_system.setup()`。

z_index 现状:地形 TileMapLayer 0 / 装饰层 0(y_sort)/ MacroLight 0 / 玩家 1 / 雾层 5 / 抛射物 30 / fx_ring 50。HUD、Minimap 是 CanvasLayer,天然在世界层之上。

`_clear_game_root()`([main.gd](file:///d:/SteamPunkExtraction/Scripts/main.gd#L359-L361))只 `queue_free` GameRoot 子节点 → 挂进 GameRoot 的雨/积水节点会随切图自动销毁;WeatherSystem 本体作为 Main 子节点持久存活,与 FogSystem 完全同一模式。

## 文件清单

### 新建

| 文件 | 职责 |
|---|---|
| `Scripts/weather_system.gd` | 核心系统:水洼网格生成、掩码烘焙、雨/溅粒子装配、积水 ShaderQuad、波纹对象池、程序音效合成与播放、踩水查询接口 |
| `Shaders/puddle.gdshader` | 积水基底 shader:世界坐标 UV、step 裁切、8 邻内缩、滚动噪声边缘虚化、微光 |
| `Scripts/ripple_ring.gd` | 单个水波纹,仿 [fx_ring.gd](file:///d:/SteamPunkExtraction/Scripts/combat/fx_ring.gd) 的 `_draw()` 双圈扩张,池化复用(不 `queue_free`) |

### 修改

| 文件 | 改动 |
|---|---|
| `Scenes/Main.tscn` | Main 下新增 `WeatherSystem`(type=Node),排在 FogSystem 之后 |
| [main.gd](file:///d:/SteamPunkExtraction/Scripts/main.gd) | ① `@onready var weather_system`;② `_enter_run()` 在 `fog_system.setup()` 后加 `weather_system.setup(game_root, result)`;③ `_enter_base()` 在 `fog_system.deactivate()` 旁加 `weather_system.deactivate()` |
| [player_move_state.gd](file:///d:/SteamPunkExtraction/Scripts/combat/states/player_move_state.gd#L20-L26) | 0.4s 脚步 tick 处:踩水则调 `weather.on_water_step(pos)`,噪声照常发(踩水不豁免噪音暴露) |
| `Data/config.json` | 新增顶层 `weather` 节 |

不动 `player.gd` / `map_generator.gd` / `enemy.gd` / `animal.gd`。

## 设计要点

### 1. 雨滴跟随 RTS 相机

不用挂相机下(会被 zoom 缩放粒子),不用超大固定发射框。做法:`RainAnchor`(Node2D,game_root 下,z=6)每帧把 `global_position` 同步成 `get_viewport().get_camera_2d().global_position`;其下两个 `GPUParticles2D` 均设 **`local_coords = false`**(世界空间模拟,anchor 移动只改变新粒子的出生框中心,已存在的雨滴不会被拖着瞬移)。发射框 `emission_box_extents` 每帧按实际 `cam.zoom` 重算 = `视口尺寸 / zoom * 0.5 + margin`,任意缩放下屏内雨密度近似恒定。

雨滴与飞溅贴图运行时程序生成(`Image.create` → `ImageTexture`:竖向 alpha 渐变条纹 / 小圆点),零美术资产依赖。

飞溅用**独立的第二个 GPUParticles2D**(短寿命 ~0.22s、小上抛初速+强重力、扁发射框贴地),不用 2D sub-emitter + `GPUParticlesCollision2D` 那套复杂度。第二阶段若要做真碰撞溅射,只需替换这个发射器,架构不冲突。

### 2. 积水:单个全图 Quad + shader(不用 TileMapLayer)

8192×8192 世界像素的 Sprite2D(1×1 白纹理,形状全来自 shader),1 个 draw call,GPU 只光栅化视口内 fragment。节点无父级变换且 `centered=false`,shader 里 `VERTEX` 恒等于世界像素坐标 → `cell = VERTEX / tile_px`,无需每帧传相机 uniform。

**必须显式设 `visibility_rect = Rect2(0,0,map_w*ts,map_h*ts)`** —— 默认按 1×1 纹理算会把整层裁掉,症状是"积水完全不显示",这是本方案唯一的坑。

层序:`map_root.add_child(puddle)` 后 `move_child` 插到地形层之后、DecorLayer 之前 → 水在树/石之下(不淹树),并受 MacroLight 统一压暗。

掩码烘焙(`setup()` 内,CPU 一次生成,两份真相同源不漂移):
1. `FastNoiseLite` simplex,种子走 `_enter_run` 的 seed 链 → `--seed` 可复现;
2. 分位数阈值微调保证占比 ≈ `puddle.floor_ratio`(同 `_biome_quantile_edges` 思路);
3. 只在 `!walls[y][x]` 地板格生成,出生点 `clear_spawn_radius_cells` 内强制排除;
4. 并入 `decor[y][x] == DECOR_WATER`(当前恒空,为将来留线);
5. 2 轮多数投票平滑,消单格噪点让水洼成团;
6. 输出 `Image(map_w,map_h,R8)` → `ImageTexture`(`filter_nearest`)给 shader uniform,同时存 `_water_cells` 二维数组供逻辑查询。

shader 四步:`step` 裁切非水格 `discard` → 8 邻取样近似腐蚀 1 格得"内部" → 边缘带 alpha 由 `TIME` 滚动的 fbm 决定(虚化) → 微光项(第二阶段把这项换成 `screen_texture` 采样即得折射,不改接口)。

### 3. 踩水波纹与音效

- 检测走 `_water_cells` 数组 O(1) 查表,不读 GPU。
- 触发点唯一:`player_move_state` 的 0.4s 脚步 tick(复用 `noise.footstep_interval_seconds`,不另设键造成两处真相)。小队多角色各自 tick,天然支持多人。
- 波纹:`RippleRing` 对象池(game_root 下,晚于地图根添加故画在积水之上),池满则跳过(波纹是消耗品,丢帧不可见)。不用 GPUParticles2D——波纹需要"每次脚步一圈"的精确语义,粒子反而要处理发射同步。
- 音效:**预生成 `AudioStreamWAV`,不用 `AudioStreamGenerator`**(Generator 每帧填缓冲,常驻雨声白占 CPU 且多一处 headless 变量;WAV 一次生成后走引擎原生无缝循环)。
  - `_make_rain_wav()`:白噪声 → 一阶低通+高通去隆隆 → 慢噪声调幅(gust 起伏)→ 首尾交叉淡化保证无缝循环;稀疏瞬态"嘀嗒"并入此循环,第一阶段不单独建滴溅 emitter。
  - `_make_step_wav()`:0.18s 指数衰减噪声包络 × 中心频率下滑带通 + 下滑正弦"啾"声。
  - 播放拓扑:雨声 = 全局 `AudioStreamPlayer`(bus SFX)挂 WeatherSystem 本体,`deactivate()` 里显式 `stop()`(它是唯一不随 `_clear_game_root` 清理的东西);踩水声 = 3 个 `AudioStreamPlayer2D` 轮转,`max_distance` 走 config。
  - 总线 SFX 由 [display_settings.gd](file:///d:/SteamPunkExtraction/Scripts/display_settings.gd) 的 `_ensure_bus()` 在 autoload 阶段建好,玩家改音量即时生效,无需接线;取不到时回落 0。

### 4. 防御与回退

`player_move_state` 走战斗热路径,必须"取不到 weather 或未激活时回落原逻辑"(`get_first_node_in_group("weather_system")` 缓存 + `is_instance_valid`)。所有对 GameRoot 内节点的引用都加 `is_instance_valid` 守卫(切图时被 `queue_free`)。`weather.enabled=false` 时 `setup()` 直接 return,整套效果零节点装配。

### 5. 第二阶段不堵死

倒影 MultiMesh 可作为 map_root 内 puddle 之后、decor 之前的兄弟节点插入;折射扰动改 puddle shader 的微光段为屏幕纹理采样;真碰撞溅射替换 splash 发射器。三者均不动本阶段任何接口。

## config.json `weather` 节

```json
"weather": {
  "enabled": true,
  "rain": { "amount": 700, "splash_amount": 140,
            "fall_speed_px": [900.0, 1300.0], "wind_x_px": -60.0,
            "streak": {"width_px":3,"length_px":26,"color":"#a8c4e0","alpha":0.55},
            "splash": {"lifetime_s":0.22,"speed_px":[40.0,110.0],"size_px":4.0,"color":"#cfe6ff","alpha":0.7},
            "emission_margin_px": 160.0, "z": 6 },
  "puddle": { "floor_ratio":0.10,"noise_frequency":0.045,"smooth_iterations":2,
              "clear_spawn_radius_cells":4,"color":"#3f6f8f","alpha":0.42,
              "noise_scale":0.10,"scroll_px_per_s":[0.02,0.05],"wobble":0.65,
              "edge_soft":0.30,"shimmer":0.08 },
  "ripple": { "pool_size":16,"radius_px":46.0,"duration_s":0.55,"color":"#bfe3ff","alpha":0.8 },
  "step":   { "max_distance_px":900.0,"volume_db":-10.0,"players":3 },
  "audio":  { "rain_loop_seconds":4.0,"sample_rate":22050,"rain_volume_db":-16.0,
              "rain_lowpass_hz":1400.0,"rain_highpass_hz":180.0,"gust_depth":0.35,
              "drip_count":6,"step_duration_s":0.18 }
}
```

## 实施顺序

每步独立可截图二分:

1. `config.json` 加 `weather` 节(先落数值,杜绝后续硬编码)
2. `Shaders/puddle.gdshader` + `Scripts/ripple_ring.gd`(独立小件)
3. `weather_system.gd` 做掩码烘焙 + 积水 Quad → 接 main.gd 的 setup/deactivate → 截图验证层序(水不淹树、受 MacroLight 压暗)
4. 加雨/溅粒子 → 验证跟随相机与缩放(`local_coords=false` 生效:按住 WASD 平移,雨不应整体瞬移)
5. 加波纹池 + 踩水 hook + 程序音效
6. 全量验证

## 验证

```powershell
# A. 无头行为回归:积水网格生成/粒子装配/音频合成不崩,日志计数合理
godot --headless --path . --fixed-fps 60 res://Scenes/Main.tscn -- --soak 30 --seed 20260915
#    期望 [Weather] 水洼 N 格(占比 x%,目标 y%);无 ERROR / RID leak

# B. 有窗口截图:同 seed 两次水洼位置必须一致(可复现性)
godot --path . -- --capture2d D:/shots/rain_a.png --capture-delay 6 --seed 123

# C. 交互:手动进局点击角色穿过水洼 → 波纹按 0.4s 节奏出现、踩水音切换;跑 2 分钟节点数不增长(池不泄漏)
# D. 循环:回基地 → 再进局 ×3,无报错、雨声不叠加(setup/deactivate 幂等)
# E. 回退:weather.enabled=false 重跑 A,确认零影响
```

可选低成本增强:`_handle_cli` 加 `--dump-puddle <path>`,把 `_water_cells` 导成 128×128 PNG(照抄 `_dump_biome_png` 骨架),水洼分布一目了然。

## 待你确认的取舍

- **敌人/动物踩水**:它们靠 `add_to_group("enemies"/"animals")` 管理,技术上各加约 10 行即可。但 100+60 个单位持续发射波纹在 RTS 远景下视觉噪音大、会挤占玩家波纹池,音效还需按听距门控。**建议第一阶段只做玩家小队**,`on_water_step(pos)` 不区分调用者,第二阶段加敌人只需各插一行。
- **局结束后是否停雨**:`run_ended` 后到按 R 回基地前雨仍在下(与雾的表现一致)。若要"局结束即停雨",连一个 `run.run_ended → deactivate()` 即可。

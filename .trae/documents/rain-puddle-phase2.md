# 雨天积水第二阶段(步骤 3-5:SubViewport 波纹 / MultiMesh 倒影 / 屏幕纹理折射色散)

## Context

第一阶段(雨滴+积水基底+踩水波纹+程序音效)已完成并验证。用户规格共 5 步,本次完成剩余 3 步,一次全做完:

- **3 水波纹交互**:SubViewport 渲染波纹粒子贴到积水,踩水出波纹 + 干/湿脚步音切换
- **4 倒影渲染**:MultiMesh2D 批量渲染装饰物,垂直镜像,SubViewport 渲染倒影+天空渐变,输出贴图作积水反射底图
- **5 折射与扰动**:噪波偏移 UV 让倒影晃动;波纹通道拆分(红=亮度基、绿蓝=色散量);采样 SCREEN_TEXTURE 实现折射扭曲;噪波灰度调反射透明度

**用户已确认**:3+4+5 一次全做完;倒影只含静态装饰(树/石/灌木)+天空渐变底,不含动态单位;两个 SubViewport 均半分辨率。项目为纯 GDScript(Godot 4.7.2),数值全部进 config.json。

## 核心推导(先定这三个,后续全部依赖)

1. **半分辨率 SubViewport 相机 zoom = 主相机 zoom × scale(scale=0.5)**。主/子视口显示同一世界区域,`SCREEN_UV` 与子视口贴图 UV 逐点对应:`zoom_sub = zoom_main × vp_sub/vp_main`。
2. **垂直镜像用 `_refl_cam.zoom = Vector2(zs, -zs)`**:负 zoom.y 绕视口水平中线翻转,相机位置一行同步。若负 zoom 在实测中异常,回退:内容根节点 `_refl_flip.scale = (1,-1)` + 相机位置取 `(x, -y)`。
3. **性能**:puddle shader 覆盖全图(8192×8192),所有重采样(SCREEN_TEXTURE / reflection_tex / ripple_tex)必须放在 `cellval < 0.5 discard` **之后**,否则全图每像素付代价。

## 实施步骤

### A. Data/config.json 加键(先落数值,零硬编码)

weather 节内新增(均带 `_comment`):

```json
"viewports":       { "scale": 0.5 },
"reflection":      { "enabled": true, "alpha": 0.55, "wobble_scale": 0.12, "wobble_speed": 0.8,
                     "wobble_strength": 0.012, "sky_top_color": "#3c4c60", "sky_bottom_color": "#6d8ba6",
                     "exclude_path_fragments": ["crack"] },
"refraction":      { "enabled": true, "strength": 0.008 },
"ripple_viewport": { "scale": 0.5 }
```

扩展:`puddle` 加 `"reflection_blend": 0.65`(原 shimmer 废弃,注释说明);`ripple` 加 `"base_channel": 0.85, "disp_channel": 0.5, "glow": 0.35`;`step` 加 `"dry_volume_db": -14.0`;`audio` 加 `"step_dry_duration_s": 0.10`。

### B. 波纹 SubViewport(weather_system.gd + ripple_ring.gd)

weather_system.gd 新成员:`_refl_vp/_ripple_vp`(SubViewport)、`_refl_cam/_ripple_cam`(Camera2D)、`_refl_root/_ripple_root_world`(Node2D)、`_sky_rect`(ColorRect)、`_refl_meshes`(Array)、`_placeholder_tex`(2×2 白 ImageTexture,`_ready` 建)。

`_build_viewports(root, map_data)`(setup 里插在 `_build_puddle` 之前):
- 两个 SubViewport `add_child` 到 `root`(game_root,随 `_clear_game_root` 销毁);`transparent_bg=true`、`render_target_update_mode=SubViewport.UPDATE_ALWAYS`、`gui_disable_input=true`、初始 `size=(主视口×scale).round()`;各自挂 Node2D 根 + `Camera2D.make_current()`。
- 波纹视口内挂 RippleLayer 池(`_build_ripples` 父节点改为 `_ripple_root_world`);ring 的 `global_position` 直接是世界坐标,`spawn()` 协议不用改。

`_process` 追加 `_sync_viewports()`(与 RainAnchor 同步并排):

```gdscript
var cam := get_viewport().get_camera_2d()
var vp: Vector2 = get_viewport().get_visible_rect().size
var scale := float(Config.get_value("weather.viewports.scale", 0.5))
var sub_px := Vector2i(maxi(1, int(vp.x*scale)), maxi(1, int(vp.y*scale)))
if _refl_vp.size != sub_px:
    _refl_vp.size = sub_px; _ripple_vp.size = sub_px   # 窗口缩放自愈
var z := maxf(cam.zoom.x, 0.05)
var zs := z * scale
_refl_cam.global_position = cam.global_position
_refl_cam.zoom = Vector2(zs, -zs)                     # 绕水平中线镜像
var vis := vp / maxf(z, 0.001)
_sky_rect.size = vis
_sky_rect.position = cam.global_position - vis * 0.5
_ripple_cam.global_position = cam.global_position
_ripple_cam.zoom = Vector2(zs, zs)
```

ripple_ring.gd 不改 `_draw`,只改 `_ripple_color()`(weather_system.gd 内)返回 `Color(base_channel, disp_channel, disp_channel, alpha)`——红=亮度基、绿/蓝=色散量,单圈一次 draw_arc 完成通道拆分。

### C. 倒影 SubViewport + MultiMesh2D(weather_system.gd)

`_build_reflection(map_data)`:取 `map_root.get_node_or_null("DecorLayer")`,遍历 Sprite2D 子节点,过滤 `offset.y >= -0.5` 且路径不含 `exclude_path_fragments`(剔除贴地裂缝),按 `texture` 分组。每组一个 MultiMesh2D:

```gdscript
var mm := MultiMesh.new()
mm.transform_format = MultiMesh.TRANSFORM_2D
mm.color_format = MultiMesh.COLOR_8BIT          # 必须先于 instance_count
var quad := QuadMesh.new()
quad.size = tex.get_size()                      # Godot 4 为 Vector2
mm.mesh = quad
mm.instance_count = sprites.size()
var mm2d := MultiMesh2D.new()
mm2d.multimesh = mm
mm2d.texture = tex
for i in sprites.size():
    var s: Sprite2D = sprites[i]
    var half := tex.get_size() * 0.5
    var sx := s.scale.x * (-1.0 if s.flip_h else 1.0)
    var origin := s.position + s.offset * s.scale + Vector2(half.x*sx, half.y*s.scale.y)
    mm.set_instance_transform_2d(i, Transform2D(Vector2(sx,0), Vector2(0,s.scale.y), origin))
    mm.set_instance_color(i, s.modulate)         # 烘焙 biome 色调/亮度抖动
_refl_root.add_child(mm2d)                       # 天空 rect 之后添加,压在渐变上
```

非居中锚点推导:quad 中心在原点,原点 = 左上角 + half×缩放(flip 带负号),轴向量由 scale 构造,旋转恒 0。装饰静态 → setup 建一次,不每帧更新。**镜像由相机做,实例 transform 用世界坐标,切勿再手动翻转**。

天空渐变:倒影视口内放 ColorRect + GradientTexture2D(两色由 config sky_top/bottom),每帧 `_sync_viewports` 同步 size/position(即可见世界区域,与 RainAnchor 同款)。

### D. puddle.gdshader 重构(weather_system.gd + puddle.gdshader)

新增 uniform:

```glsl
uniform sampler2D reflection_tex : filter_linear, repeat_disable;
uniform sampler2D ripple_tex : filter_linear, repeat_disable;
uniform float reflection_alpha = 0.55;
uniform float wobble_scale = 0.12;
uniform float wobble_speed = 0.8;
uniform float wobble_strength = 0.012;
uniform float dispersion = 0.015;
uniform float refraction_strength = 0.008;
uniform float reflection_blend = 0.65;
uniform float ripple_glow = 0.35;
uniform vec4 ripple_tint : source_color = vec4(0.75, 0.89, 1.0, 1.0);
```

fragment:①②③④(裁切/软边/内缩/边缘虚化)全部不动;替换原⑤ shimmer 段,重采样全部在 discard 之后:

```glsl
vec2 suv = SCREEN_UV;
float t = TIME;
vec2 wob = vec2(vnoise(cell*wobble_scale + vec2(0.0, t*wobble_speed)),
                vnoise(cell*wobble_scale + vec2(9.17, t*wobble_speed*0.7)));
wob = (wob - 0.5) * wobble_strength * 4.0;
vec2 rp = texture(ripple_tex, suv).rg;                    // r=亮度基 g=色散量
vec2 off = normalize(vec2(0.35,0.85) + wob*0.2) * (rp.g*2.0-1.0) * dispersion + wob;
vec3 refl;
refl.r  = texture(reflection_tex, suv + off).r;           // 红通道 +off
refl.gb = texture(reflection_tex, suv - off).gb;          // 绿蓝 −off（色散）
float refl_a = clamp(reflection_alpha * (0.5 + 0.5*fbm2(cell*noise_scale + t*scroll_dir)), 0.0, 1.0);
vec3 refr = texture(SCREEN_TEXTURE, suv + wob*refraction_strength).rgb;
vec3 rgb = mix(refr, refl, refl_a);
rgb += rp.r * ripple_glow * ripple_tint.rgb;
rgb = mix(water_color.rgb, rgb, reflection_blend);
COLOR = vec4(rgb, clamp(a, 0.0, 1.0));
```

Godot 4 canvas_item 用内置 `SCREEN_TEXTURE/SCREEN_UV`(非 3.x 的 hint_screen_texture);`repeat_disable` 防 ±off 出界回绕。`_build_puddle` 补 `set_shader_parameter("reflection_tex", _refl_vp.get_texture())`、`ripple_tex` 同理。已知小偏差:SCREEN_TEXTURE 是 puddle 绘制瞬间的屏前内容,不含其后绘制的 DecorLayer/MacroLight,折射底略欠压暗,可接受。

### E. 踩水音效干/湿分离(weather_system.gd + player_move_state.gd)

- `_gen_dry_step_wav()`(0.10s、低通 900Hz 噪声 click,照 `_gen_step_wav` 骨架)+ 3 个 dry 播放器池(volume_db 走 `step.dry_volume_db`)。
- 新公开接口 `on_dry_step(pos)`(dry 脚步:不产生波纹,只播干脚步声)。
- player_move_state.gd 脚步 tick 改为:

```gdscript
if weather != null:
    if weather.is_water_at(pos): weather.on_water_step(pos)
    else: weather.on_dry_step(pos)
```

(新增调用,不破坏现有接口;NoiseSystem.emit 保持不变)

### F. 接线与清理(weather_system.gd)

- setup 顺序:`_build_water_grid → _build_viewports → _build_puddle → _build_reflection → _build_ripples → _build_rain → _play_rain`
- deactivate()/_exit_tree():先把 `reflection_tex/ripple_tex` 置为 `_placeholder_tex`(防 ViewportTexture 在视口释放后仍被采样报 stale),再断 `_refl_vp/_ripple_vp/_refl_cam/_ripple_cam/_refl_root/_ripple_root_world/_sky_rect/_refl_meshes` 引用。
- 全部新数值走 Config.get_value 点号路径,脚本零硬编码。

## 风险与回退

- **负 zoom.y 镜像异常**(实测优先):回退 `_refl_flip.scale=(1,-1)` + 相机位置取 `(x, -y)`。
- **MultiMesh2D 实例 transform 公式偏差**:实现时对照 DecorLayer 实际 Sprite2D 的 centered/offset/flip_h/modulate 验证,先打印一个样例数值比对截图。
- **半分辨率 draw_arc 齿感**:由 shader filter_linear 采样抹平。
- **SubViewport 漏设 transparent_bg** → 整片黑底污染水面,务必设置。

## 验证

```powershell
# 无头回归:期望无 SCRIPT ERROR / ObjectDB leak(既有敌人 0/AI 未激活 FAIL 为基线)
python tools/run_soak.py --seconds 40 --seed 20260917 --log _soak_p2.log

# 有窗口截图(出生点附近才有水,临时把 weather.puddle.clear_spawn_radius_cells 改 0 再看,看完还原)
python tools/shot2d.py shots/p2_reflection.png --delay 4 --seed 20260917 --no-fog
```

Read png 检查:水面出现上下颠倒的树/石倒影、边缘晃动、波纹色散;`tools/_shot2d.log` 抓 ERROR。手动进局踩水验证波纹节奏与干/湿脚步音;`weather.enabled=false` 重跑确认零装配回退。

## 涉及文件

- Scripts/weather_system.gd(主改动:双 SubViewport、MultiMesh2D、dry 脚步、接线清理)
- Shaders/puddle.gdshader(折射/倒影/色散合成)
- Scripts/ripple_ring.gd(通道颜色来源在 weather_system._ripple_color,ring 本身不改)
- Scripts/combat/states/player_move_state.gd(脚步 tick 分支 dry/wet)
- Data/config.json(weather 节扩展)

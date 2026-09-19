# Tiny Swords (Update 010) UI — 未调用素材清单

> 来源：`D:\Tiny-Warcamp\Tiny-Warcamp-main\TinyResources\Tiny Swords\Tiny Swords (Update 010)\UI`
> 已导入项目：`res://Assets/Art/UI/tsui_update010/`（90 个 PNG，已跑 `godot_import.py` 生成 `.import` 缓存）
> 状态：**全部 90 个都是「没有叫的」** —— 游戏代码（`ui_kit.gd` / `display_settings.gd`）只认旧 `tsui/` 目录（小写命名 `btn_blue`、`banner`、`ribbon_blue`、`cursor_*`、`icon_0x`），这套 Update 010 是原版 Pupkin 命名体系（`Button_Blue`、`Banner_Connection_*` 等），命名对不上，所以一个都没被引用。

## 现有 `tsui/`（游戏真正在用的，26 个，对照用）
横幅 `banner` / 飘带 `ribbon_blue` / 按钮 `btn_blue` `btn_blue_pressed` `btn_small` `btn_small_pressed` / 光标 `cursor_arrow` `cursor_forbidden` `cursor_hand` / 图标 `icon_01,05,06,07,09,10`（6 个零散）/ 其它 `bar_base bar_fill check_off check_on grabber menu_map paper paper_dark slate_tile wood_panel wood_tile`

---

## ① Banners（横幅）— 9 个，全新增
| 文件 | 说明 | 游戏现有对应 |
|---|---|---|
| Banner_Horizontal / Banner_Vertical | 横 / 竖普通横幅 | 仅 `banner.png`（无横竖之分） |
| Banner_Connection_Up / Down / Left / Right | 带方向连接的横幅（拼角用） | 无 |
| Carved_Regular / Carved_3Slides / Carved_9Slides | 雕刻风横幅（3/9 切片版拉伸不变形） | 无 |

## ② Buttons（按钮）— 18 个，全新增
| 文件 | 说明 | 游戏现有对应 |
|---|---|---|
| Button_Blue / Button_Blue_Pressed | 蓝按钮 + 按下态（含 `_3Slides`/`_9Slides` 切片版） | `btn_blue`/`btn_blue_pressed`（无切片版） |
| Button_Red / Button_Red_Pressed | **红按钮**（危险/警告用） | 无 |
| Button_Disable / Button_Hover | 禁用态 / 悬停态（含切片版） | 无 |

## ③ Icons（图标）— 30 个，全新增
| 文件 | 说明 | 游戏现有对应 |
|---|---|---|
| Regular_01~10 | 正常态图标 ×10 | `icon_01,05,06,07,09,10`（6 个零散，无状态） |
| Disable_01~10 | 禁用态图标 ×10 | 无 |
| Pressed_01~10 | 按下态图标 ×10 | 无 |

> 这是一套完整的「10 图标 × 3 态」图标系统，游戏目前完全没有用到。

## ④ Pointers（鼠标光标）— 6 个，全新增
| 文件 | 说明 | 游戏现有对应 |
|---|---|---|
| 01.png ~ 06.png | 6 个新光标（无名，需自测哪个是手/剑/指向） | `cursor_arrow` `cursor_hand` `cursor_forbidden`（3 个，命名不同） |

## ⑤ Ribbons（飘带）— 27 个，全新增
| 文件 | 说明 | 游戏现有对应 |
|---|---|---|
| Ribbon_Blue_3Slides | 蓝飘带 3 切片 | `ribbon_blue.png`（普通，无切片） |
| Ribbon_Blue_Connection_Up/Down/Left/Right (+_Pressed) | 蓝飘带带方向连接 + 按下态 | 无 |
| Ribbon_Red_3Slides / Red_Connection_* | **红飘带**（同上结构） | 无 |
| Ribbon_Yellow_3Slides / Yellow_Connection_* | **黄飘带**（同上结构） | 无 |

---

## 想接上（低风险、建议）
- **红按钮** `Button_Red*` → 加进 `ui_kit._apply_button_skin` 当「危险/确认删除」按钮皮肤。
- **6 个新光标** `Pointers/01~06` → 在 `display_settings.gd` 注册为额外光标（需先实机看哪个对应哪种手势）。
- **10 组图标** `Icons/Regular_*` → 接物品栏/技能栏（游戏目前没图标栏，需先建槽位）。
- **方向横幅/飘带** `Banner_Connection_*` / `Ribbon_*_Connection_*` → 做连接式 UI（如任务链、地图路线）时用，目前无对应系统。

> 命名体系不同（Pupkin 原版 `Button_Blue` vs 现有 `btn_blue`），要直接替换旧皮肤需改 `ui_kit.gd` 的 `TS_TEX_DIR` 引用名或把文件改名拷进 `tsui/`。要我接哪一个，说一声即可。

## 商用
同属 Pupkin 的 Tiny Swords 体系，可商用，游戏内署 "Tiny Swords by Pupkin"。

# 敌人特性迁移（2026-09-19）

原 4 个老怪已删除，特性迁到对应 Enemy Pack 敌人。现刷怪池 = 21 个 Enemy Pack 兵种。

## 迁移对照
| 原敌人（已删） | 特性 | → 新敌人（接收） |
|---|---|---|
| brigand 劫掠者 | `ai`：满地图漫游 `whole_map` + 成群 `pack(上限5)` + 噪音敏感 1.8 | **ep_spear_goblin 长矛哥布林** |
| raider 弓手 | `traits`: phantom_double 幻影分身 | **ep_torch_goblin 火把哥布林** |
| cultist 邪术师 | `traits`: burst_drum 爆裂鼓手 | **ep_bear 熊** |
| marauder 掠夺者 | `traits`: death_split 死亡分裂 + death_regen 死亡再生 | **ep_skull 骷髅** |

## 字段说明
- 劫掠者无 `traits`（它只有 `ai` 行为段），所以迁的是整段 `ai`（漫游+成群+听感）。
- raider/cultist/marauder 迁的是 `traits` 数组。ep_skull 随机获得分裂或再生之一（与原掠夺者一致：一个角色一种特性）。
- 数值（hp/damage/speed/scale）**未搬**——新敌人保留各自的数值；只搬行为特性。
- 帧文件未动，全部就位（校验 0 缺失）。

## 校验
- JSON 合法；兵种总数 21；原 4 个无残留；4 个目标兵种特性全部 OK；帧文件 0 缺失。

## 注意
- `Dev/probe_brigand_ai.gd` / `probe_brigand_live.gd` / `probe_cultist_trait.gd` / `probe_phantom_double.gd` / `probe_enemy_split.gd` 等测试探针仍硬编码引用 brigand/raider/cultist/marauder，删配置后它们跑会找不到兵种而报错。**这些是测试脚本，不影响游戏**；要保留验证能力需更新这些探针指向新 id。
- 备份：`Data/config.json.traits.bak`

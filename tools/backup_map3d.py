#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""备份当前 3D 地图渲染层到 D:\\import\\map3d_backup_<日期>

路线 A（2D 渲染回退）开工前的安全网。
不动项目内的任何东西，纯复制（copy2 保留时间戳）。

用法：
    python tools/backup_map3d.py              # 备份到默认目录
    python tools/backup_map3d.py D:\\import   # 指定根目录
"""
import os
import sys
import shutil
import time
import hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (项目内相对路径, 备份内相对路径)。目录会被整体复制。
JOBS = [
    # --- 3D 渲染层的全部代码 ---
    ("Scripts/map_render_3d.gd",        "Scripts/map_render_3d.gd"),
    ("Scripts/iso_camera_3d.gd",        "Scripts/iso_camera_3d.gd"),
    ("Scripts/fog_3d.gd",               "Scripts/fog_3d.gd"),
    ("Scripts/entity_visual_3d.gd",     "Scripts/entity_visual_3d.gd"),
    ("Scripts/base_render_3d.gd",       "Scripts/base_render_3d.gd"),
    ("Scripts/player_visual_3d.gd",     "Scripts/player_visual_3d.gd"),
    ("Scripts/main3d.gd",               "Scripts/main3d.gd"),
    ("Scenes/Main3D.tscn",              "Scenes/Main3D.tscn"),
    # --- 3D 地图用到的资产 ---
    ("Assets/Art/Models",               "Assets/Art/Models"),
    ("Assets/Art/Terrain3D",            "Assets/Art/Terrain3D"),
    ("Assets/Art/Source3D",             "Assets/Art/Source3D"),
    # --- 探针与生成工具 ---
    ("Dev/probe_map3d_full.gd",         "Dev/probe_map3d_full.gd"),
    ("Dev/probe_map3d_full.tscn",       "Dev/probe_map3d_full.tscn"),
    ("Dev/probe_map3d_full.png",        "Dev/probe_map3d_full.png"),
    ("tools/gen_grass_3d.py",           "tools/gen_grass_3d.py"),
    ("tools/gen_ground_3d.py",          "tools/gen_ground_3d.py"),
    ("tools/tile_texture_for_3d.py",    "tools/tile_texture_for_3d.py"),
    # --- 配置快照（回退前的项目状态）---
    ("project.godot",                   "config_snapshot/project.godot"),
    ("Data/config.json",                "config_snapshot/config.json"),
]

README = """# 3D 地图渲染层备份

- 备份时间：{ts}
- 来源项目：`D:\\SteamPunkExtraction`
- 备份原因：美术转向 Tiny Swords（2D 像素整套资产），3D 地图渲染层暂时搁置。
  这是一份完整快照，不是删除 —— 项目里的 3D 代码仍在 git 历史里随时可取。

## 内容

| 目录 | 说明 |
|---|---|
| `Scripts/` | 3D 渲染层全部脚本：map_render_3d（瓦片+装饰→3D）、iso_camera_3d（等距相机+缩放）、fog_3d（战争迷雾）、entity_visual_3d（敌人/基地视觉）、base_render_3d（基地）、player_visual_3d（HD-2D 公告板）、main3d（3D 入口） |
| `Scenes/Main3D.tscn` | 3D 场景入口 |
| `Assets/Art/Models/` | tree / rock / debris 的 GLB + PBR 三贴图（albedo / normal / ORM） |
| `Assets/Art/Terrain3D/` | 6 张群系地面贴图 + 墙板 |
| `Assets/Art/Source3D/` | 50 万面角色模型（0 骨骼 0 动画）+ OBJ + 预览图 |
| `Dev/probe_map3d_full.*` | 3D 地图全量探针与基准出图 |
| `tools/gen_*_3d.py` | 地面/草地贴图生成脚本 |
| `config_snapshot/` | 备份当时的 `project.godot` 与 `Data/config.json` |

## 如何恢复

```bash
# 1) 代码与场景
cp -r Scripts/*      D:/SteamPunkExtraction/Scripts/
cp    Scenes/Main3D.tscn  D:/SteamPunkExtraction/Scenes/
cp -r tools/*        D:/SteamPunkExtraction/tools/
cp -r Dev/*          D:/SteamPunkExtraction/Dev/

# 2) 资产（几百 MB，较慢）
cp -r Assets/Art/Models     D:/SteamPunkExtraction/Assets/Art/
cp -r Assets/Art/Terrain3D  D:/SteamPunkExtraction/Assets/Art/
cp -r Assets/Art/Source3D   D:/SteamPunkExtraction/Assets/Art/

# 3) 配置（按需合并，别整个覆盖 —— 回退后 config 已有 Tiny Swords 相关段落）
python -c "import json,io,collections; d=json.load(io.open('config_snapshot/config.json',encoding='utf-8'),object_pairs_hook=collections.OrderedDict); print(d['render_mode'] if 'render_mode' in d else '见文件')"

# 4) 重新导入
godot --headless --path D:/SteamPunkExtraction --import
```

或者更简单 —— 项目本身全程在 git 管控下，直接用：
```bash
git log --oneline          # 找到 3D 迁移那几个提交
git checkout <commit> -- Scenes/Main3D.tscn Scripts/main3d.gd ...
```

## 校验和

备份时已对每个文件算 MD5（见 `MANIFEST.txt`），可用 `certutil -hashfile <文件> MD5` 核验。
"""


def main() -> int:
    dst_root = sys.argv[1] if len(sys.argv) > 1 else r"D:\import"
    stamp = time.strftime("%Y%m%d")
    dst = os.path.join(dst_root, "map3d_backup_%s" % stamp)
    if os.path.exists(dst):
        stamp = time.strftime("%Y%m%d_%H%M%S")
        dst = os.path.join(dst_root, "map3d_backup_%s" % stamp)
    os.makedirs(dst, exist_ok=True)

    total_bytes = 0
    n_files = 0
    missing = []
    manifest = []

    for src_rel, dst_rel in JOBS:
        src = os.path.join(ROOT, src_rel.replace("/", os.sep))
        target = os.path.join(dst, dst_rel.replace("/", os.sep))
        if not os.path.exists(src):
            missing.append(src_rel)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.isdir(src):
            for dp, _dn, fn in os.walk(src):
                rel = os.path.relpath(dp, src)
                out_dir = target if rel == "." else os.path.join(target, rel)
                os.makedirs(out_dir, exist_ok=True)
                for f in fn:
                    s = os.path.join(dp, f)
                    t = os.path.join(out_dir, f)
                    shutil.copy2(s, t)
                    sz = os.path.getsize(s)
                    total_bytes += sz
                    n_files += 1
                    h = hashlib.md5()
                    with open(s, "rb") as fh:
                        for chunk in iter(lambda: fh.read(1 << 20), b""):
                            h.update(chunk)
                    rel_full = os.path.relpath(t, dst).replace("\\", "/")
                    manifest.append((rel_full, sz, h.hexdigest()))
        else:
            shutil.copy2(src, target)
            sz = os.path.getsize(src)
            total_bytes += sz
            n_files += 1
            h = hashlib.md5()
            with open(src, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
            rel_full = os.path.relpath(target, dst).replace("\\", "/")
            manifest.append((rel_full, sz, h.hexdigest()))

    with open(os.path.join(dst, "README.md"), "w", encoding="utf-8", newline="") as f:
        f.write(README.format(ts=time.strftime("%Y-%m-%d %H:%M:%S")))
    with open(os.path.join(dst, "MANIFEST.txt"), "w", encoding="utf-8", newline="") as f:
        f.write("# path  size(bytes)  md5\n")
        for p, sz, md5 in sorted(manifest):
            f.write("%s  %d  %s\n" % (p, sz, md5))

    print("备份目录：%s" % dst)
    print("文件数：%d   总大小：%.1f MB" % (n_files, total_bytes / 1024 / 1024))
    if missing:
        print("!! 以下源不存在（已跳过）：")
        for m in missing:
            print("   -", m)
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())

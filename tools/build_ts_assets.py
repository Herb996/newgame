#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""build_ts_assets.py — 把 Tiny Swords (Free Pack) 官方素材搬进项目 res://。

【为什么重写】
上一版把 576x384 的官方地形图按 16px 硬抠成横条再拼，破坏了素材的
4x4 blob 描边关系，所以"地图看着跟素材包完全不一样"。本版原则：

  1. 地形图集 **整张原样拷贝**，切片规则交给 Godot 运行时（64px 网格 + blob）；
  2. 单位/装饰按 **帧宽 = 帧高** 的横向序列帧规则切，不再猜帧尺寸；
  3. 输出目录结构与代码里的常量一一对应，改素材只改本文件。

【输出】全部相对 D:\\SteamPunkExtraction\\
  Assets/Art/Tiles/TS/tilemap_color1..5.png   地形（576x384，64px 网格 9x6）
  Assets/Art/Tiles/TS/water_bg.png            水面底色（64x64 可平铺）
  Assets/Art/Sprites/Decor/tree_00..15.png    树（阻挡）
  Assets/Art/Sprites/Decor/stump_00..03.png   树桩（不阻挡）
  Assets/Art/Sprites/Decor/rock_00..03.png    岩石（阻挡，64x64）
  Assets/Art/Sprites/Decor/bush_00..15.png    灌木（不阻挡）
  Assets/Art/Sprites/Decor/pebble_00..15.png  碎石（不阻挡）
  Assets/Art/Sprites/Decor/ore_gold_00..05.png  金矿露头
  Assets/Art/Sprites/Decor/ore_iron_00..02.png  铁矿露头（官方无此素材，由金矿去色派生）
  Assets/Art/Sprites/Decor/ore_oil_00.png      油田（官方无此素材，程序化占位）
  Assets/Art/Sprites/Items/item_*.png         资源点图标
  Assets/Art/Sprites/Units/<unit>/<anim>_NN.png  单位序列帧
  Assets/Art/Sprites/Buildings/*.png          基地建筑

用法：
    python tools/build_ts_assets.py
"""
from __future__ import annotations

import os
import shutil

from PIL import Image

SRC_ROOT = r"D:\SteamPunkExtraction\images\Tiny Swords (Free Pack)"
PROJ = r"D:\SteamPunkExtraction"

TILES_DST = os.path.join(PROJ, "Assets", "Art", "Tiles", "TS")
DECOR_DST = os.path.join(PROJ, "Assets", "Art", "Sprites", "Decor")
ITEM_DST = os.path.join(PROJ, "Assets", "Art", "Sprites", "Items")
UNIT_DST = os.path.join(PROJ, "Assets", "Art", "Sprites", "Units")
BLDG_DST = os.path.join(PROJ, "Assets", "Art", "Sprites", "Buildings")

WRITTEN: list[str] = []


# ---------------------------------------------------------------- helpers
def log(msg: str) -> None:
    print(msg, flush=True)


def _src(*parts: str) -> str:
    return os.path.join(SRC_ROOT, *parts)


def ensure(d: str) -> None:
    os.makedirs(d, exist_ok=True)


def save(img: Image.Image, dst: str) -> None:
    ensure(os.path.dirname(dst))
    img.save(dst)
    WRITTEN.append(dst)


def bbox_of(img: Image.Image):
    """不透明像素包围盒（alpha>8），全透明返回 None。"""
    return img.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()


def copy_file(src: str, dst: str) -> bool:
    if not os.path.exists(src):
        log("  [skip] 缺源: %s" % src)
        return False
    ensure(os.path.dirname(dst))
    shutil.copy2(src, dst)
    WRITTEN.append(dst)
    im = Image.open(dst)
    log("  ok  %-28s %dx%d" % (os.path.basename(dst), im.width, im.height))
    return True


def slice_sheet(src_rel: str, out_dir: str, base: str, want_frames=None,
                frame_w: int | None = None, frame_h: int | None = None,
                start: int = 0) -> list:
    """把横向序列帧切成单帧 PNG。

    帧尺寸默认按"帧宽 = 帧高"推断（Tiny Swords 单位/装饰都是正方形帧）；
    树是 192x256 的例外，必须显式给 frame_w/frame_h。
    want_frames: 只导出的帧下标（None = 全部）。
    start: 输出文件名的起始编号。**必须用它，不要让输出序号跟着源帧下标走**——
           装饰物是"多张源图各取几帧、拼成一条连续变体编号"的：
           tree 用 4 张图各取 [0,2,4,6]，若按源帧下标命名会得到
           tree_00_00/tree_00_02/tree_04_00... 中间编号全断档，运行时按
           tree_00..tree_15 去 load 就会大面积缺失。
    返回导出的路径列表。
    """
    src = _src(src_rel)
    if not os.path.exists(src):
        log("  [skip] 缺源: %s" % src_rel)
        return []
    img = Image.open(src).convert("RGBA")
    fh = frame_h if frame_h else img.height
    fw = frame_w if frame_w else fh
    n = img.width // fw
    if n <= 0:
        log("  [skip] 宽高推断失败: %s (%dx%d)" % (src_rel, img.width, img.height))
        return []
    idxs = range(n) if want_frames is None else [i for i in want_frames if i < n]
    out = []
    for k, i in enumerate(idxs):
        frame = img.crop((i * fw, 0, (i + 1) * fw, fh))
        name = "%s_%02d.png" % (base, start + k)
        dst = os.path.join(out_dir, name)
        save(frame, dst)
        out.append(dst)
    log("  ok  %-28s %d 帧 x %dx%d  <- %s" % (base, len(out), fw, fh, src_rel))
    return out


def tint_metal(img: Image.Image, rgb=(0.62, 0.66, 0.72)) -> Image.Image:
    """把彩色图去色后染成金属灰蓝（用于"铁矿"派生自金矿素材）。"""
    g = img.convert("L").convert("RGBA")
    px = g.load()
    for y in range(g.height):
        for x in range(g.width):
            r, gg, b, a = px[x, y]
            px[x, y] = (int(r * rgb[0]), int(gg * rgb[1]), int(b * rgb[2]), a)
    return g


# ---------------------------------------------------------------- 地形
def build_tiles() -> None:
    log("[terrain] -> " + TILES_DST)
    for i in range(1, 6):
        copy_file(_src("Terrain", "Tileset", "Tilemap_color%d.png" % i),
                  os.path.join(TILES_DST, "tilemap_color%d.png" % i))
    copy_file(_src("Terrain", "Tileset", "Water Background color.png"),
              os.path.join(TILES_DST, "water_bg.png"))
    copy_file(_src("Terrain", "Tileset", "Water Foam.png"),
              os.path.join(TILES_DST, "water_foam.png"))


# ---------------------------------------------------------------- 装饰
def build_decor() -> None:
    log("[decor] -> " + DECOR_DST)
    # 树：Tree1..4 各 8 帧摇摆动画，取 4 个不同相位当作 4 种形态 -> 16 变体
    for i in range(1, 5):
        slice_sheet("Terrain/Resources/Wood/Trees/Tree%d.png" % i, DECOR_DST,
                    "tree", want_frames=[0, 2, 4, 6],
                    frame_w=192, frame_h=256, start=(i - 1) * 4)
    # 树桩（192x256 单帧）
    for i in range(1, 5):
        slice_sheet("Terrain/Resources/Wood/Trees/Stump %d.png" % i, DECOR_DST,
                    "stump", want_frames=[0], frame_w=192, frame_h=256, start=i - 1)
    # 岩石 64x64 单图
    for i in range(1, 5):
        slice_sheet("Terrain/Decorations/Rocks/Rock%d.png" % i, DECOR_DST,
                    "rock", start=i - 1)
    # 灌木 1024x128 -> 8 帧 x 128，取 4 帧
    for i in range(1, 5):
        slice_sheet("Terrain/Decorations/Bushes/Bushe%d.png" % i, DECOR_DST,
                    "bush", want_frames=[0, 2, 4, 6], start=(i - 1) * 4)
    # 碎石（水中礁石）1024x64 -> 16 帧 x 64，取 4 帧
    for i in range(1, 5):
        slice_sheet("Terrain/Decorations/Rocks in the Water/Water Rocks_%02d.png" % i,
                    DECOR_DST, "pebble",
                    want_frames=[0, 4, 8, 12], start=(i - 1) * 4)
    # 金矿露头（128x128 单图）
    for i in range(1, 7):
        slice_sheet("Terrain/Resources/Gold/Gold Stones/Gold Stone %d.png" % i,
                    DECOR_DST, "ore_gold", start=i - 1)
    # 铁矿：官方无此素材 -> 由金矿去色派生（占位，已在缺失清单里标注）
    for k, i in enumerate([2, 4, 6]):
        src = _src("Terrain", "Resources", "Gold", "Gold Stones", "Gold Stone %d.png" % i)
        if os.path.exists(src):
            save(tint_metal(Image.open(src).convert("RGBA")),
                 os.path.join(DECOR_DST, "ore_iron_%02d.png" % k))
    log("  ok  ore_iron_00..02  <- 金矿去色派生（占位）")
    # 油田：官方无此素材 -> 程序化占位（深色油潭 + 反光）
    make_oil_pool(os.path.join(DECOR_DST, "ore_oil_00.png"))


def make_oil_pool(dst: str) -> None:
    n = 128
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    px = img.load()
    cx = cy = n / 2.0
    for y in range(n):
        for x in range(n):
            dx = (x - cx) / (n * 0.44)
            dy = (y - cy) / (n * 0.30)
            d = dx * dx + dy * dy
            if d > 1.0:
                continue
            # 中心亮、边缘暗的油膜，带一点青紫反光
            k = 1.0 - d
            r = int(18 + 46 * k * k)
            g = int(14 + 30 * k * k)
            b = int(22 + 62 * k * k)
            a = int(235 * min(1.0, k * 2.4))
            px[x, y] = (r, g, b, a)
    save(img, dst)
    log("  ok  ore_oil_00.png  <- 程序化占位（缺素材）")


# ---------------------------------------------------------------- 道具
def build_items() -> None:
    log("[items] -> " + ITEM_DST)
    jobs = [
        ("Terrain/Resources/Wood/Wood Resource/Wood Resource.png", "item_wood.png"),
        ("Terrain/Decorations/Rocks/Rock1.png", "item_stone.png"),
        ("Terrain/Resources/Tools/Tool_02.png", "item_iron.png"),
        ("Terrain/Resources/Tools/Tool_01.png", "item_scrap.png"),
        ("Terrain/Resources/Gold/Gold Resource/Gold_Resource.png", "item_gold.png"),
        ("Terrain/Resources/Meat/Meat Resource/Meat Resource.png", "item_food.png"),
        ("Units/Blue Units/Archer/Arrow.png", "item_arrow.png"),
    ]
    for rel, name in jobs:
        src = _src(*rel.split("/"))
        if not os.path.exists(src):
            log("  [skip] 缺源: " + rel)
            continue
        img = Image.open(src).convert("RGBA")
        save(img, os.path.join(ITEM_DST, name))
        log("  ok  %-20s %dx%d" % (name, img.width, img.height))
    # 石油：无对应素材 -> 程序化油桶占位
    make_oil_barrel(os.path.join(ITEM_DST, "item_oil.png"))


def make_oil_barrel(dst: str) -> None:
    n = 64
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    px = img.load()
    for y in range(n):
        for x in range(n):
            dx = (x - n / 2.0) / (n * 0.32)
            dy = (y - n / 2.0) / (n * 0.42)
            d = dx * dx + dy * dy
            if d > 1.0:
                continue
            shade = 1.0 - 0.45 * max(0.0, dx) - 0.12 * dy
            r = int(38 * shade)
            g = int(34 * shade)
            b = int(44 * shade)
            a = 255 if d < 0.86 else int(255 * (1.0 - d) / 0.14)
            px[x, y] = (max(0, r), max(0, g), max(0, b), max(0, min(255, a)))
    # 桶箍
    for yy in (int(n * 0.34), int(n * 0.66)):
        for x in range(n):
            dx = (x - n / 2.0) / (n * 0.32)
            if abs(dx) < 1.0:
                cur = px[x, yy]
                px[x, yy] = (min(255, cur[0] + 34), min(255, cur[1] + 30),
                             min(255, cur[2] + 40), cur[3])
    save(img, dst)
    log("  ok  item_oil.png       <- 程序化占位（缺素材）")


# ---------------------------------------------------------------- 单位
UNIT_JOBS = [
    # (阵营, 兵种, 动画名, 源文件相对路径)
    ("blue", "warrior", "idle", "Units/Blue Units/Warrior/Warrior_Idle.png"),
    ("blue", "warrior", "run", "Units/Blue Units/Warrior/Warrior_Run.png"),
    ("blue", "warrior", "attack1", "Units/Blue Units/Warrior/Warrior_Attack1.png"),
    ("blue", "warrior", "attack2", "Units/Blue Units/Warrior/Warrior_Attack2.png"),
    ("blue", "warrior", "guard", "Units/Blue Units/Warrior/Warrior_Guard.png"),
    ("red", "archer", "idle", "Units/Red Units/Archer/Archer_Idle.png"),
    ("red", "archer", "run", "Units/Red Units/Archer/Archer_Run.png"),
    ("red", "archer", "attack1", "Units/Red Units/Archer/Archer_Shoot.png"),
    ("red", "pawn", "idle", "Units/Red Units/Pawn/Pawn_Idle.png"),
    ("red", "pawn", "run", "Units/Red Units/Pawn/Pawn_Run.png"),
    ("red", "pawn", "attack1", "Units/Red Units/Pawn/Pawn_Interact Knife.png"),
    ("red", "monk", "idle", "Units/Red Units/Monk/Idle.png"),
    ("red", "monk", "run", "Units/Red Units/Monk/Run.png"),
    ("red", "monk", "attack1", "Units/Red Units/Monk/Heal.png"),
    ("yellow", "pawn", "idle", "Units/Yellow Units/Pawn/Pawn_Idle.png"),
    ("yellow", "pawn", "run", "Units/Yellow Units/Pawn/Pawn_Run.png"),
    ("yellow", "pawn", "attack1", "Units/Yellow Units/Pawn/Pawn_Interact Knife.png"),
]


def build_units() -> None:
    log("[units] -> " + UNIT_DST)
    for faction, unit, anim, rel in UNIT_JOBS:
        out_dir = os.path.join(UNIT_DST, "%s_%s" % (faction, unit))
        slice_sheet(rel, out_dir, anim)
    # 中立动物：羊
    for anim, rel in [("idle", "Terrain/Resources/Meat/Sheep/Sheep_Idle.png"),
                      ("run", "Terrain/Resources/Meat/Sheep/Sheep_Move.png"),
                      ("grass", "Terrain/Resources/Meat/Sheep/Sheep_Grass.png")]:
        slice_sheet(rel, os.path.join(UNIT_DST, "sheep"), anim)


# ---------------------------------------------------------------- 建筑
def build_buildings() -> None:
    log("[buildings] -> " + BLDG_DST)
    jobs = [
        ("Buildings/Blue Buildings/House1.png", "house_small.png"),
        ("Buildings/Blue Buildings/House3.png", "house_large.png"),
        ("Buildings/Blue Buildings/Tower.png", "tower.png"),
        ("Buildings/Blue Buildings/Castle.png", "castle.png"),
        ("Buildings/Blue Buildings/Monastery.png", "monastery.png"),
        ("Buildings/Blue Buildings/Barracks.png", "barracks.png"),
        ("Buildings/Blue Buildings/Archery.png", "archery.png"),
        ("Buildings/Red Buildings/Barracks.png", "enemy_barracks.png"),
        ("Terrain/Tileset/Shadow.png", "shadow.png"),
    ]
    for rel, name in jobs:
        copy_file(_src(*rel.split("/")), os.path.join(BLDG_DST, name))


# ---------------------------------------------------------------- main
def main() -> int:
    build_tiles()
    build_decor()
    build_items()
    build_units()
    build_buildings()
    log("--------------------------------------------------")
    log("完成：共写出 %d 个文件" % len(WRITTEN))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

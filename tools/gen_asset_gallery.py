#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""素材实物库扫描器：扫描项目真实 PNG，拼缩略图，产出 docs/assets.json。

    python tools/gen_asset_gallery.py

产出  docs/thumbs/<key>.png   拼片缩略图（透明底棋盘格，像素风最近邻缩放）
      docs/assets.json        清单（供 gen_requirements_html.py 注入页面）

项目搬家后无需改本脚本：路径全部相对脚本自身推导。
"""
import json
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DOCS = ROOT / "docs"
THUMBS = DOCS / "thumbs"

CELL = 192          # 每个素材在拼片里的格子上限
MAX_FILES = 36      # 每张拼片最多几个文件
COLS = 4
BG_A = (238, 229, 210)
BG_B = (248, 242, 228)


# key, 标签, 目录, glob 列表, 备注
GROUPS = [
    ("terrain_tiles", "地形图集 · 5 群系 blob", "Assets/Art/Tiles/TS", ["tilemap_color*.png"], "64px 格 4×4 autotile"),
    ("water", "水面 · 底色+浪花 24 帧", "Assets/Art/Tiles/TS", ["water_bg.png", "water_foam.png"], "foam 尚未接线(A-13)"),
    ("decor_tree", "树 · 16 变体", "Assets/Art/Sprites/Decor", ["tree_*.png"], ""),
    ("decor_rock", "岩石", "Assets/Art/Sprites/Decor", ["rock_*.png"], ""),
    ("decor_stump", "树桩", "Assets/Art/Sprites/Decor", ["stump_*.png"], ""),
    ("decor_bush", "灌木", "Assets/Art/Sprites/Decor", ["bush_*.png"], ""),
    ("decor_pebble", "碎石", "Assets/Art/Sprites/Decor", ["pebble_*.png"], ""),
    ("decor_debris", "残骸堆", "Assets/Art/Sprites/Decor", ["debris*.png"], ""),
    ("ore_gold", "金矿", "Assets/Art/Sprites/Decor", ["ore_gold*.png", "gold_stone*.png"], ""),
    ("ore_iron", "铁矿（金矿染灰 · 占位）", "Assets/Art/Sprites/Decor", ["ore_iron*.png"], "A-07 要替换"),
    ("ore_oil", "油潭（程序糊 · 占位）", "Assets/Art/Sprites/Decor", ["ore_oil*.png"], "A-08 要替换"),
    ("items", "道具图标 · 8 种", "Assets/Art/Sprites/Items", ["*.png"], "oil 为程序画 A-09"),
    ("units_blue_warrior", "蓝战士 blue_warrior", "Assets/Art/Sprites/Units/blue_warrior", ["*.png"], "玩家顶替形象"),
    ("units_blue_archer", "蓝弓手 blue_archer", "Assets/Art/Sprites/Units/blue_archer", ["*.png"], "未用"),
    ("units_blue_lancer", "蓝枪兵 blue_lancer", "Assets/Art/Sprites/Units/blue_lancer", ["*.png"], "未用"),
    ("units_red_pawn", "红小兵（劫掠者）", "Assets/Art/Sprites/Units/red_pawn", ["*.png"], "敌人顶替"),
    ("units_red_archer", "红弓手", "Assets/Art/Sprites/Units/red_archer", ["*.png"], "敌人顶替"),
    ("units_red_monk", "红僧（邪术师）", "Assets/Art/Sprites/Units/red_monk", ["*.png"], "敌人顶替"),
    ("units_yellow_pawn", "黄小兵（掠夺者）", "Assets/Art/Sprites/Units/yellow_pawn", ["*.png"], "敌人顶替"),
    ("units_sheep", "羊（中立动物）", "Assets/Art/Sprites/Units/sheep", ["*.png"], ""),
    ("buildings", "建筑 · 9 种", "Assets/Art/Sprites/Buildings", ["*.png"], "基地借用(A-17)"),
    ("player_ts", "玩家 TS 帧 · 四向", "Assets/Art/Sprites/PlayerTS", ["*.png"], "idle/walk 四向已做"),
    ("player_legacy", "玩家旧帧", "Assets/Art/Sprites/Player", ["*.png"], ""),
    ("player_hd", "玩家 HD 帧", "Assets/Art/Sprites/PlayerHD", ["*.png"], ""),
    ("raw_enemies", "旧怪物原画（蒸汽朋克 · 作废）", "Assets/Art/Raw/Enemies", ["*.png"], "A-19 方向已改"),
    ("raw_playerhd", "玩家原画 + 抠图", "Assets/Art/Raw/PlayerHD", ["*.png", "matted/*.png"], ""),
    ("raw_terrain", "地形纹理原画", "Assets/Art/Raw/Terrain", ["*.png"], ""),
    ("raw_decor", "装饰原画", "Assets/Art/Raw/Decor", ["*.png"], ""),
    ("source3d", "3D 源预览", "Assets/Art/Source3D", ["*.png", "Probe/*.png"], ""),
    ("ts_ui", "TinySwords UI 参考包", "images/Tiny Swords (Free Pack)/UI Elements/UI Elements", ["Icons/*.png", "Bars/*.png"], "A-20/21 可借风格"),
]


def collect(dir_path: Path, patterns):
    files = []
    for pat in patterns:
        files += sorted(dir_path.glob(pat))
    return files


def scale_to(img: Image.Image, cell: int) -> Image.Image:
    w, h = img.size
    s = min(cell / w, cell / h, 1.0) if max(w, h) > cell else min(cell / w, cell / h)
    s = min(s, 1.0)
    return img.resize((max(1, round(w * s)), max(1, round(h * s))), Image.NEAREST)


def montage(files, out: Path):
    imgs = []
    for f in files[:MAX_FILES]:
        try:
            im = Image.open(f).convert("RGBA")
        except Exception:
            continue
        imgs.append((f.stem, scale_to(im, CELL)))
    if not imgs:
        return False
    cols = min(COLS, len(imgs))
    rows = (len(imgs) + cols - 1) // cols
    cw = max(im.size[0] for _, im in imgs) + 8
    ch = max(im.size[1] for _, im in imgs) + 8
    sheet = Image.new("RGBA", (cols * cw, rows * ch), (0, 0, 0, 0))
    d = ImageDraw.Draw(sheet)
    for r in range(rows):
        for c in range(cols):
            x0, y0 = c * cw, r * ch
            for by in range(0, ch, 8):
                for bx in range(0, cw, 8):
                    col = BG_A if ((bx + by) // 8 + r + c) % 2 == 0 else BG_B
                    d.rectangle([x0 + bx, y0 + by, x0 + bx + 7, y0 + by + 7], fill=col)
    for idx, (name, im) in enumerate(imgs):
        r, c = divmod(idx, cols)
        x = c * cw + (cw - im.size[0]) // 2
        y = r * ch + (ch - im.size[1]) // 2
        sheet.alpha_composite(im, (x, y))
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    return True


def main():
    THUMBS.mkdir(exist_ok=True)
    entries = []
    for key, label, rel, patterns, note in GROUPS:
        d = ROOT / rel
        files = collect(d, patterns) if d.exists() else []
        thumb = THUMBS / f"{key}.png"
        ok = montage(files, thumb) if files else False
        entries.append({
            "key": key, "label": label, "dir": rel, "note": note,
            "count": len(files),
            "thumb": f"thumbs/{key}.png" if ok else None,
            "files": [f.name for f in files[:MAX_FILES]],
        })
        print(f"  {key:22s} {len(files):4d} 张  {'OK' if ok else '--'}")
    (DOCS / "assets.json").write_text(
        json.dumps({"assets": entries}, ensure_ascii=False, indent=1), encoding="utf-8")
    print("OK  docs/assets.json + docs/thumbs/")


if __name__ == "__main__":
    main()

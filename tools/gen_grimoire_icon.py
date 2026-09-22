# -*- coding: utf-8 -*-
"""画一张魔法书图标：Assets/Art/Sprites/Items/item_grimoire.png

为什么手写而不是从素材包里切：Tiny Swords 官方那套没有书，PixelHoly 包里全是
特效帧（SwordOfJustice 是剑、HolyNova 是爆炸圈），硬切出来不像"可拾取的道具"。
所以按同一套配色（描边 #161c2e + 紫 #904e7c/#b45076 + 金 #cea554/#e9f044 +
羊皮纸 #efe1ab/#d5b583，都是从 item_food/item_gold 的实色直方图里取的）画一张。

16×16 逻辑像素 × 4 = 64×64，和 Items 目录里其余道具一个尺寸。
用法：python tools/gen_grimoire_icon.py
"""
import io
import os
import sys

from PIL import Image

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(PROJ, "Assets", "Art", "Sprites", "Items", "item_grimoire.png")
PX = 4                      # 逻辑像素 → 实际像素
TRANSPARENT = (0, 0, 0, 0)

OUTLINE = (0x16, 0x1c, 0x2e, 255)   # 全项目共用描边
SPINE = (0x6c, 0x37, 0x5c, 255)     # 书脊：深一档的紫
COVER = (0x90, 0x4e, 0x7c, 255)     # 封面主色（item_food 里就有）
COVER_HI = (0xb4, 0x50, 0x76, 255)  # 封面受光
PAGE = (0xef, 0xe1, 0xab, 255)      # 书页
PAGE_SHADE = (0xd5, 0xb5, 0x83, 255)
GOLD = (0xce, 0xa5, 0x54, 255)      # 铜扣
GOLD_HI = (0xe9, 0xf0, 0x44, 255)   # 扣上高光


def main() -> int:
    g = Image.new("RGBA", (16, 16), TRANSPARENT)
    p = g.load()

    def put(x: int, y: int, col) -> None:
        if 0 <= x < 16 and 0 <= y < 16:
            p[x, y] = col

    # 摊开一本厚书：左边书脊、中间封面、右边书页的侧面
    x0, x1 = 2, 13           # 整本书的横向范围
    y0, y1 = 3, 12           # 纵向范围
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if x == x0 or x == x1 or y == y0 or y == y1:
                col = OUTLINE
            elif x <= x0 + 1:
                col = SPINE
            elif x >= x1 - 2:
                # 书页：最外那页永远压暗，往里每三行一道接缝 —— 读出"一叠纸"
                col = PAGE_SHADE if x == x1 - 1 or y % 3 == 0 else PAGE
            else:
                col = COVER
            put(x, y, col)
    # 封面上半受光一条，书才有厚度而不是一个色块
    for x in range(x0 + 2, x1 - 2):
        put(x, y0 + 1, COVER_HI)
    # 中央的金色法阵：竖着的菱形，缩到 40px 也认得出"这是本魔法书"
    cx, cy = 8, 8
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            if abs(dx) + abs(dy) <= 2:
                put(cx + dx, cy + dy, GOLD)
    put(cx, cy, GOLD_HI)
    # 书脊上的两道铜箍 + 封面四角的铜钉
    for y in (y0 + 2, y1 - 2):
        put(x0 + 1, y, GOLD)
    for x in (x0 + 2, x1 - 3):
        for y in (y0 + 1, y1 - 1):
            put(x, y, GOLD)

    big = g.resize((16 * PX, 16 * PX), Image.NEAREST)
    d = os.path.dirname(OUT)
    os.makedirs(d, exist_ok=True)
    big.save(OUT)
    preview = os.path.join(os.environ.get("WB_LOG_DIR",
            "C:/Users/Administrator/WorkBuddy/2026-09-15-23-06-42"), "_grimoire_preview.png")
    g.resize((16 * 16, 16 * 16), Image.NEAREST).save(preview)
    print("wrote %s %s" % (OUT, big.size))
    print("preview %s" % preview)
    return 0


if __name__ == "__main__":
    sys.exit(main())

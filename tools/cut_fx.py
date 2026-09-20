# -*- coding: utf-8 -*-
"""tools/cut_fx.py —— 从 RPG Effect All Free 总表里切出特效横条，导入 Assets/Art/Sprites/FX/。

素材表结构（2026-09-20 实测，见 docs/fx_library.md 第五节的更正）：
  * **格 64x64**（清单里写的 32 是错的），表高恒 576 = 9 行 => 行 = 9 种配色
  * 表宽 768~1152 = 12~18 列 => 列 = 动画帧，右侧常有 1~2 列是空的
  * 配色行**大致的**顺序：0 橙 / 1 粉 / 2 蓝 / 3 绿 / 4 棕橙 / 5 白 / 6 土黄 / 7 红 / 8 紫。
    **别照这个表猜行号**：2026-09-20 拼 contact sheet 实测，同一个行号在不同表里能差很远
    （row6 在 Part 23 上是淡紫、在 Part 17 上是土黄）。选完行要用 tools/sheet_fx.py 看图确认。

输出约定（一次切完就不再动）：
  * 每个特效 = **一张横条 PNG**（选中那一行的若干帧，横向排开），不是逐帧文件
  * **2 倍整数放大**（64 -> 128 格），保持像素画不糊；运行时 Sprite2D.hframes 直接除
  * 每格保留完整 128x128（**不裁内容包围盒**）—— 裁了帧中心会漂，动画会抖
  * 帧数由"这一格有没有像素"自动定：连续非空的前缀，尾部空帧丢掉

用法：
    python tools/cut_fx.py            # 按下面 JOBS 切
    python tools/cut_fx.py --dry      # 只打印每格占用情况，不写文件
"""
import json
import os
import sys

from PIL import Image

SRC_ROOT = r"C:\Users\Administrator\Downloads\特效\_extracted\RPG Effect All Free\Free"
DST = r"D:\SteamPunkExtraction\Assets\Art\Sprites\FX"
CELL = 64
ZOOM = 2
ALPHA_MIN = 3          # 一格里非透明像素少于这个数就算空帧（抗压缩噪点）

# (输出名, Part, 编号, 配色行, 一句话用途)
JOBS = [
    ("slash_sword",   33, 1617, 5, "剑士：素面粗厚弯月弧，白/钢色"),
    ("thrust_spear",  28, 1350, 5, "枪手：右指长锥带环纹，白/钢色"),
    ("cast_staff",    32, 1575, 2, "僧侣：同心双环内套旋纹球，蓝色"),
    ("spark_arrow",   33, 1637, 0, "弓兵命中：饱满四芒星带亮心，橙"),
    ("spark_hit",     32, 1585, 5, "通用受击：粗射线八芒星爆发，白"),
    ("slash_claw",    33, 1616, 7, "敌人近战：带尖刺毛边的月牙弧，红"),
    ("cast_hex",      29, 1425, 8, "萨满：四扇叶旋成圆形法阵环，紫"),
    ("puff_dust",     31, 1527, 6, "落地/爆尘：放射点状扩散碎圈，土黄"),
    # ---- 2026-09-20 第二批：15 个兵种出手 + 5 个武器命中，全部走现成挂点 ----
    ("slash_bite",    27, 1349, 3, "蛇：锯齿边半圆弧带扫成钩，绿"),
    ("spit_web",      23, 1122, 5, "蜘蛛：点环收拢成尖刺缠环，白"),
    ("slam_ring",     23, 1114, 6, "巨龟：粗圆环胀成齿瓣边环，土黄"),
    ("burst_charge",  20, 975,  4, "野猪：颗粒方块裂成四臂飞散，棕橙"),
    ("slash_rend",    19, 935,  4, "豺狼人：实心月牙炸成放射短条，棕橙"),
    ("spike_bone",    25, 1227, 5, "骷髅：六角尖星胀缩外溅点，白"),
    ("bash_rock",     23, 1121, 4, "洞穴兽：圆角三角块碎成斜散片，棕橙"),
    ("slash_shadow",  21, 1012, 8, "盗贼：尖刃旋转收成细虚弧，紫"),
    ("thrust_harpoon",25, 1224, 5, "鱼叉鲨：尖锐斜向菱形刃片，白/钢色"),
    ("splash_bomb",   23, 1112, 2, "炸弹鱼：实心圆团胀成多瓣花环，蓝"),
    ("sweep_fin",     21, 1013, 2, "桨鲨：碗形宽月牙边缘散成点，蓝"),
    ("slash_sabre",   26, 1271, 0, "猪骑兵：锯齿弯刀状弧旋点环，橙"),
    ("shred_bolt",    16, 778,  1, "侏儒：箭簇碎屑横向飞散铺开，粉"),
    ("slam_paw",      21, 1020, 5, "熊猫：粗月牙两端卷钩再收窄，白"),
    ("slash_tail",    17, 825,  6, "蜥蜴：梳齿扇形月牙向右渐缩，土黄"),
    ("hit_sword",     25, 1226, 7, "剑命中：四叶X十字胀开成尖刺，红"),
    ("hit_pierce",    16, 766,  5, "枪命中：放射尖刺星配点状外环，白"),
    ("hit_holy",      23, 1113, 2, "杖命中：四角菱星胀成十字花框，蓝"),
    ("hit_arrow",     32, 1583, 7, "弓命中：放射尖刺圆球渐点散，红"),
]


def sheet_path(part, num):
    return os.path.join(SRC_ROOT, "Part %d" % part, "%d.png" % num)


def cell_used(im, px, col, row):
    n = 0
    x0, y0 = col * CELL, row * CELL
    for y in range(y0, y0 + CELL):
        for x in range(x0, x0 + CELL):
            if px[x, y][3] > ALPHA_MIN:
                n += 1
                if n >= ALPHA_MIN:
                    return True
    return False


def frame_count(im, row, max_cols):
    px = im.load()
    used = 0
    for c in range(max_cols):
        if cell_used(im, px, c, row):
            used = c + 1
        elif c - used >= 2:          # 连续两格空 => 认为后面没有了
            break
    return used


def main():
    dry = "--dry" in sys.argv
    if not dry:
        os.makedirs(DST, exist_ok=True)
    manifest = {}
    for name, part, num, row, desc in JOBS:
        p = sheet_path(part, num)
        if not os.path.exists(p):
            print("!! MISSING %s" % p)
            continue
        im = Image.open(p).convert("RGBA")
        cols = im.size[0] // CELL
        n = frame_count(im, row, cols)
        print("%-13s P%d-%d row%d  %2d 帧 / %d 列  %s" % (name, part, num, row, n, cols, desc))
        if dry:
            continue
        strip = Image.new("RGBA", (n * CELL * ZOOM, CELL * ZOOM), (0, 0, 0, 0))
        for c in range(n):
            box = (c * CELL, row * CELL, (c + 1) * CELL, (row + 1) * CELL)
            cell = im.crop(box).resize((CELL * ZOOM, CELL * ZOOM), Image.NEAREST)
            strip.paste(cell, (c * CELL * ZOOM, 0))
        out = os.path.join(DST, "%s.png" % name)
        strip.save(out)
        manifest[name] = {"texture": "res://Assets/Art/Sprites/FX/%s.png" % name,
                          "frames": n, "cell_px": CELL * ZOOM}
    if not dry:
        print(json.dumps(manifest, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()

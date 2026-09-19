# -*- coding: utf-8 -*-
"""把 Tiny Swords 的 UI 切片表预处理成 Godot 可直接用的九宫格贴图。

这些 PNG 是「3x3 块、块与块之间留透明间隔」的交付格式，直接整张贴进
StyleBoxTexture 会把间隔也拉伸出来。这里按 alpha 投影找到每行/列的内容带，
把 9 块裁出来无缝拼合，存进 Assets/Art/UI/tsui/ 供 ui_kit.gd 加载。
"""
import os
from PIL import Image

SRC = r"D:\SteamPunkExtraction\images\Tiny Swords (Free Pack)\UI Elements\UI Elements"
DST = r"D:\SteamPunkExtraction\Assets\Art\UI\tsui"


def bands(proj, min_gap=2, min_run=6):
    """alpha 投影 -> 内容区间的 [(start,end), ...]"""
    on = [v > 8 for v in proj]
    out = []
    i = 0
    n = len(on)
    while i < n:
        if on[i]:
            j = i
            gap = 0
            while j < n:
                if on[j]:
                    j += 1
                    gap = 0
                elif gap < min_gap:
                    j += 1
                    gap += 1
                else:
                    break
            if j - i - gap >= min_run:
                out.append((i, j - gap))
            i = j
        else:
            i += 1
    return out


def _proj_x(im):
    a = im.getchannel("A")
    return [max(a.getpixel((x, y)) for y in range(im.height)) for x in range(im.width)]


def _proj_y(im):
    a = im.getchannel("A")
    return [max(a.getpixel((x, y)) for x in range(im.width)) for y in range(im.height)]


def compose9(im, name=""):
    """带间隔的 3x3 / 3x1 切片表 -> 无缝九宫格。
    切片原本是连续大图裁开后拉开间距摆的：把每块按原位「平移回去」
    （减掉前方累计空隙宽）就能精确复原，不做任何对齐猜测。"""
    bx = bands(_proj_x(im))
    by = bands(_proj_y(im))
    if len(bx) != 3 or len(by) not in (1, 3):
        print("  !! %s bands x=%s y=%s" % (name, bx, by))
        return None
    out = Image.new("RGBA", (im.width - sum(bx[i + 1][0] - bx[i][1] for i in range(2)),
                             im.height - sum(by[i + 1][0] - by[i][1] for i in range(len(by) - 1))),
                    (0, 0, 0, 0))
    shifts_x = [0]
    for i in range(2):
        shifts_x.append(shifts_x[-1] + bx[i + 1][0] - bx[i][1])
    shifts_y = [0]
    for i in range(len(by) - 1):
        shifts_y.append(shifts_y[-1] + by[i + 1][0] - by[i][1])
    for y0, sy in zip(by, shifts_y):
        for x0, sx in zip(bx, shifts_x):
            t = im.crop((x0[0], y0[0], x0[1], y0[1]))
            out.paste(t, (x0[0] - sx, y0[0] - sy), t)
    return out


def recolor_hue(im, target_hue):
    """把红色系像素换成蓝青色系（进度条 Fill 是红的，蓝色主题需要换色）"""
    out = im.copy()
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            mx, mn = max(r, g, b), min(r, g, b)
            if mx == 0 or mx - mn < 30:
                continue
            # 红色判定：r 明显高于 g/b
            if r > g + 20 and r > b + 20:
                t = (mx - mn) / mx
                px[x, y] = (int(mn + t * (target_hue[0] - mn)),
                            int(mn + t * (target_hue[1] - mn)),
                            int(mn + t * (target_hue[2] - mn)), a)
    return out


def save(im, name):
    os.makedirs(DST, exist_ok=True)
    im.save(os.path.join(DST, name))
    print(name, im.size)


def main():
    # 面板底：木桌九宫格
    save(compose9(Image.open(os.path.join(SRC, "Wood Table/WoodTable.png")).convert("RGBA"), "wood"),
         "wood_panel.png")
    # 主按钮：大蓝按钮 普通/按下
    save(compose9(Image.open(os.path.join(SRC, "Buttons/BigBlueButton_Regular.png")).convert("RGBA")),
         "btn_blue.png")
    save(compose9(Image.open(os.path.join(SRC, "Buttons/BigBlueButton_Pressed.png")).convert("RGBA")),
         "btn_blue_pressed.png")
    # 纸面：内容区羊皮纸
    save(compose9(Image.open(os.path.join(SRC, "Papers/RegularPaper.png")).convert("RGBA")),
         "paper.png")
    save(compose9(Image.open(os.path.join(SRC, "Papers/SpecialPaper.png")).convert("RGBA")),
         "paper_dark.png")
    # 小按钮：单张直接拷
    Image.open(os.path.join(SRC, "Buttons/SmallBlueSquareButton_Regular.png")).convert("RGBA") \
        .save(os.path.join(DST, "btn_small.png"))
    Image.open(os.path.join(SRC, "Buttons/SmallBlueSquareButton_Pressed.png")).convert("RGBA") \
        .save(os.path.join(DST, "btn_small_pressed.png"))
    Image.open(os.path.join(SRC, "Buttons/TinyRoundBlueButton.png")).convert("RGBA") \
        .save(os.path.join(DST, "grabber.png"))
    Image.open(os.path.join(SRC, "Banners/Banner.png")).convert("RGBA") \
        .save(os.path.join(DST, "banner.png"))
    # 标题卷轴
    # 滑条：底槽九宫格；填充原为红色，换成按钮同款蓝青
    save(compose9(Image.open(os.path.join(SRC, "Bars/SmallBar_Base.png")).convert("RGBA")),
         "bar_base.png")
    fill = Image.open(os.path.join(SRC, "Bars/BigBar_Fill.png")).convert("RGBA")
    save(recolor_hue(fill, (58, 150, 168)), "bar_fill.png")
    # 复选框：小蓝方块 勾选/未勾选（勾选态画一个白勾）
    sq = Image.open(os.path.join(SRC, "Buttons/TinySquareBlueButton.png")).convert("RGBA")
    sq.save(os.path.join(DST, "check_off.png"))
    on = sq.copy()
    d = on.load()
    w, h = on.size
    for i in range(10):  # 白色对勾
        for dx, dy in ((0, 0), (1, 0)):
            x, y = 18 + i * 2 + dx, 34 - i * 2 + dy
            if 0 <= x < w and 0 <= y < h:
                d[x, y] = (255, 255, 255, 255)
                d[x, y + 1] = (230, 230, 230, 255)
    for i in range(16):
        for dx, dy in ((0, 0), (1, 0)):
            x, y = 36 + i * 2 + dx, 16 + i * 2 + dy
            if 0 <= x < w and 0 <= y < h:
                d[x, y] = (255, 255, 255, 255)
                d[x, y + 1] = (230, 230, 230, 255)
    on.save(os.path.join(DST, "check_on.png"))

    # 背景木纹：整块实木板裁掉圆角边，供菜单背景平铺（ui_kit.wood_backdrop）
    wood = Image.open(os.path.join(SRC, "Wood Table/WoodTable_Slots.png")).convert("RGBA")
    save(wood.crop((20, 20, wood.width - 20, wood.height - 20)), "wood_tile.png")

    # 菜单背景软石板：paper_dark 中心无框区 + 轻模糊（tiled_backdrop 平铺用）
    slate = Image.open(os.path.join(DST, "paper_dark.png")).convert("RGBA")
    soft = slate.crop((52, 52, slate.width - 52, slate.height - 52)).filter(
            ImageFilter.GaussianBlur(1.5))
    save(soft, "slate_tile.png")
    print("done")


if __name__ == "__main__":
    main()

"""把参考图里的独立建筑抠出来（纯 PIL，无 numpy）。
用途：给主基地做风格验证的一次性素材，不是最终美术。"""
from PIL import Image, ImageDraw, ImageFont
import os, sys
from collections import deque

SRC = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(SRC, "cut")
os.makedirs(OUT, exist_ok=True)


def key_out(path, tol, min_area):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    # 背景色 = 四角 8x8 中位数近似（取均值）
    samples = []
    for cx, cy in [(0, 0), (w - 8, 0), (0, h - 8), (w - 8, h - 8)]:
        for yy in range(cy, min(cy + 8, h)):
            for xx in range(cx, min(cx + 8, w)):
                samples.append(px[xx, yy])
    bg = tuple(sum(s[i] for s in samples) // len(samples) for i in range(3))

    mask = bytearray(w * h)
    for y in range(h):
        base = y * w
        for x in range(w):
            r, g, b = px[x, y]
            d = abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2])
            mask[base + x] = 1 if d > tol else 0
    return im, mask, bg, w, h


def components(mask, w, h, min_area):
    seen = bytearray(w * h)
    comps = []
    for start in range(w * h):
        if mask[start] != 1 or seen[start]:
            continue
        q = deque([start])
        seen[start] = 1
        minx = maxx = start % w
        miny = maxy = start // w
        n = 0
        while q:
            i = q.popleft()
            n += 1
            x = i % w
            y = i // w
            if x < minx: minx = x
            if x > maxx: maxx = x
            if y < miny: miny = y
            if y > maxy: maxy = y
            for dy in (-1, 0, 1):
                ny = y + dy
                if ny < 0 or ny >= h: continue
                for dx in (-1, 0, 1):
                    nx = x + dx
                    if nx < 0 or nx >= w: continue
                    j = ny * w + nx
                    if mask[j] and not seen[j]:
                        seen[j] = 1
                        q.append(j)
        if n >= min_area:
            comps.append((minx, miny, maxx, maxy, n))
    comps.sort(key=lambda c: (c[1] // 60, c[0]))
    return comps


def export(im, mask, w, h, box, path, pad=2):
    x0, y0, x1, y1 = box
    x0 = max(0, x0 - pad); y0 = max(0, y0 - pad)
    x1 = min(w - 1, x1 + pad); y1 = min(h - 1, y1 + pad)
    crop = im.crop((x0, y0, x1 + 1, y1 + 1)).convert("RGBA")
    cp = crop.load()
    for yy in range(crop.height):
        for xx in range(crop.width):
            if not mask[(y0 + yy) * w + (x0 + xx)]:
                cp[xx, yy] = (0, 0, 0, 0)
    crop.save(path)
    return crop.size


def main():
    report = []
    # ref1 自带 alpha，直接抄
    r1 = Image.open(os.path.join(SRC, "ref1.png")).convert("RGBA")
    r1.save(os.path.join(OUT, "s1_00.png"))
    report.append(("ref1", "s1_00", r1.size))

    for name, tol, min_area in [("ref2", 60, 900), ("ref3", 46, 900)]:
        im, mask, bg, w, h = key_out(os.path.join(SRC, name + ".jpg"), tol, min_area)
        comps = components(mask, w, h, min_area)
        print("%s bg=%s 组件=%d" % (name, bg, len(comps)))
        for i, (x0, y0, x1, y1, n) in enumerate(comps):
            if (x1 - x0) < 24 or (y1 - y0) < 24:
                continue
            tag = "%s_%02d" % (name, i)
            size = export(im, mask, w, h, (x0, y0, x1, y1), os.path.join(OUT, tag + ".png"))
            report.append((name, tag, size))
            print("  %-10s box=(%3d,%3d,%3d,%3d) px=%6d out=%s" % (tag, x0, y0, x1, y1, n, size))

    # 缩略图墙，方便一眼数清
    files = sorted(f for f in os.listdir(OUT) if f.endswith(".png"))
    cols = 6
    cell = 200
    rows = (len(files) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cell, rows * (cell + 16)), (24, 24, 28, 255))
    d = ImageDraw.Draw(sheet)
    for idx, f in enumerate(files):
        t = Image.open(os.path.join(OUT, f)).convert("RGBA")
        k = min((cell - 8) / t.width, (cell - 8) / t.height)
        t = t.resize((max(1, int(t.width * k)), max(1, int(t.height * k))))
        ox = (idx % cols) * cell + 4
        oy = (idx // cols) * (cell + 16) + 16
        sheet.alpha_composite(t, (ox, oy))
        d.text((ox, oy - 14), f[:-4], fill=(230, 230, 230, 255))
    sheet.save(os.path.join(SRC, "sheet_montage.png"))
    print("montage -> sheet_montage.png  (%d 张)" % len(files))


main()

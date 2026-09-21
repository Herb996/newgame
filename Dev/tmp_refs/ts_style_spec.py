"""量化 Tiny Swords 建筑素材的风格规格：色板 / 明度饱和 / 描边 / 画布占比 / 阴影。
纯 PIL。用途：给重画的新建筑定一份可对齐的规格，不是运行时依赖。"""
from PIL import Image
import glob, os, colorsys, collections

ROOT = "D:/SteamPunkExtraction/Assets/Art/Sprites/Buildings/"


def stats(path):
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    px = im.load()
    opaque = []
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a > 200:
                opaque.append((x, y, (r, g, b)))
    if not opaque:
        return None
    xs = [p[0] for p in opaque]
    ys = [p[1] for p in opaque]
    bw, bh = max(xs) - min(xs) + 1, max(ys) - min(ys) + 1
    hsv = [colorsys.rgb_to_hsv(*(c / 255.0 for c in p[2])) for p in opaque]
    vs = sorted(v for _, _, v in hsv)
    ss = sorted(s for s, _, _ in hsv)
    n = len(opaque)
    # 主色：把色相/明度/饱和各量化到 5 档后统计
    buckets = collections.Counter()
    for (r, g, b), (hh, ss_, vv) in zip([p[2] for p in opaque], hsv):
        buckets[(r // 40, g // 40, b // 40)] += 1
    top = buckets.most_common(6)
    # 描边：轮廓像素（不透明且上方 6px 外是透明）的平均亮度 vs 整体
    edge = []
    eset = set((x, y) for x, y, _ in opaque)
    for x, y, c in opaque:
        if (x, y - 6) not in eset:
            edge.append(sum(c) / 3.0)
    return {
        "file": os.path.basename(path), "size": (w, h),
        "bbox": (min(xs), min(ys), bw, bh),
        "fill_w": round(bw / w, 2), "fill_h": round(bh / h, 2),
        "alpha_px": n, "opaque_px": len(opaque),
        "v_med": round(vs[n // 2], 2), "v_p10": round(vs[n // 10], 2), "v_p90": round(vs[9 * n // 10], 2),
        "s_med": round(ss[n // 2], 2), "s_p90": round(ss[9 * n // 10], 2),
        "edge_v": round(sum(edge) / max(1, len(edge)) / 255.0, 2),
        "top": [(f"#{r*40:02x}{g*40:02x}{b*40:02x}", c) for (r, g, b), c in top],
    }


rows = []
for p in sorted(glob.glob(ROOT + "blue_*.png")):
    s = stats(p)
    if s:
        rows.append(s)

print("%-22s %-11s %-18s %5s %5s  V(p10/med/p90)   S(med/p90)  edgeV" %
      ("file", "size", "bbox", "fW", "fH"))
for s in rows:
    print("%-22s %-11s %-18s %5.2f %5.2f  %.2f %.2f %.2f      %.2f %.2f     %.2f" % (
        s["file"], str(s["size"]), str(s["bbox"]), s["fill_w"], s["fill_h"],
        s["v_p10"], s["v_med"], s["v_p90"], s["s_med"], s["s_p90"], s["edge_v"]))

print("\n=== 主色板（各图 top6，按出现次数）===")
for s in rows:
    print("%-22s %s" % (s["file"], "  ".join("%s:%d" % t for t in s["top"])))

# 汇总全局色板
g = collections.Counter()
for s in rows:
    for c, n in s["top"]:
        g[c] += n
print("\n=== 全局高频色 top 20 ===")
for c, n in g.most_common(20):
    print(c, n)

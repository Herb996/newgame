# -*- coding: utf-8 -*-
"""
装饰物抠图（最终版）：按素材实际背景类型走两条通道。

素材背景实测：
  * 树 / 残骸（Decor1）  —— 纯白 / 浅灰白底，物件本身极暗，用「最暗通道亮度
    软阈值」最稳；难点是树冠把部分白底包围，连通域填充传不进去（v1 留白斑），
    所以这里不做连通性判断，直接全局按亮度切。
  * 石头（Decor1）       —— 背景是浅灰渐变 + 投影，与青灰石头对比度太低，
    亮度阈值抠不干净（实测背景最暗通道 207~245，与石头的 190 太近）。
    改用 image-to-image 只替换背景为纯品红后的 Decor3 版本，做 chroma key。

另外：
  * 包围盒不能用 getbbox()（残留低 alpha 像素会把 1024x1024 全算进去），
    改用「最暗通道 < 190」的主体掩码求范围；
  * 品红版右下角有工具水印，抠图后直接在右下角区域清零 alpha（那里只有背景）。
"""
import os
import numpy as np
from PIL import Image, ImageFilter

OUT = r"D:/SteamPunkExtraction/Assets/Art/Sprites/Decor"
os.makedirs(OUT, exist_ok=True)

D1 = r"D:/SteamPunkExtraction/Assets/Art/Raw/Decor"
D3 = r"D:/SteamPunkExtraction/Assets/Art/Raw/Decor3"

# name, path, method, target, axis, param
JOBS = [
    ("tree", os.path.join(D1, "A_single_dead_steampunk_tree___2026-09-14T23-35-38.png"),
     "luma", 36, "h", 204),
    ("rock", os.path.join(D3, "Keep_the_rock_cluster_exactly__2026-09-14T23-39-20.png"),
     "chroma", 30, "w", 110.0),
    ("debris", os.path.join(D1, "A_small_pile_of_steampunk_mech_2026-09-14T23-35-45.png"),
     "luma", 26, "w", 204),
]
LUMA_FALLOFF = 2.0     # 亮度过渡带宽度（近似硬阈值）
MAIN_MASK = 190        # 求包围盒用的主体判定：最暗通道 < 该值


def cut_luma(rgb, thresh):
    minch = rgb.min(axis=2)
    bgness = np.clip((minch - thresh) / LUMA_FALLOFF, 0.0, 1.0)
    return (1.0 - bgness) * 255.0


def cut_chroma(rgb, tol):
    ref = np.median(rgb[:40, :40].reshape(-1, 3), axis=0)
    dist = np.sqrt(((rgb - ref) ** 2).sum(axis=2))
    return np.clip((dist - tol) / 35.0, 0.0, 1.0) * 255.0, ref


def despill(rgb, alpha, ref):
    """把物体边缘残留的背景色溢出压掉（品红：压低 R/B；灰白：压低整体亮度）。"""
    out = rgb.copy()
    edge = (alpha > 0) & (alpha < 250)
    if ref[0] > 180 and ref[2] > 180 and ref[1] < 120:      # 品红背景
        cap = np.minimum(out[..., 1] + 50.0, 255.0)
        out[..., 0] = np.where(edge, np.minimum(out[..., 0], cap), out[..., 0])
        out[..., 2] = np.where(edge, np.minimum(out[..., 2], cap), out[..., 2])
    return out


def fit(im, target, axis):
    w, h = im.size
    s = target / float(h if axis == "h" else w)
    im = im.resize((max(1, int(round(w * s))), max(1, int(round(h * s)))), Image.LANCZOS)
    return im.filter(ImageFilter.UnsharpMask(radius=1.2, percent=70, threshold=2))


results = []
for name, path, method, target, axis, param in JOBS:
    print("[%s] %s" % (name, os.path.basename(path)[:46]))
    rgb = np.asarray(Image.open(path).convert("RGB")).astype(np.float32)
    ref = np.array([255.0, 255.0, 255.0])
    if method == "luma":
        alpha = cut_luma(rgb, param)
    else:
        alpha, ref = cut_chroma(rgb, param)
        print("   背景参考色:", tuple(int(v) for v in ref))
        h, w, _ = rgb.shape
        alpha[int(h * 0.86):, int(w * 0.74):] = 0.0   # 清掉右下角工具水印
    rgb = despill(rgb, alpha, ref)
    print("   近全透明像素 %.1f%%" % (100.0 * (alpha < 8).mean()))

    # 主体掩码求包围盒：必须用 alpha 而不是「最暗通道」——
    # 品红背景 (254,30,255) 的最暗通道只有 30，用亮度判会把整张背景当主体。
    ys, xs = np.where(alpha > 96)
    if len(xs) == 0:
        print("   !! 没有主体，跳过")
        continue
    bbox = (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)

    im = Image.fromarray(
        np.dstack([rgb.astype(np.uint8), alpha.astype(np.uint8)]), "RGBA")
    im = im.crop(bbox)
    print("   主体 %dx%d -> 目标 %s=%d" % (im.size[0], im.size[1], axis, target))
    # 轻微羽化消除阈值硬边
    im.putalpha(im.getchannel("A").filter(ImageFilter.GaussianBlur(0.5)))
    im = fit(im, target, axis)
    dst = os.path.join(OUT, "%s_00.png" % name)
    im.save(dst)
    print("   -> %s  %s" % (dst, im.size))
    results.append(im)

if results:
    pad = 10
    W = sum(r.width for r in results) + pad * (len(results) + 1)
    H = max(r.height for r in results) + pad * 2
    pv = Image.new("RGBA", (W, H), (30, 28, 26, 255))
    x = pad
    for r in results:
        pv.alpha_composite(r, (x, pad))
        x += r.width + pad
    path = r"D:/SteamPunkExtraction/Assets/Art/Sprites/Decor/_preview_dark.png"
    pv.convert("RGB").resize((W * 5, H * 5), Image.NEAREST).save(path)
    print("预览(深底 5x):", path)
print("DONE")

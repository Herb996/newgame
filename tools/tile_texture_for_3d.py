# -*- coding: utf-8 -*-
"""
把 AI 地形纹理处理成"适合远视野平铺"的版本（3D 用）。

背景：这批 1024² 纹理是为 16px 瓦片近景设计的，含大量**宏观结构**
（成团的苔藓、大块裂纹、石板轮廓）。在 2D 瓦片里每格只取 16px，宏观结构
看不见；但 3D 里整张纹理平铺 4~10 格，宏观结构就变成每几十像素重复一次的
团块，观感像壁纸。

做法：高通滤波 —— 减去大幅模糊后的低频分量，再把局部均值拉回原全图均值。
结果是"去掉成团结构、保留细颗粒细节"，平铺时肉眼几乎察觉不到重复周期。

读：Assets/Art/Raw/Terrain/*.png（原始 AI 出图，不修改）
写：Assets/Art/Terrain3D/*.png（3D 用派生文件，可重复生成）
"""
import os
import numpy as np
from PIL import Image, ImageFilter

RAW = r"D:/SteamPunkExtraction/Assets/Art/Raw/Terrain"
DST = r"D:/SteamPunkExtraction/Assets/Art/Terrain3D"
JOBS = [
    ("Seamless_tileable_ground_textu_2026-09-14T23-34-47.png", "ground_forest.png"),
    ("Seamless_tileable_ground_textu_2026-09-14T23-35-17.png", "ground_waste.png"),
    ("Seamless_tileable_ground_textu_2026-09-14T23-35-18.png", "ground_marsh.png"),
    ("Seamless_tileable_ground_textu_2026-09-14T23-35-22.png", "ground_rock.png"),
    ("Seamless_tileable_texture_of_a_2026-09-14T23-35-17.png", "wall_plate.png"),
]
HP_RADIUS = 60      # 低频半径（像素）：越大保留的尺度越粗
CONTRAST = 0.88     # 细节对比微调（<1 更平，远处更不容易看出重复）

os.makedirs(DST, exist_ok=True)
for src, dst in JOBS:
    sp = os.path.join(RAW, src)
    if not os.path.exists(sp):
        print("  MISSING", src)
        continue
    im = Image.open(sp).convert("RGB")
    a = np.asarray(im).astype(np.float32)
    low = np.asarray(im.filter(ImageFilter.GaussianBlur(HP_RADIUS))).astype(np.float32)
    mean = a.reshape(-1, 3).mean(axis=0)
    d = a - low + mean                      # 高通：局部均值 = 全图均值
    d = (d - mean) * CONTRAST + mean        # 略压对比
    Image.fromarray(np.clip(d, 0, 255).astype(np.uint8), "RGB").save(
        os.path.join(DST, dst))
    print("  %-18s 高通半径=%d 对比=%.2f 原图均值=%s" % (
        dst, HP_RADIUS, CONTRAST, np.round(mean, 1).tolist()))
print("DONE")

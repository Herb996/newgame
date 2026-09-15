# -*- coding: utf-8 -*-
"""
生成草地的 3D 地面纹理 ground_grass.png（1024x1024 RGB）。
草地无 AI 源图（2D 里是程序化地板），这里用程序化方法造一张"适合 3D 平铺"的
绿色地面：多倍频值噪声 + 高通去宏观结构（与 tile_texture_for_3d.py 的管线一致），
避免 3D 远视野下出现壁纸式重复团块。

写：Assets/Art/Terrain3D/ground_grass.png
"""
import os
import numpy as np
from PIL import Image, ImageFilter

DST = r"D:/SteamPunkExtraction/Assets/Art/Terrain3D"
OUT = "ground_grass.png"
SIZE = 1024
SEED = 20260915
HP_RADIUS = 60      # 低频半径：与现有地面纹理保持一致
CONTRAST = 0.88     # 细节对比微调
BASE = np.array([74.0, 96.0, 52.0])   # 草地基色（绿调，shader 里还会再乘 BIOME_TUNE）


def fbm(size, octaves=5, seed=0):
    """多倍频值噪声：逐层随机图模糊叠加，得到自然颗粒感。"""
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    amp = 1.0
    total = 0.0
    for o in range(octaves):
        scale = 2 ** o
        # 低分辨率随机图，上采样后做轻微模糊 → 不同频率的斑块
        low = rng.random((max(2, size // scale), max(2, size // scale))).astype(np.float32)
        low_img = Image.fromarray((low * 255).astype(np.uint8)).resize(
            (size, size), Image.BILINEAR)
        low = np.asarray(low_img, dtype=np.float32) / 255.0
        field += low * amp
        total += amp
        amp *= 0.55
    field /= total
    return field


def main():
    np.random.seed(SEED)
    # 三通道独立的 fbm，合成彩色噪声底图
    r = fbm(SIZE, seed=SEED)
    g = fbm(SIZE, seed=SEED + 7)
    b = fbm(SIZE, seed=SEED + 13)
    noise = np.stack([r, g, b], axis=-1)  # 0..1

    # 基色 + 噪声扰动（噪声拉到 -0.18..+0.22 区间，给点明度/色相变化）
    amp_rgb = np.array([46.0, 50.0, 40.0])
    a = BASE + (noise - 0.5) * amp_rgb   # (SIZE, SIZE, 3)
    a = a.astype(np.float32)

    # 高通：减去大幅高斯模糊后的低频分量，再把局部均值拉回全图均值
    im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGB")
    low = np.asarray(im.filter(ImageFilter.GaussianBlur(HP_RADIUS)), dtype=np.float32)
    mean = a.reshape(-1, 3).mean(axis=0)
    d = a - low + mean
    d = (d - mean) * CONTRAST + mean

    out = np.clip(d, 0, 255).astype(np.uint8)
    os.makedirs(DST, exist_ok=True)
    Image.fromarray(out, "RGB").save(os.path.join(DST, OUT))
    print("grass base mean =", np.round(mean, 1).tolist())
    print("wrote", os.path.join(DST, OUT), out.shape)


if __name__ == "__main__":
    main()

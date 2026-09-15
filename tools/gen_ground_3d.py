# -*- coding: utf-8 -*-
"""
生成缺失的 3D 地面纹理（1024x1024 RGB），写入 Assets/Art/Terrain3D/。

背景：群系地面在 3D 里是「每群系一张 1024² 平铺纹理」。有 AI 源图的群系
（ground_forest / ground_waste 等）用 tiles 管线处理；**没有源图的群系**
（草地、雪原）就由本脚本程序化生成，保证 3D 场景永远不缺纹理。

与 tile_texture_for_3d.py 同一套哲学：
  多倍频值噪声 → 高通去宏观结构 → 保底细节对比。
否则 3D 远视野下会看到壁纸式的重复团块。

数据驱动：读 Data/config.json 的 map.biomes，对每个群系检查
`ground_3d` 指向的文件是否已存在；不存在才生成（已存在的不会被覆盖，
避免把 AI 处理过的好素材冲掉）。基色直接取该群系的 `floor`（与 2D 地板同色）。

用法：
    python tools/gen_ground_3d.py                 # 只补缺失的
    python tools/gen_ground_3d.py --force 雪原     # 强制重生成指定群系
    python tools/gen_ground_3d.py --all           # 全部重生成（谨慎）
"""
import os
import sys
import json
import argparse
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, "Assets", "Art", "Terrain3D")
CONFIG = os.path.join(ROOT, "Data", "config.json")

SIZE = 1024
SEED = 20260915
HP_RADIUS = 60        # 高通低频半径：与现有地面纹理保持一致
CONTRAST = 0.88       # 细节对比微调

# 无源图群系的专用风格。键 = config 里的群系 name。
# amplitude：噪声扰动幅度（RGB），越亮的地表越要小，否则一片白点很脏。
# sparkle：高光颗粒密度（雪地的闪光），0 = 不做。
STYLE = {
    "草地": {"amplitude": (46.0, 50.0, 40.0), "sparkle": 0.0,  "warm": 1.00},
    "雪原": {"amplitude": (22.0, 24.0, 30.0), "sparkle": 0.55, "warm": 0.94},
}
DEFAULT_STYLE = {"amplitude": (34.0, 36.0, 36.0), "sparkle": 0.0, "warm": 1.0}


def fbm(size, octaves=5, seed=0):
    """多倍频值噪声：逐层随机图模糊叠加，得到自然颗粒感。"""
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    amp = 1.0
    total = 0.0
    for o in range(octaves):
        scale = 2 ** o
        low = rng.random((max(2, size // scale), max(2, size // scale))).astype(np.float32)
        low_img = Image.fromarray((low * 255).astype(np.uint8)).resize(
            (size, size), Image.BILINEAR)
        low = np.asarray(low_img, dtype=np.float32) / 255.0
        field += low * amp
        total += amp
        amp *= 0.55
    field /= total
    return field


def make_ground(base_rgb, amplitude, sparkle, warm, seed):
    """程序化地面：fbm 彩色噪声 + 高通。base_rgb 为 0..255。"""
    r = fbm(SIZE, seed=seed)
    g = fbm(SIZE, seed=seed + 7)
    b = fbm(SIZE, seed=seed + 13)
    noise = np.stack([r, g, b], axis=-1)          # 0..1

    amp = np.array(amplitude, dtype=np.float32)
    a = np.array(base_rgb, dtype=np.float32)[None, None, :] + (noise - 0.5) * amp
    a[..., 0] *= warm
    a[..., 2] *= (2.0 - warm)                     # warm<1 → 偏冷（蓝多）
    a = a.astype(np.float32)

    # 高通：减去大幅高斯模糊后的低频分量，再把局部均值拉回全图均值
    im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGB")
    low = np.asarray(im.filter(ImageFilter.GaussianBlur(HP_RADIUS)), dtype=np.float32)
    mean = a.reshape(-1, 3).mean(axis=0)
    d = a - low + mean
    d = (d - mean) * CONTRAST + mean

    # 闪光颗粒（雪地）：稀疏亮点，尺寸 1~2px，避免形成规则图案
    if sparkle > 0.0:
        rng = np.random.default_rng(seed + 99)
        n = int(SIZE * SIZE * 0.00035 * sparkle)
        ys = rng.integers(0, SIZE, n)
        xs = rng.integers(0, SIZE, n)
        for i in range(n):
            y, x = int(ys[i]), int(xs[i])
            d[y, x] = np.minimum(d[y, x] + rng.uniform(26.0, 46.0), 255.0)
            if x + 1 < SIZE:
                d[y, x + 1] = np.minimum(d[y, x + 1] + rng.uniform(8.0, 18.0), 255.0)

    return np.clip(d, 0, 255).astype(np.uint8), mean


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", nargs="*", default=[], help="强制重生成这些群系（按 name）")
    ap.add_argument("--all", action="store_true", help="全部重生成")
    args = ap.parse_args()

    with open(CONFIG, encoding="utf-8") as f:
        cfg = json.load(f)
    biomes = cfg["map"]["biomes"]
    os.makedirs(DST, exist_ok=True)

    np.random.seed(SEED)
    made = []
    for i, b in enumerate(biomes):
        name = b.get("name", "?")
        fname = b.get("ground_3d", "")
        if not fname:
            print("  [%s] config 未指定 ground_3d，跳过" % name)
            continue
        path = os.path.join(DST, fname)
        forced = args.all or (name in args.force)
        if os.path.exists(path) and not forced:
            print("  [%s] %s 已存在，跳过（--force %s 可强制重生成）" % (name, fname, name))
            continue

        style = STYLE.get(name, DEFAULT_STYLE)
        floor = b.get("floor", [0.4, 0.4, 0.4])
        base = [float(c) * 255.0 for c in floor]
        out, mean = make_ground(base, style["amplitude"], style["sparkle"],
                                style["warm"], SEED + i * 31)
        Image.fromarray(out, "RGB").save(path)
        made.append(fname)
        print("  [%s] 生成 %s  基色=%s  生成后均值=%s"
              % (name, fname, [int(v) for v in base], np.round(mean, 1).tolist()))

    if made:
        print("生成 %d 张：%s" % (len(made), ", ".join(made)))
    else:
        print("没有需要生成的纹理。")
    print("提醒：新增 PNG 必须让 Godot 导入一次（--import）才会出现在 ResourceLoader 里。")


if __name__ == "__main__":
    main()

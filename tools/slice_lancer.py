# -*- coding: utf-8 -*-
"""切 Tiny Swords Lancer 的 8 向素材 -> Assets/Art/Sprites/Units/blue_lancer/

背景：Lancer 是免费包里唯一带「多方向」素材的兵种。它的结构是

    Lancer_Idle.png            12 帧  单向（正视视角）
    Lancer_Run.png              6 帧  单向（正视视角）
    Lancer_<Dir>_Attack.png     3 帧  x 5 个方向
    Lancer_<Dir>_Defence.png    6 帧  x 5 个方向（几乎静止的举盾姿势）

    <Dir> ∈ {Down, DownRight, Right, UpRight, Up}
    左半边（Left / DownLeft / UpLeft）官方没画 -> 由对应右半边水平镜像得到。

画布 320x320（不是 Warrior 的 192x192 —— 长枪要更宽的格）。

【脚底对齐】结论：**不做对齐**，直接用官方原始坐标。
理由：官方素材本身已在同一 320x320 画布坐标系里；而各 sheet 的「下沿」
受长枪伸出方向影响极大（同一方向不同动画也差很多，例如 Down_Attack 下沿 301、
Down_Defence 277），无法可靠地自动识别「脚底」。实测 Idle / Run / Right 系
（玩家 90% 时间所处的直立姿势）下沿都是 197/198，彼此一致，这才是关键。
强行按启发式对齐会误判（Run 曾被算出 +93 的荒谬平移）。
ALIGN_FEET 开关保留，若要人工微调再打开。

对齐后 config 侧：
    sprite_offset_y = -(197 - 320/2) = -37
    sprite_scale    = 192/320 = 0.6   （才能与 Warrior 视觉等大）

用法：python tools/slice_lancer.py
"""
from __future__ import annotations

import json
import os

from PIL import Image

SRC = r"D:\SteamPunkExtraction\images\Tiny Swords (Free Pack)\Units\Blue Units\Lancer"
DST = r"D:\SteamPunkExtraction\Assets\Art\Sprites\Units\blue_lancer"
CONFIG_SNIPPET = r"C:\Users\Administrator\WorkBuddy\2026-09-15-23-06-42\_lancer_frames.json"
FEET_REPORT = r"C:\Users\Administrator\WorkBuddy\2026-09-15-23-06-42\_lancer_feet.txt"

FW = FH = 320
FEET_TARGET = 197      # 对齐目标（Idle / Run / Right 系的共同下沿）
ALIGN_FEET = False     # 见文件头说明：默认不自动对齐，只出探测报告
WIDE = 25              # 「身体」行宽阈值
NARROW = 15            # 「只剩枪杆」行宽阈值
RES_DIR = "res://Assets/Art/Sprites/Units/blue_lancer/"

# (源文件, 输出前缀)
JOBS: list[tuple[str, str]] = [
    ("Lancer_Idle.png", "idle"),
    ("Lancer_Run.png", "run"),
    ("Lancer_Down_Attack.png", "attack_down"),
    ("Lancer_DownRight_Attack.png", "attack_down_right"),
    ("Lancer_Right_Attack.png", "attack_right"),
    ("Lancer_UpRight_Attack.png", "attack_up_right"),
    ("Lancer_Up_Attack.png", "attack_up"),
    ("Lancer_Down_Defence.png", "guard_down"),
    ("Lancer_DownRight_Defence.png", "guard_down_right"),
    ("Lancer_Right_Defence.png", "guard_right"),
    ("Lancer_UpRight_Defence.png", "guard_up_right"),
    ("Lancer_Up_Defence.png", "guard_up"),
]

# 需要由「右系」镜像派生的「左系」前缀
MIRROR_OF = {
    "attack_right": "attack_left",
    "attack_down_right": "attack_down_left",
    "attack_up_right": "attack_up_left",
    "guard_right": "guard_left",
    "guard_down_right": "guard_down_left",
    "guard_up_right": "guard_up_left",
    "idle": "idle_m",          # 单向素材也镜像一份：若原图其实是侧视，左向就用它
    "run": "run_m",
}

written: list[str] = []
frame_map: dict[str, dict[str, list[str]]] = {}
feet_lines: list[str] = []


def row_widths(fr: Image.Image) -> list:
    """每行不透明像素数。一次取全部像素再切片，比逐像素 load() 快得多。"""
    a = fr.getchannel("A")
    w, h = a.size
    data = list(a.getdata())
    return [sum(1 for v in data[y * w:(y + 1) * w] if v > 8) for y in range(h)]


def body_bottom(fr: Image.Image) -> int:
    """身体主体底边（≈脚底）。

    不能用 bbox 下沿 —— 朝上/朝下的刺枪姿势里枪尖会伸到脚底以下。
    判据：先自上而下找第一条「宽 >= WIDE」的行（身体开始），
    再往下找第一条「宽 < NARROW」的行（腿脚之后只剩细枪杆）。
    """
    ws = row_widths(fr)
    top = -1
    for y, c in enumerate(ws):
        if c >= WIDE:
            top = y
            break
    if top < 0:
        return -1
    for y in range(top, len(ws)):
        if ws[y] < NARROW:
            return y - 1
    for y in range(len(ws) - 1, -1, -1):
        if ws[y] > 0:
            return y
    return -1


def shift_vertical(fr: Image.Image, dy: int) -> Image.Image:
    """整帧垂直平移，空出的部分保持透明。"""
    if dy == 0:
        return fr
    canvas = Image.new("RGBA", (FW, FH), (0, 0, 0, 0))
    canvas.alpha_composite(fr, (0, dy))
    return canvas


def save(img: Image.Image, name: str, prefix: str) -> str:
    os.makedirs(DST, exist_ok=True)
    dst = os.path.join(DST, name)
    img.save(dst)
    written.append(dst)
    return RES_DIR + name


def main() -> int:
    feet_lines.append("对齐目标 FEET_TARGET = %d   （WIDE=%d / NARROW=%d）"
                      % (FEET_TARGET, WIDE, NARROW))
    feet_lines.append("")
    for src_name, prefix in JOBS:
        src = os.path.join(SRC, src_name)
        if not os.path.exists(src):
            print("[skip] 缺源 %s" % src_name)
            continue
        sheet = Image.open(src).convert("RGBA")
        n = sheet.width // FW
        frames = [sheet.crop((i * FW, 0, (i + 1) * FW, FH)) for i in range(n)]

        raw = body_bottom(frames[0])
        dy = (FEET_TARGET - raw) if (ALIGN_FEET and raw >= 0) else 0
        if dy != 0:
            frames = [shift_vertical(fr, dy) for fr in frames]

        paths: list[str] = []
        for i, fr in enumerate(frames):
            name = "%s_%02d.png" % (prefix, i)
            paths.append(save(fr, name, prefix))
        mirror_prefix = MIRROR_OF.get(prefix)
        if mirror_prefix:
            mpaths: list[str] = []
            for i, fr in enumerate(frames):
                mf = fr.transpose(Image.FLIP_LEFT_RIGHT)
                name = "%s_%02d.png" % (mirror_prefix, i)
                mpaths.append(save(mf, name, mirror_prefix))
            frame_map.setdefault(mirror_prefix, {})["_all"] = mpaths

        frame_map.setdefault(prefix, {})["_all"] = paths
        after = body_bottom(frames[0])
        bbox = frames[0].getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
        clipped = ""
        if not ALIGN_FEET:
            clipped = "   [未对齐]"
        elif not (0 <= raw + dy <= FH):
            clipped = "   [警告] 平移后超出画布"
        feet_lines.append("%-24s %2d 帧   bbox下沿 %3d   主体底边 %3d   平移 %+4d   -> %3d%s"
                          % (prefix, n, bbox[3], raw, dy, after, clipped))
        print("  ok %-24s %d 帧  dy=%+d" % (prefix, n, dy))

    with open(CONFIG_SNIPPET, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(frame_map, fh, ensure_ascii=False, indent=2)
    with open(FEET_REPORT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(feet_lines) + "\n")

    print("共写出 %d 个 png -> %s" % (len(written), DST))
    print("帧清单 -> %s" % CONFIG_SNIPPET)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

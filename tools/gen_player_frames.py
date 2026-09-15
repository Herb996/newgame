# -*- coding: utf-8 -*-
"""
gen_player_frames.py — 从 4 向 idle 基准帧程序化派生「序列帧」

为什么走程序化而不是 AI 重新出图：
  现有 4 向 idle（48x48）已经确定了角色造型（褐风衣 / 黄铜护目镜 / 背包 / 机械臂）。
  AI 再多画几帧很难保证是同一个角色，且要抠图 + 归一化；程序化派生与原造型
  在像素级 100% 一致，且完全可复现 —— 改参数重跑即可，天然进 git 做 diff。

产出（写入 Assets/Art/Sprites/Player/）：
  player_idle_{dir}_00.png / _01.png      —— 2 帧呼吸
  player_walk_{dir}_00.png ... _03.png    —— 4 帧行走（contact / passing 交替）
  预览：_frames_preview.png（放大拼图）、_walk_preview.gif（动图）

实现要点（踩过的坑）：
  1) **必须分层**：先把左右腿从基准帧里抠成独立层，再各自平移、回贴。
     直接在硬列边界内平移会有两个问题 —— 越界被裁、边界处留下补出来的假像素。
  2) **腿层平移要用透明填充**，不能用「边缘延伸」：边缘延伸会把抬起的脚
     又抹回地面，看起来完全没动。上身平移才用边缘延伸（避免躯干和腿之间裂开）。
  3) 腿层列范围按 48x48 基准帧的实测剖面定，见下方 LEG_COLS（中间那团白色
     是内衬/衣摆，不属于腿，不能跟着腿动）。

用法：python tools/gen_player_frames.py
"""

import os
import numpy as np
from PIL import Image

SRC = "D:/SteamPunkExtraction/Assets/Art/Sprites/Player"
# 预览图写到被 .gdignore 排除的目录：预览是给人看的，不该被引擎当游戏素材导入
PREVIEW = "D:/SteamPunkExtraction/tools/_preview"
DIRS = ["down", "up", "left", "right"]
CANVAS = 48

# --- 每个朝向的「视型」：前/后视 vs 侧视，腿的运动方式不同 ---
VIEW = {"down": "front", "up": "front", "left": "side", "right": "side"}

# --- 腿层几何（依据实测剖面） ---
# front：左右腿各一团暗色(14-21 / 26-33)，中间 22-25 是白色内衬（留给躯干）
# side ：两条腿明显分离成两团(16-24 / 26-32)
LEG_COLS = {
    "front": [(14, 22), (26, 34)],
    "side": [(16, 25), (26, 33)],
}
LEG_TOP = {"front": 40, "side": 37}

# --- 位移单位铁律 ---
# 48x48 是 2 倍超采样画布（PlayerAnimator.SPRITE_SCALE = 0.5，游戏里显示成 24x24）。
# 所以**所有位移都必须取 2px 的整数倍**：1px 源位移只等于屏幕上 0.5px（亚像素，看不见），
# 而 2px 源位移 = 1 显示像素，同时也保证降采样后仍落在像素网格上、不糊边。
U = 2

# --- 行走 4 帧节奏：contact / passing / contact / passing ---
# 上身 (dx, dy)：dy=-U 抬起 1 显示像素；dx 为重心左右移（压向踩地那条腿）
WALK_BODY_FRONT = [(U, 0), (0, -U), (-U, 0), (0, -U)]
WALK_BODY_SIDE = [(0, 0), (0, -U), (0, 0), (0, -U)]
# 前视：左右腿交替抬起（contact 帧抬一侧，passing 帧双脚落地）
WALK_FRONT_L = [(0, -U), (0, 0), (0, 0), (0, 0)]
WALK_FRONT_R = [(0, 0), (0, 0), (0, -U), (0, 0)]
# 侧视：前后摆腿（dx 再乘 fwd：left 面向 -x、right 面向 +x）
#   contact 帧两腿前后张开；passing 帧摆动腿抬起
WALK_SIDE_L = [(U, 0), (0, -U), (-U, 0), (0, 0)]
WALK_SIDE_R = [(-U, 0), (0, 0), (U, 0), (0, -U)]


# ------------------------------------------------------------
# 像素级平移（不做重采样，保持像素锐利）
# ------------------------------------------------------------

def shift(arr, dx, dy, vfill="transparent"):
    """整画布平移；vfill 决定纵向空出来的行怎么补：
       "transparent" = 补透明（脚抬离地面看得见）；"edge" = 边缘延伸（不裂开）。"""
    h, w = arr.shape[:2]
    out = arr
    if dx != 0:
        px = abs(dx) + 2
        out = np.pad(out, ((0, 0), (px, px), (0, 0)), mode="edge")
        x0 = px - dx
        out = out[:, x0:x0 + w]
    if dy != 0:
        py = abs(dy) + 2
        mode = "edge" if vfill == "edge" else "constant"
        out = np.pad(out, ((py, py), (0, 0), (0, 0)), mode=mode)
        y0 = py - dy
        out = out[y0:y0 + h, :]
    return np.ascontiguousarray(out)


def split_layers(base, mode):
    """把基准帧拆成 (躯干, 左腿, 右腿) 三层；腿层按列范围抠，行列互不重叠。"""
    top = LEG_TOP[mode]
    (lc0, lc1), (rc0, rc1) = LEG_COLS[mode]
    mL = np.zeros(base.shape[:2], dtype=bool)
    mR = np.zeros(base.shape[:2], dtype=bool)
    mL[top:, lc0:lc1] = True
    mR[top:, rc0:rc1] = True

    torso = base.copy()
    torso[mL | mR] = 0
    legL = np.zeros_like(base)
    legL[mL] = base[mL]
    legR = np.zeros_like(base)
    legR[mR] = base[mR]
    return torso, legL, legR


def over(bottom, layer, dx, dy, vfill="transparent"):
    """把 layer 平移后盖到 bottom 上（有内容处覆盖）。"""
    sh = shift(layer, dx, dy, vfill)
    out = bottom.copy()
    m = sh[..., 3] > 0
    out[m] = sh[m]
    return out


# ------------------------------------------------------------
# 帧生成
# ------------------------------------------------------------

def load_base(d):
    return np.array(Image.open(os.path.join(SRC, "player_idle_%s_00.png" % d)).convert("RGBA"),
                    dtype=np.uint8)


def make_walk(base, d, i):
    mode = VIEW[d]
    torso, legL, legR = split_layers(base, mode)
    if mode == "front":
        bdx, bdy = WALK_BODY_FRONT[i]
        ldx, ldy = WALK_FRONT_L[i]
        rdx, rdy = WALK_FRONT_R[i]
    else:
        fwd = -1 if d == "left" else 1
        bdx, bdy = WALK_BODY_SIDE[i]
        ldx, ldy = WALK_SIDE_L[i]
        rdx, rdy = WALK_SIDE_R[i]
        ldx *= fwd
        rdx *= fwd
    f = shift(torso, bdx, bdy, vfill="edge")
    f = over(f, legL, ldx, ldy)
    f = over(f, legR, rdx, rdy)
    return f


def make_idle(base, d, i):
    """呼吸：躯干抬 1 显示像素、腿踩地不动（躯干用边缘延伸补，避免与腿裂开）。"""
    if i == 0:
        return base.copy()
    torso, legL, legR = split_layers(base, VIEW[d])
    f = shift(torso, 0, -U, vfill="edge")
    f = over(f, legL, 0, 0)
    f = over(f, legR, 0, 0)
    return f


def save(arr, name):
    Image.fromarray(np.ascontiguousarray(arr), "RGBA").save(os.path.join(SRC, name))


# ------------------------------------------------------------
# 预览 / 诊断
# ------------------------------------------------------------

def save_preview(dir_frames):
    Z, gap = 7, 6
    cw = CANVAS * Z
    cols = 6
    W = cols * cw + (cols - 1) * gap
    H = len(DIRS) * cw + (len(DIRS) - 1) * gap
    canvas = Image.new("RGBA", (W, H), (26, 28, 34, 255))
    for r, d in enumerate(DIRS):
        seq = dir_frames[d]["idle"] + dir_frames[d]["walk"]
        for c, arr in enumerate(seq):
            im = Image.fromarray(np.ascontiguousarray(arr), "RGBA")
            bg = Image.new("RGBA", im.size, (48, 50, 58, 255))
            bg.alpha_composite(im)
            canvas.alpha_composite(bg.resize((cw, cw), Image.NEAREST),
                                   (c * (cw + gap), r * (cw + gap)))
            if c == 1:   # idle | walk 分隔线
                canvas.alpha_composite(Image.new("RGBA", (3, cw), (120, 190, 255, 255)),
                                       (c * (cw + gap) + cw + 1, r * (cw + gap)))
    out = os.path.join(PREVIEW, "frames_preview.png")
    canvas.convert("RGB").save(out)
    print("[preview]", out, canvas.size)


def save_gif(dir_frames):
    Z, gap = 4, 4
    tw = CANVAS * Z
    W = len(DIRS) * tw + (len(DIRS) - 1) * gap
    gif = []
    for i in range(4):
        c = Image.new("RGB", (W, tw), (26, 28, 34))
        x = 0
        for d in DIRS:
            im = Image.fromarray(np.ascontiguousarray(dir_frames[d]["walk"][i]), "RGBA")
            bg = Image.new("RGBA", im.size, (40, 42, 50, 255))
            bg.alpha_composite(im)
            c.paste(bg.convert("RGB").resize((tw, tw), Image.NEAREST), (x, 0))
            x += tw + gap
        gif.append(c)
    out = os.path.join(PREVIEW, "walk_preview.gif")
    gif[0].save(out, save_all=True, append_images=gif[1:], duration=110, loop=0)
    print("[preview]", out, gif[0].size)


def save_ingame(dir_frames):
    """按游戏内真实尺寸（48→24 降采样，即 PlayerAnimator.SPRITE_SCALE）再看一遍：
       这是判断"这一帧到底看不看得出动作"的唯一可信依据，别只看放大图。"""
    Z = 8
    t = 24 * Z
    g = 6
    gif = []
    for i in range(4):
        fr = Image.new("RGB", (4 * t + 3 * g, t), (24, 26, 32))
        x = 0
        for d in DIRS:
            im = Image.fromarray(np.ascontiguousarray(dir_frames[d]["walk"][i]), "RGBA")
            bg = Image.new("RGBA", (24, 24), (46, 48, 56, 255))
            bg.alpha_composite(im.resize((24, 24), Image.LANCZOS))
            fr.paste(bg.convert("RGB").resize((t, t), Image.NEAREST), (x, 0))
            x += t + g
        gif.append(fr)
    out = os.path.join(PREVIEW, "walk_ingame.gif")
    gif[0].save(out, save_all=True, append_images=gif[1:], duration=110, loop=0)
    print("[preview]", out, gif[0].size)


def diff_report(base, walk):
    """确认每帧确实改了东西（防止"改参数没生效"这类假成功）。"""
    a = base[..., 3] > 96
    print("== 帧间差异（相对基准帧的可见像素变化数）==")
    for i, f in enumerate(walk):
        b = f[..., 3] > 96
        d = int(np.logical_xor(a, b).sum())
        rgb = int((np.abs(base[..., :3].astype(int) - f[..., :3].astype(int)).sum(axis=2) > 24).sum())
        print("   walk_%02d  形变(alpha)=%4d  rgb差异=%4d" % (i, d, rgb))


# ------------------------------------------------------------

def main():
    dir_frames = {}
    for d in DIRS:
        base = load_base(d)
        idle = [make_idle(base, d, i) for i in range(2)]
        walk = [make_walk(base, d, i) for i in range(4)]
        dir_frames[d] = {"idle": idle, "walk": walk}
        for i in range(1, 2):
            save(idle[i], "player_idle_%s_%02d.png" % (d, i))
        for i in range(4):
            save(walk[i], "player_walk_%s_%02d.png" % (d, i))
        print("[gen] %-5s view=%-5s idle=2 walk=4" % (d, VIEW[d]))

    os.makedirs(PREVIEW, exist_ok=True)
    save_preview(dir_frames)
    save_gif(dir_frames)
    save_ingame(dir_frames)
    diff_report(load_base("down"), dir_frames["down"]["walk"])
    diff_report(load_base("left"), dir_frames["left"]["walk"])


if __name__ == "__main__":
    main()

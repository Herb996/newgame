# -*- coding: utf-8 -*-
"""像素级校验 Archer（弓）切片结果。

断言：
 1. 角色帧共 36 个（idle/run/shoot 各 原图+镜像），全部 192x192
 2. 每个 *_m_NN.png 与对应 *_NN.png 逐字节等于水平翻转（18 对）
 3. 原图与镜像确实不同（不是空翻转）
 4. 同一动作的不同帧编号不是同一张图（切片真的在切）
 5. idle / run / shoot 三套的不透明包围盒下沿一致（脚底对齐的前提）
 6. 箭矢 arrow.png 是 64x64，且不透明包围盒在画布里居中（旋转不跑偏）

结果落盘 _archer_frames_check.txt。
"""
from __future__ import annotations

import hashlib
import os

from PIL import Image, ImageChops

DIR = r"D:\SteamPunkExtraction\Assets\Art\Sprites\Units\blue_archer"
ARROW = r"D:\SteamPunkExtraction\Assets\Art\Sprites\Projectiles\arrow.png"
OUT = r"C:\Users\Administrator\WorkBuddy\2026-09-15-23-06-42\_archer_frames_check.txt"

ANIMS = {"idle": 6, "run": 4, "shoot": 8}

lines: list[str] = []
fails: list[str] = []
n = 0


def check(ok: bool, msg: str) -> None:
    global n
    n += 1
    lines.append("  %s %s" % ("OK  " if ok else "FAIL", msg))
    if not ok:
        fails.append(msg)


def main() -> int:
    files = sorted(f for f in os.listdir(DIR) if f.endswith(".png"))
    lines.append("目录 %s" % DIR)
    lines.append("png 总数 %d" % len(files))
    lines.append("")

    expect = sum(v * 2 for v in ANIMS.values())
    check(len(files) == expect, "角色帧数 = %d（实得 %d）" % (expect, len(files)))

    imgs = {f: Image.open(os.path.join(DIR, f)).convert("RGBA") for f in files}

    bad_size = [f for f, im in imgs.items() if im.size != (192, 192)]
    check(not bad_size, "全部 192x192（异常 %s）" % str(bad_size[:5]))

    # 镜像逐字节相等 + 原图确实不同
    pairs = 0
    mirror_bad: list[str] = []
    same_as_orig: list[str] = []
    for anim, cnt in ANIMS.items():
        for i in range(cnt):
            a = "%s_%02d.png" % (anim, i)
            b = "%s_m_%02d.png" % (anim, i)
            if a not in imgs or b not in imgs:
                mirror_bad.append("%s/%s 缺一" % (a, b))
                continue
            pairs += 1
            flipped = imgs[a].transpose(Image.FLIP_LEFT_RIGHT)
            if ImageChops.difference(flipped, imgs[b]).getbbox() is not None:
                mirror_bad.append("%s != flipH(%s)" % (b, a))
            if ImageChops.difference(imgs[a], imgs[b]).getbbox() is None:
                same_as_orig.append(a)
    check(pairs == 18, "找到 18 组镜像对（实得 %d）" % pairs)
    check(not mirror_bad, "*_m_* == flipH(*_*) 逐字节相等（异常 %s）" % str(mirror_bad[:4]))
    check(not same_as_orig,
          "镜像与原图确实不同 —— 素材是侧视而非正面对称（异常 %s）" % str(same_as_orig[:4]))

    # 同动作不同帧不能是同一张
    flat: list[str] = []
    for anim, cnt in ANIMS.items():
        uniq = {hashlib.md5(imgs["%s_%02d.png" % (anim, i)].tobytes()).hexdigest()
                for i in range(cnt)}
        flat.append("%s %d/%d 种" % (anim, len(uniq), cnt))
        check(len(uniq) == cnt, "%s 的 %d 帧两两不同（实得 %d 种）" % (anim, cnt, len(uniq)))
    lines.append("   逐帧唯一性：%s" % " | ".join(flat))

    # 三套动作的下沿必须一致
    bots = {}
    for anim in ANIMS:
        b = set()
        for i in range(ANIMS[anim]):
            bb = imgs["%s_%02d.png" % (anim, i)].getchannel("A") \
                .point(lambda v: 255 if v > 8 else 0).getbbox()
            b.add(bb[3])
        bots[anim] = sorted(b)
    lines.append("   包围盒下沿：%s" % ", ".join("%s=%s" % (k, v) for k, v in bots.items()))
    allb = set()
    for v in bots.values():
        allb |= set(v)
    check(allb == {136}, "三套动作下沿统一为 136 -> offset_y=-40 成立（实得 %s）" % str(sorted(allb)))

    # 箭矢
    check(os.path.exists(ARROW), "箭矢 arrow.png 存在")
    if os.path.exists(ARROW):
        a = Image.open(ARROW).convert("RGBA")
        check(a.size == (64, 64), "arrow.png 是 64x64（实得 %s）" % str(a.size))
        bb = a.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
        cx = (bb[0] + bb[2]) / 2.0
        cy = (bb[1] + bb[3]) / 2.0
        dx, dy = abs(cx - 32.0), abs(cy - 32.0)
        lines.append("   arrow bbox=%s  中心 (%.1f, %.1f)  偏移 (%.1f, %.1f)"
                     % (str(bb), cx, cy, dx, dy))
        check(dx <= 2.0 and dy <= 2.0,
              "箭矢在画布里居中（偏移 %.1f, %.1f，<=2px）—— 旋转不会甩飞" % (dx, dy))
        check(bb[2] - bb[0] > bb[3] - bb[1], "箭是横向的（长 > 高），旋转后朝向才自然")

    lines.append("")
    lines.append("=== 共 %d 项断言，失败 %d 项 ===" % (n, len(fails)))
    for m in fails:
        lines.append("  !! " + m)
    open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print("OK  %d/%d" % (n - len(fails), n))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

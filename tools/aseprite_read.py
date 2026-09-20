# -*- coding: utf-8 -*-
"""aseprite_read.py —— 纯 Python 读 .aseprite（不需要装 Aseprite）。

用途：把这个游戏的素材源文件（Tiny Swords 的 Units/Terrain、特效包等）
直接解出来看 / 导出 PNG，回答「这一帧长什么样、有几个图层、动画怎么分组」。

必须用带 PIL 的解释器跑：
    C:\\Users\\Administrator\\.workbuddy\\binaries\\python\\envs\\default\\Scripts\\python.exe

用法
    info  <file...>                       # 画布/帧数/图层/TAG/每帧时长与 cel 数
    png   <file> <out.png> [选项]          # 导出某一帧为 PNG
    sheet <file> <out.png> [选项]          # 把所有帧（或某个 TAG）拼成一张联络表

选项
    --frame N        只导第 N 帧（0 基）
    --tag NAME       只导该 TAG 覆盖的帧范围
    --scale S        放大倍数（默认 4，最近邻，像素画不糊）
    --bg R,G,B[,A]   背景色（默认透明；给 30,30,40 便于看深色素材）
    --skip LAYER     丢掉某图层，可重复（名字里含这段就丢，用来扒掉武器/道具层）
    --only-visible   跳过文件里标记为隐藏的图层
    --order RGBA|BGRA  通道顺序（个别导出工具是 BGRA，颜色全错时用它）

文件格式要点（全部实测核对过，和网上部分文档不一致的地方以本文件为准）
    header 128B: +0 DWORD 文件大小 / +4 WORD magic 0xA5E0 / +6 WORD 帧数 /
                 +8 WORD 宽 / +10 WORD 高 / +12 WORD 色深
    每个 frame: 12B 头部（+0 帧字节数 / +4 magic 0xF1FA / +6 chunk 数 /
                 **+8 WORD 帧时长 ms**）后跟若干 chunk
    chunk 0x2004 Layer / 0x2005 Cel / 0x2018 Tags / 0x2019 Palette
    Cel(zlib): body+0 图层序号、+2 x、+4 y、+7 类型(2=zlib)、+16 宽、+18 高、+20 起像素 w*h*4
    Tags: body+0 WORD 数量、+2 起 8B 保留；每条记录从 body+10 开始：
          from(2) to(2) dir(1) repeat(2) 保留(6) 颜色(3) 保留(1) 名长(2)+名
          —— 定长部分 17B（比文档多 1B 保留），链条刚好收在 chunk 末尾
"""
import os
import struct
import sys
import zlib

CT_OLD_PAL, CT_OLD_PAL2 = 0x0004, 0x0011
CT_LAYER, CT_CEL, CT_TAGS, CT_PALETTE = 0x2004, 0x2005, 0x2018, 0x2019
KNOWN = {0x0004, 0x0011, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008,
         0x2016, 0x2017, 0x2018, 0x2019, 0x2020, 0x2022, 0x2023}

try:
    from PIL import Image
except ImportError:                                   # 提示别用错解释器
    sys.stderr.write("!! 没有 PIL —— 请用 envs\\default\\Scripts\\python.exe 运行\n")
    raise


# ------------------------------------------------------------------ 解析
def rd_string(b, p):
    n = struct.unpack_from("<H", b, p)[0]
    return b[p + 2:p + 2 + n].decode("utf-8", "replace"), p + 2 + n


def find_sub(d, fs, fend, nch):
    """chunk 流起始偏移在 8..30 之间，靠「链长刚好收在帧尾」判定。"""
    for off in range(8, 32, 2):
        q, c, ok = fs + off, 0, True
        while q + 6 <= fend and c < nch + 4:
            ss, st = struct.unpack_from("<IH", d, q)
            if st not in KNOWN or ss < 6 or q + ss > fend:
                ok = False
                break
            c += 1
            q += ss
            if q == fend:
                break
        if ok and q == fend and c >= nch:
            return off
    return -1


def decode_cel(d, q):
    ss, st = struct.unpack_from("<IH", d, q)
    if st != CT_CEL:
        return None
    body = q + 6
    li, cx, cy = struct.unpack_from("<Hhh", d, body)
    ct = struct.unpack_from("<H", d, body + 7)[0]
    if ct == 1:                                       # linked cel：引用别处，解不出像素
        return ("linked", li)
    w = struct.unpack_from("<H", d, body + 16)[0]
    h = struct.unpack_from("<H", d, body + 18)[0]
    if w <= 0 or h <= 0:
        return None
    px = d[body + 20:q + ss]
    if ct == 2:
        try:
            px = zlib.decompress(px)
        except Exception:
            return None
    if len(px) < w * h * 4:
        return None
    return (li, cx, cy, w, h, px[:w * h * 4])


def read_tags(d, q, ss, nframes):
    """TAG chunk（0x2018）。记录链：从 body+10 起，定长 17B + 名长(2)+名。
    解析结果做三重校验（名字可打印 / from<=to<nframes / 链条刚好收尾），
    任何一条不过就直接返回空 —— 宁可没 TAG，也不要吐出一堆乱码。"""
    b = q + 6
    body_end = q + ss
    try:
        ntags = struct.unpack_from("<H", d, b)[0]
    except struct.error:
        return []
    if not 0 < ntags < 256:
        return []
    bp, out = b + 10, []
    for _t in range(ntags):
        try:
            a, z = struct.unpack_from("<HH", d, bp)
            n = struct.unpack_from("<H", d, bp + 17)[0]
        except struct.error:
            return []
        if not 0 < n <= 64 or bp + 19 + n > body_end:
            return []
        nm = d[bp + 19:bp + 19 + n].decode("utf-8", "replace")
        if not all(32 <= ord(c) < 127 for c in nm):
            return []
        if not (0 <= a <= z < max(nframes, 1)):
            return []
        out.append({"from": a, "to": z, "name": nm})
        bp += 19 + n
    return out if bp == body_end else []


def load(path):
    d = open(path, "rb").read()
    if len(d) < 128 or struct.unpack_from("<H", d, 4)[0] != 0xA5E0:
        raise ValueError("不是 .aseprite（magic 0xA5E0 没对上）")
    _, _, nframes, W, H, depth = struct.unpack_from("<IHHHHH", d, 0)
    layers, tags, frames, pal = [], [], [], 0
    p, fi = 128, -1
    while p + 8 <= len(d) and fi + 1 < nframes:
        csize, cmagic = struct.unpack_from("<IH", d, p)
        if cmagic != 0xF1FA or csize < 8 or p + csize > len(d):
            break
        fi += 1
        dur = struct.unpack_from("<H", d, p + 8)[0]
        nch = struct.unpack_from("<H", d, p + 6)[0]
        off = find_sub(d, p, p + csize, nch)
        cels = []
        if off > 0:
            q, end = p + off, p + csize
            for _ in range(nch):
                if q + 6 > end:
                    break
                ss, st = struct.unpack_from("<IH", d, q)
                if ss < 6 or q + ss > end:
                    break
                if st == CT_LAYER:
                    b = q + 6
                    flags, ltype = struct.unpack_from("<HH", d, b)
                    name, _ = rd_string(d, b + 16)
                    if ltype == 0:
                        layers.append({"name": name, "visible": bool(flags & 1)})
                elif st == CT_CEL:
                    r = decode_cel(d, q)
                    if r and r[0] != "linked":
                        cels.append(r)
                elif st == CT_TAGS and not tags:
                    tags = read_tags(d, q, ss, nframes)
                elif st == CT_PALETTE and not pal:
                    try:
                        npal = struct.unpack_from("<H", d, q + 6)[0]
                        pal = npal
                    except struct.error:
                        pass
                q += ss
        frames.append({"dur": dur, "cels": cels})
        p += csize
    return {"path": path, "w": W, "h": H, "depth": depth, "nframes": len(frames),
            "layers": layers, "tags": tags, "frames": frames, "palette": pal}


# ------------------------------------------------------------------ 合成
def composite(doc, frame_i, skip=(), only_visible=False, order="RGBA"):
    img = Image.new("RGBA", (doc["w"], doc["h"]), (0, 0, 0, 0))
    layers = doc["layers"]
    f = doc["frames"][frame_i]
    for li, cx, cy, w, h, px in sorted(f["cels"], key=lambda r: r[0]):
        if li >= len(layers):
            continue
        L = layers[li]
        if only_visible and not L["visible"]:
            continue
        if any(s and s in L["name"] for s in skip):
            continue
        img.alpha_composite(Image.frombytes("RGBA", (w, h), px, "raw", order), (cx, cy))
    return img


def tile(img, scale, bg=None, pad=6):
    im = img.resize((img.width * scale, img.height * scale), Image.NEAREST)
    if bg is None:
        return im
    c = Image.new("RGBA", (im.width + pad * 2, im.height + pad * 2), bg)
    c.alpha_composite(im, (pad, pad))
    return c


def parse_bg(s):
    if not s:
        return None
    v = [int(x) for x in s.split(",")]
    while len(v) < 3:
        v.append(0)
    if len(v) == 3:
        v.append(255)
    return tuple(v)


def frame_range(doc, tag_name, frame):
    if tag_name:
        for t in doc["tags"]:
            if t["name"] == tag_name:
                return list(range(t["from"], min(t["to"] + 1, doc["nframes"])))
        raise SystemExit("找不到 TAG：%s（用 info 看有哪些）" % tag_name)
    if frame is not None:
        return [frame]
    return list(range(doc["nframes"]))


# ------------------------------------------------------------------ 命令
def cmd_info(files):
    out = []
    for path in files:
        try:
            doc = load(path)
        except Exception as e:
            out.append("=" * 78)
            out.append("!! 打不开 %s —— %s: %s" % (path, type(e).__name__, e))
            continue
        L = doc["layers"]
        out.append("=" * 78)
        out.append("%s" % os.path.basename(path))
        out.append("  画布 %dx%d  色深 %d  帧 %d  总时长 %.2fs  调色板 %d 色"
                   % (doc["w"], doc["h"], doc["depth"], doc["nframes"],
                      sum(f["dur"] for f in doc["frames"]) / 1000.0, doc["palette"]))
        out.append("  图层(下→上 %d 个): %s"
                   % (len(L), " | ".join("%d:%s%s" % (i, l["name"], "" if l["visible"] else "(隐)")
                                         for i, l in enumerate(L))))
        if doc["tags"]:
            tg = []
            for t in doc["tags"]:
                d = sum(doc["frames"][i]["dur"] for i in range(t["from"], min(t["to"] + 1, doc["nframes"])))
                tg.append("%s[f%d-%d, %d帧, %.2fs]" % (t["name"], t["from"], t["to"],
                                                       t["to"] - t["from"] + 1, d / 1000.0))
            out.append("  TAG(%d): %s" % (len(doc["tags"]), "  ".join(tg)))
        else:
            out.append("  TAG: 无")
        out.append("  每帧 cel 数: %s" % [len(f["cels"]) for f in doc["frames"]])
        out.append("  每帧时长(ms): %s" % [f["dur"] for f in doc["frames"]])
    text = "\n".join(out)
    print(text)
    return text


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    cmd = argv[1]
    if cmd == "info":
        cmd_info(argv[2:])
        return 0

    path = argv[2]
    outp = argv[3]
    scale, bg, frame, tag, order = 4, None, None, None, "RGBA"
    skip, only_visible = [], False
    a = argv[4:]
    i = 0
    while i < len(a):
        k = a[i]
        if k == "--frame":
            frame = int(a[i + 1]); i += 2
        elif k == "--tag":
            tag = a[i + 1]; i += 2
        elif k == "--scale":
            scale = int(a[i + 1]); i += 2
        elif k == "--bg":
            bg = parse_bg(a[i + 1]); i += 2
        elif k == "--skip":
            skip.append(a[i + 1]); i += 2
        elif k == "--only-visible":
            only_visible = True; i += 1
        elif k == "--order":
            order = a[i + 1]; i += 2
        else:
            raise SystemExit("不认识参数 " + k)

    doc = load(path)
    idxs = frame_range(doc, tag, frame)
    imgs = [composite(doc, i, skip, only_visible, order) for i in idxs]

    if cmd == "png":
        tile(imgs[0], scale, bg).save(outp)
        print("写出 %s（帧 %d，%dx%d → x%d）" % (outp, idxs[0], doc["w"], doc["h"], scale))
    elif cmd == "sheet":
        cols = max(1, min(len(imgs), 8))
        rows = (len(imgs) + cols - 1) // cols
        cw, chh = doc["w"] * scale + 6, doc["h"] * scale + 6
        canvas = Image.new("RGBA", (cw * cols, chh * rows), bg or (30, 30, 40, 255))
        for n, im in enumerate(imgs):
            canvas.alpha_composite(tile(im, scale, None), ((n % cols) * cw + 3, (n // cols) * chh + 3))
        canvas.save(outp)
        print("写出 %s（%d 帧，%d 列，单帧 %dx%d x%d）"
              % (outp, len(imgs), cols, doc["w"], doc["h"], scale))
    else:
        raise SystemExit("命令只有 info / png / sheet")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

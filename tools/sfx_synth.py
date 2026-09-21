# -*- coding: utf-8 -*-
"""
卡通风格音效合成器 —— SteamPunkExtraction / Assets/Audio/sfx
纯 numpy + scipy，无需任何外部依赖、无需联网、无需 API key。

技术路线：程序化合成（减法 + FM + Karplus-Strong 拨弦），因此成品是
"合成器质感"，配合卡通渲染风格反而合适；不会是真实乐器录音。

用法：
    python tools/sfx_synth.py              # 生成全部
    python tools/sfx_synth.py sword bow    # 只生成指定分组
    python tools/sfx_synth.py --list       # 列出分组

调音色：所有参数都在本文件的 SFX 表里，改完重跑即覆盖同名 wav。
"""

import os
import sys
import math
import time
import wave
import json

import numpy as np
from scipy import signal

SR = 44100
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "Assets", "Audio", "sfx")


# ------------------------------------------------------------------ 基础积木
def _n(dur):
    return max(1, int(round(dur * SR)))


def _freq(f, n):
    """把 freq 规范成逐采样点的频率数组。f 可以是标量 / 一元函数 f(t) / 关键点数组。"""
    tt = np.arange(n, dtype=float) / SR
    if callable(f):
        return np.maximum(np.asarray(f(tt), dtype=float), 1.0)
    arr = np.asarray(f, dtype=float)
    if arr.ndim == 0:
        return np.full(n, float(arr))
    return np.interp(np.linspace(0.0, 1.0, n), np.linspace(0.0, 1.0, len(arr)), arr)


def osc(freq, dur, wave="sine", phase0=0.0):
    """振荡器。freq 支持标量 / f(t) / 关键点，因此天然支持滑音。"""
    n = _n(dur)
    fr = _freq(freq, n)
    ph = 2.0 * np.pi * np.cumsum(fr) / SR + phase0
    cyc = ph / (2.0 * np.pi)
    frac = cyc - np.floor(cyc)
    if wave == "sine":
        y = np.sin(ph)
    elif wave == "tri":
        y = 4.0 * np.abs(frac - 0.5) - 1.0
    elif wave == "saw":
        y = 2.0 * frac - 1.0
    elif wave == "square":
        y = np.where(frac < 0.5, 1.0, -1.0)
    elif wave == "pulse":
        y = np.where(frac < 0.2, 1.0, -1.0)
    else:
        raise ValueError("unknown wave: %s" % wave)
    return y


def nz(dur, seed=0):
    """白噪声（固定 seed -> 可复现）。"""
    return np.random.default_rng(seed).standard_normal(_n(dur))


def fmos(cf, ratio, dur, index=3.0, idecay=0.25):
    """FM 合成，index 指数衰减 —— 金属 / 铃类音色靠它。"""
    n = _n(dur)
    tt = np.arange(n, dtype=float) / SR
    ie = index * np.exp(-tt / max(dur * idecay, 1e-4))
    return np.sin(2.0 * np.pi * cf * tt + ie * np.sin(2.0 * np.pi * cf * ratio * tt))


def karplus(freq, dur, damp=0.996, bright=0.6, seed=0):
    """Karplus-Strong 拨弦（弓弦、更复杂的弦鸣）。"""
    p = max(2, int(round(SR / float(freq))))
    n = _n(dur)
    exc = np.random.default_rng(seed).standard_normal(p)
    if bright < 1.0:
        exc = signal.lfilter([1.0 - bright], [1.0, -bright], exc)
    a = np.zeros(p + 2)
    a[0] = 1.0
    a[p] = -0.5 * damp
    a[p + 1] = -0.5 * damp
    x = np.zeros(n)
    x[:p] = exc
    return signal.lfilter([1.0], a, x)


def lp(x, fc, order=2):
    fc = float(np.clip(fc, 20.0, SR * 0.45))
    return signal.sosfilt(signal.butter(order, fc / (SR / 2), btype="low", output="sos"), x)


def hp(x, fc, order=2):
    fc = float(np.clip(fc, 20.0, SR * 0.45))
    return signal.sosfilt(signal.butter(order, fc / (SR / 2), btype="high", output="sos"), x)


def bp(x, f0, Q=1.5, order=2):
    half = f0 / (2.0 * Q)
    lo = max(20.0, f0 - half)
    hi = min(SR * 0.47, f0 + half)
    if hi <= lo * 1.02:
        hi = min(SR * 0.47, lo * 1.02)
    return signal.sosfilt(
        signal.butter(order, [lo / (SR / 2), hi / (SR / 2)], btype="band", output="sos"), x)


def sweep(x, f0, f1, Q=2.0, frames=48, order=2, shape="exp"):
    """带通中心频率随时间扫 —— whoosh / 破空 / 金属摩擦都靠它。
    实现：分帧(50% 重叠 hann)后逐帧带通，重叠相加。"""
    n = len(x)
    hop = max(8, n // frames)
    win = np.hanning(hop * 2)
    out = np.zeros(n + hop * 2)
    us = np.arange(frames, dtype=float) / max(frames - 1, 1)
    for i in range(frames):
        u = us[i]
        f = f0 * (f1 / f0) ** u if shape == "exp" else f0 + (f1 - f0) * u
        s = i * hop
        seg = x[s:s + hop * 2]
        if len(seg) < 8:
            continue
        y = bp(seg, f, Q=Q, order=order)
        out[s:s + len(seg)] += y * win[:len(seg)]
    return out[:n]


def env(n, pts):
    """关键点包络。pts = [(0~1 位置, 幅度), ...]"""
    ts = np.array([p[0] for p in pts], dtype=float)
    vs = np.array([p[1] for p in pts], dtype=float)
    return np.interp(np.linspace(0.0, 1.0, n), ts, vs)


def decay_env(n, dur, tau):
    """快速 attack + 指数衰减。"""
    tt = np.arange(n, dtype=float) / SR
    return np.clip(tt / 0.0015, 0.0, 1.0) * np.exp(-tt / tau)


def fit(x, n):
    x = np.asarray(x, dtype=float)
    return x[:n] if len(x) >= n else np.pad(x, (0, n - len(x)))


def mix(*xs):
    n = max(len(x) for x in xs)
    out = np.zeros(n)
    for x in xs:
        out += fit(x, n)
    return out


def trim_tail(x, thresh_db=-54.0, keep=0.025):
    """裁掉尾部听不见的静音段，避免文件里留一堆无用长度。"""
    x = np.asarray(x, dtype=float)
    if len(x) == 0:
        return x
    thr = np.max(np.abs(x)) * (10 ** (thresh_db / 20.0))
    idx = np.where(np.abs(x) > thr)[0]
    if len(idx) == 0:
        return x[:min(len(x), _n(0.05))]
    return x[:min(len(x), int(idx[-1]) + _n(keep))]


def render(*xs, **kw):
    """多段合并 -> 去直流 -> 归一化到 target 峰值 -> 软限幅 -> 裁尾 -> 首尾淡入淡出。

    自动按最长段对齐（短的后补零），所以各段时长不必相等。
    最后一个位置参数若是标量，则视为归一化峰值 level。
    """
    level = float(kw.get("level", 0.85))
    args = list(xs)
    if len(args) > 1 and np.isscalar(args[-1]):
        level = float(args[-1])
        args = args[:-1]
    x = mix(*[np.asarray(a, dtype=float) for a in args]) if len(args) > 1 \
        else np.asarray(args[0], dtype=float)
    x = np.nan_to_num(x)
    x = x - float(np.mean(x))                 # 去直流（反馈类合成容易攒出偏移）
    m = float(np.max(np.abs(x))) or 1.0
    x = x / m * level
    x = np.tanh(x * 1.15) / math.tanh(1.15)
    x = trim_tail(x)
    fi, fo = _n(0.002), _n(0.008)
    if fi > 0:
        x[:fi] *= np.linspace(0.0, 1.0, fi)
    if fo > 0:
        x[-fo:] *= np.linspace(1.0, 0.0, fo)
    return np.clip(x, -1.0, 1.0)


# ------------------------------------------------------------------ 剑
def s_sword_swing(v=0):
    """挥剑破空。带通扫频 600 -> 2600 再回落，卡通式"咻"。"""
    dur = 0.30
    base = nz(dur, seed=100 + v)
    body = sweep(base, 520 + v * 60, 2500 + v * 300, Q=3.2, frames=56, order=2, shape="exp")
    body *= env(len(body), [(0, 0), (0.16, 1.0), (0.55, 0.55), (1, 0.0)])
    # 上滑的高频"咝"，加一点点金属亮泽
    sheen = osc(np.linspace(900, 1900 + v * 120, 40), dur * 0.7, "tri")
    sheen *= decay_env(len(sheen), dur * 0.7, 0.055)
    # 低速时的低频"呼"
    low = lp(nz(dur, seed=200 + v), 300)
    low *= env(len(low), [(0, 0), (0.2, 0.8), (1, 0)])
    return render(body * 1.0, sheen * 0.22, low * 0.35, 0.72)


def s_sword_hit_flesh():
    """命中肉体/布：闷"噗"，低频下坠 + 短噪声，带一点湿感。"""
    dur = 0.22
    thud = osc(np.linspace(210, 62, 60), dur, "sine")
    thud *= decay_env(len(thud), dur, 0.055)
    squelch = bp(nz(dur, seed=301), 700, Q=1.1)
    squelch *= decay_env(len(squelch), dur, 0.035)
    click = hp(nz(0.05, seed=302), 1800) * decay_env(_n(0.05), 0.05, 0.006)
    return render(thud * 1.0, squelch * 0.55, click * 0.4, 0.80)


def s_sword_hit_metal():
    """命中金属/铠甲："叮——"，非谐泛音 + FM 亮芯。"""
    dur = 0.55
    core = fmos(1150, 1.41, dur, index=6.0, idecay=0.12) * decay_env(_n(dur), dur, 0.14)
    parts = [core]
    for f, a, tau in ((2130, 0.55, 0.10), (3370, 0.38, 0.07), (4780, 0.26, 0.05)):
        parts.append(osc(f, dur, "sine") * decay_env(_n(dur), dur, tau) * a)
    hit = hp(nz(0.04, seed=311), 2500) * decay_env(_n(0.04), 0.04, 0.004)
    parts.append(hit * 0.5)
    return render(mix(*parts), 0.82)


def s_sword_draw():
    """拔剑出鞘：金属摩擦上滑 + 尾部清亮剑鸣。"""
    dur = 0.50
    fric = sweep(nz(dur, seed=321), 700, 3200, Q=7.0, frames=64, order=2, shape="exp")
    fric *= env(len(fric), [(0, 0.05), (0.35, 0.9), (0.75, 1.0), (1, 0.0)])
    ring = mix(*[osc(f, dur * 0.8, "sine") * decay_env(_n(dur * 0.8), dur * 0.8, t) * a
                 for f, a, t in ((2600, 0.35, 0.16), (4100, 0.22, 0.11))])
    ring = fit(ring, _n(dur)) * np.interp(np.arange(_n(dur)) / _n(dur), [0, 0.45, 1], [0, 0.4, 1])
    return render(fric * 0.9, ring * 0.7, 0.70)


# ------------------------------------------------------------------ 弓
def s_bow_draw():
    """拉弓：弓臂受力吱呀 + 弓弦张力，音量渐强到拉满。"""
    dur = 0.62
    creak = sweep(nz(dur, seed=401), 240, 520, Q=9.0, frames=72, order=2, shape="lin")
    # 摩擦的颗粒感：慢速 AM
    tt = np.arange(len(creak), dtype=float) / SR
    creak *= (0.55 + 0.45 * np.sin(2 * np.pi * 23 * tt))
    creak *= env(len(creak), [(0, 0.02), (0.35, 0.5), (0.82, 1.0), (0.93, 0.5), (1, 0.0)])
    wood = lp(nz(dur, seed=402), 420)
    wood *= env(_n(dur), [(0, 0), (0.5, 0.35), (0.85, 0.75), (0.95, 0.35), (1, 0.0)])
    return render(creak * 1.0, wood * 0.5, 0.62)


def s_bow_release():
    """放箭：弦振 "thwip" + 箭矢离弦的短促气流。"""
    dur = 0.42
    string = karplus(235, dur, damp=0.985, bright=0.45, seed=411)
    string *= decay_env(len(string), dur, 0.10)
    air = sweep(nz(dur, seed=412), 1800, 520, Q=2.4, frames=40, shape="exp")
    air *= env(len(air), [(0, 0), (0.10, 1.0), (0.5, 0.35), (1, 0.0)])
    body = lp(nz(0.12, seed=413), 900) * decay_env(_n(0.12), 0.12, 0.03)
    return render(string * 0.85, air * 0.75, body * 0.5, 0.80)


def s_arrow_hit_wood():
    """箭插木板："咚" + 箭杆余颤。"""
    dur = 0.34
    thunk = osc(np.linspace(320, 120, 50), 0.18, "tri") * decay_env(_n(0.18), 0.18, 0.045)
    wig = karplus(180, dur, damp=0.952, bright=0.35, seed=421)
    wig *= decay_env(len(wig), dur, 0.10)
    crack = bp(nz(0.09, seed=422), 1500, Q=1.2) * decay_env(_n(0.09), 0.09, 0.014)
    return render(thunk * 0.9, wig * 0.55, crack * 0.45, 0.80)


def s_arrow_hit_flesh():
    """箭命中肉体：干脆一记闷响 + 极短湿噪。"""
    dur = 0.26
    body = osc(np.linspace(260, 85, 50), dur, "sine") * decay_env(_n(dur), dur, 0.05)
    wet = bp(nz(dur, seed=431), 900, Q=1.4) * decay_env(_n(dur), dur, 0.03)
    tick = hp(nz(0.035, seed=432), 3200) * decay_env(_n(0.035), 0.035, 0.004)
    return render(body, wet * 0.5, tick * 0.35, 0.80)


# ------------------------------------------------------------------ 火枪（非机械枪）
def s_gun_fire():
    """火枪/燧发枪开火。黑火药一声闷爆：低频坠 + 爆裂 + 尾巴 lingering smoke。
    刻意避开现代自动武器的金属连响和枪机咔哒。"""
    dur = 0.75
    # 爆响核心
    boom_body = osc(np.linspace(240, 48, 80), 0.35, "sine")
    boom_body *= env(len(boom_body), [(0, 0), (0.02, 1.0), (0.35, 0.45), (1, 0.0)])
    # 火药燃爆的宽频击打
    crack = lp(nz(0.30, seed=501), 6000)
    crack *= env(len(crack), [(0, 0), (0.008, 1.0), (0.25, 0.25), (1, 0.0)])
    crack = hp(crack, 260)
    # 木质枪托的"咚"
    stock = osc(np.linspace(180, 70, 40), 0.16, "tri") * decay_env(_n(0.16), 0.16, 0.035)
    # 尾焰 / 硝烟
    tail = sweep(nz(dur, seed=502), 2600, 320, Q=1.1, frames=64, order=2, shape="exp")
    tail *= env(len(tail), [(0, 0), (0.06, 0.85), (0.45, 0.35), (1, 0.0)])
    out = mix(boom_body * 1.0, crack * 0.85, stock * 0.45, tail * 0.55)
    return render(out, 0.95)


def s_gun_cock():
    """击锤 / 扳机：两记干脆金属 click（后跟的短金属余音）。"""
    dur = 0.22
    parts = []
    for i, (pos, f, amp) in enumerate(((0.0, 2400, 1.0), (0.075, 1700, 0.7))):
        seg = hp(nz(0.05, seed=511 + i), 1800) * decay_env(_n(0.05), 0.05, 0.005)
        parts.append(np.pad(seg * amp, (_n(pos), 0))[:_n(dur)])
    parts.append(np.pad(osc(2600, 0.10, "sine") * decay_env(_n(0.10), 0.10, 0.035) * 0.25,
                        (_n(0.075), 0))[:_n(dur)])
    return render(mix(*parts), 0.72)


def s_gun_reload():
    """通条装填：金属杆捅进枪管 + 纸包压实，三下带节奏。"""
    dur = 0.85
    parts = []
    for i, pos in enumerate((0.0, 0.22, 0.42)):
        rod = bp(nz(0.14, seed=521 + i), 1500 + i * 180, Q=3.0)
        rod *= decay_env(len(rod), 0.14, 0.028)
        parts.append(np.pad(rod * (1.0 - i * 0.12), (_n(pos), 0))[:_n(dur)])
    paper = sweep(nz(0.30, seed=525), 4200, 1400, Q=1.6, frames=32, shape="exp")
    paper *= env(len(paper), [(0, 0), (0.15, 0.6), (0.6, 0.3), (1, 0)])
    parts.append(np.pad(paper * 0.45, (_n(0.50), 0))[:_n(dur)])
    seat = osc(np.linspace(160, 80, 30), 0.12, "tri") * decay_env(_n(0.12), 0.12, 0.03)
    parts.append(np.pad(seat * 0.5, (_n(0.68), 0))[:_n(dur)])
    return render(mix(*parts), 0.68)


def s_gun_dryfire():
    """空枪：一记空落落的咔 + 极短闷响，没有爆声。"""
    dur = 0.24
    click = hp(nz(0.045, seed=531), 2200) * decay_env(_n(0.045), 0.045, 0.004)
    hollow = bp(nz(0.18, seed=532), 420, Q=4.0) * decay_env(_n(0.18), 0.18, 0.035)
    return render(mix(click * 0.9, hollow * 0.5, np.pad(hollow * 0.3, (_n(0.02), 0))[:_n(dur)]), 0.60)


# ------------------------------------------------------------------ 角色通用
def s_jump():
    """起跳：卡通上滑 "wah-up"，三角波 + 轻气流。"""
    dur = 0.26
    body = osc(np.linspace(330, 880, 60), dur, "tri")
    body *= env(len(body), [(0, 0), (0.06, 1.0), (0.55, 0.6), (1, 0.0)])
    air = sweep(nz(dur, seed=601), 900, 2400, Q=2.5, frames=32, shape="exp")
    air *= env(len(air), [(0, 0), (0.2, 0.55), (1, 0.0)])
    return render(body * 1.0, air * 0.35, 0.72)


def s_land():
    """落地：闷"咚" + 短促形变抖尾。"""
    dur = 0.24
    thud = osc(np.linspace(190, 62, 50), dur, "sine") * decay_env(_n(dur), dur, 0.045)
    dirt = lp(nz(0.12, seed=611), 700) * decay_env(_n(0.12), 0.12, 0.02)
    wob = osc(np.linspace(120, 90, 30), 0.14, "tri") * decay_env(_n(0.14), 0.14, 0.05)
    return render(thud * 1.0, dirt * 0.45, wob * 0.35, 0.72)


def s_dash():
    """冲刺/闪避：快速掠过的气流。"""
    dur = 0.34
    air = sweep(nz(dur, seed=621), 300, 3000, Q=2.2, frames=48, shape="exp")
    air *= env(len(air), [(0, 0), (0.28, 1.0), (0.75, 0.4), (1, 0.0)])
    tail = lp(nz(dur, seed=622), 500) * env(_n(dur), [(0, 0), (0.3, 0.35), (1, 0)])
    return render(air * 1.0, tail * 0.4, 0.68)


def s_hurt():
    """受伤：卡通化的惊叫 "呃！"，双振荡微失谐制造滑稽感。"""
    dur = 0.30
    tt = np.arange(_n(dur), dtype=float) / SR
    f = np.interp(tt, [0, 0.06, 0.30], [520, 900, 430])
    ph = 2 * np.pi * np.cumsum(f) / SR
    body = np.sin(ph) * 0.6 + np.sin(ph * 1.007 + 0.4) * 0.5
    body *= env(len(body), [(0, 0), (0.05, 1.0), (0.45, 0.6), (1, 0.0)])
    grit = bp(nz(dur, seed=631), 1200, Q=1.0) * decay_env(_n(dur), dur, 0.05)
    return render(body, grit * 0.28, 0.74)


def s_die():
    """倒地：下坠的 "waaaah"，尾部沉降，卡通葬送音。"""
    dur = 0.90
    body = osc(np.linspace(560, 130, 90), dur, "tri")
    body *= env(len(body), [(0, 0), (0.05, 1.0), (0.55, 0.55), (1, 0.0)])
    # 一点点颤抖音，卡通感
    tt = np.arange(_n(dur), dtype=float) / SR
    vib = 1.0 + 0.12 * np.sin(2 * np.pi * 11 * tt) * np.clip(tt / 0.15, 0, 1)
    body *= vib
    drop = osc(np.linspace(120, 55, 40), 0.35, "sine") * decay_env(_n(0.35), 0.35, 0.10)
    return render(body * 0.95, drop * 0.4, 0.74)


def s_step_grass(v=0):
    """草地脚步：闷、软、短，沙沙声。"""
    dur = 0.14
    body = lp(nz(dur, seed=700 + v), 900 + v * 90)
    body *= env(len(body), [(0, 0), (0.05, 1.0), (0.4, 0.5), (1, 0.0)])
    thud = osc(110 + v * 8, 0.06, "sine") * decay_env(_n(0.06), 0.06, 0.016)
    return render(body * 0.85, thud * 0.55, 0.42)


def s_step_stone(v=0):
    """石地脚步：脆、短，有鞋钉感。"""
    dur = 0.16
    tick = hp(nz(0.05, seed=720 + v), 2200 + v * 200) * decay_env(_n(0.05), 0.05, 0.006)
    body = bp(nz(dur, seed=730 + v), 620 + v * 70, Q=1.6)
    body *= env(len(body), [(0, 0), (0.04, 1.0), (0.35, 0.4), (1, 0.0)])
    ring = osc(1400 + v * 120, 0.10, "sine") * decay_env(_n(0.10), 0.10, 0.02) * 0.18
    return render(body * 0.9, tick * 0.5, ring, 0.46)


# ------------------------------------------------------------------ 拾取 / UI
def blip(freq, dur, wave="square", tau=None, seed=None):
    """单个短音，带轻微音高抖动，卡通音的基本单元。"""
    n = _n(dur)
    y = osc(freq, dur, wave)
    y *= decay_env(n, dur, tau if tau else dur * 0.45)
    return y


def s_pickup_coin():
    """金币：经典两音上行，明亮短促。"""
    a = blip(988, 0.075, "square", 0.030)
    b = np.pad(blip(1319, 0.20, "square", 0.070), (_n(0.070), 0))
    shimmer = np.pad(osc(2637, 0.22, "tri") * decay_env(_n(0.22), 0.22, 0.06) * 0.25,
                     (_n(0.070), 0))
    return render(mix(a, b * 0.9, shimmer), 0.70)


def s_pickup_item():
    """拾取物品：三音上琶音，柔和三角形。"""
    parts, gaps = [], [0.0, 0.065, 0.130]
    for i, f in enumerate((523, 659, 880)):
        parts.append(np.pad(blip(f, 0.16, "tri", 0.055), (_n(gaps[i]), 0)))
    return render(mix(*parts), 0.66)


def s_pickup_ammo():
    """拾取弹药：干脆金属两下 "chk-chk"。"""
    parts = []
    for i, pos in enumerate((0.0, 0.09)):
        seg = hp(nz(0.06, seed=741 + i), 2000 + i * 400)
        seg *= decay_env(len(seg), 0.06, 0.007)
        parts.append(np.pad(seg, (_n(pos), 0)))
    parts.append(np.pad(blip(1568, 0.10, "tri", 0.04) * 0.35, (_n(0.15), 0)))
    return render(mix(*parts), 0.62)


def s_ui_click():
    """UI 点击：极短、略带下坠的方波。"""
    y = osc(np.linspace(1050, 820, 30), 0.055, "square")
    y *= decay_env(len(y), 0.055, 0.020)
    return render(y, 0.45)


def s_ui_hover():
    """UI 悬停：更轻更短的高音。"""
    y = osc(np.linspace(1250, 1450, 20), 0.045, "tri")
    y *= decay_env(len(y), 0.045, 0.018)
    return render(y, 0.30)


def s_ui_confirm():
    """确认：两音上行。"""
    return render(mix(blip(659, 0.09, "tri", 0.035),
                      np.pad(blip(988, 0.14, "tri", 0.055), (_n(0.075), 0)) * 0.9), 0.52)


def s_ui_cancel():
    """返回 / 取消：两音下行。"""
    return render(mix(blip(659, 0.09, "tri", 0.035),
                      np.pad(blip(494, 0.15, "tri", 0.060), (_n(0.075), 0)) * 0.9), 0.52)


def s_levelup():
    """升级：五音上行琶音 + 尾部闪光。"""
    gaps = [0.0, 0.060, 0.120, 0.180, 0.240]
    parts = []
    for i, f in enumerate((523, 659, 784, 1047, 1319)):
        parts.append(np.pad(blip(f, 0.22, "tri", 0.07), (_n(gaps[i]), 0)))
    shine = np.pad(sweep(nz(0.5, seed=761), 2000, 6000, Q=3.0, frames=40),
                   (_n(0.26), 0))
    shine *= np.pad(env(_n(0.5), [(0, 0), (0.2, 0.35), (1, 0.0)]), (_n(0.26), 0))[:len(shine)]
    return render(mix(*parts) * 0.9, shine * 0.5, 0.68)


def s_victory():
    """胜利：短号角动机（哒-哒-哒哒-长），锯齿+三角叠加。"""
    notes = ((0.00, 523, 0.11), (0.12, 523, 0.11), (0.24, 523, 0.11),
             (0.36, 659, 0.16), (0.53, 784, 0.46))
    parts = []
    for pos, f, dl in notes:
        lead = osc(f, dl, "saw") * 0.35 + osc(f, dl, "tri") * 0.5
        e = env(_n(dl), [(0, 0), (0.06, 1.0), (0.5, 0.75), (1, 0.0)])
        lead = lead * e
        harm = osc(f * 1.5, dl, "tri") * 0.22 * e
        parts.append(np.pad(lead + harm, (_n(pos), 0)))
    return render(mix(*parts), 0.72)


def s_fail():
    """失败：下行两音 "呜—呜"，带轻微走音的滑稽感。"""
    parts = []
    for i, (pos, f0, f1, dl) in enumerate(((0.0, 494, 440, 0.22), (0.24, 415, 330, 0.42))):
        y = osc(np.linspace(f0, f1, 40), dl, "saw") * 0.35 + osc(np.linspace(f0, f1, 40), dl, "tri") * 0.5
        y *= env(_n(dl), [(0, 0), (0.08, 1.0), (0.55, 0.7), (1, 0.0)])
        parts.append(np.pad(y, (_n(pos), 0)))
    return render(mix(*parts), 0.68)


def s_chest_open():
    """开箱：木盖吱呀 + 锁扣一响 + 内部宝光。"""
    parts = []
    lock = hp(nz(0.05, seed=771), 2600) * decay_env(_n(0.05), 0.05, 0.005)
    parts.append(lock * 0.6)
    creak = sweep(nz(0.45, seed=772), 300, 900, Q=7.0, frames=48, shape="lin")
    creak *= env(len(creak), [(0, 0), (0.2, 0.7), (0.6, 1.0), (1, 0.15)])
    parts.append(np.pad(creak * 0.8, (_n(0.05), 0)))
    lid = osc(np.linspace(150, 90, 30), 0.18, "tri") * decay_env(_n(0.18), 0.18, 0.04)
    parts.append(np.pad(lid * 0.55, (_n(0.42), 0)))
    shine = sweep(nz(0.5, seed=773), 1500, 5200, Q=3.0, frames=40)
    sh = np.pad(env(_n(0.5), [(0, 0), (0.25, 0.4), (1, 0.0)]), (_n(0.42), 0))
    shine = np.pad(shine, (_n(0.42), 0)) * sh[:len(np.pad(shine, (_n(0.42), 0)))]
    parts.append(shine * 0.45)
    return render(mix(*parts), 0.66)


# ------------------------------------------------------------------ 清单
def _series(fn, count):
    return [(None, fn, {"v": i}) for i in range(count)]


SFX = {
    "sword": [
        ("sword_swing_01.wav", s_sword_swing, {"v": 0}),
        ("sword_swing_02.wav", s_sword_swing, {"v": 1}),
        ("sword_swing_03.wav", s_sword_swing, {"v": 2}),
        ("sword_draw.wav", s_sword_draw, {}),
        ("sword_hit_flesh.wav", s_sword_hit_flesh, {}),
        ("sword_hit_metal.wav", s_sword_hit_metal, {}),
    ],
    "bow": [
        ("bow_draw.wav", s_bow_draw, {}),
        ("bow_release.wav", s_bow_release, {}),
        ("arrow_hit_wood.wav", s_arrow_hit_wood, {}),
        ("arrow_hit_flesh.wav", s_arrow_hit_flesh, {}),
    ],
    "gun": [
        ("gun_fire.wav", s_gun_fire, {}),
        ("gun_cock.wav", s_gun_cock, {}),
        ("gun_reload.wav", s_gun_reload, {}),
        ("gun_dryfire.wav", s_gun_dryfire, {}),
    ],
    "char": [
        ("jump.wav", s_jump, {}),
        ("land.wav", s_land, {}),
        ("dash.wav", s_dash, {}),
        ("hurt.wav", s_hurt, {}),
        ("die.wav", s_die, {}),
        ("step_grass_01.wav", s_step_grass, {"v": 0}),
        ("step_grass_02.wav", s_step_grass, {"v": 1}),
        ("step_grass_03.wav", s_step_grass, {"v": 2}),
        ("step_grass_04.wav", s_step_grass, {"v": 3}),
        ("step_stone_01.wav", s_step_stone, {"v": 0}),
        ("step_stone_02.wav", s_step_stone, {"v": 1}),
        ("step_stone_03.wav", s_step_stone, {"v": 2}),
        ("step_stone_04.wav", s_step_stone, {"v": 3}),
    ],
    "ui": [
        ("pickup_coin.wav", s_pickup_coin, {}),
        ("pickup_item.wav", s_pickup_item, {}),
        ("pickup_ammo.wav", s_pickup_ammo, {}),
        ("ui_click.wav", s_ui_click, {}),
        ("ui_hover.wav", s_ui_hover, {}),
        ("ui_confirm.wav", s_ui_confirm, {}),
        ("ui_cancel.wav", s_ui_cancel, {}),
        ("levelup.wav", s_levelup, {}),
        ("victory.wav", s_victory, {}),
        ("fail.wav", s_fail, {}),
        ("chest_open.wav", s_chest_open, {}),
    ],
}

GROUP_LABEL = {
    "sword": "武器 · 剑",
    "bow": "武器 · 弓",
    "gun": "武器 · 火枪",
    "char": "角色 · 移动与受创",
    "ui": "拾取 · UI · 事件",
}


# ------------------------------------------------------------------ 输出
def envelope(x, bins=96):
    """RMS 包络，用于播放器里画波形（不依赖浏览器端解码）。"""
    n = len(x)
    step = max(1, n // bins)
    m = (n // step) * step
    if m <= 0:
        return []
    a = np.abs(x[:m]).reshape(-1, step)
    e = np.sqrt((a ** 2).mean(axis=1))
    pk = float(np.max(e)) or 1.0
    return [round(float(v / pk), 3) for v in e]


def write_wav(path, x):
    x = np.clip(np.asarray(x, dtype=float), -1.0, 1.0)
    pcm = (x * 32767.0).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    return os.path.getsize(path)


def main(argv):
    if "--list" in argv:
        for g in SFX:
            print("%-8s %-24s %d 个" % (g, GROUP_LABEL[g], len(SFX[g])))
        return 0

    groups = [a for a in argv if not a.startswith("-")] or list(SFX.keys())
    os.makedirs(OUT_DIR, exist_ok=True)
    total = 0
    manifest = {"sample_rate": SR, "channels": 1, "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
                "groups": []}

    for g in groups:
        if g not in SFX:
            print("  跳过未知分组:", g)
            continue
        items = SFX[g]
        print("[%s] %s  (%d)" % (g, GROUP_LABEL[g], len(items)))
        entries = []
        for name, fn, kw in items:
            t0 = time.time()
            x = fn(**kw)
            n = len(x)
            path = os.path.join(OUT_DIR, name)
            size = write_wav(path, x)
            peak = float(np.max(np.abs(x)))
            rms = float(np.sqrt(np.mean(x ** 2)))
            entries.append({"file": name, "dur": round(n / SR, 3), "peak": round(peak, 3),
                            "rms": round(rms, 4), "bytes": size, "env": envelope(x)})
            print("   %-22s %6.3fs  peak=%.2f  %6.1f KB  (%.2fs)" %
                  (name, n / SR, peak, size / 1024.0, time.time() - t0))
            total += 1
        manifest["groups"].append({"id": g, "label": GROUP_LABEL[g], "items": entries})

    mf = os.path.join(OUT_DIR, "_manifest.json")
    with open(mf, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    # 再输出一份 JS 变量版：播放器用 <script src> 加载，file:// 直接双击也能工作
    with open(os.path.join(OUT_DIR, "_manifest.js"), "w", encoding="utf-8") as f:
        f.write("window.SFX_MANIFEST = ")
        json.dump(manifest, f, ensure_ascii=False)
        f.write(";\n")
    print("\n共生成 %d 个音效 ->  %s" % (total, OUT_DIR))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

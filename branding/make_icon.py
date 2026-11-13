# -*- coding: utf-8 -*-
"""
App 图标生成器。**生成器驱动,不要手改 PNG。**

设计 = 产品本身:两条从同一点分叉的路径。
  实线 = 你实际走的     虚线 = 你没走的那条
这正是「反事实计算器」画出来的样子。8 个竞品的图标全是烛台/K线/钱袋。

★ 第一版的虚线画成了拉链:原因是按「剩余长度」做插值,
  每段折线内重复归一化,dash 长度被压扁。改成**先算累计弧长,再按弧长取点**。
"""
from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path
import math

OUT = Path(__file__).resolve().parent
S, SS = 1024, 4                      # 输出边长 / 超采样倍数

BG_TOP, BG_BOT = (13, 17, 27), (28, 37, 58)
ACTUAL = (48, 209, 128)              # 实线:你做的
ALT    = (255, 165, 74)              # 虚线:替代方案
NODE   = (245, 248, 253)

def lerp(a, b, t): return tuple(round(x + (y - x) * t) for x, y in zip(a, b))

def densify(pts, step=2.0):
    """把折线加密成等距点列,并返回累计弧长。"""
    out, acc = [pts[0]], [0.0]
    for p0, p1 in zip(pts, pts[1:]):
        L = math.dist(p0, p1)
        n = max(int(L / step), 1)
        for i in range(1, n + 1):
            t = i / n
            out.append((p0[0] + (p1[0]-p0[0])*t, p0[1] + (p1[1]-p0[1])*t))
            acc.append(acc[-1] + L / n)
    return out, acc

def at_length(pts, acc, s):
    """按弧长取点(线性查找足够,点数不多)。"""
    if s <= 0: return pts[0]
    if s >= acc[-1]: return pts[-1]
    for i in range(1, len(acc)):
        if acc[i] >= s:
            t = (s - acc[i-1]) / max(acc[i] - acc[i-1], 1e-9)
            p0, p1 = pts[i-1], pts[i]
            return (p0[0] + (p1[0]-p0[0])*t, p0[1] + (p1[1]-p0[1])*t)
    return pts[-1]

def stroke(d, pts, color, w, round_caps=True):
    d.line(pts, fill=color, width=w, joint="curve")
    if round_caps:
        for p in (pts[0], pts[-1]):
            d.ellipse([p[0]-w/2, p[1]-w/2, p[0]+w/2, p[1]+w/2], fill=color)

def dashed(d, pts, color, w, dash, gap):
    """按累计弧长切虚线 —— 每一段都是等长的。"""
    dense, acc = densify(pts)
    total, s = acc[-1], 0.0
    while s < total:
        e = min(s + dash, total)
        seg = [at_length(dense, acc, s)]
        t = s
        while t < e:
            t = min(t + 4.0, e)
            seg.append(at_length(dense, acc, t))
        if len(seg) > 1: stroke(d, seg, color, w)
        s = e + gap

def build():
    W = S * SS
    img = Image.new("RGB", (W, W), BG_TOP)
    d = ImageDraw.Draw(img)
    for y in range(W):
        d.line([(0, y), (W, y)], fill=lerp(BG_TOP, BG_BOT, y / W))

    lw   = int(0.040 * W)                     # 线宽
    fork = (0.315 * W, 0.615 * W)

    stem = [(0.135 * W, 0.735 * W), (0.21 * W, 0.695 * W), fork]

    actual = [fork]                           # 实线:分叉后平缓,提前收住
    for i in range(1, 81):
        t = i / 80
        actual.append((fork[0] + t * 0.36 * W,
                       fork[1] - 0.155 * W * (1 - (1 - t) ** 2.2)))

    alt = [fork]                              # 虚线:更陡,冲得更高更远
    for i in range(1, 81):
        t = i / 80
        alt.append((fork[0] + t * 0.50 * W,
                    fork[1] - 0.40 * W * (t ** 0.68)))

    # 柔光只给虚线一点点,暗示「它没真的发生」
    glow = Image.new("RGB", (W, W), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.line(alt, fill=ALT, width=int(lw * 2.4), joint="curve")
    glow = glow.filter(ImageFilter.GaussianBlur(int(0.024 * W)))
    img = Image.blend(img, Image.new("RGB", (W, W), (0,0,0)), 0)
    img = Image.composite(img, img, Image.new("L", (W, W), 255))
    img.paste(Image.blend(img.crop((0,0,W,W)), glow, 0.30), (0, 0))
    d = ImageDraw.Draw(img)

    # ★ 圆头会把缝填掉:间隙必须 > 线宽,否则虚线连成一条(第二版就是这么糊的)。
    #   可见缝隙 = gap − lw = 0.045W,虚线视觉长 = dash + lw = 0.115W,约 2.5:1。
    dashed(d, alt, ALT, lw, dash=int(0.075 * W), gap=int(0.085 * W))
    stroke(d, stem + actual, ACTUAL, lw)

    r = int(lw * 1.05)                        # 分叉节点(白)
    d.ellipse([fork[0]-r-lw*0.30, fork[1]-r-lw*0.30, fork[0]+r+lw*0.30, fork[1]+r+lw*0.30],
              fill=lerp(BG_TOP, BG_BOT, 0.6))
    d.ellipse([fork[0]-r, fork[1]-r, fork[0]+r, fork[1]+r], fill=NODE)

    for p, c in ((alt[-1], ALT), (actual[-1], ACTUAL)):   # 两个终点
        r2 = int(lw * 0.66)
        d.ellipse([p[0]-r2, p[1]-r2, p[0]+r2, p[1]+r2], fill=c)

    img = img.resize((S, S), Image.LANCZOS)
    p = OUT / "AppIcon-1024.png"
    img.save(p, "PNG")
    print("wrote", p, img.size)

if __name__ == "__main__":
    build()

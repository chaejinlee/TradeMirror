# -*- coding: utf-8 -*-
"""
App Store 截图合成器。**生成器驱动,不要手改 PNG。**

做法:把原始模拟器截图缩小、加圆角、放到带标题的画布上。
输出 1320×2868(App Store 6.9 寸的必需档,其余尺寸 Apple 自动缩)。
"""
from PIL import Image, ImageDraw, ImageFont
from pathlib import Path

HERE = Path(__file__).resolve().parent
SHOTS, OUT = HERE / "shots", HERE / "appstore"
OUT.mkdir(exist_ok=True)
W, H = 1320, 2868

BG_TOP, BG_BOT = (13, 17, 27), (30, 40, 62)
TITLE_C, SUB_C = (245, 248, 253), (150, 165, 190)

def font(sz, bold=True):
    for p in ["/System/Library/Fonts/PingFang.ttc",
              "/System/Library/Fonts/STHeiti Medium.ttc",
              "/System/Library/Fonts/Hiragino Sans GB.ttc"]:
        try: return ImageFont.truetype(p, sz, index=(1 if bold and "PingFang" in p else 0))
        except Exception: continue
    return ImageFont.load_default()

def lerp(a, b, t): return tuple(round(x + (y - x) * t) for x, y in zip(a, b))

def rounded(im, r):
    m = Image.new("L", im.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, im.size[0]-1, im.size[1]-1], r, fill=255)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(im, (0, 0), m)
    return out

def wrap(d, text, f, maxw):
    lines, cur = [], ""
    for ch in text:
        if ch == "\n":
            lines.append(cur); cur = ""; continue
        t = cur + ch
        if d.textlength(t, font=f) > maxw and cur:
            lines.append(cur); cur = ch
        else:
            cur = t
    if cur: lines.append(cur)
    return lines

def compose(src, title, sub, out_name, crop_top=0):
    canvas = Image.new("RGB", (W, H), BG_TOP)
    d = ImageDraw.Draw(canvas)
    for y in range(H):
        d.line([(0, y), (W, y)], fill=lerp(BG_TOP, BG_BOT, y / H))

    ft, fs = font(76), font(44, bold=False)
    tx, ty = 96, 150
    for ln in wrap(d, title, ft, W - 192):
        d.text((tx, ty), ln, font=ft, fill=TITLE_C); ty += 96
    ty += 14
    for ln in wrap(d, sub, fs, W - 192):
        d.text((tx, ty), ln, font=fs, fill=SUB_C); ty += 60

    im = Image.open(SHOTS / src).convert("RGB")
    if crop_top: im = im.crop((0, crop_top, im.width, im.height))
    scale = (W - 200) / im.width
    im = im.resize((int(im.width * scale), int(im.height * scale)), Image.LANCZOS)
    top = ty + 70
    avail = H - top - 60
    if im.height > avail:
        im = im.crop((0, 0, im.width, int(avail / scale) if False else avail))
    im = rounded(im, 56)
    canvas.paste(im, (100, top), im)
    canvas.save(OUT / out_name, "PNG")
    print("wrote", out_name, canvas.size)

if __name__ == "__main__":
    # ★ 2026-09-01 复盘发现:这一组素材是 09:50 定稿的,之后落了 v0.7→v1.4 共七个版本。
    #   商店里陈列的是七个版本以前的软件 —— 既是 2.3 元数据不实的风险,
    #   也白扔了唯一的转化位。规则:**发版就重拍**,原始截图统一叫 new_*.png。
    compose("new_fork.png",
            "不只是记账。\n它算「换个做法会怎样」",
            "四条替代路线各差多少钱,而且两个方向都说 —— 你的做法更好时,它也会讲。",
            "01_counterfactual.png", crop_top=150)
    compose("new_history.png",
            "一个数字:\n你的出场规则值多少钱",
            "把每一笔都换成最好的替代做法,再和你的实际结果比。样本太少时它会自己说出来。",
            "02_history.png", crop_top=150)
    compose("new_guide.png",
            "券商里截个图,\n分享 → 复盘镜",
            "自动认标的、张数、成交价、时间。你只需核对一眼 —— 永不自动保存。",
            "03_capture.png", crop_top=150)
    compose("new_rules.png",
            "开仓前检查,\n当场冻结",
            "「系统警告过、你仍然要做」会被记下来。事后重算带幸存者偏差,所以这一栏绝不重算。",
            "04_discipline.png", crop_top=150)
    compose("new_strategies.png",
            "股票 · 期权 · 期货 · 外汇\n13 种策略自动摆腿",
            "选铁鹰,四条腿自动就位。做空只要把第一笔选成「卖」,不用额外开关。",
            "05_instruments.png", crop_top=150)
    compose("new_data.png",
            "你的数据,\n带得走。",
            "不连券商、不注册账号、没有广告。随时导出备份,而且导得回来。",
            "06_local.png", crop_top=150)

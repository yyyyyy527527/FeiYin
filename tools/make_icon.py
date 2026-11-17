# -*- coding: utf-8 -*-
"""
生成「星籁」应用图标（512x512，RGBA）。

设计：深空紫渐变底 + 白色四角星芒，星体中挖出三根声波竖线（负空间）。
星 = 星籁的「星」，三条竖线 = 声波，合起来读作「星的声音」。
"""
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 2048                 # 超采样画布
OUT = 512                # 输出尺寸
RADIUS = int(S * 0.225)  # 圆角半径（22.5%）

ACCENT = (240, 69, 90)   # 品牌红
WHITE = (255, 255, 255)
PINKGLOW = (255, 212, 222)
DARK_HOLE = (18, 11, 28)

R = S * 0.375            # 星芒半径（四周留白约 13%）
WAIST = 0.42             # 腰部内凹（越小越尖）


def rounded_mask(size, radius):
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def diag_gradient(size, c1, c2):
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    t = ((x + y) / (2.0 * (size - 1)))[..., None]
    a, b = np.array(c1, dtype=np.float32), np.array(c2, dtype=np.float32)
    return Image.fromarray((a * (1 - t) + b * t).astype(np.uint8), 'RGB').convert('RGBA')


def radial_glow(size, cx, cy, radius, color, alpha, power=2.0):
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    d = np.clip(np.sqrt((x - cx) ** 2 + (y - cy) ** 2) / radius, 0, 1)
    a = (np.clip(1 - d, 0, 1) ** power) * alpha
    layer = np.zeros((size, size, 4), dtype=np.float32)
    layer[..., 0], layer[..., 1], layer[..., 2] = color
    layer[..., 3] = a * 255
    return Image.fromarray(layer.astype(np.uint8), 'RGBA')


def sparkle_mask(size, radius, waist=0.5):
    """四角星芒：四个等长尖端 + 靠近中心的内凹点。"""
    c = size / 2.0
    pts = []
    for i in range(4):
        ang = np.radians(90 * i) - np.pi / 2
        pts.append((c + radius * np.cos(ang), c + radius * np.sin(ang)))
        am = ang + np.pi / 4
        ir = radius * waist
        pts.append((c + ir * np.cos(am), c + ir * np.sin(am)))
    img = Image.new('L', (size, size), 0)
    ImageDraw.Draw(img).polygon(pts, fill=255)
    return img


def plate():
    """深空底：靛紫斜向渐变 + 底部品牌粉光 + 左上冷紫光。"""
    bg = diag_gradient(S, (28, 17, 44), (9, 6, 15))
    bg = Image.alpha_composite(bg, radial_glow(S, S * 0.12, S * 0.02, S * 0.55, (118, 92, 214), 0.12))
    return bg


def main():
    star = sparkle_mask(S, R, WAIST)
    canvas = plate()

    # 星体外发光
    g = star.filter(ImageFilter.GaussianBlur(S * 0.05)).point(lambda v: int(v * 0.32))
    canvas = Image.composite(Image.new('RGBA', (S, S), PINKGLOW + (255,)), canvas, g)

    # 星体：白→极淡冷白 的斜向渐变，避免纯白平板
    grad = diag_gradient(S, (255, 255, 255), (238, 234, 246))
    canvas = Image.composite(grad, canvas, star)

    # 负空间：三根声波竖线
    bh, gap, bw = R * 0.60, R * 0.260, R * 0.115
    bars = Image.new('L', (S, S), 0)
    d = ImageDraw.Draw(bars)
    for i, hf in enumerate([0.62, 1.0, 0.62]):
        h = bh * hf
        x = S / 2 + (i - 1) * gap
        d.rounded_rectangle([x - bw / 2, S / 2 - h / 2, x + bw / 2, S / 2 + h / 2],
                            radius=bw / 2, fill=255)
    canvas = Image.composite(Image.new('RGBA', (S, S), DARK_HOLE + (255,)), canvas, bars)

    # 圆角裁切 + 缩放
    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    out.paste(canvas, (0, 0), rounded_mask(S, RADIUS))
    out = out.resize((OUT, OUT), Image.LANCZOS)
    return out


if __name__ == '__main__':
    icon = main()
    icon.save('AppScope/resources/base/media/app_icon.png')
    icon.save('entry/src/main/resources/base/media/app_icon.png')
    icon.save('screenshots/app_icon_preview.png')
    # 桌面尺寸预览
    sheet = Image.new('RGBA', (360, 120), (232, 234, 240, 255))
    for i, sz in enumerate([48, 64, 96]):
        sheet.paste(icon.resize((sz, sz), Image.LANCZOS), (30 + i * 110, 12), icon.resize((sz, sz), Image.LANCZOS))
    sheet.save('screenshots/app_icon_sizes.png')
    print('saved')

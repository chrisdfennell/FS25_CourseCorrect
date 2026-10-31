"""Draws the mod icon and writes it as a 512x512 DXT1 .dds (what GIANTS' TestRunner wants for a mod icon: opaque,
no alpha channel).

Usage:
    python make_icon.py <out.dds> [preview.png]
"""
import math
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 1024  # drawn at 4x, scaled down for smooth edges


def draw_icon():
    img = Image.new("RGBA", (S, S))
    # background: deep green, lighter towards the top right
    y, x = np.mgrid[0:S, 0:S]
    t = ((x + (S - y)) / (2 * S))[..., None]
    dark, light = np.array([10, 38, 30]), np.array([30, 98, 66])
    bg = (dark * (1 - t) + light * t).astype(np.uint8)
    img = Image.fromarray(np.dstack([bg, np.full((S, S), 255, np.uint8)]), "RGBA")
    d = ImageDraw.Draw(img)

    # the field: rows, the worked ones a little darker
    m = 120
    field = [m, m, S - m, S - 250]
    d.rounded_rectangle(field, radius=40, fill=(64, 112, 52, 255))
    rows = 7
    row_w = (field[2] - field[0]) / rows
    for i in range(rows):
        x0 = field[0] + i * row_w
        color = (92, 140, 64, 255) if i % 2 == 0 else (78, 126, 58, 255)
        if i < 4:
            color = (128, 98, 52, 255) if i % 2 == 0 else (116, 88, 46, 255)
        d.rectangle([x0 + 6, field[1] + 30, x0 + row_w - 6, field[3] - 30], fill=color)

    # the course: up and down the rows with round turns, glowing
    path = []
    top, bottom = field[1] + 70, field[3] - 70
    for i in range(rows):
        cx = field[0] + (i + 0.5) * row_w
        ys = (bottom, top) if i % 2 == 0 else (top, bottom)
        path.append((cx, ys[0]))
        path.append((cx, ys[1]))
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    line = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(line)

    # one continuous line: each row, then a half circle to the next one, so turns and rows meet exactly (a thick
    # arc on its own sits half its width inside its box and leaves a step where it meets the row)
    points = []
    for i in range(0, len(path) - 1, 2):
        points += [path[i], path[i + 1]]
        if i + 2 < len(path):
            (x1, y1), (x2, _) = path[i + 1], path[i + 2]
            r, cx = abs(x2 - x1) / 2, (x1 + x2) / 2
            bulge = -1 if y1 == top else 1
            for k in range(1, 40):
                a = math.pi * k / 40
                points.append((cx - math.cos(a) * r * (1 if x2 > x1 else -1), y1 + bulge * math.sin(a) * r))

    def stroke(drawer, width, color):
        drawer.line(points, fill=color, width=width, joint="curve")
        # (round ends)
        for px, py in (points[0], points[-1]):
            drawer.ellipse([px - width / 2, py - width / 2, px + width / 2, py + width / 2], fill=color)

    stroke(g, 46, (120, 230, 255, 160))
    glow = glow.filter(ImageFilter.GaussianBlur(18))
    stroke(ld, 22, (235, 250, 255, 255))
    img = Image.alpha_composite(img, glow)
    img = Image.alpha_composite(img, line)
    d = ImageDraw.Draw(img)
    # arrow at the end of the course
    ex, ey = path[-1]
    up = path[-1][1] < path[-2][1]
    tip = ey - 50 if up else ey + 50
    base = ey + 6 if up else ey - 6
    d.polygon([(ex - 40, base), (ex + 40, base), (ex, tip)], fill=(235, 250, 255, 255))
    # tractor dot at the start
    sx, sy = path[0]
    d.ellipse([sx - 30, sy - 30, sx + 30, sy + 30], fill=(60, 220, 120, 255), outline=(235, 250, 255, 255), width=8)

    # name
    try:
        font = ImageFont.truetype("segoeuib.ttf", 150)
    except OSError:
        font = ImageFont.load_default(size=150)
    text = "CourseCorrect"
    size = 150
    while d.textlength(text, font=font) > S - 120 and size > 60:
        size -= 6
        try:
            font = ImageFont.truetype("segoeuib.ttf", size)
        except OSError:
            font = ImageFont.load_default(size=size)
    w = d.textlength(text, font=font)
    d.text(((S - w) / 2, S - 215), text, font=font, fill=(240, 246, 242, 255))
    return img.resize((512, 512), Image.LANCZOS)


def rgb565(c):
    return ((int(c[0]) >> 3) << 11) | ((int(c[1]) >> 2) << 5) | (int(c[2]) >> 3)


def from565(v):
    r, g, b = (v >> 11) & 31, (v >> 5) & 63, v & 31
    return np.array([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)], float)


def encode_block(block):
    """block: 16x4 uint8 RGBA -> 8 bytes DXT1 (four colour mode: the icon is opaque)"""
    rgb = block[:, :3].astype(float)
    lum = rgb @ np.array([0.299, 0.587, 0.114])
    c0, c1 = rgb[lum.argmax()], rgb[lum.argmin()]
    v0, v1 = rgb565(c0), rgb565(c1)
    if v0 < v1:
        v0, v1 = v1, v0
    if v0 == v1:
        idx = [0] * 16
    else:
        p0, p1 = from565(v0), from565(v1)
        pal = [p0, p1, (2 * p0 + p1) / 3, (p0 + 2 * p1) / 3]
        idx = [int(np.argmin([((c - p) ** 2).sum() for p in pal])) for c in rgb]
    bits = 0
    for i, ix in enumerate(idx):
        bits |= ix << (2 * i)
    return struct.pack("<HH", v0, v1) + bits.to_bytes(4, "little")


def write_dds(img, path):
    a = np.asarray(img.convert("RGBA"))
    h, w = a.shape[:2]
    data = bytearray()
    for by in range(0, h, 4):
        for bx in range(0, w, 4):
            data += encode_block(a[by:by + 4, bx:bx + 4].reshape(16, 4))
    header = struct.pack("<4s7I44x", b"DDS ", 124, 0x81007, h, w, len(data), 0, 0)
    pixel_format = struct.pack("<2I4s5I", 32, 0x4, b"DXT1", 0, 0, 0, 0, 0)
    caps = struct.pack("<5I", 0x1000, 0, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(header + pixel_format + caps + bytes(data))


if __name__ == "__main__":
    icon = draw_icon()
    write_dds(icon, sys.argv[1])
    if len(sys.argv) > 2:
        icon.save(sys.argv[2])
    print("written", sys.argv[1])

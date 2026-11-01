"""Draws the panel's textures and writes them as DXT5 .dds files: a white disc with a soft edge (the panel's rounded
corners, dots and markers are drawn from its quarters and whole), and the vehicle's arrow on the course map (green,
white edge, soft shadow, pointing up; drawn in its own colours, turned to the heading).

Usage:
    python make_textures.py
"""
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SIZE = 128


# DXT5 (with alpha: the textures are transparent round their shape; make_icon's DXT1 is for the opaque mod icon only,
# a texture written with it had a black square round it in the game)
def rgb565(c):
    return ((int(c[0]) >> 3) << 11) | ((int(c[1]) >> 2) << 5) | (int(c[2]) >> 3)


def from565(v):
    r, g, b = (v >> 11) & 31, (v >> 5) & 63, v & 31
    return np.array([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)], float)


def encode_block(block):
    """block: 16x4 uint8 RGBA -> 16 bytes DXT5"""
    alpha = block[:, 3].astype(int)
    a0, a1 = alpha.max(), alpha.min()
    if a0 == a1:
        a_idx = [0] * 16
    else:
        pal = [a0, a1] + [((7 - i) * a0 + i * a1) / 7 for i in range(1, 7)]
        a_idx = [int(np.argmin([abs(a - p) for p in pal])) for a in alpha]
    bits = 0
    for i, ix in enumerate(a_idx):
        bits |= ix << (3 * i)
    alpha_bytes = bytes([a0, a1]) + bits.to_bytes(6, "little")

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
    color_bytes = struct.pack("<HH", v0, v1) + bits.to_bytes(4, "little")
    return alpha_bytes + color_bytes


def write_dds(img, path):
    a = np.asarray(img.convert("RGBA"))
    h, w = a.shape[:2]
    data = bytearray()
    for by in range(0, h, 4):
        for bx in range(0, w, 4):
            data += encode_block(a[by:by + 4, bx:bx + 4].reshape(16, 4))
    header = struct.pack("<4s7I44x", b"DDS ", 124, 0x81007, h, w, len(data), 0, 0)
    pixel_format = struct.pack("<2I4s5I", 32, 0x4, b"DXT5", 0, 0, 0, 0, 0)
    caps = struct.pack("<5I", 0x1000, 0, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(header + pixel_format + caps + bytes(data))



def disc():
    y, x = np.mgrid[0:SIZE, 0:SIZE] + 0.5
    r = np.hypot(x - SIZE / 2, y - SIZE / 2)
    # one pixel of soft edge
    alpha = np.clip(SIZE / 2 - r, 0, 1)
    rgba = np.zeros((SIZE, SIZE, 4), np.uint8)
    rgba[..., :3] = 255
    rgba[..., 3] = (alpha * 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


ACCENT = (51, 184, 115)  # the panel's accent green


def arrow(tint=False):
    """A navigation arrow pointing up, drawn 4x and scaled down for smooth edges. tint: white with a dark edge, to be
    drawn in any colour (the game multiplies a texture by its colour)"""
    big = SIZE * 4

    def kite(scale, dy=0.0):
        # tip, right wing, notch, left wing (in -1..1, y down), around the middle
        pts = [(0, -0.80), (0.62, 0.72), (0, 0.36), (-0.62, 0.72)]
        return [((x * scale + 1) * big / 2, (y * scale + 1 + dy) * big / 2) for x, y in pts]

    shadow = Image.new("L", (big, big), 0)
    ImageDraw.Draw(shadow).polygon(kite(1.0, 0.06), fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(big * 0.035))
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    img.paste((12, 14, 18, 255), (0, 0), shadow)
    d = ImageDraw.Draw(img)
    d.polygon(kite(1.0), fill=(40, 42, 46, 255) if tint else (255, 255, 255, 255))
    d.polygon(kite(0.74, 0.03), fill=(255, 255, 255, 255) if tint else ACCENT + (255,))
    return img.resize((SIZE, SIZE), Image.LANCZOS)


if __name__ == "__main__":
    import sys
    out = ROOT / "textures"
    out.mkdir(exist_ok=True)
    # (python make_textures.py tint: only the tinted arrow; the others are as they were)
    if "tint" not in sys.argv[1:]:
        write_dds(disc(), out / "circle.dds")
        print("written", out / "circle.dds")
        a = arrow()
        write_dds(a, out / "arrow.dds")
        a.save(Path(__file__).resolve().parent / "arrow_preview.png")
        print("written", out / "arrow.dds")
    t = arrow(tint=True)
    write_dds(t, out / "arrow_tint.dds")
    t.save(Path(__file__).resolve().parent / "arrow_tint_preview.png")
    print("written", out / "arrow_tint.dds")

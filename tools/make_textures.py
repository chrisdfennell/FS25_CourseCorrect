"""Draws the panel's textures and writes them as DXT5 .dds files: a white disc with a soft edge (the panel's rounded
corners, dots and markers are drawn from its quarters and whole), and the vehicle's arrow on the course map (green,
white edge, soft shadow, pointing up; drawn in its own colours, turned to the heading).

Usage:
    python make_textures.py
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from make_icon import write_dds

ROOT = Path(__file__).resolve().parent.parent
SIZE = 128


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


def arrow():
    """A navigation arrow pointing up, drawn 4x and scaled down for smooth edges"""
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
    d.polygon(kite(1.0), fill=(255, 255, 255, 255))
    d.polygon(kite(0.74, 0.03), fill=ACCENT + (255,))
    return img.resize((SIZE, SIZE), Image.LANCZOS)


if __name__ == "__main__":
    out = ROOT / "textures"
    out.mkdir(exist_ok=True)
    write_dds(disc(), out / "circle.dds")
    print("written", out / "circle.dds")
    a = arrow()
    write_dds(a, out / "arrow.dds")
    a.save(Path(__file__).resolve().parent / "arrow_preview.png")
    print("written", out / "arrow.dds")

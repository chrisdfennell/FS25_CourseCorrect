"""Writes tools/fixtures/test_fields.json: field outlines of our own (no map's data) for the automatic tests on
GitHub, under the field numbers the tests use. Each kind of shape the course maker has to handle is there: straight
and bent edges, a D, an L, a wedge cut in, a long strip, a jagged edge, a small square, a big one.

Usage:
    python make_test_fields.py
"""
import json
import math
from pathlib import Path

OUT = Path(__file__).resolve().parent / "fixtures" / "test_fields.json"


def arc(cx, cz, r, a0, a1, n):
    return [(cx + r * math.cos(a0 + (a1 - a0) * k / n), cz + r * math.sin(a0 + (a1 - a0) * k / n)) for k in range(n + 1)]


def moved(pts, dx, dz):
    return [(round(x + dx, 2), round(z + dz, 2)) for x, z in pts]


def fields():
    f = {}
    # 1: a quarter disc
    f["field1"] = [(0, 0)] + arc(0, 0, 260, 0, math.pi / 2, 16)
    # 2: tall, its east side jagged
    east = []
    for k in range(13):
        z = 600 - k * 50
        east.append((300 + (25 if k % 2 else 0), z))
    f["field2"] = [(0, 0), (0, 600)] + east + [(300, 0)]
    # 3: an L
    f["field3"] = [(0, 0), (400, 0), (400, 150), (160, 150), (160, 450), (0, 450)]
    # 7: a big pentagon
    f["field7"] = [(0, 0), (700, -40), (820, 380), (380, 650), (-60, 420)]
    # 9: a straight west side (400 m) and a longer, gently bent east side (an arc bulging 120 m): curved rows follow
    # the bent side
    r9 = (200 ** 2 + 120 ** 2) / (2 * 120)
    a9 = math.asin(200 / r9)
    f["field9"] = [(0, 0), (0, 400)] + arc(120 - r9, 200, r9, a9, -a9, 20)[1:-1]
    # 12: a D (straight east side, round west)
    f["field12"] = [(250, -250), (250, 250)] + arc(250, 0, 250, math.pi / 2, 3 * math.pi / 2, 24)
    # 18: a trapezoid with a notch in its long side
    f["field18"] = [(0, 0), (500, 0), (420, 300), (260, 300), (240, 230), (180, 230), (160, 300), (80, 300)]
    # 20: a rectangle with a wedge cut into it
    f["field20"] = [(0, 0), (320, 0), (320, 220), (180, 220), (150, 90), (120, 220), (0, 220)]
    # 24: small
    f["field24"] = [(0, 0), (110, 0), (110, 95), (0, 95)]
    # 27: long and thin, a little bent
    f["field27"] = [(0, 0), (400, -30), (820, 0), (820, 150), (400, 120), (0, 150)]
    # 34: a hexagon
    f["field34"] = arc(0, 0, 200, 0, 2 * math.pi, 6)[:-1]
    # spread over the map, as on a real one
    out = {}
    for i, (name, pts) in enumerate(sorted(f.items())):
        out[name] = moved(pts, (i % 4) * 1500 - 2500, (i // 4) * 1500 - 2500)
    return out


def main():
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps(fields(), indent=0), encoding="utf-8")
    print("written", OUT)


if __name__ == "__main__":
    main()

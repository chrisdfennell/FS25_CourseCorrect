"""Checks that the vehicle and its implement stay on the field over the whole course: every metre along the path
the work area (work width wide, from the guidance point back to the end of the implement) and the tractor are
placed on the path, and every corner of them must be inside the field outline (a little tolerance for the
headland passes, which work right up to the edge).

Runs every field of a map at several work widths (up to 45 m), with and without reversing.

Usage:
    python envelope_test.py <map.i3d> [--fields 1,2] [--widths 6,12,24,45] [--tolerance 1.0]
"""
import argparse
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402

# turning radius that goes with a work width (bigger implements, bigger tractors)
RADIUS = {6: 6, 12: 7, 24: 9, 45: 12}
TRACTOR_LENGTH, TRACTOR_WIDTH = 5.0, 3.0


def inside(px, py, poly):
    """vectorised even-odd point in polygon"""
    res = np.zeros(px.shape, bool)
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        cond = (y1 > py) != (y2 > py)
        with np.errstate(divide="ignore", invalid="ignore"):
            xc = x1 + (py - y1) * (x2 - x1) / (y2 - y1)
        res ^= cond & (px < xc)
    return res


def dist_to_outline(px, py, poly):
    best = np.full(px.shape, np.inf)
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        dx, dy = x2 - x1, y2 - y1
        l2 = dx * dx + dy * dy or 1e-9
        t = np.clip(((px - x1) * dx + (py - y1) * dy) / l2, 0, 1)
        best = np.minimum(best, np.hypot(px - (x1 + t * dx), py - (y1 + t * dy)))
    return best


def footprint(wps, width, back, towed=False):
    """corner points of the work area and the tractor, every metre along the path. A mounted implement is rigid
    (its back swings out in bends); a towed one follows the path, its back is where the path was 'back' metres
    earlier."""
    xs, ys, where = [], [], []
    trail = []  # (distance along the path, x, z, heading) of the samples so far
    dist = 0.0
    for i in range(1, len(wps)):
        a, b = wps[i - 1], wps[i]
        dx, dz = b["x"] - a["x"], b["z"] - a["z"]
        seg = math.hypot(dx, dz)
        if seg < 1e-3:
            continue
        h = math.atan2(dz, dx)
        if b["rev"]:
            h += math.pi
        fx, fz = math.cos(h), math.sin(h)
        lx, lz = -fz, fx
        steps = max(1, int(seg))
        for k in range(steps + 1):
            px, pz = a["x"] + dx * k / steps, a["z"] + dz * k / steps
            d = dist + seg * k / steps
            corners = [(0, width / 2), (0, -width / 2),
                       (TRACTOR_LENGTH, TRACTOR_WIDTH / 2), (TRACTOR_LENGTH, -TRACTOR_WIDTH / 2)]
            if not towed:
                corners += [(-back, width / 2), (-back, -width / 2)]
            for lon, lat in corners:
                xs.append(px + fx * lon + lx * lat)
                ys.append(pz + fz * lon + lz * lat)
                where.append((i, b["t"]))
            if towed:
                trail.append((d, px, pz, h))
                # the back of the implement: where the path was 'back' metres ago, facing the way it went there
                j = len(trail) - 1
                while j > 0 and trail[j][0] > d - back:
                    j -= 1
                _, tx, tz, th = trail[j]
                tlx, tlz = -math.sin(th), math.cos(th)
                for lat in (width / 2, -width / 2):
                    xs.append(tx + tlx * lat)
                    ys.append(tz + tlz * lat)
                    where.append((i, b["t"]))
        dist += seg
    return np.array(xs), np.array(ys), where


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("i3d")
    ap.add_argument("--fields", default="")
    ap.add_argument("--widths", default="6,12,24,45")
    ap.add_argument("--tolerance", type=float, default=0.75)
    ap.add_argument("--radius", type=float, default=None, help="turning radius for all widths")
    ap.add_argument("--run-out", type=float, default=3.0, help="how far the implement reaches behind the guidance point + 0.5")
    args = ap.parse_args()
    fields = fp.read_fields(args.i3d)
    wanted = [f for f in sorted(fields, key=lambda n: int("".join(c for c in n if c.isdigit()) or 0))
              if not args.fields or f[5:] in args.fields.split(",")]
    lua = fp.load_lua()
    failures = 0
    for width in [float(w) for w in args.widths.split(",")]:
        radius = args.radius or RADIUS.get(int(width), 6)
        run_out = args.run_out
        back = run_out - 0.5
        for reverse in (False, True):
            worst_all, failed = 0.0, []
            for name in wanted:
                pts = fields[name]
                course, err = fp.generate(lua, pts, {"workWidth": width, "turnRadius": radius, "runOut": run_out,
                                                      "headlands": -1, "allowReverse": reverse})
                if course is None:
                    continue
                xs, ys, where = footprint(course["waypoints"], width, back, towed=not reverse)
                poly = list(pts)
                out = ~inside(xs, ys, poly)
                if out.any():
                    d = dist_to_outline(xs[out], ys[out], poly)
                    worst = float(d.max())
                    worst_all = max(worst_all, worst)
                    if worst > args.tolerance:
                        k = int(np.flatnonzero(out)[int(d.argmax())])
                        failed.append(f"{name} {worst:.1f} m out at waypoint {where[k][0]} ({where[k][1]}), "
                                      f"{course['stats']['headlands']} headlands")
            label = f"width {width:.0f} m, radius {radius} m, {'mounted, reversing' if reverse else 'towed, forward only'}"
            print(f"{label}: {len(wanted) - len(failed)}/{len(wanted)} fields OK, worst {worst_all:.2f} m off the field")
            for f in failed:
                print("   ", f)
            failures += len(failed)
    print("OK" if failures == 0 else f"FAILED ({failures})")
    sys.exit(0 if failures == 0 else 1)


if __name__ == "__main__":
    main()

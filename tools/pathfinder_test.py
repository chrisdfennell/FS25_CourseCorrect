"""Avoid fruit, offline: for fields of a map, standing crop everywhere except the outermost headland pass and
the western third, a vehicle at a field corner that has to get to a row in the crop. Compares the direct way (what the course
generator plans) with the pathfinder's: metres through crop, time to find it, and that the follower can drive it.

Usage:
    python pathfinder_test.py <map.i3d> [--fields 1,2] [--png out_dir]
"""
import argparse
import math
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402
from sim_follow import simulate  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent

SETUP = r"""
Guidance = Guidance or {debug = function() end, info = function() end}
-- crop everywhere on the field except the outermost headland pass (6 m) and the western third
function makeProbe(field, harvestedUpTo)
    local index = GuidanceGeo.outlineIndex(field, 10)
    return {fruitIndexes = {1}, hasFruit = function(self, x, z)
        local p = {x = x, y = z}
        return x > harvestedUpTo and index:isInside(p) and index:closest(p, 6) == nil
    end}
end
function runCase(course, fromX, fromZ, fromH, toIx)
    local wps = course.waypoints
    local a, b = wps[toIx], wps[toIx + 1]
    local h = math.atan2(b.z - a.z, b.x - a.x)
    local to = {x = a.x - math.cos(h) * 4, y = a.z - math.sin(h) * 4, h = h}
    local from = {x = fromX, y = fromZ, h = fromH}
    local Geo = GuidanceGeo
    local _, minY, maxX, maxY = Geo.bounds(course.area.field)
    local minX = Geo.bounds(course.area.field)
    -- the western third is harvested
    local probe = makeProbe(course.area.field, minX + (maxX - minX) / 3)
    local direct = GuidanceCourseGenerator.planApproach(course.area, course.settings, from, to)
    local t0 = os.clock()
    local around = GuidancePathfinder.find(course.area, course.settings, from, to, probe)
    local took = os.clock() - t0
    local fd = GuidancePathfinder.fruitLength(probe, from, direct)
    local fa = around and GuidancePathfinder.fruitLength(probe, from, around) or -1
    return fd, fa, took, around, to
end
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("i3d")
    ap.add_argument("--fields", default="1,2,3,7,9,18,24,27")
    ap.add_argument("--png", default=None)
    args = ap.parse_args()
    fields = fp.read_fields(args.i3d)
    lua = fp.load_lua()
    lua.execute((ROOT / "scripts/ai/PathFollower.lua").read_text(encoding="utf-8"))
    lua.execute(SETUP)
    lua.execute((ROOT / "scripts/ai/Pathfinder.lua").read_text(encoding="utf-8"))
    ok = True
    for n in args.fields.split(","):
        name = f"field{n}"
        pts = fields[name]
        course, err = fp.generate(lua, pts, {"workWidth": 6, "turnRadius": 6, "headlands": -1})
        lc = course["lua"]
        wps = course["waypoints"]
        # target: the start of a row in the middle of the course; vehicle: the field's first corner, facing in
        rows = [i for i, w in enumerate(wps) if w["rs"] and i + 1 < len(wps)]
        target = rows[len(rows) // 2] + 1  # lua index
        fx, fz = pts[0]
        cx = sum(p[0] for p in pts) / len(pts)
        cz = sum(p[1] for p in pts) / len(pts)
        h = math.atan2(cz - fz, cx - fx)
        fd, fa, took, around, to = lua.globals().runCase(lc, fx, fz, h, target)
        if around is None:
            print(f"{name}: no way found ({took * 1000:.0f} ms)")
            ok = False
            continue
        path = [{"x": fx, "z": fz, "t": "C", "work": False}]
        path += [{"x": around[i].x, "z": around[i].y, "t": "C", "work": False} for i in range(1, len(around) + 1)]
        r = simulate(lua, {"waypoints": path}, 6 * 0.9)
        # the driver takes the way around only if it crosses 5 m less crop, else it keeps the direct way: the way
        # around must be drivable and never much worse (where the target itself is in the crop both have to cross
        # some, and rounding the last corner can cost a few metres more)
        good = fa <= fd + 10 and r["finished"] and r["turn_err"] < 1.5
        ok = ok and good
        print(f"{name}: direct way {fd:.0f} m through crop, around it {fa:.0f} m, {took * 1000:.0f} ms, "
              f"driven: finished={r['finished']} max off {r['turn_err']:.1f} m: {'OK' if good else 'FAILED'}")
        if args.png:
            from PIL import Image, ImageDraw
            out = Path(args.png)
            out.mkdir(parents=True, exist_ok=True)
            fp.render(name, pts, course, out / f"{name}_fruit.png")
            img = Image.open(out / f"{name}_fruit.png")
            d = ImageDraw.Draw(img)
            xs, zs = [p[0] for p in pts], [p[1] for p in pts]
            minx, maxx, minz, maxz = min(xs), max(xs), min(zs), max(zs)
            scale = (1100 - 80) / max(maxx - minx, maxz - minz, 1)
            tr = lambda x, z: (40 + (x - minx) * scale, 40 + (z - minz) * scale)
            d.line([tr(minx + (maxx - minx) / 3, minz), tr(minx + (maxx - minx) / 3, maxz)], fill=(255, 255, 0), width=1)
            d.line([tr(fx, fz)] + [tr(p["x"], p["z"]) for p in path], fill=(0, 255, 255), width=3)
            img.save(out / f"{name}_fruit.png")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

"""Generates Guidance courses for the fields of a map (outside the game) and draws them to PNG files.

Runs the mod's own Lua (Lua 5.1 through lupa) on the field outlines stored in a map.i3d.

Usage:
    python field_preview.py <map.i3d> <out dir> [--fields 1,5,12] [--width 6] [--radius 6] [--headlands -1]
"""
import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from lupa import lua51
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
LUA_FILES = ["scripts/geometry/Geo.lua", "scripts/geometry/Dubins.lua", "scripts/course/CourseGenerator.lua"]


def floats(text, n=3):
    vals = [float(v) for v in (text or "").split()]
    return vals + [0.0] * (n - len(vals))


def read_fields(i3d_path):
    """{field name: [(x, z), ...]} from the map's gameplay/fields/<field>/polygonPoints"""
    root = ET.parse(i3d_path).getroot()
    fields = {}
    for fields_node in root.iter("TransformGroup"):
        if fields_node.get("name") != "fields":
            continue
        for field in fields_node.findall("TransformGroup"):
            fx, _, fz = floats(field.get("translation"))
            rot = floats(field.get("rotation"))
            if any(abs(r) > 1e-6 for r in rot):
                print(f"warning: {field.get('name')} is rotated, ignoring the rotation", file=sys.stderr)
            pts_node = next((c for c in field.findall("TransformGroup") if c.get("name") == "polygonPoints"), None)
            if pts_node is None:
                continue
            pts = []
            for p in pts_node.findall("TransformGroup"):
                px, _, pz = floats(p.get("translation"))
                pts.append((fx + px, fz + pz))
            if len(pts) >= 3:
                fields[field.get("name")] = pts
    return fields


def load_lua():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    for rel in LUA_FILES:
        lua.execute((ROOT / rel).read_text(encoding="utf-8"))
    return lua


def generate(lua, pts, settings):
    boundary = lua.table_from([lua.table_from({"x": x, "z": z}) for x, z in pts])
    res = lua.globals().GuidanceCourseGenerator.generate(boundary, lua.table_from(settings))
    course, err = res if isinstance(res, tuple) else (res, None)
    if course is None:
        return None, err
    wps = []
    for i in range(1, len(course.waypoints) + 1):
        w = course.waypoints[i]
        wps.append({"x": w.x, "z": w.z, "t": w.t, "work": bool(w.work), "rs": bool(w.rs), "re": bool(w.re),
                    "block": w.block, "rev": bool(w.rev)})
    stats = {k: course.stats[k] for k in ("headlands", "rows", "blocks", "rowAngle", "pattern", "length",
                                            "workLength", "area", "skippedArea", "reverseLength", "islands",
                                            "islandsIgnored", "time")}
    return {"waypoints": wps, "stats": stats, "lua": course}, None


def test_islands(pts, radius, count=1):
    """Synthetic islands for offline tests: squares of the given half size spread over the middle of the field"""
    xs = [p[0] for p in pts]
    zs = [p[1] for p in pts]
    cx, cz = (min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2
    w = (max(xs) - min(xs)) / 4
    out = []
    for i in range(count):
        ox = cx + (i - (count - 1) / 2) * w
        out.append([(ox - radius, cz - radius), (ox + radius, cz - radius), (ox + radius, cz + radius),
                    (ox - radius, cz + radius)])
    return out


def lua_islands(lua, islands):
    return lua.table_from([lua.table_from([lua.table_from({"x": x, "z": z}) for x, z in isl]) for isl in islands])


COLORS = {
    "H": (30, 120, 220),  # headland
    "R": (240, 170, 20),  # row
    "T": (220, 50, 90),  # turn
    "C": (130, 130, 130),  # connection
}


BLOCK_COLORS = [(240, 170, 20), (250, 220, 90), (200, 120, 40), (255, 200, 150), (180, 160, 60)]


def render(name, pts, course, path, size=1100, margin=40, islands=()):
    xs = [p[0] for p in pts]
    zs = [p[1] for p in pts]
    minx, maxx, minz, maxz = min(xs), max(xs), min(zs), max(zs)
    scale = (size - 2 * margin) / max(maxx - minx, maxz - minz, 1)
    w = int((maxx - minx) * scale + 2 * margin)
    h = int((maxz - minz) * scale + 2 * margin) + 70

    def tr(x, z):
        # map seen from above: x to the right, z down (as on the ingame map)
        return (margin + (x - minx) * scale, margin + (z - minz) * scale)

    img = Image.new("RGB", (w, h), (24, 28, 32))
    d = ImageDraw.Draw(img)
    d.polygon([tr(x, z) for x, z in pts], fill=(52, 70, 44), outline=(150, 190, 120))
    for isl in islands:
        d.polygon([tr(x, z) for x, z in isl], fill=(24, 28, 32), outline=(150, 190, 120))
    wps = course["waypoints"]
    for a, b in zip(wps, wps[1:]):
        col = COLORS.get(b["t"], (255, 255, 255))
        if b.get("rev"):
            col = (255, 255, 255)
        if b["t"] == "R" and b["block"] and b["work"]:
            col = BLOCK_COLORS[(int(b["block"]) - 1) % len(BLOCK_COLORS)]
        width = 2 if b["work"] else 1
        d.line([tr(a["x"], a["z"]), tr(b["x"], b["z"])], fill=col, width=width)
    s = wps[0]
    sx, sy = tr(s["x"], s["z"])
    d.ellipse([sx - 6, sy - 6, sx + 6, sy + 6], fill=(60, 220, 90))
    e = wps[-1]
    ex, ey = tr(e["x"], e["z"])
    d.rectangle([ex - 5, ey - 5, ex + 5, ey + 5], fill=(230, 60, 60))
    st = course["stats"]
    font = ImageFont.load_default(size=16)
    text = (f"{name}: {st['area'] / 10000:.2f} ha, {st['headlands']} headlands, {st['rows']} rows in "
            f"{st['blocks']} blocks, angle {st['rowAngle']:.0f} deg, {st['pattern']}, "
            f"{st['length'] / 1000:.2f} km ({st['workLength'] / 1000:.2f} km working, {st['reverseLength']:.0f} m reversing), "
            f"{st['time'] / 60:.0f} min, {len(wps)} waypoints")
    d.text((margin, h - 60), text, fill=(230, 230, 230), font=font)
    legend = [("headland", "H"), ("row", "R"), ("turn", "T"), ("connection", "C")]
    x = margin
    for label, key in legend:
        d.line([(x, h - 25), (x + 24, h - 25)], fill=COLORS[key], width=3)
        d.text((x + 30, h - 34), label, fill=(200, 200, 200), font=font)
        x += 140
    img.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("i3d")
    ap.add_argument("out")
    ap.add_argument("--fields", default="")
    ap.add_argument("--width", type=float, default=6)
    ap.add_argument("--radius", type=float, default=6)
    ap.add_argument("--headlands", type=int, default=-1)
    ap.add_argument("--angle", type=float, default=None)
    ap.add_argument("--reverse", action="store_true", help="vehicle can back up (three-point turns, square corners)")
    ap.add_argument("--pattern", default="auto")
    ap.add_argument("--islands", type=int, default=0, help="add this many synthetic islands")
    ap.add_argument("--island-size", type=float, default=4)
    args = ap.parse_args()

    fields = read_fields(args.i3d)
    wanted = {f"field{n}" for n in args.fields.split(",") if n} or set(fields)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    lua = load_lua()
    settings = {"workWidth": args.width, "turnRadius": args.radius, "headlands": args.headlands,
                "allowReverse": args.reverse, "pattern": args.pattern}
    if args.angle is not None:
        settings["rowAngle"] = args.angle
    for name in sorted(fields, key=lambda n: int("".join(c for c in n if c.isdigit()) or 0)):
        if name not in wanted:
            continue
        pts = fields[name]
        islands = test_islands(pts, args.island_size, args.islands) if args.islands else []
        if islands:
            settings["islands"] = lua_islands(lua, islands)
        try:
            course, err = generate(lua, pts, settings)
        except Exception as ex:  # Lua errors come back as LuaError
            print(f"{name}: LUA ERROR {ex}")
            continue
        if course is None:
            print(f"{name}: {err}")
            continue
        render(name, pts, course, out / f"{name}.png", islands=islands)
        st = course["stats"]
        print(f"{name}: {len(pts)} pts, {st['area'] / 10000:.2f} ha, {st['headlands']} hl, {st['rows']} rows, "
              f"{st['blocks']} blocks, {st["rowAngle"]:.0f} deg, {st['pattern']}, {st['time'] / 60:.0f} min, "
              f"rev {st['reverseLength']:.0f} m, islands {st['islands']}/{st['islandsIgnored']} ignored, "
              f"skipped {st["skippedArea"]:.0f} m2, {len(course["waypoints"])} wps")


if __name__ == "__main__":
    main()

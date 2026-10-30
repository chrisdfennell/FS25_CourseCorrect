"""Draws the README's pictures into docs/images (not packed into the mod): the panel views (the mod's own panel
code, see hud_preview.py), the course patterns, a team's shares, a painted field read from the ground and the icon.
Everything comes from the mod's own Lua, so the pictures show what this build does.

Usage:
    python readme_images.py <map.i3d>
"""
import math
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402
import smoke_test  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "images"
BG = (24, 28, 32)
FIELD = (52, 70, 44)
EDGE = (150, 190, 120)
HEADLAND = (60, 150, 235)
ROW = (240, 170, 20)
TURN = (220, 60, 100)
TEAM = [(240, 170, 20), (90, 200, 255), (240, 90, 160), (140, 230, 120)]


def font(size, bold=False):
    for name in (("segoeuib.ttf" if bold else "segoeui.ttf"), "arial.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default(size=size)


def frame(pts, size, margin=18, extra=()):
    xs = [p[0] for p in list(pts) + list(extra)]
    zs = [p[1] for p in list(pts) + list(extra)]
    minx, maxx, minz, maxz = min(xs), max(xs), min(zs), max(zs)
    scale = (size - 2 * margin) / max(maxx - minx, maxz - minz, 1)
    ox = margin + ((size - 2 * margin) - (maxx - minx) * scale) / 2
    oz = margin + ((size - 2 * margin) - (maxz - minz) * scale) / 2
    return lambda x, z: (ox + (x - minx) * scale, oz + (z - minz) * scale)


def draw_course(d, tr, wps, color_of=None, width=3):
    for a, b in zip(wps, wps[1:]):
        if b["t"] == "C":
            continue
        col = color_of(b) if color_of else None
        if col is None:
            col = {"H": HEADLAND, "R": ROW, "T": TURN}.get(b["t"], (200, 200, 200))
        d.line([tr(a["x"], a["z"]), tr(b["x"], b["z"])], fill=col, width=width if b["work"] else 2)


def tile(title, subtitle, pts, wps_list, size=520, islands=(), color_of=None, outlines=()):
    img = Image.new("RGB", (size, size + 64), BG)
    d = ImageDraw.Draw(img)
    tr = frame(pts, size, extra=[p for o in outlines for p in o[0]])
    for o, col in outlines:
        d.polygon([tr(x, z) for x, z in o], outline=col, width=3)
    d.polygon([tr(x, z) for x, z in pts], fill=FIELD, outline=EDGE)
    for isl in islands:
        d.polygon([tr(x, z) for x, z in isl], fill=BG, outline=EDGE)
    for k, wps in enumerate(wps_list):
        draw_course(d, tr, wps, (lambda b, k=k: TEAM[k % len(TEAM)]) if len(wps_list) > 1 else color_of)
    if wps_list and wps_list[0]:
        s = wps_list[0][0]
        sx, sy = tr(s["x"], s["z"])
        d.ellipse([sx - 7, sy - 7, sx + 7, sy + 7], fill=(60, 220, 90), outline=(255, 255, 255), width=2)
    d.text((16, size + 4), title, fill=(240, 244, 246), font=font(22, True))
    d.text((16, size + 34), subtitle, fill=(170, 178, 186), font=font(16))
    return img


def grid(tiles, cols, path, gap=10):
    w, h = tiles[0].size
    rows = math.ceil(len(tiles) / cols)
    img = Image.new("RGB", (cols * w + (cols + 1) * gap, rows * h + (rows + 1) * gap), (14, 16, 19))
    for i, t in enumerate(tiles):
        img.paste(t, (gap + (i % cols) * (w + gap), gap + (i // cols) * (h + gap)))
    img.save(path, optimize=True)
    print("written", path)


def main():
    i3d = sys.argv[1]
    OUT.mkdir(parents=True, exist_ok=True)
    fields = fp.read_fields(i3d)

    # --- the panel: the mod's own panel code, every view ------------------------------------------------------------
    panels = OUT / "panel"
    subprocess.run([sys.executable, str(ROOT / "tools" / "hud_preview.py"), i3d, "9", str(panels)], check=True,
                   capture_output=True)
    for png in panels.glob("*.png"):
        Image.open(png).save(png, optimize=True)
    print("written", panels)

    # --- the icon ------------------------------------------------------------------------------------------------
    subprocess.run([sys.executable, str(ROOT / "tools" / "make_icon.py"), str(OUT / "icon.dds"), str(OUT / "icon.png")],
                   check=True, capture_output=True)
    (OUT / "icon.dds").unlink(missing_ok=True)
    print("written", OUT / "icon.png")

    # --- patterns -------------------------------------------------------------------------------------------------
    lua = fp.load_lua()
    pts = fields["field12"]
    base = {"workWidth": 12, "turnRadius": 8, "headlands": -1, "minHeadlandWidth": 40, "runOut": 3}

    def course(extra, p=pts, islands=None):
        s = dict(base, **extra)
        if islands is not None:
            s["islands"] = fp.lua_islands(lua, islands)
        c, err = fp.generate(lua, p, s)
        if c is None:
            raise SystemExit(f"no course: {err}")
        return c

    tiles = []
    for title, sub, extra in (
            ("Every row", "the next row each time", {"pattern": "adjacent"}),
            ("Racetrack", "skips rows: every turn a wide loop", {"pattern": "racetrack"}),
            ("Lands", "middle out, worked side on the left", {"pattern": "lands", "rowsPerLand": 6, "landsSide": 1}),
            ("Spiral", "round and round to the middle", {"pattern": "spiral"}),
            ("Along the edge", "curved rows follow the longest edge", {"rowShape": "edge"}),
    ):
        c = course(extra)
        tiles.append(tile(title, sub, pts, [c["waypoints"]]))
    isl = fp.test_islands(pts, 22, 1)
    c = course({"pattern": "adjacent"}, islands=isl)
    tiles.append(tile("Islands", "worked round, with their own passes", pts, [c["waypoints"]], islands=isl))
    grid(tiles, 3, OUT / "patterns.png")

    # --- a team: each tractor's share in its colour -----------------------------------------------------------------
    team_tiles = []
    for title, sub, share, pattern in (("Strips", "3 tractors: a strip each, headlands dealt out", "strips", "adjacent"),
                                       ("Lands", "3 tractors: a part each, in lands", "strips", "lands")):
        members = []
        for k in range(1, 4):
            c = course({"pattern": pattern, "rowsPerLand": 6, "teamSize": 3, "teamIndex": k, "teamShare": share})
            members.append(c["waypoints"])
        team_tiles.append(tile(title, sub, pts, members))
    whole = course({"pattern": "adjacent", "workWidth": 36, "turnRadius": 26})
    team_tiles.append(tile("Convoy", "one 3 x 12 m course, side by side", pts, [whole["waypoints"]]))
    grid(team_tiles, 3, OUT / "team.png")

    # --- a painted field: the map's outline and the field ground read from it ---------------------------------------
    p9 = fields["field12"]
    flat = [c for p in p9 for c in p]
    slua = smoke_test.fresh_lua(fields, "field12")
    slua.execute(r"""
    function paintedCourse(flat, x1, z1, x2, z2, cx, cz)
        local field = {}
        for i = 1, #flat - 1, 2 do field[#field + 1] = {x = flat[i], y = flat[i + 1]} end
        GuidanceFieldScan.isFieldAt = function(x, z)
            if x > x1 and x < x2 and z > z1 and z < z2 then return true end
            return GuidanceGeo.pointInPolygon({x = x, y = z}, field)
        end
        local id = GuidanceCourse.fieldForCourse(cx, cz, 1)
        local plan = GuidancePlan.new()
        plan.workWidth, plan.turnRadius, plan.autoWidth, plan.runOut, plan.fieldId = 12, 8, false, 3, id
        return GuidanceCourse.generate(plan), GuidanceCourse.getFieldOutline(id)
    end
    """)
    G = slua.globals()
    G.makeField(7, slua.table_from(flat))
    xs, zs = [p[0] for p in p9], [p[1] for p in p9]
    ext = (max(xs) - 5, min(zs) + 40, max(xs) + 110, max(zs) - 40)
    res = G.paintedCourse(slua.table_from(flat), *ext, sum(xs) / len(xs), sum(zs) / len(zs))
    pc, outline = res
    wps = [{"x": pc.waypoints[i].x, "z": pc.waypoints[i].z, "t": pc.waypoints[i].t, "work": bool(pc.waypoints[i].work)}
           for i in range(1, len(pc.waypoints) + 1)]
    ground = [(outline[i].x, outline[i].z) for i in range(1, len(outline) + 1)]
    box = [(ext[0], ext[1]), (ext[2], ext[1]), (ext[2], ext[3]), (ext[0], ext[3])]
    before = course({"pattern": "adjacent"}, p=p9)
    grid([tile("The map's outline", "the painted part (yellow) gets nothing", p9, [before["waypoints"]],
               outlines=[(box, (220, 210, 110))]),
          tile("Read from the ground", "CourseCorrect works the painted part too", ground, [wps],
               outlines=[(p9, (90, 110, 80))])], 2, OUT / "painted.png")

if __name__ == "__main__":
    main()

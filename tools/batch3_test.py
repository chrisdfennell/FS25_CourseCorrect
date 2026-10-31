"""Checks offline the course patterns and the editor's settings: lands (each land from its middle out), spiral
(passes all the way in), curved rows (along the longest edge), tramlines (rows on the sowing course's passes), rows
left out, areas worked round. Every course is checked to stay on the field (as envelope_test) and driven to its end
by the test tractor (as team_drive_test).

Usage:
    python batch3_test.py <map.i3d> [field number]
"""
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import envelope_test as env  # noqa: E402
import field_preview as fp  # noqa: E402
import smoke_test  # noqa: E402
import team_drive_test as tdt  # noqa: E402

LUA = r"""
local function outlineOf(flat)
    local pts = {}
    for i = 1, #flat - 1, 2 do pts[#pts + 1] = {x = flat[i], z = flat[i + 1]} end
    return pts
end

function makeCourse(flat, values)
    local plan = GuidancePlan.new()
    plan.workWidth, plan.turnRadius, plan.autoWidth, plan.runOut = 6, 6, false, 3
    -- the patterns are checked on field 9 with 30 m headlands (with 40 m its inside no longer reaches the bent edge)
    plan.minHeadlandWidth = 30
    for k, v in pairs(values) do plan[k] = v end
    local settings = plan:getGeneratorSettings()
    local zones = plan:getSkipZones()
    if #zones > 0 then settings.islands = zones end
    local course, err = GuidanceCourseGenerator.generate(outlineOf(flat), settings)
    LAST_ERROR = err
    return course
end

--- rows of a course: list of {line, n (points), x, z (middle), ax, az (start), bx, bz (end)}, in driving order
function rowsOf(course)
    local rows, cur = {}, nil
    for i, w in ipairs(course.waypoints) do
        if w.rs and w.t == "R" then cur = {line = w.line or 0, n = 1, x = w.x, z = w.z, ax = w.x, az = w.z} end
        if cur and not w.rs and w.t == "R" then cur.n = cur.n + 1 end
        if w.re and w.t == "R" and cur then
            cur.x, cur.z = (cur.x + w.x) / 2, (cur.z + w.z) / 2
            cur.bx, cur.bz = w.x, w.z
            rows[#rows + 1] = cur
            cur = nil
        end
    end
    return rows
end
"""


def waypoints(course):
    out = []
    for i in range(1, len(course.waypoints) + 1):
        w = course.waypoints[i]
        out.append({"x": w.x, "z": w.z, "rev": bool(w.rev), "t": w.t})
    return out


def off_field(course, pts, width=6.0):
    xs, ys, _ = env.footprint(waypoints(course), width, 2.5, towed=False)
    out = ~env.inside(xs, ys, list(pts))
    if not out.any():
        return 0.0
    return float(env.dist_to_outline(xs[out], ys[out], list(pts)).max())


def main():
    i3d = sys.argv[1]
    field = f"field{sys.argv[2] if len(sys.argv) > 2 else 9}"
    fields = fp.read_fields(i3d)
    pts = fields[field]
    flat = []
    for x, z in pts:
        flat += [x, z]
    lua = smoke_test.fresh_lua(fields, field)
    lua.execute(LUA)
    G = lua.globals()
    F = lua.table_from(flat)
    T = lambda d: lua.table_from(d)  # noqa: E731
    ok = True

    def check(name, good, info=""):
        nonlocal ok
        ok = ok and bool(good)
        print(f"{name}: {info}{': ' if info else ''}{'OK' if good else 'FAILED'}")

    # the move from one headland pass to the next: a short S-curve, the implement down (switched off) on it; not a
    # long drift along the pass just done (a rectangle with square corners: each pass started in the middle of an
    # edge, the move 95 m)
    lane_lua = fp.load_lua()
    lane_course, _ = fp.generate(lane_lua, [(0, 0), (250, 0), (250, 290), (0, 290)],
                                 {"workWidth": 5.5, "turnRadius": 8.758, "runOut": 2, "headlands": 8,
                                  "allowReverse": True, "squareCorners": True, "roundedPasses": 1})
    wl = lane_course["lua"].waypoints
    moves, cur = [], None
    for k in range(1, len(wl) + 1):
        w = wl[k]
        if w.lane:
            cur = (cur or 0) + (math.hypot(w.x - wl[k - 1].x, w.z - wl[k - 1].z) if k > 1 and wl[k - 1].lane else 0)
        elif cur is not None:
            moves.append(cur)
            cur = None
    check("headland lane moves", len(moves) == 7 and max(moves) < 30,
          f"{len(moves)} moves between the 8 passes, longest {max(moves or [0]):.0f} m")

    # square corners with a harvester's header ahead of the steering point (its back 4.1 m ahead): before driving on
    # into work it backs up that much further (else the first 4 m past each corner stay standing), along the line it
    # then drives on; an implement behind the tractor: nothing changes
    def cusp_moves(back):
        lp = lane_lua.table_from([lane_lua.table_from({"x": wl[i].x, "z": wl[i].z, "work": bool(wl[i].work),
                                                       "rev": bool(wl[i].rev)}) for i in range(1, len(wl) + 1)])
        before = [(lp[i].x, lp[i].z) for i in range(1, len(lp) + 1)]
        me = lane_lua.table_from({"info": lane_lua.table_from({"backOffset": back})})
        G2.GuidanceFieldworkDriver.reachBackAtCusps(me, lp)
        moved, inline = 0, True
        for i in range(1, len(lp) + 1):
            bx, bz = before[i - 1]
            if abs(lp[i].x - bx) + abs(lp[i].z - bz) > 1e-6:
                moved += 1
                nx, nz = lp[i + 1].x, lp[i + 1].z
                # on the line from the old point to the next one, behind the old point
                cross = (bx - lp[i].x) * (nz - lp[i].z) - (bz - lp[i].z) * (nx - lp[i].x)
                if abs(cross) > 1e-3 * math.hypot(nx - lp[i].x, nz - lp[i].z):
                    inline = False
        return moved, inline
    G2 = smoke_test.fresh_lua({"rect": [(0, 0), (250, 0), (250, 290), (0, 290)]}, "rect").globals()
    lane_lua = G2._G and smoke_test.fresh_lua({"rect": [(0, 0), (250, 0), (250, 290), (0, 290)]}, "rect")
    G2 = lane_lua.globals()
    lane_course, _ = fp.generate(lane_lua, [(0, 0), (250, 0), (250, 290), (0, 290)],
                                 {"workWidth": 5.5, "turnRadius": 8.758, "runOut": 2, "headlands": 8,
                                  "allowReverse": True, "squareCorners": True, "roundedPasses": 0})
    wl = lane_course["lua"].waypoints
    front_moved, front_inline = cusp_moves(4.1)
    rear_moved, _ = cusp_moves(-5)
    check("header ahead at square corners", front_moved >= 20 and front_inline and rear_moved == 0,
          f"{front_moved} reverse ends moved back for a header 4.1 m ahead (on the line driven on: {front_inline}), "
          f"{rear_moved} for an implement behind")

    # square corners next to a cut-off corner of the field (a player's field 42B, its edges along x and z): the points
    # beside a corner are pushed in off the edges there; the manoeuvre still turns by the edges, so each reverse runs
    # along an edge and is short (before 1.0.4.8: a 154 degree turn, backing up 45 m across the field)
    cut = [(1145.19, -846.49), (1035.19, -846.49), (1033.19, -846.99), (1025.19, -846.99), (1019.47, -848.90),
           (1019.47, -860.90), (1018.97, -862.90), (1018.97, -868.90), (1019.47, -870.90), (1019.47, -974.90),
           (1018.97, -976.90), (1018.97, -984.90), (1019.47, -990.90), (1020.47, -992.90), (1023.97, -996.90),
           (1027.97, -1000.90), (1033.19, -1004.99), (1034.47, -1006.90), (1034.97, -1008.90), (1037.19, -1009.99),
           (1467.19, -1009.99), (1467.47, -910.90), (1467.97, -908.90), (1467.97, -862.90), (1467.47, -860.90),
           (1467.19, -847.99), (1465.19, -846.99), (1455.19, -846.99), (1451.19, -845.99), (1437.19, -846.49),
           (1435.19, -846.99), (1431.19, -846.49)]
    cut_course, _ = fp.generate(lane_lua, cut,
                                {"workWidth": 5.5, "turnRadius": 8.758, "runOut": 2, "headlands": -1,
                                 "minHeadlandWidth": 40, "allowReverse": True, "squareCorners": True,
                                 "roundedPasses": 1, "clockwise": True, "headlandsFirst": True,
                                 "startX": 1098.67, "startZ": -860.21})
    cw = cut_course["waypoints"]
    longest, skewed, n_rev = 0, 0, 0
    for a, b in zip(cw, cw[1:]):
        if b["rev"] and not a["rev"]:
            n_rev += 1
            dx, dz = b["x"] - a["x"], b["z"] - a["z"]
            longest = max(longest, math.hypot(dx, dz))
            if min(abs(dx), abs(dz)) > 1:
                skewed += 1
    check("square corners by a cut-off corner", n_rev > 20 and longest < 16 and skewed == 0,
          f"{n_rev} reverses, longest {longest:.1f} m, {skewed} across the edges")

    whole = G.makeCourse(F, T({}))
    whole_rows = list(G.rowsOf(whole).values())
    n_lines = len(whole_rows)

    # lands: each land of 6 rows from its middle out (rows in a land: their places, the middle first)
    lands = G.makeCourse(F, T({"pattern": 4, "rowsPerLand": 6}))
    order = [r.line for r in G.rowsOf(lands).values()]
    land1 = order[:6]
    # six neighbouring rows; from the first one out, one side then the other, each further away
    dists = [abs(r - land1[0]) for r in land1[1:]]
    sides = [r - land1[0] for r in land1[1:]]
    middle_out = (len(land1) == 6 and max(land1) - min(land1) == 5 and dists == sorted(dists)
                  and all(sides[i] * sides[i + 1] < 0 for i in range(len(sides) - 1)))
    check("lands", middle_out and sorted(order) == list(range(1, n_lines + 1)),
          f"first land {land1}, {len(order)} rows (whole {n_lines})")
    check("lands on the field", off_field(lands, pts) <= 0.75, f"{off_field(lands, pts):.2f} m")

    # lands with a worked side (a harvester's pipe): in each land, the rows worked before always on that side
    for side, side_name in ((1, "left"), (2, "right")):
        c = G.makeCourse(F, T({"pattern": 4, "rowsPerLand": 6, "landsSide": side}))
        rows = list(G.rowsOf(c).values())
        wrong, checked = 0, 0
        for start in range(0, len(rows), 6):
            land = rows[start:start + 6]
            for j in range(1, len(land)):
                r = land[j]
                dx, dz = r.bx - r.ax, r.bz - r.az
                for prev in land[:j]:
                    cross = dx * (prev.z - r.az) - dz * (prev.x - r.ax)
                    on = 1 if cross < 0 else 2
                    checked += 1
                    wrong += on != side
        check(f"lands worked {side_name}", checked > 20 and wrong == 0,
              f"{checked} looks back over a land, {wrong} on the wrong side")

    # spiral: no rows, many passes
    spiral = G.makeCourse(F, T({"pattern": 5}))
    passes = {spiral.waypoints[i]["pass"] for i in range(1, len(spiral.waypoints) + 1)
              if spiral.waypoints[i].t == "H"} - {None}
    # (further in than a normal course's headlands: on into where the rows would be)
    check("spiral", spiral.stats.rows == 0 and len(passes) > whole.stats.headlands,
          f"{len(passes)} passes, {spiral.stats.rows} rows")
    check("spiral on the field", off_field(spiral, pts) <= 0.75, f"{off_field(spiral, pts):.2f} m")

    # curved rows: along the edge, more than two points each
    curved = G.makeCourse(F, T({"rowShape": 1}))
    crow = list(G.rowsOf(curved).values())
    bent = sum(1 for r in crow if r.n > 2)
    check("curved rows", len(crow) > 5 and bent > 0, f"{len(crow)} rows, {bent} with bends")
    check("curved on the field", off_field(curved, pts) <= 0.75, f"{off_field(curved, pts):.2f} m")

    # tramlines: an 18 m sprayer on the 6 m sowing course's passes (every 3rd, the middle one)
    lines = [whole.stats.rowLines[i] for i in range(1, len(whole.stats.rowLines) + 1)]
    step = (lines[-1] - lines[0]) / (len(lines) - 1)
    phase, spacing = lines[0] + step, 3 * step
    tram = G.makeCourse(F, T({"workWidth": 18, "tramlines": True, "rowAngle": whole.stats.rowAngle,
                              "rowPhase": phase, "rowSpacing": spacing}))
    tlines = [tram.stats.rowLines[i] for i in range(1, len(tram.stats.rowLines) + 1)]
    on_pass = all(min(abs(y - l) for l in lines) < 0.05 for y in tlines)
    groups = all(abs(((y - lines[0]) / step) % 3 - 1) < 0.02 for y in tlines)
    check("tramlines", len(tlines) >= 2 and on_pass and groups,
          f"{len(tlines)} sprayer rows, each on a sowing pass, the middle of 3: {groups}")

    # rows left out: gone, and listed for the editor
    skipped = G.makeCourse(F, T({"skipRows": "2 5 9"}))
    srows = list(G.rowsOf(skipped).values())
    sk_lines = sorted(l.line for l in skipped.skippedLines.values())
    check("skip rows", len(srows) == n_lines - 3 and sk_lines == [2, 5, 9] and all(r.line not in (2, 5, 9) for r in srows),
          f"{len(srows)} of {n_lines} rows, left out {sk_lines}")

    # an area worked round: no waypoint in it
    xs = [p[0] for p in pts]
    zs = [p[1] for p in pts]
    # in the middle of the rows (an obstacle in the headland band isn't worked round, see the README)
    rws = [w for w in waypoints(whole) if w["t"] == "R"]
    cx = (min(w["x"] for w in rws) + max(w["x"] for w in rws)) / 2
    cz = (min(w["z"] for w in rws) + max(w["z"] for w in rws)) / 2
    zone = (cx - 8, cz - 8, cx + 8, cz + 8)
    zoned = G.makeCourse(F, T({"skipZones": "%.1f %.1f %.1f %.1f" % zone}))
    # every piece of the course, walked in 1 m steps (a straight row has waypoints only at its ends): none in the
    # area (1 m in from its edge)
    inside = 0
    wl = waypoints(zoned) if zoned else []
    for a, b in zip(wl, wl[1:]):
        n = max(1, int(math.hypot(b["x"] - a["x"], b["z"] - a["z"])))
        for k in range(n + 1):
            x = a["x"] + (b["x"] - a["x"]) * k / n
            z = a["z"] + (b["z"] - a["z"]) * k / n
            if zone[0] + 1 < x < zone[2] - 1 and zone[1] + 1 < z < zone[3] - 1:
                inside += 1
                break
    check("skip area", zoned is not None and inside == 0,
          f"{inside} pieces of the course through the area, islands with passes {zoned.stats.islands if zoned else '?'}")
    # one too big to work round in the room there (the whole width of the rows): not worked round, but warned
    big = (cx - 200, cz - 8, cx + 200, cz + 8)
    zoned2 = G.makeCourse(F, T({"skipZones": "%.1f %.1f %.1f %.1f" % big}))
    warned = zoned2 is not None and (zoned2.stats.islandsIgnored or 0) >= 1
    check("skip area too big", warned, f"warned {(zoned2.stats.islandsIgnored or 0) if zoned2 else '?'} obstacle(s)")

    # an obstacle near the edge (a 4 m box 8 m in from the longest edge, in the headland band): driven over as before
    # (warned), or with "work round" notched into the edge: no piece of the course within 3 m of it (half the 6 m
    # implement), the course still on the field
    k = max(range(len(pts)), key=lambda i: math.dist(pts[i], pts[(i + 1) % len(pts)]))
    a, b = pts[k], pts[(k + 1) % len(pts)]
    mx, mz = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
    ex, ez = b[0] - a[0], b[1] - a[1]
    el = math.hypot(ex, ez)
    nx, nz = -ez / el, ex / el
    gx, gz = sum(x for x, _ in pts) / len(pts), sum(z for _, z in pts) / len(pts)
    if (gx - mx) * nx + (gz - mz) * nz < 0:
        nx, nz = -nx, -nz
    ox, oz = mx + nx * 8, mz + nz * 8
    box = (ox - 2, oz - 2, ox + 2, oz + 2)

    def through(course, grow):
        hits = 0
        wl = waypoints(course) if course else []
        for p1, p2 in zip(wl, wl[1:]):
            n2 = max(1, int(math.hypot(p2["x"] - p1["x"], p2["z"] - p1["z"]) * 2))
            for j in range(n2 + 1):
                x = p1["x"] + (p2["x"] - p1["x"]) * j / n2
                z = p1["z"] + (p2["z"] - p1["z"]) * j / n2
                if box[0] - grow < x < box[2] + grow and box[1] - grow < z < box[3] + grow:
                    hits += 1
                    break
        return hits
    over = G.makeCourse(F, T({"skipZones": "%.1f %.1f %.1f %.1f" % box}))
    roundc = G.makeCourse(F, T({"skipZones": "%.1f %.1f %.1f %.1f" % box, "edgeObstacles": 1}))
    over_hits = through(over, 0)
    round_hits = through(roundc, 3 - 0.05)
    notched = (roundc.stats.notched or 0) if roundc else 0
    off = off_field(roundc, pts) if roundc else 99
    check("edge obstacle, driven over (switch off)", over is not None and (over.stats.islandsIgnored or 0) >= 1
          and over_hits > 0, f"{over_hits} pieces through it, warned {(over.stats.islandsIgnored or 0) if over else '?'}")
    check("edge obstacle, worked round (switch on)", roundc is not None and notched == 1 and round_hits == 0
          and (roundc.stats.islandsIgnored or 0) == 0 and off < 0.6,
          f"notched {notched}, {round_hits} pieces within 3 m of it, worst {off:.2f} m off the field, "
          f"{roundc.stats.headlands if roundc else '?'} headland passes, {roundc.stats.rows if roundc else '?'} rows")

    # driven: lands, spiral, curved rows to the end by the test tractor
    drive = smoke_test.DRIVE
    a = drive.index("    local vt = {events")
    last = "    vt.listeners.onLoad(v, nil)\n"
    b = drive.index(last) + len(last)
    lua.execute("function makeTeamVehicle(flat)\n    local mode = nil\n" + drive[a:b] + "    return v\nend\n")
    lua.execute(tdt.HARNESS)
    for name, values in (("lands", {"pattern": 4}), ("spiral", {"pattern": 5}), ("curved", {"rowShape": 1})):
        G.TEAM_SETTINGS = T(values)
        r = G.runTeam(F, 1, 0)
        if r["error"]:
            check(f"drive {name}", False, r["error"])
            continue
        fin = r["finished"][1]
        check(f"drive {name}", fin == "AIMessageSuccessFinishedJob",
              f"{r['steps'] / 600:.0f} min, worked {100 * r['coverage']:.1f}%, {fin}")
    G.TEAM_SETTINGS = None
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

"""Checks offline the field read from the ground (scripts/course/FieldScan.lua) with made-up field ground: the map's
field as it is (the map's outline is used), field ground painted on (a field of its own, the course covers the new
part), painted away, a field painted where the map has none, a spot inside that is not field (an island), the same
ground again (no new field), and a player on a server (the field goes to the server first). Also the time a scan
takes.

Usage:
    python fieldscan_test.py <map.i3d> [field number]
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402
import smoke_test  # noqa: E402

LUA = r"""
local function poly(flat)
    local p = {}
    for i = 1, #flat - 1, 2 do p[#p + 1] = {x = flat[i], y = flat[i + 1]} end
    return p
end

--- the field ground: the map's field (or not), plus rectangles painted on, minus rectangles painted away
function setGround(flat, withField, added, removed)
    local field = poly(flat)
    GuidanceFieldScan.isFieldAt = function(x, z)
        for _, r in ipairs(removed) do
            if x > r[1] and x < r[3] and z > r[2] and z < r[4] then return false end
        end
        for _, r in ipairs(added) do
            if x > r[1] and x < r[3] and z > r[2] and z < r[4] then return true end
        end
        return withField and GuidanceGeo.pointInPolygon({x = x, y = z}, field)
    end
    GuidanceCourse.islandCache = {}
end

--- field ground area (m²) in a box, sampled every metre
function groundArea(x1, z1, x2, z2)
    local n = 0
    for x = x1 + 0.5, x2, 1 do
        for z = z1 + 0.5, z2, 1 do
            if GuidanceFieldScan.isFieldAt(x, z) then n = n + 1 end
        end
    end
    return n
end

function fieldFor(x, z)
    local id, a, b = GuidanceCourse.fieldForCourse(x, z, 1)
    return id, a, b
end

function courseOn(fieldId)
    local plan = GuidancePlan.new()
    plan.workWidth, plan.turnRadius, plan.autoWidth, plan.runOut = 6, 6, false, 3
    plan.fieldId = fieldId
    return GuidanceCourse.generate(plan)
end

--- share of points of a rectangle (inner part) a course's rows pass within 4 m of
function covered(course, r)
    local n, hit = 0, 0
    for x = r[1] + 8, r[3] - 8, 4 do
        for z = r[2] + 8, r[4] - 8, 4 do
            n = n + 1
            for _, w in ipairs(course.waypoints) do
                if w.t == "R" and math.abs(w.x - x) < 4 and math.abs(w.z - z) < 4 then hit = hit + 1; break end
            end
        end
    end
    -- rows are made of their end points: also count a row passing between two of them
    local hit2 = 0
    for x = r[1] + 8, r[3] - 8, 4 do
        for z = r[2] + 8, r[4] - 8, 4 do
            local wps = course.waypoints
            for i = 2, #wps do
                local a, b = wps[i - 1], wps[i]
                if a.t == "R" and b.t == "R" and not b.rs then
                    local dx, dz = b.x - a.x, b.z - a.z
                    local l2 = dx * dx + dz * dz
                    local t = l2 > 0 and math.max(0, math.min(1, ((x - a.x) * dx + (z - a.z) * dz) / l2)) or 0
                    local ex, ez = a.x + dx * t - x, a.z + dz * t - z
                    if ex * ex + ez * ez < 16 then hit2 = hit2 + 1; break end
                end
            end
        end
    end
    return n > 0 and hit2 / n or 0
end
"""


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
    T = lambda d: lua.table_from([lua.table_from(r) for r in d])  # noqa: E731
    G.makeField(7, F)
    xs, zs = [p[0] for p in pts], [p[1] for p in pts]
    minx, maxx, minz, maxz = min(xs), max(xs), min(zs), max(zs)
    cx, cz = sum(xs) / len(xs), sum(zs) / len(zs)
    area_map = G.GuidanceFieldScan.areaOf(lua.table_from([lua.table_from({"x": x, "z": z}) for x, z in pts]))
    ok = True

    def check(name, good, info=""):
        nonlocal ok
        ok = ok and bool(good)
        print(f"{name}: {info}{': ' if info else ''}{'OK' if good else 'FAILED'}")

    def nfields():
        return len(list(G.GuidanceLibrary.fields.values()))

    # 1. the map's field as it is: its own outline
    G.setGround(F, True, T([]), T([]))
    t0 = time.time()
    fid = G.fieldFor(cx, cz)
    dt = time.time() - t0
    fid = fid[0] if isinstance(fid, tuple) else fid
    check("as the map", fid == 7 and nfields() == 0, f"field {fid}, {area_map / 10000:.2f} ha, scan {dt:.2f} s here")

    def truth():
        return G.groundArea(minx - 120, minz - 20, maxx + 120, maxz + 20)

    # 2. painted on: 80 m more along the long west side
    ext = [minx - 80, minz + 20, minx + 5, maxz - 20]
    G.setGround(F, True, T([ext]), T([]))
    r = G.fieldFor(cx, cz)
    fid, _, scanned = r if isinstance(r, tuple) else (r, None, None)
    f = G.GuidanceLibrary.getField(fid) if fid else None
    area = G.GuidanceFieldScan.areaOf(f.outline) if f else 0
    want = truth()
    course = G.courseOn(fid) if f else None
    # rows: inside the headlands (40 m) of the new part
    cov = G.covered(course, lua.table_from([ext[0] + 40, ext[1] + 40, minx, ext[3] - 40])) if course else 0
    check("painted on", f is not None and fid < 0 and f.baseField == 7 and abs(area - want) / want < 0.03 and cov > 0.9,
          f"field {fid} base {f.baseField if f else '?'}, {area / 10000:.2f} ha (about {want / 10000:.2f}), "
          f"rows over {100 * cov:.0f}% of the new part")

    # 3. the same ground again: the same field, nothing new
    n_before = nfields()
    r = G.fieldFor(cx, cz)
    fid2 = r[0] if isinstance(r, tuple) else r
    check("same again", fid2 == fid and nfields() == n_before, f"field {fid2}, {nfields()} field(s)")

    # 4. painted more: the same field, its outline bigger
    ext2 = [minx - 120, minz + 20, minx + 5, maxz - 20]
    G.setGround(F, True, T([ext2]), T([]))
    r = G.fieldFor(cx, cz)
    fid3 = r[0] if isinstance(r, tuple) else r
    area3 = G.GuidanceFieldScan.areaOf(G.GuidanceLibrary.getField(fid3).outline)
    check("painted more", fid3 == fid and nfields() == n_before and area3 > area + 0.9 * 40 * (ext[3] - ext[1]),
          f"field {fid3}, {area3 / 10000:.2f} ha")

    # 5. painted away: a bite out of the west side (50 x 60 m), from a fresh start
    G.GuidanceLibrary.fields = lua.table_from([])
    cut = [minx - 10, cz - 30, minx + 50, cz + 30]
    G.setGround(F, True, T([]), T([cut]))
    want4 = truth()
    r = G.fieldFor(cx, cz)
    fid4 = r[0] if isinstance(r, tuple) else r
    f4 = G.GuidanceLibrary.getField(fid4) if fid4 and fid4 < 0 else None
    area4 = G.GuidanceFieldScan.areaOf(f4.outline) if f4 else 0
    course4 = G.courseOn(fid4) if f4 else None
    inside_cut = 0
    if course4:
        for i in range(1, len(course4.waypoints) + 1):
            w = course4.waypoints[i]
            if cut[0] + 2 < w.x < cut[2] - 2 and cut[1] + 2 < w.z < cut[3] - 2:
                inside_cut += 1
    check("painted away", f4 is not None and abs(area4 - want4) / want4 < 0.01 and inside_cut == 0,
          f"field {fid4}, {area4 / 10000:.2f} ha (on the ground {want4 / 10000:.2f}, map {area_map / 10000:.2f}), "
          f"{inside_cut} waypoints where it is gone")

    # 6. a spot inside that is not field: an island of the field read from the ground
    G.GuidanceLibrary.fields = lua.table_from([])
    # (in the middle of the rows: an island in the headland band isn't worked round, see the README)
    rows_x = [course.waypoints[i].x for i in range(1, len(course.waypoints) + 1) if course.waypoints[i].t == "R"]
    rows_z = [course.waypoints[i].z for i in range(1, len(course.waypoints) + 1) if course.waypoints[i].t == "R"]
    mx, mz = (min(rows_x) + max(rows_x)) / 2, (min(rows_z) + max(rows_z)) / 2
    spot = [mx - 15, mz - 15, mx + 15, mz + 15]
    G.setGround(F, True, T([ext]), T([spot]))
    r = G.fieldFor(mx + 40, mz)
    fid5 = r[0] if isinstance(r, tuple) else r
    found = len(list(G.GuidanceCourse.findIslands(fid5, G.GuidanceCourse.getFieldOutline(fid5)).values())) if fid5 else 0
    course5 = G.courseOn(fid5) if fid5 else None
    in_spot = 0
    if course5:
        for i in range(1, len(course5.waypoints) + 1):
            w = course5.waypoints[i]
            if spot[0] + 3 < w.x < spot[2] - 3 and spot[1] + 3 < w.z < spot[3] - 3:
                in_spot += 1
                print(f"  on the spot: waypoint {i} {w.t} ({w.x - spot[0]:.1f}, {w.z - spot[1]:.1f}) in the 30 m spot")
    check("island", course5 is not None and found >= 1 and in_spot == 0,
          f"field {fid5}, {found} island(s) found, {in_spot} waypoints on it")

    # 7. a field painted where the map has none (far off field 7, on its farmland)
    G.GuidanceLibrary.fields = lua.table_from([])
    far = [maxx + 300, minz, maxx + 450, minz + 120]
    G.setGround(F, True, T([far]), T([]))
    r = G.fieldFor(far[0] + 70, far[1] + 60)
    fid6 = r[0] if isinstance(r, tuple) else r
    f6 = G.GuidanceLibrary.getField(fid6) if fid6 and fid6 < 0 else None
    area6 = G.GuidanceFieldScan.areaOf(f6.outline) if f6 else 0
    check("painted new", f6 is not None and f6.baseField == 0 and abs(area6 - 150 * 120) / (150 * 120) < 0.02,
          f"field {fid6} '{f6.name if f6 else '?'}', {area6:.0f} m² (150 x 120 = 18000)")

    # 8. not on any field ground: the map's field (as before), no scan result
    G.GuidanceLibrary.fields = lua.table_from([])
    G.setGround(F, False, T([]), T([]))
    r = G.fieldFor(cx, cz)
    fid7 = r[0] if isinstance(r, tuple) else r
    check("no ground", fid7 == 7 and nfields() == 0, f"field {fid7}")

    # 9. a player on a server: the field goes to the server, the course is made when it is back
    G.setGround(F, True, T([ext]), T([]))
    lua.execute("SAVED_SERVER = g_server; g_server = nil; SENT = nil; GuidanceLibraryEvent.toServer = function(k, d) SENT = d end")
    r = G.fieldFor(cx, cz)
    first, sent = (r[0], r[1]) if isinstance(r, tuple) else (r, None)
    lua.execute("g_server = SAVED_SERVER")
    back_before = G.GuidanceCourse.isFieldBack(sent) if sent else None
    if G.SENT:
        G.GuidanceLibrary.applyAddField(G.SENT)  # the server's answer
    back = G.GuidanceCourse.isFieldBack(sent) if sent else None
    check("client", first is False and sent is not None and back_before is None and back is not None and back < 0,
          f"first {first}, back as field {back}")

    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

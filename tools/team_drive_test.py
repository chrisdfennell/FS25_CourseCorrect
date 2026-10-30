"""Drives a whole team on one field offline, every helper at the same time (the smoke test's tractor with a 6 m
implement, each its own), for each team mode: Strips, Convoy, Next free row; and one tractor alone to compare.
Checks: every helper finishes, the field gets worked (cells of 1 m the implements went over while working, of the
field's inside), little is worked twice, the tractors never come too close, next-free-row rows are done once each.

Usage:
    python team_drive_test.py <map.i3d> [field number] [team size]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402
import smoke_test  # noqa: E402

HARNESS = r"""
local function leftOf(h) return math.sin(h), -math.cos(h) end

--- the field's inside cells (1 m), at least 1 m in from the outline
local function insideCells(flat)
    local poly = {}
    for i = 1, #flat - 1, 2 do poly[#poly + 1] = {x = flat[i], y = flat[i + 1]} end
    poly = GuidanceGeo.ensureCCW(poly)
    local idx = GuidanceGeo.outlineIndex(poly, 10)
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(poly) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minY, maxY = math.min(minY, p.y), math.max(maxY, p.y)
    end
    local cells, n = {}, 0
    for cx = math.floor(minX), math.ceil(maxX) do
        for cy = math.floor(minY), math.ceil(maxY) do
            local p = {x = cx + 0.5, y = cy + 0.5}
            if idx:isInside(p) and idx:closest(p, 1.0) == nil then
                cells[cx * 100003 + cy] = true
                n = n + 1
            end
        end
    end
    return cells, n
end

function runTeam(flat, size, mode)
    FIELDS = {}
    makeField(7, flat)
    STARTED_JOB = nil
    GuidanceTeam.fields = {}
    GuidanceCourseGenerator.wholeCache = nil
    local members = {}
    for k = 1, size do
        local v = makeTeamVehicle(flat)
        -- side by side near the field's first corner, a little apart
        v.rootNode.x, v.rootNode.z = flat[1] + 5 + (k - 1) * 9, flat[2] + 5
        members[k] = v
    end
    g_currentMission.vehicleSystem = {vehicles = members}
    -- settings for this run (a pattern to drive, ...)
    for _, v in ipairs(members) do
        for name, value in pairs(TEAM_SETTINGS or {}) do v.spec_guidance.settings[name] = value end
    end
    local ok, err
    if size == 1 then
        ok, err = members[1]:guidanceGenerate()
    else
        ok, err = GuidanceTeam.makeCourses(members, 7, mode)
    end
    if not ok then return {error = tostring(err)} end
    -- everybody starts (at the first waypoint of its course)
    local jobs = {}
    for k, v in ipairs(members) do
        v:getGuidanceSettings().startMode = GuidancePlan.START_FIRST
        STARTED_JOB = nil
        v:guidanceStartStop()
        local job = STARTED_JOB
        if job == nil then return {error = "no job for member " .. k} end
        job:start(1)
        job.tasks[1]:start()
        jobs[k] = job
    end
    local cells, nInside = insideCells(flat)
    local worked, twice = {}, {}
    local dt, steps, maxSteps = 100, 0, TEAM_MAX_STEPS or 400000
    local minDist = math.huge
    local finished = {}
    local takes = {}
    local takeRow = GuidanceTeam.takeRow
    GuidanceTeam.takeRow = function(fieldId, rows, vehicle, ...)
        local r, rev, across = takeRow(fieldId, rows, vehicle, ...)
        if r then takes[r.row] = (takes[r.row] or 0) + 1 end
        return r, rev, across
    end
    local active = size
    while active > 0 and steps < maxSteps do
        steps = steps + 1
        active = 0
        for k, v in ipairs(members) do
            if v.job ~= nil then
                active = active + 1
                local node = v.rootNode
                local driver = v.spec_aiFieldWorker.driveStrategies[1]
                local tx, tz, fwd, maxSpeed = driver:getDriveData(dt, node.x, 0, node.z)
                local speed = math.min(maxSpeed or 0, 12) / 3.6
                local hm = fwd and node.h or node.h + math.pi
                local dx, dz = tx - node.x, tz - node.z
                local alpha = math.atan2(dz, dx) - hm
                alpha = (alpha + math.pi) % (2 * math.pi) - math.pi
                local dist = math.max(math.sqrt(dx * dx + dz * dz), 0.1)
                local curv = math.max(-1 / 5.4, math.min(1 / 5.4, 2 * math.sin(alpha) / dist))
                hm = hm + speed * dt / 1000 * curv
                node.x = node.x + speed * dt / 1000 * math.cos(hm)
                node.z = node.z + speed * dt / 1000 * math.sin(hm)
                node.h = fwd and hm or hm - math.pi
                v.speed = speed * 3.6
                -- what the implement works: across its width at the work point, while down and switched on
                if driver.lowered and not driver.switchedOff and v.job ~= nil then
                    -- the test implement works centred behind the tractor (in a convoy, in its lane)
                    local wx, wz = node.x, node.z
                    local lx, lz = leftOf(node.h)
                    local half = (driver.course.plan.workWidth or 6) / 2
                    local seen = {}
                    for o = -half + 0.25, half - 0.25, 0.5 do
                        local key = math.floor(wx + lx * o) * 100003 + math.floor(wz + lz * o)
                        if not seen[key] then
                            seen[key] = true
                            local by = worked[key]
                            if by == nil then
                                worked[key] = k
                            elseif by ~= k then
                                twice[key] = true
                            end
                        end
                    end
                end
            elseif not finished[k] then
                finished[k] = STOP_MESSAGE and STOP_MESSAGE.name or "stopped"
            end
        end
        if TEAM_DEBUG and steps % TEAM_DEBUG == 0 then
            DEBUG_LINES[#DEBUG_LINES + 1] = "step " .. steps .. " | " .. convoyDebug(members)
        end
        -- how close the tractors come (only while two are driving)
        for a = 1, size do
            for b = a + 1, size do
                if members[a].job and members[b].job then
                    local na, nb = members[a].rootNode, members[b].rootNode
                    minDist = math.min(minDist, math.sqrt((na.x - nb.x) ^ 2 + (na.z - nb.z) ^ 2))
                end
            end
        end
    end
    GuidanceTeam.takeRow = takeRow
    for k, v in ipairs(members) do
        if v.job ~= nil then finished[k] = "still driving" end
    end
    local covered, overlap = 0, 0
    for key in pairs(cells) do
        if worked[key] then covered = covered + 1 end
        if twice[key] then overlap = overlap + 1 end
    end
    local result = {steps = steps, coverage = covered / nInside, twice = overlap / nInside,
                    minDist = minDist, finished = finished}
    -- next free row: every row once
    local rows = members[1]:getGuidanceCourse().teamRows
    if rows then
        local once, more, none = 0, 0, 0
        local done = GuidanceTeam.count(7, rows)
        for _, r in ipairs(rows) do
            local t = takes[r.row] or 0
            if t == 1 then once = once + 1 elseif t > 1 then more = more + 1 else none = none + 1 end
        end
        result.rows = string.format("%d rows: %d taken once, %d more than once, %d never; %d done", #rows, once, more,
            none, done)
        result.rowsOk = more == 0 and none == 0 and done == #rows
    end
    return result
end
"""


def main():
    i3d = sys.argv[1]
    field = f"field{sys.argv[2] if len(sys.argv) > 2 else 9}"
    size = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    fields = fp.read_fields(i3d)
    flat = []
    for x, z in fields[field]:
        flat += [x, z]
    lua = smoke_test.fresh_lua(fields, field)
    drive = smoke_test.DRIVE
    a = drive.index("    local vt = {events")
    last = "    vt.listeners.onLoad(v, nil)\n"
    b = drive.index(last) + len(last)
    lua.execute("function makeTeamVehicle(flat)\n    local mode = nil\n" + drive[a:b] + "    return v\nend\n")
    lua.execute(HARNESS)
    G = lua.globals()
    ok = True
    alone = None
    for name, mode_name, n in (("alone", None, 1), ("strips", "TEAM_STRIPS", size), ("convoy", "TEAM_CONVOY", size),
                               ("next free row", "TEAM_NEXT_ROW", size), ("lands", "TEAM_LANDS", size)):
        mode = G.GuidancePlan[mode_name] if mode_name else 0
        r = G.runTeam(lua.table_from(flat), n, mode)
        if r["error"]:
            print(f"{name}: ERROR {r['error']}")
            ok = False
            continue
        finished = [r["finished"][k] for k in range(1, n + 1)]
        all_done = all(f == "AIMessageSuccessFinishedJob" for f in finished)
        minutes = r["steps"] / 600
        line = (f"{name} ({n}): {minutes:.0f} min, worked {100 * r['coverage']:.1f}% of the field, twice "
                f"{100 * r['twice']:.1f}%, closest {r['minDist']:.1f} m, finished: {', '.join(finished)}")
        if r["rows"]:
            line += f"; {r['rows']}"
        good = all_done
        if name == "alone":
            alone = r
        else:
            good = (good and r["coverage"] >= alone["coverage"] - 0.02 and r["minDist"] > 4
                    and minutes < alone["steps"] / 600)
            if r["rows"]:
                good = good and r["rowsOk"]
        print(line + (": OK" if good else ": FAILED"))
        ok = ok and good
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

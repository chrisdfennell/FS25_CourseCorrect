"""Checks offline the vineyards (scripts/course/Vines.lua, CourseGenerator.generateFromLines):

- a made-up vineyard on the vine system: 14 rows 2.8 m apart, 80 m long, turned 30 degrees, in two plots (the rows of
  one in two pieces each, end to end), and a second vineyard 300 m away at another angle that must stay apart;
- standing among the vines makes a field of the vineyard (its rows and room round them), named "Vineyard 1";
- with a grape harvester the course drives every row once, on the row, from 2 m before its first vine to 2 m past
  its last; turns stay inside the vineyard's outline, the next row far enough to the side to turn into;
- a sprayer (5.6 m) drives between the rows, every other gap: every row sprayed from one side or the other;
- the vine tools are unfolded, lowered and switched on at the row start, raised and switched off at its end.

Usage:
    python vines_test.py <map.i3d or fields.json>
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402
import smoke_test  # noqa: E402

LUA = r"""
local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end

-- a plot: rows from 'first' to 'last' (numbers across), pieces per row
local function plot(ox, oz, h, first, last, pieces, len, width)
    local dx, dz, nx, nz = math.cos(h), math.sin(h), -math.sin(h), math.cos(h)
    local segs = {}
    for r = first, last do
        local lat = (r - 1) * width
        for k = 1, pieces do
            local a, b = len * (k - 1) / pieces, len * k / pieces
            segs[{x1 = ox + dx * a + nx * lat, z1 = oz + dz * a + nz * lat,
                  x2 = ox + dx * b + nx * lat, z2 = oz + dz * b + nz * lat}] = {{node = 1}}
        end
    end
    return {spec_vine = {vineSegments = segs, width = width}}
end

function checkVines()
    local r = {}
    local h = math.rad(30)
    local ox, oz = 1000, 1000
    local p1 = plot(ox, oz, h, 1, 8, 1, 80, 2.8)
    local p2 = plot(ox, oz, h, 9, 14, 2, 80, 2.8)
    local other = plot(1300, 1000, math.rad(100), 1, 6, 1, 50, 2.5)
    g_currentMission.vineSystem = {nodes = {[11] = p1, [12] = p1, [13] = p2, [14] = other}}
    -- standing between rows 4 and 5, near the start
    local nx, nz = -math.sin(h), math.cos(h)
    local sx, sz = ox + math.cos(h) * 5 + nx * 3.5 * 2.8, oz + math.sin(h) * 5 + nz * 3.5 * 2.8
    local vineyard = GuidanceVines.at(sx, sz)
    r.rows = #vineyard.rows
    r.spacing = vineyard.spacing
    r.separate = GuidanceVines.at(1310, 1010) ~= nil and #GuidanceVines.at(1310, 1010).rows == 6
    -- the field of it
    local id, err, field = GuidanceCourse.fieldForCourse(sx, sz, 1)
    r.fieldName = field and field.name or tostring(err)
    local outline = GuidanceCourse.getFieldOutline(id)
    local poly = {}
    for i, p in ipairs(outline) do poly[i] = {x = p.x, y = p.z} end

    local function course(vineMode, vineTool, width)
        local plan = GuidancePlan.new()
        plan.fieldId = id
        plan.workWidth, plan.autoWidth, plan.turnRadius, plan.runOut = width, false, 5, 3
        plan.startX, plan.startZ = sx, sz
        plan.vineMode, plan.vineTool = vineMode, vineTool
        local c, e = GuidanceCourse.generate(plan)
        assert(c, tostring(e))
        return c
    end
    local function rowsOf(c)
        local out = {}
        for i = 2, #c.waypoints do
            local a, b = c.waypoints[i - 1], c.waypoints[i]
            if a.rs then
                -- the row runs from a to its re
                local j = i
                while not c.waypoints[j].re do j = j + 1 end
                local e = c.waypoints[j]
                local lat = ((a.x + e.x) / 2 - ox) * nx + ((a.z + e.z) / 2 - oz) * nz
                local la = (a.x - ox) * math.cos(h) + (a.z - oz) * math.sin(h)
                local le = (e.x - ox) * math.cos(h) + (e.z - oz) * math.sin(h)
                out[#out + 1] = {lat = lat, from = math.min(la, le), to = math.max(la, le)}
            end
        end
        return out
    end
    local function inside(c)
        local worst = 0
        for _, w in ipairs(c.waypoints) do
            if not GuidanceGeo.pointInPolygon({x = w.x, y = w.z}, poly) then worst = worst + 1 end
        end
        return worst
    end

    -- grape harvester: on every row
    local c = course(0, true, 2)
    local rows = rowsOf(c)
    local seen, onRow, ends, narrowTurns = {}, true, true, 0
    for k, row in ipairs(rows) do
        local n = row.lat / 2.8 + 1
        local ix = math.floor(n + 0.5)
        if math.abs(n - ix) > 0.05 then onRow = false end
        seen[ix] = (seen[ix] or 0) + 1
        if math.abs(row.from + 2) > 0.1 or math.abs(row.to - 82) > 0.1 then ends = false end
        if k > 1 and math.abs(row.lat - rows[k - 1].lat) < 10 then narrowTurns = narrowTurns + 1 end
    end
    local once = true
    for i = 1, 14 do if seen[i] ~= 1 then once = false end end
    r.harvester = #rows == 14 and once and onRow and ends and inside(c) == 0 and c.stats.pattern == "vines"
    r.harvesterInfo = string.format("%d rows, each once %s, on the row %s, 2 m past the vines %s, waypoints outside %d, turns into a row closer than 2 turning radii %d, %.0f m, %.0f min",
        #rows, tostring(once), tostring(onRow), tostring(ends), inside(c), narrowTurns, c.length, c.stats.time / 60)
    r.narrowTurns = narrowTurns

    -- sprayer between the rows, 5.6 m: every other gap
    c = course(0, false, 5.6)
    rows = rowsOf(c)
    local sprayed = {}
    local between = true
    for _, row in ipairs(rows) do
        local g = row.lat / 2.8 + 1  -- between rows g - 0.5 and g + 0.5
        if math.abs((g - math.floor(g)) - 0.5) > 0.05 then between = false end
        sprayed[math.floor(g)] = true
        sprayed[math.floor(g) + 1] = true
    end
    local all = true
    for i = 1, 14 do if not sprayed[i] then all = false end end
    r.sprayer = #rows == 7 and between and all and inside(c) == 0
    r.sprayerInfo = string.format("%d lines between the rows %s, every row sprayed %s, outside %d", #rows,
        tostring(between), tostring(all), inside(c))

    -- the tools: lowered, switched on, then off
    local log = {}
    local tool = {spec_vinePrepruner = {}, on = false, unfolded = false, spec_foldable = {turnOnFoldDirection = 1}}
    function tool:getIsTurnedOn() return self.on end
    function tool:setIsTurnedOn(on) self.on = on; log[#log + 1] = on and "on" or "off" end
    function tool:getIsUnfolded() return self.unfolded end
    function tool:setFoldDirection(d) self.unfolded = d == 1; log[#log + 1] = "unfold" end
    local tractor = {}
    function tractor:getAttacherJointIndexFromObject(o) return o == tool and 3 or nil end
    function tractor:setJointMoveDown(ix, down) log[#log + 1] = (down and "down" or "up") .. ix end
    function tool:getAttacherVehicle() return tractor end
    local fake = {vehicle = {getAttachedAIImplements = function() return {} end, raiseStateChange = function() end,
                             getChildVehicles = function() return {tractor, tool} end},
                  follower = {s = 0}, lowered = false}
    GuidanceFieldworkDriver.lowerImplements(fake)
    GuidanceFieldworkDriver.raiseImplements(fake)
    r.tools = table.concat(log, " ")
    return r
end
"""


def main():
    fields = fp.read_fields(sys.argv[1])
    lua = smoke_test.fresh_lua(fields, next(iter(fields)))
    lua.execute(LUA)
    r = lua.globals().checkVines()
    ok = True

    def check(name, good, info=""):
        nonlocal ok
        ok = ok and bool(good)
        print(f"{name}: {info}{': ' if info else ''}{'OK' if good else 'FAILED'}")

    check("vineyard read", r["rows"] == 14 and abs(r["spacing"] - 2.8) < 0.01 and r["separate"],
          f"{r['rows']} rows {r['spacing']:.2f} m apart (two plots, one in pieces), the other vineyard apart "
          f"{r['separate']}")
    # (the stand-in for the game's texts gives the text's name)
    check("vineyard field", r["fieldName"] in ("Vineyard 1", "guidance_vines_name"), r["fieldName"])
    check("grape harvester", r["harvester"], r["harvesterInfo"])
    check("sprayer", r["sprayer"], r["sprayerInfo"])
    check("vine tool", r["tools"] == "unfold down3 on up3 off", r["tools"])
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

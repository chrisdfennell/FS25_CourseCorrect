"""Checks several tractors on one field offline: every row and headland pass goes to exactly one member of a team
(strips of rows, headland passes dealt out), together they are the whole field, no member's turns leave the field;
and helpers give way to each other (slow down, stop, two in each other's way never both wait).

Usage:
    python team_test.py <map.i3d> [field numbers...]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402
import smoke_test  # noqa: E402

CHECKS = r"""
local function outline(flat)
    local pts = {}
    for i = 1, #flat - 1, 2 do pts[#pts + 1] = {x = flat[i], z = flat[i + 1]} end
    return pts
end

--- rows (by their middle, rounded) and headland passes of a course
local function shareOf(course)
    local rows, passes = {}, {}
    local wps = course.waypoints
    for i = 2, #wps do
        local a, b = wps[i - 1], wps[i]
        if b.re and b.t == "R" then
            rows[string.format("%.0f,%.0f", (a.x + b.x) / 2, (a.z + b.z) / 2)] = true
        end
        if b.t == "H" and b.pass and b.island == nil then passes[b.pass] = true end
    end
    return rows, passes
end

function checkTeam(flat, size, width, mode)
    local pts = outline(flat)
    local plan = GuidancePlan.new()
    plan.workWidth, plan.turnRadius, plan.autoWidth = width, 6, false
    local s = plan:getGeneratorSettings()
    local whole, err = GuidanceCourseGenerator.generate(pts, s)
    if whole == nil then return false, "whole: " .. tostring(err) end
    local wholeRows, wholePasses = shareOf(whole)
    local seenRows, seenPasses, offField = {}, {}, 0
    local nRows, nWholeRows = 0, 0
    for _ in pairs(wholeRows) do nWholeRows = nWholeRows + 1 end
    for k = 1, size do
        plan.teamMode, plan.teamSize, plan.teamIndex = mode or GuidancePlan.TEAM_STRIPS, size, k
        local c, err2 = GuidanceCourseGenerator.generate(pts, plan:getGeneratorSettings())
        if c == nil then
            -- a small field for a big team: some get nothing, which they're told
            local wholeShares = nWholeRows
            for _ in pairs(wholePasses) do wholeShares = wholeShares + 1 end
            if not (tostring(err2):find("nothing left") and wholeShares < size * 2) then
                return false, string.format("member %d: %s", k, tostring(err2))
            end
            c = {waypoints = {}, stats = {offField = 0}}
        end
        offField = offField + (c.stats.offField or 0)
        local rows, passes = shareOf(c)
        for key in pairs(rows) do
            if seenRows[key] then return false, "row worked twice: " .. key end
            if not wholeRows[key] then return false, "row not in the whole course: " .. key end
            seenRows[key] = k
            nRows = nRows + 1
        end
        for p in pairs(passes) do
            if seenPasses[p] then return false, "headland pass " .. p .. " worked twice" end
            seenPasses[p] = k
        end
    end
    for p in pairs(wholePasses) do
        if not seenPasses[p] then return false, "headland pass " .. p .. " left out" end
    end
    if nRows ~= nWholeRows then return false, string.format("%d of %d rows", nRows, nWholeRows) end
    local nPasses = 0
    for _ in pairs(wholePasses) do nPasses = nPasses + 1 end
    return offField <= (whole.stats.offField or 0) * size, string.format("%d rows, %d passes, off field %d (alone %d)",
        nRows, nPasses, offField, whole.stats.offField or 0)
end

--- giving way: our helper heading east at the origin, another helper at (x, z)
function checkGiveWay()
    local results = {}
    local function helper(x, z, blockedBy)
        local v = {rootNode = {x = x, z = z, h = 0}}
        v.spec_guidance = {driver = {course = {plan = {workWidth = 6}}, info = {backOffset = -5}, blockedBy = blockedBy}}
        return v
    end
    local me = {rootNode = {x = 0, z = 0, h = 0}, guidanceSetInfoText = function() end}
    local driver = setmetatable({vehicle = me, course = {plan = {workWidth = 6}}, info = {backOffset = -5}},
        {__index = GuidanceFieldworkDriver})
    me.spec_guidance = {driver = driver}
    local function speedWith(other)
        g_currentMission.vehicleSystem = {vehicles = {me, other}}
        return driver:giveWay(100, 12, 0, 0, 0, false)
    end
    results.farAhead = speedWith(helper(60, 0)) == 12
    results.slowing = (function() local v = speedWith(helper(22, 0)); return v > 0 and v < 12 end)()
    results.stops = speedWith(helper(12, 0)) == 0 and driver.blockedBy ~= nil
    results.besides = speedWith(helper(10, 12)) == 12
    results.behind = speedWith(helper(-10, 0)) == 12
    -- it waits for us already: we go
    local waiting = helper(12, 0, me)
    results.mutual = speedWith(waiting) == 12
    -- not Guidance: a vehicle somebody drives, another helper, one moving, one parked, AutoDrive's, a person
    local function vehicle(x, z, opts)
        local v = {rootNode = {x = x, z = z, h = 0}, size = {width = 3, length = 7}}
        function v:getRootVehicle() return self end
        function v:getIsControlled() return opts.controlled == true end
        function v:getIsAIActive() return opts.ai == true end
        function v:getLastSpeed() return opts.speed or 0 end
        if opts.autodrive then v.ad = {stateModule = {isActive = function() return true end}} end
        return v
    end
    results.driven = speedWith(vehicle(12, 0, {controlled = true})) == 0
    results.otherHelper = speedWith(vehicle(12, 0, {ai = true})) == 0
    results.moving = speedWith(vehicle(12, 0, {speed = 10})) == 0
    results.parked = speedWith(vehicle(12, 0, {})) == 12
    results.autodrive = speedWith(vehicle(12, 0, {ai = true, speed = 10, autodrive = true})) == 12
    -- AutoDrive's standing in our way (done unloading us, we turn): waited for, for AD_WAIT, then on
    local adStanding = vehicle(12, 0, {ai = true, speed = 0, autodrive = true})
    local t0 = g_time or 0
    local first = speedWith(adStanding)
    g_time = t0 + GuidanceFieldworkDriver.AD_WAIT - 1000
    local still = speedWith(adStanding)
    g_time = t0 + GuidanceFieldworkDriver.AD_WAIT + 1000
    speedWith(adStanding)
    -- (the frame after: on)
    local after = speedWith(adStanding)
    results.autodriveStanding = first == 0 and still == 0 and after == 12
    driver.adIgnored, driver.adBlock = nil, nil
    g_time = t0
    g_currentMission.playerSystem = {players = {{getCurrentVehicle = function() return nil end,
                                                 getPosition = function() return 10, 0, 0.5 end}}}
    results.onFoot = speedWith(vehicle(200, 0, {})) == 0
    g_currentMission.playerSystem = nil
    return results
end
"""


def main():
    i3d = sys.argv[1]
    numbers = sys.argv[2:] or ["9", "12", "20", "27", "34"]
    fields = fp.read_fields(i3d)
    ok = True
    lua = None
    for number in numbers:
        field = f"field{number}"
        if field not in fields:
            continue
        lua = smoke_test.fresh_lua(fields, field)
        lua.execute(CHECKS)
        flat = []
        for x, z in fields[field]:
            flat += [x, z]
        for mode_name in ("TEAM_STRIPS", "TEAM_LANDS"):
            for size, width in ((2, 6), (3, 12), (3, 24)):
                good, info = lua.globals().checkTeam(lua.table_from(flat), size, width,
                                                     lua.globals().GuidancePlan[mode_name])
                label = "lands, " if mode_name == "TEAM_LANDS" else ""
                print(f"{field}, {label}{size} tractors, {width} m: {info}: {'OK' if good else 'FAILED'}")
                ok = ok and bool(good)
    results = lua.globals().checkGiveWay()
    for name in ("farAhead", "slowing", "stops", "besides", "behind", "mutual", "driven", "otherHelper", "moving",
                 "parked", "autodrive", "autodriveStanding", "onFoot"):
        good = bool(results[name])
        print(f"give way, {name}: {'OK' if good else 'FAILED'}")
        ok = ok and good
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

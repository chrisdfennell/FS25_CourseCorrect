"""Checks offline: working part of a field (headlands only, rows only, a range of rows), the player's speeds, lights
at night, the work log (an entry per job, over the network), export / import of a course (with its field found
again, or recorded when it isn't on this map).

Usage:
    python batch2_test.py <map.i3d> [field number]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402
import smoke_test  # noqa: E402

CHECKS = r"""
-- files in memory: path -> {key -> value}
FILES = {}
local handles = {}
function createXMLFile(name, path, root) local h = #handles + 1; handles[h] = {path = path, v = {}}; return h end
function loadXMLFile(name, path)
    if FILES[path] == nil then return 0 end
    local h = #handles + 1; handles[h] = {path = path, v = FILES[path]}; return h
end
function saveXMLFile(h) FILES[handles[h].path] = handles[h].v end
function fileExists(path) return FILES[path] ~= nil end
function delete(h) end
function createFolder() end
function getUserProfileAppPath() return "profile/" end
function getFiles(folder, callback, object)
    for path in pairs(FILES) do
        if path:sub(1, #folder) == folder then object[callback](object, path:sub(#folder + 1), false) end
    end
end
function hasXMLProperty(h, key)
    for k in pairs(handles[h].v) do if k:sub(1, #key) == key then return true end end
    return false
end
local function set(h, k, v) handles[h].v[k] = v end
local function get(h, k) return handles[h].v[k] end
setXMLInt, setXMLFloat, setXMLBool, setXMLString = set, set, set, set
getXMLInt, getXMLFloat, getXMLBool, getXMLString = get, get, get, get

local function outlineOf(flat)
    local pts = {}
    for i = 1, #flat - 1, 2 do pts[#pts + 1] = {x = flat[i], z = flat[i + 1]} end
    return pts
end

--- rows (middles) and headland passes of a course
local function countWork(course)
    local rows, passes = 0, {}
    for i = 2, #course.waypoints do
        local b = course.waypoints[i]
        if b.re and b.t == "R" then rows = rows + 1 end
        if b.t == "H" and b.work and b.pass then passes[b.pass] = true end
    end
    local n = 0
    for _ in pairs(passes) do n = n + 1 end
    return rows, n
end

function checkParts(flat)
    local r = {}
    local plan = GuidancePlan.new()
    plan.workWidth, plan.turnRadius, plan.autoWidth = 6, 6, false
    local pts = outlineOf(flat)
    local whole = GuidanceCourseGenerator.generate(pts, plan:getGeneratorSettings())
    local wholeRows, wholePasses = countWork(whole)
    plan.workPart = GuidancePlan.WORK_HEADLANDS
    local c1 = GuidanceCourseGenerator.generate(pts, plan:getGeneratorSettings())
    local rows1, passes1 = countWork(c1)
    r.headlandsOnly = rows1 == 0 and passes1 == wholePasses
    plan.workPart = GuidancePlan.WORK_ROWS
    local c2 = GuidanceCourseGenerator.generate(pts, plan:getGeneratorSettings())
    local rows2, passes2 = countWork(c2)
    r.rowsOnly = rows2 == wholeRows and passes2 == 0
    -- rows 5 to 10 (on a field with fewer rows: 2 to one before the last)
    local from, to = 5, 10
    if wholeRows < 12 then from, to = 2, wholeRows - 1 end
    plan.workPart, plan.rowFrom, plan.rowTo = GuidancePlan.WORK_WHOLE, from, to
    local c3 = GuidanceCourseGenerator.generate(pts, plan:getGeneratorSettings())
    local rows3, passes3 = countWork(c3)
    r.rowRange = rows3 == to - from + 1 and passes3 == wholePasses and c3.stats.allRows == wholeRows
    PARTS = string.format("whole %d rows %d passes; headlands only %d/%d; rows only %d/%d; rows %d-%d: %d rows of %s",
        wholeRows, wholePasses, rows1, passes1, rows2, passes2, from, to, rows3, tostring(c3.stats.allRows))
    return r
end

--- drive the test tractor a while: the player's speeds kept, lights on at night, then the work log entry
function checkDrive(vehicle)
    local r = {}
    local spec = vehicle.spec_guidance
    spec.settings.turnSpeed, spec.settings.workSpeedMax = 6, 8
    vehicle:guidanceGenerate()
    g_currentMission.environment = {isSunOn = false, currentDay = 12, currentHour = 21, currentMinute = 30}
    local lights, beacon = nil, nil
    vehicle.updateAutomaticLights = function(self, night, working) lights = {night, working} end
    vehicle.setBeaconLightsVisibility = function(self, on) beacon = on end
    vehicle.getLightsTypesMask = function() return 0 end
    vehicle.setLightsTypesMask = function() end
    vehicle.spec_lights = {beaconLightsActive = false}
    GuidanceLibrary.stats = {}
    local job = GuidanceJob.new(true)
    job:applyCurrentState(vehicle, g_currentMission, 1, true)
    job:setStartIx(1)
    job:setValues()
    job:start(1)
    job.tasks[1]:start()
    vehicle.job = job
    local driver = job.tasks[1].driver
    local node = vehicle.rootNode
    local maxTurn, maxWork = 0, 0
    for step = 1, 6000 do
        local tx, tz, fwd, maxSpeed = driver:getDriveData(100, node.x, 0, node.z)
        local speed = math.min(maxSpeed or 0, 30)
        if fwd then
            local _, work = driver.follower:getCurrentSegment()
            if driver.lowered then maxWork = math.max(maxWork, speed) elseif not work then maxTurn = math.max(maxTurn, speed) end
        end
        local v = speed / 3.6
        local hm = fwd and node.h or node.h + math.pi
        local dx, dz = tx - node.x, tz - node.z
        local alpha = (math.atan2(dz, dx) - hm + math.pi) % (2 * math.pi) - math.pi
        local dist = math.max(math.sqrt(dx * dx + dz * dz), 0.1)
        hm = hm + v * 0.1 * math.max(-1 / 5.4, math.min(1 / 5.4, 2 * math.sin(alpha) / dist))
        node.x, node.z = node.x + v * 0.1 * math.cos(hm), node.z + v * 0.1 * math.sin(hm)
        node.h = fwd and hm or hm - math.pi
        vehicle.speed = speed
        if vehicle.job == nil then break end
    end
    r.turnSpeed = maxTurn <= 6.01 and maxTurn > 3
    r.workSpeed = maxWork <= 8.01 and maxWork > 5
    r.lightsOn = lights ~= nil and lights[1] == true and beacon == true
    local area = driver.stats and driver.stats.area or 0
    job:stop(AIMessageSuccessStoppedByUser.new())
    vehicle.job = nil
    r.lightsBack = beacon == false
    local e = GuidanceLibrary.stats[1]
    r.logEntry = e ~= nil and math.abs(e.area - area) < 1 and e.area > 1000 and e.seconds > 500 and e.day.day == 12
    -- over the network and back
    local s = {}
    if e then GuidanceLibrary.writeStat(s, e) end
    local back = e and GuidanceLibrary.readStat(s)
    r.logStream = back ~= nil and math.abs(back.area - e.area) < 0.01 and back.vehicle == e.vehicle and back.day.hour == 21
    DRIVE = string.format("turns up to %.1f km/h, working up to %.1f km/h, logged %.2f ha in %.0f min",
        maxTurn, maxWork, (e and e.area or 0) / 10000, (e and e.seconds or 0) / 60)
    return r
end

--- export a saved course and import it: on this map back to its own field; moved away, its outline recorded
function checkExport(vehicle)
    local r = {}
    local plan = vehicle:getGuidancePlan()
    local entry = GuidanceLibrary.newEntry("Test export", 1, plan, vehicle:getGuidanceCourse())
    GuidanceLibrary.entries, GuidanceLibrary.fields = {}, {}
    local name = GuidanceLibrary.exportCourse(entry)
    local files = GuidanceLibrary.listExports()
    local title, plan2, outline = GuidanceLibrary.readExport(files[1] or "")
    r.exportFile = name ~= nil and #files == 1 and title == "Test export" and plan2 ~= nil and outline ~= nil
        and math.abs(plan2.workWidth - plan.workWidth) < 0.01
    GuidanceLibrary.importCourse(title, 1, plan2, outline)
    local imported = GuidanceLibrary.entries[#GuidanceLibrary.entries]
    r.importSameField = imported ~= nil and imported.plan.fieldId == plan.fieldId and #GuidanceLibrary.fields == 0
    -- the same course from another map: the field isn't here, its outline becomes a recorded one
    local moved = {}
    for i, p in ipairs(outline) do moved[i] = {x = p.x + 500, z = p.z + 300} end
    GuidanceLibrary.importCourse("From elsewhere", 1, plan2:copy(), moved)
    local imported2 = GuidanceLibrary.entries[#GuidanceLibrary.entries]
    r.importNewField = imported2 ~= nil and imported2.plan.fieldId < 0 and #GuidanceLibrary.fields == 1
        and #GuidanceLibrary.fields[1].outline == #moved
    return r
end
"""


def main():
    i3d = sys.argv[1]
    field = f"field{sys.argv[2] if len(sys.argv) > 2 else 9}"
    fields = fp.read_fields(i3d)
    flat = []
    for x, z in fields[field]:
        flat += [x, z]
    lua = smoke_test.fresh_lua(fields, field)
    drive = smoke_test.DRIVE
    a = drive.index("    makeField(7, flat)")
    last = "    vt.listeners.onLoad(v, nil)\n"
    b = drive.index(last) + len(last)
    lua.execute("function makeTestVehicle(flat)\n    local mode = nil\n" + drive[a:b] + "    return v\nend\n")
    lua.execute(CHECKS)
    G = lua.globals()
    ok = True
    results = {}
    for name, value in G.checkParts(lua.table_from(flat)).items():
        results[name] = value
    print("parts:", G.PARTS)
    vehicle = G.makeTestVehicle(lua.table_from(flat))
    vehicle.raiseActive = lambda *a: None
    for name, value in G.checkDrive(vehicle).items():
        results[name] = value
    print("drive:", G.DRIVE)
    for name, value in G.checkExport(vehicle).items():
        results[name] = value
    for name in ("headlandsOnly", "rowsOnly", "rowRange", "turnSpeed", "workSpeed", "lightsOn", "lightsBack", "logEntry",
                 "logStream", "exportFile", "importSameField", "importNewField"):
        good = bool(results.get(name))
        ok = ok and good
        print(f"{name}: {'OK' if good else 'FAILED'}")
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

"""Checks the settings per field / tractor / player offline: field settings through the network stream and the
savegame file, a course made on a field taking the field's settings (but a mower's forced direction), changes
remembered for the field, the player's defaults given to a tractor, and the minimum headland width.

Usage:
    python scopes_test.py <map.i3d> [field number]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402
import smoke_test  # noqa: E402

CHECKS = r"""
-- a savegame file in memory: path -> {key -> value}
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
function hasXMLProperty(h, key)
    for k in pairs(handles[h].v) do if k:sub(1, #key) == key then return true end end
    return false
end
local function set(h, k, v) handles[h].v[k] = v end
local function get(h, k) return handles[h].v[k] end
setXMLInt, setXMLFloat, setXMLBool, setXMLString = set, set, set, set
getXMLInt, getXMLFloat, getXMLBool, getXMLString = get, get, get, get

function checkScopes(vehicle)
    local results = {}
    local L = GuidanceLibrary
    -- 1. the network: written and read back the same
    local values = {headlands = 4, rowAngle = 35, clockwise = false, headlandsFirst = true, pattern = 2, roundedPasses = 2}
    local s = {}
    L.writeFieldSettings(s, {fieldId = 9, values = values})
    local back = L.readFieldSettings(s)
    local same = back.fieldId == 9
    for k, v in pairs(values) do same = same and back.values[k] == v end
    local s2 = {}
    L.writeFieldSettings(s2, {fieldId = -3, values = nil})
    local back2 = L.readFieldSettings(s2)
    results.stream = same and back2.fieldId == -3 and back2.values == nil

    -- 2. the savegame: saved and loaded the same
    g_currentMission.missionInfo = g_currentMission.missionInfo or {}
    g_currentMission.missionInfo.savegameDirectory = "save1"
    L.fieldSettings = {[9] = values, [-2] = {headlands = -1, rowAngle = -1, clockwise = true, headlandsFirst = false,
                                             pattern = 3, roundedPasses = 0}}
    L.save()
    L.fieldSettings = {}
    L.load()
    same = L.fieldSettings[9] ~= nil and L.fieldSettings[-2] ~= nil
    for k, v in pairs(values) do same = same and L.fieldSettings[9][k] == v end
    same = same and L.fieldSettings[-2].headlands == -1 and L.fieldSettings[-2].headlandsFirst == false
    results.savegame = same

    -- 3. a course made on the field takes the field's settings
    L.fieldSettings = {}
    local spec = vehicle.spec_guidance
    spec.settings.headlands, spec.settings.rowAngle = -1, -1
    local fieldId = GuidanceCourse.getFieldIdAt(getWorldTranslation(vehicle.rootNode))
    L.fieldSettings[fieldId] = {headlands = 3, rowAngle = 40, clockwise = false, headlandsFirst = true, pattern = 1,
                                roundedPasses = 1}
    vehicle:guidanceGenerate()
    local course = vehicle:getGuidanceCourse()
    results.fieldApplied = course ~= nil and course.stats.headlands == 3 and math.abs(course.stats.rowAngle - 40) < 0.5
        and vehicle:getGuidancePlan().clockwise == false
    RESULT_HEADLANDS, RESULT_ANGLE = course and course.stats.headlands, course and course.stats.rowAngle

    -- 4. changes on the course page are remembered for the field (when the player wants that)
    GuidancePrefs.rememberFields = true
    vehicle:guidanceChangeSetting("headlands", 4)
    local remembered = L.fieldSettings[fieldId] and L.fieldSettings[fieldId].headlands == 4
        and L.fieldSettings[fieldId].rowAngle == 40
    GuidancePrefs.rememberFields = false
    vehicle:guidanceChangeSetting("headlands", 5)
    results.remember = remembered and L.fieldSettings[fieldId].headlands == 4
        and vehicle:getGuidanceCourse().stats.headlands == 5

    -- 5. the player's defaults on a tractor, one new course
    GuidancePrefs.roundedPasses, GuidancePrefs.keepLowered, GuidancePrefs.pattern = 0, true, 2
    local before = vehicle:getGuidanceCourse()
    local v = {}
    for _, name in ipairs(GuidancePrefs.PLAN_DEFAULTS) do v[name] = GuidancePrefs[name] end
    vehicle:guidanceApplySettings(v)
    results.defaults = spec.settings.keepLowered == true and spec.plan.roundedPasses == 0 and spec.plan.pattern == 2
        and vehicle:getGuidanceCourse() ~= before

    -- 6. the minimum headland: automatic headlands at least that wide
    L.fieldSettings = {}
    spec.settings.headlands = -1
    spec.settings.minHeadlandWidth = 30
    vehicle:guidanceGenerate()
    local w30 = vehicle:getGuidanceCourse().stats.headlands * spec.plan.workWidth
    spec.settings.minHeadlandWidth = 60
    vehicle:guidanceGenerate()
    local w60 = vehicle:getGuidanceCourse().stats.headlands * spec.plan.workWidth
    results.minHeadland = w30 >= 30 and w60 >= 60 and w60 > w30
    MIN_WIDTHS = {w30, w60}

    -- 7. a savegame saved while the helper worked: the game's helper flag is set, no helper. The panel can be
    -- used, and the server clears the flag after a moment
    local worker = vehicle.spec_aiFieldWorker
    vehicle.raiseActive = vehicle.raiseActive or function() end
    local getIsAIActive = vehicle.getIsAIActive
    vehicle.getIsAIActive = function(self) return self.job ~= nil or worker.isActive == true end
    worker.isActive = true
    local usable = not vehicle:getIsHelperDriving() and not vehicle:getIsGuidanceActive()
    for _ = 1, 40 do GuidanceVehicle.onUpdateTick(vehicle, 100) end
    results.staleHelper = usable and worker.isActive == false
    vehicle.getIsAIActive = getIsAIActive

    -- 8. a job the game starts itself (hire key, helper menu, its last job): "start at" decides, not waypoint 1
    spec.progressIx = math.floor(#vehicle:getGuidanceCourse().waypoints / 2)
    spec.settings.startMode = GuidancePlan.START_CONTINUE
    local job = GuidanceJob.new(true)
    job:applyCurrentState(vehicle, g_currentMission, 1, true)
    job:setValues()
    job:start(1)
    job.tasks[1]:start()
    local expected = vehicle:getGuidanceCourse():getResumeIx(spec.progressIx)
    local started = job.tasks[1].driver and job.tasks[1].driver.startIx
    STARTED_AT, EXPECTED_AT = started, expected
    results.gameStart = started == expected and expected > 1
    job:stop(AIMessageSuccessStoppedByUser.new())
    vehicle.job = nil

    -- 9. the game's own helper drives (its hire key): not ours, but it can be stopped from the panel
    vehicle.job = {name = "FIELDWORK", stop = function(self) OTHER_STOPPED = true end}
    local seen = vehicle:getIsHelperDriving() and not vehicle:getIsGuidanceActive()
    vehicle:guidanceStopHelper()
    results.otherHelper = seen and OTHER_STOPPED == true and vehicle.job == nil

    -- 10. tool offset: 0.5 m right, the helper steers 0.5 m left (side offsets count to the left)
    spec.plan.toolOffsetX = 0.5
    local job2 = GuidanceJob.new(true)
    job2:applyCurrentState(vehicle, g_currentMission, 1, true)
    job2:setValues()
    job2:start(1)
    job2.tasks[1]:start()
    local d2 = job2.tasks[1].driver
    results.toolOffset = d2 ~= nil and math.abs(d2.sideOffset + 0.5) < 1e-6
    job2:stop(AIMessageSuccessStoppedByUser.new())
    vehicle.job = nil
    spec.plan.toolOffsetX = 0

    -- 11. a harvester: AutoDrive's "call the unloader" level set from ours, to its nearest step
    local set = {}
    AutoDrive = {settings = {preCallLevel = {values = {0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 1}}},
                 setSettingState = function(name, value, v) set[#set + 1] = {name, value, v} end}
    local combine = {ad = {settings = {preCallLevel = {}}}}
    GuidanceFieldworkDriver.setCallUnloaderLevel(combine, combine, 87)
    results.callUnloader = #set == 1 and set[1][1] == "preCallLevel" and set[1][2] == 10 and set[1][3] == combine
    AutoDrive = nil

    -- 12. saved while working: starts again by itself after loading, where it was (not before the delay)
    spec.resumeAfterLoad = 0
    STARTED_JOB = nil
    GuidanceVehicle.updateResume(vehicle, spec, 1000)
    local early = STARTED_JOB == nil
    GuidanceVehicle.updateResume(vehicle, spec, GuidanceVehicle.RESUME_DELAY)
    results.autoResume = early and STARTED_JOB ~= nil and spec.resumeAfterLoad == nil
    STARTED_JOB = nil
    -- 13. the mod's old name (Guidance): its server file, a tractor's settings and the player's defaults are read
    -- once; with the old mod loaded too, CourseCorrect stays off
    g_currentMission.missionInfo.savegameDirectory = "save2"
    L.fieldSettings = {[9] = {headlands = 4, rowAngle = 35, clockwise = false, headlandsFirst = true, pattern = 2,
                              roundedPasses = 2}}
    L.save()
    FILES["save2/" .. L.OLD_FILE], FILES["save2/" .. L.FILE] = FILES["save2/" .. L.FILE], nil
    L.fieldSettings = {}
    L.load()
    local serverFile = L.fieldSettings[9] ~= nil and L.fieldSettings[9].rowAngle == 35
    local old = "vehicles.vehicle(0).FS25_Guidance.guidance.settings"
    local values = {[old .. "#fieldId"] = 0, [old .. "#workWidth"] = 9.5, [old .. "#minHeadlandWidth"] = 55,
                    [old .. "#headlandRev"] = 2}
    local xmlFile = {
        getValue = function(_, k, default) local v = values[k]; if v == nil then return default end; return v end,
        hasProperty = function(_, k)
            for key in pairs(values) do if key:sub(1, #k) == k then return true end end
            return false
        end,
    }
    local before = vehicle.spec_guidance.settings
    GuidanceVehicle.onPostLoad(vehicle, {key = "vehicles.vehicle(0)", xmlFile = xmlFile})
    local tractor = vehicle.spec_guidance.settings.workWidth == 9.5 and vehicle.spec_guidance.settings.minHeadlandWidth == 55
    vehicle.spec_guidance.settings = before
    getUserProfileAppPath = getUserProfileAppPath or function() return "profile/" end
    FILES[getUserProfileAppPath() .. "modSettings/FS25_Guidance.xml"] = {["guidance.prefs#minHeadlandWidth"] = 45,
                                                                         ["guidance.prefs#headlandRev"] = 2}
    GuidancePrefs.load()
    local defaults = GuidancePrefs.minHeadlandWidth == 45
    local alone = not Guidance.oldModLoaded()
    g_modIsLoaded.FS25_Guidance = true
    local both = Guidance.oldModLoaded()
    g_modIsLoaded.FS25_Guidance = nil
    OLD_NAME = string.format("server file %s, tractor %s, defaults %s, alone on %s, beside the old one off %s",
        tostring(serverFile), tostring(tractor), tostring(defaults), tostring(alone), tostring(both))
    results.oldName = serverFile and tractor and defaults and alone and both
    return results
end
"""


def main():
    i3d = sys.argv[1]
    field = f"field{sys.argv[2] if len(sys.argv) > 2 else 9}"
    fields = fp.read_fields(i3d)
    lua = smoke_test.fresh_lua(fields, field)
    # the smoke test's tractor, without driving
    drive = smoke_test.DRIVE
    a = drive.index("    makeField(7, flat)")
    last = "    vt.listeners.onLoad(v, nil)\n"
    b = drive.index(last) + len(last)
    lua.execute("function makeTestVehicle(flat)\n    local mode = nil\n" + drive[a:b] + "    return v\nend\n")
    lua.execute(CHECKS)
    flat = []
    for x, z in fields[field]:
        flat += [x, z]
    vehicle = lua.globals().makeTestVehicle(lua.table_from(flat))
    results = lua.globals().checkScopes(vehicle)
    g = lua.globals()
    ok = True
    for name in ("stream", "savegame", "fieldApplied", "remember", "defaults", "minHeadland", "staleHelper", "gameStart", "otherHelper", "toolOffset", "callUnloader", "autoResume", "oldName"):
        good = bool(results[name])
        ok = ok and good
        extra = ""
        if name == "oldName":
            extra = f" ({g.OLD_NAME})"
        if name == "fieldApplied":
            extra = f" (headlands {g.RESULT_HEADLANDS}, row angle {g.RESULT_ANGLE})"
        if name == "minHeadland" and g.MIN_WIDTHS:
            extra = f" ({g.MIN_WIDTHS[1]:.0f} m, {g.MIN_WIDTHS[2]:.0f} m)"
        if name == "gameStart":
            extra = f" (started at waypoint {g.STARTED_AT}, expected {g.EXPECTED_AT})"
        print(f"{name}: {'OK' if good else 'FAILED'}{extra}")
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

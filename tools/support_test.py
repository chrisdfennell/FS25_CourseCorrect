"""Checks offline the editor's moved points, the problem report and the debug overlay:

- a moved point is where the editor put it, its neighbours along the course follow (less further away), points
  further than the reach stay; the moves go over the network and into the savegame with the plan; any other change of
  the course drops them, a new course starts without them;
- the problem report has the version, the vehicle, its settings, the field's outline and the mod's last log lines, and is written through
  the game's file functions;
- the overlay draws a working helper's way, its target and its text;
- a setting only for starting (start at) goes to the server without making the course again (nor losing where it
  got to), and a later change of the course keeps it;
- the grass chain: a baler finds the rake's course on its field and follows it: its rows on the rake's passes, the
  same headland passes, with its own turning radius.

Usage:
    python support_test.py <map.i3d> [field number]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402
import helpers_test  # noqa: E402
import smoke_test  # noqa: E402

LUA = r"""
function checkSupport(flat)
    local r = {}
    makeField(7, flat)
    local v = makeVehicle(flat[1] + 30, flat[2] + 30, 0, "Test tractor")
    g_currentMission.vehicleSystem = {vehicles = {v}}
    local ok, err = v:guidanceGenerate()
    assert(ok, "generate: " .. tostring(err))
    local course = v:getGuidanceCourse()
    local wps = course.waypoints
    -- a point in the middle of a long stretch
    local ix = math.floor(#wps / 2)
    local before = {}
    for i, w in ipairs(wps) do before[i] = {x = w.x, z = w.z, d = w.d} end
    local plan = v:getGuidancePlan()
    local tx, tz = wps[ix].x + 4, wps[ix].z - 3
    v:guidanceApplySettings({moves = plan:withMove(ix, tx, tz)})
    local moved = v:getGuidanceCourse().waypoints
    local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
    r.movedThere = math.abs(moved[ix].x - tx) < 0.01 and math.abs(moved[ix].z - tz) < 0.01
    -- neighbours: within reach moved less, beyond unmoved
    local nearOk, farOk = true, true
    for i = 1, #moved do
        local along = math.abs(before[i].d - before[ix].d)
        local shift = dist(moved[i], before[i])
        if along >= GuidanceCourse.MOVE_REACH and shift > 1e-6 then farOk = false end
        if along > 0.5 and along < GuidanceCourse.MOVE_REACH and shift > dist(moved[ix], before[ix]) + 1e-6 then nearOk = false end
    end
    r.neighbours = nearOk and farOk
    -- over the network and into the savegame
    local stream = {}
    v:getGuidancePlan():writeStream(stream)
    local copy = GuidancePlan.readStream(stream)
    r.streamed = copy.moves == v:getGuidancePlan().moves and copy.moves ~= ""
    -- another change drops them
    v:guidanceApplySettings({headlands = 3})
    r.dropped = (v:getGuidancePlan().moves or "") == ""
    -- a new course starts without them
    v:guidanceApplySettings({moves = v:getGuidancePlan():withMove(ix, tx, tz)})
    v:guidanceGenerate()
    r.newCourse = (v:getGuidancePlan().moves or "") == ""

    -- saving into the savegame: a value not set (prefsApplied before the defaults were applied) is left out (the
    -- game's setValue errors on nil, and the rest of the vehicle would not be saved), and loads as the default
    do
        local store = {}
        local xml = {}
        function xml:setValue(k, val)
            if val == nil then error("setXMLBool: Argument 2 has wrong type. Expected: Bool. Actual: Nil") end
            store[k] = val
        end
        function xml:getValue(k) return store[k] end
        local plan = GuidancePlan.new()
        plan.fieldId, plan.prefsApplied, plan.vineTool = 5, nil, nil
        local ok = pcall(plan.saveToXMLFile, plan, xml, "p")
        local back = ok and GuidancePlan.loadFromXMLFile(xml, "p")
        r.saveNil = ok and back ~= nil and back.fieldId == 5 and back.vineTool == false and back.prefsApplied == nil
            and store["p#rainWait"] == true
    end
    -- saved while working as an unloader (it has a course too): saved as the unloader, not as the course's helper;
    -- after loading it starts again as the unloader, with its settings (before 1.0.5.2: it drove its old course)
    do
        local store = {}
        local xml = {}
        function xml:setValue(k, val) store[k] = val end
        local oldKind, oldActive, oldStartHelper, oldStart, oldDriving = v.getGuidanceHelperKind, v.getIsGuidanceActive,
            v.guidanceStartHelper, v.guidanceStart, v.getIsHelperDriving
        v.getGuidanceHelperKind = function() return "bales" end
        v.getIsGuidanceActive = function() return true end
        GuidanceVehicle.saveToXMLFile(v, xml, "k")
        local savedAs = store["k#active"] == false and store["k#helper"] == "bales"
        local startedHelper, startedCourse
        v.guidanceStartHelper = function(_, kind, values) startedHelper = {kind = kind, values = values}; return true end
        v.guidanceStart = function() startedCourse = true end
        v.getIsHelperDriving = function() return false end
        local spec = v.spec_guidance
        spec.resumeHelper, spec.resumeAfterLoad = "bales", GuidanceVehicle.RESUME_DELAY
        GuidanceVehicle.updateResume(v, spec, 1)
        v.getGuidanceHelperKind, v.getIsGuidanceActive, v.guidanceStartHelper, v.guidanceStart, v.getIsHelperDriving =
            oldKind, oldActive, oldStartHelper, oldStart, oldDriving
        r.resumeHelper = savedAs and startedHelper ~= nil and startedHelper.kind == "bales" and not startedCourse
        RESUME_INFO = string.format("saved as the bale collector %s; after loading: bale collector started %s, its course %s",
            tostring(savedAs), tostring(startedHelper ~= nil), tostring(startedCourse == true))
    end
    -- the course lines in the world: drawn the player's line height above the ground (up over tall crops)
    do
        local realT = getTerrainHeightAtWorldPos
        getTerrainHeightAtWorldPos = function() return 10 end
        g_currentMission.terrainRootNode = g_currentMission.terrainRootNode or 1
        local was = GuidancePrefs.lineHeight
        local ground = GuidanceDraw.lineY(0, 0)
        GuidancePrefs.lineHeight = GuidancePrefs.LINE_HEIGHTS[3]
        local up = GuidanceDraw.lineY(0, 0)
        GuidancePrefs.lineHeight = was
        getTerrainHeightAtWorldPos = realT
        r.lineHeight = math.abs(ground - 10.25) < 1e-6 and math.abs(up - 12.5) < 1e-6
    end
    -- the report's AutoDrive part for a harvester: its target, call level, tank, pipe, working or idle, and every
    -- unloader with its target (a different one: AutoDrive won't send it)
    do
        local h = {spec_combine = {fillUnitIndex = 1}, spec_pipe = {}, rootNode = {x = 0, z = 0, h = 0}}
        function h:getChildVehicles() return {self} end
        function h:getName() return "Tiger" end
        local field = {name = "Field 42b WAIT"}
        h.ad = {stateModule = {getFirstMarker = function() return field end}}
        local truck = {ad = {stateModule = {getFirstMarker = function() return field end}}, getName = function() return "Truck A" end}
        local other = {ad = {stateModule = {getFirstMarker = function() return {name = "Field 7"} end}}, getName = function() return "Truck B" end}
        AutoDrive = {getObjectFillLevels = function() return 30000, 58000 end,
                     getSetting = function(n) if n == "preCallLevel" then return 0.5 end return true end,
                     isPipeOut = function() return true end}
        ADHarvestManager = {harvesters = {h}, idleHarvesters = {}, idleUnloaders = {truck, other}, activeUnloaders = {},
                            isHarvesterActive = function() return true end,
                            getAssignedUnloader = function() return nil end}
        local lines = table.concat(GuidanceDebug.autoDriveLines(h), "|")
        AutoDrive, ADHarvestManager = nil, nil
        r.reportAutoDrive = lines:find("first target Field 42b WAIT, calls at 50%, tank 52%, pipe out true", 1, true) ~= nil
            and lines:find("working (it looks for unloaders)", 1, true) ~= nil
            and lines:find("unloader Truck A: idle, waiting for a call, first target Field 42b WAIT|", 1, true) ~= nil
            and lines:find("unloader Truck B: idle, waiting for a call, first target Field 7 (not the harvester's", 1, true) ~= nil
        AD_LINES = lines
    end
    -- the problem report
    Guidance.info("a test line for the report")
    local text = GuidanceDebug.reportText(v)
    r.report = text:find(Guidance.VERSION, 1, true) ~= nil and text:find("Test tractor", 1, true) ~= nil
        and text:find("workWidth =", 1, true) ~= nil and text:find("a test line for the report", 1, true) ~= nil
    -- (and the field's outline, to make the same course again)
    local rc = v:getGuidanceCourse()
    r.report = r.report and rc ~= nil and #rc.outline >= 3
        and text:find(string.format("field outline: %d point(s), x z", #rc.outline), 1, true) ~= nil
        and text:find(string.format("%.2f %.2f", rc.outline[1].x, rc.outline[1].z), 1, true) ~= nil
    WRITTEN = nil
    getUserProfileAppPath = function() return "profile/" end
    createFolder = function() end
    FileAccess = {WRITE = 2}
    createFile = function(path, mode) return {path = path} end
    fileWrite = function(f, s) WRITTEN = {path = f.path, text = s} end
    delete = delete or function() end
    local path = GuidanceDebug.writeReport(v)
    r.written = path ~= nil and WRITTEN ~= nil and WRITTEN.path:find("modSettings/FS25_CourseCorrect/report.txt", 1, true) ~= nil
        and #WRITTEN.text > 200
    REPORT = text

    -- the game's own field work helper hired for it (the hire key, AutoDrive set to the game's helper): CourseCorrect
    -- works the course instead; not with Game's helper here: The game's helper, nor away from the course's field
    do
        local m = g_currentMission.aiJobTypeManager
        local oldIx, oldByIx = m.getJobTypeIndex, m.getJobTypeByIndex
        m.getJobTypeIndex = function(_, job) return job.gameFieldWork and 99 or 1 end
        m.getJobTypeByIndex = function(_, ix) return {name = ix == 99 and "FIELDWORK" or "OTHER"} end
        local function hire()
            STARTED_JOB = nil
            local job = {gameFieldWork = true, vehicleParameter = {getVehicle = function() return v end}}
            AISystem.startJob(g_currentMission.aiSystem, job, 1)
            return STARTED_JOB ~= nil and STARTED_JOB.name == GuidanceJob.name
        end
        local took = hire()
        v.spec_guidance.settings.takeOver = false
        local off = hire()
        v.spec_guidance.settings.takeOver = true
        local x0 = v.rootNode.x
        v.rootNode.x = x0 + 5000
        local away = hire()
        v.rootNode.x = x0
        -- another mod's job, or ours: left alone
        STARTED_JOB = nil
        AISystem.startJob(g_currentMission.aiSystem, {vehicleParameter = {getVehicle = function() return v end}}, 1)
        local other = STARTED_JOB == nil
        m.getJobTypeIndex, m.getJobTypeByIndex = oldIx, oldByIx
        STARTED_JOB = nil
        r.takeOver = took and not off and not away and other
        TAKE_INFO = string.format("took over %s, setting off %s, away %s, other job left alone %s", tostring(took),
            tostring(off), tostring(away), tostring(other))
    end

    -- a helper waiting for the others: the engine off after 10 s standing (and the game may not start it again), on
    -- again when it has to move; not while it only stands a moment under a combine's pipe
    do
        local spec = v.spec_guidance
        local motor = {on = true, starts = 0, stops = 0}
        MotorState = MotorState or {OFF = 0, ON = 3}
        local oldStart, oldStop, oldState, oldPhase = v.startMotor, v.stopMotor, v.getMotorState, v.getGuidanceHelperPhase
        local phase = "siloWait"
        v.startMotor = function() motor.on = true; motor.starts = motor.starts + 1 end
        v.stopMotor = function() motor.on = false; motor.stops = motor.stops + 1 end
        v.getMotorState = function() return motor.on and MotorState.ON or MotorState.OFF end
        v.getGuidanceHelperPhase = function() return phase end
        spec.helperDriver = {}
        spec.engineOff, spec.idleTime = false, 0
        for _ = 1, 9 do GuidanceVehicle.saveFuel(v, spec, 1000, 0) end
        local onAt9 = motor.on
        for _ = 1, 2 do GuidanceVehicle.saveFuel(v, spec, 1000, 0) end
        local offAt11 = not motor.on
        local blocked = GuidanceVehicle.getCanMotorRun(v, function() return true end) == false
        GuidanceVehicle.saveFuel(v, spec, 100, 8)
        local onToMove = motor.on and not spec.engineOff
        phase = "siloDrive"
        for _ = 1, 30 do GuidanceVehicle.saveFuel(v, spec, 1000, 0) end
        local followOn = motor.on
        spec.helperDriver, spec.engineOff, spec.idleTime = nil, false, 0
        v.startMotor, v.stopMotor, v.getMotorState, v.getGuidanceHelperPhase = oldStart, oldStop, oldState, oldPhase
        r.fuelSave = onAt9 and offAt11 and blocked and onToMove and followOn and motor.stops == 1
        FUEL_INFO = string.format("waiting: on after 9 s %s, off after 11 s %s, game can't start it %s, on to move %s; "
            .. "driving, standing 30 s: still on %s", tostring(onAt9), tostring(offAt11), tostring(blocked),
            tostring(onToMove), tostring(followOn))
    end

    -- an AutoDrive truck standing ahead, its trailer reaching back into our line: we stop short of the trailer; after
    -- AD_WAIT we no longer wait for it further off, but still never drive into it (before 1.0.5.1: drove on into it)
    do
        local me = {rootNode = {x = 0, z = 0, h = 0}}
        function me:guidanceSetInfoText() end
        local truck = {rootNode = {x = 40, z = 0, h = 0}, size = {width = 2.5, length = 8},
                       ad = {stateModule = {isActive = function() return true end}}}
        local trailer = {rootNode = {x = 14, z = 0, h = 0}, size = {width = 2.6, length = 12}}
        function truck:getLastSpeed() return 0 end
        function truck:getRootVehicle() return self end
        function truck:getChildVehicles() return {self, trailer} end
        function trailer:getRootVehicle() return truck end
        local oldVs = g_currentMission.vehicleSystem
        g_currentMission.vehicleSystem = {vehicles = {me, truck, trailer}}
        local d = setmetatable({vehicle = me, course = {plan = {workWidth = 5.5}}, info = {frontOffset = 5.6}},
            {__index = GuidanceFieldworkDriver})
        local waited = d:giveWay(100, 10, 0, 0, 0, false)
        d.adIgnored = {[truck] = true}
        local afterWait = d:giveWay(100, 10, 0, 0, 0, false)
        trailer.rootNode.x = 26
        local clear = d:giveWay(100, 10, 0, 0, 0, false)
        g_currentMission.vehicleSystem = oldVs
        r.adTrailer = waited == 0 and afterWait == 0 and clear == 10
        AD_TRAILER_INFO = string.format("trailer 14 m ahead: speed %s waiting, %s after the 20 s; trailer clear (26 m, ignored truck): %s",
            tostring(waited), tostring(afterWait), tostring(clear))
    end

    -- our unloader (a truck its measuring calls 10 m wide) waiting beside our line: not in our way (before 1.0.5.2 the
    -- harvester stood for it); the same truck on our line: in our way. And the report says why a helper stands.
    do
        local me = {rootNode = {x = 0, z = 0, h = 0}}
        function me:guidanceSetInfoText() end
        local truck = {rootNode = {x = 12, z = 6.5, h = 0}, size = {width = 2.5, length = 9}}
        local ud = {course = {plan = {workWidth = 10}}, state = "wait", info = {backOffset = -3}}
        truck.spec_guidance = {driver = ud, helperDriver = ud}
        function truck:getRootVehicle() return self end
        function truck:getChildVehicles() return {self} end
        local oldVs = g_currentMission.vehicleSystem
        g_currentMission.vehicleSystem = {vehicles = {me, truck}}
        local d = setmetatable({vehicle = me, course = {plan = {workWidth = 5.5}}, info = {frontOffset = 5.6}},
            {__index = GuidanceFieldworkDriver})
        local beside = d:giveWay(100, 10, 0, 0, 0, false)
        truck.rootNode.z = 0
        local onLine = d:giveWay(100, 10, 0, 0, 0, false)
        g_currentMission.vehicleSystem = oldVs
        -- the report: standing, and why
        local veh = {spec_guidance = {driver = {state = GuidanceFieldworkDriver.STATE_DRIVING, debugTarget = {0, 0, 0},
                                                stopReason = "waiting for the rain to stop"}}}
        function veh:getName() return "Tiger" end
        function veh:getGuidanceHelperKind() return nil end
        function veh:getIsGuidanceActive() return false end
        function veh:getGuidanceInfoTexts() return {} end
        local said = false
        for _, line in ipairs(GuidanceDebug.describe(veh)) do
            if line == "stopped: waiting for the rain to stop" then said = true end
        end
        r.helperSize = beside == 10 and onLine == 0 and said
        HELPER_SIZE_INFO = string.format("unloader 6.5 m beside our line: speed %s (want 10); on it: %s (want 0); report says why it stands %s",
            tostring(beside), tostring(onLine), tostring(said))
    end

    -- a truck pulling a 12 m semi-trailer plans its ways round 9 m, not the cab's 4.4 m (it jackknifed and got stuck);
    -- a tractor alone keeps its own radius
    do
        local trailer = {size = {length = 12}, spec_trailer = {}}
        local truck = {}
        function truck:getChildVehicles() return {self, trailer} end
        local alone = {}
        function alone:getChildVehicles() return {self} end
        local rTruck = GuidanceHelperDriver.turnRadiusOf(truck, {turnRadius = 4.4})
        local rAlone = GuidanceHelperDriver.turnRadiusOf(alone, {turnRadius = 4.4})
        r.trailerRadius = math.abs(rTruck - 9) < 1e-6 and math.abs(rAlone - 4.4) < 1e-6
        TRAILER_RADIUS_INFO = string.format("truck with a 12 m semi-trailer plans with %.1f m (cab 4.4); alone %.1f m", rTruck, rAlone)
    end

    -- turning back (after unloading) with standing crop on one side: it turns the other way, not into the crop
    do
        local node = {x = 0, z = 0, h = 0}
        local truck = {rootNode = node}
        function truck:getAIDirectionNode() return node end
        local probe = {fruitIndexes = {1}}
        function probe:hasFruit(x, z, size) return z - (size or 2) / 2 < -4 end -- crop from z = -4 on
        local d = setmetatable({vehicle = truck, info = {turnRadius = 8}, turnRadius = 8, course = {plan = {workWidth = 3}},
                                probe = probe}, {__index = GuidanceHelperDriver})
        d:planTo(-40, 0, math.pi, 6)
        local minZ = math.huge
        for _, pt in ipairs(d.follower.points) do minZ = math.min(minZ, pt.z) end
        r.turnAway = minZ > -1
        TURN_INFO = string.format("U-turn with crop from z = -4 on: the way goes down to z = %.1f (want > -1: turned the other way)", minZ)
    end

    -- a plan asks the game about the crop once per spot (it asked thousands of times and froze the server for 0.3 s)
    do
        local calls = 0
        local probe = {fruitIndexes = {1}}
        function probe:hasFruit(x, z, size) calls = calls + 1; return z < -4 end
        local node = {x = 0, z = 0, h = 0}
        local truck = {rootNode = node}
        function truck:getAIDirectionNode() return node end
        local d = setmetatable({vehicle = truck, info = {turnRadius = 8}, turnRadius = 8, course = {plan = {workWidth = 3}},
                                probe = probe}, {__index = GuidanceHelperDriver})
        d:planTo(-40, 0, math.pi, 6)
        local planCalls = calls
        r.planCheap = planCalls < 160
        CHEAP_INFO = string.format("one U-turn plan asked the crop %d times (want < 160; 219 before 1.0.6.6)", planCalls)
    end

    -- the unloader is AutoDrive's, set up from our panel: picking the combine gives the truck and the combine the
    -- marker of the combine's field as first target (AutoDrive pairs them by it); a setting goes into AutoDrive's
    -- settings of the truck or of the combine and out with AutoDrive's settings event; Unload at is its second target;
    -- Start: "unload combine" mode, started as AutoDrive's own button does (not without both targets); our combine
    -- starting on another field takes its trucks along; the combine counts the truck AutoDrive sent it as its own
    do
        local function stateModule()
            local sm = {mode = 1, active = false}
            function sm:getFirstMarker() return self.first end
            function sm:getFirstMarkerId() return self.first and self.first.markerIndex or -1 end
            function sm:getSecondMarker() return self.second end
            function sm:getSecondMarkerId() return self.second and self.second.markerIndex or -1 end
            function sm:setFirstMarker(id) self.first = {markerIndex = id} end
            function sm:setSecondMarker(id) self.second = {markerIndex = id} end
            function sm:getMode() return self.mode end
            function sm:setMode(m) self.mode = m end
            function sm:isActive() return self.active end
            return sm
        end
        local sent, presses = {}, 0
        AutoDrive = {MODE_UNLOAD = 5, settings = {unloadFillLevel = {values = {0.5, 0.9, 1}, default = 2},
                                                  chaseSide = {values = {0, 1, 2, 3}, default = 1}}}
        function AutoDrive.getSettingState(name, vehicle)
            return vehicle.ad.settings[name] or AutoDrive.settings[name].default
        end
        function AutoDrive.setSettingState(name, ix, vehicle) vehicle.ad.settings[name] = ix end
        function AutoDrive:GetAvailableDestinations()
            return {[3] = {name = "Shop", x = 4850, z = 5000}, [8] = {name = "Field 77 WAIT", x = 4898, z = 5050},
                    [9] = {name = "Field 78 WAIT", x = 6898, z = 5050}}
        end
        AutoDriveUpdateSettingsEvent = {sendEvent = function(vehicle) sent[#sent + 1] = vehicle end}
        ADInputManager = {}
        function ADInputManager:input_start_stop(vehicle)
            presses = presses + 1
            vehicle.ad.stateModule.active = not vehicle.ad.stateModule.active
        end
        local cNode = {x = 5000, z = 5000, h = 0}
        local field = 77
        local combine = {rootNode = cNode, spec_guidance = {}, spec_combine = {fillUnitIndex = 1}, spec_pipe = {},
                         ad = {stateModule = stateModule(), settings = {}}}
        function combine:getChildVehicles() return {self} end
        function combine:getOwnerFarmId() return 1 end
        function combine:getName() return "Tiger" end
        function combine:getGuidanceCourse()
            local o = (field - 77) * 2000
            return {outline = {{x = 4900 + o, z = 4900}, {x = 5100 + o, z = 4900}, {x = 5100 + o, z = 5100}, {x = 4900 + o, z = 5100}}}
        end
        function combine:getGuidancePlan() return {fieldId = field} end
        local trailer = {spec_trailer = {}}
        function trailer:getFillUnits() return {{}} end
        local oldChildren, oldFarm, oldVs, oldServer = v.getChildVehicles, v.getOwnerFarmId, g_currentMission.vehicleSystem, g_server
        v.getChildVehicles = function(self) return {self, trailer} end
        v.getOwnerFarmId = function() return 1 end
        v.ad = {stateModule = stateModule(), settings = {}, modes = {}}
        g_currentMission.vehicleSystem = {vehicles = {v, combine}}
        g_server = g_server or {}
        local AD = GuidanceAutoDrive
        local can = AD.canUnload(v)
        AD.apply(v, AD.OP_COMBINE, combine, "", 0)
        local paired = v.ad.stateModule:getFirstMarkerId() == 8 and combine.ad.stateModule:getFirstMarkerId() == 8
            and AD.combineOf(v) == combine
        AD.apply(v, AD.OP_SETTING, v, "unloadFillLevel", 3)
        AD.apply(v, AD.OP_SETTING, combine, "chaseSide", 4)
        local values, ix = AD.setting("unloadFillLevel", v)
        local _, sideIx = AD.setting("chaseSide", combine)
        local settings = ix == 3 and values[ix] == 1 and sideIx == 4 and sent[1] == v and sent[2] == combine
        -- start without Unload at: nothing; with it: unload combine mode, pressed once; again: not twice; stop
        AD.apply(v, AD.OP_START, nil, "", 0)
        local notWithout = presses == 0
        AD.apply(v, AD.OP_UNLOAD_AT, nil, "", 3)
        AD.apply(v, AD.OP_START, nil, "", 0)
        local started = presses == 1 and v.ad.stateModule.mode == 5 and AD.isUnloading(v)
        AD.apply(v, AD.OP_START, nil, "", 0)
        local once = presses == 1
        -- the combine starts on field 78: its truck waits there now
        field, cNode.x = 78, 7000
        AD.followCombine(combine)
        local followed = combine.ad.stateModule:getFirstMarkerId() == 9 and v.ad.stateModule:getFirstMarkerId() == 9
        -- the combine and the truck AutoDrive sent it: paired (only touching counts), found as its unloader
        v.ad.modes[5] = {combine = combine}
        local d = setmetatable({vehicle = {}, harvester = combine}, {__index = GuidanceFieldworkDriver})
        local closeOnly = GuidanceFieldworkDriver.isObstacle(d, v) == "close"
        local found = GuidanceFieldworkDriver.autoDriveUnloaderOf(combine) == v
        AD.apply(v, AD.OP_STOP, nil, "", 0)
        local stopped = presses == 2 and not AD.isUnloading(v)
        local report = table.concat(AD.describeUnloader(v), "|")
        v.getChildVehicles, v.getOwnerFarmId, g_currentMission.vehicleSystem, g_server = oldChildren, oldFarm, oldVs, oldServer
        v.ad = nil
        AutoDrive, AutoDriveUpdateSettingsEvent, ADInputManager = nil, nil, nil
        r.adBridge = can and paired and settings and notWithout and started and once and followed and closeOnly and found
            and stopped and report:find("serves Tiger", 1, true) ~= nil
        AD_BRIDGE_INFO = string.format("can unload %s; Combine: both wait at Field 77 WAIT %s; settings into AutoDrive and sent %s; "
            .. "Start without Unload at: nothing %s; started in unload combine mode %s, not twice %s; combine on field 78: "
            .. "both wait at Field 78 WAIT %s; combine: its truck only when touching %s, found %s; stopped %s; report: %s",
            tostring(can), tostring(paired), tostring(settings), tostring(notWithout), tostring(started), tostring(once),
            tostring(followed), tostring(closeOnly), tostring(found), tostring(stopped), report)
    end

    -- after a server restart: a truck AutoDrive drove as a combine unloader when saved starts again 10 s after loading
    -- (AutoDrive itself does that only in single player); not before; not with After loading: Wait; not one that wasn't
    do
        local function truckState(wasActive, mode)
            local sm = {activeBeforeSave = wasActive, mode = mode, active = false, first = {markerIndex = 8}, second = {markerIndex = 3}}
            function sm:isActive() return self.active end
            function sm:getMode() return self.mode end
            function sm:setMode(m) self.mode = m end
            function sm:getFirstMarker() return self.first end
            function sm:getSecondMarker() return self.second end
            return sm
        end
        AutoDrive = {MODE_UNLOAD = 5}
        local presses = 0
        ADInputManager = {}
        function ADInputManager:input_start_stop(vehicle) presses = presses + 1; vehicle.ad.stateModule.active = true end
        local spec = v.spec_guidance
        local function restart(wasActive, mode, carryOn)
            presses = 0
            v.ad = {stateModule = truckState(wasActive, mode)}
            spec.settings.autoResume = carryOn
            spec.adResumeAfterLoad = 0
            GuidanceAutoDrive.updateResume(v, spec, 5000)
            local early = presses
            GuidanceAutoDrive.updateResume(v, spec, 6000)
            return early, presses
        end
        local early, started = restart(true, 5, true)
        local _, waitSet = restart(true, 5, false)
        local _, notUnloading = restart(true, 1, true)
        local _, notActive = restart(false, 5, true)
        spec.settings.autoResume = true
        v.ad, AutoDrive, ADInputManager = nil, nil, nil
        r.adResume = early == 0 and started == 1 and waitSet == 0 and notUnloading == 0 and notActive == 0
        AD_RESUME_INFO = string.format("unloading when saved: after 5 s %d starts, after 11 s %d (want 0, 1); After loading Wait: %d; "
            .. "another AutoDrive mode: %d; not driving when saved: %d", early, started, waitSet, notUnloading, notActive)
    end

    -- Start at First, Then Continue: the course's first start at waypoint 1; once it got going (waypoint 50), where it
    -- got to; Then Nearest: nearest; Then First: 1 again; a new course (progress 1): 1
    do
        local spec = v.spec_guidance
        local oldMode, oldAfter, oldIx = spec.settings.startMode, spec.settings.startAfter, spec.progressIx
        spec.settings.startMode = GuidancePlan.START_FIRST
        spec.settings.startAfter = GuidancePlan.START_CONTINUE
        spec.progressIx = 1
        local fresh = v:guidanceGetStart()
        spec.progressIx = 50
        local later = v:guidanceGetStart()
        local resume = spec.course:getResumeIx(50)
        spec.settings.startAfter = GuidancePlan.START_NEAREST
        local nearestNow = GuidanceVehicle.startModeNow(spec)
        spec.settings.startAfter = GuidancePlan.START_FIRST
        local firstAgain = v:guidanceGetStart()
        spec.settings.startMode, spec.settings.startAfter, spec.progressIx = oldMode, oldAfter, oldIx
        r.startAfter = fresh == 1 and later == resume and later > 1 and nearestNow == GuidancePlan.START_NEAREST and firstAgain == 1
        START_AFTER_INFO = string.format("First, Then Continue: new course starts at %s, got going (50): at %s (resume %s); Then Nearest: mode %s; Then First: %s",
            tostring(fresh), tostring(later), tostring(resume), tostring(nearestNow), tostring(firstAgain))
    end

    -- the tank forecast: litres per metre learned while harvesting (10 l/m); at the start of a 100 m row with 7000 of
    -- 8000 l (the row needs 1000): it waits for the unloader on the headland, with 6000 l it goes in; not at a
    -- headland pass, not when the row needs more than a tank, not with an unloader on its way. In a row with 7000 l
    -- and 90 m to go: AutoDrive's call level on the harvester set to where the tank is (85 %) now, back to the
    -- player's 90 % once emptied
    do
        local level = 0
        local h = {spec_combine = {fillUnitIndex = 1}, ad = {settings = {preCallLevel = {}}}}
        function h:getFillUnitFillLevel() return level end
        function h:getFillUnitCapacity() return 8000 end
        local set = {}
        AutoDrive = {settings = {preCallLevel = {values = {0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 1}}}}
        function AutoDrive.setSettingState(name, ix, v) set[#set + 1] = AutoDrive.settings[name].values[ix] end
        function AutoDrive.getSettingState() return 1 end
        local follower = {s = 0, workIntervals = {{from = 0, to = 100}},
                          points = {{d = 0, t = "R"}, {d = 100, t = "R"}}}
        function follower:isReversing() return false end
        local sent
        local d = setmetatable({vehicle = h, harvester = h, follower = follower, info = {frontOffset = 0},
                                course = {plan = {callUnloaderAt = 90}}, lowered = true,
                                state = GuidanceFieldworkDriver.STATE_DRIVING}, {__index = GuidanceFieldworkDriver})
        function d:unloadersAbout() return true end
        function d:sentUnloader() return sent end
        function h:getChildVehicles() return {self} end
        for k = 0, 40, 2 do
            follower.s, level = k, 1000 + 10 * k
            d:updateTankRate()
        end
        local rate = d:tankRateKnown()
        d.lowered, follower.s = false, -2
        level = 7000
        local hold = d:tankHoldAtRowStart()
        level = 6000
        local go = not d:tankHoldAtRowStart()
        level = 7000
        follower.points[2].t = "H"
        local notHeadland = not d:tankHoldAtRowStart()
        follower.points[2].t = "R"
        sent = {}
        local notComing = not d:tankHoldAtRowStart()
        sent = nil
        follower.workIntervals[1].to = 900
        local notLong = not d:tankHoldAtRowStart()
        follower.workIntervals[1].to = 100
        -- in the row: 10 m in, 90 to go
        d.lowered, follower.s = true, 10
        level = 6000
        d:updateEarlyCall(level, 8000)
        local noCall = not d.calledEarly and #set == 0
        level = 7000
        d:updateEarlyCall(level, 8000)
        local called = d.calledEarly == true and set[1] == 0.85
        level = 500
        d:updateEarlyCall(level, 8000)
        local back = not d.calledEarly and set[2] == 0.9
        AutoDrive = nil
        r.tankAware = rate and math.abs(rate - 10) < 0.01 and hold and go and notHeadland and notComing and notLong
            and noCall and called and back
        TANK_INFO = string.format("learned %.1f l/m (want 10); row start, 7000 of 8000 l, row needs 1000: waits %s; 6000 l: goes %s; "
            .. "headland pass: goes %s; unloader on its way: goes %s; row longer than a tank: goes %s; in the row, 6000 l: no call %s; "
            .. "7000 l (full before the row ends): called at %s; emptied: back to %s",
            rate or -1, tostring(hold), tostring(go), tostring(notHeadland), tostring(notComing), tostring(notLong),
            tostring(noCall), tostring(set[1]), tostring(set[2]))
    end

    -- fuel and repair trips: Refuel at 15 %: at 10 % fuel a fuel trip is due; at 50 % fuel but 85 % worn (Repair at
    -- 80 %): a repair; the helper buying fuel: no fuel trip; tried a moment ago: not again. Started: the job stops
    -- as "out of fuel" (AutoDrive's refuel for Courseplay), AutoDrive's own refuel switch turned on
    do
        local fuel, damage = 0.1, 0.2
        local tractor = {spec_motorized = {propellantFillUnitIndices = {1}}, spec_guidance = {},
                         ad = {settings = {}}}
        function tractor:getFillUnitCapacity() return 400 end
        function tractor:getFillUnitFillLevel() return 400 * fuel end
        function tractor:getDamageAmount() return damage end
        function tractor:getChildVehicles() return {self} end
        local realCan = GuidanceAutoDrive.canService
        GuidanceAutoDrive.canService = function() return true end
        local d = setmetatable({vehicle = tractor, course = {plan = {refuelAt = 15, repairAt = 80}}},
            {__index = GuidanceFieldworkDriver})
        local buyBefore = g_currentMission.missionInfo.helperBuyFuel
        g_currentMission.missionInfo.helperBuyFuel = false
        local fuelDue = d:serviceNeeded()
        fuel, damage = 0.5, 0.85
        local repairDue = d:serviceNeeded()
        fuel, damage = 0.1, 0.2
        g_currentMission.missionInfo.helperBuyFuel = true
        local bought = d:serviceNeeded()
        g_currentMission.missionInfo.helperBuyFuel = false
        local stopped, info
        function d:stop(msg, text) stopped, info = msg, text end
        AutoDrive = {settings = {autoRefuel = {values = {false, true}, default = 2}}}
        function AutoDrive.getSettingState(name, v) return v.ad.settings[name] or 1 end
        function AutoDrive.setSettingState(name, ix, v) v.ad.settings[name] = ix end
        d.serviceDue = fuelDue
        d:startServiceTrip()
        local again = d:serviceNeeded()
        AutoDrive = nil
        GuidanceAutoDrive.canService = realCan
        g_currentMission.missionInfo.helperBuyFuel = buyBefore
        r.serviceTrips = fuelDue == "fuel" and repairDue == "repair" and bought == nil and info == "SERVICE_FUEL"
            and stopped ~= nil and tractor.ad.settings.autoRefuel == 2 and again == nil
        SERVICE_INFO = string.format("10%% fuel: %s; 85%% worn: %s; helper buys fuel: %s; trip: %s, AutoDrive's refuel switched on %s; "
            .. "right after: %s", tostring(fuelDue), tostring(repairDue), tostring(bought), tostring(info),
            tostring(tractor.ad.settings.autoRefuel == 2), tostring(again))
    end

    -- the field's chain: the test tractor done on field 7, Then: a second tractor without a course: that one gets a
    -- course on field 7 (its own settings) and is sent there; busy: not
    do
        local v2 = makeVehicle(flat[1] + 60, flat[2] + 60, 0, "Seeder tractor")
        v2.uniqueId = "vehicleSeeder"
        local oldVs = g_currentMission.vehicleSystem
        g_currentMission.vehicleSystem = {vehicles = {v, v2}}
        local went
        v2.guidanceGoTo = function(_, id) went = id end
        local planBefore = v:getGuidancePlan().handOver
        v:getGuidancePlan().handOver = "vehicleSeeder"
        local busy = v2.getIsHelperDriving
        v2.getIsHelperDriving = function() return true end
        local notBusy = not GuidanceVehicle.handOver(v)
        v2.getIsHelperDriving = busy
        local handed = GuidanceVehicle.handOver(v)
        local p2 = v2:getGuidancePlan()
        local shown = v:getGuidanceInfoTexts()
        local said = false
        for _, i in ipairs(shown) do said = said or i.name == "HANDED_OVER" end
        v:getGuidancePlan().handOver = planBefore
        v:guidanceSetInfoText("HANDED_OVER", false)
        -- contracts: one running on field 7 for our farm, one for another farm, one done
        MissionStatus = {RUNNING = 2, FINISHED = 3}
        local function mission(farm, status, id, title)
            local field = {}
            function field:getId() return id end
            function field:getAreaHa() return 12.3 end
            return {farmId = farm, status = status, field = field, fieldPercentageDone = 0.25,
                    getTitle = function() return title end}
        end
        local all = {mission(1, 2, 7, "Harvest wheat"), mission(2, 2, 9, "Sow canola"), mission(1, 3, 11, "Plow")}
        g_missionManager = {getMissionsByFarmId = function(_, farm)
            local out = {}
            for _, m in ipairs(all) do if m.farmId == farm then out[#out + 1] = m end end
            return out
        end}
        local list = GuidanceContracts.running(1)
        local here = GuidanceContracts.onField(1, 7)
        v2:guidanceSetPlan(nil)
        local made = v2:guidanceCourseForField(7)
        local p3 = v2:getGuidancePlan()
        g_missionManager, MissionStatus = nil, nil
        g_currentMission.vehicleSystem = oldVs
        r.handOver = notBusy and handed and went == 0 and p2 ~= nil and p2.fieldId == 7 and v2:getGuidanceCourse() ~= nil and said
        r.contracts = #list == 1 and list[1].fieldId == 7 and list[1].title == "Harvest wheat" and math.abs(list[1].area - 12.3) < 1e-6
            and here ~= nil and here.fieldId == 7 and GuidanceContracts.onField(1, 9) == nil and made and p3 ~= nil and p3.fieldId == 7
        CHAIN_INFO = string.format("busy: not handed over %s; done: handed over %s, sent there %s, its course on field %s, status says so %s",
            tostring(notBusy), tostring(handed), tostring(went), tostring(p2 and p2.fieldId), tostring(said))
        CONTRACT_INFO = string.format("our running contracts: %d (want 1: field %s, %s, %.1f ha); course made for it from afar %s, on field %s",
            #list, tostring(list[1] and list[1].fieldId), tostring(list[1] and list[1].title), list[1] and list[1].area or 0,
            tostring(made), tostring(p3 and p3.fieldId))
    end

    -- going back for crop behind it, standing on its lane: straight back up the lane (reversing), then on; not a way
    -- planned round through the crop. Unable to reverse: the planned way as before
    do
        local node = {x = 50, z = 0, h = 0}
        local tr = {rootNode = node}
        function tr:getAIDirectionNode() return node end
        local planned = 0
        local realPlan = GuidanceCourseGenerator.planApproach
        GuidanceCourseGenerator.planApproach = function(_, _, from, to) planned = planned + 1; return {{x = to.x, y = to.y}} end
        local wps = {{x = 0, z = 0, t = "H", work = true}, {x = 100, z = 0, t = "H", work = true}, {x = 200, z = 0, t = "H", work = true}}
        local function build(canReverse)
            local plan = {allowReverse = canReverse}
            function plan:getGeneratorSettings() return {} end
            local d = setmetatable({vehicle = tr, sideOffset = 0, info = {runOut = 3, backOffset = 0},
                                    course = {waypoints = wps, plan = plan}}, {__index = GuidanceFieldworkDriver})
            return d:buildPath(2, {x = 20, z = 0})
        end
        local path = build(true)
        local backed = path[2] and path[2].rev == true and math.abs(path[2].x - 17) < 0.01 and planned == 0
            and path[3] and not path[3].rev and math.abs(path[3].x - 20) < 0.01
        local loop = build(false)
        local plannedNow = planned == 1 and loop[2] and not loop[2].rev
        GuidanceCourseGenerator.planApproach = realPlan
        r.backUp = backed and plannedNow
        BACKUP_INFO = string.format("start 30 m behind on its lane: backs straight up to x %.0f (want 17), then on from %.0f, no way planned %s; can't reverse: a way planned %s",
            path[2] and path[2].x or -1, path[3] and path[3].x or -1, tostring(planned == 0 or planned == 1), tostring(plannedNow))
    end

    -- the crop probe: cut fruit (a harvested sugarcane lane: the game still reports the cane, in its cut state) and
    -- withered fruit aren't standing crop; growing or ripe is (before 1.0.8.7 a harvested lane read as crop)
    do
        local oldFruit, oldTypes = FSDensityMapUtil, g_fruitTypeManager
        local CUT, WITHERED, RIPE = 10, 11, 5
        FSDensityMapUtil = {getFruitArea = function(i, x0, z0, x1, z1, x2, z2)
            local x = (x0 + x1) / 2
            local state = x < -20 and WITHERED or (x < 0 and CUT or RIPE)
            return 1, 1, 1, state
        end}
        local cane = {}
        function cane:getIsCut(st) return st == CUT end
        function cane:getIsWithered(st) return st == WITHERED end
        g_fruitTypeManager = {fruitTypes = {{index = 1}}, getFruitTypeByIndex = function(_, i) return cane end}
        local probe = GuidanceFruitProbe.new({{x = -50, z = -50}, {x = 50, z = -50}, {x = 50, z = 50}, {x = -50, z = 50}})
        local cutLane, withered, standing = probe:hasFruit(-5, 0, 1), probe:hasFruit(-30, 0, 1), probe:hasFruit(5, 0, 1)
        FSDensityMapUtil, g_fruitTypeManager = oldFruit, oldTypes
        r.cutNotCrop = #probe.fruitIndexes == 1 and not cutLane and not withered and standing
        CUT_INFO = string.format("cut cane: crop %s (want false); withered: %s (want false); ripe: %s (want true)",
            tostring(cutLane), tostring(withered), tostring(standing))
    end

    -- Start at: Nearest with a harvester standing on a pass already harvested (no crop on it, crop everywhere else):
    -- it starts on the nearest pass with crop, beside it (not standing on that pass, it doesn't go back to the pass's
    -- start: 1.0.7.1 to 1.0.8.2 it turned round through the crop to get there); without a harvester, or with no crop
    -- on the field, the nearest as before
    do
        local course = v:getGuidanceCourse()
        local wps = course.waypoints
        local best, bestLen
        for i = 2, #wps do
            local a, b = wps[i - 1], wps[i]
            if b.work and not b.rev then
                local len = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
                if bestLen == nil or len > bestLen then best, bestLen = i, len end
            end
        end
        local a, b = wps[best - 1], wps[best]
        local node = v:getAIDirectionNode()
        local ox, oz, oh = node.x, node.z, node.h
        node.x, node.z, node.h = (a.x + b.x) / 2, (a.z + b.z) / 2, math.atan2(b.z - a.z, b.x - a.x)
        local oldFruit, oldTypes, oldFind = FSDensityMapUtil, g_fruitTypeManager, GuidanceFieldworkDriver.findHarvester
        local oldMode = v.spec_guidance.settings.startMode
        local cropHere = true
        g_fruitTypeManager = {fruitTypes = {{index = 1}}}
        FSDensityMapUtil = {getFruitArea = function(i, x0, z0, x1, z1, x2, z2)
            local d = GuidanceGeo.distToSegment({x = (x1 + x2) / 2, y = (z1 + z2) / 2}, {x = a.x, y = a.z}, {x = b.x, y = b.z})
            if not cropHere or d < 3 then return 0, 0, 1 end
            return 1, 1, 1
        end}
        v.spec_guidance.settings.startMode = GuidancePlan.START_NEAREST
        GuidanceFieldworkDriver.findHarvester = function() return nil end
        local plainIx = v:guidanceGetStart()
        GuidanceFieldworkDriver.findHarvester = function(veh) return veh end
        local cropIx, cropPoint = v:guidanceGetStart()
        local start = cropPoint or wps[cropIx]
        local off = GuidanceGeo.distToSegment({x = start.x, y = start.z}, {x = a.x, y = a.z}, {x = b.x, y = b.z})
        local away = math.sqrt((start.x - node.x) ^ 2 + (start.z - node.z) ^ 2)
        cropHere = false
        local noCropIx = v:guidanceGetStart()
        FSDensityMapUtil, g_fruitTypeManager, GuidanceFieldworkDriver.findHarvester = oldFruit, oldTypes, oldFind
        v.spec_guidance.settings.startMode = oldMode
        node.x, node.z, node.h = ox, oz, oh
        local cropStretchStart = cropPoint == nil and wps[cropIx + 1] ~= nil and wps[cropIx + 1].work
        -- a start half-way along a 100 m stretch: crop behind it from 30 m on: from 24 m; none behind: where it is; crop
        -- all the way: the stretch's start
        local line = setmetatable({waypoints = {{x = 0, z = 0}, {x = 100, z = 0, work = true}}}, {__index = GuidanceCourse})
        local function probeFrom(x0)
            return {fruitIndexes = {1}, hasFruit = function(_, x) return x0 ~= nil and x >= x0 end}
        end
        local half = {x = 50, z = 0}
        local ixA, ptA = line:uncutBehind(probeFrom(30), 2, half, 4)
        local ixB, ptB = line:uncutBehind(probeFrom(nil), 2, half, 4)
        local ixC, ptC = line:uncutBehind(probeFrom(0), 2, half, 4)
        -- 250 m along a 300 m stretch, crop behind it all the way: not back to the start (that meant turning round
        -- through the crop), 60 m back at most: from 184 m; crop only beside the line (its edge 0.8 m off): not crop
        local long = setmetatable({waypoints = {{x = 0, z = 0}, {x = 300, z = 0, work = true}}}, {__index = GuidanceCourse})
        local ixD, ptD = long:uncutBehind(probeFrom(0), 2, {x = 250, z = 0}, 4)
        local edge = {fruitIndexes = {1}, hasFruit = function(_, x, z, size) return z + (size or 2) / 2 > 0.8 end}
        local ixE, ptE = long:uncutBehind(edge, 2, {x = 250, z = 0}, 4)
        -- crop only 30 to 40 m behind (scattered bits; stubble right behind it): where it is (1.0.8.3 backed up 60 m)
        local patchy = {fruitIndexes = {1}, hasFruit = function(_, x) return x >= 210 and x <= 220 end}
        local ixF, ptF = long:uncutBehind(patchy, 2, {x = 250, z = 0}, 4)
        local behindOk = ixA == 2 and ptA ~= nil and math.abs(ptA.x - 24) < 0.01 and ixB == 2 and ptB == half
            and ixC == 1 and ptC == nil and ixD == 2 and ptD ~= nil and math.abs(ptD.x - 184) < 0.01 and ixE == 2
            and ptE ~= nil and ptE.x == 250 and ixF == 2 and ptF ~= nil and ptF.x == 250
        -- (not standing on that pass: beside it, where it is, not back to its start: 1.0.8.3)
        r.nearestCrop = plainIx == best and cropIx ~= best and off >= 3 and away < 60 and not cropStretchStart
            and noCropIx == best and behindOk
        NEAREST_INFO = string.format("nearest %d (on stretch %d, %.0f m), harvester: %d, %.1f m off that pass, at its start %s; no crop: %d; "
            .. "half-way along 100 m with crop behind from 30 m: from %s m; none behind: %s; crop all along: waypoint %d; "
            .. "250 m along 300 m, crop all along: from %s m (want 184, not the start); crop only beside the line: %s",
            plainIx, best, bestLen, cropIx, off, tostring(cropStretchStart), noCropIx, ptA and string.format("%.0f", ptA.x) or "its start",
            ptB == half and "where it is" or "moved", ixC, ptD and string.format("%.0f", ptD.x) or "its start",
            (ptE and ptE.x == 250) and "where it is" or "moved")
    end

    -- the overlay: a helper working, lines and text drawn
    local LINES, TEXTS = 0, 0
    drawDebugLine = function() LINES = LINES + 1 end
    Utils = Utils or {}
    Utils.renderTextAtWorldPosition = function() TEXTS = TEXTS + 1 end
    v.getIsGuidanceActive = function() return true end
    v.spec_guidance.driver = {state = 3, follower = GuidancePathFollower.new({{x = 0, z = 0, t = "C"}, {x = 50, z = 0, t = "R", work = true}}),
                              debugTarget = {10, 0, 12}}
    GuidanceDebug.drawVehicle(v, v.spec_guidance, 0, 0)
    r.overlay = LINES >= 3 and TEXTS >= 3
    v.spec_guidance.driver = nil
    -- the course in the world: Start and End flags where it starts and ends (each near enough to the vehicle)
    do
        local flags = {}
        Utils.renderTextAtWorldPosition = function(x, y, z, text) flags[text] = {x = x, z = z} end
        setTextColor = setTextColor or function() end
        setTextBold = setTextBold or function() end
        local course = v:getGuidanceCourse()
        local wps = course.waypoints
        local node = v.rootNode
        local ox, oz = node.x, node.z
        node.x, node.z = wps[1].x, wps[1].z
        GuidanceDraw.drawCourseInWorld(v, course)
        node.x, node.z = wps[#wps].x, wps[#wps].z
        GuidanceDraw.drawCourseInWorld(v, course)
        node.x, node.z = ox + 5000, oz
        local farFlags = 0
        local before = flags
        flags = {}
        GuidanceDraw.drawCourseInWorld(v, course)
        for _ in pairs(flags) do farFlags = farFlags + 1 end
        node.x, node.z = ox, oz
        local s, e = before.guidance_world_start, before.guidance_world_end
        r.worldFlags = s ~= nil and e ~= nil and math.abs(s.x - wps[1].x) < 0.01 and math.abs(e.z - wps[#wps].z) < 0.01
            and farFlags == 0
    end

    -- a setting only for starting (start at): kept in the plan, sent to the server, the course and where it got to
    -- kept; a later change of the course keeps it too; the server takes one sent to it and passes it on
    local sent, passed = nil, 0
    local realSend = GuidanceSettingEvent.sendEvent
    GuidanceSettingEvent.sendEvent = function(_, name, value) sent = {name = name, value = value} end
    v:guidanceGenerate()
    v.spec_guidance.progressIx = 7
    local before = v:getGuidanceCourse()
    v:guidanceChangeSetting("startMode", GuidancePlan.START_NEAREST)
    r.startSetting = sent ~= nil and sent.name == "startMode" and sent.value == GuidancePlan.START_NEAREST
        and v:getGuidancePlan().startMode == GuidancePlan.START_NEAREST and v:getGuidanceCourse() == before
        and v.spec_guidance.progressIx == 7
    v:guidanceChangeSetting("headlands", 2)
    local kept = v:getGuidanceSettings().startMode == GuidancePlan.START_NEAREST
        and v:getGuidancePlan().startMode == GuidancePlan.START_NEAREST
    GuidanceSettingEvent.sendEvent = realSend
    local realBroadcast = g_server.broadcastEvent
    g_server.broadcastEvent = function() passed = passed + 1 end
    GuidanceSettingEvent.new(v, "startMode", GuidancePlan.START_FIRST):run({getIsServer = function() return false end})
    g_server.broadcastEvent = realBroadcast
    r.startSetting = r.startSetting and kept and v:getGuidanceSettings().startMode == GuidancePlan.START_FIRST
        and passed == 1

    -- an implement unfolding at the start: the driver waits until it is unfolded (no speed until then), measures the
    -- vehicle again then; one already unfolded, which the game calls "not ready to drive" (that is for the road:
    -- it wants it folded), starts at once (the 1.0.0.0 bug); one that never finishes folding: it goes after a while
    local function prepareRun(foldFor, roadReady)
        local veh = makeVehicle(flat[1] + 30, flat[2] + 30, 0, "Folding tractor")
        local implement = {spec_foldable = {hasFoldingParts = true, foldAnimTime = foldFor and 1 or 0}}
        veh.children = {veh, implement}
        g_currentMission.vehicleSystem = {vehicles = {veh}}
        assert(veh:guidanceGenerate())
        local t = 0
        function veh:getIsAIReadyToDrive() return roadReady, self end
        function veh:getIsAIPreparingToDrive() return false end
        function veh:raiseAIEvent() end
        function veh:raiseStateChange() end
        local measured = 0
        local realGet = GuidanceVehicleInfo.get
        GuidanceVehicleInfo.get = function(...) measured = measured + 1 return realGet(...) end
        local d = GuidanceFieldworkDriver.new(veh, veh:getGuidanceCourse(), 1)
        local before = measured
        local movedEarly, state = false, nil
        for _ = 1, 800 do
            -- unfolding from 1 to 0 over foldFor ms (math.huge: stuck half way)
            if foldFor then
                local f = foldFor == math.huge and 0.5 or math.max(0, 1 - t / foldFor)
                implement.spec_foldable.foldAnimTime = f
            end
            local _, _, _, speed = d:getDriveData(100)
            if foldFor and foldFor ~= math.huge and t < foldFor and (speed or 0) > 0 then movedEarly = true end
            t = t + 100
            g_time = (g_time or 0) + 100
            state = d.state
            if d.state == GuidanceFieldworkDriver.STATE_DRIVING or d.state == GuidanceFieldworkDriver.STATE_DONE then break end
        end
        GuidanceVehicleInfo.get = realGet
        return movedEarly, state, measured > before, t
    end
    local early, state, remeasured, t = prepareRun(3000, false)
    r.prepareWait = not early and state == GuidanceFieldworkDriver.STATE_DRIVING and remeasured and t >= 3000 and t < 4500
    local _, stateU, _, tU = prepareRun(nil, false)
    r.prepareUnfolded = stateU == GuidanceFieldworkDriver.STATE_DRIVING and tU <= 1500
    local _, state2, _, t2 = prepareRun(math.huge, false)
    r.prepareGiveUp = state2 == GuidanceFieldworkDriver.STATE_DRIVING and t2 > GuidanceFieldworkDriver.PREPARE_TIMEOUT
        and t2 < GuidanceFieldworkDriver.PREPARE_TIMEOUT + 2000
    PREPARE_INFO = string.format("unfolding: waited %.1f s, then driving %s, measured again %s; already unfolded (the game: not ready for the road): driving after %.1f s; stuck folding: went after %.1f s",
        t / 1000, tostring(state == GuidanceFieldworkDriver.STATE_DRIVING), tostring(remeasured), tU / 1000, t2 / 1000)
    g_currentMission.vehicleSystem = {vehicles = {v}}

    -- rain: a combine waits where it is while harvesting would lose yield, goes on when it's dry; not if told not to
    local function rainRun(wait)
        local c = makeVehicle(flat[1] + 30, flat[2] + 30, 0, "Combine")
        c.spec_combine = {fillUnitIndex = 1}
        c.spec_pipe = {numStates = 2, currentState = 1}
        function c:getFillUnitCapacity() return 10000 end
        function c:getFillUnitFillLevel() return 0 end
        function c:getIsPipeStateChangeAllowed() return true end
        function c:setPipeState(st) self.spec_pipe.currentState = st end
        RAINING = false
        function c:getIsThreshingDuringRain() return RAINING end
        function c:raiseAIEvent() end
        function c:raiseStateChange() end
        function c:getCanAIFieldWorkerContinueWork() return true end
        g_currentMission.vehicleSystem = {vehicles = {c}}
        assert(c:guidanceGenerate())
        c:getGuidanceSettings().rainWait = wait
        c:getGuidancePlan().rainWait = wait
        local d = GuidanceFieldworkDriver.new(c, c:getGuidanceCourse(), 1)
        local function speedNow()
            local sp = 0
            for _ = 1, 5 do
                local _, _, _, s2 = d:getDriveData(100)
                sp = s2 or 0
                g_time = (g_time or 0) + 100
            end
            return sp
        end
        -- (under way first: the start waits a moment for the implements)
        for _ = 1, 40 do
            if d.state == GuidanceFieldworkDriver.STATE_DRIVING then break end
            d:getDriveData(100)
            g_time = (g_time or 0) + 100
        end
        local dry = speedNow()
        RAINING = true
        local wet = speedNow()
        local shown = c.spec_guidance.infoTexts.WAITING_RAIN == true
        RAINING = false
        local after = speedNow()
        local cleared = c.spec_guidance.infoTexts.WAITING_RAIN == nil
        g_currentMission.vehicleSystem = {vehicles = {v}}
        return dry, wet, shown, after, cleared
    end
    -- while it works: the live settings go to the running helper (the course stays); the pipe goes out at the call
    -- level when there are unloaders about
    do
        local c = makeVehicle(flat[1] + 30, flat[2] + 30, 0, "Combine")
        c.spec_combine = {fillUnitIndex = 1}
        c.spec_pipe = {numStates = 2, currentState = 1}
        local level = 0
        function c:getFillUnitCapacity() return 10000 end
        function c:getFillUnitFillLevel() return level end
        function c:getIsPipeStateChangeAllowed() return true end
        function c:setPipeState(st) self.spec_pipe.currentState = st end
        function c:raiseAIEvent() end
        function c:raiseStateChange() end
        function c:getCanAIFieldWorkerContinueWork() return true end
        g_currentMission.vehicleSystem = {vehicles = {c}}
        assert(c:guidanceGenerate())
        local d = GuidanceFieldworkDriver.new(c, c:getGuidanceCourse(), 1)
        local course = c:getGuidanceCourse()
        local realActive = c.getIsGuidanceActive
        c.getIsGuidanceActive = function() return true end
        c.spec_guidance.driver = d
        c:guidanceChangeSetting("callUnloaderAt", 60)
        c:guidanceChangeSetting("workSpeedMax", 8)
        local live = c:getGuidanceCourse() == course and d.course.plan.callUnloaderAt == 60 and d.course.plan.workSpeedMax == 8
            and c:getGuidanceSettings().callUnloaderAt == 60
        c.getIsGuidanceActive = realActive
        c.spec_guidance.driver = nil
        c:guidanceChangeSetting("workSpeedMax", 10)
        local remade = c:getGuidanceCourse() ~= course
        -- the pipe: in below the call level, out at it (unloaders about), not without unloaders
        d.hasAutoDriveUnloaders = function() return true end
        level = 5000
        d:updatePipe(100)
        local inBelow = c.spec_pipe.currentState == 1
        level = 6500
        d.unloadersTimer = math.huge
        d:updatePipe(100)
        local outAt = c.spec_pipe.currentState == 2
        c.spec_pipe.currentState = 1
        d.hasAutoDriveUnloaders = function() return false end
        d.unloadersTimer = math.huge
        d.pipeIdleTimer = 0
        d:updatePipe(100)
        local stayedIn = c.spec_pipe.currentState == 1
        r.liveSettings = live and remade and inBelow and outAt and stayedIn
        LIVE_INFO = string.format("changed while working: course kept and the helper has them %s; when not working the course is made again %s; pipe in below the call level %s, out at it %s, in without unloaders %s",
            tostring(live), tostring(remade), tostring(inBelow), tostring(outAt), tostring(stayedIn))
        g_currentMission.vehicleSystem = {vehicles = {v}}
    end
    local dry, wet, shown, after, cleared = rainRun(true)
    local _, wet2 = rainRun(false)
    r.rainWait = dry > 0 and wet == 0 and shown and after > 0 and cleared and wet2 > 0
    RAIN_INFO = string.format("dry %.0f km/h, raining %.0f (status shown %s), dry again %.0f (cleared %s); told to carry on: %.0f in the rain",
        dry, wet, tostring(shown), after, tostring(cleared), wet2)

    -- refilling at the field edge: a seeder runs empty, a seed pallet stands 20 m off the field: its opening into
    -- the pallet's trigger, filled up, back to where it stopped, the course on from there
    do
        FillType = FillType or {}
        FillType.SEEDS = FillType.SEEDS or 51
        g_currentMission.missionInfo = g_currentMission.missionInfo or {}
        g_currentMission.missionInfo.helperBuySeeds = false
        local tr = makeVehicle(flat[1] + 30, flat[2] + 30, 0, "Seeder tractor")
        local opening = {lx = 0, lz = -4, x = 0, z = 0}
        local seeder = {level = 0, capacity = 1000, spec_sowingMachine = {fillUnitIndex = 1},
                        spec_fillUnit = {fillTrigger = {triggers = {}, isFilling = false}}, rootNode = opening}
        function seeder:getFillUnitCapacity() return self.capacity end
        function seeder:getFillUnitFillLevel() return self.level end
        function seeder:getFillUnitSupportsFillType(ix, ft) return ft == FillType.SEEDS end
        function seeder:getFillUnitExactFillRootNode() return opening end
        function seeder:setFillUnitIsFilling(on) self.spec_fillUnit.fillTrigger.isFilling = on end
        tr.children = {tr, seeder}
        function tr:raiseAIEvent() end
        function tr:raiseStateChange() end
        function tr:getCanAIFieldWorkerContinueWork() return true end
        function tr:getSpeedLimit() return 12, true end
        -- the pallet: 20 m west of the field's westmost point
        local wx, wz = math.huge, 0
        for i = 1, #flat - 1, 2 do if flat[i] < wx then wx, wz = flat[i], flat[i + 1] end end
        local trigNode = {x = wx - 20, z = wz, lx = 0, lz = 0}
        local pallet = {rootNode = trigNode, level = 2000,
                        spec_fillTriggerVehicle = {fillUnitIndex = 1, fillTrigger = {triggerNode = trigNode}}}
        local trigger = {getIsActivatable = function() return true end}
        function pallet:getFillUnitFillType() return FillType.SEEDS end
        function pallet:getFillUnitFillLevel() return self.level end
        g_currentMission.vehicleSystem = {vehicles = {tr, pallet}}
        tr:getGuidanceSettings().refillEdge = true
        assert(tr:guidanceGenerate())
        local d = GuidanceFieldworkDriver.new(tr, tr:getGuidanceCourse(), 1)
        tr.spec_aiFieldWorker = tr.spec_aiFieldWorker or {}
        local startX, startZ = tr.rootNode.x, tr.rootNode.z
        local reached, filled, resumeAt, backDist, phases = false, false, nil, math.huge, {}
        for step = 1, 30000 do
            local n = tr.rootNode
            opening.x = n.x + math.cos(n.h) * opening.lz
            opening.z = n.z + math.sin(n.h) * opening.lz
            -- the game: the opening in the pallet's trigger (2 m) puts the trigger in the seeder's list; filling at
            -- 200 l/s while it is on, stopping when full
            local inside = math.sqrt((opening.x - trigNode.x) ^ 2 + (opening.z - trigNode.z) ^ 2) < 2
            seeder.spec_fillUnit.fillTrigger.triggers = inside and {trigger} or {}
            if inside then reached = true end
            local ft = seeder.spec_fillUnit.fillTrigger
            if ft.isFilling and inside then
                local q = math.min(20, seeder.capacity - seeder.level, pallet.level)
                seeder.level, pallet.level = seeder.level + q, pallet.level - q
                if seeder.level >= seeder.capacity then ft.isFilling = false end
            end
            if d.refill then
                phases[d.refill.phase] = true
                resumeAt = d.refill.resume
            end
            local tx, tz, fwd, speed = d:getDriveData(100)
            if tx then
                local lx, _, lz = worldToLocal(n, tx, 0, tz)
                AIVehicleUtil.driveToPoint(tr, 100, 1, (speed or 0) > 0, fwd ~= false, lx, lz, speed or 0)
            end
            g_time = (g_time or 0) + 100
            if seeder.level >= 975 then filled = true end
            if filled and d.refill == nil then
                backDist = math.sqrt((n.x - resumeAt.x) ^ 2 + (n.z - resumeAt.z) ^ 2)
                break
            end
            if d.state == GuidanceFieldworkDriver.STATE_DONE then break end
        end
        local list = {}
        for k in pairs(phases) do list[#list + 1] = k end
        table.sort(list)
        r.edgeRefill = reached and filled and backDist < 3 and pallet.level < 1100 and d.state == GuidanceFieldworkDriver.STATE_DRIVING
        EDGE_INFO = string.format("into the pallet's trigger %s, filled to %d l (pallet down to %d l), back %.1f m from where it stopped, then: state %d (%s)",
            tostring(reached), seeder.level, pallet.level, backDist, d.state, table.concat(list, " "))
        g_currentMission.vehicleSystem = {vehicles = {v}}
    end

    -- Go with a saved course: AutoDrive (a stand-in) to the course's marker, its helper button switched on; on arrival
    -- AutoDrive presses it (calls startCpAtLastWp) and we start; its button back as it was. Without the hand-off we
    -- start ourselves once AutoDrive stops.
    do
        local function goRun(handOff)
            local veh = makeVehicle(flat[1] + 30, flat[2] + 30, 0, "Go tractor")
            g_currentMission.vehicleSystem = {vehicles = {veh}}
            assert(veh:guidanceGenerate())
            local plan = veh:getGuidancePlan():copy()
            plan.adMarker = "Field 6 gate"
            local entry = GuidanceLibrary.newEntry("Field 6", 1, plan, veh:getGuidanceCourse())
            GuidanceLibrary.add(entry)
            -- the tractor far away (300 m), no course loaded
            veh.rootNode.x = veh.rootNode.x - 300
            local first = veh:getGuidanceCourse().waypoints[1]
            local sm = {active = false, helper = false, used = nil, mode = nil}
            function sm:isActive() return self.active end
            function sm:setMode(m) self.mode = m end
            function sm:setStartHelper(on) self.helper = on end
            function sm:getStartHelper() return self.helper end
            function sm:setUsedHelper(h) self.used = h end
            veh.ad = {stateModule = sm}
            local drove
            AutoDrive = {MODE_DRIVETO = 4}
            function AutoDrive:GetAvailableDestinations()
                return {[1] = {name = "Yard", x = first.x + 200, y = 0, z = first.z},
                        [2] = {name = "Field 6 gate", x = first.x + 20, y = 0, z = first.z + 400}}
            end
            function AutoDrive:StartDriving(v2, a, b) drove = {a, b}; sm.active = true end
            ADStateModule = {HELPER_CP = 1}
            -- an unfolded cultivator on the hitch, switched on: off, raised and folded before AutoDrive sets off
            local tool = {spec_foldable = {hasFoldingParts = true, turnOnFoldDirection = 1, foldAnimTime = 1,
                                           foldMoveDirection = 0}, on = true}
            function tool:getIsTurnedOn() return self.on end
            function tool:setIsTurnedOn(o) self.on = o end
            function tool:setFoldState(dir) self.spec_foldable.foldMoveDirection = dir end
            function tool:getAttacherVehicle() return veh end
            local raised = false
            function veh:getAttacherJointIndexFromObject(o) return o == tool and 1 or nil end
            function veh:setJointMoveDown(ix, down) if not down then raised = true end end
            veh.children = {veh, tool}
            local started = {}
            veh.guidanceStart = function(self2, ix) started[#started + 1] = ix; self2.startedJob = true; return true end
            veh.getIsHelperDriving = function(self2) return self2.startedJob == true end
            veh:guidanceGoTo(entry.id)
            -- folding (the game's animation, here in 4 frames): AutoDrive waits for it
            local droveEarly = false
            for _ = 1, 6 do
                GuidanceVehicle.updateQueue(veh)
                if drove and tool.spec_foldable.foldAnimTime > 0 then droveEarly = true end
                local f = tool.spec_foldable
                if f.foldMoveDirection == -1 then f.foldAnimTime = math.max(0, f.foldAnimTime - 0.25) end
                g_time = (g_time or 0) + 100
            end
            local folded = tool.spec_foldable.foldAnimTime == 0 and raised and not tool.on and not droveEarly
            local onWay = folded and drove and drove[1] == 2 and sm.helper == true and sm.used == 1 and sm.mode == 4
            -- (a frame on the way)
            GuidanceVehicle.updateQueue(veh)
            -- AutoDrive arrives: stops, and (with the hand-off) presses its helper button
            sm.active = false
            if handOff then veh:startCpAtLastWp() end
            for _ = 1, 3 do GuidanceVehicle.updateQueue(veh); g_time = (g_time or 0) + 100 end
            AutoDrive, ADStateModule = nil, nil
            return onWay, #started, sm.helper, veh:getGuidancePlan().adMarker
        end
        local onWay, starts, helperAfter, marker = goRun(true)
        local onWay2, starts2 = goRun(false)
        -- Start away from the course's field: not at it (and how far), Go there with the course it has (0)
        local veh3 = makeVehicle(flat[1] + 30, flat[2] + 30, 0, "Away tractor")
        g_currentMission.vehicleSystem = {vehicles = {veh3}}
        assert(veh3:guidanceGenerate())
        local atBefore = veh3:guidanceAtCourseField()
        veh3.rootNode.x = veh3.rootNode.x - 600
        local atAfter, distAway = veh3:guidanceAtCourseField()
        local first3 = veh3:getGuidanceCourse().waypoints[1]
        local sm3 = {active = false, helper = false}
        function sm3:isActive() return self.active end
        function sm3:setMode(m) self.mode = m end
        function sm3:setStartHelper(on) self.helper = on end
        function sm3:getStartHelper() return self.helper end
        function sm3:setUsedHelper(h) self.used = h end
        veh3.ad = {stateModule = sm3}
        local drove3
        AutoDrive = {MODE_DRIVETO = 4}
        function AutoDrive:GetAvailableDestinations()
            return {[7] = {name = "By the field", x = first3.x + 30, y = 0, z = first3.z}}
        end
        function AutoDrive:StartDriving(v2, a) drove3 = a; sm3.active = true end
        ADStateModule = {HELPER_CP = 1}
        veh3:guidanceGoTo(0)
        for _ = 1, 3 do GuidanceVehicle.updateQueue(veh3); g_time = (g_time or 0) + 100 end
        AutoDrive, ADStateModule = nil, nil
        r.awayGo = atBefore and not atAfter and distAway > 400 and drove3 == 7 and sm3.helper == true
        -- the marker AutoDrive takes it to: the field's own (at its edge, named after it) before one at its edge, before
        -- the nearest to the course's start (a silo 25 m off the field, right by the start)
        do
            local course3 = veh3:getGuidanceCourse()
            local plan3 = veh3:getGuidancePlan()
            local o = course3.outline
            local cx, cz = 0, 0
            for _, p in ipairs(o) do cx, cz = cx + p.x / #o, cz + p.z / #o end
            local function outward(p, d)
                local l = math.sqrt((p.x - cx) ^ 2 + (p.z - cz) ^ 2)
                return p.x + (p.x - cx) / l * d, p.z + (p.z - cz) / l * d
            end
            local fs = course3.waypoints[1]
            local function dStart(p) return math.sqrt((p.x - fs.x) ^ 2 + (p.z - fs.z) ^ 2) end
            local near, other
            for _, p in ipairs(o) do
                if near == nil or dStart(p) < dStart(near) then near = p end
            end
            for _, p in ipairs(o) do
                if p ~= near and dStart(p) > dStart(near) + 20 and dStart(p) < 200 and (other == nil or dStart(p) < dStart(other)) then
                    other = p
                end
            end
            other = other or near
            local sx, sz = outward(near, 25)
            local gx, gz = outward(other, 4)
            local nx, nz = outward(other, 2)
            local number = plan3.fieldId > 0 and plan3.fieldId or 1
            if plan3.fieldId <= 0 then plan3.fieldId = 1 end
            local list
            AutoDrive = {MODE_DRIVETO = 4}
            function AutoDrive:GetAvailableDestinations() return list end
            list = {[1] = {name = "Silo", x = sx, z = sz}}
            local onlySilo = select(2, GuidanceVehicle.markerFor(plan3, course3))
            list[2] = {name = "Barn gate", x = gx, z = gz}
            local edge = select(2, GuidanceVehicle.markerFor(plan3, course3))
            list[3] = {name = "Field " .. number .. "b WAIT", x = nx, z = nz}
            list[4] = {name = "Field 1" .. number .. " WAIT", x = sx, z = sz + 1}
            local named = select(2, GuidanceVehicle.markerFor(plan3, course3))
            AutoDrive = nil
            r.markerChoice = onlySilo == "Silo" and edge == "Barn gate" and named == "Field " .. number .. "b WAIT"
            MARKER_INFO = string.format("only a silo by the start: %s; with a marker at the field's edge: %s; with one named after the field: %s",
                tostring(onlySilo), tostring(edge), tostring(named))
        end
        AWAY_INFO = string.format("at its field %s; 600 m off: at it %s, %.0f m from it; Go there: AutoDrive to marker %s, CP on %s",
            tostring(atBefore), tostring(atAfter), distAway or -1, tostring(drove3), tostring(sm3.helper))
        r.goAutoDrive = onWay and starts == 1 and helperAfter == false and marker == "Field 6 gate" and onWay2 and starts2 == 1
        GO_INFO = string.format("implement off, raised and folded first, then to the course's marker with the helper button on %s; started %d time(s) on arrival, button back off %s; without the hand-off started %d time(s)",
            tostring(onWay), starts, tostring(helperAfter == false), starts2)
        -- a start-only setting's value goes over as what it is (a name, on/off, a number)
        local buf = {}
        local realW = {streamWriteUInt8, streamWriteBool, streamWriteString, streamWriteFloat32}
        local realR = {streamReadUInt8, streamReadBool, streamReadString, streamReadFloat32}
        local function w(_, v) buf[#buf + 1] = v end
        local function rd() return table.remove(buf, 1) end
        streamWriteUInt8, streamWriteBool, streamWriteString, streamWriteFloat32 = w, w, w, w
        streamReadUInt8, streamReadBool, streamReadString, streamReadFloat32 = rd, rd, rd, rd
        NetworkUtil = NetworkUtil or {}
        local realNW, realNR = NetworkUtil.writeNodeObject, NetworkUtil.readNodeObject
        NetworkUtil.writeNodeObject = function() end
        NetworkUtil.readNodeObject = function() return nil end
        local okTypes = true
        for _, value in ipairs({"Field 6 gate", true, false, 3}) do
            buf = {}
            local e = GuidanceSettingEvent.new(v, "x", value)
            e:writeStream(1)
            local e2 = GuidanceSettingEvent.emptyNew()
            e2.run = function() end
            e2:readStream(1)
            if e2.value ~= value then okTypes = false end
        end
        streamWriteUInt8, streamWriteBool, streamWriteString, streamWriteFloat32 = realW[1], realW[2], realW[3], realW[4]
        streamReadUInt8, streamReadBool, streamReadString, streamReadFloat32 = realR[1], realR[2], realR[3], realR[4]
        NetworkUtil.writeNodeObject, NetworkUtil.readNodeObject = realNW, realNR
        r.settingTypes = okTypes
        g_currentMission.vehicleSystem = {vehicles = {v}}
    end

    -- the grass chain: a baler follows the rake's course (its passes are where the windrows lie)
    local rakeT = makeVehicle(flat[1] + 30, flat[2] + 30, 0, "Rake tractor")
    rakeT.children = {rakeT, {spec_windrower = {}}}
    local rs = rakeT:getGuidanceSettings()
    rs.autoWidth, rs.workWidth, rs.autoRadius, rs.turnRadius = false, 8, false, 6
    assert(rakeT:guidanceGenerate())
    local baler = makeVehicle(flat[1] + 40, flat[2] + 30, 0, "Baler tractor")
    baler.children = {baler, {spec_baler = {}, spec_pickup = {}}}
    local bs = baler:getGuidanceSettings()
    bs.autoWidth, bs.workWidth, bs.autoRadius, bs.turnRadius = false, 2.5, false, 9
    GuidanceMap = GuidanceMap or {}
    GuidanceMap.getFarmVehicles = function() return {rakeT, baler, v} end
    r.windrowFound = GuidanceVehicle.hasPickup(baler) and not GuidanceVehicle.hasPickup(rakeT)
        and GuidanceVehicle.windrowSource(baler) == rakeT and GuidanceVehicle.windrowSource(rakeT) == nil
    local ok = baler:guidanceFollowCourseOf(rakeT)
    local rc, bc = rakeT:getGuidanceCourse(), baler:getGuidanceCourse()
    local rRows, bRows = GuidanceCourseGenerator.rowsOf(rc.waypoints), GuidanceCourseGenerator.rowsOf(bc.waypoints)
    -- every baler row on a rake row (either way round), its ends within 1 m
    local worst = 0
    for _, b in ipairs(bRows) do
        local best = math.huge
        for _, a in ipairs(rRows) do
            local d1 = math.max(dist(a.a, b.a), dist(a.b, b.b))
            local d2 = math.max(dist(a.a, b.b), dist(a.b, b.a))
            best = math.min(best, d1, d2)
        end
        worst = math.max(worst, best)
    end
    WINDROW_INFO = string.format("%d rows each (%d), headlands %d / %d, turn radius %.0f / %.0f m, worst row end %.2f m",
        #bRows, #rRows, bc.stats.headlands, rc.stats.headlands, baler:getGuidancePlan().turnRadius,
        rakeT:getGuidancePlan().turnRadius, worst)
    r.windrowFollow = ok and #bRows == #rRows and #bRows > 3 and worst < 1 and bc.stats.headlands == rc.stats.headlands
        and baler:getGuidancePlan().turnRadius == 9 and baler:guidanceFollowsCourseOf(rakeT)
    return r
end
"""


def main():
    i3d = sys.argv[1]
    field = f"field{sys.argv[2] if len(sys.argv) > 2 else 9}"
    fields = fp.read_fields(i3d)
    flat = [c for p in fields[field] for c in p]
    lua = smoke_test.fresh_lua(fields, field)
    lua.execute(helpers_test.LUA)
    lua.execute(LUA)
    r = lua.globals().checkSupport(lua.table_from(flat))
    ok = True
    print(lua.globals().WINDROW_INFO)
    print(lua.globals().PREPARE_INFO)
    print(lua.globals().RAIN_INFO)
    print(lua.globals().EDGE_INFO)
    print(lua.globals().GO_INFO)
    print(lua.globals().AWAY_INFO)
    print(lua.globals().LIVE_INFO)
    print(lua.globals().TAKE_INFO)
    print(lua.globals().NEAREST_INFO)
    print(lua.globals().MARKER_INFO)
    print(lua.globals().FUEL_INFO)
    print(lua.globals().AD_TRAILER_INFO)
    print(lua.globals().RESUME_INFO)
    print(lua.globals().HELPER_SIZE_INFO)
    print(lua.globals().TRAILER_RADIUS_INFO)
    print(lua.globals().TURN_INFO)
    print(lua.globals().CHEAP_INFO)
    print(lua.globals().AD_BRIDGE_INFO)
    print(lua.globals().TANK_INFO)
    print(lua.globals().CUT_INFO)
    print(lua.globals().BACKUP_INFO)
    print(lua.globals().START_AFTER_INFO)
    print(lua.globals().AD_RESUME_INFO)
    print(lua.globals().SERVICE_INFO)
    print(lua.globals().CHAIN_INFO)
    print(lua.globals().CONTRACT_INFO)
    for name in ("movedThere", "neighbours", "streamed", "dropped", "newCourse", "report", "written", "overlay",
                 "windrowFound", "windrowFollow", "startSetting", "prepareWait", "prepareUnfolded", "prepareGiveUp", "rainWait", "edgeRefill", "goAutoDrive", "awayGo", "markerChoice", "settingTypes", "liveSettings", "saveNil", "lineHeight", "reportAutoDrive", "takeOver", "nearestCrop", "worldFlags", "fuelSave", "adTrailer", "resumeHelper", "helperSize", "trailerRadius", "turnAway", "planCheap", "adBridge", "tankAware", "serviceTrips", "handOver", "contracts", "adResume", "startAfter", "backUp", "cutNotCrop"):
        good = bool(r[name])
        ok = ok and good
        print(f"{name}: {'OK' if good else 'FAILED'}")
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

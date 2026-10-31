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
        v.getGuidanceHelperKind = function() return "unload" end
        v.getIsGuidanceActive = function() return true end
        GuidanceVehicle.saveToXMLFile(v, xml, "k")
        local savedAs = store["k#active"] == false and store["k#helper"] == "unload"
        local startedHelper, startedCourse
        v.guidanceStartHelper = function(_, kind, values) startedHelper = {kind = kind, values = values}; return true end
        v.guidanceStart = function() startedCourse = true end
        v.getIsHelperDriving = function() return false end
        local spec = v.spec_guidance
        spec.settings.unloadMode, spec.settings.unloadFull = 2, 90
        spec.resumeHelper, spec.resumeAfterLoad = "unload", GuidanceVehicle.RESUME_DELAY
        GuidanceVehicle.updateResume(v, spec, 1)
        v.getGuidanceHelperKind, v.getIsGuidanceActive, v.guidanceStartHelper, v.guidanceStart, v.getIsHelperDriving =
            oldKind, oldActive, oldStartHelper, oldStart, oldDriving
        spec.settings.unloadMode, spec.settings.unloadFull = 0, 97
        r.resumeHelper = savedAs and startedHelper ~= nil and startedHelper.kind == "unload" and not startedCourse
            and startedHelper.values.unloadMode == 2 and math.abs(startedHelper.values.fullLevel - 0.9) < 1e-6
        RESUME_INFO = string.format("saved as the unloader %s; after loading: unloader started %s, its course %s",
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
        local phase = "unloadWait"
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
        phase = "unloadFollow"
        for _ = 1, 30 do GuidanceVehicle.saveFuel(v, spec, 1000, 0) end
        local followOn = motor.on
        spec.helperDriver, spec.engineOff, spec.idleTime = nil, false, 0
        v.startMotor, v.stopMotor, v.getMotorState, v.getGuidanceHelperPhase = oldStart, oldStop, oldState, oldPhase
        r.fuelSave = onAt9 and offAt11 and blocked and onToMove and followOn and motor.stops == 1
        FUEL_INFO = string.format("waiting: on after 9 s %s, off after 11 s %s, game can't start it %s, on to move %s; "
            .. "standing under the pipe 30 s: still on %s", tostring(onAt9), tostring(offAt11), tostring(blocked),
            tostring(onToMove), tostring(followOn))
    end

    -- the unloader at work takes a new Unload at / Leave when full / Crop on the way at once; set to drive straight
    -- through the crop it looks for no way round it
    do
        local oldKind, oldJob = v.getGuidanceHelperKind, v.getJob
        local job = {unloadX = 0, unloadZ = 0, unloadMode = 0, fullLevel = 0.97, avoidCrop = true}
        local drv = {leaveLevel = 0.97}
        v.getGuidanceHelperKind = function() return "unload" end
        v.getJob = function() return job end
        local oldDriver = v.spec_guidance.driver
        v.spec_guidance.driver = drv
        local realSend = GuidanceSettingEvent.sendEvent
        GuidanceSettingEvent.sendEvent = function() end
        v:guidanceApplySettings({unloadMode = 0, unloadX = 512.5, unloadZ = -80})
        v:guidanceApplySettings({unloadFull = 85})
        v:guidanceApplySettings({avoidCrop = false})
        GuidanceSettingEvent.sendEvent = realSend
        v.getGuidanceHelperKind, v.getJob, v.spec_guidance.driver = oldKind, oldJob, oldDriver
        local live = job.unloadX == 512.5 and job.unloadZ == -80 and math.abs(job.fullLevel - 0.85) < 1e-6
            and math.abs(drv.leaveLevel - 0.85) < 1e-6 and job.avoidCrop == false
        -- planning a way with crop everywhere: round it, or (set so) not
        local finds = 0
        local realFind = GuidancePathfinder.find
        GuidancePathfinder.find = function() finds = finds + 1 end
        local node = {x = 0, z = 0, h = 0}
        local truck = {rootNode = node, getAIDirectionNode = function() return node end}
        local probe = {fruitIndexes = {1}, hasFruit = function() return true end}
        local function plan(avoid)
            local d = setmetatable({vehicle = truck, info = {turnRadius = 6}, course = {plan = {workWidth = 3}},
                                    area = {field = {}}, probe = probe, job = {avoidCrop = avoid}},
                {__index = GuidanceHelperDriver})
            d:planTo(80, 0, 0, 0)
        end
        plan(true)
        local roundFinds = finds
        plan(false)
        GuidancePathfinder.find = realFind
        r.unloaderLive = live and roundFinds == 1 and finds == 1
        LIVE_UNLOAD_INFO = string.format("taken at once: %s; through crop: looked for a way round %d time(s) when set to go round, %d more when set to drive through",
            tostring(live), roundFinds, finds - roundFinds)
    end

    -- an unloader waiting on a combine's line (where it was started): the combine, held up by it below its call
    -- level, calls it now (else both wait for ever); not held up by it, not yet
    do
        local truck = {rootNode = {x = 0, z = 0, h = 0}}
        local combineNode = {x = 0, z = -30, h = math.pi / 2}
        local cd = {course = {plan = {callUnloaderAt = 80}}}
        local combine = {rootNode = combineNode, spec_combine = {fillUnitIndex = 1}, spec_pipe = {},
                         spec_guidance = {driver = cd}}
        function combine:getChildVehicles() return {self} end
        function combine:getAIDirectionNode() return combineNode end
        function combine:getFillUnitCapacity() return 1000 end
        function combine:getFillUnitFillLevel() return 690 end
        local oldVs = g_currentMission.vehicleSystem
        g_currentMission.vehicleSystem = {vehicles = {truck, combine}}
        local u = setmetatable({vehicle = truck}, {__index = GuidanceUnloadDriver})
        local notYet = u:pickCombine() == nil
        cd.blockedBy = truck
        local called = u:pickCombine() == combine
        g_currentMission.vehicleSystem = oldVs
        r.unloaderInWay = notYet and called
        IN_WAY_INFO = string.format("combine 69%% full (calls at 80): not called %s; held up by the waiting unloader: called %s",
            tostring(notYet), tostring(called))
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

    -- the unloader's offsets: its place under the pipe 1 m further out from the combine (whichever side the pipe is
    -- on) and 2 m further forward
    do
        local cNode = {x = 0, z = 0, h = 0}
        local combine = {rootNode = cNode, spec_combine = {fillUnitIndex = 1, isBufferCombine = false}, spec_pipe = {currentState = 1}}
        function combine:getChildVehicles() return {self} end
        function combine:getAIDirectionNode() return cNode end
        function combine:getFillUnitCapacity() return 1000 end
        local function place(side, along, pipeLeft)
            local u = setmetatable({vehicle = {}, job = {unloadSide = side, unloadAlong = along}, pipeLeft = pipeLeft,
                                    pipeAhead = -1}, {__index = GuidanceUnloadDriver})
            local x, z = u:placeUnderPipe(combine, nil)
            return x, z
        end
        local okSides = true
        for _, pl in ipairs({7.5, -7.5}) do
            local x0, z0 = place(0, 0, pl)
            local x1, z1 = place(1, 2, pl)
            local lx, lz = math.sin(0), -math.cos(0)
            local out = ((x1 - x0) * lx + (z1 - z0) * lz) * (pl > 0 and 1 or -1)
            local fwd = (x1 - x0) * 1 + (z1 - z0) * 0
            if math.abs(out - 1) > 1e-6 or math.abs(fwd - 2) > 1e-6 then okSides = false end
        end
        r.unloadOffsets = okSides
        OFFSET_INFO = string.format("place moved 1 m out from the combine and 2 m forward, pipe left and right: %s", tostring(okSides))
    end

    -- a sugarcane harvester with a short pipe (3 m out), a 3.4 m body and a 5.5 m header: the truck's place keeps its
    -- side 0.6 m clear of the body (before 1.0.5.7 its cab drove into the harvester), not of the header (1.0.5.7 to
    -- 1.0.5.9: so far out the pipe didn't reach the trailer); a -1 m side offset doesn't bring it closer
    do
        local cNode = {x = 0, z = 0, h = 0}
        local header = {size = {width = 5.5}}
        local combine = {rootNode = cNode, size = {width = 3.4}, spec_combine = {fillUnitIndex = 1, isBufferCombine = false},
                         spec_pipe = {currentState = 1}}
        function combine:getChildVehicles() return {self, header} end
        function combine:getAIDirectionNode() return cNode end
        function combine:getFillUnitCapacity() return 1000 end
        local truck = {size = {width = 2.55}}
        function truck:getChildVehicles() return {self} end
        local u = setmetatable({vehicle = truck, job = {unloadSide = -1, unloadAlong = 0}, pipeLeft = 3, pipeAhead = -1},
            {__index = GuidanceUnloadDriver})
        local px, pz = u:placeUnderPipe(combine, nil)
        local lateral = -pz -- (left of heading 0 is -z here)
        local clear = lateral - 3.4 / 2 - 2.55 / 2
        -- clear of its body (3.4 m), not pushed out by the header (5.5 m): the pipe still reaches the trailer
        r.unloaderClear = clear > 0.59 and clear < 0.61
        CLEAR_INFO = string.format("short pipe 3 m out, 3.4 m body, 5.5 m header, side offset -1: place %.2f m out, our side %.2f m clear of its body", lateral, clear)
    end

    -- Pipe side: Right on a combine whose pipe is measured on the left: the place goes to its right; Auto: left. And a
    -- way planned through the combine it serves goes round it (it drove into the harvester)
    do
        local cNode = {x = 0, z = 0, h = 0}
        local combine = {rootNode = cNode, size = {width = 3.4, length = 12}, spec_combine = {fillUnitIndex = 1, isBufferCombine = false},
                         spec_pipe = {currentState = 1}}
        function combine:getChildVehicles() return {self} end
        function combine:getAIDirectionNode() return cNode end
        function combine:getFillUnitCapacity() return 1000 end
        local truck = {size = {width = 2.55}}
        function truck:getChildVehicles() return {self} end
        local function sideOf(forced)
            local u = setmetatable({vehicle = truck, job = {unloadPipeSide = forced}, pipeLeft = 6, pipeAhead = -1},
                {__index = GuidanceUnloadDriver})
            local _, pz = u:placeUnderPipe(combine, nil)
            return -pz > 0 and "left" or "right" -- (left of heading 0 is -z here)
        end
        local autoSide, rightSide, leftSide = sideOf(0), sideOf(2), sideOf(1)
        -- the footprint: in the combine's way (just ahead of its middle) blocked, well out to the side free
        local u = setmetatable({vehicle = truck, combine = combine, job = {avoidCrop = true}}, {__index = GuidanceUnloadDriver})
        local probe = u:wayProbe()
        local blocksBody = probe ~= nil and probe:hasFruit(3, 0, 2) and probe:hasFruit(-5, 1, 2)
        local freeBeside = probe ~= nil and not probe:hasFruit(0, 6, 2) and not probe:hasFruit(20, 0, 2)
        r.pipeSideAndRound = autoSide == "left" and rightSide == "right" and leftSide == "left" and blocksBody and freeBeside
        SIDE_INFO = string.format("pipe measured left: Auto %s, Right %s, Left %s; ways keep out of the combine %s, free beside it %s",
            autoSide, rightSide, leftSide, tostring(blocksBody), tostring(freeBeside))
    end

    -- the truck at its place but crosswise to a standing combine (its way in looped past the place): it doesn't count
    -- that as lined up, it takes a new way in (before 1.0.5.9 it stood there "unloading" for ever)
    do
        local cNode = {x = 0, z = 0, h = 0}
        local combine = {rootNode = cNode, size = {width = 3.4, length = 12}, spec_combine = {fillUnitIndex = 1, isBufferCombine = false},
                         spec_pipe = {currentState = 1}}
        function combine:getChildVehicles() return {self} end
        function combine:getAIDirectionNode() return cNode end
        function combine:getFillUnitCapacity() return 1000 end
        function combine:getFillUnitFillLevel() return 900 end
        function combine:getLastSpeed() return 0 end
        local tNode = {x = 4, z = -6, h = math.pi / 2}
        local truck = {rootNode = tNode, size = {width = 2.55}}
        function truck:getChildVehicles() return {self} end
        function truck:getAIDirectionNode() return tNode end
        function truck:getLastSpeed() return 0 end
        local u = setmetatable({vehicle = truck, combine = combine, job = {}, pipeLeft = 6, pipeAhead = -1, state = "follow",
                                timer = 0, stuckTimer = 0, info = {turnRadius = 6}, course = {plan = {workWidth = 3}}},
            {__index = GuidanceUnloadDriver})
        u:follow(100, nil)
        local ok, text = pcall(u.describe, u)
        -- lined up and pointing its way, but 8.4 m to the side of its place (the pipe was on the combine's other side):
        -- a new way in too (before 1.0.6.2 it stood there with the pipe out and nothing flowing)
        local sNode = {x = 4, z = 2.4, h = 0}
        local truck2 = {rootNode = sNode, size = {width = 2.55}}
        function truck2:getChildVehicles() return {self} end
        function truck2:getAIDirectionNode() return sNode end
        function truck2:getLastSpeed() return 0 end
        local u2 = setmetatable({vehicle = truck2, combine = combine, job = {}, pipeLeft = 6, pipeAhead = -1, state = "follow",
                                 timer = 0, stuckTimer = 0, info = {turnRadius = 6}, course = {plan = {workWidth = 3}}},
            {__index = GuidanceUnloadDriver})
        u2:follow(100, nil)
        local besideOk = u2.state == "approach"
        -- at its place and pointing the combine's way, but its trailer folded 57 deg against it (it started beside the
        -- combine like that): out straight first (1.0.6.7; before, a new way in, blocked by the combine at once, time
        -- after time), straight on where that is clear; after 3 of those a new way in; the trailer straight: it stays
        local function atPlace(trailerH, x, z, straightens, direct)
            local n = {x = x or 3, z = z or -6, h = 0}
            local t = {rootNode = {x = n.x - 8, z = n.z, h = trailerH}, spec_trailer = {}}
            local tr = {rootNode = n, size = {width = 2.55}}
            function tr:getChildVehicles() return {self, t} end
            function tr:getAIDirectionNode() return n end
            function tr:getLastSpeed() return 0 end
            local uu = setmetatable({vehicle = tr, combine = combine, job = {}, pipeLeft = 6, pipeAhead = -1, state = "follow",
                                     timer = 0, stuckTimer = 0, info = {turnRadius = 6}, course = {plan = {workWidth = 3}},
                                     straightens = straightens},
                {__index = GuidanceUnloadDriver})
            if direct then uu:startStraighten() else uu:follow(100, nil) end
            local pts = uu.follower and uu.follower.points
            local last = pts and pts[#pts]
            return uu.state, last
        end
        local folded, ahead = atPlace(1.0)
        local straight = atPlace(0)
        local spent = atPlace(1.0, 3, -6, 3)
        -- right behind the combine, folded (off its place: a new way in, which straightens first): straight on would
        -- hit it, it turns off away from it (to -z)
        local behindState, away = atPlace(1.0, -10, -2, nil, true)
        local aheadOk = ahead ~= nil and math.abs(ahead.z + 6) < 0.01 and ahead.x > 3 + 20
        local awayOk = away ~= nil and away.z < -2 - 8 and away.x > -10 + 15
        FOLD_INFO = string.format("at its place, trailer folded 57 deg: %s straight on to x %.0f (want straighten); right behind the combine: %s, to z %.1f (want away from it, -z); after 3 of those: %s (want approach); trailer straight: %s (want follow)",
            folded, ahead and ahead.x or 0, behindState, away and away.z or 0, spent, straight)
        besideOk = besideOk and folded == "straighten" and aheadOk and behindState == "straighten" and awayOk
            and spent == "approach" and straight == "follow"
        LATERAL_INFO = string.format("lined up but 8.4 m to the side of its place, combine standing: %s (want approach)", tostring(u2.state))
        r.crosswise = u.state == "approach" and besideOk and ok and type(text) == "string" and text:find("deg off", 1, true) ~= nil
        DESCRIBE_INFO = ok and text or tostring(text)
        CROSSWISE_INFO = string.format("at its place crosswise to a standing combine: %s (want approach: a new way in)", tostring(u.state))
    end

    -- a trailer whose fill point (a mod's) is 8.4 m to the side, off the trailer: its middle is used (it lined the bad
    -- point up under the pipe, the trailer stood 8 m away); one on the trailer is kept
    do
        local trailer = {rootNode = {x = 0, z = 0}, size = {width = 2.6, length = 12, lengthOffset = 0}}
        local bad = {lx = -8.4, lz = 0}
        local good = {lx = 0.3, lz = -2}
        local usedBad = GuidanceUnloadDriver.checkedFillNode(trailer, bad)
        local usedGood = GuidanceUnloadDriver.checkedFillNode(trailer, good)
        r.fillPoint = usedBad == trailer.rootNode and usedGood == good
        FILL_INFO = string.format("fill point 8.4 m off the trailer: its middle used %s; one on it kept %s",
            tostring(usedBad == trailer.rootNode), tostring(usedGood == good))
    end

    -- turning back (after unloading) with standing crop on one side: it turns the other way, not into the crop
    do
        local node = {x = 0, z = 0, h = 0}
        local truck = {rootNode = node}
        function truck:getAIDirectionNode() return node end
        local probe = {fruitIndexes = {1}}
        function probe:hasFruit(x, z, size) return z - (size or 2) / 2 < -4 end -- crop from z = -4 on
        local d = setmetatable({vehicle = truck, info = {turnRadius = 8}, turnRadius = 8, course = {plan = {workWidth = 3}},
                                probe = probe, job = {avoidCrop = true}}, {__index = GuidanceHelperDriver})
        d:planTo(-40, 0, math.pi, 6)
        local minZ = math.huge
        for _, pt in ipairs(d.follower.points) do minZ = math.min(minZ, pt.z) end
        r.turnAway = minZ > -1
        TURN_INFO = string.format("U-turn with crop from z = -4 on: the way goes down to z = %.1f (want > -1: turned the other way)", minZ)
    end

    -- full, leaving the combine it served: that combine (stopped, so "parked" for everyone else) still counts in front
    -- of us and its footprint stays in our ways (before 1.0.6.4 the truck drove into it on its way back)
    do
        local cNode = {x = 10, z = 0, h = 0}
        local combine = {rootNode = cNode, size = {width = 3.4, length = 12}}
        function combine:getChildVehicles() return {self} end
        function combine:getAIDirectionNode() return cNode end
        local u = setmetatable({vehicle = {size = {width = 2.55}}, combine = combine, job = {}}, {__index = GuidanceUnloadDriver})
        function u.vehicle:getChildVehicles() return {self} end
        u:setServing(nil)
        local ahead = u:combineAhead(0, 0, 0)
        local clearBeside = not u:combineAhead(0, 6, 0)
        r.leftCombine = u.combine == nil and u.avoidCombine == combine and ahead and clearBeside
        LEFT_INFO = string.format("after leaving it: still avoided %s, right ahead counts %s, beside it free %s",
            tostring(u.avoidCombine == combine), tostring(ahead), tostring(clearBeside))
    end

    -- a plan asks the game about the crop once per spot (it asked thousands of times and froze the server for 0.3 s);
    -- and a way that turns off past the combine's corner is free to drive although the combine is straight ahead
    do
        local calls = 0
        local probe = {fruitIndexes = {1}}
        function probe:hasFruit(x, z, size) calls = calls + 1; return z < -4 end
        local node = {x = 0, z = 0, h = 0}
        local truck = {rootNode = node}
        function truck:getAIDirectionNode() return node end
        local d = setmetatable({vehicle = truck, info = {turnRadius = 8}, turnRadius = 8, course = {plan = {workWidth = 3}},
                                probe = probe, job = {avoidCrop = true}}, {__index = GuidanceHelperDriver})
        d:planTo(-40, 0, math.pi, 6)
        local planCalls = calls
        -- a combine 10 m straight ahead; our way turns off to the left at once
        local cNode = {x = 12, z = 0, h = 0}
        local combine = {rootNode = cNode, size = {width = 3.4, length = 12}}
        function combine:getChildVehicles() return {self} end
        function combine:getAIDirectionNode() return cNode end
        local u = setmetatable({vehicle = {size = {width = 2.55}}, combine = combine, job = {}}, {__index = GuidanceUnloadDriver})
        function u.vehicle:getChildVehicles() return {self} end
        local turning = GuidancePathFollower.new({{x = 0, z = 0, t = "C"}, {x = 2, z = 4, t = "C"}, {x = 3, z = 8, t = "C"},
                                                  {x = 4, z = 12, t = "C"}, {x = 5, z = 16, t = "C"}})
        local straightAhead = u:combineAhead(4, 0, 0)
        local alongTurn = u:combineAhead(0, 0, 0, turning)
        r.planCheap = planCalls < 160 and straightAhead and not alongTurn
        CHEAP_INFO = string.format("one U-turn plan asked the crop %d times (want < 160; 219 before 1.0.6.6); combine straight ahead counts %s, a way turning off past it is free %s",
            planCalls, tostring(straightAhead), tostring(not alongTurn))
    end

    -- Combine picked: the unloader serves only that one (not a fuller one), wherever it works
    do
        local function combineAt(x, key, level)
            local node = {x = x, z = 0, h = 0}
            local c = {rootNode = node, uniqueId = key, spec_combine = {fillUnitIndex = 1, isBufferCombine = false}, spec_pipe = {}}
            function c:getChildVehicles() return {self} end
            function c:getAIDirectionNode() return node end
            function c:getFillUnitCapacity() return 1000 end
            function c:getFillUnitFillLevel() return level end
            return c
        end
        local a, b = combineAt(10, "vehicleA", 950), combineAt(900, "vehicleB", 850)
        local truck = {rootNode = {x = 0, z = 0, h = 0}}
        local oldVs = g_currentMission.vehicleSystem
        g_currentMission.vehicleSystem = {vehicles = {truck, a, b}}
        local any = setmetatable({vehicle = truck, job = {unloadCombine = ""}}, {__index = GuidanceUnloadDriver})
        local picked = setmetatable({vehicle = truck, job = {unloadCombine = "vehicleB"},
                                     field = {{x = -50, y = -50}, {x = 50, y = -50}, {x = 50, y = 50}, {x = -50, y = 50}}},
            {__index = GuidanceUnloadDriver})
        local anyPick, pickedPick = any:pickCombine(), picked:pickCombine()
        local found = GuidanceVehicle.vehicleByKey("vehicleB") == b
        g_currentMission.vehicleSystem = oldVs
        r.pickCombine = anyPick == a and pickedPick == b and found
        PICK_INFO = string.format("any: the fuller one %s; picked B (off our field): B %s; found by its key %s",
            tostring(anyPick == a), tostring(pickedPick == b), tostring(found))
    end
    -- the unloader picked for a combine on another field: AutoDrive to that field's marker (named after it), and on
    -- arrival it starts as the unloader, not a course
    do
        local spec = v.spec_guidance
        local cNode = {x = 5000, z = 5000, h = 0}
        local combine = {rootNode = cNode, uniqueId = "vehicleFar"}
        function combine:getGuidanceCourse() return {outline = {{x = 4900, z = 4900}, {x = 5100, z = 4900}, {x = 5100, z = 5100}, {x = 4900, z = 5100}}} end
        function combine:getGuidancePlan() return {fieldId = 77} end
        local oldVs = g_currentMission.vehicleSystem
        g_currentMission.vehicleSystem = {vehicles = {v, combine}}
        local sm = {active = false, helper = false}
        function sm:isActive() return self.active end
        function sm:setMode() end
        function sm:setStartHelper(on) self.helper = on end
        function sm:getStartHelper() return self.helper end
        function sm:setUsedHelper() end
        v.ad = {stateModule = sm}
        local drove
        AutoDrive = {MODE_DRIVETO = 4}
        function AutoDrive:GetAvailableDestinations()
            return {[3] = {name = "Shop", x = 4850, z = 5000}, [8] = {name = "Field 77 WAIT", x = 4898, z = 5050}}
        end
        function AutoDrive:StartDriving(_, a) drove = a; sm.active = true end
        ADStateModule = {HELPER_CP = 1}
        local started = {}
        local oldStartHelper, oldDriving = v.guidanceStartHelper, v.getIsHelperDriving
        v.guidanceStartHelper = function(_, kind) started[#started + 1] = kind; return true end
        v.getIsHelperDriving = function() return #started > 0 end
        spec.settings.unloadCombine = "vehicleFar"
        local went = v:guidanceGoUnloader()
        for _ = 1, 4 do GuidanceVehicle.updateQueue(v); g_time = (g_time or 0) + 100 end
        sm.active = false
        for _ = 1, 3 do GuidanceVehicle.updateQueue(v); g_time = (g_time or 0) + 100 end
        AutoDrive, ADStateModule = nil, nil
        v.ad, v.guidanceStartHelper, v.getIsHelperDriving = nil, oldStartHelper, oldDriving
        spec.settings.unloadCombine = ""
        g_currentMission.vehicleSystem = oldVs
        r.goUnloader = went and drove == 8 and #started == 1 and started[1] == "unload"
        GO_UNLOADER_INFO = string.format("to the far combine's field: AutoDrive to marker %s (want 8, Field 77 WAIT), started on arrival as %s",
            tostring(drove), tostring(started[1]))
    end

    -- a combine with no driver of ours at work (stopped, or it stopped itself full): the unloader opens its pipe, starts
    -- the flow into its trailer once under it, and folds the pipe again when it leaves (before 1.0.5.6: nothing came out)
    do
        Dischargeable = Dischargeable or {DISCHARGE_STATE_OFF = 0, DISCHARGE_STATE_OBJECT = 1}
        local h = {spec_pipe = {numStates = 2, currentState = 1, targetState = 1}, discharge = 0, spec_combine = {fillUnitIndex = 1}}
        function h:setPipeState(st) self.spec_pipe.targetState = st; self.spec_pipe.currentState = st end
        function h:getIsPipeStateChangeAllowed() return true end
        function h:getDischargeState() return self.discharge end
        function h:setDischargeState(st) self.discharge = st end
        function h:getCurrentDischargeNode() return {} end
        function h:getCanDischargeToObject() return self.spec_pipe.currentState == 2 end
        function h:getChildVehicles() return {self} end
        local u = setmetatable({vehicle = {}}, {__index = GuidanceUnloadDriver})
        u:runCombinePipe(h, false)
        local opened = h.spec_pipe.currentState == 2 and h.discharge == 0
        u:runCombinePipe(h, true)
        local flowing = h.discharge == Dischargeable.DISCHARGE_STATE_OBJECT and h.spec_pipe.automaticDischarge == true
        u:setServing(nil)
        local folded = h.spec_pipe.currentState == 1 and h.discharge == Dischargeable.DISCHARGE_STATE_OFF
        r.stoppedCombine = opened and flowing and folded
        STOPPED_COMBINE_INFO = string.format("stopped combine: pipe opened %s, flow started under it %s, folded when left %s",
            tostring(opened), tostring(flowing), tostring(folded))
    end

    -- Start at: Nearest with a harvester standing on a pass already harvested (no crop on it, crop everywhere else):
    -- it starts on the nearest pass with crop; without a harvester, or with no crop on the field, the nearest as before
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
        r.nearestCrop = plainIx == best and cropIx ~= best and off >= 3 and away < 60 and noCropIx == best
        NEAREST_INFO = string.format("nearest %d (on stretch %d, %.0f m), harvester: %d, %.1f m off that pass, %.0f m away; no crop: %d",
            plainIx, best, bestLen, cropIx, off, away, noCropIx)
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
    print(lua.globals().LIVE_UNLOAD_INFO)
    print(lua.globals().IN_WAY_INFO)
    print(lua.globals().AD_TRAILER_INFO)
    print(lua.globals().RESUME_INFO)
    print(lua.globals().HELPER_SIZE_INFO)
    print(lua.globals().TRAILER_RADIUS_INFO)
    print(lua.globals().OFFSET_INFO)
    print(lua.globals().STOPPED_COMBINE_INFO)
    print(lua.globals().CLEAR_INFO)
    print(lua.globals().SIDE_INFO)
    print(lua.globals().CROSSWISE_INFO)
    print(lua.globals().LATERAL_INFO)
    print(lua.globals().FOLD_INFO)
    print(lua.globals().FILL_INFO)
    print(lua.globals().TURN_INFO)
    print(lua.globals().LEFT_INFO)
    print(lua.globals().CHEAP_INFO)
    print(lua.globals().PICK_INFO)
    print(lua.globals().GO_UNLOADER_INFO)
    print("report line: unloader: " + str(lua.globals().DESCRIBE_INFO))
    for name in ("movedThere", "neighbours", "streamed", "dropped", "newCourse", "report", "written", "overlay",
                 "windrowFound", "windrowFollow", "startSetting", "prepareWait", "prepareUnfolded", "prepareGiveUp", "rainWait", "edgeRefill", "goAutoDrive", "awayGo", "markerChoice", "settingTypes", "liveSettings", "saveNil", "lineHeight", "reportAutoDrive", "takeOver", "nearestCrop", "worldFlags", "fuelSave", "unloaderLive", "unloaderInWay", "adTrailer", "resumeHelper", "helperSize", "trailerRadius", "unloadOffsets", "stoppedCombine", "unloaderClear", "pipeSideAndRound", "crosswise", "pickCombine", "goUnloader", "fillPoint", "turnAway", "leftCombine", "planCheap"):
        good = bool(r[name])
        ok = ok and good
        print(f"{name}: {'OK' if good else 'FAILED'}")
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

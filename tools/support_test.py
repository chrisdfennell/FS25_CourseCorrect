"""Checks offline the editor's moved points, the problem report and the debug overlay:

- a moved point is where the editor put it, its neighbours along the course follow (less further away), points
  further than the reach stay; the moves go over the network and into the savegame with the plan; any other change of
  the course drops them, a new course starts without them;
- the problem report has the version, the vehicle, its settings and the mod's last log lines, and is written through
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

    -- the problem report
    Guidance.info("a test line for the report")
    local text = GuidanceDebug.reportText(v)
    r.report = text:find(Guidance.VERSION, 1, true) ~= nil and text:find("Test tractor", 1, true) ~= nil
        and text:find("workWidth =", 1, true) ~= nil and text:find("a test line for the report", 1, true) ~= nil
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

    -- an implement unfolding at the start: the driver waits until the game says it can go (no speed until then),
    -- measures the vehicle again then; one that never gets ready (and isn't getting ready) stops with a message
    local function prepareRun(readyAfter)
        local veh = makeVehicle(flat[1] + 30, flat[2] + 30, 0, "Folding tractor")
        g_currentMission.vehicleSystem = {vehicles = {veh}}
        assert(veh:guidanceGenerate())
        local t = 0
        function veh:getIsAIReadyToDrive() return readyAfter ~= nil and t >= readyAfter, self end
        function veh:getIsAIPreparingToDrive() return readyAfter ~= nil end
        function veh:raiseAIEvent() end
        function veh:raiseStateChange() end
        local measured = 0
        local realGet = GuidanceVehicleInfo.get
        GuidanceVehicleInfo.get = function(...) measured = measured + 1 return realGet(...) end
        local d = GuidanceFieldworkDriver.new(veh, veh:getGuidanceCourse(), 1)
        local before = measured
        STOP_MESSAGE = nil
        local movedEarly, state = false, nil
        for _ = 1, 400 do
            local _, _, _, speed = d:getDriveData(100)
            if readyAfter and t < readyAfter and (speed or 0) > 0 then movedEarly = true end
            t = t + 100
            g_time = (g_time or 0) + 100
            state = d.state
            if d.state == GuidanceFieldworkDriver.STATE_DRIVING or d.state == GuidanceFieldworkDriver.STATE_DONE then break end
        end
        GuidanceVehicleInfo.get = realGet
        return movedEarly, state, measured > before, t, d
    end
    local early, state, remeasured, t = prepareRun(3000)
    r.prepareWait = not early and state == GuidanceFieldworkDriver.STATE_DRIVING and remeasured and t >= 3000 and t < 4000
    local _, state2, _, t2, d2 = prepareRun(nil)
    r.prepareGiveUp = state2 ~= GuidanceFieldworkDriver.STATE_DRIVING and t2 > GuidanceFieldworkDriver.PREPARE_TIMEOUT
        and t2 < GuidanceFieldworkDriver.PREPARE_TIMEOUT + 2000
    PREPARE_INFO = string.format("unfolding: waited %.1f s, then driving %s, measured again %s; never ready: gave up after %.1f s",
        t / 1000, tostring(state == GuidanceFieldworkDriver.STATE_DRIVING), tostring(remeasured), t2 / 1000)
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
    for name in ("movedThere", "neighbours", "streamed", "dropped", "newCourse", "report", "written", "overlay",
                 "windrowFound", "windrowFollow", "startSetting", "prepareWait", "prepareGiveUp", "rainWait", "edgeRefill"):
        good = bool(r[name])
        ok = ok and good
        print(f"{name}: {'OK' if good else 'FAILED'}")
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

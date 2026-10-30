"""Loads the whole mod (modDesc order) on top of engine stand-ins (smoke_stubs.lua) and runs it through:
make a course for a field of a map, start the job, drive the course to the end with the real driver, and check
that implements were lowered and raised, the job finished and AutoDrive's onCpFinished event was raised.

Usage:
    python smoke_test.py <map.i3d> [field number]
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402
from lupa import lua51  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent

DRIVE = r"""
function runSmoke(flat, mode)
    makeField(7, flat)
    local vt = {events = {}, functions = {}, listeners = {}}
    GuidanceVehicle.registerEvents(vt)
    GuidanceVehicle.registerFunctions(vt)
    GuidanceVehicle.registerEventListeners(vt)
    GuidanceVehicle.initSpecialization()

    -- a tractor with a 6 m implement 4 m behind the guidance point
    local node = {x = flat[1] + 5, z = flat[2] + 5, h = 0}
    local leftMarker, rightMarker, backMarker = {lx = 3, lz = -3}, {lx = -3, lz = -3}, {lx = 0, lz = -5}
    local towed = mode == "towed" or mode == "towedOff"
    if towed then
        -- a trailed implement: its work area 6 to 8 m behind the guidance point, on a drawbar
        leftMarker, rightMarker, backMarker = {lx = 3, lz = -6}, {lx = -3, lz = -6}, {lx = 0, lz = -8}
    end
    local implement = {object = {
        getAIMarkers = function() return leftMarker, rightMarker, backMarker end,
        aiImplementStartLine = function()
            LOWERED = (LOWERED or 0) + 1
            -- where: the front of the work area against the start of the nearest worked stretch (+ late)
            if DRIVER then
                local f = DRIVER.follower
                local pos, best = f.s + DRIVER.info.frontOffset, nil
                for _, w in ipairs(f.workIntervals) do
                    if best == nil or math.abs(pos - w.from) < math.abs(best) then best = pos - w.from end
                end
                if best then table.insert(LOWER_AT, best) end
            end
        end,
        aiImplementEndLine = function()
            RAISED = (RAISED or 0) + 1
            if DRIVER then
                local f = DRIVER.follower
                local pos, best = f.s + DRIVER.info.backOffset, nil
                for _, w in ipairs(f.workIntervals) do
                    if best == nil or math.abs(pos - w.to) < math.abs(best) then best = pos - w.to end
                end
                if best then table.insert(RAISE_AT, best) end
            end
        end,
        -- three point mounted: the tractor can back up with it
        getActiveInputAttacherJoint = function()
            if towed then return {jointType = AttacherJoints.JOINTTYPE_TRAILER} end
            return {jointType = AttacherJoints.JOINTTYPE_IMPLEMENT, topReferenceNode = 1}
        end,
        spec_wheels = towed and {wheels = {1}} or nil,
        turnedOn = true,
        getIsTurnedOn = function(self) return self.turnedOn end,
        setIsTurnedOn = function(self, on)
            if not on then SWITCHED_OFF = (SWITCHED_OFF or 0) + 1 end
            self.turnedOn = on
        end,
    }}
    local tank = {level = 0}
    local v = {
        spec_combine = {fillUnitIndex = 1},
        getFillUnitCapacity = function() return 1000 end,
        getFillUnitFillLevel = function() return tank.level end,
        rootNode = node, isServer = true, isClient = false, raisedEvents = {}, speed = 0,
        propertyState = 1, spec_aiFieldWorker = {}, maxTurningRadius = 6,
    }
    v["spec_FS25_CourseCorrect.guidance"] = {}
    for name, fn in pairs(vt.functions) do v[name] = fn end
    function v:getNextDirtyFlag() return 1 end
    function v:raiseDirtyFlags() end
    function v:getName() return "Test tractor" end
    function v:getAIDirectionNode() return node end
    function v:getAttachedAIImplements() return {implement} end
    function v:getChildVehicles() return {v, implement.object} end
    function v:updateAIFieldWorkerImplementData() end
    function v:raiseAIEvent(a, b) table.insert(self.raisedEvents, a) end
    function v:raiseStateChange() end
    function v:getAINeedsTrafficCollisionBox() return false end
    function v:getCanAIFieldWorkerContinueWork() return true end
    function v:getLastSpeed() return self.speed end
    function v:getSpeedLimit() return 12 end
    function v:getCruiseControlMaxSpeed() return 30 end
    function v:getOwnerFarmId() return 1 end
    function v:getIsAIActive() return self.job ~= nil end
    function v:getJob() return self.job end
    function v:getIsInUse() return false end
    function v:createAgent() end
    function v:deleteAgent() end
    function v:aiJobStarted(job) self.job = job end
    function v:aiJobFinished() self.job = nil end
    function v:stopFieldWorker() end
    function v:stopCurrentAIJob(msg)
        STOP_MESSAGE = msg
        if self.job then self.job:stop(msg) end
        self.job = nil
    end
    vt.listeners.onLoad(v, nil)

    if mode == "keep" then v:getGuidanceSettings().keepLowered = true end
    LOWER_AT, RAISE_AT, DRIVER = {}, {}, nil
    if mode == "early" then
        v:getGuidanceSettings().lowerLate, v:getGuidanceSettings().raiseLate = -3, 3
    elseif mode == "late" then
        v:getGuidanceSettings().lowerLate, v:getGuidanceSettings().raiseLate = 3, -3
    end
    GuidanceFieldworkDriver.TOW_COMPENSATION = mode ~= "towedOff"
    -- the normal run plays the host: it gets the notifications
    if mode == nil then g_client = {} end
    if mode == "fruit" then
        -- standing crop everywhere on the field except the outermost 6 m, through the game's functions
        local poly = {}
        for i = 1, #flat - 1, 2 do table.insert(poly, {x = flat[i], y = flat[i + 1]}) end
        local index = GuidanceGeo.outlineIndex(GuidanceGeo.ensureCCW(poly), 10)
        g_fruitTypeManager = {fruitTypes = {{index = 1}}}
        FSDensityMapUtil = {getFruitArea = function(i, x0, z0, x1, z1, x2, z2)
            local p = {x = (x1 + x2) / 2, y = (z1 + z2) / 2}
            if index:isInside(p) and index:closest(p, 6) == nil then return 1, 1, 1 end
            return 0, 0, 1
        end}
        local find = GuidancePathfinder.find
        GuidancePathfinder.find = function(...)
            PATHFINDS = (PATHFINDS or 0) + 1
            return find(...)
        end
        -- start outside the field: the way in crosses crop
        node.x, node.z, node.h = flat[1] - 20, flat[2] - 20, math.atan2(flat[4] - flat[2], flat[3] - flat[1])
    end
    local ok, err = v:guidanceGenerate()
    assert(ok, "generate failed: " .. tostring(err))
    local course = v:getGuidanceCourse()
    log("course: %d waypoints, %d rows, %d headlands, %.0f m", #course.waypoints, course.stats.rows,
        course.stats.headlands, course.length)

    -- plan goes over the network and comes back the same
    local stream = {}
    v:getGuidancePlan():writeStream(stream)
    local copy = GuidancePlan.readStream(stream)
    for k, val in pairs(v:getGuidancePlan()) do
        assert(copy[k] == val or math.abs((copy[k] or 0) - (val or 0)) < 1e-3, "stream mismatch " .. k)
    end

    assert(v.cpStartStopDriver ~= nil, "AutoDrive interface missing")
    if mode == "nearest" then
        -- in the middle of the field, facing along the first row: start there, not at the first waypoint
        local wps = course.waypoints
        for i = 2, #wps do
            local a, b = wps[i - 1], wps[i]
            if b.t == "R" and b.work and math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) > 40 then
                node.x, node.z = (a.x + b.x) / 2, (a.z + b.z) / 2
                node.h = math.atan2(b.z - a.z, b.x - a.x)
                break
            end
        end
        v:getGuidanceSettings().startMode = GuidancePlan.START_NEAREST
        v:guidanceStartStop()
        NEAREST_IX = STARTED_JOB and STARTED_JOB.startIx or -1
        NEAREST_MID = STARTED_JOB and STARTED_JOB.startPoint ~= nil
    else
        v:cpStartStopDriver(true)
    end
    local job = STARTED_JOB
    assert(job, "no job started")
    job:start(1)
    job.tasks[1]:start()
    local driver = v.spec_aiFieldWorker.driveStrategies[1]
    DRIVER = driver
    local imp, impSamples = nil, {}
    assert(driver, "no drive strategy installed")

    -- drive: the game would steer to the target, our vehicle just turns towards it within its radius
    local dt = 100
    local steps = 0
    local maxSteps = math.floor(course.length / 1.5 * 10) + 5000
    while v.job ~= nil and steps < maxSteps do
        local tx, tz, fwd, maxSpeed = driver:getDriveData(dt, node.x, 0, node.z)
        local speed = math.min(maxSpeed or 0, 12) / 3.6
        if mode == "stuck" and steps > 50 then speed = 0 end
        if mode == "full" and steps == 6000 then tank.level = 1000 end
        if mode == "pause" then
            if steps == 3000 then v:guidanceSetPaused(true) end
            if steps == 3050 then PAUSE_AT = {node.x, node.z} end
            if steps == 3300 then
                PAUSE_MOVED = math.sqrt((node.x - PAUSE_AT[1]) ^ 2 + (node.z - PAUSE_AT[2]) ^ 2)
                PAUSED_STATE = v:getIsGuidancePaused()
                v:guidanceSetPaused(false)
            end
        end
        if not fwd then REVERSED = (REVERSED or 0) + 1 end
        -- backing up: the same pure pursuit, as if the vehicle faced the way it moves
        local hm = fwd and node.h or node.h + math.pi
        local dx, dz = tx - node.x, tz - node.z
        local alpha = math.atan2(dz, dx) - hm
        alpha = (alpha + math.pi) % (2 * math.pi) - math.pi
        local dist = math.max(math.sqrt(dx * dx + dz * dz), 0.1)
        local k = math.max(-1 / 5.4, math.min(1 / 5.4, 2 * math.sin(alpha) / dist))
        hm = hm + speed * dt / 1000 * k
        node.x = node.x + speed * dt / 1000 * math.cos(hm)
        node.z = node.z + speed * dt / 1000 * math.sin(hm)
        node.h = fwd and hm or hm - math.pi
        if towed then
            -- the implement: 6 m behind a hitch 1 m behind the guidance point, pulled along (tractrix)
            local hx, hz = node.x - math.cos(node.h), node.z - math.sin(node.h)
            if imp == nil then imp = {x = hx - 6 * math.cos(node.h), z = hz - 6 * math.sin(node.h)} end
            local dx2, dz2 = hx - imp.x, hz - imp.z
            local d2 = math.max(math.sqrt(dx2 * dx2 + dz2 * dz2), 1e-6)
            imp.x, imp.z = hx - dx2 / d2 * 6, hz - dz2 / d2 * 6
            -- the markers where the implement is (world), 3 m to each side of its middle
            local ux, uz = dx2 / d2, dz2 / d2
            leftMarker.x, leftMarker.z = imp.x - uz * 3, imp.z + ux * 3
            rightMarker.x, rightMarker.z = imp.x + uz * 3, imp.z - ux * 3
            local t, work = driver.follower:getCurrentSegment()
            if driver.lowered and t == "H" and steps % 5 == 0 then
                table.insert(impSamples, {x = imp.x, y = imp.z, s = driver.follower.s})
            end
        end
        v.speed = speed * 3.6
        steps = steps + 1
        -- time left: the profile, learning the pace as it goes
        GuidanceVehicle.onUpdateTick(v, dt)
        if mode == nil and steps % 3000 == 0 then
            local total, left = v:getGuidanceTimes()
            TIME_CHECKS = TIME_CHECKS or {}
            table.insert(TIME_CHECKS, {steps, left, total})
        end
    end
    if TIME_CHECKS then
        for _, c in ipairs(TIME_CHECKS) do
            print(string.format("time left at %4.0f s: estimated %5.0f s, actually %5.0f s (whole course %5.0f s)",
                c[1] / 10, c[2], (steps - c[1]) / 10, c[3]))
        end
    end
    local events = table.concat(v.raisedEvents, ",")
    IMP_SAMPLES = impSamples
    if towed and imp then
        -- did the implement get to the end of the last worked stretch? (+ past it, - short of it)
        local wps = course.waypoints
        for i = #wps, 2, -1 do
            if wps[i].work then
                local a, b = wps[i - 1], wps[i]
                local len = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
                END_REACH = ((imp.x - b.x) * (b.x - a.x) + (imp.z - b.z) * (b.z - a.z)) / len
                break
            end
        end
    end
    if towed then
        -- how far the implement got from the headland passes while working them
        local lines = {}
        local wps = course.waypoints
        for i = 2, #wps do
            if wps[i].t == "H" and wps[i].work then
                table.insert(lines, {{x = wps[i - 1].x, y = wps[i - 1].z}, {x = wps[i].x, y = wps[i].z}})
            end
        end
        local worst, sum = 0, 0
        for _, p in ipairs(impSamples) do
            local best = math.huge
            for _, l in ipairs(lines) do
                local d = GuidanceGeo.distToSegment(p, l[1], l[2])
                best = math.min(best, d)
            end
            if best > worst then WORST_AT = string.format("(%.0f, %.0f) s=%.0f", p.x, p.y, p.s) end
            worst = math.max(worst, best)
            sum = sum + best
        end
        return STOP_MESSAGE and STOP_MESSAGE.name or "none", worst, sum / math.max(1, #impSamples), #impSamples,
            course.plan.towLength
    end
    if mode == "stuck" then
        local infos = v:getCpActiveInfoTexts()
        return steps, STOP_MESSAGE and STOP_MESSAGE.name or "none", infos[1] and infos[1].name or "none"
    elseif mode == "full" then
        local progress = v:getGuidanceProgress()
        local resumeIx = course:getResumeIx(progress)
        tank.level = 0
        STARTED_JOB = nil
        local restarted = v:startCpAtLastWp()
        return steps, STOP_MESSAGE and STOP_MESSAGE.name or "none", events:find("onCpFull") ~= nil,
            progress, resumeIx, restarted and STARTED_JOB and STARTED_JOB.startIx or -1
    end
    return steps, LOWERED or 0, RAISED or 0, STOP_MESSAGE and STOP_MESSAGE.name or "none",
        events:find("onCpFinished") ~= nil, course.stats.rows, course.stats.headlands,
        events:find("onAIFieldWorkerTurnProgress") ~= nil, SWITCHED_OFF or 0, REVERSED or 0
end
"""


def fresh_lua(fields, field):
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute((ROOT / "tools/smoke_stubs.lua").read_text(encoding="utf-8"))
    mod_desc = ET.parse(ROOT / "modDesc.xml").getroot()
    files = [e.get("filename") for e in mod_desc.iter("sourceFile")]
    files += [e.get("filename") for e in mod_desc.iter("specialization")]
    for f in files:
        lua.execute((ROOT / f).read_text(encoding="utf-8"))
    lua.execute(DRIVE)
    lua.globals().MOD_LISTENER.loadMap(lua.globals().MOD_LISTENER)
    return lua


def scenarios(lua, flat):
    ok = True
    steps, stop, info = lua.globals().runSmoke(lua.table_from(flat), "stuck")
    good = stop == "AIMessageErrorBlockedByObject" and info == "IS_STUCK" and steps < 300
    print(f"stuck: gave up after {steps / 10:.0f} s with {stop}, status {info}: {'OK' if good else 'FAILED'}")
    ok = ok and good
    steps, stop, full_event, progress, resume_ix, restart_ix = lua.globals().runSmoke(lua.table_from(flat), "full")
    good = stop == "GUIDANCE_IS_FULL" and full_event and restart_ix == resume_ix and resume_ix > 1
    print(f"full: stopped with {stop}, onCpFull={full_event}, at waypoint {progress}, AutoDrive restart at "
          f"{restart_ix} (expected {resume_ix}): {'OK' if good else 'FAILED'}")
    return ok and good


def main():
    i3d = sys.argv[1]
    field = f"field{sys.argv[2] if len(sys.argv) > 2 else 9}"
    fields = fp.read_fields(i3d)
    lua = fresh_lua(fields, field)
    flat = []
    for x, z in fields[field]:
        flat += [x, z]
    try:
        steps, lowered, raised, stop, finished_event, rows, headlands, turn_events, _, reversed_steps = \
            lua.globals().runSmoke(lua.table_from(flat))
    finally:
        for line in lua.globals().LOG.values():
            print("  lua:", line)
    print(f"{field}: {steps} steps ({steps / 600:.0f} min), lowered {lowered}x, raised {raised}x, stopped with {stop}, "
          f"onCpFinished={finished_event}, turn events={turn_events}, rows {rows}, headlands {headlands}, "
          f"{reversed_steps / 10:.0f} s backing up")
    # every row and headland pass at least once; square corners add a lowering each
    expected = rows + headlands
    notes = list(lua.globals().NOTES.values())
    ok = stop == "AIMessageSuccessFinishedJob" and finished_event and lowered == raised and lowered >= expected         and any("guidance_info_FINISHED" in n for n in notes)
    print(f"notifications: {notes}")
    print("OK" if ok else "FAILED")
    lua_keep = fresh_lua(fields, field)
    steps_k, lowered_k, _, stop_k, _, _, _, _, switched_off, _ = \
        lua_keep.globals().runSmoke(lua_keep.table_from(flat), "keep")
    good = stop_k == "AIMessageSuccessFinishedJob" and switched_off > 0 and lowered_k < lowered
    print(f"keep down in turns: lowered {lowered_k}x (was {lowered}), switched off {switched_off}x in turns, "
          f"{steps_k / 600:.0f} min (was {steps / 600:.0f}): {'OK' if good else 'FAILED'}")
    ok = ok and good
    # lowering / raising early and late: same number of times, at the shifted places
    def median(t):
        v = sorted(t.values())
        return v[len(v) // 2] if v else float("nan")
    lua_n = fresh_lua(fields, field)
    lua_n.globals().runSmoke(lua_n.table_from(flat), "normalTiming")
    base_low, base_raise = median(lua_n.globals().LOWER_AT), median(lua_n.globals().RAISE_AT)
    for mode, want in (("early", -3), ("late", 3)):
        lua_t = fresh_lua(fields, field)
        _, lowered_t, raised_t, stop_t, *_ = lua_t.globals().runSmoke(lua_t.table_from(flat), mode)
        low, rise = median(lua_t.globals().LOWER_AT), median(lua_t.globals().RAISE_AT)
        d_low, d_raise = low - base_low, rise - base_raise
        good = (stop_t == "AIMessageSuccessFinishedJob" and lowered_t == lowered and raised_t == raised
                and abs(d_low - want) < 1.0 and abs(d_raise + want) < 1.0)
        print(f"implements {mode}: lowered {lowered_t}x, raised {raised_t}x (normal {lowered}x), down {d_low:+.1f} m, "
              f"up {d_raise:+.1f} m against on time: {'OK' if good else 'FAILED'}")
        ok = ok and good
    lua_p = fresh_lua(fields, field)
    steps_p, _, _, stop_p, _, _, _, _, _, _ = lua_p.globals().runSmoke(lua_p.table_from(flat), "pause")
    moved, was_paused = lua_p.globals().PAUSE_MOVED, lua_p.globals().PAUSED_STATE
    good = stop_p == "AIMessageSuccessFinishedJob" and was_paused and moved is not None and moved < 0.5
    print(f"pause: paused={was_paused}, moved {moved if moved is None else round(moved, 2)} m while paused, "
          f"then finished with {stop_p}: {'OK' if good else 'FAILED'}")
    ok = ok and good
    lua_n = fresh_lua(fields, field)
    steps_n, _, _, stop_n, _, _, _, _, _, _ = lua_n.globals().runSmoke(lua_n.table_from(flat), "nearest")
    start_ix, mid_row = lua_n.globals().NEAREST_IX, lua_n.globals().NEAREST_MID
    good = start_ix > 1 and mid_row and stop_n == "AIMessageSuccessFinishedJob" and steps_n < steps
    print(f"start at nearest: waypoint {start_ix}, in the middle of the row={mid_row}, then finished with {stop_n} "
          f"in {steps_n / 600:.0f} min (whole course {steps / 600:.0f}): {'OK' if good else 'FAILED'}")
    ok = ok and good
    results = {}
    for m in ("towedOff", "towed"):
        lt = fresh_lua(fields, field)
        results[m] = lt.globals().runSmoke(lt.table_from(flat), m)
    stop_t, worst_t, mean_t, n_t, tow = results["towed"]
    _, worst_o, mean_o, _, _ = results["towedOff"]
    good = stop_t == "AIMessageSuccessFinishedJob" and worst_t < worst_o and mean_t < mean_o
    end_reach = lt.globals().END_REACH
    good = good and end_reach is not None and end_reach > -0.5
    print(f"towed implement: at the end of the course it got {end_reach:.1f} m past the end of the last row")
    print(f"towed implement ({tow:.0f} m back): on the headland passes off the line by up to {worst_t:.1f} m "
          f"(mean {mean_t:.2f}), without swinging wide {worst_o:.1f} m (mean {mean_o:.2f}): {'OK' if good else 'FAILED'}")
    ok = ok and good
    lua_fruit = fresh_lua(fields, field)
    steps_f, _, _, stop_f, _, _, _, _, _, _ = lua_fruit.globals().runSmoke(lua_fruit.table_from(flat), "fruit")
    finds = lua_fruit.globals().PATHFINDS or 0
    good = stop_f == "AIMessageSuccessFinishedJob" and finds > 0
    print(f"standing crop: stopped with {stop_f}, pathfinder asked {finds}x, {steps_f / 600:.0f} min: "
          f"{'OK' if good else 'FAILED'}")
    ok = ok and good
    ok = scenarios(fresh_lua(fields, field), flat) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

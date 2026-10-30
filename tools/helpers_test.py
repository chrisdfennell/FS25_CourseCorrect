"""Checks offline the helpers without a course (scripts/ai/Helpers.lua, HelperJobs.lua) and the refill trip, driven
through the mod's own drive loop (GuidanceVehicle:onUpdate -> the game's drive-to-point, here a stand-in that moves
the tractor):

- unloader: a combine harvests field 9's rows (turning at each end), its tank filling; grain flows only while the
  trailer's fill point is under the pipe. The unloader must come, follow under the pipe, take a load, leave full
  and stop (no station) for the player.
- bale collector: bales on the field, a 4-bale loader: every bale picked up, the stacks unloaded where it started.
- chopper: a forage harvester (no tank) with a trailer beside or behind it, held while nothing is under its spout:
  the trailer filled, then stops full.
- auger wagon: full, it empties into a truck standing 8 m off the field edge, then waits again.
- heap: a tipper tips two loads onto a heap where it started, standing while it runs out and on where the ground is
  full; the second load goes on where the first ended.
- silo compacter: a 12 x 50 m bunker silo: every lane driven, never outside the walls, waiting when compacted,
  finished when the silo is closed.
- refill trip: a seeder runs empty: to the station (the game's drive task), filled at the trigger, back, the field
  work on where it stopped.

Usage:
    python helpers_test.py <map.i3d>
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402
import smoke_test  # noqa: E402

LUA = r"""
-- the game's driving, as a stand-in: pure pursuit to the point, within a 5.4 m radius
DRIVEN = {}
function worldToLocal(node, x, y, z)
    local dx, dz = x - node.x, z - node.z
    local lx = dx * math.sin(node.h) - dz * math.cos(node.h)
    local lz = dx * math.cos(node.h) + dz * math.sin(node.h)
    return lx, 0, lz
end
AIVehicleUtil = {driveToPoint = function(v, dt, acc, allowed, fwd, lx, lz, maxSpeed)
    local node = v.rootNode
    local speed = allowed and math.min(maxSpeed or 0, 20) / 3.6 or 0
    -- the world point it was given
    local tx = node.x + math.sin(node.h) * lx + math.cos(node.h) * lz
    local tz = node.z - math.cos(node.h) * lx + math.sin(node.h) * lz
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
    v.speed = speed * 3.6
    if not fwd and speed > 0 then REVERSED = (REVERSED or 0) + 1 end
end}
WheelsUtil = {updateWheelsPhysics = function() end}

function makeVehicle(x, z, h, name)
    local vt = {events = {}, functions = {}, listeners = {}}
    GuidanceVehicle.registerEvents(vt)
    GuidanceVehicle.registerFunctions(vt)
    GuidanceVehicle.registerEventListeners(vt)
    local node = {x = x, z = z, h = h}
    local v = {rootNode = node, isServer = true, isClient = false, speed = 0, spec_aiFieldWorker = {}, maxTurningRadius = 6,
               raisedEvents = {}}
    v["spec_" .. g_currentModName .. ".guidance"] = {}
    for n, fn in pairs(vt.functions) do v[n] = fn end
    function v:getNextDirtyFlag() return 1 end
    function v:raiseDirtyFlags() end
    function v:raiseActive() end
    function v:getName() return name end
    function v:getAIDirectionNode() return node end
    function v:getAISteeringNode() return node end
    function v:getAttachedAIImplements() return {} end
    function v:getChildVehicles() return self.children or {self} end
    function v:getLastSpeed() return self.speed end
    function v:getCruiseControlMaxSpeed() return 30 end
    function v:getOwnerFarmId() return 1 end
    function v:getIsAIActive() return self.job ~= nil end
    function v:getJob() return self.job end
    function v:getIsInUse() return false end
    function v:createAgent() end
    function v:deleteAgent() end
    function v:aiJobStarted(job) self.job = job end
    function v:aiJobFinished() self.job = nil end
    function v:stopVehicle() self.speed = 0 end
    function v:stopCurrentAIJob(msg)
        STOP_MESSAGE = msg
        if self.job then self.job:stop(msg) end
        self.job = nil
    end
    vt.listeners.onLoad(v, nil)
    v.update = vt.listeners.onUpdate
    return v
end

function startHelper(v, jobClass, values)
    local job = jobClass.new(true)
    job:applyCurrentState(v, g_currentMission, 1, true)
    for k, val in pairs(values or {}) do job[k] = val end
    job:setValues()
    local ok, err = job:validate(1)
    assert(ok, "validate: " .. tostring(err))
    job:start(1)
    job.currentTaskIndex = job.task.taskIndex
    job.task:start()
    return job
end

local function dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

-----------------------------------------------------------------------------------------------------------------------
-- unloader
-----------------------------------------------------------------------------------------------------------------------
function runUnloader(flat, rowsFlat, homeX, homeZ)
    makeField(7, flat)
    -- the combine: drives the rows, turns (20 s, jumps to the next row's start), its tank fills while it harvests
    local rows = {}
    for i = 1, #rowsFlat - 3, 4 do
        rows[#rows + 1] = {ax = rowsFlat[i], az = rowsFlat[i + 1], bx = rowsFlat[i + 2], bz = rowsFlat[i + 3]}
    end
    local combine = makeVehicle(rows[1].ax, rows[1].az, math.atan2(rows[1].bz - rows[1].az, rows[1].bx - rows[1].ax), "Combine")
    local tank = {level = 7500, capacity = 10000}
    local pipeNode = {x = 0, z = 0}
    combine.spec_combine = {fillUnitIndex = 1}
    combine.spec_pipe = {numStates = 2, currentState = 2}
    function combine:getFillUnitCapacity() return tank.capacity end
    function combine:getFillUnitFillLevel() return tank.level end
    function combine:getPipeDischargeNodeIndex() return 1 end
    function combine:getDischargeNodeByIndex() return {node = pipeNode} end
    combine.children = {combine}
    -- the unloader: a tractor with a 20 t trailer, its fill point 7 m behind
    local tractor = makeVehicle(homeX, homeZ, 0, "Unloader")
    local trailer = {spec_trailer = {}, level = 0, capacity = 20000}
    local fillNode = {lx = 0, lz = -7}
    function trailer:getFillUnits() return {{}} end
    function trailer:getFillUnitCapacity() return self.capacity end
    function trailer:getFillUnitFillLevel() return self.level end
    function trailer:getFillUnitExactFillRootNode() return fillNode end
    tractor.children = {tractor, trailer}
    g_currentMission.vehicleSystem = {vehicles = {combine, tractor}}
    local job = startHelper(tractor, GuidanceUnloadJob, {unloadX = 0, unloadZ = 0, fullLevel = 0.97})

    local dt, steps = 100, 0
    local row, s, turning = 1, 0, 0
    local transferred, followSteps, alignedSteps, maxOff = 0, 0, 0, 0
    local combineWaited = 0
    while tractor.job ~= nil and steps < 60000 do
        steps = steps + 1
        -- the combine
        local r = rows[row]
        local len = dist(r.ax, r.az, r.bx, r.bz)
        local cnode = combine.rootNode
        if turning > 0 then
            turning = turning - dt
            combine.speed = 0
            if turning <= 0 then
                row = row % #rows + 1
                r = rows[row]
                s = 0
                cnode.x, cnode.z, cnode.h = r.ax, r.az, math.atan2(r.bz - r.az, r.bx - r.ax)
            end
        elseif tank.level >= tank.capacity then
            combine.speed = 0
            combineWaited = combineWaited + 1
        else
            s = s + 5 / 3.6 * dt / 1000
            combine.speed = 5
            tank.level = math.min(tank.capacity, tank.level + 8 * dt / 1000)
            cnode.x = r.ax + (r.bx - r.ax) * s / len
            cnode.z = r.az + (r.bz - r.az) * s / len
            if s >= len then turning = 20000 end
        end
        -- its pipe: 7.5 m to the left, 1 m behind
        pipeNode.x = cnode.x + math.sin(cnode.h) * 7.5 - math.cos(cnode.h)
        pipeNode.z = cnode.z - math.cos(cnode.h) * 7.5 - math.sin(cnode.h)
        -- grain flows into the trailer under it
        local tn = tractor.rootNode
        local fx, fz = tn.x - math.cos(tn.h) * 7, tn.z - math.sin(tn.h) * 7
        local off = dist(fx, fz, pipeNode.x, pipeNode.z)
        local d = tractor.spec_guidance.driver
        if d and d.state == "follow" then
            followSteps = followSteps + 1
            if off < 2 then alignedSteps = alignedSteps + 1 end
        end
        if off < 2 and tank.level > 0 and trailer.level < trailer.capacity then
            local q = math.min(tank.level, 150 * dt / 1000, trailer.capacity - trailer.level)
            tank.level, trailer.level = tank.level - q, trailer.level + q
            transferred = transferred + q
        end
        tractor:update(dt)
        g_time = (g_time or 0) + dt
    end
    local tn = tractor.rootNode
    return {transferred = transferred, trailer = trailer.level, followSteps = followSteps, aligned = alignedSteps,
            steps = steps, finished = tractor.job == nil, message = STOP_MESSAGE and STOP_MESSAGE.name or tostring(STOP_MESSAGE),
            homeDist = dist(tn.x, tn.z, homeX, homeZ), combineWaited = combineWaited,
            info = tractor:getGuidanceInfoTexts()[1] and tractor:getGuidanceInfoTexts()[1].name or ""}
end

-----------------------------------------------------------------------------------------------------------------------
-- bale collector
-----------------------------------------------------------------------------------------------------------------------
function runBales(flat, baleFlat, homeX, homeZ)
    makeField(7, flat)
    Bale = {}
    SlotSystem = {LIMITED_OBJECT_BALE = 1}
    BaleLoader = {EMPTY_NONE = 0, CHANGE_BUTTON_WORK_TRANSPORT = 1}
    function entityExists(node) return node ~= nil and not node.gone end
    local bales = {}
    for i = 1, #baleFlat - 1, 2 do
        local b = {id = i, nodeId = {x = baleFlat[i], z = baleFlat[i + 1]}}
        function b:isa(c) return c == Bale end
        bales[#bales + 1] = b
    end
    g_currentMission.slotSystem = {objectLimits = {[1] = {objects = bales}}}
    local tractor = makeVehicle(homeX, homeZ, 0, "Collector")
    local grab = {lx = -2.5, lz = -2}
    local loader = {count = 0, capacity = 4, unloading = 0}
    loader.spec_baleLoader = {fillUnitIndex = 1, isInWorkPosition = true, emptyState = 0, baleGrabber = {grabNode = grab}}
    function loader:getBaleTypeByBale() return {} end
    function loader:getFillUnitFreeCapacity() return self.capacity - self.count end
    function loader:getFillUnitFillLevel() return self.count end
    function loader:doStateChange() end
    function loader:startAutomaticBaleUnloading() self.unloading = 6000 end
    function loader:getIsAutomaticBaleUnloadingInProgress() return self.unloading > 0 end
    tractor.children = {tractor, loader}
    g_currentMission.vehicleSystem = {vehicles = {tractor}}
    local job = startHelper(tractor, GuidanceBaleJob)
    local dt, steps, picked, stacks, stackFar = 100, 0, 0, 0, 0
    while tractor.job ~= nil and steps < 40000 do
        steps = steps + 1
        local tn = tractor.rootNode
        -- the grab point picks a bale it passes over
        local gx = tn.x + math.sin(tn.h) * grab.lx + math.cos(tn.h) * grab.lz
        local gz = tn.z - math.cos(tn.h) * grab.lx + math.sin(tn.h) * grab.lz
        for _, b in ipairs(bales) do
            if b.mountObject == nil and loader.count < loader.capacity and dist(gx, gz, b.nodeId.x, b.nodeId.z) < 1.2 then
                b.mountObject = loader
                loader.count = loader.count + 1
                picked = picked + 1
            end
        end
        if loader.unloading > 0 then
            loader.unloading = loader.unloading - dt
            if loader.unloading <= 0 then
                loader.count = 0
                stacks = stacks + 1
                stackFar = math.max(stackFar, dist(tn.x, tn.z, homeX, homeZ))
            end
        end
        tractor:update(dt)
        g_time = (g_time or 0) + dt
    end
    return {picked = picked, total = #bales, stacks = stacks, stackFar = stackFar, finished = tractor.job == nil,
            steps = steps, message = STOP_MESSAGE and STOP_MESSAGE.name or tostring(STOP_MESSAGE)}
end

-----------------------------------------------------------------------------------------------------------------------
-- bale wrapper: picks up the unwrapped bales it can wrap (hay), wraps and drops each; straw it can't wrap is left
-----------------------------------------------------------------------------------------------------------------------
function runWrapper(flat, baleFlat, homeX, homeZ)
    makeField(7, flat)
    Bale = {}
    SlotSystem = {LIMITED_OBJECT_BALE = 1}
    BaleWrapper = {STATE_NONE = 0, STATE_WRAPPER_WRAPPING_BALE = 3, STATE_WRAPPER_FINSIHED = 4, CHANGE_WRAPPER_START_DROP_BALE = 5}
    function entityExists(node) return node ~= nil and not node.gone end
    local bales = {}
    for i = 1, #baleFlat - 1, 2 do
        local b = {id = i, nodeId = {x = baleFlat[i], z = baleFlat[i + 1]}, wrappingState = 0,
                   fill = (i == 1) and "STRAW" or "DRYGRASS"}
        function b:isa(c) return c == Bale end
        bales[#bales + 1] = b
    end
    g_currentMission.slotSystem = {objectLimits = {[1] = {objects = bales}}}
    local tractor = makeVehicle(homeX, homeZ, 0, "Wrapper")
    local grab = {lx = 0, lz = -5}
    local wrapper = {timer = 0}
    wrapper.spec_baleWrapper = {baleWrapperState = BaleWrapper.STATE_NONE, baleGrabber = {grabNode = grab}}
    function wrapper:getIsBaleWrappable(b) return b.fill ~= "STRAW" end
    function wrapper:doStateChange(change)
        if change == BaleWrapper.CHANGE_WRAPPER_START_DROP_BALE then
            self.current.wrappingState = 1
            self.current.mountObject = nil
            WRAPPED = (WRAPPED or 0) + 1
            self.current = nil
            self.spec_baleWrapper.baleWrapperState = BaleWrapper.STATE_NONE
        end
    end
    tractor.children = {tractor, wrapper}
    g_currentMission.vehicleSystem = {vehicles = {tractor}}
    WRAPPED = 0
    local job = startHelper(tractor, GuidanceBaleJob)
    local dt, steps = 100, 0
    while tractor.job ~= nil and steps < 40000 do
        steps = steps + 1
        local tn = tractor.rootNode
        local spec = wrapper.spec_baleWrapper
        if spec.baleWrapperState == BaleWrapper.STATE_NONE then
            local gx = tn.x + math.sin(tn.h) * grab.lx + math.cos(tn.h) * grab.lz
            local gz = tn.z - math.cos(tn.h) * grab.lx + math.sin(tn.h) * grab.lz
            for _, b in ipairs(bales) do
                if b.wrappingState == 0 and b.fill ~= "STRAW" and dist(gx, gz, b.nodeId.x, b.nodeId.z) < 1.2 then
                    -- taken onto the wrapper: wrapped for 5 s
                    wrapper.current, wrapper.timer = b, 5000
                    b.mountObject = wrapper
                    spec.baleWrapperState = BaleWrapper.STATE_WRAPPER_WRAPPING_BALE
                    break
                end
            end
        elseif spec.baleWrapperState == BaleWrapper.STATE_WRAPPER_WRAPPING_BALE then
            wrapper.timer = wrapper.timer - dt
            if wrapper.timer <= 0 then spec.baleWrapperState = BaleWrapper.STATE_WRAPPER_FINSIHED end
        end
        tractor:update(dt)
        g_time = (g_time or 0) + dt
    end
    local wrappedHay, straw = 0, 0
    for _, b in ipairs(bales) do
        if b.fill == "STRAW" then straw = straw + b.wrappingState else wrappedHay = wrappedHay + b.wrappingState end
    end
    return {wrapped = wrappedHay, hay = #bales - 1, strawWrapped = straw, finished = tractor.job == nil, steps = steps,
            phase = tostring(tractor:getGuidanceHelperPhase())}
end

local function worldOf(n, lx, lz)
    return n.x + math.sin(n.h) * lx + math.cos(n.h) * lz, n.z - math.cos(n.h) * lx + math.sin(n.h) * lz
end
Dischargeable = {DISCHARGE_STATE_OFF = 0, DISCHARGE_STATE_OBJECT = 1, DISCHARGE_STATE_GROUND = 2}

-----------------------------------------------------------------------------------------------------------------------
-- chopper: no tank, it throws straight into the trailer beside or behind it; it holds while nothing is there
-----------------------------------------------------------------------------------------------------------------------
function runChopper(flat, rowsFlat, homeX, homeZ, cropBoth)
    makeField(7, flat)
    GuidanceUnloadDriver.serving = {}
    local rows = {}
    for i = 1, #rowsFlat - 3, 4 do
        rows[#rows + 1] = {ax = rowsFlat[i], az = rowsFlat[i + 1], bx = rowsFlat[i + 2], bz = rowsFlat[i + 3]}
    end
    local chopper = makeVehicle(rows[1].ax, rows[1].az, math.atan2(rows[1].bz - rows[1].az, rows[1].bx - rows[1].ax), "Chopper")
    chopper.spec_combine = {fillUnitIndex = 1, isBufferCombine = true}
    chopper.spec_pipe = {numStates = 2, currentState = 2}
    function chopper:getFillUnitCapacity() return 1e8 end
    function chopper:getFillUnitFillLevel() return 0 end
    function chopper:getPipeDischargeNodeIndex() return 1 end
    function chopper:getDischargeNodeByIndex() return {node = {x = 0, z = 0}} end
    function chopper:getIsAIActive() return true end
    chopper.children = {chopper}
    local tractor = makeVehicle(homeX, homeZ, 0, "Trailer")
    local trailer = {spec_trailer = {}, level = 0, capacity = 20000}
    local fillNode = {lx = 0, lz = -7}
    function trailer:getFillUnits() return {{}} end
    function trailer:getFillUnitCapacity() return self.capacity end
    function trailer:getFillUnitFillLevel() return self.level end
    function trailer:getFillUnitExactFillRootNode() return fillNode end
    tractor.children = {tractor, trailer}
    g_currentMission.vehicleSystem = {vehicles = {chopper, tractor}}
    STOP_MESSAGE = nil
    startHelper(tractor, GuidanceUnloadJob, {unloadX = 0, unloadZ = 0, fullLevel = 0.97})
    if cropBoth then
        -- (opening a field: standing crop on both sides of it, the trailer behind; its way there not around crop)
        tractor.spec_guidance.helperDriver.probe = {hasFruit = function() return true end}
        tractor.spec_guidance.helperDriver.area = nil
    end
    local dt, steps = 100, 0
    local row, s, turning = 1, 0, 0
    local transferred, held, worked = 0, 0, 0
    local closest = math.huge
    local beside, behind = 0, 0
    while tractor.job ~= nil and steps < 40000 do
        steps = steps + 1
        local cnode = chopper.rootNode
        local tn = tractor.rootNode
        local fx, fz = worldOf(tn, 0, -7)
        -- the spout reaches the trailer beside it (5 m left, 1.5 m back) or behind it (10 to 25 m back, on its line)
        local sx, sz = worldOf(cnode, 5, -1.5)
        local bh = -((fx - cnode.x) * math.cos(cnode.h) + (fz - cnode.z) * math.sin(cnode.h))
        local bl = math.abs((fx - cnode.x) * math.sin(cnode.h) - (fz - cnode.z) * math.cos(cnode.h))
        local under = (dist(fx, fz, sx, sz) < 3 and "side") or (bh > 10 and bh < 25 and bl < 2 and "back") or nil
        -- never into it: the tractor's middle at least 5 m from the chopper's
        closest = math.min(closest, dist(tn.x, tn.z, cnode.x, cnode.z))
        local r = rows[row]
        local len = dist(r.ax, r.az, r.bx, r.bz)
        if turning > 0 then
            turning = turning - dt
            chopper.speed = 0
            if turning <= 0 then
                row = row % #rows + 1
                r = rows[row]
                s = 0
                cnode.x, cnode.z, cnode.h = r.ax, r.az, math.atan2(r.bz - r.az, r.bx - r.ax)
            end
        elseif under == nil or trailer.level >= trailer.capacity then
            -- (our forage harvester holds while nothing is under its spout)
            chopper.speed = 0
            -- (not counting the wait for the next trailer once this one is full)
            local d = tractor.spec_guidance.helperDriver
            if transferred > 0 and d and d.state ~= "leave" then held = held + 1 end
        else
            s = s + 5 / 3.6 * dt / 1000
            chopper.speed = 5
            worked = worked + 1
            if under == "side" then beside = beside + 1 else behind = behind + 1 end
            local q = math.min(40 * dt / 1000, trailer.capacity - trailer.level)
            trailer.level, transferred = trailer.level + q, transferred + q
            cnode.x = r.ax + (r.bx - r.ax) * s / len
            cnode.z = r.az + (r.bz - r.az) * s / len
            if s >= len then turning = 20000 end
        end
        tractor:update(dt)
        g_time = (g_time or 0) + dt
    end
    return {transferred = transferred, held = held, worked = worked, beside = beside, behind = behind, steps = steps,
            closest = closest,
            finished = tractor.job == nil,
            info = tractor:getGuidanceInfoTexts()[1] and tractor:getGuidanceInfoTexts()[1].name or ""}
end

-----------------------------------------------------------------------------------------------------------------------
-- auger wagon: full, into the truck standing at the field edge
-----------------------------------------------------------------------------------------------------------------------
function runOverload(flat, startX, startZ, truckX, truckZ, truckH)
    makeField(7, flat)
    GuidanceUnloadDriver.serving = {}
    local tractor = makeVehicle(startX, startZ, truckH, "Auger tractor")
    local dn = {lx = 6, lz = -3, x = 0, z = 0}
    local wagon = {spec_pipe = {numStates = 2, currentState = 1}, level = 30000, capacity = 30000, state = 0}
    function wagon:getFillUnits() return {{}} end
    function wagon:getFillUnitCapacity() return self.capacity end
    function wagon:getFillUnitFillLevel() return self.level end
    function wagon:getFillUnitExactFillRootNode() return {lx = 0, lz = -4} end
    function wagon:getCurrentDischargeNode() return {node = dn, fillUnitIndex = 1} end
    function wagon:getDischargeFillType() return 7 end
    function wagon:getDischargeState() return self.state end
    function wagon:getIsPipeStateChangeAllowed() return true end
    function wagon:setPipeState(st) self.spec_pipe.currentState = st end
    tractor.children = {tractor, wagon}
    local truckNode = {x = truckX, z = truckZ, h = truckH}
    local tfx, tfz = worldOf(truckNode, 0, -4)
    local truckFill = {x = tfx, z = tfz}
    local truck = {rootNode = truckNode, spec_trailer = {}, level = 0, capacity = 40000}
    function truck:getRootVehicle() return self end
    function truck:getLastSpeed() return 0 end
    function truck:getAIDirectionNode() return truckNode end
    function truck:getFillUnits() return {{}} end
    function truck:getFillUnitFreeCapacity() return self.capacity - self.level end
    function truck:getFillUnitSupportsFillType() return true end
    function truck:getFillUnitExactFillRootNode() return truckFill end
    g_currentMission.vehicleSystem = {vehicles = {tractor, truck}}
    startHelper(tractor, GuidanceUnloadJob, {unloadX = 0, unloadZ = 0, fullLevel = 0.97, unloadMode = 1})
    local d = tractor.spec_guidance.helperDriver
    d:onFull()
    local started = d.state == "toTruck"
    local dt, steps, offWhenFlowing, sawOverload, pipeClosed = 100, 0, 0, false, false
    while tractor.job ~= nil and steps < 20000 do
        steps = steps + 1
        local tn = tractor.rootNode
        dn.x, dn.z = worldOf(tn, dn.lx, dn.lz)
        local off = dist(dn.x, dn.z, truckFill.x, truckFill.z)
        wagon.state = 0
        if wagon.spec_pipe.currentState == 2 and wagon.spec_pipe.automaticDischarge and off < 1.5 and wagon.level > 0 then
            local q = math.min(wagon.level, 500 * dt / 1000)
            wagon.level, truck.level = wagon.level - q, truck.level + q
            wagon.state = 1
            offWhenFlowing = math.max(offWhenFlowing, off)
        end
        if d.state == "overload" then sawOverload = true end
        tractor:update(dt)
        g_time = (g_time or 0) + dt
        if sawOverload and d.state == "wait" then
            pipeClosed = wagon.spec_pipe.currentState == 1
            break
        end
    end
    local tn = tractor.rootNode
    return {started = started, truck = truck.level, wagon = wagon.level, back = tostring(d.state), pipeClosed = pipeClosed,
            steps = steps, offWhenFlowing = offWhenFlowing, truckDist = dist(tn.x, tn.z, truckX, truckZ)}
end

-----------------------------------------------------------------------------------------------------------------------
-- tipper: full, a heap where it started; it stands while the load runs out, on where the ground is full; the next
-- load goes on where the last ended
-----------------------------------------------------------------------------------------------------------------------
function runHeap(flat, startX, startZ, heapX, heapZ, heapH)
    makeField(7, flat)
    GuidanceUnloadDriver.serving = {}
    local tractor = makeVehicle(startX, startZ, heapH, "Tipper tractor")
    local tipNode = {lx = 0, lz = -8, x = 0, z = 0}
    local tipper = {spec_trailer = {dischargeNodeIndexToTipSide = {[1] = {index = 2}}},
                    spec_dischargeable = {dischargeNodes = {{node = tipNode, canDischargeToGround = true, fillUnitIndex = 1, index = 1}}},
                    level = 20000, capacity = 20000, state = 0}
    function tipper:getFillUnits() return {{}} end
    function tipper:getFillUnitCapacity() return self.capacity end
    function tipper:getFillUnitFillLevel() return self.level end
    function tipper:getFillUnitExactFillRootNode() return {lx = 0, lz = -5} end
    function tipper:setPreferedTipSide(i) self.tipSide = i end
    function tipper:setManualDischargeState(st) self.state = st end
    function tipper:getCanDischargeToGround() return true end
    function tipper:getAIHasFinishedDischarge() return true end
    tractor.children = {tractor, tipper}
    g_currentMission.vehicleSystem = {vehicles = {tractor}}
    startHelper(tractor, GuidanceUnloadJob, {unloadX = 0, unloadZ = 0, fullLevel = 0.97, unloadMode = 2})
    local d = tractor.spec_guidance.helperDriver
    d.home = {x = heapX, z = heapZ, h = heapH}
    local cells, used = {}, {}
    local loads = {}
    local dt, steps = 100, 0
    for load = 1, 2 do
        tipper.level = 20000
        d:onFull()
        local first, last
        while tractor.job ~= nil and steps < 40000 do
            steps = steps + 1
            local tn = tractor.rootNode
            tipNode.x, tipNode.z = worldOf(tn, tipNode.lx, tipNode.lz)
            if tipper.state == Dischargeable.DISCHARGE_STATE_GROUND and tipper.level > 0 then
                -- the ground under the tip point takes 4000 l per 2 m square
                local key = math.floor(tipNode.x / 2) .. ":" .. math.floor(tipNode.z / 2)
                local room = 4000 - (cells[key] or 0)
                local q = math.min(tipper.level, 600 * dt / 1000, room)
                if q > 0 then
                    if cells[key] == nil then used[#used + 1] = key end
                    cells[key] = (cells[key] or 0) + q
                    tipper.level = tipper.level - q
                    first = first or {x = tipNode.x, z = tipNode.z}
                    last = {x = tipNode.x, z = tipNode.z}
                end
            end
            tractor:update(dt)
            g_time = (g_time or 0) + dt
            if d.state == "wait" and tipper.level <= 0 then break end
        end
        loads[load] = {first = first, last = last, emptied = tipper.level <= 0, state = d.state}
    end
    local gap = (loads[1].last and loads[2].first) and dist(loads[1].last.x, loads[1].last.z, loads[2].first.x, loads[2].first.z) or 999
    local fromHome = loads[1].first and dist(loads[1].first.x, loads[1].first.z, heapX, heapZ) or 999
    return {emptied1 = loads[1].emptied, emptied2 = loads[2].emptied, cells = #used, gap = gap, fromHome = fromHome,
            tipSide = tipper.tipSide or 0, off = tipper.state == Dischargeable.DISCHARGE_STATE_OFF, steps = steps}
end

-----------------------------------------------------------------------------------------------------------------------
-- silo compacter
-----------------------------------------------------------------------------------------------------------------------
function runSilo(sx, sz)
    BunkerSilo = {STATE_FILL = 1, STATE_CLOSED = 2}
    -- 12 m wide (x), 50 m long (z)
    local silo = {bunkerSiloArea = {sx = sx, sz = sz, wx = sx + 12, wz = sz, hx = sx, hz = sz + 50},
                  compactedPercent = 40, state = BunkerSilo.STATE_FILL}
    g_currentMission.placeableSystem = {placeables = {{spec_bunkerSilo = {bunkerSilo = silo}}}}
    makeField(7, {sx - 200, sz - 200, sx + 200, sz - 200, sx + 200, sz + 200, sx - 200, sz + 200})
    local tractor = makeVehicle(sx + 6, sz - 6, math.pi / 2, "Compacter")
    tractor.children = {tractor}
    g_currentMission.vehicleSystem = {vehicles = {tractor}}
    local job = startHelper(tractor, GuidanceSiloJob)
    local dt, steps, outside, minX, maxX, waited = 100, 0, 0, math.huge, -math.huge, 0
    local closeAt
    while tractor.job ~= nil and steps < 30000 do
        steps = steps + 1
        local tn = tractor.rootNode
        local inside = tn.x > sx - 0.3 and tn.x < sx + 12.3 and tn.z > sz - 8 and tn.z < sz + 50.3
        if not inside then outside = outside + 1 end
        if tn.z > sz + 5 then minX, maxX = math.min(minX, tn.x), math.max(maxX, tn.x) end
        -- driving compacts it
        silo.compactedPercent = math.min(100, silo.compactedPercent + tractor.speed / 3.6 * dt / 1000 * 0.04)
        if tractor.spec_guidance.driver and tractor.spec_guidance.driver.state == "wait" then
            waited = waited + 1
            if waited == 100 then silo.compactedPercent = 90 end
            if waited == 300 then closeAt = steps end
        end
        if closeAt and steps >= closeAt then silo.state = BunkerSilo.STATE_CLOSED end
        tractor:update(dt)
        g_time = (g_time or 0) + dt
    end
    return {steps = steps, outside = outside, minX = minX - sx, maxX = maxX - sx, waited = waited, reversed = REVERSED or 0,
            finished = tractor.job == nil, message = STOP_MESSAGE and STOP_MESSAGE.name or tostring(STOP_MESSAGE)}
end

-----------------------------------------------------------------------------------------------------------------------
-- refill trip (the job's task order, the fill task at a trigger)
-----------------------------------------------------------------------------------------------------------------------
function runRefill()
    FillType = FillType or {}
    FillType.SEEDS, FillType.UNKNOWN = 5, 0
    local driveTasks = {}
    AITaskDriveTo = {new = function(isServer, job)
        local t = {isServer = isServer, job = job}
        function t:setVehicle(v) self.vehicle = v end
        function t:setTargetPosition(x, z) self.x, self.z = x, z end
        function t:setTargetDirection(dx, dz) self.dx, self.dz = dx, dz end
        function t:setTargetOffset() end
        function t:reset() end
        driveTasks[#driveTasks + 1] = t
        return t
    end}
    local seeder = {free = 2000}
    local trigger = {fillableObjects = {{object = seeder, fillUnitIndex = 1}}}
    function trigger:onFillTypeSelection(ft) if self.autoStart then self.isLoading = true; self.filling = ft end end
    local station = {loadTriggers = {trigger}, getAISupportedFillTypes = function() return {[5] = true} end,
                     getAITargetPositionAndDirection = function() return 500, 600, 1, 0 end}
    g_currentMission.storageSystem = {getLoadingStations = function() return {station} end}
    g_currentMission.accessHandler = {canFarmAccess = function() return true end}
    local v = makeVehicle(10, 20, 0, "Seeder")
    function seeder:getFillUnits() return {{}} end
    function seeder:getFillUnitFreeCapacity() return self.free end
    seeder.spec_sowingMachine = {fillUnitIndex = 1}
    v.children = {v, seeder}
    local job = GuidanceJob.new(true)
    job:applyCurrentState(v, g_currentMission, 1, true)
    job.refillX, job.refillZ = 500, 600
    job:setValues()
    job.currentTaskIndex = 1
    local driver = {course = {plan = {}}}
    local started = job:startRefillTrip(driver, {FillType.SEEDS})
    local order = {}
    for _ = 1, 4 do
        local ix = job:getNextTaskIndex(false)
        order[#order + 1] = ix
        job.currentTaskIndex = ix
        if job.tasks[ix] == job.fillTask then
            job.fillTask:setVehicle(v)
            job.fillTask:start()
            job.fillTask:update(100)
            -- the trigger fills it up
            seeder.free = 0
            job.fillTask:update(100)
            job.fillTask:update(100)
        end
    end
    return {started = started, order = table.concat(order, " "), toX = job.driveToRefillTask.x, toZ = job.driveToRefillTask.z,
            backX = job.driveBackTask.x, filled = trigger.filling == 5, fillDone = job.fillTask.isFinished,
            resume = job.resumeAfterTrip == true}
end
"""


def inside(x, z, pts, margin):
    """inside the outline and at least margin m from its edges"""
    n, c = len(pts), False
    j = n - 1
    for i in range(n):
        xi, zi = pts[i]
        xj, zj = pts[j]
        if (zi > z) != (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi:
            c = not c
        j = i
    if not c:
        return False
    for i in range(n):
        ax, az = pts[i]
        bx, bz = pts[(i + 1) % n]
        dx, dz = bx - ax, bz - az
        L2 = dx * dx + dz * dz or 1e-9
        t = max(0, min(1, ((x - ax) * dx + (z - az) * dz) / L2))
        if (ax + t * dx - x) ** 2 + (az + t * dz - z) ** 2 < margin * margin:
            return False
    return True


def main():
    i3d = sys.argv[1]
    fields = fp.read_fields(i3d)
    pts = fields["field9"]
    flat = [c for p in pts for c in p]
    ok = True

    def check(name, good, info=""):
        nonlocal ok
        ok = ok and bool(good)
        print(f"{name}: {info}{': ' if info else ''}{'OK' if good else 'FAILED'}")

    # the rows of field 9's course, for the combine
    lua0 = fp.load_lua()
    course, _ = fp.generate(lua0, pts, {"workWidth": 9, "turnRadius": 7, "headlands": -1})
    wps = course["waypoints"]
    rows = []
    start = None
    for w in wps:
        if w["rs"] and w["t"] == "R":
            start = w
        if w["re"] and w["t"] == "R" and start:
            rows += [start["x"], start["z"], w["x"], w["z"]]
            start = None
    xs, zs = [p[0] for p in pts], [p[1] for p in pts]

    lua = smoke_test.fresh_lua(fields, "field9")
    lua.execute(LUA)
    G = lua.globals()
    T = lua.table_from

    # unloader: starts at the field's first corner
    r = G.runUnloader(T(flat), T(rows), pts[0][0] + 6, pts[0][1] + 6)
    aligned = r["aligned"] / max(1, r["followSteps"])
    check("unloader", r["transferred"] > 15000 and aligned > 0.6 and r["finished"] and r["info"] == "NEEDS_UNLOADING"
          and r["homeDist"] < 15,
          f"took {r['transferred']:.0f} l (trailer {r['trailer']:.0f} l), under the pipe {100 * aligned:.0f}% of its "
          f"following, {r['steps'] / 600:.0f} min, back {r['homeDist']:.0f} m from where it started, "
          f"stopped: {r['info']}")

    # bales: 6 inside field 9, the collector starts at its first corner
    import random
    random.seed(4)
    bales = []
    while len(bales) < 12:
        x = random.uniform(min(xs) + 40, max(xs) - 40)
        z = random.uniform(min(zs) + 40, max(zs) - 40)
        if inside(x, z, pts, 25):
            bales += [x, z]
    r = G.runBales(T(flat), T(bales), pts[0][0] + 6, pts[0][1] + 6)
    check("bale collector", r["picked"] == r["total"] and r["stacks"] >= 2 and r["stackFar"] < 15 and r["finished"],
          f"{r['picked']} of {r['total']} bales, {r['stacks']} stacks unloaded (at most {r['stackFar']:.0f} m from "
          f"where it started), {r['steps'] / 600:.0f} min, {r['message']}")

    r = G.runWrapper(T(flat), T(bales), pts[0][0] + 6, pts[0][1] + 6)
    check("bale wrapper", r["wrapped"] == r["hay"] and r["strawWrapped"] == 0 and r["finished"]
          and r["phase"] == "balesCantWrap",
          f"{r['wrapped']} of {r['hay']} hay bales wrapped, the straw bale left, {r['steps'] / 600:.0f} min, "
          f"then: {r['phase']}")

    r = G.runChopper(T(flat), T(rows), pts[0][0] + 6, pts[0][1] + 6)
    share = r["held"] / max(1, r["held"] + r["worked"])
    check("chopper", r["transferred"] > 19000 and r["finished"] and r["info"] == "NEEDS_UNLOADING" and share < 0.5,
          f"took {r['transferred']:.0f} l, beside {r['beside'] / 10:.0f} s, behind {r['behind'] / 10:.0f} s, the "
          f"chopper held {100 * share:.0f}% of the time once going (the trailer coming round after its turns), "
          f"stopped: {r['info']}")
    r = G.runChopper(T(flat), T(rows), pts[0][0] + 6, pts[0][1] + 6, True)
    share = r["held"] / max(1, r["held"] + r["worked"])
    check("chopper, crop on both sides", r["transferred"] > 19000 and r["finished"] and r["behind"] > r["beside"]
          and r["closest"] > 5 and share < 0.5,
          f"took {r['transferred']:.0f} l, behind {r['behind'] / 10:.0f} s, beside {r['beside'] / 10:.0f} s, never "
          f"nearer than {r['closest']:.1f} m, the chopper held {100 * share:.0f}%")

    # the truck: 8 m off the field's westmost edge, along it
    import math
    west = min(range(len(pts)), key=lambda i: pts[i][0])
    a, b = pts[west], pts[(west + 1) % len(pts)]
    if abs(b[0] - a[0]) > 5:
        b = pts[west - 1]
    th = math.atan2(b[1] - a[1], b[0] - a[0])
    mx, mz = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
    nx, nz = math.sin(th), -math.cos(th)
    if inside(mx + nx * 2, mz + nz * 2, pts, 0):
        nx, nz = -nx, -nz
    tx, tz = mx + nx * 8, mz + nz * 8
    r = G.runOverload(T(flat), mx - nx * 50, mz - nz * 50, tx, tz, th)
    check("auger wagon into a truck", r["started"] and r["truck"] > 29850 and r["wagon"] < 100 and r["back"] == "wait"
          and r["pipeClosed"],
          f"{r['truck']:.0f} l into the truck {r['truckDist']:.0f} m away, pipe off the fill point at most "
          f"{r['offWhenFlowing']:.1f} m, {r['steps'] / 600:.1f} min, then: {r['back']}, pipe in: {r['pipeClosed']}")

    hx, hz = mx - nx * 40, mz - nz * 40
    r = G.runHeap(T(flat), mx - nx * 80, mz - nz * 80, hx, hz, th)
    check("heap", r["emptied1"] and r["emptied2"] and r["cells"] >= 10 and r["gap"] < 4 and r["fromHome"] < 12
          and r["tipSide"] == 2 and r["off"],
          f"two loads tipped over {r['cells']} cells, starting {r['fromHome']:.0f} m from the heap's place, the second "
          f"on {r['gap']:.1f} m from where the first ended, {r['steps'] / 600:.1f} min")

    r = G.runSilo(1000, 1000)
    check("silo compacter", r["outside"] == 0 and r["minX"] < 3 and r["maxX"] > 9 and r["reversed"] > 100
          and r["waited"] > 0 and r["finished"],
          f"lanes from {r['minX']:.1f} to {r['maxX']:.1f} m across the 12 m silo, outside the walls {r['outside']} "
          f"steps, backed up {r['reversed'] / 600:.1f} min, waited when compacted, finished when closed: {r['finished']}")

    r = G.runRefill()
    check("refill trip", r["started"] and r["order"] == "2 3 4 1" and r["toX"] == 500 and r["toZ"] == 600
          and r["backX"] == 10 and r["filled"] and r["fillDone"] and r["resume"],
          f"tasks {r['order']}, to ({r['toX']}, {r['toZ']}), back to x {r['backX']}, filled {r['filled']}, "
          f"on with the course {r['resume']}")

    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

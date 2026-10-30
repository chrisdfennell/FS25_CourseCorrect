-- CourseCorrect: helpers that don't work a course: the unloader (catches a combine's grain under its pipe and takes
-- it away), the bale collector (picks up or wraps every bale of a field) and the silo compacter (drives up and down
-- a bunker silo). Each is a drive strategy of the game's field work helper, like GuidanceFieldworkDriver: the game
-- calls getDriveData() every frame. Server only.

GuidanceHelperDriver = {}
local Base = GuidanceHelperDriver
local Base_mt = {__index = Base}

Base.SPEED = 12 -- km/h on the field
Base.STUCK_TIME = 25000

local function leftOf(h)
    return math.sin(h), -math.cos(h)
end

local function dist(ax, az, bx, bz)
    return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end

--- Pose of a vehicle (its AI direction node): x, z, heading
function Base.poseOf(vehicle)
    local node = vehicle.getAIDirectionNode and vehicle:getAIDirectionNode() or vehicle.rootNode
    local x, _, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    return x, z, math.atan2(dz, dx)
end

--- Where a node is in a vehicle's frame: left (m), ahead (m)
function Base.offsetIn(vehicle, node)
    local dirNode = vehicle.getAIDirectionNode and vehicle:getAIDirectionNode() or vehicle.rootNode
    local x, _, z = localToLocal(node, dirNode, 0, 0, 0)
    return x, z
end

function Base.init(self, vehicle)
    self.vehicle = vehicle
    self.info = GuidanceVehicleInfo.get(vehicle)
    -- (what other helpers' giving way looks at)
    self.course = {plan = {workWidth = math.max(2.5, self.info.workWidth or 3)}}
    self.stuckTimer = 0
    self.timer = 0
    local x, z, h = Base.poseOf(vehicle)
    self.home = {x = x, z = z, h = h}
    -- the field it is on: for ways around standing crop
    local fieldId = GuidanceCourse.getFieldIdAt and GuidanceCourse.getFieldIdAt(x, z)
    local outline = fieldId and GuidanceCourse.getFieldOutline(fieldId)
    if outline and #outline >= 3 then
        local poly = {}
        for i, p in ipairs(outline) do poly[i] = {x = p.x, y = p.z} end
        self.field = GuidanceGeo.ensureCCW(poly)
        self.area = {field = self.field}
        local ok, probe = pcall(GuidanceFruitProbe.new, outline)
        self.probe = ok and probe or nil
    end
end

function Base:update(dt) end
function Base:delete() end
function Base:draw() end
function Base:isConvoyPartner() return false end
function Base:isPaused() return self.vehicle.spec_guidance ~= nil and self.vehicle.spec_guidance.paused == true end
function Base:isManeuvering() return false end
function Base:isWaitingForUnload() return false end

function Base:isOnField(x, z)
    return self.field ~= nil and GuidanceGeo.pointInPolygon({x = x, y = z}, self.field)
end

--- A way from here to (tx, tz) facing th, its last 'straight' m straight in; around standing crop when the direct
--- way would cross it. Then followed.
function Base:planTo(tx, tz, th, straight)
    local x, z, h = Base.poseOf(self.vehicle)
    local r = self.info.turnRadius or 6
    straight = straight or 0
    local to = {x = tx - math.cos(th) * straight, y = tz - math.sin(th) * straight, h = th}
    local from = {x = x, y = z, h = h}
    local path = GuidanceDubins.shortest(from, to, r)
    local pts = path and GuidanceDubins.sample(from, path, r, 1.5) or {{x = to.x, y = to.y}}
    if self.area and self.probe then
        local fruit = GuidancePathfinder.fruitLength(self.probe, from, pts)
        if fruit > 5 then
            local around = GuidancePathfinder.find(self.area, {workWidth = self.course.plan.workWidth, turnRadius = r},
                from, to, self.probe)
            local aroundFruit = around and GuidancePathfinder.fruitLength(self.probe, from, around)
            if around and aroundFruit < fruit - 5 then pts = around end
        end
    end
    local list = {{x = x, z = z, t = "C", work = false}}
    for _, p in ipairs(pts) do
        if dist(p.x, p.y, list[#list].x, list[#list].z) > 0.3 then
            list[#list + 1] = {x = p.x, z = p.y, t = "C", work = false}
        end
    end
    for k = 1, math.ceil(straight / 2) do
        local f = math.min(straight, k * 2)
        list[#list + 1] = {x = to.x + math.cos(th) * f, z = to.y + math.sin(th) * f, t = "C", work = false}
    end
    if #list < 2 then
        list[#list + 1] = {x = tx + math.cos(th), z = tz + math.sin(th), t = "C", work = false}
    end
    self.follower = GuidancePathFollower.new(list)
end

--- Points to follow as they are (list of {x, z, rev})
function Base:followPoints(pts)
    local list = {}
    for _, p in ipairs(pts) do
        list[#list + 1] = {x = p.x, z = p.z, t = "C", work = false, rev = p.rev}
    end
    self.follower = GuidancePathFollower.new(list)
end

--- Driving along the path: target, forward, speed, distance to stop (the drive data). done: at its end.
function Base:drivePath(dt, maxSpeed, ignore)
    local x, z, h = Base.poseOf(self.vehicle)
    local f = self.follower
    if f == nil then
        return x + math.cos(h), z + math.sin(h), true, 0, 0, true
    end
    f:update(x, z, h)
    if f:getDistanceToCusp() < 0.5 then
        f:passCusp()
    end
    if f:isFinished() then
        return x + math.cos(h), z + math.sin(h), true, 0, 0, true
    end
    local reversing = f:isReversing()
    local gx, gz = f:getGoal(reversing and 3 or math.max(4, self.vehicle:getLastSpeed() / 3.6 * 1.2))
    local speed = maxSpeed
    local radius = f:getMinRadiusAhead(15)
    if radius < math.huge then
        speed = math.min(speed, math.max(4, 3.6 * math.sqrt(1.2 * radius)))
    end
    local toCusp = f:getDistanceToCusp()
    if toCusp < math.huge then
        speed = math.min(speed, math.max(1.5, 3.6 * math.sqrt(2 * 0.6 * toCusp)))
    end
    speed = math.min(speed, 3.6 * math.sqrt(2 * 0.8 * f:getRemaining()) + 1)
    self.ignoreForGiveWay = ignore
    speed = self:giveWay(dt, speed, x, z, h, reversing)
    self.ignoreForGiveWay = nil
    self:checkStuck(dt, speed)
    return gx, gz, not reversing, speed, math.min(f:getRemaining(), toCusp), false
end

--- Standing still
function Base:standStill()
    local x, z, h = Base.poseOf(self.vehicle)
    return x + math.cos(h), z + math.sin(h), true, 0, 0
end

--- Wanting to move but not moving for long: stop the job
function Base:checkStuck(dt, speed)
    if speed > 1 and self.vehicle:getLastSpeed() < 0.5 and not self.blockedBy then
        self.stuckTimer = self.stuckTimer + dt
        if self.stuckTimer > Base.STUCK_TIME then
            self.vehicle:guidanceSetInfoText("IS_STUCK", true)
            self.vehicle:stopCurrentAIJob(AIMessageErrorBlockedByObject.new())
        end
    else
        self.stuckTimer = 0
    end
end

function Base:finish(message, infoText)
    if self.done then return end
    self.done = true
    if infoText then self.vehicle:guidanceSetInfoText(infoText, true) end
    self.vehicle:stopCurrentAIJob(message or AIMessageSuccessFinishedJob.new())
end

-----------------------------------------------------------------------------------------------------------------------
-- The unloader: a tractor with a trailer (or an auger wagon) serving the combines of the field it starts on
-----------------------------------------------------------------------------------------------------------------------

GuidanceUnloadDriver = setmetatable({}, {__index = Base})
local Unload = GuidanceUnloadDriver
local Unload_mt = {__index = Unload}

Unload.CALL_LEVEL = 0.8 -- a combine this full calls (ours: its own setting)
Unload.LEAVE_LEVEL = 0.97 -- the trailer this full goes
Unload.APPROACH_BEHIND = 14 -- m behind its place under the pipe it comes in, straight
Unload.FOLLOW_GAIN = 1.8 -- km/h faster per metre it is behind its place
Unload.LOST = 30 -- m from its place: back to approaching
Unload.REPLAN = 6000 -- ms between new ways while approaching a moving combine
Unload.PIPE_DEFAULT = 7.5 -- m sideways the pipe is assumed out before it can be measured
-- the combine each unloader serves (two never serve the same one)
Unload.serving = {}

function Unload.new(vehicle, job)
    local self = setmetatable({}, Unload_mt)
    Base.init(self, vehicle)
    self.job = job
    self.state = "wait"
    self.leaveLevel = job and job.fullLevel or Unload.LEAVE_LEVEL
    return self
end

--- The trailers' fill units: list of {vehicle, fillUnitIndex, node}
function Unload:fillTargets()
    local out = {}
    for _, v in ipairs(self.vehicle.getChildVehicles and self.vehicle:getChildVehicles() or {}) do
        if v ~= self.vehicle and v.getFillUnits and (v.spec_trailer or v.spec_pipe) then
            for ix in ipairs(v:getFillUnits()) do
                local node = (v.getFillUnitAutoAimTargetNode and v:getFillUnitAutoAimTargetNode(ix))
                    or (v.getFillUnitExactFillRootNode and v:getFillUnitExactFillRootNode(ix))
                if node and v:getFillUnitCapacity(ix) > 0 then
                    out[#out + 1] = {vehicle = v, fillUnitIndex = ix, node = node}
                end
            end
        end
    end
    return out
end

--- How full the trailers are (0..1), and the fill node to put under the pipe (the first with room)
function Unload:trailerState()
    local level, capacity, node = 0, 0, nil
    for _, t in ipairs(self:fillTargets()) do
        local c = t.vehicle:getFillUnitCapacity(t.fillUnitIndex)
        local l = t.vehicle:getFillUnitFillLevel(t.fillUnitIndex)
        level, capacity = level + l, capacity + c
        if node == nil and l < c * 0.98 then node = t.node end
    end
    return capacity > 0 and level / capacity or 1, node
end

local function combineLevel(harvester)
    local ix = harvester.spec_combine.fillUnitIndex
    local c = harvester:getFillUnitCapacity(ix)
    return (c and c > 0) and harvester:getFillUnitFillLevel(ix) / c or 0
end

--- The combines on our field that need us: the fullest first (ours: at their own call level)
function Unload:pickCombine()
    local best, bestLevel
    local vehicles = g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles or {}
    for _, v in pairs(vehicles) do
        local harvester = v ~= self.vehicle and GuidanceFieldworkDriver.findHarvester(v)
        if harvester and v.rootNode then
            local x, z = Base.poseOf(v)
            local other = Unload.serving[v]
            if (other == nil or other == self) and (self.field == nil or self:isOnField(x, z)) then
                local level = combineLevel(harvester)
                local od = v.spec_guidance and v.spec_guidance.driver
                local call = Unload.CALL_LEVEL
                if od and od.course and od.course.plan then call = (od.course.plan.callUnloaderAt or 80) / 100 end
                local waiting = od and od.isWaitingForUnload and od:isWaitingForUnload()
                if (level >= call or waiting) and (bestLevel == nil or level > bestLevel) then
                    best, bestLevel = v, level
                end
            end
        end
    end
    return best
end

--- The pipe's discharge point: x, z (world), and the combine's heading
function Unload:pipePoint(combine)
    local harvester = GuidanceFieldworkDriver.findHarvester(combine)
    local cx, cz, ch = Base.poseOf(combine)
    local spec = harvester and harvester.spec_pipe
    if spec and spec.currentState == 2 and harvester.getPipeDischargeNodeIndex and harvester.getDischargeNodeByIndex then
        local ok, node = pcall(function()
            return harvester:getDischargeNodeByIndex(harvester:getPipeDischargeNodeIndex())
        end)
        if ok and node and node.node then
            local x, _, z = getWorldTranslation(node.node)
            local lx, lz = leftOf(ch)
            -- remember where it is (for when it is folded again)
            self.pipeLeft = (x - cx) * lx + (z - cz) * lz
            self.pipeAhead = (x - cx) * math.cos(ch) + (z - cz) * math.sin(ch)
            return x, z, ch
        end
    end
    local left = self.pipeLeft
    if left == nil then
        left = GuidanceVehicle.pipeSide(combine) == GuidancePlan.SIDE_RIGHT and -Unload.PIPE_DEFAULT or Unload.PIPE_DEFAULT
    end
    local ahead = self.pipeAhead or -1
    local lx, lz = leftOf(ch)
    return cx + lx * left + math.cos(ch) * ahead, cz + lz * left + math.sin(ch) * ahead, ch
end

--- Where the tractor must be for its fill node to be under the pipe: x, z, heading
function Unload:placeUnderPipe(combine, node)
    local px, pz, ch = self:pipePoint(combine)
    local left, ahead = 0, -4
    if node then left, ahead = Base.offsetIn(self.vehicle, node) end
    local lx, lz = leftOf(ch)
    return px - math.cos(ch) * ahead - lx * left, pz - math.sin(ch) * ahead - lz * left, ch
end

function Unload:setServing(combine)
    for v, d in pairs(Unload.serving) do
        if d == self then Unload.serving[v] = nil end
    end
    if combine then Unload.serving[combine] = self end
    self.combine = combine
    local od = combine and combine.spec_guidance and combine.spec_guidance.driver
    if self.combineDriver and self.combineDriver ~= od then self.combineDriver.unloader = nil end
    self.combineDriver = od
    if od then od.unloader = self end
end

function Unload:delete()
    self:setServing(nil)
end

local UNLOAD_PHASES = {wait = "unloadWait", approach = "unloadDrive", follow = "unloadFollow", leave = "unloadLeave",
                       home = "unloadTrip"}

function Unload:getDriveData(dt, vX, vY, vZ)
    self.timer = self.timer + dt
    local vehicle = self.vehicle
    vehicle:guidanceSetHelperPhase(UNLOAD_PHASES[self.state])
    if self:isPaused() then return self:standStill() end
    if self.done then
        return self:standStill()
    end
    local level, node = self:trailerState()
    if self.state ~= "leave" and self.state ~= "home" and (level >= self.leaveLevel or node == nil) then
        -- full: out of the way, to where it started (the field edge), then on the road or stop
        self:setServing(nil)
        self.state = "leave"
        self:planTo(self.home.x, self.home.z, self.home.h + math.pi, 6)
    end
    if self.state == "wait" then
        if self.timer > 1000 then
            self.timer = 0
            local combine = self:pickCombine()
            if combine then
                self:setServing(combine)
                self.state = "approach"
                self.planTimer = math.huge
            end
        end
        vehicle:guidanceSetInfoText("NEEDS_UNLOADING", false)
        return self:standStill()
    elseif self.state == "approach" then
        local combine = self.combine
        if combine == nil or combine.isDeleted then
            self.state = "wait"
            return self:standStill()
        end
        local tx, tz, th = self:placeUnderPipe(combine, node)
        local x, z = Base.poseOf(vehicle)
        if dist(x, z, tx, tz) < 6 then
            self.state = "follow"
            return self:standStill()
        end
        self.planTimer = (self.planTimer or 0) + dt
        if self.follower == nil or self.planTimer > Unload.REPLAN then
            self.planTimer = 0
            self:planTo(tx - math.cos(th) * 2, tz - math.sin(th) * 2, th, Unload.APPROACH_BEHIND)
        end
        local gx, gz, fwd, speed, toStop, done = self:drivePath(dt, Base.SPEED, combine)
        if done then
            self.state = "follow"
        end
        return gx, gz, fwd, speed, toStop
    elseif self.state == "follow" then
        return self:follow(dt, node)
    elseif self.state == "leave" then
        local gx, gz, fwd, speed, toStop, done = self:drivePath(dt, Base.SPEED)
        if done then
            self.state = "home"
            self:onFull()
            return self:standStill()
        end
        return gx, gz, fwd, speed, toStop
    end
    return self:standStill()
end

--- Under the pipe: keep the fill node there, at the combine's speed
function Unload:follow(dt, node)
    local combine = self.combine
    if combine == nil or combine.isDeleted then
        self:setServing(nil)
        self.state = "wait"
        return self:standStill()
    end
    local harvester = GuidanceFieldworkDriver.findHarvester(combine)
    local od = self.combineDriver
    local x, z, h = Base.poseOf(self.vehicle)
    local tx, tz, th = self:placeUnderPipe(combine, node)
    local fx, fz = math.cos(th), math.sin(th)
    local behind = (tx - x) * fx + (tz - z) * fz
    local off = dist(x, z, tx, tz)
    -- the combine turns (ours tells), or we lost it: wait / come in again
    if od and od.isManeuvering and od:isManeuvering() then
        self.turnWait = true
        return self:standStill()
    end
    if self.turnWait or off > Unload.LOST then
        self.turnWait = nil
        self.state = "approach"
        self.follower = nil
        return self:standStill()
    end
    -- done with this combine: it is (nearly) empty and not waiting
    local cLevel = harvester and combineLevel(harvester) or 0
    local waiting = od and od.isWaitingForUnload and od:isWaitingForUnload()
    if cLevel < 0.03 and not waiting then
        self.emptyTimer = (self.emptyTimer or 0) + dt
        if self.emptyTimer > 4000 then
            self.emptyTimer = 0
            self:setServing(nil)
            self.state = "wait"
            return self:standStill()
        end
    else
        self.emptyTimer = 0
    end
    -- our combine holds on while we get into place
    if od and od.hold and behind < -3 then
        od:hold(300)
    end
    local cSpeed = combine.getLastSpeed and combine:getLastSpeed() or 0
    local speed = math.max(0, math.min(cSpeed + 8, cSpeed + Unload.FOLLOW_GAIN * behind))
    if cSpeed < 0.5 and math.abs(behind) < 0.4 then
        speed = 0
    end
    if speed > 0 and speed < 1.5 then speed = 1.5 end
    -- steer along the combine's line, to our place on it a few metres ahead
    local look = math.max(4, self.vehicle:getLastSpeed() / 3.6 * 1.5)
    local gx, gz = tx + fx * (look + math.max(0, behind)), tz + fz * (look + math.max(0, behind))
    self:checkStuck(dt, speed)
    return gx, gz, true, speed, math.max(0.5, behind)
end

--- Full at the field edge: the game's roads to the station, or stop for the player / AutoDrive
function Unload:onFull()
    local job = self.job
    if job and job.startDeliveryTrip and job:startDeliveryTrip() then
        return
    end
    self:finish(AIMessageGuidanceIsFull.new(), "NEEDS_UNLOADING")
end

-----------------------------------------------------------------------------------------------------------------------
-- The bale collector: a bale loader (or a wrapper) picks up (wraps) every bale on the field it starts on; a full
-- loader unloads where it started
-----------------------------------------------------------------------------------------------------------------------

GuidanceBaleDriver = setmetatable({}, {__index = Base})
local Bales = GuidanceBaleDriver
local Bales_mt = {__index = Bales}

Bales.APPROACH = 12 -- m straight in
Bales.PICK_SPEED = 4 -- km/h over the bale
Bales.TRIES = 3
-- bales a collector is after (two don't take the same)
Bales.taken = {}

function Bales.new(vehicle, job)
    local self = setmetatable({}, Bales_mt)
    Base.init(self, vehicle)
    self.job = job
    self.state = "find"
    self.failed = {}
    for _, v in ipairs(vehicle.getChildVehicles and vehicle:getChildVehicles() or {}) do
        if v.spec_baleLoader then self.loader = v end
        if v.spec_baleWrapper and not v.spec_baler then self.wrapper = v end
    end
    self.tool = self.loader or self.wrapper
    return self
end

function Bales.findTool(vehicle)
    for _, v in ipairs(vehicle.getChildVehicles and vehicle:getChildVehicles() or {}) do
        if v.spec_baleLoader or (v.spec_baleWrapper and not v.spec_baler) then return v end
    end
    return nil
end

--- The bales on our field it can take: list of {bale, x, z}
function Bales:bales()
    local out, seen = {}, {}
    local limits = g_currentMission.slotSystem and g_currentMission.slotSystem.objectLimits
    local entry = limits and SlotSystem and limits[SlotSystem.LIMITED_OBJECT_BALE]
    local farmId = self.vehicle:getOwnerFarmId()
    for _, bale in pairs(entry and entry.objects or {}) do
        local id = bale.id or bale
        if not seen[id] and bale.isa and Bale and bale:isa(Bale) and bale.nodeId and bale.nodeId ~= 0
                and entityExists(bale.nodeId) and bale.mountObject == nil then
            seen[id] = true
            local x, _, z = getWorldTranslation(bale.nodeId)
            local ok = (self.field == nil or self:isOnField(x, z))
                and (g_currentMission.accessHandler == nil or g_currentMission.accessHandler:canFarmAccess(farmId, bale))
                and (self.failed[id] or 0) < Bales.TRIES
                and (Bales.taken[id] == nil or Bales.taken[id] == self)
            if ok and self.loader then
                ok = self.loader.getBaleTypeByBale == nil or self.loader:getBaleTypeByBale(bale) ~= nil
            elseif ok and self.wrapper then
                ok = (bale.wrappingState or 0) <= 0 and (self.wrapper.getIsBaleWrappable == nil
                    or self.wrapper:getIsBaleWrappable(bale))
            end
            if ok then out[#out + 1] = {bale = bale, id = id, x = x, z = z} end
        end
    end
    return out
end

function Bales:isFull()
    local spec = self.loader and self.loader.spec_baleLoader
    if spec == nil then return false end
    return self.loader:getFillUnitFreeCapacity(spec.fillUnitIndex) <= 0.01
end

function Bales:hasBales()
    local spec = self.loader and self.loader.spec_baleLoader
    if spec == nil then return false end
    return self.loader:getFillUnitFillLevel(spec.fillUnitIndex) > 0.01
end

--- The grab point in our frame: left, ahead
function Bales:grabOffset()
    local tool = self.tool
    local spec = tool and (tool.spec_baleLoader or tool.spec_baleWrapper)
    local node = spec and spec.baleGrabber and spec.baleGrabber.grabNode or (tool and tool.rootNode)
    if node == nil then return 0, -4 end
    return Base.offsetIn(self.vehicle, node)
end

function Bales:release()
    for id, d in pairs(Bales.taken) do
        if d == self then Bales.taken[id] = nil end
    end
end

function Bales:delete()
    self:release()
end

local BALE_PHASES = {find = "balesFind", pick = "balesPick", home = "balesHome", unload = "balesUnload"}

function Bales:getDriveData(dt, vX, vY, vZ)
    local vehicle = self.vehicle
    vehicle:guidanceSetHelperPhase(BALE_PHASES[self.state])
    if self:isPaused() then return self:standStill() end
    if self.done or self.tool == nil then
        if not self.done then self:finish(AIMessageErrorNoValidFillTypeLoaded and AIMessageErrorNoValidFillTypeLoaded.new() or nil) end
        return self:standStill()
    end
    -- the loader in its work position
    local spec = self.loader and self.loader.spec_baleLoader
    if spec and not spec.isInWorkPosition and self.state ~= "unload" and self.state ~= "home"
            and spec.emptyState == (BaleLoader and BaleLoader.EMPTY_NONE or spec.emptyState) then
        self.loader:doStateChange(BaleLoader.CHANGE_BUTTON_WORK_TRANSPORT)
        return self:standStill()
    end
    -- a wrapper wrapping: wait; done: drop it
    local wspec = self.wrapper and self.wrapper.spec_baleWrapper
    if wspec and BaleWrapper then
        if wspec.baleWrapperState == BaleWrapper.STATE_WRAPPER_FINSIHED then
            self.wrapper:doStateChange(BaleWrapper.CHANGE_WRAPPER_START_DROP_BALE)
        end
        if wspec.baleWrapperState ~= BaleWrapper.STATE_NONE and self.state == "find" then
            return self:standStill()
        end
    end
    if self.state == "find" then
        self.timer = self.timer + dt
        if self:isFull() then
            self.state = "home"
            self:planTo(self.home.x, self.home.z, self.home.h, 8)
            return self:standStill()
        end
        if self.timer < 500 then return self:standStill() end
        self.timer = 0
        local x, z = Base.poseOf(vehicle)
        local best, bestD
        for _, b in ipairs(self:bales()) do
            local d = dist(x, z, b.x, b.z)
            if bestD == nil or d < bestD then best, bestD = b, d end
        end
        if best == nil then
            -- all done: what is on the loader goes to the stack, then finished
            if self:hasBales() then
                self.state = "home"
                self.lastRound = true
                self:planTo(self.home.x, self.home.z, self.home.h, 8)
                return self:standStill()
            end
            self:finish(AIMessageSuccessFinishedJob.new(), "FINISHED")
            return self:standStill()
        end
        self:release()
        Bales.taken[best.id] = self
        self.target = best
        -- over it with the grab point: from here, lined up, a bit past it
        local th = math.atan2(best.z - z, best.x - x)
        local tries = self.failed[best.id] or 0
        if tries == 1 then th = th + math.pi end
        if tries == 2 then th = th + math.pi / 2 end
        local left, ahead = self:grabOffset()
        local lx, lz = leftOf(th)
        local px = best.x - math.cos(th) * ahead - lx * left
        local pz = best.z - math.sin(th) * ahead - lz * left
        self:planTo(px + math.cos(th) * 3, pz + math.sin(th) * 3, th, Bales.APPROACH + 3)
        self.state = "pick"
        return self:standStill()
    elseif self.state == "pick" then
        local b = self.target
        local gone = b.bale.isDeleted or b.bale.mountObject ~= nil or (b.bale.nodeId and not entityExists(b.bale.nodeId))
        if spec and spec.grabberMoveState ~= nil then self.grabbing = true end
        if gone or (self.grabbing and spec and spec.grabberMoveState == nil) then
            self.grabbing = nil
            Bales.taken[b.id] = nil
            self.state = "find"
            return self:standStill()
        end
        local x, z = Base.poseOf(vehicle)
        local near = self.follower and self.follower:getRemaining() < Bales.APPROACH + 4
        local gx, gz, fwd, speed, toStop, done = self:drivePath(dt, near and Bales.PICK_SPEED or Base.SPEED)
        if self.wrapper and wspec and wspec.baleWrapperState ~= BaleWrapper.STATE_NONE then
            -- the wrapper took it
            Bales.taken[b.id] = nil
            self.state = "find"
            return self:standStill()
        end
        if done then
            -- went over it, nothing taken: try it again from another side, later
            self.failed[b.id] = (self.failed[b.id] or 0) + 1
            Bales.taken[b.id] = nil
            self.state = "find"
        end
        return gx, gz, fwd, speed, toStop
    elseif self.state == "home" then
        local gx, gz, fwd, speed, toStop, done = self:drivePath(dt, Base.SPEED)
        if done then
            self.state = "unload"
            self.unloadStarted = false
            self.timer = 0
            return self:standStill()
        end
        return gx, gz, fwd, speed, toStop
    elseif self.state == "unload" then
        return self:unload(dt)
    end
    return self:standStill()
end

--- Unloading the loader's stack where it started: start, creep forward while it pushes them off, back to work
function Bales:unload(dt)
    local loader, spec = self.loader, self.loader and self.loader.spec_baleLoader
    self.timer = self.timer + dt
    if loader == nil then
        self.state = "find"
        return self:standStill()
    end
    if not self.unloadStarted then
        if spec.emptyState == BaleLoader.EMPTY_NONE and (loader.getIsAutomaticBaleUnloadingAllowed == nil
                or loader:getIsAutomaticBaleUnloadingAllowed()) then
            loader:startAutomaticBaleUnloading()
            self.unloadStarted = true
            self.timer = 0
        elseif self.timer > 20000 then
            self:finish(AIMessageErrorBlockedByObject.new(), "IS_STUCK")
        end
        return self:standStill()
    end
    local busy = loader.getIsAutomaticBaleUnloadingInProgress and loader:getIsAutomaticBaleUnloadingInProgress()
    if busy and self.timer > 4000 and self.timer < 9000 then
        -- clear of the stack: a few metres on, slowly
        local x, z, h = Base.poseOf(self.vehicle)
        return x + math.cos(h) * 5, z + math.sin(h) * 5, true, 2, 1
    end
    local folding = loader.getIsBaleLoaderFoldingPlaying and loader:getIsBaleLoaderFoldingPlaying()
    if not busy and not folding and spec.emptyState == BaleLoader.EMPTY_NONE then
        if self.lastRound then
            self:finish(AIMessageSuccessFinishedJob.new(), "FINISHED")
        else
            self.state = "find"
        end
    end
    return self:standStill()
end

-----------------------------------------------------------------------------------------------------------------------
-- The silo compacter: up and down the bunker silo it starts on (or the nearest), lane by lane, forwards in and
-- backing out; waits while the silo is compacted, stops when it isn't being filled any more
-----------------------------------------------------------------------------------------------------------------------

GuidanceSiloDriver = setmetatable({}, {__index = Base})
local Silo = GuidanceSiloDriver
local Silo_mt = {__index = Silo}

Silo.SPEED = 7 -- km/h in
Silo.REVERSE = 6 -- km/h out
Silo.WALL = 0.5 -- m kept from the walls
Silo.END = 2 -- m kept from the ends
Silo.DONE = 99 -- % compacted: wait
Silo.AGAIN = 95 -- % compacted: on again

function Silo.new(vehicle, job)
    local self = setmetatable({}, Silo_mt)
    Base.init(self, vehicle)
    self.job = job
    local x, z = Base.poseOf(vehicle)
    self.silo, self.geo = Silo.findSilo(x, z)
    self.lane = 0
    self.state = "drive"
    -- a compacter roller: down
    for _, v in ipairs(vehicle.getChildVehicles and vehicle:getChildVehicles() or {}) do
        if v.spec_bunkerSiloCompacter and v.aiImplementStartLine then pcall(v.aiImplementStartLine, v) end
    end
    return self
end

--- The bunker silos of the map: list of silo objects
function Silo.allSilos()
    local list = {}
    local system = g_currentMission.placeableSystem
    for _, p in pairs(system and system.placeables or {}) do
        if p.spec_bunkerSilo and p.spec_bunkerSilo.bunkerSilo then
            list[#list + 1] = p.spec_bunkerSilo.bunkerSilo
        end
        if p.spec_multiBunkerSilo then
            for _, s in pairs(p.spec_multiBunkerSilo.bunkerSilos or {}) do list[#list + 1] = s end
        end
    end
    return list
end

--- A silo's shape: start (s), across (w, the width corner), along (h, the length corner)
function Silo.geometry(silo)
    local area = silo.bunkerSiloArea
    if area == nil then return nil end
    local a = area.inner or area
    if a.sx == nil then return nil end
    local ux, uz = a.hx - a.sx, a.hz - a.sz
    local length = math.sqrt(ux * ux + uz * uz)
    local wx, wz = a.wx - a.sx, a.wz - a.sz
    local width = math.sqrt(wx * wx + wz * wz)
    if length < 1 or width < 1 then return nil end
    return {sx = a.sx, sz = a.sz, ux = ux / length, uz = uz / length, vx = wx / width, vz = wz / width,
            length = length, width = width}
end

--- The silo at (or nearest to, within 60 m) x, z
function Silo.findSilo(x, z)
    local best, bestGeo, bestD
    for _, silo in ipairs(Silo.allSilos()) do
        local g = Silo.geometry(silo)
        if g then
            local dx, dz = x - g.sx, z - g.sz
            local along, across = dx * g.ux + dz * g.uz, dx * g.vx + dz * g.vz
            local outside = math.max(0, -along, along - g.length) + math.max(0, -across, across - g.width)
            if bestD == nil or outside < bestD then best, bestGeo, bestD = silo, g, outside end
        end
    end
    if bestD and bestD < 60 then return best, bestGeo end
    return nil
end

--- How wide a lane the combination rolls: the widest of the tractor and what it pulls (a roller), 3 m if unknown
function Silo:rollWidth()
    local w = 0
    for _, v in ipairs(self.vehicle.getChildVehicles and self.vehicle:getChildVehicles() or {self.vehicle}) do
        if v.size and v.size.width then w = math.max(w, v.size.width) end
    end
    return w > 1 and w or 3
end

--- The way for the next lane: in from the end we are at, to the far end, backing out again (shifting over to the
--- lane on the way in)
function Silo:laneWay()
    local g = self.geo
    local w = self:rollWidth()
    local usable = math.max(0.1, g.width - 2 * Silo.WALL - w)
    local lanes = math.max(1, math.ceil(usable / w) + 1)
    self.lane = self.lane % lanes + 1
    local across = Silo.WALL + w / 2 + (lanes > 1 and (self.lane - 1) * usable / (lanes - 1) or usable / 2)
    local function at(along, side)
        return g.sx + g.ux * along + g.vx * side, g.sz + g.uz * along + g.vz * side
    end
    local x, z = Base.poseOf(self.vehicle)
    local nowAcross = (x - g.sx) * g.vx + (z - g.sz) * g.vz
    local pts = {}
    local steps = math.max(2, math.floor((g.length - 2 * Silo.END) / 2))
    for k = 0, steps do
        local along = Silo.END + (g.length - 2 * Silo.END) * k / steps
        -- over to the lane in the first 10 m
        local blend = math.min(1, (along - Silo.END) / 10)
        local px, pz = at(along, nowAcross + (across - nowAcross) * blend)
        pts[#pts + 1] = {x = px, z = pz}
    end
    for k = steps - 1, 0, -1 do
        local along = Silo.END + (g.length - 2 * Silo.END) * k / steps
        local px, pz = at(along, across)
        pts[#pts + 1] = {x = px, z = pz, rev = true}
    end
    -- from where we are to the start of it
    table.insert(pts, 1, {x = x, z = z})
    self:followPoints(pts)
end

function Silo:getDriveData(dt, vX, vY, vZ)
    self.vehicle:guidanceSetHelperPhase(self.state == "wait" and "siloWait" or "siloDrive")
    if self:isPaused() then return self:standStill() end
    if self.done then return self:standStill() end
    if self.silo == nil or self.geo == nil then
        self:finish(AIMessageErrorBlockedByObject.new(), "IS_STUCK")
        return self:standStill()
    end
    local silo = self.silo
    if BunkerSilo and silo.state ~= nil and silo.state ~= BunkerSilo.STATE_FILL then
        -- closed or being emptied: done
        self:finish(AIMessageSuccessFinishedJob.new(), "FINISHED")
        return self:standStill()
    end
    local compacted = silo.compactedPercent or 0
    if self.state == "wait" then
        if compacted < Silo.AGAIN then self.state = "drive" end
        return self:standStill()
    end
    if self.follower == nil then
        self:laneWay()
    end
    local reversing = self.follower:isReversing()
    local gx, gz, fwd, speed, toStop, done = self:drivePath(dt, reversing and Silo.REVERSE or Silo.SPEED)
    if done then
        self.follower = nil
        if compacted >= Silo.DONE then self.state = "wait" end
        return self:standStill()
    end
    return gx, gz, fwd, speed, toStop
end

-- giving way: the field work helper's own rules (and the vehicle being served or chased is no obstacle)
function Base:giveWay(dt, maxSpeed, x, z, h, reversing)
    return GuidanceFieldworkDriver.giveWay(self, dt, maxSpeed, x, z, h, reversing)
end

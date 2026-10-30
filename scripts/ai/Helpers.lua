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
Unload.APPROACH_CHOPPER = 25 -- (beside a forage harvester, which stands until we're there: further, to be on its line)
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

--- A forage harvester (it throws straight into a trailer, it has no tank to speak of)
function Unload.isChopper(harvester)
    local spec = harvester and harvester.spec_combine
    if spec == nil then return false end
    if spec.isBufferCombine then return true end
    local c = harvester.getFillUnitCapacity and harvester:getFillUnitCapacity(spec.fillUnitIndex)
    return c ~= nil and c > 1e7
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
                -- a forage harvester calls all the time it works (it can't work without a trailer)
                if Unload.isChopper(harvester) then
                    local working = (od and od.state == GuidanceFieldworkDriver.STATE_DRIVING)
                        or (od == nil and v.getIsAIActive and v:getIsAIActive())
                    level = working and 2 or 0
                    call = 1
                end
                if (level >= call or waiting) and (bestLevel == nil or level > bestLevel) then
                    best, bestLevel = v, level
                end
            end
        end
    end
    return best
end

Unload.CHOP_SIDE_GAP = 1.5 -- m between a forage harvester and the trailer beside it
Unload.CHOP_BEHIND = 3 -- m between a forage harvester's back and the tractor behind it
Unload.REALIGN = 8 -- m it backs away from a standing forage harvester to come in again on the line

--- Beside a forage harvester (the side with no standing crop) or behind it (crop on both sides, e.g. opening a
--- field): where the trailer's fill point goes; looked at again every few seconds
function Unload:chopperPoint(combine, cx, cz, ch)
    local lx, lz = leftOf(ch)
    local w = combine.size and combine.size.width or 4
    local len = combine.size and combine.size.length or 9
    -- the side: decided as it starts a row (a new heading), kept along it
    local turned = self.chopHeading == nil or math.abs((ch - self.chopHeading + math.pi) % (2 * math.pi) - math.pi) > 1
    if self.chopSide == nil or turned then
        self.chopHeading = ch
        local side = w / 2 + Unload.CHOP_SIDE_GAP + 2
        local function crop(sign)
            if self.probe == nil then return false end
            local px, pz = cx + lx * side * sign, cz + lz * side * sign
            return self.probe:hasFruit(px, pz, 2)
        end
        local left, right = crop(1), crop(-1)
        if left and right then self.chopSide = 0
        elseif left then self.chopSide = -1
        elseif right then self.chopSide = 1
        else self.chopSide = self.chopSide ~= 0 and self.chopSide or 1 end
    end
    if self.chopSide == 0 then
        -- our tractor between it and the trailer: the fill point that much further back
        local back = len / 2 + Unload.CHOP_BEHIND + GuidanceCourseGenerator.VEHICLE_FRONT + math.max(0, -(self.fillAhead or -4))
        return cx - math.cos(ch) * back, cz - math.sin(ch) * back, ch
    end
    local off = (w / 2 + Unload.CHOP_SIDE_GAP + 1.5) * self.chopSide
    return cx + lx * off - math.cos(ch) * 1.5, cz + lz * off - math.sin(ch) * 1.5, ch
end

--- The pipe's discharge point: x, z (world), and the combine's heading
function Unload:pipePoint(combine)
    local harvester = GuidanceFieldworkDriver.findHarvester(combine)
    local cx, cz, ch = Base.poseOf(combine)
    if Unload.isChopper(harvester) then
        return self:chopperPoint(combine, cx, cz, ch)
    end
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
    local left, ahead = 0, -4
    if node then left, ahead = Base.offsetIn(self.vehicle, node) end
    self.fillAhead = ahead
    local px, pz, ch = self:pipePoint(combine)
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
                       home = "unloadTrip", toTruck = "unloadToTruck", overload = "unloadOverload", toHeap = "unloadToHeap",
                       heap = "unloadHeap"}

function Unload:getDriveData(dt, vX, vY, vZ)
    self.timer = self.timer + dt
    self.lastDt = dt
    local vehicle = self.vehicle
    vehicle:guidanceSetHelperPhase(UNLOAD_PHASES[self.state])
    if self:isPaused() then return self:standStill() end
    if self.done then
        return self:standStill()
    end
    local level, node = self:trailerState()
    local unloading = self.state == "leave" or self.state == "home" or self.state == "toTruck" or self.state == "overload"
        or self.state == "toHeap" or self.state == "heap"
    if not unloading and (level >= self.leaveLevel or node == nil) then
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
        local x, z, h = Base.poseOf(vehicle)
        -- there, or lined up behind the place: following from here
        local fx, fz = math.cos(th), math.sin(th)
        local behind = (tx - x) * fx + (tz - z) * fz
        local side = math.abs((tx - x) * fz - (tz - z) * fx)
        local turn = math.abs((h - th + math.pi) % (2 * math.pi) - math.pi)
        -- (beside a forage harvester only lined up: its place is close by it, and it stands until we're there)
        local chopper = Unload.isChopper(GuidanceFieldworkDriver.findHarvester(combine))
        local lined = behind > -2 and behind < 25 and side < (chopper and 1.2 or 3) and turn < 0.4
        if (chopper and lined) or (not chopper and dist(x, z, tx, tz) < 6) then
            self.state = "follow"
            return self:standStill()
        end
        -- a new way when the place has moved on (a forage harvester standing still: the way there driven to its end)
        self.planTimer = (self.planTimer or 0) + dt
        local moved = not chopper or self.planTarget == nil or dist(tx, tz, self.planTarget.x, self.planTarget.z) > 4
        if self.follower == nil or (self.planTimer > Unload.REPLAN and moved) then
            self.planTimer = 0
            self.planTarget = {x = tx, z = tz}
            self:planTo(tx - fx * 2, tz - fz * 2, th, chopper and Unload.APPROACH_CHOPPER or Unload.APPROACH_BEHIND)
        end
        local gx, gz, fwd, speed, toStop, done = self:drivePath(dt, Base.SPEED, combine)
        if done then
            -- (not lined up beside a forage harvester: a new way in)
            if chopper and not lined then
                self.follower = nil
                return self:standStill()
            end
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
    elseif self.state == "toTruck" or self.state == "toHeap" then
        local gx, gz, fwd, speed, toStop, done = self:drivePath(dt, Base.SPEED, self.truck)
        if done then
            self.state = self.state == "toTruck" and "overload" or "heap"
            return self:standStill()
        end
        return gx, gz, fwd, speed, toStop
    elseif self.state == "overload" then
        return self:overload(dt)
    elseif self.state == "heap" then
        return self:tipHeap(dt)
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
    local chopper = Unload.isChopper(harvester)
    if not chopper and cLevel < 0.03 and not waiting then
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
    -- a forage harvester that stands (it waits for us), and we're past our place or off its line: straight back
    -- 8 m, then in again along the line
    if chopper and cSpeed < 0.5 then
        local lateral = math.abs((tx - x) * fz - (tz - z) * fx)
        if self.realign or behind < -1 or (lateral > 1 and behind < 3) then
            if not self.realign then self.realigns = (self.realigns or 0) + 1 end
            -- (backed off twice and still not there: a new way in)
            if self.realigns > 2 then
                self.realign, self.realigns = nil, 0
                self.state = "approach"
                self.follower = nil
                return self:standStill()
            end
            self.realign = behind < Unload.REALIGN
            if self.realign then
                self:checkStuck(dt, 3)
                return x - math.cos(h) * 5, z - math.sin(h) * 5, false, 3, Unload.REALIGN - behind
            end
        end
    else
        self.realign = nil
        if cSpeed > 1 then self.realigns = 0 end
    end
    -- (the game stops a vehicle asked for less than about 2 km/h)
    if speed > 0 and speed < 2 then speed = 2 end
    -- steer along the combine's line, to our place on it a few metres ahead
    local look = math.max(4, self.vehicle:getLastSpeed() / 3.6 * 1.5)
    local gx, gz = tx + fx * (look + math.max(0, behind)), tz + fz * (look + math.max(0, behind))
    self:checkStuck(dt, speed)
    return gx, gz, true, speed, math.max(0.5, behind)
end

--- Full at the field edge: into a truck standing there (auger wagon), onto a heap (tipper), the game's roads to the
--- station, or stop for the player / AutoDrive
function Unload:onFull()
    local job = self.job
    local mode = job and job.unloadMode or 0
    if mode == Unload.MODE_TRUCK and self:startOverload() then
        return
    end
    if mode == Unload.MODE_HEAP and self:startHeap() then
        return
    end
    if job and job.startDeliveryTrip and job:startDeliveryTrip() then
        return
    end
    self:finish(AIMessageGuidanceIsFull.new(), "NEEDS_UNLOADING")
end

Unload.MODE_STATION = 0 -- (or stop when full: no station)
Unload.MODE_TRUCK = 1
Unload.MODE_HEAP = 2
Unload.TRUCK_REACH = 20 -- m off the field a truck may stand
Unload.CREEP = 1.5 -- km/h lining the pipe up / tipping

--- The auger wagon of the combination (pipe, no combine), or nil
function Unload.findAuger(vehicle)
    for _, v in ipairs(vehicle.getChildVehicles and vehicle:getChildVehicles() or {}) do
        if v ~= vehicle and v.spec_pipe and not v.spec_combine and v.getCurrentDischargeNode then return v end
    end
    return nil
end

--- The tipper of the combination and its discharge node that tips onto the ground (the rear one first), or nil
function Unload.findTipper(vehicle)
    for _, v in ipairs(vehicle.getChildVehicles and vehicle:getChildVehicles() or {}) do
        if v ~= vehicle and v.spec_trailer and v.spec_dischargeable then
            local best, bestX
            for _, node in ipairs(v.spec_dischargeable.dischargeNodes or {}) do
                if node.canDischargeToGround and node.node then
                    local x = math.abs((localToLocal(node.node, v.rootNode, 0, 0, 0)))
                    if bestX == nil or x < bestX then best, bestX = node, x end
                end
            end
            if best then return v, best end
        end
    end
    return nil
end

local function wagonLevel(v)
    local node = v:getCurrentDischargeNode()
    local ix = node and node.fillUnitIndex or 1
    local c = v:getFillUnitCapacity(ix)
    return (c and c > 0) and v:getFillUnitFillLevel(ix) / c or 0, node
end

--- The truck to empty into: a trailer standing on or by our field, not ours, that takes what we have; and its fill
--- point (the nearest)
function Unload:findTruck(fillType)
    local x, z = Base.poseOf(self.vehicle)
    local best, bestNode, bestD
    local ours = {}
    for _, v in ipairs(self.vehicle:getChildVehicles() or {}) do ours[v] = true end
    for _, v in pairs(g_currentMission.vehicleSystem.vehicles or {}) do
        if not ours[v] and v.spec_trailer and v.getFillUnits and v.rootNode then
            local root = v.getRootVehicle and v:getRootVehicle() or v
            local tx, _, tz = getWorldTranslation(v.rootNode)
            local near = self.field == nil or self:isOnField(tx, tz)
                or (GuidanceGeo.outlineIndex and dist(x, z, tx, tz) < 400 and self:distToField(tx, tz) < Unload.TRUCK_REACH)
            if near and (root.getLastSpeed == nil or root:getLastSpeed() < 0.5) then
                for ix in ipairs(v:getFillUnits()) do
                    local free = v:getFillUnitFreeCapacity(ix, fillType, self.vehicle:getOwnerFarmId())
                    local takes = fillType == nil or v.getFillUnitSupportsFillType == nil or v:getFillUnitSupportsFillType(ix, fillType)
                    local node = v.getFillUnitExactFillRootNode and v:getFillUnitExactFillRootNode(ix)
                    if takes and free and free > 1 and node then
                        local nx, _, nz = getWorldTranslation(node)
                        local d = dist(x, z, nx, nz)
                        if bestD == nil or d < bestD then best, bestNode, bestD = v, node, d end
                    end
                end
            end
        end
    end
    return best, bestNode
end

function Unload:distToField(x, z)
    if self.field == nil then return 0 end
    self.fieldIndex = self.fieldIndex or GuidanceGeo.outlineIndex(self.field, 10)
    if self.fieldIndex:isInside({x = x, y = z}) then return 0 end
    local c, d = self.fieldIndex:closest({x = x, y = z}, 200)
    return c and d or math.huge
end

function Unload:startOverload()
    local auger = Unload.findAuger(self.vehicle)
    if auger == nil then return false end
    local _, node = wagonLevel(auger)
    local ft = node and auger.getDischargeFillType and auger:getDischargeFillType(node)
    local truck, fillNode = self:findTruck(ft)
    if truck == nil then
        Guidance.info("%s: no truck at the field edge to empty into", Guidance.vehicleName(self.vehicle))
        return false
    end
    self.auger, self.truck, self.truckNode = auger, truck, fillNode
    -- alongside the truck, the pipe towards it: the way that gets there nearer
    local px, _, pz = getWorldTranslation(fillNode)
    local th0 = select(3, Base.poseOf(truck.getRootVehicle and truck:getRootVehicle() or truck))
    local left, ahead = Base.offsetIn(self.vehicle, node.node)
    local x, z = Base.poseOf(self.vehicle)
    local best
    for _, th in ipairs({th0, th0 + math.pi}) do
        local lx, lz = leftOf(th)
        local tx = px - math.cos(th) * ahead - lx * left
        local tz = pz - math.sin(th) * ahead - lz * left
        local d = dist(x, z, tx, tz)
        if best == nil or d < best.d then best = {x = tx, z = tz, h = th, d = d} end
    end
    self.overloadTarget = best
    self:planTo(best.x, best.z, best.h, 15)
    self.state = "toTruck"
    Guidance.info("%s: emptying into %s", Guidance.vehicleName(self.vehicle), Guidance.vehicleName(truck))
    return true
end

local function setPipe(v, open)
    local spec = v.spec_pipe
    if spec == nil or (spec.numStates or 0) <= 1 then return end
    local target = open and 2 or 1
    if spec.currentState ~= target and spec.currentState ~= 0 and spec.targetState ~= target
            and (v.getIsPipeStateChangeAllowed == nil or v:getIsPipeStateChangeAllowed(target)) then
        v:setPipeState(target)
    end
end

--- At the truck: the pipe out, creep until it is over the truck's fill point, empty; then back to wait
function Unload:overload(dt)
    local auger = self.auger
    local level, node = wagonLevel(auger)
    setPipe(auger, true)
    if auger.spec_pipe then auger.spec_pipe.automaticDischarge = true end
    local px, _, pz = getWorldTranslation(self.truckNode)
    local x, z, h = Base.poseOf(self.vehicle)
    local nx, _, nz = getWorldTranslation(node.node)
    local along = (px - nx) * math.cos(h) + (pz - nz) * math.sin(h)
    if level < 0.002 then
        -- empty: pipe in, back to wait for the combines
        setPipe(auger, false)
        self.state = "wait"
        self.auger, self.truck = nil, nil
        return self:standStill()
    end
    local filling = auger.getDischargeState and auger:getDischargeState() ~= Dischargeable.DISCHARGE_STATE_OFF
    if not filling and math.abs(along) < 0.3 then
        -- not filling over the fill point: this truck is full (or out of reach): another one, or stop full
        self.stallTimer = (self.stallTimer or 0) + dt
        if self.stallTimer > 4000 then
            self.stallTimer = 0
            setPipe(auger, false)
            if not self:startOverload() then
                self:finish(AIMessageGuidanceIsFull.new(), "NEEDS_UNLOADING")
            end
        end
        return self:standStill()
    end
    self.stallTimer = 0
    if math.abs(along) < 0.3 then
        return self:standStill()
    end
    -- creep to it (forward or back)
    local fwd = along > 0
    local gx, gz = x + math.cos(h) * (fwd and 5 or -5), z + math.sin(h) * (fwd and 5 or -5)
    return gx, gz, fwd, Unload.CREEP, math.abs(along)
end

function Unload:startHeap()
    local tipper, node = Unload.findTipper(self.vehicle)
    if tipper == nil then return false end
    self.tipper, self.tipNode = tipper, node
    -- the heap: where it started, along its way then; the next load where the last one ended
    local h = self.heapNext or self.home
    self:planTo(h.x, h.z, h.h, 12)
    self.state = "toHeap"
    return true
end

--- Tipping onto the heap: the rear tip side; standing while it runs out, on slowly where the ground is full
function Unload:tipHeap(dt)
    local tipper, node = self.tipper, self.tipNode
    local ix = node.fillUnitIndex or 1
    local level = tipper:getFillUnitFillLevel(ix)
    local x, z, h = Base.poseOf(self.vehicle)
    if not self.tipSideSet and tipper.setPreferedTipSide and tipper.spec_trailer then
        local map = tipper.spec_trailer.dischargeNodeIndexToTipSide
        local side = map and node.index and map[node.index]
        if side and side.index then tipper:setPreferedTipSide(side.index) end
        self.tipSideSet = true
    end
    if level <= 0.01 then
        tipper:setManualDischargeState(Dischargeable.DISCHARGE_STATE_OFF)
        if tipper.getAIHasFinishedDischarge == nil or tipper:getAIHasFinishedDischarge(node) then
            -- the next load continues the heap here
            self.heapNext = {x = x, z = z, h = h}
            self.state = "wait"
            self.tipSideSet = nil
        end
        return self:standStill()
    end
    local canTip = tipper.getCanDischargeToGround and tipper:getCanDischargeToGround(node)
    if canTip then
        tipper:setManualDischargeState(Dischargeable.DISCHARGE_STATE_GROUND)
    end
    -- still running out here: stand; the ground here full: on a bit
    local falling = self.lastTipLevel and level < self.lastTipLevel - 0.01
    self.lastTipLevel = level
    if falling then
        return self:standStill()
    end
    return x + math.cos(h) * 5, z + math.sin(h) * 5, true, Unload.CREEP, 5
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
Bales.BALER_CLEAR = 12 -- m from a working baler: its bales left alone for now (it may be dropping the next there)
-- bales a collector is after (two don't take the same)
Bales.taken = {}

--- The balers switched on (or driven by a helper) on our field: list of {x, z}
function Bales:workingBalers()
    local out = {}
    for _, v in pairs(g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles or {}) do
        if v.spec_baler and v.rootNode then
            local root = v.getRootVehicle and v:getRootVehicle() or v
            local on = (v.getIsTurnedOn and v:getIsTurnedOn()) or (root.getIsAIActive and root:getIsAIActive())
            if on and root ~= self.vehicle then
                local x, _, z = getWorldTranslation(v.rootNode)
                if self.field == nil or self:isOnField(x, z) then out[#out + 1] = {x = x, z = z} end
            end
        end
    end
    return out
end

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
    -- unwrapped bales the wrapper can't wrap (straw...): counted, to say so at the end
    self.cantWrap = 0
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
                local unwrapped = (bale.wrappingState or 0) <= 0
                ok = unwrapped and (self.wrapper.getIsBaleWrappable == nil or self.wrapper:getIsBaleWrappable(bale))
                if unwrapped and not ok then self.cantWrap = self.cantWrap + 1 end
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
    vehicle:guidanceSetHelperPhase(self.state == "find" and self.waitingForBaler and "balesWaitBaler"
        or BALE_PHASES[self.state])
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
        local balers = self:workingBalers()
        local best, bestD
        for _, b in ipairs(self:bales()) do
            local d = dist(x, z, b.x, b.z)
            local clear = true
            for _, bl in ipairs(balers) do
                if dist(b.x, b.z, bl.x, bl.z) < Bales.BALER_CLEAR then clear = false end
            end
            if clear and (bestD == nil or d < bestD) then best, bestD = b, d end
        end
        if best == nil and #balers > 0 then
            -- a baler still at it on this field: more bales are coming
            self.waitingForBaler = true
            vehicle:guidanceSetHelperPhase("balesWaitBaler")
            return self:standStill()
        end
        self.waitingForBaler = nil
        if best == nil then
            -- all done: what is on the loader goes to the stack, then finished
            if self:hasBales() then
                self.state = "home"
                self.lastRound = true
                self:planTo(self.home.x, self.home.z, self.home.h, 8)
                return self:standStill()
            end
            if (self.cantWrap or 0) > 0 then
                Guidance.info("%s: %d bale(s) here this wrapper can't wrap", Guidance.vehicleName(vehicle), self.cantWrap)
                vehicle:guidanceSetHelperPhase("balesCantWrap")
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

-----------------------------------------------------------------------------------------------------------------------
-- The loader: a wheel loader, telehandler or tractor front loader with a bucket, loading a heap into the trailers
-- standing by it. Started facing the heap. The arm and the bucket are moved through the game's moving tools (on the
-- server; the game sends them to the clients); which way each goes is learnt from watching the bucket.
-----------------------------------------------------------------------------------------------------------------------

GuidanceShovelDriver = setmetatable({}, {__index = Base})
local Shovel = GuidanceShovelDriver
local Shovel_mt = {__index = Shovel}

Shovel.SPEED_IN = 4 -- km/h into the heap
Shovel.SPEED = 10 -- km/h between heap and trailer
Shovel.CREEP = 2 -- km/h up to the trailer, the bucket over it
Shovel.REACH = 40 -- m ahead of where it started the heap is looked for
Shovel.TRAILER_REACH = 80 -- m from where it started a trailer may stand
Shovel.LANES = 4 -- lanes each side of the first one (a bucket's width apart)
Shovel.LOAD_HEIGHT = 0.05 -- m, the bucket over the ground digging in
Shovel.CARRY_HEIGHT = 0.6 -- m carrying
Shovel.UNLOAD_MIN = 3.5 -- m at least over the ground before going over a trailer's side
Shovel.LEVEL, Shovel.CARRY, Shovel.PRE = 90, 55, 45 -- degrees: the bucket flat, tilted back to carry, before tipping
Shovel.POSE_TIME = 10000 -- ms a pose may take; then on as it is
Shovel.STUCK_IN = 4000 -- ms not getting on in the heap: out with what it has
Shovel.TIP_WAIT = 5000 -- ms tipping without the bucket getting emptier: the trailer is full
Shovel.LOOK_AHEAD = 6 -- m ahead of the bucket the lane is looked at for more

--- The bucket and the arm and bucket tools of the combination: {shovel, node, tipNode, maxTip, arm, tilt}, or nil
function Shovel.findTools(vehicle)
    local out = {}
    for _, v in ipairs(vehicle.getChildVehicles and vehicle:getChildVehicles() or {vehicle}) do
        local sp = v.spec_shovel
        if out.shovel == nil and sp and sp.shovelNodes and sp.shovelNodes[1] then
            out.shovel, out.node = v, sp.shovelNodes[1]
            local info = sp.shovelDischargeInfo
            out.tipNode = info and info.node or sp.shovelNodes[1].node
            out.maxTip = info and info.maxSpeedAngle and math.deg(info.maxSpeedAngle) or 130
        end
        local cyl = v.spec_cylindered
        for _, tool in ipairs(cyl and cyl.movingTools or {}) do
            if tool.axis == "AXIS_FRONTLOADER_ARM" and out.arm == nil then
                out.arm = {tool = tool, owner = v, sign = 1}
            elseif tool.axis == "AXIS_FRONTLOADER_TOOL" and out.tilt == nil then
                out.tilt = {tool = tool, owner = v, sign = 1}
            end
        end
    end
    if out.shovel and out.arm and out.tilt then return out end
    return nil
end

function Shovel.new(vehicle, job)
    local self = setmetatable({}, Shovel_mt)
    Base.init(self, vehicle)
    self.job = job
    self.tools = Shovel.findTools(vehicle)
    self.lane = 1
    self.fullTrailers = {}
    self.state = "start"
    self.width = math.max(1.5, ((self.tools and self.tools.node.width) or 2.5) * 0.9)
    return self
end

-- the bucket: how high over the ground, how tipped (degrees: 90 flat, less tilted back, more tipped)
function Shovel:height()
    local x, y, z = getWorldTranslation(self.tools.node.node)
    return y - getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
end

function Shovel:tiltAngle()
    local _, dy = localDirectionToWorld(self.tools.tipNode, 0, 0, 1)
    return math.deg(math.acos(math.max(-1, math.min(1, dy))))
end

function Shovel:fill()
    local v, ix = self.tools.shovel, self.tools.node.fillUnitIndex or 1
    if v.getFillUnitFillLevelPercentage then return v:getFillUnitFillLevelPercentage(ix) end
    local c = v:getFillUnitCapacity(ix)
    return (c and c > 0) and v:getFillUnitFillLevel(ix) / c or 0
end

--- Moves a tool towards target (as measure() sees it), tol: near enough. Which way is which is learnt from its first
--- moves (the error has to shrink); at an end stop it is as far as it goes. True when there.
function Shovel:moveTool(t, target, measure, tol, dt)
    local err = target - measure()
    if math.abs(err) <= tol then
        t.window = nil
        return true
    end
    local tool = t.tool
    local rot = (tool.rotSpeed or 0) ~= 0 or (tool.transSpeed or 0) == 0
    local speed = rot and math.abs((tool.rotSpeed or 0) ~= 0 and tool.rotSpeed or 0.0005) or math.abs(tool.transSpeed)
    local f = math.max(0.3, math.min(1, math.abs(err) / (tol * 5)))
    local dir = (err > 0 and 1 or -1) * t.sign
    local move = rot and Cylindered.setToolRotation or Cylindered.setToolTranslation
    if move(t.owner, tool, speed * f * dir, dt) then
        Cylindered.setDirty(t.owner, tool)
        local cyl = t.owner.spec_cylindered
        if tool.dirtyFlag then t.owner:raiseDirtyFlags(tool.dirtyFlag) end
        if cyl and cyl.cylinderedDirtyFlag then t.owner:raiseDirtyFlags(cyl.cylinderedDirtyFlag) end
        t.atEnd = 0
    else
        -- at an end stop: the wrong way round (not learnt yet), or as far as it goes
        t.atEnd = (t.atEnd or 0) + dt
        if t.atEnd > 300 then
            t.atEnd = 0
            if t.verified then return true end
            t.sign = -t.sign
            t.flips = (t.flips or 0) + 1
            if t.flips > 2 then t.verified = true end
        end
        return false
    end
    t.window = t.window or {time = 0, err = math.abs(err)}
    t.window.time = t.window.time + dt
    if t.window.time > 400 then
        local now = math.abs(err)
        if now < t.window.err - 1e-3 then
            t.verified = true
        elseif now > t.window.err + 1e-3 and not t.verified then
            t.sign = -t.sign
        end
        t.window = {time = 0, err = now}
    end
    return false
end

--- Arm and bucket towards a pose (until both have learnt their way, one after the other); true when there
function Shovel:pose(dt, height, tilt)
    local tools = self.tools
    local tiltOk = self:moveTool(tools.tilt, tilt, function() return self:tiltAngle() end, 2.5, dt)
    if not tiltOk and not (tools.tilt.verified and tools.arm.verified) then return false end
    local armOk = self:moveTool(tools.arm, height, function() return self:height() end, 0.12, dt)
    return tiltOk and armOk
end

--- Standing until the pose is there (or POSE_TIME is up), then the next state
function Shovel:poseThen(dt, height, tilt, nextState)
    self.poseTimer = (self.poseTimer or 0) + dt
    if self:pose(dt, height, tilt) or self.poseTimer > Shovel.POSE_TIME then
        self.poseTimer = 0
        self.state = nextState
    end
    return self:standStill()
end

-- along the line it started on (its heading) and across it: where (x, z) is
function Shovel:along(x, z)
    local h = self.home
    return (x - h.x) * math.cos(h.h) + (z - h.z) * math.sin(h.h)
end

function Shovel:lanePoint(along, lane)
    local h = self.home
    local lx, lz = leftOf(h.h)
    local off = Shovel.laneOffset(lane) * self.width
    return h.x + math.cos(h.h) * along + lx * off, h.z + math.sin(h.h) * along + lz * off
end

--- lanes: 0, one to the left, one to the right, two to the left...
function Shovel.laneOffset(lane)
    if lane <= 1 then return 0 end
    local k = math.floor(lane / 2)
    return (lane % 2 == 0) and k or -k
end

local function heapType(ft)
    if ft == nil or ft == 0 or (FillType and ft == FillType.UNKNOWN) then return nil end
    return ft
end

--- What lies on the ground across the lane at 'along' (a line as wide as the bucket), or nil
function Shovel:materialAt(along, lane)
    local x, z = self:lanePoint(along, lane)
    local lx, lz = leftOf(self.home.h)
    local half = self.width / 2
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
    return heapType(DensityMapHeightUtil.getFillTypeAtLine(x + lx * half, y, z + lz * half, x - lx * half, y,
        z - lz * half, 0.5))
end

--- Where the heap starts on the lane (along), its material; nil when there's none within REACH
function Shovel:findHeap(lane, from)
    for a = from or 1, Shovel.REACH, 0.5 do
        local ft = self:materialAt(a, lane)
        if ft then return a, ft end
    end
    return nil
end

--- A trailer to load: standing near where it started, not ours, room for the heap's material; and its fill node
function Shovel:findTrailer()
    local ours = {}
    for _, v in ipairs(self.vehicle:getChildVehicles() or {}) do ours[v] = true end
    local best, bestNode, bestD
    for _, v in pairs(g_currentMission.vehicleSystem.vehicles or {}) do
        if not ours[v] and not self.fullTrailers[v] and v.spec_trailer and v.getFillUnits and v.rootNode then
            local root = v.getRootVehicle and v:getRootVehicle() or v
            local tx, _, tz = getWorldTranslation(v.rootNode)
            local d = dist(tx, tz, self.home.x, self.home.z)
            if d < Shovel.TRAILER_REACH and (root.getLastSpeed == nil or root:getLastSpeed() < 0.5) then
                for ix in ipairs(v:getFillUnits()) do
                    local free = v:getFillUnitFreeCapacity(ix, self.fillType, self.vehicle:getOwnerFarmId())
                    local takes = v.getFillUnitSupportsFillType == nil or v:getFillUnitSupportsFillType(ix, self.fillType)
                    local node = v.getFillUnitExactFillRootNode and v:getFillUnitExactFillRootNode(ix)
                    if takes and free and free > 1 and node and (bestD == nil or d < bestD) then
                        best, bestNode, bestD = v, node, d
                    end
                end
            end
        end
    end
    return best, bestNode
end

--- Square to the trailer's side nearer to us, the bucket's reach plus 6 m out: where to drive to, facing it
function Shovel:trailerApproach()
    local px, _, pz = getWorldTranslation(self.trailerNode)
    local root = self.trailer.getRootVehicle and self.trailer:getRootVehicle() or self.trailer
    local _, _, th = Base.poseOf(self.trailer.getAIDirectionNode and self.trailer or root)
    local nx, nz = leftOf(th)
    local x, z = Base.poseOf(self.vehicle)
    if (x - px) * nx + (z - pz) * nz < 0 then nx, nz = -nx, -nz end
    local _, ahead = Base.offsetIn(self.vehicle, self.tools.node.node)
    local out = math.max(0, ahead) + 6
    return px + nx * out, pz + nz * out, math.atan2(-nz, -nx), px, pz
end

local SHOVEL_PHASES = {start = "shovelLoad", toLane = "shovelBack", lower = "shovelLoad", dig = "shovelLoad",
                       out = "shovelLoad", toTrailer = "shovelToTrailer", raise = "shovelToTrailer",
                       creep = "shovelToTrailer", tip = "shovelTip", away = "shovelBack"}

function Shovel:finishWith(phase, message)
    self.vehicle:guidanceSetHelperPhase(phase)
    self:finish(message or AIMessageSuccessFinishedJob.new())
end

function Shovel:getDriveData(dt, vX, vY, vZ)
    if self.done then return self:standStill() end
    self.vehicle:guidanceSetHelperPhase(SHOVEL_PHASES[self.state])
    if self:isPaused() then return self:standStill() end
    if self.tools == nil then
        self:finishWith("shovelNoHeap", AIMessageErrorBlockedByObject.new())
        return self:standStill()
    end
    local x, z, h = Base.poseOf(self.vehicle)
    local state = self.state
    if state == "start" then
        -- the heap: straight ahead (on the first lane, or one beside it)
        for lane = 1, 3 do
            local from, ft = self:findHeap(lane)
            if from then
                self.heapFrom, self.fillType = from, ft
                break
            end
        end
        if self.heapFrom == nil then
            self:finishWith("shovelNoHeap", AIMessageErrorBlockedByObject.new())
            return self:standStill()
        end
        self.state = "lower"
        return self:standStill()
    elseif state == "toLane" then
        local gx, gz, fwd, speed, toStop, done = self:drivePath(dt, Shovel.SPEED, self.trailer)
        self:pose(dt, Shovel.CARRY_HEIGHT, Shovel.CARRY)
        if done then self.state = "lower" end
        return gx, gz, fwd, speed, toStop
    elseif state == "lower" then
        return self:poseThen(dt, Shovel.LOAD_HEIGHT, Shovel.LEVEL, "dig")
    elseif state == "dig" then
        self:pose(dt, Shovel.LOAD_HEIGHT, Shovel.LEVEL)
        local _, ahead = Base.offsetIn(self.vehicle, self.tools.node.node)
        local bucketAlong = self:along(x, z) + ahead
        local fill = self:fill()
        -- the end of the heap on this lane: nothing from the bucket on for a while (what's left further on: on to it)
        local ended = false
        if bucketAlong > self.heapFrom + 0.5 then
            ended = true
            for a = bucketAlong, bucketAlong + Shovel.LOOK_AHEAD, 0.5 do
                if self:materialAt(a, self.lane) then
                    ended = false
                    break
                end
            end
        end
        local speed = Shovel.SPEED_IN
        if self.vehicle:getLastSpeed() < 0.3 then
            self.stuckIn = (self.stuckIn or 0) + dt
        else
            self.stuckIn = 0
        end
        if fill >= 0.97 or ended or self.stuckIn > Shovel.STUCK_IN or bucketAlong > Shovel.REACH + 5 then
            self.stuckIn = 0
            if ended and fill < 0.3 then self.laneDone = true end
            self.state = "out"
            return self:standStill()
        end
        local gx, gz = self:lanePoint(self:along(x, z) + 5, self.lane)
        return gx, gz, true, speed, 5
    elseif state == "out" then
        -- straight back out of the heap, carrying
        self:pose(dt, Shovel.CARRY_HEIGHT, Shovel.CARRY)
        local back = self:along(x, z)
        if back <= 0.5 then
            if self:fill() > 0.1 then
                self.emptyDigs = 0
                self.state = "toTrailer"
                self.follower = nil
            else
                -- nothing got: the next lane; a whole round of them without anything: the heap is done
                self.emptyDigs = (self.emptyDigs or 0) + 1
                if self.emptyDigs > 2 * Shovel.LANES + 1 then
                    self:finishWith("shovelEmpty")
                else
                    self:nextLane()
                end
            end
            return self:standStill()
        end
        local gx, gz = self:lanePoint(back - 5, self.lane)
        self:checkStuck(dt, 4)
        return gx, gz, false, 5, back
    elseif state == "toTrailer" then
        if self.follower == nil then
            self.trailer, self.trailerNode = self:findTrailer()
            if self.trailer == nil then
                self:finishWith("shovelNoTrailer")
                return self:standStill()
            end
            local ax, az, ah = self:trailerApproach()
            self.approachH = ah
            self:planTo(ax, az, ah, 8)
        end
        self:pose(dt, Shovel.CARRY_HEIGHT, Shovel.CARRY)
        local gx, gz, fwd, speed, toStop, done = self:drivePath(dt, Shovel.SPEED, self.trailer)
        if done then
            self.state = "raise"
            local tx, ty, tz = getWorldTranslation(self.trailerNode)
            local ground = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, tx, 0, tz)
            self.unloadHeight = math.max(Shovel.UNLOAD_MIN, (ty or 0) - ground + 1)
            return self:standStill()
        end
        return gx, gz, fwd, speed, toStop
    elseif state == "raise" then
        return self:poseThen(dt, self.unloadHeight, Shovel.PRE, "creep")
    elseif state == "creep" then
        -- in until the bucket is over the trailer's opening
        self:pose(dt, self.unloadHeight, Shovel.PRE)
        local px, _, pz = getWorldTranslation(self.trailerNode)
        local bx, _, bz = getWorldTranslation(self.tools.node.node)
        local ah = self.approachH
        local togo = (px - bx) * math.cos(ah) + (pz - bz) * math.sin(ah)
        self.creepFrom = self.creepFrom or {x = x, z = z}
        if togo <= 0.3 or dist(x, z, self.creepFrom.x, self.creepFrom.z) > 10 then
            self.creepFrom = nil
            self.state = "tip"
            self.tipLevel, self.tipTimer = self:fill(), 0
            return self:standStill()
        end
        return x + math.cos(ah) * 5, z + math.sin(ah) * 5, true, Shovel.CREEP, togo
    elseif state == "tip" then
        self:pose(dt, self.unloadHeight, self.tools.maxTip + 5)
        local fill = self:fill()
        if fill <= 0.01 then
            self.state = "away"
            self.awayFrom = {x = x, z = z}
            return self:standStill()
        end
        if fill < self.tipLevel - 0.005 then
            self.tipLevel, self.tipTimer = fill, 0
        else
            self.tipTimer = self.tipTimer + dt
            if self.tipTimer > Shovel.TIP_WAIT then
                -- not going in: the trailer is full; the rest into the next one
                self.fullTrailers[self.trailer] = true
                self.state = "away"
                self.awayFrom = {x = x, z = z}
            end
        end
        return self:standStill()
    elseif state == "away" then
        -- back off, the bucket tilted back up (the arm stays up until clear of the trailer)
        local cleared = dist(x, z, self.awayFrom.x, self.awayFrom.z) > 6
        if cleared then
            if self:fill() > 0.1 then
                -- some still in it (the trailer was full): to the next one
                self.state = "toTrailer"
                self.follower = nil
            else
                self:toLane()
            end
            return self:standStill()
        end
        self:pose(dt, self.unloadHeight, Shovel.CARRY)
        self:checkStuck(dt, 4)
        return x - math.cos(h) * 5, z - math.sin(h) * 5, false, 5, 6
    end
    return self:standStill()
end

--- Back to the start of the lane to dig
function Shovel:toLane()
    local lx, lz = self:lanePoint(0, self.lane)
    self:planTo(lx, lz, self.home.h, 6)
    self.state = "toLane"
end

--- This lane is dug out: the next one with something on it, or the heap is done
function Shovel:nextLane()
    self.laneDone = nil
    for lane = self.lane + 1, 2 * Shovel.LANES + 1 do
        local from = self:findHeap(lane, math.max(1, (self.heapFrom or 1) - 5))
        if from then
            self.lane = lane
            self:toLane()
            return
        end
    end
    -- and the first lanes once more (the heap slides into them)
    for lane = 1, self.lane do
        if self:findHeap(lane, math.max(1, (self.heapFrom or 1) - 5)) then
            self.lane = lane
            self:toLane()
            return
        end
    end
    self:finishWith("shovelEmpty")
end

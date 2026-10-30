-- Guidance: drives a course with the game's field work helper (AIFieldWorker). Installed as its drive strategy:
-- the game calls getDriveData() every frame and steers to the point we return. Server only.
--
-- It lowers and raises the implements where the course says, slows down for curves, backs up where the course
-- says (three-point turns, square corners), reports turns to the implements (plows need that), keeps the work
-- area on the course when the implement works to one side, and stops when the vehicle is full, out of seed or
-- fuel (so AutoDrive can take over). A full combine with AutoDrive unloaders around waits for them instead.
-- It gives up instead of standing around when it is stuck.

GuidanceFieldworkDriver = {}
local Driver = GuidanceFieldworkDriver
local Driver_mt = {__index = Driver}

Driver.STATE_START = 1
Driver.STATE_PREPARE = 2
Driver.STATE_DRIVING = 3
Driver.STATE_WAIT_LOWER = 4
Driver.STATE_DONE = 5
Driver.STATE_WAIT_UNLOAD = 6

Driver.TURN_SPEED = 10 -- km/h, turns and connections
Driver.REVERSE_SPEED = 5
Driver.LATERAL_ACCEL = 1.2 -- m/s², limits speed in curves
Driver.STUCK_TIME = 20000 -- ms without progress while we want to move
Driver.LOST_DISTANCE = 15 -- m off the course
Driver.LOST_TIME = 5000
Driver.LOWER_TIMEOUT = 10000
Driver.FILL_CHECK_INTERVAL = 1000
Driver.OFFSET_CHECK_INTERVAL = 500
Driver.OFFSET_RATE = 1 -- m/s the side offset may change (a plow turning over)
Driver.CONVOY_GAP_EXTRA = 12 -- m between convoy members along the course, on top of a work width
Driver.CONVOY_MAX_LAG = 60 -- m a member may fall back further than its place before the ones ahead wait for it
Driver.TEAM_LOOKAHEAD = 60 -- m before the end of its path a next-free-row helper takes its next row
Driver.GIVE_WAY_GAP = 4 -- m kept between us (our front) and the back of another helper in our way
Driver.GIVE_WAY_SLOW = 18 -- m further than that we start slowing down
Driver.GIVE_WAY_OVERLAP = 0.5 -- m the work widths may overlap side by side (neighbouring passes) without a clash
Driver.GIVE_WAY_SHOW = 3000 -- ms waiting before the status says so
Driver.CUSP_DISTANCE = 0.5 -- m from a change of direction counts as there
Driver.UNLOAD_RESUME_LEVEL = 0.9 -- a waiting combine goes on below this, once nothing is under the pipe
Driver.PIPE_CLOSE_DELAY = 3000
Driver.TOW_COMPENSATION = true -- towed implements: the tractor swings wide in bends so the implement stays on the line
Driver.TOW_GAIN = 1.2 -- how strongly the tractor corrects for how far the towed implement is off the line

function Driver.new(vehicle, course, startIx, startPoint)
    local self = setmetatable({}, Driver_mt)
    self.vehicle = vehicle
    self.course = course
    self.startIx = startIx or 1
    self.info = GuidanceVehicleInfo.get(vehicle)
    self.state = Driver.STATE_START
    self.lowered = false
    self.stuckTimer = 0
    self.lostTimer = 0
    self.fillCheckTimer = 0
    self.offsetTimer = 0
    self.holdUntil = 0
    self.pipeIdleTimer = 0
    -- the player's tool offset (right, m) on top of the measured one (left, m)
    self.toolOffset = course.plan.toolOffsetX or 0
    -- a convoy: each drives its own lane of the wide course, the first one on the left
    local plan = course.plan
    self.convoy = plan.teamMode == GuidancePlan.TEAM_CONVOY and (plan.teamSize or 1) > 1
    self.convoyOffset = 0
    if self.convoy then
        self.convoyOffset = ((plan.teamSize + 1) / 2 - (plan.teamIndex or 1)) * plan.workWidth
    end
    self.sideOffset = (math.abs(self.info.sideOffset) > 0.25 and self.info.sideOffset or 0) - self.toolOffset
    -- next free row: the course has this one's headland passes, the rows it takes as it goes
    self.teamRows = plan.teamMode == GuidancePlan.TEAM_NEXT_ROW and course.teamRows or nil
    self.passesLast = self.teamRows ~= nil and not plan.headlandsFirst
    local hasPasses = false
    for _, wp in ipairs(course.waypoints) do
        if wp.work then hasPasses = true break end
    end
    -- no headland pass of its own (more helpers than passes): right to the rows
    local rowsFirst = self.passesLast or (self.teamRows ~= nil and not hasPasses)
    self.towLength = self.info.towLength or 0
    self.harvester = Driver.findHarvester(vehicle)
    if self.harvester and vehicle.isServer ~= false then
        Driver.setCallUnloaderLevel(vehicle, self.harvester, course.plan.callUnloaderAt or 80)
    end
    -- standing crop on the field, to keep out of it on the way to the course and on connections
    local ok, probe = pcall(GuidanceFruitProbe.new, course.outline or {})
    self.probe = ok and probe or nil
    self.fruitTimer = 0
    if rowsFirst then
        -- the rows first, the headland passes (if any) after them
        local vx, vz, vh = vehiclePose(vehicle)
        local wx, wz = self:workPoint(vx, vz, vh)
        self.follower = GuidancePathFollower.new({{x = wx, z = wz, t = "C", work = false}})
        self:extendTeamPath()
    else
        self.follower = GuidancePathFollower.new(self:buildPath(startIx or 1, startPoint))
    end
    self.turns = self:findTurns()
    self.turnIx = nil
    if self.convoy then
        for _, pt in ipairs(self.follower.points) do
            if pt.laneStart then self.laneStartPoint = pt break end
        end
    end
    -- turns where the implements stay down, switched off (if the player wants that and nothing is a plow)
    self.keepEnabled = course.plan.keepLowered and self:canKeepLowered()
    self.keepGaps = self.keepEnabled and self:findKeepGaps() or {}
    self.switchedOff = nil
    Guidance.debug("%s: driver started at waypoint %d, width %.1f, radius %.1f, front %.1f, back %.1f, side %.1f%s",
        Guidance.vehicleName(vehicle), startIx or 1, self.info.workWidth, self.info.turnRadius,
        self.info.frontOffset, self.info.backOffset, self.sideOffset, self.harvester and ", harvester" or "")
    return self
end

local function vehiclePose(vehicle)
    local node = vehicle:getAIDirectionNode()
    local x, _, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    return x, z, math.atan2(dz, dx)
end

--- All vehicles of the combination
local function allVehicles(vehicle)
    if vehicle.getChildVehicles then
        return vehicle:getChildVehicles()
    end
    return {vehicle}
end

-- World z points south: seen from above, the vehicle's left is a clockwise quarter turn from its heading in x/z
local function leftOf(h)
    return math.sin(h), -math.cos(h)
end

--- Where the middle of the work area is, for a vehicle at x, z facing h
function Driver:workPoint(x, z, h)
    local lx, lz = leftOf(h)
    return x + lx * self.sideOffset, z + lz * self.sideOffset
end

--- The path to drive: from the vehicle to the waypoint we start at (lined up, so the implement is straight
--- when it gets there; along the headland if the direct way would cut through the field), then the course
function Driver:buildPath(startIx, startPoint)
    local wps = self.course.waypoints
    startIx = math.max(1, math.min(startIx, #wps - 1))
    local path = {}
    local vx, vz, h = vehiclePose(self.vehicle)
    local x, z = self:workPoint(vx, vz, h)
    -- start at a waypoint, or at a point on the way to it (the middle of a row)
    local first, second, nextIx
    if startPoint and startIx > 1 then
        first, second, nextIx = {x = startPoint.x, z = startPoint.z, t = wps[startIx].t}, wps[startIx], startIx
    else
        first, second, nextIx = wps[startIx], wps[startIx + 1], startIx + 1
    end
    local h0 = math.atan2(second.z - first.z, second.x - first.x)
    if second.rev then h0 = h0 + math.pi end
    -- a convoy member goes to the start of its own lane, beside the course
    local target = first
    if self.convoy and self.convoyOffset ~= 0 then
        local lx, lz = leftOf(h0)
        target = {x = first.x + lx * self.convoyOffset, z = first.z + lz * self.convoyOffset}
    end
    local dist = math.sqrt((target.x - x) ^ 2 + (target.z - z) ^ 2)
    local headingDiff = math.abs(GuidanceGeo.normAngle(h - h0))
    table.insert(path, {x = x, z = z, t = "C", work = false})
    if dist > 2 or headingDiff > math.rad(20) then
        local runIn = math.max(self.info.runOut, 3)
        local approach = {x = target.x - math.cos(h0) * runIn, y = target.z - math.sin(h0) * runIn, h = h0}
        local from = {x = x, y = z, h = h}
        local settings = self.course.plan:getGeneratorSettings()
        local pts = GuidanceCourseGenerator.planApproach(self.course.area, settings, from, approach)
        -- through standing crop? Then around it if there is a better way
        local fruit = GuidancePathfinder.fruitLength(self.probe, from, pts)
        if fruit > 5 then
            local around = GuidancePathfinder.find(self.course.area, settings, from, approach, self.probe)
            local aroundFruit = around and GuidancePathfinder.fruitLength(self.probe, from, around)
            Guidance.debug("%s: way to the course crosses %.0f m of crop, around it %s", Guidance.vehicleName(self.vehicle),
                fruit, aroundFruit and string.format("%.0f m", aroundFruit) or "not found")
            if around and aroundFruit < fruit - 5 then
                pts = around
            end
        end
        for _, p in ipairs(pts) do
            table.insert(path, {x = p.x, z = p.y, t = "C", work = false})
        end
    end
    if target ~= first then
        -- from here on the lane: the course's own points, the lane beside them (see getDriveData)
        table.insert(path, {x = target.x, z = target.z, t = "C", work = false, laneStart = true})
    end
    -- the course waypoint we start at, reached with the implements still up
    table.insert(path, {x = first.x, z = first.z, t = first.t, work = false, ix = startIx})
    for i = nextIx, #wps do
        local wp = wps[i]
        table.insert(path, {x = wp.x, z = wp.z, t = wp.t, work = wp.work, rev = wp.rev, keep = wp.keep, ix = i})
    end
    -- drop points too close together, they only confuse the heading checks
    local cleaned = {path[1]}
    for i = 2, #path do
        local p, q = cleaned[#cleaned], path[i]
        if (q.x - p.x) ^ 2 + (q.z - p.z) ^ 2 > 0.01 then
            table.insert(cleaned, q)
        else
            -- keep the course index of the later point
            p.ix = q.ix or p.ix
        end
    end
    return cleaned
end

--- Turns of the path: {from, to, isLeft} in path distance, for the implements' turn progress events
function Driver:findTurns()
    local turns, current = {}, nil
    local pts = self.follower.points
    for i = 2, #pts do
        local p = pts[i]
        if p.t == "T" then
            if current == nil then
                current = {from = pts[i - 1].d, to = p.d, startIx = i - 1, endIx = i}
                table.insert(turns, current)
            else
                current.to, current.endIx = p.d, i
            end
        else
            current = nil
        end
    end
    for _, turn in ipairs(turns) do
        local a, b = pts[turn.startIx], pts[math.min(turn.startIx + 1, #pts)]
        local d = pts[turn.endIx]
        local h1 = math.atan2(b.z - a.z, b.x - a.x)
        -- U-turn: which side the next row is on decides left or right. Cross product of the start heading and
        -- the way to the end point: positive is to the right of the vehicle (world z points south)
        local cross = math.cos(h1) * (d.z - a.z) - math.sin(h1) * (d.x - a.x)
        turn.isLeft = cross < 0
    end
    return turns
end

--- Stretches between two worked ones where the implements may stay down: turns the generator found clear (on the
--- field, off islands, over worked land, forward only). {from, to} in path distance.
function Driver:findKeepGaps()
    local gaps = {}
    local intervals, pts = self.follower.workIntervals, self.follower.points
    local i = 1
    for k = 1, #intervals - 1 do
        local from, to = intervals[k].to, intervals[k + 1].from
        local ok, n = true, 0
        while i <= #pts and pts[i].d <= from + 1e-6 do i = i + 1 end
        while i <= #pts and pts[i].d < to - 1e-6 do
            n = n + 1
            if not pts[i].keep or pts[i].rev then ok = false end
            i = i + 1
        end
        if ok and n > 0 then
            table.insert(gaps, {from = from, to = to})
        end
    end
    return gaps
end

--- Plows have to come up to turn over, and seeders that sow whenever they are down (nothing to switch off) must
--- come up too; everything else may stay down in a turn
function Driver:canKeepLowered()
    for _, v in pairs(allVehicles(self.vehicle)) do
        if v.spec_plow ~= nil then
            return false
        end
        local sowing = v.spec_sowingMachine
        if sowing ~= nil and (not sowing.needsActivation or v.setIsTurnedOn == nil) then
            return false
        end
    end
    return true
end

function Driver:isInKeepGap(s)
    for _, gap in ipairs(self.keepGaps) do
        if s > gap.from and s < gap.to then
            return true
        end
    end
    return false
end

--- Leaves the implements down but switches off what is switched on (seeding, spraying, mowing stop)
function Driver:switchOffImplements()
    Guidance.debug("%s: turning with the implements down, switched off", Guidance.vehicleName(self.vehicle))
    self.switchedOff = {}
    for _, v in pairs(allVehicles(self.vehicle)) do
        if v ~= self.vehicle and v.getIsTurnedOn and v.setIsTurnedOn and v:getIsTurnedOn() then
            v:setIsTurnedOn(false)
            table.insert(self.switchedOff, v)
        end
    end
end

function Driver:switchOnImplements()
    for _, v in ipairs(self.switchedOff or {}) do
        if v.setIsTurnedOn and not v:getIsTurnedOn() then
            v:setIsTurnedOn(true)
        end
    end
    self.switchedOff = nil
end

-----------------------------------------------------------------------------------------------------------------------
-- Interface of the game's drive strategies
-----------------------------------------------------------------------------------------------------------------------

function Driver:update(dt)
end

function Driver:delete()
end

function Driver:draw()
end

function Driver:getDriveData(dt, vX, vY, vZ)
    local vehicle = self.vehicle
    local x, z, h = vehiclePose(vehicle)
    self:updateSideOffset(dt)
    -- a convoy member at the start of its lane: from here on it drives beside the course
    if self.convoy and not self.onLane then
        local lane = self.laneStartPoint
        if lane == nil or self.follower.s >= lane.d - 0.3 then
            self.onLane = true
            self.sideOffset = self.sideOffset - self.convoyOffset
            if self.targetSideOffset then self.targetSideOffset = self.targetSideOffset - self.convoyOffset end
        end
    end
    local wx, wz = self:workPoint(x, z, h)
    self.follower:update(wx, wz, h)
    local reversing = self.follower:isReversing()
    local maxSpeed = 0

    if self.state == Driver.STATE_START then
        -- one AI event per frame, or implements don't lower or start for the clients
        vehicle:raiseAIEvent("onAIFieldWorkerPrepareForWork", "onAIImplementPrepareForWork")
        self.state = Driver.STATE_PREPARE
    elseif self.state == Driver.STATE_PREPARE then
        self.state = Driver.STATE_DRIVING
    elseif self.state == Driver.STATE_WAIT_LOWER then
        self.lowerTimer = self.lowerTimer + dt
        -- right after we start lowering it may still say yes, so wait at least a moment
        if self.lowerTimer > 300 and (vehicle:getCanAIFieldWorkerContinueWork() or self.lowerTimer > Driver.LOWER_TIMEOUT) then
            self.state = Driver.STATE_DRIVING
        end
    elseif self.state == Driver.STATE_WAIT_UNLOAD then
        self:updateWaitForUnload(dt)
    elseif self.state == Driver.STATE_DRIVING and vehicle.spec_guidance and vehicle.spec_guidance.paused then
        -- paused by the player: stand still, everything else stays as it is
        maxSpeed = 0
    elseif self.state == Driver.STATE_DRIVING then
        self.fruitTimer = self.fruitTimer + dt
        if self.fruitTimer > 1000 then
            self.fruitTimer = 0
            self:checkConnectionsAhead()
        end
        maxSpeed = self:updateDriving(dt)
        reversing = self.follower:isReversing()
        maxSpeed = self:giveWay(dt, maxSpeed, x, z, h, reversing)
        maxSpeed = self:keepConvoy(maxSpeed)
    end

    self:updateProgress()
    self:updateLights(dt)
    self:updateStats(dt)
    self:updateFillLevels(dt)
    self:updatePipe(dt)
    self:checkStuck(dt, maxSpeed)

    -- target: on the path ahead (behind the vehicle when reversing), moved back by the side offset so the work
    -- area, not the vehicle, follows the path
    local lookahead = reversing and 3 or self:getLookahead()
    local goalX, goalZ, goalH = self.follower:getGoal(lookahead)
    if Driver.TOW_COMPENSATION and self.towLength > 0.5 and self.lowered and not reversing then
        goalX, goalZ = self:towCorrection(goalX, goalZ, goalH, lookahead)
    end
    local facing = reversing and goalH + math.pi or goalH
    local lx, lz = leftOf(facing)
    local tx, tz = goalX - lx * self.sideOffset, goalZ - lz * self.sideOffset

    -- the game's collision prediction looks at these
    local dx, dz = tx - x, tz - z
    local len = math.sqrt(dx * dx + dz * dz)
    if len > 0.01 then
        vehicle.aiDriveDirection = {dx / len, dz / len}
    end
    vehicle.aiDriveTarget = {x, z}

    if self.state == Driver.STATE_DONE then
        return tx, tz, true, 0, 0
    end
    return tx, tz, not reversing, maxSpeed, math.min(self.follower:getRemaining(), self.follower:getDistanceToCusp())
end

--- The next connection (driven with the implements up, between blocks, to an island...) shortly ahead: if it
--- would cross standing crop, a way around it. Checked just before getting there, the crop changes while we work.
function Driver:checkConnectionsAhead()
    local probe = self.probe
    if probe == nil or #probe.fruitIndexes == 0 then
        return
    end
    local follower = self.follower
    local pts = follower.points
    local function isConnection(p)
        return p.t == "C" and not p.work and not p.rev
    end
    local i = follower.ix + 2
    while i < #pts and pts[i].d - follower.s < 40 do
        if isConnection(pts[i]) and not pts[i].fruitChecked then
            local j = i
            while j < #pts - 1 and isConnection(pts[j + 1]) do j = j + 1 end
            for k = i, j do pts[k].fruitChecked = true end
            local a, b = i - 1, j
            if pts[b].d - pts[a].d > 20 then
                local from = {x = pts[a].x, y = pts[a].z, h = math.atan2(pts[a].z - pts[a - 1].z, pts[a].x - pts[a - 1].x)}
                local to = {x = pts[b].x, y = pts[b].z, h = math.atan2(pts[b + 1].z - pts[b].z, pts[b + 1].x - pts[b].x)}
                local planned = {}
                for k = a + 1, b do table.insert(planned, {x = pts[k].x, y = pts[k].z}) end
                local fruit = GuidancePathfinder.fruitLength(probe, from, planned)
                if fruit > 5 then
                    local around = GuidancePathfinder.find(self.course.area, self.course.plan:getGeneratorSettings(),
                        from, to, probe)
                    local aroundFruit = around and GuidancePathfinder.fruitLength(probe, from, around)
                    Guidance.debug("%s: connection crosses %.0f m of crop, around it %s", Guidance.vehicleName(self.vehicle),
                        fruit, aroundFruit and string.format("%.0f m", aroundFruit) or "not found")
                    if around and aroundFruit < fruit - 5 then
                        local new = {}
                        for _, p in ipairs(around) do
                            if (p.x - to.x) ^ 2 + (p.y - to.y) ^ 2 > 0.01 then
                                table.insert(new, {x = p.x, z = p.y, t = "C", work = false, fruitChecked = true})
                            end
                        end
                        follower:replaceRange(a, b, new)
                        self.turns = self:findTurns()
                        self.keepGaps = self.keepEnabled and self:findKeepGaps() or {}
                    end
                end
            end
            return
        end
        i = i + 1
    end
end

--- Where the middle of the AI implements' work area is now (world x, z), or nil
function Driver:getImplementCenter()
    local sx, sz, n = 0, 0, 0
    for _, implement in pairs(self.vehicle:getAttachedAIImplements()) do
        local obj = implement.object
        if obj and obj.getAIMarkers then
            local ok, left, right = pcall(obj.getAIMarkers, obj)
            if ok and left and right then
                local lx, _, lz = getWorldTranslation(left)
                local rx, _, rz = getWorldTranslation(right)
                sx, sz, n = sx + (lx + rx) / 2, sz + (lz + rz) / 2, n + 1
            end
        end
    end
    if n == 0 then return nil end
    return sx / n, sz / n
end

--- A towed implement cuts inside the tractor's path in bends. So the implement, not the tractor, stays on the line:
--- the tractor aims wider in a bend (radius sqrt(R² + L²) for the implement's R, L how far back it works), and
--- further to the side by as much as the implement is off the line now, the other way (that also takes care of
--- whatever the hitch looks like).
function Driver:towCorrection(goalX, goalZ, goalH, lookahead)
    local follower = self.follower
    local L = self.towLength
    -- wider in a bend
    local k = follower:getCurvatureAt(follower.s + lookahead)
    if math.abs(k) > 1e-3 then
        local radius = 1 / math.abs(k)
        local wider = math.sqrt(radius * radius + L * L) - radius
        local side = k > 0 and 1 or -1 -- outward: right of the path for a bend to the left (x/z sense)
        goalX, goalZ = goalX + math.sin(goalH) * wider * side, goalZ - math.cos(goalH) * wider * side
    end
    -- how far the implement is to the left of the line, where the line was about L back
    local ix, iz = self:getImplementCenter()
    if ix == nil then
        return goalX, goalZ
    end
    local pts = follower.points
    local best, bestDist, bestSide
    local i = follower.ix
    while i > 1 and follower.s - pts[i].d < L + 15 do i = i - 1 end
    for j = i, math.min(#pts - 1, follower.ix + 1) do
        local a, b = pts[j], pts[j + 1]
        local d, t = GuidanceGeo.distToSegment({x = ix, y = iz}, {x = a.x, y = a.z}, {x = b.x, y = b.z})
        if best == nil or d < bestDist then
            local cross = (b.x - a.x) * (iz - a.z) - (b.z - a.z) * (ix - a.x)
            best, bestDist, bestSide = j, d, cross > 0 and 1 or -1
        end
    end
    if best == nil or bestDist > 5 then
        return goalX, goalZ
    end
    -- the other way: implement left of the line (x/z sense) -> tractor aims right
    local e = bestDist * bestSide * Driver.TOW_GAIN
    return goalX + math.sin(goalH) * e, goalZ - math.cos(goalH) * e
end

function Driver:getLookahead()
    local speedMs = math.max(self.vehicle:getLastSpeed() / 3.6, 0)
    local radius = self.follower:getMinRadiusAhead(8)
    if radius < 25 then
        return 3.5
    end
    return math.max(3.5, math.min(9, 2.5 + 0.6 * speedMs))
end

--- The side offset of the work area: measured from the implement's markers now and then (a plow moves it when it
--- turns over), changing smoothly
function Driver:updateSideOffset(dt)
    self.offsetTimer = self.offsetTimer + dt
    -- a towed implement swings to the side in bends: that's no side offset, measure it on straights only
    local straight = self.towLength <= 0.5 or self.follower:getMinRadiusAhead(5) > 100
    if self.offsetTimer >= Driver.OFFSET_CHECK_INTERVAL and straight then
        local measured = GuidanceVehicleInfo.measureSideOffset(self.vehicle)
        if measured == nil or math.abs(measured) < 0.25 then measured = 0 end
        self.targetSideOffset = measured - self.toolOffset - (self.onLane and self.convoyOffset or 0)
        self.offsetTimer = 0
    end
    local target = self.targetSideOffset or self.sideOffset
    local maxStep = Driver.OFFSET_RATE * dt / 1000
    self.sideOffset = self.sideOffset + math.max(-maxStep, math.min(maxStep, target - self.sideOffset))
end

function Driver:updateDriving(dt)
    local follower = self.follower
    if self.teamRows then
        self:updateTeamRows()
    end
    if follower:isFinished() then
        self.state = Driver.STATE_DONE
        self:raiseImplements()
        self.vehicle:guidanceSetInfoText("FINISHED", true)
        self.vehicle:stopCurrentAIJob(AIMessageSuccessFinishedJob.new())
        return 0
    end

    -- at a change of direction: stopped there, now the other way
    local toCusp = follower:getDistanceToCusp()
    if toCusp < Driver.CUSP_DISTANCE then
        follower:passCusp()
        toCusp = follower:getDistanceToCusp()
    end
    local reversing = follower:isReversing()

    -- implements: lower when the front of the work area gets to a worked stretch, raise when the back leaves it
    local speedMs = self.vehicle:getLastSpeed() / 3.6
    local lead = math.max(0.5, speedMs * 0.6)
    -- once lowered, stay lowered until the back of the work area leaves the worked stretch: the lead shrinks
    -- when we slow down to wait for the implements, that must not raise them again
    -- the player's timing: down / up that many metres later (negative: earlier)
    local plan = self.course.plan
    local lowerLate, raiseLate = plan.lowerLate or 0, plan.raiseLate or 0
    if self.lowered then
        -- (lowered early: the front isn't at the worked stretch yet either)
        lead = lead + 3 + math.max(0, -lowerLate)
    else
        lead = lead - lowerLate
    end
    local front, back = self.info.frontOffset, self.info.backOffset
    local shouldWork = not reversing and follower:isInWork(front, back, lead, raiseLate)
    if shouldWork and self.switchedOff then
        -- down all through the turn: just switch back on
        self:switchOnImplements()
    elseif shouldWork and not self.lowered then
        self:lowerImplements()
        self.state = Driver.STATE_WAIT_LOWER
        self.lowerTimer = 0
        return 0
    elseif not shouldWork and self.lowered and not self.switchedOff then
        if self:isInKeepGap(follower.s + self.info.backOffset) then
            self:switchOffImplements()
        else
            self:raiseImplements()
        end
    elseif not shouldWork and self.switchedOff and not self:isInKeepGap(follower.s + self.info.backOffset) then
        -- left the turn some other way (stopped, restarted): up after all
        self:switchOnImplements()
        self:raiseImplements()
    end

    self:updateTurnProgress()

    -- AutoDrive asked us to hold on a moment (its unloader is getting into place)
    if g_time ~= nil and g_time < self.holdUntil then
        return 0
    end
    -- the implements can't go on right now (a forage harvester with nothing under its pipe, a baler wrapping)
    if self.lowered and not self.vehicle:getCanAIFieldWorkerContinueWork() then
        return 0
    end

    -- speed: the implement's limit while working, slower in curves and turns
    local speed
    local _, work = follower:getCurrentSegment()
    local plan = self.course.plan
    if reversing then
        speed = plan.reverseSpeed or Driver.REVERSE_SPEED
    elseif self.lowered or work then
        speed = self.vehicle:getSpeedLimit(true)
        if (plan.workSpeedMax or 0) > 0 then speed = math.min(speed, plan.workSpeedMax) end
    else
        speed = plan.turnSpeed or Driver.TURN_SPEED
    end
    local radius = follower:getMinRadiusAhead(math.max(10, speedMs * 3))
    if radius < math.huge then
        speed = math.min(speed, math.max(4, 3.6 * math.sqrt(Driver.LATERAL_ACCEL * radius)))
    end
    -- stop on the spot where the direction changes
    if toCusp < math.huge then
        speed = math.min(speed, math.max(1.5, 3.6 * math.sqrt(2 * 0.6 * toCusp)))
    end
    -- don't arrive at a worked stretch too fast to lower in time
    if not self.lowered and follower:getDistanceToNextWork(front - lowerLate) < 15 then
        speed = math.min(speed, 8)
    end
    speed = math.min(speed, self.vehicle:getCruiseControlMaxSpeed() or speed)
    return math.max(speed, 1)
end

--- Something that isn't a Guidance helper we stop for, if it is in our way: a vehicle a player drives, another
--- mod's or the game's helper, anything moving; not AutoDrive's (it keeps clear itself: an unloader drives right
--- beside a combine), not our own combination, nothing parked
function Driver.isObstacle(self, other)
    if other == self.vehicle or other.isDeleted or other.rootNode == nil then
        return false
    end
    if other.getRootVehicle and other:getRootVehicle() ~= other then
        return false
    end
    if other.ad and other.ad.stateModule and other.ad.stateModule.isActive and other.ad.stateModule:isActive() then
        return false
    end
    if other.getIsControlled and other:getIsControlled() then return true end
    if other.getIsAIActive and other:getIsAIActive() then return true end
    return other.getLastSpeed ~= nil and other:getLastSpeed() > 2
end

--- Where the players on foot are: list of {x, z}
function Driver.playersOnFoot()
    local list = {}
    local system = g_currentMission and g_currentMission.playerSystem
    local players = system and (system.players or (system.getPlayers and system:getPlayers()))
    for _, player in pairs(players or {}) do
        local inVehicle = player.getCurrentVehicle and player:getCurrentVehicle() ~= nil
        if not inVehicle then
            local ok, x, _, z = pcall(function()
                if player.getPosition then return player:getPosition() end
                return getWorldTranslation(player.rootNode)
            end)
            if ok and x and z then list[#list + 1] = {x = x, z = z} end
        end
    end
    return list
end

--- Does that helper wait for us, itself or through others waiting for each other (a circle)?
local function waitsFor(od, vehicle)
    local seen, o = {}, od
    while o and o.blockedBy and not seen[o] do
        seen[o] = true
        if o.blockedBy == vehicle then return true end
        local spec = o.blockedBy.spec_guidance
        o = spec and spec.driver
    end
    return false
end

--- Another Guidance helper right ahead, in our way: slow down, then stand until it has gone. Side by side on
--- neighbouring passes isn't in the way. Helpers never all wait for each other: one that (through others) already
--- waits for us gives us the right of way, we go and the circle is broken. Returns the speed.
function Driver:giveWay(dt, maxSpeed, x, z, h, reversing)
    local blockedBy, limit = nil, maxSpeed
    local vehicles = g_currentMission and g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles
    if maxSpeed > 0 and vehicles then
        local dirX, dirZ = math.cos(h), math.sin(h)
        if reversing then dirX, dirZ = -dirX, -dirZ end
        local half = (self.course.plan.workWidth or 6) / 2 - Driver.GIVE_WAY_OVERLAP / 2
        --- something at ox, oz, otherHalf wide to each side, 'back' m long behind its middle: in our way?
        local function check(other, ox, oz, otherHalf, back)
            local dx, dz = ox - x, oz - z
            local ahead = dx * dirX + dz * dirZ
            local side = math.abs(dx * dirZ - dz * dirX)
            local gap = Driver.GIVE_WAY_GAP + GuidanceCourseGenerator.VEHICLE_FRONT + back
            if ahead > 0 and ahead < gap + Driver.GIVE_WAY_SLOW and side < half + otherHalf then
                local f = math.max(0, math.min(1, (ahead - gap) / Driver.GIVE_WAY_SLOW))
                local speed = maxSpeed * f
                if speed < 1.5 then speed = 0 end
                if speed < limit then
                    limit, blockedBy = speed, other
                end
            end
        end
        for _, other in pairs(vehicles) do
            local otherDriver = other ~= self.vehicle and other.spec_guidance and other.spec_guidance.driver
            if not otherDriver and Driver.isObstacle(self, other) then
                local ox, _, oz = getWorldTranslation(other.rootNode)
                local size = other.size or {}
                check(other, ox, oz, (size.width or 3) / 2, (size.length or 6) / 2)
            end
        end
        for _, player in ipairs(Driver.playersOnFoot()) do
            check(player, player.x, player.z, 0.5, 0.5)
        end
        for _, other in pairs(vehicles) do
            local spec = other ~= self.vehicle and other.spec_guidance or nil
            local od = spec and spec.driver
            if od and od ~= self and od.state ~= Driver.STATE_DONE and other.rootNode
                    and not self:isConvoyPartner(od) and not waitsFor(od, self.vehicle) then
                local ox, _, oz = getWorldTranslation(other.rootNode)
                local dx, dz = ox - x, oz - z
                local ahead = dx * dirX + dz * dirZ
                local side = math.abs(dx * dirZ - dz * dirX)
                local otherHalf = (od.course and od.course.plan.workWidth or 6) / 2 - Driver.GIVE_WAY_OVERLAP / 2
                -- our front to the back of its implement
                local gap = Driver.GIVE_WAY_GAP + GuidanceCourseGenerator.VEHICLE_FRONT
                    + math.max(0, -((od.info and od.info.backOffset) or 0))
                if ahead > 0 and ahead < gap + Driver.GIVE_WAY_SLOW and side < half + otherHalf then
                    local f = math.max(0, math.min(1, (ahead - gap) / Driver.GIVE_WAY_SLOW))
                    local speed = maxSpeed * f
                    if speed < 1.5 then speed = 0 end
                    if speed < limit then
                        limit, blockedBy = speed, other
                    end
                end
            end
        end
    end
    self.blockedBy = limit == 0 and blockedBy or nil
    self.giveWayTimer = self.blockedBy and (self.giveWayTimer or 0) + dt or 0
    local showing = self.giveWayTimer > Driver.GIVE_WAY_SHOW
    if showing ~= (self.showingGiveWay or false) then
        self.showingGiveWay = showing
        self.vehicle:guidanceSetInfoText("GIVING_WAY", showing)
    end
    return limit
end

-----------------------------------------------------------------------------------------------------------------------
-- Teams: a convoy keeps its order and spacing; next free row takes rows as it goes
-----------------------------------------------------------------------------------------------------------------------

--- Distance along the course (not our path, which starts with the way to it): negative before we're on it
function Driver:getCourseDistance()
    local f = self.follower
    local pts, wps = f.points, self.course.waypoints
    for i = math.min(f.ix + 1, #pts), #pts do
        local p = pts[i]
        if p.ix and wps[p.ix] then
            return wps[p.ix].d - (p.d - f.s)
        end
    end
    return wps[#wps] and wps[#wps].d or 0
end

function Driver:isConvoyPartner(other)
    if not self.convoy or not other.convoy or not self.onLane or not other.onLane then return false end
    local a, b = self.course.plan, other.course.plan
    return a.fieldId == b.fieldId and a.teamSize == b.teamSize and a.teamIndex ~= b.teamIndex
end

local function convoyPartners(self)
    local list = {}
    local vehicles = g_currentMission and g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles
    local plan = self.course.plan
    for _, v in pairs(vehicles or {}) do
        local od = v ~= self.vehicle and v.spec_guidance and v.spec_guidance.driver
        -- (one that has finished or stopped isn't in the line any more)
        if od and od.convoy and od.state ~= Driver.STATE_DONE then
            local op = od.course.plan
            if op.fieldId == plan.fieldId and op.teamSize == plan.teamSize and op.teamIndex ~= plan.teamIndex then
                table.insert(list, od)
            end
        end
    end
    return list
end

--- A convoy member keeps a gap behind the member right ahead of it along the course (whoever got to the course
--- first leads; the lanes stay as they are), from near the course's start on; the front one waits when one falls
--- far behind on the course (unloading, stuck). Returns the speed.
function Driver:keepConvoy(maxSpeed)
    if not self.convoy or maxSpeed <= 0 then
        return maxSpeed
    end
    local plan = self.course.plan
    local me = plan.teamIndex or 1
    local gap = plan.workWidth + Driver.CONVOY_GAP_EXTRA
    local mine = self:getCourseDistance()
    local ahead, behind = math.huge, nil
    local partners = convoyPartners(self)
    for _, od in ipairs(partners) do
        local theirs = od:getCourseDistance()
        local k = od.course.plan.teamIndex or 1
        -- (level: the lower number goes first)
        if theirs > mine or (theirs == mine and k < me) then
            ahead = math.min(ahead, theirs - mine)
        elseif mine >= 0 and theirs >= 0 then
            behind = math.max(behind or 0, mine - theirs)
        end
    end
    local limit = maxSpeed
    if ahead < gap and mine > -gap then
        limit = maxSpeed * math.max(0, math.min(1, (ahead - gap * 0.5) / (gap * 0.5)))
    end
    if ahead == math.huge and behind and behind > #partners * gap + Driver.CONVOY_MAX_LAG then
        -- the front one: one behind has fallen back, wait for it
        limit = 0
    end
    if limit < 1 then limit = 0 end
    return limit
end

--- Next free row: takes the next row when near the end of the path, reports rows done; after the last row the
--- headland passes if they come last. Server.
function Driver:updateTeamRows()
    local f = self.follower
    local plan = self.course.plan
    -- rows finished (the back of the work area past the end)
    for _, p in ipairs(f.points) do
        if p.teamRow and not p.teamDone and f.s + (self.info.backOffset or 0) >= p.d then
            p.teamDone = true
            GuidanceTeam.markDone(plan.fieldId, self.teamRows, p.teamRow)
            self:reportTeamProgress()
        end
    end
    if not self.teamRowsOut and f:getRemaining() < Driver.TEAM_LOOKAHEAD then
        if not self:extendTeamPath() then
            self.teamRowsOut = true
            if self.passesLast then
                self:appendPasses()
            end
            -- ending on a row: drive on until the implement is out of it, or its last metres stay undone
            local last, h = self:pathEndPose()
            if last.work then
                local runOut = math.max(self.info.runOut or 0, 2)
                self:appendPath({{x = last.x + math.cos(h) * runOut, z = last.z + math.sin(h) * runOut, t = "C",
                                  work = false}})
            end
        end
    end
end

function Driver:reportTeamProgress()
    local done, total = GuidanceTeam.count(self.course.plan.fieldId, self.teamRows)
    if self.vehicle.guidanceSetTeamProgress then
        self.vehicle:guidanceSetTeamProgress(done, total)
    end
end

--- The pose at the end of our path (heading the way the last stretch goes)
function Driver:pathEndPose()
    local pts = self.follower.points
    local last, prev = pts[#pts], pts[#pts - 1]
    local h = prev and math.atan2(last.z - prev.z, last.x - prev.x) or select(3, vehiclePose(self.vehicle))
    return last, h
end

function Driver:appendPath(pts)
    self.follower:append(pts)
    self.turns = self:findTurns()
end

--- Takes the next free row and adds the way to it and the row to our path. False if none is left.
function Driver:extendTeamPath()
    local plan = self.course.plan
    local last, h = self:pathEndPose()
    local row, reversed, across = GuidanceTeam.takeRow(plan.fieldId, self.teamRows, self.vehicle, last.x, last.z,
        self.lastAcross, 2 * plan.turnRadius)
    if row == nil then
        return false
    end
    self.lastAcross = across
    local a, b = row.a, row.b
    if reversed then a, b = b, a end
    local rh = math.atan2(b.z - a.z, b.x - a.x)
    local new = {}
    local fromX, fromZ = last.x, last.z
    if last.work then
        -- out of the row we're in first
        local runOut = math.max(self.info.runOut or 0, 2)
        fromX, fromZ = last.x + math.cos(h) * runOut, last.z + math.sin(h) * runOut
        table.insert(new, {x = fromX, z = fromZ, t = "T", work = false})
    end
    local runIn = math.max(self.info.runOut or 0, 3)
    local approach = {x = a.x - math.cos(rh) * runIn, y = a.z - math.sin(rh) * runIn, h = rh}
    local way = GuidanceCourseGenerator.planApproach(self.course.area, plan:getGeneratorSettings(),
        {x = fromX, y = fromZ, h = h}, approach)
    for _, p in ipairs(way) do
        table.insert(new, {x = p.x, z = p.y, t = "T", work = false})
    end
    table.insert(new, {x = a.x, z = a.z, t = "R", work = false, rs = true})
    table.insert(new, {x = b.x, z = b.z, t = "R", work = true, re = true, teamRow = row.row})
    self:appendPath(new)
    Guidance.debug("%s: takes row %d", Guidance.vehicleName(self.vehicle), row.row)
    return true
end

--- The headland passes after the rows: the way to the course's first waypoint, then the course
function Driver:appendPasses()
    local wps = self.course.waypoints
    local any = false
    for _, wp in ipairs(wps) do
        if wp.work then any = true break end
    end
    if not any then
        return
    end
    local last, h = self:pathEndPose()
    local first, second = wps[1], wps[2]
    local h0 = math.atan2(second.z - first.z, second.x - first.x)
    local runIn = math.max(self.info.runOut or 0, 3)
    local approach = {x = first.x - math.cos(h0) * runIn, y = first.z - math.sin(h0) * runIn, h = h0}
    local new = {}
    local way = GuidanceCourseGenerator.planApproach(self.course.area, self.course.plan:getGeneratorSettings(),
        {x = last.x, y = last.z, h = h}, approach)
    for _, p in ipairs(way) do
        table.insert(new, {x = p.x, z = p.y, t = "C", work = false})
    end
    table.insert(new, {x = first.x, z = first.z, t = first.t, work = false, ix = 1})
    for i = 2, #wps do
        local wp = wps[i]
        table.insert(new, {x = wp.x, z = wp.z, t = wp.t, work = wp.work, rev = wp.rev, keep = wp.keep, ix = i})
    end
    self:appendPath(new)
end

-----------------------------------------------------------------------------------------------------------------------
-- Lights: on at night (the game's own automatic lights where the vehicle has them), beacons while working; as
-- they were when the helper stops
-----------------------------------------------------------------------------------------------------------------------

Driver.LIGHTS_CHECK = 2000 -- ms

function Driver:updateLights(dt)
    local v = self.vehicle
    if self.course.plan.lights == GuidancePlan.LIGHTS_OFF or v.isServer == false then
        return
    end
    self.lightsTimer = (self.lightsTimer or Driver.LIGHTS_CHECK) + dt
    if self.lightsTimer < Driver.LIGHTS_CHECK then
        return
    end
    self.lightsTimer = 0
    if self.lightsBefore == nil then
        -- how they were, to put them back
        self.lightsBefore = {mask = v.getLightsTypesMask and v:getLightsTypesMask() or 0,
                             beacons = v.spec_lights and v.spec_lights.beaconLightsActive or false}
        if v.setBeaconLightsVisibility then pcall(v.setBeaconLightsVisibility, v, true) end
    end
    local env = g_currentMission and g_currentMission.environment
    local night = env ~= nil and env.isSunOn == false
    if v.updateAutomaticLights then
        pcall(v.updateAutomaticLights, v, night, true)
    elseif v.setLightsTypesMask then
        -- main and work lights (front and back)
        pcall(v.setLightsTypesMask, v, night and 7 or self.lightsBefore.mask)
    end
end

function Driver:restoreLights()
    local v, before = self.vehicle, self.lightsBefore
    if before == nil then
        return
    end
    self.lightsBefore = nil
    if v.setLightsTypesMask then pcall(v.setLightsTypesMask, v, before.mask) end
    if v.setBeaconLightsVisibility then pcall(v.setBeaconLightsVisibility, v, before.beacons) end
end

-----------------------------------------------------------------------------------------------------------------------
-- Work statistics: what this job did (worked area, time, fuel), for the work log when it stops
-----------------------------------------------------------------------------------------------------------------------

local function fuelLevel(vehicle)
    local motor = vehicle.spec_motorized
    for _, consumer in pairs(motor and motor.consumers or {}) do
        if consumer.fillUnitIndex and consumer.fillType ~= (FillType and FillType.DEF) and vehicle.getFillUnitFillLevel then
            return vehicle:getFillUnitFillLevel(consumer.fillUnitIndex) or 0
        end
    end
    return nil
end

function Driver:updateStats(dt)
    local st = self.stats
    if st == nil then
        st = {area = 0, seconds = 0, fuel = 0, fuelLevel = fuelLevel(self.vehicle)}
        self.stats = st
    end
    st.seconds = st.seconds + dt / 1000
    -- worked: the work width over the way driven while working
    if self.lowered and not self.switchedOff then
        local speed = (self.vehicle:getLastSpeed() or 0) / 3.6
        st.area = st.area + speed * dt / 1000 * (self.course.plan.workWidth or 0)
    end
    -- fuel: what went out of the tank (not what was put in)
    local level = fuelLevel(self.vehicle)
    if level and st.fuelLevel then
        if level < st.fuelLevel then st.fuel = st.fuel + (st.fuelLevel - level) end
    end
    st.fuelLevel = level
end

function Driver:lowerImplements()
    Guidance.debug("%s: lowering at %.1f m", Guidance.vehicleName(self.vehicle), self.follower.s)
    for _, implement in pairs(self.vehicle:getAttachedAIImplements()) do
        implement.object:aiImplementStartLine()
    end
    self.vehicle:raiseStateChange(VehicleStateChange.AI_START_LINE)
    self.lowered = true
end

function Driver:raiseImplements()
    if not self.lowered then
        return
    end
    Guidance.debug("%s: raising at %.1f m", Guidance.vehicleName(self.vehicle), self.follower.s)
    for _, implement in pairs(self.vehicle:getAttachedAIImplements()) do
        implement.object:aiImplementEndLine()
    end
    self.vehicle:raiseStateChange(VehicleStateChange.AI_END_LINE)
    self.lowered = false
end

function Driver:updateTurnProgress()
    local s = self.follower.s
    local current
    for i, turn in ipairs(self.turns) do
        if s >= turn.from and s <= turn.to then
            current = i
            break
        end
    end
    if current then
        local turn = self.turns[current]
        local progress = (s - turn.from) / math.max(turn.to - turn.from, 0.1)
        self.vehicle:raiseAIEvent("onAIFieldWorkerTurnProgress", "onAIImplementTurnProgress", progress, turn.isLeft)
    elseif self.turnIx then
        -- just finished a turn
        local turn = self.turns[self.turnIx]
        self.vehicle:raiseAIEvent("onAIFieldWorkerTurnProgress", "onAIImplementTurnProgress", 1, turn.isLeft)
    end
    self.turnIx = current
end

--- Remembers the course waypoint we are at, to continue there later (AutoDrive, save game)
function Driver:updateProgress()
    local p = self.follower.points[math.min(self.follower.ix + 1, #self.follower.points)]
    if p.ix then
        local spec = self.vehicle.spec_guidance
        if spec and spec.progressIx ~= p.ix then
            spec.progressIx = p.ix
            self.vehicle:guidanceProgressChanged()
        end
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- What AutoDrive's unloaders ask a harvester
-----------------------------------------------------------------------------------------------------------------------

--- Turning or backing up: an unloader keeps out of the way
function Driver:isManeuvering()
    return self.turnIx ~= nil or self.follower:isReversing()
end

function Driver:isWaitingForUnload()
    return self.state == Driver.STATE_WAIT_UNLOAD
end

--- Stand still for ms (AutoDrive calls this every frame while its unloader gets into place)
function Driver:hold(ms)
    if g_time ~= nil then
        self.holdUntil = math.max(self.holdUntil, g_time + (ms or 200))
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Harvesters: unloading on the move, waiting when full
-----------------------------------------------------------------------------------------------------------------------

--- The vehicle of the combination that harvests into a tank and unloads through a pipe, or nil
function Driver.findHarvester(vehicle)
    local list = vehicle.getChildVehicles and vehicle:getChildVehicles() or {vehicle}
    for _, v in pairs(list) do
        if v.spec_combine and v.spec_pipe and v.spec_combine.fillUnitIndex then
            return v
        end
    end
    return nil
end

--- AutoDrive sends an unloader to a harvester this full (its own setting on the harvester, "preCallLevel": a step
--- of its list of levels). We set it from ours, to the nearest step.
function Driver.setCallUnloaderLevel(vehicle, harvester, percent)
    local ad = AutoDrive
    if ad == nil and FS25_AutoDrive ~= nil then ad = FS25_AutoDrive.AutoDrive end
    if ad == nil or ad.settings == nil or ad.settings.preCallLevel == nil or ad.setSettingState == nil then
        return
    end
    local values = ad.settings.preCallLevel.values or {}
    local best, bestD
    for i, v in ipairs(values) do
        local d = math.abs(v - percent / 100)
        if bestD == nil or d < bestD then best, bestD = i, d end
    end
    if best == nil then
        return
    end
    -- (the vehicle itself, and a harvester attached to it if that's another one)
    for _, v in ipairs(harvester ~= vehicle and {vehicle, harvester} or {vehicle}) do
        if v.ad and v.ad.settings and v.ad.settings.preCallLevel then
            pcall(ad.setSettingState, "preCallLevel", best, v)
        end
    end
    Guidance.debug("%s: AutoDrive calls the unloader at %d%%", Guidance.vehicleName(vehicle), math.floor(values[best] * 100 + 0.5))
end

local function harvesterFillLevel(harvester)
    local ix = harvester.spec_combine.fillUnitIndex
    local capacity = harvester:getFillUnitCapacity(ix)
    if capacity == nil or capacity <= 0 then
        return 0
    end
    return harvester:getFillUnitFillLevel(ix) / capacity
end

--- Are there AutoDrive unloaders working for this harvester? Then it waits for them when full, instead of
--- stopping for AutoDrive to drive it away.
function Driver:hasAutoDriveUnloaders()
    local manager = ADHarvestManager
    if manager == nil and FS25_AutoDrive ~= nil then
        manager = FS25_AutoDrive.ADHarvestManager
    end
    if manager == nil or manager.hasHarvesterPotentialUnloaders == nil then
        return false
    end
    local ok, result = pcall(manager.hasHarvesterPotentialUnloaders, manager, self.harvester)
    return ok and result == true
end

local function pipeState(harvester)
    local spec = harvester.spec_pipe
    return spec, spec and spec.numStates and spec.numStates > 1
end

local function setPipe(harvester, open)
    local spec, movable = pipeState(harvester)
    if not movable then
        return
    end
    local target = open and 2 or 1
    if spec.currentState ~= target and spec.currentState ~= 0 and spec.targetState ~= target
            and harvester:getIsPipeStateChangeAllowed(target) then
        harvester:setPipeState(target)
    end
end

--- Opens the pipe while something is under it (an unloader alongside), closes it when it has gone
function Driver:updatePipe(dt)
    local harvester = self.harvester
    if harvester == nil or self.state == Driver.STATE_DONE then
        return
    end
    local spec = harvester.spec_pipe
    local somethingUnder = spec and (spec.numObjectsInTriggers or 0) > 0
    if self.state == Driver.STATE_WAIT_UNLOAD or (somethingUnder and harvesterFillLevel(harvester) > 0.01) then
        setPipe(harvester, true)
        self.pipeIdleTimer = 0
    else
        self.pipeIdleTimer = self.pipeIdleTimer + dt
        if self.pipeIdleTimer > Driver.PIPE_CLOSE_DELAY then
            setPipe(harvester, false)
        end
    end
end

--- Full, waiting for an unloader: go on once it has taken enough and driven off (or the tank is empty)
function Driver:updateWaitForUnload(dt)
    local harvester = self.harvester
    local level = harvesterFillLevel(harvester)
    local spec = harvester.spec_pipe
    local somethingUnder = spec and (spec.numObjectsInTriggers or 0) > 0
    if somethingUnder then
        self.unloadIdleTimer = 0
    else
        self.unloadIdleTimer = (self.unloadIdleTimer or 0) + dt
    end
    if level < 0.02 or (level < Driver.UNLOAD_RESUME_LEVEL and self.unloadIdleTimer > 2000) then
        Guidance.debug("%s: unloaded to %d%%, going on", Guidance.vehicleName(self.vehicle), level * 100)
        self.vehicle:guidanceSetInfoText("NEEDS_UNLOADING", false)
        self.state = Driver.STATE_DRIVING
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Stopping when something is wrong
-----------------------------------------------------------------------------------------------------------------------

function Driver:stop(message, infoText)
    if self.state == Driver.STATE_DONE then
        return
    end
    self.state = Driver.STATE_DONE
    self:raiseImplements()
    if infoText then
        self.vehicle:guidanceSetInfoText(infoText, true)
    end
    self.vehicle:stopCurrentAIJob(message)
end

function Driver:checkStuck(dt, maxSpeed)
    if self.state ~= Driver.STATE_DRIVING then
        self.stuckTimer = 0
        return
    end
    local lastS = self.lastS or 0
    if maxSpeed > 0.5 and self.follower.s - lastS < 0.05 and self.vehicle:getLastSpeed() < 0.5 then
        self.stuckTimer = self.stuckTimer + dt
    else
        self.stuckTimer = 0
    end
    self.lastS = self.follower.s
    if self.stuckTimer > Driver.STUCK_TIME then
        Guidance.info("%s: stuck, giving up", Guidance.vehicleName(self.vehicle))
        self:stop(AIMessageErrorBlockedByObject.new(), "IS_STUCK")
        return
    end
    if self.follower.crossTrack > Driver.LOST_DISTANCE then
        self.lostTimer = self.lostTimer + dt
        if self.lostTimer > Driver.LOST_TIME then
            Guidance.info("%s: %.0f m off the course, giving up", Guidance.vehicleName(self.vehicle),
                self.follower.crossTrack)
            self:stop(AIMessageErrorBlockedByObject.new(), "IS_STUCK")
        end
    else
        self.lostTimer = 0
    end
end

local function fillPercentage(object, fillUnitIndex)
    if fillUnitIndex == nil or object.getFillUnitCapacity == nil then
        return nil
    end
    local capacity = object:getFillUnitCapacity(fillUnitIndex)
    if capacity == nil or capacity <= 0 then
        return nil
    end
    return object:getFillUnitFillLevel(fillUnitIndex) / capacity
end

function Driver:updateFillLevels(dt)
    self.fillCheckTimer = self.fillCheckTimer + dt
    if self.fillCheckTimer < Driver.FILL_CHECK_INTERVAL or self.state == Driver.STATE_DONE then
        return
    end
    self.fillCheckTimer = 0
    local missionInfo = g_currentMission.missionInfo
    local fuelLow, isFull, isEmpty = false, false, false
    for _, v in pairs(allVehicles(self.vehicle)) do
        -- harvested goods: combine tank, forage wagon
        local collector = (v.spec_combine and v.spec_combine.fillUnitIndex)
            or (v.spec_forageWagon and v.spec_forageWagon.fillUnitIndex)
        local level = fillPercentage(v, collector)
        if level and level >= 0.995 then
            isFull = true
        end
        -- seed, unless the helper buys it
        if v.spec_sowingMachine and not missionInfo.helperBuySeeds then
            local seed = fillPercentage(v, v.spec_sowingMachine.fillUnitIndex)
            if seed and seed <= 0 then isEmpty = true end
        end
        if v.getSprayerFillUnitIndex and not missionInfo.helperBuyFertilizer and v.spec_sowingMachine == nil then
            local ok, ix = pcall(v.getSprayerFillUnitIndex, v)
            local sprayLevel = ok and fillPercentage(v, ix)
            if sprayLevel and sprayLevel <= 0 then isEmpty = true end
        end
        -- fuel
        if v.spec_motorized and v.spec_motorized.propellantFillUnitIndices and not missionInfo.helperBuyFuel then
            for _, ix in pairs(v.spec_motorized.propellantFillUnitIndices) do
                local fuel = fillPercentage(v, ix)
                if fuel and fuel < 0.03 then
                    self:stop(AIMessageErrorOutOfFuel.new(), "FUEL_IS_EMPTY")
                    return
                elseif fuel and fuel < 0.15 then
                    fuelLow = true
                end
            end
        end
    end
    self.vehicle:guidanceSetInfoText("FUEL_IS_LOW", fuelLow)
    if isFull and self.state ~= Driver.STATE_WAIT_UNLOAD then
        if self.harvester and self:hasAutoDriveUnloaders() then
            -- AutoDrive's unloaders come to a combine that stands with its pipe out
            Guidance.debug("%s: full, waiting for an unloader", Guidance.vehicleName(self.vehicle))
            self:raiseImplements()
            self.vehicle:guidanceSetInfoText("NEEDS_UNLOADING", true)
            self.unloadIdleTimer = 0
            self.state = Driver.STATE_WAIT_UNLOAD
        else
            self:stop(AIMessageGuidanceIsFull.new(), "NEEDS_UNLOADING")
        end
    elseif isEmpty then
        self:stop(AIMessageErrorOutOfFill.new(), "NEEDS_FILLING")
    end
end

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
Driver.PREPARE_MIN = 1000 -- ms after "prepare for work" before we look (the unfolding starts a moment later)
Driver.PREPARE_TIMEOUT = 60000 -- ms we wait for implements folding at the start; then we go anyway
Driver.LOST_DISTANCE = 15 -- m off the course
Driver.LOST_TIME = 5000
Driver.REJOIN_AHEAD = 30 -- m along the course a lost helper comes back on (past what threw it off)
Driver.REJOINS = 3 -- times it may do that before it gives up
Driver.PUSHED_DISTANCE = 4 -- m off its line while working (pushed off by a truck...): back to where it left it
Driver.PUSHED_TIME = 2000
Driver.CUSP_MARGIN = 2 -- m more it backs up for a header in front (it turns to forward a little before the point)
Driver.CORNER_REACH = 6 -- m a header in front works on past the work's end, up to where it backs up (square corners)
Driver.SAME_SPOT = 10 -- m: thrown off again this near where it came back on: on further along instead
Driver.PUSHED_CUSP = 10 -- m: this near a change of direction it is off its line on purpose (stopping past the corner)
Driver.PUSHED_LANE = 20 -- m: this near a move from one headland pass to the next (a long harvester swings wide there)
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
Driver.AD_WAIT = 20000 -- ms we wait for a standing AutoDrive vehicle in our way (it may wait for us), then go on up to it
Driver.PIPE_OUT_FOR_UNLOADER = 60 -- m: the AutoDrive unloader sent to us this near, the pipe goes out (it sees its side)
Driver.TOUCH_GAP = 1.5 -- m short of anything in our way we stop at the latest (an AutoDrive truck, its trailer)
-- one that gives us the right of way but stands in our way: we never come nearer than this (middle to middle: both
-- fronts and a bit), and it backs up to let us by (straight back, at most ROOM_BACK m, at ROOM_SPEED km/h)
Driver.HARD_GAP = 2 * 5 + 2
Driver.ROOM_BACK = 25
Driver.ROOM_SPEED = 3
Driver.ROOM_ANGLE = math.rad(30) -- backing up this much to the side, out of the other's way
Driver.ROOM_RETURN = 20000 -- ms after that the way back to our path isn't "lost"
Driver.CUSP_DISTANCE = 0.5 -- m from a change of direction counts as there
Driver.UNLOAD_RESUME_LEVEL = 0.9 -- a waiting combine goes on below this, once nothing is under the pipe
Driver.TANK_LEARN = 30 -- m harvested before the litres per metre count
Driver.TANK_FULL = 0.98 -- of the tank: as good as full for the forecast
Driver.EARLY_CALL_RESET = 0.1 -- of the tank: emptied this far, the call level is the player's again
Driver.PIPE_CLOSE_DELAY = 3000
Driver.HOLD_STALL = 15000 -- ms AutoDrive may hold us with nothing coming out of the tank before we go on regardless
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
    -- started on a field whose rows were all done already: it may start them over (once); otherwise, when the
    -- others have done them all, it is finished
    if self.teamRows and GuidanceTeam then
        self.teamFreshStart = #self.teamRows > 0 and GuidanceTeam.count(plan.fieldId, self.teamRows) >= #self.teamRows
    end
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
        -- (its AutoDrive unloaders come along to this field)
        Guidance.try(GuidanceAutoDrive.followCombine, vehicle)
    end
    -- standing crop on the field, to keep out of it on the way to the course and on connections
    local ok, probe = Guidance.try(GuidanceFruitProbe.new, course.outline or {})
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
    -- turns where the implements stay down, switched off (if the player wants that and nothing is a plow); the moves
    -- from one headland pass to the next always (nothing a plow)
    self.canKeep = self:canKeepLowered()
    self.keepEnabled = course.plan.keepLowered and self.canKeep
    self.keepGaps = self:findKeepGaps()
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
    -- the start straight behind us on our line (going back for crop left there): straight back up the lane, then on,
    -- not round in a loop through the crop
    local alongBack = (target.x - x) * math.cos(h0) + (target.z - z) * math.sin(h0)
    local sideBack = math.abs(-(target.x - x) * math.sin(h0) + (target.z - z) * math.cos(h0))
    local runInBack = math.max(self.info.runOut, 3)
    local backUp = self.course.plan.allowReverse and alongBack < -1 and sideBack < 2 and headingDiff < math.rad(20)
        and -alongBack < GuidanceCourse.UNCUT_MAX_BACK + 10
    if backUp then
        table.insert(path, {x = target.x - math.cos(h0) * runInBack, z = target.z - math.sin(h0) * runInBack, t = "C",
                            work = false, rev = true})
        Guidance.debug("%s: backing straight up %.0f m to the start", Guidance.vehicleName(self.vehicle), -alongBack)
    elseif dist > 2 or headingDiff > math.rad(20) then
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
        table.insert(path, {x = wp.x, z = wp.z, t = wp.t, work = wp.work, rev = wp.rev, keep = wp.keep, lane = wp.lane,
                            ix = i})
    end
    self:reachBackAtCusps(path)
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
            local kept = (pts[i].keep and self.keepEnabled) or (pts[i].lane and self.canKeep)
            if not kept or pts[i].rev then ok = false end
            i = i + 1
        end
        if ok and n > 0 then
            table.insert(gaps, {from = from, to = to})
        end
    end
    return gaps
end

--- Where it stops backing up and drives on into work (a square corner, a three-point turn before a row): the work
--- area has to start at the work, not past it. One ahead of the steering point (a harvester's header: its back this
--- far ahead) would start that far in and leave that much standing; so it backs up that much further. (An implement
--- behind the tractor is already behind the work start there.)
function Driver:reachBackAtCusps(path)
    local back = self.info and self.info.backOffset or 0
    if back <= 0.3 then return path end
    -- and the other way round: where it drives on past the work before backing up (into a square corner), the work
    -- is cut short there to keep the nose of a tractor on the field; with the header in front the nose is the
    -- header, so it works on up to where it backs up (else the last metres before the corner stay standing)
    for i = 2, #path - 1 do
        if not path[i].rev and path[i + 1].rev and not path[i].work then
            local k, d = i, 0
            while k > 1 and not path[k].work and not path[k].rev and d <= Driver.CORNER_REACH do
                d = d + math.sqrt((path[k].x - path[k - 1].x) ^ 2 + (path[k].z - path[k - 1].z) ^ 2)
                k = k - 1
            end
            if path[k].work and d <= Driver.CORNER_REACH then
                for j = k + 1, i do path[j].work = true end
            end
        end
    end
    for i = 2, #path - 1 do
        local p, prev = path[i], path[i - 1]
        if p.rev and not path[i + 1].rev then
            -- how far on from here the work starts (forward, before any more backing up)
            local d, start = 0, nil
            for k = i + 1, #path do
                local q = path[k]
                if q.rev or d > back then break end
                if q.work then start = d break end
                d = d + math.sqrt((q.x - path[k - 1].x) ^ 2 + (q.z - path[k - 1].z) ^ 2)
                if path[k + 1] and path[k + 1].work then start = d break end
            end
            -- back along the line it then drives forward on (it stays on its lane)
            local nxt = path[i + 1]
            local dx, dz = nxt.x - p.x, nxt.z - p.z
            local len = math.sqrt(dx * dx + dz * dz)
            if start ~= nil and start < back and len > 0.05 and prev ~= nil then
                -- (and a bit more: it turns to forward a little before the point, and stops short of it)
                local extra = back - start + Driver.CUSP_MARGIN
                p.x, p.z = p.x - dx / len * extra, p.z - dz / len * extra
            end
        end
    end
    return path
end

--- An implement part-way through folding or unfolding (not resting in its middle, lifted position)
function Driver:isFolding()
    for _, v in pairs(allVehicles(self.vehicle)) do
        local spec = v.spec_foldable
        local t = spec and spec.hasFoldingParts and spec.foldAnimTime
        if t and t > 0.001 and t < 0.999 and (spec.foldMiddleAnimTime == nil
                or math.abs(t - spec.foldMiddleAnimTime) > 0.001) then
            return true
        end
    end
    return false
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
    -- (raised early / lowered late by the player's timing: the gap reaches that much further)
    local plan = self.course.plan
    local early = math.max(0, -(plan.raiseLate or 0)) + 0.5
    local late = math.max(0, plan.lowerLate or 0) + math.max(0, (self.info.frontOffset or 0) - (self.info.backOffset or 0)) + 0.5
    for _, gap in ipairs(self.keepGaps) do
        if s > gap.from - early and s < gap.to + late then
            return true
        end
    end
    return false
end

--- Down, but the game says the implements can't go on working. Mostly one isn't switched on: the game switches on
--- only as they are lowered, and refuses that while e.g. a harvester's pipe is still moving (just after unloading);
--- nothing asks again, so it would stand there for ever. Asked again every second (the game's own "go on"), after
--- 3 s switched on directly; after 10 s it says so in the log. (A forage harvester waiting for a trailer, a baler
--- wrapping: switched on already, nothing changes.)
function Driver:askTurnOn(dt)
    local before = self.turnOnWait or 0
    self.turnOnWait = before + (dt or 0)
    if math.floor(self.turnOnWait / 1000) == math.floor(before / 1000) then return end
    self.vehicle:raiseAIEvent("onAIFieldWorkerContinue", "onAIImplementContinue")
    local off = {}
    for _, v in pairs(allVehicles(self.vehicle)) do
        if v.getIsTurnedOn and v.setIsTurnedOn and not v:getIsTurnedOn() then
            local can = v.getCanBeTurnedOn == nil or v:getCanBeTurnedOn()
            if can and self.turnOnWait > 3000 then v:setIsTurnedOn(true) end
            off[#off + 1] = Guidance.vehicleName(v) .. (can and "" or " (the game won't switch it on now)")
        end
    end
    if self.turnOnWait > 10000 and not self.turnOnLogged then
        self.turnOnLogged = true
        Guidance.info("%s: lowered but the game holds it (can't go on working); switched off: %s",
            Guidance.vehicleName(self.vehicle), #off > 0 and table.concat(off, ", ") or "none")
    end
end

--- Which of the combination the game says can't go on working, and whether it is switched on (for the report)
function Driver.whyNotWorking(vehicle)
    local out = {}
    for _, v in pairs(allVehicles(vehicle)) do
        local ok, can = Guidance.try(function()
            return v.getCanAIImplementContinueWork == nil or v:getCanAIImplementContinueWork()
        end)
        if ok and can == false then
            local on = v.getIsTurnedOn and (v:getIsTurnedOn() and "on" or "off") or "-"
            out[#out + 1] = Guidance.vehicleName(v) .. ", switched " .. on
        end
    end
    return #out > 0 and table.concat(out, "; ") or "none of them says why"
end

--- Leaves the implements down but switches off what is switched on (seeding, spraying, mowing stop)
function Driver:switchOffImplements()
    Guidance.debug("%s: turning with the implements down, switched off", Guidance.vehicleName(self.vehicle))
    self.switchedOff = {}
    -- a harvester keeps running (it harvests what it drives over; switched off, the game holds it as one that can't
    -- go on working); so does everything when the player wants it kept running
    if self.harvester or self.course.plan.keepRunning then return end
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
    -- refilling at the field edge: its own way there and back (the course's path waits where we left it)
    if self.refill and self.state == Driver.STATE_DRIVING then
        local tx, tz, fwd, speed, toStop = self:updateRefill(dt, x, z, h)
        self:updateLights(dt)
        self.debugTarget = {tx, tz, speed}
        return tx, tz, fwd, speed, toStop
    end
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
        -- implements unfolding for work: wait until they're done (the game's field helper waits for the same), then
        -- measure them again (folded, the work area isn't where it will be). Not the game's "ready to drive": that
        -- is for the road and wants them folded. Something that never finishes folding doesn't stop us: we go.
        self.prepareTime = (self.prepareTime or 0) + dt
        if self.prepareTime >= Driver.PREPARE_MIN and (not self:isFolding() or self.prepareTime > Driver.PREPARE_TIMEOUT) then
            self.info = GuidanceVehicleInfo.get(vehicle)
            self.state = Driver.STATE_DRIVING
            Guidance.debug("%s: ready after %.1f s, front %.1f, back %.1f", Guidance.vehicleName(vehicle),
                self.prepareTime / 1000, self.info.frontOffset, self.info.backOffset)
        end
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
        self:updateMakingRoom(dt, x, z, h)
    end

    self:updateProgress()
    self:updateLights(dt)
    self:updateStats(dt)
    self:updateFillLevels(dt)
    self:updatePipe(dt)
    self:checkStuck(dt, self.makingRoom and self.makingRoom.speed or maxSpeed)

    -- making room for one we stand in the way of: straight back
    if self.makingRoom and self.state == Driver.STATE_DRIVING then
        local room = self.makingRoom
        local tx, tz = x + room.dirX * 5, z + room.dirZ * 5
        self.debugTarget = {tx, tz, Driver.ROOM_SPEED}
        return tx, tz, false, room.speed, 5
    end

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

    -- (for the debug overlay)
    self.debugTarget = {tx, tz, maxSpeed}
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
                        self.keepGaps = self:findKeepGaps()
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
            local ok, left, right = Guidance.try(obj.getAIMarkers, obj)
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
    -- (why it stands, for the problem report and the overlay)
    self.stopReason = nil
    if self.teamRows then
        self:updateTeamRows()
    end
    if follower:isFinished() then
        self.state = Driver.STATE_DONE
        self:raiseImplements()
        self.vehicle:guidanceSetInfoText("FINISHED", true)
        self.vehicle:stopCurrentAIJob(AIMessageSuccessFinishedJob.new())
        -- the next tractor of the field's chain takes over
        Guidance.try(GuidanceVehicle.handOver, self.vehicle)
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
    -- (a harvester at the start of a row its tank can't take: it waits for the unloader here on the headland, not
    -- full in the middle of the crop)
    if shouldWork and not self.lowered and self:tankHoldAtRowStart() then
        Guidance.info("%s: the next row won't fit in the tank, waiting for an unloader on the headland",
            Guidance.vehicleName(self.vehicle))
        self.vehicle:guidanceSetInfoText("NEEDS_UNLOADING", true)
        self.unloadIdleTimer = 0
        self.state = Driver.STATE_WAIT_UNLOAD
        return 0
    end
    -- (a service trip due: at the end of the stretch, not in the middle of the crop)
    if self.serviceDue and (not self.lowered or self.switchedOff) and not shouldWork then
        self:startServiceTrip()
        return 0
    end
    if shouldWork and self.switchedOff then
        -- down all through the turn: just switch back on
        self:switchOnImplements()
    elseif shouldWork and not self.lowered then
        self:lowerImplements()
        self.state = Driver.STATE_WAIT_LOWER
        self.lowerTimer = 0
        self.stopReason = "lowering the implements"
        return 0
    elseif not shouldWork and self.lowered and not self.switchedOff then
        if self:isInKeepGap(follower.s + self.info.backOffset) then
            self:switchOffImplements()
        else
            self:raiseImplements(true)
        end
    elseif not shouldWork and self.switchedOff and not self:isInKeepGap(follower.s + self.info.backOffset) then
        -- left the turn some other way (stopped, restarted): up after all
        self:switchOnImplements()
        self:raiseImplements(true)
    end
    self:keepImplementsRunning(dt)

    self:updateTurnProgress()

    -- AutoDrive asked us to hold on a moment (its unloader is getting into place)
    if g_time ~= nil and g_time < self.holdUntil then
        self.stopReason = self.chopperWaiting and "nothing under its spout" or "AutoDrive asked it to hold (its unloader getting into place)"
        return 0
    end
    -- harvesting in the rain loses yield (the game's rule, till a while after it stops): stand where we are, on again
    -- when the game would harvest at full yield (not in the middle of a turn)
    if self:isRaining() then
        self.stopReason = "waiting for the rain to stop"
        return 0
    end
    -- the implements can't go on right now (a forage harvester with nothing under its pipe, a baler wrapping)
    -- (not while down but switched off between passes on purpose: then the game says it can't, and it would stand
    -- there for ever)
    if self.lowered and not self.switchedOff and not self.vehicle:getCanAIFieldWorkerContinueWork() then
        self:askTurnOn(dt)
        self.stopReason = "the game says the implements can't go on working (" .. Driver.whyNotWorking(self.vehicle) .. ")"
        return 0
    end
    self.turnOnWait = nil

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
--- mod's or the game's helper, anything moving: "wait" (we stop a gap short and wait). AutoDrive's: standing, waited
--- for AD_WAIT (it may be waiting for us to turn); moving (an unloader drives right beside a combine, it keeps clear
--- itself), or after that wait: "close", never driven into, but not waited for further off. Not our own
--- combination, nothing parked: false
function Driver.isObstacle(self, other)
    if other == self.vehicle or other.isDeleted or other.rootNode == nil then
        return false
    end
    if other.getRootVehicle and other:getRootVehicle() ~= other then
        return false
    end
    if other.ad and other.ad.stateModule and other.ad.stateModule.isActive and other.ad.stateModule:isActive() then
        -- (the unloader AutoDrive sent to us drives right beside us, it keeps clear itself)
        local mode = GuidanceAutoDrive.unloadMode()
        local m = mode and other.ad.modes and other.ad.modes[mode]
        if m and self.harvester and m.combine == self.harvester then return "close" end
        local moving = other.getLastSpeed ~= nil and other:getLastSpeed() > 1
        if moving or (self.adIgnored and self.adIgnored[other]) then return "close" end
        return "wait"
    end
    if other.getIsControlled and other:getIsControlled() then return "wait" end
    if other.getIsAIActive and other:getIsAIActive() then return "wait" end
    return other.getLastSpeed ~= nil and other:getLastSpeed() > 2 and "wait" or false
end

--- A vehicle and the vehicles hitched to it (trailers, implements): the ones with a place in the world
function Driver.partsOf(other)
    local parts = {}
    for _, v in ipairs(other.getChildVehicles and other:getChildVehicles() or {other}) do
        if v.rootNode ~= nil and not v.isDeleted then parts[#parts + 1] = v end
    end
    if #parts == 0 then parts[1] = other end
    return parts
end

--- Where the players on foot are: list of {x, z}
function Driver.playersOnFoot()
    local list = {}
    local system = g_currentMission and g_currentMission.playerSystem
    local players = system and (system.players or (system.getPlayers and system:getPlayers()))
    for _, player in pairs(players or {}) do
        local inVehicle = player.getCurrentVehicle and player:getCurrentVehicle() ~= nil
        if not inVehicle then
            local ok, x, _, z = Guidance.try(function()
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
        -- how far our front reaches ahead of the steering point (a harvester's header: further than a tractor's nose)
        local front = math.max(GuidanceCourseGenerator.VEHICLE_FRONT, (self.info and self.info.frontOffset or 0) + 1)
        --- something at ox, oz, otherHalf wide to each side, 'back' m long behind its middle: in our way? closeOnly:
        --- not waited for further off, only never driven into
        local function check(other, ox, oz, otherHalf, back, closeOnly)
            local dx, dz = ox - x, oz - z
            local ahead = dx * dirX + dz * dirZ
            local side = math.abs(dx * dirZ - dz * dirX)
            if closeOnly then
                if ahead > 0 and ahead < front + back + Driver.TOUCH_GAP and side < half + otherHalf then
                    limit, blockedBy = 0, other
                end
                return
            end
            local gap = Driver.GIVE_WAY_GAP + front + back
            if ahead > 0 and ahead < gap + Driver.GIVE_WAY_SLOW and side < half + otherHalf then
                local f = math.max(0, math.min(1, (ahead - gap) / Driver.GIVE_WAY_SLOW))
                local speed = maxSpeed * f
                if speed < 1.5 then speed = 0 end
                if speed < limit then
                    limit, blockedBy = speed, other
                end
            end
        end
        local ignore = self.ignoreForGiveWay
        for _, other in pairs(vehicles) do
            local otherDriver = other ~= self.vehicle and other.spec_guidance and other.spec_guidance.driver
            local kind = not otherDriver and other ~= ignore and Driver.isObstacle(self, other)
            if kind then
                -- the vehicle and what it pulls (a truck's trailer reaches far behind it)
                for _, part in ipairs(Driver.partsOf(other)) do
                    local ox, _, oz = getWorldTranslation(part.rootNode)
                    local size = part.size or {}
                    check(other, ox, oz, (size.width or 3) / 2, (size.length or 6) / 2, kind == "close")
                end
            end
        end
        for _, player in ipairs(Driver.playersOnFoot()) do
            check(player, player.x, player.z, 0.5, 0.5)
        end
        for _, other in pairs(vehicles) do
            local spec = other ~= self.vehicle and other.spec_guidance or nil
            local od = spec and spec.driver
            local paired = other == ignore
            local yields = od and waitsFor(od, self.vehicle)
            -- a helper without a course (unloader, bale collector...): in our way by its own size and what it pulls,
            -- not by a work width (a truck measured "10 m wide" stood in our way from beside our line)
            if od and od ~= self and spec.helperDriver == od and not paired and other.rootNode then
                for _, part in ipairs(Driver.partsOf(other)) do
                    local ox, _, oz = getWorldTranslation(part.rootNode)
                    local size = part.size or {}
                    check(other, ox, oz, (size.width or 3) / 2, (size.length or 6) / 2, false)
                end
            elseif od and od ~= self and od.state ~= Driver.STATE_DONE and other.rootNode and not paired
                    and not self:isConvoyPartner(od) and yields then
                -- it gives us the right of way, but we don't drive into it: stop short of it (it makes room)
                local ox, _, oz = getWorldTranslation(other.rootNode)
                local dx, dz = ox - x, oz - z
                local ahead = dx * dirX + dz * dirZ
                local side = math.abs(dx * dirZ - dz * dirX)
                local otherHalf = (od.course and od.course.plan.workWidth or 6) / 2 - Driver.GIVE_WAY_OVERLAP / 2
                if ahead > 0 and ahead < Driver.HARD_GAP and side < half + otherHalf then
                    limit, blockedBy = 0, other
                end
            elseif od and od ~= self and od.state ~= Driver.STATE_DONE and other.rootNode and not paired
                    and not self:isConvoyPartner(od) then
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
    local was = self.blockedBy
    self.blockedBy = limit == 0 and blockedBy or nil
    Driver.watchAutoDriveBlock(self, self.blockedBy)
    -- since when we wait for that one (who waited first makes room when two stand in each other's way)
    if self.blockedBy == nil then
        self.blockedSince = nil
    elseif self.blockedBy ~= was or self.blockedSince == nil then
        self.blockedSince = g_time or 0
    end
    self.giveWayTimer = self.blockedBy and (self.giveWayTimer or 0) + dt or 0
    local showing = self.giveWayTimer > Driver.GIVE_WAY_SHOW
    if showing ~= (self.showingGiveWay or false) then
        self.showingGiveWay = showing
        self.vehicle:guidanceSetInfoText("GIVING_WAY", showing)
    end
    return limit
end

--- A standing AutoDrive vehicle holding us up: after AD_WAIT we stop waiting for it further off (it may be waiting
--- for us, e.g. for our turn) and go on up to it, never into it; until it moves or is left behind
function Driver:watchAutoDriveBlock(blockedBy)
    -- (every vehicle has AutoDrive's data: one of our own helpers isn't AutoDrive's)
    local ad = blockedBy ~= nil and type(blockedBy) == "table" and blockedBy.ad ~= nil and blockedBy.rootNode ~= nil
        and not (blockedBy.spec_guidance and blockedBy.spec_guidance.driver)
    local now = g_time or 0
    local standing = ad and not (blockedBy.getLastSpeed ~= nil and blockedBy:getLastSpeed() > 1)
    if ad and self.adIgnored and self.adIgnored[blockedBy] then
        -- right in front of us after all: we stand, once said
        self.adBlock = nil
        if not self.adTouchSaid then
            self.adTouchSaid = true
            Guidance.info("%s: AutoDrive's %s stands right in front of us: waiting till it moves", Guidance.vehicleName(self.vehicle),
                Guidance.vehicleName(blockedBy))
        end
    elseif standing then
        if self.adBlock ~= blockedBy then self.adBlock, self.adBlockSince = blockedBy, now end
        if now - self.adBlockSince > Driver.AD_WAIT then
            self.adIgnored = self.adIgnored or {}
            self.adIgnored[blockedBy] = true
            self.adBlock = nil
            Guidance.info("%s: AutoDrive's %s has stood in our way for %d s: going on up to it", Guidance.vehicleName(self.vehicle),
                Guidance.vehicleName(blockedBy), Driver.AD_WAIT / 1000)
        end
    else
        self.adBlock = nil
    end
    if blockedBy == nil then self.adTouchSaid = nil end
    -- (one that moves again, or is far away: waited for again next time)
    if self.adIgnored then
        local x, _, z = getWorldTranslation(self.vehicle.rootNode)
        for v in pairs(self.adIgnored) do
            local gone = v.isDeleted or v.rootNode == nil
            if not gone then
                local vx, _, vz = getWorldTranslation(v.rootNode)
                gone = (v.getLastSpeed ~= nil and v:getLastSpeed() > 1) or (vx - x) ^ 2 + (vz - z) ^ 2 > 50 * 50
            end
            if gone then self.adIgnored[v] = nil end
        end
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Teams: a convoy keeps its order and spacing; next free row takes rows as it goes
-----------------------------------------------------------------------------------------------------------------------

--- Helpers standing in each other's way (a circle of them each waiting for the next, the ones with the right of way
--- stopped short): the one that waited first backs up, straight back, until nobody is held up by it any more (at
--- most ROOM_BACK m; something behind it: it stays). Then the usual giving way: it waits until the other has gone by.
function Driver:updateMakingRoom(dt, x, z, h)
    local room = self.makingRoom
    if room then
        local backed = math.sqrt((x - room.x) ^ 2 + (z - room.z) ^ 2)
        local stillHeld = false
        for _, d in ipairs(room.circle) do
            if d ~= self and d.blockedBy == self.vehicle and d.state == Driver.STATE_DRIVING then stillHeld = true end
        end
        -- out of the way of the one we back away from: beside its line of travel by both our widths
        local ox, _, oz = getWorldTranslation(room.other.rootNode)
        local _, _, oh = vehiclePose(room.other)
        local clear = math.abs((x - ox) * math.sin(oh) - (z - oz) * math.cos(oh)) > room.clearance
        if not stillHeld or clear or backed > Driver.ROOM_BACK then
            self.makingRoom = nil
            self.returnUntil = (g_time or 0) + Driver.ROOM_RETURN
        else
            -- nothing behind us to back into
            room.speed = self:giveWay(dt, Driver.ROOM_SPEED, x, z, h, true)
            self.blockedBy = room.other
        end
        return
    end
    if self.blockedBy == nil then return end
    -- the circle we're in: from us, each to the one it waits for, back to us
    local circle, d, seen = {self}, self, {[self] = true}
    while true do
        local nextVehicle = d.blockedBy
        local nd = nextVehicle and nextVehicle.spec_guidance and nextVehicle.spec_guidance.driver
        if nd == nil then return end
        if nd == self then break end
        if seen[nd] then return end
        seen[nd] = true
        circle[#circle + 1] = nd
        d = nd
    end
    -- the one that waited first (the same moment: the higher id) makes room
    for _, o in ipairs(circle) do
        if o ~= self then
            local mine, theirs = self.blockedSince or 0, o.blockedSince or 0
            if theirs < mine or (theirs == mine and Driver.priority(o.vehicle) > Driver.priority(self.vehicle)) then
                return
            end
        end
    end
    -- back away at an angle, to the side of the other's line of travel we're on (on it: the right)
    local other = self.blockedBy
    local ox, _, oz = getWorldTranslation(other.rootNode)
    local _, _, oh = vehiclePose(other)
    local across = (x - ox) * math.sin(oh) - (z - oz) * math.cos(oh)
    local lx, lz = leftOf(h)
    local towardsLeftOfOther = across >= 0
    -- which of our sides that is: the other's left seen from us
    local olx, olz = math.sin(oh), -math.cos(oh)
    local sideSign = ((lx * olx + lz * olz) >= 0) == towardsLeftOfOther and 1 or -1
    local a = Driver.ROOM_ANGLE
    local dirX = -math.cos(h) * math.cos(a) + lx * sideSign * math.sin(a)
    local dirZ = -math.sin(h) * math.cos(a) + lz * sideSign * math.sin(a)
    local od = other.spec_guidance and other.spec_guidance.driver
    local width = (self.course.plan.workWidth or 6) / 2 + (od and od.course and od.course.plan.workWidth or 6) / 2 + 1
    Guidance.debug("%s: backing up to let the others by", Guidance.vehicleName(self.vehicle))
    self.makingRoom = {x = x, z = z, other = other, circle = circle, speed = Driver.ROOM_SPEED, dirX = dirX,
                       dirZ = dirZ, clearance = width}
end

--- Who backs up when two waited for each other from the same moment: the one with the higher id
function Driver.priority(vehicle)
    local id = vehicle.id or vehicle.rootNode
    if type(id) == "number" then return id end
    return tonumber(string.match(tostring(vehicle), "%x+$") or "0", 16) or 0
end

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
        self.lastAcross, 2 * plan.turnRadius, self.teamFreshStart)
    if row == nil then
        return false
    end
    self.teamFreshStart = false
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
        table.insert(new, {x = wp.x, z = wp.z, t = wp.t, work = wp.work, rev = wp.rev, keep = wp.keep, lane = wp.lane,
                           ix = i})
    end
    self:reachBackAtCusps(new)
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
        if v.setBeaconLightsVisibility then Guidance.try(v.setBeaconLightsVisibility, v, true) end
    end
    local env = g_currentMission and g_currentMission.environment
    local night = env ~= nil and env.isSunOn == false
    if v.updateAutomaticLights then
        Guidance.try(v.updateAutomaticLights, v, night, true)
    elseif v.setLightsTypesMask then
        -- main and work lights (front and back)
        Guidance.try(v.setLightsTypesMask, v, night and 7 or self.lightsBefore.mask)
    end
end

function Driver:restoreLights()
    local v, before = self.vehicle, self.lightsBefore
    if before == nil then
        return
    end
    self.lightsBefore = nil
    if v.setLightsTypesMask then Guidance.try(v.setLightsTypesMask, v, before.mask) end
    if v.setBeaconLightsVisibility then Guidance.try(v.setBeaconLightsVisibility, v, before.beacons) end
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

--- Vine tools (grape harvester, pre-pruner, vine sprayer...) aren't the game's AI implements: unfolded, lowered
--- on their attacher joint and switched on by hand
function Driver.isVineTool(v)
    return v.spec_vineCutter ~= nil or v.spec_vinePrepruner ~= nil
end

function Driver.setVineToolWorking(v, working)
    if working and v.getIsUnfolded and not v:getIsUnfolded() and v.setFoldDirection and v.spec_foldable then
        v:setFoldDirection(v.spec_foldable.turnOnFoldDirection or -1)
    end
    local attacher = v.getAttacherVehicle and v:getAttacherVehicle()
    if attacher and attacher.getAttacherJointIndexFromObject and attacher.setJointMoveDown then
        local ix = attacher:getAttacherJointIndexFromObject(v)
        if ix then attacher:setJointMoveDown(ix, working, false) end
    end
    if v.setIsTurnedOn and v.getIsTurnedOn and v:getIsTurnedOn() ~= working
            and (not working or v.getCanBeTurnedOn == nil or v:getCanBeTurnedOn()) then
        v:setIsTurnedOn(working)
    end
end

function Driver:lowerImplements()
    Guidance.debug("%s: lowering at %.1f m", Guidance.vehicleName(self.vehicle), self.follower.s)
    for _, implement in pairs(self.vehicle:getAttachedAIImplements()) do
        implement.object:aiImplementStartLine()
    end
    for _, v in pairs(allVehicles(self.vehicle)) do
        if Driver.isVineTool(v) then Driver.setVineToolWorking(v, true) end
    end
    self.vehicle:raiseStateChange(VehicleStateChange.AI_START_LINE)
    self.lowered = true
end

--- Lifted with When lifted: Keep running: what was switched on stays on (switched on again where the game switched
--- it off as it lifted it, now or a moment later); till it is lowered again or the helper stops
function Driver:keepImplementsRunning(dt)
    local list = self.keepOn
    if list == nil then return end
    if self.lowered or not self.course.plan.keepRunning then
        self.keepOn = nil
        return
    end
    self.keepOnTimer = (self.keepOnTimer or 0) + (dt or 0)
    if self.keepOnTimer < 500 then return end
    self.keepOnTimer = 0
    for _, v in ipairs(list) do
        if not v.isDeleted and not v:getIsTurnedOn() and (v.getCanBeTurnedOn == nil or v:getCanBeTurnedOn()) then
            v:setIsTurnedOn(true)
        end
    end
end

--- Lifts the implements. working: lifted during the work (a turn, from one pass to the next), not at its end: then
--- with the player's When lifted: Keep running they stay switched on (the game switches them off as it lifts them)
function Driver:raiseImplements(working)
    if not working then self.keepOn = nil end
    if not self.lowered then
        return
    end
    Guidance.debug("%s: raising at %.1f m", Guidance.vehicleName(self.vehicle), self.follower.s)
    local running
    if working and self.course.plan.keepRunning then
        running = {}
        for _, v in pairs(allVehicles(self.vehicle)) do
            if v.getIsTurnedOn and v.setIsTurnedOn and v:getIsTurnedOn() then running[#running + 1] = v end
        end
    end
    for _, implement in pairs(self.vehicle:getAttachedAIImplements()) do
        implement.object:aiImplementEndLine()
    end
    self.keepOn = running
    if running then self.keptOnBefore = running end
    self.keepOnTimer = math.huge
    for _, v in pairs(allVehicles(self.vehicle)) do
        if Driver.isVineTool(v) then Driver.setVineToolWorking(v, false) end
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

--- A harvester that would lose yield now (rain), and its player wants it to wait for that: true. Shows the status.
function Driver:isRaining()
    local h = self.harvester
    local wait = h ~= nil and self.course.plan.rainWait ~= false and h.getIsThreshingDuringRain ~= nil
        and h:getIsThreshingDuringRain() and not self:isManeuvering()
    if wait ~= (self.rainWaiting or false) then
        self.rainWaiting = wait
        self.vehicle:guidanceSetInfoText("WAITING_RAIN", wait)
        Guidance.info("%s: %s", Guidance.vehicleName(self.vehicle), wait and "rain, waiting (harvesting now loses yield)"
            or "the crop is dry again, going on")
    end
    return wait
end

--- Stand still for ms (AutoDrive calls this every frame while its unloader gets into place)
function Driver:hold(ms)
    if g_time ~= nil then
        self.holdUntil = math.max(self.holdUntil, g_time + (ms or 200))
    end
end

--- AutoDrive holding us (every frame while its unloader is beside us): stand still, while that gets the tank emptied.
--- Held on with nothing coming out of the tank (AutoDrive waits for the last litre, its trailer can't drive on): after
--- HOLD_STALL we go on regardless, else both stand there for ever; till it lets go and holds again.
function Driver:holdForAutoDrive(ms)
    if g_time == nil then return end
    local h = self.harvester
    local level = 0
    if h and h.spec_combine and h.getFillUnitFillLevel then level = h:getFillUnitFillLevel(h.spec_combine.fillUnitIndex) or 0 end
    local watch = self.adHold
    if watch == nil or g_time - watch.last > 2000 then
        watch = {since = g_time, level = level}
        self.adHold = watch
    end
    watch.last = g_time
    if level < watch.level - 1 then
        -- (grain still coming out: worth standing for)
        watch.since, watch.level = g_time, level
    end
    if g_time - watch.since > Driver.HOLD_STALL then
        if not watch.ignored then
            watch.ignored = true
            Guidance.info("%s: AutoDrive holds us, but nothing has come out of the tank for %d s: going on",
                Guidance.vehicleName(self.vehicle), Driver.HOLD_STALL / 1000)
        end
        return
    end
    self:hold(ms)
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
--- of its list of levels). We set it from ours, to the nearest step (atOrBelow: the highest step not above it, so
--- that a call now is a call)
function Driver.setCallUnloaderLevel(vehicle, harvester, percent, atOrBelow)
    local ad = AutoDrive
    if ad == nil and FS25_AutoDrive ~= nil then ad = FS25_AutoDrive.AutoDrive end
    if ad == nil or ad.settings == nil or ad.settings.preCallLevel == nil or ad.setSettingState == nil then
        return
    end
    local values = ad.settings.preCallLevel.values or {}
    local best, bestD
    for i, v in ipairs(values) do
        local d = math.abs(v - percent / 100)
        if atOrBelow then
            d = v <= percent / 100 + 1e-6 and percent / 100 - v or math.huge
        end
        if d < math.huge and (bestD == nil or d < bestD) then best, bestD = i, d end
    end
    if best == nil then
        return
    end
    -- (the vehicle itself, and a harvester attached to it if that's another one; sent to everybody, so AutoDrive's
    -- menu shows it)
    for _, v in ipairs(harvester ~= vehicle and {vehicle, harvester} or {vehicle}) do
        if v.ad and v.ad.settings and v.ad.settings.preCallLevel then
            GuidanceAutoDrive.setSetting(v, "preCallLevel", best)
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

--- Are there unloaders for this harvester (our own on its field, or AutoDrive's)? Then it waits for them when full,
--- instead of stopping for AutoDrive to drive it away.
function Driver:hasAutoDriveUnloaders()
    local manager = ADHarvestManager
    if manager == nil and FS25_AutoDrive ~= nil then
        manager = FS25_AutoDrive.ADHarvestManager
    end
    if manager == nil or manager.hasHarvesterPotentialUnloaders == nil then
        return false
    end
    local ok, result = Guidance.try(manager.hasHarvesterPotentialUnloaders, manager, self.harvester)
    return ok and result == true
end

--- The work interval (of the follower's, {from, to} along the path) the front of the work area is in or comes to next
function Driver:currentWorkInterval()
    local front = self.follower.s + self.info.frontOffset
    for _, w in ipairs(self.follower.workIntervals or {}) do
        if w.to > front then return w end
    end
    return nil
end

--- The type of the course's stretch starting at s along the path ("R" a row, "H" a headland pass...)
function Driver:stretchTypeAt(s)
    for _, p in ipairs(self.follower.points) do
        if p.d > s + 0.5 then return p.t end
    end
    return nil
end

--- A harvester's tank: litres in it, its capacity; and, while harvesting, how many litres one metre brings (learned
--- as it goes; while unloading on the move nothing is learned)
function Driver:updateTankRate()
    local h = self.harvester
    if h == nil or Driver.isChopper(h) then return nil end
    local ix = h.spec_combine.fillUnitIndex
    local level, capacity = h:getFillUnitFillLevel(ix), h:getFillUnitCapacity(ix)
    local s = self.follower.s
    local working = self.lowered and not self.switchedOff and self.state == Driver.STATE_DRIVING
        and not self.follower:isReversing()
    local last = self.tankLast
    if working and last and level >= last.level and s > last.s + 0.5 then
        local rate = (level - last.level) / (s - last.s)
        self.tankRate = self.tankRate and (0.7 * self.tankRate + 0.3 * rate) or rate
        self.tankMeasured = (self.tankMeasured or 0) + s - last.s
    end
    self.tankLast = working and {level = level, s = s} or nil
    return level, capacity
end

--- Litres per metre, once learned (nil before)
function Driver:tankRateKnown()
    if (self.tankMeasured or 0) < Driver.TANK_LEARN or (self.tankRate or 0) <= 0 then return nil end
    return self.tankRate
end

--- At the start of a row: does the row need more than the tank has room for, with unloaders about but none on its
--- way to us? (Then waiting here on the headland beats standing full in the crop; one on its way empties it on the
--- move. A row longer than a whole tank: no use waiting.)
function Driver:tankHoldAtRowStart()
    local rate = self.harvester and self:tankRateKnown()
    local w = rate and self:currentWorkInterval()
    if w == nil or self:stretchTypeAt(w.from) ~= "R" then return false end
    local ix = self.harvester.spec_combine.fillUnitIndex
    local level, capacity = self.harvester:getFillUnitFillLevel(ix), self.harvester:getFillUnitCapacity(ix)
    local need = rate * (w.to - w.from)
    if capacity <= 0 or need > capacity * Driver.TANK_FULL or level + need <= capacity * Driver.TANK_FULL then
        return false
    end
    return self:unloadersAbout(0) and self:sentUnloader(0) == nil
end

--- While harvesting: full before this stretch ends? Then AutoDrive is asked for its unloader now (its call level on
--- the harvester set to where the tank is), not only at our call level; back to the player's once emptied or one
--- is sent
function Driver:updateEarlyCall(level, capacity)
    local rate = self:tankRateKnown()
    if self.calledEarly then
        if level < capacity * Driver.EARLY_CALL_RESET or self:sentUnloader(0) ~= nil then
            self.calledEarly = nil
            Driver.setCallUnloaderLevel(self.vehicle, self.harvester, self.course.plan.callUnloaderAt or 80)
        end
        return
    end
    local w = rate and self.lowered and self:currentWorkInterval()
    if w == nil or capacity <= 0 then return end
    local left = w.to - (self.follower.s + self.info.frontOffset)
    if level + rate * left <= capacity * Driver.TANK_FULL then return end
    if level >= capacity * (self.course.plan.callUnloaderAt or 80) / 100 then return end
    if not self:unloadersAbout(0) or self:sentUnloader(0) ~= nil then return end
    self.calledEarly = true
    Driver.setCallUnloaderLevel(self.vehicle, self.harvester, math.floor(100 * level / capacity), true)
    Guidance.info("%s: full in %.0f m, before the end of this stretch (%.0f m): unloader called now, at %d%%",
        Guidance.vehicleName(self.vehicle), (capacity * Driver.TANK_FULL - level) / rate, left,
        math.floor(100 * level / capacity))
end

--- A forage harvester (or a buffer combine): it holds no grain, its spout goes straight into a trailer alongside
function Driver.isChopper(harvester)
    local spec = harvester and harvester.spec_combine
    if spec == nil then return false end
    if spec.isBufferCombine then return true end
    local c = harvester.getFillUnitCapacity and harvester:getFillUnitCapacity(spec.fillUnitIndex)
    return c ~= nil and c > 1e7
end

--- The AutoDrive unloader sent to this harvester (driving its "unload combine" mode for it), or nil
function Driver.autoDriveUnloaderOf(harvester)
    local mode = GuidanceAutoDrive.unloadMode()
    local vehicles = mode and harvester and g_currentMission and g_currentMission.vehicleSystem
        and g_currentMission.vehicleSystem.vehicles
    for _, v in pairs(vehicles or {}) do
        local m = v.ad and v.ad.modes and v.ad.modes[mode]
        if m and (m.combine == harvester or (m.combine and m.combine.getRootVehicle
                and m.combine:getRootVehicle() == harvester:getRootVehicle()))
                and v.ad.stateModule and v.ad.stateModule:isActive() then
            return v
        end
    end
    return nil
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
    -- a forage harvester: the spout always out; nothing under it (and not turning): it holds
    if Driver.isChopper(harvester) then
        setPipe(harvester, true)
        if spec then spec.automaticDischarge = true end
        local ok, node = Guidance.try(function() return harvester:getDischargeNodeByIndex(harvester:getPipeDischargeNodeIndex()) end)
        local target = ok and node and (node.dischargeObject
            or (harvester.getDischargeTargetObject and harvester:getDischargeTargetObject(node)))
        local waiting = target == nil and self.lowered and not self:isManeuvering()
        if waiting then self:hold(500) end
        if waiting ~= (self.chopperWaiting or false) then
            self.chopperWaiting = waiting
            self.vehicle:guidanceSetInfoText("NEEDS_UNLOADING", waiting)
        end
        return
    end
    -- the AutoDrive unloader sent to us on its way and near: out already, so it sees which side the pipe is on before
    -- it lines up; alongside, the combine fills the trailer under it by itself
    local unloaderComing = false
    local unloader = self:sentUnloader(dt)
    if unloader ~= nil and unloader.rootNode then
        local ux, _, uz = getWorldTranslation(unloader.rootNode)
        local cx, _, cz = getWorldTranslation(self.vehicle.rootNode)
        unloaderComing = (ux - cx) ^ 2 + (uz - cz) ^ 2 < Driver.PIPE_OUT_FOR_UNLOADER ^ 2
    end
    local unloaderHere = unloaderComing and somethingUnder
    if unloaderHere and spec and spec.automaticDischarge == false then spec.automaticDischarge = true end
    -- at the call level, with unloaders about: out (not in turns), so an unloader on the move (AutoDrive's active
    -- unloading) lines up under it and the tank is emptied as we go
    local level = harvesterFillLevel(harvester)
    local calling = level >= (self.course.plan.callUnloaderAt or 80) / 100 and not self:isManeuvering()
        and self:unloadersAbout(dt)
    if self.state == Driver.STATE_WAIT_UNLOAD or unloaderHere or unloaderComing or calling
            or (somethingUnder and level > 0) then
        setPipe(harvester, true)
        self.pipeIdleTimer = 0
    else
        self.pipeIdleTimer = self.pipeIdleTimer + dt
        if self.pipeIdleTimer > Driver.PIPE_CLOSE_DELAY then
            setPipe(harvester, false)
        end
    end
end

--- The AutoDrive unloader sent to us (looked for once a second), or nil
function Driver:sentUnloader(dt)
    self.sentTimer = (self.sentTimer or math.huge) + (dt or 0)
    if self.sentTimer > 1000 then
        self.sentTimer = 0
        self.sentKnown = Driver.autoDriveUnloaderOf(self.harvester)
    end
    return self.sentKnown
end

--- Are there AutoDrive unloaders for us? Looked at every few seconds.
function Driver:unloadersAbout(dt)
    self.unloadersTimer = (self.unloadersTimer or math.huge) + (dt or 0)
    if self.unloadersTimer > 3000 then
        self.unloadersTimer = 0
        self.unloadersKnown = self:hasAutoDriveUnloaders()
    end
    return self.unloadersKnown == true
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
    self:switchOffKept()
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
    -- (backing up to make room takes us off the course on purpose)
    local returning = self.returnUntil ~= nil and (g_time or 0) < self.returnUntil
    -- where it last was on its line while working (to come back to there, not further along, when pushed off)
    local tracked = not self.convoy and not self.teamRows and (self.sideOffset or 0) == 0
    local working = self.lowered and not self.switchedOff and self.turnIx == nil and not self.follower:isReversing()
    -- pushed off: it was on its line on this stretch and got off it; not still getting onto it after a turn or
    -- backing up (a long harvester ends up metres off the next line at a square corner), not at a corner's stop
    if not working then
        self.onLine = false
    end
    if tracked and working and self.follower.crossTrack < 1.5 then
        self:rememberSpot()
        self.onLine = true
    end
    if tracked and working and self.onLine and self.follower.crossTrack > Driver.PUSHED_DISTANCE
            and self.follower:getDistanceToCusp() > Driver.PUSHED_CUSP and not self:nearLaneMove(Driver.PUSHED_LANE)
            and not self.makingRoom and not returning then
        self.pushedTimer = (self.pushedTimer or 0) + dt
        if self.pushedTimer > Driver.PUSHED_TIME then
            self.pushedTimer = 0
            if self:backToSpot() then return end
        end
    else
        self.pushedTimer = 0
    end
    if self.follower.crossTrack > Driver.LOST_DISTANCE and not self.makingRoom and not returning then
        self.lostTimer = self.lostTimer + dt
        if self.lostTimer > Driver.LOST_TIME then
            self.lostTimer = 0
            -- (a convoy's outer lane round a corner too tight for it, pushed off...): back on a bit further along
            if (self.rejoins or 0) < Driver.REJOINS and self:rejoin() then
                return
            end
            Guidance.info("%s: %.0f m off the course, giving up", Guidance.vehicleName(self.vehicle),
                self.follower.crossTrack)
            self:stop(AIMessageErrorBlockedByObject.new(), "IS_STUCK")
        end
    else
        self.lostTimer = 0
    end
end

--- Off the course and can't get back on where it is: a new way to the course REJOIN_AHEAD m further along (to its
--- own lane in a convoy), the implements up until it is there. False when the course ends before that.
function Driver:rejoin()
    local f = self.follower
    -- first back to where it left its line (it would miss what it was pushed past), on further along only if it gets
    -- thrown off there again
    if self:backToSpot() then
        return true
    end
    if not self.convoy then
        -- a way from here onto our own path further along (the rows a team member took stay as they are)
        local j
        for k = f.ix + 1, #f.points do
            if f.points[k].d >= f.s + Driver.REJOIN_AHEAD then
                j = k
                break
            end
        end
        -- (the path so far ends sooner: a team member adds its rows as it goes) its end
        if j == nil and #f.points > f.ix + 1 then j = #f.points end
        if j == nil then return false end
        self:noteRejoin()
        local tp = f.points[j]
        local np = f.points[j + 1] or tp
        local pp = f.points[j - 1] or tp
        local h0 = np ~= tp and math.atan2(np.z - tp.z, np.x - tp.x) or math.atan2(tp.z - pp.z, tp.x - pp.x)
        local vx, vz, vh = vehiclePose(self.vehicle)
        local wx, wz = self:workPoint(vx, vz, vh)
        local runIn = math.max(self.info.runOut, 3)
        local settings = self.course.plan:getGeneratorSettings()
        local pts = GuidanceCourseGenerator.planApproach(self.course.area, settings, {x = wx, y = wz, h = vh},
            {x = tp.x - math.cos(h0) * runIn, y = tp.z - math.sin(h0) * runIn, h = h0})
        local way = {{x = wx, z = wz, t = "C", work = false}}
        for _, q in ipairs(pts) do way[#way + 1] = {x = q.x, z = q.y, t = "C", work = false} end
        f:replaceRange(f.ix, j, way)
    else
        -- a convoy member: to its lane again (and on it from its start), the course further along
        local wps = self.course.waypoints
        local d = self:getCourseDistance() + Driver.REJOIN_AHEAD
        local ix
        for i = 1, #wps - 1 do
            if wps[i].d >= d then
                ix = i
                break
            end
        end
        if ix == nil then return false end
        self:noteRejoin()
        if self.onLane then
            self.onLane = false
            self.sideOffset = self.sideOffset + self.convoyOffset
            if self.targetSideOffset then self.targetSideOffset = self.targetSideOffset + self.convoyOffset end
        end
        self.follower = GuidancePathFollower.new(self:buildPath(ix))
        self.laneStartPoint = nil
        for _, pt in ipairs(self.follower.points) do
            if pt.laneStart then self.laneStartPoint = pt break end
        end
    end
    self.turns = self:findTurns()
    self.turnIx = nil
    self.keepGaps = self:findKeepGaps()
    self.lastS = nil
    self.stuckTimer = 0
    return true
end

--- On or within dist (m, along the path) of a move from one headland pass to the next
function Driver:nearLaneMove(dist)
    local f = self.follower
    local pts = f.points
    for k = f.ix, 1, -1 do
        local pt = pts[k]
        if pt.d < f.s - dist then break end
        if pt.lane then return true end
    end
    for k = f.ix + 1, #pts do
        local pt = pts[k]
        if pt.d > f.s + dist then break end
        if pt.lane then return true end
    end
    return false
end

--- The spot on its line it last worked at: the course waypoint it was heading for, and where it was
function Driver:rememberSpot()
    local f = self.follower
    for k = f.ix + 1, math.min(#f.points, f.ix + 3) do
        local pt = f.points[k]
        if pt.ix then
            local vx, vz, vh = vehiclePose(self.vehicle)
            local x, z = self:workPoint(vx, vz, vh)
            self.spot = {ix = pt.ix, x = x, z = z}
            return
        end
    end
end

--- Pushed or thrown off its line: a way back to the spot it last worked at, and on along the course from there,
--- the implements up until it is back. Not twice for the same spot (something keeps throwing it off there: the
--- usual rejoin further along then). False when there is no such spot.
function Driver:backToSpot()
    local spot = self.spot
    if spot == nil or self.convoy or self.teamRows or self.course.waypoints[spot.ix] == nil or spot.ix <= 1 then
        return false
    end
    local last = self.lastSpot
    if last and (last.x - spot.x) ^ 2 + (last.z - spot.z) ^ 2 < Driver.SAME_SPOT ^ 2 then
        return false
    end
    self.lastSpot = {x = spot.x, z = spot.z}
    self.rejoins = (self.rejoins or 0) + 1
    Guidance.info("%s: %.0f m off its line, back to where it left it", Guidance.vehicleName(self.vehicle),
        self.follower.crossTrack)
    self:raiseImplements()
    self.follower = GuidancePathFollower.new(self:buildPath(spot.ix, {x = spot.x, z = spot.z}))
    self.spot = nil
    self.turns = self:findTurns()
    self.turnIx = nil
    self.keepGaps = self:findKeepGaps()
    self.lastS = nil
    self.stuckTimer = 0
    self.lostTimer = 0
    return true
end

--- The helper stops: what it kept running while lifted goes off (as the game does with the rest)
function Driver:switchOffKept()
    for _, v in ipairs(self.keptOnBefore or {}) do
        if not v.isDeleted and v.getIsTurnedOn and v:getIsTurnedOn() then v:setIsTurnedOn(false) end
    end
end

function Driver:noteRejoin()
    self.rejoins = (self.rejoins or 0) + 1
    Guidance.info("%s: %.0f m off the course, back on %d m further along", Guidance.vehicleName(self.vehicle),
        self.follower.crossTrack, Driver.REJOIN_AHEAD)
    self:raiseImplements()
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

Driver.SERVICE_RETRY = 600000 -- ms before a trip that didn't help (no station, still low) is tried again

--- The lowest fuel (of the tank, 0..1) and the highest wear (damage 0..1) of the vehicle and what it pulls
function Driver.fuelAndWear(vehicle)
    local fuel, wear
    for _, v in pairs(allVehicles(vehicle)) do
        if v.spec_motorized and v.spec_motorized.propellantFillUnitIndices then
            for _, ix in pairs(v.spec_motorized.propellantFillUnitIndices) do
                local f = fillPercentage(v, ix)
                if f and (fuel == nil or f < fuel) then fuel = f end
            end
        end
        if v.getDamageAmount then
            local ok, d = Guidance.try(v.getDamageAmount, v)
            if ok and d and (wear == nil or d > wear) then wear = d end
        end
    end
    return fuel, wear
end

--- Fuel under the plan's Refuel at, or worn to its Repair at, with AutoDrive there to take it to the fuel station or
--- the workshop and bring it back (it starts us again where we stopped): "fuel", "repair" or nil. Not again soon
--- after a trip that didn't help.
function Driver:serviceNeeded()
    local plan = self.course.plan
    local refuelAt, repairAt = plan.refuelAt or 0, plan.repairAt or 0
    if (refuelAt <= 0 and repairAt <= 0) or not GuidanceAutoDrive.canService(self.vehicle) then return nil end
    local fuel, wear = Driver.fuelAndWear(self.vehicle)
    local missionInfo = g_currentMission and g_currentMission.missionInfo
    local tried = self.vehicle.spec_guidance and self.vehicle.spec_guidance.serviceTried or {}
    local function recent(kind) return tried[kind] and (g_time or 0) - tried[kind] < Driver.SERVICE_RETRY end
    if refuelAt > 0 and fuel and fuel < refuelAt / 100 and not (missionInfo and missionInfo.helperBuyFuel)
            and not recent("fuel") then
        return "fuel"
    end
    if repairAt > 0 and wear and wear >= repairAt / 100 and not recent("repair") then
        return "repair"
    end
    return nil
end

--- Off for fuel / a repair: the job stops the way AutoDrive knows from Courseplay (out of fuel, broken), AutoDrive
--- takes it there and starts us again where we stopped
function Driver:startServiceTrip()
    local kind = self.serviceDue
    self.serviceDue = nil
    if kind == nil then return end
    local spec = self.vehicle.spec_guidance
    if spec then
        spec.serviceTried = spec.serviceTried or {}
        spec.serviceTried[kind] = g_time or 0
    end
    GuidanceAutoDrive.prepareService(self.vehicle, kind)
    Guidance.info("%s: %s: AutoDrive takes it to the %s, then it carries on here", Guidance.vehicleName(self.vehicle),
        kind == "fuel" and "fuel low" or "worn", kind == "fuel" and "fuel station" or "workshop")
    if kind == "fuel" then
        self:stop(AIMessageErrorOutOfFuel.new(), "SERVICE_FUEL")
    else
        self:stop(AIMessageErrorVehicleBroken.new(), "SERVICE_REPAIR")
    end
end

function Driver:updateFillLevels(dt)
    self.fillCheckTimer = self.fillCheckTimer + dt
    if self.fillCheckTimer < Driver.FILL_CHECK_INTERVAL or self.state == Driver.STATE_DONE then
        return
    end
    self.fillCheckTimer = 0
    local missionInfo = g_currentMission.missionInfo
    local fuelLow, isFull, isEmpty = false, false, false
    -- what ran out (for a refill trip)
    local emptyTypes = {}
    -- (and which implement, which fill unit: to refill it at the field edge)
    local needer, needIx
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
            if seed and seed <= 0 then
                isEmpty = true
                needer, needIx = v, v.spec_sowingMachine.fillUnitIndex
                if FillType and FillType.SEEDS then table.insert(emptyTypes, FillType.SEEDS) end
            end
        end
        if v.getSprayerFillUnitIndex and not missionInfo.helperBuyFertilizer and v.spec_sowingMachine == nil then
            local ok, ix = Guidance.try(v.getSprayerFillUnitIndex, v)
            local sprayLevel = ok and fillPercentage(v, ix)
            if sprayLevel and sprayLevel <= 0 then
                isEmpty = true
                needer, needIx = needer or v, needIx or ix
                -- what it was spraying, else what it takes
                local ft = v.spec_fillUnit and v.spec_fillUnit.fillUnits and v.spec_fillUnit.fillUnits[ix]
                    and v.spec_fillUnit.fillUnits[ix].lastValidFillType
                if ft and ft ~= 0 then
                    table.insert(emptyTypes, ft)
                elseif v.getFillUnitSupportedFillTypes then
                    for t in pairs(v:getFillUnitSupportedFillTypes(ix) or {}) do table.insert(emptyTypes, t) end
                end
            end
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
    -- a harvester: how fast its tank fills, and whether it calls its unloader earlier than its call level
    local tankLevel, tankCapacity = self:updateTankRate()
    if tankLevel and not isFull and self.state == Driver.STATE_DRIVING then
        self:updateEarlyCall(tankLevel, tankCapacity)
    end
    -- fuel low or worn: a trip with AutoDrive, at the end of this stretch (see startServiceTrip)
    if self.serviceDue == nil then
        self.serviceDue = self:serviceNeeded()
    end
    if isFull and self.state ~= Driver.STATE_WAIT_UNLOAD then
        if self.harvester and self:hasAutoDriveUnloaders() then
            -- AutoDrive's unloaders come to a combine that stands with its pipe out
            Guidance.debug("%s: full, waiting for an unloader", Guidance.vehicleName(self.vehicle))
            self:raiseImplements()
            self.vehicle:guidanceSetInfoText("NEEDS_UNLOADING", true)
            self.unloadIdleTimer = 0
            self.state = Driver.STATE_WAIT_UNLOAD
        elseif self.harvester then
            -- a harvester with nobody to unload it: stopped, and the player told why (what would make one come)
            Guidance.info("%s: full and no unloader for it (no AutoDrive truck with the same first target as this "
                .. "harvester): stopped", Guidance.vehicleName(self.vehicle))
            self:stop(AIMessageGuidanceIsFull.new(), "NO_UNLOADER")
        else
            self:stop(AIMessageGuidanceIsFull.new(), "NEEDS_UNLOADING")
        end
    elseif isEmpty then
        -- from a supply at the field edge (if the player wants that and there is one)
        if self.course.plan.refillEdge and self.refill == nil and self:startEdgeRefill(needer, needIx, emptyTypes) then
            return
        end
        -- a refill trip (the plan names a station), else stop for AutoDrive or the player
        local job = self.task and self.task.job
        if job and job.startRefillTrip and job:startRefillTrip(self, emptyTypes) then
            self.state = Driver.STATE_DONE
            self:raiseImplements()
            return
        end
        self:stop(AIMessageErrorOutOfFill.new(), "NEEDS_FILLING")
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Refilling at the field edge: from a supply standing there (seed / fertiliser pallets and big bags, a water or
-- liquid tanker: anything the game fills vehicles from, a FillTriggerVehicle), instead of a trip on the roads. The
-- implement's opening is driven into the supply's trigger, filled up, and the course goes on where it stopped.
-----------------------------------------------------------------------------------------------------------------------

Driver.SUPPLY_REACH = 30 -- m off the field a supply may stand
Driver.REFILL_SPEED = 8 -- km/h to the supply and back
Driver.REFILL_CREEP = 2 -- km/h the last metres into its trigger
Driver.REFILL_CREEP_MAX = 8 -- m it creeps before it gives that supply up
Driver.REFILL_FULL = 0.98
Driver.REFILL_STALL = 4000 -- ms filling without getting fuller: the supply is empty (or doesn't fit)

local function isOurs(self, v)
    for _, c in pairs(allVehicles(self.vehicle)) do
        if c == v then return true end
    end
    return false
end

--- On our field or within SUPPLY_REACH m of it
function Driver:isNearField(x, z)
    local field = self.course.area and self.course.area.field
    if field == nil then return true end
    self.fieldIndexForSupply = self.fieldIndexForSupply or GuidanceGeo.outlineIndex(field, 10)
    if self.fieldIndexForSupply:isInside({x = x, y = z}) then return true end
    return self.fieldIndexForSupply:closest({x = x, y = z}, Driver.SUPPLY_REACH) ~= nil
end

--- The nearest supply that has one of the fill types and something in it: vehicle, its trigger node; or nil
function Driver:findSupply(needer, needIx, types)
    local wanted = {}
    for _, t in ipairs(types) do wanted[t] = true end
    local x, z = vehiclePose(self.vehicle)
    local vehicles = g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles or {}
    local best, bestNode, bestD
    for _, v in pairs(vehicles) do
        local spec = v.spec_fillTriggerVehicle
        local trigger = spec and spec.fillTrigger
        local node = trigger and trigger.triggerNode
        if node and not isOurs(self, v) and not (self.emptySupplies and self.emptySupplies[v]) then
            local ix = spec.fillUnitIndex or 1
            local ft = v:getFillUnitFillType(ix)
            local takes = needer.getFillUnitSupportsFillType == nil or needer:getFillUnitSupportsFillType(needIx, ft)
            if wanted[ft] and takes and v:getFillUnitFillLevel(ix) > 1 then
                local tx, _, tz = getWorldTranslation(node)
                local d = math.sqrt((tx - x) ^ 2 + (tz - z) ^ 2)
                if self:isNearField(tx, tz) and (bestD == nil or d < bestD) then best, bestNode, bestD = v, node, d end
            end
        end
    end
    return best, bestNode
end

--- Out of seed / fertiliser / spray: to a supply at the field edge, if there is one. True when on the way.
function Driver:startEdgeRefill(needer, needIx, types)
    if needer == nil or needer.setFillUnitIsFilling == nil then return false end
    local supply, node = self:findSupply(needer, needIx, types)
    if supply == nil then
        Guidance.info("%s: empty, no supply at the field edge", Guidance.vehicleName(self.vehicle))
        return false
    end
    local x, z, h = vehiclePose(self.vehicle)
    -- where we are now: back here after (the course's own path stays as it was)
    self.refill = self.refill or {resume = {x = x, z = z, h = h}, follower = self.follower, turns = self.turns,
                                  keepGaps = self.keepGaps}
    local refill = self.refill
    refill.supply, refill.node, refill.needer, refill.needIx, refill.types = supply, node, needer, needIx, types
    refill.phase = "to"
    refill.creep, refill.stall, refill.timer = 0, 0, 0
    self:raiseImplements()
    -- the implement's opening into the trigger: our guidance point that far back (and aside) of it, coming straight in
    local open = needer.getFillUnitExactFillRootNode and needer:getFillUnitExactFillRootNode(needIx) or needer.rootNode
    local left, _, ahead = localToLocal(open, self.vehicle:getAIDirectionNode(), 0, 0, 0)
    local tx, _, tz = getWorldTranslation(node)
    local th = math.atan2(tz - z, tx - x)
    local lx, lz = leftOf(th)
    -- stop REFILL_CREEP_MAX / 2 short, the rest crept
    local short = Driver.REFILL_CREEP_MAX / 2
    local gx = tx - math.cos(th) * (ahead + short) - lx * left
    local gz = tz - math.sin(th) * (ahead + short) - lz * left
    refill.creepH = th
    refill.path = self:refillPath(x, z, h, gx, gz, th)
    Guidance.info("%s: empty, refilling from %s at the field edge", Guidance.vehicleName(self.vehicle),
        Guidance.vehicleName(supply))
    return true
end

--- A way from (x, z, h) to (gx, gz) facing gh, on the field round the crop: a path follower
function Driver:refillPath(x, z, h, gx, gz, gh)
    local runIn = math.max(self.info.runOut, 3)
    local settings = self.course.plan:getGeneratorSettings()
    local pts = GuidanceCourseGenerator.planApproach(self.course.area, settings, {x = x, y = z, h = h},
        {x = gx - math.cos(gh) * runIn, y = gz - math.sin(gh) * runIn, h = gh})
    local list = {{x = x, z = z, t = "C", work = false}}
    for _, p in ipairs(pts) do list[#list + 1] = {x = p.x, z = p.y, t = "C", work = false} end
    list[#list + 1] = {x = gx, z = gz, t = "C", work = false}
    return GuidancePathFollower.new(list)
end

--- Driving data while refilling (getDriveData): to the supply, into its trigger, filling, back to where we stopped
function Driver:updateRefill(dt, x, z, h)
    local r = self.refill
    r.timer = r.timer + dt
    local function follow(f)
        f:update(x, z, h)
        if f:getDistanceToCusp() < 0.5 then f:passCusp() end
        if f:isFinished() then return nil end
        local reversing = f:isReversing()
        local gx, gz = f:getGoal(reversing and 3 or 5)
        local speed = math.min(Driver.REFILL_SPEED, 3.6 * math.sqrt(2 * 0.8 * f:getRemaining()) + 1)
        speed = self:giveWay(dt, speed, x, z, h, reversing)
        return gx, gz, not reversing, speed, f:getRemaining()
    end
    if r.phase == "to" then
        local gx, gz, fwd, speed, toStop = follow(r.path)
        if gx then return gx, gz, fwd, speed, toStop end
        r.phase, r.creepFrom = "creep", {x = x, z = z}
    end
    local needer = r.needer
    local fillSpec = needer.spec_fillUnit
    local level = fillPercentage(needer, r.needIx) or 0
    if r.phase == "creep" then
        -- in until the game says the opening is in the supply's trigger
        local triggers = fillSpec and fillSpec.fillTrigger and fillSpec.fillTrigger.triggers or {}
        local inside = false
        for _, trigger in ipairs(triggers) do
            if trigger.getIsActivatable == nil or trigger:getIsActivatable(needer) then inside = true end
        end
        if inside then
            needer:setFillUnitIsFilling(true)
            r.phase, r.lastLevel, r.stall = "fill", level, 0
            return x + math.cos(h), z + math.sin(h), true, 0, 0
        end
        local crept = math.sqrt((x - r.creepFrom.x) ^ 2 + (z - r.creepFrom.z) ^ 2)
        if crept > Driver.REFILL_CREEP_MAX then
            -- didn't get in: another supply, or stop for the player
            Guidance.info("%s: couldn't reach the supply's filling point", Guidance.vehicleName(self.vehicle))
            self.emptySupplies = self.emptySupplies or {}
            self.emptySupplies[r.supply] = true
            if not self:startEdgeRefill(needer, r.needIx, r.types) then
                self.refill = nil
                self:stop(AIMessageErrorOutOfFill.new(), "NEEDS_FILLING")
            end
            return x + math.cos(h), z + math.sin(h), true, 0, 0
        end
        return x + math.cos(r.creepH) * 5, z + math.sin(r.creepH) * 5, true, Driver.REFILL_CREEP, 5
    elseif r.phase == "fill" then
        local filling = fillSpec and fillSpec.fillTrigger and fillSpec.fillTrigger.isFilling
        if level >= Driver.REFILL_FULL then
            if filling then needer:setFillUnitIsFilling(false) end
            self:refillBack(x, z, h)
        elseif level > r.lastLevel + 0.001 then
            r.lastLevel, r.stall = level, 0
        else
            r.stall = r.stall + dt
            if r.stall > Driver.REFILL_STALL then
                -- not getting fuller: that supply is empty; enough to go on with, or the next one
                if filling then needer:setFillUnitIsFilling(false) end
                self.emptySupplies = self.emptySupplies or {}
                self.emptySupplies[r.supply] = true
                if level > 0.2 or not self:startEdgeRefill(needer, r.needIx, r.types) then
                    if level > 0.02 then
                        self:refillBack(x, z, h)
                    else
                        self.refill = nil
                        self:stop(AIMessageErrorOutOfFill.new(), "NEEDS_FILLING")
                    end
                end
            elseif not filling then
                -- (the game stops filling when the supply runs dry or the trigger changes: start it again once)
                needer:setFillUnitIsFilling(true)
            end
        end
        return x + math.cos(h), z + math.sin(h), true, 0, 0
    elseif r.phase == "back" then
        local gx, gz, fwd, speed, toStop = follow(r.path)
        if gx then return gx, gz, fwd, speed, toStop end
        -- where we stopped: the course on from there
        self.follower, self.turns, self.keepGaps = r.follower, r.turns, r.keepGaps
        self.turnIx = nil
        self.refill = nil
        self.lastS = nil
        Guidance.info("%s: refilled, going on", Guidance.vehicleName(self.vehicle))
        return x + math.cos(h), z + math.sin(h), true, 0, 0
    end
    return x + math.cos(h), z + math.sin(h), true, 0, 0
end

function Driver:refillBack(x, z, h)
    local r = self.refill
    r.phase = "back"
    r.path = self:refillPath(x, z, h, r.resume.x, r.resume.z, r.resume.h)
end
